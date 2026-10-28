# =============================================================================
# partition_topn_compact -- the compact path of PartitionTopNSink
# =============================================================================
#
# When the partition key is one INT32 / INT64 column and the order key one
# INT32 / INT64 / FLOAT64 column, neither holding a NULL, `PartitionTopNSink`
# keeps a bounded max-heap of 16-byte `CompactRow`s per partition instead of
# sorting the batch: O(rows log cap) time, O(partitions x cap) memory.
#
#   * `_encode_order_keys`: each order key as a UInt64 whose unsigned order
#     is the key's ascending order (sign bit flipped for integers; for floats
#     the canonical value, so every NaN is one key above +inf and -0.0 is
#     +0.0, then the usual float-to-unsigned map), bit-inverted for DESC.
#   * The heap order is total: (encoded key, input row), the earlier row
#     better, so equal keys keep the earliest rows and ROW_NUMBER's rows are
#     those of a stable sort. The rows kept do not depend on how the rows are
#     split into ranges or merged.
#   * `_build_heaps_range`: one row range's heaps, partitions found through an
#     open-addressing table that starts at 256 slots and doubles at half load
#     (sized from the partitions seen, not from the rows).
#   * `_build_partition_heaps_dispatch`: on a pool, one range per worker on
#     the fork-join runtime, then `_merge_chunk_heaps` (a bounded top-cap heap
#     is mergeable: a row outside its own range's top cap has cap better rows
#     in that range, so it is outside the global top cap); without a pool,
#     one range.
#   * `_emit_compact_row_number` / `_emit_compact_rank`: the winners per
#     partition. RANK reads the heap of capacity `over_fetch_k`; if the heap
#     filled and its worst row still ranks within k, rows tied with it may
#     have been dropped, so that partition is recomputed from every input row
#     (`_emit_full_rank_fallback_for_partition`).
# =============================================================================

from std.builtin.swap import swap

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_async.runtime.parallel_fork_join_shared import SharedForkJoinHandle
from komira_async.runtime.sched_trace import SITE_PTOPN_HEAP_BUILD
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_udf.float_quotient_order import canonical_bits_f64


# The open-addressing empty marker.
comptime _PTOPN_EMPTY_SLOT: Int64 = Int64.MIN

# The probe table's starting size; it doubles at half load.
comptime _PTOPN_ADAPT_START: Int = 256

# The merge table's ceiling on the partition-count estimate it is sized from.
comptime _PTOPN_EST_PARTITION_CAP: Int = 100000


struct CompactRow(ImplicitlyCopyable, Copyable, Movable):
    """A heap entry: the encoded order key (larger is worse) and the row's
    index in the input batch."""

    var order_bits: UInt64
    var batch_id: UInt32
    var row_idx: UInt32

    def __init__(out self, order_bits: UInt64, batch_id: UInt32, row_idx: UInt32):
        self.order_bits = order_bits
        self.batch_id = batch_id
        self.row_idx = row_idx


# =============================================================================
# Bulk encode / extract
# =============================================================================


def _encode_order_keys(
    batch: RecordBatch, order_col_idx: Int, num_rows: Int, descending: Bool,
) raises -> List[UInt64]:
    """The order column as UInt64 keys whose unsigned order is the
    ascending key order (inverted for DESC). Floats are canonicalized first:
    every NaN is one key above +inf, -0.0 and +0.0 one key."""
    ref order_col = batch.column_at(order_col_idx)
    var order_type = order_col.arrow_type
    var off = order_col._offset
    var keys = List[UInt64](capacity=num_rows)
    if order_type == ArrowType.INT64:
        for i in range(num_rows):
            keys.append(
                UInt64(order_col._data.get_typed[Scalar[DType.int64]](off + i))
                ^ (UInt64(1) << 63)
            )
    elif order_type == ArrowType.INT32:
        for i in range(num_rows):
            keys.append(
                UInt64(Int64(Int(order_col._data.get_typed[Scalar[DType.int32]](off + i))))
                ^ (UInt64(1) << 63)
            )
    elif order_type == ArrowType.FLOAT64:
        for i in range(num_rows):
            var bits = canonical_bits_f64(
                order_col._data.get_typed[Scalar[DType.float64]](off + i)
            )
            if bits & (UInt64(1) << 63) != 0:
                keys.append(~bits)
            else:
                keys.append(bits | (UInt64(1) << 63))
    else:
        raise Error(
            "PartitionTopN compact path: unsupported order key type "
            + String(order_type)
        )
    if descending:
        for i in range(num_rows):
            keys[i] = ~keys[i]
    return keys^


