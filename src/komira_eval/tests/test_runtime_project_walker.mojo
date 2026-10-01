# =============================================================================
# Tests for `ExpressionExecutor.eval_to_list_{i64,f64}_from_view[bo]` —
# per-DType project walker.
#
# Covers the two NEW Path B (RuntimeProgram) project walker entry points
# Each method evaluates a non-bool top-level Expr
# over a filter-narrowed `RowSelectionVector` and appends typed scalar
# values into a per-DType output buffer. The leaf arms are EXPR_COL
# (passthrough) + EXPR_LIT_I64 / EXPR_LIT_F64 (literal broadcast).
#
# Test coverage (10 cases):
#   I64 walker:
#     1. Passthrough single column, identity sel (no filter)
#     2. Passthrough single column, filter-narrowed sel
#     3. Literal-broadcast (size = sel length)
#     4. Literal-broadcast with empty sel (0 outputs)
#     5. Unsupported kind raises (EXPR_GT_I64 root — comparison, not projection)
#   F64 walker:
#     6. Passthrough single column, identity sel
#     7. Passthrough single column, filter-narrowed sel
#     8. Literal-broadcast (size = sel length)
#     9. Literal-broadcast with empty sel
#    10. Unsupported kind raises (EXPR_LIT_I64 root — wrong DType)
#
# Cross-refs:
#   - Production code: komira_eval.expression_executor
#     (eval_to_list_i64_from_view + eval_to_list_f64_from_view methods)
#   - Sibling tests (filter walker): test_expression_executor_from_view.mojo
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.batch_view import BatchView, batch_view_over
from komira_eval.expression_executor import ExpressionExecutor, DecimalSpec
from komira_eval.runtime_expr import (
    RuntimeExpr,
    make_add_f64,
    make_add_i32,
    make_add_i64,
    make_col,
    make_col_string,
    make_div_f64,
    make_div_i32,
    make_div_i64,
    make_ge_i64,
    make_gt_i64,
    make_in_list,
    make_lit_bool,
    make_lit_f64,
    make_lit_i32,
    make_lit_i64,
    make_mul_f64,
    make_mul_i32,
    make_mul_i64,
    make_sub_f64,
    make_sub_i32,
    make_sub_i64,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.string_array import StringArray
from komira_eval.filter_state import FilterState
from komira_eval.selection_vector import RowSelectionVector


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _names1(s0: String) -> List[String]:
    var out = List[String]()
    out.append(s0)
    return out^


def _build_i64_batch(n: Int) raises -> RecordBatch:
    """Single-column Int64 batch with values [0, 1, ..., n-1] named 'c0'."""
    var vals0 = List[Scalar[DType.int64]]()
    for i in range(n):
        vals0.append(Scalar[DType.int64](Int64(i)))
    var arr0 = PrimitiveArray[DType.int64].from_list(vals0^)
    var schema = Schema.from_fields_1(Field("c0", DType.int64, True))
    var col0 = Column.from_primitive[DType.int64](arr0^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


def _build_f64_batch(n: Int) raises -> RecordBatch:
    """Single-column Float64 batch with values [0.0, 1.0, ..., (n-1).0]
    named 'c0'."""
    var vals0 = List[Scalar[DType.float64]]()
    for i in range(n):
        vals0.append(Scalar[DType.float64](Float64(i)))
    var arr0 = PrimitiveArray[DType.float64].from_list(vals0^)
    var schema = Schema.from_fields_1(Field("c0", DType.float64, True))
    var col0 = Column.from_primitive[DType.float64](arr0^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


def _build_i64_batch_2col(n: Int) raises -> RecordBatch:
    """Two-column Int64 batch — c0=[0..n), c1=[0..n) — for col×col arithmetic tests.
    """
    var vals0 = List[Scalar[DType.int64]]()
    var vals1 = List[Scalar[DType.int64]]()
    for i in range(n):
        vals0.append(Scalar[DType.int64](Int64(i)))
        vals1.append(Scalar[DType.int64](Int64(i)))
    var arr0 = PrimitiveArray[DType.int64].from_list(vals0^)
    var arr1 = PrimitiveArray[DType.int64].from_list(vals1^)
    var schema = Schema.from_fields_2(
        Field("c0", DType.int64, True),
        Field("c1", DType.int64, True),
    )
    var col0 = Column.from_primitive[DType.int64](arr0^)
    var col1 = Column.from_primitive[DType.int64](arr1^)
    return RecordBatch.from_typed_columns_2(schema^, col0^, col1^)


def _build_f64_batch_2col(n: Int) raises -> RecordBatch:
    """Two-column Float64 batch — c0=[0..n), c1=[0..n) — for col×col arithmetic tests.
    """
    var vals0 = List[Scalar[DType.float64]]()
    var vals1 = List[Scalar[DType.float64]]()
    for i in range(n):
        vals0.append(Scalar[DType.float64](Float64(i)))
        vals1.append(Scalar[DType.float64](Float64(i)))
    var arr0 = PrimitiveArray[DType.float64].from_list(vals0^)
    var arr1 = PrimitiveArray[DType.float64].from_list(vals1^)
    var schema = Schema.from_fields_2(
        Field("c0", DType.float64, True),
        Field("c1", DType.float64, True),
    )
    var col0 = Column.from_primitive[DType.float64](arr0^)
    var col1 = Column.from_primitive[DType.float64](arr1^)
    return RecordBatch.from_typed_columns_2(schema^, col0^, col1^)


def _build_i32_batch(n: Int) raises -> RecordBatch:
    """Single-column Int32 batch with values [0, 1, ..., n-1] named 'c0'."""
    var vals0 = List[Scalar[DType.int32]]()
    for i in range(n):
        vals0.append(Scalar[DType.int32](Int32(i)))
    var arr0 = PrimitiveArray[DType.int32].from_list(vals0^)
    var schema = Schema.from_fields_1(Field("c0", DType.int32, True))
    var col0 = Column.from_primitive[DType.int32](arr0^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


def _build_i32_batch_2col(n: Int) raises -> RecordBatch:
    """Two-column Int32 batch — c0=[0..n), c1=[0..n) — for col×col arithmetic.
    """
    var vals0 = List[Scalar[DType.int32]]()
    var vals1 = List[Scalar[DType.int32]]()
    for i in range(n):
        vals0.append(Scalar[DType.int32](Int32(i)))
        vals1.append(Scalar[DType.int32](Int32(i)))
    var arr0 = PrimitiveArray[DType.int32].from_list(vals0^)
    var arr1 = PrimitiveArray[DType.int32].from_list(vals1^)
    var schema = Schema.from_fields_2(
        Field("c0", DType.int32, True),
        Field("c1", DType.int32, True),
    )
    var col0 = Column.from_primitive[DType.int32](arr0^)
    var col1 = Column.from_primitive[DType.int32](arr1^)
    return RecordBatch.from_typed_columns_2(schema^, col0^, col1^)


def _build_string_batch_4() raises -> RecordBatch:
    """Single-column String batch with values ['a', 'b', 'c', 'd'] named 'c0'."""
    var vals = List[String]()
    vals.append("a")
    vals.append("b")
    vals.append("c")
    vals.append("d")
    var arr = StringArray.from_strings(vals^)
    var schema = Schema.from_fields_1(Field("c0", ArrowType.STRING, True))
    var col = Column.from_string(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _make_identity_sel(n: Int) -> RowSelectionVector:
    """Build an identity RowSelectionVector [0, 1, ..., n-1]."""
    var sel = RowSelectionVector()
    var i = 0
    while i < n:
        sel.append(UInt32(i))
        i = i + 1
    return sel^


# =============================================================================
# I64 walker tests
# =============================================================================


def test_i64_passthrough_identity_sel() raises:
    """`project(col("c0"))` over a 256-row Int64 batch with identity sel.

    Output list MUST contain 256 values equal to [0, 1, ..., 255].
    """
    # Pool: just a single EXPR_COL node.
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # slot 0: EXPR_COL referring to column_names[0]
    # ExpressionExecutor's __init__ allocates state tree starting at root_idx.
    # For project, root_idx is the project expression's pool slot (0 here).
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_i64_batch(256)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(256)

    var out = List[Scalar[DType.int64]]()
    exec_.eval_to_list_i64_from_view(view, 0, sel, out)

    assert_equal(len(out), 256, "passthrough-identity: 256 outputs")
    for i in range(256):
        assert_equal(
            out[i],
            Scalar[DType.int64](Int64(i)),
            "passthrough-identity: out[" + String(i) + "] = " + String(i),
        )


def test_i64_passthrough_filter_narrowed_sel() raises:
    """`project(col("c0"))` over a 1024-row Int64 batch with sel from
    `select_expression_from_view(c0 >= 500)`.

    Output list MUST contain 524 values equal to [500, 501, ..., 1023].
    """
    # Build TWO executors — one for filter, one for project (each owns its
    # pool and column_names via take-once).
    var pool_filter = List[RuntimeExpr]()
    pool_filter.append(make_col(0))                # 0
    pool_filter.append(make_lit_i64(Int64(500)))   # 1
    pool_filter.append(make_ge_i64(0, 1))          # 2 (root)
    var exec_filter = ExpressionExecutor(pool_filter^, 2, _names1("c0"))

    var pool_project = List[RuntimeExpr]()
    pool_project.append(make_col(0))               # 0 (root)
    var exec_project = ExpressionExecutor(pool_project^, 0, _names1("c0"))

    var batch = _build_i64_batch(1024)
    var view = batch_view_over(batch)

    # Run filter to populate fs.sel.
    var fs = FilterState.with_conjunction(n_predicates=1, worker_id=0)
    _ = exec_filter.select_expression_from_view(view, fs)
    assert_equal(fs.sel.len(), 524, "filter-narrowed: 524 survivors")

    # Run project, gathering from the narrowed selection.
    var out = List[Scalar[DType.int64]]()
    exec_project.eval_to_list_i64_from_view(view, 0, fs.sel, out)

    assert_equal(len(out), 524, "passthrough-filtered: 524 outputs")
    for k in range(524):
        assert_equal(
            out[k],
            Scalar[DType.int64](Int64(500 + k)),
            "passthrough-filtered: out[" + String(k) + "] = "
            + String(500 + k),
        )


def test_i64_literal_broadcast() raises:
    """`project(lit(42))` over a 256-row batch with identity sel.

    Output list MUST contain 256 copies of 42.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(42)))  # 0 (root)
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())  # no col refs

    var batch = _build_i64_batch(256)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(256)

    var out = List[Scalar[DType.int64]]()
    exec_.eval_to_list_i64_from_view(view, 0, sel, out)

    assert_equal(len(out), 256, "lit-broadcast: 256 outputs")
    for i in range(256):
        assert_equal(
            out[i],
            Scalar[DType.int64](Int64(42)),
            "lit-broadcast: out[" + String(i) + "] = 42",
        )


def test_i64_literal_broadcast_empty_sel() raises:
    """`project(lit(99))` with empty selection vector. Output MUST be empty."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(99)))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_i64_batch(256)
    var view = batch_view_over(batch)
    var sel = RowSelectionVector()  # empty (len = 0)

    var out = List[Scalar[DType.int64]]()
    exec_.eval_to_list_i64_from_view(view, 0, sel, out)

    assert_equal(len(out), 0, "lit-broadcast-empty: 0 outputs")


def test_i64_unsupported_kind_raises() raises:
    """`eval_to_list_i64_from_view` on a root with EXPR_GT_I64 (a comparison,
    not a projection) MUST raise.

    Comparison Expr kinds belong in the bool walker; if a planner mis-routes them into
    a project walker, we want the executor to fail loudly.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))               # 0
    pool.append(make_lit_i64(Int64(5)))    # 1
    pool.append(make_gt_i64(0, 1))         # 2 (root: comparison)
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_i64_batch(64)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(64)

    var out = List[Scalar[DType.int64]]()
    var raised = False
    try:
        exec_.eval_to_list_i64_from_view(view, 2, sel, out)
    except e:
        raised = True
    assert_true(raised, "unsupported-kind-i64: expected raise")


# =============================================================================
# F64 walker tests
# =============================================================================


def test_f64_passthrough_identity_sel() raises:
    """`project(col("c0"))` over a 256-row Float64 batch with identity sel.

    Output MUST contain 256 values equal to [0.0, 1.0, ..., 255.0].
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_f64_batch(256)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(256)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 0, sel, out)

    assert_equal(len(out), 256, "f64-passthrough-identity: 256 outputs")
    for i in range(256):
        assert_equal(
            out[i],
            Scalar[DType.float64](Float64(i)),
            "f64-passthrough-identity: out[" + String(i) + "]",
        )


def test_f64_passthrough_filter_narrowed_sel() raises:
    """`project(col("c0"))` over Float64 batch with sel narrowed by a
    parallel-built Int64 filter executor.

    NOTE: we filter on an Int64 batch (since the filter walker
    supports Int64 comparison out of the box), then use the resulting
    `RowSelectionVector` to gather rows from the F64 batch. This mirrors
    the multi-DType-batch flow that real plans see — the sel is a row-
    index vector, agnostic to per-column DType.
    """
    var pool_filter = List[RuntimeExpr]()
    pool_filter.append(make_col(0))
    pool_filter.append(make_lit_i64(Int64(800)))
    pool_filter.append(make_ge_i64(0, 1))
    var exec_filter = ExpressionExecutor(pool_filter^, 2, _names1("c0"))

    var pool_project = List[RuntimeExpr]()
    pool_project.append(make_col(0))
    var exec_project = ExpressionExecutor(pool_project^, 0, _names1("c0"))

    var batch_i64 = _build_i64_batch(1024)
    var batch_f64 = _build_f64_batch(1024)
    var view_i64 = batch_view_over(batch_i64)
    var view_f64 = batch_view_over(batch_f64)

    var fs = FilterState.with_conjunction(n_predicates=1, worker_id=0)
    _ = exec_filter.select_expression_from_view(view_i64, fs)
    assert_equal(fs.sel.len(), 224, "f64-filter: 224 survivors (1024 - 800)")

    var out = List[Scalar[DType.float64]]()
    exec_project.eval_to_list_f64_from_view(view_f64, 0, fs.sel, out)

    assert_equal(len(out), 224, "f64-passthrough-filtered: 224 outputs")
    for k in range(224):
        assert_equal(
            out[k],
            Scalar[DType.float64](Float64(800 + k)),
            "f64-passthrough-filtered: out[" + String(k) + "]",
        )


def test_f64_literal_broadcast() raises:
    """`project(lit(3.14))` over a 128-row batch with identity sel."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_f64(Float64(3.14)))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_f64_batch(128)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(128)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 0, sel, out)

    assert_equal(len(out), 128, "f64-lit-broadcast: 128 outputs")
    for i in range(128):
        assert_equal(
            out[i],
            Scalar[DType.float64](Float64(3.14)),
            "f64-lit-broadcast: out[" + String(i) + "] = 3.14",
        )


def test_f64_literal_broadcast_empty_sel() raises:
    """`project(lit(1.5))` with empty sel. Output MUST be empty."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_f64(Float64(1.5)))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_f64_batch(128)
    var view = batch_view_over(batch)
    var sel = RowSelectionVector()

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 0, sel, out)

    assert_equal(len(out), 0, "f64-lit-broadcast-empty: 0 outputs")


def test_f64_unsupported_kind_raises() raises:
    """`eval_to_list_f64_from_view` on a root with a comparison kind MUST raise.

    NOTE: an EXPR_LIT_I64 root is a SUPPORTED widening arm in the F64
    walker (an i64 literal/arith root feeding the F64 agg channel widens to
    Float64 via `Float64(node.i64)` rather than raising — see
    `expression_executor.mojo` EXPR_LIT_I64 arm), so it cannot serve here.
    The guard intent — that a genuinely-unsupported kind raises cleanly
    instead of silently mishandling — is preserved here by using a
    comparison (boolean-producing) kind, EXPR_GT_I64, which the F64 VALUE
    walker does not (and should not) handle: a predicate node has no place
    as the root of a numeric projection.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(7)))  # 0
    pool.append(make_lit_i64(Int64(3)))  # 1
    pool.append(make_gt_i64(0, 1))       # 2 (root, EXPR_GT_I64 — unsupported)
    var exec_ = ExpressionExecutor(pool^, 2, List[String]())

    var batch = _build_f64_batch(64)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(64)

    var out = List[Scalar[DType.float64]]()
    var raised = False
    try:
        exec_.eval_to_list_f64_from_view(view, 2, sel, out)
    except e:
        raised = True
    assert_true(raised, "unsupported-kind-f64: expected raise")


# =============================================================================
# I64 arithmetic walker tests
# =============================================================================


def test_i64_add_lit_lit() raises:
    """`project(lit(5) + lit(3))` over identity sel of length 4 ⇒ [8, 8, 8, 8]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(5)))   # 0
    pool.append(make_lit_i64(Int64(3)))   # 1
    pool.append(make_add_i64(0, 1))       # 2 (root)
    var exec_ = ExpressionExecutor(pool^, 2, List[String]())

    var batch = _build_i64_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.int64]]()
    exec_.eval_to_list_i64_from_view(view, 2, sel, out)

    assert_equal(len(out), 4, "i64-add-lit-lit: 4 outputs")
    for i in range(4):
        assert_equal(
            out[i], Scalar[DType.int64](Int64(8)),
            "i64-add-lit-lit: out[" + String(i) + "] = 8",
        )


