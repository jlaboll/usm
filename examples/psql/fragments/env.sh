# psql shell environment. Sourced into interactive bash and zsh at shell startup.
export PSQL_PAGER='less -SXF'   # wide-table-friendly pager for query output

# pgdev — open psql against a per-branch dev database named myapp_<branch>.
# Relies on git_current_branch() from the git-workflow module (see `requires`);
# usm guarantees git-workflow loads first, so the function is defined by call time.
pgdev() {
  branch="$(git_current_branch)"
  psql "myapp_${branch:-main}"
}
