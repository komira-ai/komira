# =============================================================================
# Tests for komira_json_index/utf8_check.mojo and its three callers: the two
# string parsers and the json_extract kernel.
# =============================================================================
#
# Each ill-formed case asserts the EXACT message, so a check that refuses for
# the wrong reason, or names the wrong byte, is red as well as a check that
# does not refuse. The well-formed 2/3/4-byte cases pin that the check does
# not refuse valid text.
#
#   U1  invalid lead byte 0xFF
#   U2  stray continuation byte 0x80
#   U3  truncated 3-byte sequence at the end of the span
#   U4  lead byte followed by a non-continuation byte, at continuation
#       position 1 (C3 41, C3 C3), 2 (E2 82 41, E2 82 C3) and 3
#       (F0 9F 98 41, F0 9F 98 FF): bytes below AND above 80..BF
#   U5  overlong encoding: 2-byte leads C0 and C1, 3-byte (E0 80 AF, and
#       E0 9F BF, the highest E0 overlong) and 4-byte (F0 8F BF BF)
#   U6  UTF-16 surrogate encoded in UTF-8 (ED A0 80)
#   U7  code point above U+10FFFF (F4 90 80 80, and lead F5)
#   U8  well-formed 2/3/4-byte text accepted byte for byte, including
#       E0 A0 80 (U+0800, the lowest 3-byte code point)
#   U9  parse_string_with_escapes refuses ill-formed raw bytes
#   U10 escaped surrogates: lone high, lone low, high + non-low refused;
#       a pair decodes to the 4-byte sequence
#   U11 extract_column nulls a row whose value is ill-formed (->>, ->,
#       string, nested object slice, scalar whose FIRST or LAST byte is the
#       bad one, whole document) and keeps well-formed rows
#   U12 every continuation bound at every position of a 2-, 3- and 4-byte
#       sequence (C3 x; E2 x 82 / E2 82 x; F1 x 98 80 / F1 9F x 80 /
#       F1 9F 98 x): 0x80 and 0xBF accepted byte for byte, 0x7F and 0xC0
#       refused as "not a continuation byte". One row per bound per position,
#       so moving 0x80 or 0xBF by one in either direction is red.
#   U13 the Unicode Table 3-7 second-byte ranges at both edges, one byte
#       inside and one outside: E0 A0..BF, ED 80..9F, F0 90..BF, F4 80..8F,
#       with the exact reason for each refused row
#   U14 the Table 3-7 lead ranges at their edges: C2, DF, E1, EC, EE, EF,
#       F1, F3 accepted with second bytes 80 and BF; BF, C1, F5, F7, F8
#       refused with the exact reason; and after a well-formed 2-, 3- and
#       4-byte sequence a stray 0x80 is refused at its own index, so a lead
#       given the wrong sequence length is red
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import parse_json_path

from komira_json_index.json_extract_kernel import extract_column
from komira_json_index.parse_string import (
    parse_string,
    parse_string_raw,
    parse_string_with_escapes,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _with(prefix: String, *mid: UInt8) -> List[UInt8]:
    """`prefix`'s bytes followed by `mid`, then the byte `z`."""
    var out = _bytes(prefix)
    for i in range(len(mid)):
        out.append(mid[i])
    out.append(UInt8(ord("z")))
    return out^


def _raw_error(b: List[UInt8]) -> String:
    """The message `parse_string_raw` raises over all of `b`."""
    try:
        _ = parse_string_raw(Span(b), 0, len(b))
    except e:
        return String(e)
    return String("<no raise>")


def _esc_error(b: List[UInt8]) -> String:
    """The message `parse_string_with_escapes` raises over all of `b`."""
    try:
        _ = parse_string_with_escapes(Span(b), 0, len(b))
    except e:
        return String(e)
    return String("<no raise>")


def test_invalid_lead_byte() raises:
    assert_equal(
        _raw_error(_with("ab", 0xFF)),
        "parse_string_raw: invalid UTF-8 at byte 2: invalid lead byte 0xFF",
    )


def test_stray_continuation_byte() raises:
    assert_equal(
        _raw_error(_with("a", 0x80)),
        "parse_string_raw: invalid UTF-8 at byte 1: stray continuation byte 0x80",
    )


def test_truncated_sequence_at_end() raises:
    var b = _bytes("a")
    b.append(0xE2)
    b.append(0x82)
    assert_equal(
        _raw_error(b),
        "parse_string_raw: invalid UTF-8 at byte 1: truncated 3-byte sequence:"
        " lead byte 0xE2 has 1 of 2 continuation byte(s)",
    )
    # The END of the span is the end, not the end of the buffer: E2 82 AC is
    # complete in the buffer but the span stops after E2 82.
    var c = _bytes("a")
    c.append(0xE2)
    c.append(0x82)
    c.append(0xAC)
    var msg = String("<no raise>")
    try:
        _ = parse_string_raw(Span(c), 0, 3)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "parse_string_raw: invalid UTF-8 at byte 1: truncated 3-byte sequence:"
        " lead byte 0xE2 has 1 of 2 continuation byte(s)",
    )


