# usm update [name] — re-fetch module repo(s), re-resolve against the SAME constraints
# in config.yaml, recompile, and report what moved per module (old ref/sha -> new).
#
# With no name: fetch every repo the lock references. With a name: fetch ONLY the repo
# backing that module. In both cases the re-resolve runs with USM_NO_FETCH=1 so compile
# does not silently pull unrelated repos forward — an untouched repo keeps its ref/sha.
#
# Version movement follows the existing resolver: a `>=` module adopts a newly-published
# higher tag; a floating module advances to the freshly-fetched default-branch HEAD
# (usm_git_ff_default fast-forwards the local branch the resolver reads).
#
# KNOWN LIMITATION (Phase 3 handoff): the dependency GRAPH is discovered at each repo's
# DEFAULT BRANCH, while names/shell/rc are read at the RESOLVED ref. If a tagged
# manifest's `requires` differs from the default branch, a newly-required dep can be
# missed until the default branch also carries it. update does not add a fixpoint
# re-resolve; a second `usm update` (or edit) picks up such a graph change.

cmd_update() {
  local target="${1:-}"
  local cfg lock; cfg="$(usm_config_file)"; lock="$(usm_lock_file)"
  [ -f "$cfg" ] || usm_die "no config.yaml; run 'usm init' first"
  usm_ensure_dirs

  # Snapshot the pre-update lock so the change report can diff against it.
  local pre; pre="$(usm_data_dir)/.lock.pre-update.$$"
  if [ -f "$lock" ]; then cp "$lock" "$pre"; else printf 'modules: []\n' >"$pre"; fi

  if [ -f "$lock" ] && [ "$(yq '.modules | length' "$lock" 2>/dev/null)" -gt 0 ]; then
    if [ -n "$target" ]; then
      local src
      src="$(NM="$target" usm_yaml_get "$lock" '.modules[] | select(.name==strenv(NM)) | .source')"
      [ -n "$src" ] || { rm -f "$pre"; usm_die "no installed module named '$target'"; }
      _usm_update_fetch "$src"
    else
      local s
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        _usm_update_fetch "$s"
      done <<EOF
$(yq '[.modules[].source] | unique | .[]' "$lock")
EOF
    fi
    # Re-resolve without re-fetching: only the repos fetched above may move.
    if ! USM_NO_FETCH=1 usm_compile; then rm -f "$pre"; usm_die "update failed"; fi
  else
    # Nothing locked yet — behave like a cold compile (clone + fetch everything).
    if ! usm_compile; then rm -f "$pre"; usm_die "update failed"; fi
  fi

  # Prune worktrees the freshly-written lock no longer references (e.g. a versioned
  # module that just advanced to a higher tag leaves its old <flat>/<tag> behind).
  _usm_worktrees_prune "$lock"

  _usm_update_report "$pre" "$lock"
  rm -f "$pre"
}

