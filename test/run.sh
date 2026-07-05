#!/usr/bin/env bash
# Plain-bash test runner (no bats). Builds local fixture git repos, drives bin/usm in
# a fully sandboxed HOME/USM_CONFIG/USM_DATA, and asserts real behavior — resolved
# lock fields, emitted load order, assembled rc contents, symlinks, and removal.
#
# Never touches the real $HOME. Run: bash test/run.sh
set -u

USM_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USM_BIN="$USM_ROOT/bin/usm"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
grep_ok() { if grep -qF "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (missing [$2] in $3)"; fi; }
grep_no() { if grep -qF "$2" "$3" 2>/dev/null; then bad "$1 (unexpected [$2] in $3)"; else ok "$1"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/usm-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Sandbox — the whole point: no real dotfiles are ever touched.
export HOME="$TMP/home"; mkdir -p "$HOME"
export USM_CONFIG="$TMP/cfg"
export USM_DATA="$TMP/data"
export USM_VERBOSE=0
# Deterministic git identity/branch for fixtures.
export GIT_AUTHOR_NAME=usm GIT_AUTHOR_EMAIL=usm@test
export GIT_COMMITTER_NAME=usm GIT_COMMITTER_EMAIL=usm@test

usm() { "$USM_BIN" "$@"; }

# ---- Build a fixture repo with two module subdirs, committed and tagged v1.0.0 ----
REPO="$TMP/modrepo"
mkdir -p "$REPO/git-workflow/fragments" "$REPO/psql/fragments" "$REPO/psql/rc"

cat >"$REPO/git-workflow/usm.yaml" <<'EOF'
name: git-workflow
version: 1.0.0
description: Git aliases
shell:
  - fragments/aliases.sh
packages:
  brew: [git]
EOF
cat >"$REPO/git-workflow/fragments/aliases.sh" <<'EOF'
alias gs='git status'
EOF

cat >"$REPO/psql/usm.yaml" <<'EOF'
name: psql
version: 1.0.0
description: psql config
shell:
  - fragments/env.sh
rc:
  psqlrc:
    - rc/psqlrc.fragment
packages:
  brew: [postgresql]
EOF
cat >"$REPO/psql/fragments/env.sh" <<'EOF'
export PSQL_PAGER=less
EOF
cat >"$REPO/psql/rc/psqlrc.fragment" <<'EOF'
\set QUIET 1
\pset null '[null]'
EOF

git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "v1"
git -C "$REPO" tag v1.0.0
DEFBRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
TAG_SHA="$(git -C "$REPO" rev-parse v1.0.0^{commit})"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

LOCK="$USM_DATA/lock.yaml"
CFG="$USM_CONFIG/config.yaml"
LOAD="$USM_DATA/compiled/load.sh"

printf '== init ==\n'
usm init >/dev/null 2>&1
check "config.yaml created" "$( [ -f "$CFG" ] && echo yes )" yes
check "empty load.sh compiled? (not yet)" "$( [ -f "$LOAD" ] && echo yes || echo no )" no

printf '== install git-workflow (versioned) ==\n'
usm install "$REPO" --subdir git-workflow --version '>=1.0.0' >/dev/null 2>&1
check "config has git-workflow source" \
  "$(SRC="$REPO" SUB=git-workflow yq '[.modules[] | select(.source==strenv(SRC) and .subdir==strenv(SUB))] | length' "$CFG")" 1
check "lock git-workflow name"    "$(yq '.modules[0].name' "$LOCK")" git-workflow
check "lock git-workflow version" "$(yq '.modules[0].version' "$LOCK")" 1.0.0
check "lock git-workflow ref"     "$(yq '.modules[0].ref' "$LOCK")" v1.0.0
check "lock git-workflow sha"     "$(yq '.modules[0].sha' "$LOCK")" "$TAG_SHA"
check "lock git-workflow subdir"  "$(yq '.modules[0].subdir' "$LOCK")" git-workflow
EXP_HASH="$(printf '%s' "$REPO" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } | cut -d' ' -f1 | cut -c1-16)"
check "lock cache hash"           "$(yq '.modules[0].cache' "$LOCK")" "$EXP_HASH"
check "lock path"                 "$(yq '.modules[0].path' "$LOCK")" "$EXP_HASH/git-workflow"
check "lock requires empty"       "$(yq '.modules[0].requires | length' "$LOCK")" 0

printf '== install psql (shares git-workflow repo -> repo-granular ref) ==\n'
# psql is installed with NO version, but it lives in the SAME repo as git-workflow,
# whose >=1.0.0 constraint pins the whole repo. Resolution is repo-granular (spec:
# "All subdir-modules of that repo use that one ref"), so psql shares ref v1.0.0 —
# it does NOT float independently. (True floating is exercised by fp_* fixtures below.)
usm install "$REPO" --subdir psql >/dev/null 2>&1
check "two modules in lock"        "$(yq '.modules | length' "$LOCK")" 2
check "lock psql name"             "$(yq '.modules[1].name' "$LOCK")" psql
check "psql shares repo version"   "$(yq '.modules[1].version' "$LOCK")" 1.0.0
check "psql shares repo ref"       "$(yq '.modules[1].ref' "$LOCK")" v1.0.0
check "psql shares repo sha"       "$(yq '.modules[1].sha' "$LOCK")" "$TAG_SHA"

printf '== compiled/load.sh order + absolute paths ==\n'
CACHE="$USM_DATA/cache"
grep_ok "load sources git-workflow aliases" "$CACHE/$EXP_HASH/git-workflow/fragments/aliases.sh" "$LOAD"
grep_ok "load sources psql env"             "$CACHE/$EXP_HASH/psql/fragments/env.sh" "$LOAD"
# git-workflow was installed first, so it must be sourced before psql
GW_LINE="$(grep -n 'git-workflow/fragments/aliases.sh' "$LOAD" | cut -d: -f1)"
PS_LINE="$(grep -n 'psql/fragments/env.sh' "$LOAD" | cut -d: -f1)"
check "load order: git-workflow before psql" "$( [ "$GW_LINE" -lt "$PS_LINE" ] && echo yes || echo no )" yes

printf '== rc assembly + symlink ==\n'
check "config.rc_files derived = [psqlrc]" "$(yq -o=json -I=0 '.rc_files' "$CFG")" '["psqlrc"]'
RCFILE="$USM_DATA/rc/psqlrc"
grep_ok "psqlrc has fragment content" "\pset null '[null]'" "$RCFILE"
grep_ok "psqlrc header comment"       "generated by usm" "$RCFILE"
check "~/.psqlrc is a symlink"        "$( [ -L "$HOME/.psqlrc" ] && echo yes )" yes
check "~/.psqlrc -> staged rc"        "$(readlink "$HOME/.psqlrc")" "$RCFILE"

printf '== psqlrc backup rule ==\n'
# Fresh sandbox test: a pre-existing real ~/.psqlrc gets backed up once.
rm -f "$HOME/.psqlrc"
printf 'pre-existing user file\n' >"$HOME/.psqlrc"
usm compile >/dev/null 2>&1
check "pre-existing file backed up" "$( [ -f "$HOME/.psqlrc.usm-backup" ] && echo yes )" yes
grep_ok "backup keeps user content" "pre-existing user file" "$HOME/.psqlrc.usm-backup"
check "~/.psqlrc now our symlink"   "$(readlink "$HOME/.psqlrc")" "$RCFILE"

printf '== list ==\n'
LIST_OUT="$(usm list 2>/dev/null)"
check "list shows git-workflow" "$(printf '%s\n' "$LIST_OUT" | grep -c git-workflow)" 1
check "list shows psql"         "$(printf '%s\n' "$LIST_OUT" | grep -c '^psql')" 1

printf '== idempotent re-install (update version in place) ==\n'
usm install "$REPO" --subdir git-workflow --version '>=1.0.0' >/dev/null 2>&1
check "still two modules after re-install" "$(yq '.modules | length' "$LOCK")" 2
check "git-workflow still first"           "$(yq '.modules[0].name' "$LOCK")" git-workflow

printf '== remove psql reverses everything ==\n'
usm remove psql >/dev/null 2>&1
check "one module left"            "$(yq '.modules | length' "$LOCK")" 1
check "remaining is git-workflow"  "$(yq '.modules[0].name' "$LOCK")" git-workflow
grep_no "load no longer has psql"  "psql/fragments/env.sh" "$LOAD"
check "config.rc_files now empty"  "$(yq -o=json -I=0 '.rc_files' "$CFG")" '[]'
check "~/.psqlrc symlink removed"  "$( [ -L "$HOME/.psqlrc" ] && echo yes || echo no )" no
check "backup restored to ~/.psqlrc" "$( [ -f "$HOME/.psqlrc" ] && echo yes )" yes
grep_ok "restored content"         "pre-existing user file" "$HOME/.psqlrc"
# cache clone is still referenced by git-workflow -> must NOT be pruned
check "cache clone still present"  "$( [ -d "$CACHE/$EXP_HASH" ] && echo yes )" yes

printf '== remove last module prunes cache ==\n'
usm remove git-workflow >/dev/null 2>&1
check "no modules left"            "$(yq '.modules | length' "$LOCK")" 0
check "cache clone pruned"         "$( [ -d "$CACHE/$EXP_HASH" ] && echo yes || echo no )" no
grep_no "load empty of fragments"  "fragments/" "$LOAD"

################################################################################
# Phase 3 — dependency resolution. Config is empty here (Phase 2 removed all).
################################################################################

printf '== (a) dep auto-install + order (dep before dependent) ==\n'
LIBREPO="$TMP/librepo"; APPREPO="$TMP/apprepo"
mkdir -p "$LIBREPO/libcore/fragments" "$APPREPO/webapp/fragments"
cat >"$LIBREPO/libcore/usm.yaml" <<'EOF'
name: libcore
version: 1.0.0
shell:
  - fragments/lib.sh
EOF
printf 'export LIBCORE=1\n' >"$LIBREPO/libcore/fragments/lib.sh"
git -C "$LIBREPO" init -q; git -C "$LIBREPO" symbolic-ref HEAD refs/heads/main
git -C "$LIBREPO" add -A; git -C "$LIBREPO" commit -q -m v1; git -C "$LIBREPO" tag v1.0.0
cat >"$APPREPO/webapp/usm.yaml" <<EOF
name: webapp
version: 1.0.0
shell:
  - fragments/app.sh
requires:
  - source: $LIBREPO
    subdir: libcore
    version: ">=1.0.0"
EOF
printf 'export WEBAPP=1\n' >"$APPREPO/webapp/fragments/app.sh"
git -C "$APPREPO" init -q; git -C "$APPREPO" symbolic-ref HEAD refs/heads/main
git -C "$APPREPO" add -A; git -C "$APPREPO" commit -q -m v1; git -C "$APPREPO" tag v1.0.0
# Install only webapp; its manifest's `requires` must pull libcore in automatically.
usm install "$APPREPO" --subdir webapp --version '>=1.0.0' >/dev/null 2>&1
check "dep libcore auto-installed"  "$(NM=libcore yq '[.modules[]|select(.name==strenv(NM))]|length' "$LOCK")" 1
check "libcore NOT in config"       "$(SUB=libcore yq '[.modules[]|select((.subdir // "")==strenv(SUB))]|length' "$CFG")" 0
check "webapp requires libcore"     "$(NM=webapp yq '.modules[]|select(.name==strenv(NM))|.requires|join(",")' "$LOCK")" libcore
LIB_LINE="$(grep -n 'libcore/fragments/lib.sh' "$LOAD" | cut -d: -f1)"
APP_LINE="$(grep -n 'webapp/fragments/app.sh' "$LOAD" | cut -d: -f1)"
check "load order: libcore before webapp" "$( [ -n "$LIB_LINE" ] && [ "$LIB_LINE" -lt "$APP_LINE" ] && echo yes || echo no )" yes

printf '== (b) shared repo, two lower bounds -> one highest-tag ref ==\n'
MULTI="$TMP/multirepo"
mkdir -p "$MULTI/modx/fragments" "$MULTI/mody/fragments"
cat >"$MULTI/modx/usm.yaml" <<'EOF'
name: modx
version: 0.0.0
shell:
  - fragments/x.sh
EOF
printf 'export MODX=1\n' >"$MULTI/modx/fragments/x.sh"
cat >"$MULTI/mody/usm.yaml" <<'EOF'
name: mody
version: 0.0.0
shell:
  - fragments/y.sh
EOF
printf 'export MODY=1\n' >"$MULTI/mody/fragments/y.sh"
git -C "$MULTI" init -q; git -C "$MULTI" symbolic-ref HEAD refs/heads/main
git -C "$MULTI" add -A; git -C "$MULTI" commit -q -m v1; git -C "$MULTI" tag v1.0.0
git -C "$MULTI" commit -q --allow-empty -m v11; git -C "$MULTI" tag v1.1.0
git -C "$MULTI" commit -q --allow-empty -m v12; git -C "$MULTI" tag v1.2.0
V12_SHA="$(git -C "$MULTI" rev-parse v1.2.0^{commit})"
usm install "$MULTI" --subdir modx --version '>=1.0.0' >/dev/null 2>&1
usm install "$MULTI" --subdir mody --version '>=1.2.0' >/dev/null 2>&1
check "modx shares max ref v1.2.0"  "$(NM=modx yq '.modules[]|select(.name==strenv(NM))|.ref' "$LOCK")" v1.2.0
check "mody shares max ref v1.2.0"  "$(NM=mody yq '.modules[]|select(.name==strenv(NM))|.ref' "$LOCK")" v1.2.0
check "modx version = 1.2.0"        "$(NM=modx yq '.modules[]|select(.name==strenv(NM))|.version' "$LOCK")" 1.2.0
check "shared sha = v1.2.0 commit"  "$(NM=modx yq '.modules[]|select(.name==strenv(NM))|.sha' "$LOCK")" "$V12_SHA"
check "merged constraint recorded"  "$(NM=modx yq '.modules[]|select(.name==strenv(NM))|.constraint' "$LOCK")" '>=1.2.0'

printf '== (c) overrides before/after reorders ==\n'
OVR="$TMP/ovrrepo"
mkdir -p "$OVR/c1/fragments" "$OVR/c2/fragments"
printf 'name: c1\nversion: 0.0.0\nshell:\n  - fragments/c1.sh\n' >"$OVR/c1/usm.yaml"
printf 'export C1=1\n' >"$OVR/c1/fragments/c1.sh"
printf 'name: c2\nversion: 0.0.0\nshell:\n  - fragments/c2.sh\n' >"$OVR/c2/usm.yaml"
printf 'export C2=1\n' >"$OVR/c2/fragments/c2.sh"
git -C "$OVR" init -q; git -C "$OVR" symbolic-ref HEAD refs/heads/main
git -C "$OVR" add -A; git -C "$OVR" commit -q -m v1
usm install "$OVR" --subdir c1 >/dev/null 2>&1
usm install "$OVR" --subdir c2 >/dev/null 2>&1
C1_LINE="$(grep -n 'c1/fragments/c1.sh' "$LOAD" | cut -d: -f1)"
C2_LINE="$(grep -n 'c2/fragments/c2.sh' "$LOAD" | cut -d: -f1)"
check "default order: c1 before c2" "$( [ "$C1_LINE" -lt "$C2_LINE" ] && echo yes || echo no )" yes
yq -i '.overrides.c1.after = ["c2"]' "$CFG"   # force c1 to load AFTER c2
usm compile >/dev/null 2>&1
C1_LINE="$(grep -n 'c1/fragments/c1.sh' "$LOAD" | cut -d: -f1)"
C2_LINE="$(grep -n 'c2/fragments/c2.sh' "$LOAD" | cut -d: -f1)"
check "override after: c2 before c1" "$( [ "$C2_LINE" -lt "$C1_LINE" ] && echo yes || echo no )" yes

printf '== (d) >= constraint with no satisfying tag ERRORS ==\n'
DREPO="$TMP/drepo"
mkdir -p "$DREPO/dmod/fragments"
printf 'name: dmod\nversion: 1.0.0\nshell:\n  - fragments/d.sh\n' >"$DREPO/dmod/usm.yaml"
printf 'export DMOD=1\n' >"$DREPO/dmod/fragments/d.sh"
git -C "$DREPO" init -q; git -C "$DREPO" symbolic-ref HEAD refs/heads/main
git -C "$DREPO" add -A; git -C "$DREPO" commit -q -m v1; git -C "$DREPO" tag v1.0.0
D_ERR="$(usm install "$DREPO" --subdir dmod --version '>=2.0.0' 2>&1)"; D_RC=$?
check "(d) install fails nonzero"   "$D_RC" 1
check "(d) dmod NOT added to config" "$(SUB=dmod yq '[.modules[]|select((.subdir // "")==strenv(SUB))]|length' "$CFG")" 0
check "(d) error mentions no tag"   "$(printf '%s\n' "$D_ERR" | grep -c 'no tag satisfies')" 1

printf '== (e) duplicate name across sources ERRORS ==\n'
DUP1="$TMP/dup1"; DUP2="$TMP/dup2"
for d in "$DUP1" "$DUP2"; do
  mkdir -p "$d/m/fragments"
  printf 'name: dupname\nversion: 0.0.0\nshell:\n  - fragments/m.sh\n' >"$d/m/usm.yaml"
  printf 'export M=1\n' >"$d/m/fragments/m.sh"
  git -C "$d" init -q; git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" add -A; git -C "$d" commit -q -m v1
done
usm install "$DUP1" --subdir m >/dev/null 2>&1
E_ERR="$(usm install "$DUP2" --subdir m 2>&1)"; E_RC=$?
check "(e) dup install fails"       "$E_RC" 1
check "(e) error names conflict"    "$(printf '%s\n' "$E_ERR" | grep -c 'name conflict')" 1
usm remove dupname >/dev/null 2>&1   # clean up the surviving DUP1 entry

printf '== (f) requires cycle ERRORS ==\n'
CYA="$TMP/cyca"; CYB="$TMP/cycb"
mkdir -p "$CYA/a/fragments" "$CYB/b/fragments"
cat >"$CYA/a/usm.yaml" <<EOF
name: cyca
version: 0.0.0
shell: [fragments/a.sh]
requires:
  - source: $CYB
    subdir: b
EOF
printf 'export CYA=1\n' >"$CYA/a/fragments/a.sh"
cat >"$CYB/b/usm.yaml" <<EOF
name: cycb
version: 0.0.0
shell: [fragments/b.sh]
requires:
  - source: $CYA
    subdir: a
EOF
printf 'export CYB=1\n' >"$CYB/b/fragments/b.sh"
git -C "$CYA" init -q; git -C "$CYA" symbolic-ref HEAD refs/heads/main; git -C "$CYA" add -A; git -C "$CYA" commit -q -m v1
git -C "$CYB" init -q; git -C "$CYB" symbolic-ref HEAD refs/heads/main; git -C "$CYB" add -A; git -C "$CYB" commit -q -m v1
F_ERR="$(usm install "$CYA" --subdir a 2>&1)"; F_RC=$?
check "(f) cycle install fails"     "$F_RC" 1
check "(f) error reports cycle"     "$(printf '%s\n' "$F_ERR" | grep -c 'cycle')" 1

printf '== (g) multi-digit semver: v1.10.0 chosen over v1.9.0 ==\n'
GREPO="$TMP/grepo"
mkdir -p "$GREPO/gmod/fragments"
printf 'name: gmod\nversion: 0.0.0\nshell:\n  - fragments/g.sh\n' >"$GREPO/gmod/usm.yaml"
printf 'export GMOD=1\n' >"$GREPO/gmod/fragments/g.sh"
git -C "$GREPO" init -q; git -C "$GREPO" symbolic-ref HEAD refs/heads/main
git -C "$GREPO" add -A; git -C "$GREPO" commit -q -m v19; git -C "$GREPO" tag v1.9.0
git -C "$GREPO" commit -q --allow-empty -m v110; git -C "$GREPO" tag v1.10.0
usm install "$GREPO" --subdir gmod --version '>=1.0.0' >/dev/null 2>&1
check "(g) picks v1.10.0 over v1.9.0" "$(NM=gmod yq '.modules[]|select(.name==strenv(NM))|.ref' "$LOCK")" v1.10.0
check "(g) gmod version 1.10.0"       "$(NM=gmod yq '.modules[]|select(.name==strenv(NM))|.version' "$LOCK")" 1.10.0

################################################################################
# Phase 4 — `usm order`: edit overrides (before/after/disable/enable) + recompile.
################################################################################

printf '== Phase 4 setup: install alpha (shell+rc) and beta ==\n'
P4="$TMP/p4repo"
mkdir -p "$P4/alpha/fragments" "$P4/alpha/rc" "$P4/beta/fragments"
cat >"$P4/alpha/usm.yaml" <<'EOF'
name: alpha
version: 1.0.0
shell:
  - fragments/a1.sh
  - fragments/a2.sh
rc:
  psqlrc:
    - rc/a.fragment
EOF
printf 'export A1=1\n' >"$P4/alpha/fragments/a1.sh"
printf 'export A2=1\n' >"$P4/alpha/fragments/a2.sh"
printf '\\set ALPHA 1\n' >"$P4/alpha/rc/a.fragment"
cat >"$P4/beta/usm.yaml" <<'EOF'
name: beta
version: 1.0.0
shell:
  - fragments/b1.sh
EOF
printf 'export B1=1\n' >"$P4/beta/fragments/b1.sh"
git -C "$P4" init -q; git -C "$P4" symbolic-ref HEAD refs/heads/main
git -C "$P4" add -A; git -C "$P4" commit -q -m v1; git -C "$P4" tag v1.0.0
usm install "$P4" --subdir alpha --version '>=1.0.0' >/dev/null 2>&1
usm install "$P4" --subdir beta  --version '>=1.0.0' >/dev/null 2>&1
A1_LINE="$(grep -n 'alpha/fragments/a1.sh' "$LOAD" | cut -d: -f1)"
B1_LINE="$(grep -n 'beta/fragments/b1.sh'  "$LOAD" | cut -d: -f1)"
check "p4 default order: alpha before beta" "$( [ "$A1_LINE" -lt "$B1_LINE" ] && echo yes || echo no )" yes

printf '== (a) order --after reorders load.sh ==\n'
usm order alpha --after beta >/dev/null 2>&1
check "(a) writes overrides.alpha.after" "$(yq '.overrides.alpha.after | join(",")' "$CFG")" beta
A1_LINE="$(grep -n 'alpha/fragments/a1.sh' "$LOAD" | cut -d: -f1)"
B1_LINE="$(grep -n 'beta/fragments/b1.sh'  "$LOAD" | cut -d: -f1)"
check "(a) after: beta before alpha in load.sh" "$( [ "$B1_LINE" -lt "$A1_LINE" ] && echo yes || echo no )" yes

printf '== (f) idempotency: repeating --after does not duplicate ==\n'
usm order alpha --after beta >/dev/null 2>&1
check "(f) after entry not duplicated" "$(yq '.overrides.alpha.after | length' "$CFG")" 1

printf '== (b) order --before reorders load.sh ==\n'
yq -i 'del(.overrides)' "$CFG"; usm compile >/dev/null 2>&1   # reset to default
usm order beta --before alpha >/dev/null 2>&1
check "(b) writes overrides.beta.before" "$(yq '.overrides.beta.before | join(",")' "$CFG")" alpha
A1_LINE="$(grep -n 'alpha/fragments/a1.sh' "$LOAD" | cut -d: -f1)"
B1_LINE="$(grep -n 'beta/fragments/b1.sh'  "$LOAD" | cut -d: -f1)"
check "(b) before: beta before alpha in load.sh" "$( [ "$B1_LINE" -lt "$A1_LINE" ] && echo yes || echo no )" yes

printf '== (c) order --disable drops shell + rc fragments ==\n'
yq -i 'del(.overrides)' "$CFG"; usm compile >/dev/null 2>&1   # reset to default
grep_ok "(c) alpha rc frag present pre-disable" "\set ALPHA 1" "$USM_DATA/rc/psqlrc"
usm order alpha --disable fragments/a1.sh >/dev/null 2>&1
grep_no "(c) disabled shell frag gone from load"  "alpha/fragments/a1.sh" "$LOAD"
grep_ok "(c) sibling shell frag still in load"    "alpha/fragments/a2.sh" "$LOAD"
check   "(c) overrides records disabled shell frag" "$(yq '.overrides.alpha.disable_fragments | join(",")' "$CFG")" fragments/a1.sh
usm order alpha --disable rc/a.fragment >/dev/null 2>&1
check   "(c) psqlrc removed when last frag disabled" "$( [ -e "$USM_DATA/rc/psqlrc" ] && echo yes || echo no )" no
LIST_OUT="$(usm list 2>/dev/null)"
check   "(c) list shows 2 disabled for alpha" "$(printf '%s\n' "$LIST_OUT" | grep '^alpha' | grep -c '2 disabled')" 1
SHOW_OUT="$(usm order --show 2>/dev/null)"
check   "(c) --show reports disabled frags"   "$(printf '%s\n' "$SHOW_OUT" | grep -c 'disabled:')" 1
check   "(c) --show names a1.sh"              "$(printf '%s\n' "$SHOW_OUT" | grep -c 'fragments/a1.sh')" 1

printf '== (d) order --enable restores fragments + cleans overrides ==\n'
usm order alpha --enable fragments/a1.sh >/dev/null 2>&1
usm order alpha --enable rc/a.fragment  >/dev/null 2>&1
grep_ok "(d) enable restores shell frag" "alpha/fragments/a1.sh" "$LOAD"
grep_ok "(d) enable restores rc frag"    "\set ALPHA 1" "$USM_DATA/rc/psqlrc"
check   "(d) empty overrides map removed" "$(yq 'has("overrides")' "$CFG")" false

printf '== (e) order on uninstalled module errors ==\n'
E_ORD="$(usm order nosuchmod --after alpha 2>&1)"; E_ORD_RC=$?
check "(e) order uninstalled fails nonzero" "$E_ORD_RC" 1
check "(e) error names the module"          "$(printf '%s\n' "$E_ORD" | grep -c "no installed module named 'nosuchmod'")" 1

printf '== (g) order --show prints current effective order ==\n'
SHOW_OUT="$(usm order --show 2>/dev/null)"
check "(g) --show prints load order header" "$(printf '%s\n' "$SHOW_OUT" | grep -c 'load order')" 1
check "(g) --show lists alpha and beta"     "$(printf '%s\n' "$SHOW_OUT" | grep -Ec 'alpha|beta')" 2

printf '== hand-edit config + compile == order-command result ==\n'
yq -i 'del(.overrides)' "$CFG"; usm compile >/dev/null 2>&1
usm order alpha --after beta >/dev/null 2>&1
CMD_LOAD="$(cat "$LOAD")"; CMD_OVR="$(yq '.overrides' "$CFG")"
yq -i 'del(.overrides)' "$CFG"
yq -i '.overrides.alpha.after = ["beta"]' "$CFG"          # the same edit, by hand
usm compile >/dev/null 2>&1
check "hand-edit overrides == order-cmd overrides" "$(yq '.overrides' "$CFG")" "$CMD_OVR"
check "hand-edit load.sh == order-cmd load.sh"     "$(cat "$LOAD")" "$CMD_LOAD"

################################################################################
# Phase 5 — lifecycle: update, sync, doctor. Start from a clean config so
# assertions are not entangled with the Phase 2-4 fixtures still in config.yaml.
################################################################################

printf '== Phase 5 reset ==\n'
yq -i '.modules = []' "$CFG"; yq -i 'del(.overrides)' "$CFG"
usm compile >/dev/null 2>&1
check "reset: no modules in lock" "$(yq '.modules | length' "$LOCK")" 0

printf '== (5a) update: >= module adopts a newly-published higher tag ==\n'
UPD="$TMP/updrepo"
mkdir -p "$UPD/um/fragments"
printf 'name: um\nversion: 1.0.0\nshell:\n  - fragments/u.sh\n' >"$UPD/um/usm.yaml"
printf 'export UM=1\n' >"$UPD/um/fragments/u.sh"
git -C "$UPD" init -q; git -C "$UPD" symbolic-ref HEAD refs/heads/main
git -C "$UPD" add -A; git -C "$UPD" commit -q -m v1; git -C "$UPD" tag v1.0.0
usm install "$UPD" --subdir um --version '>=1.0.0' >/dev/null 2>&1
check "(5a) initial ref v1.0.0" "$(NM=um yq '.modules[]|select(.name==strenv(NM))|.ref' "$LOCK")" v1.0.0
git -C "$UPD" commit -q --allow-empty -m v2; git -C "$UPD" tag v2.0.0   # publish higher tag
UPD_OUT="$(usm update um 2>&1)"
check "(5a) updated ref v2.0.0"   "$(NM=um yq '.modules[]|select(.name==strenv(NM))|.ref' "$LOCK")" v2.0.0
check "(5a) updated version 2.0.0" "$(NM=um yq '.modules[]|select(.name==strenv(NM))|.version' "$LOCK")" 2.0.0
check "(5a) report shows old->new" "$(printf '%s\n' "$UPD_OUT" | grep -c 'um: v1.0.0 -> v2.0.0')" 1

printf '== (5b) update: floating module advances to new default-branch HEAD ==\n'
FLT="$TMP/fltrepo"
mkdir -p "$FLT/fm/fragments"
printf 'name: fm\nversion: 0.0.0\nshell:\n  - fragments/f.sh\n' >"$FLT/fm/usm.yaml"
printf 'export FM=1\n' >"$FLT/fm/fragments/f.sh"
git -C "$FLT" init -q; git -C "$FLT" symbolic-ref HEAD refs/heads/main
git -C "$FLT" add -A; git -C "$FLT" commit -q -m c1
usm install "$FLT" --subdir fm >/dev/null 2>&1
FM_SHA1="$(git -C "$FLT" rev-parse HEAD)"
check "(5b) floating version empty" "$(NM=fm yq '.modules[]|select(.name==strenv(NM))|.version' "$LOCK")" ""
check "(5b) floating sha = c1"      "$(NM=fm yq '.modules[]|select(.name==strenv(NM))|.sha' "$LOCK")" "$FM_SHA1"
git -C "$FLT" commit -q --allow-empty -m c2
FM_SHA2="$(git -C "$FLT" rev-parse HEAD)"
FLT_OUT="$(usm update fm 2>&1)"
check "(5b) floating sha advanced to c2" "$(NM=fm yq '.modules[]|select(.name==strenv(NM))|.sha' "$LOCK")" "$FM_SHA2"
check "(5b) c1 != c2"                    "$( [ "$FM_SHA1" != "$FM_SHA2" ] && echo yes )" yes
check "(5b) report shows sha move"       "$(printf '%s\n' "$FLT_OUT" | grep -c 'fm: main@')" 1

printf '== (5c) update <name> touches only that repo ==\n'
R1="$TMP/r1repo"; R2="$TMP/r2repo"
mkdir -p "$R1/m1/fragments" "$R2/m2/fragments"
printf 'name: m1\nversion: 0.0.0\nshell:\n  - fragments/a.sh\n' >"$R1/m1/usm.yaml"; printf 'export M1=1\n' >"$R1/m1/fragments/a.sh"
printf 'name: m2\nversion: 0.0.0\nshell:\n  - fragments/a.sh\n' >"$R2/m2/usm.yaml"; printf 'export M2=1\n' >"$R2/m2/fragments/a.sh"
git -C "$R1" init -q; git -C "$R1" symbolic-ref HEAD refs/heads/main; git -C "$R1" add -A; git -C "$R1" commit -q -m c1
git -C "$R2" init -q; git -C "$R2" symbolic-ref HEAD refs/heads/main; git -C "$R2" add -A; git -C "$R2" commit -q -m c1
usm install "$R1" --subdir m1 >/dev/null 2>&1
usm install "$R2" --subdir m2 >/dev/null 2>&1
M1_OLD="$(NM=m1 yq '.modules[]|select(.name==strenv(NM))|.sha' "$LOCK")"
M2_OLD="$(NM=m2 yq '.modules[]|select(.name==strenv(NM))|.sha' "$LOCK")"
git -C "$R1" commit -q --allow-empty -m c2   # BOTH repos get a new commit upstream
git -C "$R2" commit -q --allow-empty -m c2
usm update m1 >/dev/null 2>&1
M1_NEW="$(NM=m1 yq '.modules[]|select(.name==strenv(NM))|.sha' "$LOCK")"
M2_NEW="$(NM=m2 yq '.modules[]|select(.name==strenv(NM))|.sha' "$LOCK")"
check "(5c) m1 advanced"   "$( [ "$M1_OLD" != "$M1_NEW" ] && echo yes )" yes
check "(5c) m2 untouched"  "$M2_NEW" "$M2_OLD"

printf '== (5d) sync rebuilds from a cold cache (no cache/, no lock.yaml) ==\n'
rm -rf "$CACHE" "$LOCK" "$LOAD"
SYNC_OUT="$(usm sync 2>&1)"
check "(5d) lock rebuilt"        "$( [ -f "$LOCK" ] && echo yes )" yes
check "(5d) modules resolved"    "$( [ "$(yq '.modules | length' "$LOCK")" -gt 0 ] && echo yes )" yes
grep_ok "(5d) load.sh has m1"    "m1/fragments/a.sh" "$LOAD"
grep_ok "(5d) load.sh has um"    "um/fragments/u.sh" "$LOAD"
check "(5d) um re-resolved to v2.0.0" "$(NM=um yq '.modules[]|select(.name==strenv(NM))|.ref' "$LOCK")" v2.0.0
check "(5d) sync reports count"  "$(printf '%s\n' "$SYNC_OUT" | grep -c 'synced')" 1

printf '== (5e) doctor on a healthy install exits 0 with OK lines ==\n'
DOC_OUT="$(usm doctor 2>&1)"; DOC_RC=$?
check "(5e) doctor healthy exits 0"   "$DOC_RC" 0
check "(5e) doctor prints OK lines"   "$( [ "$(printf '%s\n' "$DOC_OUT" | grep -c '^OK')" -gt 0 ] && echo yes )" yes
check "(5e) doctor has no ERROR line" "$(printf '%s\n' "$DOC_OUT" | grep -c '^ERROR')" 0

printf '== (5f) doctor on a broken install reports ERROR and exits non-zero ==\n'
BAD_HASH="$(NM=m1 yq '.modules[]|select(.name==strenv(NM))|.cache' "$LOCK")"
rm -rf "$CACHE/$BAD_HASH"   # corrupt: delete a module's cache clone
DOC_OUT2="$(usm doctor 2>&1)"; DOC_RC2=$?
check "(5f) doctor broken exits non-zero" "$( [ "$DOC_RC2" -ne 0 ] && echo yes )" yes
check "(5f) doctor reports ERROR"         "$( [ "$(printf '%s\n' "$DOC_OUT2" | grep -c '^ERROR')" -gt 0 ] && echo yes )" yes
check "(5f) ERROR names missing cache"    "$(printf '%s\n' "$DOC_OUT2" | grep -c 'no cache clone')" 1

################################################################################
# Phase 6 — validate the committed examples/ modules end-to-end (own sandbox).
################################################################################

printf '== Phase 6: example-module validation (test/examples.sh) ==\n'
if bash "$USM_ROOT/test/examples.sh"; then
  ok "example-module validation suite"
else
  bad "example-module validation suite (see failures above)"
fi

################################################################################
# Remediation regression tests (auditor fixes). Each is written to FAIL on the
# pre-fix code path and PASS after. They reuse the live run.sh config/sandbox.
################################################################################

printf '== (fix1) semver: 4-component tag ignored, no comparator stderr leak ==\n'
SEMV="$TMP/semverrepo"
mkdir -p "$SEMV/sv/fragments"
printf 'name: sv\nversion: 0.0.0\nshell:\n  - fragments/s.sh\n' >"$SEMV/sv/usm.yaml"
printf 'export SV=1\n' >"$SEMV/sv/fragments/s.sh"
git -C "$SEMV" init -q; git -C "$SEMV" symbolic-ref HEAD refs/heads/main
git -C "$SEMV" add -A; git -C "$SEMV" commit -q -m v120; git -C "$SEMV" tag v1.2.0
git -C "$SEMV" commit -q --allow-empty -m v1234; git -C "$SEMV" tag v1.2.3.4
# Capture ONLY stderr: the invalid v1.2.3.4 must be filtered, never reach the numeric
# comparator, and leave no `[: ...: integer expression expected` behind.
SV_ERR="$(usm install "$SEMV" --subdir sv --version '>=1.0.0' 2>&1 1>/dev/null)"
check "(fix1) picks highest VALID semver v1.2.0" "$(NM=sv yq '.modules[]|select(.name==strenv(NM))|.ref' "$LOCK")" v1.2.0
check "(fix1) no 'integer expression' leak on stderr" "$(printf '%s\n' "$SV_ERR" | grep -c 'integer expression')" 0
# Multi-digit still resolves numerically (v1.10.0 > v1.9.0), unaffected by the filter.
SEMV2="$TMP/semver2repo"
mkdir -p "$SEMV2/sv2/fragments"
printf 'name: sv2\nversion: 0.0.0\nshell:\n  - fragments/s.sh\n' >"$SEMV2/sv2/usm.yaml"
printf 'export SV2=1\n' >"$SEMV2/sv2/fragments/s.sh"
git -C "$SEMV2" init -q; git -C "$SEMV2" symbolic-ref HEAD refs/heads/main
git -C "$SEMV2" add -A; git -C "$SEMV2" commit -q -m v19; git -C "$SEMV2" tag v1.9.0
git -C "$SEMV2" commit -q --allow-empty -m v110; git -C "$SEMV2" tag v1.10.0
usm install "$SEMV2" --subdir sv2 --version '>=1.0.0' >/dev/null 2>&1
check "(fix1) v1.10.0 chosen over v1.9.0" "$(NM=sv2 yq '.modules[]|select(.name==strenv(NM))|.ref' "$LOCK")" v1.10.0

printf '== (fix2) order --disable validates fragment; list counts truthfully ==\n'
F2="$TMP/fix2repo"
mkdir -p "$F2/mod2/fragments"
printf 'name: mod2\nversion: 1.0.0\nshell:\n  - fragments/one.sh\n  - fragments/two.sh\n' >"$F2/mod2/usm.yaml"
printf 'export ONE=1\n' >"$F2/mod2/fragments/one.sh"
printf 'export TWO=1\n' >"$F2/mod2/fragments/two.sh"
git -C "$F2" init -q; git -C "$F2" symbolic-ref HEAD refs/heads/main
git -C "$F2" add -A; git -C "$F2" commit -q -m v1; git -C "$F2" tag v1.0.0
usm install "$F2" --subdir mod2 --version '>=1.0.0' >/dev/null 2>&1
# (a) a bogus fragment path errors and mutates nothing.
LOAD_BEFORE="$(cat "$LOAD")"
BOGUS_ERR="$(usm order mod2 --disable fragments/bogus.sh 2>&1)"; BOGUS_RC=$?
check "(fix2) bogus --disable fails nonzero"    "$BOGUS_RC" 1
check "(fix2) error says not a fragment"        "$(printf '%s\n' "$BOGUS_ERR" | grep -c 'is not a fragment')" 1
check "(fix2) no override written for bogus"    "$(NM=mod2 yq '.overrides[strenv(NM)].disable_fragments // [] | length' "$CFG" 2>/dev/null)" 0
check "(fix2) load.sh unchanged after bogus"    "$(cat "$LOAD")" "$LOAD_BEFORE"
# (b) a real fragment disables, drops from load.sh, and list counts it correctly.
usm order mod2 --disable fragments/one.sh >/dev/null 2>&1
grep_no "(fix2) disabled frag gone from load"   "mod2/fragments/one.sh" "$LOAD"
grep_ok "(fix2) sibling frag still in load"     "mod2/fragments/two.sh" "$LOAD"
check "(fix2) list: 1 enabled, 1 disabled"      "$(usm list 2>/dev/null | grep '^mod2' | grep -c '1 enabled, 1 disabled')" 1
# (c) --enable restores it.
usm order mod2 --enable fragments/one.sh >/dev/null 2>&1
grep_ok "(fix2) enable restores frag to load"   "mod2/fragments/one.sh" "$LOAD"
check "(fix2) list: 2 enabled, 0 disabled"      "$(usm list 2>/dev/null | grep '^mod2' | grep -c '2 enabled, 0 disabled')" 1
# (d) a hand-edited config with stale/typo'd disable entries must not skew or go negative.
NM=mod2 yq -i '.overrides[strenv(NM)].disable_fragments = ["fragments/one.sh","fragments/ghost.sh","fragments/ghost2.sh"]' "$CFG"
usm compile >/dev/null 2>&1
LIST_STALE="$(usm list 2>/dev/null)"
check "(fix2) stale overrides -> 1 enabled, 1 disabled" "$(printf '%s\n' "$LIST_STALE" | grep '^mod2' | grep -c '1 enabled, 1 disabled')" 1
check "(fix2) list never prints a negative count"       "$(printf '%s\n' "$LIST_STALE" | grep -c -- '-1 enabled')" 0
yq -i 'del(.overrides)' "$CFG"; usm compile >/dev/null 2>&1   # reset for later phases

printf '== (fix3) remove clears the removed module own overrides ==\n'
F3="$TMP/fix3repo"
mkdir -p "$F3/rm3/fragments" "$F3/ref3/fragments"
printf 'name: rm3\nversion: 1.0.0\nshell:\n  - fragments/r.sh\n' >"$F3/rm3/usm.yaml"
printf 'export RM3=1\n' >"$F3/rm3/fragments/r.sh"
printf 'name: ref3\nversion: 1.0.0\nshell:\n  - fragments/x.sh\n' >"$F3/ref3/usm.yaml"
printf 'export REF3=1\n' >"$F3/ref3/fragments/x.sh"
git -C "$F3" init -q; git -C "$F3" symbolic-ref HEAD refs/heads/main
git -C "$F3" add -A; git -C "$F3" commit -q -m v1; git -C "$F3" tag v1.0.0
usm install "$F3" --subdir ref3 --version '>=1.0.0' >/dev/null 2>&1
usm install "$F3" --subdir rm3  --version '>=1.0.0' >/dev/null 2>&1
usm order rm3 --after ref3 >/dev/null 2>&1
check "(fix3) override present before remove"   "$(yq '.overrides | has("rm3")' "$CFG")" true
usm remove rm3 >/dev/null 2>&1
check "(fix3) overrides.rm3 gone after remove"   "$(NM=rm3 yq '.overrides[strenv(NM)] // "gone"' "$CFG")" gone
DOC3_OUT="$(usm doctor 2>&1)"
check "(fix3) doctor: no unknown-override WARN"  "$(printf '%s\n' "$DOC3_OUT" | grep -c 'override references unknown')" 0

printf '== (fix4) install warns on a command declared only under packages.snap ==\n'
F4="$TMP/fix4repo"
mkdir -p "$F4/snapmod/fragments"
cat >"$F4/snapmod/usm.yaml" <<'EOF'
name: snapmod
version: 1.0.0
shell:
  - fragments/s.sh
packages:
  snap: [usm-bogus-cmd-xyz]
EOF
printf 'export SNAPMOD=1\n' >"$F4/snapmod/fragments/s.sh"
git -C "$F4" init -q; git -C "$F4" symbolic-ref HEAD refs/heads/main
git -C "$F4" add -A; git -C "$F4" commit -q -m v1; git -C "$F4" tag v1.0.0
F4_OUT="$(usm install "$F4" --subdir snapmod --version '>=1.0.0' 2>&1)"
check "(fix4) warns about the missing snap-declared command" "$(printf '%s\n' "$F4_OUT" | grep -c 'usm-bogus-cmd-xyz')" 1

printf '== (fix5/6/7) doc + message corrections are in place ==\n'
grep_ok "(fix5) how-it-works: '>=' w/o tag is an error"   "no tags at all" "$USM_ROOT/docs/how-it-works.md"
grep_no "(fix5) how-it-works: drops 'no semver tags floats'" "no** semver tags: **float" "$USM_ROOT/docs/how-it-works.md"
grep_ok "(fix5) module-authoring: 'hard error, not a float'" "hard error, not a float" "$USM_ROOT/docs/module-authoring.md"
grep_ok "(fix6) usm.yaml: yq needs brew or snap ONLY"     "brew or snap ONLY" "$USM_ROOT/usm.yaml"
grep_no "(fix6) usm.yaml: drops 'resolved in Phase 1'"    "resolved in Phase 1" "$USM_ROOT/usm.yaml"
grep_ok "(fix6) pkg.sh: actionable yq install hint"       "mikefarah/yq/releases" "$USM_ROOT/lib/core/pkg.sh"
grep_ok "(fix6) init.sh: actionable yq install hint"      "mikefarah/yq/releases" "$USM_ROOT/lib/cli/init.sh"
grep_ok "(fix7) README: 'usm order [name]'"               "usm order [name]" "$USM_ROOT/README.md"
grep_no "(fix7) README: drops 'usm order [name ...]'"     "usm order [name ...]" "$USM_ROOT/README.md"
grep_ok "(fix7) resolve.sh: tag-format hint on error"     "tags must be vX.Y.Z" "$USM_ROOT/lib/core/resolve.sh"

printf '\n== summary ==\n'
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
