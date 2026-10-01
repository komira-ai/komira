# =============================================================================
# Semantics-locking tests for `regexp_replace`.
# =============================================================================
#
# Oracle: DuckDB — DuckDB has `regexp_replace`
# (RE2 engine, same engine class as our pure-Mojo Pike VM).  Expected values
# were generated with `duckdb -list <<'SQL' SELECT regexp_replace(...) SQL`
# and pasted in as literals below — no live-oracle CI dependency.
#
# Replacement-template syntax = the RE2 / PostgreSQL `\N` rewrite syntax (NOT
# DataFusion's `${N}` / `$N`, which is intentionally NOT accepted — a `$N` is
# a literal `$N`):
#   \0          -> the whole match (group 0)
#   \1 .. \9    -> capture group N (exactly one digit; `\10` is `\1` then a
#                  literal `0`); a non-participating group -> empty substitution
#   \\          -> a literal backslash
#   \<anything else>  -> the template is INVALID
#   <any other char incl. & $ %> -> that literal char
#
# Known divergences from the original Phase-2b brief, deliberate (DuckDB-faithful):
#   - `regexp_replace('aaa','a*','X','g')` -> 'X' (NOT 'XX' as the brief
#     conjectured): RE2's GlobalReplace disallows an empty match immediately
#     after a previous match, so the zero-width `a*` match at offset 3 (right
#     after the `aaa` match ending at 3) is skipped.  ('XaXbXcX' for the empty
#     pattern still holds — those empty matches are NOT adjacent to a previous
#     match end.)  DuckDB confirmed.
#   - An INVALID replacement template (out-of-range backref `\N`, unrecognized
#     escape `\&`/`\q`/..., or a trailing `\`) -> the input string is returned
#     UNCHANGED for every row (NOT an error).  This matches DuckDB exactly:
#     RE2's `Replace`/`GlobalReplace` returns false on a bad rewrite string and
#     DuckDB keeps the original.  In particular `\0` IS supported (whole match)
#     but `\&` is NOT (that's PostgreSQL/`sed`, not RE2 — DuckDB's RE2 rejects
#     it, so we do too).
#
# Flags: `g` = replace-all (it is NOT a pattern flag — `split_g_flag` strips it
# before `RegexProgram.compile`); `i`/`m`/`s`/`x` pass through to compile.
#
# The engine-dispatch cases run `_eval_column_expr` (the same compute path
# PipelineCompiler drives) over a hand-built RecordBatch + an `Expr.regexp_replace`
# node, producing a `Column` with `arrow_type == ArrowType.STRING`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.plan.expr import Expr
from komira_core.eval.regexp_nfa import RegexProgram
from komira_core.eval.regexp_functions import (
    eval_regexp_replace,
    regexp_replace_scalar,
    rewrite_template_valid,
    split_g_flag,
)
from komira_compiler.compiler_eval_column import _eval_column_expr


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

def _rr(subject: String, pattern: String, replacement: String, flags: String = "") raises -> String:
    var gsplit = split_g_flag(flags)
    var prog = RegexProgram.compile(pattern, gsplit[0])
    return regexp_replace_scalar(subject, prog, replacement, gsplit[1])


def _rr_col(vals: List[String], pattern: String, replacement: String, flags: String = "") raises -> StringArray[HeapRegion]:
    var arr = StringArray.from_strings(vals)
    var gsplit = split_g_flag(flags)
    var prog = RegexProgram.compile(pattern, gsplit[0])
    return eval_regexp_replace(arr^, prog, replacement, gsplit[1])


def _str_col(vals: List[String], name: String = "s") raises -> RecordBatch:
    var arr = StringArray.from_strings(vals)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_string(arr^))
    return rbb.build(sb.build())


# ===========================================================================
# First-match-only (no `g`) vs `g`-all.  (DuckDB oracle.)
#   regexp_replace('the cat sat','at','XX')      = 'the cXX sat'
#   regexp_replace('the cat sat','at','XX','g')  = 'the cXX sXX'
# ===========================================================================

