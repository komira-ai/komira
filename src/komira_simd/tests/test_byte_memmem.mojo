# =============================================================================
# test_byte_memmem.mojo — SIMD memmem (substring search) primitive parity.
# =============================================================================
#
# The SIMD "first+last byte"
# memmem (`find_needle`) must return the SAME offset as the scalar reference
# (`find_needle_scalar`) for every input.  The boundary-spanning needle (a
# match straddling a SIMD-chunk boundary) is the critical case.
#
# Coverage:
#   T1  needle at start / middle / end / not-present.
#   T2  needle longer than haystack -> -1.
#   T3  empty needle -> 0 (libc memmem contract).
#   T4  1-byte needle (degenerate "find byte").
#   T5  16-byte needle (the Avro sync-marker length).
#   T6  needle spanning a SIMD-chunk boundary (W, W-1, W+1 offsets).
#   T7  repeated near-misses: first byte matches everywhere but full
#       needle does not (adversarial for a first-byte-only filter).
#   T8  first AND last byte match at many positions but interior differs
#       (adversarial for the first+last filter -> exercises verify step).
#   T9  exhaustive small-input parity: every (haystack, needle) over a tiny
#       binary alphabet of bounded length, SIMD == scalar.
#   T10 randomized fuzz: 20k random (haystack, needle) pairs, SIMD == scalar.
# =============================================================================

from std.random import random_si64, seed
from std.testing import assert_equal, assert_true

from komira_simd.byte_class.byte_memmem import find_needle, find_needle_scalar


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------

