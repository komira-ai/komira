# =============================================================================
# test_like_underscore_is_one_character — SQL LIKE's `_` is one CHARACTER
# =============================================================================
#
# REGRESSION GUARD for a SILENT-WRONG-ANSWER in a LIKE matcher: if `_`
# consumes one BYTE, then over multi-byte UTF-8 it matches a fragment of a
# character. Against DuckDB 1.5.3:
#
#   'é'     LIKE '_'      DuckDB true    byte-matcher false   (2 bytes, 1 char)
#   'ée'    LIKE '_e'     DuckDB true    byte-matcher false
#   'naïve' LIKE 'na_ve'  DuckDB true    byte-matcher false
#   'é'     LIKE '__'     DuckDB false   byte-matcher TRUE    (a wrong row SELECTED)
#   '日本'  LIKE '__'     DuckDB true    byte-matcher false
#
# in a WHERE, a projected boolean, a CASE condition and `sum(CASE ...)` alike.
#
# ★ THREE MATCHERS, FOUND BY MECHANISM (the `_` wildcard byte test), NOT BY NAME:
#
#   1. `komira_column_kernels.string_comparison._like_match` — the columnar kernel
#      behind `eval_string_like` / `eval_large_string_like` (the parquet /
#      in-memory FILTER + PROJECTION routes). Its `%lit%lit%` fast path is
#      `_`-free by construction and byte-exact on valid UTF-8, so it is not a
#      fourth matcher.
#   2. `komira_eval.expression_executor._string_like_match` — the RuntimeExpr
#      `EXPR_LIKE_STRING` walker (the ROW-format source filter walker and the
#      computed-project evaluator, `lower_untyped_expr._translate_string_op`).
#   3. `komira_eval.expr_x_conformers._like_match` — the `LikeXString` conformer.
#
# 2 and 3 are the SAME function as 1 (`like_match_string`), so
# this file asks all three the same questions and a re-divergence reds it.
# Every expected value below is DuckDB 1.5.3's answer (`SELECT ? LIKE ?`).
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.string_array import StringArray
from komira_arrow.large_string_array import LargeStringArray
from komira_column_kernels.string_comparison import (
    eval_string_like,
    eval_large_string_like,
)
from komira_eval.expression_executor import _string_like_match
from komira_eval.expr_x_conformers import _like_match as _conformer_like_match


struct _Case(Copyable, Movable):
    var s: String
    var p: String
    var want: Bool

    def __init__(out self, s: String, p: String, want: Bool):
        self.s = s
        self.p = p
        self.want = want


def _cases() -> List[_Case]:
    """DuckDB 1.5.3 `SELECT ? LIKE ?` for each pair."""
    var c = List[_Case]()
    c.append(_Case("é", "_", True))
    c.append(_Case("é", "__", False))
    c.append(_Case("ée", "_e", True))
    c.append(_Case("ab", "__", True))
    c.append(_Case("日本", "__", True))
    c.append(_Case("日本", "日_", True))
    c.append(_Case("日本", "___", False))
    c.append(_Case("naïve", "na_ve", True))
    c.append(_Case("naïve", "_____", True))
    c.append(_Case("naïve", "______", False))
    c.append(_Case("ñ_", "__", True))
    c.append(_Case("aé", "%_", True))
    c.append(_Case("éa", "_a", True))
    c.append(_Case("éa", "%é_", True))
    c.append(_Case("Straße", "Stra_e", True))
    c.append(_Case("Straße", "%a_e", True))
    c.append(_Case("Straße", "______", True))
    c.append(_Case("Straße", "_______", False))
    c.append(_Case("", "", True))
    c.append(_Case("", "_", False))
    c.append(_Case("", "%", True))
    c.append(_Case("é", "é", True))
    c.append(_Case("é", "%", True))
    c.append(_Case("😀", "_", True))
    c.append(_Case("😀x", "_x", True))
    c.append(_Case("😀", "__", False))
    c.append(_Case("éé", "%é", True))
    c.append(_Case("xéy", "%_y", True))
    c.append(_Case("éab", "%_b", True))
    c.append(_Case("é", "%_%", True))
    c.append(_Case("éb", "_%_", True))
    c.append(_Case("é", "_%_", False))
    c.append(_Case("aéb", "a_b", True))
    c.append(_Case("aéb", "a__b", False))
    c.append(_Case("aéb", "a%b", True))
    c.append(_Case("ab", "a_b", False))
    return c^


def _what(c: _Case, route: String) -> String:
    return route + ": '" + c.s + "' LIKE '" + c.p + "'"


def test_columnar_kernel_string() raises:
    """`eval_string_like` (Int32 offsets) with the production default AND the
    generic reference arm forced (`use_fastpath=False`)."""
    var cases = _cases()
    for i in range(len(cases)):
        ref c = cases[i]
        var arr = StringArray.from_strings([c.s])
        assert_equal(eval_string_like(arr, c.p).get(0), c.want, _what(c, "eval_string_like"))
        assert_equal(
            eval_string_like(arr, c.p, use_fastpath=False).get(0),
            c.want,
            _what(c, "eval_string_like(use_fastpath=False)"),
        )


def test_columnar_kernel_large_string() raises:
    """`eval_large_string_like` (Int64 offsets) — the same `_like_match`."""
    var cases = _cases()
    for i in range(len(cases)):
        ref c = cases[i]
        var arr = LargeStringArray.from_strings([c.s])
        assert_equal(
            eval_large_string_like(arr, c.p).get(0), c.want,
            _what(c, "eval_large_string_like"),
        )


def test_runtime_expr_walker_matcher() raises:
    """`expression_executor._string_like_match` — `EXPR_LIKE_STRING`."""
    var cases = _cases()
    for i in range(len(cases)):
        ref c = cases[i]
        assert_equal(_string_like_match(c.s, c.p), c.want, _what(c, "_string_like_match"))


def test_like_x_string_conformer_matcher() raises:
    """`expr_x_conformers._like_match` — the `LikeXString` conformer."""
    var cases = _cases()
    for i in range(len(cases)):
        ref c = cases[i]
        assert_equal(
            _conformer_like_match(c.s, c.p), c.want, _what(c, "LikeXString")
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
