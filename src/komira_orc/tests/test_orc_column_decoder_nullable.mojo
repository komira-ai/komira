# =============================================================================
# test_orc_column_decoder_nullable.mojo: column_decoder.mojo's accumulator,
# its nullable (PRESENT) path, and the stripe orders between its states.
# =============================================================================
#
# test_orc_column_decode.mojo covers the no-null decode of each type. This
# file covers the rest of the decode side of `column_decoder.mojo`: reserve,
# build and the accumulator factory; the nullable path of every type (a
# PRESENT stream with nulls, and one with none); and the stripe orders that
# move an accumulator between its no-null and nullable states. The refusals
# are in test_orc_column_decoder_refusals.mojo.
#
# Fixture bytes come from the Apache ORC v1 specification's worked examples
# where one fits (orc.apache.org/specification/ORCv1/, "Run Length
# Encoding"); each such fixture names its example. The rest are built with
# the encoders below, which follow the same sections of the spec.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion

from komira_orc import (
    StreamSpan,
    ColumnAcc,
    make_accumulator,
    decode_stripe_column,
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_STREAM_DICTIONARY_DATA,
    ORC_ENCODING_DIRECT,
    ORC_ENCODING_DICTIONARY,
    ORC_ENCODING_DIRECT_V2,
    ORC_ENCODING_DICTIONARY_V2,
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_BINARY,
    ORC_KIND_DATE,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_TIMESTAMP,
    ORC_KIND_DECIMAL,
)
from komira_orc.column_decoder import (
    ORC_MAX_ROWS,
    ACC_BOOL,
    ACC_I8,
    ACC_I16,
    ACC_I32,
    ACC_I64,
    ACC_F32,
    ACC_F64,
    ACC_STRING,
    ACC_BINARY,
    _decode_present,
)


# -----------------------------------------------------------------------------
# Fixtures from the spec's worked examples.
# -----------------------------------------------------------------------------


