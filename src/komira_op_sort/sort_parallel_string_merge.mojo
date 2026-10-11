# =============================================================================
# sort_parallel_string_merge -- the parallel pairwise-tree merge of sorted
# string runs
# =============================================================================
#
# Sorted runs are merged in a balanced reduction tree: each round merges
# adjacent pairs, and each 2-way merge is itself cut across the pool by a
# comparator co-rank (a merge-path binary search on the output diagonal). The
# left run wins every tie, so the result is the stable merge's. The rows are
# compared by a direction-encoded 8-byte prefix key first and by the full
# comparator (`sort_parallel_string_kernels._str_before_flatvalid`) only on a
# prefix tie or a null.

from std.memory import UnsafePointer

from komira_async.runtime.parallel_fork_join_shared import SharedForkJoinHandle
from komira_async_api.shared_chunk_work import SharedChunkWork

from .sort_parallel import _PermScratch
from .sort_parallel_string_kernels import _str_before_flatvalid


@always_inline
def _pk_row_lt[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    ra: Int, rb: Int, imm pk: List[UInt64],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
) -> Bool:
    """True iff row `ra` sorts STRICTLY BEFORE row `rb` in the effective total
    order (NO run-index tiebreak — equal strings return False). pk-accelerated:
    compare the direction-encoded u64 prefix first, fall to the authoritative
    `_str_before_flatvalid` only on a prefix tie / null involvement. Equal rows
    => False (so the merge-path stability rule 'left wins ties' is enforced by
    the merge structure, not here)."""
    if has_validity:
        if not valid[ra] or not valid[rb]:
            return _str_before_flatvalid(
                offsets_ptr, data_ptr, col_offset, valid, has_validity,
                ra, rb, descending,
            )
    var ka = pk[ra]
    var kb = pk[rb]
    if ka != kb:
        return ka < kb
    return _str_before_flatvalid(
        offsets_ptr, data_ptr, col_offset, valid, has_validity, ra, rb, descending
    )


@always_inline
def _corank_2way[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    imm src: List[Int], a_lo: Int, a_mid: Int, a_hi: Int, diag: Int,
    imm pk: List[UInt64],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
) -> Int:
    """MERGE-PATH co-rank: for output diagonal `diag` (0..lenA+lenB) of the
    2-way STABLE merge of LEFT = src[a_lo:a_mid) and RIGHT = src[a_mid:a_hi),
    return the count `i` of LEFT elements that precede output position `diag`
    (so RIGHT contributes `diag - i`). STABLE (LEFT wins ties): `i` is the
    SMALLEST index such that LEFT[i] is strictly-after RIGHT[diag-i-1], i.e.
    binary search the diagonal. Indices are relative to the runs (i in [0,lenA])."""
    var len_a = a_mid - a_lo
    var len_b = a_hi - a_mid
    var lo = diag - len_b
    if lo < 0:
        lo = 0
    var hi = diag
    if hi > len_a:
        hi = len_a
    # Bisect for the smallest `i` in [lo, hi] with RIGHT[diag - i - 1]
    # strictly before LEFT[i] (else `hi`). A tie does not count as "before", so
    # equal rows stay on the LEFT side of the split: the left run wins.
    while lo < hi:
        var i = (lo + hi) // 2
        var j = diag - i - 1
        var left_row = src[a_lo + i]
        var right_row = src[a_mid + j]
        if _pk_row_lt(
            right_row, left_row, pk, offsets_ptr, data_ptr, col_offset,
            valid, has_validity, descending,
        ):
            hi = i
        else:
            lo = i + 1
    return lo


