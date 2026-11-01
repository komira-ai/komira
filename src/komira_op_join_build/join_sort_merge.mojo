# =============================================================================
# join_sort_merge -- the merge phase of a sort-merge INNER join over two
# pre-sorted INT64 key columns, and the CROSS join's index pairs
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.primitive_array import PrimitiveArray


# =============================================================================
# Sort-Merge Inner Join
# =============================================================================
#
# Implements the merge phase of a sort-merge join. Both sides must be
# pre-sorted by the join key. The algorithm uses two pointers that walk
# the sorted inputs:
#   - Left key < Right key: advance left
#   - Left key > Right key: advance right
#   - Left key == Right key: output all matching pairs (cross-product
#     of the left-side run with the right-side run of equal keys)
#
# Time complexity: O(N + M) for 1:1 joins, O(N * M) in the degenerate
# case where all keys are equal (but that's correct -- the cross-product
# IS the join result).
#
# Advantages over hash join:
#   - O(1) memory overhead (no hash table)
#   - Output is already sorted by join key
#   - Better for pre-sorted inputs (common after ORDER BY or partitioning)
# =============================================================================


@always_inline
def _smj_key_load[
    _mut: Bool, o: Origin[mut=_mut], //
](ptr: UnsafePointer[Scalar[DType.int64], o], idx: Int) -> Int64:
    """Load a single key from a raw pointer. @always_inline avoids call overhead.

    SAFETY: Raw pointer for zero-overhead key access in the sort-merge join
    inner loop. The PrimitiveArray that produced this pointer must outlive
    the entire sort_merge_join call. Origin/mutability-polymorphic params
    `_mut` + `o` so the pointer's origin is tied to the caller's array.
    """
    return Int64(ptr[idx])


def sort_merge_join_inner_into(
    left_keys: PrimitiveArray[DType.int64],
    right_keys: PrimitiveArray[DType.int64],
    mut left_matches: List[Int],
    mut right_matches: List[Int],
    left_null: Optional[List[Bool]] = None,
    right_null: Optional[List[Bool]] = None,
):
    """Sort-merge inner join that appends to caller-provided output buffers.

    See `sort_merge_join_inner` for the algorithm. This variant avoids
    the forced `.copy()` that callers of the Tuple-returning wrapper
    hit because Mojo tuples cannot be partial-moved.

    NULL keys: `left_null` / `right_null`, when supplied,
    are per-(sorted-)row NULL flags aligned with `left_keys` / `right_keys`. A
    NULL key matches NOTHING (SQL "NULL never matches" — not a real value, not
    another NULL), so a NULL row on either side is skipped during the merge.
    When both are None the merge is byte-identical to an unguarded merge (the all-valid
    fast path the caller selects when neither side has nulls).

    Args:
        left_keys: Left-side join key column (must be sorted ascending).
        right_keys: Right-side join key column (must be sorted ascending).
        left_matches: Output list for left-side row indices; appended.
        right_matches: Output list for right-side row indices; appended.
        left_null: Optional per-row NULL flags for the (sorted) left keys.
        right_null: Optional per-row NULL flags for the (sorted) right keys.
    """
    var left_n = left_keys.length
    var right_n = right_keys.length

    if left_n == 0 or right_n == 0:
        return

    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # The `_view` locals hold the borrows for the entire merge loop body.
    var left_view = left_keys.view_ro()
    var left_ptr = left_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var right_view = right_keys.view_ro()
    var right_ptr = right_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

    # A NULL key sorts as the DType-zero value among real keys; skip it.
    var l_has_nulls = left_null.__bool__()
    var r_has_nulls = right_null.__bool__()

    var li = 0
    var ri = 0

    while li < left_n and ri < right_n:
        # Skip NULL keys on either side (never a match).
        if l_has_nulls and left_null.value()[li]:
            li += 1
            continue
        if r_has_nulls and right_null.value()[ri]:
            ri += 1
            continue
        var lk = _smj_key_load(left_ptr, li)
        var rk = _smj_key_load(right_ptr, ri)

        if lk < rk:
            # Left key smaller: advance left.
            li += 1
        elif lk > rk:
            # Right key smaller: advance right.
            ri += 1
        else:
            # Keys are equal. Find the extent of the right-side run
            # with this key value, then cross-product with all matching
            # left rows. NULL right rows in the run are skipped.
            var right_run_start = ri
            while ri < right_n and _smj_key_load(right_ptr, ri) == lk:
                ri += 1
            var right_run_end = ri

            while li < left_n and _smj_key_load(left_ptr, li) == lk:
                if l_has_nulls and left_null.value()[li]:
                    li += 1
                    continue
                for rj in range(right_run_start, right_run_end):
                    if r_has_nulls and right_null.value()[rj]:
                        continue
                    left_matches.append(li)
                    right_matches.append(rj)
                li += 1


def sort_merge_join_inner(
    left_keys: PrimitiveArray[DType.int64],
    right_keys: PrimitiveArray[DType.int64],
) -> Tuple[List[Int], List[Int]]:
    """Sort-merge inner join. Tuple-returning wrapper for test callers.

    Hot-path callers use `sort_merge_join_inner_into` directly. Both
    sides must be pre-sorted.

    Returns:
        A tuple of (left_indices, right_indices) where each position
        represents one matching pair. Both lists have the same length.
        O(N + M) time, no hash table needed.
    """
    # Pre-size output lists to avoid reallocation in common case.
    var est_matches = min(left_keys.length, right_keys.length)
    var left_matches = List[Int](capacity=est_matches)
    var right_matches = List[Int](capacity=est_matches)
    sort_merge_join_inner_into(left_keys, right_keys, left_matches, right_matches)
    return (left_matches^, right_matches^)


# =============================================================================
# Cross Join (Cartesian Product)
# =============================================================================
#
# Generates index pairs for every combination of left and right rows.
# No key columns needed -- every left row matches every right row.
# Output size = left_rows * right_rows.
# =============================================================================


def cross_join_indices(left_rows: Int, right_rows: Int) -> Tuple[List[Int], List[Int]]:
    """Generate index pairs for a cross join (Cartesian product).

    Produces all (left_idx, right_idx) combinations. Output size is
    left_rows * right_rows.

    Args:
        left_rows: Number of rows on the left side.
        right_rows: Number of rows on the right side.

    Returns:
        A tuple of (left_indices, right_indices) where each position
        represents one pair. Both lists have length left_rows * right_rows.
    """
    var total = left_rows * right_rows
    var left_indices = List[Int](capacity=total)
    var right_indices = List[Int](capacity=total)
    for l in range(left_rows):
        for r in range(right_rows):
            left_indices.append(l)
            right_indices.append(r)
    return (left_indices^, right_indices^)
