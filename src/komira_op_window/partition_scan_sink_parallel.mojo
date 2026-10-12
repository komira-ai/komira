# =============================================================================
# partition_scan_sink_parallel -- the window operator over whole-partition
# buckets, in parallel
# =============================================================================
#
# `_execute_partition_by_sink_parallel` gives the rows of
# `partition_scan_sink._execute_partition_by_sink`, in the same order, using
# the engine's workers:
#
#   1. sort the batch once (`partition_keys.sort_partition_batch`);
#   2. find the partition starts and cut them into K contiguous buckets of
#      whole partitions, balanced by rows (`_compute_bucket_partition_ranges`);
#   3. evaluate each bucket on a worker (`LocalDispatcher.run_with_state`);
#      every window kernel reads only its own partition, so a partition gives
#      the same cells in a bucket as in the whole batch;
#   4. concatenate the buckets in bucket order, which is the sorted order.
#
# Below `_PARALLEL_PARTITION_BY_MIN_ROWS` rows, with fewer than
# `_PARALLEL_PARTITION_BY_MIN_PARTITIONS` partitions, or with one worker, it
# evaluates the sorted batch on the calling thread. Above
# `_HASH_SCATTER_MIN_ROWS` rows, with more than one worker and INT64 partition
# keys holding no NULL, it takes the scatter driver
# (`partition_scan_sink_hash_scatter`), which also sorts in parallel. Every
# route emits rows in (partition keys ASC ++ order keys per direction) order
# (`komira_exec_types.partition_by_output_contract`), NULLs last.
#
# Bucket assignment is a range split, so the result does not depend on the
# worker count or the scheduling.
# =============================================================================

from std.atomic import Atomic
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_arrow.record_batch import RecordBatch
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_PARTITION_BY
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_collections.slab import Slab
from komira_column_kernels.batch_slice import _slice_batch_range
from komira_operator_api.sink_batch_fold import fold_batches_into_one
from komira_physical_plan.physical_plan import PartitionBySinkData
from komira_plan_expr.partition_expr import PartitionExpr
from komira_arrow.schema import SchemaBuilder

from .partition_keys import _detect_partition_boundaries, sort_partition_batch
from .partition_scan_sink import _empty_output, _eval_sorted
from .partition_scan_sink_hash_scatter import (
    _HASH_SCATTER_MIN_ROWS,
    _all_int64_partition_keys,
    _execute_partition_by_sink_hash_scatter,
)


# =============================================================================
# Thresholds
# =============================================================================

# Below this many rows the dispatch, slice and concatenation cost more than
# the parallel evaluation saves.
comptime _PARALLEL_PARTITION_BY_MIN_ROWS: Int = 65_536

# Below this many partitions there is too little to spread over buckets.
comptime _PARALLEL_PARTITION_BY_MIN_PARTITIONS: Int = 4

# At most this many buckets, to bound the per-bucket fixed cost.
comptime _PARALLEL_PARTITION_BY_MAX_K: Int = 32


# =============================================================================
# Bucket ranges
# =============================================================================


def _compute_bucket_partition_ranges(
    bounds: List[Int], num_rows: Int, k: Int
) raises -> List[Int]:
    """Cut the partitions into `k` contiguous buckets, balanced by rows.

    `bounds` holds the partition starts of a batch of `num_rows` rows. Returns
    `k + 1` row indices: bucket `b` is rows `[out[b], out[b + 1])`. Every
    `out[b]` is a partition start (no partition is split) or `num_rows`; a
    bucket may be empty when there are fewer partitions than buckets.

    Greedy: bucket `b` ends at the first partition start past
    `(b + 1) * (num_rows / k)` rows.
    """
    var p = len(bounds)
    var bucket_starts = List[Int]()
    bucket_starts.append(0)

    if p == 0 or num_rows == 0:
        for _ in range(k):
            bucket_starts.append(0)
        return bucket_starts^

    var ext_bounds = List[Int]()
    for i in range(p):
        ext_bounds.append(bounds[i])
    ext_bounds.append(num_rows)

    if k <= 1:
        bucket_starts.append(num_rows)
        return bucket_starts^

    var target_rows = num_rows // k
    if target_rows < 1:
        target_rows = 1

    var current_bucket = 0
    var pi = 0
    while current_bucket < k - 1 and pi < p:
        var bucket_target = (current_bucket + 1) * target_rows
        while pi < p and ext_bounds[pi + 1] <= bucket_target:
            pi += 1
        # The partition that crossed the target closes this bucket.
        if pi >= p:
            bucket_starts.append(num_rows)
        else:
            bucket_starts.append(ext_bounds[pi])
        current_bucket += 1

    while len(bucket_starts) < k:
        bucket_starts.append(num_rows)
    bucket_starts.append(num_rows)
    return bucket_starts^


