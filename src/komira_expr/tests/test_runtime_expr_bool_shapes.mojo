# =============================================================================
# RuntimeExprBool: the operand shapes test_runtime_expr_bool.mojo leaves out
# =============================================================================
#
# What each group proves:
#   - comparison sub-ops: LE / GE / EQ / NE give the lane results of their
#     operator (T06 there covers LT / GT); an unknown sub-op is refused by
#     name and number.
#   - validity (strict null propagation: a result is null wherever any
#     operand is): a comparison of two nullable columns is valid only where
#     both are; a column-vs-literal comparison keeps the column's validity;
#     IS_NULL / IS_NOT_NULL read a real null bitmap and are always valid;
#     BETWEEN with column bounds reads them and ANDs their validity.
#   - refusals: each operand shape the walker does not support raises with
#     the message naming the evaluator, the operand and the tag it got; a
#     child index outside [0, node_count) is refused by _eval_node, on both
#     sides of the range.
#   - run_filter_self with a validity buffer writes the validity bytes the
#     row count needs and no mask or validity byte after them. Its mask
#     VALUES are not pinned: today the body is a scaffold that ignores the
#     expression (an always-false filter reads all rows kept), so only what
#     a correct implementation must also do is asserted.
#
# Batches (expectations read off these by hand):
#   _ab():  a = [0, 1, 2, 3, 4, 5, 6, 7]
#           b = [7, 6, 5, 4, 3, 2, 1, 0]
#   _nullable(): p = [0, null, 2, null, 4, 5, 6, 7]
#                q = [9, 9, null, 9, 9, null, 9, 9]
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_buffer.byte_view import ByteView
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_expr.runtime_expr_bool import (
    RuntimeExprBool,
    RuntimeNode,
    CMP_LT,
    CMP_LE,
    CMP_GE,
    CMP_EQ,
    CMP_NE,
    ISNULL_IS_NULL,
    ISNULL_IS_NOT_NULL,
    rt_lit_bool,
    rt_lit_int,
    rt_lit_float,
    rt_col_ref,
    rt_comparison,
    rt_and,
    rt_not,
    rt_is_null,
    rt_between,
    build_runtime_expr_bool,
    MAX_NODES,
)


def _ab() raises -> RecordBatch:
    var a = List[Scalar[DType.int64]]()
    var b = List[Scalar[DType.int64]]()
    for i in range(8):
        a.append(Scalar[DType.int64](Int64(i)))
        b.append(Scalar[DType.int64](Int64(7 - i)))
    var schema = Schema.from_fields_2(
        Field("a", DType.int64, False), Field("b", DType.int64, False)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(a^)
        ),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(b^)
        ),
    )


def _nullable() raises -> RecordBatch:
    var p = ColumnBuilder[DType.int64].with_capacity(8)
    var q = ColumnBuilder[DType.int64].with_capacity(8)
    for i in range(8):
        if i == 1 or i == 3:
            p.append_null()
        else:
            p.append(Int64(i))
        if i == 2 or i == 5:
            q.append_null()
        else:
            q.append(Int64(9))
    var schema = Schema.from_fields_2(
        Field("p", DType.int64, True), Field("q", DType.int64, True)
    )
    return RecordBatch.from_typed_columns_2(
        schema^, p^.materialize(), q^.materialize()
    )


def _bits(pattern: String) -> List[Bool]:
    """"10001011" -> [True, False, False, False, True, False, True, True]."""
    var out = List[Bool]()
    for c in pattern.codepoint_slices():
        out.append(c == "1")
    return out^


def _cmp_lanes(sub_op: UInt8, lit: Int) raises -> List[Bool]:
    """Lanes of `a <sub_op> lit` over a = [0..7]."""
    var batch = _ab()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(lit)))
    nodes.append(rt_comparison(sub_op, 0, 1))
    var expr = build_runtime_expr_bool(nodes^, root=2)
    var chunk = expr.eval[8](bv, 0)
    var out = List[Bool]()
    for j in range(8):
        out.append(Bool(chunk.values[j]))
        assert_true(Bool(chunk.validity[j]))
    return out^


def _eval_error(var nodes: List[RuntimeNode], root: Int) raises -> String:
    """The message of the Error eval[8] raises over _ab(); "" if none."""
    var batch = _ab()
    var bv = batch_view_over(batch)
    var expr = build_runtime_expr_bool(nodes^, root=root)
    try:
        _ = expr.eval[8](bv, 0)
    except e:
        return String(e)
    return String("")


