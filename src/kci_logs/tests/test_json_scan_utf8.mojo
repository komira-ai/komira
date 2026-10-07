# =============================================================================
# kci_logs/tests/test_json_scan_utf8.mojo — `json_scan_string` repairs caller
#   bytes to well-formed UTF-8 before they become a `String`.
# =============================================================================
#
# `json_scan_string` takes a `Span[UInt8]` from its caller, so the bytes it
# scans can be anything. Before the repair it built the value with an
# unchecked `String(unsafe_from_utf8=...)`, and an ill-formed byte became a
# `String` that breaks the String invariant. This package never raises, so the
# contract is REPLACE, not refuse: each maximal ill-formed subpart is one
# U+FFFD (Unicode §3.9, "U+FFFD Substitution of Maximal Subparts").
#
# Every case asserts the EXACT output bytes, so a repair that drops a byte,
# keeps an ill-formed byte, or substitutes the wrong number of U+FFFD is red.
#
#   J1  invalid lead byte 0xFF                         -> 1 x U+FFFD
#   J2  stray continuation byte 0x80                   -> 1 x U+FFFD
#   J3  truncated 3-byte sequence before the quote     -> 1 x U+FFFD
#   J4  overlong C0 AF -> 2, C1 BF -> 2, E0 80 AF -> 3, F0 8F BF BF -> 4,
#       and E0 9F BF -> 3 (the highest E0 overlong; pins the A0 bound)
#   J5  surrogate encoded in UTF-8, ED A0 80           -> 3 x U+FFFD
#   J6  above U+10FFFF, F4 90 80 80 -> 4, lead F5 -> 1 each
#   J7  well-formed 2/3/4-byte text is kept byte for byte, including
#       E0 A0 80 (U+0800, the lowest 3-byte code point)
#   J8  a bad byte after an escape is repaired; the escape still decodes
#   J9  a non-continuation byte at continuation position 3 (F0 9F 98 41)
#       ends a 3-byte subpart and is kept: U+FFFD then `A`
#   J10 a byte ABOVE the continuation range at position 2 (E2 82 C3 A9)
#       or 3 (F0 9F 98 FF) ends the subpart; a following lead byte is kept
#   J11 every continuation bound at every position of a 2-, 3- and 4-byte
#       sequence (C3 x; E2 x 82 / E2 82 x; F1 x 98 80 / F1 9F x 80 /
#       F1 9F 98 x): 0x80 and 0xBF kept byte for byte; 0x7F ends the subpart
#       and is kept (U+FFFD then DEL); 0xC0 ends the subpart and is its own
#       subpart (U+FFFD U+FFFD). One row per bound per position, so moving
#       0x80 or 0xBF by one in either direction is red.
#   J12 the Unicode Table 3-7 second-byte ranges at both edges, one byte
#       inside and one outside: E0 A0..BF, ED 80..9F, F0 90..BF, F4 80..8F.
#       A second byte outside its range ends a one-byte subpart, so each
#       following continuation byte is a subpart of its own.
#   J13 the Table 3-7 lead ranges at their edges: C2, DF, E1, EC, EE, EF,
#       F1, F3 kept with second bytes 80 and BF; BF, C1, F5, F8 each a
#       one-byte subpart; and after a well-formed 2-, 3- and 4-byte sequence
#       a following 0x80 is its own U+FFFD, so a wrong sequence length is red
#   Every case also asserts the scan ends just after the closing quote.
# =============================================================================

from std.testing import assert_equal

from kci_logs.json_scan import json_scan_string

comptime R = "�"  # U+FFFD, the bytes EF BF BD


def _quoted(head: String, *mid: UInt8) -> List[UInt8]:
    """`"` + `head` + `mid` + `z"`: a JSON string around the bytes under test."""
    var out = List[UInt8]()
    out.append(UInt8(ord('"')))
    var hb = head.as_bytes()
    for i in range(len(hb)):
        out.append(hb[i])
    for i in range(len(mid)):
        out.append(mid[i])
    out.append(UInt8(ord("z")))
    out.append(UInt8(ord('"')))
    return out^


def _scan(b: List[UInt8]) raises -> String:
    var out = String()
    var end = json_scan_string(Span(b), 0, out)
    assert_equal(end, len(b), "the scan must end after the closing quote")
    return out^


def test_invalid_lead_byte() raises:
    assert_equal(_scan(_quoted("a", 0xFF)), String("a") + R + "z")


def test_stray_continuation_byte() raises:
    assert_equal(_scan(_quoted("a", 0x80)), String("a") + R + "z")


