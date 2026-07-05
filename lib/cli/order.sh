# usm order — inspect and edit local ordering/overrides, then recompile.
#
#   usm order [--show]                 print the effective load order + overrides
#   usm order <name> --before <other>  load <name> before <other>
#   usm order <name> --after  <other>  load <name> after  <other>
#   usm order <name> --disable <frag>  skip fragment <frag> of <name>
#   usm order <name> --enable  <frag>  un-skip a previously disabled fragment
#
# Mutating flags edit config.yaml's `overrides` (via yq) and recompile — exactly the
# same structure the resolver reads, so hand-editing config.yaml then `usm compile`
# is equivalent. No separate state store. Flags may be combined in one invocation.

cmd_order() {
  local name="" show=0
  local -a befores=() afters=() disables=() enables=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --show)      show=1; shift ;;
      --before)    [ -n "${2:-}" ] || usm_die "--before needs a module name";  befores+=("$2"); shift 2 ;;
      --before=*)  befores+=("${1#--before=}"); shift ;;
      --after)     [ -n "${2:-}" ] || usm_die "--after needs a module name";   afters+=("$2");  shift 2 ;;
      --after=*)   afters+=("${1#--after=}"); shift ;;
      --disable)   [ -n "${2:-}" ] || usm_die "--disable needs a fragment path"; disables+=("$2"); shift 2 ;;
      --disable=*) disables+=("${1#--disable=}"); shift ;;
      --enable)    [ -n "${2:-}" ] || usm_die "--enable needs a fragment path";  enables+=("$2");  shift 2 ;;
      --enable=*)  enables+=("${1#--enable=}"); shift ;;
      -*)          usm_die "unknown option: $1" ;;
      *)           [ -z "$name" ] && name="$1" || usm_die "unexpected argument: $1"; shift ;;
    esac
  done

  local nact=$(( ${#befores[@]} + ${#afters[@]} + ${#disables[@]} + ${#enables[@]} ))

  # No action (or --show) => print current state and stop.
  if [ "$show" = 1 ] || { [ -z "$name" ] && [ "$nact" = 0 ]; }; then
    _usm_order_show
    return 0
  fi
  [ -n "$name" ] || usm_die "usage: usm order <name> [--before X|--after X|--disable F|--enable F]"
  [ "$nact" -gt 0 ] || usm_die "usm order $name: nothing to do (pass --before/--after/--disable/--enable)"

  local cfg lock; cfg="$(usm_config_file)"; lock="$(usm_lock_file)"
  [ -f "$cfg" ]  || usm_die "no config.yaml; run 'usm init' first"
  [ -f "$lock" ] || usm_die "no lock.yaml; run 'usm compile' first"
  _usm_name_installed "$lock" "$name" || usm_die "no installed module named '$name'"

  # Validate --disable targets against the module's REAL fragments (shell + rc paths,
  # from lock.yaml) BEFORE mutating anything. A typo would otherwise be a silent no-op.
  local frag
  if [ "${#disables[@]}" -gt 0 ]; then
    for frag in "${disables[@]}"; do
      if ! _usm_is_fragment "$lock" "$name" "$frag"; then
        usm_die "'$frag' is not a fragment of '$name'; valid: $(_usm_module_fragments "$lock" "$name" | tr '\n' ' ')"
      fi
    done
  fi

  # Mutate config under a backup so a bad edit (e.g. a before/after that introduces a
  # cycle) never leaves config.yaml and lock.yaml inconsistent.
  local backup="$cfg.usm-order.$$"
  cp "$cfg" "$backup"

  local other i
  if [ "${#befores[@]}" -gt 0 ]; then
    for other in "${befores[@]}"; do
      _usm_name_installed "$lock" "$other" || usm_warn "'$other' is not installed; keeping the override anyway"
      _usm_ovr_add "$cfg" "$name" before "$other"
    done
  fi
  if [ "${#afters[@]}" -gt 0 ]; then
    for other in "${afters[@]}"; do
      _usm_name_installed "$lock" "$other" || usm_warn "'$other' is not installed; keeping the override anyway"
      _usm_ovr_add "$cfg" "$name" after "$other"
    done
  fi
  if [ "${#disables[@]}" -gt 0 ]; then
    for frag in "${disables[@]}"; do _usm_ovr_add "$cfg" "$name" disable_fragments "$frag"; done
  fi
  if [ "${#enables[@]}" -gt 0 ]; then
    for frag in "${enables[@]}"; do
      # Enabling a path that isn't currently disabled is a clear no-op, not an error.
      _usm_frag_disabled "$cfg" "$name" "$frag" || usm_warn "'$frag' is not disabled for '$name'; nothing to enable"
      _usm_ovr_del "$cfg" "$name" disable_fragments "$frag"
    done
  fi

  _usm_ovr_cleanup "$cfg"

  if ! usm_compile; then
    mv "$backup" "$cfg"
    usm_die "compile failed; config.yaml left unchanged"
  fi
  rm -f "$backup"
  usm_log "updated order for $name"
}

# 0 if lock.yaml lists a module with this name.
_usm_name_installed() {
  local cnt
  cnt="$(NM="$2" yq '[.modules[]? | select(.name==strenv(NM))] | length' "$1" 2>/dev/null)"
  [ "${cnt:-0}" != 0 ]
}

# Print every real fragment path (shell + rc) of module $2, from lock $1 (one per line).
# Shell and rc paths are concatenated into ONE array per module: a `,` union of the two
# streams would (in yq) drop the rc branch out of the module's scope, so avoid it.
_usm_module_fragments() {
  NM="$2" yq '.modules[]? | select(.name==strenv(NM)) |
    ((.shell // []) + [ (.rc // {})[] | .[] ]) | .[]' "$1" 2>/dev/null
}

# 0 if $3 is a real fragment (shell or rc) of module $2 in lock $1.
_usm_is_fragment() {
  local cnt
  cnt="$(NM="$2" FR="$3" yq '[.modules[]? | select(.name==strenv(NM)) |
    ((.shell // []) + [ (.rc // {})[] | .[] ]) | .[]] | map(select(. == strenv(FR))) | length' "$1" 2>/dev/null)"
  [ "${cnt:-0}" != 0 ]
}

# Append VAL to overrides.<nm>.<key> unless already present (dedupe). `key` is a fixed
# literal (before/after/disable_fragments) chosen by the caller, never user input.
_usm_ovr_add() {
  local cfg="$1" nm="$2" key="$3" val="$4" present
  present="$(NM="$nm" VAL="$val" yq "[.overrides[strenv(NM)].$key // [] | .[] | select(. == strenv(VAL))] | length" "$cfg" 2>/dev/null)"
  [ "${present:-0}" != 0 ] && return 0
  NM="$nm" VAL="$val" yq -i ".overrides[strenv(NM)].$key = ((.overrides[strenv(NM)].$key // []) + [strenv(VAL)])" "$cfg"
}

# Remove every occurrence of VAL from overrides.<nm>.<key>.
_usm_ovr_del() {
  local cfg="$1" nm="$2" key="$3" val="$4"
  NM="$nm" VAL="$val" yq -i ".overrides[strenv(NM)].$key = ((.overrides[strenv(NM)].$key // []) | map(select(. != strenv(VAL))))" "$cfg"
}

# Drop empty override arrays, then empty per-module maps, then an empty overrides map,
# so the resolver never sees {}/[] cruft. Correctness-preserving no-op when clean.
_usm_ovr_cleanup() {
  local cfg="$1" has
  has="$(yq '.overrides | length' "$cfg" 2>/dev/null)"
  [ "${has:-0}" = 0 ] && return 0
  yq -i '.overrides |= with_entries(.value |= (
    del(.after            | select(length == 0)) |
    del(.before           | select(length == 0)) |
    del(.disable_fragments | select(length == 0))
  ))' "$cfg"
  yq -i '.overrides |= with_entries(select(.value | length > 0))' "$cfg"
  yq -i 'del(.overrides | select(length == 0))' "$cfg"
}

# Print the effective load order (lock.yaml) with each module's overrides + disabled
# fragments. Read-only; stdout.
_usm_order_show() {
  local lock cfg n i
  lock="$(usm_lock_file)"; cfg="$(usm_config_file)"
  if [ ! -f "$lock" ] || [ "$(yq '.modules // [] | length' "$lock" 2>/dev/null)" = 0 ]; then
    printf 'no modules installed\n'
    return 0
  fi
  n="$(yq '.modules | length' "$lock")"
  printf 'load order (effective):\n'
  i=0
  while [ "$i" -lt "$n" ]; do
    local name ver ref disp after before disabled
    name="$(yq ".modules[$i].name" "$lock")"
    ver="$(yq ".modules[$i].version" "$lock")"
    ref="$(yq ".modules[$i].ref" "$lock")"
    disp="$ver"; { [ -z "$ver" ] || [ "$ver" = null ]; } && disp="$ref (floating)"
    printf '  %s. %s (%s)\n' "$((i + 1))" "$name" "$disp"
    after="$(NM="$name"    yq '(.overrides[strenv(NM)].after // []) | join(", ")'   "$cfg" 2>/dev/null)"
    before="$(NM="$name"   yq '(.overrides[strenv(NM)].before // []) | join(", ")'  "$cfg" 2>/dev/null)"
    disabled="$(NM="$name" yq '(.overrides[strenv(NM)].disable_fragments // []) | join(", ")' "$cfg" 2>/dev/null)"
    [ -n "$after" ]    && [ "$after" != null ]    && printf '       after: %s\n' "$after"
    [ -n "$before" ]   && [ "$before" != null ]   && printf '       before: %s\n' "$before"
    [ -n "$disabled" ] && [ "$disabled" != null ] && printf '       disabled: %s\n' "$disabled"
    i=$((i + 1))
  done
}