def _extract_partition_keys(
    batch: RecordBatch, part_col_idx: Int, num_rows: Int,
) raises -> List[Int64]:
    """The partition column as Int64 values."""
    ref part_col = batch.column_at(part_col_idx)
    var off = part_col._offset
    var keys = List[Int64](capacity=num_rows)
    if part_col.arrow_type == ArrowType.INT64:
        for i in range(num_rows):
            keys.append(Int64(part_col._data.get_typed[Scalar[DType.int64]](off + i)))
    elif part_col.arrow_type == ArrowType.INT32:
        for i in range(num_rows):
            keys.append(Int64(Int(part_col._data.get_typed[Scalar[DType.int32]](off + i))))
    else:
        raise Error(
            "PartitionTopN compact path: unsupported partition key type "
            + String(part_col.arrow_type)
        )
    return keys^


# =============================================================================
# Heaps
# =============================================================================


@always_inline
def _row_worse(a: CompactRow, b: CompactRow) -> Bool:
    """True if `a` orders after `b` by (`order_bits`, `row_idx`): equal keys
    order by input row, the earlier row better (a stable sort's order)."""
    return a.order_bits > b.order_bits or (
        a.order_bits == b.order_bits and a.row_idx > b.row_idx
    )


@always_inline
def _compact_heap_insert(mut heap: List[CompactRow], row: CompactRow, k: Int):
    """Insert into a max-heap of capacity k (the worst row by (`order_bits`,
    `row_idx`) at index 0); a full heap takes only a strictly better row. The
    order is total, so the rows kept are the k best of every row offered
    whatever the offering order (ranges built apart merge to the serial
    result)."""
    if len(heap) < k:
        heap.append(row)
        var idx = len(heap) - 1
        while idx > 0:
            var parent = (idx - 1) // 2
            if _row_worse(heap[idx], heap[parent]):
                var tmp = heap[parent]
                heap[parent] = heap[idx]
                heap[idx] = tmp
                idx = parent
            else:
                break
    elif _row_worse(heap[0], row):
        heap[0] = row
        var idx = 0
        var heap_size = len(heap)
        while True:
            var worst = idx
            var left = 2 * idx + 1
            var right = 2 * idx + 2
            if left < heap_size and _row_worse(heap[left], heap[worst]):
                worst = left
            if right < heap_size and _row_worse(heap[right], heap[worst]):
                worst = right
            if worst == idx:
                break
            var tmp = heap[idx]
            heap[idx] = heap[worst]
            heap[worst] = tmp
            idx = worst


struct _ChunkHeaps(Copyable, Movable):
    """One row range's per-partition heaps: `keys[j]` is the partition key
    of `heaps[j]`. `tab_final` / `tab_grows` record the probe table's final
    size and how many times it doubled."""

    var keys: List[Int64]
    var heaps: List[List[CompactRow]]
    var tab_final: Int
    var tab_grows: Int

    def __init__(out self):
        self.keys = List[Int64]()
        self.heaps = List[List[CompactRow]]()
        self.tab_final = 0
        self.tab_grows = 0

    def take_heaps(mut self) -> List[List[CompactRow]]:
        var out = List[List[CompactRow]]()
        swap(self.heaps, out)
        return out^


@always_inline
def _ptopn_pow2_at_least(want: Int) -> Int:
    var ts = 1
    while ts < want:
        ts *= 2
    return ts


@always_inline
def _probe_hash(pk: Int64, mask: Int) -> Int:
    return Int(UInt64(pk) * 11400714819323198485) & mask