def test_first_match_only() raises:
    assert_equal(_rr("the cat sat", "at", "XX"), "the cXX sat")


def test_global_all() raises:
    assert_equal(_rr("the cat sat", "at", "XX", "g"), "the cXX sXX")


def test_first_vs_global_more() raises:
    # regexp_replace('a-b-c-d','-','_')      = 'a_b-c-d'
    # regexp_replace('a-b-c-d','-','_','g')  = 'a_b_c_d'
    assert_equal(_rr("a-b-c-d", "-", "_"), "a_b-c-d")
    assert_equal(_rr("a-b-c-d", "-", "_", "g"), "a_b_c_d")
    # No match -> unchanged (both modes).
    assert_equal(_rr("hello", "xyz", "REP"), "hello")
    assert_equal(_rr("hello", "xyz", "REP", "g"), "hello")


# ===========================================================================
# Backrefs \1..\9 in the replacement template.  (DuckDB oracle.)
#   regexp_replace('','(\d+)-(\d+)-(\d+)','\3/\2/\1') = '12/05/2026'
#   regexp_replace('a1 b2 c3','([a-z])([0-9])','\2\1','g')      = '1a 2b 3c'
# ===========================================================================

def test_backref_reorder() raises:
    assert_equal(_rr("2026-05-12", r"(\d+)-(\d+)-(\d+)", r"\3/\2/\1"), "12/05/2026")


def test_backref_global() raises:
    assert_equal(_rr("a1 b2 c3", r"([a-z])([0-9])", r"\2\1", "g"), "1a 2b 3c")


def test_backref_one_digit_only() raises:
    # `\10` is `\1` then a literal `0` (RE2 reads exactly one digit).
    #   regexp_replace('a1','([0-9])','\10') = 'a10'
    assert_equal(_rr("a1", r"([0-9])", r"\10"), "a10")


# ===========================================================================
# \0 and (NOT) \& — the whole match.  (DuckDB oracle.)
#   regexp_replace('aXc','X','[\0]')         = 'a[X]c'
#   regexp_replace('a1b2','[0-9]','<\0>','g') = 'a<1>b<2>'
#   regexp_replace('aXc','X','q\&q')          = 'aXc'   (\& is NOT RE2 syntax;
#     invalid template -> input returned unchanged)
# ===========================================================================

def test_whole_match_backref_0() raises:
    assert_equal(_rr("aXc", "X", r"[\0]"), "a[X]c")
    assert_equal(_rr("a1b2", r"[0-9]", r"<\0>", "g"), "a<1>b<2>")


def test_amp_is_not_whole_match() raises:
    # `\&` is the PostgreSQL/sed whole-match alias — RE2 (DuckDB) does NOT
    # accept it; an invalid rewrite string -> the input is returned unchanged.
    assert_equal(_rr("aXc", "X", r"q\&q"), "aXc")
    assert_equal(_rr("aXc", "X", r"\&", "g"), "aXc")


# ===========================================================================
# Literal backslash: `\\` in the template -> a single `\`.  (DuckDB oracle.)
#   regexp_replace('a.b','\.','\\')      = 'a\b'
#   regexp_replace('aXc','X','q\\q')     = 'aq\qc'
#   regexp_replace('aXc','(X)','\\1')    = 'a\1c'   (\\ -> \, then literal '1')
# ===========================================================================

def test_literal_backslash() raises:
    assert_equal(_rr("a.b", r"\.", r"\\"), "a\\b")
    assert_equal(_rr("aXc", "X", r"q\\q"), "aq\\qc")
    assert_equal(_rr("aXc", r"(X)", r"\\1"), "a\\1c")


