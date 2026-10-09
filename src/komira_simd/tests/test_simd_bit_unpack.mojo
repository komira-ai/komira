# =============================================================================
# Correctness tests for the shared width-generic MSB-first bit-unpack kernels
# in `komira_simd.bit_unpack`.
# =============================================================================
#
# Coverage:
#   1. Correctness: for every covered width (1, 2, 8, 16, 24, 32, 40, 48, 56,
#      64), the SIMD `simd_unpack_bits` output must be byte-identical to an
#      independent scalar MSB-first bit-cursor oracle on a deterministic
#      pseudo-random packed buffer. Counts chosen to exercise both the SIMD
#      body and the scalar tail (non-multiple-of-lane).
#   2. Edges: width 0 writes `count` zeros; an empty `count` writes nothing;
#      a source one byte short of the packed run, or a destination one slot
#      short of `count`, is refused (False) without writing; widths that no
#      kernel covers are refused.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_simd.bit_unpack import simd_unpack_bits


# =============================================================================
# Scalar MSB-first reference oracle (independent of the production module).
# =============================================================================


def _ref_unpack(
    src: Span[UInt8, _], bits: Int, count: Int, mut dst: List[Int64]
):
    """Scalar MSB-first bit-cursor unpack — the correctness oracle."""
    dst.resize(unsafe_uninit_length=count)
    var byte_i = 0
    var bits_left = 0
    var cur: UInt64 = 0
    for idx in range(count):
        var value: UInt64 = 0
        var need = bits
        while need > 0:
            if bits_left == 0:
                cur = UInt64(Int(src[byte_i]))
                byte_i += 1
                bits_left = 8
            var take = need if need < bits_left else bits_left
            var shift = bits_left - take
            var mask = (UInt64(1) << UInt64(take)) - 1
            var chunk = (cur >> UInt64(shift)) & mask
            value = (value << UInt64(take)) | chunk
            bits_left -= take
            need -= take
        dst[idx] = Int64(value)


def _make_packed(bits: Int, count: Int) -> List[UInt8]:
    """Deterministic pseudo-random packed MSB-first buffer of `count` values."""
    var n_bytes = (bits * count + 7) // 8 + 16  # +16 slack for SIMD overread
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=n_bytes)
    var s: UInt64 = 0x9E3779B97F4A7C15
    for i in range(n_bytes):
        s = s * 6364136223846793005 + 1442695040888963407
        buf[i] = UInt8((s >> 33) & 0xFF)
    return buf^


def _check_width(bits: Int, count: Int) raises:
    var packed = _make_packed(bits, count)
    var oracle = List[Int64]()
    _ref_unpack(Span(packed), bits, count, oracle)

    var got = List[Int64]()
    got.resize(unsafe_uninit_length=count)
    var dst_span = Span(got)
    var ok = simd_unpack_bits(Span(packed), bits, count, dst_span)
    assert_true(ok, "width " + String(bits) + " should be SIMD-covered")
    for i in range(count):
        assert_equal(
            got[i], oracle[i],
            "width " + String(bits) + " idx " + String(i) + " mismatch",
        )


# =============================================================================
# Correctness tests — body + tail for each covered width.
# =============================================================================


def test_width_1() raises:
    _check_width(1, 1000)
    _check_width(1, 1003)  # partial final byte


def test_width_2() raises:
    _check_width(2, 1000)
    _check_width(2, 999)


def test_width_8() raises:
    _check_width(8, 1000)
    _check_width(8, 1001)


def test_width_16() raises:
    _check_width(16, 1000)
    _check_width(16, 997)


def test_width_24() raises:
    _check_width(24, 1000)
    _check_width(24, 1001)
    _check_width(24, 3)  # tiny: scalar-only path


def test_width_32() raises:
    _check_width(32, 1000)
    _check_width(32, 995)


def test_width_40() raises:
    _check_width(40, 1000)
    _check_width(40, 1001)
    _check_width(40, 1)


def test_width_48() raises:
    _check_width(48, 1000)
    _check_width(48, 999)


