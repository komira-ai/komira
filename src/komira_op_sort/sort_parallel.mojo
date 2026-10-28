# =============================================================================
# sort_parallel -- the parallel single-key sort over INT64 / INT32 / FLOAT64
# =============================================================================
#
# The parallel form of the serial single-key column sort
# (`sort_topn_sink._sort_batch_single_key`). A sort here produces a
# permutation and the caller gathers every column by it, so the parallel work
# is producing that permutation:
#
#   1. Read the one key column into a flat ORDER-PRESERVING `List[Int64]`
#      (INT64 and INT32 directly; FLOAT64 through `_f64_order_key`, which keeps
#      the order of `sort.sort_key_lt`).
#   2. Split the row range `[0, n)` into P CONTIGUOUS slices.
#   3. In parallel, each chunk stable-sorts its own slice of a pre-sized
#      permutation (and the same slice of a pre-sized scratch list), giving P
#      sorted runs.
#   4. A co-rank multiway merge of the P runs into one global permutation. The
#      calling thread first co-ranks every output-slice boundary (`_corank`: a
#      binary search of the threshold key over the key range: up to 64 rounds,
#      each probing every run, per boundary); then each chunk, in
#      parallel, merges its own output slice. On a key tie the lower run wins.
#   5. The caller gathers the batch's columns by the permutation
#      (`gather_batch_dispatch`, on the same pool).
#
# The same permutation as the serial sort: slices are contiguous in input
# order, so "the lower run wins on a tie" is "the lower input row wins on a
# tie", which is what a stable sort does; and each slice's own sort is stable.
#
# Floats: `_f64_order_key` maps every NaN to one key above +inf and -0.0 to the
# key of +0.0, so the flat keys order exactly as `sort_key_lt` orders the
# floats (DuckDB's order: NaN last ascending and first descending, the two
# zeros equal and so kept in input order).
#
# NULLs: the INT64 / INT32 / FLOAT64 paths do not read the key's validity. A
# NULL cell sorts by its stored value, as in `sort_topn_sink`'s serial sort of
# a numeric key, and `can_parallel_sort_single_key` does not look at NULLs, so
# the caller that needs NULL placement for a numeric key does not route it here.
# The STRING / BINARY form (`sort_parallel_string`) does place NULLs: first
# ascending, last descending.
#
# Nothing in the sort sink calls these entries yet; they are the building
# blocks of the parallel sort and are exercised by this package's tests.
#
# Multi-key sorts are not handled here (the caller keeps `sort_batch_by_keys`);
# a STRING key is `sort_parallel_string`.
#
# Every fork-join wave runs on the engine's `LocalDispatcher` through a
# `SharedForkJoinHandle`; `serial_fork_join_handle()` runs the same chunks
# inline (the dispatcher-less `*_serial` entries). No public signature names a
# pointer: the entries take a batch and names and return a batch.
# =============================================================================

from std.memory import bitcast, UnsafePointer
from std.builtin.swap import swap
from std.sys import num_physical_cores

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import (
    SharedForkJoinHandle,
    serial_fork_join_handle,
)
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import gather_batch_dispatch
from komira_operator_api.sink_batch_fold import fold_batches_into_one


# The row count below which the sort sink keeps the serial sort: the fork-join
# and the per-chunk co-rank are not worth it for a small input. A caller that
# passes `force=True` to `can_parallel_sort_single_key` skips this floor.
comptime MIN_PARALLEL_SORT_ROWS: Int = 64 * 1024

# The Int64 key of every NaN: one above the key of +inf (0x7FF0000000000000),
# so all NaNs are equal and sort after +inf, before nothing.
comptime _NAN_ORDER_KEY: Int64 = 0x7FF0000000000001


