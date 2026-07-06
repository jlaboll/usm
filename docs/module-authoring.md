# Authoring a usm module

A **module** is a directory containing a `usm.yaml` manifest and the shell/rc fragments
it declares. A git repo can hold one module (at its root) or many (each in a subdir).
usm installs a module by `(repo URL, subdir)`, so there is no registry to publish to —
you just push a git repo and tag it.

The runnable [`examples/`](../examples/) directory holds two complete modules,
`git-workflow` and `psql`, that this guide references throughout. They are validated
end-to-end by [`test/examples.sh`](../test/examples.sh).

## Repo layout: many modules in one repo

usm resolves versions per *repo* (git tags are repo-wide), so a natural layout is one
repo of subdir modules that share a tag:

```
shell-modules/                 # one git repo, tagged v1.0.0, v1.1.0, …
  git-workflow/
    usm.yaml
    fragments/
      aliases.sh
      functions.sh
  psql/
    usm.yaml
    fragments/env.sh
    rc/psqlrc.fragment
```

Install a subdir module with `--subdir`:

```sh
usm install https://github.com/you/shell-modules --subdir git-workflow --version '>=1.0.0'
```

A single-module repo omits `--subdir` (the manifest sits at the repo root).

### Declaring a monorepo: install every module at once

Rather than make consumers run one `usm install --subdir …` per member, a monorepo can
ship a **root `usm.yaml` that declares its members**. This root manifest is a *workspace
descriptor* — it lists member subdirs under `modules:` and is **not itself a module** (no
`name`/`shell`/`rc`):

```yaml
# shell-modules/usm.yaml  (repo root)
modules:
  - git-workflow
  - psql
```

Now a consumer installs the whole repo in one command — no `--subdir`:

```sh
usm install https://github.com/you/shell-modules --version '>=1.0.0'
```

usm registers **every declared member** in `config.yaml` and resolves them together.
Because git tags (and therefore versions) are repo-wide, the single `--version` floor
applies to all members. `--subdir X` still works to cherry-pick one member from the same
repo. A repo without a root `modules:` declaration behaves exactly as before: no
`--subdir` means the root manifest is treated as a single module.

## The `usm.yaml` manifest schema

Every field, with the `git-workflow` example manifest:

```yaml
name: git-workflow                 # REQUIRED. Short id: dependency key + display name.
                                   # Must be unique across everything you install.
version: 1.0.0                     # A sanity mirror of the git tag. The TAG is the
                                   # source of truth for resolution; this is display only.
description: Git status/log aliases and a current-branch helper (bash + zsh).

shell:                             # Ordered shell fragments, relative to the module dir.
  - fragments/aliases.sh           # Listed order = the module's internal load order.
  - fragments/functions.sh

rc:                                # Fragment-assembly contributions to app rc files.
  psqlrc:                          # key = rc file basename (no leading dot)
    - rc/psqlrc.fragment           # value = ordered list of fragments to concatenate

packages:                          # DETECT & WARN ONLY — usm never installs these.
  brew: [git]                      # Checked by command name for the active manager;
  apt:  [git]                      # `install` warns if missing. snap: [...] also allowed.

requires:                          # Module dependencies (URL-based, lower-bound).
  - source: https://github.com/you/shell-modules
    subdir: git-workflow           # optional; omit/"" = repo root
    version: ">=1.0.0"             # optional lower bound; omit = floating
```

`name` is the only required field, but a real module always has at least `name` plus
`shell` and/or `rc`. Fields you omit are simply absent — no defaults are invented.

### `shell:` — fragments sourced into interactive shells

Each path is sourced (in listed order) at shell startup, so keep fragments **quiet**
(no `echo`) and **cross-shell safe** — they must behave identically under bash 3.2 and
zsh. Define aliases and functions; export env vars; wire completions. Avoid bashisms
(`declare -A`, `[[ … ]]` where `[ … ]` suffices) unless you guard for the shell.

`git-workflow/fragments/aliases.sh`:

```sh
# Sourced into interactive bash and zsh at shell startup.
alias gs='git status --short --branch'
alias gl='git log --oneline --graph -15'
```

`git-workflow/fragments/functions.sh`:

```sh
# POSIX-portable — identical under bash 3.2 and zsh.
git_current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null
}
```

> Aliases only take effect in **interactive** shells (bash disables alias expansion in
> non-interactive shells) — which is exactly where usm loads fragments. Functions and
> `export`s work everywhere.

### `rc:` — contributing to an assembled rc file

Modules contribute fragments to app rc files (`psqlrc`, `inputrc`, `gitconfig`, …).
usm concatenates every contributing module's fragments **in load order** into
`$USM_DATA/rc/<name>`, prepends a `generated by usm` header (using the file's natural
comment syntax — `--` for `psqlrc`, `#` otherwise), and links `~/.<name>` to it.

`psql/rc/psqlrc.fragment`:

```
-- comment syntax here is psql's own (--)
\set QUIET 1
\pset null '[null]'
\timing on
\set QUIET 0
```

After installing the `psql` module, `~/.psqlrc` is a symlink to the assembled file:

```
-- generated by usm — do not edit
-- comment syntax here is psql's own (--)
\set QUIET 1
\pset null '[null]'
\timing on
\set QUIET 0
```

Because assembly is by concatenation, **multiple modules can contribute to the same rc
file** — a personal `psql` module and a work `db-service` module can both add to
`psqlrc`, and their fragments land in load order. (`rc_files` in `config.yaml` is the
generated union of these names — you never set it by hand.)

