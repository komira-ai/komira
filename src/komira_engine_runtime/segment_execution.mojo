# =============================================================================
# SegmentExecution -- per-segment fused dispatch + state (Phase 2E.1)
# =============================================================================
#
# RFC v4 §3.2: fused dispatch + per-segment-state type (Option B, 2-type
# collapse). v3's SegmentScheduler layer is gone; dispatch is a method on
# `SegmentExecution` directly.
#
# Ownership + lifetime model:
#   * ZERO struct-level origin parameters. `PipelineExecution` is NOT
#     held by reference; it is passed per-dispatch by `mut ref`. Workers
#     receive the pipeline ref via their dispatch call argument and use
#     it within that call's lifetime only.
#   * NOT Movable (Atomic fields force Deinitable). Caller
#     builds `SegmentExecution` on the driver stack per-segment.
#   * Per-segment STATE (HashAggState, RadixProcessState, ...) is built
#     separately on the driver stack and threaded through the
#     `dispatch` method -- not stored inside `SegmentExecution` to keep
#     the type concrete, not parametric on another axis.
#
# Why `dispatch` is `@always_inline`:
#   The dispatch hop must reduce at AOT to a direct call into
#   `pool.run_with_state`. Spike Repro 9 validates inlining on
#   Mojo. If AOT inlining ever fails, §11.8 free-function
#   fallback is the escape hatch (dispatch as free fn).
#
# Per-segment timing fields (source_ns, operator_ns, sink_ns,
# combine_ns, morsel_count) are Atomic. Multiple workers in one
# dispatch may accumulate into these concurrently -- the per-segment
# AGGREGATE timing IS shared, so it must be Atomic.
#
# Phase 3.2: per-operator breakdown moved to each
# MorselOperatorImpl instance's `OwnedPointer[MetricsSet]` (see
# `morsel_operator.mojo` + `metrics_set.mojo`). The dead
# pipeline-level `per_op_scratch` was deleted alongside
# `PipelineMetrics`.
#
# References:
#   * RFC v4 §3.2 -- an internal doc
#   * Spike Repro 2 -- zero struct-level origins compiles cleanly.
#   * Spike Repro 3 -- method-level `state_o` + `pipe_o` origins work.
#   * Spike Repro 9 -- AOT @always_inline collapses the dispatch hop.
# =============================================================================

from komira_atomic_alias import AtomicI64

from komira_morsel.pipeline_execution import PipelineExecution
# Slot PERCORE-DIRECT-MIGRATION-S3: KeepAlive + Segment
# traits live at their canonical module path (the worker_pool.mojo
# shim is gone). Engine-runtime modules import them from the trait
# module directly — same path engine-operators / engine-dispatch /
# parquet have used since the Phase 2 circular-dep break.
from komira_async_api.worker_pool_traits import KeepAlive, Segment

# Phase 1.3 (A10 cascade): substrate dispatcher imports for
# body-only migration of `pool_ref.run_with_state` callsite.
# Phase 1 Layer B-residual: the dispatch method now takes
# the substrate dispatcher + cancel_token directly; pipeline no longer
# carries a pool borrow.
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_SEGMENT_EXEC


# =============================================================================
# Segment trait — canonical at komira_async_api.worker_pool_traits
# =============================================================================
#
# The `Segment` trait is imported above from the canonical trait module.
# See `komira_async_api/worker_pool_traits.mojo` for the trait
# definition (`fn execute[State: KeepAlive] ... raises`).


# =============================================================================
# SegmentExecution
# =============================================================================


