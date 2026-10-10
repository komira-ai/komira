# =============================================================================
# test_metadata_cdata_negative_words.mojo: decode_metadata reads each i32
# of the Arrow C Data Interface metadata encoding as a signed value
# =============================================================================
#
# The metadata encoding is a sequence of int32 words (a key count, then a
# length before each key and value). decode_metadata refuses a negative
# word, and its message names the word it read. A reader that assembles
# the four bytes as an unsigned 32-bit value and widens it reads FF FF FF FF
# as 4294967295 rather than -1, so the message is wrong and the negative
# check never fires (the word is still refused, as a value above the caps).
# Each case pins the exact number the refusal reports, for -1 and for the
# most negative i32, in each of the three positions.
#
# What the decode_metadata rows can and cannot prove: the old reader,
# `Int32(Int(u))`, narrows an Int above Int32's range, and what that
# produces depends on how the expression is compiled. In this build it
# gives the right answer for -2^31 (and for -2, -256 and -2^30), and wrong
# only for -1. So the -2^31 rows are not an independent guard: a reader that
# special-cases FF FF FF FF and keeps `Int32(Int(u))` otherwise passes them.
# No output-only test can pin compiler-dependent behaviour, and the direct
# cases below do not either: that special-casing reader passes them too,
# because in this build `Int32(Int(u))` is wrong only for FF FF FF FF.
# The `_bytes_to_i32` cases call the reader directly over a sweep of
# runtime words (top byte 0x80 to 0xFF under several low patterns, plus a
# pseudo-random walk over all 32 bits) against a reference computed in
# `Int`. They catch a reader that misreads any other word they reach (for
# example one that returns -1 for every word near FF FF FF FF), which the
# decode_metadata rows, testing three words, do not.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow_ipc.c_data_interface import (
    _bytes_to_i32,
    decode_metadata,
    encode_metadata,
)


def _decode_error(words: List[Int]) -> String:
    """Decode a buffer of little-endian i32 words; return the error text.

    The buffer is encode_metadata's encoding of one empty pair (three i32
    words: count 1, key length 0, value length 0), with its first
    `len(words)` words overwritten; every refusal below fires on a length
    word before any key or value bytes are read."""
    var keys = List[String]()
    keys.append(String(""))
    var vals = List[String]()
    vals.append(String(""))
    var p = encode_metadata(keys, vals)
    for i in range(len(words)):
        var u = words[i] & 0xFFFFFFFF
        for b in range(4):
            p[i * 4 + b] = Int8(Int(UInt8((u >> (8 * b)) & 0xFF)))
    var msg = String("no error")
    try:
        _ = decode_metadata(p)
    except e:
        msg = String(e)
    p.free()
    return msg


def test_negative_key_count_is_reported_signed() raises:
    assert_equal(
        _decode_error([-1]), "decode_metadata: implausible key count -1"
    )
    assert_equal(
        _decode_error([-(1 << 31)]),
        "decode_metadata: implausible key count -2147483648",
    )


def test_negative_key_length_is_reported_signed() raises:
    assert_equal(
        _decode_error([1, -1]), "decode_metadata: implausible key length -1"
    )
    assert_equal(
        _decode_error([1, -(1 << 31)]),
        "decode_metadata: implausible key length -2147483648",
    )


def test_negative_value_length_is_reported_signed() raises:
    assert_equal(
        _decode_error([1, 0, -1]),
        "decode_metadata: implausible value length -1",
    )
    assert_equal(
        _decode_error([1, 0, -(1 << 31)]),
        "decode_metadata: implausible value length -2147483648",
    )


def test_top_bit_clear_words_are_unchanged() raises:
    """The control: a word just over the caps, top bit clear, is reported
    as itself (so the signed read changes only words with the top bit
    set)."""
    assert_equal(
        _decode_error([(1 << 20) + 1]),
        "decode_metadata: implausible key count 1048577",
    )
    assert_equal(
        _decode_error([1, 0, (1 << 28) + 1]),
        "decode_metadata: implausible value length 268435457",
    )


def test_empty_pair_control_decodes() raises:
    """The buffer the cases above start from decodes to one empty pair."""
    assert_equal(_decode_error([1, 0, 0]), "no error")


def _signed(u: Int) -> Int:
    """The two's complement value of the 32-bit word `u` (0 <= u < 2^32)."""
    if u >= (1 << 31):
        return u - (1 << 32)
    return u


def _check_reads(words: List[Int]) raises:
    """Write each word little-endian into a 12-byte buffer, three at a time,
    and check `_bytes_to_i32` reads each back as its signed value."""
    var keys = List[String]()
    keys.append(String(""))
    var vals = List[String]()
    vals.append(String(""))
    # encode_metadata of one empty pair is a 12-byte heap buffer.
    var p = encode_metadata(keys, vals)
    var i = 0
    while i < len(words):
        var k = min(3, len(words) - i)
        for j in range(k):
            var u = words[i + j] & 0xFFFFFFFF
            for b in range(4):
                p[j * 4 + b] = Int8(Int(UInt8((u >> (8 * b)) & 0xFF)))
        for j in range(k):
            var u = words[i + j] & 0xFFFFFFFF
            var got = Int(_bytes_to_i32(p + j * 4))
            if got != _signed(u):
                p.free()
                assert_equal(got, _signed(u), "word " + String(u))
        i += k
    p.free()


def test_bytes_to_i32_top_bit_set_sweep() raises:
    """Every top byte 0x80..0xFF under low bytes FF FF FF, 00 00 00,
    00 00 01 and FE FF FF: each reads as a negative i32."""
    var w = List[Int]()
    for hb in range(0x80, 0x100):
        w.append((hb << 24) | 0xFFFFFF)
        w.append(hb << 24)
        w.append((hb << 24) | 1)
        w.append((hb << 24) | 0xFFFFFE)
    _check_reads(w)


def test_bytes_to_i32_byte_order_and_top_bit_clear() raises:
    """Distinct bytes pin little-endian order; top-bit-clear words read as
    themselves, including Int32's maximum."""
    var w = List[Int]()
    w.append(0x01020304)
    w.append(0x7FFFFFFF)
    w.append(0)
    w.append(0x80000000)
    w.append(0xFFFFFFFF)
    w.append(0x04030201)
    _check_reads(w)


def test_bytes_to_i32_pseudo_random_walk() raises:
    """4096 words from a 32-bit LCG, so neither the bytes nor the expected
    values are compile-time constants."""
    var w = List[Int]()
    var x = 0x2545F491
    for _ in range(4096):
        x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
        w.append(x)
    _check_reads(w)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
