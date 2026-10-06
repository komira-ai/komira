# =============================================================================
# test_avro_json_string_branches.mojo — every branch of json_string.mojo, driven
# directly on byte spans.
# =============================================================================
#
# test_avro_schema_json_unicode.mojo checks the behaviour end to end through
# `AvroSchema.parse` and `decode_ocf_header`. This file drives
# `decode_json_string` and `utf8_well_formed` on raw bytes, which reaches the
# branches the public path cannot: a `String` argument to `AvroSchema.parse` is
# already UTF-8, so the decoder's own UTF-8 refusal is only reachable with
# bytes, and end-of-input positions are easiest to place on a bare span.
#
# Branch -> test:
#   closing quote, result valid             B1 (every accepting case)
#   closing quote, result not UTF-8         B2 (raw C3 28 inside quotes)
#   raw run stopped by `"`                  B3 "abc"
#   raw run stopped by `\`                  B3 "ab\n"
#   raw run stopped by end of input         B3 "abc   (unterminated)
#   `\` as the last byte                    B4
#   escapes " \ / n t r b f                 B5
#   unknown escape                          B6 \x
#   \u short (fewer than 4 bytes left)      B7 "\u00
#   \u non-hex digit (_hex_digit -> -1)     B7 \u00G1
#   _hex_digit 0-9 / a-f / A-F              B8
#   lone low surrogate                      B9 \uDC00, \uDFFF
#   high: fewer than 2 bytes after it       B10 "\uD800 and "\uD800" (end)
#   high: next byte not `\`                 B10 \uD800x, \uD800"
#   high: `\` then not `u`                  B10 \uD800\n
#   high: low half short                    B10 \uD800\uDC
#   high: low half non-hex                  B10 \uD800\uDCz0
#   high: low half < DC00                   B10 \uD800\uDBFF, \uD800\u0041
#   high: low half > DFFF                   B10 \uD800\uE000
#   pair joined (both ends of the range)    B11 D800 DC00 -> U+10000, DBFF DFFF
#   _append_utf8 1/2/3/4-byte forms         B12 007F, 0080, 07FF, 0800, FFFF
#   start offset honoured                   B13
#   boundary guards, on a span that is a     B16
#     PREFIX of a larger buffer, so a `>`
#     mutant of `pos + 2 >= n` or
#     `i + need >= n` reads a planted byte
#     past the span and silently accepts
#   utf8_well_formed: every lead class,     B14
#     each continuation-range check,
#     truncation
#   utf8_to_string valid / invalid          B15
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_avro.json_string import (
    decode_json_string,
    utf8_to_string,
    utf8_well_formed,
)


def _bl(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _decode(src: List[UInt8]) raises -> String:
    var v = String("")
    var end = decode_json_string(Span(src), 0, v)
    assert_equal(end, len(src), "decoder must stop just past the closing quote")
    return v^


def _assert_decodes(lit: String, want: List[UInt8], what: String) raises:
    """`lit` is the JSON literal text, quotes included."""
    var got = _decode(_bytes(lit))
    var g = got.as_bytes()
    assert_equal(len(g), len(want), what + ": byte length")
    for i in range(len(want)):
        assert_equal(Int(g[i]), Int(want[i]), what + ": byte " + String(i))


def _assert_refused_bytes(src: List[UInt8], needle: String, what: String) raises:
    var raised = False
    try:
        var _v = _decode(src)
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            "AvroSchemaError.MALFORMED_JSON" in msg, what + ": wrong error: " + msg
        )
        assert_true(needle in msg, what + ": expected '" + needle + "' in " + msg)
    assert_true(raised, what + ": expected a refusal")


def _assert_refused(lit: String, needle: String, what: String) raises:
    _assert_refused_bytes(_bytes(lit), needle, what)


comptime HIGH_LOW = "high surrogate not followed by a \\u low surrogate"


def test_b2_result_not_utf8() raises:
    _assert_refused_bytes(_bl(0x22, 0xC3, 0x28, 0x22), "not valid UTF-8", "C3 28")
    _assert_refused_bytes(_bl(0x22, 0xFF, 0x22), "not valid UTF-8", "FF")