def _bytes(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _spec_byte_rle_44_45() -> List[UInt8]:
    """Byte RLE: "the sequence 0x44, 0x45 would be encoded as [0xfe, 0x44,
    0x45]"."""
    return _bytes(0xFE, 0x44, 0x45)


def _spec_bool_one_true() -> List[UInt8]:
    """Boolean RLE: "[0xff, 0x80] would be one true followed by seven false
    values"."""
    return _bytes(0xFF, 0x80)


def _spec_rlev1_literals() -> List[UInt8]:
    """RLEv1: "Numbers [2, 3, 6, 7, 11] would be encoded as [0xfb, 0x02,
    0x03, 0x06, 0x07, 0xb]". Read signed (zigzag) it is [1, -2, 3, -4, -6]."""
    return _bytes(0xFB, 0x02, 0x03, 0x06, 0x07, 0x0B)


def _spec_rlev2_short_repeat() -> List[UInt8]:
    """RLEv2 Short Repeat: unsigned [10000] * 5 is [0x0a, 0x27, 0x10]. Read
    signed (zigzag) it is [5000] * 5."""
    return _bytes(0x0A, 0x27, 0x10)


def _spec_rlev2_direct() -> List[UInt8]:
    """RLEv2 Direct: unsigned [23713, 43806, 57005, 48879] is [0x5e, 0x03,
    0x5c, 0xa1, 0xab, 0x1e, 0xde, 0xad, 0xbe, 0xef]. Read signed (zigzag) it
    is [-11857, 21903, -28503, -24440]."""
    return _bytes(0x5E, 0x03, 0x5C, 0xA1, 0xAB, 0x1E, 0xDE, 0xAD, 0xBE, 0xEF)


def _spec_rlev2_delta() -> List[UInt8]:
    """RLEv2 Delta: unsigned [2, 3, 5, 7, 11, 13, 17, 19, 23, 29] (sum 129)
    is [0xc6, 0x09, 0x02, 0x02, 0x22, 0x42, 0x42, 0x46]."""
    return _bytes(0xC6, 0x09, 0x02, 0x02, 0x22, 0x42, 0x42, 0x46)


def _rlev2_one_u64_sign_bit() -> List[UInt8]:
    """RLEv2 Direct, one unsigned value at width 64 (5-bit width code 31):
    header 0x7e 0x00, then 0x8000000000000000 big-endian. As an Int64 it is
    negative, the shape `_check_lengths_non_negative` and the dictionary
    index check exist for."""
    return _bytes(0x7E, 0x00, 0x80, 0, 0, 0, 0, 0, 0, 0)


# -----------------------------------------------------------------------------
# Encoders (spec "Run Length Encoding" and "Column Encoding" sections).
# -----------------------------------------------------------------------------


def _zigzag(v: Int64) -> UInt64:
    return UInt64((v << 1) ^ (v >> 63))


def _rlev2_direct(values: List[Int64], bits: Int, signed: Bool) -> List[UInt8]:
    """One RLEv2 Direct run at `bits` (1..24: width code bits - 1)."""
    var out = List[UInt8]()
    var n = len(values) - 1
    out.append(UInt8((1 << 6) | ((bits - 1) << 1) | ((n >> 8) & 1)))
    out.append(UInt8(n & 0xFF))
    var cur: UInt64 = 0
    var filled = 0
    for i in range(len(values)):
        var v = _zigzag(values[i]) if signed else UInt64(values[i])
        for b in range(bits - 1, -1, -1):
            cur = (cur << 1) | ((v >> UInt64(b)) & 1)
            filled += 1
            if filled == 8:
                out.append(UInt8(cur & 0xFF))
                cur = 0
                filled = 0
    if filled > 0:
        out.append(UInt8((cur << UInt64(8 - filled)) & 0xFF))
    return out^


def _i64s(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(Int64(vals[i]))
    return out^


def _flags(spec: String) -> List[Bool]:
    """'v' = present, 'n' = null, one character per row."""
    var out = List[Bool]()
    for b in spec.as_bytes():
        out.append(b == UInt8(ord("v")))
    return out^


def _present(spec: String) -> List[UInt8]:
    """A PRESENT stream: the flags as boolean RLE, one byte-RLE literal run of
    ceil(n / 8) bytes, most significant bit first (n <= 1024)."""
    var flags = _flags(spec)
    var n_bytes = (len(flags) + 7) // 8
    var out = List[UInt8]()
    out.append(UInt8(256 - n_bytes))
    for bi in range(n_bytes):
        var byte = 0
        for k in range(8):
            var i = bi * 8 + k
            byte = (byte << 1) | (1 if i < len(flags) and flags[i] else 0)
        out.append(UInt8(byte))
    return out^


def _f32_le(*vals: Float32) -> List[UInt8]:
    from std.memory import bitcast

    var out = List[UInt8]()
    for i in range(len(vals)):
        var u = bitcast[DType.uint32, 1](vals[i])
        for k in range(4):
            out.append(UInt8((u >> UInt32(8 * k)) & 0xFF))
    return out^


def _f64_le(*vals: Float64) -> List[UInt8]:
    from std.memory import bitcast

    var out = List[UInt8]()
    for i in range(len(vals)):
        var u = bitcast[DType.uint64, 1](vals[i])
        for k in range(8):
            out.append(UInt8((u >> UInt64(8 * k)) & 0xFF))
    return out^


def _text(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _one(kind: Int, var bytes: List[UInt8]) -> List[StreamSpan]:
    var out = List[StreamSpan]()
    out.append(StreamSpan(kind, bytes^))
    return out^


def _two(
    k1: Int, var b1: List[UInt8], k2: Int, var b2: List[UInt8]
) -> List[StreamSpan]:
    var out = List[StreamSpan]()
    out.append(StreamSpan(k1, b1^))
    out.append(StreamSpan(k2, b2^))
    return out^


def _nulls(col_rows: Int, col: Column[HeapRegion]) -> String:
    """'v'/'n' per row of `col`, the inverse of `_flags`."""
    var s = String()
    for i in range(col_rows):
        s += "n" if col.is_null_at(i) else "v"
    return s^


# =============================================================================
# 1. Accumulator: reserve, build, factory.
# =============================================================================


def test_reserve_refuses_bad_row_counts() raises:
    # A negative count and one past ORC_MAX_ROWS are refused before any
    # allocation; 0 is accepted for every tag (the `< 0` boundary).
    var acc = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    with assert_raises(contains="negative row count -1"):
        acc.reserve(-1)
    with assert_raises(contains="declared row count 1099511627777 exceeds"):
        acc.reserve(ORC_MAX_ROWS + 1)
    var kinds: List[Int] = [
        ORC_KIND_BOOLEAN, ORC_KIND_BYTE, ORC_KIND_SHORT, ORC_KIND_INT,
        ORC_KIND_LONG, ORC_KIND_FLOAT, ORC_KIND_DOUBLE, ORC_KIND_STRING,
        ORC_KIND_BINARY,
    ]
    for i in range(len(kinds)):
        var a = make_accumulator(kinds[i], ArrowType.INT64)
        a.reserve(0)
        assert_equal(a.n_rows, 0)


def test_reserve_long_zero_keeps_list_path() raises:
    # reserve(0) on BIGINT leaves the zero-copy buffer off (`total_rows > 0`
    # false); reserve(3) turns it on. Both still decode the same values.
    var off = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    off.reserve(0)
    assert_false(off.i64_buf_active)
    var on = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    on.reserve(3)
    assert_true(on.i64_buf_active)
    for which in range(2):
        var acc = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
        acc.reserve(3 * which)
        var data = _rlev2_direct(_i64s(-7, 0, 9), 8, True)
        decode_stripe_column(
            acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0,
            _one(ORC_STREAM_DATA, data^), 3,
        )
        var arr = acc^.build().as_primitive[DType.int64]()
        assert_equal(Int(arr.get(0)), -7)
        assert_equal(Int(arr.get(2)), 9)


def test_reserve_binary_then_decode() raises:
    var acc = make_accumulator(ORC_KIND_BINARY, ArrowType.BINARY)
    acc.reserve(2)
    var streams = _two(
        ORC_STREAM_DATA, _bytes(0xDE, 0xAD, 0xBE),
        ORC_STREAM_LENGTH, _rlev2_direct(_i64s(1, 2), 4, False),
    )
    decode_stripe_column(
        acc, ORC_KIND_BINARY, ORC_ENCODING_DIRECT_V2, 0, streams, 2
    )
    var arr = acc^.build().as_binary()
    assert_equal(arr.get_length(0), 1)
    assert_equal(Int(arr.get(1)[1]), 0xBE)


def test_unknown_tag_reserves_nothing_and_build_raises() raises:
    # A tag outside the nine: reserve() matches no arm and turns nothing on;
    # build() refuses it.
    var acc = ColumnAcc(Int8(9), ArrowType.INT64)
    acc.reserve(4)
    assert_false(acc.i64_buf_active)
    assert_equal(acc.n_rows, 0)
    with assert_raises(contains="INTERNAL: unknown accumulator tag"):
        _ = acc^.build()


def test_make_accumulator_maps_every_kind() raises:
    assert_equal(make_accumulator(ORC_KIND_BOOLEAN, ArrowType.BOOL).tag, ACC_BOOL)
    assert_equal(make_accumulator(ORC_KIND_BYTE, ArrowType.INT8).tag, ACC_I8)
    assert_equal(make_accumulator(ORC_KIND_SHORT, ArrowType.INT16).tag, ACC_I16)
    assert_equal(make_accumulator(ORC_KIND_INT, ArrowType.INT32).tag, ACC_I32)
    assert_equal(make_accumulator(ORC_KIND_DATE, ArrowType.DATE32).tag, ACC_I32)
    assert_equal(make_accumulator(ORC_KIND_LONG, ArrowType.INT64).tag, ACC_I64)
    assert_equal(make_accumulator(ORC_KIND_FLOAT, ArrowType.FLOAT32).tag, ACC_F32)
    assert_equal(make_accumulator(ORC_KIND_DOUBLE, ArrowType.FLOAT64).tag, ACC_F64)
    for k in [ORC_KIND_STRING, ORC_KIND_VARCHAR, ORC_KIND_CHAR]:
        assert_equal(make_accumulator(k, ArrowType.STRING).tag, ACC_STRING)
    assert_equal(make_accumulator(ORC_KIND_BINARY, ArrowType.BINARY).tag, ACC_BINARY)
    with assert_raises(contains="UNSUPPORTED_TYPE: ORC Type.Kind timestamp (9)"):
        _ = make_accumulator(ORC_KIND_TIMESTAMP, ArrowType.INT64)
    with assert_raises(contains="(14) is not a primitive kind"):
        _ = make_accumulator(ORC_KIND_DECIMAL, ArrowType.INT64)


def test_decode_refuses_unsupported_kind_on_both_paths() raises:
    var acc = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    with assert_raises(contains="Type.Kind timestamp is not a primitive"):
        decode_stripe_column(
            acc, ORC_KIND_TIMESTAMP, ORC_ENCODING_DIRECT_V2, 0,
            _one(ORC_STREAM_DATA, _bytes(0x00)), 1,
        )
    with assert_raises(contains="Type.Kind decimal is not a primitive"):
        decode_stripe_column(
            acc, ORC_KIND_DECIMAL, ORC_ENCODING_DIRECT_V2, 0,
            _one(ORC_STREAM_PRESENT, _present("v")), 1,
        )


# =============================================================================
# 2. The nullable path of each type (a PRESENT stream with nulls).
# =============================================================================


def test_boolean_nullable() raises:
    # 5 rows "vnvvn": 3 present values from the spec's [0xff, 0x80]
    # (true, false, false). Null rows are null in the bitmap, and the values
    # land on the present rows in order.
    var acc = make_accumulator(ORC_KIND_BOOLEAN, ArrowType.BOOL)
    var streams = _two(
        ORC_STREAM_PRESENT, _present("vnvvn"),
        ORC_STREAM_DATA, _spec_bool_one_true(),
    )
    decode_stripe_column(
        acc, ORC_KIND_BOOLEAN, ORC_ENCODING_DIRECT_V2, 0, streams, 5
    )
    var col = acc^.build()
    assert_equal(col.null_count(), 2)
    assert_equal(_nulls(5, col), "vnvvn")
    var arr = col.as_boolean()
    assert_true(arr.get(0))
    assert_false(arr.get(2))
    assert_false(arr.get(3))


def test_tinyint_nullable_sign_extends() raises:
    # Present values: the spec's byte-RLE [0x44, 0x45], then a literal of
    # 0x7f, 0x80, 0xff: 127 stays positive, 0x80 and 0xff read as -128 and
    # -1. Moving the decoder's `b >= 128` boundary to `> 128`, or deleting
    # `b -= 256`, leaves 128 or 255 in the int64 list; the int8 bulk fill
    # refuses a value outside int8 (VALUE_OUT_OF_RANGE), so both turn this red.
    var acc = make_accumulator(ORC_KIND_BYTE, ArrowType.INT8)
    var data = _spec_byte_rle_44_45()
    data.extend(_bytes(0xFD, 0x7F, 0x80, 0xFF))
    var streams = _two(
        ORC_STREAM_PRESENT, _present("vvnvvv"), ORC_STREAM_DATA, data^
    )
    decode_stripe_column(acc, ORC_KIND_BYTE, ORC_ENCODING_DIRECT_V2, 0, streams, 6)
    var col = acc^.build()
    assert_equal(_nulls(6, col), "vvnvvv")
    assert_equal(col.null_count(), 1)
    var arr = col.as_primitive[DType.int8]()
    assert_equal(Int(arr.get(0)), 0x44)
    assert_equal(Int(arr.get(1)), 0x45)
    assert_equal(Int(arr.get(3)), 127)
    assert_equal(Int(arr.get(4)), -128)
    assert_equal(Int(arr.get(5)), -1)


def test_tinyint_no_present_sign_extends() raises:
    var acc = make_accumulator(ORC_KIND_BYTE, ArrowType.INT8)
    decode_stripe_column(
        acc, ORC_KIND_BYTE, ORC_ENCODING_DIRECT_V2, 0,
        _one(ORC_STREAM_DATA, _bytes(0xFD, 0x7F, 0x80, 0xFF)), 3,
    )
    var arr = acc^.build().as_primitive[DType.int8]()
    assert_equal(Int(arr.get(0)), 127)
    assert_equal(Int(arr.get(1)), -128)
    assert_equal(Int(arr.get(2)), -1)


def test_short_nullable_spec_direct() raises:
    # The spec's RLEv2 Direct example read signed fills the 4 present rows.
    var acc = make_accumulator(ORC_KIND_SHORT, ArrowType.INT16)
    var streams = _two(
        ORC_STREAM_PRESENT, _present("vnvvnv"),
        ORC_STREAM_DATA, _spec_rlev2_direct(),
    )
    decode_stripe_column(acc, ORC_KIND_SHORT, ORC_ENCODING_DIRECT_V2, 0, streams, 6)
    var col = acc^.build()
    assert_equal(col.arrow_type.type_id, ArrowType.INT16.type_id)
    assert_equal(_nulls(6, col), "vnvvnv")
    assert_equal(col.null_count(), 2)
    var arr = col.as_primitive[DType.int16]()
    assert_equal(Int(arr.get(0)), -11857)
    assert_equal(Int(arr.get(2)), 21903)
    assert_equal(Int(arr.get(3)), -28503)
    assert_equal(Int(arr.get(5)), -24440)


def test_int_v1_nullable_spec_literals() raises:
    # DIRECT (v1) encoding: the RLEv1 literal example read signed.
    var acc = make_accumulator(ORC_KIND_INT, ArrowType.INT32)
    var streams = _two(
        ORC_STREAM_PRESENT, _present("vvnvvv"),
        ORC_STREAM_DATA, _spec_rlev1_literals(),
    )
    decode_stripe_column(acc, ORC_KIND_INT, ORC_ENCODING_DIRECT, 0, streams, 6)
    var col = acc^.build()
    assert_equal(_nulls(6, col), "vvnvvv")
    var arr = col.as_primitive[DType.int32]()
    assert_equal(Int(arr.get(0)), 1)
    assert_equal(Int(arr.get(1)), -2)
    assert_equal(Int(arr.get(3)), 3)
    assert_equal(Int(arr.get(4)), -4)
    assert_equal(Int(arr.get(5)), -6)


def test_int_v1_no_present() raises:
    var acc = make_accumulator(ORC_KIND_DATE, ArrowType.DATE32)
    decode_stripe_column(
        acc, ORC_KIND_DATE, ORC_ENCODING_DIRECT, 0,
        _one(ORC_STREAM_DATA, _spec_rlev1_literals()), 5,
    )
    var arr = acc^.build().as_primitive[DType.int32]()
    assert_equal(Int(arr.get(1)), -2)
    assert_equal(Int(arr.get(4)), -6)


def test_float_nullable_and_all_present() raises:
    # Stripe 1 "vnv": a null between 1.5 and -0.25. Stripe 2 has a PRESENT
    # stream with no null: the fast arm, which must keep `present` in step
    # because stripe 1 had a null.
    var acc = make_accumulator(ORC_KIND_FLOAT, ArrowType.FLOAT32)
    var s1 = _two(
        ORC_STREAM_PRESENT, _present("vnv"),
        ORC_STREAM_DATA, _f32_le(Float32(1.5), Float32(-0.25)),
    )
    decode_stripe_column(acc, ORC_KIND_FLOAT, ORC_ENCODING_DIRECT, 0, s1, 3)
    var s2 = _two(
        ORC_STREAM_PRESENT, _present("vv"),
        ORC_STREAM_DATA, _f32_le(Float32(3.0), Float32(-8.0)),
    )
    decode_stripe_column(acc, ORC_KIND_FLOAT, ORC_ENCODING_DIRECT, 0, s2, 2)
    assert_equal(len(acc.present), 5)
    var col = acc^.build()
    assert_equal(_nulls(5, col), "vnvvv")
    assert_equal(col.null_count(), 1)
    var arr = col.as_primitive[DType.float32]()
    assert_equal(arr.get(0), Float32(1.5))
    assert_equal(arr.get(2), Float32(-0.25))
    assert_equal(arr.get(3), Float32(3.0))
    assert_equal(arr.get(4), Float32(-8.0))


def test_float_present_all_valid_first() raises:
    # A PRESENT stream with no null, and no null before it: `present` stays
    # empty and the column has no validity.
    var acc = make_accumulator(ORC_KIND_FLOAT, ArrowType.FLOAT32)
    var streams = _two(
        ORC_STREAM_PRESENT, _present("vv"),
        ORC_STREAM_DATA, _f32_le(Float32(2.0), Float32(4.0)),
    )
    decode_stripe_column(acc, ORC_KIND_FLOAT, ORC_ENCODING_DIRECT, 0, streams, 2)
    assert_equal(len(acc.present), 0)
    var col = acc^.build()
    assert_equal(col.null_count(), 0)
    assert_equal(col.as_primitive[DType.float32]().get(1), Float32(4.0))


def test_double_nullable_and_all_present() raises:
    var acc = make_accumulator(ORC_KIND_DOUBLE, ArrowType.FLOAT64)
    var s1 = _two(
        ORC_STREAM_PRESENT, _present("nvn"),
        ORC_STREAM_DATA, _f64_le(Float64(-2.5)),
    )
    decode_stripe_column(acc, ORC_KIND_DOUBLE, ORC_ENCODING_DIRECT, 0, s1, 3)
    var s2 = _two(
        ORC_STREAM_PRESENT, _present("vv"),
        ORC_STREAM_DATA, _f64_le(Float64(0.5), Float64(1e300)),
    )
    decode_stripe_column(acc, ORC_KIND_DOUBLE, ORC_ENCODING_DIRECT, 0, s2, 2)
    var col = acc^.build()
    assert_equal(_nulls(5, col), "nvnvv")
    assert_equal(col.null_count(), 2)
    var arr = col.as_primitive[DType.float64]()
    assert_equal(arr.get(1), Float64(-2.5))
    assert_equal(arr.get(3), Float64(0.5))
    assert_equal(arr.get(4), Float64(1e300))


def test_string_direct_v1_nullable() raises:
    # DIRECT (v1): LENGTH is the RLEv1 literal example [2, 3, 6, 7, 11],
    # DATA their 29 bytes; one null between them.
    var acc = make_accumulator(ORC_KIND_VARCHAR, ArrowType.STRING)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_PRESENT, _present("vvnvvv")))
    streams.append(
        StreamSpan(ORC_STREAM_DATA, _text("abcdefghijklmnopqrstuvwxyz012"))
    )
    streams.append(StreamSpan(ORC_STREAM_LENGTH, _spec_rlev1_literals()))
    decode_stripe_column(acc, ORC_KIND_VARCHAR, ORC_ENCODING_DIRECT, 0, streams, 6)
    var col = acc^.build()
    assert_equal(_nulls(6, col), "vvnvvv")
    var arr = col.as_string()
    assert_equal(arr.get(0), "ab")
    assert_equal(arr.get(1), "cde")
    assert_equal(arr.get(3), "fghijk")
    assert_equal(arr.get(4), "lmnopqr")
    assert_equal(arr.get(5), "stuvwxyz012")


def test_binary_nullable_across_stripes() raises:
    # Stripe 1 has no PRESENT stream (2 rows), stripe 2 "nvn" holds the
    # first null: the 2 earlier rows are back-filled valid. Stripe 3 "vn"
    # is a second null-bearing stripe (the back-fill runs once).
    var acc = make_accumulator(ORC_KIND_BINARY, ArrowType.BINARY)
    var s1 = _two(
        ORC_STREAM_DATA, _bytes(1, 2, 3),
        ORC_STREAM_LENGTH, _rlev2_direct(_i64s(1, 2), 4, False),
    )
    decode_stripe_column(acc, ORC_KIND_BINARY, ORC_ENCODING_DIRECT_V2, 0, s1, 2)
    var s2 = List[StreamSpan]()
    s2.append(StreamSpan(ORC_STREAM_PRESENT, _present("nvn")))
    s2.append(StreamSpan(ORC_STREAM_DATA, _bytes(9, 8)))
    s2.append(StreamSpan(ORC_STREAM_LENGTH, _rlev2_direct(_i64s(2), 4, False)))
    decode_stripe_column(acc, ORC_KIND_BINARY, ORC_ENCODING_DIRECT_V2, 0, s2, 3)
    var s3 = List[StreamSpan]()
    s3.append(StreamSpan(ORC_STREAM_PRESENT, _present("vn")))
    s3.append(StreamSpan(ORC_STREAM_DATA, _bytes()))
    s3.append(StreamSpan(ORC_STREAM_LENGTH, _rlev2_direct(_i64s(0), 1, False)))
    decode_stripe_column(acc, ORC_KIND_BINARY, ORC_ENCODING_DIRECT_V2, 0, s3, 2)
    assert_equal(len(acc.present), 7)
    var col = acc^.build()
    assert_equal(_nulls(7, col), "vvnvnvn")
    assert_equal(col.null_count(), 3)
    var arr = col.as_binary()
    assert_equal(arr.get_length(1), 2)
    assert_equal(Int(arr.get(1)[1]), 3)
    assert_equal(arr.get_length(3), 2)
    assert_equal(Int(arr.get(3)[0]), 9)
    assert_equal(arr.get_length(5), 0)
    assert_false(col.is_null_at(5))


def test_binary_present_all_valid() raises:
    # A PRESENT stream with no null on a fresh column: no validity at all.
    var acc = make_accumulator(ORC_KIND_BINARY, ArrowType.BINARY)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_PRESENT, _present("v")))
    streams.append(StreamSpan(ORC_STREAM_DATA, _bytes(7)))
    streams.append(StreamSpan(ORC_STREAM_LENGTH, _rlev2_direct(_i64s(1), 1, False)))
    decode_stripe_column(acc, ORC_KIND_BINARY, ORC_ENCODING_DIRECT_V2, 0, streams, 1)
    assert_equal(len(acc.present), 0)
    var col = acc^.build()
    assert_equal(col.null_count(), 0)
    assert_equal(Int(col.as_binary().get(0)[0]), 7)


