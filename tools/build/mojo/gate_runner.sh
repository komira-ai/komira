# gate_runner.sh -- runs one gated test inside a build action.
#
# usage: busybox sh gate_runner.sh <busybox> <compiler_dir> <label> <test_binary> <marker> \
#            [--env NAME=VALUE]...
#
# On success writes `PASS <label>` to <marker>. The library's public package is
# produced by an action that takes every marker as an input, so the package
# cannot exist unless each of its tests passed.
#
# <test_binary> is `<root>/bin/<name>` in the test's staged tree (defs.bzl,
# _test_root): <root>/share holds exactly the test's declared data. The test
# runs with <root>/share as its current directory (an empty directory when
# nothing is declared), so a relative path reaches a declared file and nothing
# else -- not the action's other inputs, not the repository.
#
# The environment is fixed: PATH holds only busybox applets, LD_LIBRARY_PATH
# points at the toolchain's runtime libraries (built binaries carry no run
# path that reaches them from bin/), and TMPDIR = TEST_TMPDIR and HOME are two
# empty directories made for this run under the action's own working
# directory, so no two runs share them. Each --env adds one variable; the rule
# refuses the names above and this script refuses them again. A --env variable
# is given to the TEST PROCESS ONLY (exported in the subshell that execs it), never
# to this script's own shell: exported here it would reach the variables the
# verdict is computed from (BIN, MARKER, LABEL, ...), so
# `test_env = {"BIN": "true"}` would run `true` in place of the test.
#
# Exit status: 0 on PASS; otherwise the test's own exit status (so a signal
# death, 128+N, stays distinguishable from an assertion failure); 2 for a
# usage error. The compile watchdog's 124 is the compiler's action
# (mojo_wrapper.sh), not this one; a test's own exit 124 is its own verdict.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -ge 5 ] || { echo "gate_runner: usage error" >&2; exit 2; }
BB=$(abspath "$1")
TC=$(abspath "$2")
LABEL=$3
BIN=$(abspath "$4")
MARKER=$5
shift 5
ROOT=${BIN%/bin/*}
[ "$ROOT" != "$BIN" ] || { echo "gate_runner: $BIN is not <root>/bin/<name>" >&2; exit 2; }

T=$("$BB" mktemp -d "$PWD/.komira_test.XXXXXX")
trap '"$BB" rm -rf "$T"' EXIT
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home" "$T/share"
"$BB" --install -s "$T/bin"

# Each --env NAME=VALUE is moved to the end of "$@"; once the loop has consumed
# the other options, "$@" holds exactly the test's variables.
n=$#
while [ "$n" -gt 0 ]; do
    case "$1" in
        --env)
            [ "$n" -ge 2 ] || { echo "gate_runner: --env needs NAME=VALUE" >&2; exit 2; }
            name=${2%%=*}
            case "$name" in
                "$2" | "" | [0-9]* | *[!A-Za-z0-9_]*)
                    echo "gate_runner: --env $2 is not NAME=VALUE" >&2; exit 2 ;;
                PATH | LD_LIBRARY_PATH | LD_PRELOAD | DYLD_LIBRARY_PATH | DYLD_FALLBACK_LIBRARY_PATH | DYLD_INSERT_LIBRARIES | TMPDIR | TEST_TMPDIR | HOME | PWD)
                    echo "gate_runner: --env may not set $name; the runner sets it" >&2; exit 2 ;;
            esac
            set -- "$@" "$2"
            shift 2
            n=$((n - 2))
            ;;
        *) echo "gate_runner: unknown argument $1" >&2; exit 2 ;;
    esac
done

# The staged share/, or an empty one: never the action's own directory.
CWD="$T/share"
[ -d "$ROOT/share" ] && CWD="$ROOT/share"

PATH="$T/bin"
LD_LIBRARY_PATH="$TC/lib"
TMPDIR="$T/tmp"
TEST_TMPDIR="$T/tmp"
HOME="$T/home"
export PATH LD_LIBRARY_PATH TMPDIR TEST_TMPDIR HOME

rc=0
# The test's variables are exported by this shell, in the subshell that execs the
# test, and not given through the `env` applet: on macOS that applet is a
# system-integrity-protected binary, and dyld prunes every DYLD_* variable from
# the environment of such a process, so a test started through it never sees
# DYLD_LIBRARY_PATH and cannot find its runtime library. Nothing between this
# shell and the test may be such a binary. (The names were checked above.)
#
# Nothing the subshell does after its first export may expand a variable: an
# exported NAME=VALUE replaces a shell variable of that name, so `--env BIN=x`
# would run x in place of the test. The subshell reads only its positional
# parameters, which no environment variable can set: the test is appended to
# "$@", each leading NAME=VALUE is exported and shifted off, and what is left
# is the test, exec'd as "$1". (export, shift, exec and [ are builtins, found
# without PATH.) The variables the verdict is computed from (rc, MARKER,
# LABEL, T, BIN, CWD, ...) are read only by this shell, which exports nothing.
set -- "$@" "$BIN"
# shellcheck disable=SC2163 # each "$1" is NAME=VALUE: the value is exported, not a variable named by it
(cd "$CWD" && while [ "$#" -gt 1 ]; do export "$1" && shift; done && exec "$1") > "$T/log" 2>&1 < /dev/null || rc=$?
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
