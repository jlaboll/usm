# Git and cache helpers. One clone per repo under $USM_DATA/cache/<hash>; a module
# is a subdir within it. All git output is silenced unless verbose (usm_run / -q).

# Stable short hash of a string (cache key). Uses sha1sum or shasum, whichever exists.
usm_hash() {
  printf '%s' "$1" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } | cut -d' ' -f1 | cut -c1-16
}

# Expand a host shorthand ("owner/repo") into a full https URL. Left unchanged: anything
# with a scheme (https://, git://, ssh://…), scp-like syntax (git@host:owner/repo), a
# local path (/…, ./…, ~/…, or a leading dot), an existing local directory of that name,
# or a value that isn't exactly two non-empty path segments. Host is $USM_GIT_HOST
# (default github.com), so `jlaboll/usm-core` -> `https://github.com/jlaboll/usm-core`.
# Expects an already-trimmed value (no trailing whitespace/slashes/.git).
usm_url_shorthand() {
  local url="$1"
  case "$url" in
    *://* | *@*:* | /* | .* | ~*) printf '%s' "$url"; return ;;  # URL / scp / local path
    */*/*)                        printf '%s' "$url"; return ;;  # more than two segments
    */*)                          : ;;                            # candidate: one slash
    *)                            printf '%s' "$url"; return ;;  # no slash -> not shorthand
  esac
  # A real local directory of that name wins over the shorthand interpretation.
  [ -d "$url" ] && { printf '%s' "$url"; return; }
  printf 'https://%s/%s' "${USM_GIT_HOST:-github.com}" "$url"
}

# Normalize a git URL: strip trailing whitespace, trailing slashes, and one trailing
# ".git", then expand any host shorthand ("owner/repo") to a full URL.
usm_url_normalize() {
  local url="$1"
  while case "$url" in *[[:space:]]) true ;; *) false ;; esac; do url="${url%?}"; done
  while [ "${url%/}" != "$url" ]; do url="${url%/}"; done
  url="${url%.git}"
  usm_url_shorthand "$url"
}

# Cache directory for a (already-normalized) URL. Pure: no side effects, no git output.
usm_cache_path() {
  printf '%s/%s' "$(usm_cache_dir)" "$(usm_hash "$1")"
}

# Ensure the repo for a normalized URL is cloned (else fetched). Returns non-zero on
# failure. Prints nothing to stdout (so callers can capture usm_cache_path separately).
# A missing repo is always cloned; the fetch of an already-cloned repo is skipped when
# USM_NO_FETCH=1 — `update` sets that after fetching only the repo(s) it means to touch,
# so a re-resolve stays surgical instead of pulling every repo forward.
usm_cache_sync() {
  local url="$1" dir
  dir="$(usm_cache_path "$url")"
  if [ -d "$dir/.git" ]; then
    [ "${USM_NO_FETCH:-0}" = 1 ] && return 0
    usm_run git -C "$dir" fetch --tags --prune origin || return 1
  else
    usm_run git clone "$url" "$dir" || return 1
  fi
}

# Fast-forward a clone's default branch to its origin remote-tracking ref. `git fetch`
# advances refs/remotes/origin/* but not the local branch the resolver checks out for a
# floating module, so `update` calls this after fetching to actually move floating HEADs.
# No-op (returns 0) if the branch or its remote ref is absent. usm owns these clones, so
# a hard reset is safe: they are never hand-edited.
usm_git_ff_default() {
  local dir="$1" db
  db="$(usm_git_default_branch "$dir")"
  [ -n "$db" ] || return 0
  git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$db" >/dev/null 2>&1 || return 0
  usm_run git -C "$dir" checkout -q "$db" || return 0
  usm_run git -C "$dir" reset --hard "origin/$db"
}

# Check out a ref (tag or branch) in a clone, quietly.
usm_git_checkout() {
  usm_run git -C "$1" checkout --quiet "$2"
}

# Full commit sha of HEAD (or a ref if given).
usm_git_head_sha() {
  git -C "$1" rev-parse "${2:-HEAD}" 2>/dev/null
}

# The repo's default branch name (main/master/...). Prefers origin/HEAD.
usm_git_default_branch() {
  local dir="$1" b c
  b="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  b="${b#origin/}"
  if [ -z "$b" ]; then
    for c in main master; do
      if git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$c" >/dev/null 2>&1; then b="$c"; break; fi
    done
  fi
  [ -z "$b" ] && b="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  printf '%s' "$b"
}

# List v* tags (one per line).
usm_git_tags() {
  git -C "$1" tag --list 'v*' 2>/dev/null
}
