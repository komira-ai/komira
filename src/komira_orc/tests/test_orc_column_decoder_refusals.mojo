# =============================================================================
# test_orc_column_decoder_refusals.mojo: every refusal of column_decoder.mojo.
# =============================================================================
#
# A stream the encoding requires is absent; float data is short; LENGTH
# values overrun DATA, are negative, or overrun the dictionary; DICTIONARY_DATA
# passes the Int32 offset limit; a dictionary index is out of range; a fill
# is longer than its column. Each refusal is reached on every path that has
# one (no PRESENT stream, a PRESENT stream with no null, one with nulls), and
# where a refusal is a bound, the value at the bound is accepted beside it.
#
# Fixture bytes come from the Apache ORC v1 specification's worked examples
# where one fits (orc.apache.org/specification/ORCv1/, "Run Length
# Encoding"); each such fixture names its example. The rest are built with
# the encoders below, which follow the same sections of the spec.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray

from komira_orc import (
    StreamSpan,
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
)
from komira_orc.column_decoder import _apply_present_nulls


# -----------------------------------------------------------------------------
# Fixtures from the spec's worked examples.
# -----------------------------------------------------------------------------


def _bytes(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


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


def _rlev2_two_u64_sign_bit_first() -> List[UInt8]:
    """RLEv2 Direct, two unsigned values at width 64: header 0x7e 0x01, then
    0x8000000000000000 (negative as an Int64) and 1, big-endian. The negative
    value is NOT the last one, so a guard that looks only at the last value
    (an overwrite instead of an OR into the accumulator) accepts it."""
    return _bytes(
        0x7E, 0x01, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    )


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




# =============================================================================
# 4. Refusals: a stream the encoding requires is absent.
# =============================================================================


def _expect_missing(
    kind: Int, encoding: Int, var streams: List[StreamSpan], n: Int, msg: String
) raises:
    var acc = make_accumulator(kind, ArrowType.INT64)
    with assert_raises(contains=msg):
        decode_stripe_column(acc, kind, encoding, 2, streams, n)


def test_missing_data_no_present() raises:
    var e = ORC_ENCODING_DIRECT_V2
    var len_only = ORC_STREAM_LENGTH
    _expect_missing(ORC_KIND_BOOLEAN, e, List[StreamSpan](), 1, "BOOLEAN has no DATA")
    _expect_missing(ORC_KIND_BYTE, e, List[StreamSpan](), 1, "TINYINT has no DATA")
    _expect_missing(ORC_KIND_INT, e, List[StreamSpan](), 1, "integer column has no DATA")
    _expect_missing(ORC_KIND_FLOAT, e, List[StreamSpan](), 1, "FLOAT has no DATA")
    _expect_missing(ORC_KIND_DOUBLE, e, List[StreamSpan](), 1, "DOUBLE has no DATA")
    _expect_missing(
        ORC_KIND_STRING, e, _one(len_only, _bytes(0x00, 0x01)), 1,
        "STRING has no DATA",
    )
    _expect_missing(
        ORC_KIND_BINARY, e, _one(len_only, _bytes(0x00, 0x01)), 1,
        "BINARY has no DATA",
    )
    _expect_missing(
        ORC_KIND_STRING, e, _one(ORC_STREAM_DATA, _bytes(0x41)), 1,
        "MISSING_LENGTH: column has no LENGTH stream",
    )


def test_missing_data_nullable() raises:
    var e = ORC_ENCODING_DIRECT_V2
    _expect_missing(ORC_KIND_BOOLEAN, e, _one(ORC_STREAM_PRESENT, _present("vn")), 2, "BOOLEAN has no DATA")
    _expect_missing(ORC_KIND_BYTE, e, _one(ORC_STREAM_PRESENT, _present("vn")), 2, "TINYINT has no DATA")
    _expect_missing(ORC_KIND_LONG, e, _one(ORC_STREAM_PRESENT, _present("vn")), 2, "integer column has no DATA")
    _expect_missing(ORC_KIND_FLOAT, e, _one(ORC_STREAM_PRESENT, _present("vn")), 2, "FLOAT has no DATA")
    _expect_missing(ORC_KIND_DOUBLE, e, _one(ORC_STREAM_PRESENT, _present("vn")), 2, "DOUBLE has no DATA")
    _expect_missing(
        ORC_KIND_STRING, e,
        _two(ORC_STREAM_PRESENT, _present("vn"), ORC_STREAM_LENGTH, _bytes(0, 0)),
        2, "STRING has no DATA",
    )
    _expect_missing(
        ORC_KIND_BINARY, e,
        _two(ORC_STREAM_PRESENT, _present("vn"), ORC_STREAM_LENGTH, _bytes(0, 0)),
        2, "BINARY has no DATA",
    )


def test_missing_dictionary_streams_both_paths() raises:
    # Each of the three dictionary streams removed in turn, with and without
    # a PRESENT stream: each refusal names the stream that is missing.
    for p in range(2):
        var pres = "vv" if p == 1 else ""
        for drop in range(3):
            var full = _dict_streams(
                pres, _rlev2_direct(_i64s(0, 1), 1, False), True
            )
            var kinds = List[Int]()
            kinds.append(ORC_STREAM_DICTIONARY_DATA)
            kinds.append(ORC_STREAM_LENGTH)
            kinds.append(ORC_STREAM_DATA)
            var kept = List[StreamSpan]()
            for i in range(len(full)):
                if full[i].kind != kinds[drop]:
                    kept.append(full[i].copy())
            var msg: String
            if drop == 0:
                msg = "MISSING_DICTIONARY_DATA: DICTIONARY STRING column"
            elif drop == 1:
                msg = "MISSING_LENGTH: DICTIONARY column LENGTH"
            else:
                msg = "MISSING_DATA: DICTIONARY column DATA"
            _expect_missing(
                ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2, kept^, 2, msg
            )


# =============================================================================
# 5. Refusals: lengths and values that do not fit their streams.
# =============================================================================


def test_float_double_truncated_every_arm() raises:
    # One byte short of the declared values, on the no-PRESENT path, the
    # PRESENT-with-no-null arm and the per-row null arm. Exactly enough bytes
    # is accepted here on the no-PRESENT arm; the float tests of
    # test_orc_column_decoder_nullable.mojo decode exact-length data on the
    # other two.
    var e = ORC_ENCODING_DIRECT
    for arm in range(3):
        var pres = "" if arm == 0 else ("vv" if arm == 1 else "vnv")
        var f = _f32_le(Float32(1), Float32(2))
        _ = f.pop()
        var d = _f64_le(Float64(1), Float64(2))
        _ = d.pop()
        var fs = List[StreamSpan]()
        var ds = List[StreamSpan]()
        if pres != "":
            fs.append(StreamSpan(ORC_STREAM_PRESENT, _present(pres)))
            ds.append(StreamSpan(ORC_STREAM_PRESENT, _present(pres)))
        fs.append(StreamSpan(ORC_STREAM_DATA, f^))
        ds.append(StreamSpan(ORC_STREAM_DATA, d^))
        var rows = 3 if arm == 2 else 2
        _expect_missing(ORC_KIND_FLOAT, e, fs^, rows, "TRUNCATED: FLOAT data overrun")
        _expect_missing(ORC_KIND_DOUBLE, e, ds^, rows, "TRUNCATED: DOUBLE data overrun")
    var exact = make_accumulator(ORC_KIND_DOUBLE, ArrowType.FLOAT64)
    decode_stripe_column(
        exact, ORC_KIND_DOUBLE, e, 0,
        _one(ORC_STREAM_DATA, _f64_le(Float64(7), Float64(8))), 2,
    )
    var exact32 = make_accumulator(ORC_KIND_FLOAT, ArrowType.FLOAT32)
    decode_stripe_column(
        exact32, ORC_KIND_FLOAT, e, 0,
        _one(ORC_STREAM_DATA, _f32_le(Float32(7), Float32(8))), 2,
    )
    assert_equal(exact^.build().as_primitive[DType.float64]().get(1), Float64(8))
    assert_equal(exact32^.build().as_primitive[DType.float32]().get(1), Float32(8))


def test_lengths_overrun_data_spec_delta() raises:
    # LENGTH is the spec's Delta example (10 lengths summing to 129) against
    # 128 data bytes: the last value runs one byte past. Each STRING/BINARY
    # arm refuses; the no-PRESENT STRING arm names the value it stopped at.
    var data = List[UInt8]()
    for i in range(128):
        data.append(UInt8(0x41 + i % 26))
    var e = ORC_ENCODING_DIRECT_V2
    for kind in [ORC_KIND_STRING, ORC_KIND_BINARY]:
        for p in range(2):
            var streams = List[StreamSpan]()
            if p == 1:
                streams.append(StreamSpan(ORC_STREAM_PRESENT, _present("vvvvvvvvvv")))
            streams.append(StreamSpan(ORC_STREAM_DATA, data.copy()))
            streams.append(StreamSpan(ORC_STREAM_LENGTH, _spec_rlev2_delta()))
            var msg: String
            if kind == ORC_KIND_BINARY:
                msg = "TRUNCATED: BINARY data overrun"
            elif p == 1:
                msg = "TRUNCATED: STRING data overrun"
            else:
                msg = "lengths sum to more than the 128 bytes in the DATA stream (at value 9)"
            _expect_missing(kind, e, streams^, 10, msg)
    # 129 bytes is exactly enough: the last value is "29 bytes", accepted.
    data.append(UInt8(0x5A))
    var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
    decode_stripe_column(
        acc, ORC_KIND_STRING, e, 0,
        _two(ORC_STREAM_DATA, data^, ORC_STREAM_LENGTH, _spec_rlev2_delta()), 10,
    )
    var arr = acc^.build().as_string()
    assert_equal(arr.get_length(0), 2)
    assert_equal(arr.get_length(9), 29)


def test_negative_length_refused() raises:
    # An unsigned width-64 LENGTH value with the sign bit set: refused by
    # `_check_lengths_non_negative` on every LENGTH decoder (direct STRING,
    # BINARY, and the dictionary's own LENGTH decode).
    var e = ORC_ENCODING_DIRECT_V2
    for kind in [ORC_KIND_STRING, ORC_KIND_BINARY]:
        _expect_missing(
            kind, e,
            _two(ORC_STREAM_DATA, _bytes(0x41), ORC_STREAM_LENGTH, _rlev2_one_u64_sign_bit()),
            1, "NEGATIVE_LENGTH",
        )
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DICTIONARY_DATA, _text("x")))
    streams.append(StreamSpan(ORC_STREAM_LENGTH, _rlev2_one_u64_sign_bit()))
    streams.append(StreamSpan(ORC_STREAM_DATA, _rlev2_direct(_i64s(0), 1, False)))
    var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
    with assert_raises(contains="NEGATIVE_LENGTH"):
        decode_stripe_column(
            acc, ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2, 1, streams, 1
        )


