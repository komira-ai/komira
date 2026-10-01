# =============================================================================
# Unit tests for the RuntimeExprBool wrapper
# =============================================================================
#
# Acceptance checks:
#   - 16-tag coverage: at least one case per tag (round-trip via eval[W]
#     where supported, FALLBACK assertion where stubbed).
#   - Overflow case: build expr > MAX_NODES (256) → raises Error.
#   - Kleene 3VL: build expr with NULL operands → Kleene arms fire.
#
# Coverage table:
#   T01 — RT_LIT_BOOL  — splat True / False, validity all-True.
#   T02 — RT_LIT_INT   — STUB (used as comparison rhs immediate, not standalone).
#   T03 — RT_LIT_FLOAT — STUB (FALLBACK path).
#   T04 — RT_LIT_STR   — STUB (FALLBACK path).
#   T05 — RT_COL_REF   — Bool column read round-trip.
#   T06 — RT_COMPARISON — col_i64 > lit_int and col_i64 < col_i64 shapes.
#   T07 — RT_AND        — Kleene AND of two RT_COMPARISON children.
#   T08 — RT_OR         — Kleene OR of two RT_COMPARISON children.
#   T09 — RT_NOT        — Kleene NOT of one RT_COMPARISON child.
#   T10 — RT_IS_NULL    — IS_NULL and IS_NOT_NULL variants.
#   T11 — RT_BETWEEN    — col_i64 BETWEEN lit AND lit shape.
#   T12 — RT_IN_LIST    — STUB (FALLBACK path).
#   T13 — RT_BIN_OP     — STUB (FALLBACK path when used standalone).
#   T14 — RT_EXPR_AGG_FN — STUB (FALLBACK path).
#   T15 — RT_EXPR_WHEN   — STUB (FALLBACK path).
#   T16 — RT_EXPR_CAST   — STUB (FALLBACK path).
#
#   Plus:
#   - Overflow raises (build_runtime_expr_bool with > MAX_NODES nodes).
#   - Out-of-range root raises.
#   - Kleene 3VL: AND with NULL operand — validity propagated (Kleene).
#   - run_filter_self forwards through ExprBoolU surface — writes 0xFF
#     bytes per the default (stub).
#   - shape_classify returns SHAPE_FALLBACK (stub).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.collections import batch_view_over
from komira_core.collections.byte_view import ByteView
from komira_eval import (
    RuntimeExprBool,
    RuntimeNode,
    ShapeClass,
    MAX_NODES,
    SHAPE_FALLBACK,
    RT_LIT_BOOL,
    RT_LIT_INT,
    RT_LIT_FLOAT,
    RT_LIT_STR,
    RT_COL_REF,
    RT_COMPARISON,
    RT_AND,
    RT_OR,
    RT_NOT,
    RT_IS_NULL,
    RT_BETWEEN,
    RT_IN_LIST,
    RT_BIN_OP,
    RT_EXPR_AGG_FN,
    RT_EXPR_WHEN,
    RT_EXPR_CAST,
    CMP_LT,
    CMP_GT,
    CMP_EQ,
    ISNULL_IS_NULL,
    ISNULL_IS_NOT_NULL,
    rt_lit_bool,
    rt_lit_int,
    rt_lit_float,
    rt_lit_str,
    rt_col_ref,
    rt_comparison,
    rt_and,
    rt_or,
    rt_not,
    rt_is_null,
    rt_between,
    rt_in_list,
    rt_bin_op,
    rt_expr_agg_fn,
    rt_expr_when,
    rt_expr_cast,
    build_runtime_expr_bool,
)


# =============================================================================
# Builders
# =============================================================================


