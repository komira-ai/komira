# =============================================================================
# STRING / BINARY sort kernel producing permutation indices
# =============================================================================
#
# Sorts an Arrow STRING or BINARY column (Int32 offsets + UInt8 data +
# optional validity; the two layouts are the same, so one kernel serves
# both). Order: byte-wise unsigned lexicographic, and when one string is a
# prefix of the other the shorter sorts first. That is DuckDB's default
# (BINARY) collation for VARCHAR and Arrow C++'s `SortIndices` on UTF-8.
#
# Null placement: `nulls_first` when given, else derived from the direction
# (ASC -> NULLS FIRST, DESC -> NULLS LAST), the engine's derived default.
#
# The kernel reads the `Column` buffers directly, honouring `_offset`, so a
# sliced batch sorts without a contiguous copy.
#
# Two algorithms, the same total order:
#   * the prefix-key path (default): one O(N) pass packs the leading 8 bytes
#     of each string big-endian into a u64, a stable unsigned radix sort
#     orders the rows, and runs of equal prefixes recurse on the next 8
#     bytes or fall to the byte comparator (see `_prefix_key_sort_segment`);
#   * the byte-compare merge sort (`prefix_key=False`), the reference the
#     prefix-key path is tested against.
# Both are stable: equal strings keep their input order.
# =============================================================================

from std.memory import alloc, memcpy

from komira_counters.keyeq_census import keyeq_record, KEYEQ_SORTSTR_RUN_IDENT
from komira_arrow.column import Column
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from .sort import _identity_indices
from .sort_radix import radix_sort_u64_keys


# Threshold for switching from merge sort to insertion sort. Mirrors
# `_INSERTION_SORT_THRESHOLD` in `sort.mojo` so behavior is uniform across
# the kernel family.
comptime _INSERTION_SORT_THRESHOLD: Int = 32


# =============================================================================
# Public entry point: sort_indices_string
# =============================================================================


def sort_indices_string(
    keys: Column[HeapRegion],
    descending: Bool = False,
    nulls_first: Optional[Bool] = None,
    prefix_key: Bool = True,
) raises -> PrimitiveArray[DType.int32]:
    """Sort a STRING or BINARY column and return permutation indices.

    Returns an Int32 array such that `keys[result[i]]` is in sorted order;
    the data is not moved. Order: byte-wise unsigned lexicographic, the
    shorter string first when one is a prefix of the other. Stable.

    Args:
        keys: STRING or BINARY column to sort. Its `_offset` is honoured.
        descending: Sort in descending order. Default ascending.
        nulls_first: Where NULLs go. None derives it from the direction:
            ASC -> NULLS FIRST, DESC -> NULLS LAST.
        prefix_key: Use the prefix-key radix path (default). False runs the
            byte-compare merge sort instead; both give the same permutation.

    Returns:
        A PrimitiveArray[DType.int32] of permutation indices.

    Raises:
        Error if the column type is not STRING or BINARY, or if the
        offsets buffer is missing.
    """
    var nf = nulls_first.value() if nulls_first else (not descending)
    if keys.arrow_type != ArrowType.STRING and keys.arrow_type != ArrowType.BINARY:
        raise Error(
            "sort_indices_string: unsupported arrow_type "
            + String(keys.arrow_type)
            + " (expected STRING or BINARY)"
        )
    if not keys._offsets:
        raise Error("sort_indices_string: column missing offsets buffer")

    var n = keys._length
    if n == 0:
        return PrimitiveArray[DType.int32].allocate(0)

    if prefix_key:
        return _sort_indices_string_prefix_key(keys, descending, nf)

    var indices = _identity_indices(n)
    if n == 1:
        return indices^
    var idx_view = indices.view_mut()
    var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    # SAFETY: `keys` is borrowed for the whole call; the offset and data
    # views below keep its buffers' borrows alive across the merge sort.
    var offs_view = keys._offsets.value().view_ro()
    var offsets_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = keys._data.view_ro()
    var data_ptr = data_view._unsafe_ptr()
    var col_offset = keys._offset

    # SAFETY: `tmp` is owned by this frame and freed before return.
    var tmp = alloc[Scalar[DType.int32]](n)
    if keys._validity:
        ref bm = keys._validity.value()
        _merge_sort_string_validity(
            idx_ptr, tmp, offsets_ptr, data_ptr, col_offset,
            bm, 0, n, descending, nf,
        )
    else:
        _merge_sort_string(
            idx_ptr, tmp, offsets_ptr, data_ptr, col_offset,
            0, n, descending,
        )
    tmp.free()
    return indices^