# ===========================================================================
# Backref to a non-participating group -> empty substitution (NOT error).
# (DuckDB oracle.)
#   regexp_replace('Yc','(X)?(c)','[\1][\2]')          = 'Y[][c]'
#   regexp_replace('Yc Zc','(X)?(c)','[\1][\2]','g')   = 'Y[][c] Z[][c]'
# ===========================================================================

def test_nonparticipating_group_backref() raises:
    assert_equal(_rr("Yc", r"(X)?(c)", r"[\1][\2]"), "Y[][c]")
    assert_equal(_rr("Yc Zc", r"(X)?(c)", r"[\1][\2]", "g"), "Y[][c] Z[][c]")
    # When the optional group DOES participate, it expands normally.
    #   regexp_replace('aXc','(X)?(c)','[\1][\2]') = 'a[X][c]'
    assert_equal(_rr("aXc", r"(X)?(c)", r"[\1][\2]"), "a[X][c]")


# ===========================================================================
# Zero-width-pattern global replace.  THE classic bug source.  (DuckDB oracle.)
#   regexp_replace('abc','','X','g')      = 'XaXbXcX'
#   regexp_replace('hello','','-','g')    = '-h-e-l-l-o-'
#   regexp_replace('','','X','g')         = 'X'
#   regexp_replace('aaa','a*','X','g')    = 'X'      (NOT 'XX' — the zero-width
#     a* match at offset 3, right after the 'aaa' match ending at 3, is skipped)
#   regexp_replace('aaa','a*','X')        = 'X'      (first-only: a* -> 'aaa')
#   regexp_replace('aaab','a*','X','g')   = 'XbX'    (a* -> 'aaa'; skip empty
#     at pos 3; copy 'b'; a* -> '' at pos 4 (not adjacent to a match end) -> X)
#   regexp_replace('aaaa','aa','X','g')   = 'XX'
#   regexp_replace('xaaay','a*','X','g')  = 'XxXyX'
# ===========================================================================

def test_zerowidth_empty_pattern_global() raises:
    assert_equal(_rr("abc", "", "X", "g"), "XaXbXcX")
    assert_equal(_rr("hello", "", "-", "g"), "-h-e-l-l-o-")
    assert_equal(_rr("", "", "X", "g"), "X")


def test_zerowidth_astar_global() raises:
    assert_equal(_rr("aaa", r"a*", "X", "g"), "X")
    assert_equal(_rr("aaa", r"a*", "X"), "X")
    assert_equal(_rr("aaab", r"a*", "X", "g"), "XbX")
    assert_equal(_rr("xaaay", r"a*", "X", "g"), "XxXyX")


def test_nonoverlapping_global() raises:
    assert_equal(_rr("aaaa", "aa", "X", "g"), "XX")
    # regexp_replace('abcabc','b','X','g') = 'aXcaXc'
    assert_equal(_rr("abcabc", "b", "X", "g"), "aXcaXc")


# ===========================================================================
# Flags in the flags arg.  (DuckDB oracle.)
#   regexp_replace('ABC','b','X','i')        = 'AXC'
#   regexp_replace('ABCabc','b','X','gi')    = 'AXCaXc'
#   regexp_replace('ABCabc','b','X','ig')    = 'AXCaXc'   (order doesn't matter)
# ===========================================================================

def test_case_insensitive_flag() raises:
    assert_equal(_rr("ABC", "b", "X", "i"), "AXC")


def test_case_insensitive_global_flag() raises:
    assert_equal(_rr("ABCabc", "b", "X", "gi"), "AXCaXc")
    assert_equal(_rr("ABCabc", "b", "X", "ig"), "AXCaXc")


def test_split_g_flag_helper() raises:
    var a = split_g_flag("g")
    assert_equal(a[0], "")
    assert_true(a[1])
    var b = split_g_flag("gi")
    assert_equal(b[0], "i")
    assert_true(b[1])
    var c = split_g_flag("ims")
    assert_equal(c[0], "ims")
    assert_false(c[1])
    var d = split_g_flag("")
    assert_equal(d[0], "")
    assert_false(d[1])