def test_b3_raw_runs() raises:
    _assert_decodes(String('"abc"'), _bytes(String("abc")), "run to quote")
    _assert_decodes(String('"ab\\n"'), _bl(0x61, 0x62, 0x0A), "run to escape")
    _assert_decodes(String('"\\nab"'), _bl(0x0A, 0x61, 0x62), "escape then run")
    _assert_decodes(String('""'), _bl(), "empty")
    _assert_refused(String('"abc'), "unterminated string", "run to end")
    _assert_refused(String('"'), "unterminated string", "quote only")


def test_b4_backslash_last() raises:
    _assert_refused(String('"ab\\'), "bad escape", "trailing backslash")


def test_b5_simple_escapes() raises:
    _assert_decodes(
        String('"\\"\\\\\\/\\n\\t\\r\\b\\f"'),
        _bl(0x22, 0x5C, 0x2F, 0x0A, 0x09, 0x0D, 0x08, 0x0C),
        "simple escapes",
    )


def test_b6_unknown_escape() raises:
    _assert_refused(String('"\\x"'), "unknown escape", "\\x")
    _assert_refused(String('"\\U0041"'), "unknown escape", "\\U")


def test_b7_short_and_bad_hex() raises:
    _assert_refused(String('"\\u00'), "short \\u escape", "short at end")
    _assert_refused(String('"\\u"'), "short \\u escape", "\\u then quote, end")
    _assert_refused(String('"\\u00G1"'), "non-hex digit", "G")
    _assert_refused(String('"\\u00g1"'), "non-hex digit", "g")
    _assert_refused(String('"\\u/000"'), "non-hex digit", "/ below 0")
    _assert_refused(String('"\\u:000"'), "non-hex digit", ": above 9")
    _assert_refused(String('"\\u@000"'), "non-hex digit", "@ below A")
    _assert_refused(String('"\\u`000"'), "non-hex digit", "` below a")


def test_b8_hex_digit_classes() raises:
    _assert_decodes(String('"\\u0039"'), _bl(0x39), "0-9")
    _assert_decodes(String('"\\u004a"'), _bl(0x4A), "a-f")
    _assert_decodes(String('"\\u004A"'), _bl(0x4A), "A-F")
    _assert_decodes(String('"\\u004f"'), _bl(0x4F), "f")
    _assert_decodes(String('"\\u004F"'), _bl(0x4F), "F")


def test_b9_lone_low() raises:
    _assert_refused(String('"\\uDC00"'), "low surrogate", "DC00")
    _assert_refused(String('"\\uDFFF"'), "low surrogate", "DFFF")
    _assert_refused(String('"\\uDE00\\uD83D"'), "low surrogate", "reversed")


def test_b10_bad_high() raises:
    _assert_refused(String('"\\uD800'), HIGH_LOW, "end of input")
    _assert_refused(String('"\\uD800"'), HIGH_LOW, "quote after high")
    _assert_refused(String('"\\uD800x"'), HIGH_LOW, "raw char after high")
    _assert_refused(String('"\\uD800\\n"'), HIGH_LOW, "\\n after high")
    _assert_refused(String('"\\uD800\\uDC'), "short \\u escape", "short low")
    _assert_refused(String('"\\uD800\\uDCz0"'), "non-hex digit", "bad hex low")
    _assert_refused(String('"\\uD800\\uDBFF"'), HIGH_LOW, "high + high")
    _assert_refused(String('"\\uD800\\u0041"'), HIGH_LOW, "high + BMP")
    _assert_refused(String('"\\uD800\\uE000"'), HIGH_LOW, "high + E000")


def test_b11_pairs() raises:
    _assert_decodes(
        String('"\\uD800\\uDC00"'), _bl(0xF0, 0x90, 0x80, 0x80), "U+10000"
    )
    _assert_decodes(
        String('"\\uDBFF\\uDFFF"'), _bl(0xF4, 0x8F, 0xBF, 0xBF), "U+10FFFF"
    )
    _assert_decodes(
        String('"\\uD83D\\uDE00\\uD83D\\uDE00"'),
        _bl(0xF0, 0x9F, 0x98, 0x80, 0xF0, 0x9F, 0x98, 0x80),
        "two pairs back to back",
    )