def test_i64_sub_col_lit() raises:
    """`project(col(c0) - lit(10))` over 256-row [0..256) ⇒ [-10, -9, ..., 245]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))               # 0
    pool.append(make_lit_i64(Int64(10)))   # 1
    pool.append(make_sub_i64(0, 1))        # 2 (root)
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_i64_batch(256)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(256)

    var out = List[Scalar[DType.int64]]()
    exec_.eval_to_list_i64_from_view(view, 2, sel, out)

    assert_equal(len(out), 256, "i64-sub-col-lit: 256 outputs")
    for i in range(256):
        assert_equal(
            out[i], Scalar[DType.int64](Int64(i - 10)),
            "i64-sub-col-lit: out[" + String(i) + "] = " + String(i - 10),
        )


def test_i64_mul_col_col() raises:
    """`project(col(c0) * col(c1))` on 16-row [0..16) ⇒ [i*i for i in 0..16)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))         # 0 (c0)
    pool.append(make_col(1))         # 1 (c1)
    pool.append(make_mul_i64(0, 1))  # 2 (root)
    var names = List[String]()
    names.append("c0")
    names.append("c1")
    var exec_ = ExpressionExecutor(pool^, 2, names^)

    var batch = _build_i64_batch_2col(16)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(16)

    var out = List[Scalar[DType.int64]]()
    exec_.eval_to_list_i64_from_view(view, 2, sel, out)

    assert_equal(len(out), 16, "i64-mul-col-col: 16 outputs")
    for i in range(16):
        assert_equal(
            out[i], Scalar[DType.int64](Int64(i * i)),
            "i64-mul-col-col: out[" + String(i) + "] = " + String(i * i),
        )