def _merge_2way_range[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    imm src: List[Int], mut dst: List[Int],
    a_lo: Int, a_mid: Int, a_hi: Int,
    out_lo: Int, out_hi: Int,
    imm pk: List[UInt64],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
):
    """Merge the co-ranked OUTPUT sub-range [out_lo, out_hi) of the 2-way STABLE
    merge of LEFT = src[a_lo:a_mid) and RIGHT = src[a_mid:a_hi) into dst (absolute
    positions a_lo + out_lo .. a_lo + out_hi). `out_lo`/`out_hi` are diagonals
    relative to the pair (0..lenA+lenB). Co-ranks the two diagonals to find the
    per-run cursors, then merges. STABLE: LEFT wins ties."""
    var i = _corank_2way(
        src, a_lo, a_mid, a_hi, out_lo, pk, offsets_ptr, data_ptr,
        col_offset, valid, has_validity, descending,
    )
    var j = out_lo - i
    var i_end = _corank_2way(
        src, a_lo, a_mid, a_hi, out_hi, pk, offsets_ptr, data_ptr,
        col_offset, valid, has_validity, descending,
    )
    var j_end = out_hi - i_end
    var la = a_mid
    var lb = a_hi
    var w = a_lo + out_lo
    var ai = a_lo + i
    var bj = a_mid + j
    var ai_end = a_lo + i_end
    var bj_end = a_mid + j_end
    while ai < ai_end and bj < bj_end:
        var ra = src[ai]
        var rb = src[bj]
        # STABLE: take LEFT unless RIGHT is strictly before LEFT.
        if _pk_row_lt(
            rb, ra, pk, offsets_ptr, data_ptr, col_offset,
            valid, has_validity, descending,
        ):
            dst[w] = rb
            bj += 1
        else:
            dst[w] = ra
            ai += 1
        w += 1
    while ai < ai_end:
        dst[w] = src[ai]
        ai += 1
        w += 1
    while bj < bj_end:
        dst[w] = src[bj]
        bj += 1
        w += 1
    _ = la
    _ = lb


@fieldwise_init
struct _PairMergeWork[
    o_off: Origin[mut=False], o_data: Origin[mut=False], v_o: ImmOrigin,
](SharedChunkWork):
    """One flattened (pair, output-sub-range) 2-way co-rank merge item of a
    pairwise-tree reduction round."""
    # SAFETY: raw STRING offsets/data pointers with CONCRETE origins pinned to
    # the caller's borrowed key column; read-only, never escape this module.
    var offsets_ptr: UnsafePointer[Scalar[DType.int32], Self.o_off]
    var data_ptr: UnsafePointer[Scalar[DType.uint8], Self.o_data]
    # Safe tight-origin reference to the driver's flat validity list.
    var valid: Pointer[List[Bool], Self.v_o]
    var col_offset: Int
    var has_validity: Bool
    var desc: Bool
    var src_is_perm: Bool
    var pair_lo: List[Int]
    var pair_mid: List[Int]
    var pair_hi: List[Int]
    var item_pair: List[Int]
    var item_olo: List[Int]
    var item_ohi: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        var pkp = UnsafePointer(to=input).bitcast[List[UInt64]]()
        var bp = UnsafePointer(to=payload).bitcast[_PermScratch]()
        var perm_p = UnsafePointer(to=bp[].perm)
        var scratch_p = UnsafePointer(to=bp[].scratch)
        var t = self.item_pair[chunk_id]
        var a_lo = self.pair_lo[t]
        var a_mid = self.pair_mid[t]
        var a_hi = self.pair_hi[t]
        var olo = self.item_olo[chunk_id]
        var ohi = self.item_ohi[chunk_id]
        if a_mid >= a_hi:
            # Degenerate lone run: copy [a_lo+olo, a_lo+ohi) through.
            if self.src_is_perm:
                for x in range(a_lo + olo, a_lo + ohi):
                    scratch_p[][x] = perm_p[][x]
            else:
                for x in range(a_lo + olo, a_lo + ohi):
                    perm_p[][x] = scratch_p[][x]
            return
        if self.src_is_perm:
            _merge_2way_range(
                perm_p[], scratch_p[], a_lo, a_mid, a_hi, olo, ohi,
                pkp[], self.offsets_ptr, self.data_ptr, self.col_offset,
                self.valid[], self.has_validity, self.desc,
            )
        else:
            _merge_2way_range(
                scratch_p[], perm_p[], a_lo, a_mid, a_hi, olo, ohi,
                pkp[], self.offsets_ptr, self.data_ptr, self.col_offset,
                self.valid[], self.has_validity, self.desc,
            )


