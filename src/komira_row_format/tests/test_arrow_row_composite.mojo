# =============================================================================
# `komira_row_format.arrow_row`: the composite key encoder over every fixed
# type family, its null slots, its argument checks, the widths table, and the
# length tiebreak of `arrow_row_compare`.
# =============================================================================
#
# WHAT THIS PROVES
# ----------------
# `encode_row_keys_for_sort` writes, per key, one sentinel byte (0x01 for a
# value; 0x00 for a NULL under NULLS_FIRST, 0xFF under NULLS_LAST; a value
# slot's bytes inverted under DESC, a NULL slot's zero padding never) and then
# the value in the order-preserving form: big-endian, the sign bit flipped for
# a signed integer, the quotient-order image for a float (positive: sign bit
# set; negative: every bit inverted). The expected bytes below are worked out
# by hand from that layout, one row holding a value of every type family the
# encoder accepts, with set top bits (a missed sign flip changes the first
# byte) and distinct bytes (a byte-order slip permutes them). A NULL slot is
# the sentinel plus the type's width of zeros, so the widths are pinned too.
#
# A NULL slot's sentinel is never inverted, DESC or not (as in arrow-rs):
# NULLS_FIRST is 0x00 and NULLS_LAST 0xFF under both directions, so the NULL
# stays on its side of a DESC value slot (sentinel 0xFE). An inverted NULL
# sentinel would put a NULLS_FIRST NULL after every DESC value.
#
# The values are read from a batch at run time; the existing per-encoder tests
# call the scalar encoders with constants, which the compiler folds.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_row_format.arrow_row import (
    DT_BINARY,
    DT_BOOL,
    DT_DATE32,
    DT_DATE64,
    DT_DECIMAL128,
    DT_F32,
    DT_F64,
    DT_I16,
    DT_I32,
    DT_I64,
    DT_I8,
    DT_STRING,
    DT_TIMESTAMP_MS,
    DT_TIMESTAMP_NS,
    DT_TIMESTAMP_S,
    DT_TIMESTAMP_US,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_U8,
    NULLS_FIRST,
    NULLS_LAST,
    SORT_ASC,
    SORT_DESC,
    arrow_row_compare,
    encode_decimal128_to_bytes,
    encode_row_keys_for_sort,
    encoded_width_for_dtype,
)


def _prim[dt: DType](mut rbb: RecordBatchBuilder, var vals: List[Scalar[dt]]):
    rbb.add_column(
        Column.from_primitive[dt](PrimitiveArray[dt].from_list(vals))
    )


def _batch() raises -> RecordBatch:
    """Two rows. Column c holds key c of `_tags()`; row 0 is the hand-worked
    row, row 1 a second row with other values."""
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", DType.int64, False))
    sb.add_field(Field("f64", DType.float64, False))
    sb.add_field(Field("u64", DType.uint64, False))
    sb.add_field(Field("i32", DType.int32, False))
    sb.add_field(Field("f32", DType.float32, False))
    sb.add_field(Field("u32", DType.uint32, False))
    sb.add_field(Field("d32", DType.int32, False))
    sb.add_field(Field("d64", DType.int64, False))
    sb.add_field(Field("ts", DType.int64, False))
    sb.add_field(Field("i16", DType.int16, False))
    sb.add_field(Field("u16", DType.uint16, False))
    sb.add_field(Field("i8", DType.int8, False))
    sb.add_field(Field("u8", DType.uint8, False))
    sb.add_field(Field("b", ArrowType.BOOL, False))
    sb.add_field(Field("dec", ArrowType.DECIMAL128, False))
    var rbb = RecordBatchBuilder.with_capacity(15)
    _prim[DType.int64](rbb, [-5, 7])
    _prim[DType.float64](rbb, [2.25, -3.5])
    _prim[DType.uint64](rbb, [0x0102030405060708, 0xFFFFFFFFFFFFFFFF])
    _prim[DType.int32](rbb, [-2, 0x01020304])
    _prim[DType.float32](rbb, [-1.5, 0.5])
    _prim[DType.uint32](rbb, [0x01020304, 0xFFFFFFFE])
    _prim[DType.int32](rbb, [19000, -1])
    _prim[DType.int64](rbb, [1, -1])
    _prim[DType.int64](rbb, [-1, 0x0102030405060708])
    _prim[DType.int16](rbb, [-32767, 0x0102])
    _prim[DType.uint16](rbb, [0xABCD, 1])
    _prim[DType.int8](rbb, [-127, 127])
    _prim[DType.uint8](rbb, [0xFE, 0x01])
    var ba = BooleanArray.allocate(2)
    ba.set(0, True)
    ba.set(1, False)
    rbb.add_column(Column.from_boolean(ba))
    var dec = Decimal128Array.allocate(2, precision=38, scale=0)
    dec.set_raw(0, Int64(5), Int64(1))
    dec.set_raw(1, Int64(-1), Int64(-1))
    rbb.add_column(Column.from_decimal128(dec^))
    return rbb.build(sb.build())


