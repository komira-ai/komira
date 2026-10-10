# =============================================================================
# cd_distinct_key: the COUNT(DISTINCT) admission rule and the per-row key and
# null-mask readers.
#
# What each part proves:
#
#   * THE CHANNEL TABLE. Every ArrowType family maps to the channel its
#     storage is read through (int64-storage temporals verbatim, int32-storage
#     temporals through the int32 channel), and every type with no Int64
#     injection (strings, binaries, dictionary, decimals, float16, nested)
#     maps to CDK_UNSUPPORTED. `cd_value_type_supported` is the negation of
#     that refusal; `cd_key_column_type_supported` admits INT32/INT64 only.
#   * THE FLOAT KEY. -0.0 and +0.0 are one key; other values keep their
#     IEEE bit pattern (so 1.0 and 2.0 differ).
#   * THE KEYS AND THE MASK, ONE COLUMN PER CHANNEL. Each column is read at
#     its own width: a negative narrow signed value sign-extends, an unsigned
#     high value stays positive (u8 255 is 255, not -1), u64 max is the bit
#     pattern -1, f32 widens to the same key as the equal f64, bool is 0/1.
#     Every column has a NULL at a non-zero row and the last row is checked,
#     so a loop that stops one short or a mask that reads the wrong polarity
#     goes red. A DATE32 and a TIMESTAMP_US column read through their storage
#     channel.
#   * SLICES. A sliced nullable column (INT32, FLOAT64; BOOL has no zero-copy
#     slice) is read for its window only: keys and null flags of rows
#     [start, start+len) of the parent.
#   * REFUSAL. Both readers raise, naming the type, on a STRING column.
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_agg_api.cd_distinct_key import (
    CDK_BOOL,
    CDK_F32,
    CDK_F64,
    CDK_I16,
    CDK_I32,
    CDK_I8,
    CDK_RAW_I64,
    CDK_U16,
    CDK_U32,
    CDK_U64,
    CDK_U8,
    CDK_UNSUPPORTED,
    cd_distinct_key_channel,
    cd_distinct_keys_for_column,
    cd_f64_distinct_key,
    cd_key_column_type_supported,
    cd_null_mask_for_column,
    cd_value_type_supported,
)


# =============================================================================
# Fixture helpers
# =============================================================================


def _prim[
    dt: DType
](imm v: List[Scalar[dt]], null_row: Int) raises -> Column[HeapRegion]:
    """A nullable column of `v` with row `null_row` NULL (-1: none)."""
    var a = PrimitiveArray[dt].allocate_nullable(len(v))
    for i in range(len(v)):
        a.set(i, v[i])
        if i == null_row:
            a._set_null(i)
    return Column.from_primitive[dt](a^)


def _batch1(var col: Column[HeapRegion], at: ArrowType) raises -> RecordBatch:
    """A one-column batch whose column and field both carry `at`."""
    col.arrow_type = at
    var rbb = RecordBatchBuilder.with_capacity(1)
    var sb = SchemaBuilder()
    rbb.add_column(col^)
    sb.add_field(Field(String("c"), at, True))
    return rbb.build(sb.build())


def _check(
    imm b: RecordBatch, imm want: List[Int64], null_row: Int
) raises:
    """Keys equal `want` at every non-NULL row; the mask is True exactly at
    `null_row`; both lists have one entry per row."""
    var keys = cd_distinct_keys_for_column(b, 0)
    var mask = cd_null_mask_for_column(b, 0)
    assert_equal(len(keys), len(want))
    assert_equal(len(mask), len(want))
    for r in range(len(want)):
        assert_equal(mask[r], r == null_row, "mask row " + String(r))
        if r != null_row:
            assert_equal(keys[r], want[r], "key row " + String(r))


# =============================================================================
# The channel table
# =============================================================================


