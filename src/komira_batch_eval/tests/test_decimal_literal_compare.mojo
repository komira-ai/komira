# =============================================================================
# DECIMAL column vs literal predicates: every operator, literal scale, column
# width and row count, against an exact oracle
# =============================================================================
#
# `_eval_predicate` over `col <op> literal` for a DECIMAL128 column and a
# decimal or integer literal of any scale. The expected mask is computed here,
# row by row, in 256-bit integers by cross-multiplying the two fractions
# (`c / 10^s  <op>  V / 10^t`  is  `c * 10^t  <op>  V * 10^s`), so no
# rounding, flooring or ceiling is involved in the oracle. The oracle is a
# derivation from the definition of the comparison; the answers of the pinned
# DuckDB for the same comparisons through the SQL door are in
# komira_decimal_compare_conformance. The literals are the
# ones that matter to a rescale: more scale than the column (0.065 on a
# scale-2 column, for every operator), equal scale, less scale, integers,
# negatives, zero, and values past the int64 range of the unscaled integer.
# The columns are DECIMAL(15, 2), (18, 2), (19, 2), (38, 2), (18, 0), (18, 5)
# and (38, 10): precision 18 is the widest that fits an int64 unscaled, 19 the
# narrowest that may not. Row counts straddle the SIMD block sizes, and some
# rows are NULL.
#
# Where DuckDB cannot make the comparison the evaluator raises: DuckDB compares
# in DECIMAL(38, the larger of the two scales), and raises when the literal, or
# a stored non-NULL value widened to that scale, has 39 digits or more. The
# oracle derives that from the definition (|literal| * 10^(common - t) and
# |c| * 10^(common - s) against 10^38), row by row; the answers of the pinned
# DuckDB, errors included, are in komira_decimal_compare_conformance.
#
# What each test proves, and the defect it catches:
#   * test_every_literal_every_operator_every_column: the mask of every
#     (column, literal, operator, row count) equals the oracle's, or the
#     evaluator raises where the oracle says DuckDB would, and a NULL row is
#     NULL, not false. The integer literals include 10^15 (wider than the
#     precision of DECIMAL(15, 2)), the int64 limits and uint64 values past
#     Int64.MAX. Catches a literal rescaled by rounding, a wrong floor or ceil
#     for one operator, a sign error for a negative literal, a compare
#     narrowed to int64 for a column that does not fit, a tail of a SIMD block
#     left unevaluated, a NULL row that passes, an integer literal wider than
#     the column's precision raised on or answered wrongly, an answer where
#     DuckDB raises, and a refusal where DuckDB answers.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_batch_eval.eval_predicate import _eval_predicate
from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128, I256, pow10_i256


def _ops() -> List[UInt8]:
    var ops = List[UInt8]()
    ops.append(BIN_LT)
    ops.append(BIN_LE)
    ops.append(BIN_GT)
    ops.append(BIN_GE)
    ops.append(BIN_EQ)
    ops.append(BIN_NE)
    return ops^


def _op_text(op: UInt8) -> String:
    if op == BIN_LT:
        return "<"
    if op == BIN_LE:
        return "<="
    if op == BIN_GT:
        return ">"
    if op == BIN_GE:
        return ">="
    if op == BIN_EQ:
        return "="
    return "<>"


def _holds(lhs: I256, rhs: I256, op: UInt8) -> Bool:
    """`lhs <op> rhs`, where lhs = c * 10^t and rhs = v * 10^s."""
    if op == BIN_LT:
        return lhs < rhs
    if op == BIN_LE:
        return lhs <= rhs
    if op == BIN_GT:
        return lhs > rhs
    if op == BIN_GE:
        return lhs >= rhs
    if op == BIN_EQ:
        return lhs == rhs
    return lhs != rhs


struct _Literal(Copyable, Movable):
    """A literal of the sweep: its text, and unscaled value and scale. `scale`
    is -1 for an int64 literal and -2 for a uint64 literal (both compared at
    scale 0)."""

    var text: String
    var value: I128
    var scale: Int

    def __init__(out self, text: String, value: I128, scale: Int):
        self.text = text
        self.value = value
        self.scale = scale

    def scalar(self) -> ScalarValue:
        if self.scale == -2:
            return ScalarValue.from_uint64(self.value.cast[DType.uint64]())
        if self.scale < 0:
            return ScalarValue.from_int(Int(self.value.cast[DType.int64]()))
        return ScalarValue.decimal128_i128(self.value, 38, self.scale)

    def lit_scale(self) -> Int:
        if self.scale < 0:
            return 0
        return self.scale


