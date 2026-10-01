# =============================================================================
# test_projection_type_matches_data — the TYPE ladder must agree with the DATA
# ladder, because `MapOp.execute` pairs them
# =============================================================================
#
# ⛔ THE PRODUCTION FAILURE THIS PINS, IN ONE SENTENCE: `MapOp.execute`
# computes a projected column's DATA with `_eval_column_expr` and names its
# TYPE with `field_for_expr`, so a tag armed in one ladder and not the other
# emits a batch whose data is CORRECT and whose schema says `null`, and the
# Arrow C-ABI export then refuses the whole result with
#
#     UnsupportedArrowCABIType: Arrow type 'null' (export)
#
# That is why EVERY `proj_case_*` cell of the plan matrix failed over EVERY
# column type including int64, and why `substring(...)` could not execute
# through the plan-wire door.
#
# ⭐ THE TELL, WORTH REMEMBERING: the ZERO-ROW variants PASSED. An empty
# result takes `materialize_parquet_collect`'s `empty_out_schema` recovery,
# which is derived from `schema_from_project_exprs` -> `_infer_expr_field` —
# the OTHER inference function. So the zero-row path and the non-zero-row
# path used DIFFERENT type inference, and only one of them was wrong. A
# projection green on `empty` and red on everything else is this bug.
#
# ⚠ THIS IS A DIFFERENT ASSERTION FROM THE ONE IN
# `komira_core/tests/test_expr_walk_unification.mojo`. That file pins the two
# TYPE entry points against EACH OTHER (they are one walk now, so they must
# agree). This file pins the TYPE ladder against the DATA ladder — two
# genuinely independent implementations that must produce the same answer,
# and the pair that actually broke. Neither test implies the other.
#
# The static twin is a cross-ladder ledger that checks the two walkers name the
# same tags (it found two live instances of this exact bug, EXPR_JSON_EXTRACT
# and EXPR_EXTRACT).
# written. This is its runtime form: the ledger proves the arms exist, this
# proves the answers match on real data.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.schema import (
    Schema,
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_core.io.heap_region import HeapRegion
from komira_core.helpers.compiler_helpers import field_for_expr
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.expr import (
    Expr,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    BIN_ADD,
    STRFN_UPPER,
    EXPR_STRING_OP,
    STR_CONTAINS,
    STR_STARTS_WITH,
    STR_ENDS_WITH,
)
from komira_compiler.compiler_eval_column import _eval_column_expr


# ===========================================================================
# Fixture — a 4-row batch with an INT64, a FLOAT64, a BOOL and a STRING col.
# ===========================================================================


def _int64_col(values: List[Int]) -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate(len(values))
    var p = a._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, Scalar[DType.int64](values[i]))
    return Column.from_primitive[DType.int64](a)


def _float64_col(values: List[Float64]) -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.float64].allocate(len(values))
    var p = a._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, Scalar[DType.float64](values[i]))
    return Column.from_primitive[DType.float64](a)


def _bool_col(bits: List[Bool]) -> Column[HeapRegion]:
    var a = BooleanArray.allocate(len(bits))
    for i in range(len(bits)):
        a.set(i, bits[i])
    return Column.from_boolean(a)