# =============================================================================
# Internal: Comparator
# =============================================================================
#
# SAFETY: The comparator and its sort callees take origin-polymorphic
# `UnsafePointer`s extracted from `Column._offsets`/`_data`. Each call
# site pins the origin to the borrowed `Column`, so ASAP-destruction
# tracking is preserved; no pointer outlives the call.


@always_inline
def _string_lt[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    a: Int,
    b: Int,
) -> Bool:
    """Return True iff string at logical row `a` < string at logical row `b`.

    Byte-wise lexicographic compare with length tie-break.
    `col_offset` is the parent column's row offset (sliced batches).
    """
    # Read offsets[col_offset + a] / [col_offset + a + 1] for row a.
    var a_off = col_offset + a
    var b_off = col_offset + b
    var a_start = Int((offsets_ptr + a_off)[])
    var a_end = Int((offsets_ptr + a_off + 1)[])
    var b_start = Int((offsets_ptr + b_off)[])
    var b_end = Int((offsets_ptr + b_off + 1)[])
    var a_len = a_end - a_start
    var b_len = b_end - b_start
    var min_len = a_len if a_len < b_len else b_len

    # Byte-wise compare over the common prefix.
    var i = 0
    while i < min_len:
        var ca = (data_ptr + a_start + i)[]
        var cb = (data_ptr + b_start + i)[]
        if ca != cb:
            return ca < cb
        i += 1

    # Common prefix matched -- shorter string is "less than".
    return a_len < b_len


# =============================================================================
# Internal: Stable merge sort (no validity bitmap)
# =============================================================================


def _merge_sort_string[
    o_idx: Origin[mut=True], o_tmp: Origin[mut=True],
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    tmp: UnsafePointer[Scalar[DType.int32], o_tmp],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    lo: Int,
    hi: Int,
    descending: Bool,
):
    """Stable merge sort on the index range [lo, hi) by string keys.

    Mirrors `_merge_sort_int64` in `sort.mojo`. Falls back to insertion
    sort below `_INSERTION_SORT_THRESHOLD`.
    """
    var n = hi - lo
    if n <= 1:
        return
    if n <= _INSERTION_SORT_THRESHOLD:
        _insertion_sort_string(
            idx_ptr, offsets_ptr, data_ptr, col_offset, lo, hi, descending,
        )
        return
    var mid = lo + n // 2
    _merge_sort_string(
        idx_ptr, tmp, offsets_ptr, data_ptr, col_offset, lo, mid, descending,
    )
    _merge_sort_string(
        idx_ptr, tmp, offsets_ptr, data_ptr, col_offset, mid, hi, descending,
    )
    _merge_string(
        idx_ptr, tmp, offsets_ptr, data_ptr, col_offset, lo, mid, hi, descending,
    )


def _insertion_sort_string[
    o_idx: Origin[mut=True],
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    lo: Int,
    hi: Int,
    descending: Bool,
):
    """Stable insertion sort over [lo, hi) by string keys."""
    for i in range(lo + 1, hi):
        var key_idx = (idx_ptr + i)[]
        var j = i
        while j > lo:
            var prev_idx = (idx_ptr + j - 1)[]
            # For stability: only move on STRICT inequality. Equal keys
            # preserve original (idx_ptr) order.
            var should_move: Bool
            if descending:
                should_move = _string_lt(
                    offsets_ptr, data_ptr, col_offset,
                    Int(prev_idx), Int(key_idx),
                )
            else:
                should_move = _string_lt(
                    offsets_ptr, data_ptr, col_offset,
                    Int(key_idx), Int(prev_idx),
                )
            if not should_move:
                break
            (idx_ptr + j)[] = prev_idx
            j -= 1
        (idx_ptr + j)[] = key_idx


