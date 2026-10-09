# =============================================================================
# test_row_filter_regexp_kerneldirect.mojo — row-typed regex FILTER
# (`regexp_like` / EXPR_REGEXP per-cell FILTER predicate) VERIFICATION
# (kernel-direct).
# =============================================================================
#
# VERIFIES the row-typed FILTER predicate REGEXP arm:
#   * A row-source `regexp_like(col, 'pat')` predicate serves the per-cell
#     row FILTER walker ROW-NATIVE (no demotion to the column path). The walker's
#     EXPR_REGEXP arm reads the value STRING cell and runs the compiled Thompson-
#     NFA / Pike-VM `RegexProgram.is_match` (via `regexp_like_scalar`) — the SAME
#     leaf the column oracle `eval_regexp_like` runs, so the row path is
#     value-identical, NOT a reimplementation.
#   * The regex is COMPILED ONCE (here, before the per-row loop) and carried in
#     the executor's `regex_pool` side-table; the per-cell hot loop only runs
#     `is_match`. The EXPR_REGEXP node carries the value-column child slot in
#     `left` + the regex_pool index in `col_idx` (REPURPOSED — tag-disambiguated).
#   * NOT REGEXP = NOT(EXPR_REGEXP) — the unary-NOT wrapper over the REGEXP
#     arm, with 3VL (a NULL value cell -> NOT NULL = NULL -> row excluded).
#
# The column NFA executor
# (`regexp_nfa.RegexProgram`) ALREADY exposes a per-string entry point —
# `is_match(subject: List[UInt8]) -> Bool` + the convenience
# `regexp_functions.regexp_like_scalar(subject: String, prog) -> Bool`. The
# column path loops over a StringArray calling per-element match; the row arm
# reuses the exact same compiled program + per-string match. No NFA refactor.
#
# WHY KERNEL-DIRECT (the whole point + the gate bypass):
# ------------------------------------------------------
# If the SDK gate DECLINES EXPR_REGEXP, the SDK never routes a regex
# predicate to the row path and the engine arm is unreachable from the SDK. To pin the ENGINE arm independent of the closed gate, this test
# drives the production per-cell filter kernel DIRECTLY:
#   * `ExpressionExecutor._eval_bool_from_source[RowCellSource]`
# over a `RowCellSource` borrowing a hand-built `RowBlock`, with a constructed
# EXPR_REGEXP RuntimeExpr + a real compiled `RegexProgram`. NO `ctx`, NO
# `read_csv*`, NO `collect`, NO `materialize` (those instantiate the full
# plan dispatch tree).
#
# The seam exercised is the EXACT production filter-walker kernel
# (the row-streaming filter walker calls this evaluator per row).
#
# Neutralizing the EXPR_REGEXP arm (forcing it always-True or
# always-False) makes §1/§2 FAIL (the NFA eval is load-bearing). The pattern-
# discriminating oracle (some rows match, some don't) cannot be satisfied by a
# constant.
#
# Encapsulation: NO UnsafePointer / wildcard origins /
# unsafe_from_address / take_pointee. eval surface only. `fn` style.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_row_format.row_block import RowBlock
from komira_row_format.cell_source import (
    RowCellSource,
    CELL_DT_STRING,
)
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_col_string,
    make_regexp,
    make_not_bool,
)
from komira_column_kernels.regexp_nfa import RegexProgram


# =============================================================================
# Fixture: a single STRING column — col0 @ 0, stride 8 (var-string slot
# descriptor). Built via the RowBlock string write API.
# =============================================================================

comptime _SOFF0: Int = 0
comptime _SSTRIDE: Int = 8


def _string_offsets() -> List[Int]:
    var offs = List[Int]()
    offs.append(_SOFF0)
    return offs^


def _string_dtypes() -> List[UInt8]:
    var dts = List[UInt8]()
    dts.append(CELL_DT_STRING)
    return dts^


def _build_string_block(vals: List[String]) raises -> RowBlock:
    var n = len(vals)
    var rb = RowBlock.with_capacity(n, n * 16, _SSTRIDE)
    for i in range(n):
        rb.write_var_string_cell(i, _SOFF0, vals[i].as_bytes())
    rb.set_n_rows(n)
    return rb^


def _regex_pool_with(var prog: RegexProgram) -> List[RegexProgram]:
    var rp = List[RegexProgram]()
    rp.append(prog^)
    return rp^