struct SegmentExecution(Deinitable):
    """Per-segment execution context. Fused dispatch + per-segment state.

    ZERO struct-level origin parameters (mojo M1 resolved). Per-segment
    timing fields are Atomic so multiple workers under a dispatch can
    accumulate concurrently. Not Movable.

    Carries per-segment metadata:
      * `segment_id`           -- 0-based index of this segment in the plan.
      * `op_slot_start/_end`   -- legacy slot-range kept for source-compat;
        unused post-Phase 3.2 (per-operator metrics live on each
        MorselOperatorImpl instance, not in a pipeline-level scratch).
        Will drop with the follow-up SegmentExecution signature cleanup.
      * per-segment timing + `morsel_count` -- rust-fidelity F1+F2 per-
        segment breakdown (atomic fetch_add under dispatch; single-writer
        after barrier).

    The dispatch method takes the substrate dispatcher + cancel_token
    by-ref per-call (Phase 1 Layer B-residual — pipeline no
    longer borrows the pool) and returns the moved `task` value to the
    caller (matching `LocalDispatcher.run_with_state` semantics so the
    caller can reuse the task struct or drop it explicitly).
    """

    var segment_id: Int32

    # Phase 3.2: legacy slot range kept for source-compat (no operator
    # writes into a pipeline-level slab any more — per-operator metrics
    # live on each MorselOperatorImpl instance's MetricsSet). Drop with
    # the follow-up SegmentExecution signature cleanup.
    var op_slot_start: Int32
    var op_slot_end: Int32

    # Per-segment timing (rust-fidelity F1+F2). Atomic because workers
    # under a dispatch update these concurrently.
    var source_ns: AtomicI64
    var operator_ns: AtomicI64
    var sink_ns: AtomicI64
    var combine_ns: AtomicI64
    var morsel_count: AtomicI64

    # ---------------------------------------------------------------------
    # Lifecycle
    # ---------------------------------------------------------------------

    def __init__(
        out self,
        segment_id: Int32,
        op_slot_start: Int32,
        op_slot_end: Int32,
    ):
        self.segment_id = segment_id
        self.op_slot_start = op_slot_start
        self.op_slot_end = op_slot_end
        self.source_ns = AtomicI64(Int64(0))
        self.operator_ns = AtomicI64(Int64(0))
        self.sink_ns = AtomicI64(Int64(0))
        self.combine_ns = AtomicI64(Int64(0))
        self.morsel_count = AtomicI64(Int64(0))

    # ---------------------------------------------------------------------
    # Dispatch (the single path for all driver dispatches)
    # ---------------------------------------------------------------------

    @always_inline
    def dispatch[
        state_o: Origin[mut=True],
        disp_o: Origin[mut=True],
        S: KeepAlive,
        T: Segment,
    ](
        mut self,
        ref [disp_o] dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        ref [state_o] state: S,
        var task: T,
        n: Int,
    ) raises -> T:
        """Dispatch `task` across `n` workers, sharing `state` by ref.

        Phase 1 Layer B-residual: the substrate
        dispatcher + cancel_token are passed in directly; the previous
        `pipeline._pool[]` access is gone with the `_pool` field. The
        call chain still reduces to a direct
        `dispatcher.run_with_state` (validated by spike Repro 9).

        Returns the moved `task` value so the caller can reuse it or
        explicitly drop via `_ = task_back^`.
        """
        return dispatcher.run_with_state[S, T](
            state, task^, n, cancel_token^, site_id=SITE_SEGMENT_EXEC
        )

    # ---------------------------------------------------------------------
    # Per-segment metric accessors (driver-side convenience)
    # ---------------------------------------------------------------------

    @always_inline
    def add_source_ns(mut self, ns: Int64):
        _ = self.source_ns.fetch_add(ns)

    @always_inline
    def add_operator_ns(mut self, ns: Int64):
        _ = self.operator_ns.fetch_add(ns)

    @always_inline
    def add_sink_ns(mut self, ns: Int64):
        _ = self.sink_ns.fetch_add(ns)

    @always_inline
    def add_combine_ns(mut self, ns: Int64):
        _ = self.combine_ns.fetch_add(ns)

    @always_inline
    def bump_morsel_count(mut self, n: Int64 = Int64(1)):
        _ = self.morsel_count.fetch_add(n)