# =============================================================================
# Comparison sub-ops
# =============================================================================


def test_cmp_le() raises:
    var got = _cmp_lanes(CMP_LE, 3)
    for j in range(8):
        assert_equal(got[j], j <= 3, String("lane ", j))


def test_cmp_ge() raises:
    var got = _cmp_lanes(CMP_GE, 3)
    for j in range(8):
        assert_equal(got[j], j >= 3, String("lane ", j))


def test_cmp_eq() raises:
    var got = _cmp_lanes(CMP_EQ, 3)
    for j in range(8):
        assert_equal(got[j], j == 3, String("lane ", j))


def test_cmp_ne() raises:
    var got = _cmp_lanes(CMP_NE, 3)
    for j in range(8):
        assert_equal(got[j], j != 3, String("lane ", j))


def test_cmp_unknown_sub_op_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(3)))
    nodes.append(rt_comparison(UInt8(9), 0, 1))
    assert_equal(
        _eval_error(nodes^, 2), "RuntimeExprBool._cmp_simd: unknown sub_op 9"
    )


# =============================================================================
# Validity
# =============================================================================


def test_cmp_col_col_validity_is_and() raises:
    """p < q: validity is valid(p) & valid(q) = lanes 0, 4, 6, 7 only; at
    those lanes p is 0, 4, 6, 7 and q is 9, so the values are True."""
    var batch = _nullable()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_col_ref(1))
    nodes.append(rt_comparison(CMP_LT, 0, 1))
    var expr = build_runtime_expr_bool(nodes^, root=2)
    var chunk = expr.eval[8](bv, 0)
    var valid = _bits("10001011")
    for j in range(8):
        assert_equal(Bool(chunk.validity[j]), valid[j], String("lane ", j))
    assert_true(Bool(chunk.values[0]))
    assert_true(Bool(chunk.values[4]))
    assert_true(Bool(chunk.values[7]))


def test_cmp_col_lit_validity_is_column() raises:
    """p >= 0: the literal is always valid, so validity is p's."""
    var batch = _nullable()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(0)))
    nodes.append(rt_comparison(CMP_GE, 0, 1))
    var expr = build_runtime_expr_bool(nodes^, root=2)
    var chunk = expr.eval[8](bv, 0)
    var valid = _bits("10101111")
    for j in range(8):
        assert_equal(Bool(chunk.validity[j]), valid[j], String("lane ", j))


def test_is_null_reads_bitmap() raises:
    """IS_NULL(p) is True at lanes 1, 3; IS_NOT_NULL(p) is its complement;
    both always valid."""
    var batch = _nullable()
    var bv = batch_view_over(batch)
    var n1 = List[RuntimeNode]()
    n1.append(rt_col_ref(0))
    n1.append(rt_is_null(0, ISNULL_IS_NULL))
    var is_null = build_runtime_expr_bool(n1^, root=1).eval[8](bv, 0)
    var n2 = List[RuntimeNode]()
    n2.append(rt_col_ref(0))
    n2.append(rt_is_null(0, ISNULL_IS_NOT_NULL))
    var not_null = build_runtime_expr_bool(n2^, root=1).eval[8](bv, 0)
    for j in range(8):
        var want_null = j == 1 or j == 3
        assert_equal(Bool(is_null.values[j]), want_null, String("lane ", j))
        assert_equal(Bool(not_null.values[j]), not want_null, String("lane ", j))
        assert_true(Bool(is_null.validity[j]))
        assert_true(Bool(not_null.validity[j]))


def test_between_column_bounds() raises:
    """b BETWEEN a AND lit 5 over a = [0..7], b = [7..0]: b >= a holds for
    lanes 0..3, b <= 5 for lanes 2..7; both at lanes 2, 3."""
    var batch = _ab()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(1))
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(5)))
    nodes.append(rt_between(0, 1, 2))
    var chunk = build_runtime_expr_bool(nodes^, root=3).eval[8](bv, 0)
    for j in range(8):
        assert_equal(Bool(chunk.values[j]), j == 2 or j == 3, String("lane ", j))
        assert_true(Bool(chunk.validity[j]))


