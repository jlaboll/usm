# usm remove <name> — remove a module (matched by manifest name) from config.yaml,
# recompile, and prune any cache clone no longer referenced by the lock.

cmd_remove() {
  local name="${1:-}"
  [ -n "$name" ] || usm_die "usage: usm remove <name>"

  local cfg lock; cfg="$(usm_config_file)"; lock="$(usm_lock_file)"
  [ -f "$cfg" ] || usm_die "no config.yaml; run 'usm init' first"
  [ -f "$lock" ] || usm_die "no lock.yaml; run 'usm compile' first"

  # config.modules is keyed by source+subdir; map the name -> source/subdir via lock.
  local src sub
  src="$(NM="$name" usm_yaml_get "$lock" '.modules[] | select(.name==strenv(NM)) | .source')"
  [ -n "$src" ] || usm_die "no installed module named '$name'"
  sub="$(NM="$name" usm_yaml_get "$lock" '.modules[] | select(.name==strenv(NM)) | .subdir')"

  # Warn if any other installed module still requires this one.
  local dependents
  dependents="$(NM="$name" yq '[.modules[] | select((.requires // []) | any_c(. == strenv(NM))) | .name] | join(", ")' "$lock" 2>/dev/null)"
  [ -n "$dependents" ] && [ "$dependents" != null ] && usm_warn "still required by: $dependents"

  SRC="$src" SUB="$sub" yq -i '
    .modules = ((.modules // []) | map(select(((.source==strenv(SRC)) and ((.subdir // "")==strenv(SUB))) | not)))' "$cfg"

  # Drop the removed module's own overrides so they don't linger as cruft (doctor would
  # otherwise WARN on the now-unknown module reference); collapse an emptied map.
  NM="$name" yq -i 'del(.overrides[strenv(NM)])' "$cfg"
  yq -i 'del(.overrides | select(length == 0))' "$cfg"

  usm_compile || usm_die "compile failed"
  _usm_prune_cache
  usm_log "removed $name"
}

# Delete cache clones no longer referenced by any lock module.
_usm_prune_cache() {
  local lock cache used d h
  lock="$(usm_lock_file)"; cache="$(usm_cache_dir)"
  [ -d "$cache" ] || return 0
  # Guard: only prune on a SUCCESSFUL lock read. A failed/empty yq read would look like
  # "no clone is referenced" and license `rm -rf` of every clone — skip instead. (A
  # legitimately module-less lock reads successfully with empty output and prunes all.)
  [ -f "$lock" ] || { usm_warn "no lock.yaml; skipping cache prune"; return 0; }
  if ! used="$(yq '[.modules[].cache] | .[]' "$lock" 2>/dev/null)"; then
    usm_warn "could not read lock.yaml; skipping cache prune"
    return 0
  fi
  for d in "$cache"/*; do
    [ -d "$d" ] || continue
    h="$(basename "$d")"
    if ! printf '%s\n' "$used" | grep -qxF "$h"; then
      usm_run rm -rf "$d"
      usm_vlog "pruned cache clone $h"
    fi
  done
}
