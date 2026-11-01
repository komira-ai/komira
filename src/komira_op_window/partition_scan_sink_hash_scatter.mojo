# =============================================================================
# partition_scan_sink_hash_scatter -- the window operator with a parallel sort
# =============================================================================
#
# The range driver (`partition_scan_sink_parallel`) sorts the whole batch on
# one thread and parallelizes only the evaluation; on a large batch the sort
# is most of the time. This driver sorts in parallel instead:
#
#   1. assign each row a bucket 0..K-1 by its partition-key tuple's RANGE:
#      K-1 equi-depth splitter tuples sampled from the input, and
#      `bucket(row) = #{ s : splitter_s <= key(row) }`;
#   2. per bucket, on a worker: gather the bucket's rows, sort them
#      (`partition_keys.sort_partition_batch`) and evaluate them;
#   3. concatenate the buckets in bucket order.
#
# The bucket is a function of the key tuple, so a partition never spans two
# buckets; and it is non-decreasing in the key tuple, so bucket order is key
# order and the concatenation is sorted by (partition keys ++ order keys)
# globally, the order every driver emits
# (`komira_exec_types.partition_by_output_contract`).
#
# Served for one or more INT64 partition keys that hold no NULL: the splitters
# compare raw values, which agrees with the sort only when no key is NULL
# (NULLs sort last). With no partition key every row would share one bucket,
# so that case, and other key types, take the range driver.
#
# Splitters come from a fixed stride sample, and each bucket keeps its rows in
# input order before its stable sort, so the output does not depend on the
# worker count or the scheduling beyond the bucket count.
# =============================================================================

from std.atomic import Atomic
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_PARTITION_BY
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import gather_batch
from komira_operator_api.sink_batch_fold import fold_batches_into_one
from komira_physical_plan.physical_plan import PartitionBySinkData

from .partition_keys import column_has_nulls, sort_partition_batch
from .partition_scan_sink import (
    _copy_sink_data,
    _empty_output,
    _eval_sorted,
    _execute_partition_by_sink,
)


# =============================================================================
# Thresholds
# =============================================================================

# Below this many rows the scatter and gathers cost more than the parallel
# sort saves; the range driver (or the serial kernel) runs instead.
comptime _HASH_SCATTER_MIN_ROWS: Int = 65_536

# At most this many buckets, so each holds enough rows to amortize its sort.
comptime _HASH_SCATTER_MAX_K: Int = 32

# Rows sampled to choose the splitters: >= 128 per splitter at K <= 32.
comptime _RANGE_SPLITTER_SAMPLE_TARGET: Int = 4096


# =============================================================================
# The range scatter
# =============================================================================


def _all_int64_partition_keys(
    batch: RecordBatch, partition_keys: List[String]
) raises -> Bool:
    """True iff there is a partition key and each is an INT64 column with no
    NULL (the keys this driver's raw-value splitters order as the sort does).
    With no key every row would land in one bucket."""
    if len(partition_keys) == 0:
        return False
    for k in partition_keys:
        ref c = batch.column_at(batch.schema.column_index(k))
        if c.arrow_type != ArrowType.INT64:
            return False
        if column_has_nulls(c):
            return False
    return True


def _sample_key_tuples_int64(
    batch: RecordBatch,
    key_indices: List[Int],
    target: Int,
) raises -> List[Int64]:
    """Stride-sample rows; `out[i * num_keys + j]` is sample i's key j. The
    first sample is at `stride // 2`, so samples sit at stride centres."""
    var num_rows = batch.num_rows()
    var num_keys = len(key_indices)
    var want = target
    if want > num_rows:
        want = num_rows
    if want < 1:
        want = 1
    var stride = num_rows // want
    if stride < 1:
        stride = 1
    var out = List[Int64](capacity=want * num_keys)
    var r = stride // 2
    while r < num_rows:
        for j in range(num_keys):
            ref kc = batch.column_at(key_indices[j])
            out.append(kc._data.get_typed[Scalar[DType.int64]](kc._offset + r))
        r += stride
    return out^


