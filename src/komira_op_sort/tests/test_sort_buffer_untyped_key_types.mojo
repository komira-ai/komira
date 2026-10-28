# =============================================================================
# SortBuffer_Untyped: one sort key of each remaining DType, and tie stability
# =============================================================================
#
# Each test sorts a batch `[k, id]` by `k` and reads back the `id` payload
# (1-based input position), so the assertion is the exact permutation:
#
#   * DECIMAL128: both 64-bit words, signed (a value that differs only in the
#     high word, and negative values, sort by value).
#   * FLOAT32: `sort_key_lt` order, NaN above every number.
#   * UINT64: unsigned order (a value above 2^63 sorts above one below it).
#   * DATE64 and TIMESTAMP_US: stored as 64-bit cells, ordered as SIGNED.
#   * Stability: 200 rows over 3 distinct keys keep input order within each
#     key, ascending and descending, through every merge level.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_column_format.column_format_storage import (
    COL_DECIMAL128,
    COL_FIXED,
    ColDescriptor,
    DT_DATE64,
    DT_DECIMAL128,
    DT_F32,
    DT_I64,
    DT_TIMESTAMP_US,
    DT_U64,
    ROLE_PAYLOAD,
    ROLE_SORT_KEY,
)
from komira_op_sort.sort_buffer_untyped import (
    SORT_ASC,
    SORT_DESC,
    SortBuffer_Untyped,
)


def _key_desc(kind: UInt8, tag: UInt8) -> List[ColDescriptor]:
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=kind,
            dtype_tag=tag,
            role=ROLE_SORT_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _id_payload() -> List[ColDescriptor]:
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=1,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_PAYLOAD,
            col_idx_in_batch=1,
            col_idx_in_storage=1,
            validity_tracked=False,
        )
    )
    return l^


def _ids(n: Int) -> Column[HeapRegion]:
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        ids.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    return Column.from_primitive[DType.int64](ids^)


def _batch_with_key(
    var key: Column[HeapRegion], var key_field: Field, n: Int
) raises -> RecordBatch:
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(key^)
    builder.add_column(_ids(n))
    var sb = SchemaBuilder()
    sb.add_field(key_field^)
    sb.add_field(Field("id", ArrowType.INT64, False))
    return builder.build(sb.build())


def _sorted_ids(
    var key_desc: List[ColDescriptor], dir: UInt8, batch: RecordBatch
) raises -> List[Int64]:
    var dirs = List[UInt8]()
    dirs.append(dir)
    var sbuf = SortBuffer_Untyped(key_desc^, dirs^, _id_payload(), 16)
    sbuf.feed_batch(BatchView(batch))
    sbuf.finalize_sort()
    return sbuf.read_sorted_i64(1)


def _assert_ids(got: List[Int64], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label + ": row count")
    for i in range(len(want)):
        assert_equal(Int(got[i]), want[i], label + ": id @" + String(i))


def _list(a: Int, b: Int, c: Int, d: Int, e: Int) -> List[Int]:
    var l = List[Int]()
    l.append(a)
    l.append(b)
    l.append(c)
    l.append(d)
    l.append(e)
    return l^


# -----------------------------------------------------------------------------
# DECIMAL128
# -----------------------------------------------------------------------------


def _i128(hi: Int, lo: Int) -> Scalar[DType.int128]:
    """hi * 2^64 + lo as a signed 128-bit value."""
    var h = Scalar[DType.int128](hi) << Scalar[DType.int128](64)
    return h + Scalar[DType.int128](lo)


