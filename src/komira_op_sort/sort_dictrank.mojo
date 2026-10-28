# =============================================================================
# sort_dictrank -- the single-key STRING sort of a low-cardinality key by
# dense ranks and a parallel counting sort
# =============================================================================
#
# For one STRING / BINARY key with few distinct values, a counting sort over
# dense ranks replaces the comparison merge:
#
#   1. The dictionary of distinct values and each row's distinct id, built in
#      parallel (`sort_dictrank_build._build_distinct_ids`).
#   2. The distinct values sorted once into ranks (byte-wise order, the shorter
#      string first on a shared prefix); DESC complements each rank so the same
#      ascending counting sort emits descending order. A NULL row takes a
#      sentinel rank: first ascending, last descending.
#   3. Each row mapped to its rank, then a stable parallel counting sort:
#      per-worker histograms, one serial prefix sum giving each (worker, rank)
#      its window of the permutation, and a per-worker scatter.
#   4. One gather of every column by the permutation.
#
# The rank order is the string order (equal strings share a rank) and the
# counting sort keeps equal ranks in input order, so the permutation is a
# single stable `sort_indices_string`'s.
#
# The gate (`can_dictrank_sort_single_key_string`) admits a key whose sampled
# distinct count is under the ceiling. The sample is an estimate: after the
# exact build, a distinct count above the ceiling falls back to the parallel
# comparison sort (`sort_parallel_string`) on the same batch, so the answer is
# the same either way and only the histogram's size is bounded.
#
# What the sample can miss. The sample reads a fixed stride over the column, so
# a key whose distinct values fall between the sampled rows (a periodic key
# whose period shares the stride, or distinct values only past the last
# sampled row) is admitted although it is high-cardinality. The exact build is
# the backstop: the answer is still correct (the fallback above), but the sort
# has paid for a full dictionary build first. On the multi-worker route of
# `SortSink` the gate samples partition 0 only, so a first partition that is
# not representative of the rest can admit or decline wrongly in the same way.
# Neither changes the rows; both cost time.

from std.builtin.swap import swap
from std.memory import UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import (
    SharedForkJoinHandle,
    serial_fork_join_handle,
)
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_column_kernels.compiler_helpers import gather_batch_dispatch
from komira_counters.global_counter import GlobalCounter

from .sort_dictrank_build import (
    DICTRANK_MAX_DISTINCT,
    DICTRANK_MIN_ROWS,
    _build_distinct_ids,
    _dictrank_cardinality_ok,
    _sort_distinct_to_rank,
)
from .sort_parallel import resolve_sort_workers
from .sort_parallel_string import (
    _extract_string_validity,
    parallel_sort_single_key_string,
)

# Batches that took the comparison-sort fallback after the exact distinct
# count exceeded the ceiling (read through `dictrank_fallback_count`).
comptime _FALLBACKS = GlobalCounter["komira_op_sort_dictrank_fallbacks"]


def dictrank_fallback_count() -> Int:
    """How many times, in this process, `parallel_dictrank_sort_string` found
    the exact distinct count above its ceiling and sorted by comparison
    instead. Diagnostic: it lets a caller see which path a sort took. Read it
    before and after a call and compare."""
    try:
        return _FALLBACKS.read()
    except:
        return 0


# -----------------------------------------------------------------------------
# Parallel counting sort over the per-row ranks
# -----------------------------------------------------------------------------


struct _RankMapIn(Deinitable):
    """Read-only input bundle for the rank-map wave: the per-row provisional
    distinct id and the distinct-id -> dense-rank table."""
    var prov_id: List[Int]
    var rank: List[Int]

    def __init__(out self, var prov_id: List[Int], var rank: List[Int]):
        self.prov_id = prov_id^
        self.rank = rank^


