# test_deadline.sh -- runs the command of one `buck2 test` test under a time limit.
#
# usage: busybox sh test_deadline.sh <busybox> <limit_s> <timeout_s> <label> -- <command...>
#
# The command is gate_runner.sh, or mem_cap.sh around it (defs.bzl, a
# mojo_test). buck2's test runner gives a test action a timeout (its
# `--timeout`, 600 s by default), but when a remote executor stops an action
# at that timeout, buck2 reports the test as an ordinary failure with no word
# of the timeout, and the test's output is lost with the runner (seen on a
# remote executor: `Fail`, `Timeout 0`). test_limit.bzl therefore sets
# <limit_s> TEST_LIMIT_MARGIN_S seconds under that timeout (<timeout_s>, the
# root cell's `[komira] test_timeout_s`, used only in the message), and this
# script stops the test first.
#
# When the command has not exited after <limit_s> seconds, this script stops,
# then kills (SIGKILL), every process below the command whose executable is
# not <busybox>: the test binary and what it started, never the shells of
# gate_runner.sh and mem_cap.sh. gate_runner.sh therefore reports the test's
# death with its output (`GATED TEST FAILED: <label> (exit 137)`), and this
# script then prints
#   TEST TIME LIMIT: killed <label> after <limit_s> s, under the test runner's timeout of <timeout_s> s (komira.test_timeout_s)
# and exits with the command's status. Where /proc cannot be read (macOS), or
# when the command is still running 10 s after that kill, it kills the
# command's whole process group instead, and the runner's report is lost; the
# TEST TIME LIMIT line is still printed.
#
# The command leads a session (and process group) of its own. Once the
# command has exited, and on SIGHUP, SIGINT or SIGTERM, this script kills that
# group, so nothing the test left running outlives the action. SIGKILL cannot
# be caught: a tether in the command's session blocks reading a FIFO whose
# only writer is this script (fd 9), and when this script exits the read
# returns and the tether kills the session's process group (as mem_cap.sh).
#
# Exit status: the command's (137 for a test this script killed, through
# gate_runner.sh); 129, 130 or 143 when this script was signalled; 2 for a
# usage error, or when the timer could not run (the test ran unlimited).
set -eu

[ "$#" -ge 6 ] || { echo "test_deadline: usage error" >&2; exit 2; }
BB=$1
LIMIT=$2
TIMEOUT=$3
LABEL=$4
shift 4
[ "$1" = "--" ] || { echo "test_deadline: expected -- before the command" >&2; exit 2; }
shift
for n in "$LIMIT" "$TIMEOUT"; do
    case "$n" in
        "" | *[!0-9]* | 0*) echo "test_deadline: REFUSING: '$n' is not a positive whole number of seconds" >&2; exit 2 ;;
    esac
done
case "$BB" in /*) ;; *) BB=$PWD/$BB ;; esac
BB_EXE=$("$BB" readlink -f "$BB")

# below <root>: the processes below root (root excluded, found by parent
# pid) whose executable is not busybox, one per line, read from /proc;
# nothing where /proc cannot be read. The status files are read through cat,
# which goes on past a process that exited while it read.
below() {
    "$BB" cat /proc/[0-9]*/status 2> /dev/null | "$BB" awk -v root="$1" '
        $1 == "Pid:" { p = $2; n++; pid[n] = p }
        $1 == "PPid:" { par[p] = $2 }
        END {
            if (!(root in par)) exit
            in_[root] = 1
            do {
                grew = 0
                for (k = 1; k <= n; k++)
                    if (!(pid[k] in in_) && (par[pid[k]] in in_)) { in_[pid[k]] = 1; grew = 1 }
            } while (grew)
            for (q in in_) if (q != root) print q
        }' | while read -r q; do
        e=$("$BB" readlink -f "/proc/$q/exe" 2> /dev/null) || continue
        [ "$e" = "$BB_EXE" ] || echo "$q"
    done
}

T=$("$BB" mktemp -d "$PWD/.komira_test_deadline.XXXXXX")
trap '"$BB" rm -rf "$T"' EXIT
"$BB" mkfifo "$T/tether"
exec 9<> "$T/tether"
# As mem_cap.sh: the background job leads no group, so setsid makes a session
# without a fork and $! is the command's pid; the tether kills the group by
# the session leader's pid.
"$BB" setsid "$BB" sh -c '
    exec 8< "$2"
    g=$$
    { "$1" cat <&8; kill -s KILL "-$g"; } > /dev/null 2>&1 &
    exec 8<&-
    shift 2
    exec "$@"
' tether "$BB" "$T/tether" "$@" 9>&- &
pid=$!

# The timer: a subshell that reads the tether FIFO under `timeout`. The read
# returns (cat exits 0) when this script exits, however it exits, so the
# timer never outlives it; `timeout` stops the read after <limit_s> seconds
# (busybox exits 143 then; another `timeout` 124), and the timer kills the
# test. The 10 s grace after that kill waits the same way.
(
    exec 9>&-
    trc=0
    "$BB" timeout "$LIMIT" "$BB" cat < "$T/tether" || trc=$?
    case "$trc" in
        0) exit 0 ;;
        124 | 143) ;;
        *) : > "$T/timer_failed"; exit 0 ;;
    esac
    : > "$T/expired"
    victims=$(below "$pid")
    if [ -n "$victims" ]; then
        for q in $victims; do kill -s STOP "$q" 2> /dev/null || true; done
        for q in $victims; do kill -s KILL "$q" 2> /dev/null || true; done
        "$BB" timeout 10 "$BB" cat < "$T/tether" && exit 0
    fi
    kill -s KILL "-$pid" 2> /dev/null || true
) > /dev/null 2>&1 &
trap 'kill -s KILL "-$pid" 2> /dev/null || true; exit 129' HUP
trap 'kill -s KILL "-$pid" 2> /dev/null || true; exit 130' INT
trap 'kill -s KILL "-$pid" 2> /dev/null || true; exit 143' TERM
rc=0
wait "$pid" || rc=$?
# What is left in the command's group: a child that left its process tree,
# and the tether.
kill -s KILL "-$pid" 2> /dev/null || true
trap - HUP INT TERM
if [ -e "$T/expired" ]; then
    echo "TEST TIME LIMIT: killed $LABEL after $LIMIT s, under the test runner's timeout of $TIMEOUT s (komira.test_timeout_s)" >&2
elif [ -e "$T/timer_failed" ]; then
    echo "test_deadline: the timer of $LABEL failed, so the test ran without its limit of $LIMIT s" >&2
    exit 2
fi
exit "$rc"