def _tags() -> List[UInt8]:
    """Key k reads column k; the timestamp column (8) is keyed with each of
    the four timestamp tags in `_ts_tags`."""
    return [
        DT_I64, DT_F64, DT_U64, DT_I32, DT_F32, DT_U32, DT_DATE32, DT_DATE64,
        DT_TIMESTAMP_NS, DT_I16, DT_U16, DT_I8, DT_U8, DT_BOOL,
    ]


def _cols(n: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        out.append(i)
    return out^


def _fill_u8(n: Int, v: UInt8) -> List[UInt8]:
    return List[UInt8](length=n, fill=v)


def _row0_value_bytes() -> List[List[UInt8]]:
    """Row 0's value section per key of `_tags()`, worked out by hand."""
    var out = List[List[UInt8]]()
    # i64 -5: 0xFFFFFFFFFFFFFFFB ^ 1<<63, big-endian.
    out.append([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB])
    # f64 2.25 = 0x4002000000000000, positive: set the sign bit.
    out.append([0xC0, 0x02, 0, 0, 0, 0, 0, 0])
    # u64: big-endian as is.
    out.append([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    # i32 -2: 0xFFFFFFFE ^ 1<<31.
    out.append([0x7F, 0xFF, 0xFF, 0xFE])
    # f32 -1.5 = 0xBFC00000, negative: invert every bit.
    out.append([0x40, 0x3F, 0xFF, 0xFF])
    # u32.
    out.append([0x01, 0x02, 0x03, 0x04])
    # date32 19000 = 0x4A38, signed i32 form.
    out.append([0x80, 0x00, 0x4A, 0x38])
    # date64 1, signed i64 form.
    out.append([0x80, 0, 0, 0, 0, 0, 0, 0x01])
    # timestamp -1, signed i64 form.
    out.append([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    # i16 -32767 = 0x8001 ^ 0x8000.
    out.append([0x00, 0x01])
    # u16 0xABCD.
    out.append([0xAB, 0xCD])
    # i8 -127 = 0x81 ^ 0x80.
    out.append([0x01])
    # u8 0xFE.
    out.append([0xFE])
    # bool true.
    out.append([0x01])
    return out^


def _encode(
    batch: RecordBatch,
    row: Int,
    tags: List[UInt8],
    asc: List[UInt8],
    nf: List[UInt8],
    nulls: List[Bool],
) raises -> List[UInt8]:
    return encode_row_keys_for_sort(
        BatchView(batch), row, _cols(len(tags)), tags, asc, nf, nulls
    )


def test_every_family_exact_bytes_asc() raises:
    """Row 0, all keys ascending, no NULL: sentinel 0x01 then the hand-worked
    value bytes, key after key."""
    var batch = _batch()
    var tags = _tags()
    var n = len(tags)
    var got = _encode(
        batch, 0, tags, _fill_u8(n, SORT_ASC), _fill_u8(n, NULLS_FIRST),
        List[Bool](length=n, fill=False),
    )
    var want = List[UInt8]()
    var vals = _row0_value_bytes()
    for k in range(n):
        want.append(0x01)
        want.extend(vals[k].copy())
    assert_equal(got, want)
    assert_equal(len(got), 9 + 9 + 9 + 5 + 5 + 5 + 5 + 9 + 9 + 3 + 3 + 2 + 2 + 2)


def test_every_family_exact_bytes_desc() raises:
    """The same row, every key descending: every byte of every slot, the
    sentinel included, is inverted."""
    var batch = _batch()
    var tags = _tags()
    var n = len(tags)
    var got = _encode(
        batch, 0, tags, _fill_u8(n, SORT_DESC), _fill_u8(n, NULLS_LAST),
        List[Bool](length=n, fill=False),
    )
    var want = List[UInt8]()
    var vals = _row0_value_bytes()
    for k in range(n):
        want.append(0xFE)
        for b in vals[k]:
            want.append(b ^ 0xFF)
    assert_equal(got, want)


def test_timestamp_units_encode_alike() raises:
    """Each timestamp tag encodes the i64 cell the same way: sentinel then the
    signed i64 form (row 1: 0x0102030405060708 -> 0x81 0x02 ... 0x08)."""
    var batch = _batch()
    var ts_tags: List[UInt8] = [
        DT_TIMESTAMP_NS, DT_TIMESTAMP_US, DT_TIMESTAMP_MS, DT_TIMESTAMP_S,
    ]
    var want: List[UInt8] = [0x01, 0x81, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    for t in ts_tags:
        var tags: List[UInt8] = [t]
        var cols: List[Int] = [8]
        var asc: List[UInt8] = [SORT_ASC]
        var nf: List[UInt8] = [NULLS_FIRST]
        var nulls: List[Bool] = [False]
        var got = encode_row_keys_for_sort(
            BatchView(batch), 1, cols, tags, asc, nf, nulls
        )
        assert_equal(got, want, "tag " + String(Int(t)))
        assert_equal(encoded_width_for_dtype(t), 9)


def test_null_slots_sentinel_and_zero_padding() raises:
    """A NULL slot is one sentinel and the type's width of zeros. Over every
    family plus DECIMAL128 (width 16): NULLS_FIRST 0x00 and NULLS_LAST 0xFF,
    ASC and DESC alike (the NULL sentinel is not inverted for DESC)."""
    var batch = _batch()
    var tags = _tags()
    tags.append(DT_DECIMAL128)
    var n = len(tags)
    var widths: List[Int] = [8, 8, 8, 4, 4, 4, 4, 8, 8, 2, 2, 1, 1, 1, 16]
    var orders: List[UInt8] = [SORT_ASC, SORT_ASC, SORT_DESC, SORT_DESC]
    var nfs: List[UInt8] = [NULLS_FIRST, NULLS_LAST, NULLS_FIRST, NULLS_LAST]
    var sentinels: List[UInt8] = [0x00, 0xFF, 0x00, 0xFF]
    for i in range(4):
        var got = _encode(
            batch, 1, tags, _fill_u8(n, orders[i]), _fill_u8(n, nfs[i]),
            List[Bool](length=n, fill=True),
        )
        var want = List[UInt8]()
        for k in range(n):
            want.append(sentinels[i])
            for _ in range(widths[k]):
                want.append(0)
        assert_equal(got, want, "case " + String(i))


def test_mixed_null_and_value_keys() raises:
    """Per-key flags are read per key: (i16 value ASC, i8 NULL NULLS_LAST
    ASC, u16 value DESC, bool NULL NULLS_FIRST ASC) on row 1."""
    var batch = _batch()
    var tags: List[UInt8] = [DT_I16, DT_I8, DT_U16, DT_BOOL]
    var cols: List[Int] = [9, 11, 10, 13]
    var asc: List[UInt8] = [SORT_ASC, SORT_ASC, SORT_DESC, SORT_ASC]
    var nf: List[UInt8] = [NULLS_FIRST, NULLS_LAST, NULLS_LAST, NULLS_FIRST]
    var nulls: List[Bool] = [False, True, False, True]
    var got = encode_row_keys_for_sort(
        BatchView(batch), 1, cols, tags, asc, nf, nulls
    )
    # i16 0x0102 -> 0x8102; i8 NULL LAST ASC -> 0xFF + one zero;
    # u16 1 DESC -> sentinel 0xFE, ~0x0001; bool NULL FIRST ASC -> 0x00, 0.
    var want: List[UInt8] = [
        0x01, 0x81, 0x02, 0xFF, 0x00, 0xFE, 0xFF, 0xFE, 0x00, 0x00,
    ]
    assert_equal(got, want)


def test_desc_null_sides() raises:
    """Under DESC, a NULLS_FIRST NULL sorts before every value and a
    NULLS_LAST NULL after every value, by the encodings alone. The values
    are the extremes of each key's DESC image (i64 MAX encodes to all zero
    bytes under DESC, MIN to all 0xFF), so the sentinel alone must decide."""
    var batch = _desc_null_batch()
    var tags: List[UInt8] = [DT_I64]
    var cols: List[Int] = [0]
    var desc: List[UInt8] = [SORT_DESC]
    var is_null: List[Bool] = [True]
    var not_null: List[Bool] = [False]
    var nfs: List[UInt8] = [NULLS_FIRST, NULLS_LAST]
    var want: List[Int] = [-1, 1]
    for i in range(2):
        var nf: List[UInt8] = [nfs[i]]
        var bv = BatchView(batch)
        var e_null = encode_row_keys_for_sort(bv, 0, cols, tags, desc, nf, is_null)
        for row in range(2):
            var e_val = encode_row_keys_for_sort(
                bv, row, cols, tags, desc, nf, not_null
            )
            assert_equal(
                arrow_row_compare(e_null, e_val), want[i],
                "nf case " + String(i) + " row " + String(row),
            )


def _desc_null_batch() raises -> RecordBatch:
    """One i64 column: INT64_MAX, INT64_MIN."""
    var sb = SchemaBuilder()
    sb.add_field(Field("k", DType.int64, False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    _prim[DType.int64](rbb, [Int64.MAX, Int64.MIN])
    return rbb.build(sb.build())


def test_rows_order_by_encoding() raises:
    """Row 1 against row 0 per family, ascending, by the encodings alone: the
    value order decides (and descending reverses it)."""
    var batch = _batch()
    var tags = _tags()
    # Row 1 against row 0, key by key: i64 7 > -5, f64 -3.5 < 2.25,
    # u64 2^64-1 > 0x0102.., i32 0x01020304 > -2, f32 0.5 > -1.5,
    # u32 0xFFFFFFFE > 0x01020304, d32 -1 < 19000, d64 -1 < 1,
    # ts 0x0102.. > -1, i16 258 > -32767, u16 1 < 0xABCD, i8 127 > -127,
    # u8 1 < 0xFE, bool false < true.
    var want: List[Int] = [1, -1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, -1]
    for k in range(len(tags)):
        var t: List[UInt8] = [tags[k]]
        var c: List[Int] = [k]
        var asc: List[UInt8] = [SORT_ASC]
        var desc: List[UInt8] = [SORT_DESC]
        var nf: List[UInt8] = [NULLS_FIRST]
        var nl: List[Bool] = [False]
        var bv = BatchView(batch)
        var a0 = encode_row_keys_for_sort(bv, 0, c, t, asc, nf, nl)
        var a1 = encode_row_keys_for_sort(bv, 1, c, t, asc, nf, nl)
        var d0 = encode_row_keys_for_sort(bv, 0, c, t, desc, nf, nl)
        var d1 = encode_row_keys_for_sort(bv, 1, c, t, desc, nf, nl)
        assert_equal(arrow_row_compare(a1, a0), want[k], "asc key " + String(k))
        assert_equal(arrow_row_compare(d1, d0), -want[k], "desc key " + String(k))


def test_argument_length_checks() raises:
    """Each per-key list must hold one entry per key; each mismatch is
    refused, naming the list."""
    var batch = _batch()
    var cols: List[Int] = [0, 3]
    var tags: List[UInt8] = [DT_I64, DT_I32]
    var two_u8: List[UInt8] = [SORT_ASC, SORT_ASC]
    var one_u8: List[UInt8] = [SORT_ASC]
    var two_b: List[Bool] = [False, False]
    var three_b: List[Bool] = [False, False, False]
    var names: List[String] = ["asc_flags", "nulls_first_flags", "is_null_per_key"]
    for which in range(3):
        var msg = String("")
        try:
            if which == 0:
                _ = encode_row_keys_for_sort(
                    BatchView(batch), 0, cols, tags, one_u8, two_u8, two_b
                )
            elif which == 1:
                _ = encode_row_keys_for_sort(
                    BatchView(batch), 0, cols, tags, two_u8, one_u8, two_b
                )
            else:
                _ = encode_row_keys_for_sort(
                    BatchView(batch), 0, cols, tags, two_u8, two_u8, three_b
                )
        except e:
            msg = String(e)
        assert_true(names[which] + " length" in msg, msg)
        assert_true("!= n_keys 2" in msg, msg)
    # All lists matching: no refusal, 9 + 5 bytes.
    var ok = encode_row_keys_for_sort(
        BatchView(batch), 0, cols, tags, two_u8, two_u8, two_b
    )
    assert_equal(len(ok), 14)


def test_widths_and_refusals() raises:
    """The widths table for the timestamp units (read from a list, not
    folded); STRING and BINARY refused as varlen; any other tag refused as
    unsupported, by number. The composite encoder refuses the same tags in
    its width pass, before it reads a value."""
    var ts: List[UInt8] = [DT_TIMESTAMP_US, DT_TIMESTAMP_MS, DT_TIMESTAMP_S]
    for t in ts:
        assert_equal(encoded_width_for_dtype(t), 9)
    var varlen: List[UInt8] = [DT_STRING, DT_BINARY]
    for t in varlen:
        var msg = String("")
        try:
            _ = encoded_width_for_dtype(t)
        except e:
            msg = String(e)
        assert_true("varlen STRING/BINARY" in msg, msg)
        assert_true("(dtype_tag=" + String(Int(t)) + ")" in msg, msg)
    var bad: List[UInt8] = [0, 21, 255]
    for t in bad:
        var msg = String("")
        try:
            _ = encoded_width_for_dtype(t)
        except e:
            msg = String(e)
        assert_true("unsupported dtype_tag=" + String(Int(t)) in msg, msg)
    var batch = _batch()
    var all_bad: List[UInt8] = [DT_BINARY, 21]
    for t in all_bad:
        var tags: List[UInt8] = [DT_I64, t]
        var cols: List[Int] = [0, 1]
        var flags: List[UInt8] = [SORT_ASC, SORT_ASC]
        var nulls: List[Bool] = [False, False]
        var msg = String("")
        try:
            _ = encode_row_keys_for_sort(
                BatchView(batch), 0, cols, tags, flags, flags, nulls
            )
        except e:
            msg = String(e)
        assert_true("arrow_row.encoded_width_for_dtype:" in msg, msg)


def test_decimal128_value_encodes_both_words() raises:
    """A non-NULL DECIMAL128 key encodes as the sentinel plus
    `encode_decimal128_to_bytes` of the cell's high and low words, read at
    the 16-byte cell stride: row 0 is 2^64 + 5 (high word 1, so a read of
    the low word alone loses it), row 1 is -1 (both words all ones, so a
    missed sign flip or a swapped half shows). ASC and DESC, and the rows
    order by value: -1 < 2^64 + 5."""
    var batch = _batch()
    var tags: List[UInt8] = [DT_DECIMAL128]
    var cols: List[Int] = [14]
    var nulls: List[Bool] = [False]
    var his: List[UInt64] = [1, 0xFFFFFFFFFFFFFFFF]
    var los: List[UInt64] = [5, 0xFFFFFFFFFFFFFFFF]
    var dirs: List[UInt8] = [SORT_ASC, SORT_DESC]
    for d in range(2):
        var flags: List[UInt8] = [dirs[d]]
        var nf: List[UInt8] = [NULLS_FIRST]
        var enc = List[List[UInt8]]()
        for row in range(2):
            var dec = encode_decimal128_to_bytes(his[row], los[row], d == 0)
            var want = List[UInt8]()
            want.append(UInt8(0x01) if d == 0 else UInt8(0xFE))
            for i in range(16):
                want.append(dec[i])
            var got = encode_row_keys_for_sort(
                BatchView(batch), row, cols, tags, flags, nf, nulls
            )
            assert_equal(got, want, "dir " + String(d) + " row " + String(row))
            enc.append(got^)
        # Row 1 (-1) against row 0 (2^64 + 5).
        assert_equal(arrow_row_compare(enc[1], enc[0]), -1 if d == 0 else 1)


def test_compare_length_tiebreak() raises:
    """The first differing byte decides; a proper prefix is below the longer
    string; equal strings, empty ones included, are 0."""
    var e = List[UInt8]()
    var a: List[UInt8] = [1, 2, 3]
    var ab: List[UInt8] = [1, 2, 3, 0]
    var lo_long: List[UInt8] = [1, 1, 0xFF, 0xFF]
    var hi_last: List[UInt8] = [1, 2, 4]
    assert_equal(arrow_row_compare(a, ab), -1)
    assert_equal(arrow_row_compare(ab, a), 1)
    assert_equal(arrow_row_compare(e, a), -1)
    assert_equal(arrow_row_compare(a, e), 1)
    assert_equal(arrow_row_compare(e, e), 0)
    assert_equal(arrow_row_compare(a, a.copy()), 0)
    assert_equal(arrow_row_compare(lo_long, a), -1)
    assert_equal(arrow_row_compare(a, lo_long), 1)
    assert_equal(arrow_row_compare(a, hi_last), -1)
    assert_equal(arrow_row_compare(hi_last, a), 1)


def main() raises:
    var s = TestSuite()
    s.test[test_every_family_exact_bytes_asc]()
    s.test[test_every_family_exact_bytes_desc]()
    s.test[test_timestamp_units_encode_alike]()
    s.test[test_null_slots_sentinel_and_zero_padding]()
    s.test[test_mixed_null_and_value_keys]()
    s.test[test_desc_null_sides]()
    s.test[test_rows_order_by_encoding]()
    s.test[test_argument_length_checks]()
    s.test[test_widths_and_refusals]()
    s.test[test_decimal128_value_encodes_both_words]()
    s.test[test_compare_length_tiebreak]()
    s^.run()
