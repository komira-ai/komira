# =============================================================================
# sort_dictrank_build -- the dictionary of a low-cardinality STRING sort key:
# the cardinality gate, the parallel dictionary build, and the rank of each
# distinct value
# =============================================================================
#
# `sort_dictrank` sorts one STRING / BINARY key of low cardinality without a
# comparison merge: each distinct value gets a dense rank (its position in
# byte-wise order, the shorter string first on a shared prefix), every row is
# mapped to its value's rank, and a stable counting sort over the ranks gives
# the permutation. This module holds the first half:
#
#   * the gate's cheap estimate: hash a strided sample of rows and count the
#     distinct hashes (`_dictrank_cardinality_ok`). The sample is a fixed
#     stride, so a periodic key whose period shares the stride, or one that is
#     distinct only past the last sampled row, can be admitted although its
#     cardinality is high. The exact build is the backstop: the rows are still
#     correct (a distinct count over the ceiling falls back to the comparison
#     sort), but the sort has paid for a full dictionary build first. On the
#     multi-worker `SortSink` route the gate samples partition 0 only;
##   * the dictionary: each worker hashes its own slice into its own dictionary
#     (verifying each hit against the bytes of a representative row), the
#     per-worker dictionaries merge serially into one, and each worker then
#     translates its rows' local ids to global ids (`_build_distinct_ids`);
#   * the ranks: the D distinct values sorted once, O(D log D)
#     (`_sort_distinct_to_rank`).
#
# The dictionary holds row indices, never strings: a worker reads the key's
# offsets and data through pointers with the borrowed column's origins and
# builds no reference-counted value.

from std.collections.dict import Dict
from std.builtin.swap import swap
from std.memory import UnsafePointer

from komira_async.runtime.parallel_fork_join_shared import SharedForkJoinHandle
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_counters.keyeq_census import keyeq_record, KEYEQ_DICTRANK_ROWBYTES

from .sort_parallel_string_kernels import _str_lt_idx


# The number of rows the cardinality estimate hashes, strided over the column.
comptime DICTRANK_SAMPLE_ROWS: Int = 1 << 16

# The default ceiling on the distinct count. The counting sort's histogram is
# `workers * (distinct + 1)` ints, so a key above this keeps the comparison
# sort. A caller may pass a lower ceiling to bound that histogram.
comptime DICTRANK_MAX_DISTINCT: Int = 1 << 17

# A sample whose distinct ratio is above this percentage is read as a
# high-cardinality column, whatever the absolute count.
comptime DICTRANK_MAX_DISTINCT_RATIO_PCT: Int = 50

# The row count below which the gate declines unless forced.
comptime DICTRANK_MIN_ROWS: Int = 64 * 1024


def _estimate_distinct_sampled[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    n: Int,
) -> Int:
    """Estimate the distinct VALUE count by hashing `DICTRANK_SAMPLE_ROWS` rows
    STRIDED across the WHOLE [0, n) range (not the first-N) into an FNV-keyed set.
    Returns the sampled distinct count (NOT extrapolated — the caller compares it
    against the absolute + ratio ceilings). Hash-only (no string materialize) so
    this stays cheap; rare hash collisions only UNDER-count, which can only make
    the gate MORE conservative (decline), never wrongly admit.

    Strided, not the first N rows: a first-N sample admits a column that is
    low-cardinality in its head and high-cardinality in its tail (a clustered
    or partly sorted key), and the `workers * (d + 1)` histogram then grows
    with the tail. The exact distinct count after the build is the hard
    backstop (`parallel_dictrank_sort_string` falls back above the ceiling);
    the stride makes the cheap gate catch the common case."""
    var sample = DICTRANK_SAMPLE_ROWS if n > DICTRANK_SAMPLE_ROWS else n
    if sample <= 0:
        return 0
    # Stride so `sample` probes tile [0, n) uniformly. stride>=1; the last probe
    # lands at row (sample-1)*stride < n. When n <= sample, stride==1 (scan all).
    var stride = n // sample
    if stride < 1:
        stride = 1
    var seen = Dict[Int64, Bool]()
    for k in range(sample):
        var row = k * stride
        if row >= n:
            break
        var off = col_offset + row
        var start = Int((offsets_ptr + off)[])
        var slen = Int((offsets_ptr + off + 1)[]) - start
        var h = Int64(-3750763034362895579)  # FNV-1a 64-bit offset basis
        for b in range(slen):
            h = (h ^ Int64((data_ptr + start + b)[])) * Int64(1099511628211)
        h = h ^ (Int64(slen) * Int64(1099511628211))
        seen[h] = True
    return len(seen)