@always_inline
def _f64_order_key(v: Float64) -> Int64:
    """Map a Float64 to an Int64 key whose signed order is `sort_key_lt`'s.

    `a` sorts before `b` under `sort_key_lt` exactly when
    `_f64_order_key(a) < _f64_order_key(b)`, and two floats are tied exactly
    when their keys are equal:

        -inf  -> -9218868437227405313
        -1.0  -> -4607182418800017409
        -0.0  ->                    0   (the key of +0.0: the zeros tie)
        +0.0  ->                    0
         1.0  ->  4607182418800017408
        +inf  ->  9218868437227405312
        NaN   ->  9218868437227405313   (every NaN, whatever its sign or
                                         payload: above +inf, all tied)

    A non-NaN, non-zero float: a non-negative bit pattern is its own key; a
    negative one maps to `~bits ^ (1 << 63)`, a negative Int64 that decreases
    as the float decreases.
    """
    if v != v:
        return _NAN_ORDER_KEY
    if v == 0.0:
        return 0
    var bits = bitcast[DType.int64, 1](SIMD[DType.float64, 1](v))[0]
    if bits >= 0:
        return bits
    return Int64((~UInt64(bits)) ^ (UInt64(1) << 63))


@always_inline
def _eff_less(a: Int64, b: Int64, desc: Bool) -> Bool:
    """Effective strict-less under the sort direction over flat order-preserving
    keys: ASC == `a < b`, DESC == `a > b`."""
    if desc:
        return a > b
    return a < b


@always_inline
def _mid_floor(lo: Int64, hi: Int64) -> Int64:
    """Overflow-safe FLOOR midpoint of [lo, hi] (lo <= hi). The flat order-
    preserving F64 keys span the FULL Int64 range, so `(hi - lo)` can overflow
    a signed Int64 (e.g. hi near MAX, lo near MIN). Compute the unsigned
    distance in UInt64 (two's-complement-correct), halve, add back to lo."""
    var dist = UInt64(hi) - UInt64(lo)
    return lo + Int64(dist >> 1)


@always_inline
def _mid_ceil(lo: Int64, hi: Int64) -> Int64:
    """Overflow-safe CEIL midpoint of [lo, hi] (lo <= hi): `lo + ceil((hi-lo)/2)`.
    Used by the DESC branch, which rounds up so the search advances when
    hi == lo + 1. The distance is up to 2^64 - 1 (`dist + 1` would wrap to 0),
    so the halved distance and the rounding bit are added to lo one at a time."""
    var dist = UInt64(hi) - UInt64(lo)
    return lo + Int64(dist >> 1) + Int64(dist & UInt64(1))


# =============================================================================
# Flat key extraction: one INT64 / INT32 / FLOAT64 key into order-preserving Int64
# =============================================================================


def _extract_flat_keys(
    imm batch: RecordBatch, key_name: String
) raises -> List[Int64]:
    """Extract the single sort key column of `batch` into a flat
    order-preserving `List[Int64]` (`keys[row]` orders identically to the
    column's ascending order under `sort_key_lt`). INT64 / INT32 are read
    directly (sign-extended); FLOAT64 through `_f64_order_key`. Raises on any
    other key DType (the caller keeps the serial path)."""
    var key_idx = batch.schema.column_index(key_name)
    ref key_col = batch.column_at(key_idx)
    var n = batch.num_rows()
    var keys = List[Int64](capacity=n)
    if key_col.arrow_type == ArrowType.INT64:
        var arr = key_col.as_primitive[DType.int64]()
        for i in range(n):
            keys.append(arr.get_typed[Scalar[DType.int64]](i))
    elif key_col.arrow_type == ArrowType.INT32:
        var arr = key_col.as_primitive[DType.int32]()
        for i in range(n):
            keys.append(Int64(Int(arr.get_typed[Scalar[DType.int32]](i))))
    elif key_col.arrow_type == ArrowType.FLOAT64:
        var arr = key_col.as_primitive[DType.float64]()
        for i in range(n):
            keys.append(
                _f64_order_key(Float64(arr.get_typed[Scalar[DType.float64]](i)))
            )
    else:
        raise Error(
            "parallel_column_sort: unsupported single-key DType "
            + String(key_col.arrow_type)
            + " for column '" + key_name + "'"
        )
    return keys^


@always_inline
def _is_fast_subset_single_key(imm batch: RecordBatch, key_name: String) -> Bool:
    """True iff `key_name` is a fast-subset (INT64 / INT32 / FLOAT64) column —
    the only DTypes the parallel single-key path handles."""
    try:
        var key_idx = batch.schema.column_index(key_name)
        ref key_col = batch.column_at(key_idx)
        return (
            key_col.arrow_type == ArrowType.INT64
            or key_col.arrow_type == ArrowType.INT32
            or key_col.arrow_type == ArrowType.FLOAT64
        )
    except:
        return False


