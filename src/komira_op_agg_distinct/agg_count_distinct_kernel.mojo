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
# task per partition. Both fold workers 1..nw-1 INTO worker 0's sets (passed
# in by value as the accumulator), so no set is copied.
#
# Pointer rules: the dispatcher is borrowed `mut`; the State borrows
# the other workers' sets through a `Pointer` whose immutable origin the Task type also
# carries, and owns the accumulator and the per-partition counts, so the Task's bitcast restores
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
    """Task `p` reads only `others[*][p]` (a disjoint value range), inserts
    only into `acc[p]` and writes only `counts[p]`. `others` is borrowed
    read-only; `acc` and `counts` are owned by the State for the dispatch."""

    var others: Pointer[List[List[GrowableHashSetI64]], Self.so]
    var num_others: Int
    var acc: OwnedPointer[List[GrowableHashSetI64]]
    var counts: OwnedPointer[List[Int]]

    def __init__(
        out self,
        ref [Self.so] others: List[List[GrowableHashSetI64]],
        var acc: List[GrowableHashSetI64],
    ):
        self.others = Pointer(to=others)
        self.num_others = len(others)
        self.acc = OwnedPointer(acc^)
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
        # the State's read-only origin). Task `p` reads `others[w][p]` for
        # every `w`, inserts only into `acc[p]` and writes only `counts[p]`.
        var sp = UnsafePointer(to=state).bitcast[_CdUnionState[Self.so]]()
        var p = Int(task_id)
        for w in range(sp[].num_others):
            ref src = sp[].others[][w][p]
            for s in range(src.size()):
                _ = sp[].acc[][p].insert(src.key_at(s))
        sp[].counts[][p] = sp[].acc[][p].size()

    def __keep_alive(mut self):
        pass


def _cd_union_count(
    var acc: List[GrowableHashSetI64],
    imm others: List[List[GrowableHashSetI64]],
) -> Int:
    """Serial per-partition union of `others` into `acc` (worker 0's sets,
    consumed): the sum of the partitions' union sizes."""
    var total = 0
    for p in range(_CD_UNION_NUM_PARTITIONS):
        for w in range(len(others)):
            ref src = others[w][p]
            for s in range(src.size()):
                _ = acc[p].insert(src.key_at(s))
        total += acc[p].size()
    return total


def _cd_union_count_parallel(
    var acc: List[GrowableHashSetI64],
    imm others: List[List[GrowableHashSetI64]],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
) raises -> Int:
    """The per-partition union with one task per partition: `others` (the
    other workers' sets) folded into `acc` (worker 0's sets, consumed; no set
    is copied). With no other worker (nothing to union) it takes the serial
    form."""
    if len(others) == 0:
        _ = cancel_token^
        return _cd_union_count(acc^, others)

    # PARALLELIZE-BOUNDARY: per-partition union.
    # Disjointness: task `p` reads only `others[*][p]`, inserts only into
    #   `acc[p]` and writes only `counts[p]`; value partitions are disjoint
    #   by hash.
    # Liveness: `others` is the caller's and outlives the barrier; the State
    #   owns `acc` and `counts`.
    # No-realloc: `others` is read-only; `acc` and `counts` are sized before
    #   the dispatch and each task grows only its own partition's set.
    comptime StateT = _CdUnionState[origin_of(others)]
    comptime TaskT = _CdUnionTask[origin_of(others)]
    var state = StateT(others, acc^)
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
