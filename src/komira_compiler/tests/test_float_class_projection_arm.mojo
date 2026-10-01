# =============================================================================
# FLOAT-CLASS PROJECTION ARM — a comparison as an OUTPUT COLUMN
# =============================================================================
#
# `isfinite` / `isinf` / `isnan` are a PURE BINDER DESUGAR
# (`komira_sdk/sql_binder._bind_float_class`): no op, no kernel, no wire
# member. All three lower to the SAME comparison shape —
#
#     isfinite(x) == x > -inf AND x < inf
#     isinf(x)    == x  =  inf OR  x  = -inf
#     isnan(x)    == NOT isfinite(x) AND NOT isinf(x)
#
# — so they are one class: served together or blocked together. They were in
# THREE different states, and that is what this file pins.
#
# ⛔ THE DEFECT (through the shipped `.so`, over a parquet
# leaf). `_eval_column_expr`'s `EXPR_BINARY_OP` arm is an ARITHMETIC ladder:
# the literal-RHS fast path lands in `_eval_binary_col_scalar`, whose FLOAT64
# arm serves ADD/SUB/MUL/DIV and then raises
#
#     LocalDispatcher.run_with_state: unsupported float64 scalar binary op: 14
#
# — 14 is `BIN_GT`. The col-col ladder below it raises the same way per type
# pair. So a comparison was executable as a FILTER PREDICATE
# (`compiler_eval_predicate._eval_predicate` -> `_col_cmp_nullable`, which
# carries GT/LT/EQ/NE/GE/LE) and NOT as an output COLUMN.
#
#   isfinite(v)  REFUSED  — `BIN_GT` with a literal RHS
#   isnan(v)     REFUSED  — same, via the `isfinite` half it is built from
#   isinf(v)     ANSWERED — and WRONG on a NULL row (got False, want NULL)
#
# ⭐ WHY THE THIRD ONE ANSWERED AT ALL, which is the whole reason the split
# was not obvious: `isinf`'s `OR`-of-equalities-on-one-column is exactly the
# shape `optimizer_expr._rewrite_in_expr` folds to an
# `EXPR_IN_LIST` — and `rewrite_in_clauses_inplace` visits `PLAN_PROJECT`, not
# just `PLAN_FILTER`. `EXPR_IN_LIST` HAS a projection arm. So `isinf` reached
# the evaluator through a DIFFERENT tag than the one its desugar wrote, and
# inherited that tag's null policy: `_eval_in_list` builds its result with
# `BooleanArray.from_bitmap` and never touches validity, which is right in a
# PREDICATE (an UNKNOWN row must not select) and a WRONG ANSWER in a
# PROJECTION (DuckDB propagates NULL through all three classifiers).
#
# ⇒ THE FIX IS TWO EDITS, in `compiler_eval_column.mojo`:
#   (1) boolean-valued binary ops (the six comparisons + AND/OR) in
#       projection context DELEGATE to the predicate ladder rather than
#       falling into the arithmetic one. Not a second implementation of float
#       comparison — the same `_col_cmp_nullable` / `kleene_cmp_finalize_*`
#       seam, which is what makes the NULL contract free.
#   (2) the `EXPR_IN_LIST` projection arm RE-IMPOSES the child column's
#       validity, exactly as the `EXPR_STRING_OP` projection arm one screen
#       down already does, and for the identical reason.
#
# ORACLE: DuckDB v1.5.3, over {1.5, nan, inf, -inf, 0.0, -1e308, NULL}.
# ⭐ `-1e308` IS NOT DECORATION — it is FINITE and HUGE, so a lowering that
# compared a MAGNITUDE against a threshold instead of against infinity itself
# is red on that row alone. `0.0` is here because a sign-blind reading gets it
# wrong, and the NULL because that is the row all three got wrong or refused.
#
# ⛔ THE OBVIOUS `isnan(x) == x <> x` IS WRONG AGAINST DuckDB and is NOT what
# is tested here: `'nan'::double = 'nan'::double` is TRUE there (DuckDB orders
# floats TOTALLY). The desugar above is correct under BOTH orderings, and so
# are these expectations.
#
# RED-before / GREEN-after:
#   isfinite / isnan / bare `v > lit` / `a > b` — RAISED
#     ("unsupported float64 scalar binary op: 14" / "unsupported float64
#      binary op: 14"); now answer.
#   isinf — row 6 came back FALSE-and-VALID; now NULL.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import (
    Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder,
)
from komira_core.plan.expr import (
    Expr, BIN_AND, BIN_OR, BIN_EQ, BIN_GT, BIN_LT, BIN_MUL, UN_NOT,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_compiler.compiler_eval_predicate import _eval_predicate


# =============================================================================
# Fixture — the seven-row float column, NULL at index 6
# =============================================================================


def _pos_inf() raises -> Float64:
    return Float64("inf")


def _neg_inf() raises -> Float64:
    return Float64("-inf")


def _nan() raises -> Float64:
    return Float64("nan")


def _float_batch() raises -> RecordBatch:
    """`v` = [1.5, nan, inf, -inf, 0.0, -1e308, NULL] — NULLABLE FLOAT64.

    Row 6 is stored as 0.0 and then marked NULL: the raw payload under a null
    lane must not be what decides the answer.
    """
    var vals = List[Float64]()
    vals.append(1.5)
    vals.append(_nan())
    vals.append(_pos_inf())
    vals.append(_neg_inf())
    vals.append(0.0)
    vals.append(-1e308)
    vals.append(0.0)

    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, Scalar[DType.float64](vals[i]))
    # `set` marks a lane VALID, so the null is imposed AFTER the writes.
    arr._set_null(6)

    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](arr^))
    return rbb.build(sb.build())


