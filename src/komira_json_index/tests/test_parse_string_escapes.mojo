# =============================================================================
# Tests for parse_string.mojo's escape decoder and utf8_check.mojo's range
# checks — the arms test_utf8_check.mojo does not reach.
# =============================================================================
#
#   * every two-character escape of RFC 8259 §7 decodes to its byte, and an
#     unknown one or a trailing backslash is refused by name;
#   * a `\u` escape: every hex-digit class and the bytes just outside each,
#     a truncated escape (refused as truncated even when a digit is also
#     bad: the length check comes first), and each UTF-8 form (one to four
#     bytes, a surrogate pair for four) at both of its ends;
#   * an inverted range is refused before any byte is read;
#   * `check_utf8` refuses a range outside its input, for each bound;
#   * the private sequence helpers answer for an ASCII lead byte.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_json_index.parse_string import (
    parse_string,
    parse_string_raw,
    parse_string_with_escapes,
)
from komira_json_index.utf8_check import (
    check_utf8,
    _utf8_error_at,
    _utf8_seq_len,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _esc(s: String) raises -> String:
    var b = _bytes(s)
    return parse_string_with_escapes(Span(b), 0, len(b))


def _esc_error(s: String) -> String:
    var b = _bytes(s)
    try:
        _ = parse_string_with_escapes(Span(b), 0, len(b))
    except e:
        return String(e)
    return String("<no raise>")


def _one_byte(s: String) raises -> Int:
    """The single byte `s` decodes to."""
    var out = _esc(s)
    var ob = out.as_bytes()
    assert_equal(len(ob), 1, s)
    return Int(ob[0])


def test_every_two_character_escape() raises:
    assert_equal(_one_byte("\\\""), 0x22)
    assert_equal(_one_byte("\\\\"), 0x5C)
    assert_equal(_one_byte("\\/"), 0x2F)
    assert_equal(_one_byte("\\b"), 0x08)
    assert_equal(_one_byte("\\f"), 0x0C)
    assert_equal(_one_byte("\\n"), 0x0A)
    assert_equal(_one_byte("\\r"), 0x0D)
    assert_equal(_one_byte("\\t"), 0x09)
    # All of them in one string, with plain bytes between, decode in order.
    assert_equal(
        _esc("<\\\"|\\\\|\\/|\\n|\\r|\\t>"),
        String("<\"|\\|/|\n|\r|\t>"),
    )


def test_an_unknown_escape_is_refused() raises:
    assert_equal(
        _esc_error("ab\\x"),
        "parse_string_with_escapes: unrecognized escape '\\x'",
    )
    # Upper-case forms of the known letters are not escapes.
    assert_equal(
        _esc_error("\\N"),
        "parse_string_with_escapes: unrecognized escape '\\N'",
    )
    assert_equal(
        _esc_error("\\T"),
        "parse_string_with_escapes: unrecognized escape '\\T'",
    )


def test_a_trailing_backslash_is_refused() raises:
    assert_equal(
        _esc_error("abc\\"),
        "parse_string_with_escapes: trailing '\\' with no follow byte",
    )
    # The decoder's range ends at the backslash even though the buffer goes on.
    var b = _bytes("ab\\n")
    try:
        _ = parse_string_with_escapes(Span(b), 0, 3)
        raise Error("no raise")
    except e:
        assert_equal(
            String(e),
            "parse_string_with_escapes: trailing '\\' with no follow byte",
        )
    assert_equal(parse_string_with_escapes(Span(b), 0, 4), String("ab\n"))


def test_u_escape_hex_digit_classes() raises:
    # Every class at both of its ends, and mixed case in one escape.
    assert_equal(_esc("\\u0030\\u0039"), String("09"))
    assert_equal(_esc("\\u004a\\u004f"), String("JO"))
    assert_equal(_esc("\\u004A\\u004F"), String("JO"))
    assert_equal(_esc("\\u00Aa"), String("ª"))
    assert_equal(_esc("\\u00fF"), String("ÿ"))
    # One-byte UTF-8 form: U+0000..U+007F. U+0000 itself is not here: it
    # ends the decoded string today, komira-ai/komira#1513.
    assert_equal(_one_byte("\\u0041"), 0x41)
    assert_equal(_one_byte("\\u007F"), 0x7F)
    assert_equal(_one_byte("\\u0001"), 0x01)
    # Two-byte form starts at U+0080.
    var two = _esc("\\u0080").as_bytes()
    assert_equal(len(two), 2)
    assert_equal(Int(two[0]), 0xC2)
    assert_equal(Int(two[1]), 0x80)


def _utf8_of(s: String, want: List[Int]) raises:
    """`s` decodes to exactly the bytes `want`."""
    var got = _esc(s).as_bytes()
    assert_equal(len(got), len(want), s)
    for i in range(len(want)):
        assert_equal(Int(got[i]), want[i], s)


def test_u_escape_utf8_form_boundaries() raises:
    """Each UTF-8 form at both of its ends (RFC 3629 table 3.1): a range
    check that is off by one encodes the first code point of a form in the
    form below it, which is an invalid sequence (`E0 80` for U+0800)."""
    _utf8_of("\\u007F", [0x7F])
    _utf8_of("\\u0080", [0xC2, 0x80])
    _utf8_of("\\u07FF", [0xDF, 0xBF])
    _utf8_of("\\u0800", [0xE0, 0xA0, 0x80])
    _utf8_of("\\uD7FF", [0xED, 0x9F, 0xBF])
    _utf8_of("\\uE000", [0xEE, 0x80, 0x80])
    _utf8_of("\\uFFFF", [0xEF, 0xBF, 0xBF])
    # A surrogate pair: U+10000, the first four-byte code point, and U+10FFFF,
    # the last.
    _utf8_of("\\uD800\\uDC00", [0xF0, 0x90, 0x80, 0x80])
    _utf8_of("\\uDBFF\\uDFFF", [0xF4, 0x8F, 0xBF, 0xBF])


def test_u_escape_refuses_bytes_just_outside_each_hex_class() raises:
    # '/' ':' (around 0-9), '`' 'g' (around a-f), '@' 'G' (around A-F).
    var bad = List[String]()
    bad.append(String("/"))
    bad.append(String(":"))
    bad.append(String("`"))
    bad.append(String("g"))
    bad.append(String("@"))
    bad.append(String("G"))
    for i in range(len(bad)):
        assert_equal(
            _esc_error("\\u00" + bad[i] + "1"),
            "parse_string_with_escapes: '\\u' escape has a non-hex digit '"
            + bad[i]
            + "'",
        )
    # The bad digit in the first and the last position.
    assert_equal(
        _esc_error("\\uZ000"),
        "parse_string_with_escapes: '\\u' escape has a non-hex digit 'Z'",
    )
    assert_equal(
        _esc_error("\\u000 "),
        "parse_string_with_escapes: '\\u' escape has a non-hex digit ' '",
    )


def test_a_truncated_u_escape_is_refused() raises:
    var msg = String(
        "parse_string_with_escapes: truncated '\\u' escape — 4 hex digits"
        " required, fewer remain in the string"
    )
    assert_equal(_esc_error("\\u"), msg)
    assert_equal(_esc_error("x\\u1"), msg)
    assert_equal(_esc_error("\\u123"), msg)
    # A truncated escape whose digits are also not hex: truncation is reported.
    assert_equal(_esc_error("\\uzz"), msg)
    # A high surrogate whose low half is truncated.
    assert_equal(_esc_error("\\uD83D\\uDE0"), msg)


def _inverted(which: Int) raises:
    var b = _bytes("abcdef")
    if which == 0:
        _ = parse_string_raw(Span(b), 4, 2)
    elif which == 1:
        _ = parse_string_with_escapes(Span(b), 4, 2)
    else:
        _ = parse_string(Span(b), 4, 2, True)


def _inverted_error(which: Int) -> String:
    try:
        _inverted(which)
    except e:
        return String(e)
    return String("<no raise>")


def test_an_inverted_range_is_refused() raises:
    assert_equal(_inverted_error(0), "parse_string_raw: end < start")
    assert_equal(_inverted_error(1), "parse_string_with_escapes: end < start")
    assert_equal(_inverted_error(2), "parse_string_with_escapes: end < start")
    var b = _bytes("abcdef")
    assert_equal(parse_string_raw(Span(b), 2, 2), String(""))
    assert_equal(parse_string_with_escapes(Span(b), 2, 2), String(""))
    assert_equal(parse_string_raw(Span(b), 1, 4), String("bcd"))


def _range_error(start: Int, end: Int) -> String:
    var b = _bytes("abcd")
    try:
        check_utf8(Span(b), start, end, "probe")
    except e:
        return String(e)
    return String("<no raise>")


def test_check_utf8_refuses_a_range_outside_the_input() raises:
    # Each bound alone.
    assert_equal(
        _range_error(-1, 2),
        "probe: UTF-8 check range [-1, 2) is outside the input of 4 byte(s)",
    )
    assert_equal(
        _range_error(0, 5),
        "probe: UTF-8 check range [0, 5) is outside the input of 4 byte(s)",
    )
    assert_equal(
        _range_error(3, 2),
        "probe: UTF-8 check range [3, 2) is outside the input of 4 byte(s)",
    )
    # Two bounds broken at once: one message, the same refusal.
    assert_equal(
        _range_error(-2, -3),
        "probe: UTF-8 check range [-2, -3) is outside the input of 4 byte(s)",
    )
    # The widest and the emptiest accepted ranges.
    assert_equal(_range_error(0, 4), String("<no raise>"))
    assert_equal(_range_error(4, 4), String("<no raise>"))
    assert_equal(_range_error(0, 0), String("<no raise>"))


def test_sequence_helpers_on_ascii() raises:
    """`check_utf8` steps over ASCII itself, so these arms are reached only
    by a direct call: an ASCII lead byte is a well-formed one-byte sequence."""
    var b = List[UInt8]()
    b.append(UInt8(0x41))
    b.append(UInt8(0x7F))
    b.append(UInt8(0x00))
    for i in range(len(b)):
        assert_equal(_utf8_error_at(Span(b), i, len(b)), String(""))
        assert_equal(_utf8_seq_len(b[i]), 1)
    # The other lengths, at each lead byte boundary.
    assert_equal(_utf8_seq_len(UInt8(0xC2)), 2)
    assert_equal(_utf8_seq_len(UInt8(0xDF)), 2)
    assert_equal(_utf8_seq_len(UInt8(0xE0)), 3)
    assert_equal(_utf8_seq_len(UInt8(0xEF)), 3)
    assert_equal(_utf8_seq_len(UInt8(0xF0)), 4)
    assert_equal(_utf8_seq_len(UInt8(0xF4)), 4)


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    """Run one case; a failure is recorded, not fatal, so a red build names
    EVERY failing case rather than only the first."""
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_every_two_character_escape", test_every_two_character_escape, failed)
    _run("test_an_unknown_escape_is_refused", test_an_unknown_escape_is_refused, failed)
    _run("test_a_trailing_backslash_is_refused", test_a_trailing_backslash_is_refused, failed)
    _run("test_u_escape_hex_digit_classes", test_u_escape_hex_digit_classes, failed)
    _run("test_u_escape_utf8_form_boundaries", test_u_escape_utf8_form_boundaries, failed)
    _run("test_u_escape_refuses_bytes_just_outside_each_hex_class", test_u_escape_refuses_bytes_just_outside_each_hex_class, failed)
    _run("test_a_truncated_u_escape_is_refused", test_a_truncated_u_escape_is_refused, failed)
    _run("test_an_inverted_range_is_refused", test_an_inverted_range_is_refused, failed)
    _run("test_check_utf8_refuses_a_range_outside_the_input", test_check_utf8_refuses_a_range_outside_the_input, failed)
    _run("test_sequence_helpers_on_ascii", test_sequence_helpers_on_ascii, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("parse_string escapes: ALL CASES PASS")
