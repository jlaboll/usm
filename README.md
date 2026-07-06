# usm — Unix-like Shell Manager

Manage your shell environment the way `brew` manages packages. A bare-minimum base
lays down the plumbing, then you **install** functionality as versioned **modules**
pulled from git repositories. Modules are dependency-aware, reorderable, updatable,
and removable — and the base ships almost no personal content, so you compose each
device from exactly the modules it should have.

## The problem it solves

A single dotfiles tree intermixes work and personal shell config. Clone it onto a
personal laptop and you inherit work-specific settings — and secrets — you never
wanted there.

usm makes personal and work config **separate installable repos**:

- **Work vs. personal separation.** Your personal `config.yaml` lives in a public
  repo; your work `config.yaml` lives in a private one and references work modules
  from a private repo. A personal device simply never lists the work modules, so
  work config and secrets are *structurally* unable to land there.
- **Cross-machine reproducibility.** `config.yaml` is the whole portable description
  of a device. Copy it to a new machine and `usm sync` clones, resolves, and compiles
  everything to match — the setup reproduces exactly, pinned by resolved versions and
  commit SHAs in a generated lockfile.
- **Fast shells.** Resolution happens ahead of time in the CLI; shell startup only
  sources one flat, pre-ordered file. Startup never parses YAML or shells out to git.

## 60-second quickstart

```sh
# 1. Clone the base (the tool) and bootstrap it into this machine's shells.
git clone <your-usm-repo-url> ~/.usm
~/.usm/bin/usm init                 # detects OS, checks git+yq (installs with approval),
                                    # writes state dirs, and wires the loader into your rc

# Optional: put usm on PATH so you can drop the ~/.usm/bin/ prefix.
ln -s ~/.usm/bin/usm /usr/local/bin/usm

# 2. Install a module from a git repo (a subdir of a repo that holds a usm.yaml).
usm install https://github.com/you/shell-modules --subdir git-workflow
# ...or use a GitHub shorthand; and if the repo's root usm.yaml declares its modules,
# omit --subdir to install every module in the monorepo at once:
usm install you/shell-modules

# 3. Open a new shell (or `. ~/.bashrc` / `. ~/.zshrc`). Your module is live.
```

`usm init` appends a small guarded block to `~/.bashrc` and `~/.zshrc` that sources
the usm loader; on macOS it also makes `~/.bash_profile` source `~/.bashrc`.

## Commands

| Command | What it does |
|---|---|
| `usm init` | Bootstrap usm into this machine's shells (the only place it installs OS packages, with approval). |
| `usm install <url> [--subdir X] [--version 'C']` | Fetch a module's repo, register it in `config.yaml`, resolve deps, and recompile. |
| `usm update [module]` | Re-fetch repo(s), re-resolve against constraints, recompile, and report what moved. |
| `usm remove <name>` | Remove a module from `config.yaml`, recompile, prune unreferenced cache. |
| `usm list` | List installed modules: name, resolved version, source, fragment counts. |
| `usm order [name]` | Show the effective load order, or reorder / toggle fragments of one module via overrides. |
| `usm sync` | Reconcile this device to its `config.yaml` — reproduce a machine from cold. |
| `usm doctor` | Diagnose config/install problems; exits non-zero on any error. |
| `usm compile` | Internal but invokable: resolve → lockfile → loader → rc files → symlinks. |

Pass `-v` / `--verbose` anywhere to surface the underlying git/command output.

## Documentation

- [docs/how-it-works.md](docs/how-it-works.md) — the architecture: thin runtime loader
  vs. the compile step, the cache, repo-granular version resolution, `config.yaml`
  vs. `lock.yaml`, and how per-device separation and reproducibility fall out.
- [docs/module-authoring.md](docs/module-authoring.md) — how to build a compatible
  module: the `usm.yaml` schema, fragments, rc assembly, `requires`, versioning, and
  testing/publishing. References the runnable [examples/](examples/).
- [docs/commands.md](docs/commands.md) — full command reference with real output, plus
  the `config.yaml` overrides reference and per-device patterns.

## License

[MIT](LICENSE)
