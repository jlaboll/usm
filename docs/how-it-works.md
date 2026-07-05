# How usm works

usm splits the job of "configure my shell" into two halves that never run at the same
time:

1. A **compile step** (run by the CLI, ahead of time) resolves your whole module graph
   and emits a flat, ordered list of files to source.
2. A **thin runtime loader** (run at shell startup) sources exactly that one file and
   nothing else — no YAML parsing, no git, no subshells.

This is what keeps interactive shells fast while still giving you dependency-aware,
versioned, reorderable configuration.

## The two-layer model

```
usm CLI (occasional)                         shell startup (every shell)
────────────────────                         ───────────────────────────
config.yaml ──► resolve ──► lock.yaml            ~/.bashrc / ~/.zshrc
                    │                                   │
                    ├──► compiled/load.sh  ◄────────────┘ sources lib/loader.sh,
                    │                                     which sources load.sh
                    └──► rc/<name> ──► ~/.<name> symlink
```

Everything expensive — cloning repos, reading manifests, resolving semver tags,
topologically ordering modules — happens in the CLI when you `install`, `update`,
`order`, `sync`, or `compile`. The result is written to `compiled/load.sh`, a plain
list of absolute `source` lines. Shell startup does one guarded thing:

```sh
# lib/loader.sh (sourced by your rc) — silent, dependency-free.
_usm_data="${USM_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/usm}"
[ -r "$_usm_data/compiled/load.sh" ] && . "$_usm_data/compiled/load.sh"
unset _usm_data
```

`usm init` wires this in by appending a guarded block to `~/.bashrc` and `~/.zshrc`:

```sh
# >>> usm >>>
# Load modular shell configuration managed by usm.
[ -r "/Users/you/.usm/lib/loader.sh" ] && . "/Users/you/.usm/lib/loader.sh"
# <<< usm <<<
```

On macOS, a login bash shell reads `~/.bash_profile` rather than `~/.bashrc`, so `init`
also ensures `~/.bash_profile` sources `~/.bashrc` (its own guarded block).

## Filesystem layout

usm separates the **tool** (the shared repo you clone) from **per-device state** (never
committed to the base repo). Dirs are XDG-style and all overridable via the matching
environment variable.

| Location | Default | Holds |
|---|---|---|
| `$USM_ROOT` | `~/.usm` | The usm base repo: `bin/usm`, `lib/`, docs, `examples/`. |
| `$USM_CONFIG` | `~/.config/usm` | `config.yaml` — your portable device description. |
| `$USM_DATA` | `~/.local/share/usm` | Generated state: `cache/`, `lock.yaml`, `compiled/load.sh`, `rc/`. |

Inside `$USM_DATA`:

```
cache/<repo-hash>/     one git clone per source repo (a module is a subdir within it)
lock.yaml              resolved graph, in final load order (generated)
compiled/load.sh       flat ordered list of source lines (generated)
rc/<name>              assembled app rc files (e.g. rc/psqlrc), linked to ~/.<name>
```

`$USM_ROOT`, `$USM_CONFIG`, and `$USM_DATA` are read from the environment, so a fully
sandboxed run (as the test suite does) is just a matter of pointing them at temp dirs.

## config.yaml — portable, per-device (you own this)

`config.yaml` is the shareable artifact. It describes *what this device should have*,
in load order.

```yaml
shells: [bash, zsh]          # shells usm manages rc for (set by init from what's present)
rc_files: [psqlrc]           # GENERATED — the union of rc files modules contribute (see below)
modules:                     # ORDER of this list = the base load order
  - source: https://github.com/you/shell-modules
    subdir: git-workflow     # optional; omit/"" = repo root
    version: ">=1.0.0"       # optional lower bound; omit = floating
overrides:                   # optional local conflict resolution, keyed by module name
  git-workflow:
    after: [core-helpers]    # force ordering relative to another module
    disable_fragments:       # turn off part of a module locally
      - fragments/aliases.sh
```

Two fields are **not** hand-authored:

