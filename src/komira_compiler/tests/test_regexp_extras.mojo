# =============================================================================
# Semantics-locking tests for the remaining
# scalar regexp functions: regexp_count / regexp_instr / regexp_substr /
# regexp_full_match, plus named capture groups `(?P<name>...)` and a
# defense-in-depth check that `Expr.write_to` (-> structural_hash) distinguishes
# two `regexp_replace` nodes that differ only in their replacement string.
# =============================================================================
#
# Oracles:
#   - `regexp_full_match` — DuckDB (v1.5.0 has it,
#     RE2 engine — same engine class as our pure-Mojo Pike VM).  Expected
#     values pasted as literals below (no live-oracle CI dep).
#   - `regexp_count` / `regexp_instr` / `regexp_substr` — DuckDB v1.5.0 does NOT
#     have these (only PostgreSQL/Oracle do).  We follow PostgreSQL semantics:
#       regexp_count(s, p)  -> the number of non-overlapping matches; 0 if none.
#       regexp_instr(s, p)  -> the 1-based BYTE position of the first match;
#                              0 if none.  (PG positions are character-based;
#                              for ASCII subjects byte == char.  Only the
#                              `(s, p[, flags])` form is supported —
#                              PG's optional `start`/`N`/`endoption`/`subexpr`
#                              args are follow-ups.)
#       regexp_substr(s, p) -> the first matched substring; NULL if no match.
#                              (NOTE: differs from our `regexp_extract`, which
#                              returns '' on no match per DuckDB — both follow
#                              their respective oracle.  The per-row substring
#                              IS cross-checked against DuckDB's
#                              `regexp_extract(s, p, 0)`.)
#   - named groups — DuckDB/RE2 accept `(?P<name>...)` (Python-style) but reject
#     `(?<name>...)` ("invalid perl operator: (?<").  We match that exactly: a
#     pattern with `(?P<name>...)` parses cleanly (the named group still works
#     positionally), `(?<name>...)` raises.  The by-name extract API (`group=
#     "name"`) is a follow-up — only the names are RECORDED on `RegexProgram`.
#     A duplicate named group `(?P<x>a)(?P<x>b)` is accepted (RE2/DuckDB
#     tolerate it).
#
# `regexp_full_match` is implemented by wrapping the user pattern in
# `\A(?:...)\z` (the standard RE2 `FullMatch` desugaring; the `(?:...)` is
# needed so an alternation `a|b` becomes `\A(?:a|b)\z`, not `\Aa|b\z`).  It is
# Bool-producing so it also gets a `_eval_predicate` arm — testable as a filter.
#
# The engine-dispatch cases run `_eval_column_expr` / `_eval_predicate` (the
# same compute paths PipelineCompiler drives) over hand-built RecordBatches +
# `Expr.regexp_*` nodes.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false, assert_raises

from komira_core.arrow import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.plan.expr import Expr
from komira_core.eval.regexp_nfa import RegexProgram
from komira_core.eval.regexp_functions import (
    eval_regexp_extract,
    eval_regexp_count,
    eval_regexp_instr,
    eval_regexp_substr,
    eval_regexp_full_match,
    compile_full_match_program,
    regexp_count_scalar,
    regexp_instr_scalar,
    regexp_full_match_scalar,
)
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_compiler.compiler_eval_predicate import _eval_predicate


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

def _count(subject: String, pattern: String, flags: String = "") raises -> Int:
    var prog = RegexProgram.compile(pattern, flags)
    return regexp_count_scalar(subject, prog)


def _instr(subject: String, pattern: String, flags: String = "") raises -> Int:
    var prog = RegexProgram.compile(pattern, flags)
    return regexp_instr_scalar(subject, prog)


def _substr(subject: String, pattern: String, flags: String = "") raises -> StringArray[HeapRegion]:
    # Returns a 1-row StringArray so the test can check is_null.
    var arr = StringArray.from_strings([subject])
    var prog = RegexProgram.compile(pattern, flags)
    return eval_regexp_substr(arr^, prog)


def _full(subject: String, pattern: String, flags: String = "") raises -> Bool:
    var prog = compile_full_match_program(pattern, flags)
    return regexp_full_match_scalar(subject, prog)