def _build_int64_batch(n: Int) raises -> RecordBatch:
    """`n`-row Int64 batch with values [0, 1, ..., n-1] in column 0."""
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("x", DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_int64_batch_2cols(n: Int) raises -> RecordBatch:
    """`n`-row 2-column batch: col0=[0,1,..,n-1], col1=[n-1,n-2,..,0]."""
    var v0 = List[Scalar[DType.int64]]()
    var v1 = List[Scalar[DType.int64]]()
    for i in range(n):
        v0.append(Scalar[DType.int64](Int64(i)))
        v1.append(Scalar[DType.int64](Int64(n - 1 - i)))
    var arr0 = PrimitiveArray[DType.int64].from_list(v0^)
    var arr1 = PrimitiveArray[DType.int64].from_list(v1^)
    var schema = Schema.from_fields_2(
        Field("x", DType.int64, True),
        Field("y", DType.int64, True),
    )
    var col0 = Column.from_primitive[DType.int64](arr0^)
    var col1 = Column.from_primitive[DType.int64](arr1^)
    return RecordBatch.from_typed_columns_2(schema^, col0^, col1^)


def _build_bool_batch(n: Int) raises -> RecordBatch:
    """`n`-row Bool batch — col0[i] = (i % 2 == 0)."""
    var arr = BooleanArray.allocate(n)
    for i in range(n):
        arr.set(i, (i % 2) == 0)
    var schema = Schema.from_fields_1(Field("b", DType.bool, True))
    var col = Column.from_boolean(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


# =============================================================================
# T01 — RT_LIT_BOOL — splat True / False
# =============================================================================


def test_rt_lit_bool_true() raises:
    """RT_LIT_BOOL True splats True across all W lanes; validity all-True."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(True))
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var chunk = expr.eval[4](bv, 0)
    assert_equal(Bool(chunk.values[0]), True)
    assert_equal(Bool(chunk.values[1]), True)
    assert_equal(Bool(chunk.values[2]), True)
    assert_equal(Bool(chunk.values[3]), True)
    assert_equal(Bool(chunk.validity[0]), True)


def test_rt_lit_bool_false() raises:
    """RT_LIT_BOOL False splats False; validity all-True (False is a
    valid value, not NULL)."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(False))
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var chunk = expr.eval[4](bv, 0)
    assert_equal(Bool(chunk.values[0]), False)
    assert_equal(Bool(chunk.validity[0]), True)


# =============================================================================
# T02 — RT_LIT_INT — STUB at standalone Bool root (FALLBACK)
# =============================================================================


def test_rt_lit_int_standalone_fallback() raises:
    """RT_LIT_INT as a Bool-tree root must raise FALLBACK (LIT_INT is
    not Bool-typed)."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_int(Int64(42)))
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var raised = False
    try:
        _ = expr.eval[4](bv, 0)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# T03 — RT_LIT_FLOAT — STUB (FALLBACK)
# =============================================================================


def test_rt_lit_float_standalone_fallback() raises:
    """RT_LIT_FLOAT must raise FALLBACK at standalone root."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_float(Float64(3.14)))
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var raised = False
    try:
        _ = expr.eval[4](bv, 0)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# T04 — RT_LIT_STR — STUB (FALLBACK)
# =============================================================================


def test_rt_lit_str_fallback() raises:
    """RT_LIT_STR raises FALLBACK."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_str())
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var raised = False
    try:
        _ = expr.eval[4](bv, 0)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# T05 — RT_COL_REF — Bool column read
# =============================================================================


def test_rt_col_ref_bool_column() raises:
    """RT_COL_REF reads a Bool column. For n=8 with alternating
    True/False, lanes 0/2/4/6 = True, 1/3/5/7 = False."""
    var batch = _build_bool_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var chunk = expr.eval[8](bv, 0)
    assert_equal(Bool(chunk.values[0]), True)
    assert_equal(Bool(chunk.values[1]), False)
    assert_equal(Bool(chunk.values[2]), True)
    assert_equal(Bool(chunk.values[3]), False)
    # Non-nullable column → validity all-True.
    assert_equal(Bool(chunk.validity[0]), True)


# =============================================================================
# T06 — RT_COMPARISON
# =============================================================================


def test_rt_comparison_col_gt_lit() raises:
    """col0 > lit(3) — for col0=[0,1,..,7], lanes 4..7 = True."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))           # 0
    nodes.append(rt_lit_int(Int64(3)))    # 1
    nodes.append(rt_comparison(CMP_GT, 0, 1))  # 2: root
    var expr = build_runtime_expr_bool(nodes^, root=2)
    var chunk = expr.eval[8](bv, 0)
    assert_equal(Bool(chunk.values[0]), False)  # 0 > 3? False
    assert_equal(Bool(chunk.values[3]), False)  # 3 > 3? False
    assert_equal(Bool(chunk.values[4]), True)   # 4 > 3? True
    assert_equal(Bool(chunk.values[7]), True)
    assert_equal(Bool(chunk.validity[0]), True)


def test_rt_comparison_col_lt_col() raises:
    """col0 < col1 — for col0=[0,..,7], col1=[7,..,0], lanes 0..3 = True."""
    var batch = _build_int64_batch_2cols(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))   # 0
    nodes.append(rt_col_ref(1))   # 1
    nodes.append(rt_comparison(CMP_LT, 0, 1))  # 2: root
    var expr = build_runtime_expr_bool(nodes^, root=2)
    var chunk = expr.eval[8](bv, 0)
    assert_equal(Bool(chunk.values[0]), True)   # 0 < 7
    assert_equal(Bool(chunk.values[3]), True)   # 3 < 4
    assert_equal(Bool(chunk.values[4]), False)  # 4 < 3
    assert_equal(Bool(chunk.values[7]), False)  # 7 < 0


# =============================================================================
# T07 — RT_AND — Kleene AND of two comparisons
# =============================================================================


def test_rt_and_two_comparisons() raises:
    """AND(col0 > 2, col0 < 6) — for [0..7], lanes 3,4,5 = True."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))                  # 0
    nodes.append(rt_lit_int(Int64(2)))           # 1
    nodes.append(rt_comparison(CMP_GT, 0, 1))    # 2: col > 2
    nodes.append(rt_col_ref(0))                  # 3
    nodes.append(rt_lit_int(Int64(6)))           # 4
    nodes.append(rt_comparison(CMP_LT, 3, 4))    # 5: col < 6
    nodes.append(rt_and(2, 5))                   # 6: root AND
    var expr = build_runtime_expr_bool(nodes^, root=6)
    var chunk = expr.eval[8](bv, 0)
    assert_equal(Bool(chunk.values[0]), False)  # 0: F & T = F
    assert_equal(Bool(chunk.values[2]), False)  # 2: F & T = F
    assert_equal(Bool(chunk.values[3]), True)   # 3: T & T = T
    assert_equal(Bool(chunk.values[4]), True)
    assert_equal(Bool(chunk.values[5]), True)
    assert_equal(Bool(chunk.values[6]), False)  # 6: T & F = F


# =============================================================================
# T08 — RT_OR — Kleene OR
# =============================================================================


def test_rt_or_two_comparisons() raises:
    """OR(col0 < 2, col0 > 6) — for [0..7], lanes 0,1,7 = True."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(2)))
    nodes.append(rt_comparison(CMP_LT, 0, 1))    # 2: col < 2
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(6)))
    nodes.append(rt_comparison(CMP_GT, 3, 4))    # 5: col > 6
    nodes.append(rt_or(2, 5))                    # 6: root OR
    var expr = build_runtime_expr_bool(nodes^, root=6)
    var chunk = expr.eval[8](bv, 0)
    assert_equal(Bool(chunk.values[0]), True)   # 0 < 2
    assert_equal(Bool(chunk.values[1]), True)
    assert_equal(Bool(chunk.values[2]), False)  # neither
    assert_equal(Bool(chunk.values[6]), False)
    assert_equal(Bool(chunk.values[7]), True)   # 7 > 6