def _decimal_batch() raises -> RecordBatch:
    """Seven values; 1 and 4 differ in the low word only, 2^100 and the
    negative 2^64 differ from the rest in the high word."""
    var vals = List[Scalar[DType.int128]]()
    vals.append(_i128(1, 5))   # id 1: 2^64 + 5
    vals.append(_i128(0, 7))   # id 2: 7
    vals.append(_i128(0, -3))  # id 3: -3
    vals.append(_i128(1, 0))   # id 4: 2^64
    vals.append(_i128(-1, 0))  # id 5: -2^64
    vals.append(_i128(1 << 36, 0))  # id 6: 2^100
    vals.append(_i128(0, 0))   # id 7: 0
    var col = Column.from_decimal128(
        Decimal128Array.from_i128_list(vals, 38, 0)
    )
    return _batch_with_key(
        col^, Field.decimal128("k", 38, 0, False), len(vals)
    )


def _decimal_want_asc() -> List[Int]:
    var w = List[Int]()
    w.append(5)  # -2^64
    w.append(3)  # -3
    w.append(7)  # 0
    w.append(2)  # 7
    w.append(4)  # 2^64
    w.append(1)  # 2^64 + 5
    w.append(6)  # 2^100
    return w^


def test_decimal128_key_ascending_orders_by_the_signed_128_bit_value() raises:
    var got = _sorted_ids(
        _key_desc(COL_DECIMAL128, DT_DECIMAL128), SORT_ASC, _decimal_batch()
    )
    _assert_ids(got, _decimal_want_asc(), String("DECIMAL128 ASC"))


def test_decimal128_key_descending_reverses_the_order() raises:
    var got = _sorted_ids(
        _key_desc(COL_DECIMAL128, DT_DECIMAL128), SORT_DESC, _decimal_batch()
    )
    var want = _decimal_want_asc()
    var rev = List[Int]()
    for i in range(len(want) - 1, -1, -1):
        rev.append(want[i])
    _assert_ids(got, rev, String("DECIMAL128 DESC"))


# -----------------------------------------------------------------------------
# FLOAT32
# -----------------------------------------------------------------------------


def _f32_batch() raises -> RecordBatch:
    var nan = Float32(0.0) / Float32(0.0)
    var vals = List[Scalar[DType.float32]]()
    vals.append(Float32(2.5))       # id 1
    vals.append(Float32(-1.0))      # id 2
    vals.append(nan)                # id 3
    vals.append(Float32(0.5))       # id 4
    vals.append(Float32.MAX)        # id 5
    vals.append(-Float32.MAX)       # id 6
    var col = Column.from_primitive[DType.float32](
        PrimitiveArray[DType.float32].from_list(vals)
    )
    return _batch_with_key(
        col^, Field("k", ArrowType.FLOAT32, False), len(vals)
    )


def test_float32_key_ascending_puts_nan_last() raises:
    var got = _sorted_ids(
        _key_desc(COL_FIXED, DT_F32), SORT_ASC, _f32_batch()
    )
    var want = List[Int]()
    want.append(6)
    want.append(2)
    want.append(4)
    want.append(1)
    want.append(5)
    want.append(3)
    _assert_ids(got, want, String("FLOAT32 ASC"))


def test_float32_key_descending_puts_nan_first() raises:
    var got = _sorted_ids(
        _key_desc(COL_FIXED, DT_F32), SORT_DESC, _f32_batch()
    )
    var want = List[Int]()
    want.append(3)
    want.append(5)
    want.append(1)
    want.append(4)
    want.append(2)
    want.append(6)
    _assert_ids(got, want, String("FLOAT32 DESC"))


# -----------------------------------------------------------------------------
# UINT64
# -----------------------------------------------------------------------------


def _u64_batch() raises -> RecordBatch:
    var vals = List[Scalar[DType.uint64]]()
    vals.append(UInt64(9223372036854775809))  # id 1: 2^63 + 1
    vals.append(UInt64(5))                    # id 2
    vals.append(UInt64.MAX)                   # id 3
    vals.append(UInt64(0))                    # id 4
    vals.append(UInt64(9223372036854775808))  # id 5: 2^63
    var col = Column.from_primitive[DType.uint64](
        PrimitiveArray[DType.uint64].from_list(vals)
    )
    return _batch_with_key(
        col^, Field("k", ArrowType.UINT64, False), len(vals)
    )