def test_i64_div_col_lit_truncates() raises:
    """`project(col(c0) // lit(2))` over [0..8) ⇒ [0, 0, 1, 1, 2, 2, 3, 3]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))               # 0
    pool.append(make_lit_i64(Int64(2)))    # 1
    pool.append(make_div_i64(0, 1))        # 2 (root)
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_i64_batch(8)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(8)

    var out = List[Scalar[DType.int64]]()
    exec_.eval_to_list_i64_from_view(view, 2, sel, out)

    assert_equal(len(out), 8, "i64-div-col-lit: 8 outputs")
    var expected = List[Int64]()
    expected.append(0)
    expected.append(0)
    expected.append(1)
    expected.append(1)
    expected.append(2)
    expected.append(2)
    expected.append(3)
    expected.append(3)
    for i in range(8):
        assert_equal(
            out[i], Scalar[DType.int64](expected[i]),
            "i64-div-col-lit: out[" + String(i) + "] = "
            + String(expected[i]),
        )


def test_i64_div_by_zero_raises() raises:
    """`project(col(c0) // lit(0))` over identity sel MUST raise on the FIRST row.

    Int division by zero is a hard error (DuckDB
    integer-divide convention).
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))               # 0
    pool.append(make_lit_i64(Int64(0)))    # 1
    pool.append(make_div_i64(0, 1))        # 2 (root)
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_i64_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.int64]]()
    var raised = False
    try:
        exec_.eval_to_list_i64_from_view(view, 2, sel, out)
    except e:
        raised = True
    assert_true(raised, "i64-div-by-zero: expected raise")