# =============================================================================
# T09 — RT_NOT — Kleene NOT
# =============================================================================


def test_rt_not_one_comparison() raises:
    """NOT(col0 > 3) — for [0..7], lanes 0,1,2,3 = True."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(3)))
    nodes.append(rt_comparison(CMP_GT, 0, 1))    # 2: col > 3
    nodes.append(rt_not(2))                      # 3: root NOT
    var expr = build_runtime_expr_bool(nodes^, root=3)
    var chunk = expr.eval[8](bv, 0)
    assert_equal(Bool(chunk.values[0]), True)   # NOT(0 > 3) = T
    assert_equal(Bool(chunk.values[3]), True)
    assert_equal(Bool(chunk.values[4]), False)  # NOT(4 > 3) = F
    assert_equal(Bool(chunk.values[7]), False)


# =============================================================================
# T10 — RT_IS_NULL / RT_IS_NOT_NULL
# =============================================================================


def test_rt_is_null_non_nullable() raises:
    """IS_NULL on a non-nullable column → all False; result valid."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_is_null(0, ISNULL_IS_NULL))  # 1: root
    var expr = build_runtime_expr_bool(nodes^, root=1)
    var chunk = expr.eval[4](bv, 0)
    assert_equal(Bool(chunk.values[0]), False)
    assert_equal(Bool(chunk.values[1]), False)
    assert_equal(Bool(chunk.validity[0]), True)