def test_width_56() raises:
    _check_width(56, 1000)
    _check_width(56, 997)


def test_width_64() raises:
    _check_width(64, 1000)
    _check_width(64, 1001)


# =============================================================================
# Edges — width 0, empty count, short buffers, uncovered widths.
# =============================================================================


def test_width_0_writes_zeros() raises:
    var packed: List[UInt8] = [0xFF, 0xFF]
    var got = List[Int64](length=5, fill=Int64(-1))
    var dst_span = Span(got)
    assert_true(simd_unpack_bits(Span(packed), 0, 5, dst_span), "width 0")
    for i in range(5):
        assert_equal(got[i], Int64(0), "width 0 idx " + String(i))


def test_count_0_writes_nothing() raises:
    var packed: List[UInt8] = [0xFF]
    var got = List[Int64](length=1, fill=Int64(-1))
    var dst_span = Span(got)
    assert_true(simd_unpack_bits(Span(packed), 8, 0, dst_span), "count 0")
    assert_equal(got[0], Int64(-1), "count 0 wrote")


def test_short_source_refused() raises:
    """72 values of 1 bit need exactly 9 bytes: 9 is accepted, 8 is refused
    and nothing is written (the destination is long enough either way)."""
    var packed = _make_packed(8, 16)
    var got = List[Int64](length=72, fill=Int64(-1))
    var dst_span = Span(got)
    var exact = Span(packed)[0:9]
    var short = Span(packed)[0:8]
    assert_true(
        not simd_unpack_bits(short, 1, 72, dst_span), "8 bytes for 72 bits"
    )
    for i in range(72):
        assert_equal(got[i], Int64(-1), "refused call wrote " + String(i))
    var got72 = List[Int64](length=72, fill=Int64(-1))
    var d72 = Span(got72)
    assert_true(simd_unpack_bits(exact, 1, 72, d72), "9 bytes for 72 bits")
    var oracle = List[Int64]()
    _ref_unpack(exact, 1, 72, oracle)
    for i in range(72):
        assert_equal(got72[i], oracle[i], "exact source idx " + String(i))


def test_short_destination_refused() raises:
    """The destination view is one slot short of `count`; it is carved out
    of a longer list, so a call that wrote anyway lands in the list's last
    slot and shows up there."""
    var packed = _make_packed(16, 8)
    var got = List[Int64](length=8, fill=Int64(-1))
    var short = Span(got)[0:7]
    assert_true(
        not simd_unpack_bits(Span(packed), 16, 8, short), "7 slots for 8"
    )
    for i in range(8):
        assert_equal(got[i], Int64(-1), "refused call wrote " + String(i))


def test_uncovered_widths_refused() raises:
    """Widths with no kernel here return False and write nothing. Width 4
    has no kernel in this function (ORC calls its own), and -1 is not a
    multiple of 8 (`-1 % 8 == 7`), so neither reaches a kernel."""
    var packed = _make_packed(8, 64)
    var got = List[Int64](length=64, fill=Int64(-1))
    var dst_span = Span(got)
    var widths: List[Int] = [3, 4, 5, 7, 12, 63, -1]
    for wi in range(len(widths)):
        assert_true(
            not simd_unpack_bits(Span(packed), widths[wi], 8, dst_span),
            "width " + String(widths[wi]) + " has no kernel",
        )
    for i in range(64):
        assert_equal(got[i], Int64(-1), "refused width wrote " + String(i))


def main() raises:
    var suite = TestSuite()
    suite.test[test_width_1]()
    suite.test[test_width_2]()
    suite.test[test_width_8]()
    suite.test[test_width_16]()
    suite.test[test_width_24]()
    suite.test[test_width_32]()
    suite.test[test_width_40]()
    suite.test[test_width_48]()
    suite.test[test_width_56]()
    suite.test[test_width_64]()
    suite.test[test_width_0_writes_zeros]()
    suite.test[test_count_0_writes_nothing]()
    suite.test[test_short_source_refused]()
    suite.test[test_short_destination_refused]()
    suite.test[test_uncovered_widths_refused]()
    suite^.run()