def test_uint64_key_ascending_is_unsigned_order() raises:
    var got = _sorted_ids(
        _key_desc(COL_FIXED, DT_U64), SORT_ASC, _u64_batch()
    )
    _assert_ids(got, _list(4, 2, 5, 1, 3), String("UINT64 ASC"))


def test_uint64_key_descending_is_unsigned_order() raises:
    var got = _sorted_ids(
        _key_desc(COL_FIXED, DT_U64), SORT_DESC, _u64_batch()
    )
    _assert_ids(got, _list(3, 1, 5, 2, 4), String("UINT64 DESC"))


# -----------------------------------------------------------------------------
# DATE64 and TIMESTAMP_US
# -----------------------------------------------------------------------------


def _i64_values() -> List[Scalar[DType.int64]]:
    var vals = List[Scalar[DType.int64]]()
    vals.append(Int64(5))      # id 1
    vals.append(Int64(-5))     # id 2
    vals.append(Int64(1000))   # id 3
    vals.append(Int64(-1000))  # id 4
    vals.append(Int64(0))      # id 5
    return vals^


def test_date64_key_orders_negative_values_first() raises:
    var col = Column.from_primitive_with_arrow_type[DType.int64](
        PrimitiveArray[DType.int64].from_list(_i64_values()), ArrowType.DATE64
    )
    var batch = _batch_with_key(
        col^, Field("k", ArrowType.DATE64, False), 5
    )
    var got = _sorted_ids(_key_desc(COL_FIXED, DT_DATE64), SORT_ASC, batch)
    _assert_ids(got, _list(4, 2, 5, 1, 3), String("DATE64 ASC"))


def test_timestamp_us_key_orders_negative_values_first() raises:
    var col = Column.from_primitive_with_arrow_type[DType.int64](
        PrimitiveArray[DType.int64].from_list(_i64_values()),
        ArrowType.TIMESTAMP_US,
    )
    var batch = _batch_with_key(
        col^, Field("k", ArrowType.TIMESTAMP_US, False), 5
    )
    var got = _sorted_ids(
        _key_desc(COL_FIXED, DT_TIMESTAMP_US), SORT_ASC, batch
    )
    _assert_ids(got, _list(4, 2, 5, 1, 3), String("TIMESTAMP_US ASC"))


# -----------------------------------------------------------------------------
# Stability through every merge level
# -----------------------------------------------------------------------------

comptime _TIE_ROWS: Int = 200


def _tie_batch() raises -> RecordBatch:
    """`[k INT64, id INT64]`: k = row % 3."""
    var k = PrimitiveArray[DType.int64].allocate(_TIE_ROWS)
    for i in range(_TIE_ROWS):
        k.set_typed[Scalar[DType.int64]](i, Int64(i % 3))
    return _batch_with_key(
        Column.from_primitive[DType.int64](k^),
        Field("k", ArrowType.INT64, False),
        _TIE_ROWS,
    )


def _tie_want(first_key: Int, step: Int) -> List[Int]:
    """Ids grouped by key, starting at `first_key`, moving by `step`, each
    group in input order."""
    var w = List[Int]()
    var key = first_key
    for _ in range(3):
        for i in range(_TIE_ROWS):
            if i % 3 == key:
                w.append(i + 1)
        key += step
    return w^


def test_equal_keys_keep_input_order_ascending() raises:
    var got = _sorted_ids(
        _key_desc(COL_FIXED, DT_I64), SORT_ASC, _tie_batch()
    )
    _assert_ids(got, _tie_want(0, 1), String("ties ASC"))


def test_equal_keys_keep_input_order_descending() raises:
    var got = _sorted_ids(
        _key_desc(COL_FIXED, DT_I64), SORT_DESC, _tie_batch()
    )
    _assert_ids(got, _tie_want(2, -1), String("ties DESC"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