def _build_heaps_range(
    part_keys: List[Int64],
    order_keys: List[UInt64],
    lo: Int,
    hi: Int,
    cap: Int,
    mut out: _ChunkHeaps,
) raises -> None:
    """Per-partition heaps of capacity `cap` over rows `[lo, hi)`, appended
    to `out`. The probe table starts at `_PTOPN_ADAPT_START` slots and
    doubles (rehashing `out.keys`) when the partitions reach half its size;
    the check runs once per new partition, not per row. `row_idx` is the
    global row index, so ranges merge and gather directly."""
    if hi - lo <= 0:
        out.tab_final = 0
        out.tab_grows = 0
        return

    var table_size = _PTOPN_ADAPT_START
    var key_slots = List[Int64](capacity=table_size)
    var heap_indices = List[Int32](capacity=table_size)
    for _ in range(table_size):
        key_slots.append(_PTOPN_EMPTY_SLOT)
        heap_indices.append(Int32(-1))
    var mask = table_size - 1
    var grows = 0

    for row in range(lo, hi):
        var pk = part_keys[row]
        var h = _probe_hash(pk, mask)
        var heap_idx: Int
        while True:
            var slot_key = key_slots[h]
            if slot_key == _PTOPN_EMPTY_SLOT and heap_indices[h] == Int32(-1):
                key_slots[h] = pk
                heap_idx = len(out.heaps)
                heap_indices[h] = Int32(heap_idx)
                out.heaps.append(List[CompactRow]())
                out.keys.append(pk)
                if len(out.heaps) * 2 >= table_size:
                    table_size *= 2
                    var nmask = table_size - 1
                    var nk = List[Int64](capacity=table_size)
                    var nh = List[Int32](capacity=table_size)
                    for _ in range(table_size):
                        nk.append(_PTOPN_EMPTY_SLOT)
                        nh.append(Int32(-1))
                    for j in range(len(out.keys)):
                        var g = _probe_hash(out.keys[j], nmask)
                        while nh[g] != Int32(-1):
                            g = (g + 1) & nmask
                        nk[g] = out.keys[j]
                        nh[g] = Int32(j)
                    key_slots = nk^
                    heap_indices = nh^
                    mask = nmask
                    grows += 1
                break
            elif slot_key == pk and heap_indices[h] != Int32(-1):
                heap_idx = Int(heap_indices[h])
                break
            else:
                h = (h + 1) & mask
        _compact_heap_insert(out.heaps[heap_idx], CompactRow(order_keys[row], UInt32(0), UInt32(row)), cap)

    out.tab_final = table_size
    out.tab_grows = grows


struct _HeapBuildIn(Deinitable):
    """The read-only input of the parallel build: the two key arrays (moved
    in for the wave and handed back) and the range starts."""

    var part_keys: List[Int64]
    var order_keys: List[UInt64]
    var chunk_lo: List[Int]

    def __init__(out self, var part_keys: List[Int64], var order_keys: List[UInt64], var chunk_lo: List[Int]):
        self.part_keys = part_keys^
        self.order_keys = order_keys^
        self.chunk_lo = chunk_lo^

    def take_part_keys(mut self) -> List[Int64]:
        var out = List[Int64]()
        swap(self.part_keys, out)
        return out^

    def take_order_keys(mut self) -> List[UInt64]:
        var out = List[UInt64]()
        swap(self.order_keys, out)
        return out^


struct _HeapBuildOut(Movable, Deinitable):
    """One `_ChunkHeaps` per range, sized before the wave."""

    var chunks: List[_ChunkHeaps]

    def __init__(out self, n: Int):
        self.chunks = List[_ChunkHeaps]()
        for _ in range(n):
            self.chunks.append(_ChunkHeaps())


@fieldwise_init
struct _HeapBuildWork(SharedChunkWork):
    """Chunk `p` builds the heaps of rows `[chunk_lo[p], chunk_lo[p+1])` into
    payload slot `p`."""

    var cap: Int

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P) raises:
        # SAFETY: the driver runs this work with `_HeapBuildIn` input and a
        # `_HeapBuildOut` payload; the casts only name those types.
        var ip = UnsafePointer(to=input).bitcast[_HeapBuildIn]()
        var op = UnsafePointer(to=payload).bitcast[_HeapBuildOut]()
        var local = _ChunkHeaps()
        _build_heaps_range(
            ip[].part_keys, ip[].order_keys,
            ip[].chunk_lo[chunk_id], ip[].chunk_lo[chunk_id + 1],
            self.cap, local,
        )
        op[].chunks[chunk_id] = local^