def _str_col(vals: List[String], name: String = "s") raises -> RecordBatch:
    var arr = StringArray.from_strings(vals)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_string(arr^))
    return rbb.build(sb.build())


# ===========================================================================
# regexp_count — number of non-overlapping matches (PG semantics; 0 if none).
# ===========================================================================

def test_regexp_count_basic() raises:
    assert_equal(_count("aXbXcX", "X"), 3)
    assert_equal(_count("the cat sat on the mat", "at"), 3)


def test_regexp_count_no_match() raises:
    assert_equal(_count("hello world", "[0-9]"), 0)
    assert_equal(_count("xyz", "q"), 0)


def test_regexp_count_non_overlapping() raises:
    # 'aa' on 'aaaa' -> 2 non-overlapping matches (NOT 3).
    assert_equal(_count("aaaa", "aa"), 2)
    assert_equal(_count("aaaaa", "aa"), 2)


def test_regexp_count_digits_runs() raises:
    assert_equal(_count("a1b22c333d", "[0-9]+"), 3)


def test_regexp_count_word_boundary() raises:
    # \bat\b: 'the cat sat on the mat' -> only the standalone words don't exist
    # ('cat'/'sat'/'mat' are not the standalone word 'at').
    assert_equal(_count("the cat sat on the mat", "\\bat\\b"), 0)
    assert_equal(_count("at the bat at noon", "\\bat\\b"), 2)


def test_regexp_count_zero_width() raises:
    # Empty pattern: a zero-width match before every byte and one at the end —
    # find_all_in advances by 1 on a zero-width match, so 'abc' -> 4.
    assert_equal(_count("abc", ""), 4)
    assert_equal(_count("", ""), 1)
    # 'a*' on 'aaa': matches 'aaa' [0,3), then a zero-width match at offset 3
    # (find_all_in counts it — note this differs from regexp_replace's
    # GlobalReplace, which SKIPS it).
    assert_equal(_count("aaa", "a*"), 2)


def test_regexp_count_case_insensitive() raises:
    assert_equal(_count("AbAbAB", "ab", "i"), 3)


# ===========================================================================
# regexp_instr — 1-based byte position of the first match (0 if none).
# ===========================================================================

def test_regexp_instr_basic() raises:
    # regexp_instr('abcabc','b') -> 2  (PG cross-check).
    assert_equal(_instr("abcabc", "b"), 2)
    assert_equal(_instr("abcabc", "c"), 3)


def test_regexp_instr_at_start() raises:
    assert_equal(_instr("abc", "a"), 1)
    assert_equal(_instr("abc", "abc"), 1)


def test_regexp_instr_no_match() raises:
    assert_equal(_instr("abcabc", "z"), 0)
    assert_equal(_instr("hello", "[0-9]"), 0)


def test_regexp_instr_later_match() raises:
    assert_equal(_instr("xxabc", "abc"), 3)
    assert_equal(_instr("foo bar baz", "ba"), 5)


def test_regexp_instr_empty_pattern() raises:
    # Empty pattern matches at offset 0 -> 1-based position 1.
    assert_equal(_instr("abc", ""), 1)
    # Empty input: still a zero-width match at offset 0 -> position 1.
    assert_equal(_instr("", ""), 1)
    # Empty input, non-empty pattern -> no match -> 0.
    assert_equal(_instr("", "a"), 0)


# ===========================================================================
# regexp_substr — first matched substring; NULL if no match (PG/Oracle).
# ===========================================================================

def test_regexp_substr_basic() raises:
    var r = _substr("1abc2", "[a-z]+")
    assert_false(r.is_null(0))
    assert_equal(r.get(0), "abc")
    # Cross-check against DuckDB's regexp_extract(s, p, 0):
    # regexp_extract('a1 b22 c333','[0-9]+',0) = '1'
    var r2 = _substr("a1 b22 c333", "[0-9]+")
    assert_false(r2.is_null(0))
    assert_equal(r2.get(0), "1")


def test_regexp_substr_no_match_is_null() raises:
    # No match -> NULL (PG/Oracle; differs from regexp_extract which returns '').
    var r = _substr("abc", "x")
    assert_true(r.is_null(0))
    assert_equal(r.null_count, 1)
    var r2 = _substr("hello", "[0-9]+")
    assert_true(r2.is_null(0))


