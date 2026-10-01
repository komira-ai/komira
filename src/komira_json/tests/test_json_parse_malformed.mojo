# =============================================================================
# test_json_parse_malformed.mojo: everything outside RFC 8259 is refused.
# =============================================================================
#
# Each case asserts the parse RAISES and that the message names the right
# problem (a refusal for the wrong reason would hide a parser bug), plus the
# hostile-nesting case: a million `[` must be a clean refusal, not a stack
# overflow.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_json import (
    JSON_DEFAULT_MAX_DEPTH,
    JSON_MAX_DEPTH,
    parse_json_bytes,
    parse_json_value,
)


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


def _check(msg: String, needle: String, label: String) raises:
    assert_true(
        msg.find(String("JsonError: ")) == 0 and msg.find(needle) >= 0,
        label + ": expected a refusal naming '" + needle + "', got: '" + msg + "'",
    )


def _refused(doc: String, needle: String) raises:
    _check(_refusal_of(doc), needle, String("doc ") + doc)


def test_document_shape() raises:
    _refused("", "unexpected end of input")
    _refused("   \n ", "unexpected end of input")
    _refused("1 2", "trailing content")
    _refused('{"a":1}}', "trailing content")
    _refused("[1] x", "trailing content")
    _refused("nul", "expected 'null'")
    _refused("True", "unexpected character")
    _refused("truex", "trailing content")
    _refused("'a'", "unexpected character")
    # A byte-order mark is not whitespace.
    var bom: List[UInt8] = [0xEF, 0xBB, 0xBF, 0x31]
    _check(_refusal_of_bytes(bom), "unexpected character", "BOM")
    # The location: line 2, byte column 3.
    _refused("[1,\n  x]", "at line 2, byte column 3")
    print("  test_document_shape: PASS")


def test_numbers() raises:
    _refused("01", "leading zero")
    _refused("-01", "leading zero")
    _refused("00", "leading zero")
    _refused("+1", "unexpected character")
    _refused(".5", "unexpected character")
    _refused("-", "expected a digit")
    _refused("-a", "expected a digit")
    _refused("1.", "after '.'")
    _refused("1.e5", "after '.'")
    _refused("1e", "exponent")
    _refused("1e+", "exponent")
    _refused("NaN", "unexpected character")
    _refused("Infinity", "unexpected character")
    _refused("-Infinity", "expected a digit")
    _refused("0x10", "trailing content")
    _refused("1.5.2", "trailing content")
    _refused("[1e5e5]", "expected ',' or ']'")
    print("  test_numbers: PASS")


def test_strings() raises:
    _refused('"abc', "unterminated string")
    _refused('"abc\\', "unterminated escape")
    _refused('"\\x41"', "invalid escape")
    _refused('"\\a"', "invalid escape")
    _refused("\"\\'\"", "invalid escape")
    _refused('"\\u12"', "\\u escape")
    _refused('"\\u12G4"', "bad hex digit")
    # Raw control characters must be escaped.
    _refused(String('"a') + chr(0x0A) + 'b"', "unescaped control character")
    _refused(String('"a') + chr(0x09) + 'b"', "unescaped control character")
    _refused(String('"') + chr(0x01) + '"', "unescaped control character")
    print("  test_strings: PASS")


def test_lone_and_broken_surrogates() raises:
    _refused('"\\ud834"', "lone high surrogate")
    _refused('"\\ud834x"', "lone high surrogate")
    _refused('"\\ud834\\n"', "lone high surrogate")
    _refused('"\\udd1e"', "lone low surrogate")
    _refused('"\\udd1e\\ud834"', "lone low surrogate")  # reversed pair
    _refused('"\\ud834\\ud834"', "not followed by a low surrogate")
    _refused('"\\ud834\\u0041"', "not followed by a low surrogate")
    _refused('"\\ud834\\udd"', "\\u escape")
    print("  test_lone_and_broken_surrogates: PASS")


def _quoted(var inner: List[UInt8]) -> List[UInt8]:
    var out: List[UInt8] = [0x22]
    for b in inner:
        out.append(b)
    out.append(0x22)
    return out^


