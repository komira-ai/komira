# =============================================================================
# test_null_test_computed_child — `IS NULL` / `IS NOT NULL` over a child that
# is NOT a bare column reference
# =============================================================================
#
# ⛔ THE FAILURE THIS PINS, IN ONE SENTENCE: `_eval_predicate`'s `UN_IS_NULL` /
# `UN_IS_NOT_NULL` arms resolved their child straight to a column index and
# refused anything else by name —
#
#     PipelineCompiler: IS_NOT_NULL only supports column references (got tag=24)
#
# — so a null test over a COMPUTED expression was unreachable. That is the
# same shape as the COMPUTED-LHS defect pinned by
# `test_predicate_compound_lhs.mojo` and the Gap-C
# compound-RHS one before it: an operand generalized on one side of the
# evaluator and left un-generalized on the other.
#
# ★ WHY IT MATTERED ENOUGH TO FIX RATHER THAN DOCUMENT. `coalesce(a, b, c)`
# has no `EXPR_*` tag of its own — `sql_binder._bind_coalesce` desugars it to
#
#     CASE WHEN a IS NOT NULL THEN a WHEN b IS NOT NULL THEN b ELSE c END
#
# and EVERY argument of a real `coalesce` except the first is typically a
# computed expression or a literal. So the whole function was one refusal
# away from unreachable, and the DuckDB-documented form `coalesce(NULL, NULL,
# 3)` = 3 has a LITERAL in the very first position.
#
# ⚠ THE NO-VALIDITY-BITMAP CASE IS ASYMMETRIC AND IS ASSERTED SEPARATELY.
# Arrow's absent validity bitmap means EVERY ROW IS VALID, so `IS NULL` must
# answer all-false (which `BooleanArray.allocate_nullable`'s zero-fill already
# gives) and `IS NOT NULL` must answer all-TRUE (which it does NOT). The two
# polarities therefore cannot be one body with a `~` toggled, and a defect
# there is a silent all-rows / no-rows answer with no error at all.
#
# ⚠ SIX ROWS, NOT EIGHT, ON PURPOSE. The mask is built bytewise and the last
# byte carries two bits past the end; a missing trailing-bit mask makes those
# read as phantom set rows. `true_count` over a row count that is not a
# multiple of 8 is what sees it.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.schema import (
    Schema,
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.expr import (
    Expr,
    WhenCaseData,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    STRFN_UPPER,
)
from komira_compiler.compiler_eval_predicate import _eval_predicate
from komira_compiler.compiler_eval_case import _eval_when_expr


# ===========================================================================
# Fixture — six rows, two of them NULL, in a STRING column plus an all-valid
# twin with NO validity bitmap at all.
# ===========================================================================