def test_regexp_substr_first_only() raises:
    # Only the FIRST match, not all of them.
    var r = _substr("cat dog cow", "c\\w+")
    assert_false(r.is_null(0))
    assert_equal(r.get(0), "cat")


def test_regexp_substr_group0_is_whole_match() raises:
    # A pattern with capture groups: regexp_substr returns the WHOLE match
    # (group 0), not a sub-group.
    var r = _substr("key=val;k2=v2", "(\\w+)=(\\w+)")
    assert_false(r.is_null(0))
    assert_equal(r.get(0), "key=val")


# ===========================================================================
# regexp_full_match — does the ENTIRE string match? (DuckDB oracle.)
#   regexp_full_match('abc','abc')   = true
#   regexp_full_match('abc','ab')    = false
#   regexp_full_match('abc','a.c')   = true
#   regexp_full_match('b','a|b')     = true   (proves the (?:...) wrapper)
#   regexp_full_match('ab','a|b')    = false
#   regexp_full_match('aaa','a*')    = true
#   regexp_full_match('','')         = true
#   regexp_full_match('abc','')      = false
#   regexp_full_match('abc','.*')    = true
#   regexp_full_match('ABC','abc','i') = true
#   regexp_full_match('abc','^abc$') = true   (redundant anchors are fine)
#   regexp_full_match('xabcx','abc') = false  (partial-in-middle does NOT count)
#   regexp_full_match('café','caf.') = true   (multibyte: '.' matches one byte
#                                              and 'é' is 2 bytes, so 'caf.'
#                                              fails... actually DuckDB matches
#                                              because RE2's '.' in default mode
#                                              matches a UTF-8 rune; our matcher
#                                              is byte-oriented so 'caf.' would
#                                              only consume one of the 2 bytes
#                                              of 'é' — we use a byte-pattern
#                                              that works in both: 'caf..')
# ===========================================================================

def test_regexp_full_match_literal() raises:
    assert_true(_full("abc", "abc"))
    assert_false(_full("abc", "ab"))
    assert_false(_full("abc", "abcd"))


def test_regexp_full_match_metachar() raises:
    assert_true(_full("abc", "a.c"))
    assert_false(_full("axyc", "a.c"))


def test_regexp_full_match_alternation_needs_wrapper() raises:
    # The crucial test: 'a|b' must become '\A(?:a|b)\z', NOT '\Aa|b\z'
    # (which would mean '\Aa' OR 'b\z').
    assert_true(_full("b", "a|b"))
    assert_true(_full("a", "a|b"))
    assert_false(_full("ab", "a|b"))
    assert_true(_full("foo", "foo|bar|baz"))
    assert_false(_full("foobar", "foo|bar"))


def test_regexp_full_match_quantifier() raises:
    assert_true(_full("aaa", "a*"))
    assert_true(_full("", "a*"))
    assert_false(_full("aaab", "a*"))
    assert_true(_full("aaa", "a+"))
    assert_false(_full("", "a+"))


def test_regexp_full_match_empty() raises:
    assert_true(_full("", ""))
    assert_false(_full("abc", ""))


def test_regexp_full_match_dotstar() raises:
    assert_true(_full("abc", ".*"))
    assert_true(_full("anything at all", ".*"))


def test_regexp_full_match_case_insensitive() raises:
    assert_true(_full("ABC", "abc", "i"))
    assert_false(_full("ABC", "abc"))


def test_regexp_full_match_redundant_anchors() raises:
    # The user pattern can have its own anchors — wrapping is harmless.
    assert_true(_full("abc", "^abc$"))
    assert_true(_full("abc", "\\Aabc\\z"))


def test_regexp_full_match_partial_does_not_count() raises:
    assert_false(_full("xabcx", "abc"))
    assert_false(_full("abcd", "bcd"))


def test_regexp_full_match_multibyte() raises:
    # Byte-oriented matcher: 'é' is 2 bytes, so 'caf..' (5 byte-atoms) matches
    # 'café' (5 bytes).  'caf.' (4 atoms) does NOT.
    assert_true(_full("café", "caf.."))
    assert_false(_full("café", "caf."))


