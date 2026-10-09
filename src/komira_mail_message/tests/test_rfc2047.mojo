# RFC 2047 encoded words. Decoding: every example of RFC 2047 section 8 (the
# comment examples are read as unstructured text, without the parentheses;
# the iso-8859-8 one is kept as written, that charset is not transcoded),
# the RFC 2231 section 5 language suffix, and the words a decoder must keep
# as written (section 6.3): unknown charset, malformed, not white-space
# delimited, decoded bytes that are not UTF-8 or that hold CR, LF or NUL.
# The addresses of the section 8 examples are replaced by reserved example
# names (RFC 2606); the encoded words are the RFC's bytes.
# Ill-formed UTF-8 outside encoded words: one U+FFFD per octet that does not
# start a well-formed sequence, with a vector on each side of every edge of
# the RFC 3629 section 4 lead-byte and continuation-byte ranges.
# Encoding: exact output for a Q and a B case, every word at most 75
# characters with no UTF-8 sequence split, and decode(encode(x)) == x.

from std.testing import assert_equal, assert_true

from komira_mail_message import decode_header_text, encode_header_text


def test_rfc2047_section_8_comment_examples() raises:
    assert_equal(decode_header_text("=?ISO-8859-1?Q?a?="), "a")
    assert_equal(decode_header_text("=?ISO-8859-1?Q?a?= b"), "a b")
    # White space between adjacent encoded words is not displayed.
    assert_equal(decode_header_text("=?ISO-8859-1?Q?a?= =?ISO-8859-1?Q?b?="), "ab")
    assert_equal(decode_header_text("=?ISO-8859-1?Q?a?=  =?ISO-8859-1?Q?b?="), "ab")
    # The folded example, after unfolding (the CRLF is removed, the WSP kept).
    assert_equal(
        decode_header_text("=?ISO-8859-1?Q?a?=    =?ISO-8859-1?Q?b?="), "ab"
    )
    assert_equal(decode_header_text("=?ISO-8859-1?Q?a_b?="), "a b")
    assert_equal(decode_header_text("=?ISO-8859-1?Q?a?= =?ISO-8859-2?Q?_b?="), "a b")


def test_rfc2047_section_8_from_examples() raises:
    # The two `From:` lines of the section 8 sample messages.
    assert_equal(
        decode_header_text("=?ISO-8859-1?Q?Olle_J=E4rnefors?= <ojarnef@example.org>"),
        "Olle Järnefors <ojarnef@example.org>",
    )
    assert_equal(
        decode_header_text("=?ISO-8859-1?Q?Patrik_F=E4ltstr=F6m?= <paf@example.org>"),
        "Patrik Fältström <paf@example.org>",
    )


def test_rfc2047_section_8_header_examples() raises:
    assert_equal(
        decode_header_text("=?US-ASCII?Q?Keith_Moore?= <moore@example.org>"),
        "Keith Moore <moore@example.org>",
    )
    assert_equal(
        decode_header_text("=?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?= <keld@example.org>"),
        "Keld Jørn Simonsen <keld@example.org>",
    )
    assert_equal(
        decode_header_text("=?ISO-8859-1?Q?Andr=E9?= Pirard <PIRARD@example.org>"),
        "André Pirard <PIRARD@example.org>",
    )
    assert_equal(
        decode_header_text(
            "=?ISO-8859-1?B?SWYgeW91IGNhbiByZWFkIHRoaXMgeW8=?=    "
            + "=?ISO-8859-2?B?dSB1bmRlcnN0YW5kIHRoZSBleGFtcGxlLg==?="
        ),
        "If you can read this you understand the example.",
    )
    # Section 8 also shows `=?iso-8859-8?b?7eXs+SDv4SDp7Oj08A==?=`: Hebrew
    # bytes above 0x7F in a charset not transcoded, so it stays as written.
    assert_equal(
        decode_header_text("=?iso-8859-8?b?7eXs+SDv4SDp7Oj08A==?="),
        "=?iso-8859-8?b?7eXs+SDv4SDp7Oj08A==?=",
    )


def test_rfc2231_language_suffix_is_ignored() raises:
    assert_equal(decode_header_text("=?US-ASCII*EN?Q?Keith_Moore?="), "Keith Moore")


