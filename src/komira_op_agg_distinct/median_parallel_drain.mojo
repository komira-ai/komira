# =============================================================================
# median_parallel_drain.mojo — parallel PER-GROUP finalize for the typed-stage
# drain
# =============================================================================
#
# The typed-stage grouped MEDIAN (`MedianOp`, `komira_agg/hash_agg_op_dt.mojo`) buffers every
# fed value per group and finalizes each group via an EXACT variable-size buffer
# `sort()` + interpolated 50th-percentile select. That per-group finalize is
# INDEPENDENT across groups (a group's median depends only on its own buffer), so
# the serial drain loop (`AggSlot.emit_column`) that sorts + interpolates every
# group ONE AT A TIME is the ~84% post-collect wall of an exact grouped-median
# query with many groups (for example 10K groups of ~600 values each). This primitive parallelizes that loop by
# PARTITIONING GROUPS across workers: each worker finalizes a disjoint contiguous
# slice of the occupied slots, writing into disjoint output positions. The result
# is BYTE-IDENTICAL to the serial `emit_column` — the SAME per-group buffers, the
# SAME sort, the SAME interpolation, the SAME slot order; only the loop is fanned.
#
# ORTHOGONAL to a radix COUNT_DISTINCT drain, which
# parallelizes WITHIN a group (value-hash partition of one group's buffer, summed
# — correct only for the order-independent distinct COUNT). THIS parallelizes
# ACROSS groups (each group's global-order percentile select stays whole + exact).
# MEDIAN must NOT set `IS_DISTINCT_BUFFER` (a per-value-partition union would
# corrupt the percentile); it sets `SORT_FINALIZE` instead. The two are
# independent axes on the op.
#
# Pointer rules: no pointer in the public signature (the dispatcher is borrowed
# `mut`); the Task carries the State's three concrete origins as parameters, so
# its bitcast restores the exact State type and names no wildcard origin.
# Disjoint per-slot writes; POD driver scalars; each worker's `finalize`
# allocates its own private sort scratch (no shared realloc).
# =============================================================================

from std.collections import List
from std.builtin.swap import swap
from std.memory import OwnedPointer, Pointer, UnsafePointer

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatchBuilder
from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_MEDIAN_DRAIN

from komira_agg.aggregator import Aggregator


# Below this occupied-group count the fork-join barrier is not worth it — the
# per-group finalizes run serially (matching the pre-fix `emit_column`). A drain
# with 10K groups clears it; low-cardinality median drains (few groups) stay serial.
comptime _MEDIAN_PARALLEL_MIN_GROUPS: Int = 256


# =============================================================================
# Parallelize State + Task — one task per contiguous slot-slice (disjoint
# per-group finalize writes).
#
# PARALLELIZE-BOUNDARY (run_with_state, fork-join synchronous):
#   Disjointness: task `t` finalizes slot-indices `[t*chunk, (t+1)*chunk)` ONLY,
#     writing ONLY those `out[si]` positions. No two tasks touch the same slot,
#     and `states`/`slots` are IMMUTABLE shared borrows (finalize reads, never
#     mutates — it copies the buffer before sorting).
#   Liveness: the driver owns `states` (borrowed in) and `slots` on its stack,
#     and the State owns `out`, across the dispatch; run_with_state's drain barrier guarantees every
#     worker exits before the driver reads `out` back.
#   No-realloc: `out` is pre-sized to `len(slots)` before the fork and never
#     grown; each worker only allocates its OWN finalize sort scratch (private
#     heap, no shared reallocation).
# =============================================================================