def _two_col_batch() raises -> RecordBatch:
    """`a` / `b` — both FLOAT64, `b` NULL at index 2."""
    var a_vals = List[Float64]()
    a_vals.append(3.0)
    a_vals.append(1.0)
    a_vals.append(5.0)
    var b_vals = List[Float64]()
    b_vals.append(1.0)
    b_vals.append(2.0)
    b_vals.append(0.0)

    var a = PrimitiveArray[DType.float64].allocate(len(a_vals))
    for i in range(len(a_vals)):
        a.set(i, Scalar[DType.float64](a_vals[i]))
    var b = PrimitiveArray[DType.float64].allocate_nullable(len(b_vals))
    for i in range(len(b_vals)):
        b.set(i, Scalar[DType.float64](b_vals[i]))
    b._set_null(2)

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.FLOAT64, False))
    sb.add_field(Field("b", ArrowType.FLOAT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](a^))
    rbb.add_column(Column.from_primitive[DType.float64](b^))
    return rbb.build(sb.build())


# =============================================================================
# The desugars — built EXACTLY as `sql_binder._bind_float_class` builds them
# =============================================================================


def _isfinite_expr() raises -> Expr:
    return Expr.binary(
        BIN_AND,
        Expr.binary(
            BIN_GT,
            Expr.col_ref("v"),
            Expr.literal(ScalarValue.from_float(_neg_inf())),
        ),
        Expr.binary(
            BIN_LT,
            Expr.col_ref("v"),
            Expr.literal(ScalarValue.from_float(_pos_inf())),
        ),
    )


def _isinf_expr() raises -> Expr:
    return Expr.binary(
        BIN_OR,
        Expr.binary(
            BIN_EQ,
            Expr.col_ref("v"),
            Expr.literal(ScalarValue.from_float(_pos_inf())),
        ),
        Expr.binary(
            BIN_EQ,
            Expr.col_ref("v"),
            Expr.literal(ScalarValue.from_float(_neg_inf())),
        ),
    )


def _isinf_expr_as_the_optimizer_emits_it() raises -> Expr:
    """`v IN (inf, -inf)` — what `_rewrite_in_expr` turns `_isinf_expr` into.

    ⚠ THIS, NOT THE OR-TREE, IS THE SHAPE THAT ACTUALLY REACHES THE EVALUATOR
    on any plan that went through `optimize_full`. A test that only drove the
    OR-tree would have been green on a build where `isinf(NULL)` still
    answered False.
    """
    var values = List[ScalarValue]()
    values.append(ScalarValue.from_float(_pos_inf()))
    values.append(ScalarValue.from_float(_neg_inf()))
    return Expr.in_list_node(Expr.col_ref("v"), values^)


