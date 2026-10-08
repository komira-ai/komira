# RFC 2047 encoded words. Decoding: every example of RFC 2047 section 8 (the
# comment examples are read as unstructured text, without the parentheses),
# the RFC 2231 section 5 language suffix, and the words a decoder must keep
# as written (section 6.3): unknown charset, malformed, not white-space
# delimited, decoded bytes that are not UTF-8 or that hold CR, LF or NUL.
# The addresses of the section 8 examples are replaced by reserved example
# names (RFC 2606); the encoded words are the RFC's bytes.
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
    test_rfc2047_section_8_comment_examples()
    test_rfc2047_section_8_header_examples()
    test_rfc2231_language_suffix_is_ignored()
    test_words_kept_as_written()
    test_plain_text_and_white_space_are_kept()
    test_encode_exact()
    test_encode_round_trip()
    print("test_rfc2047: OK")
