# usm list — show installed modules from lock.yaml: name, resolved version/ref,
# source (+subdir), and enabled/disabled fragment counts. Results go to stdout.

cmd_list() {
  local lock cfg n i
  lock="$(usm_lock_file)"
  if [ ! -f "$lock" ] || [ "$(yq '.modules // [] | length' "$lock" 2>/dev/null)" = 0 ]; then
    printf 'no modules installed\n'
    return 0
  fi
  cfg="$(usm_config_file)"
  n="$(yq '.modules | length' "$lock")"

  {
    printf 'NAME\tVERSION\tSOURCE\tFRAGMENTS\n'
    i=0
    while [ "$i" -lt "$n" ]; do
      local name ver ref src sub disp total disabled enabled
      name="$(yq ".modules[$i].name" "$lock")"
      ver="$(yq ".modules[$i].version" "$lock")"
      ref="$(yq ".modules[$i].ref" "$lock")"
      src="$(yq ".modules[$i].source" "$lock")"
      sub="$(yq ".modules[$i].subdir" "$lock")"
      [ -n "$sub" ] && [ "$sub" != null ] && src="$src ($sub)"
      disp="$ver"
      { [ -z "$ver" ] || [ "$ver" = null ]; } && disp="$ref (floating)"

      total="$(yq "(.modules[$i].shell // [] | length) + ([.modules[$i].rc // {} | .[] | .[]] | length)" "$lock")"
      # Count DISABLED as the module's REAL fragments that are actually disabled — the
      # intersection of its fragments with overrides.disable_fragments. A stale/typo'd
      # override entry that names no real fragment must not skew the count negative.
      local frag
      disabled=0
      while IFS= read -r frag; do
        [ -z "$frag" ] && continue
        _usm_frag_disabled "$cfg" "$name" "$frag" && disabled=$((disabled + 1))
      done <<EOF
$(yq "[(.modules[$i].shell // [])[], (.modules[$i].rc // {} | .[] | .[])] | .[]" "$lock" 2>/dev/null)
EOF
      enabled=$((total - disabled))
      printf '%s\t%s\t%s\t%s enabled, %s disabled\n' "$name" "$disp" "$src" "$enabled" "$disabled"
      i=$((i + 1))
    done
  } | { command -v column >/dev/null 2>&1 && column -t -s "$(printf '\t')" || cat; }
}
