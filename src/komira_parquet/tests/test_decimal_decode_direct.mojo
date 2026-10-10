# Direct tests of `decimal_decode.mojo`: DECIMAL values on FLBA, INT32 and
# INT64 decoded to Arrow Decimal128 (a 16-byte little-endian two's-complement
# integer per value). Expected values come from the format: an FLBA DECIMAL
# is the big-endian two's-complement unscaled integer; INT32 and INT64
# DECIMALs are the little-endian integer. The precision a backing width can
# hold is floor(log10(2^(8n-1) - 1)).
from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet.decimal_decode import (
    _flba_bytes_to_i128,
    _max_precision_for_byte_width,
    decode_int32_buf_to_decimal128,
    decode_int64_buf_to_decimal128,
    decode_plain_flba_decimal_to_i128,
    sign_extend_int_to_i128,
)

comptime _I128 = SIMD[DType.int128, 1]


def _be(v: _I128, width: Int) -> List[UInt8]:
    """`v` as `width` big-endian two's-complement bytes (sign-extended above
    16 bytes)."""
    var out = List[UInt8](length=width, fill=0)
    for i in range(width):
        var byte: UInt8
        if i < 16:
            byte = UInt8(Int((v >> _I128(8 * i)) & _I128(0xFF)))
        else:
            byte = UInt8(0xFF) if v < _I128(0) else UInt8(0)
        out[width - 1 - i] = byte
    return out^


def _le(v: Int64, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var u = UInt64(v)
    for k in range(width):
        out.append(UInt8((u >> UInt64(8 * k)) & 0xFF))
    return out^


def test_max_precision_of_every_backing_width() raises:
    var expect: List[Int] = [
        2, 2, 4, 6, 9, 11, 14, 16, 18, 28, 28, 28, 28, 38, 38, 38, 38,
    ]
    for n in range(len(expect)):
        assert_equal(_max_precision_for_byte_width(n), expect[n], "width " + String(n))


def test_flba_round_trips_at_every_width() raises:
    # Widths 1..16 sign-extend from the top bit of the first byte; 17 and 20
    # carry sign-extension bytes above the low 16.
    for width in range(1, 21):
        var vals = List[_I128]()
        var bits = min(width, 16) * 8
        var top = _I128(1) << _I128(bits - 1)
        vals.append(_I128(0))
        vals.append(top - _I128(1))  # the largest value the width holds
        vals.append(-top)  # the smallest
        vals.append(_I128(-1))
        vals.append(_I128(5) if width > 1 else _I128(-5))
        var page = List[UInt8]()
        for i in range(len(vals)):
            var b = _be(vals[i], width)
            for k in range(width):
                page.append(b[k])
        var arr = decode_plain_flba_decimal_to_i128(
            Span(page), len(vals), width, 3
        )
        assert_equal(arr.length, len(vals))
        assert_equal(arr.scale, 3)
        assert_equal(arr.precision, _max_precision_for_byte_width(width))
        for i in range(len(vals)):
            assert_true(
                arr.get_i128(i) == vals[i],
                "width " + String(width) + " value " + String(i),
            )


def test_flba_declared_precision_and_refusals() raises:
    var page = _be(_I128(-42), 4)
    var arr = decode_plain_flba_decimal_to_i128(Span(page), 1, 4, 2, 7)
    assert_equal(arr.precision, 7)
    assert_true(arr.get_i128(0) == _I128(-42))
    var cases: List[Tuple[Int, Int, String]] = [
        (1, -1, "parquet: corrupt FLBA DECIMAL column: non-positive type_length -1"),
        # A zero width reads nothing, so no page bounds the count; the array
        # is `num_values * 16` bytes. Refused rather than decoded to zeros.
        (5, 0, "parquet: corrupt FLBA DECIMAL column: non-positive type_length 0"),
        (
            2,
            4,
            "parquet: corrupt PLAIN FLBA DECIMAL page: declares 2 values (8"
            " bytes at 4 bytes/value) but the page body holds only 4 bytes",
        ),
    ]
    for i in range(len(cases)):
        var msg = String("")
        try:
            _ = decode_plain_flba_decimal_to_i128(
                Span(page), cases[i][0], cases[i][1], 2
            )
        except e:
            msg = String(e)
        assert_equal(msg, cases[i][2])


def test_flba_bytes_helper_width_zero() raises:
    var b: List[UInt8] = [UInt8(0xFF)]
    assert_true(_flba_bytes_to_i128(b.unsafe_ptr(), 0) == _I128(0))
    assert_true(_flba_bytes_to_i128(b.unsafe_ptr(), -3) == _I128(0))


def test_int32_and_int64_buffers() raises:
    var v32: List[Int64] = [0, 1, -1, 2147483647, -2147483648, 123456]
    var p32 = List[UInt8]()
    for i in range(len(v32)):
        var b = _le(v32[i], 4)
        for k in range(4):
            p32.append(b[k])
    var a32 = decode_int32_buf_to_decimal128(Span(p32), len(v32), 2)
    assert_equal(a32.precision, 9)
    for i in range(len(v32)):
        assert_true(a32.get_i128(i) == _I128(v32[i]))
    var v64: List[Int64] = [0, -7, Int64.MAX, Int64.MIN, 9876543210]
    var p64 = List[UInt8]()
    for i in range(len(v64)):
        var b = _le(v64[i], 8)
        for k in range(8):
            p64.append(b[k])
    var a64 = decode_int64_buf_to_decimal128(Span(p64), len(v64), 4, 12)
    assert_equal(a64.precision, 12)
    assert_equal(a64.scale, 4)
    for i in range(len(v64)):
        assert_true(a64.get_i128(i) == _I128(v64[i]))
    assert_true(sign_extend_int_to_i128(Int64(-9)) == _I128(-9))


def test_int_buffers_refuse_short_pages() raises:
    var page = List[UInt8](length=7, fill=0)
    var msg32 = String("")
    try:
        _ = decode_int32_buf_to_decimal128(Span(page), 2, 0)
    except e:
        msg32 = String(e)
    assert_equal(
        msg32,
        "parquet: corrupt PLAIN DECIMAL INT32 page: declares 2 values (8 bytes"
        " at 4 bytes/value) but the page body holds only 7 bytes",
    )
    var msg64 = String("")
    try:
        _ = decode_int64_buf_to_decimal128(Span(page), 1, 0)
    except e:
        msg64 = String(e)
    assert_equal(
        msg64,
        "parquet: corrupt PLAIN DECIMAL INT64 page: declares 1 values (8 bytes"
        " at 8 bytes/value) but the page body holds only 7 bytes",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
