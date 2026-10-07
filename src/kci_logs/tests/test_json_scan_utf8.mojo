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
#   J4  overlong C0 AF -> 2, E0 80 AF -> 3
#   J5  surrogate encoded in UTF-8, ED A0 80           -> 3 x U+FFFD
#   J6  above U+10FFFF, F4 90 80 80 -> 4, lead F5 -> 1 each
#   J7  well-formed 2/3/4-byte text is kept byte for byte
#   J8  a bad byte after an escape is repaired; the escape still decodes
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
    assert_equal(_scan(_quoted("", 0xE0, 0x80, 0xAF)), String(R) + R + R + "z")


def test_surrogate_encoded_in_utf8() raises:
    assert_equal(_scan(_quoted("", 0xED, 0xA0, 0x80)), String(R) + R + R + "z")


def test_code_point_above_max() raises:
    assert_equal(
        _scan(_quoted("", 0xF4, 0x90, 0x80, 0x80)), String(R) + R + R + R + "z"
    )
    assert_equal(_scan(_quoted("", 0xF5, 0x80)), String(R) + R + "z")


def test_well_formed_multibyte_kept() raises:
    # U+00E9, U+20AC, U+1F600 and the edges U+D7FF, U+E000, U+10FFFF.
    var b = _quoted(
        "",
        0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80,
        0xED, 0x9F, 0xBF, 0xEE, 0x80, 0x80, 0xF4, 0x8F, 0xBF, 0xBF,
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
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("test_json_scan_utf8: ALL 8 CASES PASS")