# =============================================================================
# F64 arithmetic walker tests
# =============================================================================


def test_f64_add_lit_lit() raises:
    """`project(lit(1.5) + lit(2.5))` over identity sel of length 4 ⇒ [4.0]*4."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_f64(Float64(1.5)))
    pool.append(make_lit_f64(Float64(2.5)))
    pool.append(make_add_f64(0, 1))
    var exec_ = ExpressionExecutor(pool^, 2, List[String]())

    var batch = _build_f64_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 2, sel, out)

    assert_equal(len(out), 4, "f64-add-lit-lit: 4 outputs")
    for i in range(4):
        assert_equal(
            out[i], Scalar[DType.float64](Float64(4.0)),
            "f64-add-lit-lit: out[" + String(i) + "] = 4.0",
        )


def test_f64_sub_col_lit() raises:
    """`project(col(c0) - lit(0.5))` over [0..256) ⇒ [i - 0.5 for i ...]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_f64(Float64(0.5)))
    pool.append(make_sub_f64(0, 1))
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_f64_batch(256)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(256)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 2, sel, out)

    assert_equal(len(out), 256, "f64-sub-col-lit: 256 outputs")
    for i in range(256):
        assert_equal(
            out[i], Scalar[DType.float64](Float64(i) - Float64(0.5)),
            "f64-sub-col-lit: out[" + String(i) + "]",
        )


def test_f64_mul_col_col() raises:
    """`project(col(c0) * col(c1))` on 16-row [0..16) ⇒ [i*i for ...]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))         # 0 c0
    pool.append(make_col(1))         # 1 c1
    pool.append(make_mul_f64(0, 1))  # 2 root
    var names = List[String]()
    names.append("c0")
    names.append("c1")
    var exec_ = ExpressionExecutor(pool^, 2, names^)

    var batch = _build_f64_batch_2col(16)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(16)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 2, sel, out)

    assert_equal(len(out), 16, "f64-mul-col-col: 16 outputs")
    for i in range(16):
        assert_equal(
            out[i], Scalar[DType.float64](Float64(i) * Float64(i)),
            "f64-mul-col-col: out[" + String(i) + "]",
        )


def test_f64_div_col_lit_halves() raises:
    """`project(col(c0) / lit(2.0))` on [0..8) ⇒ [0.0, 0.5, 1.0, ...]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_f64(Float64(2.0)))
    pool.append(make_div_f64(0, 1))
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_f64_batch(8)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(8)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 2, sel, out)

    assert_equal(len(out), 8, "f64-div-col-lit: 8 outputs")
    for i in range(8):
        assert_equal(
            out[i], Scalar[DType.float64](Float64(i) / Float64(2.0)),
            "f64-div-col-lit: out[" + String(i) + "]",
        )