def _parallel_pairwise_round[
    o_off: Origin[mut=False], o_data: Origin[mut=False],
    has_pool: Bool, disp_o: Origin[mut=True],
](
    var buf: _PermScratch, imm pk: List[UInt64],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
    imm pair_lo: List[Int], imm pair_mid: List[Int], imm pair_hi: List[Int],
    src_is_perm: Bool, mw: Int,
    pool: SharedForkJoinHandle[has_pool, disp_o],
) raises -> _PermScratch:
    """Run ONE reduction round in PARALLEL: merge each (pair_lo, pair_mid,
    pair_hi) 2-way pair from the SOURCE buffer into the DEST buffer. Work is
    tiled into `mw` flattened (pair, output-sub-range) items so even a single
    big late-round pair is split across all workers via co-rank. `src_is_perm`
    selects perm->scratch (True) or scratch->perm (False).

    Cross-thread safe: every work item writes a DISJOINT output sub-range of the
    dest buffer (co-rank tiles each pair's output exactly) and reads only the
    source buffer + pk + raw byte buffers. NO ArcPointer/Column is touched."""
    var npairs = len(pair_lo)
    # Build flattened work items: distribute `mw` sub-ranges across pairs in
    # proportion to each pair's output length (so big pairs get more workers).
    var total_out = 0
    for t in range(npairs):
        total_out += pair_hi[t] - pair_lo[t]
    if total_out == 0:
        return buf^
    var item_pair = List[Int]()
    var item_olo = List[Int]()
    var item_ohi = List[Int]()
    for t in range(npairs):
        var plo = pair_lo[t]
        var pmid = pair_mid[t]
        var phi = pair_hi[t]
        var pair_out = phi - plo
        if pair_out <= 0:
            continue
        # Degenerate pair (mid == hi): a lone trailing run, just copy through.
        if pmid >= phi:
            item_pair.append(t)
            item_olo.append(0)
            item_ohi.append(pair_out)
            continue
        # Sub-divide this pair's [0, pair_out) into `share` chunks.
        var share = (mw * pair_out + total_out - 1) // total_out
        if share < 1:
            share = 1
        for s in range(share):
            var olo = (s * pair_out) // share
            var ohi = ((s + 1) * pair_out) // share
            if ohi <= olo:
                continue
            item_pair.append(t)
            item_olo.append(olo)
            item_ohi.append(ohi)
    var n_items = len(item_pair)
    if n_items == 0:
        return buf^

    # DISPATCH-BOUNDARY SAFETY:
    #   * Disjointness: each chunk writes a DISJOINT output sub-range of the
    #     DEST buffer — the co-rank tiles every pair's output [0,pair_out) into
    #     non-overlapping [olo,ohi) chunks, and pairs cover disjoint absolute
    #     ranges (the bounds tile [0,n)). No two chunks write the same dest
    #     slot. The SOURCE buffer, pk, valid, and the raw byte buffers are
    #     READ-ONLY.
    #   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier; `pk` is
    #     borrowed through a concrete immutable origin, `valid` + the byte
    #     buffers through concrete-origin pointers on the work descriptor, and
    #     the perm/scratch payload is MOVED onto the dispatch State. NO
    #     StringArray/ArcPointer is constructed on a worker.
    #   * No-realloc: perm/scratch are sized to n once; the merge is setitem on
    #     existing slots, never append.
    return pool.run[
        _PairMergeWork[o_off, o_data, origin_of(valid)],
        List[UInt64],
        _PermScratch,
        origin_of(pk),
    ](
        _PairMergeWork[o_off, o_data, origin_of(valid)](
            offsets_ptr,
            data_ptr,
            Pointer(to=valid),
            col_offset,
            has_validity,
            descending,
            src_is_perm,
            pair_lo.copy(),
            pair_mid.copy(),
            pair_hi.copy(),
            item_pair^,
            item_olo^,
            item_ohi^,
        ),
        pk,
        buf^,
        n_items,
    )