def _dict_streams(
    present: String, var indices: List[UInt8], is_v2: Bool
) -> List[StreamSpan]:
    """Dictionary ["blue", "red"] (sorted, as the spec requires): LENGTH
    [4, 3], DICTIONARY_DATA "bluered", DATA the given index stream."""
    var out = List[StreamSpan]()
    if present != "":
        out.append(StreamSpan(ORC_STREAM_PRESENT, _present(present)))
    out.append(StreamSpan(ORC_STREAM_DICTIONARY_DATA, _text("bluered")))
    if is_v2:
        out.append(
            StreamSpan(ORC_STREAM_LENGTH, _rlev2_direct(_i64s(4, 3), 4, False))
        )
    else:
        # RLEv1 literal of 2 unsigned varints: [0xfe, 4, 3].
        out.append(StreamSpan(ORC_STREAM_LENGTH, _bytes(0xFE, 4, 3)))
    out.append(StreamSpan(ORC_STREAM_DATA, indices^))
    return out^


def test_dictionary_v2_nullable() raises:
    var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
    var streams = _dict_streams(
        "vnvv", _rlev2_direct(_i64s(1, 0, 1), 1, False), True
    )
    decode_stripe_column(
        acc, ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2, 2, streams, 4
    )
    var col = acc^.build()
    assert_equal(_nulls(4, col), "vnvv")
    var arr = col.as_string()
    assert_equal(arr.get(0), "red")
    assert_equal(arr.get(2), "blue")
    assert_equal(arr.get(3), "red")


