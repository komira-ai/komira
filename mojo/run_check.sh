# run_check.sh -- runs a built binary inside a build action and records its
# standard output. With an expected-output file, fails unless stdout matches
# it byte for byte.
#
# usage: busybox sh run_check.sh <busybox> <compiler_dir> <binary> <out> [<expected>]
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

BB=$(abspath "$1")
TC=$(abspath "$2")
BIN=$(abspath "$3")
OUT=$4
EXPECTED=${5:-}

T="$PWD/.komira_action"
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
LD_LIBRARY_PATH="$TC/lib"
TMPDIR="$T/tmp"
HOME="$T/home"
export PATH LD_LIBRARY_PATH TMPDIR HOME

rc=0
"$BIN" > "$OUT" 2> "$T/err" < /dev/null || rc=$?
if [ "$rc" != 0 ]; then
    echo "run_check: $3 exited $rc" >&2
    tail -n 100 "$T/err" >&2
    exit 1
fi
if [ -n "$EXPECTED" ] && ! cmp -s "$OUT" "$EXPECTED"; then
    echo "run_check: stdout of $3 differs from $EXPECTED" >&2
    echo "--- expected" >&2; cat "$EXPECTED" >&2
    echo "--- actual" >&2; cat "$OUT" >&2
    exit 1
fi
rm -rf "$T"