def _execute_partition_by_sink_slice(
    sorted_batch_full: RecordBatch,
    slice_start: Int,
    slice_len: Int,
    sink_data: PartitionBySinkData,
) raises -> RecordBatch:
    """The window output of rows `[slice_start, slice_start + slice_len)` of
    the sorted batch, a range of whole partitions."""
    if slice_len == 0:
        return _empty_output(sink_data)
    var sliced = _slice_batch_range(sorted_batch_full, slice_start, slice_len)
    return _eval_sorted(sliced, sink_data)


# =============================================================================
# Dispatch state
# =============================================================================


struct _PartitionByParallelState(KeepAlive, Movable):
    """The state the bucket workers share: the sorted batch, the spec and
    the bucket starts (read-only), one output slot per bucket, a bucket
    counter and the first error.

    Bucket `b` is claimed once (`bucket_counter.fetch_add`) and its worker is
    the only writer of `morsel_results[b]`. The state lives on the driver's
    stack across `run_with_state`, which returns after every worker has
    exited; the fields are heap-stable behind `OwnedPointer`.
    """

    var sorted_batch: OwnedPointer[RecordBatch]
    var sink_spec: OwnedPointer[PartitionBySinkData]
    var bucket_starts: OwnedPointer[List[Int]]
    var morsel_results: OwnedPointer[Slab[Optional[RecordBatch]]]
    var err_flag: OwnedPointer[Atomic[DType.int8]]
    var err_msg: OwnedPointer[String]
    var bucket_counter: OwnedPointer[Atomic[DType.int64]]
    var num_buckets: Int

    def __init__(
        out self,
        var sorted_batch: RecordBatch,
        var sink_spec: PartitionBySinkData,
        var bucket_starts: List[Int],
        var morsel_results: Slab[Optional[RecordBatch]],
        num_buckets: Int,
    ):
        self.sorted_batch = OwnedPointer(sorted_batch^)
        self.sink_spec = OwnedPointer(sink_spec^)
        self.bucket_starts = OwnedPointer(bucket_starts^)
        self.morsel_results = OwnedPointer(morsel_results^)
        # Atomic is not Movable: construct it in place on its heap slot.
        var fraw = alloc[Atomic[DType.int8]](1)
        UnsafePointer(to=fraw[].value).unsafe_write(Scalar[DType.int8](0))
        self.err_flag = OwnedPointer[Atomic[DType.int8]](unsafe_from_raw_pointer=fraw)
        self.err_msg = OwnedPointer(String(""))
        var craw = alloc[Atomic[DType.int64]](1)
        UnsafePointer(to=craw[].value).unsafe_write(Scalar[DType.int64](0))
        self.bucket_counter = OwnedPointer[Atomic[DType.int64]](
            unsafe_from_raw_pointer=craw
        )
        self.num_buckets = num_buckets


