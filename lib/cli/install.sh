# usm install <url> [--subdir X] [--version 'C'] — fetch a module's repo into the
# cache, register it in config.yaml (idempotent), then resolve + compile. Detects and
# WARNS about missing OS packages the module declares, but never installs them.

cmd_install() {
  local url="" subdir="" version=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --subdir)    subdir="${2:-}"; shift 2 ;;
      --subdir=*)  subdir="${1#--subdir=}"; shift ;;
      --version)   version="${2:-}"; shift 2 ;;
      --version=*) version="${1#--version=}"; shift ;;
      -*)          usm_die "unknown option: $1" ;;
      *)           [ -z "$url" ] && url="$1" || usm_die "unexpected argument: $1"; shift ;;
    esac
  done
  [ -n "$url" ] || usm_die "usage: usm install <url> [--subdir X] [--version 'C']"

  usm_ensure_dirs
  local cfg; cfg="$(usm_config_file)"
  [ -f "$cfg" ] || usm_die "no config.yaml; run 'usm init' first"

  local nurl; nurl="$(usm_url_normalize "$url")"
  usm_vlog "fetching $nurl"
  usm_cache_sync "$nurl" || usm_die "failed to fetch $nurl"

  # Validate the manifest at HEAD before touching config (resolution/checkout happens
  # in compile; here we just confirm the subdir holds a usm.yaml with a name).
  local dir mdir manifest name
  dir="$(usm_cache_path "$nurl")"
  mdir="$dir"; [ -n "$subdir" ] && mdir="$dir/$subdir"
  manifest="$mdir/usm.yaml"
  [ -f "$manifest" ] || usm_die "no usm.yaml at '${subdir:-<root>}' in $nurl"
  name="$(usm_yaml_get "$manifest" '.name')"
  [ -n "$name" ] || usm_die "manifest at '${subdir:-<root>}' has no 'name'"

  _usm_install_pkg_warn "$manifest"

  # Mutate config, then compile. If compile fails, restore config so a bad constraint
  # never leaves config.yaml and lock.yaml inconsistent.
  local backup="$cfg.usm-install.$$"
  cp "$cfg" "$backup"
  _usm_config_upsert_module "$cfg" "$nurl" "$subdir" "$version"
  if ! usm_compile; then
    mv "$backup" "$cfg"
    usm_die "compile failed; config.yaml left unchanged"
  fi
  rm -f "$backup"
  usm_log "installed $name"
}

# Warn (only) about missing commands the manifest declares as packages. Detection is by
# COMMAND NAME on PATH, not by manager, so we check the UNION of names declared under
# brew/apt/snap (deduped) — a command declared only under a non-active manager (e.g.
# packages.snap on a brew host) is still worth warning about. Never installs anything.
_usm_install_pkg_warn() {
  local manifest="$1" mgr pkgs missing
  mgr="$(usm_pkg_manager)"
  [ "$mgr" = none ] && return 0
  pkgs="$(
    { usm_yaml_seq "$manifest" ".packages.brew"
      usm_yaml_seq "$manifest" ".packages.apt"
      usm_yaml_seq "$manifest" ".packages.snap"
    } | awk 'NF && !seen[$0]++'
  )"
  [ -n "$pkgs" ] || return 0
  missing="$(usm_pkg_missing $pkgs)"
  [ -n "$missing" ] && usm_warn "module needs missing command(s): $(printf '%s ' $missing)— install them yourself; usm won't."
  return 0
}

# Upsert a module entry (matched by source+subdir) into config.modules, preserving
# position on update. Empty subdir/version keys are omitted.
_usm_config_upsert_module() {
  local cfg="$1" src="$2" subdir="$3" version="$4" exists
  exists="$(SRC="$src" SUB="$subdir" yq '[.modules[]? | select((.source==strenv(SRC)) and ((.subdir // "")==strenv(SUB)))] | length' "$cfg")"
  if [ "${exists:-0}" -gt 0 ]; then
    SRC="$src" SUB="$subdir" VER="$version" yq -i '
      (.modules[] | select((.source==strenv(SRC)) and ((.subdir // "")==strenv(SUB)))) |=
        ({"source": strenv(SRC), "subdir": strenv(SUB), "version": strenv(VER)} | del(.[] | select(. == "")))' "$cfg"
  else
    SRC="$src" SUB="$subdir" VER="$version" yq -i '
      .modules += [ ({"source": strenv(SRC), "subdir": strenv(SUB), "version": strenv(VER)} | del(.[] | select(. == ""))) ]' "$cfg"
  fi
}
