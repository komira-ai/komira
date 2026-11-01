# =============================================================================
# sort_sink -- SortSink, the sort as a MorselSink
# =============================================================================
#
# `SortSink` collects every morsel of a pipeline and emits the rows sorted by
# a `SortSinkData` (`komira_physical_plan`). Each worker appends its batches
# to its own `SortSinkLocal`; `combine` folds each worker's batches into one
# batch per worker and picks the route, once, from the key count, the key's
# type, the total rows and (for a STRING key) a sampled cardinality:
#
#   * one INT64 / INT32 / FLOAT64 key, at least `routes.parallel_min_rows`
#     rows, more than one worker batch: the per-worker batches stay as
#     partitions; the executor sorts each on its own worker
#     (`combine_partition`), and `finalize` merges them
#     (`sort_parallel.merge_sorted_partitions_single_key`);
#   * the same with one STRING / BINARY key (`routes.parallel_string`): the
#     merge is `sort_parallel_string.merge_sorted_partitions_single_key_string_parallel`;
#   * one STRING / BINARY key of low cardinality (`routes.dictrank`, and the
#     gate of `sort_dictrank`): `finalize` concatenates the worker batches on
#     the pool and runs the counting sort (`parallel_dictrank_sort_string`);
#     no `combine_partition`, since the counting sort is global;
#   * anything else: one batch, sorted by `sort_topn_sink._execute_sort_sink`.
#
# Every route gives the rows `_execute_sort_sink` gives over the worker
# batches concatenated in worker order, ties in that order. The routes differ
# in cost only, so the choice is data-dependent but never changes an answer.
#
# Not here: `SortSinkData.memory_budget > 0` (the external sort) is not driven
# by this sink, and `nulls_first` is not read (the kernels place NULLs by
# direction). Both are as in the kernel `_execute_sort_sink`.
#
# `SortSinkGlobal` holds an inline Atomic, so it is not Movable: it is built in
# place by `init_global`'s out-parameter.
# =============================================================================

from std.atomic import Atomic
from std.collections.optional import Optional
from std.memory import OwnedPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import SharedForkJoinHandle
from komira_async_api.worker_pool_traits import KeepAlive
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import (
    materialize_selection_if_present,
)
from komira_engine_runtime.streaming_concat_parallel import (
    concat_record_batches_column_parallel,
)
from komira_operator_api.memory_reservation import MemoryReservation
from komira_operator_api.morsel_sink import (
    FinalizeOutput,
    MorselSink,
    NeverMorselSource,
    PARTITIONS_IMPOSSIBLE,
    PARTITIONS_TRIVIAL,
    SinkCapabilities,
)
from komira_operator_api.sink_batch_fold import fold_batches_into_one
from komira_physical_plan.physical_plan import SortSinkData

from .sort_dictrank import (
    can_dictrank_sort_single_key_string,
    parallel_dictrank_sort_string,
)
from .sort_dictrank_build import DICTRANK_MAX_DISTINCT
from .sort_parallel import (
    can_parallel_sort_single_key,
    merge_sorted_partitions_single_key,
)
from .sort_parallel_string import (
    can_parallel_sort_single_key_string,
    merge_sorted_partitions_single_key_string_parallel,
)
from .sort_topn_sink import _execute_sort_sink


# The total row count below which the sink sorts one batch serially: the
# per-partition fork-join and the merge are not worth it for a small input.
comptime SORT_SINK_PARALLEL_MIN_ROWS: Int = 256 * 1024


struct SortSinkRoutes(Copyable, ImplicitlyCopyable, Movable):
    """The sort sink's route switches, as a value. The defaults are the
    shipped routes; every route gives the same rows.

    Fields:
      * `dictrank` -- a low-cardinality single STRING key takes the
        dense-rank counting sort.
      * `parallel_string` -- a single STRING key takes the partitioned
        parallel sort and merge (otherwise the serial kernel).
      * `dictrank_max_distinct` -- the distinct-count ceiling of the
        counting sort (its histogram is `workers * (distinct + 1)` ints).
      * `parallel_min_rows` -- the total rows below which the sink sorts
        serially.
      * `num_workers` -- the slice count of the finalize merges and the
        counting sort; 0 is one per physical core.
    """

    var dictrank: Bool
    var parallel_string: Bool
    var dictrank_max_distinct: Int
    var parallel_min_rows: Int
    var num_workers: Int

    def __init__(
        out self,
        dictrank: Bool = True,
        parallel_string: Bool = True,
        dictrank_max_distinct: Int = DICTRANK_MAX_DISTINCT,
        parallel_min_rows: Int = SORT_SINK_PARALLEL_MIN_ROWS,
        num_workers: Int = 0,
    ):
        self.dictrank = dictrank
        self.parallel_string = parallel_string
        self.dictrank_max_distinct = dictrank_max_distinct
        self.parallel_min_rows = parallel_min_rows
        self.num_workers = num_workers


def _copy_spec(spec: SortSinkData) -> SortSinkData:
    return SortSinkData(
        spec.sort_keys.copy(),
        spec.descending.copy(),
        spec.memory_budget,
        spec.nulls_first.copy(),
    )