def test_words_kept_as_written() raises:
    var kept = List[String]()
    kept.append("=?ISO-8859-1?Q?a")  # not closed
    kept.append("=?X-UNKNOWN?Q?a?=")  # charset not read
    kept.append("=?UTF-8?X?a?=")  # no such encoding
    kept.append("=?UTF-8?Q?a=0D=0ABcc:_x?=")  # would decode to CR LF
    kept.append("=?UTF-8?Q?a=00?=")  # would decode to NUL
    kept.append("=?UTF-8?Q?=FF?=")  # not UTF-8
    kept.append("=?UTF-8?Q?=G1?=")  # not a hex escape
    kept.append("=?UTF-8?B?#####?=")  # not base64
    kept.append("x=?UTF-8?Q?a?=")  # not delimited by white space
    kept.append("=??Q?a?=")  # empty charset
    for i in range(len(kept)):
        assert_equal(decode_header_text(kept[i]), kept[i])
    # A kept word next to a decoded one keeps the white space between them.
    assert_equal(
        decode_header_text("=?X-UNKNOWN?Q?a?= =?UTF-8?Q?b?="), "=?X-UNKNOWN?Q?a?= b"
    )


def test_malformed_words_each_rule() raises:
    # One word per refusal in decode_encoded_word and _decode_q; each would
    # decode if that one rule were skipped.
    var kept = List[String]()
    kept.append("=?utf-8?Q?a=4?=")  # an escape cut short by the word's end
    kept.append(String("=?utf-8?Q?a") + chr(127) + "b?=")  # DEL in Q text
    kept.append("=?utf-8*e(n?Q?a?=")  # a non-token byte in the language
    kept.append("=?utf-8?QXab?=")  # no `?` after the encoding letter
    kept.append("=?utf-8?Q?a?b?=")  # a `?` inside the encoded text
    for i in range(len(kept)):
        assert_equal(decode_header_text(kept[i]), kept[i])
    # windows-125* is read for its ASCII bytes, like iso-8859-*.
    assert_equal(decode_header_text("=?windows-1252?Q?abc?="), "abc")
    assert_equal(
        decode_header_text("=?windows-1252?Q?caf=E9?="), "=?windows-1252?Q?caf=E9?="
    )


def _lossy(a: UInt8, b: UInt8, c: UInt8) raises -> String:
    var bytes = List[UInt8]()
    bytes.append(a)
    bytes.append(b)
    bytes.append(c)
    return decode_header_text(Span(bytes))


def test_ill_formed_utf8_outside_words_is_replaced() raises:
    # RFC 3629: a second byte outside its lead byte's range (C3 41; the
    # overlong E0 80 80) and a bad third byte (E2 82 41) are each U+FFFD per
    # octet that does not start a sequence.
    assert_equal(_lossy(0x61, 0xC3, 0x41), "a�A")
    assert_equal(_lossy(0xE0, 0x80, 0x80), "���")
    assert_equal(_lossy(0xE2, 0x82, 0x41), "��A")
    assert_equal(_lossy(0xE2, 0x82, 0xAC), "€")
    # A second byte above its lead byte's range: the surrogate ED A0 80
    # (ED allows 80..9F) and F4 90 80 80, above U+10FFFF (F4 allows 80..8F).
    assert_equal(_lossy(0xED, 0xA0, 0x80), "���")
    assert_equal(_lossy(0xED, 0x9F, 0xBF), chr(0xD7FF))
    var above = List[UInt8]()
    above.append(0xF4)
    above.append(0x90)
    above.append(0x80)
    above.append(0x80)
    assert_equal(decode_header_text(Span(above)), "����")
    above[1] = 0x8F
    assert_equal(decode_header_text(Span(above)), chr(0x10F000))
    # Overlong lead bytes C0 and C1 never appear (RFC 3629 section 1); each
    # octet of C0 AF and C1 BF is U+FFFD.
    var two = List[UInt8]()
    two.append(0xC0)
    two.append(0xAF)
    assert_equal(decode_header_text(Span(two)), "��")
    two[0] = 0xC1
    two[1] = 0xBF
    assert_equal(decode_header_text(Span(two)), "��")
    # F0 needs a second byte 90..BF (RFC 3629 section 4): the overlong
    # F0 8F BF BF is four U+FFFD, and F0 90 80 80 is U+10000.
    var four = List[UInt8]()
    four.append(0xF0)
    four.append(0x8F)
    four.append(0xBF)
    four.append(0xBF)
    assert_equal(decode_header_text(Span(four)), "����")
    four[1] = 0x90
    four[2] = 0x80
    four[3] = 0x80
    assert_equal(decode_header_text(Span(four)), chr(0x10000))
    # A third byte above BF is not a continuation byte: E2 82 C0 is three
    # U+FFFD (C0 is not a lead byte either).
    assert_equal(_lossy(0xE2, 0x82, 0xC0), "���")


def _hex(text: String) -> List[UInt8]:
    """The octets written as space-separated hex pairs in `text`."""
    var out = List[UInt8]()
    var b = text.as_bytes()
    var i = 0
    while i + 1 < len(b):
        out.append(UInt8(_nibble(b[i]) * 16 + _nibble(b[i + 1])))
        i += 3
    return out^