def test_truncated_sequence() raises:
    # E2 82 is the start of U+20AC with its last byte missing: one subpart.
    assert_equal(_scan(_quoted("a", 0xE2, 0x82)), String("a") + R + "z")
    # And right before the closing quote, with no byte after it.
    var b = List[UInt8]()
    b.append(UInt8(ord('"')))
    b.append(0xF0)
    b.append(0x9F)
    b.append(0x98)
    b.append(UInt8(ord('"')))
    assert_equal(_scan(b), String(R))


def test_overlong_encodings() raises:
    assert_equal(_scan(_quoted("", 0xC0, 0xAF)), String(R) + R + "z")
    assert_equal(_scan(_quoted("", 0xC1, 0xBF)), String(R) + R + "z")
    assert_equal(_scan(_quoted("", 0xE0, 0x80, 0xAF)), String(R) + R + R + "z")
    assert_equal(
        _scan(_quoted("", 0xF0, 0x8F, 0xBF, 0xBF)), String(R) + R + R + R + "z"
    )
    # E0 9F BF is the overlong form of U+07FF: E0 must be followed by A0..BF.
    assert_equal(_scan(_quoted("", 0xE0, 0x9F, 0xBF)), String(R) + R + R + "z")


def test_surrogate_encoded_in_utf8() raises:
    assert_equal(_scan(_quoted("", 0xED, 0xA0, 0x80)), String(R) + R + R + "z")


def test_code_point_above_max() raises:
    assert_equal(
        _scan(_quoted("", 0xF4, 0x90, 0x80, 0x80)), String(R) + R + R + R + "z"
    )
    assert_equal(_scan(_quoted("", 0xF5, 0x80)), String(R) + R + "z")


def test_well_formed_multibyte_kept() raises:
    # U+00E9, U+20AC, U+1F600 and the edges U+D7FF, U+E000, U+10FFFF, U+0800.
    var b = _quoted(
        "",
        0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80,
        0xED, 0x9F, 0xBF, 0xEE, 0x80, 0x80, 0xF4, 0x8F, 0xBF, 0xBF,
        0xE0, 0xA0, 0x80,
    )
    var s = _scan(b)
    assert_equal(s.byte_length(), len(b) - 2)
    var sb = s.as_bytes()
    for i in range(len(sb)):
        assert_equal(sb[i], b[i + 1])
    assert_equal(_scan(_quoted("é€😀")), String("é€😀z"))


def test_escape_then_bad_byte() raises:
    assert_equal(_scan(_quoted("\\n", 0xFF)), String("\n") + R + "z")
    # A backslash before a multi-byte character passes the character through.
    assert_equal(_scan(_quoted("\\é")), String("éz"))


def test_non_continuation_at_position_3() raises:
    assert_equal(_scan(_quoted("", 0xF0, 0x9F, 0x98, 0x41)), String(R) + "Az")


def test_above_range_continuation() raises:
    # C3 is above the continuation range at position 2: E2 82 is one subpart,
    # and C3 A9 (U+00E9) after it is kept.
    assert_equal(
        _scan(_quoted("", 0xE2, 0x82, 0xC3, 0xA9)), String(R) + "éz"
    )
    # FF at position 3: F0 9F 98 is one subpart, FF is another.
    assert_equal(
        _scan(_quoted("", 0xF0, 0x9F, 0x98, 0xFF)), String(R) + R + "z"
    )


def _repaired(
    label: String, b: List[UInt8], want: String, mut bad: List[String]
):
    """Record `label` in `bad` unless `json_scan_string` over `b` gives
    exactly `want` and ends after the closing quote."""
    var out = String()
    var end = json_scan_string(Span(b), 0, out)
    if end != len(b):
        bad.append(label + " -> scan ended at " + String(end))
    elif out != want:
        bad.append(label + " -> " + out)