def _isnan_expr() raises -> Expr:
    return Expr.binary(
        BIN_AND,
        Expr.unary(UN_NOT, _isfinite_expr()),
        Expr.unary(UN_NOT, _isinf_expr()),
    )


# =============================================================================
# Grading
# =============================================================================


def _project_bool(expr: Expr, batch: RecordBatch) raises -> BooleanArray:
    """Evaluate `expr` as an OUTPUT COLUMN and hand back the Bool array.

    Asserts the column's Arrow type on the way through: `walk_expr_field`
    types every comparison / AND / OR as BOOL regardless of operand type, and
    a projection whose DATA and declared TYPE disagree is refused by the
    Arrow C-ABI export rather than by anything here.
    """
    var col = _eval_column_expr(expr, batch)
    assert_true(col.arrow_type == ArrowType.BOOL)
    return col.as_boolean()


def _grade(ba: BooleanArray, expected: List[Int], label: String) raises:
    """`expected[i]` is 0 = False, 1 = True, -1 = NULL."""
    assert_equal(len(ba), len(expected), label + ": row count")
    for i in range(len(expected)):
        var want = expected[i]
        if want == -1:
            assert_true(
                ba.is_null(i),
                label + ": row " + String(i) + " must be NULL",
            )
            # THE REPO-WIDE ENCODING: an UNKNOWN row carries DATA BIT 0, and
            # the validity bitmap says WHY it is 0. A data-only consumer
            # (`filter_to_indices`) never reads validity.
            assert_false(
                ba.get(i),
                label + ": row " + String(i) + " NULL lane must carry data 0",
            )
        else:
            assert_false(
                ba.is_null(i),
                label + ": row " + String(i) + " must not be NULL",
            )
            assert_equal(
                ba.get(i),
                want == 1,
                label + ": row " + String(i),
            )


def _verdicts(
    r0: Int, r1: Int, r2: Int, r3: Int, r4: Int, r5: Int, r6: Int
) -> List[Int]:
    """A seven-row verdict list; variadic list construction is unsupported."""
    var out = List[Int]()
    out.append(r0)
    out.append(r1)
    out.append(r2)
    out.append(r3)
    out.append(r4)
    out.append(r5)
    out.append(r6)
    return out^


def _verdicts3(r0: Int, r1: Int, r2: Int) -> List[Int]:
    var out = List[Int]()
    out.append(r0)
    out.append(r1)
    out.append(r2)
    return out^


def _duck_isfinite() -> List[Int]:
    return _verdicts(1, 0, 0, 0, 1, 1, -1)


def _duck_isinf() -> List[Int]:
    return _verdicts(0, 0, 1, 1, 0, 0, -1)


def _duck_isnan() -> List[Int]:
    return _verdicts(0, 1, 0, 0, 0, 0, -1)


# =============================================================================
# THE THREE CLASSIFIERS
# =============================================================================


def test_isfinite_as_an_output_column() raises:
    """RED-before: raised `unsupported float64 scalar binary op: 14`."""
    var batch = _float_batch()
    var ba = _project_bool(_isfinite_expr(), batch)
    _grade(ba, _duck_isfinite(), "isfinite")


def test_isinf_as_an_output_column_or_tree() raises:
    """The desugar's own shape, before the optimizer folds it."""
    var batch = _float_batch()
    var ba = _project_bool(_isinf_expr(), batch)
    _grade(ba, _duck_isinf(), "isinf(OR-tree)")


def test_isinf_as_an_output_column_in_list() raises:
    """The shape the optimizer actually emits. RED-before: row 6 was False."""
    var batch = _float_batch()
    var ba = _project_bool(_isinf_expr_as_the_optimizer_emits_it(), batch)
    _grade(ba, _duck_isinf(), "isinf(IN_LIST)")