def test_channel_table_every_supported_family() raises:
    assert_equal(cd_distinct_key_channel(ArrowType.INT64), CDK_RAW_I64)
    var raw64: List[ArrowType] = [
        ArrowType.DATE64, ArrowType.TIME64_US, ArrowType.TIME64_NS,
        ArrowType.INTERVAL_DAY_TIME, ArrowType.TIMESTAMP,
        ArrowType.TIMESTAMP_S, ArrowType.TIMESTAMP_MS,
        ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_NS,
        ArrowType.DURATION_S, ArrowType.DURATION_MS,
        ArrowType.DURATION_US, ArrowType.DURATION_NS,
    ]
    for i in range(len(raw64)):
        assert_equal(
            cd_distinct_key_channel(raw64[i]), CDK_RAW_I64, String(raw64[i])
        )
    var i32: List[ArrowType] = [
        ArrowType.INT32, ArrowType.DATE32, ArrowType.TIME32_S,
        ArrowType.TIME32_MS, ArrowType.INTERVAL_YEAR_MONTH,
    ]
    for i in range(len(i32)):
        assert_equal(cd_distinct_key_channel(i32[i]), CDK_I32, String(i32[i]))
    assert_equal(cd_distinct_key_channel(ArrowType.INT16), CDK_I16)
    assert_equal(cd_distinct_key_channel(ArrowType.INT8), CDK_I8)
    assert_equal(cd_distinct_key_channel(ArrowType.UINT8), CDK_U8)
    assert_equal(cd_distinct_key_channel(ArrowType.UINT16), CDK_U16)
    assert_equal(cd_distinct_key_channel(ArrowType.UINT32), CDK_U32)
    assert_equal(cd_distinct_key_channel(ArrowType.UINT64), CDK_U64)
    assert_equal(cd_distinct_key_channel(ArrowType.FLOAT64), CDK_F64)
    assert_equal(cd_distinct_key_channel(ArrowType.FLOAT32), CDK_F32)
    assert_equal(cd_distinct_key_channel(ArrowType.BOOL), CDK_BOOL)


def test_channel_table_refusals() raises:
    var refused: List[ArrowType] = [
        ArrowType.NULL, ArrowType.STRING, ArrowType.LARGE_STRING,
        ArrowType.BINARY, ArrowType.LARGE_BINARY, ArrowType.DICTIONARY,
        ArrowType.DECIMAL128, ArrowType.DECIMAL256, ArrowType.FLOAT16,
        ArrowType.LIST, ArrowType.STRUCT, ArrowType.MAP,
        ArrowType.INTERVAL_MONTH_DAY_NANO, ArrowType.FIXED_SIZE_BINARY,
        ArrowType.UTF8_VIEW,
    ]
    for i in range(len(refused)):
        assert_equal(
            cd_distinct_key_channel(refused[i]),
            CDK_UNSUPPORTED,
            String(refused[i]),
        )
        assert_false(cd_value_type_supported(refused[i]), String(refused[i]))
    assert_true(cd_value_type_supported(ArrowType.INT64))
    assert_true(cd_value_type_supported(ArrowType.BOOL))
    assert_true(cd_value_type_supported(ArrowType.DATE32))


def test_key_column_types_are_int32_and_int64_only() raises:
    assert_true(cd_key_column_type_supported(ArrowType.INT32))
    assert_true(cd_key_column_type_supported(ArrowType.INT64))
    # Same storage, same channel, but the emit names the two types literally.
    assert_false(cd_key_column_type_supported(ArrowType.DATE32))
    assert_false(cd_key_column_type_supported(ArrowType.TIMESTAMP_US))
    assert_false(cd_key_column_type_supported(ArrowType.INT16))
    assert_false(cd_key_column_type_supported(ArrowType.FLOAT64))


# =============================================================================
# The float key
# =============================================================================


def test_f64_key_folds_signed_zero_only() raises:
    assert_equal(cd_f64_distinct_key(Float64(-0.0)), Int64(0))
    assert_equal(cd_f64_distinct_key(Float64(0.0)), Int64(0))
    # 1.0 = 0x3FF0000000000000; -1.0 sets the sign bit too.
    assert_equal(cd_f64_distinct_key(Float64(1.0)), Int64(0x3FF0000000000000))
    assert_equal(
        cd_f64_distinct_key(Float64(-1.0)),
        UInt64(0xBFF0000000000000).cast[DType.int64](),
    )
    assert_true(
        cd_f64_distinct_key(Float64(1.0)) != cd_f64_distinct_key(Float64(2.0))
    )


# =============================================================================
# Keys and masks, one column per channel
# =============================================================================


def test_keys_int64_and_int64_storage_temporal() raises:
    var v: List[Int64] = [5, -3, 77, Int64.MAX, -9]
    var want: List[Int64] = [5, -3, 0, Int64.MAX, -9]
    _check(_batch1(_prim[DType.int64](v, 2), ArrowType.INT64), want, 2)
    _check(_batch1(_prim[DType.int64](v, 2), ArrowType.TIMESTAMP_US), want, 2)


def test_keys_int32_sign_extends_and_date32() raises:
    var v: List[Int32] = [-7, 0, Int32.MIN, 9, Int32.MAX]
    var want: List[Int64] = [-7, 0, Int64(Int32.MIN), 0, Int64(Int32.MAX)]
    _check(_batch1(_prim[DType.int32](v, 3), ArrowType.INT32), want, 3)
    _check(_batch1(_prim[DType.int32](v, 3), ArrowType.DATE32), want, 3)