def test_f64_div_by_zero_no_raise() raises:
    """`project(lit(1.0) / lit(0.0))` MUST NOT raise — IEEE-754 produces +Inf.

    F64 div-by-zero is IEEE-754 default; matches DuckDB
    DOUBLE + Polars Float64 conventions.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_f64(Float64(1.0)))
    pool.append(make_lit_f64(Float64(0.0)))
    pool.append(make_div_f64(0, 1))
    var exec_ = ExpressionExecutor(pool^, 2, List[String]())

    var batch = _build_f64_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.float64]]()
    # MUST NOT raise.
    exec_.eval_to_list_f64_from_view(view, 2, sel, out)
    assert_equal(len(out), 4, "f64-div-by-zero: 4 outputs (no raise)")
    # +Inf check: lhs > 0, rhs == +0.0 ⇒ +Inf in IEEE-754. We avoid a
    # bit-pattern compare and instead verify the value is greater than any
    # finite Float64 we can represent.
    for i in range(4):
        # Simple property: +Inf > 1e308 (well below DBL_MAX).
        assert_true(
            out[i] > Scalar[DType.float64](Float64(1.0e308)),
            "f64-div-by-zero: out[" + String(i) + "] should be +Inf",
        )


# =============================================================================
# Int32 walker tests
# =============================================================================


def test_i32_passthrough_identity_sel() raises:
    """`project(col("c0"))` over a 64-row Int32 batch with identity sel."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_i32_batch(64)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(64)

    var out = List[Scalar[DType.int32]]()
    exec_.eval_to_list_i32_from_view(view, 0, sel, out)

    assert_equal(len(out), 64, "i32-passthrough-identity: 64 outputs")
    for i in range(64):
        assert_equal(
            out[i], Scalar[DType.int32](Int32(i)),
            "i32-passthrough-identity: out[" + String(i) + "]",
        )


def test_i32_passthrough_filter_narrowed_sel() raises:
    """Manually-built sel over I32 batch: gather rows [10, 20, 30]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_i32_batch(64)
    var view = batch_view_over(batch)
    var sel = RowSelectionVector()
    sel.append(UInt32(10))
    sel.append(UInt32(20))
    sel.append(UInt32(30))

    var out = List[Scalar[DType.int32]]()
    exec_.eval_to_list_i32_from_view(view, 0, sel, out)

    assert_equal(len(out), 3, "i32-passthrough-filter: 3 outputs")
    assert_equal(out[0], Scalar[DType.int32](Int32(10)), "i32 out[0] = 10")
    assert_equal(out[1], Scalar[DType.int32](Int32(20)), "i32 out[1] = 20")
    assert_equal(out[2], Scalar[DType.int32](Int32(30)), "i32 out[2] = 30")


def test_i32_literal_broadcast() raises:
    """`project(lit_i32(7))` over identity sel of length 4 ⇒ [7, 7, 7, 7]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i32(Int32(7)))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_i32_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.int32]]()
    exec_.eval_to_list_i32_from_view(view, 0, sel, out)

    assert_equal(len(out), 4, "i32-lit-broadcast: 4 outputs")
    for i in range(4):
        assert_equal(
            out[i], Scalar[DType.int32](Int32(7)),
            "i32-lit-broadcast: out[" + String(i) + "] = 7",
        )


def test_i32_unsupported_kind_raises() raises:
    """I32 walker on EXPR_GT_I64 root MUST raise (no comparison projection)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_i64(Int64(5)))
    pool.append(make_gt_i64(0, 1))
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_i32_batch(8)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(8)

    var out = List[Scalar[DType.int32]]()
    var raised = False
    try:
        exec_.eval_to_list_i32_from_view(view, 2, sel, out)
    except e:
        raised = True
    assert_true(raised, "i32-unsupported: expected raise")


# =============================================================================
# I32 arithmetic
# walker tests. Mirror of the I64 arithmetic test patterns above.
# =============================================================================


def test_i32_add_lit_lit() raises:
    """`project(lit(5) + lit(3))` over identity sel of length 4 ⇒ [8]*4."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i32(Int32(5)))   # 0
    pool.append(make_lit_i32(Int32(3)))   # 1
    pool.append(make_add_i32(0, 1))       # 2 (root)
    var exec_ = ExpressionExecutor(pool^, 2, List[String]())

    var batch = _build_i32_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.int32]]()
    exec_.eval_to_list_i32_from_view(view, 2, sel, out)

    assert_equal(len(out), 4, "i32-add-lit-lit: 4 outputs")
    for i in range(4):
        assert_equal(
            out[i], Scalar[DType.int32](Int32(8)),
            "i32-add-lit-lit: out[" + String(i) + "] = 8",
        )


def test_i32_sub_col_lit() raises:
    """`project(col(c0) - lit(10))` over 64-row [0..64) ⇒ [-10..54)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))               # 0
    pool.append(make_lit_i32(Int32(10)))   # 1
    pool.append(make_sub_i32(0, 1))        # 2 (root)
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_i32_batch(64)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(64)

    var out = List[Scalar[DType.int32]]()
    exec_.eval_to_list_i32_from_view(view, 2, sel, out)

    assert_equal(len(out), 64, "i32-sub-col-lit: 64 outputs")
    for i in range(64):
        assert_equal(
            out[i], Scalar[DType.int32](Int32(i - 10)),
            "i32-sub-col-lit: out[" + String(i) + "] = " + String(i - 10),
        )


def test_i32_mul_col_col() raises:
    """`project(col(c0) * col(c1))` on 8-row [0..8) ⇒ [i*i for i in 0..8)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))         # 0 (c0)
    pool.append(make_col(1))         # 1 (c1)
    pool.append(make_mul_i32(0, 1))  # 2 (root)
    var names = List[String]()
    names.append("c0")
    names.append("c1")
    var exec_ = ExpressionExecutor(pool^, 2, names^)

    var batch = _build_i32_batch_2col(8)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(8)

    var out = List[Scalar[DType.int32]]()
    exec_.eval_to_list_i32_from_view(view, 2, sel, out)

    assert_equal(len(out), 8, "i32-mul-col-col: 8 outputs")
    for i in range(8):
        assert_equal(
            out[i], Scalar[DType.int32](Int32(i * i)),
            "i32-mul-col-col: out[" + String(i) + "] = " + String(i * i),
        )


