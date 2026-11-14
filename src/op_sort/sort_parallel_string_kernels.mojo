# =============================================================================
# sort_parallel_string_kernels -- the per-slice string sort of the parallel
# single-key STRING sort, and its comparators
# =============================================================================
#
# The numeric co-rank merge of `sort_parallel` bisects an Int64 value range to
# place its split points; a variable-length string has no such range. So the
# STRING sort keeps the per-slice parallel sort (the O(n log n) part) and
# merges the sorted runs with comparator merges (`sort_parallel_string_merge`).
# The comparator is the order of the serial `sort_indices_string`: byte-wise,
# the shorter string first on a shared prefix, NULLS FIRST ascending and
# NULLS LAST descending, and on a tie the lower run (the lower input row)
# first.
#
# Same order as the serial sort: slices are contiguous in input order, each is
# sorted stably, and every merge breaks a tie by the lower run, so the
# permutation is a single stable `sort_indices_string`'s.
#
# Cross-thread safety. A worker reads the column's offsets and data buffers
# through pointers whose origins are the borrowed column's, and validity from a
# `List[Bool]` resolved on the calling thread before the dispatch. No
# `StringArray`, `Bitmap` or other reference-counted value is built, copied or
# dropped on a worker, so no reference count changes off the calling thread.
# The output column is built once, by the gather after the barrier.

from std.memory import UnsafePointer


@always_inline
def _str_lt_idx[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    a: Int,
    b: Int,
) -> Bool:
    """True iff string at logical row `a` < string at row `b`. Byte-wise
    lexicographic with a length tiebreak (shorter prefix sorts first) —
    the order of the serial `sort_string._string_lt`."""
    var a_off = col_offset + a
    var b_off = col_offset + b
    var a_start = Int((offsets_ptr + a_off)[])
    var a_end = Int((offsets_ptr + a_off + 1)[])
    var b_start = Int((offsets_ptr + b_off)[])
    var b_end = Int((offsets_ptr + b_off + 1)[])
    var a_len = a_end - a_start
    var b_len = b_end - b_start
    var min_len = a_len if a_len < b_len else b_len
    var i = 0
    while i < min_len:
        var ca = (data_ptr + a_start + i)[]
        var cb = (data_ptr + b_start + i)[]
        if ca != cb:
            return ca < cb
        i += 1
    return a_len < b_len


@always_inline
def _str_before_flatvalid[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    imm valid: List[Bool],
    has_validity: Bool,
    a: Int,
    b: Int,
    descending: Bool,
) -> Bool:
    """True iff row `a` should sort STRICTLY BEFORE row `b` for the given
    direction. Byte-for-byte the serial `_string_compare_null_aware` order, but
    reads validity from a flat pre-extracted `List[Bool]` (resolved on the main
    thread) instead of the ArcPointer-backed Bitmap — so it is cross-thread safe
    to call from a fork-join worker. Equality => False (stable; keep original
    order)."""
    if has_validity:
        var a_valid = valid[a]
        var b_valid = valid[b]
        if not a_valid and not b_valid:
            return False
        if not a_valid:
            # `a` null: NULLS FIRST (ASC) => a before b; NULLS LAST (DESC) => not.
            return not descending
        if not b_valid:
            return descending
    # Both valid (or no validity) — byte compare.
    if descending:
        return _str_lt_idx(offsets_ptr, data_ptr, col_offset, b, a)
    return _str_lt_idx(offsets_ptr, data_ptr, col_offset, a, b)


comptime _PREFIX_RADIX_MIN: Int = 64


@always_inline
def _pack_prefix8[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    row: Int,
    chunk_no: Int,
) -> UInt64:
    """Pack bytes [chunk_no*8, +8) of the string at logical `row` big-endian into
    a u64, NUL-right-padded. Byte chunk_no*8 lands MOST-significant so an UNSIGNED
    u64 compare reproduces the byte-wise memcmp order of that 8-byte window
    (as `sort_string._pack_string_prefix_chunk`; kept local so the parallel
    module has no cross-module pointer-signature seam)."""
    var off = col_offset + row
    var start = Int((offsets_ptr + off)[])
    var s_len = Int((offsets_ptr + off + 1)[]) - start
    var base = chunk_no * 8
    var key: UInt64 = 0
    var i = 0
    while i < 8:
        var pos = base + i
        if pos < s_len:
            var byte = UInt64(Int((data_ptr + start + pos)[]))
            key |= byte << UInt64(8 * (7 - i))
        i += 1
    return key