def test_keys_int16_and_int8() raises:
    var v16: List[Int16] = [Int16.MIN, 4, 1, Int16.MAX]
    var w16: List[Int64] = [-32768, 4, 0, 32767]
    _check(_batch1(_prim[DType.int16](v16, 2), ArrowType.INT16), w16, 2)
    var v8: List[Int8] = [Int8.MIN, 1, -1, Int8.MAX]
    var w8: List[Int64] = [-128, 0, -1, 127]
    _check(_batch1(_prim[DType.int8](v8, 1), ArrowType.INT8), w8, 1)


def test_keys_unsigned_stay_positive() raises:
    var v8: List[UInt8] = [255, 0, 3, 128]
    var w8: List[Int64] = [255, 0, 0, 128]
    _check(_batch1(_prim[DType.uint8](v8, 2), ArrowType.UINT8), w8, 2)
    var v16: List[UInt16] = [65535, 6, 32768, 1]
    var w16: List[Int64] = [65535, 0, 32768, 1]
    _check(_batch1(_prim[DType.uint16](v16, 1), ArrowType.UINT16), w16, 1)
    var v32: List[UInt32] = [4294967295, 2147483648, 8, 2]
    var w32: List[Int64] = [4294967295, 2147483648, 0, 2]
    _check(_batch1(_prim[DType.uint32](v32, 2), ArrowType.UINT32), w32, 2)
    var v64: List[UInt64] = [UInt64.MAX, 1, 5, UInt64(1) << 63]
    var w64: List[Int64] = [-1, 1, 0, Int64.MIN]
    _check(_batch1(_prim[DType.uint64](v64, 2), ArrowType.UINT64), w64, 2)


def test_keys_floats_fold_zero_and_f32_widens() raises:
    var vf: List[Float64] = [-0.0, 1.5, 0.0, 9.0, 0.0]
    var wf: List[Int64] = [
        0, cd_f64_distinct_key(1.5), 0, 0, 0,
    ]
    _check(_batch1(_prim[DType.float64](vf, 3), ArrowType.FLOAT64), wf, 3)
    var v32: List[Float32] = [1.5, -0.0, 2.0, 0.25]
    var w32: List[Int64] = [
        cd_f64_distinct_key(1.5), 0, 0, cd_f64_distinct_key(0.25),
    ]
    _check(_batch1(_prim[DType.float32](v32, 2), ArrowType.FLOAT32), w32, 2)


def test_keys_bool_is_zero_or_one() raises:
    var a = BooleanArray.allocate_nullable(5)
    a.set(0, True)
    a.set(1, False)
    a.set(2, True)
    a.set(3, False)
    a.set(4, True)
    a._set_null(3)
    var want: List[Int64] = [1, 0, 1, 0, 1]
    _check(_batch1(Column.from_boolean(a), ArrowType.BOOL), want, 3)


# =============================================================================
# Slices
# =============================================================================


def test_keys_and_mask_on_a_sliced_nullable_column() raises:
    # Parent rows 0..7, NULL at parent row 3; window [2, 6) holds the NULL at
    # window row 1.
    var v: List[Int32] = [10, 11, 12, 13, 14, 15, 16, 17]
    var c = _prim[DType.int32](v, 3).slice(2, 4)
    var want: List[Int64] = [12, 0, 14, 15]
    _check(_batch1(c^, ArrowType.INT32), want, 1)

    var fv: List[Float64] = [1.0, 2.0, -0.0, 4.0, 5.0, 6.0]
    var fc = _prim[DType.float64](fv, 5).slice(1, 5)
    var fwant: List[Int64] = [
        cd_f64_distinct_key(2.0), 0, cd_f64_distinct_key(4.0),
        cd_f64_distinct_key(5.0), 0,
    ]
    _check(_batch1(fc^, ArrowType.FLOAT64), fwant, 4)


# =============================================================================
# Refusal
# =============================================================================


def _string_batch() raises -> RecordBatch:
    var s: List[String] = [String("a"), String("b")]
    var rbb = RecordBatchBuilder.with_capacity(1)
    var sb = SchemaBuilder()
    rbb.add_column(Column.from_string(StringArray.from_strings(s)))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    return rbb.build(sb.build())


def test_both_readers_refuse_an_unsupported_column() raises:
    var b = _string_batch()
    var raised = False
    try:
        _ = cd_distinct_keys_for_column(b, 0)
    except e:
        raised = True
        var m = String(e)
        assert_true("cd_distinct_keys_for_column" in m, m)
        assert_true("over string" in m, m)
    assert_true(raised, "keys reader answered a STRING column")
    raised = False
    try:
        _ = cd_null_mask_for_column(b, 0)
    except e:
        raised = True
        var m = String(e)
        assert_true("cd_null_mask_for_column" in m, m)
        assert_true("over string" in m, m)
    assert_true(raised, "mask reader answered a STRING column")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