def test_lead_followed_by_non_continuation() raises:
    assert_equal(
        _raw_error(_with("", 0xC3, 0x41)),
        "parse_string_raw: invalid UTF-8 at byte 0: lead byte 0xC3 is followed"
        " by 0x41, which is not a continuation byte",
    )
    assert_equal(
        _raw_error(_with("", 0xE2, 0x82, 0x41)),
        "parse_string_raw: invalid UTF-8 at byte 0: lead byte 0xE2 is followed"
        " by 0x41, which is not a continuation byte",
    )
    assert_equal(
        _raw_error(_with("", 0xF0, 0x9F, 0x98, 0x41)),
        "parse_string_raw: invalid UTF-8 at byte 0: lead byte 0xF0 is followed"
        " by 0x41, which is not a continuation byte",
    )
    # A byte ABOVE the continuation range, at positions 1, 2 and 3.
    assert_equal(
        _raw_error(_with("", 0xC3, 0xC3)),
        "parse_string_raw: invalid UTF-8 at byte 0: lead byte 0xC3 is followed"
        " by 0xC3, which is not a continuation byte",
    )
    assert_equal(
        _raw_error(_with("", 0xE2, 0x82, 0xC3)),
        "parse_string_raw: invalid UTF-8 at byte 0: lead byte 0xE2 is followed"
        " by 0xC3, which is not a continuation byte",
    )
    assert_equal(
        _raw_error(_with("", 0xF0, 0x9F, 0x98, 0xFF)),
        "parse_string_raw: invalid UTF-8 at byte 0: lead byte 0xF0 is followed"
        " by 0xFF, which is not a continuation byte",
    )


def test_overlong_encodings() raises:
    assert_equal(
        _raw_error(_with("", 0xC0, 0xAF)),
        "parse_string_raw: invalid UTF-8 at byte 0: overlong encoding: lead"
        " byte 0xC0",
    )
    assert_equal(
        _raw_error(_with("", 0xC1, 0xBF)),
        "parse_string_raw: invalid UTF-8 at byte 0: overlong encoding: lead"
        " byte 0xC1",
    )
    assert_equal(
        _raw_error(_with("x", 0xE0, 0x80, 0xAF)),
        "parse_string_raw: invalid UTF-8 at byte 1: overlong encoding: 0xE0 0x80",
    )
    assert_equal(
        _raw_error(_with("", 0xF0, 0x8F, 0xBF, 0xBF)),
        "parse_string_raw: invalid UTF-8 at byte 0: overlong encoding: 0xF0 0x8F",
    )
    # E0 9F BF is the overlong form of U+07FF: E0 must be followed by A0..BF.
    assert_equal(
        _raw_error(_with("", 0xE0, 0x9F, 0xBF)),
        "parse_string_raw: invalid UTF-8 at byte 0: overlong encoding: 0xE0 0x9F",
    )


