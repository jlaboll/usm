# Example usm modules

Two complete, well-commented modules laid out as **subdir modules of one repo** — the
layout usm resolves best (git tags are repo-wide, so subdir modules share a tag). They
are reference/teaching material for [docs/module-authoring.md](../docs/module-authoring.md),
and are validated end-to-end by [test/examples.sh](../test/examples.sh).

| Module | Demonstrates |
|---|---|
| [`git-workflow`](git-workflow/) | A standalone module: two aliases + one function, cross-shell (bash 3.2 + zsh), plus a detect-and-warn `packages` block. |
| [`psql`](psql/) | A second module that `requires` git-workflow (dependency + load ordering) **and** contributes a `psqlrc` fragment (rc assembly → `~/.psqlrc`). |

## Try them

The usm repo itself has no commits/tags, so stage these into a throwaway git repo,
tag it, and install from that — all in a sandbox that never touches your real `$HOME`:

```sh
tmp="$(mktemp -d)"
export HOME="$tmp/home"; mkdir -p "$HOME"
export USM_CONFIG="$tmp/cfg" USM_DATA="$tmp/data"

repo="$tmp/shell-modules"; mkdir -p "$repo"
cp -R examples/git-workflow examples/psql "$repo"/
# psql ships a placeholder requires.source; point it at this repo so the dep resolves.
SRC="$repo" yq -i '.requires[0].source = strenv(SRC)' "$repo/psql/usm.yaml"
git -C "$repo" init -q && git -C "$repo" add -A
git -C "$repo" commit -q -m examples && git -C "$repo" tag v1.0.0

~/.usm/bin/usm init
~/.usm/bin/usm install "$repo" --subdir psql --version '>=1.0.0'  # auto-pulls git-workflow
~/.usm/bin/usm list
cat "$USM_DATA/compiled/load.sh"

rm -rf "$tmp"
```

## Publishing your own

Replace the placeholder `requires.source` URL in `psql/usm.yaml` with the real git URL
you publish the repo under, push, and tag `v1.0.0`. Consumers then install by URL — see
[docs/module-authoring.md](../docs/module-authoring.md#publishing-a-module).
