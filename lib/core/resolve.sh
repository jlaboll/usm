# Dependency resolution (Phase 3). Builds the module graph from config.yaml plus
# every manifest's `requires`, resolves each repo (repo-granular: one git ref shared
# by all its subdir-modules) to the highest semver tag >= the MERGED max lower bound,
# populates `requires` edges, topologically orders by deps + overrides, and writes
# lock.yaml in FINAL LOAD ORDER. bash 3.2-safe: maps are emulated with parallel arrays
# searched linearly (NO associative arrays).
#
# Reuses from compile.sh: _usm_ver_ge, _usm_pick_tag. From git.sh: usm_url_normalize,
# usm_hash, usm_cache_sync, usm_git_* helpers. From yaml.sh: usm_yaml_get/seq.

# ---- tiny map helpers (linear search over parallel arrays) --------------------

# Index of a repo hash in REPO_HASH, or -1.
_usm_repo_index() {
  local key="$1" i=0 n=${#REPO_HASH[@]}
  while [ "$i" -lt "$n" ]; do
    [ "${REPO_HASH[$i]}" = "$key" ] && { printf '%s' "$i"; return; }
    i=$((i + 1))
  done
  printf -- '-1'
}

# Index of a module identity ("<hash>|<subdir>") in MOD_KEY, or -1.
_usm_mod_index() {
  local key="$1" i=0 n=${#MOD_KEY[@]}
  while [ "$i" -lt "$n" ]; do
    [ "${MOD_KEY[$i]}" = "$key" ] && { printf '%s' "$i"; return; }
    i=$((i + 1))
  done
  printf -- '-1'
}

# Index of a module by resolved name in MOD_NAME, or -1.
_usm_name_index() {
  local nm="$1" i=0 n=${#MOD_NAME[@]}
  while [ "$i" -lt "$n" ]; do
    [ "${MOD_NAME[$i]}" = "$nm" ] && { printf '%s' "$i"; return; }
    i=$((i + 1))
  done
  printf -- '-1'
}

# Strip a constraint down to its bare numeric lower bound (X.Y.Z), or "" if none.
_usm_bound() {
  local c="$1"
  [ "$c" = null ] && c=""
  c="${c#>=}"; c="${c#>}"; c="${c#=}"; c="${c#v}"
  printf '%s' "$(printf '%s' "$c" | tr -d '[:space:]')"
}

# ---- graph discovery (BFS over module identities) ----------------------------

# Visit one (source, subdir, constraint): ensure the repo is cached, merge its lower
# bound, and — if this module identity is new — record it and enqueue its requires.
_usm_visit() {
  local src sub cons hash dir ri bound cur key mi mdir manifest reqkeys rn j
  src="$(usm_url_normalize "$1")"; sub="$2"; cons="$3"
  [ "$sub" = null ] && sub=""
  [ "$cons" = null ] && cons=""
  hash="$(usm_hash "$src")"
  dir="$(usm_cache_path "$src")"

  # Register the repo (once). Check it out at the default branch so manifests read
  # during discovery are consistent regardless of a prior compile's checked-out tag.
  ri="$(_usm_repo_index "$hash")"
  if [ "$ri" = -1 ]; then
    usm_cache_sync "$src" || { usm_err "failed to fetch $src"; return 1; }
    local db; db="$(usm_git_default_branch "$dir")"
    [ -n "$db" ] && usm_git_checkout "$dir" "$db"
    REPO_HASH+=("$hash"); REPO_URL+=("$src"); REPO_BOUND+=("")
    REPO_REF+=(""); REPO_VER+=(""); REPO_SHA+=(""); REPO_DIR+=("")
    ri="$(_usm_repo_index "$hash")"
  fi

  # Merge this requester's lower bound into the repo's max bound.
  bound="$(_usm_bound "$cons")"
  if [ -n "$bound" ]; then
    cur="${REPO_BOUND[$ri]}"
    if [ -z "$cur" ] || _usm_ver_ge "$bound" "$cur"; then REPO_BOUND[$ri]="$bound"; fi
  fi

  key="$hash|$sub"
  mi="$(_usm_mod_index "$key")"
  [ "$mi" != -1 ] && return 0   # identity already discovered

  mdir="$dir"; [ -n "$sub" ] && mdir="$dir/$sub"
  manifest="$mdir/usm.yaml"
  [ -f "$manifest" ] || { usm_err "no usm.yaml at '${sub:-<root>}' in $src"; return 1; }

  # Enqueue this manifest's requires and remember their identities for edge-building.
  reqkeys=""
  rn="$(yq '.requires // [] | length' "$manifest" 2>/dev/null)"; rn="${rn:-0}"
  j=0
  while [ "$j" -lt "$rn" ]; do
    local rsrc rsub rcons rkey
    rsrc="$(yq ".requires[$j].source" "$manifest")"
    rsub="$(yq ".requires[$j].subdir // \"\"" "$manifest")"
    rcons="$(yq ".requires[$j].version // \"\"" "$manifest")"
    [ "$rsub" = null ] && rsub=""
    [ "$rcons" = null ] && rcons=""
    rkey="$(usm_hash "$(usm_url_normalize "$rsrc")")|$rsub"
    reqkeys="$reqkeys $rkey"
    Q_SRC+=("$rsrc"); Q_SUB+=("$rsub"); Q_CONS+=("$rcons")
    j=$((j + 1))
  done

  MOD_KEY+=("$key"); MOD_HASH+=("$hash"); MOD_SUB+=("$sub"); MOD_SRC+=("$src")
  MOD_NAME+=(""); MOD_REQ+=(""); MOD_REQKEYS+=("${reqkeys# }")
}

# Seed the worklist from config modules (in order), then drain it (deps appended
# after, so config order precedes transitive deps as the base ordering).
_usm_discover() {
  local cfg="$1" n i head
  n="$(yq '.modules // [] | length' "$cfg")"
  i=0
  while [ "$i" -lt "$n" ]; do
    Q_SRC+=("$(yq ".modules[$i].source" "$cfg")")
    Q_SUB+=("$(yq ".modules[$i].subdir // \"\"" "$cfg")")
    Q_CONS+=("$(yq ".modules[$i].version // \"\"" "$cfg")")
    i=$((i + 1))
  done
  head=0
  while [ "$head" -lt "${#Q_SRC[@]}" ]; do
    _usm_visit "${Q_SRC[$head]}" "${Q_SUB[$head]}" "${Q_CONS[$head]}" || return 1
    head=$((head + 1))
  done
}

# ---- per-repo version resolution ---------------------------------------------

# Resolve every discovered repo to a single ref/version/sha and check it out.
_usm_resolve_repos() {
  local i=0 n=${#REPO_HASH[@]}
  while [ "$i" -lt "$n" ]; do
    local hash="${REPO_HASH[$i]}" url="${REPO_URL[$i]}" bound="${REPO_BOUND[$i]}"
    local base ref ver sha moddir wt
    base="$(usm_cache_path "$url")"
    if [ -z "$bound" ]; then
      # No constraint anywhere -> the base clone floats at default-branch HEAD.
      ref="$(usm_git_default_branch "$base")"
      [ -n "$ref" ] || { usm_err "cannot determine default branch for $url"; return 1; }
      ver=""
      usm_git_checkout "$base" "$ref" || { usm_err "checkout '$ref' failed for $url"; return 1; }
      moddir="$base"
    else
      # Versioned release -> resolve the tag and materialize it in an isolated worktree.
      ref="$(_usm_pick_tag "$base" "$bound")"
      [ -n "$ref" ] || { usm_err "no tag satisfies '>=$bound' for $url (release tags must be vX.Y.Z)"; return 1; }
      ver="${ref#v}"
      wt="$(usm_worktrees_dir)/$(usm_url_flatten "$url")/$ref"
      usm_git_worktree_add "$base" "$ref" "$wt" || { usm_err "worktree '$ref' failed for $url"; return 1; }
      moddir="$wt"
    fi
    sha="$(usm_git_head_sha "$moddir")"
    [ -n "$sha" ] || { usm_err "cannot read sha for '$ref' in $url"; return 1; }
    REPO_REF[$i]="$ref"; REPO_VER[$i]="$ver"; REPO_SHA[$i]="$sha"; REPO_DIR[$i]="$moddir"
    i=$((i + 1))
  done
}

# ---- names, conflicts, requires edges ----------------------------------------

# Read each module's manifest name at the resolved ref; error on a missing name or on
# two DIFFERENT sources declaring the SAME name (naming both culprits).
_usm_read_names() {
  local i=0 n=${#MOD_KEY[@]}
  while [ "$i" -lt "$n" ]; do
    local hash="${MOD_HASH[$i]}" sub="${MOD_SUB[$i]}" dir mdir manifest name ri
    ri="$(_usm_repo_index "$hash")"
    dir="${REPO_DIR[$ri]}"
    mdir="$dir"; [ -n "$sub" ] && mdir="$dir/$sub"
    manifest="$mdir/usm.yaml"
    [ -f "$manifest" ] || { usm_err "no usm.yaml at '${sub:-<root>}' in ${MOD_SRC[$i]} at resolved ref"; return 1; }
    name="$(usm_yaml_get "$manifest" '.name')"
    [ -n "$name" ] || { usm_err "manifest at '${sub:-<root>}' in ${MOD_SRC[$i]} has no 'name'"; return 1; }
    MOD_NAME[$i]="$name"
    i=$((i + 1))
  done
  local a=0
  while [ "$a" -lt "$n" ]; do
    local b=$((a + 1))
    while [ "$b" -lt "$n" ]; do
      if [ "${MOD_NAME[$a]}" = "${MOD_NAME[$b]}" ]; then
        usm_err "module name conflict: '${MOD_NAME[$a]}' declared by ${MOD_SRC[$a]} (${MOD_SUB[$a]:-<root>}) and ${MOD_SRC[$b]} (${MOD_SUB[$b]:-<root>})"
        return 1
      fi
      b=$((b + 1))
    done
    a=$((a + 1))
  done
}

# Turn each module's required identities into a space-separated list of dep NAMES.
_usm_build_requires() {
  local i=0 n=${#MOD_KEY[@]}
  while [ "$i" -lt "$n" ]; do
    local reqs="" k mi
    for k in ${MOD_REQKEYS[$i]}; do
      mi="$(_usm_mod_index "$k")"
      if [ "$mi" = -1 ]; then
        usm_err "unresolved dependency ($k) required by ${MOD_NAME[$i]}"
        return 1
      fi
      reqs="$reqs ${MOD_NAME[$mi]}"
    done
    MOD_REQ[$i]="${reqs# }"
    i=$((i + 1))
  done
}

# ---- topological ordering (Kahn, stable by base/discovery order) -------------

# Add a dependency edge from->to (dep before dependent), deduped; bumps indegree[to].
_usm_add_edge() {
  local key="$1>$2"
  case "$EDGE_SEEN" in *" $key "*) return 0 ;; esac
  EDGE_SEEN="$EDGE_SEEN$key "
  EDGE_FROM+=("$1"); EDGE_TO+=("$2")
  INDEG[$2]=$(( ${INDEG[$2]} + 1 ))
}

# Names of nodes never emitted (the cycle) for error reporting.
_usm_cycle_members() {
  local n="$1" i=0 out=""
  while [ "$i" -lt "$n" ]; do
    [ "${DONE[$i]}" = 0 ] && out="$out ${MOD_NAME[$i]}"
    i=$((i + 1))
  done
  printf '%s' "${out# }"
}

# Produce ORDER (module indices in final load order): requires edges first, then
# overrides before/after, resolved by Kahn's algorithm with a min-base-index tie-break
# so config order is preserved among independent modules. Cycles -> error.
_usm_toposort() {
  local cfg="$1" n=${#MOD_KEY[@]} i
  INDEG=(); EDGE_FROM=(); EDGE_TO=(); EDGE_SEEN=" "; ORDER=(); DONE=()
  i=0; while [ "$i" -lt "$n" ]; do INDEG[$i]=0; i=$((i + 1)); done

  # requires: each dependency loads before its dependent.
  i=0
  while [ "$i" -lt "$n" ]; do
    local dep di
    for dep in ${MOD_REQ[$i]}; do
      di="$(_usm_name_index "$dep")"
      [ "$di" = -1 ] && continue
      _usm_add_edge "$di" "$i"
    done
    i=$((i + 1))
  done

  # overrides: after=[X] => X before this; before=[Y] => this before Y.
  i=0
  while [ "$i" -lt "$n" ]; do
    local nm="${MOD_NAME[$i]}" a ai
    while IFS= read -r a; do
      [ -z "$a" ] && continue
      ai="$(_usm_name_index "$a")"; [ "$ai" = -1 ] && continue
      _usm_add_edge "$ai" "$i"
    done <<EOF
$(NM="$nm" usm_yaml_seq "$cfg" '.overrides[strenv(NM)].after')
EOF
    while IFS= read -r a; do
      [ -z "$a" ] && continue
      ai="$(_usm_name_index "$a")"; [ "$ai" = -1 ] && continue
      _usm_add_edge "$i" "$ai"
    done <<EOF
$(NM="$nm" usm_yaml_seq "$cfg" '.overrides[strenv(NM)].before')
EOF
    i=$((i + 1))
  done

  i=0; while [ "$i" -lt "$n" ]; do DONE[$i]=0; i=$((i + 1)); done
  local emitted=0
  while [ "$emitted" -lt "$n" ]; do
    local pick=-1
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${DONE[$i]}" = 0 ] && [ "${INDEG[$i]}" -le 0 ]; then pick=$i; break; fi
      i=$((i + 1))
    done
    if [ "$pick" = -1 ]; then
      usm_err "dependency cycle among: $(_usm_cycle_members "$n")"
      return 1
    fi
    DONE[$pick]=1; ORDER+=("$pick"); emitted=$((emitted + 1))
    local e=0 en=${#EDGE_FROM[@]}
    while [ "$e" -lt "$en" ]; do
      if [ "${EDGE_FROM[$e]}" = "$pick" ]; then
        local t="${EDGE_TO[$e]}"
        INDEG[$t]=$(( ${INDEG[$t]} - 1 ))
      fi
      e=$((e + 1))
    done
  done
}

# ---- lock emission -----------------------------------------------------------

# Write lock.yaml modules in ORDER. Byte-compatible with the Phase 2 schema; only
# `constraint` (now the merged lower bound), `requires`, and ORDER differ.
_usm_write_lock() {
  local lock="$1" tmp="$lock.tmp.$$"
  printf 'modules: []\n' >"$tmp"
  local oi=0 on=${#ORDER[@]}
  while [ "$oi" -lt "$on" ]; do
    local idx="${ORDER[$oi]}"
    local hash="${MOD_HASH[$idx]}" sub="${MOD_SUB[$idx]}" src="${MOD_SRC[$idx]}"
    local ri; ri="$(_usm_repo_index "$hash")"
    local ref="${REPO_REF[$ri]}" ver="${REPO_VER[$ri]}" sha="${REPO_SHA[$ri]}" bound="${REPO_BOUND[$ri]}"
    local cons=""; [ -n "$bound" ] && cons=">=$bound"
    local base mdir manifest relpath root cachekey
    base="${REPO_DIR[$ri]}"
    mdir="$base"; [ -n "$sub" ] && mdir="$base/$sub"
    manifest="$mdir/usm.yaml"
    root="$(usm_cache_dir)"; relpath="${mdir#"$root"/}"
    cachekey="$(usm_url_flatten "$src")"
    SRC="$src" SUB="$sub" CONS="$cons" VER="$ver" REF="$ref" SHA="$sha" \
    HASH="$cachekey" RELPATH="$relpath" MAN="$manifest" REQ="${MOD_REQ[$idx]}" \
    yq -i '.modules += [(load(strenv(MAN)) | {
      "name": .name,
      "source": strenv(SRC),
      "subdir": strenv(SUB),
      "constraint": strenv(CONS),
      "version": strenv(VER),
      "ref": strenv(REF),
      "sha": strenv(SHA),
      "cache": strenv(HASH),
      "path": strenv(RELPATH),
      "requires": (strenv(REQ) | split(" ") | map(select(. != ""))),
      "shell": (.shell // []),
      "rc": (.rc // {})
    })]' "$tmp"
    oi=$((oi + 1))
  done
  mv "$tmp" "$lock"
}

# ---- driver ------------------------------------------------------------------

# Resolve the whole graph described by $cfg and write $lock in final load order.
# All working state is process-global (usm runs one command per process); reset it
# here so a re-entrant call starts clean. No lock is written unless every step passes.
_usm_resolve() {
  local cfg="$1" lock="$2"
  REPO_HASH=(); REPO_URL=(); REPO_BOUND=(); REPO_REF=(); REPO_VER=(); REPO_SHA=(); REPO_DIR=()
  MOD_KEY=(); MOD_HASH=(); MOD_SUB=(); MOD_SRC=(); MOD_NAME=(); MOD_REQ=(); MOD_REQKEYS=()
  Q_SRC=(); Q_SUB=(); Q_CONS=(); ORDER=()
  _usm_discover "$cfg"      || return 1
  _usm_resolve_repos        || return 1
  _usm_read_names           || return 1
  _usm_build_requires       || return 1
  _usm_toposort "$cfg"      || return 1
  _usm_write_lock "$lock"   || return 1
}
