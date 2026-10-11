# Every class of invalid input, per scheme: the decoder raises the named
# error with the right position, never skips a byte, and never echoes input.

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import (
    base64_decode,
    base64_url_decode,
    base64_url_decode_nopad,
    base32_decode,
    hex_decode,
    error_kind,
)

comptime B64 = 0
comptime URL = 1
comptime URL_NOPAD = 2
comptime B32 = 3
comptime HEX = 4


def _decode(which: Int, s: Span[UInt8, _]) raises -> List[UInt8]:
    if which == B64:
        return base64_decode(s)
    if which == URL:
        return base64_url_decode(s)
    if which == URL_NOPAD:
        return base64_url_decode_nopad(s)
    if which == B32:
        return base32_decode(s)
    return hex_decode(s)


def _outcome(which: Int, s: Span[UInt8, _]) -> String:
    """`OK`, or the error message."""
    try:
        _ = _decode(which, s)
    except e:
        return String(e)
    return String("OK")


def _expect(which: Int, s: String, kind: String, position: Int) raises:
    var msg = _outcome(which, s.as_bytes())
    var ctx = String("input '") + s + String("' gave: ") + msg
    assert_true(msg != String("OK"), ctx)
    var e = Error(msg)
    assert_equal(error_kind(e), kind, ctx)
    assert_true(
        msg.endswith(String(" at position ") + String(position)), ctx
    )


def _ok(which: Int, s: String) raises:
    assert_equal(_outcome(which, s.as_bytes()), String("OK"), s)


def test_bad_character() raises:
    _expect(B64, "Zm9v!A==", "InvalidCharacter", 4)
    _expect(B64, "-_8=", "InvalidCharacter", 0)  # url symbols in standard
    _expect(URL, "+/8=", "InvalidCharacter", 0)  # standard symbols in url
    _expect(URL_NOPAD, "Zm9vY+", "InvalidCharacter", 5)
    _expect(B32, "MY0=====", "InvalidCharacter", 2)  # 0, 1, 8, 9 are not base32
    _expect(B32, "MZXW1YQ", "InvalidCharacter", 4)
    _expect(B32, "MZXW6YT!", "InvalidCharacter", 7)
    _expect(HEX, "zz", "InvalidCharacter", 0)
    _expect(HEX, "0g", "InvalidCharacter", 1)
    # The FIRST bad byte is reported, not the last.
    _expect(B64, "Zm!v!A==", "InvalidCharacter", 2)


def test_whitespace_is_rejected() raises:
    # RFC 4648 section 3.3: no line breaks or other characters are skipped.
    _expect(B64, " Zm9vYg=", "InvalidCharacter", 0)
    _expect(B64, "Zm9\nZm8=", "InvalidCharacter", 3)
    _expect(B64, "Zm9vYmFy\n", "InvalidCharacter", 8)
    # After the newline, `==` is no longer trailing: the first bad byte is `=`.
    _expect(B64, "Zm9vYg==\n", "InvalidCharacter", 6)
    _expect(URL, "Zm9v\tYg", "InvalidCharacter", 4)
    _expect(B32, "MZXW 6YTB", "InvalidCharacter", 4)
    _expect(B32, "MZXW6YTB\r\n", "InvalidCharacter", 8)
    _expect(HEX, "ab cd", "InvalidCharacter", 2)
    _expect(B64, "Zm9v YmFy", "InvalidCharacter", 4)


def test_misplaced_equals_is_a_bad_character() raises:
    _expect(B64, "Zg==Zg==", "InvalidCharacter", 2)
    _expect(B32, "MY==MY==", "InvalidCharacter", 2)
    _expect(HEX, "ab==", "InvalidCharacter", 2)  # hex has no padding


def test_bad_padding() raises:
    _expect(B64, "Zg", "InvalidPadding", 2)  # standard requires padding
    _expect(B64, "Zm9vYmE", "InvalidPadding", 7)
    _expect(B64, "Zm9vYg", "InvalidPadding", 6)
    _expect(B64, "Zg=", "InvalidPadding", 2)  # incomplete
    _expect(URL, "Zg=", "InvalidPadding", 2)
    _expect(B64, "Zm8==", "InvalidPadding", 3)
    _expect(B64, "Zm9v====", "InvalidPadding", 4)  # a whole block of padding
    _expect(B64, "Z===", "InvalidPadding", 1)
    _expect(B64, "Zm9v=", "InvalidPadding", 4)
    _expect(URL_NOPAD, "Zg==", "InvalidPadding", 2)  # RFC 7515: none allowed
    _expect(URL_NOPAD, "Zm8=", "InvalidPadding", 3)
    _expect(B32, "MY=====", "InvalidPadding", 2)
    _expect(B32, "MZXW6YTBOI=", "InvalidPadding", 10)
    _expect(B32, "MZX=====", "InvalidPadding", 3)  # 3 symbols encode nothing
    _expect(B32, "========", "InvalidPadding", 0)


