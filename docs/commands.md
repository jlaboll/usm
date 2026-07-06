# Command reference

Every command, with real output. The lifecycle commands are grouped around the
workflows you actually run: **add** a module (`install`), **update** it (`update`),
**remove** it (`remove`), and reproduce a device (`sync`).

Global flags: pass `-v` / `--verbose` anywhere to surface the git/command output that is
otherwise silenced. Diagnostics go to stderr; machine-readable results to stdout.

```
usm help        # or -h, --help — the command list below
usm version     # -> "usm 0.0.0"
```

## `usm init`

First-run bootstrap. Run once per machine.

```sh
usm init
```

It: detects OS + package manager; checks the base's own tools (`git`, `yq`) and, if any
are missing, **prompts once** to install them (the only place usm touches the OS package
manager); creates the state dirs; seeds `config.yaml`; and wires the loader into your
shells. Safe to re-run — every step is idempotent.

```
usm initialized. Open a new shell, or source your shell rc, to load it.
```

It appends a guarded block to `~/.bashrc` and `~/.zshrc`:

```sh
# >>> usm >>>
# Load modular shell configuration managed by usm.
[ -r "/Users/you/.usm/lib/loader.sh" ] && . "/Users/you/.usm/lib/loader.sh"
# <<< usm <<<
```

and (on macOS, where login bash reads `~/.bash_profile`) ensures `~/.bash_profile`
sources `~/.bashrc`. The seeded `config.yaml`:

```yaml
# usm device configuration. Manage with 'usm install', 'usm order', or by hand.
shells: [bash, zsh]
rc_files: []
modules: []
overrides: {}
```

## Add a module — `usm install`

```
usm install <url> [--subdir X] [--version 'C']
```

Fetches the repo into the cache, validates the manifest at `<subdir>/usm.yaml`, warns
about any missing OS packages it declares, adds/updates the entry in `config.yaml`, then
resolves the graph and recompiles. Flags accept both `--flag value` and `--flag=value`.

```sh
usm install https://github.com/you/shell-modules --subdir psql --version '>=1.0.0'
```
```
warning: module needs missing brew package(s): libpq — install them yourself; usm won't.
installed psql
```

- `<url>` accepts a **shorthand** `owner/repo`, expanded to `https://github.com/owner/repo`
  (set `USM_GIT_HOST` to target another host). Full URLs (`https://…`, `git@host:…`) and
  local paths are used as-is. So `usm install jlaboll/usm-core` just works.