def test_surrogate_encoded_in_utf8() raises:
    assert_equal(
        _raw_error(_with("", 0xED, 0xA0, 0x80)),
        "parse_string_raw: invalid UTF-8 at byte 0: UTF-16 surrogate encoded in"
        " UTF-8: 0xED 0xA0",
    )


def test_code_point_above_max() raises:
    assert_equal(
        _raw_error(_with("", 0xF4, 0x90, 0x80, 0x80)),
        "parse_string_raw: invalid UTF-8 at byte 0: code point above U+10FFFF:"
        " 0xF4 0x90",
    )
    assert_equal(
        _raw_error(_with("", 0xF5, 0x80, 0x80, 0x80)),
        "parse_string_raw: invalid UTF-8 at byte 0: code point above U+10FFFF:"
        " lead byte 0xF5",
    )


def test_well_formed_multibyte_accepted() raises:
    # U+00E9 (2 bytes), U+20AC (3), U+1F600 (4), and the edges U+D7FF,
    # U+E000, U+10FFFF, U+0800 that sit next to the refused ranges.
    var b = List[UInt8]()
    for x in [
        0x61, 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80,
        0xED, 0x9F, 0xBF, 0xEE, 0x80, 0x80, 0xF4, 0x8F, 0xBF, 0xBF,
        0xE0, 0xA0, 0x80,
    ]:
        b.append(UInt8(x))
    var s = parse_string_raw(Span(b), 0, len(b))
    assert_equal(s.byte_length(), len(b))
    var sb = s.as_bytes()
    for i in range(len(b)):
        assert_equal(sb[i], b[i])
    assert_equal(parse_string(Span(b), 0, 10, False), String("aé€😀"))
    assert_equal(parse_string(Span(b), 0, 10, True), String("aé€😀"))


def test_escapes_path_refuses_ill_formed_raw_bytes() raises:
    # An escape before the bad byte: the RAW span is checked, so the offset is
    # the raw index (3), not an index into the decoded output.
    var b = _bytes("\\n" + "a")
    b.append(0xED)
    b.append(0xA0)
    b.append(0x80)
    assert_equal(
        _esc_error(b),
        "parse_string_with_escapes: invalid UTF-8 at byte 3: UTF-16 surrogate"
        " encoded in UTF-8: 0xED 0xA0",
    )
    assert_equal(
        _esc_error(_with("\\t", 0xFF)),
        "parse_string_with_escapes: invalid UTF-8 at byte 2: invalid lead byte"
        " 0xFF",
    )


def test_escaped_surrogates() raises:
    assert_equal(
        _esc_error(_bytes("a\\uD83Dz")),
        "parse_string_with_escapes: high surrogate '\\u55357' is not followed"
        " by a '\\u' low surrogate",
    )
    assert_equal(
        _esc_error(_bytes("\\uDE00")),
        "parse_string_with_escapes: lone low surrogate '\\u56832' with no"
        " preceding high surrogate",
    )
    assert_equal(
        _esc_error(_bytes("\\uD83D\\u0041")),
        "parse_string_with_escapes: high surrogate is followed by '\\u65',"
        " which is not a low surrogate (DC00-DFFF)",
    )
    var pair = _bytes("\\uD83D\\uDE00")
    assert_equal(
        parse_string_with_escapes(Span(pair), 0, len(pair)), String("😀")
    )
    var bmp = _bytes("\\u00e9\\u20AC")
    assert_equal(parse_string_with_escapes(Span(bmp), 0, len(bmp)), String("é€"))


