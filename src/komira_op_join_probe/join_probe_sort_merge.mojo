# =============================================================================
# join_probe_sort_merge -- the sort-merge join over two whole batches, one
# INT64 key: INNER, LEFT, RIGHT and FULL.
# =============================================================================
#
# Both key columns are sorted with the stable radix sort, the sorted keys are
# merged (`komira_op_join_build`'s INNER merge, or `sort_merge_join_outer`),
# and the merged positions are mapped back through the two permutations to
# row indices of the batches. A NULL key matches nothing: its row's flag is
# looked up through the permutation and handed to the merge.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch

from komira_plan_ir.logical_plan import JOIN_LEFT, JOIN_RIGHT, JOIN_FULL
from komira_join_assembly.compiler_join_assembly import (
    assemble_join_result,
    assemble_join_result_projected,
)
from komira_op_join_build.join_sort_merge import sort_merge_join_inner_into
from komira_op_sort.sort_radix import radix_sort_int64

from .join_output_schema import (
    build_join_output_schema,
    build_join_output_schema_outer,
)
from .sort_merge_join_outer import (
    sort_merge_join_left_into,
    sort_merge_join_right_into,
    sort_merge_join_full_into,
)


struct _SortedKeys(Movable):
    """One side's keys in ascending order, the permutation that sorted them
    (`perm[i]` is the row of sorted position `i`) and, when the column has a
    NULL, the per-sorted-row NULL flags."""

    var keys: PrimitiveArray[DType.int64]
    var perm: PrimitiveArray[DType.int32]
    var nulls: Optional[List[Bool]]

    def __init__(out self, keys: PrimitiveArray[DType.int64]) raises:
        var n = keys.length
        var perm = radix_sort_int64(keys)
        var ordered = PrimitiveArray[DType.int64].allocate(n)
        var nulls: Optional[List[Bool]] = None
        # SAFETY: read-only views of `keys` and `perm`, a mutable view of the
        # freshly allocated `ordered`; all three live across the loops and
        # nothing else touches them.
        var src_view = keys.view_ro()
        var src = src_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var dst_view = ordered.view_mut()
        var dst = dst_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var p_view = perm.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        for i in range(n):
            (dst + i)[] = (src + Int((p + i)[]))[]
        if keys.null_count != 0:
            var flags = List[Bool](capacity=n)
            for i in range(n):
                flags.append(keys.is_null(Int((p + i)[])))
            nulls = Optional[List[Bool]](flags^)
        _ = src_view
        _ = dst_view
        _ = p_view
        self.keys = ordered^
        self.perm = perm^
        self.nulls = nulls^

    def row(self, sorted_pos: Int) raises -> Int:
        """The row of sorted position `sorted_pos`; -1 stays -1."""
        if sorted_pos < 0:
            return -1
        return Int(self.perm.get(sorted_pos))


def execute_sort_merge_join_probe(
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    left_key_arr: PrimitiveArray[DType.int64],
    right_key_arr: PrimitiveArray[DType.int64],
    output_cols: Optional[List[String]] = None,
) raises -> RecordBatch:
    """The INNER sort-merge join of `probe_batch` (left) and `build_batch`
    (right) on the two key columns, assembled to `output_cols` when given,
    else to every column of both sides."""
    var ls = _SortedKeys(left_key_arr)
    var rs = _SortedKeys(right_key_arr)
    var merge_left = List[Int](capacity=min(ls.keys.length, rs.keys.length))
    var merge_right = List[Int](capacity=min(ls.keys.length, rs.keys.length))
    sort_merge_join_inner_into(
        ls.keys, rs.keys, merge_left, merge_right, ls.nulls, rs.nulls,
    )
    var left_indices = List[Int](capacity=len(merge_left))
    var right_indices = List[Int](capacity=len(merge_left))
    for i in range(len(merge_left)):
        left_indices.append(ls.row(merge_left[i]))
        right_indices.append(rs.row(merge_right[i]))
    if output_cols:
        return assemble_join_result_projected(
            probe_batch, build_batch, left_indices, right_indices,
            output_cols.value(),
        )
    var out_schema = build_join_output_schema(
        probe_batch.schema, build_batch.schema
    )
    return assemble_join_result(
        probe_batch, build_batch, left_indices, right_indices, out_schema,
    )


def execute_sort_merge_join_outer_probe(
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    left_key_arr: PrimitiveArray[DType.int64],
    right_key_arr: PrimitiveArray[DType.int64],
    join_type: UInt8,
    output_cols: Optional[List[String]] = None,
) raises -> RecordBatch:
    """The LEFT, RIGHT or FULL (`join_type`) sort-merge join; an unmatched
    row's other side comes out NULL. Any other join type raises."""
    var ls = _SortedKeys(left_key_arr)
    var rs = _SortedKeys(right_key_arr)
    var est = max(ls.keys.length, rs.keys.length)
    var merge_left = List[Int](capacity=est)
    var merge_right = List[Int](capacity=est)
    if join_type == JOIN_LEFT:
        sort_merge_join_left_into(
            ls.keys, rs.keys, merge_left, merge_right, ls.nulls, rs.nulls,
        )
    elif join_type == JOIN_RIGHT:
        sort_merge_join_right_into(
            ls.keys, rs.keys, merge_left, merge_right, ls.nulls, rs.nulls,
        )
    elif join_type == JOIN_FULL:
        sort_merge_join_full_into(
            ls.keys, rs.keys, merge_left, merge_right, ls.nulls, rs.nulls,
        )
    else:
        raise Error(
            "execute_sort_merge_join_outer_probe: unsupported join_type="
            + String(Int(join_type))
        )
    var left_indices = List[Int](capacity=len(merge_left))
    var right_indices = List[Int](capacity=len(merge_left))
    for i in range(len(merge_left)):
        left_indices.append(ls.row(merge_left[i]))
        right_indices.append(rs.row(merge_right[i]))

    var left_nullable = join_type == JOIN_RIGHT or join_type == JOIN_FULL
    var right_nullable = join_type == JOIN_LEFT or join_type == JOIN_FULL
    if output_cols:
        return assemble_join_result_projected(
            probe_batch, build_batch, left_indices, right_indices,
            output_cols.value(),
            left_nullable=left_nullable,
            right_nullable=right_nullable,
        )
    var out_schema = build_join_output_schema_outer(
        probe_batch.schema, build_batch.schema, left_nullable, right_nullable,
    )
    return assemble_join_result(
        probe_batch, build_batch, left_indices, right_indices, out_schema,
        left_nullable=left_nullable,
        right_nullable=right_nullable,
    )
