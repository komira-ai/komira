# test_runner.sh -- runs one rust_test inside a build action.
#
# usage: busybox sh test_runner.sh <busybox> <label> <test_binary> <marker> \
#            [--hold <test name> <issue> <reason>]...
#
# <test_binary> is a libtest harness (`rustc --test`). On success writes
# `PASS <label>: <n> passed[, <h> held]` to <marker>. A gated rust_library or
# rust_binary is produced by an action that takes every marker as an input,
# so it cannot exist unless each of its tests passed (defs.bzl, `tests`).
#
# The run, in order:
#   1. `--list` names every test. None is a refusal (EMPTY GATE): a gate that
#      runs nothing passes for any code.
#   2. Each --hold must name a listed test (else LEDGER STALE), and not every
#      test may be held.
#   3. The unheld tests run in one harness invocation (`--exact --skip <held>`).
#      Any failure is red (GATED TEST FAILED). The harness's own summary must
#      count every unheld test as passed: an #[ignore]d test is refused, and a
#      count that does not add up is refused.
#   4. Each held test runs alone (`--exact <name>`) and must FAIL. A pass is red
#      (LEDGER STALE), naming the row to delete. SIGKILL (exit 137) is NO
#      VERDICT: a memory limit's kill is not the test's failure
#      (tools/build/mojo/gate_runner.sh says why), so the action fails and the
#      executor may retry it.
#
# The environment is fixed: PATH holds only busybox applets, TMPDIR and HOME
# are empty directories made for this run, the current directory is a third,
# and LD_LIBRARY_PATH and LD_PRELOAD are unset. A test reads nothing it did not
# compile in (include_str! of a file in `srcs`; README.md says how a file
# from another package gets there).
#
# Exit status: 0 on PASS; the harness's own status for a failed run (so a
# signal death, 128+N, stays distinguishable); 1 for a refusal; 2 for a usage
# error.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -ge 4 ] || { echo "rust test_runner: usage error" >&2; exit 2; }
BB=$(abspath "$1")
LABEL=$2
BIN=$(abspath "$3")
MARKER=$4
shift 4

T=$("$BB" mktemp -d "$PWD/.komira_rust_test.XXXXXX")
trap '"$BB" rm -rf "$T"' EXIT
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home" "$T/cwd"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
TMPDIR="$T/tmp"
HOME="$T/home"
export PATH TMPDIR HOME
unset LD_LIBRARY_PATH LD_PRELOAD RUST_TEST_THREADS RUST_BACKTRACE || true

# Held rows, one per line: name, then issue and reason in parallel files.
: > "$T/held"
: > "$T/held_issue"
: > "$T/held_reason"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --hold)
            [ "$#" -ge 4 ] || { echo "rust test_runner: --hold needs <name> <issue> <reason>" >&2; exit 2; }
            printf '%s\n' "$2" >> "$T/held"
            printf '%s\n' "$3" >> "$T/held_issue"
            printf '%s\n' "$4" >> "$T/held_reason"
            shift 4
            ;;
        *) echo "rust test_runner: unknown argument $1" >&2; exit 2 ;;
    esac
done

banner() {
    echo "=================================================================="
    echo "$1"
}

# 1. The listed tests.
rc=0
(cd "$T/cwd" && exec "$BIN" --list --format terse) > "$T/list_raw" 2> "$T/list_err" < /dev/null || rc=$?
if [ "$rc" != 0 ]; then
    banner "GATED TEST FAILED: $LABEL: listing its tests exited $rc." >&2
    tail -n 50 "$T/list_err" >&2
    exit "$rc"
fi
sed -n 's/: test$//p' "$T/list_raw" > "$T/list"
listed=$(wc -l < "$T/list" | tr -d ' ')
held=$(wc -l < "$T/held" | tr -d ' ')
if [ "$listed" = 0 ]; then
    banner "EMPTY GATE: $LABEL lists 0 tests. A gate that runs nothing passes for any code; give it a #[test], or drop it from \`tests\`." >&2
    exit 1
fi

# 2. Each hold names a listed test.
while IFS= read -r name; do
    if ! grep -qxF -- "$name" "$T/list"; then
        banner "LEDGER STALE: $LABEL: tests_known_failing[\"$name\"] names no test of this target." >&2
        echo "  The test was renamed or deleted; fix the row's name, or delete the row." >&2
        exit 1
    fi
done < "$T/held"
if [ "$held" -ge "$listed" ]; then
    banner "REFUSED: $LABEL holds all $listed tests. That gate asserts nothing passes." >&2
    exit 1
fi

# 3. The unheld tests, in one run.
set -- --exact
while IFS= read -r name; do
    set -- "$@" --skip "$name"
done < "$T/held"
rc=0
(cd "$T/cwd" && exec "$BIN" "$@") > "$T/log" 2>&1 < /dev/null || rc=$?
if [ "$rc" != 0 ]; then
    banner "GATED TEST FAILED: $LABEL (exit $rc)" >&2
    tail -n 100 "$T/log" >&2
    exit "$rc"
fi
want=$((listed - held))
summary=$(grep -m1 '^test result: ok\.' "$T/log" || true)
passed=$(printf '%s\n' "$summary" | sed -n 's/^test result: ok\. \([0-9]*\) passed; \([0-9]*\) failed; \([0-9]*\) ignored;.*/\1/p')
ignored=$(printf '%s\n' "$summary" | sed -n 's/^test result: ok\. \([0-9]*\) passed; \([0-9]*\) failed; \([0-9]*\) ignored;.*/\3/p')
if [ -z "$passed" ]; then
    banner "GATED TEST FAILED: $LABEL: the harness exited 0 without a \`test result: ok.\` line." >&2
    tail -n 50 "$T/log" >&2
    exit 1
fi
if [ "$ignored" != 0 ]; then
    banner "REFUSED: $LABEL: $ignored #[ignore]d test(s) did not run. An ignored test is a mute; hold it in tests_known_failing (it must then fail) or delete it." >&2
    grep ' \.\.\. ignored' "$T/log" >&2 || true
    exit 1
fi
if [ "$passed" != "$want" ]; then
    banner "REFUSED: $LABEL: $listed tests listed, $held held, so $want must pass; the harness reports $passed." >&2
    tail -n 50 "$T/log" >&2
    exit 1
fi

# 4. Each held test runs alone and must fail.
i=0
while IFS= read -r name; do
    i=$((i + 1))
    issue=$(sed -n "${i}p" "$T/held_issue")
    reason=$(sed -n "${i}p" "$T/held_reason")
    rc=0
    (cd "$T/cwd" && exec "$BIN" --exact "$name") > "$T/held_log" 2>&1 < /dev/null || rc=$?
    if [ "$rc" = 137 ]; then
        banner "NO VERDICT: held test $name of $LABEL was killed by SIGKILL (exit 137)." >&2
        echo "  A memory limit's kill is not the test's failure; retry on a larger machine." >&2
        exit 137
    fi
    if [ "$rc" = 0 ]; then
        banner "LEDGER STALE: held test $name of $LABEL PASSES." >&2
        echo "  row:    tests_known_failing[\"$name\"]" >&2
        echo "  issue:  $issue" >&2
        echo "  reason: $reason" >&2
        echo "  The test is fixed: delete the row, and close the issue if nothing else holds it." >&2
        exit 1
    fi
done < "$T/held"

if [ "$held" = 0 ]; then
    printf 'PASS %s: %s passed\n' "$LABEL" "$passed" > "$MARKER"
else
    printf 'PASS %s: %s passed, %s held (each failing, as its row records)\n' "$LABEL" "$passed" "$held" > "$MARKER"
fi
