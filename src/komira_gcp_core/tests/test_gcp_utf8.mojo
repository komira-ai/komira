# =============================================================================
# test_gcp_utf8.mojo — is_valid_utf8 against the RFC 3629 §4 table.
# =============================================================================
#
# Every response body is checked by `is_valid_utf8` before it becomes a
# String, so a wrong ACCEPT is unsound decoding and a wrong REJECT refuses a
# legitimate non-ASCII page. Both halves are asserted, at every boundary of
# the table, plus each truncation (a short trailing sequence must be rejected
# without reading past the end).
# =============================================================================

from std.testing import assert_true, assert_false

from komira_gcp_core.utf8 import is_valid_utf8


def _b(var bytes: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in bytes:
        out.append(UInt8(v))
    return out^


def _accepts(bytes: List[Int], what: String) raises:
    assert_true(is_valid_utf8(_b(bytes.copy())), String("rejected ") + what)
    # Also mid-buffer, between ASCII, so the index arithmetic is exercised.
    var framed: List[Int] = [0x61]
    for v in bytes:
        framed.append(v)
    framed.append(0x62)
    assert_true(is_valid_utf8(_b(framed^)), String("rejected framed ") + what)


def _rejects(bytes: List[Int], what: String) raises:
    assert_false(is_valid_utf8(_b(bytes.copy())), String("accepted ") + what)


def test_valid_boundaries_are_accepted() raises:
    _accepts([0x00], "U+0000")
    _accepts([0x7F], "U+007F")
    _accepts([0xC2, 0x80], "U+0080")
    _accepts([0xDF, 0xBF], "U+07FF")
    _accepts([0xE0, 0xA0, 0x80], "U+0800")
    _accepts([0xED, 0x9F, 0xBF], "U+D7FF")
    _accepts([0xEE, 0x80, 0x80], "U+E000")
    _accepts([0xEF, 0xBF, 0xBF], "U+FFFF")
    _accepts([0xF0, 0x90, 0x80, 0x80], "U+10000")
    _accepts([0xF4, 0x8F, 0xBF, 0xBF], "U+10FFFF")
    _accepts(List[Int](), "the empty body")


def test_invalid_sequences_are_rejected() raises:
    # Overlong 2-byte leads.
    _rejects([0xC0, 0x80], "C0 80")
    _rejects([0xC1, 0xBF], "C1 BF")
    # Overlong 3-byte forms: E0 80..9F.
    _rejects([0xE0, 0x80, 0x80], "E0 80 80")
    _rejects([0xE0, 0x9F, 0xBF], "E0 9F BF")
    # Surrogates: ED A0..BF.
    _rejects([0xED, 0xA0, 0x80], "ED A0 80 (U+D800)")
    _rejects([0xED, 0xBF, 0xBF], "ED BF BF (U+DFFF)")
    # Overlong 4-byte forms: F0 80..8F.
    _rejects([0xF0, 0x80, 0x80, 0x80], "F0 80 80 80")
    _rejects([0xF0, 0x8F, 0xBF, 0xBF], "F0 8F BF BF")
    # Above U+10FFFF: F4 90.., and the F5..FF leads.
    _rejects([0xF4, 0x90, 0x80, 0x80], "F4 90 80 80")
    for lead in range(0xF5, 0x100):
        _rejects([lead, 0x80, 0x80, 0x80], String("lead ") + String(lead))
    # A continuation byte with no lead.
    _rejects([0x80], "lone 80")
    _rejects([0xBF], "lone BF")
    _rejects([0x61, 0x80, 0x62], "a 80 b")
    # A non-continuation byte where a continuation is due.
    _rejects([0xC2, 0x41], "C2 41")
    _rejects([0xE1, 0x80, 0x41], "E1 80 41")
    _rejects([0xF1, 0x80, 0x80, 0xC0], "F1 80 80 C0")


def test_truncated_sequences_are_rejected() raises:
    _rejects([0xC2], "2-byte lead at end")
    _rejects([0x61, 0xC2], "2-byte lead at end after ASCII")
    _rejects([0xE1, 0x80], "3-byte lead truncated by one")
    _rejects([0xE1], "3-byte lead alone")
    _rejects([0xF1, 0x80, 0x80], "4-byte lead truncated by one")
    _rejects([0xF1, 0x80], "4-byte lead truncated by two")
    _rejects([0xF1], "4-byte lead alone")


def main() raises:
    test_valid_boundaries_are_accepted()
    test_invalid_sequences_are_rejected()
    test_truncated_sequences_are_rejected()
    print("all gcp utf8 tests passed")