def _kept(label: String, b: List[UInt8], mut bad: List[String]):
    """Record `label` in `bad` unless `json_scan_string` over `b` returns the
    bytes between the quotes unchanged."""
    var out = String()
    var end = json_scan_string(Span(b), 0, out)
    var ob = out.as_bytes()
    if end != len(b):
        bad.append(label + " -> scan ended at " + String(end))
        return
    if len(ob) != len(b) - 2:
        bad.append(label + " -> wrong length " + String(len(ob)))
        return
    for i in range(len(ob)):
        if ob[i] != b[i + 1]:
            bad.append(label + " -> byte " + String(i) + " differs")
            return


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
    _kept("C3 80", _quoted("", 0xC3, 0x80), bad)
    _kept("C3 BF", _quoted("", 0xC3, 0xBF), bad)
    _repaired(
        "C3 7F", _quoted("", 0xC3, 0x7F), String(R) + chr(0x7F) + "z", bad
    )
    _repaired(
        "C3 C0", _quoted("", 0xC3, 0xC0), String(R) + R + "z", bad
    )
    _kept("E2 80 82", _quoted("", 0xE2, 0x80, 0x82), bad)
    _kept("E2 BF 82", _quoted("", 0xE2, 0xBF, 0x82), bad)
    _kept("E2 82 80", _quoted("", 0xE2, 0x82, 0x80), bad)
    _kept("E2 82 BF", _quoted("", 0xE2, 0x82, 0xBF), bad)
    _repaired(
        "E2 7F", _quoted("", 0xE2, 0x7F), String(R) + chr(0x7F) + "z", bad
    )
    _repaired(
        "E2 C0", _quoted("", 0xE2, 0xC0), String(R) + R + "z", bad
    )
    _repaired(
        "E2 82 7F", _quoted("", 0xE2, 0x82, 0x7F), String(R) + chr(0x7F) + "z", bad
    )
    _repaired(
        "E2 82 C0", _quoted("", 0xE2, 0x82, 0xC0), String(R) + R + "z", bad
    )
    _kept("F1 80 98 80", _quoted("", 0xF1, 0x80, 0x98, 0x80), bad)
    _kept("F1 BF 98 80", _quoted("", 0xF1, 0xBF, 0x98, 0x80), bad)
    _kept("F1 9F 80 80", _quoted("", 0xF1, 0x9F, 0x80, 0x80), bad)
    _kept("F1 9F BF 80", _quoted("", 0xF1, 0x9F, 0xBF, 0x80), bad)
    _kept("F1 9F 98 80", _quoted("", 0xF1, 0x9F, 0x98, 0x80), bad)
    _kept("F1 9F 98 BF", _quoted("", 0xF1, 0x9F, 0x98, 0xBF), bad)
    _repaired(
        "F1 7F", _quoted("", 0xF1, 0x7F), String(R) + chr(0x7F) + "z", bad
    )
    _repaired(
        "F1 C0", _quoted("", 0xF1, 0xC0), String(R) + R + "z", bad
    )
    _repaired(
        "F1 9F 7F", _quoted("", 0xF1, 0x9F, 0x7F), String(R) + chr(0x7F) + "z", bad
    )
    _repaired(
        "F1 9F C0", _quoted("", 0xF1, 0x9F, 0xC0), String(R) + R + "z", bad
    )
    _repaired(
        "F1 9F 98 7F", _quoted("", 0xF1, 0x9F, 0x98, 0x7F), String(R) + chr(0x7F) + "z", bad
    )
    _repaired(
        "F1 9F 98 C0", _quoted("", 0xF1, 0x9F, 0x98, 0xC0), String(R) + R + "z", bad
    )
    _raise_if_any(bad)


def test_second_byte_special_ranges() raises:
    var bad = List[String]()
    # E0 A0..BF: below is overlong, above is not a continuation byte.
    _repaired(
        "E0 9F 80", _quoted("", 0xE0, 0x9F, 0x80), String(R) + R + R + "z", bad
    )
    _kept("E0 A0 80", _quoted("", 0xE0, 0xA0, 0x80), bad)
    _kept("E0 BF 80", _quoted("", 0xE0, 0xBF, 0x80), bad)
    _repaired(
        "E0 C0", _quoted("", 0xE0, 0xC0), String(R) + R + "z", bad
    )
    # ED 80..9F: above is a UTF-16 surrogate (U+D800).
    _repaired(
        "ED 7F", _quoted("", 0xED, 0x7F), String(R) + chr(0x7F) + "z", bad
    )
    _kept("ED 80 80", _quoted("", 0xED, 0x80, 0x80), bad)
    _kept("ED 9F 80", _quoted("", 0xED, 0x9F, 0x80), bad)
    _repaired(
        "ED A0 80", _quoted("", 0xED, 0xA0, 0x80), String(R) + R + R + "z", bad
    )
    # F0 90..BF: below is overlong.
    _repaired(
        "F0 8F 80 80", _quoted("", 0xF0, 0x8F, 0x80, 0x80), String(R) + R + R + R + "z", bad
    )
    _kept("F0 90 80 80", _quoted("", 0xF0, 0x90, 0x80, 0x80), bad)
    _kept("F0 BF 80 80", _quoted("", 0xF0, 0xBF, 0x80, 0x80), bad)
    _repaired(
        "F0 C0", _quoted("", 0xF0, 0xC0), String(R) + R + "z", bad
    )
    # F4 80..8F: above is beyond U+10FFFF.
    _repaired(
        "F4 7F", _quoted("", 0xF4, 0x7F), String(R) + chr(0x7F) + "z", bad
    )
    _kept("F4 80 80 80", _quoted("", 0xF4, 0x80, 0x80, 0x80), bad)
    _kept("F4 8F 80 80", _quoted("", 0xF4, 0x8F, 0x80, 0x80), bad)
    _repaired(
        "F4 90 80 80", _quoted("", 0xF4, 0x90, 0x80, 0x80), String(R) + R + R + R + "z", bad
    )
    _raise_if_any(bad)


