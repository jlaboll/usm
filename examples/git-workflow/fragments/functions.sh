# git-workflow functions. POSIX-portable definitions — no bashisms, so the same
# fragment behaves identically under bash 3.2 and zsh.

# git_current_branch — print the current branch name, or nothing outside a repo.
# Other modules (e.g. psql) depend on this via `requires`.
git_current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null
}