def _dictrank_cardinality_ok[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    n: Int,
    max_distinct: Int,
) -> Bool:
    """Cheap gate: True iff the sampled distinct estimate is low enough that the
    dict-rank counting sort is the right path. Combines an absolute ceiling
    (`max_distinct`) with a sampled-distinct-RATIO ceiling (the column is
    near-all-distinct in the sample => high-cardinality at scale)."""
    var sd = _estimate_distinct_sampled(offsets_ptr, data_ptr, col_offset, n)
    if sd > max_distinct:
        return False
    var sample = DICTRANK_SAMPLE_ROWS if n > DICTRANK_SAMPLE_ROWS else n
    if sample <= 0:
        return False
    # sd/sample > ratio  <=>  sd*100 > ratio_pct*sample (integer, no float).
    if sd * 100 > DICTRANK_MAX_DISTINCT_RATIO_PCT * sample:
        return False
    return True


# -----------------------------------------------------------------------------
# Dictionary build + distinct sort + per-row rank map
# -----------------------------------------------------------------------------


@always_inline
def _fnv_hash_row[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    row: Int,
) -> Int64:
    """FNV-1a hash of the string at logical `row` (length-mixed)."""
    var off = col_offset + row
    var start = Int((offsets_ptr + off)[])
    var slen = Int((offsets_ptr + off + 1)[]) - start
    var h = Int64(-3750763034362895579)
    var b = 0
    while b < slen:
        h = (h ^ Int64((data_ptr + start + b)[])) * Int64(1099511628211)
        b += 1
    h = h ^ (Int64(slen) * Int64(1099511628211))
    return h


@always_inline
def _row_bytes_equal[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    a: Int,
    b: Int,
) -> Bool:
    """Byte-equality of the strings at logical rows `a` and `b`."""
    var a_off = col_offset + a
    var b_off = col_offset + b
    var a_start = Int((offsets_ptr + a_off)[])
    var a_len = Int((offsets_ptr + a_off + 1)[]) - a_start
    var b_start = Int((offsets_ptr + b_off)[])
    var b_len = Int((offsets_ptr + b_off + 1)[]) - b_start
    if a_len != b_len:
        keyeq_record(KEYEQ_DICTRANK_ROWBYTES, a_len, 0, False)
        return False
    var i = 0
    var _eq = True
    while i < a_len:
        if (data_ptr + a_start + i)[] != (data_ptr + b_start + i)[]:
            _eq = False
            break
        i += 1
    keyeq_record(KEYEQ_DICTRANK_ROWBYTES, a_len, i, _eq)
    return _eq


def _dict_build_row[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    row: Int,
    mut hd: Dict[Int64, List[Int]],
    mut reps: List[Int],
) raises -> Int:
    """Insert/find `row`'s string value in the hash dict `hd` (chains of distinct
    ids, verify-on-hit against `reps[id]`'s bytes). Returns the (possibly new)
    distinct id; appends to `reps` on a miss. Shared by the per-worker LOCAL build
    and the serial GLOBAL merge."""
    var h = _fnv_hash_row(offsets_ptr, data_ptr, col_offset, row)
    if h in hd:
        ref chain = hd[h]
        for c in range(len(chain)):
            var cand = chain[c]
            if _row_bytes_equal(
                offsets_ptr, data_ptr, col_offset, row, reps[cand]
            ):
                return cand
        var nid = len(reps)
        reps.append(row)
        chain.append(nid)
        return nid
    var nid = len(reps)
    reps.append(row)
    var chain = List[Int]()
    chain.append(nid)
    hd[h] = chain^
    return nid


@fieldwise_init
struct _DictBuildPayload(Movable, Deinitable):
    """Shared fork-join payload for the parallel LOCAL dict build: one hash
    dict + one representative-row list PER WORKER (chunk `p` owns slot `p`
    exclusively), plus the per-row local distinct id over the whole row space
    (chunk `p` writes only its own slice)."""
    var local_dicts: List[Dict[Int64, List[Int]]]
    var local_reps: List[List[Int]]
    var local_id: List[Int]

    def take_local_id(mut self) -> List[Int]:
        var out = List[Int]()
        swap(self.local_id, out)
        return out^