def test_dictionary_v1_both_paths() raises:
    # DICTIONARY (v1) on a CHAR column: indices as an RLEv1 literal
    # [0xfd, 0, 1, 1], first with no PRESENT stream, then with "vnvv".
    var acc = make_accumulator(ORC_KIND_CHAR, ArrowType.STRING)
    decode_stripe_column(
        acc, ORC_KIND_CHAR, ORC_ENCODING_DICTIONARY, 2,
        _dict_streams("", _bytes(0xFD, 0, 1, 1), False), 3,
    )
    decode_stripe_column(
        acc, ORC_KIND_CHAR, ORC_ENCODING_DICTIONARY, 2,
        _dict_streams("vnvv", _bytes(0xFD, 1, 0, 0), False), 4,
    )
    var col = acc^.build()
    assert_equal(_nulls(7, col), "vvvvnvv")
    var arr = col.as_string()
    assert_equal(arr.get(0), "blue")
    assert_equal(arr.get(1), "red")
    assert_equal(arr.get(3), "red")
    assert_equal(arr.get(5), "blue")
    assert_equal(arr.get(6), "blue")


# =============================================================================
# 3. Stripe orders that move an integer accumulator between its states.
# =============================================================================


def test_long_zero_copy_then_nullable_migrates() raises:
    # reserve() turns on BIGINT's zero-copy buffer; stripe 1 (no PRESENT)
    # decodes into it; stripe 2 "vnv" must copy those 3 rows to the list
    # path, back-fill them valid and append its own. Stripe 3 (PRESENT, no
    # null) appends to the list path with its flags.
    var acc = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    acc.reserve(8)
    decode_stripe_column(
        acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0,
        _one(ORC_STREAM_DATA, _rlev2_direct(_i64s(10, -20, 30), 8, True)), 3,
    )
    assert_true(acc.i64_buf_active)
    var s2 = _two(
        ORC_STREAM_PRESENT, _present("vnv"),
        ORC_STREAM_DATA, _rlev2_direct(_i64s(40, -50), 8, True),
    )
    decode_stripe_column(acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0, s2, 3)
    assert_false(acc.i64_buf_active)
    var s3 = _two(
        ORC_STREAM_PRESENT, _present("vv"),
        ORC_STREAM_DATA, _rlev2_direct(_i64s(60, 70), 8, True),
    )
    decode_stripe_column(acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0, s3, 2)
    assert_equal(len(acc.present), 8)
    var col = acc^.build()
    assert_equal(_nulls(8, col), "vvvvnvvv")
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 10)
    assert_equal(Int(arr.get(1)), -20)
    assert_equal(Int(arr.get(2)), 30)
    assert_equal(Int(arr.get(3)), 40)
    assert_equal(Int(arr.get(5)), -50)
    assert_equal(Int(arr.get(7)), 70)