def _lit(text: String, value: Int, scale: Int) -> _Literal:
    return _Literal(text, I128(value), scale)


def _literals() raises -> List[_Literal]:
    var out = List[_Literal]()
    # More scale than a scale-2 column, positive and negative, on and between
    # the steps (0.06 is a step; 0.065 is half way to the next).
    out.append(_lit("0.065", 65, 3))
    out.append(_lit("0.055", 55, 3))
    out.append(_lit("-0.065", -65, 3))
    out.append(_lit("-0.055", -55, 3))
    out.append(_lit("0.0649", 649, 4))
    out.append(_lit("0.0651", 651, 4))
    out.append(_lit("0.0000001", 1, 7))
    out.append(_lit("-0.0000001", -1, 7))
    out.append(_lit("23.995", 23995, 3))
    out.append(_lit("24.005", 24005, 3))
    out.append(_lit("0.060", 60, 3))
    out.append(_lit("0.0600", 600, 4))
    out.append(_lit("-7.000", -7000, 3))
    # The column's own scale.
    out.append(_lit("0.06", 6, 2))
    out.append(_lit("0.05", 5, 2))
    out.append(_lit("0.07", 7, 2))
    out.append(_lit("-0.06", -6, 2))
    out.append(_lit("0.00", 0, 2))
    out.append(_lit("24.00", 2400, 2))
    # Less scale than the column.
    out.append(_lit("0.1", 1, 1))
    out.append(_lit("-0.5", -5, 1))
    out.append(_lit("0.0", 0, 1))
    # Integers, as an integer literal.
    out.append(_lit("0", 0, -1))
    out.append(_lit("1", 1, -1))
    out.append(_lit("-1", -1, -1))
    out.append(_lit("24", 24, -1))
    out.append(_lit("-7", -7, -1))
    out.append(_lit("10", 10, -1))
    # Integers wider than a narrow column's precision: DECIMAL(15, 2) holds
    # 13 integer digits. DuckDB casts them to DECIMAL(38, 2) and compares.
    out.append(_lit("10^15", 1000000000000000, -1))
    out.append(_lit("-10^15", -1000000000000000, -1))
    out.append(_Literal("Int64.MAX", I128(Int(Int64.MAX)), -1))
    out.append(_Literal("Int64.MIN", -I128(Int(Int64.MAX)) - I128(1), -1))
    out.append(_Literal("2^63 (uint64)", I128(Int(Int64.MAX)) + I128(1), -2))
    out.append(_Literal("2^64-1 (uint64)", I128(Int(Int64.MAX)) * I128(2) + I128(1), -2))
    # Past the int64 range of the unscaled integer, at the column's scale
    # (scale 2: 92233720368547758.07 is 2^63 - 1 hundredths) and beyond it.
    out.append(_Literal("2^63-1 @2", I128(Int(Int64.MAX)), 2))
    out.append(_Literal("2^63 @2", I128(Int(Int64.MAX)) + I128(1), 2))
    out.append(_Literal("-2^63 @2", -I128(Int(Int64.MAX)) - I128(1), 2))
    out.append(_Literal("-2^63-1 @2", -I128(Int(Int64.MAX)) - I128(2), 2))
    out.append(_Literal("2^63-1 @3", I128(Int(Int64.MAX)), 3))
    out.append(_Literal("-2^63 @3", -I128(Int(Int64.MAX)) - I128(1), 3))
    out.append(_Literal("10^18 @2", pow10_i256(18).cast[DType.int128](), 2))
    out.append(_Literal("10^18-1 @2", pow10_i256(18).cast[DType.int128]() - I128(1), 2))
    out.append(_Literal("-10^18 @2", -pow10_i256(18).cast[DType.int128](), 2))
    out.append(_Literal("10^30 @0", pow10_i256(30).cast[DType.int128](), 0))
    out.append(_Literal("-10^30 @0", -pow10_i256(30).cast[DType.int128](), 0))
    out.append(_Literal("10^37 @2", pow10_i256(37).cast[DType.int128](), 2))
    out.append(_Literal("-10^37 @2", -pow10_i256(37).cast[DType.int128](), 2))
    return out^