def _nibble(c: UInt8) -> Int:
    if c >= 0x41:
        return Int(c) - 0x41 + 10
    return Int(c) - 0x30


def _check_lossy(hex: String, want: String) raises:
    assert_equal(decode_header_text(Span(_hex(hex))), want, hex)


def _ffd(count: Int) -> String:
    var out = String("")
    for _ in range(count):
        out += chr(0xFFFD)
    return out


def test_utf8_lead_and_continuation_byte_edges() raises:
    # RFC 3629 section 4: every edge of the lead-byte table, every edge of
    # the second-byte range of the first and last lead byte of each
    # lead-byte range (C2..DF, E0, E1..EC, ED, EE..EF, F0, F1..F3, F4) and
    # of F2, and every edge of the continuation-byte range at each later
    # byte position, as a well-formed sequence and its code point on the
    # inside, and on the outside one U+FFFD per octet that does not start a
    # well-formed sequence.
    _check_lossy("7F", chr(0x7F))
    _check_lossy("80", _ffd(1))
    _check_lossy("C1 BF", _ffd(2))
    _check_lossy("C2 80", chr(0x80))
    _check_lossy("DF BF", chr(0x7FF))
    _check_lossy("E0 A0 80", chr(0x800))
    _check_lossy("E0 9F BF", _ffd(3))
    _check_lossy("E1 80 80", chr(0x1000))
    _check_lossy("EC BF BF", chr(0xCFFF))
    _check_lossy("ED 80 80", chr(0xD000))
    _check_lossy("EE 80 80", chr(0xE000))
    _check_lossy("EF BF BF", chr(0xFFFF))
    _check_lossy("F0 90 80 80", chr(0x10000))
    _check_lossy("F1 80 80 80", chr(0x40000))
    _check_lossy("F3 BF BF BF", chr(0xFFFFF))
    _check_lossy("F4 80 80 80", chr(0x100000))
    _check_lossy("F4 8F BF BF", chr(0x10FFFF))
    _check_lossy("F4 90 80 80", _ffd(4))
    # F5..FF never appear (RFC 3629 section 1).
    _check_lossy("F5 80 80 80", _ffd(4))
    _check_lossy("F7 8F 80 80", _ffd(4))
    _check_lossy("FF 80", _ffd(2))
    # A byte that never starts a sequence (80..C1), followed by three bytes
    # in 80..BF: one U+FFFD each, not a four-byte sequence.
    _check_lossy("80 80 80 80", _ffd(4))
    _check_lossy("C1 BF BF BF", _ffd(4))
    # The second-byte ranges of E0 (A0..BF), ED (80..9F), F0 (90..BF) and
    # F4 (80..8F): the edges not pinned by the lead-byte vectors above.
    _check_lossy("E0 BF BF", chr(0xFFF))
    _check_lossy("E0 C0 80", _ffd(3))
    _check_lossy("ED 7F 80", _ffd(1) + chr(0x7F) + _ffd(1))
    _check_lossy("F0 BF BF BF", chr(0x3FFFF))
    _check_lossy("F0 C0 80 80", _ffd(4))
    _check_lossy("F4 7F 80 80", _ffd(1) + chr(0x7F) + _ffd(2))
    # The outside edges of 80..BF as the second byte after each lead-byte
    # range that uses it.
    _check_lossy("E1 7F 80", _ffd(1) + chr(0x7F) + _ffd(1))
    _check_lossy("EC C0 80", _ffd(3))
    _check_lossy("EE 7F 80", _ffd(1) + chr(0x7F) + _ffd(1))
    _check_lossy("EF C0 80", _ffd(3))
    _check_lossy("F1 7F 80 80", _ffd(1) + chr(0x7F) + _ffd(2))
    _check_lossy("F3 C0 80 80", _ffd(4))
    # The edges of 80..BF not yet pinned at each end of each lead-byte
    # range that uses it, and at F2, the one lead byte strictly inside
    # F1..F3.
    _check_lossy("C2 BF", chr(0xBF))
    _check_lossy("C2 C0", _ffd(2))
    _check_lossy("DF 7F", _ffd(1) + chr(0x7F))
    _check_lossy("DF 80", chr(0x7C0))
    _check_lossy("E1 BF BF", chr(0x1FFF))
    _check_lossy("E1 C0 80", _ffd(3))
    _check_lossy("EC 7F 80", _ffd(1) + chr(0x7F) + _ffd(1))
    _check_lossy("EC 80 80", chr(0xC000))
    _check_lossy("EE BF BF", chr(0xEFFF))
    _check_lossy("EE C0 80", _ffd(3))
    _check_lossy("EF 7F 80", _ffd(1) + chr(0x7F) + _ffd(1))
    _check_lossy("EF 80 80", chr(0xF000))
    _check_lossy("F1 BF BF BF", chr(0x7FFFF))
    _check_lossy("F1 C0 80 80", _ffd(4))
    _check_lossy("F2 7F 80 80", _ffd(1) + chr(0x7F) + _ffd(2))
    _check_lossy("F2 80 80 80", chr(0x80000))
    _check_lossy("F2 BF BF BF", chr(0xBFFFF))
    _check_lossy("F2 C0 80 80", _ffd(4))
    _check_lossy("F3 7F 80 80", _ffd(1) + chr(0x7F) + _ffd(2))
    _check_lossy("F3 80 80 80", chr(0xC0000))
    # The default continuation range 80..BF, second byte.
    _check_lossy("C2 7F", _ffd(1) + chr(0x7F))
    _check_lossy("DF C0", _ffd(2))
    # Third byte.
    _check_lossy("E2 82 7F", _ffd(2) + chr(0x7F))
    _check_lossy("E2 82 80", chr(0x2080))
    _check_lossy("E2 82 BF", chr(0x20BF))
    # Third and fourth bytes of a four-byte sequence.
    _check_lossy("F0 90 41 80", _ffd(2) + "A" + _ffd(1))
    _check_lossy("F0 90 7F 80", _ffd(2) + chr(0x7F) + _ffd(1))
    _check_lossy("F0 90 C0 80", _ffd(4))
    _check_lossy("F0 90 80 7F", _ffd(3) + chr(0x7F))
    _check_lossy("F0 90 80 C0", _ffd(4))
    # A sequence cut short by the end of the token, and one that ends
    # exactly there.
    _check_lossy("C3", _ffd(1))
    _check_lossy("E2 82", _ffd(2))
    _check_lossy("F0 90 80", _ffd(3))
    _check_lossy("61 C3 A9", "a" + chr(0xE9))
    _check_lossy("61 F0 90 80 80", "a" + chr(0x10000))