def test_long_present_all_valid_stays_zero_copy() raises:
    # A PRESENT stream with no null on a reserved BIGINT column decodes into
    # the zero-copy buffer at the running offset (stripe 2 after stripe 1).
    var acc = make_accumulator(ORC_KIND_LONG, ArrowType.INT64)
    acc.reserve(10)
    for _s in range(2):
        var streams = _two(
            ORC_STREAM_PRESENT, _present("vvvvv"),
            ORC_STREAM_DATA, _spec_rlev2_short_repeat(),
        )
        decode_stripe_column(
            acc, ORC_KIND_LONG, ORC_ENCODING_DIRECT_V2, 0, streams, 5
        )
    assert_true(acc.i64_buf_active)
    var col = acc^.build()
    assert_equal(col.length(), 10)
    assert_equal(col.null_count(), 0)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 5000)
    assert_equal(Int(arr.get(9)), 5000)


def test_int_nullable_then_present_all_valid() raises:
    # INT (list path): "nv" then a PRESENT stream with no null; the second
    # stripe's rows are valid and `present` keeps their flags.
    var acc = make_accumulator(ORC_KIND_INT, ArrowType.INT32)
    var s1 = _two(
        ORC_STREAM_PRESENT, _present("nv"),
        ORC_STREAM_DATA, _rlev2_direct(_i64s(-3), 4, True),
    )
    decode_stripe_column(acc, ORC_KIND_INT, ORC_ENCODING_DIRECT_V2, 0, s1, 2)
    var s2 = _two(
        ORC_STREAM_PRESENT, _present("vvvvv"),
        ORC_STREAM_DATA, _spec_rlev2_short_repeat(),
    )
    decode_stripe_column(acc, ORC_KIND_INT, ORC_ENCODING_DIRECT_V2, 0, s2, 5)
    assert_equal(len(acc.present), 7)
    var col = acc^.build()
    assert_equal(_nulls(7, col), "nvvvvvv")
    var arr = col.as_primitive[DType.int32]()
    assert_equal(Int(arr.get(1)), -3)
    assert_equal(Int(arr.get(6)), 5000)