# =============================================================================
# Per-slice stable sort (within-run, parallel) over flat keys
# =============================================================================


def _stable_msort_slice(
    imm keys: List[Int64], mut perm: List[Int], lo: Int, hi: Int,
    mut scratch: List[Int], desc: Bool,
):
    """Stable bottom-up merge sort of `perm[lo:hi)` (indices into `keys`) by the
    effective key order. `scratch` (>= hi capacity in [lo,hi)) is the merge
    buffer. Equal keys keep `perm` order (the merge takes the LEFT run unless
    the RIGHT is strictly effective-less) — STABLE, identical to the serial
    column sort's stable merge."""
    var n = hi - lo
    if n < 2:
        return
    var width = 1
    while width < n:
        var s = lo
        while s < hi:
            var mid = s + width
            if mid > hi:
                mid = hi
            var e = s + 2 * width
            if e > hi:
                e = hi
            var i = s
            var j = mid
            var k = s
            while i < mid and j < e:
                # STABLE: take LEFT unless RIGHT is strictly effective-less.
                if _eff_less(keys[perm[j]], keys[perm[i]], desc):
                    scratch[k] = perm[j]
                    j += 1
                else:
                    scratch[k] = perm[i]
                    i += 1
                k += 1
            while i < mid:
                scratch[k] = perm[i]
                i += 1
                k += 1
            while j < e:
                scratch[k] = perm[j]
                j += 1
                k += 1
            s += 2 * width
        for t in range(lo, hi):
            perm[t] = scratch[t]
        width *= 2


# =============================================================================
# Co-rank parallel multiway merge
# =============================================================================


@always_inline
def _run_lowerbound(imm keys: List[Int64], imm run: List[Int], t: Int64, desc: Bool) -> Int:
    """First index `i` in the effective-sorted `run` (indices into `keys`)
    whose value is NOT effective-less than `t` (count of elements that sort
    strictly before value `t`)."""
    var lo = 0
    var hi = len(run)
    while lo < hi:
        var mid = (lo + hi) // 2
        if _eff_less(keys[run[mid]], t, desc):
            lo = mid + 1
        else:
            hi = mid
    return lo


@always_inline
def _run_upperbound(imm keys: List[Int64], imm run: List[Int], t: Int64, desc: Bool) -> Int:
    """First index `i` in the effective-sorted `run` whose value is effective-
    GREATER than `t` (count of elements <= t)."""
    var lo = 0
    var hi = len(run)
    while lo < hi:
        var mid = (lo + hi) // 2
        if _eff_less(t, keys[run[mid]], desc):
            hi = mid
        else:
            lo = mid + 1
    return lo