comptime _NEG_LEN_MSG = (
    "OrcDecodeError.NEGATIVE_LENGTH: the LENGTH stream decoded a negative"
    " value length (an unsigned RLE run wide enough to set the Int64 sign"
    " bit); a byte length cannot be negative"
)


def test_negative_length_before_valid_one_refused() raises:
    # LENGTH [-2^63, 1]: the negative value comes first and a valid one
    # follows. Kills `sign_acc |= lens[i]` -> `sign_acc = lens[i]` in
    # `_check_lengths_non_negative` (only the last value would be checked;
    # the one-value stream above cannot tell them apart). The direct LENGTH
    # decoders, STRING and BINARY, on the no-PRESENT and the PRESENT path.
    var e = ORC_ENCODING_DIRECT_V2
    for p in range(2):
        for kind in [ORC_KIND_STRING, ORC_KIND_BINARY]:
            var streams = List[StreamSpan]()
            if p == 1:
                streams.append(StreamSpan(ORC_STREAM_PRESENT, _present("vv")))
            streams.append(StreamSpan(ORC_STREAM_DATA, _bytes(0x41)))
            streams.append(
                StreamSpan(ORC_STREAM_LENGTH, _rlev2_two_u64_sign_bit_first())
            )
            _expect_missing(kind, e, streams^, 2, _NEG_LEN_MSG)