def test_int_present_all_valid_first() raises:
    var acc = make_accumulator(ORC_KIND_SHORT, ArrowType.INT16)
    var streams = _two(
        ORC_STREAM_PRESENT, _present("vvvvv"),
        ORC_STREAM_DATA, _spec_rlev2_short_repeat(),
    )
    decode_stripe_column(acc, ORC_KIND_SHORT, ORC_ENCODING_DIRECT_V2, 0, streams, 5)
    assert_equal(len(acc.present), 0)
    var col = acc^.build()
    assert_equal(col.null_count(), 0)
    assert_equal(Int(col.as_primitive[DType.int16]().get(4)), 5000)


def test_present_all_valid_on_fresh_column() raises:
    # A PRESENT stream with no null, nothing null before it: BOOLEAN, TINYINT
    # and DOUBLE keep no flags (`n_present == n`, `track_present` false) and
    # build with no validity.
    var b = make_accumulator(ORC_KIND_BOOLEAN, ArrowType.BOOL)
    decode_stripe_column(
        b, ORC_KIND_BOOLEAN, ORC_ENCODING_DIRECT_V2, 0,
        _two(ORC_STREAM_PRESENT, _present("vvv"), ORC_STREAM_DATA, _spec_bool_one_true()), 3,
    )
    assert_equal(len(b.present), 0)
    var bc = b^.build()
    assert_equal(bc.null_count(), 0)
    assert_true(bc.as_boolean().get(0))
    assert_false(bc.as_boolean().get(1))
    var t = make_accumulator(ORC_KIND_BYTE, ArrowType.INT8)
    decode_stripe_column(
        t, ORC_KIND_BYTE, ORC_ENCODING_DIRECT_V2, 0,
        _two(ORC_STREAM_PRESENT, _present("vv"), ORC_STREAM_DATA, _spec_byte_rle_44_45()), 2,
    )
    assert_equal(len(t.present), 0)
    var tc = t^.build()
    assert_equal(tc.null_count(), 0)
    assert_equal(Int(tc.as_primitive[DType.int8]().get(1)), 0x45)
    var d = make_accumulator(ORC_KIND_DOUBLE, ArrowType.FLOAT64)
    decode_stripe_column(
        d, ORC_KIND_DOUBLE, ORC_ENCODING_DIRECT, 0,
        _two(ORC_STREAM_PRESENT, _present("vv"), ORC_STREAM_DATA, _f64_le(Float64(1.25), Float64(-3.5))), 2,
    )
    assert_equal(len(d.present), 0)
    var dc = d^.build()
    assert_equal(dc.null_count(), 0)
    assert_equal(dc.as_primitive[DType.float64]().get(1), Float64(-3.5))


