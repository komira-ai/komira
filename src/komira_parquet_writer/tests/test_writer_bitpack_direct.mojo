# The fixed-width LSB-first packer (`writer_bitpack`).
#
# What each test proves, and the defect it catches:
#   * test_matches_reference_every_width_and_count: for every width 1..64
#     and every count 0..80, `pack_fixed_width` is byte-identical to a
#     one-bit-at-a-time reference written here from the layout rule alone
#     (value k's bit i is stream bit k*w + i). The counts cover the SIMD
#     group path (>= 8 trailing slack bytes), the slack-short last group
#     and the sub-8 tail; widths 57..64 cover the scalar-only widths. A
#     wrong lane shift, a missed zeroing of a group's bytes, or a group
#     taken by the SIMD path without slack (an out-of-range store) fails it.
#     It was red on the predecessor's packer at w=59, n=3: its scalar
#     accumulator shifted a value's top bits out of the 64-bit word whenever
#     the bits still pending plus the width passed 64 (widths 58..64), so a
#     DELTA_BINARY_PACKED miniblock of wide deltas lost bits.
#   * test_known_bytes: one hand-computed vector pins the bit order itself,
#     which a reference that shared the packer's mistake would not.
#   * test_masks_wide_inputs: inputs wider than the width are masked.
#   * test_refuses_bad_arguments: a count past the list or a width outside
#     [0, 64] raises instead of reading out of bounds.
#   * test_min_bit_width: ceil(log2(v + 1)) at every power-of-two boundary.
from std.testing import TestSuite, assert_equal, assert_raises

from komira_parquet_writer.writer_bitpack import min_bit_width, pack_fixed_width


def _reference(values: List[Int64], count: Int, w: Int) -> List[UInt8]:
    var n_bytes = (count * w + 7) // 8
    var out = List[UInt8](length=n_bytes, fill=0)
    for k in range(count):
        var v = UInt64(values[k])
        for i in range(w):
            if (v >> UInt64(i)) & 1 == 1:
                var pos = k * w + i
                out[pos // 8] = out[pos // 8] | UInt8(1 << (pos % 8))
    return out^


def _values(n: Int, seed: UInt64) -> List[Int64]:
    """Deterministic 64-bit values (splitmix64), all bits exercised."""
    var out = List[Int64]()
    var x = seed
    for _ in range(n):
        x = x + UInt64(0x9E3779B97F4A7C15)
        var z = x
        z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B5)
        z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
        z = z ^ (z >> 31)
        out.append(Int64(z))
    return out^


def test_matches_reference_every_width_and_count() raises:
    var values = _values(80, 7)
    for w in range(1, 65):
        var mask = (UInt64(1) << UInt64(w)) - 1 if w < 64 else ~UInt64(0)
        var fitted = List[Int64]()
        for k in range(len(values)):
            fitted.append(Int64(UInt64(values[k]) & mask))
        for count in range(0, 81):
            var got = pack_fixed_width(fitted, count, w)
            var want = _reference(fitted, count, w)
            var bad = -1
            if len(got) != len(want):
                bad = len(want)
            else:
                for j in range(len(want)):
                    if got[j] != want[j]:
                        bad = j
                        break
            # The message is built only on a mismatch: building it for every
            # byte of 5,184 packings costs minutes.
            if bad >= 0:
                assert_equal(
                    -1,
                    bad,
                    "w=" + String(w) + " n=" + String(count) + ": first differing byte",
                )


def test_known_bytes() raises:
    # Width 3, values 0..7: stream bits 000 100 010 110 001 101 011 111
    # (LSB first per value) -> bytes 0x88, 0xC6, 0xFA.
    var v: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7]
    var got = pack_fixed_width(v, 8, 3)
    assert_equal(len(got), 3)
    assert_equal(Int(got[0]), 0x88)
    assert_equal(Int(got[1]), 0xC6)
    assert_equal(Int(got[2]), 0xFA)


def test_masks_wide_inputs() raises:
    var wide: List[Int64] = [0xFF, 0x1FF, -1, 0x7]
    var narrow: List[Int64] = [0x7, 0x7, 0x7, 0x7]
    var a = pack_fixed_width(wide, 4, 3)
    var b = pack_fixed_width(narrow, 4, 3)
    assert_equal(len(a), len(b))
    for j in range(len(a)):
        assert_equal(Int(a[j]), Int(b[j]))


def test_width_zero_and_count_zero_emit_nothing() raises:
    var v: List[Int64] = [1, 2, 3]
    assert_equal(len(pack_fixed_width(v, 3, 0)), 0)
    assert_equal(len(pack_fixed_width(v, 0, 5)), 0)


def test_refuses_bad_arguments() raises:
    var v: List[Int64] = [1, 2, 3]
    with assert_raises(contains="count 4"):
        _ = pack_fixed_width(v, 4, 2)
    with assert_raises(contains="count -1"):
        _ = pack_fixed_width(v, -1, 2)
    with assert_raises(contains="bit_width 65"):
        _ = pack_fixed_width(v, 3, 65)


def test_min_bit_width() raises:
    assert_equal(min_bit_width(0), 0)
    assert_equal(min_bit_width(-5), 0)
    assert_equal(min_bit_width(1), 1)
    for b in range(1, 63):
        assert_equal(min_bit_width((1 << b) - 1), b, "2^" + String(b) + " - 1")
        assert_equal(min_bit_width(1 << b), b + 1, "2^" + String(b))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
