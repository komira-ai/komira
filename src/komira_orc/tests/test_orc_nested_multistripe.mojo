# =============================================================================
# test_orc_nested_multistripe.mojo — the nested read path over 0 and N stripes.
# =============================================================================
#
# A nested schema routes `read_orc_bytes` through the recursive nested decoder.
# A file with no stripes is an empty table; a file with several stripes is the
# row-wise concatenation of its stripes, exactly as the flat path (and any
# other ORC reader) returns it.
#
# Fixture (hand-emitted, NONE codec, DIRECT_V2 everywhere):
#   struct<id:bigint, vals:array<int>, u:uniontype<int,bigint>,
#          s:struct<x:int>, m:map<int,bigint>>
# Schema node ids: 0=root, 1=id, 2=vals(list), 3=int, 4=u(union), 5=int,
#                  6=bigint, 7=s(struct), 8=x(int), 9=m(map), 10=key(int),
#                  11=value(bigint).
#
# Stripe 0 (3 rows):
#   id   = 1, 2, 3
#   vals = [10,11], NULL, [12]      (PRESENT 1,0,1; LENGTH 2,1)
#   u    = int 100, bigint 201, int 102   (tags 0,1,0)
#   s.x  = 7, 8, 9
#   m    = {1:1000}, {}, {2:2000, 3:3000}  (LENGTH 1,0,2)
# Stripe 1 (2 rows):
#   id   = 4, 5
#   vals = [13], [14,15,16]          (no PRESENT; LENGTH 1,3)
#   u    = bigint 204, int 105        (tags 1,0)
#   s.x  = 10, 11
#   m    = {4:4000}, {5:5000}         (LENGTH 1,1)
#
# Expected (the concatenation): 5 rows; vals offsets 0,2,2,3,4,7 with row 1
# null and child 10..16; u type_ids 0,1,0,1,0 with dense offsets 0,0,1,1,2
# into int [100,102,105] and bigint [201,204]; s.x 7..11; m offsets
# 0,1,1,3,4,5 with keys 1..5 and values 1000..5000.
#
# What each test catches:
#   - test_nested_two_stripes_concatenate: a reader that refuses N > 1 stripes;
#     one that restarts list / map offsets or dense-union offsets at each
#     stripe (offsets 3 -> 0 at row 3); one that drops the first stripe's
#     validity; one that decodes only stripe 0.
#   - test_nested_zero_stripes_is_empty_batch: a reader that refuses a
#     nested file with no stripes instead of returning an empty batch.
#   - test_nested_stripe_row_count_bound: a stripe whose declared row count no
#     file of this size can back is refused by name before any decode
#     allocates for it.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_orc import (
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_LIST,
    ORC_KIND_MAP,
    ORC_KIND_UNION,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_STREAM_PRESENT,
    ORC_ENCODING_DIRECT_V2,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
)
from komira_arrow.arrow_types import ArrowType


comptime _N_NODES = 12


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


def _append(src: List[UInt8], mut out: List[UInt8]):
    for i in range(len(src)):
        out.append(src[i])


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
    """One RLEv2 DIRECT run (bits in 1..24 encode as bits - 1)."""
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


def _signed(values: List[Int64]) -> List[UInt8]:
    return _rlev2_direct(values, 16, True)


def _lengths(values: List[Int64]) -> List[UInt8]:
    return _rlev2_direct(values, 4, False)


def _tags(*vals: Int) -> List[UInt8]:
    """Byte-RLE LITERAL run: header = 256 - count, then `count` raw bytes."""
    var out = List[UInt8]()
    out.append(UInt8(256 - len(vals)))
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _present(*flags: Bool) -> List[UInt8]:
    """Boolean RLE: one byte-RLE LITERAL run of MSB-first packed bits."""
    var n_bytes = (len(flags) + 7) // 8
    var out = List[UInt8]()
    out.append(UInt8(256 - n_bytes))
    for bi in range(n_bytes):
        var byte: Int = 0
        for k in range(8):
            var idx = bi * 8 + k
            var bit = idx < len(flags) and flags[idx]
            byte = (byte << 1) | (1 if bit else 0)
        out.append(UInt8(byte))
    return out^


