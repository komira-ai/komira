# mem_cap.sh -- runs one test command under a memory cap.
#
# usage: busybox sh mem_cap.sh <busybox> <cap_mib> <label> -- <command...>
#
# The command is gate_runner.sh (defs.bzl). Every 0.1 s this script sums the
# resident memory (VmRSS) of the command's process tree: the command and its
# descendants by parent pid, read from /proc. When the sum exceeds <cap_mib>
# MiB it stops, then kills (SIGKILL), every descendant of the command, which
# leaves the command itself to report the test's death (gate_runner.sh:
# `GATED TEST FAILED: <label> (exit 137)` and the test's output), and then
# prints
#   MEMORY CAP: killed <label> at <n> MiB resident, over its cap of <cap_mib> MiB
# and exits with the command's status. A test that allocates without bound
# therefore fails instead of exhausting the worker's memory. No cgroup and no
# privilege: only /proc and signals to its own children.
#
# Resident memory, not address space: the Mojo runtime's allocator (tcmalloc)
# reserves address space in aligned 1 GiB regions at start, so an
# address-space limit (RLIMIT_AS, `ulimit -v`) of a few GiB aborts a test
# before its first line (measured on the farm), whatever the test itself uses.
# The cap is sampled: a test can pass it by what it allocates and touches in
# one interval before it is killed, and a process that leaves the tree (a
# daemon reparented away) is not counted.
#
# Exit status: the command's (137 for a test the cap killed, through
# gate_runner.sh); 2 for a usage error, or when it cannot read the process
# tree (the test is killed: it never runs uncapped). Linux only: on macOS
# there is no /proc, and a capped test is refused (exit 2).
set -eu

[ "$#" -ge 5 ] || { echo "mem_cap: usage error" >&2; exit 2; }
BB=$1
CAP=$2
LABEL=$3
shift 3
[ "$1" = "--" ] || { echo "mem_cap: expected -- before the command" >&2; exit 2; }
shift
case "$CAP" in
    "" | *[!0-9]* | 0*) echo "mem_cap: REFUSING: cap '$CAP' is not a positive whole number of MiB" >&2; exit 2 ;;
esac
[ -r /proc/self/status ] || { echo "mem_cap: REFUSING: no /proc here to read resident memory from; $LABEL would run uncapped" >&2; exit 2; }
CAP_KB=$((CAP * 1024))

# tree <root> [pids]: prints the summed VmRSS (KiB) of root and its
# descendants, or "gone" once root has exited (a zombie counts as exited);
# with `pids`, prints the descendants of root (root excluded), one per line.
# The status files are read through cat, which goes on past a process that
# exited while it read (awk would stop at that file).
tree() {
    "$BB" cat /proc/[0-9]*/status 2> /dev/null | "$BB" awk -v root="$1" -v mode="${2:-}" '
        $1 == "State:" { state = $2 }
        $1 == "Pid:" { p = $2; n++; pid[n] = p; st[p] = state; rss_of[p] = 0 }
        $1 == "PPid:" { par[p] = $2 }
        $1 == "VmRSS:" { rss_of[p] = $2 }
        END {
            if (!(root in par) || st[root] == "Z") { if (mode != "pids") print "gone"; exit }
            in_[root] = 1
            do {
                grew = 0
                for (k = 1; k <= n; k++)
                    if (!(pid[k] in in_) && (par[pid[k]] in in_)) { in_[pid[k]] = 1; grew = 1 }
            } while (grew)
            if (mode == "pids") { for (q in in_) if (q != root && q + 0 > 1) print q; exit }
            tot = 0
            for (q in in_) tot += rss_of[q]
            print tot
        }'
}

kill_below() {
    # Stop every descendant first, so none starts another; then kill the
    # frozen list.
    for q in $(tree "$1" pids); do kill -s STOP "$q" 2> /dev/null || true; done
    for q in $(tree "$1" pids); do kill -s KILL "$q" 2> /dev/null || true; done
}

"$@" &
pid=$!
trap 'kill_below "$pid"; kill -s KILL "$pid" 2> /dev/null; exit 143' HUP INT TERM
killed=""
unread=0
while :; do
    s=$(tree "$pid") || s=""
    case "$s" in
        gone) break ;;
        "")
            # No reading: a failure of cat or awk. Three in a row end the run
            # rather than leave it uncapped.
            unread=$((unread + 1))
            if [ "$unread" -ge 3 ]; then
                kill_below "$pid"
                kill -s KILL "$pid" 2> /dev/null || true
                wait "$pid" 2> /dev/null || true
                echo "mem_cap: cannot read the process tree of $LABEL from /proc; killed it rather than run it uncapped" >&2
                exit 2
            fi
            "$BB" sleep 0.1
            continue
            ;;
    esac
    unread=0
    if [ "$s" -gt "$CAP_KB" ]; then
        kill_below "$pid"
        killed=$((s / 1024))
        break
    fi
    "$BB" sleep 0.1
done
rc=0
wait "$pid" || rc=$?
trap - HUP INT TERM
if [ -n "$killed" ]; then
    echo "MEMORY CAP: killed $LABEL at $killed MiB resident, over its cap of $CAP MiB" >&2
fi
exit "$rc"