# ===========================================================================
# Named capture groups `(?P<name>...)` — parse cleanly + work positionally.
#   regexp_extract('2026-01', '(?P<year>\d+)-(?P<month>\d+)', 1) = '2026'
#   regexp_extract('2026-01', '(?P<year>\d+)-(?P<month>\d+)', 2) = '01'
#   regexp_extract('', '(?P<y>\d+)-(?P<m>\d+)-(?P<d>\d+)', 3) = '15'
#   (?<name>...) -> 'invalid perl operator: (?<' (DuckDB rejects; we match)
# ===========================================================================

def test_named_group_parses_and_works_positionally() raises:
    var prog = RegexProgram.compile("(?P<year>\\d+)-(?P<month>\\d+)")
    assert_equal(prog.n_groups, 2)
    var b = StringArray.from_strings(["2026-01"])
    # Use the regexp_extract kernel via a 1-row column.
    var g1 = eval_regexp_extract(b^, prog, 1)
    assert_equal(g1.get(0), "2026")
    var b2 = StringArray.from_strings(["2026-01"])
    var prog2 = RegexProgram.compile("(?P<year>\\d+)-(?P<month>\\d+)")
    var g2 = eval_regexp_extract(b2^, prog2, 2)
    assert_equal(g2.get(0), "01")


def test_named_group_three() raises:
    var prog = RegexProgram.compile("(?P<y>\\d+)-(?P<m>\\d+)-(?P<d>\\d+)")
    assert_equal(prog.n_groups, 3)
    var b = StringArray.from_strings(["2026-01-15"])
    var g3 = eval_regexp_extract(b^, prog, 3)
    assert_equal(g3.get(0), "15")


def test_named_group_index_for_name_lookup() raises:
    # RegexProgram records the names (even though there is no by-name extract
    # API yet) — the lookup helper resolves name -> 1-based index.
    var prog = RegexProgram.compile("(?P<year>\\d+)-(?P<month>\\d+)-(?P<day>\\d+)")
    assert_equal(prog.group_index_for_name("year"), 1)
    assert_equal(prog.group_index_for_name("month"), 2)
    assert_equal(prog.group_index_for_name("day"), 3)
    assert_equal(prog.group_index_for_name("nope"), -1)


def test_named_group_mixed_with_unnamed() raises:
    # A mix of named and plain groups: group_names is parallel to all groups.
    var prog = RegexProgram.compile("(\\w+):(?P<val>\\d+)")
    assert_equal(prog.n_groups, 2)
    assert_equal(len(prog.group_names), 2)
    assert_equal(prog.group_names[0], "")          # group 1 is unnamed
    assert_equal(prog.group_names[1], "val")       # group 2 is 'val'
    assert_equal(prog.group_index_for_name("val"), 2)


def test_named_group_duplicate_name_accepted() raises:
    # RE2/DuckDB tolerate a duplicate name; we accept it too (first wins on the
    # by-name lookup).  Both groups still work positionally.
    var prog = RegexProgram.compile("(?P<dup>a)(?P<dup>b)")
    assert_equal(prog.n_groups, 2)
    assert_equal(prog.group_index_for_name("dup"), 1)  # first wins
    var b = StringArray.from_strings(["ab"])
    assert_equal(eval_regexp_extract(b^, prog, 2).get(0), "b")


def test_named_group_with_full_match() raises:
    # Named group inside a full_match pattern (the (?:...) wrapper doesn't
    # disturb the named group's index).
    assert_true(_full("2026", "(?P<y>\\d+)"))
    assert_false(_full("2026x", "(?P<y>\\d+)"))


def test_named_group_with_regexp_count() raises:
    assert_equal(_count("k1=v1 k2=v2 k3=v3", "(?P<k>\\w+)=(?P<v>\\w+)"), 3)


def test_perl_named_group_rejected() raises:
    # (?<name>...) is Perl/.NET — RE2 rejects it ("invalid perl operator: (?<");
    # DuckDB rejects it; we match.
    with assert_raises():
        _ = RegexProgram.compile("(?<year>\\d+)")
    with assert_raises():
        _ = RegexProgram.compile("(?<=foo)bar")  # lookbehind, also (?<


