# usm compile — resolve config.yaml, write lock.yaml + compiled/load.sh, assemble rc
# files, and refresh ~/.<name> symlinks. Internal but user-invokable. All the work
# lives in lib/core/compile.sh (usm_compile) so other commands can reuse it.

cmd_compile() {
  usm_compile || usm_die "compile failed"
}