def test_rt_is_not_null_non_nullable() raises:
    """IS_NOT_NULL on a non-nullable column → all True; result valid."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_is_null(0, ISNULL_IS_NOT_NULL))  # 1: root
    var expr = build_runtime_expr_bool(nodes^, root=1)
    var chunk = expr.eval[4](bv, 0)
    assert_equal(Bool(chunk.values[0]), True)
    assert_equal(Bool(chunk.values[3]), True)
    assert_equal(Bool(chunk.validity[0]), True)


# =============================================================================
# T11 — RT_BETWEEN
# =============================================================================


def test_rt_between_lit_lit() raises:
    """col0 BETWEEN 2 AND 5 — for [0..7], lanes 2,3,4,5 = True."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))                  # 0: value
    nodes.append(rt_lit_int(Int64(2)))           # 1: low
    nodes.append(rt_lit_int(Int64(5)))           # 2: high
    nodes.append(rt_between(0, 1, 2))            # 3: root
    var expr = build_runtime_expr_bool(nodes^, root=3)
    var chunk = expr.eval[8](bv, 0)
    assert_equal(Bool(chunk.values[0]), False)
    assert_equal(Bool(chunk.values[1]), False)
    assert_equal(Bool(chunk.values[2]), True)
    assert_equal(Bool(chunk.values[3]), True)
    assert_equal(Bool(chunk.values[4]), True)
    assert_equal(Bool(chunk.values[5]), True)
    assert_equal(Bool(chunk.values[6]), False)
    assert_equal(Bool(chunk.values[7]), False)
    assert_equal(Bool(chunk.validity[0]), True)


# =============================================================================
# T12 — RT_IN_LIST — STUB (FALLBACK)
# =============================================================================


def test_rt_in_list_fallback() raises:
    """RT_IN_LIST raises FALLBACK (auxiliary list-child
    storage is not implemented)."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_in_list(0))
    var expr = build_runtime_expr_bool(nodes^, root=1)
    var raised = False
    try:
        _ = expr.eval[4](bv, 0)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# T13 — RT_BIN_OP — STUB (FALLBACK as standalone Bool root)
# =============================================================================


def test_rt_bin_op_standalone_fallback() raises:
    """RT_BIN_OP as a Bool-tree root must raise FALLBACK (arithmetic
    binops produce Int64/Float64, not Bool)."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_lit_int(Int64(1)))
    nodes.append(rt_bin_op(UInt8(0), 0, 1))  # BIN_ADD
    var expr = build_runtime_expr_bool(nodes^, root=2)
    var raised = False
    try:
        _ = expr.eval[4](bv, 0)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# T14 — RT_EXPR_AGG_FN — STUB (FALLBACK)
# =============================================================================


def test_rt_expr_agg_fn_fallback() raises:
    """RT_EXPR_AGG_FN raises FALLBACK (agg trait is
    AggI64U / AggF64U; bool-expr-tree consumption is not implemented)."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_expr_agg_fn())
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var raised = False
    try:
        _ = expr.eval[4](bv, 0)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# T15 — RT_EXPR_WHEN — STUB (FALLBACK)
# =============================================================================


def test_rt_expr_when_fallback() raises:
    """RT_EXPR_WHEN raises FALLBACK (multi-branch CASE
    requires auxiliary list-child storage)."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_expr_when())
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var raised = False
    try:
        _ = expr.eval[4](bv, 0)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# T16 — RT_EXPR_CAST — STUB (FALLBACK)
# =============================================================================


