# =============================================================================
# test_utf8_check.mojo -- the strict UTF-8 validator behind every String the
#   package builds from bytes.
# =============================================================================
#
#   accepted   ASCII, the empty input, and the boundary code points of the
#              two-, three- and four-byte forms (U+0080, U+07FF, U+0800,
#              U+D7FF, U+E000, U+FFFF, U+10000, U+10FFFF).
#   refused    a lone continuation byte, an overlong two-, three- and four-byte
#              form, a surrogate (U+D800), a code point above U+10FFFF, a lead
#              byte that is never valid (C0, C1, F5, FF), a bad continuation
#              byte, and a sequence cut off at the end of the input.
# =============================================================================

from std.testing import TestSuite, assert_false, assert_true

from komira_kg_format.utf8_check import bytes_are_utf8


def _ok(b: List[Int]) -> Bool:
    var l = List[UInt8]()
    for x in b:
        l.append(UInt8(x))
    return bytes_are_utf8(Span(l))


def test_well_formed_input_is_accepted() raises:
    assert_true(_ok([]))
    assert_true(_ok([0x41, 0x7F, 0x00]))
    assert_true(_ok([0xC2, 0x80]))  # U+0080
    assert_true(_ok([0xDF, 0xBF]))  # U+07FF
    assert_true(_ok([0xE0, 0xA0, 0x80]))  # U+0800
    assert_true(_ok([0xED, 0x9F, 0xBF]))  # U+D7FF
    assert_true(_ok([0xEE, 0x80, 0x80]))  # U+E000
    assert_true(_ok([0xEF, 0xBF, 0xBF]))  # U+FFFF
    assert_true(_ok([0xF0, 0x90, 0x80, 0x80]))  # U+10000
    assert_true(_ok([0xF4, 0x8F, 0xBF, 0xBF]))  # U+10FFFF
    assert_true(_ok([0x41, 0xC3, 0xA9, 0x42]))  # A é B


def test_ill_formed_input_is_refused() raises:
    assert_false(_ok([0x80]))  # a lone continuation byte
    assert_false(_ok([0xC0, 0x80]))  # overlong two-byte
    assert_false(_ok([0xC1, 0xBF]))
    assert_false(_ok([0xE0, 0x80, 0x80]))  # overlong three-byte
    assert_false(_ok([0xF0, 0x80, 0x80, 0x80]))  # overlong four-byte
    assert_false(_ok([0xED, 0xA0, 0x80]))  # U+D800, a surrogate
    assert_false(_ok([0xF4, 0x90, 0x80, 0x80]))  # U+110000
    assert_false(_ok([0xF5, 0x80, 0x80, 0x80]))
    assert_false(_ok([0xFF]))
    assert_false(_ok([0xC3, 0x28]))  # a bad continuation byte
    assert_false(_ok([0xE2, 0x82, 0x28]))
    assert_false(_ok([0xF0, 0x90, 0x28, 0xBC]))


def test_a_sequence_cut_off_at_the_end_is_refused() raises:
    assert_false(_ok([0xC3]))
    assert_false(_ok([0xE2, 0x82]))
    assert_false(_ok([0xF0, 0x9F, 0x98]))
    assert_false(_ok([0x41, 0xE2]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
