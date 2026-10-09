# Direct tests of `plain_flba.mojo`: the PLAIN FIXED_LEN_BYTE_ARRAY decode to
# a BinaryArray, and the DECIMAL decode to Float64 at the two SIMD widths (16
# and 8 bytes) and the scalar widths. Expected values come from the format: an
# FLBA(N) page is N bytes per value back to back, and a DECIMAL value is the
# big-endian two's-complement integer divided by 10^scale.
from std.sys import simd_width_of
from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet.plain_flba import (
    _flba_value_to_int64_be,
    decode_plain_fixed_len_byte_array,
    decode_plain_flba_decimal_to_float64,
)


def _be(v: Int64, width: Int) -> List[UInt8]:
    """`v` as `width` big-endian two's-complement bytes (sign-extended above
    8 bytes)."""
    var out = List[UInt8](length=width, fill=0)
    var u = UInt64(v)
    for i in range(width):
        if i < 8:
            out[width - 1 - i] = UInt8((u >> UInt64(8 * i)) & 0xFF)
        else:
            out[width - 1 - i] = UInt8(0xFF) if v < 0 else UInt8(0)
    return out^


def _page(values: List[Int64], width: Int) -> List[UInt8]:
    var page = List[UInt8]()
    for i in range(len(values)):
        var b = _be(values[i], width)
        for k in range(width):
            page.append(b[k])
    return page^


def _values(n: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        var mag = Int64(i * 7919 + i * i)
        out.append(mag if i % 2 == 0 else -mag - 1)
    return out^


# --- FLBA to BinaryArray -----------------------------------------------------


def test_flba_round_trips_at_counts_around_the_simd_width() raises:
    comptime W = simd_width_of[DType.int32]()
    var counts: List[Int] = [1, W - 1, W, W + 1, 2 * W + 3, 37]
    for ci in range(len(counts)):
        var n = counts[ci]
        for width in range(1, 6):
            var page = List[UInt8]()
            for i in range(n * width):
                page.append(UInt8((i * 13 + width) & 0xFF))
            var arr = decode_plain_fixed_len_byte_array(Span(page), n, width)
            assert_equal(arr.length, n)
            assert_equal(arr.data_length, n * width)
            for v in range(n):
                assert_equal(arr.get_length(v), width)
                var got = arr.get(v)
                for k in range(width):
                    assert_equal(got[k], page[v * width + k])


def test_flba_empty_and_zero_width() raises:
    var page = List[UInt8](length=4, fill=0)
    assert_equal(decode_plain_fixed_len_byte_array(Span(page), 0, 4).length, 0)
    # Pinned, not fixed here: a zero-width column decodes to an empty array,
    # whatever the count (the format has no zero-width FLBA).
    assert_equal(decode_plain_fixed_len_byte_array(Span(page), 3, 0).length, 0)


def test_flba_refusals() raises:
    var page = List[UInt8](length=10, fill=0)
    var cases: List[Tuple[Int, Int, String]] = [
        (
            1,
            -1,
            "parquet: corrupt FIXED_LEN_BYTE_ARRAY column: negative type_length -1",
        ),
        (
            3,
            4,
            "parquet: corrupt PLAIN FLBA page: declares 3 values (12 bytes at 4"
            " bytes/value) but the page body holds only 10 bytes",
        ),
        (1 << 62, 8, "parquet: corrupt PLAIN FLBA page: declares "),
    ]
    for i in range(len(cases)):
        var msg = String("")
        try:
            _ = decode_plain_fixed_len_byte_array(
                Span(page), cases[i][0], cases[i][1]
            )
        except e:
            msg = String(e)
        assert_true(msg.startswith(cases[i][2]), msg)


def test_flba_refuses_values_past_the_int32_offsets() raises:
    # One value of 2^31 bytes over a Span that claims them: the offsets would
    # wrap. Refused before any byte is read or allocated.
    var page = List[UInt8](length=8, fill=0)
    var fake = Span[UInt8, origin_of(page)](
        unsafe_ptr=page.unsafe_ptr(), length=1 << 31
    )
    var msg = String("")
    try:
        _ = decode_plain_fixed_len_byte_array(fake, 1, 1 << 31)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "parquet: PLAIN FLBA page of 1 values of 2147483648 bytes is past the"
        " 2147483647 bytes Int32 offsets can address",
    )


# --- DECIMAL to Float64 -------------------------------------------------------------


def _expect(v: Int64, scale: Int) -> Float64:
    var d = Float64(1.0)
    for _ in range(scale):
        d = d * Float64(10.0)
    return Float64(v) * (Float64(1.0) / d)


def test_decimal_to_float64_every_width_path() raises:
    comptime W = simd_width_of[DType.float64]()
    var counts: List[Int] = [1, W, W + 1, 3 * W + 2]
    # 16 and 8 take the SIMD paths, the others the scalar loop; widths below
    # 8 sign-extend, widths above 8 read the low 8 bytes.
    var widths: List[Int] = [16, 8, 1, 3, 4, 7, 12]
    for wi in range(len(widths)):
        var width = widths[wi]
        for ci in range(len(counts)):
            var n = counts[ci]
            var vals = _values(n)
            if width < 8:
                var lim = Int64(1) << Int64(8 * width - 1)
                for i in range(n):
                    vals[i] = vals[i] % (2 * lim) - lim  # in [-lim, lim)
            var page = _page(vals, width)
            for scale in range(0, 4):
                var arr = decode_plain_flba_decimal_to_float64(
                    Span(page), n, width, scale
                )
                assert_equal(arr.length, n)
                for i in range(n):
                    assert_equal(
                        arr.get(i).to_bits(), _expect(vals[i], scale).to_bits()
                    )


def test_decimal_to_float64_refusals() raises:
    var page = List[UInt8](length=10, fill=0)
    assert_equal(
        decode_plain_flba_decimal_to_float64(Span(page), 0, 16, 2).length, 0
    )
    var cases: List[Tuple[Int, Int, String]] = [
        (
            1,
            -2,
            "parquet: corrupt FLBA DECIMAL column: non-positive type_length -2",
        ),
        # A zero width reads nothing, so no page bounds the count, and the
        # output is `num_values * 8` bytes: refused rather than decoded to
        # zeros.
        (
            5,
            0,
            "parquet: corrupt FLBA DECIMAL column: non-positive type_length 0",
        ),
        (
            2,
            8,
            "parquet: corrupt PLAIN FLBA DECIMAL page: declares 2 values (16"
            " bytes at 8 bytes/value) but the page body holds only 10 bytes",
        ),
    ]
    for i in range(len(cases)):
        var msg = String("")
        try:
            _ = decode_plain_flba_decimal_to_float64(
                Span(page), cases[i][0], cases[i][1], 2
            )
        except e:
            msg = String(e)
        assert_equal(msg, cases[i][2])


def test_value_to_int64_width_zero_and_sign() raises:
    var neg: List[UInt8] = [UInt8(0xFF), UInt8(0x7F)]
    var pos: List[UInt8] = [UInt8(0x7F), UInt8(0xFF)]
    assert_equal(_flba_value_to_int64_be(neg.unsafe_ptr(), 0), Int64(0))
    assert_equal(_flba_value_to_int64_be(neg.unsafe_ptr(), -1), Int64(0))
    assert_equal(_flba_value_to_int64_be(neg.unsafe_ptr(), 2), Int64(-129))
    assert_equal(_flba_value_to_int64_be(pos.unsafe_ptr(), 2), Int64(0x7FFF))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