def _merge_string[
    o_idx: Origin[mut=True], o_tmp: Origin[mut=True],
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    tmp: UnsafePointer[Scalar[DType.int32], o_tmp],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    lo: Int,
    mid: Int,
    hi: Int,
    descending: Bool,
):
    """Merge two sorted halves [lo, mid) and [mid, hi) by string keys."""
    # Copy [lo, hi) of indices to tmp via memcpy (mirrors int64 merge).
    var range_len = hi - lo
    memcpy(dest=tmp + lo, src=idx_ptr + lo, count=range_len)

    var left = lo
    var right = mid
    var dest = lo

    while left < mid and right < hi:
        var li = Int((tmp + left)[])
        var ri = Int((tmp + right)[])
        # Stable merge: take from left when keys are equal (left <= right
        # for ascending). For descending, take left when left >= right;
        # equality still falls to the left (preserves original order).
        var take_left: Bool
        if descending:
            # left wins if NOT strictly less than right (i.e. left >= right).
            take_left = not _string_lt(
                offsets_ptr, data_ptr, col_offset, li, ri,
            )
        else:
            # left wins if NOT strictly greater than right (i.e. left <= right).
            take_left = not _string_lt(
                offsets_ptr, data_ptr, col_offset, ri, li,
            )

        if take_left:
            (idx_ptr + dest)[] = (tmp + left)[]
            left += 1
        else:
            (idx_ptr + dest)[] = (tmp + right)[]
            right += 1
        dest += 1

    var left_remaining = mid - left
    if left_remaining > 0:
        memcpy(dest=idx_ptr + dest, src=tmp + left, count=left_remaining)
    var right_remaining = hi - right
    if right_remaining > 0:
        memcpy(
            dest=idx_ptr + dest + left_remaining,
            src=tmp + right,
            count=right_remaining,
        )


# =============================================================================
# Internal: Stable merge sort with validity bitmap (null-aware path)
# =============================================================================
#
# Null collation matches Arrow / DuckDB:
#   ASC  -> NULLS FIRST  (null < any value)
#   DESC -> NULLS LAST   (null sorts after any value)
#
# The compare returns True iff `a` should sort BEFORE `b` for the given
# direction (so it absorbs the descending flag rather than the merge
# step inverting it). Equality => return False to keep the sort stable.


@always_inline
def _string_compare_null_aware[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    bm: Bitmap[HeapRegion],
    a: Int,
    b: Int,
    descending: Bool,
    nulls_first: Bool,
) -> Bool:
    """Return True iff row `a` should sort BEFORE row `b`.

    Bitmap convention: bit=1 means valid, bit=0 means null.

    NULL placement is `nulls_first`, not derived from `descending`; the
    caller passes the resolved value.
    """
    var a_valid = bm.test(col_offset + a)
    var b_valid = bm.test(col_offset + b)
    if not a_valid and not b_valid:
        return False  # equal nulls => stable, keep original order
    if not a_valid:
        # `a` is null: NULLS FIRST => a sorts before b; NULLS LAST => a after b.
        return nulls_first
    if not b_valid:
        # `b` is null: NULLS FIRST => b before a => a NOT before b; else a before b.
        return not nulls_first
    # Both valid -- byte compare.
    if descending:
        return _string_lt(offsets_ptr, data_ptr, col_offset, b, a)
    return _string_lt(offsets_ptr, data_ptr, col_offset, a, b)