def test_isnan_as_an_output_column() raises:
    """RED-before: raised through the `isfinite` half it is built from."""
    var batch = _float_batch()
    var ba = _project_bool(_isnan_expr(), batch)
    _grade(ba, _duck_isnan(), "isnan")


def test_float_class_is_one_class() raises:
    """⭐ THE ANTI-PARTIAL-FIX ARM — three functions, one comparison shape.

    A change that serves two of the three is still RED here, on purpose. The
    claim is not "each is individually right" (the three tests above own
    that); it is that the class agrees ROW BY ROW: every non-null row belongs
    to exactly ONE of finite / infinite / nan, and every null row is NULL in
    all three.
    """
    var batch = _float_batch()
    var fin = _project_bool(_isfinite_expr(), batch)
    var inf = _project_bool(_isinf_expr_as_the_optimizer_emits_it(), batch)
    var nan = _project_bool(_isnan_expr(), batch)

    assert_equal(len(fin), 7)
    assert_equal(len(inf), 7)
    assert_equal(len(nan), 7)

    for i in range(7):
        if fin.is_null(i) or inf.is_null(i) or nan.is_null(i):
            assert_true(fin.is_null(i), "row " + String(i) + ": isfinite NULL")
            assert_true(inf.is_null(i), "row " + String(i) + ": isinf NULL")
            assert_true(nan.is_null(i), "row " + String(i) + ": isnan NULL")
            continue
        var hits = 0
        if fin.get(i):
            hits += 1
        if inf.get(i):
            hits += 1
        if nan.get(i):
            hits += 1
        assert_equal(
            hits, 1, "row " + String(i) + ": exactly one float class"
        )


# =============================================================================
# THE SECOND WALL — AN ALIAS **BELOW** THE TOP OF A PREDICATE
# =============================================================================
#
# ⛔ FOUND BY THE PLAN-MATRIX SWEEP, NOT BY THIS FILE. With the projection arm
# delegating comparisons to `_eval_predicate`, cell
# `proj_float_class/float64/{full,nanmix}` moved straight off
# `unsupported float64 scalar binary op: 14` and onto
#
#     LocalDispatcher.run_with_state: PipelineCompiler: unsupported predicate
#     expression tag: 6
#
# — tag 6 is `EXPR_ALIAS`. `_eval_column_expr` unwraps an alias;
# `_eval_predicate` had no arm for one, and nothing had ever reached it
# because a comparison was not executable as a projection in the first place.
#
# ⭐ THE ALIAS IS NOT AT THE TOP OF THE EXPRESSION, which is why unwrapping at
# the projection entry point does not cover it. `isfinite(v)` and `isnan(v)` in
# ONE SELECT share the subtree `v > -inf AND v < inf`; CSE hoists the shared
# subtree under an alias and `merge_projects` inlines the aliased node back
# into its consumers, so what survives is `NOT(Alias(AND(...)))` — an alias
# BELOW a `UN_NOT`, handed straight back to `_eval_predicate` by its own
# UN_NOT arm.
#
# ⚠ THESE TWO CASES ARE WRITTEN AS SHAPES, NOT AS "WHAT CSE EMITS". The fix
# belongs to the ladder, not to the pass that happened to produce the shape,
# and a test phrased in terms of the pass would go quiet if the pass changed.


def test_an_alias_directly_under_a_logical_op() raises:
    """`Alias(v > -inf) AND Alias(v < inf)` — RED-before: predicate tag 6."""
    var batch = _float_batch()
    var expr = Expr.binary(
        BIN_AND,
        Expr.alias(
            Expr.binary(
                BIN_GT,
                Expr.col_ref("v"),
                Expr.literal(ScalarValue.from_float(_neg_inf())),
            ),
            "cse_0",
        ),
        Expr.alias(
            Expr.binary(
                BIN_LT,
                Expr.col_ref("v"),
                Expr.literal(ScalarValue.from_float(_pos_inf())),
            ),
            "cse_1",
        ),
    )
    var ba = _project_bool(expr, batch)
    _grade(ba, _duck_isfinite(), "isfinite with aliased conjuncts")


