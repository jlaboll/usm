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

usm_pkg_installed() { command -v "$1" >/dev/null 2>&1; }

# Print the commands from the argument list that are not on PATH (one per line).
usm_pkg_missing() {
  local c
  for c in "$@"; do usm_pkg_installed "$c" || printf '%s\n' "$c"; done
}

# Install one package via the active manager. yq is special-cased: mikefarah/yq
# ships via brew and snap but not apt (apt's yq is a different tool), so route it
# to whichever of brew/snap is available. Used ONLY by `usm init` after approval.
usm_pkg_install_one() {
  local pkg="$1" mgr; mgr="$(usm_pkg_manager)"
  if [ "$pkg" = yq ]; then
    if   command -v brew >/dev/null 2>&1; then usm_run brew install yq; return
    elif command -v snap >/dev/null 2>&1; then usm_run sudo snap install yq; return
    else usm_err "yq (mikefarah) installs via brew or snap; apt's yq is a different tool. Install it with 'snap install yq' or from https://github.com/mikefarah/yq/releases, then re-run 'usm init'"; return 1
    fi
  fi
  case "$mgr" in
    brew) usm_run brew install "$pkg" ;;
    apt)  usm_run sudo apt-get update && usm_run sudo apt-get install -y "$pkg" ;;
    snap) usm_run sudo snap install "$pkg" ;;
    *)    usm_err "no supported package manager to install '$pkg'"; return 1 ;;
  esac
}