def test_i32_div_by_zero_raises() raises:
    """`project(col(c0) // lit(0))` over identity sel MUST raise.

    Int32 division by zero is a hard error, mirroring Int64 + DuckDB
    integer-divide convention.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))               # 0
    pool.append(make_lit_i32(Int32(0)))    # 1
    pool.append(make_div_i32(0, 1))        # 2 (root)
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var batch = _build_i32_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.int32]]()
    var raised = False
    try:
        exec_.eval_to_list_i32_from_view(view, 2, sel, out)
    except e:
        raised = True
    assert_true(raised, "i32-div-by-zero: expected raise")


# =============================================================================
# String walker tests
# =============================================================================


def test_string_passthrough_identity_sel() raises:
    """`project(col("c0"))` over String batch ['a','b','c','d'] identity sel."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_string_batch_4()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[String]()
    exec_.eval_to_list_string_from_view(view, 0, sel, out)

    assert_equal(len(out), 4, "string-passthrough-identity: 4 outputs")
    assert_equal(out[0], String("a"), "string out[0]")
    assert_equal(out[1], String("b"), "string out[1]")
    assert_equal(out[2], String("c"), "string out[2]")
    assert_equal(out[3], String("d"), "string out[3]")


def test_string_passthrough_filter_narrowed_sel() raises:
    """String walker with sel=[1, 3] over ['a','b','c','d'] ⇒ ['b','d']."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_string_batch_4()
    var view = batch_view_over(batch)
    var sel = RowSelectionVector()
    sel.append(UInt32(1))
    sel.append(UInt32(3))

    var out = List[String]()
    exec_.eval_to_list_string_from_view(view, 0, sel, out)

    assert_equal(len(out), 2, "string-passthrough-filter: 2 outputs")
    assert_equal(out[0], String("b"), "string-filter out[0]")
    assert_equal(out[1], String("d"), "string-filter out[1]")


def test_string_unsupported_kind_raises() raises:
    """String walker on EXPR_LIT_I64 root MUST raise (EXPR_COL only)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(7)))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_string_batch_4()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[String]()
    var raised = False
    try:
        exec_.eval_to_list_string_from_view(view, 0, sel, out)
    except e:
        raised = True
    assert_true(raised, "string-unsupported: expected raise")


# =============================================================================
# F32 walker tests
# =============================================================================


def _build_f32_batch(n: Int) raises -> RecordBatch:
    """Single-column Float32 batch with values [0.0, 1.0, ..., (n-1).0]."""
    var vals = List[Scalar[DType.float32]]()
    for i in range(n):
        vals.append(Scalar[DType.float32](Float32(Float64(i))))
    var arr = PrimitiveArray[DType.float32].from_list(vals^)
    var schema = Schema.from_fields_1(Field("c0", DType.float32, True))
    var col = Column.from_primitive[DType.float32](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def test_f32_passthrough_identity_sel() raises:
    """F32 walker passthrough with identity sel — 4-row [0.0, 1.0, 2.0, 3.0]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_f32_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.float32]]()
    exec_.eval_to_list_f32_from_view(view, 0, sel, out)

    assert_equal(len(out), 4, "f32-passthrough-identity: 4 outputs")
    for i in range(4):
        assert_equal(
            Float32(out[i]),
            Float32(Float64(i)),
            "f32 out[" + String(i) + "] matches",
        )


def test_f32_passthrough_filter_narrowed_sel() raises:
    """F32 walker with sel=[1,3] over [0.0,1.0,2.0,3.0] ⇒ [1.0, 3.0]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_f32_batch(4)
    var view = batch_view_over(batch)
    var sel = RowSelectionVector()
    sel.append(UInt32(1))
    sel.append(UInt32(3))

    var out = List[Scalar[DType.float32]]()
    exec_.eval_to_list_f32_from_view(view, 0, sel, out)

    assert_equal(len(out), 2, "f32-passthrough-filter: 2 outputs")
    assert_equal(Float32(out[0]), Float32(1.0), "f32-filter out[0]=1.0")
    assert_equal(Float32(out[1]), Float32(3.0), "f32-filter out[1]=3.0")


def test_f32_unsupported_kind_raises() raises:
    """F32 walker on EXPR_LIT_I64 root MUST raise (EXPR_COL only)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(7)))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_f32_batch(4)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.float32]]()
    var raised = False
    try:
        exec_.eval_to_list_f32_from_view(view, 0, sel, out)
    except e:
        raised = True
    assert_true(raised, "f32-unsupported: expected raise on non-COL root")


# =============================================================================
# Bool walker tests
# =============================================================================


def _build_bool_batch_4() raises -> RecordBatch:
    """Single-column Boolean batch ⇒ [True, False, True, False]."""
    var arr = BooleanArray.allocate(4)
    arr.set(0, True)
    arr.set(1, False)
    arr.set(2, True)
    arr.set(3, False)
    var schema = Schema.from_fields_1(Field("c0", ArrowType.BOOL, True))
    var col = Column.from_boolean(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def test_bool_passthrough_identity_sel() raises:
    """Bool walker passthrough with identity sel over [T,F,T,F]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_bool_batch_4()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Bool]()
    exec_.eval_to_list_bool_from_view(view, 0, sel, out)

    assert_equal(len(out), 4, "bool-passthrough-identity: 4 outputs")
    assert_true(out[0], "bool out[0]=True")
    assert_true(not out[1], "bool out[1]=False")
    assert_true(out[2], "bool out[2]=True")
    assert_true(not out[3], "bool out[3]=False")


def test_bool_passthrough_filter_narrowed_sel() raises:
    """Bool walker with sel=[1,2] over [T,F,T,F] ⇒ [F, T]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_bool_batch_4()
    var view = batch_view_over(batch)
    var sel = RowSelectionVector()
    sel.append(UInt32(1))
    sel.append(UInt32(2))

    var out = List[Bool]()
    exec_.eval_to_list_bool_from_view(view, 0, sel, out)

    assert_equal(len(out), 2, "bool-passthrough-filter: 2 outputs")
    assert_true(not out[0], "bool-filter out[0]=False (was idx 1)")
    assert_true(out[1], "bool-filter out[1]=True (was idx 2)")


def test_bool_literal_broadcast() raises:
    """Bool walker on EXPR_LIT_BOOL(True) broadcasts to sel.len() copies."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_bool(True))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_bool_batch_4()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Bool]()
    exec_.eval_to_list_bool_from_view(view, 0, sel, out)

    assert_equal(len(out), 4, "bool-lit-broadcast: 4 outputs")
    for i in range(4):
        assert_true(out[i], "bool-lit out[" + String(i) + "]=True")