def _merge_sort_string_validity[
    o_idx: Origin[mut=True], o_tmp: Origin[mut=True],
    o_off: Origin[mut=False], o_data: Origin[mut=False],
    o_bm: Origin[mut=False],
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    tmp: UnsafePointer[Scalar[DType.int32], o_tmp],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    ref [o_bm] bm: Bitmap[HeapRegion],
    lo: Int,
    hi: Int,
    descending: Bool,
    nulls_first: Bool,
):
    """Stable merge sort on [lo, hi), null-aware (Arrow null collation)."""
    var n = hi - lo
    if n <= 1:
        return
    if n <= _INSERTION_SORT_THRESHOLD:
        _insertion_sort_string_validity(
            idx_ptr, offsets_ptr, data_ptr, col_offset, bm, lo, hi, descending, nulls_first,
        )
        return
    var mid = lo + n // 2
    _merge_sort_string_validity(
        idx_ptr, tmp, offsets_ptr, data_ptr, col_offset, bm, lo, mid, descending, nulls_first,
    )
    _merge_sort_string_validity(
        idx_ptr, tmp, offsets_ptr, data_ptr, col_offset, bm, mid, hi, descending, nulls_first,
    )
    _merge_string_validity(
        idx_ptr, tmp, offsets_ptr, data_ptr, col_offset, bm, lo, mid, hi, descending, nulls_first,
    )


def _insertion_sort_string_validity[
    o_idx: Origin[mut=True],
    o_off: Origin[mut=False], o_data: Origin[mut=False],
    o_bm: Origin[mut=False],
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    ref [o_bm] bm: Bitmap[HeapRegion],
    lo: Int,
    hi: Int,
    descending: Bool,
    nulls_first: Bool,
):
    """Stable insertion sort over [lo, hi), null-aware."""
    for i in range(lo + 1, hi):
        var key_idx = (idx_ptr + i)[]
        var j = i
        while j > lo:
            var prev_idx = (idx_ptr + j - 1)[]
            # Move only if strict order: key_idx < prev_idx.
            var should_move = _string_compare_null_aware(
                offsets_ptr, data_ptr, col_offset, bm,
                Int(key_idx), Int(prev_idx), descending, nulls_first,
            )
            if not should_move:
                break
            (idx_ptr + j)[] = prev_idx
            j -= 1
        (idx_ptr + j)[] = key_idx


def _merge_string_validity[
    o_idx: Origin[mut=True], o_tmp: Origin[mut=True],
    o_off: Origin[mut=False], o_data: Origin[mut=False],
    o_bm: Origin[mut=False],
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    tmp: UnsafePointer[Scalar[DType.int32], o_tmp],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    ref [o_bm] bm: Bitmap[HeapRegion],
    lo: Int,
    mid: Int,
    hi: Int,
    descending: Bool,
    nulls_first: Bool,
):
    """Merge two sorted halves, null-aware."""
    var range_len = hi - lo
    memcpy(dest=tmp + lo, src=idx_ptr + lo, count=range_len)

    var left = lo
    var right = mid
    var dest = lo

    while left < mid and right < hi:
        var li = Int((tmp + left)[])
        var ri = Int((tmp + right)[])
        # Stable: take left when left <= right. We test `right < left`;
        # if false, take left (which covers left <= right and equal).
        var right_lt_left = _string_compare_null_aware(
            offsets_ptr, data_ptr, col_offset, bm, ri, li, descending, nulls_first,
        )
        if not right_lt_left:
            (idx_ptr + dest)[] = (tmp + left)[]
            left += 1
        else:
            (idx_ptr + dest)[] = (tmp + right)[]
            right += 1
        dest += 1

    var left_remaining = mid - left
    if left_remaining > 0:
        memcpy(dest=idx_ptr + dest, src=tmp + left, count=left_remaining)
    var right_remaining = hi - right
    if right_remaining > 0:
        memcpy(
            dest=idx_ptr + dest + left_remaining,
            src=tmp + right,
            count=right_remaining,
        )


