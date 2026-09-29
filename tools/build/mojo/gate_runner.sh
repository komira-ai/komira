# gate_runner.sh -- runs one gated test inside a build action.
#
# usage: busybox sh gate_runner.sh <busybox> <compiler_dir> <label> <test_binary> <marker> \
#            [<held entry> <issue> <reason>]
#
# On success writes `PASS <label>` to <marker>. The library's public package is
# produced by an action that takes every marker as an input, so the package
# cannot exist unless each of its tests passed.
#
# The test runs with a fixed environment: PATH holds only busybox applets,
# LD_LIBRARY_PATH points at the toolchain's runtime libraries (built binaries
# carry no run path), and TMPDIR, TEST_TMPDIR and HOME are a private directory
# made for this run.
#
# With the last three arguments the test is HELD (mojo_library's
# `tests_known_failing` row <held entry>) and the verdict inverts: the test
# still runs, a FAILURE (any non-zero exit, a signal death included) writes
# `HELD <label>` and exits 0, and a PASS is red (exit 1, LEDGER STALE), naming
# the row to delete. The marker's bytes never depend on the run.
#
# Exit status: 0 on PASS (or a held test's failure); otherwise the test's own exit status (so a signal
# death, 128+N, stays distinguishable from an assertion failure); 2 for a
# usage error.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" = 5 ] || [ "$#" = 8 ] || { echo "gate_runner: usage error" >&2; exit 2; }
BB=$(abspath "$1")
TC=$(abspath "$2")
LABEL=$3
BIN=$(abspath "$4")
MARKER=$5

T=$("$BB" mktemp -d "$PWD/.komira_test.XXXXXX")
trap '"$BB" rm -rf "$T"' EXIT
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
LD_LIBRARY_PATH="$TC/lib"
TMPDIR="$T/tmp"
TEST_TMPDIR="$T/tmp"
HOME="$T/home"
export PATH LD_LIBRARY_PATH TMPDIR TEST_TMPDIR HOME

rc=0
"$BIN" > "$T/log" 2>&1 < /dev/null || rc=$?
if [ "$#" = 8 ]; then
    if [ "$rc" != 0 ]; then
        printf 'HELD %s\n' "$LABEL" > "$MARKER"
        exit 0
    fi
    {
        echo "=================================================================="
        echo "LEDGER STALE: $LABEL PASSED, but it is held as known-failing."
        echo "  row:    tests_known_failing[\"$6\"]"
        echo "  issue:  $7"
        echo "  reason: $8"
        echo "Delete that row from the library's tests_known_failing (and close"
        echo "or update the issue). A held test must fail; one that passes is"
        echo "good news the ledger has to record by shrinking."
        echo "------------------------------------------------------------------ output"
        tail -n 50 "$T/log"
        echo "=================================================================="
    } >&2
    exit 1
fi
if [ "$rc" = 0 ]; then
    printf 'PASS %s\n' "$LABEL" > "$MARKER"
    exit 0
fi
{
    echo "=================================================================="
    echo "GATED TEST FAILED: $LABEL (exit $rc)"
    echo "The library's package is not produced until this test passes."
    echo "------------------------------------------------------------------ output"
    tail -n 200 "$T/log"
    echo "=================================================================="
} >&2
exit "$rc"