def test_bool_unsupported_kind_raises() raises:
    """Bool walker on EXPR_LIT_I64 root MUST raise (only EXPR_COL +
    EXPR_LIT_BOOL supported)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(7)))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_bool_batch_4()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Bool]()
    var raised = False
    try:
        exec_.eval_to_list_bool_from_view(view, 0, sel, out)
    except e:
        raised = True
    assert_true(raised, "bool-unsupported: expected raise on EXPR_LIT_I64")


# =============================================================================
# EXPR_IN_LIST
# as a Bool-PRODUCING projection. The CSE pass hoists q19's OR-common IN_LIST
# subtrees (`l_shipmode IN (...)`, `p_container IN (...)`) into a `_cse_*`
# BOOL projection; the bool-view walker previously raised "unsupported node
# kind 55". These tests drive `eval_to_list_bool_from_view` (BOTH overloads)
# directly on an EXPR_IN_LIST node and assert no-raise + per-row membership.
# =============================================================================


def _build_shipmode_batch() raises -> RecordBatch:
    """Single-column String batch mirroring q19's `l_shipmode` domain:
    ['AIR', 'REG AIR', 'MAIL', 'SHIP', 'TRUCK', 'AIR'] named 'c0'."""
    var vals = List[String]()
    vals.append("AIR")
    vals.append("REG AIR")
    vals.append("MAIL")
    vals.append("SHIP")
    vals.append("TRUCK")
    vals.append("AIR")
    var arr = StringArray.from_strings(vals^)
    var schema = Schema.from_fields_1(Field("c0", ArrowType.STRING, True))
    var col = Column.from_string(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _shipmode_in_list() -> List[List[ScalarValue]]:
    """`in_list_pool` carrying a single entry = {'AIR', 'REG AIR'} at slot 0."""
    var entry = List[ScalarValue]()
    entry.append(ScalarValue.from_string(String("AIR")))
    entry.append(ScalarValue.from_string(String("REG AIR")))
    var pool = List[List[ScalarValue]]()
    pool.append(entry^)
    return pool^


def test_in_list_bool_string_identity_sel() raises:
    """`l_shipmode IN ('AIR','REG AIR')` as a Bool projection over identity sel.

    Drives the `List[Bool]` overload. The bool-view walker MUST NOT raise
    (the kind-55 gap) and MUST emit per-row membership:
    [AIR, REG AIR, MAIL, SHIP, TRUCK, AIR] ⇒ [T, T, F, F, F, T].
    """
    # Pool: slot 0 = EXPR_COL_STRING child, slot 1 = EXPR_IN_LIST root
    # (in_list_pool index 0).
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))   # 0: STRING column-leaf
    pool.append(make_in_list(0, 0))   # 1 (root): IN_LIST over slot-0, pool 0
    var exec_ = ExpressionExecutor(
        pool^, 1, _names1("c0"),
        List[String](),
        List[DecimalSpec](),
        _shipmode_in_list(),
    )

    var batch = _build_shipmode_batch()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(6)

    var out = List[Bool]()
    # MUST NOT raise "unsupported node kind 55".
    exec_.eval_to_list_bool_from_view(view, 1, sel, out)

    assert_equal(len(out), 6, "in-list-bool-string: 6 outputs")
    assert_true(out[0], "in-list out[0]=AIR -> True")
    assert_true(out[1], "in-list out[1]=REG AIR -> True")
    assert_true(not out[2], "in-list out[2]=MAIL -> False")
    assert_true(not out[3], "in-list out[3]=SHIP -> False")
    assert_true(not out[4], "in-list out[4]=TRUCK -> False")
    assert_true(out[5], "in-list out[5]=AIR -> True")


def test_in_list_bool_string_filter_narrowed_sel() raises:
    """Same IN_LIST over a narrowed sel=[1,2,5] ⇒ [REG AIR, MAIL, AIR]
    ⇒ [T, F, T]. Confirms the per-row mask is emitted in `sel` order."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))
    pool.append(make_in_list(0, 0))
    var exec_ = ExpressionExecutor(
        pool^, 1, _names1("c0"),
        List[String](),
        List[DecimalSpec](),
        _shipmode_in_list(),
    )

    var batch = _build_shipmode_batch()
    var view = batch_view_over(batch)
    var sel = RowSelectionVector()
    sel.append(UInt32(1))
    sel.append(UInt32(2))
    sel.append(UInt32(5))

    var out = List[Bool]()
    exec_.eval_to_list_bool_from_view(view, 1, sel, out)

    assert_equal(len(out), 3, "in-list-bool-filter: 3 outputs")
    assert_true(out[0], "in-list-filter out[0]=REG AIR -> True")
    assert_true(not out[1], "in-list-filter out[1]=MAIL -> False")
    assert_true(out[2], "in-list-filter out[2]=AIR -> True")