def test_between_high_column_and_validity() raises:
    """q BETWEEN lit 0 AND p: value valid only where q is, high only where
    p is; validity is their AND = lanes 0, 4, 6, 7. There p is 0, 4, 6, 7,
    so 9 <= p fails and every valid lane is False."""
    var batch = _nullable()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(1))
    nodes.append(rt_lit_int(Int64(0)))
    nodes.append(rt_col_ref(0))
    nodes.append(rt_between(0, 1, 2))
    var chunk = build_runtime_expr_bool(nodes^, root=3).eval[8](bv, 0)
    var valid = _bits("10001011")
    for j in range(8):
        assert_equal(Bool(chunk.validity[j]), valid[j], String("lane ", j))
    assert_false(Bool(chunk.values[0]))
    assert_false(Bool(chunk.values[4]))
    assert_false(Bool(chunk.values[7]))


def test_between_low_column_validity() raises:
    """p BETWEEN q AND lit 7: the low operand q is null at lanes 2, 5, where
    p is valid, so the result's validity is valid(p) & valid(q) = lanes
    0, 4, 6, 7 (not p's alone). There p is 0, 4, 6, 7 and q is 9, so
    p >= q fails and every valid lane is False."""
    var batch = _nullable()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_col_ref(1))
    nodes.append(rt_lit_int(Int64(7)))
    nodes.append(rt_between(0, 1, 2))
    var chunk = build_runtime_expr_bool(nodes^, root=3).eval[8](bv, 0)
    var valid = _bits("10001011")
    for j in range(8):
        assert_equal(Bool(chunk.validity[j]), valid[j], String("lane ", j))
    assert_false(Bool(chunk.values[0]))
    assert_false(Bool(chunk.values[6]))


# =============================================================================
# Refusals
# =============================================================================


def test_child_index_past_count_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(True))
    nodes.append(rt_and(0, 5))
    assert_equal(
        _eval_error(nodes^, 1),
        "RuntimeExprBool._eval_node: node_idx 5 out of bounds [0, 2)",
    )


def test_child_index_negative_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(True))
    nodes.append(rt_not(-1))
    assert_equal(
        _eval_error(nodes^, 1),
        "RuntimeExprBool._eval_node: node_idx -1 out of bounds [0, 2)",
    )


def test_comparison_left_not_column_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_int(Int64(1)))
    nodes.append(rt_col_ref(0))
    nodes.append(rt_comparison(CMP_LT, 0, 1))
    assert_equal(
        _eval_error(nodes^, 2),
        "RuntimeExprBool._eval_comparison: supports only col_ref on the"
        " left; got tag 1",
    )


def test_comparison_right_float_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_float(1.5))
    nodes.append(rt_comparison(CMP_LT, 0, 1))
    assert_equal(
        _eval_error(nodes^, 2),
        "RuntimeExprBool._eval_comparison: supports col_ref or lit_int on"
        " the right; got tag 2",
    )


def test_is_null_child_not_column_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(False))
    nodes.append(rt_is_null(0, ISNULL_IS_NULL))
    assert_equal(
        _eval_error(nodes^, 1),
        "RuntimeExprBool._eval_is_null: supports only col_ref child; got"
        " tag 0",
    )


def test_between_value_not_column_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_int(Int64(1)))
    nodes.append(rt_lit_int(Int64(0)))
    nodes.append(rt_lit_int(Int64(2)))
    nodes.append(rt_between(0, 1, 2))
    assert_equal(
        _eval_error(nodes^, 3),
        "RuntimeExprBool._eval_between: supports only col_ref on the value;"
        " got tag 1",
    )


def test_between_low_float_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_float(0.5))
    nodes.append(rt_lit_int(Int64(2)))
    nodes.append(rt_between(0, 1, 2))
    assert_equal(
        _eval_error(nodes^, 3),
        "RuntimeExprBool._eval_between: low operand must be lit_int or"
        " col_ref; got tag 2",
    )


def test_between_high_bool_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(0)))
    nodes.append(rt_lit_bool(True))
    nodes.append(rt_between(0, 1, 2))
    assert_equal(
        _eval_error(nodes^, 3),
        "RuntimeExprBool._eval_between: high operand must be lit_int or"
        " col_ref; got tag 0",
    )


# =============================================================================
# run_filter_self with a validity buffer
# =============================================================================


comptime _UNTOUCHED: UInt8 = 0xA5