@fieldwise_init
struct _DictBuildWork[
    o_off: Origin[mut=False], o_data: Origin[mut=False],
](SharedChunkWork):
    """Chunk `p` hashes rows [slice_lo[p], slice_lo[p+1]) into ITS OWN local
    dict + rep list, recording each row's LOCAL distinct id."""
    # SAFETY: raw STRING offsets/data pointers with CONCRETE origins pinned to
    # the caller's borrowed key column; read-only, never escape this module.
    var offsets_ptr: UnsafePointer[Scalar[DType.int32], Self.o_off]
    var data_ptr: UnsafePointer[Scalar[DType.uint8], Self.o_data]
    var col_offset: Int
    var has_validity: Bool
    var slice_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes the `In` this struct is dispatched with; the
        # bitcast names that exact type, fixed by the call site, and the borrow
        # outlives the synchronous barrier. It is only read.
        var vp = UnsafePointer(to=input).bitcast[List[Bool]]()
        # SAFETY: `payload` is the value the driver moved onto the dispatch State,
        # of the bitcast type; this chunk writes only its own disjoint band.
        var pp = UnsafePointer(to=payload).bitcast[_DictBuildPayload]()
        var lo = self.slice_lo[chunk_id]
        var hi = self.slice_lo[chunk_id + 1]
        var hd_p = UnsafePointer(to=pp[].local_dicts[chunk_id])
        var reps_p = UnsafePointer(to=pp[].local_reps[chunk_id])
        var lid_p = UnsafePointer(to=pp[].local_id)
        for row in range(lo, hi):
            if self.has_validity and not vp[][row]:
                lid_p[][row] = -1
                continue
            lid_p[][row] = _dict_build_row(
                self.offsets_ptr, self.data_ptr, self.col_offset, row,
                hd_p[], reps_p[],
            )


@fieldwise_init
struct _DictTranslateWork(SharedChunkWork):
    """Chunk `p` translates its slice's LOCAL distinct ids to GLOBAL ids."""
    var l2g: List[List[Int]]
    var slice_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver passes the `In` this struct is dispatched with; the
        # bitcast names that exact type, fixed by the call site, and the borrow
        # outlives the synchronous barrier. It is only read.
        var lp = UnsafePointer(to=input).bitcast[List[Int]]()
        # SAFETY: `payload` is the value the driver moved onto the dispatch State,
        # of the bitcast type; this chunk writes only its own disjoint band.
        var pp = UnsafePointer(to=payload).bitcast[List[Int]]()
        var lo = self.slice_lo[chunk_id]
        var hi = self.slice_lo[chunk_id + 1]
        ref trans = self.l2g[chunk_id]
        for row in range(lo, hi):
            var li = lp[][row]
            if li < 0:
                pp[][row] = -1
            else:
                pp[][row] = trans[li]