def test_an_alias_under_a_NOT_inside_the_isnan_desugar() raises:
    """The exact post-CSE `isnan` shape: `NOT(Alias(fin)) AND NOT(Alias(inf))`.
    """
    var batch = _float_batch()
    var expr = Expr.binary(
        BIN_AND,
        Expr.unary(UN_NOT, Expr.alias(_isfinite_expr(), "cse_fin")),
        Expr.unary(UN_NOT, Expr.alias(_isinf_expr(), "cse_inf")),
    )
    var ba = _project_bool(expr, batch)
    _grade(ba, _duck_isnan(), "isnan with aliased halves")


# =============================================================================
# THE GENERAL CLAIM — a comparison is materializable as an output column
# =============================================================================


def test_bare_comparison_with_a_literal_as_an_output_column() raises:
    """`v > 0.0` PROJECTED — opcode 14, the number in the old message."""
    var batch = _float_batch()
    var expr = Expr.binary(
        BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_float(0.0))
    )
    var ba = _project_bool(expr, batch)
    # 1.5 > 0 T | nan > 0 F | inf > 0 T | -inf > 0 F | 0 > 0 F |
    # -1e308 > 0 F | NULL -> NULL
    _grade(ba, _verdicts(1, 0, 1, 0, 0, 0, -1), "v > 0.0")


def test_literal_on_the_left_as_an_output_column() raises:
    """`0.0 < v` — the scalar-on-the-LEFT branch, which must not invert."""
    var batch = _float_batch()
    var expr = Expr.binary(
        BIN_LT, Expr.literal(ScalarValue.from_float(0.0)), Expr.col_ref("v")
    )
    var ba = _project_bool(expr, batch)
    _grade(ba, _verdicts(1, 0, 1, 0, 0, 0, -1), "0.0 < v")


def test_col_vs_col_comparison_as_an_output_column() raises:
    """`a > b` PROJECTED — the col-col half of the same gap."""
    var batch = _two_col_batch()
    var expr = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.col_ref("b"))
    var ba = _project_bool(expr, batch)
    # 3>1 T | 1>2 F | 5>NULL -> NULL
    _grade(ba, _verdicts3(1, 0, -1), "a > b")


# =============================================================================
# THE OTHER POSITION — THE SAME DESUGAR AS A **FILTER PREDICATE**
# =============================================================================
#
# ⛔ A NULL ROW MUST BE **REJECTED** BY A FILTER, and the mechanism that makes
# that true is not 3VL alone: `filter_to_indices` reads the DATA bitmap and
# never looks at validity, so the row is dropped because its DATA BIT IS 0.
# These arms assert the data bit, which is what the row set actually depends
# on.
#
# ⚠ THEY ARE HERE BECAUSE THE E2E GATE FOUND `SELECT k FROM F WHERE
# isfinite(v)` KEEPING THE NULL ROW (`survivors [0,4,5,6]`, want `[0,4,5]`)
# WHILE `isinf` AND `isnan` WERE BOTH CORRECT — and that asymmetry is the
# finding, not a coincidence: over a NULL row whose undecoded payload reads as
# 0.0, `isfinite` is the only one of the three that answers TRUE. So the three
# filter arms agreeing here says the PREDICATE LADDER is not where the leak is.
# If these pass and the e2e filter arm still leaks, the operand column has lost
# its validity bitmap BEFORE the predicate runs.


def _predicate_data_bits(expr: Expr, batch: RecordBatch) raises -> List[Int]:
    """The rows a filter would KEEP — `filter_to_indices` reads data bits."""
    var ba = _eval_predicate(expr, batch)
    var keep = List[Int]()
    for i in range(len(ba)):
        if ba.get(i):
            keep.append(i)
    return keep^