def test_ill_formed_utf8() raises:
    var cases = List[List[UInt8]]()
    cases.append([0x80])  # lone continuation byte
    cases.append([0xC0, 0xAF])  # overlong '/'
    cases.append([0xC1, 0xBF])  # overlong
    cases.append([0xE0, 0x80, 0xAF])  # overlong 3-byte
    cases.append([0xF0, 0x80, 0x80, 0xAF])  # overlong 4-byte
    cases.append([0xED, 0xA0, 0x80])  # encoded surrogate U+D800
    cases.append([0xF4, 0x90, 0x80, 0x80])  # above U+10FFFF
    cases.append([0xF5, 0x80, 0x80, 0x80])  # invalid lead
    cases.append([0xFF])  # invalid lead
    cases.append([0xC3, 0x28])  # bad continuation
    cases.append([0xE2, 0x82])  # truncated before the closing quote
    for i in range(len(cases)):
        var msg = _refusal_of_bytes(_quoted(cases[i].copy()))
        _check(msg, "UTF-8", String("utf-8 case ") + String(i))
    # Truncated at end of input.
    var trunc: List[UInt8] = [0x22, 0xE2, 0x82]
    _check(_refusal_of_bytes(trunc), "UTF-8", "utf-8 truncated at end")
    # Non-ASCII outside a string.
    var outside: List[UInt8] = [0xC3, 0xA9]
    _check(_refusal_of_bytes(outside), "unexpected character", "outside")
    print("  test_ill_formed_utf8: PASS")


def test_arrays_and_objects() raises:
    _refused("[1,]", "unexpected character")
    _refused("[,1]", "unexpected character")
    _refused("[1 2]", "expected ',' or ']'")
    _refused("[1", "unterminated array")
    _refused("[", "unexpected end of input")
    _refused('{"a":1,}', "expected a string object key")
    _refused("{a:1}", "expected a string object key")
    _refused("{1:1}", "expected a string object key")
    _refused('{"a" 1}', "expected ':'")
    _refused('{"a":}', "unexpected character")
    _refused('{"a":1 "b":2}', "expected ',' or '}'")
    _refused('{"a":1', "unterminated object")
    _refused("{", "expected a string object key")
    _refused("]", "unexpected character")
    print("  test_arrays_and_objects: PASS")


def _brackets(n: Int) -> String:
    var b = List[UInt8](capacity=n)
    for _ in range(n):
        b.append(0x5B)  # '['
    return String(unsafe_from_utf8=Span(b))


def test_nesting_limit() raises:
    # One past the default limit is refused, naming the limit.
    var s = _brackets(JSON_DEFAULT_MAX_DEPTH + 1) + "1"
    for _ in range(JSON_DEFAULT_MAX_DEPTH + 1):
        s += "]"
    _refused(s, String("nesting deeper than the limit of ") + String(JSON_DEFAULT_MAX_DEPTH))
    # Objects count too.
    var o = String("")
    for _ in range(JSON_DEFAULT_MAX_DEPTH + 1):
        o += '{"a":'
    _refused(o, "nesting deeper than the limit")
    # Hostile input: a million unclosed brackets is a clean refusal at the
    # limit, not a stack overflow.
    _refused(_brackets(1000000), "nesting deeper than the limit")
    # An explicit limit.
    var msg = String("")
    try:
        _ = parse_json_value("[[1]]", 1)
    except e:
        msg = String(e)
    _check(msg, "nesting deeper than the limit of 1", "limit 1")
    msg = String("")
    try:
        _ = parse_json_value("[]", 0)
    except e:
        msg = String(e)
    _check(msg, "nesting deeper than the limit of 0", "limit 0")
    msg = String("")
    try:
        _ = parse_json_value("1", -1)
    except e:
        msg = String(e)
    _check(msg, "max_depth must not be negative", "limit -1")
    # A limit above the cap is refused before any input is read: destroying
    # a parsed tree recurses per level, so the depth may not be unbounded.
    msg = String("")
    try:
        _ = parse_json_value("1", JSON_MAX_DEPTH + 1)
    except e:
        msg = String(e)
    _check(
        msg,
        String("max_depth ")
        + String(JSON_MAX_DEPTH + 1)
        + " is above the maximum of "
        + String(JSON_MAX_DEPTH),
        "limit above the cap",
    )
    # At the cap, a document that is JSON_MAX_DEPTH deep and then fails
    # (trailing byte) unwinds the whole tree it built: a clean refusal.
    var deep = _brackets(JSON_MAX_DEPTH)
    for _ in range(JSON_MAX_DEPTH):
        deep += "]"
    msg = String("")
    try:
        _ = parse_json_value(deep + "x", JSON_MAX_DEPTH)
    except e:
        msg = String(e)
    _check(msg, "trailing content", "a cap-deep document then a stray byte")
    print("  test_nesting_limit: PASS")


def main() raises:
    print("test_json_parse_malformed")
    test_document_shape()
    test_numbers()
    test_strings()
    test_lone_and_broken_surrogates()
    test_ill_formed_utf8()
    test_arrays_and_objects()
    test_nesting_limit()
    print("test_json_parse_malformed: ALL PASS")