def _prefix_radix_sort_slice[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    imm valid: List[Bool],
    has_validity: Bool,
    mut perm: List[Int],
    lo: Int,
    hi: Int,
    mut scratch: List[Int],
    chunk_no: Int,
    descending: Bool,
):
    """Fast per-slice string sort over the VALID sub-range `perm[lo:hi)`: a
    STABLE 8-pass LSB-byte radix on the chunk-`chunk_no` big-endian prefix key
    (ZERO string touches per pass), then recurse into equal-prefix runs and fall
    to the comparator merge sort for the colliding tail. Byte-identical to the
    serial prefix-key path (`sort_string._prefix_key_sort_segment`): the prefix
    radix + `_str_before_flatvalid` tiebreak induce the same total order.

    Cross-thread safe: touches ONLY `List[Int]` perm / `List[UInt64]` keys /
    `List[Int]` count buckets + the borrowed raw byte buffers — NO ArcPointer /
    Column / RecordBatch / StringArray is constructed on the worker. PRECONDITION:
    `perm[lo:hi)` are all VALID rows (nulls pre-partitioned out by the caller)."""
    var seg_n = hi - lo
    if seg_n < 2:
        return
    if seg_n <= _PREFIX_RADIX_MIN:
        # Small segment: the comparator merge sort is byte-identical and avoids
        # the per-segment key/bucket alloc churn.
        _stable_msort_slice_string(
            offsets_ptr, data_ptr, col_offset, valid, has_validity,
            perm, lo, hi, scratch, descending,
        )
        return

    # Materialize the chunk key for every row in perm[lo:hi). For descending we
    # COMPLEMENT the key so the ascending radix yields descending string order on
    # this chunk while KEEPING stability (equal strings retain input order).
    var keys = List[UInt64](capacity=seg_n)
    for i in range(seg_n):
        var row = perm[lo + i]
        var k = _pack_prefix8(offsets_ptr, data_ptr, col_offset, row, chunk_no)
        if descending:
            k = ~k
        keys.append(k)

    # STABLE 8-pass LSB-byte radix of the seg index space [0, seg_n) by `keys`.
    # `order`/`order_next` hold a LOCAL permutation of [0, seg_n); `perm[lo:hi)`
    # is reordered by it at the end.
    var order = List[Int](capacity=seg_n)
    for i in range(seg_n):
        order.append(i)
    var order_next = List[Int](capacity=seg_n)
    for _ in range(seg_n):
        order_next.append(0)
    var count = List[Int](capacity=256)
    for _ in range(256):
        count.append(0)
    var pass_no = 0
    while pass_no < 8:
        for c in range(256):
            count[c] = 0
        var shift = UInt64(8 * pass_no)
        for i in range(seg_n):
            var b = Int((keys[order[i]] >> shift) & UInt64(255))
            count[b] += 1
        var acc = 0
        for c in range(256):
            var cc = count[c]
            count[c] = acc
            acc += cc
        for i in range(seg_n):
            var b = Int((keys[order[i]] >> shift) & UInt64(255))
            order_next[count[b]] = order[i]
            count[b] += 1
        for i in range(seg_n):
            order[i] = order_next[i]
        pass_no += 1

    # Apply the local order to perm[lo:hi) via scratch.
    for i in range(seg_n):
        scratch[lo + i] = perm[lo + order[i]]
    for i in range(seg_n):
        perm[lo + i] = scratch[lo + i]

    # Walk the now-chunk-sorted segment; recurse into maximal equal-chunk-key
    # sub-runs whose longest member has distinguishing bytes past this window,
    # else resolve byte-identically with the comparator merge sort (covers
    # length-tiebreak + embedded-NUL aliasing).
    var run_lo = lo
    while run_lo < hi:
        var run_key = _pack_prefix8(
            offsets_ptr, data_ptr, col_offset, perm[run_lo], chunk_no
        )
        var run_hi = run_lo + 1
        while run_hi < hi:
            var rk = _pack_prefix8(
                offsets_ptr, data_ptr, col_offset, perm[run_hi], chunk_no
            )
            if rk != run_key:
                break
            run_hi += 1
        var run_len = run_hi - run_lo
        if run_len > 1:
            var covered = (chunk_no + 1) * 8
            var run_max_len = 0
            var run_has_nul = False
            for i in range(run_lo, run_hi):
                var row = perm[i]
                var off = col_offset + row
                var start = Int((offsets_ptr + off)[])
                var s_len = Int((offsets_ptr + off + 1)[]) - start
                if s_len > run_max_len:
                    run_max_len = s_len
                if not run_has_nul:
                    var lim = s_len if s_len < covered else covered
                    var b = 0
                    while b < lim:
                        if (data_ptr + start + b)[] == UInt8(0):
                            run_has_nul = True
                            break
                        b += 1
            if run_has_nul or run_max_len <= covered:
                # Embedded NUL may alias the chunk key (NUL-pad inverts length
                # tiebreak), OR all members fit the covered window (length
                # tiebreak / byte-identical). Resolve exactly via the comparator
                # merge sort, which is exact.
                _stable_msort_slice_string(
                    offsets_ptr, data_ptr, col_offset, valid, has_validity,
                    perm, run_lo, run_hi, scratch, descending,
                )
            else:
                # Distinguishing bytes exist past the window — escalate to the
                # next 8-byte chunk. Terminates (window grows to run_max_len).
                _prefix_radix_sort_slice(
                    offsets_ptr, data_ptr, col_offset, valid, has_validity,
                    perm, run_lo, run_hi, scratch, chunk_no + 1, descending,
                )
        run_lo = run_hi