def _enc_stream(kind: Int, column: Int, length: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    _pb_varint_field(2, UInt64(column), b)
    _pb_varint_field(3, UInt64(length), b)
    return b^


def _enc_type(kind: Int, *subtypes: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    for i in range(len(subtypes)):
        _pb_varint_field(2, UInt64(subtypes[i]), b)
    return b^


struct _OrcFile:
    """Lays stripes out one after another behind the "ORC" magic, then the
    Footer and PostScript. Every node gets a DIRECT_V2 ColumnEncoding."""

    var out: List[UInt8]
    var stripe_infos: List[UInt8]
    var sf: List[UInt8]
    var data: List[UInt8]

    def __init__(out self):
        self.out = List[UInt8]()
        self.out.append(UInt8(ord("O")))
        self.out.append(UInt8(ord("R")))
        self.out.append(UInt8(ord("C")))
        self.stripe_infos = List[UInt8]()
        self.sf = List[UInt8]()
        self.data = List[UInt8]()

    def stream(mut self, kind: Int, column: Int, body: List[UInt8]):
        _pb_message_field(1, _enc_stream(kind, column, len(body)), self.sf)
        _append(body, self.data)

    def end_stripe(mut self, rows: Int):
        for _i in range(_N_NODES):
            var enc = List[UInt8]()
            _pb_varint_field(1, UInt64(ORC_ENCODING_DIRECT_V2), enc)
            _pb_message_field(2, enc, self.sf)
        var info = List[UInt8]()
        _pb_varint_field(1, UInt64(len(self.out)), info)
        _pb_varint_field(2, 0, info)
        _pb_varint_field(3, UInt64(len(self.data)), info)
        _pb_varint_field(4, UInt64(len(self.sf)), info)
        _pb_varint_field(5, UInt64(rows), info)
        _pb_message_field(3, info, self.stripe_infos)
        _append(self.data, self.out)
        _append(self.sf, self.out)
        self.data = List[UInt8]()
        self.sf = List[UInt8]()

    def finish(mut self, total_rows: Int) -> List[UInt8]:
        var root = _enc_type(ORC_KIND_STRUCT, 1, 2, 4, 7, 9)
        _pb_string_field(3, String("id"), root)
        _pb_string_field(3, String("vals"), root)
        _pb_string_field(3, String("u"), root)
        _pb_string_field(3, String("s"), root)
        _pb_string_field(3, String("m"), root)
        var s_t = _enc_type(ORC_KIND_STRUCT, 8)
        _pb_string_field(3, String("x"), s_t)

        var footer = List[UInt8]()
        _pb_varint_field(1, 3, footer)
        _pb_varint_field(2, UInt64(len(self.out) - 3), footer)
        _append(self.stripe_infos, footer)
        _pb_message_field(4, root, footer)
        _pb_message_field(4, _enc_type(ORC_KIND_LONG), footer)  # 1 id
        _pb_message_field(4, _enc_type(ORC_KIND_LIST, 3), footer)  # 2 vals
        _pb_message_field(4, _enc_type(ORC_KIND_INT), footer)  # 3
        _pb_message_field(4, _enc_type(ORC_KIND_UNION, 5, 6), footer)  # 4 u
        _pb_message_field(4, _enc_type(ORC_KIND_INT), footer)  # 5
        _pb_message_field(4, _enc_type(ORC_KIND_LONG), footer)  # 6
        _pb_message_field(4, s_t, footer)  # 7 s
        _pb_message_field(4, _enc_type(ORC_KIND_INT), footer)  # 8 x
        _pb_message_field(4, _enc_type(ORC_KIND_MAP, 10, 11), footer)  # 9 m
        _pb_message_field(4, _enc_type(ORC_KIND_INT), footer)  # 10 key
        _pb_message_field(4, _enc_type(ORC_KIND_LONG), footer)  # 11 value
        _pb_varint_field(6, UInt64(total_rows), footer)

        var ps = List[UInt8]()
        _pb_varint_field(1, UInt64(len(footer)), ps)
        _pb_varint_field(2, UInt64(ORC_COMPRESSION_NONE), ps)
        _pb_varint_field(3, 262144, ps)
        _pb_varint_field(5, 0, ps)
        _pb_string_field(8000, String("ORC"), ps)

        var f = self.out.copy()
        _append(footer, f)
        _append(ps, f)
        f.append(UInt8(len(ps)))
        return f^


def _stripe0(mut f: _OrcFile, declared_rows: Int):
    f.stream(ORC_STREAM_DATA, 1, _signed(_i64s(1, 2, 3)))
    f.stream(ORC_STREAM_PRESENT, 2, _present(True, False, True))
    f.stream(ORC_STREAM_LENGTH, 2, _lengths(_i64s(2, 1)))
    f.stream(ORC_STREAM_DATA, 3, _signed(_i64s(10, 11, 12)))
    f.stream(ORC_STREAM_DATA, 4, _tags(0, 1, 0))
    f.stream(ORC_STREAM_DATA, 5, _signed(_i64s(100, 102)))
    f.stream(ORC_STREAM_DATA, 6, _signed(_i64s(201)))
    f.stream(ORC_STREAM_DATA, 8, _signed(_i64s(7, 8, 9)))
    f.stream(ORC_STREAM_LENGTH, 9, _lengths(_i64s(1, 0, 2)))
    f.stream(ORC_STREAM_DATA, 10, _signed(_i64s(1, 2, 3)))
    f.stream(ORC_STREAM_DATA, 11, _signed(_i64s(1000, 2000, 3000)))
    f.end_stripe(declared_rows)


def _stripe1(mut f: _OrcFile):
    f.stream(ORC_STREAM_DATA, 1, _signed(_i64s(4, 5)))
    f.stream(ORC_STREAM_LENGTH, 2, _lengths(_i64s(1, 3)))
    f.stream(ORC_STREAM_DATA, 3, _signed(_i64s(13, 14, 15, 16)))
    f.stream(ORC_STREAM_DATA, 4, _tags(1, 0))
    f.stream(ORC_STREAM_DATA, 5, _signed(_i64s(105)))
    f.stream(ORC_STREAM_DATA, 6, _signed(_i64s(204)))
    f.stream(ORC_STREAM_DATA, 8, _signed(_i64s(10, 11)))
    f.stream(ORC_STREAM_LENGTH, 9, _lengths(_i64s(1, 1)))
    f.stream(ORC_STREAM_DATA, 10, _signed(_i64s(4, 5)))
    f.stream(ORC_STREAM_DATA, 11, _signed(_i64s(4000, 5000)))
    f.end_stripe(2)


def test_nested_two_stripes_concatenate() raises:
    var f = _OrcFile()
    _stripe0(f, 3)
    _stripe1(f)
    var file_bytes = f.finish(5)
    var rb = read_orc_bytes(Span(file_bytes))

    assert_equal(rb.num_rows(), 5, "3 + 2 rows")
    assert_equal(rb.num_columns(), 5, "id, vals, u, s, m")

    var ids = rb.column_at(0).as_primitive[DType.int64]()
    for i in range(5):
        assert_equal(Int(ids.get(i)), i + 1, "id[" + String(i) + "]")

    # LIST: offsets continue across the stripe boundary (row 3 starts at 3).
    var la = rb.column_at(1).as_list()
    assert_equal(len(la), 5, "5 list rows")
    var want_off = [0, 2, 2, 3, 4, 7]
    for i in range(6):
        assert_equal(la.get_offset(i), want_off[i], "vals offset " + String(i))
    assert_false(la.is_null(0), "vals[0] valid")
    assert_true(la.is_null(1), "vals[1] null (stripe 0 PRESENT)")
    assert_false(la.is_null(3), "vals[3] valid (stripe 1 has no PRESENT)")
    assert_false(la.is_null(4), "vals[4] valid")
    var lchild = la.child.as_primitive[DType.int32]()
    assert_equal(lchild.length, 7, "7 list child values")
    for i in range(7):
        assert_equal(Int(lchild.get(i)), 10 + i, "vals child " + String(i))

    # Dense UNION: per-branch offsets keep counting across stripes.
    var ua = rb.column_at(2).as_union()
    assert_equal(len(ua), 5, "5 union rows")
    var want_tag = [0, 1, 0, 1, 0]
    var want_uoff = [0, 0, 1, 1, 2]
    for i in range(5):
        assert_equal(Int(ua.type_id_at(i)), want_tag[i], "u tag " + String(i))
        assert_equal(Int(ua.offset_at(i)), want_uoff[i], "u off " + String(i))
    var b0 = ua.child_at(0).as_primitive[DType.int32]()
    assert_equal(b0.length, 3, "int branch: 2 + 1 values")
    assert_equal(Int(b0.get(0)), 100, "int[0]")
    assert_equal(Int(b0.get(1)), 102, "int[1]")
    assert_equal(Int(b0.get(2)), 105, "int[2] (stripe 1)")
    var b1 = ua.child_at(1).as_primitive[DType.int64]()
    assert_equal(b1.length, 2, "bigint branch: 1 + 1 values")
    assert_equal(Int(b1.get(0)), 201, "bigint[0]")
    assert_equal(Int(b1.get(1)), 204, "bigint[1] (stripe 1)")

    # STRUCT: children span every stripe's rows.
    var sa = rb.column_at(3).as_struct()
    assert_equal(len(sa), 5, "5 struct rows")
    var xs = sa.child_at(0).as_primitive[DType.int32]()
    assert_equal(xs.length, 5, "s.x spans both stripes")
    for i in range(5):
        assert_equal(Int(xs.get(i)), 7 + i, "s.x[" + String(i) + "]")

    # MAP: offsets continue across the stripe boundary.
    var ma = rb.column_at(4).as_map()
    assert_equal(len(ma), 5, "5 map rows")
    var want_moff = [0, 1, 1, 3, 4, 5]
    for i in range(6):
        assert_equal(ma.get_offset(i), want_moff[i], "m offset " + String(i))
    var keys = ma.keys.as_primitive[DType.int32]()
    var vals = ma.values.as_primitive[DType.int64]()
    assert_equal(keys.length, 5, "5 map keys")
    for i in range(5):
        assert_equal(Int(keys.get(i)), i + 1, "m key " + String(i))
        assert_equal(Int(vals.get(i)), (i + 1) * 1000, "m value " + String(i))


def test_nested_zero_stripes_is_empty_batch() raises:
    var f = _OrcFile()
    var file_bytes = f.finish(0)
    var rb = read_orc_bytes(Span(file_bytes))

    assert_equal(rb.num_rows(), 0, "no stripes: zero rows")
    assert_equal(rb.num_columns(), 5, "the nested schema is kept")
    assert_equal(rb.column_at(0).arrow_type, ArrowType.INT64, "id")
    assert_equal(rb.column_at(1).arrow_type, ArrowType.LIST, "vals")
    assert_equal(rb.column_at(2).arrow_type, ArrowType.UNION_DENSE, "u")
    assert_equal(rb.column_at(3).arrow_type, ArrowType.STRUCT, "s")
    assert_equal(rb.column_at(4).arrow_type, ArrowType.MAP, "m")
    assert_equal(len(rb.column_at(1).as_list()), 0, "empty list column")


def test_nested_stripe_row_count_bound() raises:
    # Stripe 0 claims 100000 rows in a file of a few hundred bytes (at most
    # 8 rows per byte can be backed).
    var f = _OrcFile()
    _stripe0(f, 100_000)
    _stripe1(f)
    var file_bytes = f.finish(5)
    with assert_raises(contains="BAD_ROW_COUNT: stripe 0 declares 100000 rows"):
        _ = read_orc_bytes(Span(file_bytes))


def main() raises:
    test_nested_two_stripes_concatenate()
    test_nested_zero_stripes_is_empty_batch()
    test_nested_stripe_row_count_bound()
    print("test_orc_nested_multistripe: ALL PASS")
