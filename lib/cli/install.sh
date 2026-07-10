# usm install <url> [--subdir X] [--version 'C'] — fetch a module's repo into the
# cache, register it in config.yaml (idempotent), then resolve + compile. Detects and
# WARNS about missing OS packages the module declares, but never installs them.
#
# <url> may be a shorthand ("owner/repo" -> https://github.com/owner/repo; see
# usm_url_normalize). When no --subdir is given and the repo's root usm.yaml declares a
# `modules:` list (a monorepo of member subdirs), every listed member is installed and
# the repo-wide --version applies to all of them; the repo is also recorded as a followed
# monorepo so `usm update` auto-installs members added upstream later. --subdir still
# cherry-picks one member (and does NOT follow the monorepo).

cmd_install() {
  local url="" subdir="" version="" subdir_set=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --subdir)    subdir="${2:-}"; subdir_set=1; shift 2 ;;
      --subdir=*)  subdir="${1#--subdir=}"; subdir_set=1; shift ;;
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

  local dir; dir="$(usm_cache_path "$nurl")"

  # Decide which subdir(s) to install. With no --subdir, a root usm.yaml that declares a
  # non-empty `modules:` list marks a monorepo — install every member. Otherwise install
  # the single module at --subdir (or the repo root when omitted).
  local targets=() monorepo=0 s
  if [ "$subdir_set" = 0 ] && [ -f "$dir/usm.yaml" ]; then
    while IFS= read -r s; do [ -n "$s" ] && targets+=("$s"); done <<EOF
$(usm_yaml_seq "$dir/usm.yaml" '.modules')
EOF
  fi
  if [ "${#targets[@]}" -gt 0 ]; then
    monorepo=1
  else
    targets=("$subdir")   # single module; "" = repo root
  fi

  # Validate every target manifest at HEAD before touching config (resolution/checkout
  # happens in compile; here we just confirm each subdir holds a usm.yaml with a name).
  local t mdir manifest name
  for t in "${targets[@]}"; do
    mdir="$dir"; [ -n "$t" ] && mdir="$dir/$t"
    manifest="$mdir/usm.yaml"
    [ -f "$manifest" ] || usm_die "no usm.yaml at '${t:-<root>}' in $nurl"
    name="$(usm_yaml_get "$manifest" '.name')"
    [ -n "$name" ] || usm_die "manifest at '${t:-<root>}' has no 'name'"
    _usm_install_pkg_warn "$manifest"
  done

  # Mutate config (all targets), then compile. If compile fails, restore config so a bad
  # constraint never leaves config.yaml and lock.yaml inconsistent.
  local backup="$cfg.usm-install.$$"
  cp "$cfg" "$backup"
  for t in "${targets[@]}"; do
    _usm_config_upsert_module "$cfg" "$nurl" "$t" "$version"
  done
  # Whole-repo install: follow this monorepo so `usm update` auto-installs members added
  # upstream later. A --subdir cherry-pick is NOT followed (only that one member is wanted).
  [ "$monorepo" = 1 ] && _usm_config_add_monorepo "$cfg" "$nurl"
  if ! usm_compile; then
    mv "$backup" "$cfg"
    usm_die "compile failed; config.yaml left unchanged"
  fi
  rm -f "$backup"
  if [ "$monorepo" = 1 ]; then
    usm_log "installed ${#targets[@]} modules from $nurl"
  else
    usm_log "installed $name"
  fi
}
