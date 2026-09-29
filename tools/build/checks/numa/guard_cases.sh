# guard_cases.sh -- runs tools/build/mojo/numa_guard.sh against made-up NUMA
# topologies and requires each verdict. Writes one line per case to <report>; exits 1 if
# any case got the wrong verdict.
#
# usage: busybox sh guard_cases.sh <busybox> <numa_guard.sh> <report>
set -eu
case "$1" in /*) BB=$1 ;; *) BB=$PWD/$1 ;; esac
case "$2" in /*) GUARD=$2 ;; *) GUARD=$PWD/$2 ;; esac
REPORT=$3
D=$PWD/.komira_numa_cases
"$BB" rm -rf "$D"
"$BB" mkdir -p "$D"
bad=0

# topo <name> <online> <has_memory> <Mems_allowed_list> <Cpus_allowed_list> <node:cpulist>...
topo() {
    r=$D/$1
    "$BB" mkdir -p "$r/sys/devices/system/node" "$r/proc/self"
    printf '%s\n' "$2" > "$r/sys/devices/system/node/online"
    printf '%s\n' "$3" > "$r/sys/devices/system/node/has_memory"
    printf 'Name:\tsh\nCpus_allowed:\tff\nCpus_allowed_list:\t%s\nMems_allowed:\t3\nMems_allowed_list:\t%s\n' "$5" "$4" > "$r/proc/self/status"
    shift 5
    for nc in "$@"; do
        "$BB" mkdir -p "$r/sys/devices/system/node/node${nc%%:*}"
        printf '%s\n' "${nc#*:}" > "$r/sys/devices/system/node/node${nc%%:*}/cpulist"
    done
}

# expect <name> <min nodes> run|refuse
expect() {
    rc=0
    "$BB" sh "$GUARD" "$BB" "$2" --root "$D/$1" -- "$BB" sh -c 'echo ran' > "$D/$1.out" 2> "$D/$1.err" || rc=$?
    got=refuse
    if [ "$rc" = 0 ] && "$BB" grep -qx ran "$D/$1.out"; then got=run; fi
    if [ "$got" = refuse ] && [ "$rc" != 3 ]; then got="rc$rc"; fi
    if [ "$got" = "$3" ]; then
        echo "ok   $1 min=$2 $got" >> "$REPORT"
    else
        echo "BAD  $1 min=$2 expected $3, got $got: $("$BB" tr '\n' ' ' < "$D/$1.err")" >> "$REPORT"
        bad=1
    fi
}

: > "$REPORT"
topo two_nodes          0-1 0-1 0-1 0-15      0:0-7 1:8-15
expect two_nodes 2 run
topo one_node           0   0   0   0-15      0:0-15
expect one_node 2 refuse
topo membind_one        0-1 0-1 0   0-15      0:0-7 1:8-15
expect membind_one 2 refuse
topo cpuset_one         0-1 0-1 0-1 0-7       0:0-7 1:8-15
expect cpuset_one 2 refuse
topo cpus_split_list    0-1 0-1 0-1 3,12      0:0-7 1:8-15
expect cpus_split_list 2 run
topo memoryless_node    0-1 0   0-1 0-15      0:0-7 1:8-15
expect memoryless_node 2 refuse
topo offline_node       0   0-1 0-1 0-15      0:0-7 1:8-15
expect offline_node 2 refuse
topo three_nodes        0-2 0-2 0-2 0-23      0:0-7 1:8-15 2:16-23
expect three_nodes 3 run
topo three_one_narrowed 0-2 0-2 0-1 0-23      0:0-7 1:8-15 2:16-23
expect three_one_narrowed 3 refuse
topo no_node_cpulist    0-1 0-1 0-1 0-15      0:0-7
expect no_node_cpulist 2 refuse
topo garbage_list       0-x 0-1 0-1 0-15      0:0-7 1:8-15
expect garbage_list 2 refuse
"$BB" mkdir -p "$D/no_sysfs/proc/self"
expect no_sysfs 2 refuse

"$BB" rm -rf "$D"
if [ "$bad" != 0 ]; then
    "$BB" grep '^BAD ' "$REPORT" >&2
    exit 1
fi