# =============================================================================
# The prefix-key path: normalized fixed-width keys, DuckDB-style
# =============================================================================
#
# One O(N) pass packs the leading bytes of each string big-endian into a `u64`
# key (the exact memcmp byte order), then the stable unsigned radix orders all
# rows without touching a string. Runs of equal keys are resolved by the next
# 8 bytes, or by the `_string_lt` merge sort when the key cannot prove their
# order, so the permutation is the one the byte-compare merge sort produces.
#
# SAFETY: like the comparator above, every helper takes origin-polymorphic
# `UnsafePointer`s extracted from `Column._offsets`/`_data`; each call site
# pins the origin to the borrowed `keys`. No pointer outlives a call and none
# crosses the module boundary: the helpers are private, and the public entry
# returns a `PrimitiveArray`.


@always_inline
def _pack_string_prefix_chunk[
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    row: Int,
    chunk_no: Int,
) -> UInt64:
    """Pack bytes `[chunk_no*8, chunk_no*8+8)` of the string at logical `row`
    into a big-endian `u64`, NUL-right-padded.

    Byte `chunk_no*8` lands in the MOST-significant position so that an UNSIGNED
    `u64` comparison of two keys reproduces the byte-wise memcmp order of that
    8-byte window. Bytes beyond the string length are left zero (NUL pad).

    The only state is the borrowed column buffers and the row/chunk
    indices. Bytes at or past the string's end are zero, so a string
    containing a 0x00 byte can tie with a shorter one; the caller detects
    that and falls back to the byte comparator.
    """
    var off = col_offset + row
    var start = Int((offsets_ptr + off)[])
    var end = Int((offsets_ptr + off + 1)[])
    var s_len = end - start
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


