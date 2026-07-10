# Module + config helpers shared by the `install` and `update` commands. These live in
# core (always sourced) rather than in a single lib/cli/*.sh because CLI files are
# dispatched one at a time — `update` cannot see functions defined only in `install`.

# Warn (only) about missing commands a manifest declares as packages. Detection is by
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

# Record a source as a followed monorepo — installed whole (no --subdir), so `usm update`
# should auto-install members added to it upstream later. Stored as a unique top-level
# `monorepos:` list of normalized source URLs. Idempotent.
_usm_config_add_monorepo() {
  local cfg="$1" src="$2" have
  have="$(SRC="$src" yq '[.monorepos[]? | select(. == strenv(SRC))] | length' "$cfg")"
  [ "${have:-0}" -gt 0 ] && return 0
  SRC="$src" yq -i '.monorepos = ((.monorepos // []) + [strenv(SRC)])' "$cfg"
}

# Auto-install monorepo members added upstream. For a followed monorepo `src` (recorded by
# a whole-repo install), read the CURRENT member list from its cached root usm.yaml and
# upsert any members not already in config. New members inherit the repo-wide version
# constraint shared by existing members (first non-empty). Each new member's manifest is
# validated (a usm.yaml with a name) and its missing-package warning emitted, mirroring
# `usm install`; a listed-but-broken member is skipped with a warning rather than aborting
# the whole update. No-op unless `src` is actually a followed monorepo and its repo is
# cached and checked out at the ref whose root usm.yaml lists members (update fetches and
# fast-forwards the default branch before calling this).
_usm_monorepo_expand() {
  local cfg="$1" src="$2" dir ver s mdir manifest name
  [ "$(SRC="$src" yq '[.monorepos[]? | select(. == strenv(SRC))] | length' "$cfg")" -gt 0 ] || return 0
  dir="$(usm_cache_path "$src")"
  [ -f "$dir/usm.yaml" ] || return 0
  ver="$(SRC="$src" yq '[.modules[]? | select(.source==strenv(SRC)) | .version // ""] | map(select(. != "")) | .[0] // ""' "$cfg")"
  [ "$ver" = null ] && ver=""
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    [ "$(SRC="$src" SUB="$s" yq '[.modules[]? | select((.source==strenv(SRC)) and ((.subdir // "")==strenv(SUB)))] | length' "$cfg")" -gt 0 ] && continue
    mdir="$dir/$s"; manifest="$mdir/usm.yaml"
    if [ ! -f "$manifest" ]; then usm_warn "monorepo $src lists '$s' but it has no usm.yaml; skipping"; continue; fi
    name="$(usm_yaml_get "$manifest" '.name')"
    [ -n "$name" ] || { usm_warn "monorepo member '$s' in $src has no 'name'; skipping"; continue; }
    _usm_install_pkg_warn "$manifest"
    _usm_config_upsert_module "$cfg" "$src" "$s" "$ver"
    usm_log "monorepo $src: new member '$name' ($s) — installing"
  done <<EOF
$(usm_yaml_seq "$dir/usm.yaml" '.modules')
EOF
  return 0
}