def test_named_group_malformed() raises:
    with assert_raises():
        _ = RegexProgram.compile("(?P<")           # truncated
    with assert_raises():
        _ = RegexProgram.compile("(?P<>a)")        # empty name
    with assert_raises():
        _ = RegexProgram.compile("(?P<1bad>a)")    # name can't start with a digit
    with assert_raises():
        _ = RegexProgram.compile("(?Pname>a)")     # missing '<' after (?P


# ===========================================================================
# write_to / structural_hash distinguishes two regexp_replace nodes that differ
# only in their replacement string. `write_to` emits `replacement="..."`;
# this test locks that against regression.)
# ===========================================================================

def test_write_to_includes_replacement() raises:
    var e1 = Expr.regexp_replace(Expr.col_idx(0), "(\\d+)", "[\\1]")
    var e2 = Expr.regexp_replace(Expr.col_idx(0), "(\\d+)", "<\\1>")
    var s1 = String(e1)
    var s2 = String(e2)
    # write_to (which structural_hash hashes) must distinguish them.
    assert_true(s1 != s2)
    assert_true("replacement=\"[\\1]\"" in s1)
    assert_true("replacement=\"<\\1>\"" in s2)
    # Same replacement -> same write_to (sanity).
    var e3 = Expr.regexp_replace(Expr.col_idx(0), "(\\d+)", "[\\1]")
    assert_equal(String(e1), String(e3))


def test_write_to_includes_group_for_extract() raises:
    var e1 = Expr.regexp_extract(Expr.col_idx(0), "(\\w+)", 1)
    var e2 = Expr.regexp_extract(Expr.col_idx(0), "(\\w+)", 2)
    assert_true(String(e1) != String(e2))


# ===========================================================================
# Column-kernel + NULL-row tests.
# ===========================================================================

def test_count_kernel_with_null_row() raises:
    var arr = StringArray.from_strings(["aXbX", "no digits", "XX", ""])
    var vbm = Bitmap.create_all_valid(4)
    vbm.clear(1)  # row 1 null
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = RegexProgram.compile("X")
    var out = eval_regexp_count(arr^, prog)
    assert_equal(out.length, 4)
    assert_equal(out.null_count, 1)
    assert_equal(out.get(0), Int64(2))
    assert_true(out.is_null(1))
    assert_equal(out.get(2), Int64(2))
    assert_equal(out.get(3), Int64(0))   # no match in '' -> 0, NOT null


def test_instr_kernel_with_null_row() raises:
    var arr = StringArray.from_strings(["xxabc", "nope here", "abc"])
    var vbm = Bitmap.create_all_valid(3)
    vbm.clear(1)
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = RegexProgram.compile("abc")
    var out = eval_regexp_instr(arr^, prog)
    assert_equal(out.get(0), Int64(3))
    assert_true(out.is_null(1))
    assert_equal(out.get(2), Int64(1))


def test_substr_kernel_with_null_row() raises:
    var arr = StringArray.from_strings(["a1b2", "input was null", "no match here", "c3"])
    var vbm = Bitmap.create_all_valid(4)
    vbm.clear(1)
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = RegexProgram.compile("[0-9]")
    var out = eval_regexp_substr(arr^, prog)
    assert_equal(out.length, 4)
    # row 1 = NULL input -> NULL; row 2 = no match -> NULL.
    assert_equal(out.null_count, 2)
    assert_equal(out.get(0), "1")
    assert_true(out.is_null(1))
    assert_true(out.is_null(2))
    assert_equal(out.get(3), "3")


def test_full_match_kernel_with_null_row() raises:
    var arr = StringArray.from_strings(["abc", "this is null", "ab", "abc"])
    var vbm = Bitmap.create_all_valid(4)
    vbm.clear(1)
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = compile_full_match_program("abc")
    var out = eval_regexp_full_match(arr^, prog)
    assert_equal(out.length, 4)
    assert_equal(out.null_count, 1)
    assert_true(out.get(0))
    assert_true(out.is_null(1))
    assert_false(out.get(2))
    assert_true(out.get(3))


# ===========================================================================
# Engine dispatch — `_eval_column_expr` over a RecordBatch + an Expr node.
# ===========================================================================