@fieldwise_init
struct _RankMapWork(SharedChunkWork):
    """Chunk `p` maps rows [rslice[p], rslice[p+1]) from provisional distinct
    id to the dense sort rank (NULL rows take the null sentinel)."""
    var rslice: List[Int]
    var null_rank: Int
    var has_validity: Bool
    var desc: Bool

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes the `In` this struct is dispatched with; the
        # bitcast names that exact type, which the call site below fixes, and the
        # borrow outlives the synchronous barrier. Input is read only.
        var ip = UnsafePointer(to=input).bitcast[_RankMapIn]()
        # SAFETY: `payload` is the value the driver moved onto the dispatch State,
        # of the bitcast type; this chunk writes only its own disjoint band.
        var op = UnsafePointer(to=payload).bitcast[List[Int]]()
        var lo = self.rslice[chunk_id]
        var hi = self.rslice[chunk_id + 1]
        for row in range(lo, hi):
            var pid = ip[].prov_id[row]
            if pid < 0:
                # NULL row.
                op[][row] = self.null_rank
            else:
                var vr = ip[].rank[pid]
                if self.has_validity and not self.desc:
                    # ASC with nulls: shift valid ranks +1 (null is rank 0).
                    op[][row] = vr + 1
                else:
                    op[][row] = vr


@fieldwise_init
struct _HistWork(SharedChunkWork):
    """Chunk `p` histograms its slice's ranks into its OWN band
    hist[p*R : (p+1)*R)."""
    var slice_lo: List[Int]
    var n_ranks: Int

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes the `In` this struct is dispatched with; the
        # bitcast names that exact type, which the call site below fixes, and the
        # borrow outlives the synchronous barrier. Input is read only.
        var rp = UnsafePointer(to=input).bitcast[List[Int]]()
        # SAFETY: `payload` is the value the driver moved onto the dispatch State,
        # of the bitcast type; this chunk writes only its own disjoint band.
        var hp = UnsafePointer(to=payload).bitcast[List[Int]]()
        var lo = self.slice_lo[chunk_id]
        var hi = self.slice_lo[chunk_id + 1]
        var base = chunk_id * self.n_ranks
        for row in range(lo, hi):
            var r = rp[][row]
            hp[][base + r] = hp[][base + r] + 1


@fieldwise_init
struct _ScatterPayload(Movable, Deinitable):
    """Shared fork-join payload for the stable scatter: the output permutation
    plus the per-(worker, rank) write cursor band."""
    var perm: List[Int]
    var cursor: List[Int]

    def take_perm(mut self) -> List[Int]:
        var out = List[Int]()
        swap(self.perm, out)
        return out^


@fieldwise_init
struct _ScatterWork(SharedChunkWork):
    """Chunk `p` scatters its slice's rows into `perm` at its own per-rank
    cursor."""
    var slice_lo: List[Int]
    var n_ranks: Int

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes the `In` this struct is dispatched with; the
        # bitcast names that exact type, which the call site below fixes, and the
        # borrow outlives the synchronous barrier. Input is read only.
        var rp = UnsafePointer(to=input).bitcast[List[Int]]()
        # SAFETY: `payload` is the value the driver moved onto the dispatch State,
        # of the bitcast type; this chunk writes only its own disjoint band.
        var pp = UnsafePointer(to=payload).bitcast[_ScatterPayload]()
        var perm_p = UnsafePointer(to=pp[].perm)
        var cur_p = UnsafePointer(to=pp[].cursor)
        var lo = self.slice_lo[chunk_id]
        var hi = self.slice_lo[chunk_id + 1]
        var base = chunk_id * self.n_ranks
        for row in range(lo, hi):
            var r = rp[][row]
            var dst = cur_p[][base + r]
            perm_p[][dst] = row
            cur_p[][base + r] = dst + 1


