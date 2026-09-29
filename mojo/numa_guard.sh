# numa_guard.sh -- refuses to start a command unless this process can use at
# least N NUMA nodes, then runs it in its own place (exec).
#
# usage: busybox sh numa_guard.sh <busybox> <min nodes> [--root <dir>] -- <command...>
#
# The constraint label an execution platform carries is only a claim about the
# worker behind it. This reads what the action actually got. A node counts
# when it is
#   - online           (/sys/devices/system/node/online),
#   - has memory       (/sys/devices/system/node/has_memory),
#   - in this process's Mems_allowed_list  (/proc/<pid>/status), and
#   - holds at least one CPU in its Cpus_allowed_list
#                      (/sys/devices/system/node/node<N>/cpulist),
# so a cpuset, a CPU affinity mask or a memory binding that narrows a
# multi-node host to one node is refused too. A file that cannot be read is a
# refusal, never a pass: "cannot tell" is not "enough nodes".
#
# `--root <dir>` reads <dir>/sys/... and <dir>/proc/self/status instead, for
# the check that exercises this script on made-up topologies.
#
# Exit status: the command's own, or 3 when refused, 2 for a usage error.
set -eu

usage() { echo "numa_guard: usage error" >&2; exit 2; }

[ "$#" -ge 3 ] || usage
case "$1" in /*) BB=$1 ;; *) BB=$PWD/$1 ;; esac
MIN=$2
shift 2
case "$MIN" in '' | *[!0-9]*) usage ;; esac
SYS=/sys
STATUS=/proc/$$/status
if [ "$1" = --root ]; then
    [ "$#" -ge 2 ] || usage
    SYS=$2/sys
    STATUS=$2/proc/self/status
    shift 2
fi
[ "$#" -ge 2 ] && [ "$1" = -- ] || usage
shift

NODES=$SYS/devices/system/node

refuse() {
    echo "numa_guard: REFUSING to run: $*" >&2
    echo "numa_guard: this run needs at least $MIN NUMA nodes it can use (online, with memory, in Mems_allowed_list, and holding a CPU in Cpus_allowed_list); the execution platform it was scheduled on does not provide them" >&2
    exit 3
}

# Prints one number per line for a kernel list such as `0-3,8,10-11`.
expand() {
    printf '%s\n' "$1" | "$BB" awk -F, '{
        for (i = 1; i <= NF; i++) {
            if ($i == "") continue
            n = split($i, r, "-")
            if (n == 1) r[2] = r[1]
            if (r[1] !~ /^[0-9]+$/ || r[2] !~ /^[0-9]+$/) { print "BAD"; exit }
            for (c = r[1] + 0; c <= r[2] + 0; c++) print c
        }
    }'
}

# in_list <number> <kernel list>
in_list() {
    expand "$2" | "$BB" grep -qx "$1"
}

read_one() { # <file>: its first line, or refuse
    [ -r "$1" ] || refuse "cannot read $1"
    "$BB" head -n 1 "$1"
}

status_field() { # <name>
    [ -r "$STATUS" ] || refuse "cannot read $STATUS"
    v=$("$BB" awk -F':[ \t]*' -v k="$1" '$1 == k { print $2; exit }' "$STATUS")
    [ -n "$v" ] || refuse "no $1 in $STATUS"
    printf '%s\n' "$v"
}

online=$(read_one "$NODES/online")
has_memory=$(read_one "$NODES/has_memory")
mems=$(status_field Mems_allowed_list)
cpus=$(status_field Cpus_allowed_list)
for l in "$online" "$has_memory" "$mems" "$cpus"; do
    if expand "$l" | "$BB" grep -qx BAD; then refuse "cannot parse node or CPU list '$l'"; fi
done

usable=""
count=0
for n in $(expand "$online"); do
    in_list "$n" "$has_memory" || continue
    in_list "$n" "$mems" || continue
    node_cpus=$(read_one "$NODES/node$n/cpulist")
    hit=0
    for c in $(expand "$node_cpus"); do
        if in_list "$c" "$cpus"; then hit=1; break; fi
    done
    [ "$hit" = 1 ] || continue
    usable="$usable $n"
    count=$((count + 1))
done

if [ "$count" -lt "$MIN" ]; then
    refuse "usable NUMA nodes [${usable# }] (online $online, has_memory $has_memory, Mems_allowed_list $mems, Cpus_allowed_list $cpus)"
fi
echo "numa_guard: $count usable NUMA nodes [${usable# }]" >&2
exec "$@"
