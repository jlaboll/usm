# Logging and user-interaction helpers. Output is minimal by default; a command's
# own output is silenced unless USM_VERBOSE=1. Diagnostics go to stderr so stdout
# stays clean for machine-readable results.

: "${USM_VERBOSE:=0}"

usm_log()  { printf '%s\n' "$*" >&2; }
usm_vlog() { [ "$USM_VERBOSE" = 1 ] && printf '%s\n' "$*" >&2; return 0; }
usm_warn() { printf 'warning: %s\n' "$*" >&2; }
usm_err()  { printf 'error: %s\n' "$*" >&2; }
usm_die()  { usm_err "$*"; exit 1; }

# Run a command, silencing its output unless verbose. Returns the command's code.
usm_run() {
  if [ "$USM_VERBOSE" = 1 ]; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

# Yes/no prompt on stderr; returns 0 for yes. Defaults to no when empty or when
# stdin is not a terminal (non-interactive runs never auto-approve).
usm_confirm() {
  local reply
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1" >&2
  read -r reply || return 1
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}
