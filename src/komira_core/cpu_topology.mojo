# =============================================================================
# CpuTopology — re-export of `komira_core.runtime.cpu_topology`
# =============================================================================
#
# The implementation lives in `komira_core.runtime.cpu_topology`; this module
# re-exports its public surface at the package root.
#
# Public surface (re-exported):
#   * CpuTopology            — the resource-model struct
#   * EnginePlacement        — the worker/driver placement policy value that
#                              every `engine_*` function below takes
#   * derive_pools           — pure pool-derivation (testable)
#   * engine_worker_count    — compute pool size
#   * engine_compute_cpus / engine_io_cpus — the per-lane CPU lists
#   * pin_current_thread_to  — affinity pin
#
# Driver-CPU reservation:
#   * derive_driver_reservation — the pure driver-CPU reservation policy
#   * engine_topology           — detect() + the placement policies enabled
#                                 in the given `EnginePlacement`
#   * engine_driver_cpu / pin_driver_thread — the reserved CPU + driver-side pin
#
# Topology resolution:
#   * prime_cpu_topology     — force the process-wide allowed-set snapshot
#   * reset_current_thread_affinity_to_all — the inverse of a thread pin
#   * topology_probe_count   — how many times the allowed set was probed
#
# IO-lane placement:
#   * derive_io_placement       — the pure placement policy (SIBLING /
#                                 DEDICATED / DRIVER_CORESIDENT / INLINE)
#   * engine_io_placement_mode  — which arm fires on this host + placement
#   * IO_PLACEMENT_*            — the mode discriminants
#
# NUMA-node restriction:
#   * derive_numa_locality      — the pure policy (identity no-op on <= 1 node)
#   * numa_nodes_spanned / numa_preferred_node — its two pure predicates
#   * engine_numa_spanned_nodes / engine_numa_node_id / engine_numa_node_cpus
#   * confine_current_thread_to / confine_thread_to_engine_numa_node — the
#     MULTI-cpu affinity mask (contrast `pin_current_thread_to`, ONE cpu)
#
# Pin placement — where a worker pin actually LANDS, which is a function of
# the WORKER COUNT and not of the lane (a small pool fits one socket, a
# larger one spans two, on the same host). `engine_numa_spanned_nodes`
# cannot see this; it spans the whole detected lane at every worker count:
#   * pinned_lane_prefix / numa_nodes_spanned_by_pin / numa_pin_node_histogram
#                               — pure, host-independent
#   * engine_pinned_worker_node_histogram — the host-reading form. DIAGNOSTIC
#     ONLY: it re-walks /sys/devices/system/node (not snapshot-served).
# =============================================================================

from komira_core.runtime.engine_placement import EnginePlacement
from komira_core.runtime.cpu_topology import (
    CpuTopology,
    derive_pools,
    derive_driver_reservation,
    derive_io_placement,
    derive_numa_locality,
    numa_nodes_spanned,
    numa_preferred_node,
    pinned_lane_prefix,
    numa_nodes_spanned_by_pin,
    numa_pin_node_histogram,
    engine_pinned_worker_node_histogram,
    engine_numa_spanned_nodes,
    engine_numa_node_id,
    engine_numa_node_cpus,
    confine_current_thread_to,
    confine_thread_to_engine_numa_node,
    engine_worker_count,
    engine_compute_cpus,
    engine_io_cpus,
    engine_io_placement_mode,
    engine_topology,
    engine_driver_cpu,
    pin_driver_thread,
    pin_current_thread_to,
    prime_cpu_topology,
    reset_current_thread_affinity_to_all,
    topology_probe_count,
    IO_PLACEMENT_UNSET,
    IO_PLACEMENT_INLINE,
    IO_PLACEMENT_SIBLING,
    IO_PLACEMENT_DEDICATED,
    IO_PLACEMENT_DRIVER_CORESIDENT,
)