def test_boolean_and_short_no_present() raises:
    # No PRESENT stream: BOOLEAN from the spec's [0xff, 0x80] (true, then
    # seven false) and SHORT from the spec's Direct example read signed.
    var b = make_accumulator(ORC_KIND_BOOLEAN, ArrowType.BOOL)
    decode_stripe_column(
        b, ORC_KIND_BOOLEAN, ORC_ENCODING_DIRECT_V2, 0,
        _one(ORC_STREAM_DATA, _spec_bool_one_true()), 8,
    )
    var bc = b^.build()
    assert_equal(bc.length(), 8)
    assert_equal(bc.null_count(), 0)
    var ba = bc.as_boolean()
    assert_true(ba.get(0))
    for i in range(1, 8):
        assert_false(ba.get(i))
    var s = make_accumulator(ORC_KIND_SHORT, ArrowType.INT16)
    decode_stripe_column(
        s, ORC_KIND_SHORT, ORC_ENCODING_DIRECT_V2, 0,
        _one(ORC_STREAM_DATA, _spec_rlev2_direct()), 4,
    )
    var sa = s^.build().as_primitive[DType.int16]()
    assert_equal(Int(sa.get(0)), -11857)
    assert_equal(Int(sa.get(3)), -24440)


def test_decode_present_without_stream_is_all_valid() raises:
    # `_decode_present` (also the nested decoder's entry): no PRESENT stream
    # means every row present; with one, its flags.
    var none = _decode_present(List[StreamSpan](), 3)
    assert_equal(len(none), 3)
    assert_true(none[0] and none[1] and none[2])
    var some = _decode_present(_one(ORC_STREAM_PRESENT, _present("vnv")), 3)
    assert_true(some[0])
    assert_false(some[1])
    assert_true(some[2])



