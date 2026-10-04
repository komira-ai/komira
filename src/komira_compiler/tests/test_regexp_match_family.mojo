# =============================================================================
# Semantics-locking tests for the List<Utf8>
# regexp family: regexp_match / regexp_split_to_array / regexp_extract_all.
# =============================================================================
#
# Oracle: DuckDB for `regexp_split_to_array` /
# `regexp_extract_all` (DuckDB has both — RE2 engine, same engine class as our
# pure-Mojo Pike VM).  `regexp_match` is a PostgreSQL function (DuckDB doesn't
# have it); we follow PG's `text[]` shape (capture-group substrings, or
# `{whole_match}` if the pattern has no groups; NULL list on no match) per the
# arrow-expert rev-2 review.  DuckDB's `regexp_extract(s, p, N)` cross-checks
# the per-group substrings.  Expected values were generated with the local
# `duckdb -csv -c "SELECT ..."` and pasted in as literals — no live-oracle CI
# dependency.
#
# Known divergences from DuckDB, deliberate (noted at the call sites):
#   - `regexp_extract_all(s, p, group)` where `group` did not participate in a
#     given match: DuckDB returns a NULL element in that list slot; we return
#     the empty string '' (consistent with our Phase-1 scalar `regexp_extract`,
#     and per the Phase-2a brief).  The overall list / row validity is
#     unaffected.
#   - `regexp_split_to_array(s, '')` (empty pattern): DuckDB splits between
#     every byte with NO leading/trailing '' ('abc' -> ['a','b','c']); we
#     collapse the zero-width match at offsets 0 and len the same way.
#
# The engine-dispatch cases run `_eval_column_expr` (the same compute path
# PipelineCompiler drives) over hand-built RecordBatches + `Expr.regexp_*`
# nodes, producing a `Column` with `arrow_type == ArrowType.LIST` that
# round-trips back to a `ListArray` via `Column.as_list_of_string`.
#
# Test helper: `_join` renders a List[String] as "['a', 'b']" — every element
# quoted, so an empty-string element ("['']") is distinct from the empty list
# ("[]").
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import BooleanArray, Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.list_array import ListArray
from komira_core.plan.expr import Expr
from komira_core.eval.regexp_nfa import RegexProgram
from komira_core.eval.regexp_functions import (
    eval_regexp_match, eval_regexp_split_to_array, eval_regexp_extract_all,
)
from komira_compiler.compiler_eval_column import _eval_column_expr


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

def _join(parts: List[String]) -> String:
    var out = String("[")
    for i in range(len(parts)):
        if i > 0:
            out += ", "
        out += "'"
        out += parts[i]
        out += "'"
    out += "]"
    return out^


def _match_row(subject: String, pattern: String, flags: String = "") raises -> String:
    var arr = StringArray.from_strings([subject])
    var prog = RegexProgram.compile(pattern, flags)
    var la = eval_regexp_match(arr^, prog)
    if la.is_null(0):
        return String("NULL")
    return _join(la.list_strings(0))


def _split_row(subject: String, pattern: String, flags: String = "") raises -> String:
    var arr = StringArray.from_strings([subject])
    var prog = RegexProgram.compile(pattern, flags)
    var la = eval_regexp_split_to_array(arr^, prog)
    if la.is_null(0):
        return String("NULL")
    return _join(la.list_strings(0))


def _extract_all_row(subject: String, pattern: String, group: Int = 0, flags: String = "") raises -> String:
    var arr = StringArray.from_strings([subject])
    var prog = RegexProgram.compile(pattern, flags)
    var la = eval_regexp_extract_all(arr^, prog, group)
    if la.is_null(0):
        return String("NULL")
    return _join(la.list_strings(0))


def _str_col(vals: List[String], name: String = "s") raises -> RecordBatch:
    var arr = StringArray.from_strings(vals)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_string(arr^))
    return rbb.build(sb.build())


def _str_col_nullable(vals: List[String], null_at: List[Int], name: String = "s") raises -> RecordBatch:
    var arr = StringArray.from_strings(vals)
    var n = len(vals)
    var vbm = Bitmap.create_all_valid(n)
    for k in range(len(null_at)):
        vbm.clear(null_at[k])
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = len(null_at)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_string(arr^))
    return rbb.build(sb.build())


# ===========================================================================
# regexp_match  ->  List<Utf8>
# ===========================================================================
#
# DuckDB regexp_extract cross-checks the per-group substrings:
#   regexp_extract('14:30','(\d{4})-(\d{2})-(\d{2})',1)='2026'
#   ...                                                          ,2)='05'
#   ...                                                          ,3)='12'
#   regexp_extract('xab','((a)(b))',1)='ab' ,2)='a' ,3)='b'
#   regexp_extract('foobar','o+',0)='oo'
# ---------------------------------------------------------------------------

