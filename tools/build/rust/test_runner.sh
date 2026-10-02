# test_runner.sh -- runs one rust_test inside a build action.
#
# usage: busybox sh test_runner.sh <busybox> <label> <test_binary> <marker> \
#            <timeout seconds>
#
# <test_binary> is a libtest harness (`rustc --test`). On success writes
# `PASS <label>: <n> passed` to <marker> and to stdout. A gated
# rust_library or rust_binary is produced by an action that takes every
# marker as an input, so it cannot exist unless each of its tests passed
# (defs.bzl, `tests`). `buck2 test` runs this same script with /dev/null as
# the marker.
#
# The run, in order:
#   1. `--list` names every test. None is a refusal (EMPTY GATE): a gate that
#      runs nothing passes for any code.
#   2. Every test runs in one harness invocation. Any failure is red (GATED
#      TEST FAILED). The harness's own summary must count every listed test as
#      passed: an #[ignore]d test is refused, and a count that does not add up
#      is refused. There are no holds: every test must pass.
#
# NO VERDICT, in every run above: SIGKILL (exit 137), because a memory limit's
# kill is not the test's failure (tools/build/mojo/gate_runner.sh says why);
# and the timeout (exit 142), because each harness invocation runs under
# `busybox timeout -s ALRM <timeout seconds>`, and a hang is not a verdict
# either. The action fails, and the executor may retry it.
#
# The environment is fixed: the harness is started with `busybox env -i`, so
# it sees exactly PATH (busybox applets only), and TMPDIR and HOME (empty
# directories made for this run); its current directory is a third. Nothing
# in the action's environment (RUST_TEST_*, RUST_MIN_STACK, LD_PRELOAD) can
# reach it. A test reads nothing it did not compile in (include_str! of a file
# in `srcs`; README.md says how a file from another package gets there).
#
# Exit status: 0 on PASS; the harness's own status for a failed run (so a
# signal death, 128+N, stays distinguishable); 137 or 142 for NO VERDICT; 1
# for a refusal; 2 for a usage error.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -eq 5 ] || { echo "rust test_runner: usage error" >&2; exit 2; }
BB=$(abspath "$1")
LABEL=$2
BIN=$(abspath "$3")
MARKER=$4
TIMEOUT=$5
case "$TIMEOUT" in
    ''|*[!0-9]*|0) echo "rust test_runner: timeout must be a positive number of seconds, not '$TIMEOUT'" >&2; exit 2 ;;
esac

T=$("$BB" mktemp -d "$PWD/.komira_rust_test.XXXXXX")
trap '"$BB" rm -rf "$T"' EXIT
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home" "$T/cwd"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH
unset LD_LIBRARY_PATH LD_PRELOAD || true

# Runs the harness with `$@`, in its own directory and a scrubbed
# environment, under the timeout.
harness() {
    (cd "$T/cwd" && exec "$BB" env -i PATH="$T/bin" TMPDIR="$T/tmp" HOME="$T/home" \
        "$BB" timeout -s ALRM "$TIMEOUT" "$BIN" "$@") < /dev/null
}

# Exits NO VERDICT when `$1` (a harness exit status) is a kill, not a verdict.
no_verdict() {
    case "$1" in
        137)
            banner "NO VERDICT: $2 of $LABEL was killed by SIGKILL (exit 137)." >&2
            echo "  A memory limit's kill is not the test's failure; retry on a larger machine." >&2
            exit 137
            ;;
        142)
            banner "NO VERDICT: $2 of $LABEL timed out after ${TIMEOUT}s (exit 142)." >&2
            echo "  A hang is not the test's failure; find what it waits on, or raise \`test_timeout_s\`." >&2
            exit 142
            ;;
    esac
}

banner() {
    echo "=================================================================="
    echo "$1"
}

# 1. The listed tests.
rc=0
harness --list --format terse > "$T/list_raw" 2> "$T/list_err" || rc=$?
no_verdict "$rc" "listing the tests"
if [ "$rc" != 0 ]; then
    banner "GATED TEST FAILED: $LABEL: listing its tests exited $rc." >&2
    tail -n 50 "$T/list_err" >&2
    exit "$rc"
fi
sed -n 's/: test$//p' "$T/list_raw" > "$T/list"
listed=$(wc -l < "$T/list" | tr -d ' ')
if [ "$listed" = 0 ]; then
    banner "EMPTY GATE: $LABEL lists 0 tests. A gate that runs nothing passes for any code; give it a #[test], or drop it from \`tests\`." >&2
    exit 1
fi

# 2. Every test, in one run.
rc=0
harness > "$T/log" 2>&1 || rc=$?
no_verdict "$rc" "the tests"
if [ "$rc" != 0 ]; then
    banner "GATED TEST FAILED: $LABEL (exit $rc)" >&2
    tail -n 100 "$T/log" >&2
    exit "$rc"
fi
summary=$(grep -m1 '^test result: ok\.' "$T/log" || true)
passed=$(printf '%s\n' "$summary" | sed -n 's/^test result: ok\. \([0-9]*\) passed; \([0-9]*\) failed; \([0-9]*\) ignored;.*/\1/p')
ignored=$(printf '%s\n' "$summary" | sed -n 's/^test result: ok\. \([0-9]*\) passed; \([0-9]*\) failed; \([0-9]*\) ignored;.*/\3/p')
if [ -z "$passed" ]; then
    banner "GATED TEST FAILED: $LABEL: the harness exited 0 without a \`test result: ok.\` line." >&2
    tail -n 50 "$T/log" >&2
    exit 1
fi
if [ "$ignored" != 0 ]; then
    banner "REFUSED: $LABEL: $ignored #[ignore]d test(s) did not run. An ignored test is a mute; remove its #[ignore] and make it pass, or delete it." >&2
    grep ' \.\.\. ignored' "$T/log" >&2 || true
    exit 1
fi
if [ "$passed" != "$listed" ]; then
    banner "REFUSED: $LABEL: $listed tests listed, so $listed must pass; the harness reports $passed." >&2
    tail -n 50 "$T/log" >&2
    exit 1
fi

line=$(printf 'PASS %s: %s passed' "$LABEL" "$passed")
printf '%s\n' "$line" > "$MARKER"
printf '%s\n' "$line"
