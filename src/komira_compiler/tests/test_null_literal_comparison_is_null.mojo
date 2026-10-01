# =============================================================================
# test_null_literal_comparison_is_null — `x OP NULL` is NULL, not FALSE
# =============================================================================
#
# REGRESSION GUARD for
# the two `col OP <NULL literal>` gates in `compiler_eval_predicate.
# _eval_predicate` (the bare-column one and the computed-LHS one).
#
# THE DEFECT. Both gates answered a comparison against a NULL literal with an
# all-FALSE mask and NO validity — "the predicate never holds -> drop all rows".
# The ROW SET is right for a bare WHERE, and wrong the moment anything reads the
# VALUE: `NOT (x = NULL)` became TRUE on every row (DuckDB: NULL, the WHERE
# selects nothing), `(x = NULL) OR (x = 1)` answered FALSE where it is NULL, and
# the projection arm (`compiler_eval_column` routes every comparison against a
# literal through `_eval_predicate`) returned FALSE for a value DuckDB returns
# NULL. That is SQL's `x NOT IN (1, NULL)` / `NOT (x IN (1, NULL))`, desugared.
#
# The fix answers `kleene_all_null_predicate` — the decimal arm's answer for the
# same question, i.e. data 0 + validity 0 on every row, which
# still drops every row in a WHERE and reads as UNKNOWN to NOT / AND / OR.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.column import Column
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.schema import SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.plan.expr import Expr, UN_NOT, BIN_EQ, BIN_NE, BIN_LT, BIN_OR, BIN_ADD
from komira_core.plan.scalar_value import ScalarValue

from komira_compiler.compiler_eval_predicate import _eval_predicate


def _batch() raises -> RecordBatch:
    """`k int64 = [1, 2, NULL(payload 0), 4]`, `s string = [a, b, NULL, d]`."""
    comptime n = 4
    comptime elem = size_of[Scalar[DType.int64]]()
    var raw: List[Int64] = [1, 2, 0, 4]
    var buf = OwnedAlignedBuffer(n * elem)
    for i in range(n):
        buf.set_typed[Scalar[DType.int64]](i, Scalar[DType.int64](raw[i]))
    buf.set_length(Int64(n * elem))
    var bm = Bitmap.create_all_valid(n)
    bm.clear(2)
    var karr = PrimitiveArray[DType.int64](
        buf^, n, Optional[Bitmap[HeapRegion]](bm^), 1, 0
    )
    var sa = StringArray.from_strings(["a", "b", "", "d"])
    var sbm = Bitmap.create_all_valid(n)
    sbm.clear(2)
    sa.validity = sbm^
    sa.null_count = 1
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    rbb.add_column(Column.from_string(sa^))
    return rbb.build(sb.build())


comptime T = 1
comptime F = 0
comptime N = -1


def _check(got: BooleanArray, want: List[Int], what: String) raises:
    assert_equal(got.length, len(want), what + ": length")
    for i in range(len(want)):
        var is_null = got.validity and not got.validity.value().test(i)
        if want[i] == N:
            assert_true(is_null, what + ": row " + String(i) + " must be NULL")
            assert_false(got.data.test(i), what + ": row " + String(i) + " NULL with data 1")
        else:
            assert_false(is_null, what + ": row " + String(i) + " must be valid")
            assert_equal(got.data.test(i), want[i] == T, what + ": row " + String(i))


def _null() -> Expr:
    return Expr.literal(ScalarValue.null(DType.int64))


def _k() -> Expr:
    return Expr.col_ref("k")


def test_col_eq_null_is_null_on_every_row() raises:
    _check(_eval_predicate(Expr.binary(BIN_EQ, _k(), _null()), _batch()), [N, N, N, N], "k = NULL")


def test_not_col_eq_null_selects_nothing() raises:
    """Pre-fix: all-FALSE with no validity, which NOT turned into all-TRUE."""
    var e = Expr.unary(UN_NOT, Expr.binary(BIN_EQ, _k(), _null()))
    _check(_eval_predicate(e, _batch()), [N, N, N, N], "NOT (k = NULL)")


def test_not_col_ne_null_selects_nothing() raises:
    var e = Expr.unary(UN_NOT, Expr.binary(BIN_NE, _k(), _null()))
    _check(_eval_predicate(e, _batch()), [N, N, N, N], "NOT (k <> NULL)")


def test_string_col_vs_null_is_null() raises:
    var e = Expr.unary(UN_NOT, Expr.binary(BIN_LT, Expr.col_ref("s"), _null()))
    _check(_eval_predicate(e, _batch()), [N, N, N, N], "NOT (s < NULL)")


def test_computed_lhs_vs_null_is_null() raises:
    """The computed-LHS gate (`k + 1 = NULL`)."""
    var lhs = Expr.binary(BIN_ADD, _k(), Expr.literal(ScalarValue.from_int64(1)))
    var e = Expr.unary(UN_NOT, Expr.binary(BIN_EQ, lhs^, _null()))
    _check(_eval_predicate(e, _batch()), [N, N, N, N], "NOT (k + 1 = NULL)")


def test_null_or_true_is_true_and_its_negation_false() raises:
    """`(k = NULL) OR (k = 1)` — SQL's `k IN (1, NULL)` desugared: TRUE where
    k = 1, NULL elsewhere; and its NOT (`k NOT IN (1, NULL)`) FALSE / NULL."""
    var one = Expr.literal(ScalarValue.from_int64(1))
    var e = Expr.binary(
        BIN_OR, Expr.binary(BIN_EQ, _k(), _null()), Expr.binary(BIN_EQ, _k(), one^)
    )
    _check(_eval_predicate(e.copy(), _batch()), [T, N, N, N], "(k = NULL) OR (k = 1)")
    _check(
        _eval_predicate(Expr.unary(UN_NOT, e^), _batch()), [F, N, N, N],
        "NOT ((k = NULL) OR (k = 1))",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
