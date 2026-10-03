# =============================================================================
# komira_async.observability.hot_shard_metrics — per-worker work counter + CV aggregator
# =============================================================================
#
# Per-worker counter (live on each Worker as a direct field; aggregation is
# across workers via a stack-local List[Int64] of pre-snapshotted values).
# The full design watches per-worker CPU% + queue depth + in-flight task
# count over a rolling 30s window with CV computed across workers, alerting
# if CV > 0.3 is sustained for 30s.
#
# Minimum-viable scope:
#   - HotShardMetrics struct: per-worker work_completed counter (proxy for
#     CPU% / queue depth — a single signal for now).
#   - Aggregator free fns: compute_cv(samples), is_imbalanced(samples,
#     threshold_cv) operating on List[Int64] (caller materializes).
#   - No sustained-for-K-ticks logic yet: a single-snapshot CV.
#   - Worker integration (an `_imbalance_metrics` field + a worker-loop
#     hook) waits for a real task scheduler.
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO ArcPointer — counter is per-worker single-owner.
#   - ZERO wildcard origins on public surface.
#   - ZERO unsafe_from_address.
#   - work_completed counter heap-allocated via OwnedPointer[Atomic[int64]]
#     (Repro 7 pattern; Atomic non-Movable on 0.26.3; OwnedPointer makes
#     HotShardMetrics Movable).
#
# Aggregator design rationale:
#   HotShardMetrics is NOT Copyable (OwnedPointer field), so a List of
#   metrics is structurally impossible (List requires Copyable T). Phase
#   1.26 ships compute_cv(List[Int64]) and the canonical pattern is for
#   the caller to materialize per-worker work_completed() into a stack-
#   local List[Int64] before invoking the aggregator. This matches the
#   precedent (see `executor_msink.mojo:26` — same finding
#   applies to List[OwnedPointer[T]]).
# =============================================================================

from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI64
from std.collections import List
from std.math import sqrt


# alert when CV > 0.3.
comptime DEFAULT_IMBALANCE_CV_THRESHOLD: Float64 = 0.3


struct HotShardMetrics(Movable, Deinitable):
    """Per-worker work-completed counter.

    A single-signal counter (work completed per task_finished).
    Multi-signal expansion (CPU%, queue depth, in-flight count, rolling
    30s window) is a later hardening step.

    Field set:
      - _worker_id: UInt16 — provenance / structured-log emission.
      - _work_completed: OwnedPointer[Atomic[int64]] — incremented on
        each task_finished. Atomic so a separate aggregator thread can
        read it without contention (relaxed load). OwnedPointer because
        Atomic is non-Movable on 0.26.3.
      - _last_snapshot_value: Int64 — last value the aggregator
        snapshotted; used to compute deltas across ticks.

    NOT shared across workers. Aggregator reads each worker's counter
    via work_completed() (relaxed load) and computes CV across the
    stack-local List[Int64]; no ArcPointer-shared counter.
    """

    var _worker_id: UInt16
    var _work_completed: OwnedPointer[AtomicI64]
    var _last_snapshot_value: Int64

    def __init__(out self, worker_id: UInt16) raises:
        self._worker_id = worker_id
        self._last_snapshot_value = Int64(0)
        var raw = alloc[AtomicI64](1)
        # SAFETY: raw is a fresh allocation we own; Atomic ctor accepts
        # a Scalar value; ownership transfers to OwnedPointer; __del__
        # runs free. Repro 7 pattern; matches ExecutionBudget._morsels.
        raw[] = AtomicI64(Int64(0))
        self._work_completed = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw
        )

    def worker_id(self) -> UInt16:
        return self._worker_id

    def work_completed(self) -> Int64:
        """Returns the current work-completed count. Relaxed load —
        safe to call from any thread; the only ordering guarantee is
        that the value is non-decreasing within a worker."""
        return self._work_completed[].load()

    def record_task_completed(mut self):
        """increment on task_finished.
        proxies CPU% / queue depth via "tasks completed in tick"."""
        _ = self._work_completed[].fetch_add(Int64(1))

    def record_n_tasks_completed(mut self, n: Int64):
        """Bulk-record N task completions in one atomic op (e.g., when
        a batch finishes). n=0 is a no-op."""
        if n != Int64(0):
            _ = self._work_completed[].fetch_add(n)

    def snapshot(mut self) -> Int64:
        """Snapshot the current work_completed value and update the
        last-snapshot bookkeeping. Returns the current value.
        delta_since_last_snapshot() will return 0 immediately after."""
        var val = self._work_completed[].load()
        self._last_snapshot_value = val
        return val

    def delta_since_last_snapshot(self) -> Int64:
        """Returns work_completed - _last_snapshot_value. Used by the
        aggregator to compute per-tick rates across workers."""
        return self._work_completed[].load() - self._last_snapshot_value


# ----------------------------------------------------------------------------
# CV aggregator — free fns over List[Int64] samples.
# ----------------------------------------------------------------------------
# Caller is responsible for materializing samples from per-worker counters:
#
#   var samples = List[Int64]()
#   samples.append(workers[0].metrics.work_completed())
#   samples.append(workers[1].metrics.work_completed())
#   ...
#   if is_imbalanced(samples):
#       # emit warning event
#
# This indirection is required because HotShardMetrics is NOT Copyable
# (OwnedPointer field), so List[HotShardMetrics] is structurally
# impossible.
# ----------------------------------------------------------------------------


def compute_cv(samples: List[Int64]) -> Float64:
    """Coefficient of variation = stddev / mean.

    Returns 0.0 for:
      - Empty samples list (nothing to compare).
      - Single sample (no variation across 1 worker).
      - Zero mean (no work; not imbalanced — defined as 0.0 rather
        than NaN because the alert semantics is "is the workload
        skewed", and a no-work workload is not skewed).

    alerts at CV > 0.3.
    """
    var n = len(samples)
    if n <= 1:
        return Float64(0.0)
    # Compute mean.
    var sum_val = Float64(0.0)
    var i = 0
    while i < n:
        sum_val = sum_val + Float64(Int(samples[i]))
        i = i + 1
    var mean = sum_val / Float64(n)
    if mean == Float64(0.0):
        return Float64(0.0)
    # Compute variance (population variance — divisor N, not N-1; we
    # treat samples as the full population of workers in the snapshot,
    # not as a sample drawn from a larger distribution).
    var sumsq = Float64(0.0)
    i = 0
    while i < n:
        var diff = Float64(Int(samples[i])) - mean
        sumsq = sumsq + diff * diff
        i = i + 1
    var variance = sumsq / Float64(n)
    var stddev = sqrt(variance)
    return stddev / mean


def is_imbalanced(
    samples: List[Int64],
    threshold_cv: Float64 = DEFAULT_IMBALANCE_CV_THRESHOLD,
) -> Bool:
    """Convenience: True iff compute_cv(samples) > threshold_cv.
    Default threshold = 0.3."""
    return compute_cv(samples) > threshold_cv