def test_in_list_bool_scalar_overload_string() raises:
    """Same IN_LIST but driving the `List[Scalar[DType.bool]]` overload
    (the second `eval_to_list_bool_from_view` at expression_executor.mojo
    :3484). Identity sel ⇒ [T, T, F, F, F, T]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))
    pool.append(make_in_list(0, 0))
    var exec_ = ExpressionExecutor(
        pool^, 1, _names1("c0"),
        List[String](),
        List[DecimalSpec](),
        _shipmode_in_list(),
    )

    var batch = _build_shipmode_batch()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(6)

    var out = List[Scalar[DType.bool]]()
    exec_.eval_to_list_bool_from_view(view, 1, sel, out)

    assert_equal(len(out), 6, "in-list-bool-scalar: 6 outputs")
    assert_true(Bool(out[0]), "scalar in-list out[0]=AIR -> True")
    assert_true(Bool(out[1]), "scalar in-list out[1]=REG AIR -> True")
    assert_true(not Bool(out[2]), "scalar in-list out[2]=MAIL -> False")
    assert_true(not Bool(out[3]), "scalar in-list out[3]=SHIP -> False")
    assert_true(not Bool(out[4]), "scalar in-list out[4]=TRUCK -> False")
    assert_true(Bool(out[5]), "scalar in-list out[5]=AIR -> True")


def test_in_list_bool_i64_membership() raises:
    """`c0 IN (1, 3)` over an I64 column [0..6) ⇒ [F, T, F, T, F, F].

    Confirms the IN_LIST arm dispatches on the child column's DType (INT64
    here), not just STRING — the bool-view walker is generic over the child
    column dtype (mirrors the scalar `_eval_in_list_typed` per-DType arms).
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))          # 0: INT64 column-leaf
    pool.append(make_in_list(0, 0))   # 1 (root)
    var entry = List[ScalarValue]()
    entry.append(ScalarValue.from_int(1))
    entry.append(ScalarValue.from_int(3))
    var in_list_pool = List[List[ScalarValue]]()
    in_list_pool.append(entry^)
    var exec_ = ExpressionExecutor(
        pool^, 1, _names1("c0"),
        List[String](),
        List[DecimalSpec](),
        in_list_pool^,
    )

    var batch = _build_i64_batch(6)
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(6)

    var out = List[Bool]()
    exec_.eval_to_list_bool_from_view(view, 1, sel, out)

    assert_equal(len(out), 6, "in-list-bool-i64: 6 outputs")
    assert_true(not out[0], "i64 in-list out[0]=0 -> False")
    assert_true(out[1], "i64 in-list out[1]=1 -> True")
    assert_true(not out[2], "i64 in-list out[2]=2 -> False")
    assert_true(out[3], "i64 in-list out[3]=3 -> True")
    assert_true(not out[4], "i64 in-list out[4]=4 -> False")
    assert_true(not out[5], "i64 in-list out[5]=5 -> False")


def test_in_list_bool_empty_list_all_false() raises:
    """`c0 IN ()` (K=0) ⇒ every row False. SQL `x IN ()` semantics."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))
    pool.append(make_in_list(0, 0))
    var empty_entry = List[ScalarValue]()
    var in_list_pool = List[List[ScalarValue]]()
    in_list_pool.append(empty_entry^)
    var exec_ = ExpressionExecutor(
        pool^, 1, _names1("c0"),
        List[String](),
        List[DecimalSpec](),
        in_list_pool^,
    )

    var batch = _build_shipmode_batch()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(6)

    var out = List[Bool]()
    exec_.eval_to_list_bool_from_view(view, 1, sel, out)

    assert_equal(len(out), 6, "in-list-bool-empty: 6 outputs")
    for i in range(6):
        assert_true(not out[i], "in-list-empty out[" + String(i) + "]=False")


# -----------------------------------------------------------------------------
# TestSuite registration
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()

    # I64 walker
    suite.test[test_i64_passthrough_identity_sel]()
    suite.test[test_i64_passthrough_filter_narrowed_sel]()
    suite.test[test_i64_literal_broadcast]()
    suite.test[test_i64_literal_broadcast_empty_sel]()
    suite.test[test_i64_unsupported_kind_raises]()

    # F64 walker
    suite.test[test_f64_passthrough_identity_sel]()
    suite.test[test_f64_passthrough_filter_narrowed_sel]()
    suite.test[test_f64_literal_broadcast]()
    suite.test[test_f64_literal_broadcast_empty_sel]()
    suite.test[test_f64_unsupported_kind_raises]()

    # I64 arithmetic walker
    suite.test[test_i64_add_lit_lit]()
    suite.test[test_i64_sub_col_lit]()
    suite.test[test_i64_mul_col_col]()
    suite.test[test_i64_div_col_lit_truncates]()
    suite.test[test_i64_div_by_zero_raises]()

    # F64 arithmetic walker
    suite.test[test_f64_add_lit_lit]()
    suite.test[test_f64_sub_col_lit]()
    suite.test[test_f64_mul_col_col]()
    suite.test[test_f64_div_col_lit_halves]()
    suite.test[test_f64_div_by_zero_no_raise]()

    # I32 walker
    suite.test[test_i32_passthrough_identity_sel]()
    suite.test[test_i32_passthrough_filter_narrowed_sel]()
    suite.test[test_i32_literal_broadcast]()
    suite.test[test_i32_unsupported_kind_raises]()

    # I32 arithmetic walker
    suite.test[test_i32_add_lit_lit]()
    suite.test[test_i32_sub_col_lit]()
    suite.test[test_i32_mul_col_col]()
    suite.test[test_i32_div_by_zero_raises]()

    # String walker
    suite.test[test_string_passthrough_identity_sel]()
    suite.test[test_string_passthrough_filter_narrowed_sel]()
    suite.test[test_string_unsupported_kind_raises]()

    # F32 walker
    suite.test[test_f32_passthrough_identity_sel]()
    suite.test[test_f32_passthrough_filter_narrowed_sel]()
    suite.test[test_f32_unsupported_kind_raises]()

    # Bool walker
    suite.test[test_bool_passthrough_identity_sel]()
    suite.test[test_bool_passthrough_filter_narrowed_sel]()
    suite.test[test_bool_literal_broadcast]()
    suite.test[test_bool_unsupported_kind_raises]()

    # EXPR_IN_LIST as Bool projection
    suite.test[test_in_list_bool_string_identity_sel]()
    suite.test[test_in_list_bool_string_filter_narrowed_sel]()
    suite.test[test_in_list_bool_scalar_overload_string]()
    suite.test[test_in_list_bool_i64_membership]()
    suite.test[test_in_list_bool_empty_list_all_false]()

    suite^.run()
