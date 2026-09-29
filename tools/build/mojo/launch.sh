# launch.sh -- starts a linked Mojo binary.
#
# usage: busybox sh launch.sh <busybox> <compiler_dir> <binary> [args...]
#
# A built binary's only run path is $ORIGIN/lib, which resolves inside its
# runnable directory. Started from anywhere else, it needs the loader pointed
# at the toolchain's runtime libraries (<compiler_dir>/lib), which this does. Everything else in
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