def _merge_chunk_heaps(chunks: List[_ChunkHeaps], cap: Int) raises -> List[List[CompactRow]]:
    """Merge range-local heaps into one heap per partition by re-inserting
    every range entry; equal to a single build over all rows, whatever the
    ranges (the heap order is total)."""
    var ub = 0
    for c in range(len(chunks)):
        ub += len(chunks[c].keys)
    if ub == 0:
        return List[List[CompactRow]]()
    var table_size = _ptopn_pow2_at_least(max(256, min(ub, _PTOPN_EST_PARTITION_CAP) * 2))
    while table_size < ub * 2:
        table_size *= 2
    var key_slots = List[Int64](capacity=table_size)
    var heap_indices = List[Int32](capacity=table_size)
    for _ in range(table_size):
        key_slots.append(_PTOPN_EMPTY_SLOT)
        heap_indices.append(Int32(-1))
    var mask = table_size - 1
    var heaps = List[List[CompactRow]]()
    for c in range(len(chunks)):
        for j in range(len(chunks[c].keys)):
            var pk = chunks[c].keys[j]
            var h = _probe_hash(pk, mask)
            var gi: Int
            while True:
                if heap_indices[h] == Int32(-1):
                    key_slots[h] = pk
                    gi = len(heaps)
                    heap_indices[h] = Int32(gi)
                    heaps.append(List[CompactRow]())
                    break
                elif key_slots[h] == pk:
                    gi = Int(heap_indices[h])
                    break
                else:
                    h = (h + 1) & mask
            for e in range(len(chunks[c].heaps[j])):
                _compact_heap_insert(heaps[gi], chunks[c].heaps[j][e], cap)
    return heaps^