def _build_distinct_ids[
    o_off: Origin[mut=False], o_data: Origin[mut=False],
    has_pool: Bool, disp_o: Origin[mut=True],
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    n: Int,
    imm valid: List[Bool],
    has_validity: Bool,
    nw_hint: Int,
    var prov_id: List[Int],
    mut rep_row: List[Int],
    pool: SharedForkJoinHandle[has_pool, disp_o],
) raises -> List[Int]:
    """PARALLEL dict build: assign each row a GLOBAL provisional distinct id in
    `prov_id[row]` and record a REPRESENTATIVE original row index for each distinct
    value in `rep_row[id]`. NULL rows get `prov_id = -1` (handled by the null
    sentinel rank downstream). Hash-keyed (verify-on-hit) over the row's bytes,
    mirroring the COUNT(DISTINCT) STRING-encode shape — NO String materialize, the
    representative row index pins the bytes.

    Three phases, so the per-row hashing is split across the workers:
      A (PARALLEL): each worker hashes ITS slice into a LOCAL hash dict, assigning
        a LOCAL distinct id per row into `local_id[row]` + a local rep_row list.
      B (SERIAL, cheap): merge the N local distinct sets into ONE global dict
        (~N*D lookups, small for a low-cardinality key), building a per-worker local->global id
        translation table + the global `rep_row`.
      C (PARALLEL): each worker translates `prov_id[row] = l2g[w][local_id[row]]`.

    `prov_id` must be pre-sized to `n`; `rep_row` empty (grows by distinct count)."""
    var nw = nw_hint
    if nw < 1:
        nw = 1
    if nw > n:
        nw = n

    var slice_lo = List[Int](capacity=nw + 1)
    for p in range(nw + 1):
        slice_lo.append((p * n) // nw)

    # Per-worker local hash dict (hash -> chain of LOCAL distinct ids) + per-worker
    # local rep_row list (local id -> representative original row). Each worker
    # owns its own slot exclusively (disjoint).
    var local_dicts = List[Dict[Int64, List[Int]]]()
    var local_reps = List[List[Int]]()
    for _ in range(nw):
        local_dicts.append(Dict[Int64, List[Int]]())
        local_reps.append(List[Int]())
    # Per-row LOCAL distinct id (within the row's worker). -1 == NULL.
    var local_id = List[Int](capacity=n)
    for _ in range(n):
        local_id.append(-1)

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` reads ONLY rows [slice_lo[p], slice_lo[p+1]) of
    #     the (read-only) key buffers + `valid`, and writes ONLY local_dicts[p],
    #     local_reps[p], and local_id[slice_lo[p]:slice_lo[p+1]) — each chunk's
    #     own slot of the per-worker lists + its own disjoint band of local_id.
    #     No two chunks touch the same Dict / rep list / local_id element.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier; `valid`
    #     is borrowed through a concrete immutable origin and the
    #     dicts/reps/local_id payload is MOVED onto the dispatch State. The
    #     per-worker Dict[Int64, List[Int]] is a pure value type (NO
    #     StringArray/Column/ArcPointer) — the representative ROW INDEX pins the
    #     string bytes (read-only on the caller's column).
    #   * No-realloc: local_dicts/local_reps/local_id are sized to nw / n ONCE
    #     before the dispatch; the per-chunk Dict/rep list grow within a chunk's
    #     OWN slot (no cross-chunk realloc), local_id is setitem on live slots.
    var built = pool.run(
        _DictBuildWork(
            offsets_ptr, data_ptr, col_offset, has_validity, slice_lo.copy(),
        ),
        valid,
        _DictBuildPayload(local_dicts^, local_reps^, local_id^),
        nw,
    )

    # Phase B (SERIAL, cheap): merge per-worker local distincts into the GLOBAL
    # dict. `l2g[w]` maps worker w's LOCAL id -> the GLOBAL distinct id.
    var global_dict = Dict[Int64, List[Int]]()
    var l2g = List[List[Int]]()
    for w in range(nw):
        var nloc = len(built.local_reps[w])
        var trans = List[Int](capacity=nloc)
        for li in range(nloc):
            var rrow = built.local_reps[w][li]
            var gid = _dict_build_row(
                offsets_ptr, data_ptr, col_offset, rrow, global_dict, rep_row
            )
            trans.append(gid)
        l2g.append(trans^)

    # Phase C (PARALLEL): translate each row's local id -> global id.
    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: chunk `p` reads l2g[p] (its own translation) + local_id
    #     [slice_lo[p]:slice_lo[p+1]) and writes ONLY prov_id over the SAME
    #     disjoint band. No two chunks touch the same prov_id element;
    #     l2g/local_id are read-only here.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier;
    #     `local_id` is borrowed through a concrete immutable origin and
    #     `prov_id` is MOVED onto the dispatch State.
    #   * No-realloc: prov_id is sized to `n` ONCE; the translate is setitem on
    #     existing slots.
    var lid_done = built.take_local_id()
    _ = built^
    var prov_out = pool.run(
        _DictTranslateWork(l2g^, slice_lo.copy()),
        lid_done,
        prov_id^,
        nw,
    )
    _ = lid_done^
    return prov_out^


def _sort_distinct_to_rank[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    imm rep_row: List[Int],
    descending: Bool,
) raises -> List[Int]:
    """Sort the distinct values lexicographically (length tiebreak — the
    `_str_lt_idx` order) and return `rank[id]` = the sorted position of distinct
    `id`. For DESCENDING the rank is COMPLEMENTED (`d-1-pos`) so the SAME
    ascending counting sort emits descending order. O(D log D) over the distinct
    representatives (a comparison merge sort; cheap for a low-cardinality
    key)."""
    var d = len(rep_row)
    var rank = List[Int](capacity=max(d, 1))
    for _ in range(d):
        rank.append(0)
    if d <= 1:
        return rank^

    # order[i] = distinct id at sorted position i. Bottom-up STABLE merge sort
    # over the distinct ids, comparing their representative rows' string bytes.
    var order = List[Int](capacity=d)
    for i in range(d):
        order.append(i)
    var tmp = List[Int](capacity=d)
    for _ in range(d):
        tmp.append(0)

    var width = 1
    while width < d:
        var lo = 0
        while lo < d:
            var mid = lo + width
            if mid > d:
                mid = d
            var hi = lo + 2 * width
            if hi > d:
                hi = d
            # Merge order[lo:mid) and order[mid:hi) into tmp[lo:hi).
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                # STABLE: take left when keys are equal — but distinct values are
                # UNIQUE, so equality cannot occur between two distinct ids.
                if _str_lt_idx(
                    offsets_ptr, data_ptr, col_offset,
                    rep_row[order[j]], rep_row[order[i]],
                ):
                    tmp[k] = order[j]
                    j += 1
                else:
                    tmp[k] = order[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = order[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = order[j]
                j += 1
                k += 1
            lo += 2 * width
        for x in range(d):
            order[x] = tmp[x]
        width *= 2

    for pos in range(d):
        var did = order[pos]
        if descending:
            rank[did] = d - 1 - pos
        else:
            rank[did] = pos
    return rank^