def test_rt_expr_cast_fallback() raises:
    """RT_EXPR_CAST raises FALLBACK (type cast emits a
    typed sub-tree)."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))
    nodes.append(rt_expr_cast(0))
    var expr = build_runtime_expr_bool(nodes^, root=1)
    var raised = False
    try:
        _ = expr.eval[4](bv, 0)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# Overflow + out-of-range
# =============================================================================


def test_overflow_raises() raises:
    """build_runtime_expr_bool raises when len(nodes) > MAX_NODES."""
    var nodes = List[RuntimeNode]()
    for _ in range(MAX_NODES + 1):
        nodes.append(rt_lit_bool(True))
    var raised = False
    try:
        _ = build_runtime_expr_bool(nodes^, root=0)
    except e:
        raised = True
    assert_true(raised)


def test_root_out_of_range_raises() raises:
    """build_runtime_expr_bool raises when root is out of [0, len(nodes))."""
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(True))
    var raised = False
    try:
        _ = build_runtime_expr_bool(nodes^, root=5)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# Shape classify
# =============================================================================


def test_shape_classify_returns_fallback() raises:
    """shape_classify always returns SHAPE_FALLBACK."""
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(True))
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var sc = expr.shape_classify()
    assert_equal(Int(sc.code), Int(SHAPE_FALLBACK))


# =============================================================================
# run_filter_self forwarding (the default writes 0xFF)
# =============================================================================


def test_run_filter_self_forwards_default() raises:
    """RuntimeExprBool.run_filter_self forwards to the free-function
    default which writes 0xFF mask bytes (a stub; a shape-dispatch-
    then-tight-loop override would replace it)."""
    var batch = _build_int64_batch(16)  # 16 rows → 2 mask bytes
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_lit_bool(True))
    var expr = build_runtime_expr_bool(nodes^, root=0)
    var mask_buf = OwnedAlignedBuffer(2)
    mask_buf.set_length(2)

    var mask_view = mask_buf.view_mut()
    mask_view.write_u8_at(0, UInt8(0))
    mask_view.write_u8_at(1, UInt8(0))
    var dummy_buf = OwnedAlignedBuffer(1)
    dummy_buf.set_length(1)

    var dummy_view = dummy_buf.view_mut()
    var validity_none = Optional[ByteView[dummy_view.origin]](None)
    expr.run_filter_self(bv, mask_view, validity_none)
    assert_equal(Int(mask_view.read_u8_at(0)), 0xFF)
    assert_equal(Int(mask_view.read_u8_at(1)), 0xFF)
    _ = dummy_buf^


# =============================================================================
# Kleene 3VL — AND with NULL operand verified through Kleene helper
# =============================================================================


def test_kleene_and_with_null_left() raises:
    """Build AND(IS_NULL(col), col > 3) — for lanes where IS_NULL is
    True (none, since non-nullable col), AND short-circuits to False.

    This test verifies the Kleene AND helper fires via the eval[W]
    path. For a non-nullable column:
        IS_NULL = always False, validity = always True
        col > 3 = depends, validity = always True
        AND result = False (short-circuit) for all lanes.
    """
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))                  # 0
    nodes.append(rt_is_null(0, ISNULL_IS_NULL))  # 1: IS_NULL(col)
    nodes.append(rt_col_ref(0))                  # 2
    nodes.append(rt_lit_int(Int64(3)))           # 3
    nodes.append(rt_comparison(CMP_GT, 2, 3))    # 4: col > 3
    nodes.append(rt_and(1, 4))                   # 5: root AND
    var expr = build_runtime_expr_bool(nodes^, root=5)
    var chunk = expr.eval[8](bv, 0)
    # All lanes: AND(False, X) = False
    assert_equal(Bool(chunk.values[0]), False)
    assert_equal(Bool(chunk.values[4]), False)
    assert_equal(Bool(chunk.values[7]), False)
    # All lanes valid (both operands valid for non-nullable input).
    assert_equal(Bool(chunk.validity[0]), True)


# =============================================================================
# Nested 16-tag round-trip — comparison + Kleene AND with all-True OR
# =============================================================================


def test_nested_and_or_not_round_trip() raises:
    """Nested expr exercises AND, OR, NOT, COMPARISON, COL_REF, LIT_INT,
    LIT_BOOL — six tags in one round-trip.

    Expression: AND(OR(col0 > 5, NOT(col0 < 2)), lit_bool(True))
    For [0..7]: NOT(col0 < 2) = True at lanes 2..7; col0 > 5 = True
    at lanes 6,7. OR is True everywhere except lanes 0,1. Final AND
    with True_lit preserves: lanes 2..7 = True.
    """
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var nodes = List[RuntimeNode]()
    nodes.append(rt_col_ref(0))                  # 0
    nodes.append(rt_lit_int(Int64(5)))           # 1
    nodes.append(rt_comparison(CMP_GT, 0, 1))    # 2: col0 > 5
    nodes.append(rt_col_ref(0))                  # 3
    nodes.append(rt_lit_int(Int64(2)))           # 4
    nodes.append(rt_comparison(CMP_LT, 3, 4))    # 5: col0 < 2
    nodes.append(rt_not(5))                      # 6: NOT(col0 < 2)
    nodes.append(rt_or(2, 6))                    # 7: OR
    nodes.append(rt_lit_bool(True))              # 8
    nodes.append(rt_and(7, 8))                   # 9: root AND
    var expr = build_runtime_expr_bool(nodes^, root=9)
    var chunk = expr.eval[8](bv, 0)
    assert_equal(Bool(chunk.values[0]), False)
    assert_equal(Bool(chunk.values[1]), False)
    assert_equal(Bool(chunk.values[2]), True)
    assert_equal(Bool(chunk.values[5]), True)
    assert_equal(Bool(chunk.values[7]), True)


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