def _prefix_key_sort_segment[
    o_idx: Origin[mut=True], o_tmp: Origin[mut=True],
    o_off: Origin[mut=False], o_data: Origin[mut=False]
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    tmp: UnsafePointer[Scalar[DType.int32], o_tmp],
    offsets_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    data_ptr: UnsafePointer[Scalar[DType.uint8], o_data],
    col_offset: Int,
    lo: Int,
    hi: Int,
    chunk_no: Int,
    descending: Bool,
):
    """Order the index sub-range `idx[lo:hi)` by the string keys, using the
    prefix-key radix at `chunk_no` and recursing into equal-key sub-runs.

    Precondition: `idx[lo:hi)` is in stable input order relative to the original
    row order (the radix is stable, so within-group order is preserved across
    recursion). Postcondition: `idx[lo:hi)` is in the exact total order
    `_string_lt`/`_string_compare_null_aware` would produce for these rows.
    """
    var seg_n = hi - lo
    if seg_n <= 1:
        return

    # Small segments: skip the radix machinery and go straight to the stable
    # `_string_lt` merge sort. This is byte-identical to the radix+tiebreak
    # result and avoids the per-segment u64 alloc churn on the colliding tail.
    if seg_n <= _INSERTION_SORT_THRESHOLD:
        _merge_sort_string(
            idx_ptr, tmp, offsets_ptr, data_ptr, col_offset, lo, hi, descending,
        )
        return

    # Materialize the chunk-`chunk_no` key for every row in idx[lo:hi), in
    # current (stable) order. For descending we complement the key so the
    # ascending radix yields descending string order on this chunk while
    # KEEPING stability (equal strings retain input order — a plain array
    # reverse would break that).
    var seg_keys = PrimitiveArray[DType.uint64].allocate(seg_n)
    var seg_keys_view = seg_keys.view_mut()
    var seg_keys_ptr = seg_keys_view._unsafe_ptr().bitcast[Scalar[DType.uint64]]()
    for i in range(seg_n):
        var row = Int((idx_ptr + lo + i)[])
        var k = _pack_string_prefix_chunk(
            offsets_ptr, data_ptr, col_offset, row, chunk_no,
        )
        if descending:
            k = ~k
        (seg_keys_ptr + i)[] = k

    # Stable unsigned radix → a LOCAL permutation of [0, seg_n).
    var local_perm = radix_sort_u64_keys(seg_keys)

    # Apply the local permutation to idx[lo:hi) via the scratch buffer.
    var lp_view = local_perm.view_ro()
    var lp_ptr = lp_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    for i in range(seg_n):
        (tmp + lo + i)[] = (idx_ptr + lo + Int((lp_ptr + i)[]))[]
    memcpy(dest=idx_ptr + lo, src=tmp + lo, count=seg_n)

    # Walk the now-chunk-sorted segment and recurse into maximal equal-chunk-key
    # sub-runs. Re-derive each row's chunk key (cheap; the segment is small
    # relative to N once the radix has bucketed it).
    var run_lo = lo
    while run_lo < hi:
        var first_row = Int((idx_ptr + run_lo)[])
        var run_key = _pack_string_prefix_chunk(
            offsets_ptr, data_ptr, col_offset, first_row, chunk_no,
        )
        var run_hi = run_lo + 1
        while run_hi < hi:
            var r = Int((idx_ptr + run_hi)[])
            var rk = _pack_string_prefix_chunk(
                offsets_ptr, data_ptr, col_offset, r, chunk_no,
            )
            if rk != run_key:
                break
            run_hi += 1

        var run_len = run_hi - run_lo
        if run_len > 1:
            # The run members are equal on chunks 0..chunk_no. Decide how to
            # resolve their relative order, preserving byte-identity with the
            # `_string_lt` total order:
            #
            #   covered = (chunk_no + 1) * 8   bytes proven equal so far
            #
            #   (1) NUL in the covered prefix of ANY member -> the chunk-key
            #       comparison may have aliased an embedded `0x00` (NUL-pad
            #       inverts the length tiebreak). Fall to the exact `_string_lt`
            #       stable merge sort (the byte-identity oracle). Rare; BINARY
            #       only (well-formed UTF-8 is NUL-free except U+0000).
            #
            #   (2) Else if the longest member exceeds `covered` -> distinguishing
            #       bytes exist past the current window. Escalate to the next
            #       8-byte chunk. No fixed cap: the window grows until it covers
            #       `run_max_len`, which is bounded by the key length, so the
            #       recursion terminates. A long shared prefix is thus resolved
            #       by deeper chunks instead of a `_string_lt` merge sort over
            #       the whole run.
            #
            #   (3) Else (NUL-free, run_max_len <= covered, equal on every
            #       covered chunk) -> the run members are BYTE-IDENTICAL strings.
            #       The radix kept them in stable input order, which IS their
            #       final order. Skip.
            var covered = (chunk_no + 1) * 8
            var run_has_nul = False
            var run_max_len = 0
            # Reference (run head) string extent — used by the all-identical
            # fast check below.
            var head_row = Int((idx_ptr + run_lo)[])
            var head_off = col_offset + head_row
            var head_start = Int((offsets_ptr + head_off)[])
            var head_len = Int((offsets_ptr + head_off + 1)[]) - head_start
            var all_identical = True
            for i in range(run_lo, run_hi):
                var r = Int((idx_ptr + i)[])
                var off = col_offset + r
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
                # All-identical check: same length AND same bytes BEYOND the
                # covered window (the covered region is already proven equal by
                # the radix; we only need to compare the uncovered tail). This
                # catches a run of byte-identical wide values, which would
                # otherwise escalate through every 8-byte chunk.
                if all_identical and i > run_lo:
                    if s_len != head_len:
                        all_identical = False
                    else:
                        var _b0 = covered if covered < s_len else s_len
                        var b2 = _b0
                        while b2 < s_len:
                            if (data_ptr + start + b2)[] != (
                                data_ptr + head_start + b2
                            )[]:
                                all_identical = False
                                break
                            b2 += 1
                        # WIDTH is the UNCOVERED tail only -- the radix already
                        # proved the first `covered` bytes equal, so a memcmp
                        # here would be handed `s_len - _b0`, not `s_len`.
                        keyeq_record(
                            KEYEQ_SORTSTR_RUN_IDENT,
                            s_len - _b0,
                            b2 - _b0,
                            all_identical,
                        )

            if all_identical and not run_has_nul:
                # The run is byte-identical strings (and NUL-free). The radix
                # kept them in stable input order — that IS their final order.
                pass
            elif run_has_nul:
                # An embedded NUL may have aliased the chunk-key comparison
                # (NUL-pad inverts the length tiebreak). Resolve via the exact
                # `_string_lt` stable merge sort — the byte-identity oracle.
                _merge_sort_string(
                    idx_ptr, tmp, offsets_ptr, data_ptr, col_offset,
                    run_lo, run_hi, descending,
                )
            elif run_max_len > covered:
                # Distinguishing bytes exist past the current window. Escalate
                # to the next 8-byte chunk. The window grows until it covers
                # `run_max_len`, so the recursion terminates.
                _prefix_key_sort_segment(
                    idx_ptr, tmp, offsets_ptr, data_ptr, col_offset,
                    run_lo, run_hi, chunk_no + 1, descending,
                )
            # else: NUL-free, run_max_len <= covered, equal on every covered
            # chunk -> byte-identical, already stable. Skip.

        run_lo = run_hi