@always_inline
def _batch_key_is_string(imm batch: RecordBatch, key_name: String) -> Bool:
    """True iff `key_name` resolves to a STRING / BINARY column in `batch`."""
    try:
        var ki = batch.schema.column_index(key_name)
        ref col = batch.column_at(ki)
        return (
            col.arrow_type == ArrowType.STRING
            or col.arrow_type == ArrowType.BINARY
        )
    except:
        return False


# =============================================================================
# SortSinkLocal / SortSinkGlobal
# =============================================================================


struct SortSinkLocal(Movable, Deinitable):
    """One worker's batches, appended by `consume`, moved out by `combine`."""

    var batches: Slab[RecordBatch]

    def __init__(out self):
        self.batches = Slab[RecordBatch]()

    def num_batches(self) -> Int:
        return len(self.batches)


struct SortSinkGlobal(KeepAlive):
    """The shared state: the per-worker batches (`partitions`), or the one
    batch of the serial route (`combined`), and the route `combine` chose.

    Not Movable (inline Atomic); built in place by `init_global`.
    """

    var partitions: Slab[RecordBatch]
    var combined: Optional[RecordBatch]
    var claim: Atomic[DType.int64]
    # True when combine chose the dense-rank counting sort: the per-worker
    # batches stay unfolded in `partitions`, `num_partitions` is 1 (no
    # per-partition sort), and finalize concatenates and counting-sorts them.
    var string_dictrank: Bool

    def __init__(out self):
        self.partitions = Slab[RecordBatch]()
        self.combined = None
        self.claim = Atomic[DType.int64](Int64(0))
        self.string_dictrank = False

    def __keep_alive(mut self):
        pass


# =============================================================================
# SortSink
# =============================================================================


