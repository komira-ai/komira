# =============================================================================
# sort_parallel_string -- the parallel single-key STRING / BINARY sort, and
# the merge of sorted STRING partitions
# =============================================================================
#
# `parallel_sort_single_key_string`: each of P contiguous slices is sorted on
# its own chunk (`sort_parallel_string_kernels`), then the P runs are merged by
# the parallel pairwise tree (`sort_parallel_string_merge`), and the batch is
# gathered once. `merge_sorted_partitions_single_key_string_parallel` merges
# partitions that are already sorted the same way;
# `merge_sorted_partitions_single_key_string` is its serial form, a comparator
# heap merge, kept as the oracle the parallel merge is tested against. Nothing
# in the sort sink calls these entries yet.
#
# Every entry gives the permutation of one serial `sort_indices_string` over
# the rows (the partitions concatenated in slab order): byte-wise order, the
# shorter string first on a shared prefix, NULLS FIRST ascending and NULLS LAST
# descending, ties in input order.

from std.builtin.swap import swap
from std.memory import UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import (
    SharedForkJoinHandle,
    serial_fork_join_handle,
)
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import (
    gather_batch,
    gather_batch_dispatch,
)
from komira_operator_api.sink_batch_fold import fold_batches_into_one

from .sort_parallel import (
    MIN_PARALLEL_SORT_ROWS,
    _PermScratch,
    resolve_sort_workers,
)
from .sort_parallel_string_kernels import (
    _pack_prefix8,
    _sort_slice_string_full,
    _str_sift,
)
from .sort_parallel_string_merge import _parallel_pairwise_tree_merge


def _extract_string_validity(imm keys: Column[HeapRegion]) raises -> List[Bool]:
    """Resolve the column's validity bitmap into a flat per-logical-row
    `List[Bool]` on the calling thread (valid == True). Empty if the column has
    no validity. This is the cross-thread boundary: workers read this list,
    never the reference-counted `Bitmap`."""
    var n = keys._length
    var out = List[Bool](capacity=n)
    if not keys._validity:
        return out^
    ref bm = keys._validity.value()
    var col_offset = keys._offset
    for r in range(n):
        out.append(bm.test(col_offset + r))
    return out^


@fieldwise_init
struct _StringPermPayload(Movable, Deinitable):
    """Shared fork-join payload for the per-slice STRING sort: the permutation,
    its merge scratch, and the per-row direction-encoded u64 prefix key. All
    three are pre-sized to `n`; a chunk only setitems its own slice."""
    var perm: List[Int]
    var scratch: List[Int]
    var pk: List[UInt64]

    def take_perm(mut self) -> List[Int]:
        var out = List[Int]()
        swap(self.perm, out)
        return out^

    def take_scratch(mut self) -> List[Int]:
        var out = List[Int]()
        swap(self.scratch, out)
        return out^

    def take_pk(mut self) -> List[UInt64]:
        var out = List[UInt64]()
        swap(self.pk, out)
        return out^


@fieldwise_init
struct _StringSliceSortWork[
    o_off: Origin[mut=False], o_data: Origin[mut=False],
](SharedChunkWork):
    """Chunk `p` fills the prefix keys for, then fully string-sorts,
    `perm[slice_lo[p]:slice_lo[p+1])`."""
    # SAFETY: raw STRING offsets/data pointers with CONCRETE origins pinned to
    # the caller's borrowed key column; read-only, never escape this module.
    var offsets_ptr: UnsafePointer[Scalar[DType.int32], Self.o_off]
    var data_ptr: UnsafePointer[Scalar[DType.uint8], Self.o_data]
    var col_offset: Int
    var has_validity: Bool
    var desc: Bool
    var slice_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes a `List[Bool]` as `input` and a
        # `_StringPermPayload` as `payload` to the `pool.run` that dispatches
        # this work, so each cast is to the exact type of the referent.
        var vp = UnsafePointer(to=input).bitcast[List[Bool]]()
        var sp = UnsafePointer(to=payload).bitcast[_StringPermPayload]()
        var lo = self.slice_lo[chunk_id]
        var hi = self.slice_lo[chunk_id + 1]
        # Fill the prefix key for this slice's original rows (perm is iota
        # here, so slice [lo,hi) covers original rows lo..hi).
        var pk_p = UnsafePointer(to=sp[].pk)
        for row in range(lo, hi):
            var k = _pack_prefix8(
                self.offsets_ptr, self.data_ptr, self.col_offset, row, 0
            )
            if self.desc:
                k = ~k
            pk_p[][row] = k
        var perm_p = UnsafePointer(to=sp[].perm)
        var scratch_p = UnsafePointer(to=sp[].scratch)
        _sort_slice_string_full(
            self.offsets_ptr, self.data_ptr, self.col_offset, vp[],
            self.has_validity, perm_p[], lo, hi, scratch_p[], self.desc,
        )


