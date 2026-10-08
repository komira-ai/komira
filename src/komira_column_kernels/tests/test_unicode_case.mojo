# komira_column_kernels/tests/test_unicode_case.mojo -- the UTF-8 driver of
# `upper(s)` / `lower(s)` (`unicode_case.mojo`) over the simple case table.
#
# What is pinned, and where each expected value comes from:
#   * ASCII: the letter ranges and their four neighbours ('@', '[', '`', '{').
#   * Mappings that change the encoded length, written out by hand from the
#     UTF-8 encoding rule (RFC 3629 section 3): U+00DF -> U+1E9E (2 bytes to 3),
#     U+0131 -> 'I' and U+212A -> 'k' (to 1), U+1E9E -> U+00DF (3 to 2), the
#     Deseret pair U+10428 <-> U+10400 (4 bytes).
#   * The sample word of Markus Kuhn's "UTF-8 decoder capability and stress
#     test" (UTF-8-test.txt, section 1, "kosme" in Greek), upper and lower.
#   * Every malformed input is a case of that same file, cited by its section
#     number: unexpected continuation bytes (3.1), lonely start bytes (3.2),
#     truncated sequences (3.3, 3.4), impossible bytes (3.5), overlong forms
#     (4.1 to 4.3), surrogates (5.1) and the first value past U+10FFFF (2.3.5).
#     The driver's contract is that each is copied through byte for byte.
#   * The two private helpers are pinned on their own: `_utf8_seq_len` on all
#     256 lead bytes (RFC 3629 section 4 syntax) and `_encode_utf8_into` on the
#     boundary code points of the test file's section 2.

from std.testing import TestSuite, assert_equal

from komira_column_kernels.unicode_case import (
    _encode_utf8_into,
    _utf8_seq_len,
    unicode_lower_bytes,
    unicode_upper_bytes,
)