def _batch() raises -> RecordBatch:
    """4 rows: n = [3, -7, 0, 42], f = [1.5, -2.25, 0.0, 100.0],
    flag = [T, F, T, F], s = ["apple", NULL, "apricot", "banana"].

    `-7` and `-2.25` are present so a negate that only ever sees positives
    cannot pass, and `0` is present because `-0` is the value a hand-rolled
    negate is most likely to get wrong.

    ⚠ `s` CARRIES A NULL ON PURPOSE AND IT IS THE ONLY COLUMN THAT DOES. The
    pattern kernels never see a validity bitmap (they take
    `(length, offsets, data)`), so a null row is matched AS THE EMPTY STRING
    — harmless in a PREDICATE, a wrong answer in a PROJECTION. A fixture with
    no null row cannot tell the two apart. Rows 0 and 2 share the prefix `ap`
    and differ after it, so `starts_with` and `contains` split the four rows
    differently from each other rather than agreeing by accident.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("n"), ArrowType.INT64, False))
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("flag"), ArrowType.BOOL, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))

    var ns = List[Int]()
    ns.append(3)
    ns.append(-7)
    ns.append(0)
    ns.append(42)

    var fs = List[Float64]()
    fs.append(1.5)
    fs.append(-2.25)
    fs.append(0.0)
    fs.append(100.0)

    var bs = List[Bool]()
    bs.append(True)
    bs.append(False)
    bs.append(True)
    bs.append(False)

    var ss = List[String]()
    ss.append(String("apple"))
    ss.append(String(""))
    ss.append(String("apricot"))
    ss.append(String("banana"))

    var svalid = List[Bool]()
    svalid.append(True)
    svalid.append(False)
    svalid.append(True)
    svalid.append(True)

    var rb = RecordBatchBuilder()
    rb.add_column(_int64_col(ns))
    rb.add_column(_float64_col(fs))
    rb.add_column(_bool_col(bs))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(ss, svalid))
    )
    return rb.build(sb.build())


def _int_at(col: Column[HeapRegion], i: Int) -> Int64:
    return col._data.get_typed[Scalar[DType.int64]](i)


def _float_at(col: Column[HeapRegion], i: Int) -> Float64:
    return col._data.get_typed[Scalar[DType.float64]](i)


def _bool_at(col: Column[HeapRegion], i: Int) raises -> Bool:
    return col.as_boolean().get(i)


def _assert_type_matches_data(var expr: Expr, label: String) raises:
    """★ THE CORE ASSERTION OF THIS FILE.

    Evaluate the expression the way `MapOp.execute` does — data through
    `_eval_column_expr`, type through `field_for_expr` — and require the two
    to agree. A `null` declared type over a correct column is the
    export failure; a MISMATCHED declared type is the same class one step
    worse, because a consumer calling `as_primitive[DType.int32]` on it
    raises `arrow_type mismatch` instead of failing at export.
    """
    var batch = _batch()
    var declared = field_for_expr(expr, batch.schema)
    var actual = _eval_column_expr(expr, batch)

    assert_true(
        declared.arrow_type != ArrowType.NULL,
        label
        + ": the DATA ladder produced a column and the TYPE ladder said"
        " `null`. That column's data is correct and the Arrow C-ABI export"
        " will refuse the whole result."
        " Add the arm to `walk_expr_field`.",
    )
    assert_true(
        declared.arrow_type == actual.arrow_type,
        label
        + ": declared type "
        + String(declared.arrow_type)
        + " but the evaluated column is "
        + String(actual.arrow_type)
        + " -- the batch's schema contradicts its own column",
    )
    assert_equal(
        actual.length(),
        batch.num_rows(),
        label + ": the projected column must be the batch's length",
    )
    _ = expr^


# ===========================================================================
# `NOT x` and `-x` — the fourth recurrence, closed.
# ===========================================================================


def test_not_bool_column_projects_with_matching_type() raises:
    """`SELECT NOT flag`. Before this raised "unsupported
    projection expression tag: 4" from the DATA ladder, and would then have
    exported as `null` from the TYPE ladder even once the data existed —
    both halves were unarmed."""
    _assert_type_matches_data(
        Expr.unary(UN_NOT, Expr.col_ref("flag")), String("NOT flag")
    )


def test_not_bool_column_values_match_duckdb() raises:
    """DuckDB: `NOT true = false`, `NOT false = true`, elementwise.

    Fixture flags are [T, F, T, F], so the projection is [F, T, F, T]."""
    var batch = _batch()
    var e = Expr.unary(UN_NOT, Expr.col_ref("flag"))
    var out = _eval_column_expr(e, batch)
    assert_equal(_bool_at(out, 0), False, "NOT true = false")
    assert_equal(_bool_at(out, 1), True, "NOT false = true")
    assert_equal(_bool_at(out, 2), False, "NOT true = false")
    assert_equal(_bool_at(out, 3), True, "NOT false = true")
    _ = e^


def test_negate_int64_projects_with_matching_type() raises:
    """`SELECT -n`."""
    _assert_type_matches_data(
        Expr.unary(UN_NEGATE, Expr.col_ref("n")), String("-n")
    )


def test_negate_int64_values_match_duckdb() raises:
    """DuckDB: `-x` negates, preserving INT64 width. Fixture n = [3,-7,0,42].

    ⚠ `-0` MUST STILL BE `0`, not a trap value -- the negate is routed
    through `_eval_binary_col_scalar(col, BIN_MUL, -1)` precisely so it
    inherits the tested width rules rather than a hand-rolled loop."""
    var batch = _batch()
    var e = Expr.unary(UN_NEGATE, Expr.col_ref("n"))
    var out = _eval_column_expr(e, batch)
    assert_true(
        out.arrow_type == ArrowType.INT64,
        "`-int64_col` stays INT64 -- it must not promote",
    )
    assert_equal(_int_at(out, 0), Int64(-3), "-3")
    assert_equal(_int_at(out, 1), Int64(7), "-(-7) = 7")
    assert_equal(_int_at(out, 2), Int64(0), "-0 = 0")
    assert_equal(_int_at(out, 3), Int64(-42), "-42")
    _ = e^


def test_negate_float64_values_match_duckdb() raises:
    """The FLOAT64 width of the same rule. f = [1.5, -2.25, 0.0, 100.0]."""
    var batch = _batch()
    var e = Expr.unary(UN_NEGATE, Expr.col_ref("f"))
    var out = _eval_column_expr(e, batch)
    assert_true(
        out.arrow_type == ArrowType.FLOAT64,
        "`-float64_col` stays FLOAT64",
    )
    assert_equal(_float_at(out, 0), Float64(-1.5), "-1.5")
    assert_equal(_float_at(out, 1), Float64(2.25), "-(-2.25) = 2.25")
    assert_equal(_float_at(out, 3), Float64(-100.0), "-100.0")
    _ = e^


def test_negate_of_negate_is_identity() raises:
    """`-(-x) = x`. Exercises the RECURSIVE path — the arm must evaluate its
    child through the ladder, not assume a bare column reference."""
    var batch = _batch()
    var e = Expr.unary(
        UN_NEGATE, Expr.unary(UN_NEGATE, Expr.col_ref("n"))
    )
    var out = _eval_column_expr(e, batch)
    assert_equal(_int_at(out, 0), Int64(3), "-(-3) = 3")
    assert_equal(_int_at(out, 1), Int64(-7), "-(-(-7)) = -7")
    _ = e^


def test_negate_of_an_arithmetic_subtree() raises:
    """`-(n + n)`. The child is a compound expression, so this pins that the
    unary arm composes with the rest of the ladder rather than special-casing
    a column reference."""
    var batch = _batch()
    var e = Expr.unary(
        UN_NEGATE,
        Expr.binary(BIN_ADD, Expr.col_ref("n"), Expr.col_ref("n")),
    )
    var out = _eval_column_expr(e, batch)
    assert_equal(_int_at(out, 0), Int64(-6), "-(3+3) = -6")
    assert_equal(_int_at(out, 3), Int64(-84), "-(42+42) = -84")
    _ = e^


def test_is_null_and_is_not_null_are_EVALUABLE_as_output_columns() raises:
    """★ THE TRIPWIRE THIS TEST WAS, NOW DISCHARGED.

    Its previous revision was `test_is_null_in_projection_refuses_by_name`
    and asserted `assert_raises(contains="PROJECTION context")`, on the
    reasoning that reaching `compiler_eval_predicate._eval_predicate` from the
    projection ladder "would close an import cycle" and that re-implementing
    the validity-bitmap walk here would recreate the duplicate-ladder defect
    the surrounding change had just deleted.

    ⛔ THE CYCLE ARGUMENT STOPPED BEING TRUE BEFORE THE REFUSAL DID. That
    import LANDED earlier -- `compiler_eval_column` now opens
    `from .compiler_eval_predicate import _eval_predicate, _is_comparison_op`
    and the `EXPR_BINARY_OP` arm has been delegating AND/OR and the six
    comparisons through it ever since. So the refusal was defending a cycle
    the module had already, deliberately, accepted, and the only thing keeping
    `x IS NULL` out of a SELECT list was its own sentence. This test is that
    sentence's falsifier and it fired the moment the arm landed, which is
    exactly what a named refusal is for.

    ⛔ STILL ONE LADDER, NOT TWO. The arm hands `_eval_predicate` the node
    UNCHANGED rather than re-deriving the bitmap walk, so the trailing-slack-
    bit mask and the general-child fallback are inherited. That is why the
    fix was ~2 lines and why this file's duplicate-ladder objection survives
    the change rather than being overridden by it.

    ⚠ THE TYPE HALF WAS ALREADY ARMED and is re-asserted here, because it is
    the half that would fail SILENTLY: `field_for_expr` has typed these BOOL
    so a plan carrying `IS NULL` in a projection had a
    CORRECT output schema and a missing column of data.

    ⚠ THE FIXTURE'S `n` IS NON-NULLABLE AND THAT IS THE CONTROL. An arm that
    answered from something other than the validity bitmap -- the data bytes,
    say, where `n` row 2 is a genuine `0` and `s` row 1 is a genuine `""` --
    would still get `s` right by luck on a fixture whose null row and whose
    falsy row were the same row. Here they are NOT: `n` is [3, -7, 0, 42] with
    no nulls at all, so `n IS NULL` must be FOUR FALSES including over the
    zero, while `s` is ["apple", NULL, "apricot", "banana"] whose NULL row
    carries an EMPTY STRING in its data slot.
    """
    var batch = _batch()

    # -- the TYPE ladder, both polarities ---------------------------------
    var t_null = Expr.unary(UN_IS_NULL, Expr.col_ref("s"))
    assert_true(
        field_for_expr(t_null, batch.schema).arrow_type == ArrowType.BOOL,
        "the TYPE ladder must answer BOOL for IS NULL",
    )
    var t_not = Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("s"))
    assert_true(
        field_for_expr(t_not, batch.schema).arrow_type == ArrowType.BOOL,
        "the TYPE ladder must answer BOOL for IS NOT NULL",
    )
    _ = t_null^
    _ = t_not^

    # -- IS NULL over the one NULLABLE column -----------------------------
    var e_null = Expr.unary(UN_IS_NULL, Expr.col_ref("s"))
    var out_null = _eval_column_expr(e_null, batch)
    assert_equal(out_null.length(), 4, "IS NULL must answer every row")
    assert_false(_bool_at(out_null, 0), "'apple' IS NULL -> false")
    assert_true(_bool_at(out_null, 1), "the NULL row IS NULL -> true")
    assert_false(_bool_at(out_null, 2), "'apricot' IS NULL -> false")
    assert_false(_bool_at(out_null, 3), "'banana' IS NULL -> false")
    _ = e_null^

    # -- IS NOT NULL: the OTHER polarity, not the same arm read backwards --
    var e_not = Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("s"))
    var out_not = _eval_column_expr(e_not, batch)
    assert_equal(out_not.length(), 4, "IS NOT NULL must answer every row")
    assert_true(_bool_at(out_not, 0), "'apple' IS NOT NULL -> true")
    assert_false(_bool_at(out_not, 1), "the NULL row IS NOT NULL -> false")
    assert_true(_bool_at(out_not, 2), "'apricot' IS NOT NULL -> true")
    assert_true(_bool_at(out_not, 3), "'banana' IS NOT NULL -> true")
    _ = e_not^

    # -- ⛔ THE CONTROL. A NON-NULLABLE column, whose row 2 is a genuine 0.
    var e_tot = Expr.unary(UN_IS_NULL, Expr.col_ref("n"))
    var out_tot = _eval_column_expr(e_tot, batch)
    assert_equal(out_tot.length(), 4, "IS NULL over a total column answers 4")
    assert_false(_bool_at(out_tot, 0), "3 IS NULL -> false")
    assert_false(_bool_at(out_tot, 1), "-7 IS NULL -> false")
    assert_false(
        _bool_at(out_tot, 2),
        "0 IS NULL -> false. An arm reading the DATA rather than the validity"
        " bitmap answers true here, and a fixture whose null row and whose"
        " zero row were the same row could not tell the two apart",
    )
    assert_false(_bool_at(out_tot, 3), "42 IS NULL -> false")
    _ = e_tot^

# ===========================================================================
# The shapes that were already armed — regression-locked against the
# convergence, since the BinaryOp ladder was restructured.
# ===========================================================================


def test_string_op_projects_with_matching_type() raises:
    """★ `SELECT starts_with(s, 'ap')` — the REVERSE cross-ladder direction,
    .

    `walk_expr_field` typed this tag BOOL for months while
    `_eval_column_expr` raised `unsupported projection expression tag: 7` on
    it. The forward ledger (`eval_armed - field_armed`) could not see it,
    because this is the OTHER subtraction — and it was reachable without any
    new SQL, since CSE hoisting a duplicated pattern subtree into a synthetic
    projection is the same route that made `EXPR_IN_LIST` need its arm in
    .
    """
    _assert_type_matches_data(
        Expr.string_op(STR_STARTS_WITH, Expr.col_ref("s"), String("ap")),
        "starts_with(s,'ap')",
    )
    _assert_type_matches_data(
        Expr.string_op(STR_ENDS_WITH, Expr.col_ref("s"), String("e")),
        "ends_with(s,'e')",
    )
    _assert_type_matches_data(
        Expr.string_op(STR_CONTAINS, Expr.col_ref("s"), String("ri")),
        "contains(s,'ri')",
    )


def test_string_op_projection_is_declared_NULLABLE() raises:
    """⛔ THE DECLARED FIELD SAID `nullable=False` AND THE DATA HAS NULLS.

    A schema contradicting its own column — the same pairing this file exists
    for, one slot over from the arrow_type. It was correct while the tag
    lived only in PREDICATE context (an unknown never selects, so the mask
    carries no validity); the projection arm propagates the child's validity,
    so the declaration had to move with it.

    `EXPR_IN_LIST` and `EXPR_BETWEEN` — the two other predicates that reach a
    projection by the same route — have always been nullable. This was the
    odd one out.
    """
    var batch = _batch()
    var e = Expr.string_op(STR_STARTS_WITH, Expr.col_ref("s"), String("ap"))
    var declared = field_for_expr(e, batch.schema)
    assert_true(
        declared.nullable,
        "a projected pattern predicate over a nullable child must be"
        " declared nullable -- DuckDB v1.5.3 answers NULL for"
        " starts_with(NULL,'ap')",
    )
    _ = e^


def test_string_op_projection_values_match_duckdb() raises:
    """VALUES, including the NULL row, measured on DuckDB v1.5.3.

    s = ["apple", NULL, "apricot", "banana"]
      starts_with(s,'ap') -> [true,  NULL, true,  false]
      contains(s,'ri')    -> [false, NULL, true,  false]

    ⚠ ROW 1 IS THE WHOLE POINT. Its slot holds the EMPTY STRING (Arrow: a
    null row still occupies an offsets slot), so a kernel reading slot
    CONTENTS answers `false` for both — plausible booleans, wrong answers,
    no raise. ⚠ AND `starts_with(NULL, '')` WOULD ANSWER **TRUE** the same
    way, so the divergence is not merely "too narrow"; it flips.
    """
    var batch = _batch()
    var e = Expr.string_op(STR_STARTS_WITH, Expr.col_ref("s"), String("ap"))
    var col = _eval_column_expr(e, batch)
    var arr = col.as_boolean()
    assert_true(arr.get(0), "row 0 'apple' starts with 'ap'")
    assert_true(arr.is_null(1), "row 1 is NULL, not false")
    assert_true(arr.get(2), "row 2 'apricot' starts with 'ap'")
    assert_true(not arr.get(3), "row 3 'banana' does not")
    assert_equal(arr.null_count, 1, "exactly one null row")
    _ = e^

    var e2 = Expr.string_op(STR_CONTAINS, Expr.col_ref("s"), String("ri"))
    var col2 = _eval_column_expr(e2, batch)
    var arr2 = col2.as_boolean()
    assert_true(not arr2.get(0), "'apple' does not contain 'ri'")
    assert_true(arr2.is_null(1), "row 1 is NULL under contains too")
    assert_true(arr2.get(2), "'apricot' contains 'ri'")
    _ = e2^


def test_arithmetic_projection_type_still_matches_data() raises:
    """The comparison carve-out now returns BOOL before the operands are even
    walked, so the arithmetic promotion rules moved below an early return.
    Pin that they are still reached."""
    _assert_type_matches_data(
        Expr.binary(BIN_ADD, Expr.col_ref("n"), Expr.col_ref("n")),
        String("n + n"),
    )
    _assert_type_matches_data(
        Expr.binary(BIN_ADD, Expr.col_ref("f"), Expr.col_ref("f")),
        String("f + f"),
    )


def test_int_plus_float_still_promotes_to_float64() raises:
    """`n + f` -> FLOAT64 in BOTH ladders. Without the promotion the
    streaming NoBreaker emit loop dispatches an F64 RuntimeExpr tree to the
    i64 view-evaluator."""
    _assert_type_matches_data(
        Expr.binary(BIN_ADD, Expr.col_ref("n"), Expr.col_ref("f")),
        String("n + f"),
    )


def test_literal_projection_type_matches_data() raises:
    _assert_type_matches_data(
        Expr.binary(
            BIN_ADD, Expr.col_ref("n"), Expr.literal(ScalarValue.from_int(5))
        ),
        String("n + 5"),
    )


def test_alias_preserves_the_child_type_through_both_ladders() raises:
    _assert_type_matches_data(
        Expr.alias(Expr.col_ref("f"), "renamed"), String("f AS renamed")
    )


def main() raises:
    var ts = TestSuite()
    ts.test[test_not_bool_column_projects_with_matching_type]()
    ts.test[test_not_bool_column_values_match_duckdb]()
    ts.test[test_negate_int64_projects_with_matching_type]()
    ts.test[test_negate_int64_values_match_duckdb]()
    ts.test[test_negate_float64_values_match_duckdb]()
    ts.test[test_negate_of_negate_is_identity]()
    ts.test[test_negate_of_an_arithmetic_subtree]()
    ts.test[test_is_null_and_is_not_null_are_EVALUABLE_as_output_columns]()
    ts.test[test_string_op_projects_with_matching_type]()
    ts.test[test_string_op_projection_is_declared_NULLABLE]()
    ts.test[test_string_op_projection_values_match_duckdb]()
    ts.test[test_arithmetic_projection_type_still_matches_data]()
    ts.test[test_int_plus_float_still_promotes_to_float64]()
    ts.test[test_literal_projection_type_matches_data]()
    ts.test[test_alias_preserves_the_child_type_through_both_ladders]()
    ts^.run()
