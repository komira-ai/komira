# gate_runner.sh -- runs one gated test inside a build action.
#
# usage: busybox sh gate_runner.sh <busybox> <compiler_dir> <label> <test_binary> <marker>
#
# On success writes `PASS <label>` to <marker>. The library's public package is
# produced by an action that takes every marker as an input, so the package
# cannot exist unless each of its tests passed.
#
# The test runs with a fixed environment: PATH holds only busybox applets,
# LD_LIBRARY_PATH points at the toolchain's runtime libraries (a linked
# binary's run path names the sandbox of the action that linked it, so it
# does not resolve here), and TMPDIR, TEST_TMPDIR and HOME are private.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" = 5 ] || { echo "gate_runner: usage error" >&2; exit 2; }
BB=$(abspath "$1")
TC=$(abspath "$2")
LABEL=$3
BIN=$(abspath "$4")
MARKER=$5

T="$PWD/.komira_action"
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
if [ "$rc" = 0 ]; then
    printf 'PASS %s\n' "$LABEL" > "$MARKER"
    rm -rf "$T"
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
rm -rf "$T"
exit 1
