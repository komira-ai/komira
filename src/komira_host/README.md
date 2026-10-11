# komira_host

What the host looks like: cgroup-aware CPU topology, memory and hugepage probes, worker placement.

The package is four modules, each imported by name (the package root
re-exports nothing):

| module | what it answers |
|---|---|
| `komira_host.engine_placement` | `EnginePlacement`, the policy for pinning worker threads, as one plain value |
| `komira_host.cpu_topology` | which CPUs the process may use (cpuset- and cgroup-aware), split into compute and IO lanes, with NUMA nodes, and the thread-pinning calls |
| `komira_host.thp_policy` | the host's transparent-hugepage settings and whether hugepage advice pays off on it |
| `komira_host.proc_probe` | how much RAM a cache may size itself against |

Probes read the kernel (`sched_getaffinity`, `/sys`, `/proc`) once per
process and cache the answer. None of them reads an environment variable,
and none raises: on a probe failure, or off Linux, each falls back to a
stated safe value. The decisions are pure functions of what was read, kept
public so they can be checked without the host they describe.

Every example below runs as a test when the package is built, so it cannot
go stale.

## The pinning policy

`EnginePlacement()` turns every policy off: workers are unpinned, there is
no separate IO lane, no NUMA restriction and no reserved driver CPU. A
reserved driver CPU means something only when workers are pinned, which
`driver_reserved()` encodes. The program that embeds the engine sets the
policy (for example from its flags); nothing reads it from the environment.

```mojo
from komira_host.cpu_topology import engine_driver_cpu, engine_numa_node_id, engine_worker_count
from komira_host.engine_placement import EnginePlacement
from std.testing import assert_equal, assert_false, assert_true

var off = EnginePlacement()
assert_false(off.pin_workers or off.io_lane or off.numa_local)
assert_false(EnginePlacement(reserve_driver_cpu=True).driver_reserved())
assert_true(EnginePlacement(pin_workers=True, reserve_driver_cpu=True).driver_reserved())

# With the default policy no CPU is reserved and no NUMA node is chosen,
# and the worker count is at least 1 on any host.
assert_equal(engine_driver_cpu(off), -1)
assert_equal(engine_numa_node_id(off), -1)
assert_true(engine_worker_count(off) >= 1)
```

## Where a pin lands

Worker `k` pins to the `k`-th CPU of the compute lane, so `nw` pinned workers
occupy only the lane's first `nw` CPUs. Which NUMA nodes they sit on is a
function of the worker count, not of the lane. These functions answer that
from a lane and the per-node CPU lists, with no system call. Node lists are
indexed by ordinal: the i-th online node, in ascending id order.

```mojo
from komira_host.cpu_topology import numa_nodes_spanned, numa_nodes_spanned_by_pin, numa_pin_node_histogram, pinned_lane_prefix
from std.testing import assert_equal

# Two nodes of four CPUs each; the compute lane is all eight.
var nodes: List[List[Int]] = [[0, 1, 2, 3], [4, 5, 6, 7]]
var lane: List[Int] = [0, 1, 2, 3, 4, 5, 6, 7]

assert_equal(numa_nodes_spanned(lane, nodes), 2)
var first_three: List[Int] = [0, 1, 2]
assert_equal(pinned_lane_prefix(lane, 3), first_three)
assert_equal(len(pinned_lane_prefix(lane, 20)), 8)  # capped at the lane
assert_equal(numa_nodes_spanned_by_pin(lane, 3, nodes), 1)
assert_equal(numa_nodes_spanned_by_pin(lane, 6, nodes), 2)
var four_and_two: List[Int] = [4, 2]
assert_equal(numa_pin_node_histogram(lane, 6, nodes), four_and_two)
```

## Transparent hugepages

The kernel lists every legal value of a hugepage setting and brackets the
active one. The parsers turn the file's text into a token, and
`resolve_auto_mode` decides the advice: `MADV_HUGEPAGE` only when the host's
setting is `madvise` and the process has not disabled hugepages. `always`
resolves to off (the kernel already does it, so the advice only adds cost),
and so does anything unreadable or unrecognised.
`hugepage_auto_advice_mode()` applies the same decision to this host.
On a kernel before Linux 5.0 `/proc/self/status` has no `THP_enabled:` field,
so a process that set `PR_SET_THP_DISABLE` reads as available. The package's
tests observe that row on the real kernel and so require Linux 5.0 or later.

```mojo
from komira_host.thp_policy import ADVICE_HUGEPAGE, ADVICE_OFF, THP_DEFRAG_DEFER, THP_DEFRAG_DEFER_MADVISE, THP_ENABLED_ALWAYS, THP_ENABLED_MADVISE, THP_ENABLED_UNKNOWN, THP_PROCESS_AVAILABLE, THP_PROCESS_DISABLED, parse_thp_defrag, parse_thp_enabled, parse_thp_process_enabled, resolve_auto_mode
from std.testing import assert_equal

assert_equal(parse_thp_enabled("always [madvise] never\n"), THP_ENABLED_MADVISE)
assert_equal(parse_thp_enabled("[always] madvise never\n"), THP_ENABLED_ALWAYS)
assert_equal(parse_thp_enabled(""), THP_ENABLED_UNKNOWN)  # a missing file
assert_equal(parse_thp_defrag("always defer [defer+madvise] madvise never\n"), THP_DEFRAG_DEFER_MADVISE)

assert_equal(parse_thp_process_enabled("Name:\tprog\nTHP_enabled:\t0\n"), THP_PROCESS_DISABLED)
assert_equal(parse_thp_process_enabled("Name:\tprog\n"), THP_PROCESS_AVAILABLE)  # older kernels

assert_equal(resolve_auto_mode(THP_ENABLED_MADVISE, THP_DEFRAG_DEFER, THP_PROCESS_AVAILABLE), ADVICE_HUGEPAGE)
assert_equal(resolve_auto_mode(THP_ENABLED_MADVISE, THP_DEFRAG_DEFER, THP_PROCESS_DISABLED), ADVICE_OFF)
assert_equal(resolve_auto_mode(THP_ENABLED_ALWAYS, THP_DEFRAG_DEFER, THP_PROCESS_AVAILABLE), ADVICE_OFF)
assert_equal(resolve_auto_mode(THP_ENABLED_UNKNOWN, THP_DEFRAG_DEFER, THP_PROCESS_AVAILABLE), ADVICE_OFF)
```