struct SortSink(MorselSink):
    """The sort of a pipeline's rows by a `SortSinkData`, as a `MorselSink`.
    See the module header for the routes."""

    comptime Local = SortSinkLocal
    comptime Global = SortSinkGlobal
    comptime Output = RecordBatch
    comptime Source = NeverMorselSource

    var _spec: SortSinkData
    var _routes: SortSinkRoutes

    def __init__(
        out self, var spec: SortSinkData, routes: SortSinkRoutes = SortSinkRoutes()
    ):
        self._spec = spec^
        self._routes = routes

    def init_local(self) raises -> Self.Local:
        return SortSinkLocal()

    def init_global(self, out sink_global: Self.Global) raises:
        sink_global = SortSinkGlobal()

    def consume[
        o_local: Origin[mut=True], o_global: Origin[mut=True],
    ](
        self,
        worker_id: Int,
        ref [o_local] local: Self.Local,
        ref [o_global] sink_global: Self.Global,
        var batch: RecordBatch,
    ) raises:
        if batch.num_rows() == 0:
            _ = batch^
            return
        # A batch with a selection mask is materialized before it is kept.
        batch = materialize_selection_if_present(batch^)
        if batch.num_rows() == 0:
            _ = batch^
            return
        local.batches.append(batch^)

    def combine[
        o_global: Origin[mut=True], o_mem: Origin[mut=True],
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        var states: Slab[OwnedPointer[Self.Local]],
        ref [o_mem] reservation: MemoryReservation,
    ) raises:
        # One batch per worker with rows, in worker order, each folded in one
        # sized pass (`fold_batches_into_one`, which also merges the key's
        # validity: the STRING kernels read it to place NULLs).
        var n = len(states)
        var states_owned = states^
        for w in range(n):
            var owned_ptr = states_owned.take_slot_unchecked(w)
            var local = owned_ptr^.into_inner()
            var nb = local.num_batches()
            var staged = Slab[RecordBatch]()
            for i in range(nb):
                var b = local.batches.take_slot_unchecked(i)
                if b.num_rows() == 0:
                    _ = b^
                    continue
                staged.append(b^)
            local.batches.set_len_unchecked(0)
            _ = local^
            if len(staged) == 0:
                _ = staged^
            else:
                sink_global.partitions.append(fold_batches_into_one(staged^))
        states_owned.set_len_unchecked(0)
        _ = states_owned^

        # The route, decided once (see the module header).
        var parallel_ok = False
        var dictrank_ok = False
        var npart_now = len(sink_global.partitions)
        if len(self._spec.sort_keys) == 1 and npart_now >= 1:
            var total = 0
            for p in range(npart_now):
                total += sink_global.partitions[p].num_rows()
            if total >= self._routes.parallel_min_rows:
                ref probe = sink_global.partitions[0]
                ref key0 = self._spec.sort_keys[0]
                # The counting sort takes any partition count: it concatenates
                # the partitions itself and needs no pre-sorted runs. With more
                # than one partition the gate samples partition 0.
                if self._routes.dictrank and can_dictrank_sort_single_key_string(
                    probe, key0, True, self._routes.dictrank_max_distinct
                ):
                    dictrank_ok = True
                elif npart_now > 1:
                    # The partitioned sort needs several partitions to spread
                    # over the workers; one partition takes the serial kernel.
                    parallel_ok = can_parallel_sort_single_key(
                        probe, 1, key0, force=True
                    )
                    if (
                        not parallel_ok
                        and self._routes.parallel_string
                        and can_parallel_sort_single_key_string(
                            probe, 1, key0, force=True
                        )
                    ):
                        parallel_ok = True
        sink_global.string_dictrank = dictrank_ok
        if not dictrank_ok and not parallel_ok:
            # The serial route: fold the partitions, in order, into one batch.
            var npart = len(sink_global.partitions)
            var staged_p = Slab[RecordBatch]()
            for p in range(npart):
                staged_p.append(sink_global.partitions.take_slot_unchecked(p))
            sink_global.partitions.set_len_unchecked(0)
            if len(staged_p) == 0:
                _ = staged_p^
            else:
                sink_global.combined = fold_batches_into_one(staged_p^)

    def num_partitions[o: Origin](
        self, ref [o] sink_global: Self.Global
    ) -> Int:
        if sink_global.string_dictrank:
            # A per-partition sort is the wrong answer on this route: the
            # counting sort is global.
            return PARTITIONS_IMPOSSIBLE
        var np = len(sink_global.partitions)
        if np > 1:
            return np
        # One partition (or the serial route's one folded batch): a fan-out
        # would hand every worker zero work.
        return PARTITIONS_TRIVIAL

    def combine_partition[o_global: Origin[mut=True]](
        self,
        ref [o_global] sink_global: Self.Global,
        partition_idx: Int,
    ) raises:
        # Each partition is sorted on its own executor worker by the serial
        # kernel (no fork-join nests under the live dispatch); finalize merges.
        if partition_idx < 0 or partition_idx >= len(sink_global.partitions):
            return
        # Swap the batch out for an empty one, sort it, swap it back.
        var b = sink_global.partitions.replace(partition_idx, RecordBatch())
        if b.num_rows() <= 1:
            var old = sink_global.partitions.replace(partition_idx, b^)
            _ = old^
            return
        var sorted = _execute_sort_sink(b^, _copy_spec(self._spec))
        var old2 = sink_global.partitions.replace(partition_idx, sorted^)
        _ = old2^

    def finalize[disp_o: Origin[mut=True]](
        self,
        var sink_global: Self.Global,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        cancel_token: CancellationToken,
    ) raises -> FinalizeOutput[Self]:
        # finalize runs after the combine_partition dispatch has returned, so
        # the pool is idle and the merges, the concat and the gathers below
        # may fork on it.
        var pool = SharedForkJoinHandle[True, disp_o](
            Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr)
        )
        var nw = self._routes.num_workers
        var out_batch: RecordBatch
        # `partitions` is non-empty only on the counting-sort route (any
        # count) and the partitioned route (more than one); the serial route
        # left one folded batch in `combined`, or nothing.
        var npart = len(sink_global.partitions)
        if sink_global.string_dictrank and npart >= 1:
            var parts = Slab[RecordBatch]()
            for p in range(npart):
                parts.append(sink_global.partitions.replace(p, RecordBatch()))
            sink_global.partitions.set_len_unchecked(0)
            _ = sink_global^
            var combined: RecordBatch
            if npart == 1:
                combined = parts.take_slot_unchecked(0)
                parts.set_len_unchecked(0)
            else:
                combined = concat_record_batches_column_parallel(
                    parts^, dispatcher_ptr[], cancel_token.clone()
                )
            out_batch = parallel_dictrank_sort_string(
                combined^,
                self._spec.sort_keys[0],
                self._spec.descending[0],
                pool,
                nw,
                self._routes.dictrank_max_distinct,
            )
        elif npart > 1:
            # Each partition was sorted by combine_partition; merge them. A
            # STRING key takes the comparator merge (the flat-key merge reads
            # only INT64 / INT32 / FLOAT64).
            var key0 = self._spec.sort_keys[0]
            var desc0 = self._spec.descending[0]
            var key_is_string = _batch_key_is_string(
                sink_global.partitions[0], key0
            )
            var parts = Slab[RecordBatch]()
            for p in range(npart):
                parts.append(sink_global.partitions.replace(p, RecordBatch()))
            sink_global.partitions.set_len_unchecked(0)
            _ = sink_global^
            if key_is_string:
                out_batch = merge_sorted_partitions_single_key_string_parallel(
                    parts^, key0, desc0, pool, nw
                )
            else:
                out_batch = merge_sorted_partitions_single_key(
                    parts^, key0, desc0, pool
                )
        elif not sink_global.combined:
            out_batch = RecordBatch()
            _ = sink_global^
        else:
            var batch = sink_global.combined.take()
            _ = sink_global^
            out_batch = _execute_sort_sink(batch^, _copy_spec(self._spec))
        var out_slab = Slab[Self.Output].create(1)
        out_slab.append(out_batch^)
        return FinalizeOutput[Self](out_slab^)

    def combine_trace_label(self) -> StaticString:
        """This sink's name in the executor's combine trace. Diagnostic only."""
        return "SortSink"

    def capabilities(self) -> SinkCapabilities:
        # `num_partitions` > 1 is the declaration that combine_partition runs.
        var caps = SinkCapabilities()
        caps.output_is_batch = True
        return caps