# =============================================================================
# §1 — regexp_like(col, '^a.*z$'). Anchored: starts with 'a', ends with 'z'.
# Pool:
#   0: EXPR_COL_STRING(col0)
#   1: EXPR_REGEXP(value_child=0, regex_pool_idx=0)   ROOT
# Oracle (DuckDB `regexp_like(x, '^a.*z$')`): row selected iff x starts 'a' AND
# ends 'z' (the `.*` spans the middle; `^`/`$` anchor both ends).
# =============================================================================
def test_regexp_anchored() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))      # 0
    pool.append(make_regexp(0, 0))       # 1 ROOT (value child=0, regex idx=0)

    var prog = RegexProgram.compile("^a.*z$", "")
    var rp = _regex_pool_with(prog^)

    var vals = List[String]()
    vals.append("abz")        # match: starts a, ends z
    vals.append("az")         # match: a...z with empty middle (.* = 0)
    vals.append("abc")        # no: ends 'c'
    vals.append("xabz")       # no: anchored ^ -> must START with a
    vals.append("abzq")       # no: anchored $ -> must END with z
    vals.append("alongerzzz") # match: starts a, ends z
    vals.append("zaz")        # no: starts 'z'

    var rb = _build_string_block(vals)
    var cs = RowCellSource(rb, _string_offsets(), _string_dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String](), regex_pool=rp^)

    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 1, r)
        var v = vals[r]
        var want = v.startswith("a") and v.endswith("z")
        assert_equal(
            got, want,
            "regexp_like(x,'^a.*z$') row " + String(r) + " (x=" + v + ")",
        )


# =============================================================================
# §2 — regexp_like(col, 'foo'). Unanchored CONTAINS (the regex equivalent of
# SQL `LIKE '%foo%'`).
# Pool:
#   0: EXPR_COL_STRING(col0)
#   1: EXPR_REGEXP(0, 0)   ROOT
# Oracle (DuckDB `regexp_like(x, 'foo')`): row selected iff 'foo' appears
# anywhere in x (unanchored).
# =============================================================================
def test_regexp_contains_unanchored() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))      # 0
    pool.append(make_regexp(0, 0))       # 1 ROOT

    var prog = RegexProgram.compile("foo", "")
    var rp = _regex_pool_with(prog^)

    var vals = List[String]()
    vals.append("foobar")     # match: leading foo
    vals.append("barfoo")     # match: trailing foo
    vals.append("xfooy")      # match: middle foo
    vals.append("fo")         # no: partial
    vals.append("bar")        # no
    vals.append("foofoo")     # match
    vals.append("")           # no: empty

    var rb = _build_string_block(vals)
    var cs = RowCellSource(rb, _string_offsets(), _string_dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String](), regex_pool=rp^)

    # Hand-computed contains-'foo' oracle (no library substring helper needed):
    var oracle = List[Bool]()
    oracle.append(True)   # foobar
    oracle.append(True)   # barfoo
    oracle.append(True)   # xfooy
    oracle.append(False)  # fo
    oracle.append(False)  # bar
    oracle.append(True)   # foofoo
    oracle.append(False)  # ""

    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 1, r)
        assert_equal(
            got, oracle[r],
            "regexp_like(x,'foo') row " + String(r) + " (x=" + vals[r] + ")",
        )


# =============================================================================
# §3 — regexp_like(col, '[0-9]+'). Char-class + quantifier: one-or-more digits
# anywhere. Exercises a non-trivial NFA fragment (OP_CLASS + OP_SPLIT loop) over
# the row path.
# =============================================================================
def test_regexp_charclass_digits() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))      # 0
    pool.append(make_regexp(0, 0))       # 1 ROOT

    var prog = RegexProgram.compile("[0-9]+", "")
    var rp = _regex_pool_with(prog^)

    var vals = List[String]()
    vals.append("abc123")     # match: has digits
    vals.append("007bond")    # match
    vals.append("noDigits")   # no
    vals.append("a1b")        # match: single digit
    vals.append("")           # no

    var rb = _build_string_block(vals)
    var cs = RowCellSource(rb, _string_offsets(), _string_dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String](), regex_pool=rp^)

    var oracle = List[Bool]()
    oracle.append(True)   # abc123
    oracle.append(True)   # 007bond
    oracle.append(False)  # noDigits
    oracle.append(True)   # a1b
    oracle.append(False)  # ""

    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 1, r)
        assert_equal(
            got, oracle[r],
            "regexp_like(x,'[0-9]+') row " + String(r) + " (x=" + vals[r] + ")",
        )


