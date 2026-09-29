# run_check.sh -- runs a built binary inside a build action, through the
# command its RunInfo carries, and records its standard output. With an
# expected-output file, fails unless stdout matches it byte for byte.
#
# usage: busybox sh run_check.sh <busybox> <runnable binary> <out> [<expected>]
#
# <runnable binary> is the binary inside its runnable directory (next to
# lib/). This script sets no library path, and clears any it inherits, so a
# binary that cannot find its runtime libraries through its own run path
# fails here, as it would under `buck2 run`.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -ge 3 ] || { echo "run_check: usage error" >&2; exit 2; }
BB=$(abspath "$1")
BIN=$(abspath "$2")
OUT=$3
EXPECTED=${4:-}

T=$("$BB" mktemp -d "$PWD/.komira_run.XXXXXX")
trap '"$BB" rm -rf "$T"' EXIT
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
TMPDIR="$T/tmp"
HOME="$T/home"
export PATH TMPDIR HOME
unset LD_LIBRARY_PATH LD_PRELOAD || true

rc=0
"$BIN" > "$OUT" 2> "$T/err" < /dev/null || rc=$?
if [ "$rc" != 0 ]; then
    echo "run_check: $2 exited $rc" >&2
    tail -n 100 "$T/err" >&2
    exit 1
fi
if [ -n "$EXPECTED" ] && ! cmp -s "$OUT" "$EXPECTED"; then
    echo "run_check: stdout of $2 differs from $EXPECTED" >&2
    echo "--- expected" >&2; cat "$EXPECTED" >&2
    echo "--- actual" >&2; cat "$OUT" >&2
    exit 1
fi