def _small_values() -> List[Int]:
    """Unscaled column values around the steps the literals sit on."""
    var v = List[Int]()
    for x in [
        -1000, -701, -700, -699, -651, -650, -649, -600, -551, -550, -501,
        -500, -499, -100, -99, -10, -7, -6, -5, -1, 0, 1, 5, 6, 7, 8, 10, 49,
        50, 51, 64, 65, 66, 99, 100, 101, 599, 600, 601, 649, 650, 651, 699,
        700, 701, 2399, 2400, 2401, 23995, 24005,
    ]:
        v.append(x)
    return v^


def _wide_values(precision: Int) raises -> List[I128]:
    """Values of a column of `precision` digits that lie past int64 or on its
    edge, empty when the precision fits an int64."""
    var out = List[I128]()
    if precision < 19:
        return out^
    var m = I128(Int(Int64.MAX))
    out.append(m - I128(1))
    out.append(m)
    out.append(m + I128(1))
    out.append(-m)
    out.append(-m - I128(1))
    out.append(-m - I128(2))
    var e18 = pow10_i256(18).cast[DType.int128]()
    out.append(e18 - I128(1))
    out.append(e18)
    out.append(-e18)
    out.append(-e18 + I128(1))
    var top = pow10_i256(precision).cast[DType.int256]() - I256(1)
    out.append(top.cast[DType.int128]())
    out.append((-top).cast[DType.int128]())
    out.append((top - I256(1)).cast[DType.int128]())
    return out^