def test_b12_utf8_encode_widths() raises:
    _assert_decodes(String('"\\u0000"'), _bl(0x00), "U+0000")
    _assert_decodes(String('"\\u007F"'), _bl(0x7F), "U+007F")
    _assert_decodes(String('"\\u0080"'), _bl(0xC2, 0x80), "U+0080")
    _assert_decodes(String('"\\u07FF"'), _bl(0xDF, 0xBF), "U+07FF")
    _assert_decodes(String('"\\u0800"'), _bl(0xE0, 0xA0, 0x80), "U+0800")
    _assert_decodes(String('"\\uD7FF"'), _bl(0xED, 0x9F, 0xBF), "U+D7FF")
    _assert_decodes(String('"\\uFFFF"'), _bl(0xEF, 0xBF, 0xBF), "U+FFFF")


def test_b13_start_offset() raises:
    var src = _bytes(String('xx"hi"yy'))
    var v = String("")
    var end = decode_json_string(Span(src), 2, v)
    assert_equal(v, String("hi"))
    assert_equal(end, 6)


def test_b14_utf8_well_formed() raises:
    # Accepted: one sequence from each lead class, at both edges of its
    # continuation range where the range is narrowed.
    assert_true(utf8_well_formed(Span(_bl())), "empty")
    assert_true(utf8_well_formed(Span(_bl(0x41, 0x7F))), "ASCII")
    assert_true(utf8_well_formed(Span(_bl(0xC2, 0x80))), "C2 80")
    assert_true(utf8_well_formed(Span(_bl(0xDF, 0xBF))), "DF BF")
    assert_true(utf8_well_formed(Span(_bl(0xE0, 0xA0, 0x80))), "E0 A0 80")
    assert_true(utf8_well_formed(Span(_bl(0xE1, 0x80, 0x80))), "E1 80 80")
    assert_true(utf8_well_formed(Span(_bl(0xEC, 0xBF, 0xBF))), "EC BF BF")
    assert_true(utf8_well_formed(Span(_bl(0xED, 0x9F, 0xBF))), "ED 9F BF")
    assert_true(utf8_well_formed(Span(_bl(0xEE, 0x80, 0x80))), "EE 80 80")
    assert_true(utf8_well_formed(Span(_bl(0xEF, 0xBF, 0xBF))), "EF BF BF")
    assert_true(utf8_well_formed(Span(_bl(0xF0, 0x90, 0x80, 0x80))), "F0 90")
    assert_true(utf8_well_formed(Span(_bl(0xF1, 0x80, 0x80, 0x80))), "F1")
    assert_true(utf8_well_formed(Span(_bl(0xF3, 0xBF, 0xBF, 0xBF))), "F3")
    assert_true(utf8_well_formed(Span(_bl(0xF4, 0x8F, 0xBF, 0xBF))), "F4 8F")
    # Refused: a lead outside C2..F4.
    assert_false(utf8_well_formed(Span(_bl(0x80))), "lone continuation")
    assert_false(utf8_well_formed(Span(_bl(0xBF))), "BF lead")
    assert_false(utf8_well_formed(Span(_bl(0xC0, 0xAF))), "overlong C0")
    assert_false(utf8_well_formed(Span(_bl(0xC1, 0xBF))), "overlong C1")
    assert_false(utf8_well_formed(Span(_bl(0xF5, 0x80, 0x80, 0x80))), "F5")
    assert_false(utf8_well_formed(Span(_bl(0xFF))), "FF")
    # Refused: the first continuation outside its narrowed range.
    assert_false(utf8_well_formed(Span(_bl(0xE0, 0x9F, 0xBF))), "E0 overlong")
    assert_false(utf8_well_formed(Span(_bl(0xED, 0xA0, 0x80))), "ED surrogate")
    assert_false(utf8_well_formed(Span(_bl(0xF0, 0x8F, 0xBF, 0xBF))), "F0 low")
    assert_false(utf8_well_formed(Span(_bl(0xF4, 0x90, 0x80, 0x80))), "F4 high")
    assert_false(utf8_well_formed(Span(_bl(0xC2, 0x7F))), "C2 below 80")
    assert_false(utf8_well_formed(Span(_bl(0xC2, 0xC0))), "C2 above BF")
    # Refused: a later continuation byte out of range, below and above.
    assert_false(utf8_well_formed(Span(_bl(0xE1, 0x80, 0x41))), "E1 80 41")
    assert_false(utf8_well_formed(Span(_bl(0xE1, 0x80, 0xC0))), "E1 80 C0")
    assert_false(
        utf8_well_formed(Span(_bl(0xF1, 0x80, 0x80, 0x7F))), "F1 last low"
    )
    # Refused: truncated sequences (the lead is the last byte, or one short).
    assert_false(utf8_well_formed(Span(_bl(0xC3))), "C3 at end")
    assert_false(utf8_well_formed(Span(_bl(0xE2, 0x82))), "E2 82 at end")
    assert_false(utf8_well_formed(Span(_bl(0xF0, 0x9F, 0x98))), "F0 9F 98 end")
    # A good sequence followed by a bad one: the loop advances correctly.
    assert_false(utf8_well_formed(Span(_bl(0xC3, 0xBC, 0x80))), "good then bad")