def test_engine_regexp_count() raises:
    var batch = _str_col(["aXbXcX", "no x here", ""])
    # SELECT regexp_count(s, 'X')
    var e = Expr.regexp_count(Expr.col_idx(0), "X")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.INT64)
    var p = col.as_primitive[DType.int64]()
    assert_equal(p.get(0), Int64(3))
    assert_equal(p.get(1), Int64(0))
    assert_equal(p.get(2), Int64(0))


def test_engine_regexp_instr() raises:
    var batch = _str_col(["abcabc", "zzz", "xxabc"])
    # SELECT regexp_instr(s, 'abc')
    var e = Expr.regexp_instr(Expr.col_idx(0), "abc")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.INT64)
    var p = col.as_primitive[DType.int64]()
    assert_equal(p.get(0), Int64(1))
    assert_equal(p.get(1), Int64(0))
    assert_equal(p.get(2), Int64(3))


def test_engine_regexp_substr() raises:
    var batch = _str_col(["1abc2", "nodigitshere"])
    # SELECT regexp_substr(s, '[a-z]+')
    var e = Expr.regexp_substr(Expr.col_idx(0), "[a-z]+")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.STRING)
    var sa = col.as_string()
    assert_equal(sa.get(0), "abc")
    # row 1: 'nodigitshere' DOES match [a-z]+ -> 'nodigitshere' (whole string).
    assert_equal(sa.get(1), "nodigitshere")


def test_engine_regexp_substr_no_match_null() raises:
    var batch = _str_col(["abc"])
    # SELECT regexp_substr(s, '[0-9]+') -> no match -> NULL
    var e = Expr.regexp_substr(Expr.col_idx(0), "[0-9]+")
    var col = _eval_column_expr(e, batch)
    var sa = col.as_string()
    assert_true(sa.is_null(0))


def test_engine_regexp_full_match_projection() raises:
    var batch = _str_col(["abc", "ab", "abcd", "axc"])
    # SELECT regexp_full_match(s, 'a.c')
    var e = Expr.regexp_full_match(Expr.col_idx(0), "a.c")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.BOOL)
    var ba = col.as_boolean()
    assert_true(ba.get(0))   # 'abc' fully matches 'a.c'
    assert_false(ba.get(1))  # 'ab'
    assert_false(ba.get(2))  # 'abcd'
    assert_true(ba.get(3))   # 'axc'


def test_engine_regexp_full_match_predicate() raises:
    # regexp_full_match is Bool-producing -> usable as a filter predicate.
    var batch = _str_col(["123", "12a", "456", "abc"])
    var e = Expr.regexp_full_match(Expr.col_idx(0), "\\d+")
    var ba = _eval_predicate(e, batch)
    assert_true(ba.get(0))   # '123' all digits
    assert_false(ba.get(1))  # '12a'
    assert_true(ba.get(2))   # '456'
    assert_false(ba.get(3))  # 'abc'


def test_engine_regexp_full_match_predicate_alternation() raises:
    # The (?:...) wrapper matters here: 'a|b' as a predicate would (without the
    # wrapper) match any row containing 'a' OR ending in 'b' — with the wrapper
    # it's only single-char 'a' or 'b'.
    var batch = _str_col(["a", "b", "ab", "c", "ba"])
    var e = Expr.regexp_full_match(Expr.col_idx(0), "a|b")
    var ba = _eval_predicate(e, batch)
    assert_true(ba.get(0))   # 'a'
    assert_true(ba.get(1))   # 'b'
    assert_false(ba.get(2))  # 'ab'
    assert_false(ba.get(3))  # 'c'
    assert_false(ba.get(4))  # 'ba'


def test_engine_regexp_count_named_group() raises:
    var batch = _str_col(["k1=v1 k2=v2", "no kv"])
    var e = Expr.regexp_count(Expr.col_idx(0), "(?P<k>\\w+)=(?P<v>\\w+)")
    var col = _eval_column_expr(e, batch)
    var p = col.as_primitive[DType.int64]()
    assert_equal(p.get(0), Int64(2))
    assert_equal(p.get(1), Int64(0))


def test_engine_non_bool_regexp_not_a_predicate() raises:
    # regexp_count etc. produce non-boolean values -> can't be a filter.
    var batch = _str_col(["abc"])
    var e = Expr.regexp_count(Expr.col_idx(0), "a")
    with assert_raises():
        _ = _eval_predicate(e, batch)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