def _sort_indices_string_prefix_key(
    keys: Column[HeapRegion],
    descending: Bool,
    nulls_first: Bool,
) -> PrimitiveArray[DType.int32]:
    """Prefix-key entry: null pre-partition + prefix-key radix over
    the valid rows + `_string_lt` tiebreak. Produces a permutation that induces
    the EXACT same total order as the byte-compare merge sort.

    `nulls_first` decides placement (the caller resolves it). Nulls are
    partitioned out first (stably), so the valid-row path never reads the
    validity bitmap.
    """
    var n = keys._length

    var indices = PrimitiveArray[DType.int32].allocate(n)
    var idx_view = indices.view_mut()
    var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    var offs_view = keys._offsets.value().view_ro()
    var offsets_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = keys._data.view_ro()
    var data_ptr = data_view._unsafe_ptr()
    var col_offset = keys._offset

    var tmp = alloc[Scalar[DType.int32]](n)

    var has_validity = keys._validity.__bool__()

    # ---- Null pre-partition (stable): [valids ...][nulls ...] in idx, with a
    # record of where the valid block ends. Both blocks keep input order.
    var n_valid = n
    if has_validity:
        ref bm = keys._validity.value()
        var w_valid = 0
        # First pass: valid rows in input order.
        for r in range(n):
            if bm.test(col_offset + r):
                (idx_ptr + w_valid)[] = Scalar[DType.int32](r)
                w_valid += 1
        n_valid = w_valid
        # Second pass: null rows in input order, appended after the valids.
        var w_null = w_valid
        for r in range(n):
            if not bm.test(col_offset + r):
                (idx_ptr + w_null)[] = Scalar[DType.int32](r)
                w_null += 1
    else:
        # No validity → iota over all rows.
        for r in range(n):
            (idx_ptr + r)[] = Scalar[DType.int32](r)

    # ---- Sort the valid block [0, n_valid) via the prefix-key path.
    if n_valid > 1:
        _prefix_key_sort_segment(
            idx_ptr, tmp, offsets_ptr, data_ptr, col_offset,
            0, n_valid, 0, descending,
        )

    # ---- Null placement: NULLS FIRST rotates the null block to
    # the front; NULLS LAST leaves it at the back (already there from the
    # pre-partition). The null block is in stable input order.
    if has_validity and nulls_first and n_valid < n:
        # Rotate so the null block [n_valid, n) precedes the sorted valids.
        # Copy [valids][nulls] → tmp as [nulls][valids].
        var n_null = n - n_valid
        memcpy(dest=tmp, src=idx_ptr + n_valid, count=n_null)
        memcpy(dest=tmp + n_null, src=idx_ptr, count=n_valid)
        memcpy(dest=idx_ptr, src=tmp, count=n)

    tmp.free()
    return indices^
