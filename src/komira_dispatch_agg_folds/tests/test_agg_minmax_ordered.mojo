# =============================================================================
# `agg_minmax_ordered`: the 0-key MIN/MAX over an ordered input that is not
# arithmetic (dates, times, timestamps, durations, strings) — which reader a
# type gets, the fold over each reader, and the one emitter.
#
# No other test of this package reaches this module (its caller, the scalar
# fold, moves in a later PR), so every arm is driven directly here:
#
#   * `_minmax_ordered_storage`: each admitted type lands on its own reader,
#     and the arithmetic families and the unordered types are NOT members;
#   * `_fold_minmax_ordered_int` at both storage widths and
#     `_fold_minmax_ordered_string` over STRING and LARGE_STRING: null rows
#     skipped, the first non-null value seeds, MIN keeps the smaller and MAX
#     the larger in both arrival orders, and an all-null input leaves `have`
#     False;
#   * `_emit_minmax_ordered`: each reader emits the INPUT's own type, a value
#     when one was seen and a NULL (nullable field) when none was, and an
#     unknown reader raises rather than emitting a guess.
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import AGG_MAX, AGG_MIN

from komira_dispatch_agg_folds.agg_minmax_ordered import (
    _MINMAX_ORD_I32,
    _MINMAX_ORD_I64,
    _MINMAX_ORD_LSTR,
    _MINMAX_ORD_NONE,
    _MINMAX_ORD_STR,
    _emit_minmax_ordered,
    _fold_minmax_ordered_int,
    _fold_minmax_ordered_string,
    _minmax_ordered_storage,
)


# =============================================================================
# Fixtures
# =============================================================================


def _batch_of(var col: Column[HeapRegion], at: ArrowType) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), at, True))
    return rbb.build(sb.build())


