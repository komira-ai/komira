# =============================================================================
# test_rule_pattern.mojo -- the whole-token byte pattern behind token rules.
# =============================================================================
#
#   atoms        a literal, `.`, a class with ranges and negation, and the
#                `\d` and `\w` escapes each match exactly the bytes they name.
#   quantifiers  `?`, `*` and `+` accept the counts they stand for and no others.
#   whole token  a pattern must match from the first byte to the last; a match
#                inside a longer token is not a match.
#   linear       a pattern built to make a backtracking engine explode answers
#                false on a long token (a backtracking matcher would not return).
#   refusals     each malformed or unsupported pattern is refused by name, an
#                escape is refused as the end of a range, a pattern no token can
#                match (whitespace, a start that is only trimmed, an end that is
#                only trimmed) is refused, and an escaped operator is accepted
#                as a literal.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg import PATTERN_MAX_BYTES, Pattern


def _m(pattern: String, token: String) raises -> Bool:
    return Pattern.compile(pattern).matches(token)


def test_a_literal_and_the_dot() raises:
    assert_true(_m("abc", "abc"))
    assert_false(_m("abc", "abd"))
    assert_true(_m("a.c", "abc"))
    assert_true(_m("a.c", "a-c"))
    assert_false(_m("a.c", "ac"))
    assert_false(_m("a.c", "abbc"))


def test_a_pattern_must_match_the_whole_token() raises:
    assert_false(_m("b", "abc"))
    assert_false(_m("abc", "abcd"))
    assert_false(_m("abc", "zabc"))
    assert_false(_m("a", ""))


def test_optional_star_and_plus_count_correctly() raises:
    assert_true(_m("ab?c", "ac"))
    assert_true(_m("ab?c", "abc"))
    assert_false(_m("ab?c", "abbc"))
    assert_true(_m("ab*c", "ac"))
    assert_true(_m("ab*c", "abbbc"))
    assert_false(_m("ab*c", "abxc"))
    assert_false(_m("ab+c", "ac"))
    assert_true(_m("ab+c", "abc"))
    assert_true(_m("ab+c", "abbbbc"))
    assert_true(_m("a*", ""))
    assert_true(_m("a?b?", ""))
    assert_false(_m("a+", ""))


def test_classes_ranges_and_negation() raises:
    assert_true(_m("[a-c]+", "abcabc"))
    assert_false(_m("[a-c]+", "abd"))
    assert_true(_m("[a-cx-z]+", "azy"))
    assert_true(_m("[^0-9]+", "abc"))
    assert_false(_m("[^0-9]+", "ab1"))
    assert_true(_m("[a-]+", "a-a"))
    assert_true(_m("[-a]+", "-a-"))
    assert_true(_m("[\\d_]+", "1_2"))
    assert_false(_m("[\\d_]+", "1a"))
    assert_true(_m("[\\]x]+", "]x]"))


def test_the_digit_and_word_escapes() raises:
    assert_true(_m("\\d+\\.\\d+", "3.14"))
    assert_false(_m("\\d+\\.\\d+", "3x14"))
    assert_false(_m("\\d+", "12a"))
    assert_true(_m("\\w+", "ab_9"))
    assert_false(_m("\\w+", "ab-9"))


def test_a_structured_token_shape() raises:
    var p = Pattern.compile("[A-Z][A-Z0-9]*-\\d+")
    assert_true(p.matches("REF-12"))
    assert_true(p.matches("A1B2-007"))
    assert_false(p.matches("ref-12"))
    assert_false(p.matches("REF-"))
    assert_false(p.matches("REF12"))
    assert_equal(p.num_atoms(), 4)


def test_a_pattern_cannot_be_made_exponential() raises:
    var p = Pattern.compile("a*a*a*a*a*a*a*a*a*a*b")
    var token = String("")
    for _ in range(4000):
        token += "a"
    assert_false(p.matches(token))
    assert_true(p.matches(token + "b"))