def _parallel_counting_sort_perm[
    has_pool: Bool, disp_o: Origin[mut=True],
](
    imm row_rank: List[Int],
    n: Int,
    num_ranks: Int,
    nw_hint: Int,
    pool: SharedForkJoinHandle[has_pool, disp_o],
) raises -> List[Int]:
    """Parallel STABLE counting sort of the per-row ranks in [0, num_ranks).
    Returns `perm` where `perm[i]` is the original row index at sorted position
    `i`. NO merge: per-worker local histograms -> global histogram (exclusive
    prefix-sum to bucket bases) -> per-worker stable scatter.

    Stability: bucket `r`'s rows are emitted (a) in ascending WORKER order, and
    (b) within a worker in ascending ROW order — i.e. ascending input order. The
    SortSink folds workers WORKER-MAJOR into the concatenated batch, so input
    order == the worker-major order the serial reference breaks ties by."""
    var perm = List[Int](capacity=n)
    for _ in range(n):
        perm.append(0)
    if n < 2:
        if n == 1:
            perm[0] = 0
        return perm^

    var R = num_ranks
    if R < 1:
        R = 1

    var nw = nw_hint
    if nw < 1:
        nw = 1
    if nw > n:
        nw = n

    var slice_lo = List[Int](capacity=nw + 1)
    for p in range(nw + 1):
        slice_lo.append((p * n) // nw)

    # Per-worker local histogram, row-major: hist[p * R + r] = count of rank r in
    # worker p's slice. Sized once (nw * R ints).
    var hist = List[Int](capacity=nw * R)
    for _ in range(nw * R):
        hist.append(0)

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` reads ONLY row_rank[slice_lo[p]:slice_lo[p+1])
    #     and writes ONLY hist[p*R : (p+1)*R) (its own contiguous histogram
    #     band). The slice boundaries tile [0,n) exactly; the hist bands tile
    #     [0,nw*R) exactly — no two chunks touch the same hist element.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier;
    #     `row_rank` is borrowed through a concrete immutable origin and `hist`
    #     is MOVED onto the dispatch State. No String/Column/ArcPointer is
    #     constructed on a worker — ranks are a pre-resolved flat `List[Int]`.
    #   * No-realloc: `hist` is sized to `nw*R` ONCE before the dispatch; the
    #     histogram is setitem (`+= 1`) on existing slots, never append.
    hist = pool.run(_HistWork(slice_lo.copy(), R), row_rank, hist^, nw)

    # SERIAL: per-(rank, worker) exclusive prefix-sum to a global START offset.
    # `start[p * R + r]` = the absolute perm position where worker p begins
    # writing rank-r rows = (sum of all ranks < r across all workers)
    #                       + (count of rank r in workers 0..p-1).
    # Computed by walking ranks in ascending order, and within each rank walking
    # workers in ascending order. This single layout gives both the bucket base
    # (rank-major) and the per-worker stable offset (worker-major within a rank).
    var start = List[Int](capacity=nw * R)
    for _ in range(nw * R):
        start.append(0)
    var running = 0
    for r in range(R):
        for p in range(nw):
            start[p * R + r] = running
            running += hist[p * R + r]

    # PARALLEL: worker p scatters its slice's rows into perm at its per-rank
    # cursor (start[p*R+r], incremented per row). Stable: rows scanned in
    # ascending input order; the cursor for (p, r) begins after all lower-worker
    # rank-r rows.
    var cursor = start^  # reuse the start layout as the mutable per-worker cursor.

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` reads ONLY row_rank[slice_lo[p]:slice_lo[p+1])
    #     and cursor[p*R : (p+1)*R) (its own band), and WRITES perm at positions
    #     [start[p*R+r] .. start[p*R+r]+hist[p*R+r]) for each rank r — these
    #     ranges are DISJOINT across (p, r) by construction (the exclusive
    #     prefix-sum gives each (p,r) a contiguous, non-overlapping perm window
    #     that tiles [0,n)). No two chunks write the same perm element.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier;
    #     `row_rank` is borrowed through a concrete immutable origin and the
    #     perm/cursor payload is MOVED onto the dispatch State.
    #   * No-realloc: `perm`/`cursor` sized ONCE before the dispatch; the
    #     scatter is setitem on existing slots, never append.
    var scattered = pool.run(
        _ScatterWork(slice_lo.copy(), R),
        row_rank,
        _ScatterPayload(perm^, cursor^),
        nw,
    )
    return scattered.take_perm()


# -----------------------------------------------------------------------------
# Public entry
# -----------------------------------------------------------------------------


def can_dictrank_sort_single_key_string(
    imm batch: RecordBatch,
    key_name: String,
    force: Bool = False,
    max_distinct: Int = DICTRANK_MAX_DISTINCT,
) -> Bool:
    """Gate: True iff the dict-rank counting sort should run for the single
    STRING / BINARY key `key_name` of `batch`: the key has offsets, the batch
    has at least `DICTRANK_MIN_ROWS` rows (unless `force`), and the sampled
    distinct estimate is under `max_distinct` and under the ratio ceiling.

    Takes the batch and the key name and resolves the key buffers itself; no
    pointer crosses the module boundary. Any resolution failure declines."""
    try:
        var key_idx = batch.schema.column_index(key_name)
        ref key_col = batch.column_at(key_idx)
        if not (
            key_col.arrow_type == ArrowType.STRING
            or key_col.arrow_type == ArrowType.BINARY
        ):
            return False
        if not key_col._offsets:
            return False
        var n = batch.num_rows()
        if not force and n < DICTRANK_MIN_ROWS:
            return False
        var offs_view = key_col._offsets.value().view_ro()
        # SAFETY: the offsets buffer holds `num_rows + 1` Int32 values from
        # `_offset`; `offs_view` (and `data_view`) are held until after the
        # cardinality check, so the pointers stay valid, and the check only
        # reads.
        var offsets_ptr = offs_view._unsafe_ptr().bitcast[
            Scalar[DType.int32]
        ]()
        var data_view = key_col._data.view_ro()
        # SAFETY: as for `offsets_ptr`; the data buffer is bytes.
        var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
        var ok = _dictrank_cardinality_ok(
            offsets_ptr, data_ptr, key_col._offset, n, max_distinct
        )
        _ = offs_view
        _ = data_view
        return ok
    except:
        return False


def parallel_dictrank_sort_string[
    has_pool: Bool, disp_o: Origin[mut=True],
](
    var batch: RecordBatch, key_name: String, descending: Bool,
    pool: SharedForkJoinHandle[has_pool, disp_o],
    num_workers: Int = 0,
    max_distinct: Int = DICTRANK_MAX_DISTINCT,
) raises -> RecordBatch:
    """Sort `batch` by its one STRING / BINARY key `key_name` through dense
    ranks and a parallel counting sort, then one gather. The same rows in the
    same order as the serial `sort_indices_string`: NULLs first ascending and
    last descending, ties in input order. `batch` is consumed.

    The caller has checked `can_dictrank_sort_single_key_string`. When the
    exact distinct count exceeds `max_distinct`, the batch goes to
    `parallel_sort_single_key_string` instead (same rows). `num_workers` is
    the slice count (`sort_parallel.resolve_sort_workers`)."""
    var n = batch.num_rows()
    if n <= 1:
        return batch^

    var key_idx = batch.schema.column_index(key_name)
    ref key_col = batch.column_at(key_idx)
    if not key_col._offsets:
        raise Error(
            "parallel_dictrank_sort_string: STRING column missing offsets"
        )

    # Validity as a flat List[Bool], resolved on this thread: the dictionary
    # build and the counting sort read the list, never the Bitmap.
    var valid = _extract_string_validity(key_col)
    var has_validity = key_col._validity.__bool__()

    var offs_view = key_col._offsets.value().view_ro()
    # SAFETY: the offsets buffer holds `n + 1` Int32 values from `col_offset`.
    # `offs_view` and `data_view` live to the end of the sort (the `_ = ...`
    # releases below), the pointers are only read, and `batch` is not moved
    # while they are in use (the fallback releases the views first).
    var offsets_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = key_col._data.view_ro()
    # SAFETY: as for `offsets_ptr`; the data buffer is bytes.
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var col_offset = key_col._offset

    var nw = resolve_sort_workers(num_workers)

    # ---- Stage 1: the dictionary (each row's distinct id) ----
    var prov_id = List[Int](capacity=n)
    for _ in range(n):
        prov_id.append(-1)
    var rep_row = List[Int]()
    prov_id = _build_distinct_ids[has_pool=has_pool, disp_o=disp_o](
        offsets_ptr, data_ptr, col_offset, n, valid, has_validity, nw,
        prov_id^, rep_row, pool,
    )
    var d = len(rep_row)

    # ---- The exact distinct count against the ceiling ----
    # The gate sampled; now `d` is exact. Above the ceiling the histogram
    # (`nw * (d + 1)` ints) is not built: the same batch goes to the
    # comparison sort, which gives the same rows. The key-buffer views are
    # released first so `batch` can be moved.
    if d > max_distinct:
        _FALLBACKS.try_incr()
        _ = valid^
        _ = prov_id^
        _ = rep_row^
        _ = offs_view
        _ = data_view
        return parallel_sort_single_key_string[has_pool, disp_o](
            batch^, key_name, descending, pool, num_workers
        )

    # ---- Stage 2: the distinct values to ranks, then each row to its rank ----
    var rank = _sort_distinct_to_rank(
        offsets_ptr, data_ptr, col_offset, rep_row, descending
    )
    # Ranks: [0, d) for the values, and a NULL sentinel folded into the
    # [0, num_ranks) space: NULL first ascending (rank 0, the values shifted
    # up by one), NULL last descending (rank d).
    var num_ranks: Int
    var null_rank: Int
    if has_validity:
        if descending:
            null_rank = d
            num_ranks = d + 1
        else:
            null_rank = 0
            num_ranks = d + 1
    else:
        null_rank = 0  # unused
        num_ranks = max(d, 1)

    var row_rank = List[Int](capacity=n)
    for _ in range(n):
        row_rank.append(0)
    var nw2 = nw
    if nw2 > n:
        nw2 = n
    var rslice = List[Int](capacity=nw2 + 1)
    for p in range(nw2 + 1):
        rslice.append((p * n) // nw2)
    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` reads prov_id[slice]/rank[*] (read-only) and
    #     writes ONLY row_rank[rslice[p]:rslice[p+1]) (slices tile [0,n)
    #     exactly). No two chunks write the same row_rank element.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier; the
    #     read-only `prov_id` + `rank` are bundled into ONE driver-owned
    #     `_RankMapIn` borrowed through a concrete immutable origin, and
    #     `row_rank` is MOVED onto the dispatch State.
    #   * No-realloc: `row_rank` sized to `n` ONCE; the map is setitem, never
    #     append.
    var rank_in = _RankMapIn(prov_id^, rank^)
    row_rank = pool.run(
        _RankMapWork(rslice.copy(), null_rank, has_validity, descending),
        rank_in,
        row_rank^,
        nw2,
    )
    _ = rank_in^

    # ---- Stage 3: the parallel counting sort, giving the permutation ----
    var perm = _parallel_counting_sort_perm[has_pool, disp_o](
        row_rank, n, num_ranks, nw, pool
    )

    _ = offs_view
    _ = data_view

    # ---- Stage 4: one gather, on the pool ----
    return gather_batch_dispatch[
        has_pool, LocalDispatcher[NoopSink], disp_o
    ](batch, perm, pool.ptr)


def parallel_dictrank_sort_string_serial(
    var batch: RecordBatch, key_name: String, descending: Bool,
    num_workers: Int = 0,
    max_distinct: Int = DICTRANK_MAX_DISTINCT,
) raises -> RecordBatch:
    """The dispatcher-less entry: the same chunks run inline, so the result is
    the pooled entry's."""
    return parallel_dictrank_sort_string(
        batch^, key_name, descending, serial_fork_join_handle(), num_workers,
        max_distinct,
    )