def _corank(
    imm keys: List[Int64], imm runs: List[List[Int]], total: Int,
    desc: Bool, target: Int, mut start: List[Int],
):
    """Co-rank: fill `start[r]` (length == len(runs)) with the per-run cursor
    such that the FIRST `target` elements of the global stable merge are exactly
    the union of `runs[r][0:start[r]]` across runs. Exact + stable: the first
    `target` global elements are all elements effective-less-than a threshold
    value `t`, plus a run-index-ordered prefix of the elements equal to `t`.
    `t` is found by binary search over the Int64 value domain so that
    `cnt_lt(t) <= target <= cnt_le(t)`; the equal-to-`t` boundary elements are
    distributed across runs in ASCENDING run index (lower-run-wins-on-tie —
    stability identical to the serial stable merge over contiguous slices)."""
    var nr = len(runs)
    if target <= 0:
        for r in range(nr):
            start[r] = 0
        return
    if target >= total:
        for r in range(nr):
            start[r] = len(runs[r])
        return

    # Value-domain bounds (global min / max effective key across runs). Each run
    # is sorted in EFFECTIVE order, so its head is eff-smallest and tail eff-
    # largest; track the global raw-Int64 value range.
    var vmin = Int64(0)
    var vmax = Int64(0)
    var seen = False
    for r in range(nr):
        var rn = len(runs[r])
        if rn == 0:
            continue
        var head = keys[runs[r][0]]
        var tail = keys[runs[r][rn - 1]]
        var rmin = head
        var rmax = tail
        if rmax < rmin:
            rmin = tail
            rmax = head
        if not seen:
            vmin = rmin
            vmax = rmax
            seen = True
        else:
            if rmin < vmin:
                vmin = rmin
            if rmax > vmax:
                vmax = rmax

    # Binary search the threshold value `t`. `cnt_le_eff(t)` is monotone NON-
    # DECREASING along the EFFECTIVE-increasing direction of the raw line:
    # ASC == raw-increasing (smallest t with cnt_le >= target), DESC == raw-
    # decreasing (largest t with cnt_le >= target).
    var t: Int64
    if not desc:
        var lo = vmin
        var hi = vmax
        while lo < hi:
            var mid = _mid_floor(lo, hi)
            var cnt_le = 0
            for r in range(nr):
                cnt_le += _run_upperbound(keys, runs[r], mid, desc)
            if cnt_le >= target:
                hi = mid
            else:
                lo = mid + 1
        t = lo
    else:
        var lo = vmin
        var hi = vmax
        while lo < hi:
            var mid = _mid_ceil(lo, hi)
            var cnt_le = 0
            for r in range(nr):
                cnt_le += _run_upperbound(keys, runs[r], mid, desc)
            if cnt_le >= target:
                lo = mid
            else:
                hi = mid - 1
        t = lo

    var cnt_lt = 0
    var lb = List[Int](capacity=nr)
    var ub = List[Int](capacity=nr)
    for r in range(nr):
        var l = _run_lowerbound(keys, runs[r], t, desc)
        var u = _run_upperbound(keys, runs[r], t, desc)
        lb.append(l)
        ub.append(u)
        cnt_lt += l

    var rem = target - cnt_lt
    for r in range(nr):
        if rem <= 0:
            start[r] = lb[r]
            continue
        var eq = ub[r] - lb[r]
        if eq <= rem:
            start[r] = ub[r]
            rem -= eq
        else:
            start[r] = lb[r] + rem
            rem = 0


@always_inline
def _slice_head_less(
    run_a: Int, run_b: Int, imm cur: List[Int],
    imm keys: List[Int64], imm runs: List[List[Int]], desc: Bool,
) -> Bool:
    """True iff run_a's current slice head sorts STRICTLY BEFORE run_b's, with a
    RUN-INDEX tiebreak (lower run id is 'smaller' so it is emitted first —
    stability: lower-run-wins-on-tie). Free function so the parallel merge
    closure does not capture a struct receiver."""
    var ka = keys[runs[run_a][cur[run_a]]]
    var kb = keys[runs[run_b][cur[run_b]]]
    if ka != kb:
        if desc:
            return ka > kb
        return ka < kb
    return run_a < run_b


@always_inline
def _sift_slice(
    mut heap: List[Int], root: Int, hn: Int, imm cur: List[Int],
    imm keys: List[Int64], imm runs: List[List[Int]], desc: Bool,
):
    """Min-heap sift-down over the per-slice run ids, ordered by (current-head
    key, run id) ascending."""
    var i = root
    while True:
        var l = 2 * i + 1
        var r = 2 * i + 2
        var smallest = i
        if l < hn and _slice_head_less(heap[l], heap[smallest], cur, keys, runs, desc):
            smallest = l
        if r < hn and _slice_head_less(heap[r], heap[smallest], cur, keys, runs, desc):
            smallest = r
        if smallest == i:
            return
        var tmp = heap[i]
        heap[i] = heap[smallest]
        heap[smallest] = tmp
        i = smallest


# =============================================================================
# The parallel permutation and the public entries
# =============================================================================