def _build_partition_heaps_dispatch[
    has_pool: Bool, disp_o: Origin[mut=True]
](
    mut part_keys: List[Int64],
    mut order_keys: List[UInt64],
    num_rows: Int,
    cap: Int,
    pool: SharedForkJoinHandle[has_pool, disp_o],
) raises -> List[List[CompactRow]]:
    """The per-partition heaps: one range per worker on the pool, then a
    merge; without a pool, one range. The key arrays are moved into the wave
    and back (the RANK emitter reads them after)."""
    comptime if not has_pool:
        var out = _ChunkHeaps()
        _build_heaps_range(part_keys, order_keys, 0, num_rows, cap, out)
        return out.take_heaps()
    else:
        var nw = pool.ptr.value()[].worker_count()
        if nw > num_rows:
            nw = num_rows
        if nw < 1:
            nw = 1
        var chunk_lo = List[Int](capacity=nw + 1)
        for p in range(nw + 1):
            chunk_lo.append((p * num_rows) // nw)
        # DISPATCH-BOUNDARY SAFETY:
        #   * Disjointness: chunk p reads the key arrays over its own range
        #     (read-only for the wave) and writes only `chunks[p]`.
        #   * Liveness: `run` returns after every chunk has joined; the input
        #     is one driver-owned bundle, the payload is moved onto the wave.
        #   * No-realloc: `chunks` is sized before the wave; a chunk assigns
        #     its own slot.
        # The key arrays are swapped out (not moved: they are `mut`
        # parameters) and swapped back after the wave.
        var pk_local = List[Int64]()
        var ok_local = List[UInt64]()
        swap(part_keys, pk_local)
        swap(order_keys, ok_local)
        var hb_in = _HeapBuildIn(pk_local^, ok_local^, chunk_lo^)
        var built = pool.run[_HeapBuildWork, _HeapBuildIn, _HeapBuildOut, origin_of(hb_in)](
            _HeapBuildWork(cap), hb_in, _HeapBuildOut(nw), nw, 2, SITE_PTOPN_HEAP_BUILD,
        )
        var pk_back = hb_in.take_part_keys()
        var ok_back = hb_in.take_order_keys()
        swap(part_keys, pk_back)
        swap(order_keys, ok_back)
        _ = hb_in^
        var heaps = _merge_chunk_heaps(built.chunks, cap)
        _ = built^
        return heaps^


# =============================================================================
# Emission
# =============================================================================


def _sift_down_worst_first(mut s: List[CompactRow], start: Int, end: Int):
    """Restore the max-heap property (worst row at the root) below `start`
    within `s[0:end]`."""
    var idx = start
    while True:
        var worst = idx
        var left = 2 * idx + 1
        var right = left + 1
        if left < end and _row_worse(s[left], s[worst]):
            worst = left
        if right < end and _row_worse(s[right], s[worst]):
            worst = right
        if worst == idx:
            return
        var tmp = s[idx]
        s[idx] = s[worst]
        s[worst] = tmp
        idx = worst


def _sorted_entries(rows: List[CompactRow]) -> List[CompactRow]:
    """`rows` ordered best first by (`order_bits`, `row_idx`): a heap sort,
    O(n log n), whatever order `rows` came in."""
    var s = List[CompactRow](capacity=len(rows))
    for i in range(len(rows)):
        s.append(rows[i])
    var n = len(s)
    for i in range(n // 2 - 1, -1, -1):
        _sift_down_worst_first(s, i, n)
    for end in range(n - 1, 0, -1):
        var tmp = s[0]
        s[0] = s[end]
        s[end] = tmp
        _sift_down_worst_first(s, 0, end)
    return s^


def _emit_compact_row_number(
    heaps: List[List[CompactRow]],
    want_rk: Bool,
    mut winner_indices: List[Int],
    mut winner_ranks: List[Int],
):
    """ROW_NUMBER: each heap's rows best first, by (key, row); with a rank
    column, numbered 1..n."""
    for p in range(len(heaps)):
        if len(heaps[p]) == 0:
            continue
        if len(heaps[p]) == 1:
            # PERF-CRITICAL: k = 1 (or a one-row partition) allocates nothing.
            winner_indices.append(Int(heaps[p][0].row_idx))
            if want_rk:
                winner_ranks.append(1)
            continue
        var s = _sorted_entries(heaps[p])
        for i in range(len(s)):
            winner_indices.append(Int(s[i].row_idx))
            if want_rk:
                winner_ranks.append(i + 1)


def _emit_compact_rank(
    heaps: List[List[CompactRow]],
    part_keys: List[Int64],
    order_keys: List[UInt64],
    k: Int,
    cap: Int,
    mut winner_indices: List[Int],
    mut winner_ranks: List[Int],
):
    """RANK (1 + rows strictly better; ties share): each heap's rows ranked
    within k. A full heap whose worst row still ranks within k may have
    dropped rows tied with it: that partition is recomputed from every row."""
    for p in range(len(heaps)):
        var heap_size = len(heaps[p])
        if heap_size == 0:
            continue
        var s = _sorted_entries(heaps[p])
        var worst_rank = 1
        var g = s[0].order_bits
        for i in range(heap_size):
            if s[i].order_bits != g:
                worst_rank = i + 1
                g = s[i].order_bits
        if heap_size >= cap and worst_rank <= k:
            _emit_full_rank_fallback_for_partition(
                part_keys, order_keys, part_keys[Int(s[0].row_idx)], k,
                winner_indices, winner_ranks,
            )
            continue
        var rank = 1
        var cur = s[0].order_bits
        for i in range(heap_size):
            if s[i].order_bits != cur:
                rank = i + 1
                cur = s[i].order_bits
            if rank > k:
                break
            winner_indices.append(Int(s[i].row_idx))
            winner_ranks.append(rank)


def _emit_full_rank_fallback_for_partition(
    part_keys: List[Int64],
    order_keys: List[UInt64],
    partition_pk: Int64,
    k: Int,
    mut winner_indices: List[Int],
    mut winner_ranks: List[Int],
):
    """RANK of one partition from every input row: the rows of
    `partition_pk`, sorted by key, ranked, kept within k."""
    var pairs = List[CompactRow]()
    for r in range(len(part_keys)):
        if part_keys[r] == partition_pk:
            pairs.append(CompactRow(order_keys[r], UInt32(0), UInt32(r)))
    if len(pairs) == 0:
        return
    var s = _sorted_entries(pairs)
    var rank = 1
    var cur = s[0].order_bits
    for i in range(len(s)):
        if s[i].order_bits != cur:
            rank = i + 1
            cur = s[i].order_bits
        if rank > k:
            break
        winner_indices.append(Int(s[i].row_idx))
        winner_ranks.append(rank)
