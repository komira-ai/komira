# =============================================================================
# Evaluating text -> DATE / TIMESTAMP: the EXPR_CAST and strptime arms
# =============================================================================
#
# What it proves, through `_eval_column_expr` (the projection evaluator):
#   * CAST(<text> AS DATE) is a DATE32 column of DuckDB's day counts and
#     CAST(<text> AS TIMESTAMP) a TIMESTAMP_US column of its microseconds,
#     with NULL in -> NULL out; the text is parsed, not read as an integer
#     (DATE32 and TIMESTAMP_US share a physical type with INT32 / INT64);
#   * a strict cast raises DuckDB's conversion error for text that does not
#     parse, and TRY_CAST answers NULL for that row;
#   * a dictionary-encoded text column casts like the plain one;
#   * a text cast to a timestamp of another unit is refused by name;
#   * strptime / try_strptime produce TIMESTAMP_US, raise or NULL a row that
#     does not match, and refuse a format that is not a literal.
# Expected values are DuckDB v1.5's answers for the same text.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.dictionary_array import StringDictionaryArray
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from plan_expr.expr import Expr, STRFNN_STRPTIME, STRFNN_TRY_STRPTIME
from plan_expr.scalar_value import ScalarValue

from batch_eval.eval_column import _eval_column_expr


def _batch(var c: Column[HeapRegion], name: String) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _text_batch(vals: List[String], valid: List[Bool]) raises -> RecordBatch:
    return _batch(Column.from_string(StringArray.from_strings_with_validity(vals, valid)), "s")


def _iso_batch() raises -> RecordBatch:
    """'2026-09-15', NULL, ' 2026-9-5 ', '2026-09-15 10:11:12'."""
    return _text_batch(
        [String("2026-09-15"), String(""), String(" 2026-9-5 "), String("2026-09-15 10:11:12")],
        [True, False, True, True],
    )


def _bad_batch() raises -> RecordBatch:
    """'2026-09-15', 'not a date', '2026-02-30', NULL."""
    return _text_batch(
        [String("2026-09-15"), String("not a date"), String("2026-02-30"), String("")],
        [True, True, True, False],
    )


def _try_cast(arrow: ArrowType) -> Expr:
    var phys = DType.int32 if arrow == ArrowType.DATE32 else DType.int64
    return Expr.cast_from_parts(Expr.col_ref("s"), phys, arrow, 0, 0, True)


def _error_of(e: Expr, batch: RecordBatch) raises -> String:
    try:
        _ = _eval_column_expr(e, batch)
    except err:
        return String(err)
    return "no error"


def test_cast_text_to_date_is_a_date32_of_duckdbs_days() raises:
    """ISO text (with DuckDB's looser shapes) becomes DuckDB's day counts in
    a DATE32 column; the NULL row stays NULL."""
    var out = _eval_column_expr(Expr.cast_to_arrow(Expr.col_ref("s"), ArrowType.DATE32), _iso_batch())
    assert_true(out.arrow_type == ArrowType.DATE32)
    var a = out.as_primitive[DType.int32]()
    assert_equal(a.get(0), Int32(20711))
    assert_true(a.is_null(1))
    assert_equal(a.get(2), Int32(20701))
    assert_equal(a.get(3), Int32(20711))


def test_cast_text_to_timestamp_is_a_timestamp_us_of_duckdbs_micros() raises:
    """The same text as TIMESTAMP: midnight for a date alone, the time of day
    when it is written; a TIMESTAMP_US column."""
    var out = _eval_column_expr(
        Expr.cast_to_arrow(Expr.col_ref("s"), ArrowType.TIMESTAMP_US), _iso_batch()
    )
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_US)
    var a = out.as_primitive[DType.int64]()
    assert_equal(a.get(0), Int64(1789430400000000))
    assert_true(a.is_null(1))
    assert_equal(a.get(2), Int64(1788566400000000))
    assert_equal(a.get(3), Int64(1789467072000000))


def test_strict_cast_raises_duckdbs_error_and_try_cast_nulls_the_row() raises:
    """'not a date' and Feb 30 raise DuckDB's error under CAST; under
    TRY_CAST both are NULL and the good row keeps its value."""
    assert_equal(
        _error_of(Expr.cast_to_arrow(Expr.col_ref("s"), ArrowType.DATE32), _bad_batch()),
        "Conversion Error: invalid date field format: \"not a date\", expected format is (YYYY-MM-DD)",
    )
    var feb30 = _text_batch([String("2026-02-30")], [True])
    assert_equal(
        _error_of(Expr.cast_to_arrow(Expr.col_ref("s"), ArrowType.DATE32), feb30),
        "Conversion Error: date field value out of range: \"2026-02-30\"",
    )
    assert_equal(
        _error_of(Expr.cast_to_arrow(Expr.col_ref("s"), ArrowType.TIMESTAMP_US), feb30),
        "Conversion Error: timestamp field value out of range: \"2026-02-30\"",
    )
    var d = _eval_column_expr(_try_cast(ArrowType.DATE32), _bad_batch())
    assert_true(d.arrow_type == ArrowType.DATE32)
    var da = d.as_primitive[DType.int32]()
    assert_equal(da.get(0), Int32(20711))
    assert_true(da.is_null(1))
    assert_true(da.is_null(2))
    assert_true(da.is_null(3))
    var t = _eval_column_expr(_try_cast(ArrowType.TIMESTAMP_US), _bad_batch())
    assert_true(t.arrow_type == ArrowType.TIMESTAMP_US)
    var ta = t.as_primitive[DType.int64]()
    assert_equal(ta.get(0), Int64(1789430400000000))
    assert_true(ta.is_null(1))
    assert_true(ta.is_null(2))