def _parallel_pairwise_tree_merge[
    o_off: Origin[mut=False], o_data: Origin[mut=False],
    has_pool: Bool, disp_o: Origin[mut=True],
](
    var buf: _PermScratch, imm pk: List[UInt64],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
    var bounds: List[Int], mw: Int,
    pool: SharedForkJoinHandle[has_pool, disp_o],
) raises -> List[Int]:
    """PARALLEL pairwise-tree co-rank merge of the pre-sorted runs delimited by
    `bounds` (run k == perm[bounds[k]:bounds[k+1]), each already stably sorted in
    the effective order). Merges them with a balanced REDUCTION TREE: each round
    halves the run count by merging adjacent pairs, and EVERY 2-way pair-merge is
    itself cut across the pool by a comparator CO-RANK (merge-path diagonal
    binary search): an O((n/P) log P) span where a heap merge is O(n log P). Stability: the LEFT run always wins ties (lower
    original-index == lower run), byte-identical to the serial stable merge. Each
    round ping-pongs perm<->scratch; the result is left in `perm` (an odd number
    of rounds copies scratch back).

    Shared by `_parallel_string_perm` (slices = the per-worker sort runs) and
    `merge_sorted_partitions_single_key_string_parallel` (runs = the per-worker
    pre-sorted PARTITIONS). `scratch` MUST be pre-sized to the total row count.
    No reference-counted value is touched on a worker.
    """
    var n = len(buf.perm)
    var src_is_perm = True

    while len(bounds) > 2:
        # bounds[k] are the boundaries of the current runs in `src`. Merge
        # adjacent pairs (2k, 2k+1) into `dst`, leaving an odd trailing run
        # copied through. `pair_lo[t]` / `pair_mid[t]` / `pair_hi[t]` describe
        # pair t for the parallel co-rank merge.
        var nb = len(bounds) - 1  # current run count
        var npairs = (nb + 1) // 2
        var pair_lo = List[Int](capacity=npairs)
        var pair_mid = List[Int](capacity=npairs)
        var pair_hi = List[Int](capacity=npairs)
        var new_bounds = List[Int](capacity=npairs + 1)
        new_bounds.append(bounds[0])
        var t = 0
        while t < nb:
            if t + 1 < nb:
                pair_lo.append(bounds[t])
                pair_mid.append(bounds[t + 1])
                pair_hi.append(bounds[t + 2])
                new_bounds.append(bounds[t + 2])
                t += 2
            else:
                # Odd trailing run: no partner this round — record a degenerate
                # pair (mid==hi) so the worker just copies it through.
                pair_lo.append(bounds[t])
                pair_mid.append(bounds[t + 1])
                pair_hi.append(bounds[t + 1])
                new_bounds.append(bounds[t + 1])
                t += 1

        # Merge the round's pairs in PARALLEL. Work is tiled into (pair,
        # output-sub-range) items so even a single big late-round pair is split
        # across all workers via co-rank.
        buf = _parallel_pairwise_round[o_off, o_data, has_pool, disp_o](
            buf^, pk, offsets_ptr, data_ptr, col_offset,
            valid, has_validity, descending,
            pair_lo, pair_mid, pair_hi, src_is_perm, mw, pool,
        )

        bounds = new_bounds^
        src_is_perm = not src_is_perm

    # If the final result is in `scratch`, copy it back into `perm`.
    if not src_is_perm:
        var done = buf.take_scratch()
        for i in range(n):
            buf.perm[i] = done[i]
        _ = done^
    return buf.take_perm()
