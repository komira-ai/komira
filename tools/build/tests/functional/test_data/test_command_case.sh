# test_command_case.sh -- runs the command a mojo_test gives `buck2 test`
# (its ExternalRunnerTestInfo command: gate_runner.sh, the staged test, its
# --env and --arg options) inside a build action, and requires it to pass.
# Writes `ok <label>` to <report>.
#
# usage: busybox sh test_command_case.sh <busybox> <label> <report> -- <command...>
#
# The pull-request check builds; it does not run `buck2 test`. Built here, the
# test command, with every artifact its `args` name as an input of this
# action, gates a pull request the way a library's test_srcs do.
set -eu
[ "$#" -ge 5 ] && [ "$4" = -- ] || { echo "test_command_case: usage error" >&2; exit 2; }
LABEL=$2
REPORT=$3
shift 4
rc=0
"$@" || rc=$?
if [ "$rc" != 0 ]; then
    echo "test_command_case: the test command of $LABEL exited $rc" >&2
    exit 1
fi
printf 'ok %s\n' "$LABEL" > "$REPORT"