def _batch() raises -> RecordBatch:
    """`s` = ["a", NULL, "c", "d", NULL, "f"], `t` = the same six letters with
    NO nulls and therefore NO validity bitmap.

    Rows 1 and 4 are the null ones — interior positions in both halves of the
    single byte, so a mask built from the wrong nibble cannot agree by
    accident. `t` exists because the absent-bitmap path is a DIFFERENT branch
    from the present-bitmap one and answers the opposite default.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    sb.add_field(Field(String("t"), ArrowType.STRING, False))

    var vals = List[String]()
    vals.append(String("a"))
    vals.append(String(""))
    vals.append(String("c"))
    vals.append(String("d"))
    vals.append(String(""))
    vals.append(String("f"))

    var valid = List[Bool]()
    valid.append(True)
    valid.append(False)
    valid.append(True)
    valid.append(True)
    valid.append(False)
    valid.append(True)

    var full = List[String]()
    full.append(String("a"))
    full.append(String("b"))
    full.append(String("c"))
    full.append(String("d"))
    full.append(String("e"))
    full.append(String("f"))

    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    rb.add_column(Column.from_string(StringArray.from_strings(full)))
    return rb.build(sb.build())


def _upper_of(name: String) -> Expr:
    return Expr.string_fn(STRFN_UPPER, Expr.col_ref(name))


def _str_at(col: Column[HeapRegion], i: Int) raises -> String:
    return col.as_string().get(i)


# ===========================================================================
# THE CONTROL — the COL_REF fast path still answers what it always did.
# ===========================================================================


def test_col_ref_fast_path_unchanged() raises:
    """Both polarities over a bare column, which is the ONLY shape that worked
    before the generalization. If this moves, the generalization broke the fast path
    rather than extending past it."""
    var batch = _batch()
    var m_null = _eval_predicate(Expr.unary(UN_IS_NULL, Expr.col_ref("s")), batch)
    var m_nn = _eval_predicate(Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("s")), batch)
    assert_equal(m_null.true_count(), 2, "IS NULL over s: rows 1 and 4")
    assert_equal(m_nn.true_count(), 4, "IS NOT NULL over s: the other four")
    print("PASS: COL_REF fast path unchanged (2 null / 4 non-null of 6)")


def test_col_ref_no_validity_bitmap_polarity() raises:
    """★ THE ASYMMETRY. `t` has NO validity bitmap, so every row is valid:
    `IS NULL` is 0 of 6 and `IS NOT NULL` is 6 of 6. A body that treats
    "no bitmap" as "zero-filled data is the answer" gets the second one
    wrong on every row and raises nothing."""
    var batch = _batch()
    var m_null = _eval_predicate(Expr.unary(UN_IS_NULL, Expr.col_ref("t")), batch)
    var m_nn = _eval_predicate(Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("t")), batch)
    assert_equal(m_null.true_count(), 0, "IS NULL over a bitmap-less column")
    assert_equal(m_nn.true_count(), 6, "IS NOT NULL over a bitmap-less column")
    print("PASS: absent validity bitmap -> all-valid, BOTH polarities")


# ===========================================================================
# ★ THE FIX — a COMPUTED child. Every assertion below RAISED before the change.
# ===========================================================================


def test_is_not_null_over_computed_child() raises:
    """`upper(s) IS NOT NULL`. Pre-fix: `IS_NOT_NULL only supports column
    references (got tag=24)`.

    ⚠ IT ALSO ASSERTS THAT `upper(NULL)` IS NULL rather than the empty
    string. The fixture stores `""` in the null slots (Arrow's contract:
    a null row still occupies an offset slot), so a kernel that read the
    slot contents instead of the validity bit would answer 6 here — a
    plausible number that is off by exactly the two rows the test is for.
    """
    var batch = _batch()
    var mask = _eval_predicate(
        Expr.unary(UN_IS_NOT_NULL, _upper_of("s")), batch
    )
    assert_equal(mask.true_count(), 4, "upper(s) IS NOT NULL: 4 of 6")
    print("PASS: IS NOT NULL over a computed (STRFN) child")


def test_is_null_over_computed_child() raises:
    """The other polarity of the same shape — and the PARTITION, which is
    what makes the pair self-checking: 2 + 4 = 6 with no row in both."""
    var batch = _batch()
    var m_null = _eval_predicate(Expr.unary(UN_IS_NULL, _upper_of("s")), batch)
    var m_nn = _eval_predicate(
        Expr.unary(UN_IS_NOT_NULL, _upper_of("s")), batch
    )
    assert_equal(m_null.true_count(), 2, "upper(s) IS NULL: 2 of 6")
    assert_equal(
        m_null.true_count() + m_nn.true_count(),
        6,
        "the two polarities must partition the six rows",
    )
    print("PASS: IS NULL over a computed child, and the pair partitions")


def test_null_test_over_literal_children() raises:
    """★ THE `coalesce(NULL, NULL, 3)` SHAPE. A LITERAL is not a column
    reference either, and it is what DuckDB's own documented example puts in
    the FIRST argument position.

    A NULL literal broadcasts to an all-null column, so `IS NOT NULL` is
    0 of 6; a value literal broadcasts to a bitmap-less column, so it is
    6 of 6 — which routes through the absent-bitmap branch again, this time
    reached from a materialized column rather than a resident one.
    """
    var batch = _batch()
    var lit_null = Expr.literal(ScalarValue.null(DType.int64))
    var lit_three = Expr.literal(ScalarValue.from_int64(3))

    var m_null_nn = _eval_predicate(
        Expr.unary(UN_IS_NOT_NULL, lit_null.copy()), batch
    )
    var m_three_nn = _eval_predicate(
        Expr.unary(UN_IS_NOT_NULL, lit_three.copy()), batch
    )
    assert_equal(m_null_nn.true_count(), 0, "NULL IS NOT NULL: never")
    assert_equal(m_three_nn.true_count(), 6, "3 IS NOT NULL: always")

    var m_null_isnull = _eval_predicate(
        Expr.unary(UN_IS_NULL, lit_null.copy()), batch
    )
    assert_equal(m_null_isnull.true_count(), 6, "NULL IS NULL: always")
    print("PASS: null tests over LITERAL children (the coalesce-of-NULLs shape)")


# ===========================================================================
# ★ THE WHOLE DESUGAR, END TO END — this is what `coalesce` compiles to.
# ===========================================================================


def test_coalesce_desugar_two_arg() raises:
    """`coalesce(s, 'Z')` = `CASE WHEN s IS NOT NULL THEN s ELSE 'Z' END`.

    Values, not just counts: rows 1 and 4 must be the literal and the rest
    must be their own content. A mask defect that inverted the polarity would
    keep the row COUNT at six and replace exactly the wrong four.
    """
    var batch = _batch()
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("s")), Expr.col_ref("s")
        )
    )
    var out = _eval_when_expr(
        Expr.when(cases^, Expr.literal(ScalarValue.from_string(String("Z")))),
        batch,
    )
    assert_equal(out.arrow_type, ArrowType.STRING, "coalesce(s,'Z') is Utf8")
    assert_equal(_str_at(out, 0), String("a"), "row 0 keeps its value")
    assert_equal(_str_at(out, 1), String("Z"), "row 1 was NULL -> 'Z'")
    assert_equal(_str_at(out, 2), String("c"), "row 2 keeps its value")
    assert_equal(_str_at(out, 3), String("d"), "row 3 keeps its value")
    assert_equal(_str_at(out, 4), String("Z"), "row 4 was NULL -> 'Z'")
    assert_equal(_str_at(out, 5), String("f"), "row 5 keeps its value")
    print("PASS: coalesce(s,'Z') desugar, VALUE by VALUE")


def test_coalesce_desugar_three_arg_computed_middle() raises:
    """★ `coalesce(s, upper(s), 'Z')` — THREE arguments, so TWO `WHEN`
    branches, and the middle one is COMPUTED.

    ⚠ THE SECOND BRANCH IS UNREACHABLE BY CONSTRUCTION AND THAT IS THE
    ASSERTION. `upper(NULL)` is NULL exactly when `s` is NULL, so whenever
    branch 1 fails branch 2 fails too and the ELSE must win. An executor that
    let a later branch overwrite an earlier winner, or that evaluated them in
    reverse, would answer the upper-cased value on the null rows instead of
    `'Z'` — and would still be green on any two-branch case whose branches
    can both fire.

    It is also the only place `len(cases) == 2` is exercised here: until a
    second element exists, "first", "last" and "only" are the same slot.
    """
    var batch = _batch()
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("s")), Expr.col_ref("s")
        )
    )
    cases.append(
        WhenCaseData(Expr.unary(UN_IS_NOT_NULL, _upper_of("s")), _upper_of("s"))
    )
    var out = _eval_when_expr(
        Expr.when(cases^, Expr.literal(ScalarValue.from_string(String("Z")))),
        batch,
    )
    assert_equal(_str_at(out, 0), String("a"), "row 0: branch 1")
    assert_equal(_str_at(out, 1), String("Z"), "row 1: BOTH branches fail")
    assert_equal(_str_at(out, 4), String("Z"), "row 4: BOTH branches fail")
    assert_equal(_str_at(out, 5), String("f"), "row 5: branch 1")
    print("PASS: coalesce(s, upper(s), 'Z') — two WHEN branches, ELSE wins")


def main() raises:
    print("=== IS NULL / IS NOT NULL over a COMPUTED child ===")
    test_col_ref_fast_path_unchanged()
    test_col_ref_no_validity_bitmap_polarity()
    test_is_not_null_over_computed_child()
    test_is_null_over_computed_child()
    test_null_test_over_literal_children()
    test_coalesce_desugar_two_arg()
    test_coalesce_desugar_three_arg_computed_middle()
    print()
    print("All computed-child null-test / coalesce-desugar tests PASS")