@always_inline
def _cmp_sample_tuples(samples: List[Int64], num_keys: Int, a: Int, b: Int) -> Int:
    """Lexicographic compare of sample tuples `a` and `b`: -1 / 0 / 1."""
    var ba = a * num_keys
    var bb = b * num_keys
    for j in range(num_keys):
        var va = samples[ba + j]
        var vb = samples[bb + j]
        if va < vb:
            return -1
        if va > vb:
            return 1
    return 0


def _sort_sample_perm(samples: List[Int64], num_keys: Int, n: Int) -> List[Int]:
    """A stable bottom-up merge sort of sample indices `[0, n)` by tuple.
    `n` is at most `_RANGE_SPLITTER_SAMPLE_TARGET`."""
    var cur = List[Int](capacity=n)
    for i in range(n):
        cur.append(i)
    if n <= 1:
        return cur^
    var buf = List[Int](capacity=n)
    for _ in range(n):
        buf.append(0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var o = lo
            while i < mid and j < hi:
                # Strict `<` for the right run keeps the merge stable.
                if _cmp_sample_tuples(samples, num_keys, cur[j], cur[i]) < 0:
                    buf[o] = cur[j]
                    j += 1
                else:
                    buf[o] = cur[i]
                    i += 1
                o += 1
            while i < mid:
                buf[o] = cur[i]
                i += 1
                o += 1
            while j < hi:
                buf[o] = cur[j]
                j += 1
                o += 1
            lo = hi
        for t in range(n):
            cur[t] = buf[t]
        width *= 2
    return cur^


def _choose_range_splitters_int64(
    batch: RecordBatch,
    key_indices: List[Int],
    k: Int,
) raises -> List[Int64]:
    """The `k - 1` equi-depth splitter tuples, flattened row-major and
    non-decreasing. A row whose key equals a splitter goes to the bucket
    after it, so equal keys share a bucket. Empty when `k < 2`, there are no
    keys or no rows (then every row is bucket 0)."""
    var out = List[Int64]()
    var num_keys = len(key_indices)
    if k < 2 or num_keys == 0 or batch.num_rows() == 0:
        return out^
    var samples = _sample_key_tuples_int64(batch, key_indices, _RANGE_SPLITTER_SAMPLE_TARGET)
    var n_samples = len(samples) // num_keys
    if n_samples == 0:
        return out^
    var perm = _sort_sample_perm(samples, num_keys, n_samples)
    for b in range(1, k):
        var pos = (b * n_samples) // k
        if pos >= n_samples:
            pos = n_samples - 1
        var src = perm[pos]
        for j in range(num_keys):
            out.append(samples[src * num_keys + j])
    return out^


@always_inline
def _bucket_for_key_single(splitters: List[Int64], n_split: Int, v: Int64) -> Int:
    """`#{ s : splitters[s] <= v }` over non-decreasing splitters. `mid` is
    `lo + ((hi - lo) >> 1)`: the shift avoids the sign fix-up of a signed
    `// 2`, and the form relies only on `hi >= lo`."""
    var lo = 0
    var hi = n_split
    while lo < hi:
        var mid = lo + ((hi - lo) >> 1)
        if splitters[mid] <= v:
            lo = mid + 1
        else:
            hi = mid
    return lo


@always_inline
def _bucket_for_key_tuple(
    splitters: List[Int64], num_keys: Int, n_split: Int, row_vals: List[Int64]
) -> Int:
    """The number of splitter tuples lexicographically `<=` `row_vals`."""
    var lo = 0
    var hi = n_split
    while lo < hi:
        var mid = lo + ((hi - lo) >> 1)
        var base = mid * num_keys
        var c = 0
        for j in range(num_keys):
            var sv = splitters[base + j]
            var rv = row_vals[j]
            if sv < rv:
                c = -1
                break
            if sv > rv:
                c = 1
                break
        if c <= 0:
            lo = mid + 1
        else:
            hi = mid
    return lo


def _scatter_rows_to_buckets_int64(
    batch: RecordBatch,
    partition_keys: List[String],
    k: Int,
) raises -> List[List[Int]]:
    """The row indices of each of `k` buckets, in ascending row order. Every
    partition key is an INT64 column with no NULL (`_all_int64_partition_keys`).
    Rows with the same key tuple share a bucket, and the bucket is
    non-decreasing in the key tuple."""
    var num_rows = batch.num_rows()
    var key_indices = List[Int]()
    for kn in partition_keys:
        key_indices.append(batch.schema.column_index(kn))
    var num_keys = len(key_indices)

    var buckets = List[List[Int]]()
    var reserve_per = (num_rows // k) + 16
    for _ in range(k):
        buckets.append(List[Int](capacity=reserve_per))

    var splitters = _choose_range_splitters_int64(batch, key_indices, k)
    var n_split = 0
    if num_keys > 0:
        n_split = len(splitters) // num_keys
    if n_split == 0:
        for r in range(num_rows):
            buckets[0].append(r)
        return buckets^

    if num_keys == 1:
        ref kc = batch.column_at(key_indices[0])
        var koff = kc._offset
        for r in range(num_rows):
            var v = kc._data.get_typed[Scalar[DType.int64]](koff + r)
            buckets[_bucket_for_key_single(splitters, n_split, v)].append(r)
    else:
        var row_vals = List[Int64](capacity=num_keys)
        for _ in range(num_keys):
            row_vals.append(Int64(0))
        for r in range(num_rows):
            for j in range(num_keys):
                ref kc = batch.column_at(key_indices[j])
                row_vals[j] = kc._data.get_typed[Scalar[DType.int64]](kc._offset + r)
            buckets[_bucket_for_key_tuple(splitters, num_keys, n_split, row_vals)].append(r)
    return buckets^


def _execute_partition_by_sink_bucket(
    full_batch: RecordBatch,
    bucket_indices: List[Int],
    sink_data: PartitionBySinkData,
) raises -> RecordBatch:
    """One bucket: gather its rows, sort them, evaluate them. The gathers of
    all buckets together hold a second copy of the input, so the peak is
    about twice the input size; this is not counted in a MemoryReservation."""
    if len(bucket_indices) == 0:
        return _empty_output(sink_data)
    var sorted_sub = sort_partition_batch(
        gather_batch(full_batch, bucket_indices),
        sink_data.partition_keys,
        sink_data.order_keys,
        sink_data.descending,
    )
    return _eval_sorted(sorted_sub, sink_data)


# =============================================================================
# Dispatch state
# =============================================================================


struct _HashScatterPartitionByState(KeepAlive, Movable):
    """The state the bucket workers share: the input batch, the spec and the
    bucket row lists (read-only), one output slot per bucket, a bucket
    counter and the first error. Bucket `b` is claimed once and its worker is
    the only writer of `morsel_results[b]`; the state outlives the dispatch."""

    var input_batch: OwnedPointer[RecordBatch]
    var sink_spec: OwnedPointer[PartitionBySinkData]
    var bucket_indices: OwnedPointer[List[List[Int]]]
    var morsel_results: OwnedPointer[Slab[Optional[RecordBatch]]]
    var err_flag: OwnedPointer[Atomic[DType.int8]]
    var err_msg: OwnedPointer[String]
    var bucket_counter: OwnedPointer[Atomic[DType.int64]]
    var num_buckets: Int

    def __init__(
        out self,
        var input_batch: RecordBatch,
        var sink_spec: PartitionBySinkData,
        var bucket_indices: List[List[Int]],
        var morsel_results: Slab[Optional[RecordBatch]],
        num_buckets: Int,
    ):
        self.input_batch = OwnedPointer(input_batch^)
        self.sink_spec = OwnedPointer(sink_spec^)
        self.bucket_indices = OwnedPointer(bucket_indices^)
        self.morsel_results = OwnedPointer(morsel_results^)
        # SAFETY: Atomic is not Movable, so each is constructed in place on a
        # fresh heap slot, written once before the pointer is wrapped. The
        # OwnedPointer owns the slot and frees it when the state is dropped;
        # no other owner exists.
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
struct _HashScatterPartitionByTask(Segment):
    """Each worker claims buckets until none is left."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the driver binds `run_with_state[_HashScatterPartitionByState,
        # ...]`, so `State` is that type; the cast only names it.
        var sp = UnsafePointer(to=state).bitcast[_HashScatterPartitionByState]()
        var num_buckets = sp[].num_buckets
        while True:
            if sp[].err_flag[].load() != Int8(0):
                return
            var b = Int(sp[].bucket_counter[].fetch_add(Int64(1)))
            if b >= num_buckets:
                return
            try:
                ref lists = sp[].bucket_indices[]
                var bucket_out = _execute_partition_by_sink_bucket(
                    sp[].input_batch[], lists[b], sp[].sink_spec[]
                )
                sp[].morsel_results[][b] = Optional[RecordBatch](bucket_out^)
            except e:
                var expected = Int8(0)
                if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                    sp[].err_msg[] = String(e)
                return


# =============================================================================
# The driver
# =============================================================================


def _execute_partition_by_sink_hash_scatter(
    var batch: RecordBatch,
    sink_data: PartitionBySinkData,
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """The window operator with a range scatter and a sort per bucket on the
    engine's workers. Every partition key is an INT64 column with no NULL
    (`_all_int64_partition_keys`). The rows and their order are those of
    `_execute_partition_by_sink`."""
    var num_rows = batch.num_rows()
    if num_rows == 0:
        _ = batch^
        return _empty_output(sink_data)

    var k = dispatcher.worker_count()
    if k > _HASH_SCATTER_MAX_K:
        k = _HASH_SCATTER_MAX_K
    if k <= 1:
        return _execute_partition_by_sink(batch^, sink_data)

    var bucket_indices = _scatter_rows_to_buckets_int64(batch, sink_data.partition_keys, k)
    var morsel_results = Slab[Optional[RecordBatch]].create(k)
    for _ in range(k):
        morsel_results.append(Optional[RecordBatch](None))

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: bucket b is claimed once, and its worker is the only
    #     writer of `morsel_results[b]`; the batch, the spec and the bucket
    #     lists are read-only (frozen before the dispatch).
    #   * Liveness: `state` lives on this stack across `run_with_state`, which
    #     returns after every worker has exited.
    #   * No-realloc: `morsel_results` is sized to k before the dispatch and
    #     only assigned in place.
    var state = _HashScatterPartitionByState(
        batch^,
        _copy_sink_data(sink_data),
        bucket_indices^,
        morsel_results^,
        num_buckets=k,
    )
    var task_back = dispatcher.run_with_state[
        _HashScatterPartitionByState, _HashScatterPartitionByTask
    ](state, _HashScatterPartitionByTask(Int32(0)), k, cancel_token.clone(), site_id=SITE_PARTITION_BY)
    _ = task_back^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    ref results = state.morsel_results[]
    var staged = Slab[RecordBatch]()
    for b in range(k):
        var taken = results.replace(b, Optional[RecordBatch](None))
        if not taken:
            raise Error("PartitionByHashScatter: bucket " + String(b) + " produced no output")
        var rb = taken.take()
        if rb.num_rows() == 0:
            _ = rb^
            continue
        staged.append(rb^)
    var out_batch: RecordBatch
    if len(staged) > 0:
        out_batch = fold_batches_into_one(staged^)
    else:
        _ = staged^
        out_batch = _empty_output(sink_data)
    _ = state^
    _ = cancel_token^
    return out_batch^