def test_dictionary_text_column_casts_like_plain_text() raises:
    """A dictionary-encoded text column (codes 1, 0, null, 1 over
    ['2026-09-15', '2026-12-31']) casts to the same days."""
    var codes = PrimitiveArray[DType.int32].allocate_nullable(4)
    codes.set(0, Int32(1))
    codes.set(1, Int32(0))
    codes.set(2, Int32(0))
    codes.validity.value().clear(2)
    codes.null_count = 1
    codes.set(3, Int32(1))
    var col = Column.from_dictionary(
        StringDictionaryArray(
            codes^, StringArray.from_strings([String("2026-09-15"), String("2026-12-31")]), 4
        )
    )
    var out = _eval_column_expr(
        Expr.cast_to_arrow(Expr.col_ref("s"), ArrowType.DATE32), _batch(col^, "s")
    )
    assert_true(out.arrow_type == ArrowType.DATE32)
    var a = out.as_primitive[DType.int32]()
    assert_equal(a.get(0), Int32(20818))
    assert_equal(a.get(1), Int32(20711))
    assert_true(a.is_null(2))
    assert_equal(a.get(3), Int32(20818))


def test_text_to_another_timestamp_unit_is_refused_by_name() raises:
    """Text is parsed to DATE or TIMESTAMP (microseconds) only."""
    assert_equal(
        _error_of(Expr.cast_to_arrow(Expr.col_ref("s"), ArrowType.TIMESTAMP_NS), _iso_batch()),
        "SQL not supported: a cast from text to " + String(ArrowType.TIMESTAMP_NS)
        + ". Text is parsed to DATE or to TIMESTAMP (microseconds), the two text"
        " casts DuckDB's CAST serves with this grammar; cast the TIMESTAMP to"
        " another unit afterwards.",
    )


def _strptime(op: UInt8, var fmt: Expr) -> Expr:
    var args = List[Expr]()
    args.append(Expr.col_ref("s"))
    args.append(fmt^)
    return Expr.string_fn_n(op, args^)


def test_strptime_parses_by_format_into_timestamp_us() raises:
    """`strptime(s, '%m/%d/%Y')` is a TIMESTAMP_US column; NULL stays NULL."""
    var batch = _text_batch(
        [String("09/15/2026"), String(""), String("9/5/2026")], [True, False, True]
    )
    var out = _eval_column_expr(
        _strptime(STRFNN_STRPTIME, Expr.literal(ScalarValue.from_string("%m/%d/%Y"))), batch
    )
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_US)
    var a = out.as_primitive[DType.int64]()
    assert_equal(a.get(0), Int64(1789430400000000))
    assert_true(a.is_null(1))
    assert_equal(a.get(2), Int64(1788566400000000))


def test_strptime_raises_and_try_strptime_nulls_a_row_that_does_not_match() raises:
    """'13/01/2026' has no month 13: strptime raises DuckDB's message,
    try_strptime answers NULL for it and keeps the matching row."""
    var batch = _text_batch([String("09/15/2026"), String("13/01/2026")], [True, True])
    assert_equal(
        _error_of(_strptime(STRFNN_STRPTIME, Expr.literal(ScalarValue.from_string("%m/%d/%Y"))), batch),
        "Invalid Input Error: Could not parse string \"13/01/2026\" according to"
        " format specifier \"%m/%d/%Y\"\n13/01/2026\n^\nError: Month out of"
        " range, expected a value between 1 and 12",
    )
    var out = _eval_column_expr(
        _strptime(STRFNN_TRY_STRPTIME, Expr.literal(ScalarValue.from_string("%m/%d/%Y"))), batch
    )
    var a = out.as_primitive[DType.int64]()
    assert_equal(a.get(0), Int64(1789430400000000))
    assert_true(a.is_null(1))


def test_strptime_refuses_a_format_that_is_not_a_literal() raises:
    """The format must be a constant, as DuckDB requires."""
    var batch = _text_batch([String("2026")], [True])
    assert_equal(
        _error_of(_strptime(STRFNN_STRPTIME, Expr.col_ref("s")), batch),
        "Invalid Input Error: strptime format must be a constant",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