def _sort_slice_string_full[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    imm valid: List[Bool],
    has_validity: Bool,
    mut perm: List[Int],
    lo: Int,
    hi: Int,
    mut scratch: List[Int],
    descending: Bool,
):
    """Fully sort ONE slice `perm[lo:hi)` into TOTAL ORDER (the worker primitive).

    Handles nulls so each slice run is in the SAME total order the merge
    comparator implements (the merge compares run HEADS, so a run must be globally
    ordered):
      ASC  -> NULLS FIRST: stable-partition nulls to the slice front, then prefix-
              radix the trailing valid sub-range.  run == [nulls, sorted_valids].
      DESC -> NULLS LAST:  stable-partition valids to the slice front, prefix-radix
              them, nulls trail.  run == [sorted_valids, nulls].
    Nulls keep input order within the slice (stable). All-valid slices skip the
    partition and prefix-radix the whole slice. Cross-thread safe (no ArcPointer
    touched)."""
    var seg_n = hi - lo
    if seg_n < 2:
        return
    if not has_validity:
        _prefix_radix_sort_slice(
            offsets_ptr, data_ptr, col_offset, valid, has_validity,
            perm, lo, hi, scratch, 0, descending,
        )
        return

    # Stable null partition within [lo, hi) using scratch as staging.
    var w = lo
    if not descending:
        # ASC: nulls first (stable), then valids (stable).
        for t in range(lo, hi):
            if not valid[perm[t]]:
                scratch[w] = perm[t]
                w += 1
        var valid_lo = w
        for t in range(lo, hi):
            if valid[perm[t]]:
                scratch[w] = perm[t]
                w += 1
        for t in range(lo, hi):
            perm[t] = scratch[t]
        if hi - valid_lo > 1:
            _prefix_radix_sort_slice(
                offsets_ptr, data_ptr, col_offset, valid, has_validity,
                perm, valid_lo, hi, scratch, 0, descending,
            )
    else:
        # DESC: valids first (stable), then nulls (stable).
        for t in range(lo, hi):
            if valid[perm[t]]:
                scratch[w] = perm[t]
                w += 1
        var valid_hi = w
        for t in range(lo, hi):
            if not valid[perm[t]]:
                scratch[w] = perm[t]
                w += 1
        for t in range(lo, hi):
            perm[t] = scratch[t]
        if valid_hi - lo > 1:
            _prefix_radix_sort_slice(
                offsets_ptr, data_ptr, col_offset, valid, has_validity,
                perm, lo, valid_hi, scratch, 0, descending,
            )


def _stable_msort_slice_string[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    imm valid: List[Bool],
    has_validity: Bool,
    mut perm: List[Int],
    lo: Int,
    hi: Int,
    mut scratch: List[Int],
    descending: Bool,
):
    """Stable bottom-up merge sort of `perm[lo:hi)` (indices into the column) by
    the string comparator. `scratch` (>= hi capacity in [lo,hi)) is the merge
    buffer. STABLE: the merge takes the LEFT run unless the RIGHT is strictly
    `_str_before_flatvalid` — equal keys keep `perm` order, identical to the
    serial string merge sort's stable merge."""
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
                # STABLE: take LEFT unless RIGHT is strictly before LEFT.
                if _str_before_flatvalid(
                    offsets_ptr, data_ptr, col_offset, valid, has_validity,
                    perm[j], perm[i], descending,
                ):
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


