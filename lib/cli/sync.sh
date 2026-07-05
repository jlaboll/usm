# usm sync — reconcile this device to its config.yaml (the "copy config.yaml to a new
# machine" flow). Ensures every configured repo and transitive dep is cloned/fetched,
# then compiles. Works from a cold state: cache/ and lock.yaml may be absent — compile's
# discovery clones every missing repo and fetches the rest, so sync is just compile with
# a guaranteed fetch, plus an installed-count report.

cmd_sync() {
  local cfg lock; cfg="$(usm_config_file)"; lock="$(usm_lock_file)"
  [ -f "$cfg" ] || usm_die "no config.yaml; run 'usm init' first"
  usm_ensure_dirs

  # A plain compile already clones missing repos and fetches present ones during graph
  # discovery, so no separate fetch pass is needed to satisfy "guaranteed fetch".
  usm_compile || usm_die "sync failed"

  local n; n="$(yq '.modules | length' "$lock" 2>/dev/null)"; n="${n:-0}"
  usm_log "synced $n module(s)"
}
