# run_check.sh -- runs a built binary inside a build action, through the same
# launch command its RunInfo carries, and records its standard output. With an
# expected-output file, fails unless stdout matches it byte for byte.
#
# usage: busybox sh run_check.sh <busybox> sh <launch.sh> <busybox> <compiler_dir> \
#            <binary> <out> [<expected>]
#
# The first six arguments are the binary's RunInfo command. This script sets
# no library path of its own, so a launcher or a binary that cannot start on
# its own terms fails here.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -ge 7 ] || { echo "run_check: usage error" >&2; exit 2; }
BB=$(abspath "$1")
LAUNCH=$(abspath "$3")
LBB=$(abspath "$4")
TC=$(abspath "$5")
BIN=$(abspath "$6")
OUT=$7
EXPECTED=${8:-}

T=$("$BB" mktemp -d "$PWD/.komira_run.XXXXXX")
trap '"$BB" rm -rf "$T"' EXIT
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
TMPDIR="$T/tmp"
HOME="$T/home"
export PATH TMPDIR HOME
unset LD_LIBRARY_PATH || true

rc=0
"$BB" sh "$LAUNCH" "$LBB" "$TC" "$BIN" > "$OUT" 2> "$T/err" < /dev/null || rc=$?
if [ "$rc" != 0 ]; then
    echo "run_check: $6 exited $rc" >&2
    tail -n 100 "$T/err" >&2
    exit 1
fi
if [ -n "$EXPECTED" ] && ! cmp -s "$OUT" "$EXPECTED"; then
    echo "run_check: stdout of $6 differs from $EXPECTED" >&2
    echo "--- expected" >&2; cat "$EXPECTED" >&2
    echo "--- actual" >&2; cat "$OUT" >&2
    exit 1
fi