@fieldwise_init
struct _PermScratch(Movable, Deinitable):
    """Shared fork-join payload: the permutation under construction plus its
    merge scratch. Both are pre-sized to `n` by the driver; a chunk only
    setitems slots inside its own slice."""
    var perm: List[Int]
    var scratch: List[Int]

    def take_perm(mut self) -> List[Int]:
        """Extract `perm`, leaving an empty List behind (a swap, not a move
        through the field's address)."""
        var out = List[Int]()
        swap(self.perm, out)
        return out^

    def take_scratch(mut self) -> List[Int]:
        """Extract `scratch`, leaving an empty (drop-safe) List behind."""
        var out = List[Int]()
        swap(self.scratch, out)
        return out^


@fieldwise_init
struct _SliceSortWork(SharedChunkWork):
    """Chunk `p` stable-sorts `perm[slice_lo[p]:slice_lo[p+1])` in place using
    the SAME sub-range of `scratch`."""
    var slice_lo: List[Int]
    var desc: Bool

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes a `List[Int64]` as `input` and a
        # `_PermScratch` as `payload` to the `pool.run` that dispatches this
        # work, so each cast is to the exact type of the referent.
        var kp = UnsafePointer(to=input).bitcast[List[Int64]]()
        var pp = UnsafePointer(to=payload).bitcast[_PermScratch]()
        var lo = self.slice_lo[chunk_id]
        var hi = self.slice_lo[chunk_id + 1]
        _stable_msort_slice(kp[], pp[].perm, lo, hi, pp[].scratch, self.desc)


struct _CorankMergeIn(Deinitable):
    """Read-only input bundle for the co-rank multiway merge wave: the flat
    keys, the P sorted runs, the output-rank boundaries, and the per-boundary
    per-run cursors."""
    var keys: List[Int64]
    var runs: List[List[Int]]
    var bounds: List[Int]
    var seg_start: List[List[Int]]

    def __init__(
        out self,
        var keys: List[Int64],
        var runs: List[List[Int]],
        var bounds: List[Int],
        var seg_start: List[List[Int]],
    ):
        self.keys = keys^
        self.runs = runs^
        self.bounds = bounds^
        self.seg_start = seg_start^