def test_lead_byte_edges() raises:
    var bad = List[String]()
    # Table 3-7 lead ranges: C2..DF opens 2 bytes, E0..EF 3, F0..F4 4. Each
    # range edge, and each lead next to E0, ED, F0, F4 (whose second byte is
    # restricted), is kept with the full 80..BF second-byte range.
    _kept("C2 80", _quoted("", 0xC2, 0x80), bad)
    _kept("C2 BF", _quoted("", 0xC2, 0xBF), bad)
    _kept("DF 80", _quoted("", 0xDF, 0x80), bad)
    _kept("DF BF", _quoted("", 0xDF, 0xBF), bad)
    _kept("E1 80 80", _quoted("", 0xE1, 0x80, 0x80), bad)
    _kept("E1 BF BF", _quoted("", 0xE1, 0xBF, 0xBF), bad)
    _kept("EC 80 80", _quoted("", 0xEC, 0x80, 0x80), bad)
    _kept("EC BF BF", _quoted("", 0xEC, 0xBF, 0xBF), bad)
    _kept("EE 80 80", _quoted("", 0xEE, 0x80, 0x80), bad)
    _kept("EE BF BF", _quoted("", 0xEE, 0xBF, 0xBF), bad)
    _kept("EF 80 80", _quoted("", 0xEF, 0x80, 0x80), bad)
    _kept("EF BF BF", _quoted("", 0xEF, 0xBF, 0xBF), bad)
    _kept("F1 80 80 80", _quoted("", 0xF1, 0x80, 0x80, 0x80), bad)
    _kept("F3 BF BF BF", _quoted("", 0xF3, 0xBF, 0xBF, 0xBF), bad)
    # The bytes just outside the lead ranges are each a one-byte subpart.
    _repaired("BF", _quoted("", 0xBF), String(R) + "z", bad)
    _repaired("C1 80", _quoted("", 0xC1, 0x80), String(R) + R + "z", bad)
    _repaired(
        "F5 80 80 80", _quoted("", 0xF5, 0x80, 0x80, 0x80),
        String(R) + R + R + R + "z", bad,
    )
    _repaired("F8", _quoted("", 0xF8), String(R) + "z", bad)
    # After a well-formed sequence of each length the next byte starts a new
    # sequence, so a lead given the wrong length cannot absorb the 0x80.
    _repaired(
        "C2 BF 80", _quoted("", 0xC2, 0xBF, 0x80), chr(0xBF) + R + "z", bad
    )
    _repaired(
        "DF BF 80", _quoted("", 0xDF, 0xBF, 0x80), chr(0x7FF) + R + "z", bad
    )
    _repaired(
        "E0 A0 80 80", _quoted("", 0xE0, 0xA0, 0x80, 0x80),
        chr(0x800) + R + "z", bad,
    )
    _repaired(
        "EF BF BF 80", _quoted("", 0xEF, 0xBF, 0xBF, 0x80),
        chr(0xFFFF) + R + "z", bad,
    )
    _repaired(
        "F0 90 80 80 80", _quoted("", 0xF0, 0x90, 0x80, 0x80, 0x80),
        chr(0x10000) + R + "z", bad,
    )
    _repaired(
        "F4 8F BF BF 80", _quoted("", 0xF4, 0x8F, 0xBF, 0xBF, 0x80),
        chr(0x10FFFF) + R + "z", bad,
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
    _run("test_truncated_sequence", test_truncated_sequence, failed)
    _run("test_overlong_encodings", test_overlong_encodings, failed)
    _run("test_surrogate_encoded_in_utf8", test_surrogate_encoded_in_utf8, failed)
    _run("test_code_point_above_max", test_code_point_above_max, failed)
    _run("test_well_formed_multibyte_kept", test_well_formed_multibyte_kept, failed)
    _run("test_escape_then_bad_byte", test_escape_then_bad_byte, failed)
    _run("test_non_continuation_at_position_3", test_non_continuation_at_position_3, failed)
    _run("test_above_range_continuation", test_above_range_continuation, failed)
    _run("test_continuation_bounds_every_position", test_continuation_bounds_every_position, failed)
    _run("test_second_byte_special_ranges", test_second_byte_special_ranges, failed)
    _run("test_lead_byte_edges", test_lead_byte_edges, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("test_json_scan_utf8: ALL 13 CASES PASS")