### `packages:` — detect and warn, never install

List the OS packages a module needs, per manager. usm **never installs** them; on
`install` it only warns if the command is missing for the active manager:

```
warning: module needs missing brew package(s): libpq — install them yourself; usm won't.
```

Detection is by **command name on PATH**. If a package's command differs from its
package name and that command is what your fragments call, list the command name so the
check is meaningful. Only `usm init` ever touches the OS package manager (for the base's
own `git`/`yq`, with approval).

### `requires:` — dependencies and load ordering

`requires` declares other modules yours depends on, by `source` URL (+ optional
`subdir`, + optional lower-bound `version`). usm auto-pulls each dependency (even if it
isn't in `config.yaml`) and guarantees it **loads before** your module.

The `psql` example depends on `git-workflow` because its `pgdev()` function calls
`git_current_branch()`:

```yaml
# psql/usm.yaml
requires:
  - source: https://github.com/you/shell-modules   # the real published URL of the repo
    subdir: git-workflow
    version: ">=1.0.0"
```

```sh
# psql/fragments/env.sh
export PSQL_PAGER='less -SXF'
pgdev() {
  branch="$(git_current_branch)"        # provided by git-workflow, loaded first
  psql "myapp_${branch:-main}"
}
```

Notes:

- `source` must be the **real git URL** the dependency is published under. When the
  dependency is a sibling subdir of the *same* repo (as here), point `source` at that
  repo's URL and set `subdir`. (The examples ship a placeholder URL you replace with
  your published one; the validation test rewrites it to a local repo to run offline.)
- `requires` merges with any constraint in `config.yaml` for the same repo — the max
  lower bound wins. Cycles (`A` requires `B` requires `A`) are a hard error.
- Referencing a function at *definition* time isn't required; `pgdev` only calls
  `git_current_branch` when invoked, so ordering matters at call time, not source time.

## Versioning: semver git tags + floating fallback

Resolution is driven by **git tags**, not the manifest `version:` field:

- Tag releases as `vX.Y.Z` (e.g. `v1.0.0`, `v1.10.0`). usm keeps `v*` tags whose
  remainder is numeric `X.Y.Z` and picks the **highest** one satisfying a consumer's
  `>=` lower bound. Multi-digit components compare numerically (`v1.10.0 > v1.9.0`).
- A module **floats** only when there is **no** constraint on its repo anywhere (no
  `--version` and no `requires` lower bound): it pins to the default-branch HEAD by
  commit SHA, recorded in the lock with `version: ""`, and `usm update` advances it to
  the newest HEAD. A repo with no semver tags floats only in this no-constraint case —
  a `>=` constraint with **no satisfying tag** (including a repo with no tags at all) is
  a hard error, not a float.
- Keep `version:` in the manifest in sync with the tag as a sanity mirror; it is shown
  by `usm list` but does not drive resolution.

Because constraints are lower-bound floors, releasing a higher tag never breaks a
consumer — they simply adopt it on the next `usm update`.

## Ordering hints

Two mechanisms control load order:

1. **Within a module**, the `shell:` list order is the fragment order — put env/PATH
   setup before things that depend on it.
2. **Across modules**, `requires` forces a dependency before its dependent. A consumer
   can further nudge order locally with `overrides` (`before`/`after`) in their
   `config.yaml` — see [docs/commands.md](commands.md#configyaml-reference). Prefer
   `requires` for real dependencies; leave `overrides` to the consumer for local
   conflict resolution.

## Testing a module

Test the way the suite does: build a local fixture git repo, install into a sandbox,
and assert real behavior. No network, no bats, no touching your real `$HOME`.

```sh
tmp="$(mktemp -d)"
export HOME="$tmp/home"; mkdir -p "$HOME"
export USM_CONFIG="$tmp/cfg" USM_DATA="$tmp/data"

# Stage the module into a throwaway repo and tag it.
repo="$tmp/repo"; mkdir -p "$repo"
cp -R /path/to/your/module "$repo/git-workflow"
git -C "$repo" init -q && git -C "$repo" add -A
git -C "$repo" commit -q -m v1 && git -C "$repo" tag v1.0.0

~/.usm/bin/usm init
~/.usm/bin/usm install "$repo" --subdir git-workflow --version '>=1.0.0'
~/.usm/bin/usm list                       # confirm it resolved
cat "$USM_DATA/compiled/load.sh"          # confirm fragments + order

# Confirm it sources cleanly in BOTH shells (usm targets bash 3.2 and zsh):
bash --norc -c 'shopt -s expand_aliases; . "$USM_DATA/compiled/load.sh"; alias gs'
zsh  -f   -c '. "$USM_DATA/compiled/load.sh"; type git_current_branch'

rm -rf "$tmp"
```

[`test/examples.sh`](../test/examples.sh) does exactly this for the example modules —
copy its structure. It also asserts dependency ordering and rc assembly.

## Publishing a module

1. Push the repo (root module, or subdir modules) to a git host.
2. Tag a release: `git tag v1.0.0 && git push --tags`.
3. Consumers install by URL:
   `usm install https://github.com/you/shell-modules --subdir git-workflow --version '>=1.0.0'`.
4. Ship a new version by pushing a higher tag (`v1.1.0`); consumers pick it up with
   `usm update`.

Keep personal and work modules in **separate repos** (public vs. private) so a device's
`config.yaml` decides what it gets — see the separation model in
[docs/how-it-works.md](how-it-works.md#how-separation-and-reproducibility-fall-out).
