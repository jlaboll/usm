# usm init — bootstrap usm into this machine: install the base's required tools
# (with approval), create state dirs, seed config, and wire the loader into the
# managed shells. Safe to re-run.

cmd_init() {
  usm_vlog "platform: $(usm_os)/$(usm_arch)  manager: $(usm_pkg_manager)"

  _usm_init_packages
  usm_pkg_installed yq || usm_die "yq (mikefarah) is required; re-run and approve installation, or install it via brew or snap ('snap install yq') or from https://github.com/mikefarah/yq/releases (apt's yq is a different tool), then re-run 'usm init'"

  usm_ensure_dirs
  _usm_init_config
  _usm_init_shell_rc

  usm_log "usm initialized. Open a new shell, or source your shell rc, to load it."
}

# Offer to install the base's required commands — only those missing, only on
# approval. The needs list is hardcoded (not read from usm.yaml) because parsing
# the manifest would itself require yq, which may be one of the missing tools.
_usm_init_packages() {
  [ "$(usm_pkg_manager)" = none ] && { usm_warn "no supported package manager; skipping package check"; return 0; }

  local needs="git yq" missing c
  missing="$(usm_pkg_missing $needs)"
  [ -z "$missing" ] && { usm_vlog "base commands present"; return 0; }

  usm_log "usm needs: $(printf '%s ' $missing)"
  if usm_confirm "Install now via $(usm_pkg_manager)/brew/snap?"; then
    for c in $missing; do
      usm_pkg_install_one "$c" || usm_die "could not install '$c'"
    done
  else
    usm_warn "skipped install; usm needs: $missing"
  fi
}

# Seed config.yaml (only if absent) with the shells detected on this machine.
_usm_init_config() {
  local cfg; cfg="$(usm_config_file)"
  [ -f "$cfg" ] && { usm_vlog "config exists: $cfg"; return 0; }

  local shells; shells="$(_usm_detect_shells)"
  cat >"$cfg" <<EOF
# usm device configuration. Manage with 'usm install', 'usm order', or by hand.
shells: [$shells]
rc_files: []
modules: []
overrides: {}
EOF
  usm_vlog "wrote $cfg"
}

# Comma-joined list of interactive shells present on this machine.
_usm_detect_shells() {
  local list="" s
  for s in bash zsh; do
    command -v "$s" >/dev/null 2>&1 && list="${list:+$list, }$s"
  done
  printf '%s' "$list"
}

# Wire the usm loader into each managed shell's rc (idempotent, guarded block).
_usm_init_shell_rc() {
  local loader="$USM_ROOT/lib/loader.sh" cfg shell
  cfg="$(usm_config_file)"
  while IFS= read -r shell; do
    [ -z "$shell" ] && continue
    case "$shell" in
      bash)
        _usm_link_rc "$HOME/.bashrc" "$loader"
        # On macOS a login bash shell reads .bash_profile, not .bashrc.
        _usm_ensure_sources "$HOME/.bash_profile" "$HOME/.bashrc" ;;
      zsh)
        _usm_link_rc "$HOME/.zshrc" "$loader" ;;
      *)
        usm_warn "unknown shell '$shell' in config; skipping" ;;
    esac
  done <<EOF
$(usm_yaml_seq "$cfg" ".shells")
EOF
}

# Append a guarded block to $1 that sources the usm loader $2 (idempotent).
_usm_link_rc() {
  local rc="$1" loader="$2" begin="# >>> usm >>>"
  if [ -f "$rc" ] && grep -qF "$begin" "$rc"; then
    usm_vlog "usm block already present in $rc"
    return 0
  fi
  {
    printf '\n%s\n' "$begin"
    printf '# Load modular shell configuration managed by usm.\n'
    printf '[ -r "%s" ] && . "%s"\n' "$loader" "$loader"
    printf '# <<< usm <<<\n'
  } >>"$rc"
  usm_vlog "added usm block to $rc"
}

# Ensure file $1 sources file $2 (idempotent, guarded).
_usm_ensure_sources() {
  local target="$1" src="$2" begin="# >>> usm-source >>>"
  if [ -f "$target" ] && grep -qF "$begin" "$target"; then
    return 0
  fi
  {
    printf '\n%s\n' "$begin"
    printf '[ -r "%s" ] && . "%s"\n' "$src" "$src"
    printf '# <<< usm-source <<<\n'
  } >>"$target"
  usm_vlog "ensured $target sources $src"
}
