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
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow_ipc.c_data_interface import decode_metadata, encode_metadata


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