def test_dict_negative_length_before_valid_one_refused() raises:
    # The same LENGTH [-2^63, 1] through the dictionary's own LENGTH decode,
    # on the no-PRESENT and the PRESENT path. Its own test, run before the
    # direct one in `main`, so the `sign_acc` mutant above fails here first
    # and the failure names the dictionary path.
    for p in range(2):
        var d = List[StreamSpan]()
        if p == 1:
            d.append(StreamSpan(ORC_STREAM_PRESENT, _present("v")))
        d.append(StreamSpan(ORC_STREAM_DICTIONARY_DATA, _text("x")))
        d.append(StreamSpan(ORC_STREAM_LENGTH, _rlev2_two_u64_sign_bit_first()))
        d.append(StreamSpan(ORC_STREAM_DATA, _rlev2_direct(_i64s(0), 1, False)))
        var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
        with assert_raises(contains=_NEG_LEN_MSG):
            decode_stripe_column(
                acc, ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2, 2, d, 1
            )


def test_dictionary_length_overrun() raises:
    # LENGTH [4, 4] against the 7 bytes of "bluered": the second entry
    # ends one byte past the dictionary.
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DICTIONARY_DATA, _text("bluered")))
    streams.append(StreamSpan(ORC_STREAM_LENGTH, _rlev2_direct(_i64s(4, 4), 4, False)))
    streams.append(StreamSpan(ORC_STREAM_DATA, _rlev2_direct(_i64s(0), 1, False)))
    var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
    with assert_raises(contains="DICT_LENGTH_OVERRUN: entry past dict"):
        decode_stripe_column(
            acc, ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2, 2, streams, 1
        )