def test_wrong_length() raises:
    _expect(B64, "Z", "InvalidLength", 1)
    _expect(URL, "Zm9vY", "InvalidLength", 5)
    _expect(URL_NOPAD, "Z", "InvalidLength", 1)
    _expect(B32, "M", "InvalidLength", 1)
    _expect(B32, "MZX", "InvalidLength", 3)
    _expect(B32, "MZXW6Y", "InvalidLength", 6)
    _expect(HEX, "abc", "InvalidLength", 3)
    _expect(HEX, "a", "InvalidLength", 1)


def test_non_canonical_trailing_bits_are_rejected() raises:
    # RFC 4648 section 3.5 lets a decoder reject these; this one does, so
    # each accepted input is the one canonical encoding of its output.
    _ok(B64, "Zg==")
    _expect(B64, "Zh==", "NonCanonical", 1)
    _ok(B64, "Zm8=")
    _expect(B64, "Zm9=", "NonCanonical", 2)
    _expect(URL, "Zh", "NonCanonical", 1)
    _expect(URL_NOPAD, "Zm9", "NonCanonical", 2)
    _ok(B32, "MY")
    _expect(B32, "MZ", "NonCanonical", 1)
    _expect(B32, "MZ======", "NonCanonical", 1)
    _ok(B32, "MZXW6YQ")
    _expect(B32, "MZXW6YR", "NonCanonical", 6)


def test_empty_input_is_valid() raises:
    for which in range(5):
        _ok(which, "")


def _in_alphabet(which: Int, c: Int) -> Bool:
    if which == HEX:
        return (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
    if which == B32:
        return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 50 and c <= 55)
    var base = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57)
    if which == B64:
        return base or c == 43 or c == 47
    return base or c == 45 or c == 95


def test_every_byte_value_is_classified() raises:
    # Substitute each of the 256 byte values into a valid input at a position
    # whose value bits are all used, so the only question is membership.
    var templates: List[String] = ["AAAA", "AAAA", "AAAA", "AAAAAAAA", "AA"]
    for which in range(5):
        for c in range(256):
            var b = List[UInt8]()
            var t = templates[which].as_bytes()
            for i in range(len(t)):
                b.append(t[i])
            b[1] = UInt8(c)
            var msg = _outcome(which, Span(b))
            var ctx = String("scheme ") + String(which) + String(" byte ") + String(c)
            if _in_alphabet(which, c):
                assert_equal(msg, String("OK"), ctx)
            else:
                assert_equal(error_kind(Error(msg)), String("InvalidCharacter"), ctx)
                assert_true(msg.endswith(" at position 1"), ctx)


def test_errors_do_not_echo_input() raises:
    var msg = _outcome(B64, String("Zm9vQ!==").as_bytes())
    assert_true(msg.startswith("komira_encoding.InvalidCharacter: base64_decode: "), msg)
    assert_false("!" in msg, msg)
    assert_false("Zm9v" in msg, msg)


def test_error_kind_of_foreign_error() raises:
    assert_equal(error_kind(Error("something else")), String(""))
    # The komira_encoding prefix with no colon after the kind is no
    # komira_encoding error either.
    assert_equal(error_kind(Error("komira_encoding.NoColon")), String(""))
    assert_equal(error_kind(Error("komira_encoding.")), String(""))
    # The kind is what lies between the prefix and the first colon.
    assert_equal(
        error_kind(Error("komira_encoding.Kind: f: a: b at position 0")),
        String("Kind"),
    )


def main() raises:
    test_bad_character()
    test_whitespace_is_rejected()
    test_misplaced_equals_is_a_bad_character()
    test_bad_padding()
    test_wrong_length()
    test_non_canonical_trailing_bits_are_rejected()
    test_empty_input_is_valid()
    test_every_byte_value_is_classified()
    test_errors_do_not_echo_input()
    test_error_kind_of_foreign_error()
    print("test_invalid_input: OK")
