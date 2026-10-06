# =============================================================================
# REGEXP PIKE-VM DIFFERENTIAL ORACLE — 414 cases x 5 assertions, oracle = DuckDB.
# =============================================================================
#
# ⛔ WHY THIS FILE EXISTS.  FIX A rewrote the Pike VM's epsilon closure
# (`RegexProgram._closure`, `komira_column_kernels/regexp_nfa.mojo`): the per-thread
# `List[Int]` capture vectors became REGIONS OF ONE FLAT STACK, the `SPLIT` arm
# now duplicates a region instead of copying a list, and the `SAVE` arm mutates
# its region IN PLACE.  That is exactly the machinery that decides WHICH SPAN
# each capture group ends up holding, and a value-only unit test with
# hand-picked cases is a weak instrument against it: the failure mode is a
# capture that is subtly wrong under one quantifier/alternation shape.
#
# So: 23 patterns x 18 subjects, every combination, five answers each
# (`regexp_matches`, first-only `regexp_replace`, global `regexp_replace`,
# `regexp_extract` group 0 and group 1), all generated from DuckDB v1.5.3 — the
# same RE2-backed oracle the sibling regexp tests use — and pasted in as
# literals.  No live-oracle dependency.
#
# The patterns are chosen to hit the rewritten arms, not to be pretty:
# alternation and nested alternation (SPLIT), greedy vs non-greedy and counted
# repetition (SPLIT + the `seen` stamp on a loop), nested and optional groups
# (SAVE ordering), anchors crossed with captures (Fix B's seed filter meeting
# Fix A's stack), zero-width matches, character classes, and UTF-8 subjects.
#
# ⚠ ORDER OF VALIDATION, and it matters: this table was run against the
# PRE-FIX-A engine first.  Every case listed in `_KNOWN_DIVERGENCES` below
# diverged from DuckDB THERE TOO, so it is pre-existing behaviour and is
# recorded, not silently dropped; everything else was GREEN before and must
# stay green.  A new red here is a Fix A regression, full stop.
#
# Regenerate: the scratch generator is not committed -- it is ~40 lines of
# `duckdb -json` over the tables below.  Re-deriving it is cheaper than
# trusting a stale one.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_column_kernels.regexp_nfa import RegexProgram
from komira_column_kernels.regexp_functions import (
    regexp_like_scalar,
    regexp_replace_scalar,
    regexp_extract_scalar,
)


def _patterns() -> List[String]:
    var v = List[String]()
    v.append("(a|b)+")
    v.append("(a*)(b*)")
    v.append("(a+?)(a*)")
    v.append("(ab|a)(b?)")
    v.append("((a)|(b))+")
    v.append("(a{2,3})(a*)")
    v.append("(a|ab)(c|bcd)")
    v.append("((a)(b))(c)")
    v.append("(a(b(c)?)?)")
    v.append("^(a+)(b*)$")
    v.append("^(\\w+)")
    v.append("(\\w+)$")
    v.append("^a|b")
    v.append("(^a)|(b)")
    v.append("\\A(a*)")
    v.append("([^/]+)")
    v.append("([a-c]+)(.*)")
    v.append("(\\d+)-(\\d+)")
    v.append("(\\s+)")
    v.append("()")
    v.append("(a*)")
    v.append("\\b")
    v.append("^https?://(?:www\\.)?([^/]+)/.*$")
    return v^

def _repls() -> List[String]:
    var v = List[String]()
    v.append("<\\1>")
    v.append("<\\1|\\2>")
    v.append("<\\1|\\2>")
    v.append("<\\1|\\2>")
    v.append("<\\1|\\2|\\3>")
    v.append("<\\1|\\2>")
    v.append("<\\1|\\2>")
    v.append("<\\1|\\2|\\3|\\4>")
    v.append("<\\1|\\2|\\3>")
    v.append("<\\1|\\2>")
    v.append("<\\1>")
    v.append("<\\1>")
    v.append("X")
    v.append("<\\1|\\2>")
    v.append("<\\1>")
    v.append("<\\1>")
    v.append("<\\1|\\2>")
    v.append("\\2-\\1")
    v.append("_")
    v.append("X")
    v.append("[\\1]")
    v.append("|")
    v.append("\\1")
    return v^

def _subjects() -> List[String]:
    var v = List[String]()
    v.append("")
    v.append("a")
    v.append("b")
    v.append("ab")
    v.append("aab")
    v.append("abc")
    v.append("aaa")
    v.append("abab")
    v.append("bbb")
    v.append("a b")
    v.append("  ")
    v.append("12-34")
    v.append("x/y/z")
    v.append("a\nb")
    v.append("http://www.example.com/p/q")
    v.append("http:%2F%2Fx")
    v.append("доп_приборы")
    v.append("aдb")
    return v^

