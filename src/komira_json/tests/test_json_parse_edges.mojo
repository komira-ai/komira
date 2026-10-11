# =============================================================================
# test_json_parse_edges.mojo: the parser's edge decisions, one byte either
# side of each bound.
# =============================================================================
#
# Each refusal is pinned by its whole message (what, line and byte column),
# so a refusal for another reason or at another offset fails; each acceptance
# by the exact bytes it yields. Cases: a literal whose length fits but whose
# bytes differ, an object key at the end of the input, an exponent followed
# by a non-digit, hex digits just outside each `\u` digit range, the 4-byte
# UTF-8 lead bytes F1..F3, a third or fourth byte above 0xBF, and a high
# surrogate followed by a `\u` escape above the low-surrogate range, and
# the line cursor queried past the end of its input.
# =============================================================================

from std.testing import assert_equal

from komira_json import parse_json_bytes, parse_json_value
from komira_json.parse import _LineCursor


def _refusal_of(doc: String) -> String:
    """The error `parse_json_value(doc)` raises, or "" if it was accepted."""
    try:
        _ = parse_json_value(doc)
    except e:
        return String(e)
    return String("")


def _refusal_of_bytes(doc: List[UInt8]) -> String:
    try:
        _ = parse_json_bytes(doc)
    except e:
        return String(e)
    return String("")


def _quoted(inner: List[UInt8]) -> List[UInt8]:
    var out: List[UInt8] = [0x22]
    for b in inner:
        out.append(b)
    out.append(0x22)
    return out^


def _assert_bytes(got: String, want: List[UInt8], label: String) raises:
    var g = got.as_bytes()
    assert_equal(len(g), len(want), label + ": length")
    for i in range(len(want)):
        assert_equal(Int(g[i]), Int(want[i]), label + ": byte " + String(i))


def test_literal_same_length_other_bytes() raises:
    # The input is long enough for the literal, so the bytes are compared
    # one by one; a mismatch at the last byte must still refuse.
    assert_equal(
        _refusal_of("trux"),
        String("JsonError: malformed literal (expected 'true') at line 1, byte column 1"),
    )
    assert_equal(
        _refusal_of("[falsx]"),
        String("JsonError: malformed literal (expected 'false') at line 1, byte column 2"),
    )
    assert_equal(
        _refusal_of("[1,\nnulL]"),
        String("JsonError: malformed literal (expected 'null') at line 2, byte column 1"),
    )
    print("  test_literal_same_length_other_bytes: PASS")


def test_key_at_end_of_input() raises:
    # A key with nothing after it: the ':' check meets the end of the input.
    assert_equal(
        _refusal_of('{"a"'),
        String("JsonError: expected ':' after object key at line 1, byte column 5"),
    )
    assert_equal(
        _refusal_of('{"a"  '),
        String("JsonError: expected ':' after object key at line 1, byte column 7"),
    )
    assert_equal(
        _refusal_of('{"a":1,"b"'),
        String("JsonError: expected ':' after object key at line 1, byte column 11"),
    )
    print("  test_key_at_end_of_input: PASS")


def test_exponent_then_non_digit() raises:
    # `e` (and a sign) followed by a byte that is not a digit, inside the
    # input: refused at that byte, not read as `1e` plus trailing content.
    assert_equal(
        _refusal_of("1ex"),
        String("JsonError: expected a digit in number exponent at line 1, byte column 3"),
    )
    assert_equal(
        _refusal_of("[1e+x]"),
        String("JsonError: expected a digit in number exponent at line 1, byte column 5"),
    )
    assert_equal(
        _refusal_of("[1E,2]"),
        String("JsonError: expected a digit in number exponent at line 1, byte column 4"),
    )
    print("  test_exponent_then_non_digit: PASS")


