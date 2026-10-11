# =============================================================================
# RuntimeExprBool: child indices read by the leaf evaluators, and IS_NULL
# variants
# =============================================================================
#
# What each test proves:
#   - _eval_comparison, _eval_is_null and _eval_between check every child
#     index they read against [0, node_count) before reading it, as
#     _eval_node does, and raise naming the evaluator and the index. Without
#     the check an index in [node_count, MAX_NODES) or -1 reads an unused
#     slot (tag 255) and raises a misleading "got tag 255", and an index
#     past MAX_NODES reads outside the node array.
#   - node_count is a public field. A count set past MAX_NODES does not let
#     an index past the array through: the bound is capped at MAX_NODES.
#   - IS_NULL refuses a variant other than IS_NULL / IS_NOT_NULL instead of
#     reading it as IS_NOT_NULL, as _cmp_simd refuses an unknown sub-op.
#
# Batch: _ab(): a = [0..7], b = [7..0], both Int64, no nulls.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_expr.runtime_expr_bool import (
    RuntimeNode,
    CMP_LT,
    ISNULL_IS_NULL,
    ISNULL_IS_NOT_NULL,
    rt_lit_int,
    rt_col_ref,
    rt_comparison,
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
# RT_COMPARISON
# =============================================================================


def test_comparison_right_past_count_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_comparison(CMP_LT, 0, 5))
    assert_equal(
        _eval_error(nodes^, 1),
        "RuntimeExprBool._eval_comparison: node_idx 5 out of bounds [0, 2)",
    )


def test_comparison_left_negative_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_comparison(CMP_LT, -1, 0))
    assert_equal(
        _eval_error(nodes^, 1),
        "RuntimeExprBool._eval_comparison: node_idx -1 out of bounds [0, 2)",
    )


def test_comparison_right_past_max_nodes_raises() raises:
    """300 is past the node array, not only past node_count."""
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_comparison(CMP_LT, 0, 300))
    assert_equal(
        _eval_error(nodes^, 1),
        "RuntimeExprBool._eval_comparison: node_idx 300 out of bounds [0, 2)",
    )


# =============================================================================
# RT_IS_NULL
# =============================================================================


def test_is_null_child_past_count_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_is_null(2, ISNULL_IS_NULL))
    assert_equal(
        _eval_error(nodes^, 1),
        "RuntimeExprBool._eval_is_null: node_idx 2 out of bounds [0, 2)",
    )


def test_is_null_unknown_variant_raises() raises:
    """Variant 7 is neither IS_NULL (0) nor IS_NOT_NULL (1)."""
    assert_equal(ISNULL_IS_NULL, UInt8(0))
    assert_equal(ISNULL_IS_NOT_NULL, UInt8(1))
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_is_null(0, UInt8(7)))
    assert_equal(
        _eval_error(nodes^, 1),
        "RuntimeExprBool._eval_is_null: unknown variant 7",
    )


# =============================================================================
# RT_BETWEEN: each of the three children
# =============================================================================


def test_between_value_past_count_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_int(Int64(1)))
    nodes.append(rt_lit_int(Int64(5)))
    nodes.append(rt_between(9, 0, 1))
    assert_equal(
        _eval_error(nodes^, 2),
        "RuntimeExprBool._eval_between: node_idx 9 out of bounds [0, 3)",
    )


def test_between_low_negative_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(5)))
    nodes.append(rt_between(0, -2, 1))
    assert_equal(
        _eval_error(nodes^, 2),
        "RuntimeExprBool._eval_between: node_idx -2 out of bounds [0, 3)",
    )


def test_between_high_past_max_nodes_raises() raises:
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(1)))
    nodes.append(rt_between(0, 1, 1000))
    assert_equal(
        _eval_error(nodes^, 2),
        "RuntimeExprBool._eval_between: node_idx 1000 out of bounds [0, 3)",
    )


# =============================================================================
# node_count past MAX_NODES
# =============================================================================


def test_node_count_past_max_nodes_is_capped() raises:
    """A caller-set node_count of 1000 does not admit index 300: the bound
    reported and enforced is MAX_NODES."""
    var batch = _ab()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_not(300))
    var expr = build_runtime_expr_bool(nodes^, root=0)
    expr.node_count = 1000
    var msg = String("")
    try:
        _ = expr.eval[8](bv, 0)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "RuntimeExprBool._eval_node: node_idx 300 out of bounds [0, ",
            MAX_NODES,
            ")",
        ),
    )


def test_in_bounds_children_still_evaluate() raises:
    """The checks refuse nothing in range: `a < 4` over a = [0..7] gives
    lanes 0..3 true, and IS_NOT_NULL over a non-null column is all true."""
    var batch = _ab()
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(4)))
    nodes.append(rt_comparison(CMP_LT, 0, 1))
    var chunk = build_runtime_expr_bool(nodes^, root=2).eval[8](bv, 0)
    for j in range(8):
        assert_equal(Bool(chunk.values[j]), j < 4, String("lane ", j))
    var n2 = List[RuntimeNode]()
    n2.append(rt_col_ref(0))
    n2.append(rt_is_null(0, ISNULL_IS_NOT_NULL))
    var c2 = build_runtime_expr_bool(n2^, root=1).eval[8](bv, 0)
    for j in range(8):
        assert_equal(Bool(c2.values[j]), True, String("not-null lane ", j))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