# pi, si, matches, replace_first, replace_global, extract0, extract1
def _expected() -> List[String]:
    """Flat: 5 entries per case, in (pattern, subject) order.  A Bool is
    spelled \"T\"/\"F\" so the whole oracle is ONE table and cannot desync."""
    var v = List[String]()
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a>"); v.append("<a>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<b>"); v.append("<b>"); v.append("b"); v.append("b")
    v.append("T"); v.append("<b>"); v.append("<b>"); v.append("ab"); v.append("b")
    v.append("T"); v.append("<b>"); v.append("<b>"); v.append("aab"); v.append("b")
    v.append("T"); v.append("<b>c"); v.append("<b>c"); v.append("ab"); v.append("b")
    v.append("T"); v.append("<a>"); v.append("<a>"); v.append("aaa"); v.append("a")
    v.append("T"); v.append("<b>"); v.append("<b>"); v.append("abab"); v.append("b")
    v.append("T"); v.append("<b>"); v.append("<b>"); v.append("bbb"); v.append("b")
    v.append("T"); v.append("<a> b"); v.append("<a> <b>"); v.append("a"); v.append("a")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("<a>\nb"); v.append("<a>\n<b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("http://www.ex<a>mple.com/p/q"); v.append("http://www.ex<a>mple.com/p/q"); v.append("a"); v.append("a")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a>дb"); v.append("<a>д<b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<|>"); v.append("<|>"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>"); v.append("<a|>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<|b>"); v.append("<|b>"); v.append("b"); v.append("")
    v.append("T"); v.append("<a|b>"); v.append("<a|b>"); v.append("ab"); v.append("a")
    v.append("T"); v.append("<aa|b>"); v.append("<aa|b>"); v.append("aab"); v.append("aa")
    v.append("T"); v.append("<a|b>c"); v.append("<a|b>c<|>"); v.append("ab"); v.append("a")
    v.append("T"); v.append("<aaa|>"); v.append("<aaa|>"); v.append("aaa"); v.append("aaa")
    v.append("T"); v.append("<a|b>ab"); v.append("<a|b><a|b>"); v.append("ab"); v.append("a")
    v.append("T"); v.append("<|bbb>"); v.append("<|bbb>"); v.append("bbb"); v.append("")
    v.append("T"); v.append("<a|> b"); v.append("<a|> <|b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<|>  "); v.append("<|> <|> <|>"); v.append(""); v.append("")
    v.append("T"); v.append("<|>12-34"); v.append("<|>1<|>2<|>-<|>3<|>4<|>"); v.append(""); v.append("")
    v.append("T"); v.append("<|>x/y/z"); v.append("<|>x<|>/<|>y<|>/<|>z<|>"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>\nb"); v.append("<a|>\n<|b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<|>http://www.example.com/p/q"); v.append("<|>h<|>t<|>t<|>p<|>:<|>/<|>/<|>w<|>w<|>w<|>.<|>e<|>x<a|>m<|>p<|>l<|>e<|>.<|>c<|>o<|>m<|>/<|>p<|>/<|>q<|>"); v.append(""); v.append("")
    v.append("T"); v.append("<|>http:%2F%2Fx"); v.append("<|>h<|>t<|>t<|>p<|>:<|>%<|>2<|>F<|>%<|>2<|>F<|>x<|>"); v.append(""); v.append("")
    v.append("T"); v.append("<|>доп_приборы"); v.append("<|>д<|>о<|>п<|>_<|>п<|>р<|>и<|>б<|>о<|>р<|>ы<|>"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>дb"); v.append("<a|>д<|b>"); v.append("a"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a|>"); v.append("<a|>"); v.append("a"); v.append("a")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>b"); v.append("<a|>b"); v.append("a"); v.append("a")
    v.append("T"); v.append("<a|a>b"); v.append("<a|a>b"); v.append("aa"); v.append("a")
    v.append("T"); v.append("<a|>bc"); v.append("<a|>bc"); v.append("a"); v.append("a")
    v.append("T"); v.append("<a|aa>"); v.append("<a|aa>"); v.append("aaa"); v.append("a")
    v.append("T"); v.append("<a|>bab"); v.append("<a|>b<a|>b"); v.append("a"); v.append("a")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("T"); v.append("<a|> b"); v.append("<a|> b"); v.append("a"); v.append("a")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>\nb"); v.append("<a|>\nb"); v.append("a"); v.append("a")
    v.append("T"); v.append("http://www.ex<a|>mple.com/p/q"); v.append("http://www.ex<a|>mple.com/p/q"); v.append("a"); v.append("a")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>дb"); v.append("<a|>дb"); v.append("a"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a|>"); v.append("<a|>"); v.append("a"); v.append("a")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("T"); v.append("<ab|>"); v.append("<ab|>"); v.append("ab"); v.append("ab")
    v.append("T"); v.append("<a|>ab"); v.append("<a|><ab|>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<ab|>c"); v.append("<ab|>c"); v.append("ab"); v.append("ab")
    v.append("T"); v.append("<a|>aa"); v.append("<a|><a|><a|>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<ab|>ab"); v.append("<ab|><ab|>"); v.append("ab"); v.append("ab")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("T"); v.append("<a|> b"); v.append("<a|> b"); v.append("a"); v.append("a")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>\nb"); v.append("<a|>\nb"); v.append("a"); v.append("a")
    v.append("T"); v.append("http://www.ex<a|>mple.com/p/q"); v.append("http://www.ex<a|>mple.com/p/q"); v.append("a"); v.append("a")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>дb"); v.append("<a|>дb"); v.append("a"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a|a|>"); v.append("<a|a|>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<b||b>"); v.append("<b||b>"); v.append("b"); v.append("b")
    v.append("T"); v.append("<b|a|b>"); v.append("<b|a|b>"); v.append("ab"); v.append("b")
    v.append("T"); v.append("<b|a|b>"); v.append("<b|a|b>"); v.append("aab"); v.append("b")
    v.append("T"); v.append("<b|a|b>c"); v.append("<b|a|b>c"); v.append("ab"); v.append("b")
    v.append("T"); v.append("<a|a|>"); v.append("<a|a|>"); v.append("aaa"); v.append("a")
    v.append("T"); v.append("<b|a|b>"); v.append("<b|a|b>"); v.append("abab"); v.append("b")
    v.append("T"); v.append("<b||b>"); v.append("<b||b>"); v.append("bbb"); v.append("b")
    v.append("T"); v.append("<a|a|> b"); v.append("<a|a|> <b||b>"); v.append("a"); v.append("a")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("<a|a|>\nb"); v.append("<a|a|>\n<b||b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("http://www.ex<a|a|>mple.com/p/q"); v.append("http://www.ex<a|a|>mple.com/p/q"); v.append("a"); v.append("a")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a|a|>дb"); v.append("<a|a|>д<b||b>"); v.append("a"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("F"); v.append("a"); v.append("a"); v.append(""); v.append("")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("F"); v.append("ab"); v.append("ab"); v.append(""); v.append("")
    v.append("T"); v.append("<aa|>b"); v.append("<aa|>b"); v.append("aa"); v.append("aa")
    v.append("F"); v.append("abc"); v.append("abc"); v.append(""); v.append("")
    v.append("T"); v.append("<aaa|>"); v.append("<aaa|>"); v.append("aaa"); v.append("aaa")
    v.append("F"); v.append("abab"); v.append("abab"); v.append(""); v.append("")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("F"); v.append("a b"); v.append("a b"); v.append(""); v.append("")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("F"); v.append("a\nb"); v.append("a\nb"); v.append(""); v.append("")
    v.append("F"); v.append("http://www.example.com/p/q"); v.append("http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("F"); v.append("aдb"); v.append("aдb"); v.append(""); v.append("")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("F"); v.append("a"); v.append("a"); v.append(""); v.append("")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("F"); v.append("ab"); v.append("ab"); v.append(""); v.append("")
    v.append("F"); v.append("aab"); v.append("aab"); v.append(""); v.append("")
    v.append("T"); v.append("<ab|c>"); v.append("<ab|c>"); v.append("abc"); v.append("ab")
    v.append("F"); v.append("aaa"); v.append("aaa"); v.append(""); v.append("")
    v.append("F"); v.append("abab"); v.append("abab"); v.append(""); v.append("")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("F"); v.append("a b"); v.append("a b"); v.append(""); v.append("")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("F"); v.append("a\nb"); v.append("a\nb"); v.append(""); v.append("")
    v.append("F"); v.append("http://www.example.com/p/q"); v.append("http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("F"); v.append("aдb"); v.append("aдb"); v.append(""); v.append("")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("F"); v.append("a"); v.append("a"); v.append(""); v.append("")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("F"); v.append("ab"); v.append("ab"); v.append(""); v.append("")
    v.append("F"); v.append("aab"); v.append("aab"); v.append(""); v.append("")
    v.append("T"); v.append("<ab|a|b|c>"); v.append("<ab|a|b|c>"); v.append("abc"); v.append("ab")
    v.append("F"); v.append("aaa"); v.append("aaa"); v.append(""); v.append("")
    v.append("F"); v.append("abab"); v.append("abab"); v.append(""); v.append("")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("F"); v.append("a b"); v.append("a b"); v.append(""); v.append("")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("F"); v.append("a\nb"); v.append("a\nb"); v.append(""); v.append("")
    v.append("F"); v.append("http://www.example.com/p/q"); v.append("http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("F"); v.append("aдb"); v.append("aдb"); v.append(""); v.append("")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a||>"); v.append("<a||>"); v.append("a"); v.append("a")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("T"); v.append("<ab|b|>"); v.append("<ab|b|>"); v.append("ab"); v.append("ab")
    v.append("T"); v.append("<a||>ab"); v.append("<a||><ab|b|>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<abc|bc|c>"); v.append("<abc|bc|c>"); v.append("abc"); v.append("abc")
    v.append("T"); v.append("<a||>aa"); v.append("<a||><a||><a||>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<ab|b|>ab"); v.append("<ab|b|><ab|b|>"); v.append("ab"); v.append("ab")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("T"); v.append("<a||> b"); v.append("<a||> b"); v.append("a"); v.append("a")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("<a||>\nb"); v.append("<a||>\nb"); v.append("a"); v.append("a")
    v.append("T"); v.append("http://www.ex<a||>mple.com/p/q"); v.append("http://www.ex<a||>mple.com/p/q"); v.append("a"); v.append("a")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a||>дb"); v.append("<a||>дb"); v.append("a"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a|>"); v.append("<a|>"); v.append("a"); v.append("a")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("T"); v.append("<a|b>"); v.append("<a|b>"); v.append("ab"); v.append("a")
    v.append("T"); v.append("<aa|b>"); v.append("<aa|b>"); v.append("aab"); v.append("aa")
    v.append("F"); v.append("abc"); v.append("abc"); v.append(""); v.append("")
    v.append("T"); v.append("<aaa|>"); v.append("<aaa|>"); v.append("aaa"); v.append("aaa")
    v.append("F"); v.append("abab"); v.append("abab"); v.append(""); v.append("")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("F"); v.append("a b"); v.append("a b"); v.append(""); v.append("")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("F"); v.append("a\nb"); v.append("a\nb"); v.append(""); v.append("")
    v.append("F"); v.append("http://www.example.com/p/q"); v.append("http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("F"); v.append("aдb"); v.append("aдb"); v.append(""); v.append("")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a>"); v.append("<a>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<b>"); v.append("<b>"); v.append("b"); v.append("b")
    v.append("T"); v.append("<ab>"); v.append("<ab>"); v.append("ab"); v.append("ab")
    v.append("T"); v.append("<aab>"); v.append("<aab>"); v.append("aab"); v.append("aab")
    v.append("T"); v.append("<abc>"); v.append("<abc>"); v.append("abc"); v.append("abc")
    v.append("T"); v.append("<aaa>"); v.append("<aaa>"); v.append("aaa"); v.append("aaa")
    v.append("T"); v.append("<abab>"); v.append("<abab>"); v.append("abab"); v.append("abab")
    v.append("T"); v.append("<bbb>"); v.append("<bbb>"); v.append("bbb"); v.append("bbb")
    v.append("T"); v.append("<a> b"); v.append("<a> b"); v.append("a"); v.append("a")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("T"); v.append("<12>-34"); v.append("<12>-34"); v.append("12"); v.append("12")
    v.append("T"); v.append("<x>/y/z"); v.append("<x>/y/z"); v.append("x"); v.append("x")
    v.append("T"); v.append("<a>\nb"); v.append("<a>\nb"); v.append("a"); v.append("a")
    v.append("T"); v.append("<http>://www.example.com/p/q"); v.append("<http>://www.example.com/p/q"); v.append("http"); v.append("http")
    v.append("T"); v.append("<http>:%2F%2Fx"); v.append("<http>:%2F%2Fx"); v.append("http"); v.append("http")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a>дb"); v.append("<a>дb"); v.append("a"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a>"); v.append("<a>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<b>"); v.append("<b>"); v.append("b"); v.append("b")
    v.append("T"); v.append("<ab>"); v.append("<ab>"); v.append("ab"); v.append("ab")
    v.append("T"); v.append("<aab>"); v.append("<aab>"); v.append("aab"); v.append("aab")
    v.append("T"); v.append("<abc>"); v.append("<abc>"); v.append("abc"); v.append("abc")
    v.append("T"); v.append("<aaa>"); v.append("<aaa>"); v.append("aaa"); v.append("aaa")
    v.append("T"); v.append("<abab>"); v.append("<abab>"); v.append("abab"); v.append("abab")
    v.append("T"); v.append("<bbb>"); v.append("<bbb>"); v.append("bbb"); v.append("bbb")
    v.append("T"); v.append("a <b>"); v.append("a <b>"); v.append("b"); v.append("b")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("T"); v.append("12-<34>"); v.append("12-<34>"); v.append("34"); v.append("34")
    v.append("T"); v.append("x/y/<z>"); v.append("x/y/<z>"); v.append("z"); v.append("z")
    v.append("T"); v.append("a\n<b>"); v.append("a\n<b>"); v.append("b"); v.append("b")
    v.append("T"); v.append("http://www.example.com/p/<q>"); v.append("http://www.example.com/p/<q>"); v.append("q"); v.append("q")
    v.append("T"); v.append("http:%2F%<2Fx>"); v.append("http:%2F%<2Fx>"); v.append("2Fx"); v.append("2Fx")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("aд<b>"); v.append("aд<b>"); v.append("b"); v.append("b")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("X"); v.append("X"); v.append("a"); v.append("")
    v.append("T"); v.append("X"); v.append("X"); v.append("b"); v.append("")
    v.append("T"); v.append("Xb"); v.append("XX"); v.append("a"); v.append("")
    v.append("T"); v.append("Xab"); v.append("XaX"); v.append("a"); v.append("")
    v.append("T"); v.append("Xbc"); v.append("XXc"); v.append("a"); v.append("")
    v.append("T"); v.append("Xaa"); v.append("Xaa"); v.append("a"); v.append("")
    v.append("T"); v.append("Xbab"); v.append("XXaX"); v.append("a"); v.append("")
    v.append("T"); v.append("Xbb"); v.append("XXX"); v.append("b"); v.append("")
    v.append("T"); v.append("X b"); v.append("X X"); v.append("a"); v.append("")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("X\nb"); v.append("X\nX"); v.append("a"); v.append("")
    v.append("F"); v.append("http://www.example.com/p/q"); v.append("http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("Xдb"); v.append("XдX"); v.append("a"); v.append("")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a|>"); v.append("<a|>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<|b>"); v.append("<|b>"); v.append("b"); v.append("")
    v.append("T"); v.append("<a|>b"); v.append("<a|><|b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<a|>ab"); v.append("<a|>a<|b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<a|>bc"); v.append("<a|><|b>c"); v.append("a"); v.append("a")
    v.append("T"); v.append("<a|>aa"); v.append("<a|>aa"); v.append("a"); v.append("a")
    v.append("T"); v.append("<a|>bab"); v.append("<a|><|b>a<|b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<|b>bb"); v.append("<|b><|b><|b>"); v.append("b"); v.append("")
    v.append("T"); v.append("<a|> b"); v.append("<a|> <|b>"); v.append("a"); v.append("a")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>\nb"); v.append("<a|>\n<|b>"); v.append("a"); v.append("a")
    v.append("F"); v.append("http://www.example.com/p/q"); v.append("http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>дb"); v.append("<a|>д<|b>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<>"); v.append("<>"); v.append(""); v.append("")
    v.append("T"); v.append("<a>"); v.append("<a>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<>b"); v.append("<>b"); v.append(""); v.append("")
    v.append("T"); v.append("<a>b"); v.append("<a>b"); v.append("a"); v.append("a")
    v.append("T"); v.append("<aa>b"); v.append("<aa>b"); v.append("aa"); v.append("aa")
    v.append("T"); v.append("<a>bc"); v.append("<a>bc"); v.append("a"); v.append("a")
    v.append("T"); v.append("<aaa>"); v.append("<aaa>"); v.append("aaa"); v.append("aaa")
    v.append("T"); v.append("<a>bab"); v.append("<a>bab"); v.append("a"); v.append("a")
    v.append("T"); v.append("<>bbb"); v.append("<>bbb"); v.append(""); v.append("")
    v.append("T"); v.append("<a> b"); v.append("<a> b"); v.append("a"); v.append("a")
    v.append("T"); v.append("<>  "); v.append("<>  "); v.append(""); v.append("")
    v.append("T"); v.append("<>12-34"); v.append("<>12-34"); v.append(""); v.append("")
    v.append("T"); v.append("<>x/y/z"); v.append("<>x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("<a>\nb"); v.append("<a>\nb"); v.append("a"); v.append("a")
    v.append("T"); v.append("<>http://www.example.com/p/q"); v.append("<>http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("T"); v.append("<>http:%2F%2Fx"); v.append("<>http:%2F%2Fx"); v.append(""); v.append("")
    v.append("T"); v.append("<>доп_приборы"); v.append("<>доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a>дb"); v.append("<a>дb"); v.append("a"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a>"); v.append("<a>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<b>"); v.append("<b>"); v.append("b"); v.append("b")
    v.append("T"); v.append("<ab>"); v.append("<ab>"); v.append("ab"); v.append("ab")
    v.append("T"); v.append("<aab>"); v.append("<aab>"); v.append("aab"); v.append("aab")
    v.append("T"); v.append("<abc>"); v.append("<abc>"); v.append("abc"); v.append("abc")
    v.append("T"); v.append("<aaa>"); v.append("<aaa>"); v.append("aaa"); v.append("aaa")
    v.append("T"); v.append("<abab>"); v.append("<abab>"); v.append("abab"); v.append("abab")
    v.append("T"); v.append("<bbb>"); v.append("<bbb>"); v.append("bbb"); v.append("bbb")
    v.append("T"); v.append("<a b>"); v.append("<a b>"); v.append("a b"); v.append("a b")
    v.append("T"); v.append("<  >"); v.append("<  >"); v.append("  "); v.append("  ")
    v.append("T"); v.append("<12-34>"); v.append("<12-34>"); v.append("12-34"); v.append("12-34")
    v.append("T"); v.append("<x>/y/z"); v.append("<x>/<y>/<z>"); v.append("x"); v.append("x")
    v.append("T"); v.append("<a\nb>"); v.append("<a\nb>"); v.append("a\nb"); v.append("a\nb")
    v.append("T"); v.append("<http:>//www.example.com/p/q"); v.append("<http:>//<www.example.com>/<p>/<q>"); v.append("http:"); v.append("http:")
    v.append("T"); v.append("<http:%2F%2Fx>"); v.append("<http:%2F%2Fx>"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx")
    v.append("T"); v.append("<доп_приборы>"); v.append("<доп_приборы>"); v.append("доп_приборы"); v.append("доп_приборы")
    v.append("T"); v.append("<aдb>"); v.append("<aдb>"); v.append("aдb"); v.append("aдb")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("<a|>"); v.append("<a|>"); v.append("a"); v.append("a")
    v.append("T"); v.append("<b|>"); v.append("<b|>"); v.append("b"); v.append("b")
    v.append("T"); v.append("<ab|>"); v.append("<ab|>"); v.append("ab"); v.append("ab")
    v.append("T"); v.append("<aab|>"); v.append("<aab|>"); v.append("aab"); v.append("aab")
    v.append("T"); v.append("<abc|>"); v.append("<abc|>"); v.append("abc"); v.append("abc")
    v.append("T"); v.append("<aaa|>"); v.append("<aaa|>"); v.append("aaa"); v.append("aaa")
    v.append("T"); v.append("<abab|>"); v.append("<abab|>"); v.append("abab"); v.append("abab")
    v.append("T"); v.append("<bbb|>"); v.append("<bbb|>"); v.append("bbb"); v.append("bbb")
    v.append("T"); v.append("<a| b>"); v.append("<a| b>"); v.append("a b"); v.append("a")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("<a|>\nb"); v.append("<a|>\n<b|>"); v.append("a"); v.append("a")
    v.append("T"); v.append("http://www.ex<a|mple.com/p/q>"); v.append("http://www.ex<a|mple.com/p/q>"); v.append("ample.com/p/q"); v.append("a")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("T"); v.append("<a|дb>"); v.append("<a|дb>"); v.append("aдb"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("F"); v.append("a"); v.append("a"); v.append(""); v.append("")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("F"); v.append("ab"); v.append("ab"); v.append(""); v.append("")
    v.append("F"); v.append("aab"); v.append("aab"); v.append(""); v.append("")
    v.append("F"); v.append("abc"); v.append("abc"); v.append(""); v.append("")
    v.append("F"); v.append("aaa"); v.append("aaa"); v.append(""); v.append("")
    v.append("F"); v.append("abab"); v.append("abab"); v.append(""); v.append("")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("F"); v.append("a b"); v.append("a b"); v.append(""); v.append("")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("T"); v.append("34-12"); v.append("34-12"); v.append("12-34"); v.append("12")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("F"); v.append("a\nb"); v.append("a\nb"); v.append(""); v.append("")
    v.append("F"); v.append("http://www.example.com/p/q"); v.append("http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("F"); v.append("aдb"); v.append("aдb"); v.append(""); v.append("")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("F"); v.append("a"); v.append("a"); v.append(""); v.append("")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("F"); v.append("ab"); v.append("ab"); v.append(""); v.append("")
    v.append("F"); v.append("aab"); v.append("aab"); v.append(""); v.append("")
    v.append("F"); v.append("abc"); v.append("abc"); v.append(""); v.append("")
    v.append("F"); v.append("aaa"); v.append("aaa"); v.append(""); v.append("")
    v.append("F"); v.append("abab"); v.append("abab"); v.append(""); v.append("")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("T"); v.append("a_b"); v.append("a_b"); v.append(" "); v.append(" ")
    v.append("T"); v.append("_"); v.append("_"); v.append("  "); v.append("  ")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("T"); v.append("a_b"); v.append("a_b"); v.append("\n"); v.append("\n")
    v.append("F"); v.append("http://www.example.com/p/q"); v.append("http://www.example.com/p/q"); v.append(""); v.append("")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("F"); v.append("aдb"); v.append("aдb"); v.append(""); v.append("")
    v.append("T"); v.append("X"); v.append("X"); v.append(""); v.append("")
    v.append("T"); v.append("Xa"); v.append("XaX"); v.append(""); v.append("")
    v.append("T"); v.append("Xb"); v.append("XbX"); v.append(""); v.append("")
    v.append("T"); v.append("Xab"); v.append("XaXbX"); v.append(""); v.append("")
    v.append("T"); v.append("Xaab"); v.append("XaXaXbX"); v.append(""); v.append("")
    v.append("T"); v.append("Xabc"); v.append("XaXbXcX"); v.append(""); v.append("")
    v.append("T"); v.append("Xaaa"); v.append("XaXaXaX"); v.append(""); v.append("")
    v.append("T"); v.append("Xabab"); v.append("XaXbXaXbX"); v.append(""); v.append("")
    v.append("T"); v.append("Xbbb"); v.append("XbXbXbX"); v.append(""); v.append("")
    v.append("T"); v.append("Xa b"); v.append("XaX XbX"); v.append(""); v.append("")
    v.append("T"); v.append("X  "); v.append("X X X"); v.append(""); v.append("")
    v.append("T"); v.append("X12-34"); v.append("X1X2X-X3X4X"); v.append(""); v.append("")
    v.append("T"); v.append("Xx/y/z"); v.append("XxX/XyX/XzX"); v.append(""); v.append("")
    v.append("T"); v.append("Xa\nb"); v.append("XaX\nXbX"); v.append(""); v.append("")
    v.append("T"); v.append("Xhttp://www.example.com/p/q"); v.append("XhXtXtXpX:X/X/XwXwXwX.XeXxXaXmXpXlXeX.XcXoXmX/XpX/XqX"); v.append(""); v.append("")
    v.append("T"); v.append("Xhttp:%2F%2Fx"); v.append("XhXtXtXpX:X%X2XFX%X2XFXxX"); v.append(""); v.append("")
    v.append("T"); v.append("Xдоп_приборы"); v.append("XдXоXпX_XпXрXиXбXоXрXыX"); v.append(""); v.append("")
    v.append("T"); v.append("Xaдb"); v.append("XaXдXbX"); v.append(""); v.append("")
    v.append("T"); v.append("[]"); v.append("[]"); v.append(""); v.append("")
    v.append("T"); v.append("[a]"); v.append("[a]"); v.append("a"); v.append("a")
    v.append("T"); v.append("[]b"); v.append("[]b[]"); v.append(""); v.append("")
    v.append("T"); v.append("[a]b"); v.append("[a]b[]"); v.append("a"); v.append("a")
    v.append("T"); v.append("[aa]b"); v.append("[aa]b[]"); v.append("aa"); v.append("aa")
    v.append("T"); v.append("[a]bc"); v.append("[a]b[]c[]"); v.append("a"); v.append("a")
    v.append("T"); v.append("[aaa]"); v.append("[aaa]"); v.append("aaa"); v.append("aaa")
    v.append("T"); v.append("[a]bab"); v.append("[a]b[a]b[]"); v.append("a"); v.append("a")
    v.append("T"); v.append("[]bbb"); v.append("[]b[]b[]b[]"); v.append(""); v.append("")
    v.append("T"); v.append("[a] b"); v.append("[a] []b[]"); v.append("a"); v.append("a")
    v.append("T"); v.append("[]  "); v.append("[] [] []"); v.append(""); v.append("")
    v.append("T"); v.append("[]12-34"); v.append("[]1[]2[]-[]3[]4[]"); v.append(""); v.append("")
    v.append("T"); v.append("[]x/y/z"); v.append("[]x[]/[]y[]/[]z[]"); v.append(""); v.append("")
    v.append("T"); v.append("[a]\nb"); v.append("[a]\n[]b[]"); v.append("a"); v.append("a")
    v.append("T"); v.append("[]http://www.example.com/p/q"); v.append("[]h[]t[]t[]p[]:[]/[]/[]w[]w[]w[].[]e[]x[a]m[]p[]l[]e[].[]c[]o[]m[]/[]p[]/[]q[]"); v.append(""); v.append("")
    v.append("T"); v.append("[]http:%2F%2Fx"); v.append("[]h[]t[]t[]p[]:[]%[]2[]F[]%[]2[]F[]x[]"); v.append(""); v.append("")
    v.append("T"); v.append("[]доп_приборы"); v.append("[]д[]о[]п[]_[]п[]р[]и[]б[]о[]р[]ы[]"); v.append(""); v.append("")
    v.append("T"); v.append("[a]дb"); v.append("[a]д[]b[]"); v.append("a"); v.append("a")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("T"); v.append("|a"); v.append("|a|"); v.append(""); v.append("")
    v.append("T"); v.append("|b"); v.append("|b|"); v.append(""); v.append("")
    v.append("T"); v.append("|ab"); v.append("|ab|"); v.append(""); v.append("")
    v.append("T"); v.append("|aab"); v.append("|aab|"); v.append(""); v.append("")
    v.append("T"); v.append("|abc"); v.append("|abc|"); v.append(""); v.append("")
    v.append("T"); v.append("|aaa"); v.append("|aaa|"); v.append(""); v.append("")
    v.append("T"); v.append("|abab"); v.append("|abab|"); v.append(""); v.append("")
    v.append("T"); v.append("|bbb"); v.append("|bbb|"); v.append(""); v.append("")
    v.append("T"); v.append("|a b"); v.append("|a| |b|"); v.append(""); v.append("")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("T"); v.append("|12-34"); v.append("|12|-|34|"); v.append(""); v.append("")
    v.append("T"); v.append("|x/y/z"); v.append("|x|/|y|/|z|"); v.append(""); v.append("")
    v.append("T"); v.append("|a\nb"); v.append("|a|\n|b|"); v.append(""); v.append("")
    v.append("T"); v.append("|http://www.example.com/p/q"); v.append("|http|://|www|.|example|.|com|/|p|/|q|"); v.append(""); v.append("")
    v.append("T"); v.append("|http:%2F%2Fx"); v.append("|http|:%|2F|%|2Fx|"); v.append(""); v.append("")
    v.append("T"); v.append("доп|_приборы"); v.append("доп|_|приборы"); v.append(""); v.append("")
    v.append("T"); v.append("|aдb"); v.append("|a|д|b|"); v.append(""); v.append("")
    v.append("F"); v.append(""); v.append(""); v.append(""); v.append("")
    v.append("F"); v.append("a"); v.append("a"); v.append(""); v.append("")
    v.append("F"); v.append("b"); v.append("b"); v.append(""); v.append("")
    v.append("F"); v.append("ab"); v.append("ab"); v.append(""); v.append("")
    v.append("F"); v.append("aab"); v.append("aab"); v.append(""); v.append("")
    v.append("F"); v.append("abc"); v.append("abc"); v.append(""); v.append("")
    v.append("F"); v.append("aaa"); v.append("aaa"); v.append(""); v.append("")
    v.append("F"); v.append("abab"); v.append("abab"); v.append(""); v.append("")
    v.append("F"); v.append("bbb"); v.append("bbb"); v.append(""); v.append("")
    v.append("F"); v.append("a b"); v.append("a b"); v.append(""); v.append("")
    v.append("F"); v.append("  "); v.append("  "); v.append(""); v.append("")
    v.append("F"); v.append("12-34"); v.append("12-34"); v.append(""); v.append("")
    v.append("F"); v.append("x/y/z"); v.append("x/y/z"); v.append(""); v.append("")
    v.append("F"); v.append("a\nb"); v.append("a\nb"); v.append(""); v.append("")
    v.append("T"); v.append("example.com"); v.append("example.com"); v.append("http://www.example.com/p/q"); v.append("example.com")
    v.append("F"); v.append("http:%2F%2Fx"); v.append("http:%2F%2Fx"); v.append(""); v.append("")
    v.append("F"); v.append("доп_приборы"); v.append("доп_приборы"); v.append(""); v.append("")
    v.append("F"); v.append("aдb"); v.append("aдb"); v.append(""); v.append("")
    return v^


# ---------------------------------------------------------------------------
# ⚠⚠ PRE-EXISTING DIVERGENCES — A SHRINK-ONLY RATCHET, NOT AN EXEMPTION FILE.
# ---------------------------------------------------------------------------
#
# SIX of the 2,034 oracle assertions disagree with DuckDB, all one class and all
# of them PRE-EXISTING: they reproduce byte-for-byte on the pre-Fix-A engine
# (verified by running this exact table against it before Fix A was applied),
# and Fix A introduced ZERO new ones.
#
# THE DEFECT: a GLOBAL replace of a ZERO-WIDTH match advances by one BYTE.
# RE2/DuckDB advance by one CODEPOINT, so on a multi-byte subject we insert the
# template BETWEEN the continuation bytes of a character and emit invalid UTF-8:
#     regexp_replace('aдb', '', 'X', 'g')  ->  'XaX?X?XbX'   (ours, 9 bytes)
#                                            ->  'XaXдXbX'     (DuckDB, 8 bytes)
# The advance sites are `_replace_one` and `find_all_in` in
# `regexp_functions.mojo` (`pos = ms + 1` / `pos += 1`).  Fixing it is a
# UTF-8-aware step, has its own oracle, and is NOT part of Fix A or Fix B.
#
# ⛔ THESE ARE NOT MUTED.  Each row asserts (a) that the divergence IS STILL
# THERE and (b) that our answer is still exactly the recorded byte length.  If
# somebody fixes the codepoint advance, this test REDS naming the row to delete
# -- red on good news, which is what makes the set only ever shrink.  A row that
# starts giving a THIRD answer also reds.
def _known_divergent_gotlen(pi: Int, si: Int) -> Int:
    """Our recorded byte length for a known-divergent `replace_g` cell, or -1."""
    if pi == 1 and si == 16: return 87      # (a*)(b*)  over "доп_приборы"
    if pi == 1 and si == 17: return 13      # (a*)(b*)  over "aдb"
    if pi == 19 and si == 16: return 43     # ()        over "доп_приборы"
    if pi == 19 and si == 17: return 9      # ()        over "aдb"
    if pi == 20 and si == 16: return 65     # (a*)      over "доп_приборы"
    if pi == 20 and si == 17: return 12     # (a*)      over "aдb"
    return -1


comptime _N_KNOWN_DIVERGENT: Int = 6


def test_pike_vm_differential_against_duckdb_oracle() raises:
    var pats = _patterns()
    var repls = _repls()
    var subs = _subjects()
    var exp = _expected()
    var n_cases = len(pats) * len(subs)
    if len(exp) != n_cases * 5:
        raise Error(String("oracle table desync: ", len(exp), " != ", n_cases * 5))

    var failures = List[String]()
    var checked = 0
    var kd_hits = 0
    var ci = 0
    for pi in range(len(pats)):
        var pat = pats[pi]
        var repl = repls[pi]
        var prog = RegexProgram.compile(pat, "")
        for si in range(len(subs)):
            var subj = subs[si]
            var base = ci * 5
            ci += 1
            var tag = String("p", pi, "/s", si, " pat=", pat, " subj=", subj)

            var got_m = "T" if regexp_like_scalar(subj, prog) else "F"
            if got_m != exp[base]:
                failures.append(String(tag, " matches: got ", got_m, " want ", exp[base]))
            checked += 1

            var got_r1 = regexp_replace_scalar(subj, prog, repl, False)
            if got_r1 != exp[base + 1]:
                failures.append(String(tag, " replace: got ", got_r1, " want ", exp[base + 1]))
            checked += 1

            var got_rg = regexp_replace_scalar(subj, prog, repl, True)
            var kd = _known_divergent_gotlen(pi, si)
            if kd >= 0:
                if got_rg == exp[base + 2]:
                    failures.append(String(tag, " replace_g: THE KNOWN DIVERGENCE IS GONE -- delete its row from _known_divergent_gotlen"))
                elif got_rg.byte_length() != kd:
                    failures.append(String(tag, " replace_g: known divergence CHANGED, gotlen ", got_rg.byte_length(), " want ", kd))
                else:
                    kd_hits += 1
            elif got_rg != exp[base + 2]:
                failures.append(String(tag, " replace_g: got ", got_rg, " want ", exp[base + 2]))
            checked += 1

            var got_e0 = regexp_extract_scalar(subj, prog, 0)
            if got_e0 != exp[base + 3]:
                failures.append(String(tag, " extract0: got ", got_e0, " want ", exp[base + 3]))
            checked += 1

            if prog.n_groups >= 1:
                var got_e1 = regexp_extract_scalar(subj, prog, 1)
                if got_e1 != exp[base + 4]:
                    failures.append(String(tag, " extract1: got ", got_e1, " want ", exp[base + 4]))
                checked += 1

    # Non-vacuity: a table that silently stopped being consulted is worse than
    # a red one.
    assert_true(checked > 1800, String("oracle ran only ", checked, " assertions"))
    # Non-vacuity for the ratchet too: if a known row stopped being REACHED the
    # set would shrink without anything being fixed.
    assert_equal(kd_hits, _N_KNOWN_DIVERGENT)

    if len(failures) > 0:
        var msg = String("DuckDB-oracle divergences: ", len(failures), " of ", checked, "\n")
        var shown = 0
        for k in range(len(failures)):
            if shown >= 40:
                break
            msg += failures[k] + "\n"
            shown += 1
        raise Error(msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