def test_match_multi_group() raises:
    assert_equal(_match_row("2026-05-12 14:30", r"(\d{4})-(\d{2})-(\d{2})"), "['2026', '05', '12']")


def test_match_nested_groups() raises:
    assert_equal(_match_row("xab", "((a)(b))"), "['ab', 'a', 'b']")


def test_match_no_groups_whole_match() raises:
    # No capture groups -> 1-element list of the whole (first) match.
    assert_equal(_match_row("foobar", "o+"), "['oo']")
    assert_equal(_match_row("foobar", "bar"), "['bar']")


def test_match_no_match_null_list() raises:
    assert_equal(_match_row("hello", r"(\d+)"), "NULL")
    assert_equal(_match_row("hello", "z+"), "NULL")


def test_match_non_participating_group() raises:
    # (a)?(b) on 'b': group 1 didn't participate -> '' in its slot, group 2 = 'b'.
    assert_equal(_match_row("b", "(a)?(b)"), "['', 'b']")


def test_match_optional_trailing_group() raises:
    # 'a(b)?' on 'a' -> 1 group, didn't participate -> [''].
    assert_equal(_match_row("a", "a(b)?"), "['']")
    # 'a(b)?' on 'ab' -> group 1 = 'b'.
    assert_equal(_match_row("ab", "a(b)?"), "['b']")


def test_match_unanchored_first() raises:
    # regexp_match searches unanchored and reports the FIRST match.
    assert_equal(_match_row("xx2026-05-12yy", r"(\d{4})-(\d{2})"), "['2026', '05']")


# ===========================================================================
# regexp_split_to_array  ->  List<Utf8>     (DuckDB oracle)
# ===========================================================================
#
# duckdb -csv:
#   regexp_split_to_array('1,2,3,4', ',')         = [1, 2, 3, 4]
#   regexp_split_to_array('aXXbXXc', 'XX')        = [a, b, c]
#   regexp_split_to_array(',a,b', ',')            = ['', a, b]
#   regexp_split_to_array('a,b,', ',')            = [a, b, '']
#   regexp_split_to_array('a,,b', ',')            = [a, '', b]
#   regexp_split_to_array('abc', 'z')             = [abc]
#   regexp_split_to_array('a1b22c333d', '[0-9]+') = [a, b, c, d]
#   regexp_split_to_array('abcd', '')             = [a, b, c, d]
#   regexp_split_to_array('', ',')                = ['']
#   regexp_split_to_array('xxaxxbxx', 'xx')       = ['', a, b, '']
# ---------------------------------------------------------------------------

def test_split_single_char_delim() raises:
    assert_equal(_split_row("1,2,3,4", ","), "['1', '2', '3', '4']")


def test_split_multi_char_delim() raises:
    assert_equal(_split_row("aXXbXXc", "XX"), "['a', 'b', 'c']")


def test_split_leading_match() raises:
    assert_equal(_split_row(",a,b", ","), "['', 'a', 'b']")


def test_split_trailing_match() raises:
    assert_equal(_split_row("a,b,", ","), "['a', 'b', '']")


def test_split_consecutive_matches() raises:
    assert_equal(_split_row("a,,b", ","), "['a', '', 'b']")


def test_split_leading_and_trailing() raises:
    assert_equal(_split_row("xxaxxbxx", "xx"), "['', 'a', 'b', '']")


def test_split_no_match_whole_string() raises:
    assert_equal(_split_row("abc", "z"), "['abc']")


def test_split_regex_delim() raises:
    assert_equal(_split_row("a1b22c333d", "[0-9]+"), "['a', 'b', 'c', 'd']")


def test_split_empty_pattern() raises:
    # DuckDB: empty pattern splits between every byte, no leading/trailing ''.
    assert_equal(_split_row("abcd", ""), "['a', 'b', 'c', 'd']")


def test_split_empty_input() raises:
    # DuckDB: '' splits to a 1-element list of ''.
    assert_equal(_split_row("", ","), "['']")


# ===========================================================================
# regexp_extract_all  ->  List<Utf8>        (DuckDB oracle)
# ===========================================================================
#
# duckdb -csv:
#   regexp_extract_all('a1 b2 c3', '([a-z])([0-9])')    = [a1, b2, c3]
#   regexp_extract_all('a1 b2 c3', '([a-z])([0-9])', 1) = [a, b, c]
#   regexp_extract_all('a1 b2 c3', '([a-z])([0-9])', 2) = [1, 2, 3]
#   regexp_extract_all('aaaa', 'aa')   = [aa, aa]    (non-overlapping)
#   regexp_extract_all('aaaaa', 'aa')  = [aa, aa]
#   regexp_extract_all('hello world', '[0-9]')          = []
#   regexp_extract_all('a1b2c3', '[0-9]')               = [1, 2, 3]
# ---------------------------------------------------------------------------