# =============================================================================
# §4 — NOT regexp_like(col, '^a.*z$'). NOT(EXPR_REGEXP) with 3VL over a
# NULLABLE column. NULL rows are EXCLUDED (NOT NULL = NULL -> dropped from a
# WHERE). The NULL rows' RAW stored bytes ARE "abz" (which WOULD match) so a
# non-3VL negation would WRONGLY include them; the 3VL exclusion is the only
# thing dropping them — distinguishing 3VL-correct from a plain raw negation.
# Pool:
#   0: EXPR_COL_STRING(col0)
#   1: EXPR_REGEXP(0, 0)
#   2: EXPR_NOT_BOOL(1)   ROOT
# =============================================================================
comptime _SVAL_OFF: Int = 8           # validity bitmap after the 8-byte var slot
comptime _SSTRIDE_NULLABLE: Int = 9   # 8 (var slot) + 1 (validity byte for 1 col)


def test_not_regexp_3vl_null() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))      # 0
    pool.append(make_regexp(0, 0))       # 1
    pool.append(make_not_bool(1))        # 2 ROOT

    var prog = RegexProgram.compile("^a.*z$", "")
    var rp = _regex_pool_with(prog^)

    var vals = List[String]()
    vals.append("abz")     # present, matches '^a.*z$' -> NOT -> False
    vals.append("abz")     # NULL -> excluded (raw "abz" WOULD match)
    vals.append("hello")   # present, no match -> NOT -> True
    vals.append("abz")     # NULL -> excluded
    vals.append("zzz")     # present, no match -> NOT -> True
    var is_null = List[Bool]()
    is_null.append(False); is_null.append(True); is_null.append(False)
    is_null.append(True); is_null.append(False)

    var n = len(vals)
    var rb = RowBlock.with_capacity(n, n * 16, _SSTRIDE_NULLABLE)
    for i in range(n):
        rb.write_var_string_cell(i, _SOFF0, vals[i].as_bytes())
        if is_null[i]:
            rb.set_cell_null(i, _SVAL_OFF, 0)
    rb.set_n_rows(n)

    var cs = RowCellSource(
        rb, _string_offsets(), _string_dtypes(),
        has_validity=True, validity_offset=_SVAL_OFF,
    )
    var exec = ExpressionExecutor(pool^, 2, List[String](), regex_pool=rp^)

    for r in range(n):
        var got = exec._eval_bool_from_source(cs, 2, r)
        var v = vals[r]
        var matches = v.startswith("a") and v.endswith("z")
        # 3VL: NULL operand -> NOT NULL = NULL -> excluded (False); else NOT match.
        var want = False if is_null[r] else (not matches)
        assert_equal(
            got, want,
            "NOT regexp_like(x,'^a.*z$') row " + String(r)
            + " null=" + String(is_null[r]) + " x=" + v,
        )


def test_regexp_3vl_null_stored_match() raises:
    """Plain `regexp_like(x, '^a.*z$')`, no NOT: a NULL row whose stored
    bytes ('abz') match is UNKNOWN and excluded. Under NOT, FALSE and
    UNKNOWN both exclude the row, so only the plain form tells a walker that
    reads the stored bytes of a NULL cell from one that does not."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))      # 0
    pool.append(make_regexp(0, 0))       # 1 ROOT

    var prog = RegexProgram.compile("^a.*z$", "")
    var rp = _regex_pool_with(prog^)

    var vals: List[String] = ["abz", "abz", "hello", "azz"]
    var is_null: List[Bool] = [False, True, False, True]
    var n = len(vals)
    var rb = RowBlock.with_capacity(n, n * 16, _SSTRIDE_NULLABLE)
    for i in range(n):
        rb.write_var_string_cell(i, _SOFF0, vals[i].as_bytes())
        if is_null[i]:
            rb.set_cell_null(i, _SVAL_OFF, 0)
    rb.set_n_rows(n)

    var cs = RowCellSource(
        rb, _string_offsets(), _string_dtypes(),
        has_validity=True, validity_offset=_SVAL_OFF,
    )
    var exec = ExpressionExecutor(pool^, 1, List[String](), regex_pool=rp^)

    var want: List[Bool] = [True, False, False, False]
    for r in range(n):
        assert_equal(
            exec._eval_bool_from_source(cs, 1, r), want[r],
            "regexp_like(x,'^a.*z$') row " + String(r)
            + " null=" + String(is_null[r]) + " x=" + vals[r],
        )
    var sel = exec.select_filter_from_source(cs)
    assert_equal(sel.len(), 1, "regexp_like survivors")
    assert_equal(Int(sel.get(0)), 0, "regexp_like survivor 0")


def main() raises:
    var suite = TestSuite()
    suite.test[test_regexp_anchored]()
    suite.test[test_regexp_contains_unanchored]()
    suite.test[test_regexp_charclass_digits]()
    suite.test[test_not_regexp_3vl_null]()
    suite.test[test_regexp_3vl_null_stored_match]()
    suite^.run()
