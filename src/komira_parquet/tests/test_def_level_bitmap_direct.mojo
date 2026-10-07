# Direct tests of `def_level_bitmap.mojo`: a V1 definition-level section
# (`[i32 LE length][RLE / Bit-Packing Hybrid at bit width 1]`) to an Arrow
# validity bitmap. Level 1 is a value, level 0 a null; a level the section
# does not encode (it ends early) is a null. The all-valid fast path must give
# the same bitmap as the full decode, so every case is checked against the
# levels the test encoded, whichever path it takes; `all_valid` says no null.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.bitmap import Bitmap

from komira_parquet.def_level_bitmap import (
    DefLevelResult,
    _is_all_valid_def_levels,
    decode_def_levels_to_bitmap,
)


def _section(body: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    var n = len(body)
    for k in range(4):
        out.append(UInt8((n >> (8 * k)) & 0xFF))
    for i in range(n):
        out.append(body[i])
    return out^


def _check(
    section: List[UInt8], num: Int, levels: List[Int], all_valid: Bool
) raises:
    """`levels[i]` is the expected level of row i (rows past it are null)."""
    var r = decode_def_levels_to_bitmap(Span(section), num)
    assert_equal(r.bytes_consumed, len(section))
    assert_equal(r.all_valid, all_valid, "all_valid")
    assert_equal(r.bitmap.length, num)
    for i in range(num):
        var want = i < len(levels) and levels[i] == 1
        assert_equal(r.bitmap.test(i), want, "row " + String(i))


def _ones(n: Int) -> List[Int]:
    return List[Int](length=n, fill=1)


# --- the fast path, pattern 1: one RLE run of 1 ------------------------------


def test_one_rle_run_of_ones_is_all_valid() raises:
    for n in range(1, 70, 7):
        var body: List[UInt8] = [UInt8((n << 1) & 0x7F), UInt8(1)]
        if n >= 64:
            body = [UInt8(((n << 1) & 0x7F) | 0x80), UInt8(n >> 6), UInt8(1)]
        _check(_section(body), n, _ones(n), True)
    # A run longer than the page's count.
    var long_run: List[UInt8] = [UInt8(40 << 1), UInt8(1)]
    _check(_section(long_run), 5, _ones(5), True)
    assert_true(_is_all_valid_def_levels(Span(long_run), 5))


def test_rle_runs_that_are_not_the_fast_path() raises:
    # A run of zeros: every row null.
    var zeros: List[UInt8] = [UInt8(6 << 1), UInt8(0)]
    _check(_section(zeros), 6, List[Int](length=6, fill=0), False)
    # Two runs of ones (3 then 2): the first run is short of the count, so the
    # full decode runs and finds no null.
    var two: List[UInt8] = [UInt8(3 << 1), UInt8(1), UInt8(2 << 1), UInt8(1)]
    assert_false(_is_all_valid_def_levels(Span(two), 5))
    _check(_section(two), 5, _ones(5), True)
    # A two-byte header with no value byte after it: not the fast path, and
    # the decode finds no complete run, so every row is null.
    var torn: List[UInt8] = [UInt8(0x80), UInt8(0x01)]
    assert_false(_is_all_valid_def_levels(Span(torn), 3))
    _check(_section(torn), 3, List[Int](), False)


# --- the fast path, pattern 2: one bit-packed run of all ones ----------------


def test_bitpacked_all_ones() raises:
    # Two groups (16 values), every bit set; the count a multiple of 8.
    var sixteen: List[UInt8] = [UInt8((2 << 1) | 1), UInt8(0xFF), UInt8(0xFF)]
    _check(_section(sixteen), 16, _ones(16), True)
    # 13 values: the last byte needs only its low 5 bits.
    var thirteen: List[UInt8] = [UInt8((2 << 1) | 1), UInt8(0xFF), UInt8(0x1F)]
    assert_true(_is_all_valid_def_levels(Span(thirteen), 13))
    _check(_section(thirteen), 13, _ones(13), True)


def test_bitpacked_runs_that_are_not_the_fast_path() raises:
    # Low 5 bits of the last byte not all set: row 8 is null.
    var hole: List[UInt8] = [UInt8((2 << 1) | 1), UInt8(0xFF), UInt8(0x1E)]
    assert_false(_is_all_valid_def_levels(Span(hole), 13))
    var lv = _ones(13)
    lv[8] = 0
    _check(_section(hole), 13, lv, False)
    # A full byte with a zero bit: row 2 is null.
    var gap: List[UInt8] = [UInt8((1 << 1) | 1), UInt8(0xFB)]
    var lv8 = _ones(8)
    lv8[2] = 0
    assert_false(_is_all_valid_def_levels(Span(gap), 8))
    _check(_section(gap), 8, lv8, False)
    # One group (8 values) for a count of 10: rows 8 and 9 are not encoded.
    var short_run: List[UInt8] = [UInt8((1 << 1) | 1), UInt8(0xFF)]
    assert_false(_is_all_valid_def_levels(Span(short_run), 10))
    _check(_section(short_run), 10, _ones(8), False)
    # A header claiming 3 groups over 1 byte: not the fast path; the decode
    # stops at the end of the section.
    var claims: List[UInt8] = [UInt8((3 << 1) | 1), UInt8(0xFF)]
    assert_false(_is_all_valid_def_levels(Span(claims), 8))


def test_malformed_and_tiny_sections() raises:
    # A varint that never ends: the fast path's reader raises and declines.
    var endless: List[UInt8] = [UInt8(0xFF), UInt8(0xFF)]
    assert_false(_is_all_valid_def_levels(Span(endless), 4))
    _check(_section(endless), 4, List[Int](), False)
    # One byte is too short for the fast path to read a run.
    var one: List[UInt8] = [UInt8(2 << 1)]
    assert_false(_is_all_valid_def_levels(Span(one), 2))
    _check(_section(one), 2, List[Int](), False)


# --- the section prefix and the value count ----------------------------------


def test_no_section_or_no_values_is_all_valid() raises:
    var three: List[UInt8] = [UInt8(1), UInt8(2), UInt8(3)]
    var r = decode_def_levels_to_bitmap(Span(three), 9)
    assert_true(r.all_valid)
    assert_equal(r.bytes_consumed, 3)
    assert_equal(r.bitmap.length, 9)
    assert_true(r.bitmap.test(8))
    var body: List[UInt8] = [UInt8(2), UInt8(1)]
    var _h1 = _section(body)
    var r0 = decode_def_levels_to_bitmap(Span(_h1), 0)
    assert_true(r0.all_valid)
    assert_equal(r0.bytes_consumed, 4)
    assert_equal(r0.bitmap.length, 0)


def test_refusals() raises:
    var body: List[UInt8] = [UInt8(4), UInt8(1)]
    var counts: List[Int] = [-1, 2147483648]
    for ci in range(len(counts)):
        try:
            var _h2 = _section(body)
            _ = decode_def_levels_to_bitmap(Span(_h2), counts[ci])
            assert_true(False, "count " + String(counts[ci]))
        except e:
            assert_true("cannot hold" in String(e), String(e))
    # A prefix longer than the bytes after it, and a negative prefix.
    var long_prefix: List[UInt8] = [UInt8(9), UInt8(0), UInt8(0), UInt8(0), UInt8(2), UInt8(1)]
    var negative: List[UInt8] = [UInt8(0xFF), UInt8(0xFF), UInt8(0xFF), UInt8(0xFF), UInt8(2), UInt8(1)]
    for which in range(2):
        var refused = False
        try:
            if which == 0:
                _ = decode_def_levels_to_bitmap(Span(long_prefix), 1)
            else:
                _ = decode_def_levels_to_bitmap(Span(negative), 1)
        except e:
            refused = True
        assert_true(refused, "a prefix the section cannot hold")


def test_result_holds_its_fields() raises:
    var body: List[UInt8] = [UInt8(3 << 1), UInt8(1)]
    var _h3 = _section(body)
    var r = decode_def_levels_to_bitmap(Span(_h3), 3)
    assert_equal(r.bytes_consumed, 6)
    var built = DefLevelResult(Bitmap.create_all_valid(3), 6)
    assert_false(built.all_valid, "all_valid defaults to False")
    assert_equal(built.bytes_consumed, 6)
    assert_true(built.bitmap.test(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
