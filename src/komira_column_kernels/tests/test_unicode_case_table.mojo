# komira_column_kernels/tests/test_unicode_case_table.mojo -- the generated
# SIMPLE case mapping `simple_upper_cp` / `simple_lower_cp`, swept over every
# codepoint U+0000..U+10FFFF so every leaf of both decision trees runs.
#
# The oracle is the Mojo standard library's own Unicode tables
# (`String.upper()` / `String.lower()` of one codepoint), a second source
# written from the Unicode Character Database, not from this file. They
# differ from DuckDB's simple mapping in one known way, which the test states
# as a rule rather than a list: where the library applies a FULL
# (SpecialCasing) mapping of two or more codepoints, the simple mapping is the
# identity, except `ß` (U+00DF), which DuckDB maps to `ẞ` (U+1E9E).

from std.testing import TestSuite, assert_equal

from komira_column_kernels.unicode_case_table import simple_lower_cp, simple_upper_cp


comptime _MAX_CP = 0x10FFFF


def _std_case(cp: Int, upper: Bool) -> List[Int]:
    """The standard library's mapping of one scalar value, as codepoints."""
    var s = chr(cp)
    var t = s.upper() if upper else s.lower()
    var out = List[Int]()
    for c in t.codepoints():
        out.append(Int(c.to_u32()))
    return out^


def _is_surrogate(cp: Int) -> Bool:
    return cp >= 0xD800 and cp <= 0xDFFF


def test_ascii_is_the_byte_flip() raises:
    # The fast path ahead of each tree: a..z <-> A..Z, every other ASCII
    # byte (both neighbours of each range included) maps to itself.
    for cp in range(0x80):
        var want_upper = cp - 32 if (cp >= 0x61 and cp <= 0x7A) else cp
        var want_lower = cp + 32 if (cp >= 0x41 and cp <= 0x5A) else cp
        assert_equal(simple_upper_cp(cp), want_upper, String("upper ") + hex(cp))
        assert_equal(simple_lower_cp(cp), want_lower, String("lower ") + hex(cp))


def test_documented_mappings() raises:
    # The facts the module header states.
    assert_equal(simple_upper_cp(0xDF), 0x1E9E)  # upper('ß') is 'ẞ', not 'SS'
    assert_equal(simple_lower_cp(0x1E9E), 0xDF)
    assert_equal(simple_lower_cp(0xDF), 0xDF)
    assert_equal(simple_lower_cp(0x130), 0x69)  # lower('İ') = 'i'
    assert_equal(simple_upper_cp(0x130), 0x130)
    assert_equal(simple_upper_cp(0x131), 0x49)  # upper('ı') = 'I'
    assert_equal(simple_lower_cp(0x131), 0x131)
    # Not an involution: upper(lower('İ')) is 'I', not 'İ'.
    assert_equal(simple_upper_cp(simple_lower_cp(0x130)), 0x49)
    # Other single-codepoint facts of the Unicode Character Database.
    assert_equal(simple_upper_cp(0xB5), 0x39C)  # micro sign -> Greek capital mu
    assert_equal(simple_upper_cp(0xFF), 0x178)  # ÿ -> Ÿ
    assert_equal(simple_upper_cp(0x3C2), 0x3A3)  # final sigma -> capital sigma
    assert_equal(simple_lower_cp(0x212A), 0x6B)  # Kelvin sign -> k
    assert_equal(simple_upper_cp(0x6B), 0x4B)  # ... and k back to K, not the sign
    assert_equal(simple_lower_cp(0x2126), 0x3C9)  # Ohm sign -> omega
    assert_equal(simple_upper_cp(0x10428), 0x10400)  # Deseret, 4-byte UTF-8
    assert_equal(simple_lower_cp(0x10400), 0x10428)
    assert_equal(simple_upper_cp(0x1E922), 0x1E900)  # Adlam, the last range
    assert_equal(simple_lower_cp(0x1E921), 0x1E943)
    assert_equal(simple_upper_cp(0x1E944), 0x1E944)
    assert_equal(simple_lower_cp(0x1E922), 0x1E922)


def test_changed_counts_match_the_generator() raises:
    # Each function's docstring states how many codepoints its ranges map
    # to another codepoint; a leaf dropped, widened or narrowed changes it.
    var changed_upper = 0
    var changed_lower = 0
    for cp in range(_MAX_CP + 1):
        if simple_upper_cp(cp) != cp:
            changed_upper += 1
        if simple_lower_cp(cp) != cp:
            changed_lower += 1
    assert_equal(changed_upper, 1451)
    assert_equal(changed_lower, 1433)


def test_outside_the_scalar_values_is_identity() raises:
    # Surrogates are not scalar values (the driver never passes one); the
    # tables leave them, and anything past U+10FFFF or below 0, unchanged.
    for cp in range(0xD800, 0xE000):
        assert_equal(simple_upper_cp(cp), cp, String("upper ") + hex(cp))
        assert_equal(simple_lower_cp(cp), cp, String("lower ") + hex(cp))
    var outside: List[Int] = [-1, -0x41, _MAX_CP + 1, 0x7FFFFFFF, Int.MAX, Int.MIN]
    for cp in outside:
        assert_equal(simple_upper_cp(cp), cp)
        assert_equal(simple_lower_cp(cp), cp)


def test_every_scalar_against_the_standard_library() raises:
    var full_upper = 0
    var full_lower = 0
    for cp in range(_MAX_CP + 1):
        if _is_surrogate(cp):
            continue
        var std_upper = _std_case(cp, True)
        var want_upper: Int
        if len(std_upper) == 1:
            want_upper = std_upper[0]
        else:
            full_upper += 1
            want_upper = 0x1E9E if cp == 0xDF else cp
        assert_equal(simple_upper_cp(cp), want_upper, String("upper ") + hex(cp))
        var std_lower = _std_case(cp, False)
        var want_lower: Int
        if len(std_lower) == 1:
            want_lower = std_lower[0]
        else:
            full_lower += 1
            want_lower = cp
        assert_equal(simple_lower_cp(cp), want_lower, String("lower ") + hex(cp))
    # How many full mappings the pinned standard library applies (SpecialCasing:
    # ß, ŉ, ǰ, ΐ, ΰ, և, ẖ..ẚ, sixteen Greek letters with diacritics, the
    # Latin and Armenian ligatures). A change here is the oracle moving, not
    # this file: compare the two before trusting either.
    assert_equal(full_upper, 39)
    assert_equal(full_lower, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