def test_plain_text_and_white_space_are_kept() raises:
    assert_equal(decode_header_text("  Hello\tworld  "), "  Hello\tworld  ")
    assert_equal(decode_header_text("=?UTF-8?Q?a?= b =?UTF-8?Q?c?="), "a b c")
    assert_equal(decode_header_text("=?utf-8?q?caf=c3=a9?="), "café")


def test_encode_exact() raises:
    # Q is shorter for mostly-ASCII text; a space is `_`.
    assert_equal(
        encode_header_text("Keld Jørn Simonsen"),
        "=?UTF-8?Q?Keld_J=C3=B8rn_Simonsen?=",
    )
    # B is shorter for one euro sign (E2 82 AC).
    assert_equal(encode_header_text("€"), "=?UTF-8?B?4oKs?=")
    # Characters outside the phrase set of section 5 (3) are escaped.
    assert_equal(
        encode_header_text("a=b?c_d plain text"),
        "=?UTF-8?Q?a=3Db=3Fc=5Fd_plain_text?=",
    )


def _check_round_trip(text: String) raises:
    var encoded = encode_header_text(text)
    var b = encoded.as_bytes()
    # Every word is at most 75 characters and ASCII.
    var run = 0
    for i in range(len(b)):
        assert_true(b[i] < 128)
        if b[i] == 32:
            run = 0
        else:
            run += 1
            assert_true(run <= 75, encoded)
    assert_equal(decode_header_text(encoded), text)


def test_encode_round_trip() raises:
    _check_round_trip("a")
    _check_round_trip("a b")
    _check_round_trip("ab")
    _check_round_trip("André Pirard")
    _check_round_trip("Keld Jørn Simonsen")
    var long = String("")
    for _ in range(30):
        long += "Ünïcödé ☕ "
    _check_round_trip(long)
    var euros = String("")
    for _ in range(40):
        euros += "€"
    _check_round_trip(euros)
    # Many words: none splits a three-byte sequence.
    var words = encode_header_text(euros)
    assert_true(words.find(" ") > 0, words)


def main() raises:
    test_rfc2047_section_8_from_examples()
    test_rfc2047_section_8_comment_examples()
    test_rfc2047_section_8_header_examples()
    test_rfc2231_language_suffix_is_ignored()
    test_words_kept_as_written()
    test_malformed_words_each_rule()
    test_ill_formed_utf8_outside_words_is_replaced()
    test_utf8_lead_and_continuation_byte_edges()
    test_plain_text_and_white_space_are_kept()
    test_encode_exact()
    test_encode_round_trip()
    print("test_rfc2047: OK")