def _column(rows: List[List[UInt8]]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_byte_lists(rows)
    return Column.from_string(sa^)


def test_extract_column_nulls_ill_formed_rows() raises:
    var rows = List[List[UInt8]]()
    rows.append(_bytes('{"k":"café"}'))
    var bad_str = _bytes('{"k":"a')
    bad_str.append(0xFF)
    bad_str.append(UInt8(ord('"')))
    bad_str.append(UInt8(ord("}")))
    rows.append(bad_str^)
    var bad_obj = _bytes('{"k":{"x":"')
    bad_obj.append(0xED)
    bad_obj.append(0xA0)
    bad_obj.append(0x80)
    bad_obj.extend(_bytes('"}}'))
    rows.append(bad_obj^)
    # A bad byte outside the extracted value does not null the row.
    var bad_elsewhere = _bytes('{"o":"')
    bad_elsewhere.append(0xC0)
    bad_elsewhere.extend(_bytes('","k":"ok"}'))
    rows.append(bad_elsewhere^)
    # Scalar values: the bad byte is the FIRST byte of the value (row 4) and
    # the LAST byte of the value (row 5), so a check that skips either end of
    # the slice is red.
    var bad_scalar_first = _bytes('{"k":')
    bad_scalar_first.append(0xFF)
    bad_scalar_first.append(UInt8(ord("}")))
    rows.append(bad_scalar_first^)
    var bad_scalar_last = _bytes('{"k":1')
    bad_scalar_last.append(0xC3)
    bad_scalar_last.append(UInt8(ord("}")))
    rows.append(bad_scalar_last^)

    var col = _column(rows)
    var unq = extract_column(col, parse_json_path(String("$.k")), ArrowType.STRING, False)
    assert_false(unq.is_null_at(0))
    assert_equal(unq.as_string().get(0), String("café"))
    assert_true(unq.is_null_at(1), "->> over an ill-formed string value")
    assert_true(unq.is_null_at(2), "a nested object slice holding a surrogate")
    assert_false(unq.is_null_at(3))
    assert_equal(unq.as_string().get(3), String("ok"))
    assert_true(unq.is_null_at(4), "->> over a scalar whose first byte is 0xFF")
    assert_true(unq.is_null_at(5), "->> over a scalar whose last byte is 0xC3")

    var col2 = _column(rows)
    var raw = extract_column(col2, parse_json_path(String("$.k")), ArrowType.STRING, True)
    assert_false(raw.is_null_at(0))
    assert_equal(raw.as_string().get(0), String('"café"'))
    assert_true(raw.is_null_at(1), "-> raw slice of an ill-formed string value")
    assert_true(raw.is_null_at(2))
    assert_false(raw.is_null_at(3))
    assert_true(raw.is_null_at(4), "-> over a scalar whose first byte is 0xFF")
    assert_true(raw.is_null_at(5), "-> over a scalar whose last byte is 0xC3")

    var col3 = _column(rows)
    var whole = extract_column(col3, List[String](), ArrowType.STRING, True)
    assert_false(whole.is_null_at(0))
    assert_true(whole.is_null_at(1), "whole-document extract of an ill-formed row")
    assert_true(whole.is_null_at(2))
    assert_true(whole.is_null_at(3))
    assert_true(whole.is_null_at(4))
    assert_true(whole.is_null_at(5))


def _refused(
    label: String, b: List[UInt8], reason: String, mut bad: List[String]
):
    """Record `label` in `bad` unless `parse_string_raw` over all of `b`
    raises exactly `reason` for the sequence at byte 0."""
    var want = "parse_string_raw: invalid UTF-8 at byte 0: " + reason
    var got = _raw_error(b)
    if got != want:
        bad.append(label + " -> " + got)


def _accepted(label: String, b: List[UInt8], mut bad: List[String]):
    """Record `label` in `bad` unless `parse_string_raw` over all of `b`
    returns `b` byte for byte."""
    try:
        var s = parse_string_raw(Span(b), 0, len(b))
        var sb = s.as_bytes()
        if len(sb) != len(b):
            bad.append(label + " -> wrong length " + String(len(sb)))
            return
        for i in range(len(b)):
            if sb[i] != b[i]:
                bad.append(label + " -> byte " + String(i) + " differs")
                return
    except e:
        bad.append(label + " -> " + String(e))


def _raise_if_any(bad: List[String]) raises:
    """Raise naming EVERY failed row, so a red build shows which bounds a
    defect moved rather than only the first."""
    if len(bad) == 0:
        return
    var msg = String(len(bad)) + " row(s) failed:"
    for i in range(len(bad)):
        msg += " [" + bad[i] + "]"
    raise Error(msg)


def test_continuation_bounds_every_position() raises:
    var bad = List[String]()
    # 2-byte, continuation position 1.
    _accepted("C3 80", _with("", 0xC3, 0x80), bad)
    _accepted("C3 BF", _with("", 0xC3, 0xBF), bad)
    _refused(
        "C3 7F",
        _with("", 0xC3, 0x7F),
        "lead byte 0xC3 is followed by 0x7F, which is not a continuation byte",
        bad,
    )
    _refused(
        "C3 C0",
        _with("", 0xC3, 0xC0),
        "lead byte 0xC3 is followed by 0xC0, which is not a continuation byte",
        bad,
    )
    # 3-byte, positions 1 and 2.
    _accepted("E2 80 82", _with("", 0xE2, 0x80, 0x82), bad)
    _accepted("E2 BF 82", _with("", 0xE2, 0xBF, 0x82), bad)
    _accepted("E2 82 80", _with("", 0xE2, 0x82, 0x80), bad)
    _accepted("E2 82 BF", _with("", 0xE2, 0x82, 0xBF), bad)
    _refused(
        "E2 7F",
        _with("", 0xE2, 0x7F),
        "lead byte 0xE2 is followed by 0x7F, which is not a continuation byte",
        bad,
    )
    _refused(
        "E2 C0",
        _with("", 0xE2, 0xC0),
        "lead byte 0xE2 is followed by 0xC0, which is not a continuation byte",
        bad,
    )
    _refused(
        "E2 82 7F",
        _with("", 0xE2, 0x82, 0x7F),
        "lead byte 0xE2 is followed by 0x7F, which is not a continuation byte",
        bad,
    )
    _refused(
        "E2 82 C0",
        _with("", 0xE2, 0x82, 0xC0),
        "lead byte 0xE2 is followed by 0xC0, which is not a continuation byte",
        bad,
    )
    # 4-byte, positions 1, 2 and 3. F1 has the full 80..BF second-byte range.
    _accepted("F1 80 98 80", _with("", 0xF1, 0x80, 0x98, 0x80), bad)
    _accepted("F1 BF 98 80", _with("", 0xF1, 0xBF, 0x98, 0x80), bad)
    _accepted("F1 9F 80 80", _with("", 0xF1, 0x9F, 0x80, 0x80), bad)
    _accepted("F1 9F BF 80", _with("", 0xF1, 0x9F, 0xBF, 0x80), bad)
    _accepted("F1 9F 98 80", _with("", 0xF1, 0x9F, 0x98, 0x80), bad)
    _accepted("F1 9F 98 BF", _with("", 0xF1, 0x9F, 0x98, 0xBF), bad)
    _refused(
        "F1 7F",
        _with("", 0xF1, 0x7F),
        "lead byte 0xF1 is followed by 0x7F, which is not a continuation byte",
        bad,
    )
    _refused(
        "F1 C0",
        _with("", 0xF1, 0xC0),
        "lead byte 0xF1 is followed by 0xC0, which is not a continuation byte",
        bad,
    )
    _refused(
        "F1 9F 7F",
        _with("", 0xF1, 0x9F, 0x7F),
        "lead byte 0xF1 is followed by 0x7F, which is not a continuation byte",
        bad,
    )
    _refused(
        "F1 9F C0",
        _with("", 0xF1, 0x9F, 0xC0),
        "lead byte 0xF1 is followed by 0xC0, which is not a continuation byte",
        bad,
    )
    _refused(
        "F1 9F 98 7F",
        _with("", 0xF1, 0x9F, 0x98, 0x7F),
        "lead byte 0xF1 is followed by 0x7F, which is not a continuation byte",
        bad,
    )
    _refused(
        "F1 9F 98 C0",
        _with("", 0xF1, 0x9F, 0x98, 0xC0),
        "lead byte 0xF1 is followed by 0xC0, which is not a continuation byte",
        bad,
    )
    _raise_if_any(bad)


def test_second_byte_special_ranges() raises:
    var bad = List[String]()
    # E0 A0..BF: below is overlong, above is not a continuation byte.
    _refused(
        "E0 9F 80",
        _with("", 0xE0, 0x9F, 0x80),
        "overlong encoding: 0xE0 0x9F",
        bad,
    )
    _accepted("E0 A0 80", _with("", 0xE0, 0xA0, 0x80), bad)
    _accepted("E0 BF 80", _with("", 0xE0, 0xBF, 0x80), bad)
    _refused(
        "E0 C0",
        _with("", 0xE0, 0xC0),
        "lead byte 0xE0 is followed by 0xC0, which is not a continuation byte",
        bad,
    )
    # ED 80..9F: above is a UTF-16 surrogate (U+D800).
    _refused(
        "ED 7F",
        _with("", 0xED, 0x7F),
        "lead byte 0xED is followed by 0x7F, which is not a continuation byte",
        bad,
    )
    _accepted("ED 80 80", _with("", 0xED, 0x80, 0x80), bad)
    _accepted("ED 9F 80", _with("", 0xED, 0x9F, 0x80), bad)
    _refused(
        "ED A0 80",
        _with("", 0xED, 0xA0, 0x80),
        "UTF-16 surrogate encoded in UTF-8: 0xED 0xA0",
        bad,
    )
    # F0 90..BF: below is overlong.
    _refused(
        "F0 8F 80 80",
        _with("", 0xF0, 0x8F, 0x80, 0x80),
        "overlong encoding: 0xF0 0x8F",
        bad,
    )
    _accepted("F0 90 80 80", _with("", 0xF0, 0x90, 0x80, 0x80), bad)
    _accepted("F0 BF 80 80", _with("", 0xF0, 0xBF, 0x80, 0x80), bad)
    _refused(
        "F0 C0",
        _with("", 0xF0, 0xC0),
        "lead byte 0xF0 is followed by 0xC0, which is not a continuation byte",
        bad,
    )
    # F4 80..8F: above is beyond U+10FFFF.
    _refused(
        "F4 7F",
        _with("", 0xF4, 0x7F),
        "lead byte 0xF4 is followed by 0x7F, which is not a continuation byte",
        bad,
    )
    _accepted("F4 80 80 80", _with("", 0xF4, 0x80, 0x80, 0x80), bad)
    _accepted("F4 8F 80 80", _with("", 0xF4, 0x8F, 0x80, 0x80), bad)
    _refused(
        "F4 90 80 80",
        _with("", 0xF4, 0x90, 0x80, 0x80),
        "code point above U+10FFFF: 0xF4 0x90",
        bad,
    )
    _raise_if_any(bad)


def _refused_at(
    label: String, b: List[UInt8], at: Int, reason: String, mut bad: List[String]
):
    """Record `label` in `bad` unless `parse_string_raw` over all of `b`
    raises exactly `reason` for the sequence at byte `at`."""
    var want = (
        "parse_string_raw: invalid UTF-8 at byte " + String(at) + ": " + reason
    )
    var got = _raw_error(b)
    if got != want:
        bad.append(label + " -> " + got)


def test_lead_byte_edges() raises:
    var bad = List[String]()
    # Table 3-7 lead ranges: C2..DF opens 2 bytes, E0..EF 3, F0..F4 4. Each
    # range edge, and each lead next to E0, ED, F0, F4 (whose second byte is
    # restricted), is accepted with the full 80..BF second-byte range.
    _accepted("C2 80", _with("", 0xC2, 0x80), bad)
    _accepted("C2 BF", _with("", 0xC2, 0xBF), bad)
    _accepted("DF 80", _with("", 0xDF, 0x80), bad)
    _accepted("DF BF", _with("", 0xDF, 0xBF), bad)
    _accepted("E1 80 80", _with("", 0xE1, 0x80, 0x80), bad)
    _accepted("E1 BF BF", _with("", 0xE1, 0xBF, 0xBF), bad)
    _accepted("EC 80 80", _with("", 0xEC, 0x80, 0x80), bad)
    _accepted("EC BF BF", _with("", 0xEC, 0xBF, 0xBF), bad)
    _accepted("EE 80 80", _with("", 0xEE, 0x80, 0x80), bad)
    _accepted("EE BF BF", _with("", 0xEE, 0xBF, 0xBF), bad)
    _accepted("EF 80 80", _with("", 0xEF, 0x80, 0x80), bad)
    _accepted("EF BF BF", _with("", 0xEF, 0xBF, 0xBF), bad)
    _accepted("F1 80 80 80", _with("", 0xF1, 0x80, 0x80, 0x80), bad)
    _accepted("F3 BF BF BF", _with("", 0xF3, 0xBF, 0xBF, 0xBF), bad)
    # The bytes just outside the lead ranges.
    _refused("BF", _with("", 0xBF), "stray continuation byte 0xBF", bad)
    _refused(
        "C1 80", _with("", 0xC1, 0x80), "overlong encoding: lead byte 0xC1", bad
    )
    _refused(
        "F5 80 80 80",
        _with("", 0xF5, 0x80, 0x80, 0x80),
        "code point above U+10FFFF: lead byte 0xF5",
        bad,
    )
    _refused(
        "F7 80 80 80",
        _with("", 0xF7, 0x80, 0x80, 0x80),
        "code point above U+10FFFF: lead byte 0xF7",
        bad,
    )
    _refused("F8", _with("", 0xF8), "invalid lead byte 0xF8", bad)
    # The check resumes right after a well-formed sequence of each length, so
    # a lead given the wrong length cannot skip the stray 0x80 that follows.
    _refused_at(
        "C2 BF 80", _with("", 0xC2, 0xBF, 0x80), 2,
        "stray continuation byte 0x80", bad,
    )
    _refused_at(
        "DF BF 80", _with("", 0xDF, 0xBF, 0x80), 2,
        "stray continuation byte 0x80", bad,
    )
    _refused_at(
        "E0 A0 80 80", _with("", 0xE0, 0xA0, 0x80, 0x80), 3,
        "stray continuation byte 0x80", bad,
    )
    _refused_at(
        "EF BF BF 80", _with("", 0xEF, 0xBF, 0xBF, 0x80), 3,
        "stray continuation byte 0x80", bad,
    )
    _refused_at(
        "F0 90 80 80 80", _with("", 0xF0, 0x90, 0x80, 0x80, 0x80), 4,
        "stray continuation byte 0x80", bad,
    )
    _refused_at(
        "F4 8F BF BF 80", _with("", 0xF4, 0x8F, 0xBF, 0xBF, 0x80), 4,
        "stray continuation byte 0x80", bad,
    )
    _raise_if_any(bad)


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
    _run("test_invalid_lead_byte", test_invalid_lead_byte, failed)
    _run("test_stray_continuation_byte", test_stray_continuation_byte, failed)
    _run("test_truncated_sequence_at_end", test_truncated_sequence_at_end, failed)
    _run("test_lead_followed_by_non_continuation", test_lead_followed_by_non_continuation, failed)
    _run("test_overlong_encodings", test_overlong_encodings, failed)
    _run("test_surrogate_encoded_in_utf8", test_surrogate_encoded_in_utf8, failed)
    _run("test_code_point_above_max", test_code_point_above_max, failed)
    _run("test_well_formed_multibyte_accepted", test_well_formed_multibyte_accepted, failed)
    _run("test_escapes_path_refuses_ill_formed_raw_bytes", test_escapes_path_refuses_ill_formed_raw_bytes, failed)
    _run("test_escaped_surrogates", test_escaped_surrogates, failed)
    _run("test_extract_column_nulls_ill_formed_rows", test_extract_column_nulls_ill_formed_rows, failed)
    _run("test_continuation_bounds_every_position", test_continuation_bounds_every_position, failed)
    _run("test_second_byte_special_ranges", test_second_byte_special_ranges, failed)
    _run("test_lead_byte_edges", test_lead_byte_edges, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("utf8_check: ALL 14 CASES PASS")
