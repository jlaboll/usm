# usm doctor — diagnose configuration/install problems and report OK / WARN / ERROR
# lines. Exits non-zero if any ERROR was found, zero otherwise (warnings don't fail).
#
# Checks: git + yq present; config.yaml exists and is valid YAML; lock.yaml present;
# every module source has a cache clone; lock is consistent with config (no configured
# module missing from lock, no orphan lock module); the config resolves cleanly (no
# unsatisfiable constraint / name conflict / cycle — a dry re-resolve); overrides keys
# reference installed modules (WARN on unknown); each assembled rc file's ~/.<name>
# symlink points at its staged file; compiled/load.sh exists and every path it sources
# exists on disk.

_dr_ok()   { printf 'OK    %s\n' "$1"; }
_dr_warn() { printf 'WARN  %s\n' "$1"; _DR_WARN=$((_DR_WARN + 1)); }
_dr_err()  { printf 'ERROR %s\n' "$1"; _DR_ERR=$((_DR_ERR + 1)); }

cmd_doctor() {
  local cfg lock cache rcdir compiled
  cfg="$(usm_config_file)"; lock="$(usm_lock_file)"
  cache="$(usm_cache_dir)"; rcdir="$(usm_rc_dir)"; compiled="$(usm_compiled_dir)"
  _DR_ERR=0; _DR_WARN=0

  # 1. required tools
  if command -v git >/dev/null 2>&1; then _dr_ok "git present"; else _dr_err "git not found on PATH"; fi
  if command -v yq  >/dev/null 2>&1; then _dr_ok "yq present";  else _dr_err "yq not found on PATH"; fi

  # 2. config.yaml presence + validity
  local have_cfg=0
  if [ -f "$cfg" ]; then
    if yq '.' "$cfg" >/dev/null 2>&1; then have_cfg=1; _dr_ok "config.yaml is valid YAML"
    else _dr_err "config.yaml is not valid YAML ($cfg)"; fi
  else
    _dr_err "config.yaml missing ($cfg)"
  fi

  # 3. lock.yaml presence
  local have_lock=0
  if [ -f "$lock" ]; then have_lock=1; _dr_ok "lock.yaml present"
  else _dr_err "lock.yaml missing; run 'usm compile'"; fi

  # 4. every module source has a cache clone present
  if [ "$have_lock" = 1 ]; then
    local s missing_cache=0
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      if [ ! -d "$cache/$(usm_hash "$s")/.git" ]; then
        _dr_err "no cache clone for source: $s"; missing_cache=1
      fi
    done <<EOF
$(yq '[.modules[].source] | unique | .[]' "$lock" 2>/dev/null)
EOF
    [ "$missing_cache" = 0 ] && _dr_ok "all module sources cloned in cache"
  fi

  # 5. lock consistent with config: configured modules present, no orphan lock module
  if [ "$have_cfg" = 1 ] && [ "$have_lock" = 1 ]; then
    local cn ci miss=0
    cn="$(yq '.modules // [] | length' "$cfg")"
    ci=0
    while [ "$ci" -lt "$cn" ]; do
      local csrc csub cnt
      csrc="$(usm_url_normalize "$(yq ".modules[$ci].source" "$cfg")")"
      csub="$(yq ".modules[$ci].subdir // \"\"" "$cfg")"; [ "$csub" = null ] && csub=""
      cnt="$(SRC="$csrc" SUB="$csub" yq '[.modules[]?|select((.source==strenv(SRC)) and ((.subdir // "")==strenv(SUB)))]|length' "$lock")"
      [ "${cnt:-0}" -gt 0 ] || { _dr_err "configured module '${csub:-<root>}' @ $csrc is missing from lock"; miss=1; }
      ci=$((ci + 1))
    done
    [ "$miss" = 0 ] && _dr_ok "all configured modules present in lock"

    local ln li orph=0
    ln="$(yq '.modules | length' "$lock")"
    li=0
    while [ "$li" -lt "$ln" ]; do
      local lname lsrc lsub inconf req
      lname="$(yq ".modules[$li].name" "$lock")"
      lsrc="$(yq ".modules[$li].source" "$lock")"
      lsub="$(yq ".modules[$li].subdir // \"\"" "$lock")"
      inconf="$(SRC="$lsrc" SUB="$lsub" yq '[.modules[]?|select((.source==strenv(SRC)) and ((.subdir // "")==strenv(SUB)))]|length' "$cfg")"
      if [ "${inconf:-0}" = 0 ]; then
        # Not configured directly — it must be pulled in as a dependency of something.
        req="$(NM="$lname" yq '[.modules[]?|select((.requires // [])|any_c(.==strenv(NM)))]|length' "$lock" 2>/dev/null)"
        [ "${req:-0}" -gt 0 ] || { _dr_err "orphan lock module '$lname' (not configured and not required by any module)"; orph=1; }
      fi
      li=$((li + 1))
    done
    [ "$orph" = 0 ] && _dr_ok "no orphan lock modules"
  fi

  # 6. dry re-resolve (constraints / name conflicts / cycles). Skipped when earlier
  # checks already failed, so a broken cache is not silently re-cloned to mask it.
  if [ "$_DR_ERR" = 0 ] && [ "$have_cfg" = 1 ]; then
    local tmpl rerr rc reason
    tmpl="$(usm_data_dir)/.lock.doctor.$$"
    rerr="$(USM_NO_FETCH=1 _usm_resolve "$cfg" "$tmpl" 2>&1)"; rc=$?
    rm -f "$tmpl"
    if [ "$rc" = 0 ]; then
      _dr_ok "config resolves cleanly (no conflicts, cycles, or unsatisfiable constraints)"
    else
      reason="$(printf '%s\n' "$rerr" | grep '^error:' | tail -1)"; reason="${reason#error: }"
      _dr_err "config does not resolve: ${reason:-unknown}"
    fi
  fi

  # 7. overrides keys must reference installed module names (WARN only)
  if [ "$have_cfg" = 1 ] && [ "$have_lock" = 1 ]; then
    local k
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      local kc; kc="$(NM="$k" yq '[.modules[]?|select(.name==strenv(NM))]|length' "$lock" 2>/dev/null)"
      [ "${kc:-0}" -gt 0 ] || _dr_warn "override references unknown module '$k'"
    done <<EOF
$(yq '.overrides // {} | keys | .[]' "$cfg" 2>/dev/null)
EOF
  fi

  # 8. rc symlinks: for each staged rc file, ~/.<name> must point at it
  if [ "$have_cfg" = 1 ]; then
    local name staged link
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      staged="$rcdir/$name"; link="$HOME/.$name"
      [ -f "$staged" ] || continue   # nothing was assembled for this rc file
      if [ -L "$link" ] && [ "$(readlink "$link")" = "$staged" ]; then
        _dr_ok "~/.$name links to its staged rc file"
      else
        _dr_err "~/.$name does not link to $staged"
      fi
    done <<EOF
$(yq '.rc_files // [] | .[]' "$cfg" 2>/dev/null)
EOF
  fi

  # 9. compiled/load.sh exists and every sourced path is present on disk
  local load="$compiled/load.sh"
  if [ -f "$load" ]; then
    local line p bad=0
    while IFS= read -r line; do
      case "$line" in
        '. "'*)
          p="${line#. \"}"; p="${p%\"}"
          [ -f "$p" ] || { _dr_err "load.sh sources a missing file: $p"; bad=1; }
          ;;
      esac
    done < "$load"
    [ "$bad" = 0 ] && _dr_ok "all load.sh fragment paths exist"
  else
    _dr_err "compiled/load.sh missing; run 'usm compile'"
  fi

  printf '\n'
  if [ "$_DR_ERR" -gt 0 ]; then
    usm_log "doctor: $_DR_ERR error(s), $_DR_WARN warning(s)"
    return 1
  fi
  [ "$_DR_WARN" -gt 0 ] && usm_log "doctor: $_DR_WARN warning(s)"
  usm_log "doctor: all checks passed"
  return 0
}