def test_an_escaped_operator_is_a_literal() raises:
    assert_true(_m("a\\(b\\)c", "a(b)c"))
    assert_true(_m("a\\|b", "a|b"))
    assert_true(_m("\\^\\$\\{\\}\\*\\+\\?x", "^${}*+?x"))
    assert_true(_m("a\\.b", "a.b"))
    assert_false(_m("a\\.b", "axb"))


def test_malformed_patterns_are_refused() raises:
    with assert_raises(contains="the pattern is empty"):
        _ = Pattern.compile("")
    with assert_raises(contains="unterminated class"):
        _ = Pattern.compile("[abc")
    with assert_raises(contains="empty class"):
        _ = Pattern.compile("[]")
    with assert_raises(contains="empty class"):
        _ = Pattern.compile("[^]")
    with assert_raises(contains="descending range"):
        _ = Pattern.compile("[z-a]")
    with assert_raises(contains="nothing to repeat"):
        _ = Pattern.compile("*a")
    with assert_raises(contains="nothing to repeat"):
        _ = Pattern.compile("a**")
    with assert_raises(contains="nothing to repeat"):
        _ = Pattern.compile("a+?")
    with assert_raises(contains="escape with nothing after it"):
        _ = Pattern.compile("a\\")
    with assert_raises(contains="escape with nothing after it"):
        _ = Pattern.compile("[a\\")


def test_an_escape_cannot_end_a_range() raises:
    with assert_raises(contains="escape as the end of a range"):
        _ = Pattern.compile("[a-\\d]")
    with assert_raises(contains="escape as the end of a range"):
        _ = Pattern.compile("[a-\\]]")
    # An escaped member that is not a range bound still works.
    assert_true(_m("[\\]x]+", "x]"))
    assert_true(_m("[a-c\\d]+", "a9c"))


def test_a_pattern_no_token_can_match_is_refused() raises:
    # A token never holds whitespace.
    with assert_raises(contains="can only match whitespace"):
        _ = Pattern.compile("a b")
    with assert_raises(contains="can only match whitespace"):
        _ = Pattern.compile("a[ \t]+b")
    # A token loses `. , ; : ! ? ) ] } " '` from its end.
    with assert_raises(contains="trimmed from the end"):
        _ = Pattern.compile("[a-z]+\\.")
    with assert_raises(contains="trimmed from the end"):
        _ = Pattern.compile("a[.,;]?[.,;]")
    with assert_raises(contains="trimmed from the end"):
        _ = Pattern.compile("a\\)*\\)+")
    # A token loses `( [ { " '` from its start.
    with assert_raises(contains="trimmed from the start"):
        _ = Pattern.compile("\\(a")
    with assert_raises(contains="trimmed from the start"):
        _ = Pattern.compile("\\(*[\\[\\{]a")
    # A shape that can match something else as well is accepted.
    assert_true(_m("[a-z]+\\.?", "ab"))
    assert_true(_m("[a-z.]+", "a.b"))
    assert_true(_m("\\.a", ".a"))
    assert_true(_m("a\\(", "a("))
    assert_true(_m("a.", "ab"))
    assert_true(_m("a*", ""))


def test_unsupported_operators_are_refused() raises:
    with assert_raises(contains="unsupported operator"):
        _ = Pattern.compile("(a)")
    with assert_raises(contains="unsupported operator"):
        _ = Pattern.compile("a|b")
    with assert_raises(contains="unsupported operator"):
        _ = Pattern.compile("a{2}")
    with assert_raises(contains="unsupported operator"):
        _ = Pattern.compile("^a")
    with assert_raises(contains="unsupported operator"):
        _ = Pattern.compile("a$")


def test_the_length_limit_is_exact() raises:
    var ok = String("")
    for _ in range(PATTERN_MAX_BYTES):
        ok += "a"
    assert_equal(Pattern.compile(ok).num_atoms(), PATTERN_MAX_BYTES)
    with assert_raises(contains="over the limit"):
        _ = Pattern.compile(ok + "a")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
