# =============================================================================
# SortBuffer_Untyped orders a key of every supported DType
# =============================================================================
#
# One case per key type, each reading the slot order from `sorted_indices`
# (slot i holds input row i), so the assertion is on the exact permutation and
# not on a typed reader. Fixtures put the values whose order depends on the
# type's width and signedness together: unsigned values with the top bit set
# beside small ones, floats with NaN and both infinities, timestamps before
# the epoch, decimals whose order lives in the high 64-bit word, and binary
# bytes at or above 0x80.
#
# Encapsulation: public surface only; no UnsafePointer, no wildcard origin.
# =============================================================================

from std.math import inf, nan
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.binary_array import BinaryArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_column_format.column_format_storage import (
    COL_DECIMAL128,
    COL_FIXED,
    COL_VAR_BINARY,
    ColDescriptor,
    DT_BINARY,
    DT_BOOL,
    DT_DATE32,
    DT_DECIMAL128,
    DT_F32,
    DT_F64,
    DT_TIMESTAMP_MS,
    DT_TIMESTAMP_NS,
    DT_TIMESTAMP_S,
    DT_TIMESTAMP_US,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_U8,
    ROLE_SORT_KEY,
)
from komira_op_sort.sort_buffer_untyped import (
    SORT_ASC,
    SORT_DESC,
    SortBuffer_Untyped,
)


def _key(kind: UInt8, tag: UInt8) -> List[ColDescriptor]:
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


def _one_col(var col: Column[HeapRegion], at: ArrowType) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), at, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    return rbb.build(schema^)


def _perm(
    batch: RecordBatch, kind: UInt8, tag: UInt8, dir: UInt8
) raises -> List[Int]:
    var dirs = List[UInt8]()
    dirs.append(dir)
    var sbuf = SortBuffer_Untyped(
        _key(kind, tag), dirs^, List[ColDescriptor](), 16
    )
    sbuf.feed_batch(BatchView(batch))
    sbuf.finalize_sort()
    return sbuf.sorted_indices.copy()


def _prim[
    dt: DType
](imm vals: List[Scalar[dt]], at: ArrowType) raises -> RecordBatch:
    return _one_col(
        Column.from_primitive_with_arrow_type[dt](
            PrimitiveArray[dt].from_list(vals), at
        ),
        at,
    )


def _check(got: List[Int], expect: List[Int], what: String) raises:
    assert_equal(len(got), len(expect), what + ": length")
    for i in range(len(expect)):
        assert_equal(got[i], expect[i], what + ": position " + String(i))


def test_u64_orders_unsigned() raises:
    var v: List[Scalar[DType.uint64]] = [
        UInt64(1) << 63 | 5,
        3,
        UInt64.MAX,
        0,
    ]
    var b = _prim[DType.uint64](v, ArrowType.UINT64)
    _check(_perm(b, COL_FIXED, DT_U64, SORT_ASC), [3, 1, 0, 2], "u64 asc")
    _check(_perm(b, COL_FIXED, DT_U64, SORT_DESC), [2, 0, 1, 3], "u64 desc")


def test_u32_orders_unsigned() raises:
    var v: List[Scalar[DType.uint32]] = [4000000000, 5, 2147483648, 0]
    var b = _prim[DType.uint32](v, ArrowType.UINT32)
    _check(_perm(b, COL_FIXED, DT_U32, SORT_ASC), [3, 1, 2, 0], "u32 asc")


def test_u16_orders_unsigned() raises:
    var v: List[Scalar[DType.uint16]] = [65535, 3, 32768, 0]
    var b = _prim[DType.uint16](v, ArrowType.UINT16)
    _check(_perm(b, COL_FIXED, DT_U16, SORT_ASC), [3, 1, 2, 0], "u16 asc")


def test_u8_orders_unsigned() raises:
    var v: List[Scalar[DType.uint8]] = [255, 3, 128, 0]
    var b = _prim[DType.uint8](v, ArrowType.UINT8)
    _check(_perm(b, COL_FIXED, DT_U8, SORT_ASC), [3, 1, 2, 0], "u8 asc")


def test_f64_orders_nan_above_inf() raises:
    var v: List[Scalar[DType.float64]] = [
        nan[DType.float64](),
        1.0,
        inf[DType.float64](),
        -inf[DType.float64](),
        0.0,
    ]
    var b = _prim[DType.float64](v, ArrowType.FLOAT64)
    _check(_perm(b, COL_FIXED, DT_F64, SORT_ASC), [3, 4, 1, 2, 0], "f64 asc")
    _check(_perm(b, COL_FIXED, DT_F64, SORT_DESC), [0, 2, 1, 4, 3], "f64 desc")


