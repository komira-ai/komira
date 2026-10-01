# =============================================================================
# test_orc_acid_default_suppress.mojo — Hive ACID 6-column default-suppress +
# row.* lift + with_acid_columns opt-in.
# =============================================================================
#
# Acceptance: `test_orc_acid_default_suppress` —
# an ACID-shaped footer suppresses the 5 metadata columns by default and lifts
# `row.*`; `with_acid_columns=True` exposes all 6.
#
# Fixture (hand-emitted, NONE codec, single stripe, 2 rows):
#   struct<operation:int, originalTransaction:bigint, bucket:int, rowId:bigint,
#          currentTransaction:bigint, row:struct<x:bigint, y:string>>
# Schema node ids: 0=root, 1=operation, 2=originalTransaction, 3=bucket,
#                  4=rowId, 5=currentTransaction, 6=row(struct), 7=x, 8=y.
#
# Default read: 2 columns (x, y) — the row.* children lifted to the top level.
# with_acid_columns=True: 6 columns (operation .. row), bucket as raw Int32.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    read_orc_bytes,
    read_orc_bytes_opts,
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_STRING,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT_V2,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
)
from komira_core.arrow.arrow_types import ArrowType


def _pb_varint(n: UInt64, mut out: List[UInt8]):
    var v = n
    while True:
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _pb_tag(field_number: Int, wire_type: Int, mut out: List[UInt8]):
    _pb_varint(UInt64((field_number << 3) | wire_type), out)


def _pb_varint_field(field_number: Int, value: UInt64, mut out: List[UInt8]):
    _pb_tag(field_number, PB_WIRE_VARINT, out)
    _pb_varint(value, out)


def _pb_string_field(field_number: Int, s: String, mut out: List[UInt8]):
    _pb_tag(field_number, PB_WIRE_LEN, out)
    var b = s.as_bytes()
    _pb_varint(UInt64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _pb_message_field(field_number: Int, body: List[UInt8], mut out: List[UInt8]):
    _pb_tag(field_number, PB_WIRE_LEN, out)
    _pb_varint(UInt64(len(body)), out)
    for i in range(len(body)):
        out.append(body[i])


def _i64s(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(Int64(vals[i]))
    return out^


def _zigzag_encode(v: Int64) -> UInt64:
    return UInt64((v << 1) ^ (v >> 63))


def _pack_bits_be(values: List[Int64], bits: Int, mut out: List[UInt8]):
    var cur: UInt64 = 0
    var filled: Int = 0
    for vi in range(len(values)):
        var v = UInt64(values[vi]) & ((UInt64(1) << UInt64(bits)) - 1)
        var need = bits
        while need > 0:
            var space = 8 - filled
            var take = need if need < space else space
            var shift = need - take
            var chunk = (v >> UInt64(shift)) & ((UInt64(1) << UInt64(take)) - 1)
            cur = (cur << UInt64(take)) | chunk
            filled += take
            need -= take
            if filled == 8:
                out.append(UInt8(cur & 0xFF))
                cur = 0
                filled = 0
    if filled > 0:
        cur = cur << UInt64(8 - filled)
        out.append(UInt8(cur & 0xFF))


def _rlev2_direct(values: List[Int64], bits: Int, signed: Bool) -> List[UInt8]:
    var packed = List[Int64]()
    for i in range(len(values)):
        if signed:
            packed.append(Int64(_zigzag_encode(values[i])))
        else:
            packed.append(values[i])
    var out = List[UInt8]()
    var enc_w = bits - 1
    var L = len(values) - 1
    var b0 = (1 << 6) | (enc_w << 1) | ((L >> 8) & 1)
    out.append(UInt8(b0))
    out.append(UInt8(L & 0xFF))
    _pack_bits_be(packed, bits, out)
    return out^


def _str_bytes(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])


def _enc_stream(kind: Int, column: Int, length: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    _pb_varint_field(2, UInt64(column), b)
    _pb_varint_field(3, UInt64(length), b)
    return b^


def _enc_encoding(kind: Int, dict_size: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    if dict_size > 0:
        _pb_varint_field(2, UInt64(dict_size), b)
    return b^


def _enc_type_leaf(kind: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    return b^


def _app(src: List[UInt8], mut dst: List[UInt8]):
    for i in range(len(src)):
        dst.append(src[i])


# Schema node ids: 0=root, 1=operation, 2=origTxn, 3=bucket, 4=rowId,
#                  5=currTxn, 6=row(struct), 7=x(bigint), 8=y(string).
# 2 rows. operation=[0,0], origTxn=[100,100], bucket=[536936448,536936448],
# rowId=[0,1], currTxn=[5,5]. row.x=[42,43], row.y=["aa","bb"].


def _build_acid_file() -> List[UInt8]:
    var op_data = _rlev2_direct(_i64s(0, 0), 4, True)
    var otxn_data = _rlev2_direct(_i64s(100, 100), 8, True)
    # bucket packed value kept small so the RLEv2 Direct bit-width (4) maps
    # cleanly through the encoded-width table (widths >24 use non-contiguous
    # codes; the BucketCodec packed layout is NOT decoded by the reader —
    # this is a raw-Int32 passthrough assertion, value is representative only).
    var bucket_data = _rlev2_direct(_i64s(7, 7), 4, True)
    var rowid_data = _rlev2_direct(_i64s(0, 1), 4, True)
    var ctxn_data = _rlev2_direct(_i64s(5, 5), 4, True)
    var x_data = _rlev2_direct(_i64s(42, 43), 8, True)
    var y_data = List[UInt8]()
    _str_bytes(String("aabb"), y_data)
    var y_len = _rlev2_direct(_i64s(2, 2), 4, False)

    # On-disk order: col1..5 DATA, col7 (x) DATA, col8 (y) DATA, col8 LENGTH.
    var data_region = List[UInt8]()
    _app(op_data, data_region)
    _app(otxn_data, data_region)
    _app(bucket_data, data_region)
    _app(rowid_data, data_region)
    _app(ctxn_data, data_region)
    _app(x_data, data_region)
    _app(y_data, data_region)
    _app(y_len, data_region)

    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(op_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 2, len(otxn_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, len(bucket_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 4, len(rowid_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 5, len(ctxn_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 7, len(x_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 8, len(y_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 8, len(y_len)), sf)
    for _i in range(9):
        _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)

    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_varint_field(2, 3, root)
    _pb_varint_field(2, 4, root)
    _pb_varint_field(2, 5, root)
    _pb_varint_field(2, 6, root)
    _pb_string_field(3, String("operation"), root)
    _pb_string_field(3, String("originalTransaction"), root)
    _pb_string_field(3, String("bucket"), root)
    _pb_string_field(3, String("rowId"), root)
    _pb_string_field(3, String("currentTransaction"), root)
    _pb_string_field(3, String("row"), root)

    var row_t = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), row_t)
    _pb_varint_field(2, 7, row_t)
    _pb_varint_field(2, 8, row_t)
    _pb_string_field(3, String("x"), row_t)
    _pb_string_field(3, String("y"), row_t)

    var data_length = len(data_region)
    var sf_length = len(sf)

    var footer2 = List[UInt8]()
    _pb_varint_field(1, 3, footer2)
    _pb_varint_field(2, UInt64(data_length + sf_length), footer2)
    var stripe_entry = List[UInt8]()
    _pb_varint_field(1, 3, stripe_entry)
    _pb_varint_field(2, 0, stripe_entry)
    _pb_varint_field(3, UInt64(data_length), stripe_entry)
    _pb_varint_field(4, UInt64(sf_length), stripe_entry)
    _pb_varint_field(5, 2, stripe_entry)
    _pb_message_field(3, stripe_entry, footer2)
    _pb_message_field(4, root, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)  # operation
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)  # origTxn
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)  # bucket
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)  # rowId
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)  # currTxn
    _pb_message_field(4, row_t, footer2)  # row struct
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)  # x
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_STRING), footer2)  # y
    _pb_varint_field(6, 2, footer2)

    var ps = List[UInt8]()
    _pb_varint_field(1, UInt64(len(footer2)), ps)
    _pb_varint_field(2, UInt64(ORC_COMPRESSION_NONE), ps)
    _pb_varint_field(3, 262144, ps)
    _pb_varint_field(5, 0, ps)
    _pb_string_field(8000, String("ORC"), ps)

    var f = List[UInt8]()
    f.append(UInt8(ord("O")))
    f.append(UInt8(ord("R")))
    f.append(UInt8(ord("C")))
    _app(data_region, f)
    _app(sf, f)
    _app(footer2, f)
    _app(ps, f)
    f.append(UInt8(len(ps)))
    return f^