# ===========================================================================
# Empty replacement -> delete the matches.  (DuckDB oracle.)
#   regexp_replace('hello','l','')       = 'helo'
#   regexp_replace('hello','l','','g')   = 'heo'
#   regexp_replace('aXbXc','X','','g')   = 'abc'
# ===========================================================================

def test_empty_replacement_deletes() raises:
    assert_equal(_rr("hello", "l", ""), "helo")
    assert_equal(_rr("hello", "l", "", "g"), "heo")
    assert_equal(_rr("aXbXc", "X", "", "g"), "abc")


# ===========================================================================
# Invalid replacement templates -> input returned UNCHANGED.  (DuckDB oracle.)
#   regexp_replace('aXc','(X)','\2')      = 'aXc'   (out-of-range backref:
#     pattern has 1 group, \2 doesn't exist)
#   regexp_replace('aXc','X','\1')        = 'aXc'   (pattern has 0 groups)
#   regexp_replace('aXc','X','q\&q')      = 'aXc'   (unknown escape \&)
#   regexp_replace('aXc','X','\q')        = 'aXc'   (unknown escape \q)
#   regexp_replace('aXc','X','q\')        = 'aXc'   (trailing backslash)
#   regexp_replace('aXc','(X)','$1')      = 'a$1c'  ($N is a LITERAL, not a
#     backref — DataFusion's syntax is intentionally not accepted)
# ===========================================================================

def test_invalid_template_out_of_range_backref() raises:
    assert_equal(_rr("aXc", r"(X)", r"\2"), "aXc")
    assert_equal(_rr("aXc", "X", r"\1"), "aXc")


def test_invalid_template_unknown_escape() raises:
    assert_equal(_rr("aXc", "X", r"q\&q"), "aXc")
    assert_equal(_rr("aXc", "X", r"\q"), "aXc")


def test_invalid_template_trailing_backslash() raises:
    assert_equal(_rr("aXc", "X", "q\\"), "aXc")


def test_dollar_n_is_literal_not_backref() raises:
    assert_equal(_rr("aXc", r"(X)", r"$1"), "a$1c")


def test_rewrite_template_valid_helper() raises:
    # Valid: literal text, \0 always OK, \1 if >= 1 group, \\.
    assert_true(rewrite_template_valid("plain text", 0))
    assert_true(rewrite_template_valid(r"\0", 0))
    assert_true(rewrite_template_valid(r"x\1y", 1))
    assert_true(rewrite_template_valid(r"\1\2\3", 3))
    assert_true(rewrite_template_valid(r"\\", 0))
    assert_true(rewrite_template_valid(r"a\\b\1", 1))
    assert_true(rewrite_template_valid(r"$1 100% &", 0))   # $, %, & are literal
    # Invalid: out-of-range backref, unknown escape, trailing backslash.
    assert_false(rewrite_template_valid(r"\1", 0))
    assert_false(rewrite_template_valid(r"\2", 1))
    assert_false(rewrite_template_valid(r"\&", 5))
    assert_false(rewrite_template_valid(r"\q", 5))
    assert_false(rewrite_template_valid("x\\", 5))


# ===========================================================================
# Anchored pattern under `g` — `^a` matches only at the absolute start.
# (DuckDB oracle.)
#   regexp_replace('aaa','^a','X','g') = 'Xaa'
# ===========================================================================

def test_anchored_pattern_global() raises:
    assert_equal(_rr("aaa", "^a", "X", "g"), "Xaa")


# ===========================================================================
# Multibyte (byte-oriented matcher; the substituted bytes are pass-through).
# (DuckDB oracle.)
#   regexp_replace('café résumé','é','e','g') = 'cafe resume'
# ===========================================================================

def test_multibyte_passthrough() raises:
    assert_equal(_rr("café résumé", "é", "e", "g"), "cafe resume")


# ===========================================================================
# Column kernel: a StringArray with a NULL row.
# ===========================================================================

