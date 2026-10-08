# mut_step.sh -- runs one build step of one mutant and records how it ended
# (tools/build/mojo/mutation.bzl; the statuses are read by `mutate score`,
# mutate/score.mojo).
#
# usage: busybox sh mut_step.sh <busybox> <status> <limit_secs> \
#            [--after <status of a step this one waits for>]... \
#            [--infra-exit <n>]... -- <command...>
#
# A mutant's library that does not compile, or a test that fails, is a result
# here, not a broken build: the action exits 0 and <status> says what
# happened. Its first line is one of
#
#   skipped          an --after status does not start with `ok`: the command
#                    did not run
#   ok               the command exited 0
#   timeout <secs>   the command was still running after <limit_secs>: its
#                    whole process group was sent SIGTERM, then SIGKILL
#   fail <status>    the command exited <status>, not 0, within its limit
#
# and the last 60 lines of the command's output follow.
#
# Not a result: an exit status named by --infra-exit (the compile wrapper's
# watchdog, 124, and its refusals and signals) when the step did not time
# out. That is a failure of the machine the step ran on, not of the mutant,
# so this script fails the action with that status, the build fails and
# nothing is cached; a rerun retries it.
#
# The command runs in a session of its own (setsid), so the timeout reaches
# every process it started. Each argument of the command that starts with
# @MUT_SCRATCH@ has that prefix replaced by a directory private to this run
# (in buck2's per-action scratch directory, BUCK_SCRATCH_PATH): a file the
# command must write that is no output of the action (the gate runner's
# PASS marker) goes there, and so does the command's log. Every `-o <path>`
# of the command that does not exist afterwards (the step failed or was
# skipped) is created empty, so the action's declared outputs exist and the
# steps that wait for this one read its status, not a missing file.
#
# Exit status: 0; an --infra-exit status; 2 for a usage error.
set -eu

[ "$#" -ge 4 ] || { echo "mut_step: usage error" >&2; exit 2; }
BB=$1
STATUS=$2
LIMIT=$3
shift 3
case "$LIMIT" in
    "" | *[!0-9]* | 0*) echo "mut_step: limit '$LIMIT' is not a positive number of seconds" >&2; exit 2 ;;
esac

run=1
INFRA=" "
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
        --after)
            [ "$#" -ge 2 ] || { echo "mut_step: --after needs a status file" >&2; exit 2; }
            first=$("$BB" head -n 1 "$2")
            [ "$first" = ok ] || run=0
            shift 2
            ;;
        --infra-exit)
            [ "$#" -ge 2 ] || { echo "mut_step: --infra-exit needs a status" >&2; exit 2; }
            case "$2" in "" | *[!0-9]*) echo "mut_step: --infra-exit $2 is not a status" >&2; exit 2 ;; esac
            INFRA="$INFRA$2 "
            shift 2
            ;;
        *) echo "mut_step: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ "$#" -ge 2 ] || { echo "mut_step: expected -- and a command" >&2; exit 2; }
shift

case "${BUCK_SCRATCH_PATH:-}" in
    "") S=$("$BB" mktemp -d "$PWD/.mut_step.XXXXXX") ;;
    /*) S="$BUCK_SCRATCH_PATH/mut_step" ;;
    *) S="$PWD/$BUCK_SCRATCH_PATH/mut_step" ;;
esac
"$BB" mkdir -p "$S"

# Replace the @MUT_SCRATCH@ prefix in place: each argument is moved to the end.
n=$#
while [ "$n" -gt 0 ]; do
    case "$1" in
        @MUT_SCRATCH@*) set -- "$@" "$S${1#@MUT_SCRATCH@}" ;;
        *) set -- "$@" "$1" ;;
    esac
    shift
    n=$((n - 1))
done

ensure_outputs() {
    prev=
    for a in "$@"; do
        if [ "$prev" = "-o" ] && [ ! -e "$a" ]; then
            "$BB" mkdir -p "$("$BB" dirname "$a")"
            : > "$a"
        fi
        prev=$a
    done
}

if [ "$run" = 0 ]; then
    echo skipped > "$STATUS"
    ensure_outputs "$@"
    exit 0
fi

LOG="$S/log"
# The command's own session: its pid is its process group's id.
("$BB" setsid "$@" > "$LOG" 2>&1 < /dev/null & echo $! > "$S/pid"; wait $! && echo 0 > "$S/rc" || echo $? > "$S/rc") &
while [ ! -s "$S/pid" ]; do "$BB" sleep 0.1; done
pid=$("$BB" cat "$S/pid")
waited=0
timed_out=0
while [ ! -s "$S/rc" ]; do
    if [ "$waited" -ge "$((LIMIT * 10))" ]; then
        timed_out=1
        "$BB" kill -TERM -- "-$pid" 2>/dev/null || true
        "$BB" sleep 2
        "$BB" kill -KILL -- "-$pid" 2>/dev/null || true
        break
    fi
    "$BB" sleep 0.1
    waited=$((waited + 1))
done
wait || true
rc=$("$BB" cat "$S/rc" 2>/dev/null || echo 137)
[ -n "$rc" ] || rc=137

if [ "$timed_out" = 1 ]; then
    echo "timeout $LIMIT" > "$STATUS"
elif [ "$rc" = 0 ]; then
    echo ok > "$STATUS"
else
    case "$INFRA" in
        *" $rc "*)
            echo "mut_step: the step exited $rc, a failure of the machine it ran on, not of the mutant; failing the action so that it is not cached" >&2
            "$BB" tail -n 60 "$LOG" >&2
            exit "$rc"
            ;;
    esac
    echo "fail $rc" > "$STATUS"
fi
"$BB" tail -n 60 "$LOG" >> "$STATUS"
ensure_outputs "$@"
exit 0