def test_dictionary_data_over_int32_offsets() raises:
    # DICTIONARY_DATA of 2^31 bytes (one past the Int32 offset limit) with an
    # empty dictionary: refused before any byte of it is read. The buffer is
    # never written, so it costs address space, not resident memory.
    var big = List[UInt8](capacity=2147483648)
    big.resize(unsafe_uninit_length=2147483648)
    var streams = List[StreamSpan]()
    streams.append(StreamSpan(ORC_STREAM_DICTIONARY_DATA, big^))
    streams.append(StreamSpan(ORC_STREAM_LENGTH, List[UInt8]()))
    streams.append(StreamSpan(ORC_STREAM_DATA, List[UInt8]()))
    var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
    with assert_raises(contains="DICT_DATA_TOO_LARGE: DICTIONARY_DATA holds 2147483648 bytes"):
        decode_stripe_column(
            acc, ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2, 0, streams, 0
        )


def test_dictionary_index_out_of_range() raises:
    # Two entries: index 2 (one past the end) and an index with the sign bit
    # set (negative as Int64) are refused on both paths; index 1 (the last)
    # is accepted.
    for p in range(2):
        var pres = "v" if p == 1 else ""
        _expect_missing(
            ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2,
            _dict_streams(pres, _rlev2_direct(_i64s(2), 2, False), True),
            1, "DICT_INDEX_OOB: index 2 out of range [0, 2)",
        )
        _expect_missing(
            ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2,
            _dict_streams(pres, _rlev2_one_u64_sign_bit(), True),
            1, "DICT_INDEX_OOB: index -9223372036854775808 out of range",
        )
        var acc = make_accumulator(ORC_KIND_STRING, ArrowType.STRING)
        decode_stripe_column(
            acc, ORC_KIND_STRING, ORC_ENCODING_DICTIONARY_V2, 2,
            _dict_streams(pres, _rlev2_direct(_i64s(1), 1, False), True), 1,
        )
        assert_equal(acc^.build().as_string().get(0), "red")


# =============================================================================
# 6. The write boundary: a fill longer than its column.
# =============================================================================


def test_bulk_fill_longer_than_column_refused() raises:
    # `len(i64s)` / `len(f64s)` one past `n_rows`: the build refuses rather
    # than store past the Arrow buffer. Equal lengths build (every other test).
    var ints = make_accumulator(ORC_KIND_SHORT, ArrowType.INT16)
    ints.i64s.append(Int64(1))
    ints.i64s.append(Int64(2))
    ints.n_rows = 1
    with assert_raises(contains="DESTINATION_OVERRUN: integer column bulk-fill has 2 decoded values but the column was allocated for 1 rows"):
        _ = ints^.build()
    var floats = make_accumulator(ORC_KIND_DOUBLE, ArrowType.FLOAT64)
    floats.f64s.append(Float64(1))
    floats.f64s.append(Float64(2))
    floats.n_rows = 1
    with assert_raises(contains="DESTINATION_OVERRUN: float column bulk-fill has 2"):
        _ = floats^.build()


def test_apply_present_nulls_zero_count_is_noop() raises:
    # With nc == 0 the flags are not read: a False flag marks nothing.
    var arr = PrimitiveArray[DType.int32].allocate_nullable(2)
    var flags = _flags("nv")
    _apply_present_nulls[DType.int32](arr, flags, 0)
    assert_false(arr.is_null(0))
    assert_equal(arr.null_count, 0)
    _apply_present_nulls[DType.int32](arr, flags, 1)
    assert_true(arr.is_null(0))
    assert_false(arr.is_null(1))
    assert_equal(arr.null_count, 1)


def main() raises:
    test_missing_data_no_present()
    test_missing_data_nullable()
    test_missing_dictionary_streams_both_paths()
    test_float_double_truncated_every_arm()
    test_lengths_overrun_data_spec_delta()
    test_negative_length_refused()
    test_dict_negative_length_before_valid_one_refused()
    test_negative_length_before_valid_one_refused()
    test_dictionary_length_overrun()
    test_dictionary_data_over_int32_offsets()
    test_dictionary_index_out_of_range()
    test_bulk_fill_longer_than_column_refused()
    test_apply_present_nulls_zero_count_is_noop()
    print("test_orc_column_decoder_refusals: ALL PASS")