def test_hex_digit_range_edges() raises:
    # The byte just below and just above each of 0-9, A-F, a-f.
    var bad = List[String]()
    bad.append("/")  # 0x2F, below '0'
    bad.append(":")  # 0x3A, above '9'
    bad.append("@")  # 0x40, below 'A'
    bad.append("G")  # 0x47, above 'F'
    bad.append("`")  # 0x60, below 'a'
    bad.append("g")  # 0x67, above 'f'
    for i in range(len(bad)):
        assert_equal(
            _refusal_of(String('"\\u00') + bad[i] + '0"'),
            String("JsonError: bad hex digit in \\u escape at line 1, byte column 6"),
            String("hex digit ") + bad[i],
        )
    # Each range's own ends are digits: U+09AF and U+0FAF.
    var a: List[UInt8] = [0xE0, 0xA6, 0xAF]
    _assert_bytes(parse_json_value('"\\u09aF"').as_string(), a, "\\u09aF")
    var b: List[UInt8] = [0xE0, 0xBE, 0xAF]
    _assert_bytes(parse_json_value('"\\u0FAf"').as_string(), b, "\\u0FAf")
    print("  test_hex_digit_range_edges: PASS")


def test_four_byte_leads_f1_to_f3() raises:
    # F1, F2 and F3 lead a 4-byte sequence with any continuation bytes
    # (U+40000, U+80000, U+FFFFF): accepted and copied verbatim.
    var cases = List[List[UInt8]]()
    cases.append([0xF1, 0x80, 0x80, 0x80])
    cases.append([0xF2, 0x80, 0x80, 0x80])
    cases.append([0xF3, 0xBF, 0xBF, 0xBF])
    for i in range(len(cases)):
        var v = parse_json_bytes(_quoted(cases[i]))
        _assert_bytes(v.as_string(), cases[i], String("lead case ") + String(i))
    # Their second byte is any continuation byte, and only those.
    assert_equal(
        _refusal_of_bytes(_quoted([0xF3, 0xC0, 0x80, 0x80])),
        String("JsonError: ill-formed UTF-8 sequence in string at line 1, byte column 2"),
    )
    print("  test_four_byte_leads_f1_to_f3: PASS")


def test_later_byte_above_continuation_range() raises:
    # The third or fourth byte is 0xC0, one above the continuation range.
    var want = String("JsonError: ill-formed UTF-8 sequence in string at line 1, byte column 2")
    assert_equal(_refusal_of_bytes(_quoted([0xE1, 0x80, 0xC0])), want)
    assert_equal(_refusal_of_bytes(_quoted([0xF1, 0x80, 0x80, 0xC0])), want)
    # 0xBF itself is a continuation byte.
    var ok: List[UInt8] = [0xE1, 0xBF, 0xBF]
    _assert_bytes(parse_json_bytes(_quoted(ok)).as_string(), ok, "E1 BF BF")
    print("  test_later_byte_above_continuation_range: PASS")


def test_high_surrogate_then_above_low_range() raises:
    # A high surrogate followed by `\u` of a code unit above DFFF.
    var want = String(
        "JsonError: high surrogate \\u escape not followed by a low surrogate at line 1, byte column 2"
    )
    assert_equal(_refusal_of('"\\uD800\\uE000"'), want)
    assert_equal(_refusal_of('"\\uDBFF\\uFFFF"'), want)
    # DFFF itself is a low surrogate: U+103FF.
    var top: List[UInt8] = [0xF0, 0x90, 0x8F, 0xBF]
    _assert_bytes(parse_json_value('"\\uD800\\uDFFF"').as_string(), top, "D800 DFFF")
    print("  test_high_surrogate_then_above_low_range: PASS")


def test_line_cursor_target_past_end() raises:
    # The parser never asks past the end, so only a direct call reaches the
    # `pos < n` stop: without it the walk reads b[3] of a 3-byte input.
    var b: List[UInt8] = [0x61, 0x0A, 0x62]
    var c = _LineCursor()
    assert_equal(c.line_at(b, 1), 1)
    assert_equal(c.pos, 1)
    assert_equal(c.line_at(b, 10), 2)
    assert_equal(c.pos, 3)
    # A later query, still past the end, stays put.
    assert_equal(c.line_at(b, 11), 2)
    assert_equal(c.pos, 3)
    print("  test_line_cursor_target_past_end: PASS")


def main() raises:
    print("test_json_parse_edges")
    test_literal_same_length_other_bytes()
    test_key_at_end_of_input()
    test_exponent_then_non_digit()
    test_hex_digit_range_edges()
    test_four_byte_leads_f1_to_f3()
    test_later_byte_above_continuation_range()
    test_high_surrogate_then_above_low_range()
    test_line_cursor_target_past_end()
    print("test_json_parse_edges: ALL PASS")
