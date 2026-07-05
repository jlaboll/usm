# Canonical usm paths. USM_ROOT is exported by bin/usm. Config and state default
# to XDG dirs and are all overridable via the matching environment variables.

usm_config_dir()   { printf '%s' "${USM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/usm}"; }
usm_data_dir()     { printf '%s' "${USM_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/usm}"; }
usm_config_file()  { printf '%s/config.yaml' "$(usm_config_dir)"; }
usm_lock_file()    { printf '%s/lock.yaml' "$(usm_data_dir)"; }
usm_cache_dir()    { printf '%s/cache' "$(usm_data_dir)"; }
usm_compiled_dir() { printf '%s/compiled' "$(usm_data_dir)"; }
usm_rc_dir()       { printf '%s/rc' "$(usm_data_dir)"; }

# Create all state directories (idempotent).
usm_ensure_dirs() {
  mkdir -p "$(usm_config_dir)" "$(usm_cache_dir)" "$(usm_compiled_dir)" "$(usm_rc_dir)"
}