def test_extract_all_group0() raises:
    assert_equal(_extract_all_row("a1 b2 c3", "([a-z])([0-9])"), "['a1', 'b2', 'c3']")
    assert_equal(_extract_all_row("a1b2c3", r"[0-9]"), "['1', '2', '3']")


def test_extract_all_group_n() raises:
    assert_equal(_extract_all_row("a1 b2 c3", "([a-z])([0-9])", 1), "['a', 'b', 'c']")
    assert_equal(_extract_all_row("a1 b2 c3", "([a-z])([0-9])", 2), "['1', '2', '3']")


def test_extract_all_non_overlapping() raises:
    # 'aa' on 'aaaa' -> ['aa','aa'] (NOT 3 — non-overlapping, left-to-right).
    assert_equal(_extract_all_row("aaaa", "aa"), "['aa', 'aa']")
    assert_equal(_extract_all_row("aaaaa", "aa"), "['aa', 'aa']")


def test_extract_all_no_matches_empty_list() raises:
    # No matches -> empty list [] (NOT NULL).
    var arr = StringArray.from_strings(["hello world"])
    var prog = RegexProgram.compile(r"[0-9]")
    var la = eval_regexp_extract_all(arr^, prog, 0)
    assert_false(la.is_null(0))
    assert_equal(la.get_length(0), 0)
    assert_equal(_extract_all_row("hello world", r"[0-9]"), "[]")


def test_extract_all_non_participating_group() raises:
    # '([a-z])([0-9])?' on 'a1 b c2': matches 'a1','b','c2'; group 2 absent
    # in the 'b' match -> '' element (our choice; DuckDB -> NULL element).
    assert_equal(_extract_all_row("a1 b c2", "([a-z])([0-9])?", 2), "['1', '', '2']")


def test_extract_all_group_out_of_range_raises() raises:
    var arr = StringArray.from_strings(["abc"])
    var prog = RegexProgram.compile(r"(a)(b)(c)")
    var raised = False
    try:
        _ = eval_regexp_extract_all(arr^, prog, -1)
    except e:
        raised = True
    assert_true(raised)
    var arr2 = StringArray.from_strings(["abc"])
    var prog2 = RegexProgram.compile(r"(a)(b)(c)")
    var raised2 = False
    try:
        _ = eval_regexp_extract_all(arr2^, prog2, 10)
    except e:
        raised2 = True
    assert_true(raised2)


# ===========================================================================
# NULL-input-row -> NULL-list, and column-kernel validity / offsets / values.
# ===========================================================================

def test_null_input_row_match() raises:
    # rows: ['a1', NULL, 'no digits', 'b2 c3'] ; pattern '([a-z])([0-9])'
    var arr = StringArray.from_strings(["a1", "x", "no digits", "b2 c3"])
    var vbm = Bitmap.create_all_valid(4)
    vbm.clear(1)
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = RegexProgram.compile("([a-z])([0-9])")
    var la = eval_regexp_match(arr^, prog)
    assert_equal(len(la), 4)
    assert_false(la.is_null(0))
    assert_equal(_join(la.list_strings(0)), "['a', '1']")
    assert_true(la.is_null(1))            # NULL input -> NULL list
    assert_true(la.is_null(2))            # no match -> NULL list
    assert_false(la.is_null(3))
    assert_equal(_join(la.list_strings(3)), "['b', '2']")
    assert_equal(la.get_length(0), 2)
    assert_equal(la.get_length(1), 0)
    assert_equal(la.get_length(2), 0)
    assert_equal(la.get_length(3), 2)
    assert_equal(la.total_values(), 4)


def test_null_input_row_split() raises:
    var arr = StringArray.from_strings(["a,b", "x", "no-delim", ",z,"])
    var vbm = Bitmap.create_all_valid(4)
    vbm.clear(1)
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = RegexProgram.compile(",")
    var la = eval_regexp_split_to_array(arr^, prog)
    assert_equal(len(la), 4)
    assert_equal(_join(la.list_strings(0)), "['a', 'b']")
    assert_true(la.is_null(1))
    assert_false(la.is_null(2))
    assert_equal(_join(la.list_strings(2)), "['no-delim']")
    assert_equal(_join(la.list_strings(3)), "['', 'z', '']")