def _date32_batch(imm vals: List[Int32], imm valid: List[Bool]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(len(vals))
    for i in range(len(vals)):
        if valid[i]:
            arr.set(i, vals[i])
        else:
            arr._set_null(i)
    return _batch_of(
        Column.from_primitive_with_arrow_type[DType.int32](arr^, ArrowType.DATE32),
        ArrowType.DATE32,
    )


def _ts_batch(imm vals: List[Int64], imm valid: List[Bool]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        if valid[i]:
            arr.set(i, vals[i])
        else:
            arr._set_null(i)
    return _batch_of(
        Column.from_primitive_with_arrow_type[DType.int64](
            arr^, ArrowType.TIMESTAMP_US
        ),
        ArrowType.TIMESTAMP_US,
    )


def _str_batch(imm vals: List[String], imm valid: List[Bool]) raises -> RecordBatch:
    var sa = StringArray.from_strings_with_validity(vals, valid)
    return _batch_of(Column.from_string(sa^), ArrowType.STRING)


def _lstr_batch(imm vals: List[String], imm valid: List[Bool]) raises -> RecordBatch:
    var la = LargeStringArray.from_strings_with_validity(vals, valid)
    return _batch_of(Column.from_large_string(la^), ArrowType.LARGE_STRING)


# =============================================================================
# `_minmax_ordered_storage`
# =============================================================================


def test_each_ordered_type_gets_its_reader() raises:
    """Every operand of each `or` chain is a member on its own: the three
    int32-storage types, the four int64-storage spellings (DATE64, both
    TIME64s, a timestamp, a duration), and the two string widths. Catches an
    operand dropped from a chain (TIME32_MS, say, not admitted)."""
    assert_equal(_minmax_ordered_storage(ArrowType.DATE32), _MINMAX_ORD_I32)
    assert_equal(_minmax_ordered_storage(ArrowType.TIME32_S), _MINMAX_ORD_I32)
    assert_equal(_minmax_ordered_storage(ArrowType.TIME32_MS), _MINMAX_ORD_I32)
    assert_equal(_minmax_ordered_storage(ArrowType.DATE64), _MINMAX_ORD_I64)
    assert_equal(_minmax_ordered_storage(ArrowType.TIME64_US), _MINMAX_ORD_I64)
    assert_equal(_minmax_ordered_storage(ArrowType.TIME64_NS), _MINMAX_ORD_I64)
    assert_equal(
        _minmax_ordered_storage(ArrowType.TIMESTAMP_NS), _MINMAX_ORD_I64
    )
    assert_equal(
        _minmax_ordered_storage(ArrowType.DURATION_MS), _MINMAX_ORD_I64
    )
    assert_equal(_minmax_ordered_storage(ArrowType.STRING), _MINMAX_ORD_STR)
    assert_equal(
        _minmax_ordered_storage(ArrowType.LARGE_STRING), _MINMAX_ORD_LSTR
    )


def test_arithmetic_and_unordered_types_are_not_members() raises:
    """INT32, INT64 and FLOAT64 keep their own arithmetic arm (routing them
    here would change `min(<int32>)`'s output type), and BOOL and DECIMAL128
    decline. Catches a widening that admits the int family here."""
    assert_equal(_minmax_ordered_storage(ArrowType.INT32), _MINMAX_ORD_NONE)
    assert_equal(_minmax_ordered_storage(ArrowType.INT64), _MINMAX_ORD_NONE)
    assert_equal(_minmax_ordered_storage(ArrowType.FLOAT64), _MINMAX_ORD_NONE)
    assert_equal(_minmax_ordered_storage(ArrowType.BOOL), _MINMAX_ORD_NONE)
    assert_equal(
        _minmax_ordered_storage(ArrowType.DECIMAL128), _MINMAX_ORD_NONE
    )


# =============================================================================
# `_fold_minmax_ordered_int`
# =============================================================================


def test_int32_fold_min_and_max_skip_nulls() raises:
    """Over [NULL, 50, 20, 70, NULL, 30] (days): MIN is 20 and MAX is 70. The
    NULL first row must not seed (its word is 0, which would win MIN), the
    later smaller and larger values must replace the seed, and the values
    that do not beat it must not. Catches `<` written `>` in the MIN arm and
    the null skip removed (MIN would read 0)."""
    var vals: List[Int32] = [0, 50, 20, 70, 0, 30]
    var valid: List[Bool] = [False, True, True, True, False, True]
    var b = _date32_batch(vals, valid)
    var have = False
    var mn = _fold_minmax_ordered_int[DType.int32](b, 0, AGG_MIN, have)
    assert_true(have)
    assert_equal(Int(mn), 20)
    have = False
    var mx = _fold_minmax_ordered_int[DType.int32](b, 0, AGG_MAX, have)
    assert_true(have)
    assert_equal(Int(mx), 70)


def test_int64_fold_compares_at_its_own_width() raises:
    """A timestamp column read as int64: MIN and MAX over values beyond the
    int32 range, in an order where the extreme arrives last. Catches a fold
    that narrows to int32 before comparing."""
    var vals: List[Int64] = [Int64(5_000_000_000), Int64(-7_000_000_000), Int64(9_000_000_000)]
    var valid: List[Bool] = [True, True, True]
    var b = _ts_batch(vals, valid)
    var have = False
    assert_equal(
        Int(_fold_minmax_ordered_int[DType.int64](b, 0, AGG_MIN, have)),
        -7_000_000_000,
    )
    have = False
    assert_equal(
        Int(_fold_minmax_ordered_int[DType.int64](b, 0, AGG_MAX, have)),
        9_000_000_000,
    )


def test_all_null_int_input_leaves_have_false() raises:
    """No non-null row: `have` stays False, so the caller emits NULL and not
    the zero date. Catches `have` set before the null test."""
    var vals: List[Int32] = [3, 4]
    var valid: List[Bool] = [False, False]
    var have = False
    _ = _fold_minmax_ordered_int[DType.int32](
        _date32_batch(vals, valid), 0, AGG_MIN, have
    )
    assert_false(have)


# =============================================================================
# `_fold_minmax_ordered_string`
# =============================================================================


def _str_cases() -> List[String]:
    return [String("m"), String(""), String("zz"), String("b"), String("q")]


def _str_valid() -> List[Bool]:
    return [True, False, True, True, True]


def test_string_fold_min_and_max() raises:
    """Over ['m', NULL, 'zz', 'b', 'q']: MIN 'b', MAX 'zz'. The NULL (stored
    as '') must not win MIN. Catches the null skip removed and the MIN and
    MAX arms swapped."""
    var b = _str_batch(_str_cases(), _str_valid())
    var have = False
    assert_equal(
        _fold_minmax_ordered_string(b, 0, AGG_MIN, _MINMAX_ORD_STR, have), "b"
    )
    assert_true(have)
    have = False
    assert_equal(
        _fold_minmax_ordered_string(b, 0, AGG_MAX, _MINMAX_ORD_STR, have), "zz"
    )


def test_large_string_fold_min_and_max() raises:
    """The same values through the LARGE_STRING reader give the same answers.
    Catches the LARGE_STRING arm comparing in the wrong direction."""
    var b = _lstr_batch(_str_cases(), _str_valid())
    var have = False
    assert_equal(
        _fold_minmax_ordered_string(b, 0, AGG_MIN, _MINMAX_ORD_LSTR, have), "b"
    )
    assert_true(have)
    have = False
    assert_equal(
        _fold_minmax_ordered_string(b, 0, AGG_MAX, _MINMAX_ORD_LSTR, have),
        "zz",
    )


def test_all_null_strings_leave_have_false_in_both_readers() raises:
    """All NULL: `have` stays False through both readers, so the emitter can
    tell 'no value' from the empty string."""
    var vals: List[String] = [String(""), String("")]
    var valid: List[Bool] = [False, False]
    var have = False
    _ = _fold_minmax_ordered_string(
        _str_batch(vals, valid), 0, AGG_MAX, _MINMAX_ORD_STR, have
    )
    assert_false(have)
    _ = _fold_minmax_ordered_string(
        _lstr_batch(vals, valid), 0, AGG_MAX, _MINMAX_ORD_LSTR, have
    )
    assert_false(have)


# =============================================================================
# `_emit_minmax_ordered`
# =============================================================================


def _emit(
    at: ArrowType, kind: Int, have: Bool, v32: Int32, v64: Int64, s: String
) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(1)
    var sb = SchemaBuilder()
    _emit_minmax_ordered(rbb, sb, String("out"), at, kind, have, v32, v64, s)
    return rbb.build(sb.build())


def test_emit_int32_reader_keeps_the_input_type() raises:
    """A DATE32 result is emitted as DATE32 (not INT64), non-nullable with
    the value when one was seen, nullable and NULL when none was. Catches the
    `at` override dropped and `not have` written `have`."""
    var b = _emit(ArrowType.DATE32, _MINMAX_ORD_I32, True, 18000, 0, "")
    assert_true(b.column_arrow_type(0) == ArrowType.DATE32)
    assert_false(b.schema.field_at_unchecked(0).nullable)
    assert_equal(Int(b.column_as_primitive[DType.int32](0).get(0)), 18000)
    var n = _emit(ArrowType.TIME32_S, _MINMAX_ORD_I32, False, 0, 0, "")
    assert_true(n.column_arrow_type(0) == ArrowType.TIME32_S)
    assert_true(n.schema.field_at_unchecked(0).nullable)
    assert_true(n.column_as_primitive[DType.int32](0).is_null(0))


def test_emit_int64_reader_keeps_the_input_type() raises:
    """The same contract for an int64-storage type (TIMESTAMP_US)."""
    var b = _emit(ArrowType.TIMESTAMP_US, _MINMAX_ORD_I64, True, 0, 123456789, "")
    assert_true(b.column_arrow_type(0) == ArrowType.TIMESTAMP_US)
    assert_false(b.schema.field_at_unchecked(0).nullable)
    assert_equal(Int(b.column_as_primitive[DType.int64](0).get(0)), 123456789)
    var n = _emit(ArrowType.DURATION_S, _MINMAX_ORD_I64, False, 0, 0, "")
    assert_true(n.schema.field_at_unchecked(0).nullable)
    assert_true(n.column_as_primitive[DType.int64](0).is_null(0))


def test_emit_string_readers() raises:
    """STRING and LARGE_STRING results keep their width; a seen '' is a
    value, not a NULL; an unseen result is NULL. Catches the empty string
    emitted as NULL (validity taken from the value instead of `have`)."""
    var s = _emit(ArrowType.STRING, _MINMAX_ORD_STR, True, 0, 0, "")
    assert_true(s.column_arrow_type(0) == ArrowType.STRING)
    assert_false(s.column_as_string(0).is_null(0))
    assert_equal(s.column_as_string(0).get(0), "")
    var sn = _emit(ArrowType.STRING, _MINMAX_ORD_STR, False, 0, 0, "")
    assert_true(sn.column_as_string(0).is_null(0))
    assert_true(sn.schema.field_at_unchecked(0).nullable)
    var l = _emit(ArrowType.LARGE_STRING, _MINMAX_ORD_LSTR, True, 0, 0, "abc")
    assert_true(l.column_arrow_type(0) == ArrowType.LARGE_STRING)
    assert_equal(l.column_as_large_string(0).get(0), "abc")
    var ln = _emit(ArrowType.LARGE_STRING, _MINMAX_ORD_LSTR, False, 0, 0, "")
    assert_true(ln.column_as_large_string(0).is_null(0))


def test_emit_unknown_reader_raises() raises:
    """`_MINMAX_ORD_NONE` has no emitter: the call raises and names the
    reader. Catches a fall-through that emits an empty string column."""
    var raised = False
    try:
        _ = _emit(ArrowType.BOOL, _MINMAX_ORD_NONE, True, 0, 0, "")
    except e:
        raised = True
        assert_true(String(e).find("no emitter for ord_kind 0") >= 0)
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