@fieldwise_init
struct _PartitionByParallelTask(Segment):
    """Each worker claims buckets until none is left and writes each
    bucket's output into its slot."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the driver binds `run_with_state[_PartitionByParallelState,
        # ...]`, so `State` is that type; the cast only names it.
        var sp = UnsafePointer(to=state).bitcast[_PartitionByParallelState]()
        var num_buckets = sp[].num_buckets
        while True:
            if sp[].err_flag[].load() != Int8(0):
                return
            var b = Int(sp[].bucket_counter[].fetch_add(Int64(1)))
            if b >= num_buckets:
                return
            try:
                ref starts = sp[].bucket_starts[]
                var bucket_out = _execute_partition_by_sink_slice(
                    sp[].sorted_batch[],
                    starts[b],
                    starts[b + 1] - starts[b],
                    sp[].sink_spec[],
                )
                sp[].morsel_results[][b] = Optional[RecordBatch](bucket_out^)
            except e:
                var expected = Int8(0)
                if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                    sp[].err_msg[] = String(e)
                return


def _copy_sink_data(sink_data: PartitionBySinkData) raises -> PartitionBySinkData:
    """A deep copy of a PartitionBySinkData (its fields are Movable only)."""
    var exprs_copy = List[PartitionExpr]()
    for i in range(len(sink_data.partition_exprs)):
        exprs_copy.append(sink_data.partition_exprs[i].copy())
    var sb = SchemaBuilder()
    for i in range(sink_data.output_schema.num_columns()):
        sb.add_field(sink_data.output_schema.field_at(i))
    return PartitionBySinkData(
        sink_data.partition_keys.copy(),
        sink_data.order_keys.copy(),
        sink_data.descending.copy(),
        exprs_copy^,
        sb.build(),
    )


def _collect_buckets(
    mut results: Slab[Optional[RecordBatch]],
    k: Int,
    sink_data: PartitionBySinkData,
    driver: StaticString,
) raises -> RecordBatch:
    """Concatenate the bucket outputs in bucket order (one sized fold; the
    validity of the window columns is merged with the values)."""
    var staged = Slab[RecordBatch]()
    for b in range(k):
        var taken = results.replace(b, Optional[RecordBatch](None))
        if not taken:
            raise Error(String(driver) + ": bucket " + String(b) + " produced no output")
        var rb = taken.take()
        if rb.num_rows() == 0:
            _ = rb^
            continue
        staged.append(rb^)
    if len(staged) == 0:
        _ = staged^
        return _empty_output(sink_data)
    return fold_batches_into_one(staged^)


# =============================================================================
# The driver
# =============================================================================


def _execute_partition_by_sink_parallel(
    var batch: RecordBatch,
    sink_data: PartitionBySinkData,
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """`_execute_partition_by_sink` on the engine's workers: the same rows in
    the same order."""
    var num_rows = batch.num_rows()
    if num_rows == 0:
        _ = batch^
        return _empty_output(sink_data)

    if (
        num_rows >= _HASH_SCATTER_MIN_ROWS
        and dispatcher.worker_count() > 1
        and _all_int64_partition_keys(batch, sink_data.partition_keys)
    ):
        return _execute_partition_by_sink_hash_scatter(
            batch^, sink_data, dispatcher, cancel_token^
        )

    var sorted_batch = sort_partition_batch(
        batch^, sink_data.partition_keys, sink_data.order_keys, sink_data.descending
    )
    var bounds = _detect_partition_boundaries(sorted_batch, sink_data.partition_keys)
    var num_partitions = len(bounds)

    var worker_count = dispatcher.worker_count()
    if (
        num_rows < _PARALLEL_PARTITION_BY_MIN_ROWS
        or num_partitions < _PARALLEL_PARTITION_BY_MIN_PARTITIONS
        or worker_count <= 1
    ):
        return _eval_sorted(sorted_batch, sink_data)

    var k = worker_count
    if k > num_partitions:
        k = num_partitions
    if k > _PARALLEL_PARTITION_BY_MAX_K:
        k = _PARALLEL_PARTITION_BY_MAX_K
    if k < 1:
        k = 1

    var bucket_starts = _compute_bucket_partition_ranges(bounds, num_rows, k)
    var morsel_results = Slab[Optional[RecordBatch]].create(k)
    for _ in range(k):
        morsel_results.append(Optional[RecordBatch](None))

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: bucket b is claimed once, and its worker is the only
    #     writer of `morsel_results[b]`; the batch, the spec and the bucket
    #     starts are read-only.
    #   * Liveness: `state` lives on this stack across `run_with_state`, which
    #     returns after every worker has exited.
    #   * No-realloc: `morsel_results` is sized to k before the dispatch and
    #     only assigned in place.
    var state = _PartitionByParallelState(
        sorted_batch^,
        _copy_sink_data(sink_data),
        bucket_starts^,
        morsel_results^,
        num_buckets=k,
    )
    var task_back = dispatcher.run_with_state[
        _PartitionByParallelState, _PartitionByParallelTask
    ](state, _PartitionByParallelTask(Int32(0)), k, cancel_token.clone(), site_id=SITE_PARTITION_BY)
    _ = task_back^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    var out_batch = _collect_buckets(
        state.morsel_results[], k, sink_data, "PartitionByParallel"
    )
    _ = state^
    _ = cancel_token^
    return out_batch^