def _b(*v: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(v)):
        out.append(UInt8(v[i]))
    return out^


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _cat(a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a.copy()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _str(bs: List[UInt8]) -> String:
    # Malformed input must reach the kernel as the exact bytes, so the String
    # is built without validation.
    return String(unsafe_from_utf8=Span(bs))


def _nib(v: Int) -> UInt8:
    return UInt8(48 + v) if v < 10 else UInt8(87 + v)


def _hex(bs: List[UInt8]) -> String:
    # "c3 a9": the bytes as text, so a failing assertion shows both sides.
    var out = List[UInt8]()
    for i in range(len(bs)):
        if i > 0:
            out.append(0x20)
        out.append(_nib(Int(bs[i]) >> 4))
        out.append(_nib(Int(bs[i]) & 0xF))
    return _str(out)


def _assert_bytes(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(_hex(got), _hex(want), what)


def _upper(bs: List[UInt8]) -> List[UInt8]:
    return unicode_upper_bytes(_str(bs))


def _lower(bs: List[UInt8]) -> List[UInt8]:
    return unicode_lower_bytes(_str(bs))


def _assert_both_unchanged(bs: List[UInt8], what: String) raises:
    _assert_bytes(_upper(bs), bs, String("upper ") + what)
    _assert_bytes(_lower(bs), bs, String("lower ") + what)


# -----------------------------------------------------------------------------
# ASCII
# -----------------------------------------------------------------------------


def test_ascii_letter_ranges_and_their_neighbours() raises:
    # '@' 'A' 'Z' '[' '`' 'a' 'z' '{': each range's two ends and the byte on
    # either side of it.
    var edges = _b(0x40, 0x41, 0x5A, 0x5B, 0x60, 0x61, 0x7A, 0x7B)
    _assert_bytes(
        _upper(edges), _b(0x40, 0x41, 0x5A, 0x5B, 0x60, 0x41, 0x5A, 0x7B), "upper edges"
    )
    _assert_bytes(
        _lower(edges), _b(0x40, 0x61, 0x7A, 0x5B, 0x60, 0x61, 0x7A, 0x7B), "lower edges"
    )
    var fox = _ascii("The quick brown fox jumps over the lazy dog 0123456789")
    _assert_bytes(
        _upper(fox),
        _ascii("THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 0123456789"),
        "upper pangram",
    )
    _assert_bytes(
        _lower(fox),
        _ascii("the quick brown fox jumps over the lazy dog 0123456789"),
        "lower pangram",
    )
    # NUL and DEL, the ends of the one-byte range.
    _assert_both_unchanged(_b(0x00, 0x7F), "NUL DEL")


def test_empty_string_is_empty() raises:
    assert_equal(len(unicode_upper_bytes(String(""))), 0)
    assert_equal(len(unicode_lower_bytes(String(""))), 0)


# -----------------------------------------------------------------------------
# Multi-byte mappings
# -----------------------------------------------------------------------------


def test_kuhn_section_1_greek_kosme() raises:
    # U+03BA U+1F79 U+03C3 U+03BC U+03B5, as the test file encodes them.
    var kosme = _b(0xCE, 0xBA, 0xE1, 0xBD, 0xB9, 0xCF, 0x83, 0xCE, 0xBC, 0xCE, 0xB5)
    # U+039A U+1FF9 U+03A3 U+039C U+0395: a 2-byte and a 3-byte re-encode, and
    # U+03C3 (CF 83) -> U+03A3 (CE A3) changes the lead byte, not only the last.
    var upper = _b(0xCE, 0x9A, 0xE1, 0xBF, 0xB9, 0xCE, 0xA3, 0xCE, 0x9C, 0xCE, 0x95)
    _assert_bytes(_upper(kosme), upper, "upper kosme")
    _assert_bytes(_lower(upper), kosme, "lower KOSME")
    # Already lower case: every code point maps to itself and is copied.
    _assert_bytes(_lower(kosme), kosme, "lower kosme")
    _assert_bytes(_upper(upper), upper, "upper KOSME")


def test_output_length_is_not_input_length() raises:
    # U+00DF -> U+1E9E (simple mapping, not "SS"): 2 bytes become 3.
    _assert_bytes(_upper(_b(0xC3, 0x9F)), _b(0xE1, 0xBA, 0x9E), "upper sharp s")
    # ... and back: 3 bytes become 2.
    _assert_bytes(_lower(_b(0xE1, 0xBA, 0x9E)), _b(0xC3, 0x9F), "lower capital sharp s")
    # "straße" -> "STRAẞE": 7 bytes become 8, ASCII and non-ASCII interleaved,
    # and the 3-byte result is written mid-string.
    _assert_bytes(
        _upper(_b(0x73, 0x74, 0x72, 0x61, 0xC3, 0x9F, 0x65)),
        _b(0x53, 0x54, 0x52, 0x41, 0xE1, 0xBA, 0x9E, 0x45),
        "upper strasse",
    )
    # U+0131 dotless i -> 'I' and U+0130 -> 'i': 2 bytes become 1.
    _assert_bytes(_upper(_b(0xC4, 0xB1)), _b(0x49), "upper dotless i")
    _assert_bytes(_lower(_b(0xC4, 0xB0)), _b(0x69), "lower dotted I")
    # U+212A KELVIN SIGN -> 'k': 3 bytes become 1.
    _assert_bytes(_lower(_b(0xE2, 0x84, 0xAA)), _b(0x6B), "lower kelvin")
    # A mapped code point as the LAST bytes of the input: the sequence ends
    # exactly at the end of the buffer and must still be decoded.
    _assert_bytes(
        _upper(_b(0x61, 0xC3, 0xA9)), _b(0x41, 0xC3, 0x89), "upper a e-acute"
    )


def test_four_byte_deseret_pair() raises:
    # U+10428 DESERET SMALL LETTER LONG I <-> U+10400 DESERET CAPITAL LETTER
    # LONG I: the 4-byte decode and the 4-byte encode.
    _assert_bytes(
        _upper(_b(0xF0, 0x90, 0x90, 0xA8)), _b(0xF0, 0x90, 0x90, 0x80), "upper deseret"
    )
    _assert_bytes(
        _lower(_b(0xF0, 0x90, 0x90, 0x80)), _b(0xF0, 0x90, 0x90, 0xA8), "lower deseret"
    )


def test_kuhn_section_2_boundaries_are_valid_and_unchanged() raises:
    # Well-formed, uncased code points at the encoding boundaries: decoded,
    # not mistaken for malformed input, mapped to themselves.
    _assert_both_unchanged(_b(0xC2, 0x80), "2.1.2 U+0080")
    _assert_both_unchanged(_b(0xE0, 0xA0, 0x80), "2.1.3 U+0800")
    _assert_both_unchanged(_b(0xF0, 0x90, 0x80, 0x80), "2.1.4 U+10000")
    _assert_both_unchanged(_b(0xDF, 0xBF), "2.2.2 U+07FF")
    _assert_both_unchanged(_b(0xEF, 0xBF, 0xBF), "2.2.3 U+FFFF")
    _assert_both_unchanged(_b(0xED, 0x9F, 0xBF), "2.3.1 U+D7FF")
    _assert_both_unchanged(_b(0xEE, 0x80, 0x80), "2.3.2 U+E000")
    _assert_both_unchanged(_b(0xEF, 0xBF, 0xBD), "2.3.3 U+FFFD")
    _assert_both_unchanged(_b(0xF4, 0x8F, 0xBF, 0xBF), "2.3.4 U+10FFFF")


# -----------------------------------------------------------------------------
# Malformed input: Kuhn's UTF-8-test.txt, sections 2.3.5 and 3 to 5
# -----------------------------------------------------------------------------


def test_kuhn_malformed_sequences_pass_through() raises:
    _assert_both_unchanged(_b(0xF4, 0x90, 0x80, 0x80), "2.3.5 U+110000")
    _assert_both_unchanged(_b(0x80), "3.1.1")
    _assert_both_unchanged(_b(0xBF), "3.1.2")
    _assert_both_unchanged(_b(0xFE), "3.5.1")
    _assert_both_unchanged(_b(0xFF), "3.5.2")
    _assert_both_unchanged(_b(0xFE, 0xFE, 0xFF, 0xFF), "3.5.3")
    _assert_both_unchanged(_b(0xC0, 0xAF), "4.1.1")
    _assert_both_unchanged(_b(0xE0, 0x80, 0xAF), "4.1.2")
    _assert_both_unchanged(_b(0xF0, 0x80, 0x80, 0xAF), "4.1.3")
    _assert_both_unchanged(_b(0xF8, 0x80, 0x80, 0x80, 0xAF), "4.1.4")
    _assert_both_unchanged(_b(0xC1, 0xBF), "4.2.1")
    _assert_both_unchanged(_b(0xE0, 0x9F, 0xBF), "4.2.2")
    _assert_both_unchanged(_b(0xF0, 0x8F, 0xBF, 0xBF), "4.2.3")
    _assert_both_unchanged(_b(0xC0, 0x80), "4.3.1")
    _assert_both_unchanged(_b(0xE0, 0x80, 0x80), "4.3.2")
    _assert_both_unchanged(_b(0xF0, 0x80, 0x80, 0x80), "4.3.3")
    _assert_both_unchanged(_b(0xED, 0xA0, 0x80), "5.1.1 U+D800")
    _assert_both_unchanged(_b(0xED, 0xBF, 0xBF), "5.1.7 U+DFFF")


def test_kuhn_truncated_sequences_at_end_of_input() raises:
    # Section 3.3: a sequence whose last byte is missing, here with nothing
    # after it, so the lead promises more bytes than the buffer holds.
    _assert_both_unchanged(_b(0xE0, 0x80), "3.3.2")
    _assert_both_unchanged(_b(0xF0, 0x80, 0x80), "3.3.3")
    _assert_both_unchanged(_b(0xDF), "3.3.6")
    _assert_both_unchanged(_b(0xEF, 0xBF), "3.3.7")
    # Section 3.4: the ten sequences of 3.3 concatenated. Every byte is copied
    # and none swallowed: each truncated lead is followed by the next lead.
    var s34 = _b(
        0xC0, 0xE0, 0x80, 0xF0, 0x80, 0x80, 0xF8, 0x80, 0x80, 0x80,
        0xFC, 0x80, 0x80, 0x80, 0x80, 0xDF, 0xEF, 0xBF, 0xF7, 0xBF,
        0xBF, 0xFB, 0xBF, 0xBF, 0xBF, 0xFD, 0xBF, 0xBF, 0xBF, 0xBF,
    )
    _assert_both_unchanged(s34, "3.4")


def test_kuhn_lonely_start_bytes_resynchronise() raises:
    # Sections 3.2.1 to 3.2.3: every lead byte of a 2-, 3- and 4-byte
    # sequence, each followed by a space. A lead whose next byte is not a
    # continuation is copied alone and the space after it is kept.
    var s = List[UInt8]()
    for lead in range(0xC0, 0xF8):
        s.append(UInt8(lead))
        s.append(0x20)
    assert_equal(len(s), 112)
    _assert_both_unchanged(s, "3.2.1-3.2.3")


def test_folding_resumes_after_a_malformed_byte() raises:
    # The 3.3.6 and 3.3.7 lines of the test file, as it writes them: a heading,
    # the truncated sequence in quotes, a bar. The ASCII after each malformed
    # sequence is still folded, so the driver resynchronised on the next byte.
    var line1 = _cat(
        _cat(
            _ascii('3.3.6  2-byte sequence with last byte missing (U-000007FF):    "'),
            _b(0xDF),
        ),
        _ascii('"|\n'),
    )
    var line2 = _cat(
        _cat(
            _ascii('3.3.7  3-byte sequence with last byte missing (U-0000FFFF):    "'),
            _b(0xEF, 0xBF),
        ),
        _ascii('"|\n'),
    )
    var both = _cat(line1, line2)
    var up1 = _cat(
        _cat(
            _ascii('3.3.6  2-BYTE SEQUENCE WITH LAST BYTE MISSING (U-000007FF):    "'),
            _b(0xDF),
        ),
        _ascii('"|\n'),
    )
    var up2 = _cat(
        _cat(
            _ascii('3.3.7  3-BYTE SEQUENCE WITH LAST BYTE MISSING (U-0000FFFF):    "'),
            _b(0xEF, 0xBF),
        ),
        _ascii('"|\n'),
    )
    var lo1 = _cat(
        _cat(
            _ascii('3.3.6  2-byte sequence with last byte missing (u-000007ff):    "'),
            _b(0xDF),
        ),
        _ascii('"|\n'),
    )
    var lo2 = _cat(
        _cat(
            _ascii('3.3.7  3-byte sequence with last byte missing (u-0000ffff):    "'),
            _b(0xEF, 0xBF),
        ),
        _ascii('"|\n'),
    )
    _assert_bytes(_upper(both), _cat(up1, up2), "upper 3.3.6+3.3.7 lines")
    _assert_bytes(_lower(both), _cat(lo1, lo2), "lower 3.3.6+3.3.7 lines")


# -----------------------------------------------------------------------------
# The private helpers, on their whole domain
# -----------------------------------------------------------------------------


def test_utf8_seq_len_on_every_lead_byte() raises:
    # RFC 3629 section 4: 00-7F one byte; C2-DF two; E0-EF three; F0-F4 four;
    # 80-BF (continuations), C0-C1 (overlong only) and F5-FF lead nothing.
    for b in range(256):
        var want: Int
        if b <= 0x7F:
            want = 1
        elif b <= 0xC1:
            want = 0
        elif b <= 0xDF:
            want = 2
        elif b <= 0xEF:
            want = 3
        elif b <= 0xF4:
            want = 4
        else:
            want = 0
        assert_equal(_utf8_seq_len(UInt8(b)), want, String("lead ") + String(b))


def _enc(cp: Int) -> List[UInt8]:
    var out = List[UInt8]()
    _encode_utf8_into(cp, out)
    return out^


def test_encode_utf8_at_the_section_2_boundaries() raises:
    # The first and last code point of each encoded length (UTF-8-test.txt
    # 2.1.1 to 2.2.3, and 2.3.4 for the last scalar value).
    _assert_bytes(_enc(0x00), _b(0x00), "U+0000")
    _assert_bytes(_enc(0x7F), _b(0x7F), "U+007F")
    _assert_bytes(_enc(0x80), _b(0xC2, 0x80), "U+0080")
    _assert_bytes(_enc(0x7FF), _b(0xDF, 0xBF), "U+07FF")
    _assert_bytes(_enc(0x800), _b(0xE0, 0xA0, 0x80), "U+0800")
    _assert_bytes(_enc(0xFFFF), _b(0xEF, 0xBF, 0xBF), "U+FFFF")
    _assert_bytes(_enc(0x10000), _b(0xF0, 0x90, 0x80, 0x80), "U+10000")
    _assert_bytes(_enc(0x10FFFF), _b(0xF4, 0x8F, 0xBF, 0xBF), "U+10FFFF")
    # It appends: what was in the list stays in front.
    var out = _b(0x41)
    _encode_utf8_into(0xE9, out)
    _assert_bytes(out, _b(0x41, 0xC3, 0xA9), "append after 'A'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
