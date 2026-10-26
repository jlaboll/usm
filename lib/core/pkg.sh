# OS package-manager abstraction. usm installs OS packages ONLY during `usm init`,
# after explicit approval. Everywhere else it only detects and reports missing
# commands. Detection is by command name on PATH, which is what matters for shell
# config; modules that need a package whose command differs declare the command.

# brew | apt | snap | none
usm_pkg_manager() {
  [ -n "${_USM_PKGMGR:-}" ] && { printf '%s' "$_USM_PKGMGR"; return; }
  case "$(usm_os)" in
    darwin) _USM_PKGMGR=brew ;;
    linux)
      if   command -v apt-get >/dev/null 2>&1; then _USM_PKGMGR=apt
      elif command -v snap    >/dev/null 2>&1; then _USM_PKGMGR=snap
      else _USM_PKGMGR=none; fi ;;
    *) _USM_PKGMGR=none ;;
  esac
  printf '%s' "$_USM_PKGMGR"
}

# True when $1 is on PATH — and for yq, specifically mikefarah/yq v4 (apt's
# python-yq / kislyuk wrapper is a different, incompatible tool).
usm_pkg_installed() {
  command -v "$1" >/dev/null 2>&1 || return 1
  if [ "$1" = yq ]; then
    case "$(yq --version 2>&1)" in
      *mikefarah* | *"version v4"* | *"version 4."*) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

# Print the commands from the argument list that are not on PATH (one per line).
usm_pkg_missing() {
  local c
  for c in "$@"; do usm_pkg_installed "$c" || printf '%s\n' "$c"; done
}

# Download the standalone mikefarah/yq binary from GitHub releases into /usr/local/bin/yq.
_usm_install_yq_binary() {
  local os arch yq_arch url tmp
  os="$(usm_os)"; arch="$(usm_arch)"
  case "$os" in linux | darwin) ;; *) return 1 ;; esac
  case "$arch" in
    x86_64) yq_arch=amd64 ;;
    arm64)  yq_arch=arm64 ;;
    *)      return 1 ;;
  esac
  url="https://github.com/mikefarah/yq/releases/latest/download/yq_${os}_${yq_arch}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/yq.XXXXXX")" || return 1
  if command -v curl >/dev/null 2>&1; then
    usm_run curl -fsSL "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    usm_run wget -qO "$tmp" "$url" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; return 1
  fi
  chmod +x "$tmp" && usm_run sudo mv "$tmp" /usr/local/bin/yq || { rm -f "$tmp"; return 1; }
  hash -r 2>/dev/null || true
}

# Install one package via the active manager. yq is special-cased: mikefarah/yq
# ships via brew, snap, or standalone GitHub release binary (apt's yq is a
# different tool). Used ONLY by `usm init` after approval.
usm_pkg_install_one() {
  local pkg="$1" mgr; mgr="$(usm_pkg_manager)"
  if [ "$pkg" = yq ]; then
    if   command -v brew >/dev/null 2>&1 && usm_run brew install yq; then return 0
    elif command -v snap >/dev/null 2>&1 && usm_run sudo snap install yq; then return 0
    elif _usm_install_yq_binary; then return 0
    else
      usm_err "yq (mikefarah) installs via brew, snap, or GitHub release binary; apt's yq is a different tool. Install it from https://github.com/mikefarah/yq/releases, then re-run 'usm init'"
      return 1
    fi
  fi
  case "$mgr" in
    brew) usm_run brew install "$pkg" ;;
    apt)  usm_run sudo apt-get update && usm_run sudo apt-get install -y "$pkg" ;;
    snap) usm_run sudo snap install "$pkg" ;;
    *)    usm_err "no supported package manager to install '$pkg'"; return 1 ;;
  esac
}