def test_column_kernel_with_null_row() raises:
    var arr = StringArray.from_strings(["the cat", "MISSING", "a hat", "no vowels here"])
    var vbm = Bitmap.create_all_valid(4)
    vbm.clear(1)  # row 1 is NULL
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = RegexProgram.compile("at", "")
    var out = eval_regexp_replace(arr^, prog, "XX", True)
    assert_equal(out.length, 4)
    assert_equal(out.null_count, 1)
    assert_true(out.is_null(1))                # NULL row stays NULL
    assert_false(out.is_null(0))
    assert_equal(out.get(0), "the cXX")        # 'cat' -> 'cXX'
    assert_equal(out.get(2), "a hXX")          # 'hat' -> 'hXX'
    assert_equal(out.get(3), "no vowels here") # no 'at' -> unchanged


def test_column_kernel_all_valid() raises:
    var sa = _rr_col(["foo bar", "bar baz", "qux"], "ba.", "ZZ", "g")
    assert_equal(sa.length, 3)
    assert_equal(sa.get(0), "foo ZZ")
    assert_equal(sa.get(1), "ZZ ZZ")
    assert_equal(sa.get(2), "qux")
    assert_equal(sa.null_count, 0)


def test_column_kernel_invalid_template_echoes_input() raises:
    # An invalid template -> every row returned unchanged (matches DuckDB).
    var sa = _rr_col(["aXc", "bXd", "no x here"], "X", r"\1", "g")
    assert_equal(sa.get(0), "aXc")
    assert_equal(sa.get(1), "bXd")
    assert_equal(sa.get(2), "no x here")


# ===========================================================================
# Engine dispatch — _eval_column_expr over a hand-built RecordBatch +
# Expr.regexp_replace (the same compute path PipelineCompiler drives).
# ===========================================================================

def test_engine_regexp_replace_projection() raises:
    var batch = _str_col(["the cat sat", "a flat mat", "nothing here"])
    # SELECT regexp_replace(s, 'at', '[at]', 'g')
    var e = Expr.regexp_replace(Expr.col_idx(0), "at", "[at]", "g")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.STRING)
    var sa = col.as_string()
    assert_equal(sa.get(0), "the c[at] s[at]")
    assert_equal(sa.get(1), "a fl[at] m[at]")
    assert_equal(sa.get(2), "nothing here")


def test_engine_regexp_replace_backref_projection() raises:
    var batch = _str_col(["2026-05-12", "1999-12-31"])
    # SELECT regexp_replace(s, '(\d+)-(\d+)-(\d+)', '\3/\2/\1')
    var e = Expr.regexp_replace(Expr.col_idx(0), r"(\d+)-(\d+)-(\d+)", r"\3/\2/\1")
    var col = _eval_column_expr(e, batch)
    var sa = col.as_string()
    assert_equal(sa.get(0), "12/05/2026")
    assert_equal(sa.get(1), "31/12/1999")


def test_engine_regexp_replace_first_only() raises:
    var batch = _str_col(["a-b-c"])
    # SELECT regexp_replace(s, '-', '_')  -- no `g`, first only
    var e = Expr.regexp_replace(Expr.col_idx(0), "-", "_")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.as_string().get(0), "a_b-c")


def test_engine_regexp_replace_case_insensitive() raises:
    var batch = _str_col(["ABCabc"])
    # SELECT regexp_replace(s, 'b', 'X', 'gi')
    var e = Expr.regexp_replace(Expr.col_idx(0), "b", "X", "gi")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.as_string().get(0), "AXCaXc")


def test_engine_regexp_replace_zerowidth() raises:
    var batch = _str_col(["abc"])
    # SELECT regexp_replace(s, '', 'X', 'g') = 'XaXbXcX'
    var e = Expr.regexp_replace(Expr.col_idx(0), "", "X", "g")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.as_string().get(0), "XaXbXcX")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