# Remove every worktree under $(usm_worktrees_dir) not referenced by a versioned module
# in $lock, forcefully cleaning leftover artifacts (usm_git_worktree_remove). Referenced
# worktrees are keyed by <flat>/<ref>, derived from each versioned lock module's source
# and ref. Empty <flat> parents are dropped. A missing/empty worktrees tree is a no-op.
_usm_worktrees_prune() {
  local lock="$1" wtroot referenced="" n i d
  wtroot="$(usm_worktrees_dir)"
  [ -d "$wtroot" ] || return 0
  [ -f "$lock" ] || return 0
  n="$(yq '.modules | length' "$lock" 2>/dev/null)"; n="${n:-0}"
  i=0
  while [ "$i" -lt "$n" ]; do
    local ver src rf flat
    ver="$(yq ".modules[$i].version" "$lock")"
    if [ -n "$ver" ] && [ "$ver" != null ]; then
      src="$(yq ".modules[$i].source" "$lock")"
      rf="$(yq ".modules[$i].ref" "$lock")"
      flat="$(usm_url_flatten "$src")"
      referenced="$referenced $wtroot/$flat/$rf"
    fi
    i=$((i + 1))
  done
  for d in "$wtroot"/*/*; do
    [ -d "$d" ] || continue
    case " $referenced " in
      *" $d "*) : ;;
      *) usm_git_worktree_remove "$d"; usm_vlog "pruned worktree $d" ;;
    esac
  done
  for d in "$wtroot"/*; do
    [ -d "$d" ] || continue
    rmdir "$d" 2>/dev/null || :
  done
}

# Fetch one repo (by source URL) and fast-forward its default branch so a floating
# module actually advances on re-resolve.
_usm_update_fetch() {
  local src dir
  src="$(usm_url_normalize "$1")"
  usm_vlog "fetching $src"
  usm_cache_sync "$src" || usm_die "failed to fetch $src"
  dir="$(usm_cache_path "$src")"
  usm_git_ff_default "$dir"
}

# A comparable ref token for a lock module: the tag for a versioned module, or
# "<branch>@<sha12>" for a floating one (where the ref alone never changes).
_usm_reftok() {
  local ref="$1" ver="$2" sha="$3"
  if [ -z "$ver" ] || [ "$ver" = null ]; then
    printf '%s@%s' "$ref" "$(printf '%s' "$sha" | cut -c1-12)"
  else
    printf '%s' "$ref"
  fi
}

# Print a per-module change summary comparing the pre-update lock to the current one.
# Changed modules always print; unchanged ones only under -v. Reports adds/removes too.
_usm_update_report() {
  local pre="$1" cur="$2" n i changed=0
  n="$(yq '.modules | length' "$cur" 2>/dev/null)"; n="${n:-0}"
  i=0
  while [ "$i" -lt "$n" ]; do
    local name nref nver nsha ntok oref over osha otok ocount
    name="$(yq ".modules[$i].name" "$cur")"
    nref="$(yq ".modules[$i].ref" "$cur")"
    nver="$(yq ".modules[$i].version" "$cur")"
    nsha="$(yq ".modules[$i].sha" "$cur")"
    ntok="$(_usm_reftok "$nref" "$nver" "$nsha")"
    ocount="$(NM="$name" yq '[.modules[]?|select(.name==strenv(NM))]|length' "$pre" 2>/dev/null)"
    if [ "${ocount:-0}" = 0 ]; then
      printf '  %s: (new) -> %s\n' "$name" "$ntok"
      changed=$((changed + 1))
    else
      oref="$(NM="$name" yq '.modules[]|select(.name==strenv(NM))|.ref' "$pre")"
      over="$(NM="$name" yq '.modules[]|select(.name==strenv(NM))|.version' "$pre")"
      osha="$(NM="$name" yq '.modules[]|select(.name==strenv(NM))|.sha' "$pre")"
      otok="$(_usm_reftok "$oref" "$over" "$osha")"
      if [ "$otok" != "$ntok" ]; then
        printf '  %s: %s -> %s\n' "$name" "$otok" "$ntok"
        changed=$((changed + 1))
      elif [ "${USM_VERBOSE:-0}" = 1 ]; then
        printf '  %s: unchanged (%s)\n' "$name" "$ntok"
      fi
    fi
    i=$((i + 1))
  done
  # Modules present before but gone now.
  local m mn mcur
  m="$(yq '.modules | length' "$pre" 2>/dev/null)"; m="${m:-0}"
  i=0
  while [ "$i" -lt "$m" ]; do
    mn="$(yq ".modules[$i].name" "$pre")"
    mcur="$(NM="$mn" yq '[.modules[]?|select(.name==strenv(NM))]|length' "$cur" 2>/dev/null)"
    if [ "${mcur:-0}" = 0 ]; then
      printf '  %s: removed\n' "$mn"
      changed=$((changed + 1))
    fi
    i=$((i + 1))
  done
  if [ "$changed" = 0 ]; then
    printf 'everything up to date\n'
  else
    printf 'updated %s module(s)\n' "$changed"
  fi
}