def test_varchar_no_present_and_date_nullable() raises:
    # The middle operands of the kind `or` chains: VARCHAR with no PRESENT
    # stream (string DIRECT, LENGTH the spec's RLEv1 literals [2, 3, 6, 7,
    # 11]) and DATE with nulls (its days read signed from the same bytes).
    var v = make_accumulator(ORC_KIND_VARCHAR, ArrowType.STRING)
    decode_stripe_column(
        v, ORC_KIND_VARCHAR, ORC_ENCODING_DIRECT, 0,
        _two(
            ORC_STREAM_DATA, _text("abcdefghijklmnopqrstuvwxyz012"),
            ORC_STREAM_LENGTH, _spec_rlev1_literals(),
        ),
        5,
    )
    var va = v^.build().as_string()
    assert_equal(va.get(0), "ab")
    assert_equal(va.get(4), "stuvwxyz012")
    var d = make_accumulator(ORC_KIND_DATE, ArrowType.DATE32)
    decode_stripe_column(
        d, ORC_KIND_DATE, ORC_ENCODING_DIRECT, 0,
        _two(ORC_STREAM_PRESENT, _present("nvvvvv"), ORC_STREAM_DATA, _spec_rlev1_literals()),
        6,
    )
    var dc = d^.build()
    assert_equal(dc.arrow_type.type_id, ArrowType.DATE32.type_id)
    assert_equal(_nulls(6, dc), "nvvvvv")
    var da = dc.as_primitive[DType.int32]()
    assert_equal(Int(da.get(1)), 1)
    assert_equal(Int(da.get(5)), -6)


def main() raises:
    test_reserve_refuses_bad_row_counts()
    test_reserve_long_zero_keeps_list_path()
    test_reserve_binary_then_decode()
    test_unknown_tag_reserves_nothing_and_build_raises()
    test_make_accumulator_maps_every_kind()
    test_decode_refuses_unsupported_kind_on_both_paths()
    test_boolean_nullable()
    test_tinyint_nullable_sign_extends()
    test_tinyint_no_present_sign_extends()
    test_short_nullable_spec_direct()
    test_int_v1_nullable_spec_literals()
    test_int_v1_no_present()
    test_float_nullable_and_all_present()
    test_float_present_all_valid_first()
    test_double_nullable_and_all_present()
    test_string_direct_v1_nullable()
    test_binary_nullable_across_stripes()
    test_binary_present_all_valid()
    test_dictionary_v2_nullable()
    test_dictionary_v1_both_paths()
    test_long_zero_copy_then_nullable_migrates()
    test_long_present_all_valid_stays_zero_copy()
    test_int_nullable_then_present_all_valid()
    test_int_present_all_valid_first()
    test_present_all_valid_on_fresh_column()
    test_boolean_and_short_no_present()
    test_decode_present_without_stream_is_all_valid()
    test_varchar_no_present_and_date_nullable()
    print("test_orc_column_decoder_nullable: ALL PASS")