def _parallel_string_perm[
    o_off: Origin[mut=False], o_data: Origin[mut=False],
    has_pool: Bool, disp_o: Origin[mut=True],
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    n: Int,
    imm valid: List[Bool],
    has_validity: Bool,
    descending: Bool,
    nw_hint: Int,
    pool: SharedForkJoinHandle[has_pool, disp_o],
) raises -> List[Int]:
    """Produce the global stable string-sort permutation: a per-slice parallel
    stable string sort, then the parallel pairwise-tree merge of the slices.

    `perm[i]` is the original row index at sorted position `i`. Byte-identical to
    a single serial `sort_indices_string` (contiguous slices + lower-run-wins-on-
    tie == lower-original-index-wins-on-tie == stable global order)."""
    var perm = List[Int](capacity=n)
    for i in range(n):
        perm.append(i)
    if n < 2:
        return perm^

    var nw = nw_hint
    if nw < 1:
        nw = 1
    if nw > n:
        nw = n

    var slice_lo = List[Int](capacity=nw + 1)
    for p in range(nw + 1):
        slice_lo.append((p * n) // nw)

    # ---- Phase 1: PARALLEL per-slice stable string sort ----
    var scratch = List[Int](capacity=n)
    for _ in range(n):
        scratch.append(0)

    # Precomputed chunk-0 DIRECTION-ENCODED u64 prefix key per ORIGINAL row,
    # filled in parallel by each worker for ITS slice's original rows (perm is
    # iota at worker entry, so slice [lo,hi) covers original rows lo..hi). The
    # merge then compares these integers (one compare per step) and only
    # touches the full string buffers on a prefix TIE, which keeps each
    # comparison cheap.
    var pk = List[UInt64](capacity=n)
    for _ in range(n):
        pk.append(0)

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` reads/writes ONLY perm[slice_lo[p]:slice_lo[p+1])
    #     and scratch[slice_lo[p]:slice_lo[p+1]) (the slice boundaries tile [0,n)
    #     exactly, no overlap), and fills pk over the SAME row band. The STRING
    #     `offsets`/`data` byte buffers and the flat `valid` list are READ-ONLY
    #     across all chunks (no two chunks write the same element).
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier; `valid`
    #     is borrowed through a concrete immutable origin, the offsets/data
    #     pointers are pinned to the borrowed `keys` column on the caller's
    #     frame, and the perm/scratch/pk payload is MOVED onto the dispatch
    #     State. No reference-counted value is built on a worker:
    #     validity is the pre-resolved flat `List[Bool]`.
    #   * No-realloc: `perm`/`scratch`/`pk` are sized to `n` ONCE before the
    #     dispatch; the slice sort is setitem on existing slots, never append.
    var buf = pool.run[
        _StringSliceSortWork[o_off, o_data],
        List[Bool],
        _StringPermPayload,
        origin_of(valid),
    ](
        _StringSliceSortWork[o_off, o_data](
            offsets_ptr,
            data_ptr,
            col_offset,
            has_validity,
            descending,
            slice_lo.copy(),
        ),
        valid,
        _StringPermPayload(perm^, scratch^, pk^),
        nw,
    )

    if nw == 1:
        return buf.take_perm()

    # ---- Phase 2: PARALLEL pairwise-tree co-rank merge ----
    var bounds = List[Int](capacity=nw + 1)
    for p in range(nw + 1):
        bounds.append(slice_lo[p])
    var pk_done = buf.take_pk()
    var merged = _parallel_pairwise_tree_merge[
        o_off, o_data, has_pool, disp_o
    ](
        _PermScratch(buf.take_perm(), buf.take_scratch()),
        pk_done,
        offsets_ptr, data_ptr, col_offset,
        valid, has_validity, descending, bounds^, nw, pool,
    )
    _ = buf^
    _ = pk_done^
    return merged^


@always_inline
def _is_string_key(imm batch: RecordBatch, key_name: String) -> Bool:
    """True iff `key_name` is a STRING / BINARY column."""
    try:
        var key_idx = batch.schema.column_index(key_name)
        ref key_col = batch.column_at(key_idx)
        return (
            key_col.arrow_type == ArrowType.STRING
            or key_col.arrow_type == ArrowType.BINARY
        )
    except:
        return False


def can_parallel_sort_single_key_string(
    imm batch: RecordBatch, num_keys: Int, key_name: String, force: Bool = False
) -> Bool:
    """Gate: True iff `batch` should take the PARALLEL single-key STRING column-
    sort path. Requires exactly one STRING/BINARY sort key and (unless `force`)
    at least `MIN_PARALLEL_SORT_ROWS` rows."""
    if num_keys != 1:
        return False
    if not _is_string_key(batch, key_name):
        return False
    if force:
        return True
    return batch.num_rows() >= MIN_PARALLEL_SORT_ROWS


def parallel_sort_single_key_string[
    has_pool: Bool, disp_o: Origin[mut=True],
](
    var batch: RecordBatch, key_name: String, descending: Bool,
    pool: SharedForkJoinHandle[has_pool, disp_o],
    num_workers: Int = 0,
) raises -> RecordBatch:
    """Sort `batch` by its one STRING / BINARY key `key_name`: a per-slice
    parallel stable string sort, the parallel pairwise-tree merge of the
    slices, then one gather.

    The same rows in the same order as the serial `sort_indices_string` arm of
    `sort_topn_sink._sort_batch_single_key`. `batch` is consumed. The caller
    has checked `can_parallel_sort_single_key_string`. `num_workers` is the
    slice count (`resolve_sort_workers`)."""
    var n = batch.num_rows()
    if n <= 1:
        return batch^

    var key_idx = batch.schema.column_index(key_name)
    ref key_col = batch.column_at(key_idx)
    if not key_col._offsets:
        raise Error(
            "parallel_sort_single_key_string: STRING column missing offsets"
        )

    # Validity as a flat List[Bool], resolved on this thread: workers read the
    # list, never the reference-counted Bitmap.
    var valid = _extract_string_validity(key_col)
    var has_validity = key_col._validity.__bool__()

    var offs_view = key_col._offsets.value().view_ro()
    var offsets_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = key_col._data.view_ro()
    var data_ptr = data_view._unsafe_ptr()
    var col_offset = key_col._offset

    var perm = _parallel_string_perm[
        has_pool=has_pool, disp_o=disp_o
    ](
        offsets_ptr, data_ptr, col_offset, n, valid, has_validity,
        descending, resolve_sort_workers(num_workers), pool,
    )
    _ = offs_view
    _ = data_view
    # The gather runs on the pool (see `sort_parallel.parallel_sort_single_key`).
    return gather_batch_dispatch[
        has_pool, LocalDispatcher[NoopSink], disp_o
    ](batch, perm, pool.ptr)


def parallel_sort_single_key_string_serial(
    var batch: RecordBatch, key_name: String, descending: Bool,
    num_workers: Int = 0,
) raises -> RecordBatch:
    """The dispatcher-less entry: the same chunks run inline, so the result is
    the pooled entry's."""
    return parallel_sort_single_key_string(
        batch^, key_name, descending, serial_fork_join_handle(), num_workers
    )


def merge_sorted_partitions_single_key_string(
    var partitions: Slab[RecordBatch], key_name: String, descending: Bool,
) raises -> RecordBatch:
    """Merge N already-sorted single-STRING-key partition batches into ONE
    globally-sorted batch by a serial comparator heap k-way merge.

    Nothing in the sort sink calls this entry. It is the fully serial oracle
    the parallel merge is tested against, so its gather is serial too (an
    oracle that forks is a weaker oracle).

    Each partition MUST already be sorted by `key_name` (STRING/BINARY) in the
    same direction. Concatenates them into one contiguous batch (preserving
    per-partition order), then runs a serial binary-min-heap k-way merge over the
    per-partition cursors producing one global permutation (lower-partition-wins-
    on-tie == stable == a single serial `sort_indices_string` over
    P0 ++ P1 ++ ... ++ P_{N-1}), and gathers once. `partitions` is consumed.

    Runs entirely on the calling thread, so it reads the merged column's
    Bitmap directly."""
    var np = len(partitions)
    var owned = partitions^
    if np == 0:
        return RecordBatch()

    # Fold the pre-sorted partitions into ONE batch in `num_columns`
    # allocations (`sink_batch_fold.fold_batches_into_one`, an N-way concat)
    # and record each partition's [base[p], base[p+1])
    # row range in the result.
    #
    # THIS LOOP'S ORDER IS A CORRECTNESS CONTRACT, NOT A STYLE. `base` is the
    # k-way merge's index space, and the merge ASSUMES each [base[p],
    # base[p+1]) range is one of the internally-sorted runs. The fold visits
    # the slab in slot order, so partition `p` lands at [base[p], base[p+1]).
    # A fold in any other order would leave `base[p]` pointing at a range that
    # is not a sorted run, and the merge would emit an UNSORTED result; a
    # value-only (order-independent) check cannot see that. The guard is
    # `test_sort_parallel_merge_fold.test_*_merge_is_sorted_*`.
    #
    # The row counts are read by reference off the slab before the fold
    # consumes it.
    var base = List[Int](capacity=np + 1)
    base.append(0)
    var running = 0
    for p in range(np):
        running += owned[p].num_rows()
        base.append(running)
    var merged = fold_batches_into_one(owned^)
    var total = merged.num_rows()
    if total <= 1:
        return merged^

    var key_idx = merged.schema.column_index(key_name)
    ref key_col = merged.column_at(key_idx)
    if not key_col._offsets:
        raise Error(
            "merge_sorted_partitions_single_key_string: STRING column missing"
            " offsets"
        )
    var valid = _extract_string_validity(key_col)
    var has_validity = key_col._validity.__bool__()
    var offs_view = key_col._offsets.value().view_ro()
    var offsets_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = key_col._data.view_ro()
    var data_ptr = data_view._unsafe_ptr()
    var col_offset = key_col._offset

    # The concatenated batch is the single index space [0, total); each
    # partition occupies [base[p], base[p+1)). Build runs as the per-partition
    # row-index ranges (already sorted within each partition). Reuse the same
    # comparator-heap merge as the parallel path (lower-PARTITION-wins-on-tie ==
    # the order combine folds workers).
    var runs = List[List[Int]]()
    for p in range(np):
        var lo = base[p]
        var hi = base[p + 1]
        var run = List[Int](capacity=hi - lo)
        for r in range(lo, hi):
            run.append(r)
        runs.append(run^)
    var total_runs = np

    var cur = List[Int](capacity=total_runs)
    for _ in range(total_runs):
        cur.append(0)

    var heap = List[Int](capacity=total_runs)
    for r in range(total_runs):
        if len(runs[r]) > 0:
            heap.append(r)
    var hn = len(heap)
    var st = (hn // 2) - 1
    while st >= 0:
        _str_sift(
            heap, st, hn, cur, runs, offsets_ptr, data_ptr, col_offset,
            valid, has_validity, descending,
        )
        st -= 1

    var perm = List[Int](capacity=total)
    while hn > 0:
        var top = heap[0]
        var pos = cur[top]
        perm.append(runs[top][pos])
        cur[top] = pos + 1
        if cur[top] >= len(runs[top]):
            hn -= 1
            if hn > 0:
                heap[0] = heap[hn]
        if hn > 0:
            _str_sift(
                heap, 0, hn, cur, runs, offsets_ptr, data_ptr, col_offset,
                valid, has_validity, descending,
            )

    _ = offs_view
    _ = data_view
    return gather_batch(merged, perm)


@fieldwise_init
struct _PkFillWork[
    o_off: Origin[mut=False], o_data: Origin[mut=False],
](SharedChunkWork):
    """Chunk `p` fills the direction-encoded u64 prefix key for rows
    pk_lo[p]..pk_lo[p+1) of the (iota) permutation."""
    # SAFETY: raw STRING offsets/data pointers with CONCRETE origins pinned to
    # the caller's borrowed key column; read-only, never escape this module.
    var offsets_ptr: UnsafePointer[Scalar[DType.int32], Self.o_off]
    var data_ptr: UnsafePointer[Scalar[DType.uint8], Self.o_data]
    var col_offset: Int
    var desc: Bool
    var pk_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes a `_StringPermPayload` as `payload` to the
        # `pool.run` that dispatches this work, so the cast is to the exact type
        # of the referent.
        var pp = UnsafePointer(to=payload).bitcast[_StringPermPayload]()
        var lo = self.pk_lo[chunk_id]
        var hi = self.pk_lo[chunk_id + 1]
        var pk_p = UnsafePointer(to=pp[].pk)
        var perm_p = UnsafePointer(to=pp[].perm)
        for i in range(lo, hi):
            var row = perm_p[][i]
            var k = _pack_prefix8(
                self.offsets_ptr, self.data_ptr, self.col_offset, row, 0
            )
            if self.desc:
                k = ~k
            pk_p[][row] = k


def merge_sorted_partitions_single_key_string_parallel[
    has_pool: Bool, disp_o: Origin[mut=True],
](
    var partitions: Slab[RecordBatch], key_name: String, descending: Bool,
    pool: SharedForkJoinHandle[has_pool, disp_o],
    num_workers: Int = 0,
) raises -> RecordBatch:
    """Merge N already-sorted single-STRING-key partition batches into ONE
    globally-sorted batch on the pool: the parallel form of
    `merge_sorted_partitions_single_key_string`.

    Call it when no other dispatch is live on the pool, so the merge and the
    gather get every worker (no fork-join nests under a live one). Nothing in
    the sort sink calls it yet.

    The same permutation as `merge_sorted_partitions_single_key_string`: the
    N partitions are the sorted runs, and the pairwise-tree co-rank merge gives
    every tie to the left run (the lower partition), as the heap merge does.
    `partitions` is consumed. `num_workers` cuts the prefix-key fill and each
    merge round (`sort_parallel.resolve_sort_workers`).

    Cross-thread safety: validity is resolved to a flat `List[Bool]` on the
    calling thread; workers read only the borrowed offsets / data buffers, the
    prefix-key list and the perm / scratch lists, and build or drop no
    reference-counted value. The output column is built once, by the gather
    after the barrier."""
    var np = len(partitions)
    var owned = partitions^
    if np == 0:
        return RecordBatch()

    # Fold the pre-sorted partitions into ONE batch in `num_columns`
    # allocations (`sink_batch_fold.fold_batches_into_one`, an N-way concat)
    # and record each partition's [base[p], base[p+1])
    # row range in the result.
    #
    # THIS LOOP'S ORDER IS A CORRECTNESS CONTRACT, NOT A STYLE. `base` is the
    # k-way merge's index space, and the merge ASSUMES each [base[p],
    # base[p+1]) range is one of the internally-sorted runs. The fold visits
    # the slab in slot order, so partition `p` lands at [base[p], base[p+1]).
    # A fold in any other order would leave `base[p]` pointing at a range that
    # is not a sorted run, and the merge would emit an UNSORTED result; a
    # value-only (order-independent) check cannot see that. The guard is
    # `test_sort_parallel_merge_fold.test_*_merge_is_sorted_*`.
    #
    # The row counts are read by reference off the slab before the fold
    # consumes it.
    var base = List[Int](capacity=np + 1)
    base.append(0)
    var running = 0
    for p in range(np):
        running += owned[p].num_rows()
        base.append(running)
    var merged = fold_batches_into_one(owned^)
    var total = merged.num_rows()
    if total <= 1:
        return merged^

    var key_idx = merged.schema.column_index(key_name)
    ref key_col = merged.column_at(key_idx)
    if not key_col._offsets:
        raise Error(
            "merge_sorted_partitions_single_key_string_parallel: STRING column"
            " missing offsets"
        )
    # Validity as a flat List[Bool], resolved on this thread: workers read the
    # list, never the reference-counted Bitmap.
    var valid = _extract_string_validity(key_col)
    var has_validity = key_col._validity.__bool__()
    var offs_view = key_col._offsets.value().view_ro()
    var offsets_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = key_col._data.view_ro()
    var data_ptr = data_view._unsafe_ptr()
    var col_offset = key_col._offset

    var nw = resolve_sort_workers(num_workers)

    # perm == iota over the concatenated rows; each partition's sub-range
    # [base[p], base[p+1]) is ALREADY sorted (the caller sorted it).
    var perm = List[Int](capacity=total)
    for i in range(total):
        perm.append(i)
    var scratch = List[Int](capacity=total)
    for _ in range(total):
        scratch.append(0)

    # Precompute the chunk-0 DIRECTION-ENCODED u64 prefix key per ROW (parallel
    # fill over disjoint row chunks); the merge compares these integers and only
    # touches the full string buffers on a prefix tie.
    var pk = List[UInt64](capacity=total)
    for _ in range(total):
        pk.append(0)

    # P contiguous chunks tile [0, total) for the parallel prefix-key fill.
    var pk_lo = List[Int](capacity=nw + 1)
    for p in range(nw + 1):
        pk_lo.append((p * total) // nw)

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` writes ONLY pk[pk_lo[p]:pk_lo[p+1]) (chunks
    #     tile [0,total) exactly); reads `perm` (RO here — iota) + the borrowed
    #     RO offsets/data byte buffers. No two chunks write the same pk slot.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier; the
    #     perm/scratch/pk payload is MOVED onto the dispatch State, and the
    #     offsets/data pointers are pinned to the borrowed `merged` column on
    #     this frame. No reference-counted value is touched on a worker.
    #   * No-realloc: `pk` is sized to `total` ONCE; the fill is setitem only.
    var pk_buf = pool.run(
        _PkFillWork(
            offsets_ptr, data_ptr, col_offset, descending, pk_lo.copy(),
        ),
        valid,
        _StringPermPayload(perm^, scratch^, pk^),
        nw,
    )

    # The partition boundaries ARE the pre-sorted run boundaries.
    var pk_done = pk_buf.take_pk()
    var out_perm = _parallel_pairwise_tree_merge[
        has_pool=has_pool, disp_o=disp_o
    ](
        _PermScratch(pk_buf.take_perm(), pk_buf.take_scratch()),
        pk_done,
        offsets_ptr, data_ptr, col_offset,
        valid, has_validity, descending, base^, nw, pool,
    )
    _ = pk_buf^
    _ = pk_done^

    _ = offs_view
    _ = data_view
    # The gather runs on the pool (see `sort_parallel.parallel_sort_single_key`).
    return gather_batch_dispatch[has_pool, LocalDispatcher[NoopSink], disp_o](
        merged, out_perm, pool.ptr
    )


def merge_sorted_partitions_single_key_string_parallel_serial(
    var partitions: Slab[RecordBatch], key_name: String, descending: Bool,
    num_workers: Int = 0,
) raises -> RecordBatch:
    """The dispatcher-less entry: the same chunks run inline, so the result is
    the pooled entry's."""
    return merge_sorted_partitions_single_key_string_parallel(
        partitions^, key_name, descending, serial_fork_join_handle(),
        num_workers,
    )
