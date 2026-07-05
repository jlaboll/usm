# YAML helpers — thin wrappers over yq (mikefarah v4). Reads only; commands that
# mutate config/lock call `yq -i` directly.

# Read a scalar. Prints empty string for a missing/null value.
# usm_yaml_get <file> <yq-expression>
usm_yaml_get() {
  local out
  out="$(yq "$2" "$1" 2>/dev/null)" || return 1
  [ "$out" = null ] && out=""
  printf '%s' "$out"
}

# Read a sequence as newline-separated values (nothing for missing/empty).
# usm_yaml_seq <file> <yq-expression-yielding-a-sequence>
usm_yaml_seq() {
  yq "(${2} // [])[]" "$1" 2>/dev/null
}