def _column_values(precision: Int, n: Int) raises -> List[I128]:
    var small = _small_values()
    var wide = _wide_values(precision)
    var pool = List[I128]()
    for i in range(len(small)):
        pool.append(I128(small[i]))
    for i in range(len(wide)):
        pool.append(wide[i])
    var out = List[I128]()
    for i in range(n):
        out.append(pool[(i * 7 + i // len(pool)) % len(pool)])
    return out^


def _is_null_row(i: Int) -> Bool:
    return i % 5 == 3


def _batch(
    values: List[I128], precision: Int, scale: Int, with_nulls: Bool
) raises -> RecordBatch:
    var n = len(values)
    var arr = Decimal128Array.allocate(n, precision, scale)
    if with_nulls:
        arr = Decimal128Array.allocate_nullable(n, precision, scale)
    for i in range(n):
        arr.set_i128(i, values[i])
    if with_nulls:
        for i in range(n):
            if _is_null_row(i):
                arr.set_null(i)
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128(String("d"), precision, scale, with_nulls))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_decimal128(arr^))
    return rbb.build(sb.build())


struct _Shape(Copyable, Movable):
    var precision: Int
    var scale: Int

    def __init__(out self, precision: Int, scale: Int):
        self.precision = precision
        self.scale = scale


def _shapes() -> List[_Shape]:
    var out = List[_Shape]()
    out.append(_Shape(15, 2))
    out.append(_Shape(18, 2))
    out.append(_Shape(19, 2))
    out.append(_Shape(38, 2))
    out.append(_Shape(18, 0))
    out.append(_Shape(18, 5))
    out.append(_Shape(38, 10))
    return out^


struct _Tally(Movable):
    var true_by_op: List[Int]
    var false_by_op: List[Int]
    var checked: Int
    var refused: Int

    def __init__(out self):
        self.true_by_op = List[Int]()
        self.false_by_op = List[Int]()
        for _ in range(6):
            self.true_by_op.append(0)
            self.false_by_op.append(0)
        self.checked = 0
        self.refused = 0


def _duckdb_raises(
    lit: _Literal, sh: _Shape, values: List[I128], nulls: Bool
) raises -> Bool:
    """True iff DuckDB cannot make `d <op> literal`: it compares in
    DECIMAL(38, c) with c the larger of the two scales, and raises when the
    literal, or a stored non-NULL value, has 39 digits or more at scale c."""
    var limit = pow10_i256(38)
    var common = max(lit.lit_scale(), sh.scale)
    var lit_at_common = lit.value.cast[DType.int256]() * pow10_i256(
        common - lit.lit_scale()
    )
    if lit_at_common >= limit or lit_at_common <= -limit:
        return True
    var factor = pow10_i256(common - sh.scale)
    for i in range(len(values)):
        if nulls and _is_null_row(i):
            continue
        var widened = values[i].cast[DType.int256]() * factor
        if widened >= limit or widened <= -limit:
            return True
    return False


def _sweep(mut problems: List[String], mut tally: _Tally) raises:
    var ops = _ops()
    var lits = _literals()
    var shapes = _shapes()
    var sizes = [1, 8, 9, 17, 40]
    for si in range(len(shapes)):
        var sh = shapes[si].copy()
        for n in sizes:
            for nulls in [False, True]:
                var values = _column_values(sh.precision, n)
                var batch = _batch(values, sh.precision, sh.scale, nulls)
                for li in range(len(lits)):
                    ref lit = lits[li]
                    var col_mul = pow10_i256(lit.lit_scale())
                    var lit_mul = pow10_i256(sh.scale)
                    var rhs = lit.value.cast[DType.int256]() * lit_mul
                    var refuses = _duckdb_raises(lit, sh, values, nulls)
                    for oi in range(len(ops)):
                        var op = ops[oi]
                        var e = Expr.binary(
                            op, Expr.col_ref("d"), Expr.literal(lit.scalar())
                        )
                        if refuses:
                            tally.refused += 1
                            var raised = False
                            try:
                                _ = _eval_predicate(e, batch)
                            except:
                                raised = True
                            if not raised:
                                problems.append(
                                    "DECIMAL("
                                    + String(sh.precision)
                                    + ","
                                    + String(sh.scale)
                                    + ") n="
                                    + String(n)
                                    + ": DuckDB raises on `d "
                                    + _op_text(op)
                                    + " "
                                    + lit.text
                                    + "`, the evaluator answers"
                                )
                            continue
                        var mask = _eval_predicate(e, batch)
                        assert_equal(len(mask), n)
                        for i in range(n):
                            tally.checked += 1
                            var expect_null = nulls and _is_null_row(i)
                            if expect_null:
                                if not mask.is_null(i):
                                    problems.append(
                                        "DECIMAL("
                                        + String(sh.precision)
                                        + ","
                                        + String(sh.scale)
                                        + ") row "
                                        + String(i)
                                        + " is NULL but `d "
                                        + _op_text(op)
                                        + " "
                                        + lit.text
                                        + "` is not"
                                    )
                                continue
                            var want = _holds(
                                values[i].cast[DType.int256]() * col_mul, rhs, op
                            )
                            if want:
                                tally.true_by_op[oi] += 1
                            else:
                                tally.false_by_op[oi] += 1
                            if mask.is_null(i) or mask.get(i) != want:
                                problems.append(
                                    "DECIMAL("
                                    + String(sh.precision)
                                    + ","
                                    + String(sh.scale)
                                    + ") n="
                                    + String(n)
                                    + " row "
                                    + String(i)
                                    + " value "
                                    + String(Int(values[i].cast[DType.int64]()))
                                    + " (unscaled, low word): `d "
                                    + _op_text(op)
                                    + " "
                                    + lit.text
                                    + "` should be "
                                    + String(want)
                                )


def _report(problems: List[String]) raises:
    if len(problems) == 0:
        return
    var text = String(len(problems)) + " rows differ from the oracle:\n"
    for i in range(min(len(problems), 30)):
        text += "  " + problems[i] + "\n"
    assert_true(False, text)


def test_every_literal_every_operator_every_column() raises:
    var problems = List[String]()
    var tally = _Tally()
    _sweep(problems, tally)
    assert_true(tally.checked > 100000, "the sweep checked too few rows")
    # Some comparisons are ones DuckDB raises on, and most are not.
    assert_true(tally.refused > 500, "the sweep held too few refusals")
    assert_true(tally.refused * 4 < tally.checked, "the sweep refused most of its cases")
    # The sweep holds both answers for every operator, so an oracle or a
    # table that degenerated into one answer cannot pass.
    for oi in range(6):
        assert_true(tally.true_by_op[oi] > 100, "an operator never held")
        assert_true(tally.false_by_op[oi] > 100, "an operator never failed")
    _report(problems)


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_literal_every_operator_every_column]()
    suite^.run()
