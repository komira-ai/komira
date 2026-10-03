# =============================================================================
# test_orc_column_decode.mojo — ORC per-column decode -> Arrow + PRESENT nulls.
# =============================================================================
#
# Drives the column decoder directly with hand-built decompressed StreamSpans, covering the
# primitive type matrix + the PRESENT-stream null bitmap (the value stream
# carries ONLY non-null rows; the decoder interleaves).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType

from komira_orc import (
    StreamSpan,
    ColumnAcc,
    make_accumulator,
    decode_stripe_column,
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_STREAM_DICTIONARY_DATA,
    ORC_ENCODING_DIRECT_V2,
    ORC_ENCODING_DICTIONARY_V2,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_DOUBLE,
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_STRING,
    ORC_KIND_BINARY,
    ORC_KIND_DATE,
)


# -----------------------------------------------------------------------------
# Encoder helpers (RLEv2 Direct + LENGTH + raw bytes/floats).
# -----------------------------------------------------------------------------


def _zigzag_encode(v: Int64) -> UInt64:
    return UInt64((v << 1) ^ (v >> 63))


def _vulong(n: UInt64, mut out: List[UInt8]):
    var v = n
    while True:
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


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
    """Emit a single RLEv2 Direct run encoding `values` at `bits` width."""
    var packed = List[Int64]()
    for i in range(len(values)):
        if signed:
            packed.append(Int64(_zigzag_encode(values[i])))
        else:
            packed.append(values[i])
    var out = List[UInt8]()
    var enc_w = bits - 1  # bits 1..24 map to enc 0..23 (direct table prefix)
    var L = len(values) - 1
    var b0 = (1 << 6) | (enc_w << 1) | ((L >> 8) & 1)
    out.append(UInt8(b0))
    out.append(UInt8(L & 0xFF))
    _pack_bits_be(packed, bits, out)
    return out^


def _present_stream(flags: List[Bool]) -> List[UInt8]:
    """Boolean RLE literal stream: ceil(n/8) bytes, MSB-first, as one literal."""
    var n_bytes = (len(flags) + 7) // 8
    var bits = List[UInt8]()
    for bi in range(n_bytes):
        var byte: Int = 0
        for k in range(8):
            var idx = bi * 8 + k
            var present = idx < len(flags) and flags[idx]
            byte = (byte << 1) | (1 if present else 0)
        bits.append(UInt8(byte))
    # Wrap as a byte-RLE literal run (header = 256 - count).
    var out = List[UInt8]()
    out.append(UInt8(256 - n_bytes))
    for i in range(n_bytes):
        out.append(bits[i])
    return out^


def _i64s(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(Int64(vals[i]))
    return out^


# =============================================================================
# Tests
# =============================================================================


def test_bigint_no_nulls() raises:
    var vals = _i64s(100, 200, 300, 400)
    var data = _rlev2_direct(vals, 12, True)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    var acc = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    decode_stripe_column(acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0, streams, 4)
    var col = acc^.build()
    assert_equal(col.length(), 4)
    assert_equal(col.null_count(), 0)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 100)
    assert_equal(Int(arr.get(3)), 400)


def test_bigint_with_nulls() raises:
    # 5 rows, present [T, F, T, T, F]. DATA carries 3 values for the 3 present.
    var present = List[Bool]()
    present.append(True)
    present.append(False)
    present.append(True)
    present.append(True)
    present.append(False)
    var vals = _i64s(11, 22, 33)  # for rows 0, 2, 3
    var data = _rlev2_direct(vals, 8, True)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_PRESENT, _present_stream(present)^))
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    var acc = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    decode_stripe_column(acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0, streams, 5)
    var col = acc^.build()
    assert_equal(col.length(), 5)
    assert_equal(col.null_count(), 2)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 11)
    assert_true(arr.is_null(1))
    assert_equal(Int(arr.get(2)), 22)
    assert_equal(Int(arr.get(3)), 33)
    assert_true(arr.is_null(4))


def test_int32_signed() raises:
    var vals = _i64s(-5, 10, -2000)
    var data = _rlev2_direct(vals, 12, True)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    var acc = make_accumulator(ORC_KIND_INT, ArrowType.INT32)
    decode_stripe_column(acc, ORC_KIND_INT, ORC_ENCODING_DIRECT_V2, 0, streams, 3)
    var col = acc^.build()
    var arr = col.as_primitive[DType.int32]()
    assert_equal(Int(arr.get(0)), -5)
    assert_equal(Int(arr.get(2)), -2000)


def test_date_arrow_type() raises:
    var vals = _i64s(18000, 18001, 18002)
    var data = _rlev2_direct(vals, 16, True)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    var acc = make_accumulator(ORC_KIND_DATE, ArrowType.DATE32)
    decode_stripe_column(acc, ORC_KIND_DATE, ORC_ENCODING_DIRECT_V2, 0, streams, 3)
    var col = acc^.build()
    assert_equal(col.arrow_type.type_id, ArrowType.DATE32.type_id)
    var arr = col.as_primitive[DType.int32]()
    assert_equal(Int(arr.get(0)), 18000)


def test_double() raises:
    # Two doubles 1.5 and -2.25, raw IEEE-754 LE, no RLE.
    var data = List[UInt8]()
    _append_f64_le(data, Float64(1.5))
    _append_f64_le(data, Float64(-2.25))
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    var acc = make_accumulator(ORC_KIND_DOUBLE, ArrowType.FLOAT64)
    decode_stripe_column(acc, ORC_KIND_DOUBLE, ORC_ENCODING_DIRECT_V2, 0, streams, 2)
    var col = acc^.build()
    var arr = col.as_primitive[DType.float64]()
    assert_true(arr.get(0) > 1.49 and arr.get(0) < 1.51)
    assert_true(arr.get(1) > -2.26 and arr.get(1) < -2.24)