def test_acid_default_suppress() raises:
    var file_bytes = _build_acid_file()
    var rb = read_orc_bytes(Span(file_bytes))

    # Default: 5 metadata columns suppressed, row.* lifted -> 2 cols (x, y).
    assert_equal(rb.num_rows(), 2, "2 rows")
    assert_equal(rb.num_columns(), 2, "default: only row.* (x, y)")
    assert_equal(rb.schema.field_name(0), String("x"), "col 0 = x (lifted)")
    assert_equal(rb.schema.field_name(1), String("y"), "col 1 = y (lifted)")

    ref x_col = rb.column_at(0)
    var xa = x_col.as_primitive[DType.int64]()
    assert_equal(Int(xa.get(0)), 42, "x[0]")
    assert_equal(Int(xa.get(1)), 43, "x[1]")
    ref y_col = rb.column_at(1)
    var ya = y_col.as_string()
    assert_equal(ya.get(0), String("aa"), "y[0]")
    assert_equal(ya.get(1), String("bb"), "y[1]")


def test_acid_with_columns_opt_in() raises:
    var file_bytes = _build_acid_file()
    var rb = read_orc_bytes_opts(Span(file_bytes), True)

    # Opt-in: all 6 ACID columns exposed.
    assert_equal(rb.num_columns(), 6, "with_acid_columns: 6 cols")
    assert_equal(rb.schema.field_name(0), String("operation"), "col 0")
    assert_equal(rb.schema.field_name(2), String("bucket"), "col 2 = bucket")
    assert_equal(rb.schema.field_name(5), String("row"), "col 5 = row struct")

    # bucket exposed as raw Int32 (BucketCodec NOT decoded).
    ref bucket_col = rb.column_at(2)
    assert_equal(bucket_col.arrow_type, ArrowType.INT32, "bucket is raw Int32")
    var ba = bucket_col.as_primitive[DType.int32]()
    assert_equal(Int(ba.get(0)), 7, "bucket[0] raw packed value")

    # row exposed as the full nested STRUCT.
    ref row_col = rb.column_at(5)
    assert_equal(row_col.arrow_type, ArrowType.STRUCT, "row is STRUCT")
    var sa = row_col.as_struct()
    assert_equal(sa.num_fields(), 2, "row struct has x, y")
    var rx = sa.child_at(0).as_primitive[DType.int64]()
    assert_equal(Int(rx.get(1)), 43, "row.x[1]")


def main() raises:
    test_acid_default_suppress()
    test_acid_with_columns_opt_in()
    print("test_orc_acid_default_suppress: ALL PASS")
