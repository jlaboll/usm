# usm runtime loader. Sourced by managed shell rc files at startup.
# Sources the compiled loader if present. Kept silent and dependency-free so
# shell startup never parses YAML or shells out — all resolution happens ahead
# of time in the `usm` CLI compile step.
_usm_data="${USM_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/usm}"
[ -r "$_usm_data/compiled/load.sh" ] && . "$_usm_data/compiled/load.sh"
unset _usm_data