struct _GroupFinalizeState[
    A: Aggregator,
    so: Origin[mut=False],
    sl: Origin[mut=False],
](KeepAlive):
    # `out` is OWNED by the State for the dispatch and swapped back into the
    # driver's list after it: a borrowed mutable origin would be named by the
    # Task type too, and `run_with_state` takes the State and the Task `mut`,
    # which the compiler rejects as aliasing.
    var states: Pointer[List[Self.A.StateTy], Self.so]
    var slots: Pointer[List[Int], Self.sl]
    var out: OwnedPointer[List[Scalar[Self.A.OUT_DT]]]
    var n: Int
    var nw: Int

    def __init__(
        out self,
        ref [Self.so] states: List[Self.A.StateTy],
        ref [Self.sl] slots: List[Int],
        var out: List[Scalar[Self.A.OUT_DT]],
        n: Int,
        nw: Int,
    ):
        self.states = Pointer(to=states)
        self.slots = Pointer(to=slots)
        self.out = OwnedPointer(out^)
        self.n = n
        self.nw = nw

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _GroupFinalizeTask[
    A: Aggregator,
    so: Origin[mut=False],
    sl: Origin[mut=False],
](Segment):
    """POD discriminator; `execute` finalizes this task's contiguous slot-slice."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        comptime ConcreteState = _GroupFinalizeState[Self.A, Self.so, Self.sl]
        # SAFETY: the bitcast restores the exact State type the driver passed
        # to `run_with_state` (the Task is instantiated with the same two
        # origins). Task `t` writes ONLY slot-indices `[t*chunk, (t+1)*chunk)`
        # (disjoint); `states` and `slots` are IMMUTABLE shared borrows.
        var sp = UnsafePointer(to=state).bitcast[ConcreteState]()
        var t = Int(task_id)
        var n = sp[].n
        var nw = sp[].nw
        var chunk = (n + nw - 1) // nw
        var lo = t * chunk
        var hi = lo + chunk
        if hi > n:
            hi = n
        for si in range(lo, hi):
            # SAFETY: disjoint per-slot output index; the finalize reads the
            # group's IMMUTABLE state buffer (it copies before sorting and never
            # writes the shared `states`), so cross-worker reads never race.
            var slot = sp[].slots[][si]
            sp[].out[][si] = Self.A.finalize(sp[].states[][slot])

    def __keep_alive(mut self):
        pass


# =============================================================================
# The driver — build one agg's output column via a PARALLEL per-group finalize.
# =============================================================================


def parallel_group_finalize_column[
    A: Aggregator
](
    imm states: List[A.StateTy],
    imm slots: List[Int],
    mut rb: RecordBatchBuilder,
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
) raises:
    """Append aggregate `A`'s output column to `rb` by finalizing each occupied
    group in PARALLEL (partition groups across workers). BYTE-IDENTICAL to the
    serial `AggSlot.emit_column` — the SAME `A.finalize` per group, in the SAME
    slot order, materialized into a `PrimitiveArray[A.OUT_DT]`.

    At or above `_MEDIAN_PARALLEL_MIN_GROUPS` occupied groups, with more than
    one worker, the per-group finalizes run fork-join; otherwise they run
    serially — byte-identical either way. Consumed by the median arm of
    `AggSlot.emit_column_parallel`; only instantiated for a `SORT_FINALIZE` op."""
    var n = len(slots)

    # Pre-size the output value list (fixed backing buffer; the parallel tasks
    # write disjoint positions into it — no realloc after this point).
    var out = List[Scalar[A.OUT_DT]](capacity=n)
    for _ in range(n):
        out.append(Scalar[A.OUT_DT](0))

    var nw = dispatcher.worker_count()
    if nw < 1:
        nw = 1
    # No empty tasks: cap the task count at the group count.
    if nw > n:
        nw = n

    var parallel = nw > 1 and n >= _MEDIAN_PARALLEL_MIN_GROUPS

    if not parallel:
        # Serial per-group finalize (the pre-fix `emit_column` loop, byte-exact).
        for si in range(n):
            out[si] = A.finalize(states[slots[si]])
        _ = cancel_token^
    else:
        comptime StateT = _GroupFinalizeState[
            A, origin_of(states), origin_of(slots)
        ]
        var st = StateT(states, slots, out^, n, nw)
        comptime TaskT = _GroupFinalizeTask[
            A, origin_of(states), origin_of(slots)
        ]
        var task = TaskT(_pad=Int32(0))
        var _back = dispatcher.run_with_state[StateT, TaskT](
            st, task^, nw, cancel_token^, site_id=SITE_MEDIAN_DRAIN
        )
        _ = _back^
        out = List[Scalar[A.OUT_DT]]()
        swap(st.out[], out)

    var arr = PrimitiveArray[A.OUT_DT].from_list(out)
    rb.add_column(Column.from_primitive[A.OUT_DT](arr^))