def _assert_keeps(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label + ": survivor count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ": survivor " + String(i))


def test_isfinite_as_a_filter_predicate_rejects_the_null_row() raises:
    """`WHERE isfinite(v)` keeps {0, 4, 5} — NOT row 6 (NULL)."""
    var batch = _float_batch()
    var keep = _predicate_data_bits(_isfinite_expr(), batch)
    var want = List[Int]()
    want.append(0)
    want.append(4)
    want.append(5)
    _assert_keeps(keep, want, "WHERE isfinite(v)")


def test_isinf_as_a_filter_predicate_rejects_the_null_row() raises:
    """`WHERE isinf(v)` keeps {2, 3}."""
    var batch = _float_batch()
    var keep = _predicate_data_bits(_isinf_expr(), batch)
    var want = List[Int]()
    want.append(2)
    want.append(3)
    _assert_keeps(keep, want, "WHERE isinf(v)")


def test_isnan_as_a_filter_predicate_rejects_the_null_row() raises:
    """`WHERE isnan(v)` keeps {1}."""
    var batch = _float_batch()
    var keep = _predicate_data_bits(_isnan_expr(), batch)
    var want = List[Int]()
    want.append(1)
    _assert_keeps(keep, want, "WHERE isnan(v)")


def test_the_null_row_is_rejected_when_the_column_carries_NO_validity() raises:
    """⛔ THE CONTROL THAT LOCALISES THE E2E LEAK, AND IT IS EXPECTED TO KEEP
    ROW 6.

    Same seven values, same expression — but the column is built NON-NULLABLE
    with the null lane's payload left at 0.0, which is what a decode path that
    drops the validity bitmap hands the predicate. `isfinite(0.0)` is TRUE, so
    row 6 survives, and `isinf` / `isnan` are both FALSE on 0.0, so THEY do
    not change. That is exactly the asymmetry the e2e gate reported.

    ⇒ This arm does not assert correct behaviour; it asserts the MECHANISM, so
    that a future reader can tell a 3VL defect in the ladder (which would move
    all three) from a lost validity bitmap upstream (which moves only
    `isfinite`). Keep it RED-sensitive in that direction: if this ever stops
    keeping row 6, the loss is no longer the explanation.
    """
    var vals = List[Float64]()
    vals.append(1.5)
    vals.append(_nan())
    vals.append(_pos_inf())
    vals.append(_neg_inf())
    vals.append(0.0)
    vals.append(-1e308)
    vals.append(0.0)
    var arr = PrimitiveArray[DType.float64].allocate(len(vals))
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.float64](vals[i]))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](arr^))
    var batch = rbb.build(sb.build())

    var keep_fin = _predicate_data_bits(_isfinite_expr(), batch)
    var want_fin = List[Int]()
    want_fin.append(0)
    want_fin.append(4)
    want_fin.append(5)
    want_fin.append(6)
    _assert_keeps(keep_fin, want_fin, "no-validity isfinite KEEPS row 6")

    # ... and the other two are unmoved by the same loss.
    var keep_inf = _predicate_data_bits(_isinf_expr(), batch)
    var want_inf = List[Int]()
    want_inf.append(2)
    want_inf.append(3)
    _assert_keeps(keep_inf, want_inf, "no-validity isinf is unmoved")

    var keep_nan = _predicate_data_bits(_isnan_expr(), batch)
    var want_nan = List[Int]()
    want_nan.append(1)
    _assert_keeps(keep_nan, want_nan, "no-validity isnan is unmoved")


# =============================================================================
# THE ARITHMETIC ARMS MUST BE UNTOUCHED
# =============================================================================


def test_arithmetic_projection_is_unchanged() raises:
    """`v * 2.0` still FLOAT64, still validity-preserving.

    The fix routes BOOLEAN-valued ops away from the arithmetic ladder; it must
    not move ADD/SUB/MUL/DIV, whose scalar fast path
    (`_eval_binary_col_scalar` + `clone_array_validity`) is load-bearing on
    the hot path.
    """
    var batch = _float_batch()
    var expr = Expr.binary(
        BIN_MUL, Expr.col_ref("v"), Expr.literal(ScalarValue.from_float(2.0))
    )
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.FLOAT64)
    var arr = out.as_primitive[DType.float64]()
    assert_equal(arr.length, 7)
    assert_true(arr.get(0) == 3.0, "1.5 * 2.0")
    assert_true(arr.get(4) == 0.0, "0.0 * 2.0")
    assert_true(arr.is_null(6), "the NULL lane stays NULL")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
