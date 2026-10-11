# =============================================================================
# agg_count_distinct_kernel.mojo — the ungrouped COUNT(DISTINCT) finalize:
# the union of every worker's per-partition dedup sets
# =============================================================================
#
# The ungrouped (scalar) COUNT(DISTINCT) dedups DURING the scan: each worker
# inserts every value into one of `_CD_UNION_NUM_PARTITIONS` hash sets, chosen
# by the top 3 bits of the value's Fibonacci hash
# (`streaming_agg_count_distinct._cd_value_partition`). Equal values land in
# the same partition on every worker, so the finalize unions partition p
# across the workers independently of every other partition, and the global
# distinct count is the SUM of the partitions' union sizes — no union across
# partitions is needed.
#
# `worker_sets[w][p]` is worker `w`'s partition-p set (one aggregate slot).
# `_cd_union_count` is the serial form; `_cd_union_count_parallel` runs one
# task per partition.
#
# Pointer rules: the dispatcher is borrowed `mut`; the State borrows
# `worker_sets` through a `Pointer` whose immutable origin the Task type also
# carries, and owns the per-partition counts, so the Task's bitcast restores
# the exact State type and names no wildcard origin.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_COUNT_DISTINCT
from std.memory import OwnedPointer, Pointer, UnsafePointer

from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_op_agg_state.growable_hash_set_i64 import GrowableHashSetI64


comptime _CD_UNION_NUM_PARTITIONS: Int = 8


struct _CdUnionState[so: Origin[mut=False]](KeepAlive):
    """Task `p` reads only `worker_sets[*][p]` (a disjoint value range) and
    writes only `counts[p]`. `worker_sets` is borrowed read-only; `counts` is
    owned by the State for the dispatch."""

    var sets: Pointer[List[List[GrowableHashSetI64]], Self.so]
    var num_workers: Int
    var counts: OwnedPointer[List[Int]]

    def __init__(
        out self,
        ref [Self.so] sets: List[List[GrowableHashSetI64]],
        num_workers: Int,
    ):
        self.sets = Pointer(to=sets)
        self.num_workers = num_workers
        self.counts = OwnedPointer(
            List[Int](length=_CD_UNION_NUM_PARTITIONS, fill=0)
        )

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _CdUnionTask[so: Origin[mut=False]](Segment):
    """POD discriminator; one task per value partition."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the bitcast restores the exact State type (the Task carries
        # the State's read-only origin). Task `p` reads only
        # `worker_sets[w][p]` for every `w` and writes only `counts[p]`.
        var sp = UnsafePointer(to=state).bitcast[_CdUnionState[Self.so]]()
        var p = Int(task_id)
        var nw = sp[].num_workers
        # A copy of worker 0's set-p, then workers 1..nw-1 folded in.
        var acc = sp[].sets[][0][p].copy()
        for w in range(1, nw):
            ref src = sp[].sets[][w][p]
            for s in range(src.size()):
                _ = acc.insert(src.key_at(s))
        sp[].counts[][p] = acc.size()

    def __keep_alive(mut self):
        pass


def _cd_union_count(imm worker_sets: List[List[GrowableHashSetI64]]) -> Int:
    """Serial per-partition union: the sum of the partitions' union sizes."""
    var nw = len(worker_sets)
    if nw == 0:
        return 0
    var total = 0
    for p in range(_CD_UNION_NUM_PARTITIONS):
        var acc = worker_sets[0][p].copy()
        for w in range(1, nw):
            ref src = worker_sets[w][p]
            for s in range(src.size()):
                _ = acc.insert(src.key_at(s))
        total += acc.size()
    return total


def _cd_union_count_parallel(
    imm worker_sets: List[List[GrowableHashSetI64]],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
) raises -> Int:
    """The per-partition union with one task per partition. One worker state
    (nothing to union) takes the serial form."""
    var nw = len(worker_sets)
    if nw <= 1:
        _ = cancel_token^
        return _cd_union_count(worker_sets)

    # PARALLELIZE-BOUNDARY: per-partition union.
    # Disjointness: task `p` reads only `worker_sets[*][p]` and writes only
    #   `counts[p]`; value partitions are disjoint by hash.
    # Liveness: `worker_sets` is the caller's and outlives the barrier; the
    #   State owns `counts`.
    # No-realloc: `worker_sets` is read-only (each task unions into its own
    #   copy); `counts` is sized before the dispatch.
    comptime StateT = _CdUnionState[origin_of(worker_sets)]
    comptime TaskT = _CdUnionTask[origin_of(worker_sets)]
    var state = StateT(worker_sets, nw)
    var task = TaskT(Int32(0))
    _ = dispatcher.run_with_state[StateT, TaskT](
        state, task^, _CD_UNION_NUM_PARTITIONS, cancel_token^,
        site_id=SITE_COUNT_DISTINCT,
    )
    var total = 0
    for p in range(_CD_UNION_NUM_PARTITIONS):
        total += state.counts[][p]
    _ = state^
    return total