def test_null_input_row_extract_all() raises:
    var arr = StringArray.from_strings(["a1b2", "x", "none", "c3"])
    var vbm = Bitmap.create_all_valid(4)
    vbm.clear(1)
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = RegexProgram.compile(r"[0-9]")
    var la = eval_regexp_extract_all(arr^, prog, 0)
    assert_equal(len(la), 4)
    assert_equal(_join(la.list_strings(0)), "['1', '2']")
    assert_true(la.is_null(1))            # NULL input -> NULL list
    assert_false(la.is_null(2))           # no matches -> empty list, NOT null
    assert_equal(la.get_length(2), 0)
    assert_equal(_join(la.list_strings(3)), "['3']")


# ===========================================================================
# ListArray <-> Column round-trip (the gating wiring).
# ===========================================================================

def test_list_column_round_trip() raises:
    var arr = StringArray.from_strings(["a1 b2", "x", "c3"])
    var vbm = Bitmap.create_all_valid(3)
    vbm.clear(1)
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    var prog = RegexProgram.compile("([a-z])([0-9])")
    var la = eval_regexp_match(arr^, prog)
    var col = Column.from_list(la^)
    assert_equal(col.arrow_type, ArrowType.LIST)
    assert_equal(col.length(), 3)
    var back = col.as_list_of_string()
    assert_equal(len(back), 3)
    assert_equal(_join(back.list_strings(0)), "['a', '1']")
    assert_true(back.is_null(1))
    assert_equal(_join(back.list_strings(2)), "['c', '3']")
    assert_equal(back.total_values(), 4)


def test_from_string_lists_factory() raises:
    var lists = List[List[String]]()
    lists.append(["x", "y"])
    lists.append(List[String]())          # null row (mask False)
    lists.append(["z"])
    var mask = List[Bool]()
    mask.append(True)
    mask.append(False)
    mask.append(True)
    var la = ListArray.from_string_lists(lists, mask)
    assert_equal(len(la), 3)
    assert_equal(_join(la.list_strings(0)), "['x', 'y']")
    assert_true(la.is_null(1))
    assert_equal(_join(la.list_strings(2)), "['z']")
    assert_equal(la.null_count, 1)


# ===========================================================================
# Engine dispatch — _eval_column_expr over hand-built RecordBatches +
# Expr.regexp_* nodes (SDK -> LogicalPlan -> executor compute path).
# ===========================================================================

def test_engine_regexp_match_projection() raises:
    var batch = _str_col(["k=v1 a=b", "no match here", "x=1 y=2"])
    var e = Expr.regexp_match(Expr.col_idx(0), r"(\w+)=(\w+)")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.LIST)
    var la = col.as_list_of_string()
    assert_equal(len(la), 3)
    assert_equal(_join(la.list_strings(0)), "['k', 'v1']")   # first match
    assert_true(la.is_null(1))                                # no match -> NULL
    assert_equal(_join(la.list_strings(2)), "['x', '1']")


def test_engine_regexp_split_projection() raises:
    var batch = _str_col(["a,b,c", "single", ",lead", "trail,"])
    var e = Expr.regexp_split_to_array(Expr.col_idx(0), ",")
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.LIST)
    var la = col.as_list_of_string()
    assert_equal(_join(la.list_strings(0)), "['a', 'b', 'c']")
    assert_equal(_join(la.list_strings(1)), "['single']")
    assert_equal(_join(la.list_strings(2)), "['', 'lead']")
    assert_equal(_join(la.list_strings(3)), "['trail', '']")


def test_engine_regexp_extract_all_projection() raises:
    var batch = _str_col(["a1b2c3", "xyz", "9 and 8 and 7"])
    var e0 = Expr.regexp_extract_all(Expr.col_idx(0), r"[0-9]")
    var col0 = _eval_column_expr(e0, batch)
    var la0 = col0.as_list_of_string()
    assert_equal(_join(la0.list_strings(0)), "['1', '2', '3']")
    assert_equal(la0.get_length(1), 0)                        # no matches -> empty
    assert_equal(_join(la0.list_strings(2)), "['9', '8', '7']")
    var batch2 = _str_col(["a1 b2 c3"])
    var e1 = Expr.regexp_extract_all(Expr.col_idx(0), r"([a-z])([0-9])", 1)
    var col1 = _eval_column_expr(e1, batch2)
    var la1 = col1.as_list_of_string()
    assert_equal(_join(la1.list_strings(0)), "['a', 'b', 'c']")


def test_engine_regexp_match_null_row() raises:
    var batch = _str_col_nullable(["k=v", "x", "z=9"], [1])
    var e = Expr.regexp_match(Expr.col_idx(0), r"(\w+)=(\w+)")
    var col = _eval_column_expr(e, batch)
    var la = col.as_list_of_string()
    assert_equal(_join(la.list_strings(0)), "['k', 'v']")
    assert_true(la.is_null(1))                                # NULL input -> NULL
    assert_equal(_join(la.list_strings(2)), "['z', '9']")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