@always_inline
def _str_run_head_before[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    run_a: Int, run_b: Int, imm cur: List[Int], imm runs: List[List[Int]],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
) -> Bool:
    """True iff run_a's current slice head sorts STRICTLY BEFORE run_b's, with a
    RUN-INDEX tiebreak (lower run id wins on a tie -> emitted first -> stable)."""
    var ra = runs[run_a][cur[run_a]]
    var rb = runs[run_b][cur[run_b]]
    if _str_before_flatvalid(
        offsets_ptr, data_ptr, col_offset, valid, has_validity, ra, rb, descending
    ):
        return True
    if _str_before_flatvalid(
        offsets_ptr, data_ptr, col_offset, valid, has_validity, rb, ra, descending
    ):
        return False
    # Equal keys -> lower run id wins (stable).
    return run_a < run_b


@always_inline
def _str_sift[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    mut heap: List[Int], root: Int, hn: Int, imm cur: List[Int],
    imm runs: List[List[Int]],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
):
    """Min-heap sift-down over run ids, ordered by (current-head key, run id)."""
    var i = root
    while True:
        var l = 2 * i + 1
        var r = 2 * i + 2
        var smallest = i
        if l < hn and _str_run_head_before(
            heap[l], heap[smallest], cur, runs, offsets_ptr, data_ptr,
            col_offset, valid, has_validity, descending,
        ):
            smallest = l
        if r < hn and _str_run_head_before(
            heap[r], heap[smallest], cur, runs, offsets_ptr, data_ptr,
            col_offset, valid, has_validity, descending,
        ):
            smallest = r
        if smallest == i:
            return
        var tmp = heap[i]
        heap[i] = heap[smallest]
        heap[smallest] = tmp
        i = smallest


@always_inline
def _pk_head_before[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    run_a: Int, run_b: Int, imm cur: List[Int], imm runs: List[List[Int]],
    imm pk: List[UInt64],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
) -> Bool:
    """PREFIX-KEY-ACCELERATED head comparator: compare the precomputed
    DIRECTION-ENCODED u64 prefix key first (a single integer compare — the common
    case), falling to the authoritative `_str_before_flatvalid` ONLY when the
    prefix keys are EQUAL (or a null is involved). Byte-identical to
    `_str_run_head_before` (the prefix key encodes the same order on distinct
    prefixes; equal prefixes defer to the full comparator)."""
    var ra = runs[run_a][cur[run_a]]
    var rb = runs[run_b][cur[run_b]]
    # Null involved -> defer to the authoritative comparator (the prefix key is a
    # placeholder for null rows).
    if has_validity:
        if not valid[ra] or not valid[rb]:
            if _str_before_flatvalid(
                offsets_ptr, data_ptr, col_offset, valid, has_validity,
                ra, rb, descending,
            ):
                return True
            if _str_before_flatvalid(
                offsets_ptr, data_ptr, col_offset, valid, has_validity,
                rb, ra, descending,
            ):
                return False
            return run_a < run_b
    var ka = pk[ra]
    var kb = pk[rb]
    if ka != kb:
        # pk is direction-encoded: a plain unsigned `<` is the effective order.
        return ka < kb
    # Equal 8-byte prefix -> authoritative full-string tiebreak.
    if _str_before_flatvalid(
        offsets_ptr, data_ptr, col_offset, valid, has_validity, ra, rb, descending
    ):
        return True
    if _str_before_flatvalid(
        offsets_ptr, data_ptr, col_offset, valid, has_validity, rb, ra, descending
    ):
        return False
    return run_a < run_b


@always_inline
def _pk_sift[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    mut heap: List[Int], root: Int, hn: Int, imm cur: List[Int],
    imm runs: List[List[Int]], imm pk: List[UInt64],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int, imm valid: List[Bool], has_validity: Bool, descending: Bool,
):
    """Min-heap sift-down using the prefix-key-accelerated head comparator."""
    var i = root
    while True:
        var l = 2 * i + 1
        var r = 2 * i + 2
        var smallest = i
        if l < hn and _pk_head_before(
            heap[l], heap[smallest], cur, runs, pk, offsets_ptr, data_ptr,
            col_offset, valid, has_validity, descending,
        ):
            smallest = l
        if r < hn and _pk_head_before(
            heap[r], heap[smallest], cur, runs, pk, offsets_ptr, data_ptr,
            col_offset, valid, has_validity, descending,
        ):
            smallest = r
        if smallest == i:
            return
        var tmp = heap[i]
        heap[i] = heap[smallest]
        heap[smallest] = tmp
        i = smallest


