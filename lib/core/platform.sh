# OS, architecture, and distro detection. Results are memoized in the current
# process. All functions print their result to stdout.

# darwin | linux | unknown
usm_os() {
  [ -n "${_USM_OS:-}" ] && { printf '%s' "$_USM_OS"; return; }
  case "$(uname -s)" in
    Darwin) _USM_OS=darwin ;;
    Linux)  _USM_OS=linux ;;
    *)      _USM_OS=unknown ;;
  esac
  printf '%s' "$_USM_OS"
}

# arm64 | x86_64 | <raw uname -m>
usm_arch() {
  [ -n "${_USM_ARCH:-}" ] && { printf '%s' "$_USM_ARCH"; return; }
  case "$(uname -m)" in
    arm64 | aarch64) _USM_ARCH=arm64 ;;
    x86_64 | amd64)  _USM_ARCH=x86_64 ;;
    *)               _USM_ARCH="$(uname -m)" ;;
  esac
  printf '%s' "$_USM_ARCH"
}

# Linux distro id (e.g. debian, ubuntu) from /etc/os-release; empty elsewhere.
usm_distro() {
  [ -n "${_USM_DISTRO+x}" ] && { printf '%s' "$_USM_DISTRO"; return; }
  _USM_DISTRO=""
  [ -r /etc/os-release ] && _USM_DISTRO="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
  printf '%s' "$_USM_DISTRO"
}

# Homebrew prefix for this arch: /opt/homebrew (Apple Silicon) or /usr/local (Intel).
usm_brew_prefix() {
  [ -n "${HOMEBREW_PREFIX:-}" ] && { printf '%s' "$HOMEBREW_PREFIX"; return; }
  command -v brew >/dev/null 2>&1 && { brew --prefix; return; }
  case "$(usm_arch)" in
    arm64) printf '/opt/homebrew' ;;
    *)     printf '/usr/local' ;;
  esac
}