- **`rc_files`** is *generated*. On every compile, usm rewrites it to the union of the
  rc files that installed modules contribute to. Editing it by hand has no lasting
  effect — it is a derived index, not an input. (Which rc files exist is decided by
  modules' `rc:` blocks, not by this list.)
- **`shells`** is seeded by `init` from the interactive shells present on the machine.
  You can edit it if you want usm to manage a different set, but normally you don't.

The parts you do own are **`modules`** (which modules, in what base order) and
**`overrides`** (local ordering and fragment toggles). See
[docs/commands.md](commands.md#configyaml-reference) for the full override reference.

## lock.yaml — resolved graph (generated)

`compile` writes `lock.yaml` in **final load order**. It is the cache manifest and the
reproducibility record: each module's resolved version, exact ref, commit SHA, cache
location, dependency edges, and a copy of its `shell`/`rc` fragment lists.

```yaml
modules:
  - name: git-workflow
    source: https://github.com/you/shell-modules
    subdir: git-workflow
    constraint: ">=1.0.0"    # merged lower bound actually used
    version: 1.0.0           # resolved semver ("" if floating)
    ref: v1.0.0              # git ref checked out (tag, or a branch when floating)
    sha: 9f1c…               # full commit sha
    cache: 3d686e9e4d61d813  # cache/<hash> subdir holding the clone
    path: 3d686e9e4d61d813/git-workflow   # module dir relative to cache/
    requires: []             # dependency names
    shell: [fragments/aliases.sh, fragments/functions.sh]
    rc: {}
```

You never edit `lock.yaml`; regenerate it with `usm compile` (or any command that
recompiles). `usm doctor` checks that it stays consistent with `config.yaml` and the
cache.

## Version resolution is repo-granular

Module identity is `(normalized source URL, subdir)`, but **git tags are repo-wide**, so
resolution granularity is the *repo*, not the module:

1. **Discover** the graph: start from `config.yaml` `modules`, then follow every
   manifest's `requires` (breadth-first). Each repo is cloned once into `cache/<hash>`.
2. **Merge constraints** per repo: collect every lower bound requested for that repo
   (from config plus transitive `requires`) and take the **max**.
3. **Resolve** each repo to a single ref:
   - With a lower bound `>=X.Y.Z`: pick the highest `vX.Y.Z` git tag that satisfies it.
     Constraints are lower-bound floors only (`>=`), so resolution is always solvable —
     there is no upper bound to conflict with. A bare `--version 1.2.0` is treated as
     `>=1.2.0`.
   - With **no** constraint anywhere: **float** to the default branch HEAD, pinned by
     SHA (`version: ""`). This is the fallback, and it is the *only* case that floats —
     a repo with no semver tags floats **only** because (and when) nothing requests a
     version.
   - A `>=` constraint with **no satisfying tag** — including a repo with no tags at all
     — is an error. usm surfaces it rather than silently floating: a version was
     requested, so falling back to HEAD would silently ignore it.
   All subdir-modules of one repo share that single resolved ref.
4. **Names & conflicts**: read each module's `name` at the resolved ref. Two *different*
   sources declaring the *same* `name` is an error (both culprits are named).
5. **Order** (topological): each `requires` dependency loads before its dependent; then
   `overrides` `before`/`after` edges refine it. Ties keep `config.yaml` order. Cycles
   are an error.

Semver comparison is implemented in pure bash 3.2 (split on `.`, numeric compare) — it
does not rely on `sort -V`, so multi-digit versions like `v1.10.0 > v1.9.0` resolve
correctly.

## The cache: one clone per repo

`cache/<hash>` is a full clone of a source repo, where `<hash>` is a short hash of the
**normalized** URL (trailing whitespace, trailing `/`, and a single trailing `.git` are
stripped before hashing). Multiple modules living in different subdirs of the same repo
**share one clone**. `usm remove` prunes a clone once no locked module references it;
`usm update` fetches clones and re-resolves.

## Shell fragments vs. rc assembly

The compile step produces two kinds of output from module fragments:

- **Shell fragments** (`shell:` in a manifest) become `source` lines in
  `compiled/load.sh`, in lock order, skipping any listed in that module's
  `overrides.disable_fragments`. These are sourced into interactive shells.
- **rc fragments** (`rc:` in a manifest) are *assembled*: for each rc file name, usm
  concatenates every contributing module's fragments, in lock order, into
  `$USM_DATA/rc/<name>` behind a `generated by usm` header, then links `~/.<name>` to
  it. Multiple modules can contribute to the same rc file (e.g. a personal and a work
  module both adding to `psqlrc`); ordering resolves conflicts. If a real `~/.<name>`
  already exists, usm moves it to `~/.<name>.usm-backup` once (never clobbering an
  existing backup) and warns; removing the last contribution restores the backup.

## How separation and reproducibility fall out

- **Per-device separation** is just *which entries are in this device's `config.yaml`*.
  A personal device's config never lists the work modules, so work config and secrets
  can't reach it. Put your personal `config.yaml` in a public repo and your work one in
  a private repo; each device pulls the config it should have.
- **Secrets** live per-device (in the device's own config/environment), never in a
  shared module repo.
- **Reproducibility** comes from `config.yaml` + resolution: copy the config to a new
  machine and `usm sync` clones every referenced repo, resolves the same versions, and
  compiles — the lockfile records the exact SHAs so the result is deterministic.

Next: [docs/module-authoring.md](module-authoring.md) to build a module, or
[docs/commands.md](commands.md) for the command reference.