- `--subdir X` — module lives in subdir `X` of the repo (omit for a root module).
- **Monorepos**: if the repo's root `usm.yaml` declares a `modules:` list of member
  subdirs, `usm install <url>` with **no** `--subdir` installs *every* member at once
  (the repo-wide `--version` applies to all). `--subdir` still cherry-picks one member.
  See [module-authoring.md](module-authoring.md#declaring-a-monorepo-install-every-module-at-once).
- `--version 'C'` — a lower-bound floor. `>=1.2.0` and a bare `1.2.0` both mean "at
  least 1.2.0"; usm picks the highest satisfying `vX.Y.Z` tag. Omit to **float** to the
  default branch HEAD.
- **Dependencies** in the module's `requires` are pulled in automatically, even if not
  listed in `config.yaml`, and ordered before it.
- **Idempotent**: re-installing the same `(url, subdir)` updates the entry in place
  (keeping its position), so it doubles as "change this module's version".
- If resolution/compile fails (e.g. a `>=` with no satisfying tag), `config.yaml` is
  restored unchanged — a bad install never leaves config and lock inconsistent.

## Update modules — `usm update`

```
usm update [module]
```

Re-fetches repos, re-resolves against the **same** constraints in `config.yaml`,
recompiles, and reports what moved. With a name, only that module's repo is fetched;
without one, every repo the lock references. A `>=` module adopts a newly-published
higher tag; a floating module advances to the fresh default-branch HEAD.

```sh
usm update git-workflow
```
```
  git-workflow: v1.0.0 -> v2.0.0
updated 1 module(s)
```

A floating module reports the branch and short SHA it moved to
(`fm: main@<sha> -> main@<sha>`). When nothing changed:

```
everything up to date
```

Changed modules always print; unchanged ones only under `-v`. Adds and removes caused by
a re-resolve are reported too.

## Remove a module — `usm remove`

```
usm remove <name>
```

Removes the module (matched by manifest **name**) from `config.yaml`, recompiles, and
prunes any cache clone no longer referenced by the lock.

```sh
usm remove psql
```
```
removed psql
```

If another installed module still `requires` the one you're removing, usm warns
(`still required by: <names>`) but proceeds. Removing a module that contributed the last
fragment of an rc file tears down that rc file and restores any `~/.<name>.usm-backup`.

## Inspect — `usm list`

```sh
usm list
```
```
NAME          VERSION  SOURCE                                         FRAGMENTS
git-workflow  1.0.0    https://github.com/you/shell-modules (git-workflow)  2 enabled, 0 disabled
psql          1.0.0    https://github.com/you/shell-modules (psql)          2 enabled, 0 disabled
```

Columns: module name, resolved version, source (with subdir in parentheses), and the
enabled/disabled fragment count (shell + rc fragments; disabled = counted from
`overrides.disable_fragments`). A floating module shows `<ref> (floating)` in place of a
version. With nothing installed: `no modules installed`.

## Ordering & fragment toggles — `usm order`

```
usm order [--show]                    # print the effective load order + overrides
usm order <name> --before <other>     # load <name> before <other>
usm order <name> --after  <other>     # load <name> after  <other>
usm order <name> --disable <frag>     # skip fragment <frag> of <name>
usm order <name> --enable  <frag>     # un-skip a previously disabled fragment
```

With no arguments (or `--show`) it prints the current state; otherwise it edits
`config.yaml`'s `overrides` and recompiles. Flags may be combined, take `--flag=value`
too, and are idempotent (no duplicate override entries).

```sh
usm order --show
```
```
load order (effective):
  1. git-workflow (1.0.0)
  2. psql (1.0.0)
```

```sh
usm order psql --disable fragments/env.sh
```

Editing `config.yaml` by hand and running `usm compile` is exactly equivalent — `order`
is a convenience over the same `overrides` structure the resolver reads. A `--before`/
`--after` that introduces a cycle fails the compile and leaves `config.yaml` unchanged.

## Reproduce a device — `usm sync`

```sh
usm sync
```
```
synced 2 module(s)
```

Given a `config.yaml` (e.g. freshly copied to a new machine), `sync` clones every
missing repo, fetches the rest, resolves, and compiles — reproducing the device from a
cold cache. It is `compile` with a guaranteed fetch of every referenced repo.

## Diagnose — `usm doctor`

```sh
usm doctor
```
```
OK    git present
OK    yq present
OK    config.yaml is valid YAML
OK    lock.yaml present
OK    all module sources cloned in cache
OK    all configured modules present in lock
OK    no orphan lock modules
OK    config resolves cleanly (no conflicts, cycles, or unsatisfiable constraints)
OK    ~/.psqlrc links to its staged rc file
OK    all load.sh fragment paths exist

doctor: all checks passed
```

Reports `OK` / `WARN` / `ERROR` lines and **exits non-zero if any ERROR** was found
(warnings don't fail). It checks: `git`+`yq` present; `config.yaml` valid; `lock.yaml`
present; every source cloned; lock consistent with config (no missing/orphan modules);
config re-resolves cleanly; overrides reference installed modules (WARN); each assembled
rc file's `~/.<name>` symlink is intact; and every path in `load.sh` exists. A broken
install surfaces the specific problem, e.g. `ERROR no cache clone for source: <url>`.

## `usm compile`

```sh
usm compile
```

Internal but user-invokable. Resolves `config.yaml` → writes `lock.yaml` → writes
`compiled/load.sh` → assembles rc files → refreshes `~/.<name>` symlinks. `install`,
`remove`, `order`, `update`, and `sync` all call it; run it directly after hand-editing
`config.yaml`. (It is intentionally omitted from `usm help`.)

---

## config.yaml reference

`config.yaml` (in `$USM_CONFIG`, default `~/.config/usm`) is the portable, per-device
description. You own `modules` and `overrides`; `shells` is seeded by `init`; `rc_files`
is generated.

```yaml
shells: [bash, zsh]            # shells usm manages rc for (seeded by init)
rc_files: [psqlrc]            # GENERATED each compile — union of rc files modules add
modules:                      # ORDER of this list = base load order
  - source: https://github.com/you/shell-modules   # required, git URL
    subdir: git-workflow      # optional; omit/"" = repo root
    version: ">=1.0.0"        # optional lower-bound floor; omit = floating
  - source: git@github.com:you/work-private        # a work-only entry lives ONLY
    subdir: corp-certs        # in the work device's config.yaml
overrides:                    # optional local conflict resolution, keyed by module name
  git-workflow:
    after: [core-helpers]     # force this module to load AFTER these
    before: [psql]            # force this module to load BEFORE these
    disable_fragments:        # skip specific fragments (shell OR rc), by relative path
      - fragments/aliases.sh
```

### `overrides` keys

| Key | Effect |
|---|---|
| `after: [names]` | This module loads **after** each named module (adds a dep edge into it). |
| `before: [names]` | This module loads **before** each named module. |
| `disable_fragments: [paths]` | Skip these fragment paths (shell or rc) for this module. A shell fragment vanishes from `load.sh`; an rc fragment is dropped from assembly (and the rc file is torn down if it was the last contribution). |

`overrides` are resolved on top of `requires` edges; a contradictory `before`/`after`
that would form a cycle fails the compile. Manage them with `usm order` or by hand — the
structure is identical.

## Per-device patterns

- **Personal vs. work.** Keep two `config.yaml` files: a personal one (in a public repo)
  listing personal modules, and a work one (in a private repo) that *also* lists work
  modules from a private module repo. Each device checks out the config it should have.
  Work modules and secrets never reach a personal device because its config never lists
  them.
- **Secrets** stay in per-device config/environment, never in a shared module repo.
- **New machine.** Clone the base, `usm init`, drop in the device's `config.yaml`, then
  `usm sync`. The lockfile pins exact SHAs, so the result is reproducible.
- **Local tweaks without forking a module.** Use `overrides` (`order --disable` /
  `--before` / `--after`) to turn off part of a module or reorder it for this device
  only — no need to edit the module's source.

See [docs/how-it-works.md](how-it-works.md) for the resolution model behind these, and
[docs/module-authoring.md](module-authoring.md) to build the modules you install.
