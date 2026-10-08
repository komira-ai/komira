# mut_step.sh -- runs one build step of one mutant and records how it ended,
# never failing the action (tools/build/mojo/mutation.bzl; the statuses are
# read by `mutate score`, mutate/score.mojo).
#
# usage: busybox sh mut_step.sh <busybox> <status> <limit_secs> \
#            [--after <status of a step this one waits for>]... -- <command...>
#
# A mutant's library that does not compile, or a test that fails, is a result
# here, not a broken build: the action exits 0 whatever the command did, and
# <status> says what happened. Its first line is one of
#
#   skipped          an --after status does not start with `ok`: the command
#                    did not run
#   ok               the command exited 0
#   timeout <secs>   the command was still running after <limit_secs> and was
#                    sent SIGTERM (the compiler wrapper and mem_cap.sh kill
#                    their whole process tree on it)
#   fail <status>    the command exited <status>, not 0
#
# and the last 60 lines of the command's output follow. Every `-o <path>` of
# the command that does not exist afterwards (the step failed or was skipped)
# is created empty, so the action's declared outputs exist and the steps
# that wait for this one read its status, not a missing file.
#
# Exit status: 0, or 2 for a usage error.
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
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
        --after)
            [ "$#" -ge 2 ] || { echo "mut_step: --after needs a status file" >&2; exit 2; }
            first=$("$BB" head -n 1 "$2")
            [ "$first" = ok ] || run=0
            shift 2
            ;;
        *) echo "mut_step: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ "$#" -ge 2 ] || { echo "mut_step: expected -- and a command" >&2; exit 2; }
shift

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

LOG=$("$BB" mktemp "$PWD/.mut_step.XXXXXX")
start=$("$BB" date +%s)
rc=0
"$BB" timeout -s TERM "$LIMIT" "$@" > "$LOG" 2>&1 < /dev/null || rc=$?
end=$("$BB" date +%s)
if [ "$rc" = 0 ]; then
    echo ok > "$STATUS"
elif [ $((end - start)) -ge "$LIMIT" ]; then
    echo "timeout $LIMIT" > "$STATUS"
else
    echo "fail $rc" > "$STATUS"
fi
"$BB" tail -n 60 "$LOG" >> "$STATUS"
"$BB" rm -f "$LOG"
ensure_outputs "$@"
exit 0