def test_b15_utf8_to_string() raises:
    var good = _bl(0x61, 0xC3, 0xBC)
    assert_equal(utf8_to_string(Span(good), String("ctx")), String("aü"))
    var bad = _bl(0x61, 0xC3)
    var raised = False
    try:
        var _s = utf8_to_string(Span(bad), String("PREFIX: thing"))
    except e:
        raised = True
        assert_true(
            String(e).startswith("PREFIX: thing: not valid UTF-8"), String(e)
        )
    assert_true(raised, "utf8_to_string accepted invalid UTF-8")


def _prefix_decode_refused(full: List[UInt8], n: Int, needle: String, what: String) raises:
    var raised = False
    try:
        var v = String("")
        var _end = decode_json_string(Span(full)[:n], 0, v)
    except e:
        raised = True
        assert_true(needle in String(e), what + ": wrong error: " + String(e))
    assert_true(raised, what + ": expected a refusal")


def test_b16_boundaries_on_prefix_spans() raises:
    # `"\uD800\` ends right after the backslash; past the span lie
    # `uDC00"`, so reading beyond the end would find a valid low half.
    var full = _bytes(String('"\\uD800\\uDC00"'))
    _prefix_decode_refused(full, 8, HIGH_LOW, "high + lone backslash at end")
    # `"\uD800` ends on the last hex digit; past it `\uDC00"`.
    _prefix_decode_refused(full, 7, HIGH_LOW, "high at end, pair beyond")
    # The whole buffer is a valid pair (control: the prefix is what refuses).
    var v = String("")
    var _end = decode_json_string(Span(full), 0, v)
    assert_equal(len(v.as_bytes()), 4, "pair in full buffer")

    # utf8_well_formed: the span ends one byte short of a sequence; the
    # byte past the span is a valid continuation.
    var u = _bl(0xC3, 0xBC)
    assert_false(utf8_well_formed(Span(u)[:1]), "C3 | BC")
    var u3 = _bl(0xE2, 0x82, 0xAC)
    assert_false(utf8_well_formed(Span(u3)[:2]), "E2 82 | AC")
    var u4 = _bl(0xF0, 0x9F, 0x98, 0x80)
    assert_false(utf8_well_formed(Span(u4)[:3]), "F0 9F 98 | 80")
    assert_true(utf8_well_formed(Span(u4)), "full F0 9F 98 80")


def main() raises:
    test_b2_result_not_utf8()
    test_b3_raw_runs()
    test_b4_backslash_last()
    test_b5_simple_escapes()
    test_b6_unknown_escape()
    test_b7_short_and_bad_hex()
    test_b8_hex_digit_classes()
    test_b9_lone_low()
    test_b10_bad_high()
    test_b11_pairs()
    test_b12_utf8_encode_widths()
    test_b13_start_offset()
    test_b14_utf8_well_formed()
    test_b15_utf8_to_string()
    test_b16_boundaries_on_prefix_spans()
    print("test_avro_json_string_branches: ALL PASS")