@fieldwise_init
struct _CorankMergeWork(SharedChunkWork):
    """Chunk `p` k-way merges output ranks [bounds[p], bounds[p+1]) out of its
    own disjoint per-run sub-ranges."""
    var n_runs: Int
    var desc: Bool

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes a `_CorankMergeIn` as `input` and a
        # `List[Int]` as `payload` to the `pool.run` that dispatches this work,
        # so each cast is to the exact type of the referent.
        var ip = UnsafePointer(to=input).bitcast[_CorankMergeIn]()
        var op = UnsafePointer(to=payload).bitcast[List[Int]]()
        var w_lo = ip[].bounds[chunk_id]
        var w_hi = ip[].bounds[chunk_id + 1]
        if w_hi <= w_lo:
            return
        var nruns = self.n_runs
        var cur = List[Int](capacity=nruns)
        var end = List[Int](capacity=nruns)
        for r in range(nruns):
            cur.append(ip[].seg_start[chunk_id][r])
            end.append(ip[].seg_start[chunk_id + 1][r])
        # Heap of run ids over the slice sub-ranges, ordered by current head key
        # then run id (lower run id wins on a tie — stable).
        var heap = List[Int](capacity=nruns)
        for r in range(nruns):
            if cur[r] < end[r]:
                heap.append(r)
        var hn = len(heap)
        var st = (hn // 2) - 1
        while st >= 0:
            _sift_slice(heap, st, hn, cur, ip[].keys, ip[].runs, self.desc)
            st -= 1
        var w = w_lo
        while hn > 0 and w < w_hi:
            var top = heap[0]
            var pos = cur[top]
            # The global row index at this run cursor.
            op[][w] = ip[].runs[top][pos]
            w += 1
            cur[top] = pos + 1
            if cur[top] >= end[top]:
                hn -= 1
                if hn > 0:
                    heap[0] = heap[hn]
            if hn > 0:
                _sift_slice(heap, 0, hn, cur, ip[].keys, ip[].runs, self.desc)


def _parallel_single_key_perm[
    has_pool: Bool, disp_o: Origin[mut=True],
](
    var keys: List[Int64], desc: Bool, nw_hint: Int,
    pool: SharedForkJoinHandle[has_pool, disp_o],
) raises -> List[Int]:
    """Produce the global stable sort permutation of `keys` (effective order)
    via per-slice parallel sort + co-rank parallel multiway merge.

    The output `perm[i]` is the original row index at sorted position `i`.
    Byte-identical to a single stable merge sort of `keys` (contiguous slices +
    lower-run-wins-on-tie == lower-original-index-wins-on-tie == stable global
    order). The input is cut into `nw_hint` slices (at least 1, at most
    `len(keys)`)."""
    var n = len(keys)
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
    if nw < 1:
        nw = 1

    # Slice boundaries: P contiguous slices [slice_lo[p], slice_lo[p+1]).
    var slice_lo = List[Int](capacity=nw + 1)
    for p in range(nw + 1):
        slice_lo.append((p * n) // nw)

    # ---- Phase 1: PARALLEL per-slice stable sort ----
    # Each worker stable-sorts its OWN disjoint slice [slice_lo[p], slice_lo[p+1])
    # of `perm` in place, using its own scratch sub-range. A single shared
    # `scratch` list is pre-sized to `n`; each worker only touches its own
    # [lo,hi) of both `perm` and `scratch`, so the regions are disjoint.
    var scratch = List[Int](capacity=n)
    for _ in range(n):
        scratch.append(0)

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` reads/writes ONLY perm[slice_lo[p]:slice_lo[p+1])
    #     and scratch[slice_lo[p]:slice_lo[p+1]) (the slice boundaries tile [0,n)
    #     exactly, no overlap). `keys` and `slice_lo` are read-only. No two
    #     chunks touch the same element of perm or scratch.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier (every
    #     shard joins before `run` returns); `keys` is borrowed through a
    #     concrete immutable origin and the perm/scratch payload is MOVED onto
    #     the dispatch State (owned, not borrowed, across the barrier).
    #   * No-realloc: `perm` and `scratch` are sized to `n` ONCE before the
    #     dispatch; the slice sort is setitem on existing slots, never append.
    var buf = pool.run[
        _SliceSortWork, List[Int64], _PermScratch, origin_of(keys)
    ](
        _SliceSortWork(slice_lo.copy(), desc),
        keys,
        _PermScratch(perm^, scratch^),
        nw,
    )

    # If only one slice, `perm` is already the global sorted order.
    if nw == 1:
        return buf.take_perm()

    # ---- Build the P sorted runs as index lists into `keys` ----
    # runs[p] = perm[slice_lo[p]:slice_lo[p+1]) (now sorted within the slice).
    var runs = List[List[Int]]()
    for p in range(nw):
        var lo = slice_lo[p]
        var hi = slice_lo[p + 1]
        var run = List[Int](capacity=hi - lo)
        for t in range(lo, hi):
            run.append(buf.perm[t])
        runs.append(run^)
    _ = buf^
    var total_runs = nw

    # ---- Phase 2: co-rank multiway merge ----
    # Split the `n` output ranks into P contiguous slices; this thread co-ranks
    # each boundary into per-run cursor ranges (serial, `mw + 1` calls of
    # `_corank`); then each worker independently k-way-merges its disjoint
    # output slice from its disjoint per-run sub-ranges into the pre-sized
    # `out_perm`.
    var mw = nw
    if mw > n:
        mw = n
    if mw < 1:
        mw = 1

    var out_perm = List[Int](capacity=n)
    for _ in range(n):
        out_perm.append(0)

    var bounds = List[Int](capacity=mw + 1)
    for p in range(mw + 1):
        bounds.append((p * n) // mw)

    var seg_start = List[List[Int]]()
    for p in range(mw + 1):
        var sc = List[Int](capacity=total_runs)
        for _ in range(total_runs):
            sc.append(0)
        _corank(keys, runs, n, desc, bounds[p], sc)
        seg_start.append(sc^)

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` writes ONLY out_perm[bounds[p]:bounds[p+1])
    #     (pre-sized to `n`, setitem on existing slots). It reads only its own
    #     per-run sub-range [seg_start[p][run], seg_start[p+1][run]) of each
    #     read-only `runs[run]`. The co-rank tiles each run exactly with no
    #     overlap, so no two chunks read or write the same element.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier; the
    #     read-only `keys`/`runs`/`bounds`/`seg_start` are bundled into ONE
    #     driver-owned `_CorankMergeIn` borrowed through a concrete immutable
    #     origin, and `out_perm` is MOVED onto the dispatch State.
    #   * No-realloc: `out_perm` is sized to `n` ONCE before the dispatch;
    #     `seg_start` is a pre-built per-boundary list, read-only in the chunk.
    var merge_in = _CorankMergeIn(keys^, runs^, bounds^, seg_start^)
    var merged = pool.run[
        _CorankMergeWork, _CorankMergeIn, List[Int], origin_of(merge_in)
    ](
        _CorankMergeWork(total_runs, desc),
        merge_in,
        out_perm^,
        mw,
    )
    _ = merge_in^

    return merged^


def can_parallel_sort_single_key(
    imm batch: RecordBatch, num_keys: Int, key_name: String, force: Bool = False
) -> Bool:
    """Gate: True iff `batch` should take the PARALLEL single-key column-sort
    path. Requires exactly one sort key in the fast fixed subset
    (INT64 / INT32 / FLOAT64) and (unless `force`) at least
    `MIN_PARALLEL_SORT_ROWS` rows."""
    if num_keys != 1:
        return False
    if not _is_fast_subset_single_key(batch, key_name):
        return False
    if force:
        return True
    return batch.num_rows() >= MIN_PARALLEL_SORT_ROWS


@always_inline
def resolve_sort_workers(num_workers: Int) -> Int:
    """The slice count of a parallel sort: `num_workers` when positive, else
    the host's physical core count (at least 1). The permutation does not
    depend on it; a test passes a count to pin the split."""
    if num_workers > 0:
        return num_workers
    var nw = num_physical_cores()
    if nw < 1:
        nw = 1
    return nw


def parallel_sort_single_key[
    has_pool: Bool, disp_o: Origin[mut=True],
](
    var batch: RecordBatch, key_name: String, descending: Bool,
    pool: SharedForkJoinHandle[has_pool, disp_o],
    num_workers: Int = 0,
) raises -> RecordBatch:
    """Sort `batch` by its one INT64 / INT32 / FLOAT64 key `key_name`: a
    per-slice parallel stable sort and a parallel co-rank multiway merge, then
    one gather of every column by the permutation.

    The same rows in the same order as the serial
    `sort_topn_sink._sort_batch_single_key`, NaN and signed zeros included.
    `batch` is consumed. The caller has checked `can_parallel_sort_single_key`.
    `num_workers` is the slice count (`resolve_sort_workers`)."""
    var n = batch.num_rows()
    if n <= 1:
        return batch^

    var keys = _extract_flat_keys(batch, key_name)
    var perm = _parallel_single_key_perm[has_pool, disp_o](
        keys^, descending, resolve_sort_workers(num_workers), pool
    )
    # The gather runs on the same pool: `pool.ptr` is the
    # `Optional[Pointer[LocalDispatcher[NoopSink], disp_o]]` it takes.
    return gather_batch_dispatch[has_pool, LocalDispatcher[NoopSink], disp_o](
        batch, perm, pool.ptr
    )


def parallel_sort_single_key_serial(
    var batch: RecordBatch, key_name: String, descending: Bool,
    num_workers: Int = 0,
) raises -> RecordBatch:
    """The dispatcher-less entry: the same chunks run inline, so the result is
    the pooled entry's."""
    return parallel_sort_single_key(
        batch^, key_name, descending, serial_fork_join_handle(), num_workers
    )


# =============================================================================
# merge_sorted_partitions_single_key: the serial k-way merge of sorted batches
# =============================================================================
#
# A caller that sorts each worker's batch on its own (so no fork-join nests
# under a live pool) merges the N already-sorted partition batches here into
# ONE globally-sorted batch with a SERIAL heap k-way merge. The merge is
# O(n log N) (N == partition count), the cheap part when the O(n log n) sorts
# already ran in parallel. Not yet called from the sort sink. Same rows as a
# single stable sort: each partition is stably sorted, and the heap breaks
# key ties by ASCENDING partition index (lower partition wins), which matches a
# stable global sort over (P0 ++ P1 ++ ... ++ P_{N-1}) — the same partition
# order the driver folds workers in.


@always_inline
def _heap_head_less(
    run_a: Int, run_b: Int, imm cur: List[Int], imm base: List[Int],
    imm keys: List[Int64], desc: Bool,
) -> Bool:
    """True iff partition run_a's current head sorts STRICTLY BEFORE run_b's,
    lower-partition-wins-on-tie. `cur[r]` is the per-partition cursor; `base[r]`
    is partition r's row offset in the concatenated flat-key array."""
    var ka = keys[base[run_a] + cur[run_a]]
    var kb = keys[base[run_b] + cur[run_b]]
    if ka != kb:
        if desc:
            return ka > kb
        return ka < kb
    return run_a < run_b


@always_inline
def _heap_sift(
    mut heap: List[Int], root: Int, hn: Int, imm cur: List[Int],
    imm base: List[Int], imm keys: List[Int64], desc: Bool,
):
    var i = root
    while True:
        var l = 2 * i + 1
        var r = 2 * i + 2
        var smallest = i
        if l < hn and _heap_head_less(heap[l], heap[smallest], cur, base, keys, desc):
            smallest = l
        if r < hn and _heap_head_less(heap[r], heap[smallest], cur, base, keys, desc):
            smallest = r
        if smallest == i:
            return
        var tmp = heap[i]
        heap[i] = heap[smallest]
        heap[smallest] = tmp
        i = smallest


def merge_sorted_partitions_single_key[
    has_pool: Bool, disp_o: Origin[mut=True],
](
    var partitions: Slab[RecordBatch], key_name: String, descending: Bool,
    pool: SharedForkJoinHandle[has_pool, disp_o],
) raises -> RecordBatch:
    """Merge N already-sorted single-key partition batches into ONE globally-
    sorted batch (SERIAL heap k-way merge; only the final gather forks).

    Each partition in `partitions` MUST already be sorted by `key_name` in the
    same direction. Concatenates them into one contiguous batch (preserving
    per-partition order), extracts the single flat order-preserving key, runs a
    serial binary-min-heap k-way merge over the per-partition cursors producing
    one global permutation (lower-partition-wins-on-tie == stable), and gathers
    once. `partitions` is consumed.

    `pool` is for the closing gather only; the k-way merge is serial. Call it
    when no other dispatch is live on the pool, so the gather gets every
    worker. A key column's NULLs are not read (see the header). Dispatcher-less
    callers use `merge_sorted_partitions_single_key_serial`."""
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

    var keys = _extract_flat_keys(merged, key_name)
    var desc = descending

    # Per-partition cursor (offset within its [base[p], base[p+1]) range).
    var cur = List[Int](capacity=np)
    var plen = List[Int](capacity=np)
    for p in range(np):
        cur.append(0)
        plen.append(base[p + 1] - base[p])

    # Seed the heap with every non-empty partition.
    var heap = List[Int](capacity=np)
    for p in range(np):
        if plen[p] > 0:
            heap.append(p)
    var hn = len(heap)
    var start = (hn // 2) - 1
    while start >= 0:
        _heap_sift(heap, start, hn, cur, base, keys, desc)
        start -= 1

    var perm = List[Int](capacity=total)
    while hn > 0:
        var top = heap[0]
        perm.append(base[top] + cur[top])
        cur[top] = cur[top] + 1
        if cur[top] >= plen[top]:
            hn -= 1
            if hn > 0:
                heap[0] = heap[hn]
        if hn > 0:
            _heap_sift(heap, 0, hn, cur, base, keys, desc)

    # The gather runs on the pool (see `parallel_sort_single_key`).
    return gather_batch_dispatch[has_pool, LocalDispatcher[NoopSink], disp_o](
        merged, perm, pool.ptr
    )


def merge_sorted_partitions_single_key_serial(
    var partitions: Slab[RecordBatch], key_name: String, descending: Bool,
) raises -> RecordBatch:
    """The dispatcher-less entry: the gather runs inline, so the result is
    the pooled entry's."""
    return merge_sorted_partitions_single_key(
        partitions^, key_name, descending, serial_fork_join_handle()
    )