def test_boolean() raises:
    # 3 rows: present-true / values [T, F, T].
    var data = List[UInt8]()
    data.append(UInt8(256 - 1))  # literal 1 byte
    data.append(UInt8(0b10100000))  # T F T (MSB-first)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    var acc = make_accumulator(ORC_KIND_BOOLEAN, ArrowType.BOOL)
    decode_stripe_column(acc, ORC_KIND_BOOLEAN, ORC_ENCODING_DIRECT_V2, 0, streams, 3)
    var col = acc^.build()
    var arr = col.as_boolean()
    assert_true(arr.get(0))
    assert_true(not arr.get(1))
    assert_true(arr.get(2))


def test_tinyint() raises:
    # byte RLE literal: 3 values 1, -2, 127.
    var data = List[UInt8]()
    data.append(UInt8(256 - 3))
    data.append(UInt8(1))
    data.append(UInt8(256 - 2))  # -2 two's complement
    data.append(UInt8(127))
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    var acc = make_accumulator(ORC_KIND_BYTE, ArrowType.INT8)
    decode_stripe_column(acc, ORC_KIND_BYTE, ORC_ENCODING_DIRECT_V2, 0, streams, 3)
    var col = acc^.build()
    var arr = col.as_primitive[DType.int8]()
    assert_equal(Int(arr.get(0)), 1)
    assert_equal(Int(arr.get(1)), -2)
    assert_equal(Int(arr.get(2)), 127)


def test_string_direct() raises:
    # 3 strings: "ab", "", "xyz". LENGTH = [2, 0, 3] unsigned RLEv2 Direct.
    var data = List[UInt8]()
    var concat = String("abxyz")
    var cb = concat.as_bytes()
    for i in range(len(cb)):
        data.append(cb[i])
    var lens = _i64s(2, 0, 3)
    var length_stream = _rlev2_direct(lens, 4, False)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    streams.append(StreamSpan(ORC_STREAM_LENGTH, length_stream^))
    var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
    decode_stripe_column(acc, ORC_KIND_STRING, ORC_ENCODING_DIRECT_V2, 0, streams, 3)
    var col = acc^.build()
    var arr = col.as_string()
    assert_equal(arr.get(0), String("ab"))
    assert_equal(arr.get(1), String(""))
    assert_equal(arr.get(2), String("xyz"))


def test_string_dictionary() raises:
    # Dictionary of 2 entries ["red", "blue"]; 4 rows index [0,1,1,0].
    # DICTIONARY_DATA = "redblue", LENGTH = [3, 4], DATA indices = [0,1,1,0].
    var dict_data = List[UInt8]()
    var ds = String("redblue")
    var db = ds.as_bytes()
    for i in range(len(db)):
        dict_data.append(db[i])
    var dict_lens = _i64s(3, 4)
    var length_stream = _rlev2_direct(dict_lens, 4, False)
    var indices = _i64s(0, 1, 1, 0)
    var data = _rlev2_direct(indices, 2, False)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DICTIONARY_DATA, dict_data^))
    streams.append(StreamSpan(ORC_STREAM_LENGTH, length_stream^))
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
    decode_stripe_column(
        acc, ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2, 2, streams, 4
    )
    var col = acc^.build()
    var arr = col.as_string()
    assert_equal(arr.get(0), String("red"))
    assert_equal(arr.get(1), String("blue"))
    assert_equal(arr.get(2), String("blue"))
    assert_equal(arr.get(3), String("red"))


def test_binary() raises:
    # 2 binaries: [0xDE,0xAD], [0xBE,0xEF,0x00]. LENGTH = [2,3].
    var data = List[UInt8]()
    data.append(UInt8(0xDE))
    data.append(UInt8(0xAD))
    data.append(UInt8(0xBE))
    data.append(UInt8(0xEF))
    data.append(UInt8(0x00))
    var lens = _i64s(2, 3)
    var length_stream = _rlev2_direct(lens, 4, False)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DATA, data^))
    streams.append(StreamSpan(ORC_STREAM_LENGTH, length_stream^))
    var acc = make_accumulator(ORC_KIND_BINARY, ArrowType.BINARY)
    decode_stripe_column(acc, ORC_KIND_BINARY, ORC_ENCODING_DIRECT_V2, 0, streams, 2)
    var col = acc^.build()
    var arr = col.as_binary()
    assert_equal(arr.get_length(0), 2)
    assert_equal(arr.get_length(1), 3)


def test_multi_stripe_accumulation() raises:
    # Same accumulator fed two stripes of 2 BIGINTs each -> 4 rows.
    var acc = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    var s1 = List[StreamSpan]()
    s1.append(StreamSpan(ORC_STREAM_DATA, _rlev2_direct(_i64s(1, 2), 8, True)^))
    decode_stripe_column(acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0, s1, 2)
    var s2 = List[StreamSpan]()
    s2.append(StreamSpan(ORC_STREAM_DATA, _rlev2_direct(_i64s(3, 4), 8, True)^))
    decode_stripe_column(acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0, s2, 2)
    var col = acc^.build()
    assert_equal(col.length(), 4)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 1)
    assert_equal(Int(arr.get(3)), 4)


def _append_f64_le(mut out: List[UInt8], v: Float64):
    from std.memory import bitcast

    var u = bitcast[DType.uint64, 1](v)
    for k in range(8):
        out.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def main() raises:
    test_bigint_no_nulls()
    test_bigint_with_nulls()
    test_int32_signed()
    test_date_arrow_type()
    test_double()
    test_boolean()
    test_tinyint()
    test_string_direct()
    test_string_dictionary()
    test_binary()
    test_multi_stripe_accumulation()
    print("test_orc_column_decode: ALL PASS")