def _bytes(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


def _str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _find(haystack: List[UInt8], needle: List[UInt8]) -> Int:
    return find_needle(Span(haystack), Span(needle))


def _find_scalar(haystack: List[UInt8], needle: List[UInt8]) -> Int:
    return find_needle_scalar(Span(haystack), Span(needle))


# -----------------------------------------------------------------------------
# T1 — basic positions.
# -----------------------------------------------------------------------------

def test_basic_positions() raises:
    var h = _str_bytes("the quick brown fox jumps over the lazy dog")

    # at start
    assert_equal(_find(h, _str_bytes("the")), 0, "needle at start")
    # in middle
    assert_equal(_find(h, _str_bytes("brown")), 10, "needle in middle")
    # at end
    assert_equal(_find(h, _str_bytes("dog")), 40, "needle at end")
    # not present
    assert_equal(_find(h, _str_bytes("cat")), -1, "needle not present")
    # second occurrence: "the" appears at 0 and 31 -> first wins
    assert_equal(_find(h, _str_bytes("the")), 0, "first occurrence wins")
    # SIMD == scalar for all of the above
    assert_equal(_find(h, _str_bytes("over")), _find_scalar(h, _str_bytes("over")),
                 "SIMD == scalar (over)")


# -----------------------------------------------------------------------------
# T2 — needle longer than haystack.
# -----------------------------------------------------------------------------

def test_needle_longer_than_haystack() raises:
    var h = _str_bytes("abc")
    assert_equal(_find(h, _str_bytes("abcd")), -1, "needle longer -> -1")
    assert_equal(_find(h, _str_bytes("abcdefghij")), -1, "much longer -> -1")


# -----------------------------------------------------------------------------
# T3 — empty needle.
# -----------------------------------------------------------------------------

def test_empty_needle() raises:
    var h = _str_bytes("abc")
    var empty = List[UInt8]()
    assert_equal(_find(h, empty), 0, "empty needle matches at 0")
    assert_equal(_find_scalar(h, empty), 0, "scalar: empty needle matches at 0")


# -----------------------------------------------------------------------------
# T4 — 1-byte needle.
# -----------------------------------------------------------------------------

def test_one_byte_needle() raises:
    var h = _str_bytes("hello world")
    assert_equal(_find(h, _str_bytes("h")), 0, "1-byte at start")
    assert_equal(_find(h, _str_bytes("o")), 4, "1-byte first 'o'")
    assert_equal(_find(h, _str_bytes("d")), 10, "1-byte at end")
    assert_equal(_find(h, _str_bytes("z")), -1, "1-byte not present")
    assert_equal(_find(h, _str_bytes("o")), _find_scalar(h, _str_bytes("o")),
                 "1-byte SIMD == scalar")


# -----------------------------------------------------------------------------
# T5 — 16-byte needle (Avro sync-marker length).
# -----------------------------------------------------------------------------

def test_sixteen_byte_needle() raises:
    # Build a 64-byte haystack with a unique 16-byte marker at offset 20.
    var marker = List[UInt8]()
    for i in range(16):
        marker.append(UInt8(0xA0 + i))  # 0xA0..0xAF — distinct bytes

    var h = List[UInt8]()
    for i in range(20):
        h.append(UInt8(i))  # 0..19 filler (cannot collide with 0xA0..0xAF)
    for i in range(16):
        h.append(marker[i])
    for i in range(28):
        h.append(UInt8(0x30 + i))  # trailing filler

    assert_equal(_find(h, marker), 20, "16-byte marker found at 20")
    assert_equal(_find(h, marker), _find_scalar(h, marker), "16B SIMD == scalar")

    # marker not present (flip one byte of the needle)
    var miss = marker.copy()
    miss[8] = UInt8(0xFF)
    assert_equal(_find(h, miss), -1, "16-byte marker absent -> -1")


# -----------------------------------------------------------------------------
# T6 — needle spanning a SIMD-chunk boundary (THE critical case).
# -----------------------------------------------------------------------------

def test_boundary_spanning_needle() raises:
    # Native uint8 SIMD width W is 16 (NEON) / 32 (AVX2) / 64 (AVX-512). Place
    # a needle so its match straddles every plausible W boundary: 15, 16, 17,
    # 31, 32, 33, 63, 64, 65. For each placement, assert SIMD == scalar AND
    # the found offset == the placement offset.
    var needle = _str_bytes("NEEDLE12")  # 8 bytes, distinct enough

    var placements = List[Int]()
    placements.append(14)
    placements.append(15)
    placements.append(16)
    placements.append(17)
    placements.append(30)
    placements.append(31)
    placements.append(32)
    placements.append(33)
    placements.append(62)
    placements.append(63)
    placements.append(64)
    placements.append(65)

    for p_i in range(len(placements)):
        var p = placements[p_i]
        var h = List[UInt8]()
        # filler 'a' (0x61) that never appears in the needle's first byte 'N'
        for i in range(p):
            h.append(UInt8(0x61))
        for j in range(len(needle)):
            h.append(needle[j])
        # trailing filler
        for i in range(20):
            h.append(UInt8(0x61))

        var simd_r = _find(h, needle)
        var scal_r = _find_scalar(h, needle)
        assert_equal(simd_r, scal_r,
                     "boundary placement SIMD == scalar @ " + String(p))
        assert_equal(simd_r, p, "found at placement offset " + String(p))


# -----------------------------------------------------------------------------
# T7 — repeated first-byte near-misses.
# -----------------------------------------------------------------------------

def test_repeated_first_byte_near_miss() raises:
    # Haystack of all 'a' (first byte of needle matches everywhere) but the
    # needle "aaab" only matches where a 'b' follows three a's. This defeats a
    # first-byte-only filter; ensure both SIMD + scalar agree.
    var h = List[UInt8]()
    for i in range(100):
        h.append(UInt8(0x61))  # 'a'
    # plant "aaab" ending at offset 50: place 'b' at 50
    h[50] = UInt8(0x62)  # 'b'
    var needle = _str_bytes("aaab")  # match must start at 47

    var simd_r = _find(h, needle)
    var scal_r = _find_scalar(h, needle)
    assert_equal(simd_r, scal_r, "near-miss SIMD == scalar")
    assert_equal(simd_r, 47, "aaab matches at 47 (b at 50)")

    # No 'b' at all -> not present.
    var h2 = List[UInt8]()
    for i in range(100):
        h2.append(UInt8(0x61))
    assert_equal(_find(h2, needle), -1, "no 'b' -> not present")


# -----------------------------------------------------------------------------
# T8 — first AND last byte match, interior differs.
# -----------------------------------------------------------------------------

def test_first_last_match_interior_differs() raises:
    # needle = "XooooX" (first=last='X'). Build a haystack peppered with 'X'
    # pairs the right distance apart but WRONG interior, plus one true match.
    var needle = _str_bytes("XooooX")  # len 6, X..X
    var h = List[UInt8]()
    for i in range(120):
        h.append(UInt8(0x2E))  # '.'
    # decoy: X at 10 and X at 15 (distance 5 == len-1) but interior is '.'
    h[10] = UInt8(0x58)  # 'X'
    h[15] = UInt8(0x58)  # 'X'  -> first+last filter fires, verify rejects
    # true match at offset 40: X o o o o X
    h[40] = UInt8(0x58)
    h[41] = UInt8(0x6F)  # 'o'
    h[42] = UInt8(0x6F)
    h[43] = UInt8(0x6F)
    h[44] = UInt8(0x6F)
    h[45] = UInt8(0x58)

    var simd_r = _find(h, needle)
    var scal_r = _find_scalar(h, needle)
    assert_equal(simd_r, scal_r, "interior-differs SIMD == scalar")
    assert_equal(simd_r, 40, "true match at 40, decoy at 10 rejected")


# -----------------------------------------------------------------------------
# T9 — exhaustive small-input parity over a tiny alphabet.
# -----------------------------------------------------------------------------

def _ternary_to_bytes(value: Int, ndigits: Int) -> List[UInt8]:
    """Map a base-3 integer to a `ndigits`-byte list over alphabet {A,B,C}."""
    var out = List[UInt8]()
    var v = value
    for _i in range(ndigits):
        var d = v % 3
        v = v // 3
        out.append(UInt8(0x41 + d))  # 'A'+d
    return out^


def test_exhaustive_small_inputs() raises:
    # Alphabet {A,B,C}. Haystacks of length 0..5, needles of length 1..4.
    # For every (haystack, needle), assert SIMD == scalar. 3^5 haystacks ×
    # (3^1+..+3^4) needles is a few thousand cases — fully exhaustive.
    var checked = 0
    for hlen in range(0, 6):
        var n_haystacks = 1
        for _i in range(hlen):
            n_haystacks *= 3
        for hv in range(n_haystacks):
            var h = _ternary_to_bytes(hv, hlen)
            for nlen in range(1, 5):
                var n_needles = 1
                for _i in range(nlen):
                    n_needles *= 3
                for nv in range(n_needles):
                    var needle = _ternary_to_bytes(nv, nlen)
                    var simd_r = find_needle(Span(h), Span(needle))
                    var scal_r = find_needle_scalar(Span(h), Span(needle))
                    assert_equal(
                        simd_r, scal_r,
                        "exhaustive mismatch h=" + String(hv)
                        + " hlen=" + String(hlen)
                        + " n=" + String(nv) + " nlen=" + String(nlen),
                    )
                    checked += 1
    assert_true(checked > 1000, "exhaustive ran a meaningful number of cases")


# -----------------------------------------------------------------------------
# T10 — randomized fuzz over a wider alphabet + longer inputs.
# -----------------------------------------------------------------------------

def test_randomized_fuzz() raises:
    # NOTE: `random_si64(lo, hi)` is INCLUSIVE on both ends — `random_si64(0,
    # n)` yields a value in [0, n]. All bounds below are written accordingly
    # (upper bound == desired_max, not desired_max + 1).
    seed(0xA5A5)
    var iters = 20000
    for _it in range(iters):
        # Haystack length 0..200, needle length 0..24, alphabet of 4 symbols
        # (so near-misses + first+last collisions are frequent enough to
        # exercise the verify path), with occasional full-byte alphabet to
        # stress distinct-byte fast filters.
        var hlen = Int(random_si64(0, 200))
        var nlen = Int(random_si64(0, 24))
        var alpha = Int(random_si64(0, 1))  # 0 -> 4-symbol, 1 -> 256-symbol
        var modulus = 4 if alpha == 0 else 256

        var h = List[UInt8]()
        for _i in range(hlen):
            h.append(UInt8(Int(random_si64(0, Int64(modulus - 1))) % 256))
        var needle = List[UInt8]()
        for _i in range(nlen):
            needle.append(UInt8(Int(random_si64(0, Int64(modulus - 1))) % 256))

        # Occasionally plant the needle into the haystack so positive matches
        # are well-represented (random needles rarely occur by chance).
        if nlen > 0 and hlen >= nlen and (random_si64(0, 1) == 0):
            var at = Int(random_si64(0, Int64(hlen - nlen)))
            for j in range(nlen):
                h[at + j] = needle[j]

        var simd_r = find_needle(Span(h), Span(needle))
        var scal_r = find_needle_scalar(Span(h), Span(needle))
        assert_equal(simd_r, scal_r,
                     "fuzz mismatch hlen=" + String(hlen)
                     + " nlen=" + String(nlen) + " iter=" + String(_it))


def main() raises:
    test_basic_positions()
    test_needle_longer_than_haystack()
    test_empty_needle()
    test_one_byte_needle()
    test_sixteen_byte_needle()
    test_boundary_spanning_needle()
    test_repeated_first_byte_near_miss()
    test_first_last_match_interior_differs()
    test_exhaustive_small_inputs()
    test_randomized_fuzz()
    print("test_byte_memmem: ALL PASS")