def test_f32_orders_nan_above_inf() raises:
    var v: List[Scalar[DType.float32]] = [
        nan[DType.float32](),
        1.0,
        inf[DType.float32](),
        -inf[DType.float32](),
        0.0,
    ]
    var b = _prim[DType.float32](v, ArrowType.FLOAT32)
    _check(_perm(b, COL_FIXED, DT_F32, SORT_ASC), [3, 4, 1, 2, 0], "f32 asc")
    _check(_perm(b, COL_FIXED, DT_F32, SORT_DESC), [0, 2, 1, 4, 3], "f32 desc")


def test_date32_orders_signed() raises:
    var v: List[Scalar[DType.int32]] = [19000, -5, 0, 7]
    var b = _prim[DType.int32](v, ArrowType.DATE32)
    _check(_perm(b, COL_FIXED, DT_DATE32, SORT_ASC), [1, 2, 3, 0], "date32")


def test_bool_orders_false_first() raises:
    var arr = BooleanArray.allocate(4)
    arr.set(0, True)
    arr.set(1, False)
    arr.set(2, True)
    arr.set(3, False)
    var b = _one_col(Column.from_boolean(arr^), ArrowType.BOOL)
    _check(_perm(b, COL_FIXED, DT_BOOL, SORT_ASC), [1, 3, 0, 2], "bool asc")
    _check(_perm(b, COL_FIXED, DT_BOOL, SORT_DESC), [0, 2, 1, 3], "bool desc")


def _timestamp_case(at: ArrowType, tag: UInt8, what: String) raises:
    var v: List[Scalar[DType.int64]] = [5, -3, 0, -100, 7]
    var b = _prim[DType.int64](v, at)
    _check(_perm(b, COL_FIXED, tag, SORT_ASC), [3, 1, 2, 0, 4], what + " asc")
    _check(_perm(b, COL_FIXED, tag, SORT_DESC), [4, 0, 2, 1, 3], what + " desc")


def test_timestamp_units_order_signed() raises:
    _timestamp_case(ArrowType.TIMESTAMP_S, DT_TIMESTAMP_S, "ts s")
    _timestamp_case(ArrowType.TIMESTAMP_MS, DT_TIMESTAMP_MS, "ts ms")
    _timestamp_case(ArrowType.TIMESTAMP_US, DT_TIMESTAMP_US, "ts us")
    _timestamp_case(ArrowType.TIMESTAMP_NS, DT_TIMESTAMP_NS, "ts ns")


def _i128(hi: Int64, lo: UInt64) -> SIMD[DType.int128, 1]:
    var u = (hi.cast[DType.uint128]() << UInt128(64)) | lo.cast[DType.uint128]()
    return u.cast[DType.int128]()


def test_decimal128_orders_full_signed_width() raises:
    # 2^64, 5, -1, -2^64, 2^64 - 1: the order of three of them is decided by
    # the high word, and two are negative.
    var v = List[SIMD[DType.int128, 1]]()
    v.append(_i128(1, 0))
    v.append(_i128(0, 5))
    v.append(_i128(-1, UInt64.MAX))
    v.append(_i128(-1, 0))
    v.append(_i128(0, UInt64.MAX))
    var arr = Decimal128Array.from_i128_list(v, 38, 0)
    var b = _one_col(Column.from_decimal128(arr^), ArrowType.DECIMAL128)
    _check(
        _perm(b, COL_DECIMAL128, DT_DECIMAL128, SORT_ASC),
        [3, 2, 1, 4, 0],
        "decimal asc",
    )
    _check(
        _perm(b, COL_DECIMAL128, DT_DECIMAL128, SORT_DESC),
        [0, 4, 1, 2, 3],
        "decimal desc",
    )


def test_binary_orders_bytes_unsigned_shorter_first() raises:
    var rows = List[List[UInt8]]()
    rows.append([UInt8(0xFF)])
    rows.append([UInt8(0x01), UInt8(0x00)])
    rows.append([UInt8(0x01)])
    rows.append(List[UInt8]())
    var b = _one_col(
        Column.from_binary(BinaryArray.from_bytes_list(rows)),
        ArrowType.BINARY,
    )
    _check(
        _perm(b, COL_VAR_BINARY, DT_BINARY, SORT_ASC), [3, 2, 1, 0], "binary asc"
    )
    _check(
        _perm(b, COL_VAR_BINARY, DT_BINARY, SORT_DESC),
        [0, 1, 2, 3],
        "binary desc",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