def _run_filter_self_bytes(n: Int) raises -> List[UInt8]:
    """Runs `rt_lit_bool(False).run_filter_self` over an `n`-row batch into a
    3-byte mask and a 3-byte validity buffer, both prefilled with
    _UNTOUCHED; returns [mask0, mask1, mask2, val0, val1, val2]."""
    var a = List[Scalar[DType.int64]]()
    for i in range(n):
        a.append(Scalar[DType.int64](Int64(i)))
    var batch = RecordBatch.from_typed_columns_1(
        Schema.from_fields_1(Field("a", DType.int64, False)),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(a^)
        ),
    )
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(False))
    var expr = build_runtime_expr_bool(nodes^, root=0)

    var mask_buf = OwnedAlignedBuffer(3)
    mask_buf.set_length(3)
    var mask_view = mask_buf.view_mut()
    var val_buf = OwnedAlignedBuffer(3)
    val_buf.set_length(3)
    var val_view = val_buf.view_mut()
    for k in range(3):
        mask_view.write_u8_at(k, _UNTOUCHED)
        val_view.write_u8_at(k, _UNTOUCHED)
    var validity = Optional[ByteView[val_view.origin]](val_view)
    expr.run_filter_self(bv, mask_view, validity)
    var out = List[UInt8]()
    for k in range(3):
        out.append(mask_view.read_u8_at(k))
    for k in range(3):
        out.append(val_view.read_u8_at(k))
    _ = mask_buf^
    _ = val_buf^
    return out^


def test_run_filter_self_writes_validity_bytes() raises:
    """10 rows need (10 + 7) // 8 = 2 bytes.

    run_filter_self is a scaffold today (it ignores the expression), so the
    mask values are NOT pinned. Asserted, true of a correct implementation
    too: the literal is never null, so validity rows 0..7 (byte 0) and rows
    8, 9 (bits 0, 1 of byte 1) are valid; byte 2 of the mask and of the
    validity buffer, past the 2 bytes 10 rows need, is untouched."""
    var b = _run_filter_self_bytes(10)
    assert_equal(Int(b[2]), Int(_UNTOUCHED), "mask byte 2")
    assert_equal(Int(b[3]), 0xFF, "validity byte 0")
    assert_equal(Int(b[4] & 0x03), 0x03, "validity rows 8, 9")
    assert_equal(Int(b[5]), Int(_UNTOUCHED), "validity byte 2")


def test_run_filter_self_whole_bytes_stop_at_n_bytes() raises:
    """16 rows need exactly 2 bytes (not 16 // 8 + 1 = 3): both validity
    bytes are all-valid and byte 2 of the mask and validity buffers is
    untouched. Mask values are not pinned (scaffold, see above)."""
    var b = _run_filter_self_bytes(16)
    assert_equal(Int(b[2]), Int(_UNTOUCHED), "mask byte 2")
    assert_equal(Int(b[3]), 0xFF, "validity byte 0")
    assert_equal(Int(b[4]), 0xFF, "validity byte 1")
    assert_equal(Int(b[5]), Int(_UNTOUCHED), "validity byte 2")


# =============================================================================
# build_runtime_expr_bool bounds
# =============================================================================


def test_build_negative_root_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(True))
    var msg = String("")
    try:
        _ = build_runtime_expr_bool(nodes^, root=-1)
    except e:
        msg = String(e)
    assert_equal(msg, "build_runtime_expr_bool: root -1 out of bounds [0, 1)")


def test_build_root_equal_to_count_raises() raises:
    """root == len(nodes) is the first index past the end."""
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(True))
    nodes.append(rt_lit_bool(False))
    var msg = String("")
    try:
        _ = build_runtime_expr_bool(nodes^, root=2)
    except e:
        msg = String(e)
    assert_equal(msg, "build_runtime_expr_bool: root 2 out of bounds [0, 2)")


def test_build_exactly_max_nodes_accepted() raises:
    """MAX_NODES nodes fit; the last slot is a usable root."""
    assert_equal(MAX_NODES, 256)
    var batch = _ab()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    for _ in range(MAX_NODES - 1):
        nodes.append(rt_lit_bool(False))
    nodes.append(rt_lit_bool(True))
    var expr = build_runtime_expr_bool(nodes^, root=MAX_NODES - 1)
    assert_equal(expr.node_count, MAX_NODES)
    assert_true(Bool(expr.eval[4](bv, 0).values[0]))


def test_build_one_past_max_nodes_message() raises:
    var nodes = List[RuntimeNode]()
    for _ in range(MAX_NODES + 1):
        nodes.append(rt_lit_bool(True))
    var msg = String("")
    try:
        _ = build_runtime_expr_bool(nodes^, root=0)
    except e:
        msg = String(e)
    assert_equal(
        msg, "build_runtime_expr_bool: node count 257 exceeds MAX_NODES=256"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
