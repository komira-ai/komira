# =============================================================================
# komira_core.runtime -- low-level runtime resource primitives
# =============================================================================
#
# Leaf runtime primitives that depend only on std and komira_core_ffi and
# are consumed by higher layers (async runtime, engine runtime, engine
# dispatch, file formats, SDK) for thread-pool sizing and placement.
#
# Modules:
#   * engine_placement -- `EnginePlacement`, the worker/driver CPU placement
#                     policy value (pin workers, IO lane, NUMA-local,
#                     reserved driver CPU). Callers pass it explicitly; it is
#                     never read from the environment.
#   * cpu_topology -- cgroup/cpuset-aware CPU resource model with HT-sibling
#                     split (CpuTopology, engine_compute_cpus, engine_io_cpus,
#                     engine_worker_count, ...). Every `engine_*` function
#                     takes an `EnginePlacement`.
#   * thp_policy   -- host transparent-hugepage policy probe behind the
#                     `auto` memory-advice mode (hugepage_auto_advice_mode,
#                     thp_policy_report, thp_probe_count). Same shape as
#                     cpu_topology: PURE parsers + a `_Global`-frozen sysfs
#                     probe, fail-closed to ADVICE_OFF. It OWNS the ADVICE_*
#                     vocabulary that `komira_core.arrow.hugepage_span`
#                     aliases, so the graph stays acyclic (arrow -> runtime,
#                     never the reverse).
#   * proc_probe   -- the host MEMORY basis
#                     (`detect_scan_cache_ram_basis_bytes` =
#                     min(/proc/meminfo MemAvailable, cgroup-v2 memory.max)),
#                     plus the procfs/sysfs small-file reader and the ASCII
#                     parsers the engine runtime's hardware probe shares.
#
# These live here, not in an engine package, because a host probe with no
# engine semantics would otherwise put an engine package into the closure of
# everything that needs one (the Parquet footer cache, for example).
#
# `proc_probe` MUST STAY A `std`-ONLY LEAF. One import edge from here back
# into an engine package -- or into anything that reaches one -- restores
# that whole cost.
# =============================================================================

from .engine_placement import EnginePlacement
