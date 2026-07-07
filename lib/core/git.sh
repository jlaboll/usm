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

# Whether https://host/path and git@host:path address the SAME repo, so ssh<->https is a
# pure scheme swap (the GitHub family: github.com, GitHub Enterprise, GitLab, Gitea,
# Bitbucket Server, and self-hosted look-alikes). Returns non-zero for hosts whose ssh
# and https forms differ STRUCTURALLY in host AND path — Azure DevOps
# (https://dev.azure.com/org/proj/_git/repo vs git@ssh.dev.azure.com:v3/org/proj/repo),
# AWS CodeCommit, VSTS — which must never be mechanically converted or a wrong URL results.
# Detection is by host, plus the `_git` path segment as a belt-and-suspenders catch for a
# CNAME'd Azure DevOps https URL whose host we would not otherwise recognize.
_usm_url_scheme_swappable() {
  local host="$1" path="$2"
  case "$host" in
    dev.azure.com | ssh.dev.azure.com | *.visualstudio.com | vs-ssh.* | git-codecommit.*.amazonaws.com)
      return 1 ;;
  esac
  case "$path" in
    _git/* | */_git/*) return 1 ;;
  esac
  return 0
}

# Canonicalize equivalent remote git forms that address the SAME repo to one https
# identity, so a repo referenced as ssh (scp-style git@host:owner/repo, or ssh://…) or
# git:// dedupes with its https:// form instead of colliding as two sources declaring the
# same module name. Already-https/http/file URLs, local paths, and bare shorthands pass
# through untouched. This is IDENTITY only (cache key, config source, dedup) — the clone
# transport is chosen separately at clone time (usm_url_transports), so an ssh-first,
# https-fallback clone still records one stable https identity.
usm_url_canonicalize() {
  local url="$1" rest host path
  case "$url" in
    *://*) : ;;                                       # has a scheme; handled below
    *@*:*)                                            # scp-style [user@]host:owner/repo
      rest="${url#*@}"                                # drop leading user@
      host="${rest%%:*}"; path="${rest#*:}"
      if _usm_url_scheme_swappable "$host" "$path"; then
        printf 'https://%s/%s' "$host" "$path"        # GitHub-family: one https identity
      else
        printf '%s' "$url"                            # ADO/CodeCommit/etc: keep as-is
      fi
      return ;;
    *) printf '%s' "$url"; return ;;                  # local path / shorthand / bare
  esac
  case "$url" in
    ssh://*) rest="${url#ssh://}"; rest="${rest#*@}" ;;  # -> host[:port]/path
    git://*) rest="${url#git://}" ;;                     # -> host/path
    *)       printf '%s' "$url"; return ;;               # https/http/file: unchanged
  esac
  host="${rest%%/*}"; path="${rest#*/}"
  if _usm_url_scheme_swappable "$host" "$path"; then
    printf 'https://%s' "$rest"
  else
    printf '%s' "$url"
  fi
}

# Normalize a git URL: strip trailing whitespace, trailing slashes, and one trailing
# ".git", canonicalize equivalent ssh/git forms to a single https identity (so the same
# repo addressed two ways dedupes), then expand any host shorthand ("owner/repo").
usm_url_normalize() {
  local url="$1"
  while case "$url" in *[[:space:]]) true ;; *) false ;; esac; do url="${url%?}"; done
  while [ "${url%/}" != "$url" ]; do url="${url%/}"; done
  url="${url%.git}"
  url="$(usm_url_canonicalize "$url")"
  usm_url_shorthand "$url"
}

# Print the ordered clone transports to try for a normalized identity, one per line. For a
# GitHub-family https identity (where https://host/path and git@host:path address the same
# repo) emit the ssh form FIRST, then https — so a machine with ssh keys clones a private
# repo without an https token, and one with only an https credential still succeeds on the
# fallback. USM_GIT_TRANSPORT forces a single transport: `ssh` or `https` (default: both,
# ssh first). Any identity we cannot safely convert (Azure DevOps, CodeCommit, an already-
# non-swappable ssh URL, local paths, file://) yields exactly itself — usm never fabricates
# a counterpart it can't derive correctly; pass an explicit ssh/https URL for those.
usm_url_transports() {
  local id="$1" order="${USM_GIT_TRANSPORT:-auto}" rest host path ssh
  case "$id" in
    https://*)
      rest="${id#https://}"; host="${rest%%/*}"; path="${rest#*/}"
      if [ "$path" != "$rest" ] && _usm_url_scheme_swappable "$host" "$path"; then
        ssh="git@$host:$path"
        case "$order" in
          ssh)   printf '%s\n' "$ssh" ;;
          https) printf '%s\n' "$id" ;;
          *)     printf '%s\n%s\n' "$ssh" "$id" ;;
        esac
        return
      fi ;;
  esac
  printf '%s\n' "$id"
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
    return 0
  fi
  _usm_clone "$url" "$dir"
}

# Clone the repo for normalized identity $id into $dir, trying each candidate transport
# (usm_url_transports) in order. Non-final candidates fail FAST and SILENTLY — no auth
# prompts, bounded ssh connect — so a dead transport (e.g. no ssh key) falls through to
# the next instead of hanging. If every probe fails and stdin is a terminal, the LAST
# candidate is retried ATTACHED so the user can authenticate (enter an https token, unlock
# an ssh key, accept a host key) and see git's real error. On total failure, print
# actionable guidance and return non-zero.
_usm_clone() {
  local id="$1" dir="$2" t tried="" i=0 n
  local cands=()
  while IFS= read -r t; do [ -n "$t" ] && cands+=("$t"); done <<EOF
$(usm_url_transports "$id")
EOF
  n=${#cands[@]}
  [ "$n" -gt 0 ] || { usm_err "no clone transport for $id"; return 1; }
  while [ "$i" -lt "$n" ]; do
    t="${cands[$i]}"; tried="$tried $t"
    [ -e "$dir" ] && rm -rf "$dir"
    if usm_run env GIT_TERMINAL_PROMPT=0 \
         GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new' \
         git clone "$t" "$dir"; then
      return 0
    fi
    usm_vlog "clone via $t failed"
    i=$((i + 1))
  done
  # Every fast probe failed. Retry the last candidate interactively (if we have a tty) so
  # credentials / host-key can be entered and git's real error is shown, not swallowed.
  t="${cands[$((n - 1))]}"
  if [ -t 0 ]; then
    [ -e "$dir" ] && rm -rf "$dir"
    usm_vlog "retrying $t interactively"
    git clone "$t" "$dir" && return 0
  fi
  usm_warn "could not clone $id (tried:$tried )"
  usm_warn "if it is private, check your git credentials (ssh key/agent, or an https token),"
  usm_warn "or pass an explicit https/ssh URL. Set USM_GIT_TRANSPORT=ssh|https to force one."
  return 1
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
