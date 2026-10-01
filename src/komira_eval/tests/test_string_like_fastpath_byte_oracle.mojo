# =============================================================================
# Byte-oracle: the `%lit%lit%` LIKE fast path === the generic backtracking
# `_like_match`, bit-for-bit, across a pattern/string corpus.
# =============================================================================
#
# `eval_string_like` has a fast path (ALWAYS ON in production) that decomposes a
# `_`-free SQL LIKE pattern into literal segments and matches each with libc
# `memmem` (mirroring DuckDB's LikeMatcher), instead of the per-character
# backtracking `_like_match`. This is the q13 lever (o_comment NOT LIKE
# '%special%requests%'). This test is the correctness guard: for every (pattern,
# string) pair it runs `eval_string_like` with the fast path OFF (reference =
# `_like_match`) and ON (fast, the default), and asserts identical BooleanArray
# masks. A byte divergence here fails the build.
#
# HOW THE REFERENCE ARM IS REACHED: the generic `_like_match` arm is the
# ORACLE, reached through a plain defaulted parameter — `eval_string_like(arr, pattern, use_fastpath=False)`. Production
# never passes the argument. No env mutation, so this test is also safe to run
# concurrently with anything else in the process.
#
# It also pins the exact q13 pattern semantics against hand-computed truth so a
# regression in EITHER path (fast or slow) is caught, not just a fast/slow
# agreement on a shared bug.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.string_array import StringArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.eval.string_comparison import eval_string_like


# -----------------------------------------------------------------------------
# core oracle: fast === slow for a (values, pattern) case
# -----------------------------------------------------------------------------


def _assert_fast_equals_slow(values: List[String], pattern: String) raises:
    var arr = StringArray.from_strings(values)

    # `use_fastpath=False` forces the generic `_like_match` reference path.
    var slow = eval_string_like(arr, pattern, use_fastpath=False)

    # The default (argument omitted) == production: the memmem fast path.
    var fast = eval_string_like(arr, pattern)

    assert_equal(
        slow.length, fast.length, "length mismatch for pattern=" + pattern
    )
    for i in range(slow.length):
        assert_equal(
            slow.get(i),
            fast.get(i),
            "byte divergence pattern='" + pattern + "' row " + String(i)
            + " value='" + values[i] + "'",
        )


# A representative string corpus reused across every pattern.
def _corpus() -> List[String]:
    var v: List[String] = [
        String(""),
        String("a"),
        String("ab"),
        String("abc"),
        String("aa"),
        String("aXa"),
        String("special"),
        String("requests"),
        String("special requests"),
        String("requests special"),
        String("specialrequests"),
        String("xspecialyrequestsz"),
        String("this order has special requests attached"),
        String("no anomalies here at all"),
        String("special but no r-word"),
        String("prefix_special_mid_requests_suffix"),
        String("SPECIAL REQUESTS"),
        String("%literal-percent%"),
        String("ends with special"),
        String("requests at the very start special later"),
        String("special special requests requests"),
    ]
    return v^


# -----------------------------------------------------------------------------
# Test 1: the exact q13 pattern (the whole reason this fast path exists)
# -----------------------------------------------------------------------------


def test_q13_pattern_fast_equals_slow() raises:
    _assert_fast_equals_slow(_corpus(), String("%special%requests%"))


# -----------------------------------------------------------------------------
# Test 2: a broad shape sweep (anchors, multi-seg, empties, exact, all-%)
# -----------------------------------------------------------------------------


def test_shape_sweep_fast_equals_slow() raises:
    var patterns: List[String] = [
        String(""),  # empty pattern -> exact match to empty string only
        String("a"),  # exact, no wildcard
        String("abc"),  # exact, no wildcard
        String("special"),  # exact
        String("a%"),  # prefix anchor only
        String("%a"),  # suffix anchor only
        String("%a%"),  # single interior contains
        String("al%"),
        String("%ob"),
        String("%li%"),
        String("a%c"),  # prefix + suffix anchor, no interior
        String("a%b%c"),  # prefix + interior + suffix
        String("%a%b%"),  # two interior, no anchors
        String("special%requests"),  # anchored both ends, one gap
        String("%special%requests%"),  # the q13 shape
        String("special%"),
        String("%requests"),
        String("%%"),  # all-percent (collapse) -> matches everything
        String("%%a%%"),  # collapsing percents around one contains
        String("aa%"),  # repeated first-byte prefix
        String("%aa%"),  # repeated first-byte contains
        String("x%x%x"),  # three anchored/interior with same char
    ]
    var corpus = _corpus()
    for i in range(len(patterns)):
        _assert_fast_equals_slow(corpus, patterns[i])


# -----------------------------------------------------------------------------
# Test 3: underscore patterns take the FALLBACK path — toggling `use_fastpath`
# must not change results (both arms run `_like_match`).
# -----------------------------------------------------------------------------


def test_underscore_fallback_unaffected() raises:
    var patterns: List[String] = [
        String("a_c"),
        String("_bc"),
        String("ab_"),
        String("%a_"),
        String("_%_"),
        String("special_requests"),
        String("%spec_al%"),
    ]
    var corpus = _corpus()
    for i in range(len(patterns)):
        _assert_fast_equals_slow(corpus, patterns[i])


# -----------------------------------------------------------------------------
# Test 4: anchored semantics pinned against hand-computed truth (guards BOTH
# paths from a shared regression, with the fast path ON).
# -----------------------------------------------------------------------------


def test_q13_semantics_pinned_fastpath_on() raises:
    var values: List[String] = [
        String("special requests"),  # contains special..requests -> MATCH
        String("has special hidden requests inside"),  # MATCH
        String("requests then special"),  # wrong order -> NO
        String("specialrequests"),  # adjacent, still in order -> MATCH
        String("only special"),  # missing requests -> NO
        String("plain comment"),  # neither -> NO
        String(""),  # empty -> NO
    ]
    var arr = StringArray.from_strings(values)

    # The default (argument omitted) == production: the memmem fast path.
    var m = eval_string_like(arr, String("%special%requests%"))

    assert_true(m.get(0))
    assert_true(m.get(1))
    assert_false(m.get(2))
    assert_true(m.get(3))
    assert_false(m.get(4))
    assert_false(m.get(5))
    assert_false(m.get(6))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
