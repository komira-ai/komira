# =============================================================================
# DECIMAL column vs FLOAT64 literal: compared in doubles, as DuckDB compares
# them
# =============================================================================
#
# DuckDB compares a DECIMAL column with a DOUBLE literal in DOUBLE: each stored
# value c becomes `double(c) / 10^scale` and meets the literal as it is. A
# literal between two steps of the column keeps its place there (`x = 0.015` on
# a scale-2 column keeps no row, `x < 0.015` keeps the rows up to 0.01), and a
# literal one ulp past a step (0.30000000000000004) is above the row holding
# 0.30. The evaluator rounded such a literal to the column's scale before
# comparing, which kept the 0.02 row for `x = 0.015`.
#
# What each test proves, and the defect it catches:
#   * test_a_float_between_two_steps_keeps_its_place: 0.015 on a scale-2
#     column of 0.00, 0.01, 0.02, 0.30, 0.31 and a NULL, every operator.
#     Catches a literal rounded to the column's scale (the `=` row, and `<`
#     and `>` moving by a step).
#   * test_a_float_one_ulp_off_a_step_is_not_that_step: 0.3 matches the 0.30
#     row; 0.30000000000000004 and 0.29999999999999993 do not, and order
#     against it on the correct side. Catches a rounding of the literal to
#     two digits.
#   * test_a_wider_scale: a scale-5 column against 0.12345 (a step) and
#     0.123455 (between steps). Catches a scale taken as 2.
#   * test_nan_and_infinite_literals_are_refused: they have no place among
#     the steps.
#   * test_a_stored_value_past_2_53_converts_in_parts: DuckDB converts a stored
#     value past 2^53 unscaled as integer part plus fraction part; 2^53 + 1 and
#     2^53 + 2 hundredths both read 90071992547409.9375, 2^53 reads
#     90071992547409.92. Catches one division of the whole value, which gives
#     ...409.92 for 2^53 + 1.
#   * test_a_buffer_shorter_than_the_length_is_refused_before_any_read: nine rows
#     claimed over two held, with a float literal, an over-scale decimal literal
#     on a wide column and an integer literal. Catches a read past the buffer by
#     the float loop or the widening scan, which ran before the kernel's check.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_batch_eval.eval_predicate import _eval_predicate
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_plan_expr.expr import (
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128


def _batch(values: List[Int], precision: Int, scale: Int, null_row: Int) raises -> RecordBatch:
    var n = len(values)
    var arr = Decimal128Array.allocate_nullable(n, precision, scale)
    for i in range(n):
        arr.set_i128(i, I128(values[i]))
    if null_row >= 0:
        arr.set_null(null_row)
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128(String("d"), precision, scale, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_decimal128(arr^))
    return rbb.build(sb.build())


def _mask(batch: RecordBatch, op: UInt8, literal: Float64) raises -> String:
    """The predicate `d <op> literal` as one character per row: T, F or N."""
    var e = Expr.binary(op, Expr.col_ref("d"), Expr.literal(ScalarValue.from_float(literal)))
    var mask = _eval_predicate(e, batch)
    var out = String("")
    for i in range(len(mask)):
        if mask.is_null(i):
            out += "N"
        elif mask.get(i):
            out += "T"
        else:
            out += "F"
    return out^


def _all_ops(batch: RecordBatch, literal: Float64, lt: String, le: String, gt: String, ge: String, eq: String, ne: String) raises:
    var label = String(literal)
    assert_equal(_mask(batch, BIN_LT, literal), lt, "< " + label)
    assert_equal(_mask(batch, BIN_LE, literal), le, "<= " + label)
    assert_equal(_mask(batch, BIN_GT, literal), gt, "> " + label)
    assert_equal(_mask(batch, BIN_GE, literal), ge, ">= " + label)
    assert_equal(_mask(batch, BIN_EQ, literal), eq, "= " + label)
    assert_equal(_mask(batch, BIN_NE, literal), ne, "<> " + label)


def test_a_float_between_two_steps_keeps_its_place() raises:
    # 0.00, 0.01, 0.02, 0.30, 0.31, NULL
    var batch = _batch([0, 1, 2, 30, 31, 0], 15, 2, 5)
    _all_ops(batch, 0.015, "TTFFFN", "TTFFFN", "FFTTTN", "FFTTTN", "FFFFFN", "TTTTTN")
    _all_ops(batch, 0.005, "TFFFFN", "TFFFFN", "FTTTTN", "FTTTTN", "FFFFFN", "TTTTTN")
    _all_ops(batch, -0.005, "FFFFFN", "FFFFFN", "TTTTTN", "TTTTTN", "FFFFFN", "TTTTTN")
    # A literal that is a step.
    _all_ops(batch, 0.02, "TTFFFN", "TTTFFN", "FFFTTN", "FFTTTN", "FFTFFN", "TTFTTN")


def test_a_float_one_ulp_off_a_step_is_not_that_step() raises:
    var batch = _batch([0, 1, 2, 30, 31, 0], 15, 2, 5)
    _all_ops(batch, 0.3, "TTTFFN", "TTTTFN", "FFFFTN", "FFFTTN", "FFFTFN", "TTTFTN")
    # 0.30000000000000004 is the double after 0.3: above the 0.30 row.
    _all_ops(batch, 0.30000000000000004, "TTTTFN", "TTTTFN", "FFFFTN", "FFFFTN", "FFFFFN", "TTTTTN")
    # 0.29999999999999993 is the double before 0.3: below the 0.30 row.
    _all_ops(batch, 0.29999999999999993, "TTTFFN", "TTTFFN", "FFFTTN", "FFFTTN", "FFFFFN", "TTTTTN")


def test_a_wider_scale() raises:
    # 0.12344, 0.12345, 0.12346 at scale 5.
    var batch = _batch([12344, 12345, 12346], 18, 5, -1)
    _all_ops(batch, 0.12345, "TFF", "TTF", "FFT", "FTT", "FTF", "TFT")
    _all_ops(batch, 0.123455, "TTF", "TTF", "FFT", "FFT", "FFF", "TTT")


def test_nan_and_infinite_literals_are_refused() raises:
    var batch = _batch([1, 2], 15, 2, -1)
    var refused = 0
    for v in [Float64(1.0e308) * 10.0, -(Float64(1.0e308) * 10.0)]:
        try:
            _ = _mask(batch, BIN_LT, v)
        except:
            refused += 1
    assert_equal(refused, 2)


def _wide_batch(values: List[I128], precision: Int, scale: Int) raises -> RecordBatch:
    var arr = Decimal128Array.allocate(len(values), precision, scale)
    for i in range(len(values)):
        arr.set_i128(i, values[i])
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128(String("d"), precision, scale, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_decimal128(arr^))
    return rbb.build(sb.build())


def test_a_stored_value_past_2_53_converts_in_parts() raises:
    # DuckDB converts a DECIMAL of more than 2^53 unscaled to a double as its
    # integer part plus its fraction part over 10^scale, not as one double over
    # 10^scale. 2^53 + 1 hundredths is 90071992547409.93: apart it is
    # 90071992547409 + 0.93 = 90071992547409.9375; as one double it would be
    # 9007199254740992 / 100 = 90071992547409.92. 2^53 itself is not past it.
    var two53 = I128(9007199254740992)
    var values = List[I128]()
    values.append(two53 + I128(1))
    values.append(two53)
    values.append(two53 + I128(2))
    for p in [18, 19, 38]:
        var batch = _wide_batch(values, p, 2)
        assert_equal(_mask(batch, BIN_EQ, 90071992547409.9375), "TFT", "DECIMAL(" + String(p) + ", 2)")
        assert_equal(_mask(batch, BIN_LT, 90071992547409.9375), "FTF", "<")
        assert_equal(_mask(batch, BIN_EQ, 90071992547409.921875), "FTF", "= .921875")
    # A scale-0 column is one double however large: 2^53 + 1 is 2^53.
    var integers = _wide_batch(values, 18, 0)
    assert_equal(_mask(integers, BIN_EQ, 9007199254740992.0), "TTF")
    # A negative value is converted by parts the same way.
    var negative = List[I128]()
    negative.append(-two53 - I128(1))
    assert_equal(_mask(_wide_batch(negative, 18, 2), BIN_EQ, -90071992547409.9375), "T")


def _short_batch(precision: Int, scale: Int, claimed: Int) raises -> RecordBatch:
    """A column that claims `claimed` rows over a buffer of two."""
    var buf = OwnedAlignedBuffer(32)
    buf.zero()
    buf.set_length(Int64(32))
    var arr = Decimal128Array(buf^, Optional[Bitmap[HeapRegion]](None), claimed, 0, precision, scale)
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128(String("d"), precision, scale, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_decimal128(arr^))
    return rbb.build(sb.build())


def _raises(batch: RecordBatch, literal: ScalarValue) -> Bool:
    var e = Expr.binary(BIN_LT, Expr.col_ref("d"), Expr.literal(literal.copy()))
    try:
        _ = _eval_predicate(e, batch)
    except:
        return True
    return False


def test_a_buffer_shorter_than_the_length_is_refused_before_any_read() raises:
    # Nine rows claimed, two held. Every path that reads the column checks the
    # buffer first: the float loop, the scan for a value that does not widen,
    # and the kernel.
    assert_true(_raises(_short_batch(15, 2, 9), ScalarValue.from_float(0.5)), "float literal")
    # A decimal literal with more scale than a DECIMAL(38, 2) column: the column
    # is scanned for a value that does not widen.
    assert_true(
        _raises(_short_batch(38, 2, 9), ScalarValue.decimal128(Int64(0), Int64(1), 6, 5)),
        "widening scan",
    )
    assert_true(_raises(_short_batch(15, 2, 9), ScalarValue.from_int(1)), "kernel")
    assert_true(_raises(_short_batch(38, 2, 9), ScalarValue.from_int(1)), "wide kernel")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_float_between_two_steps_keeps_its_place]()
    suite.test[test_a_float_one_ulp_off_a_step_is_not_that_step]()
    suite.test[test_a_wider_scale]()
    suite.test[test_nan_and_infinite_literals_are_refused]()
    suite.test[test_a_stored_value_past_2_53_converts_in_parts]()
    suite.test[test_a_buffer_shorter_than_the_length_is_refused_before_any_read]()
    suite^.run()
