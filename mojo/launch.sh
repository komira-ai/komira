# launch.sh -- starts a linked Mojo binary.
#
# usage: busybox sh launch.sh <busybox> <compiler_dir> <binary> [args...]
#
# Built binaries carry no run path, so the loader is pointed at the
# toolchain's runtime libraries (<compiler_dir>/lib) here. Everything else in
# the caller's environment is passed through unchanged.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -ge 3 ] || { echo "launch: usage error" >&2; exit 2; }
TC=$(abspath "$2")
BIN=$(abspath "$3")
shift 3
LD_LIBRARY_PATH="$TC/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
exec "$BIN" "$@"
