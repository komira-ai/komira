# =============================================================================
# sort_merge_join_outer -- the LEFT, RIGHT and FULL OUTER sort-merge joins.
# =============================================================================
#
# Two cursors walk two key arrays sorted ascending and emit pairs of row
# indices; -1 stands for the missing side of an unmatched row (the convention
# `komira_join_assembly`'s assembly reads as NULL):
#
#   1. left < right: the left row has no match. LEFT and FULL emit
#      (left_row, -1); advance left.
#   2. left > right: the right row has no match. RIGHT and FULL emit
#      (-1, right_row); advance right.
#   3. left == right: every left row of the run pairs with every right row of
#      the run.
#   4. When one side runs out, the other side's remaining rows are unmatched.
#
# A NULL key matches nothing, not even another NULL: a row whose flag in
# `left_null` / `right_null` is set is an unmatched row of its side wherever
# the sort put it. The flags are per SORTED row; None on a side means it has
# no NULL. The INNER merge is `komira_op_join_build`'s
# `sort_merge_join_inner_into`.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray

from komira_op_join_build.join_sort_merge import _smj_key_load


def sort_merge_join_left_into(
    left_keys: PrimitiveArray[DType.int64],
    right_keys: PrimitiveArray[DType.int64],
    mut left_matches: List[Int],
    mut right_matches: List[Int],
    left_null: Optional[List[Bool]] = None,
    right_null: Optional[List[Bool]] = None,
):
    """LEFT OUTER merge of two ascending key arrays, appending to the caller's
    lists. Every left row appears; an unmatched one pairs with -1.

    Args:
        left_keys: Left join keys, sorted ascending.
        right_keys: Right join keys, sorted ascending.
        left_matches: Left row indices, appended.
        right_matches: Right row indices, appended; -1 for no match.
        left_null: Per sorted left row, True for a NULL key; None for none.
        right_null: Per sorted right row, True for a NULL key; None for none.
    """
    _sort_merge_join_outer_impl(
        left_keys, right_keys, left_matches, right_matches,
        emit_unmatched_left=True, emit_unmatched_right=False,
        left_null=left_null, right_null=right_null,
    )


def sort_merge_join_right_into(
    left_keys: PrimitiveArray[DType.int64],
    right_keys: PrimitiveArray[DType.int64],
    mut left_matches: List[Int],
    mut right_matches: List[Int],
    left_null: Optional[List[Bool]] = None,
    right_null: Optional[List[Bool]] = None,
):
    """RIGHT OUTER merge: every right row appears; an unmatched one pairs with
    -1 in `left_matches`. Arguments as `sort_merge_join_left_into`."""
    _sort_merge_join_outer_impl(
        left_keys, right_keys, left_matches, right_matches,
        emit_unmatched_left=False, emit_unmatched_right=True,
        left_null=left_null, right_null=right_null,
    )


def sort_merge_join_full_into(
    left_keys: PrimitiveArray[DType.int64],
    right_keys: PrimitiveArray[DType.int64],
    mut left_matches: List[Int],
    mut right_matches: List[Int],
    left_null: Optional[List[Bool]] = None,
    right_null: Optional[List[Bool]] = None,
):
    """FULL OUTER merge: every row of both sides appears; an unmatched one
    pairs with -1 on the other side. Arguments as `sort_merge_join_left_into`.
    """
    _sort_merge_join_outer_impl(
        left_keys, right_keys, left_matches, right_matches,
        emit_unmatched_left=True, emit_unmatched_right=True,
        left_null=left_null, right_null=right_null,
    )


def _sort_merge_join_outer_impl(
    left_keys: PrimitiveArray[DType.int64],
    right_keys: PrimitiveArray[DType.int64],
    mut left_matches: List[Int],
    mut right_matches: List[Int],
    emit_unmatched_left: Bool,
    emit_unmatched_right: Bool,
    left_null: Optional[List[Bool]] = None,
    right_null: Optional[List[Bool]] = None,
):
    """The merge loop shared by the three outer joins; the two flags say which
    side's unmatched rows are emitted (LEFT: left, RIGHT: right, FULL: both).
    """
    var left_n = left_keys.length
    var right_n = right_keys.length

    if left_n == 0 and right_n == 0:
        return
    if left_n == 0:
        if emit_unmatched_right:
            for ri in range(right_n):
                left_matches.append(-1)
                right_matches.append(ri)
        return
    if right_n == 0:
        if emit_unmatched_left:
            for li in range(left_n):
                left_matches.append(li)
                right_matches.append(-1)
        return

    # SAFETY: read-only views of the two key buffers, borrowed for this call;
    # the `_view` locals pin them across the merge loop.
    var left_view = left_keys.view_ro()
    var left_ptr = left_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var right_view = right_keys.view_ro()
    var right_ptr = right_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

    var l_has_nulls = left_null.__bool__()
    var r_has_nulls = right_null.__bool__()

    var li = 0
    var ri = 0
    while li < left_n and ri < right_n:
        # A NULL key is an unmatched row of its side, before any comparison:
        # its slot holds some value that could otherwise compare equal.
        if l_has_nulls and left_null.value()[li]:
            if emit_unmatched_left:
                left_matches.append(li)
                right_matches.append(-1)
            li += 1
            continue
        if r_has_nulls and right_null.value()[ri]:
            if emit_unmatched_right:
                left_matches.append(-1)
                right_matches.append(ri)
            ri += 1
            continue
        var lk = _smj_key_load(left_ptr, li)
        var rk = _smj_key_load(right_ptr, ri)

        if lk < rk:
            if emit_unmatched_left:
                left_matches.append(li)
                right_matches.append(-1)
            li += 1
        elif lk > rk:
            if emit_unmatched_right:
                left_matches.append(-1)
                right_matches.append(ri)
            ri += 1
        else:
            # The run of right rows holding `lk` (NULL rows whose slot holds
            # `lk` included; they are skipped below), then every left row of
            # the run against it. The run starts at a non-NULL row (the NULL
            # checks above ran first), so every non-NULL left row of the run
            # matches at least that one.
            var right_run_start = ri
            while ri < right_n and _smj_key_load(right_ptr, ri) == lk:
                ri += 1
            var right_run_end = ri

            while li < left_n and _smj_key_load(left_ptr, li) == lk:
                if l_has_nulls and left_null.value()[li]:
                    if emit_unmatched_left:
                        left_matches.append(li)
                        right_matches.append(-1)
                    li += 1
                    continue
                for rj in range(right_run_start, right_run_end):
                    if r_has_nulls and right_null.value()[rj]:
                        continue
                    left_matches.append(li)
                    right_matches.append(rj)
                li += 1

            # The run's NULL right rows matched no left row.
            if emit_unmatched_right and r_has_nulls:
                for rj in range(right_run_start, right_run_end):
                    if right_null.value()[rj]:
                        left_matches.append(-1)
                        right_matches.append(rj)

    if emit_unmatched_left:
        while li < left_n:
            left_matches.append(li)
            right_matches.append(-1)
            li += 1
    if emit_unmatched_right:
        while ri < right_n:
            left_matches.append(-1)
            right_matches.append(ri)
            ri += 1
    _ = left_view
    _ = right_view
