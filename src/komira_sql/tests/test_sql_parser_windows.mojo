# =============================================================================
# sql_parser: window functions, OVER clauses and frames
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. An aggregate with OVER becomes a window: its SXWIN_* code, its
#      argument column and qualifier, the partition and order keys with
#      their qualifiers and directions, and the frame (ROWS / RANGE, BETWEEN
#      or the single-bound shorthand, each bound kind). (catches: a key's
#      qualifier dropped; DESC not recorded; the shorthand's end not
#      CURRENT ROW)
#   2. Window-aggregate misuse is refused: DISTINCT, an expression argument,
#      a named window (bare or inside the parentheses), a computed key, and
#      each malformed frame bound, including a RANGE offset past BIGINT.
#      (catches: `OVER w` reported as a parenthesis error)
#   3. Ranking and distribution windows: row_number / rank / dense_rank,
#      percent_rank / cume_dist, ntile(k) with its bucket count, and their
#      refusals. (catches: ntile(0) accepted)
#   4. Value windows: lag / lead offsets (signed) and every default literal
#      kind, first_value / last_value / nth_value arity, RESPECT NULLS
#      accepted and IGNORE NULLS refused, and the column-argument rules.
#      (catches: a negative default not negated; `-9223372036854775808`
#      refused as out of range)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_sql.sql_token import tokenize
from komira_sql.sql_ast import (
    SqlExpr,
    SqlStatement,
    SqlWindowData,
    SX_WINDOW, SX_INT, SX_FLOAT, SX_STRING, SX_DATE,
    SXWIN_ROW_NUMBER, SXWIN_RANK, SXWIN_DENSE_RANK,
    SXWIN_SUM, SXWIN_COUNT, SXWIN_MIN, SXWIN_MAX, SXWIN_AVG,
    SXWIN_LAG, SXWIN_LEAD, SXWIN_FIRST_VALUE, SXWIN_LAST_VALUE, SXWIN_NTH_VALUE,
    SXWIN_PERCENT_RANK, SXWIN_CUME_DIST, SXWIN_NTILE,
    SXFRAME_ROWS, SXFRAME_RANGE,
    SXFRAME_UNBOUNDED_PRECEDING, SXFRAME_PRECEDING, SXFRAME_CURRENT_ROW,
    SXFRAME_FOLLOWING, SXFRAME_UNBOUNDED_FOLLOWING,
)
from komira_sql.sql_parser import parse_sql


def _parse(sql: String) raises -> SqlStatement:
    return parse_sql(tokenize(sql))


def _win(expr: String) raises -> SqlWindowData:
    var st = _parse("SELECT " + expr + " FROM t")
    ref e = st.query.select_items[0].expr
    assert_equal(Int(e.tag), Int(SX_WINDOW), expr)
    return e._window.value().copy()


def _err(sql: String) raises -> String:
    try:
        _ = _parse(sql)
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + sql)


def _refuses(expr: String, needle: String) raises:
    var m = _err("SELECT " + expr + " FROM t")
    assert_true(needle in m, "`" + expr + "` raised: " + m)


def _frame(
    w: SqlWindowData, units: UInt8, st: UInt8, so: Int64, en: UInt8, eo: Int64
) raises:
    assert_true(w.has_frame)
    assert_equal(Int(w.frame_units), Int(units))
    assert_equal(Int(w.frame_start_tag), Int(st))
    assert_equal(w.frame_start_offset, so)
    assert_equal(Int(w.frame_end_tag), Int(en))
    assert_equal(w.frame_end_offset, eo)


def test_aggregate_windows_record_keys_and_frames() raises:
    var w = _win(
        "sum(v) OVER (PARTITION BY a.k, j ORDER BY t DESC, b.u ASC, w"
        " ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)"
    )
    assert_equal(Int(w.func), Int(SXWIN_SUM))
    assert_equal(w.arg_col, "v")
    assert_equal(w.arg_qual, "")
    assert_equal(len(w.partition_by), 2)
    assert_equal(w.partition_by[0], "k")
    assert_equal(w.partition_qual[0], "a")
    assert_equal(w.partition_by[1], "j")
    assert_equal(w.partition_qual[1], "")
    assert_equal(len(w.order_by), 3)
    assert_equal(w.order_by[1], "u")
    assert_equal(w.order_qual[1], "b")
    assert_true(w.descending[0])
    assert_false(w.descending[1])
    assert_false(w.descending[2])
    _frame(w, SXFRAME_ROWS, SXFRAME_PRECEDING, 2, SXFRAME_CURRENT_ROW, 0)
    var c = _win("count(*) OVER ()")
    assert_equal(Int(c.func), Int(SXWIN_COUNT))
    assert_equal(c.arg_col, "")
    assert_false(c.has_frame)
    var m = _win("min(q.v) OVER (ORDER BY k RANGE UNBOUNDED PRECEDING)")
    assert_equal(Int(m.func), Int(SXWIN_MIN))
    assert_equal(m.arg_col, "v")
    assert_equal(m.arg_qual, "q")
    _frame(m, SXFRAME_RANGE, SXFRAME_UNBOUNDED_PRECEDING, 0, SXFRAME_CURRENT_ROW, 0)
    var x = _win("max(v) OVER (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)")
    assert_equal(Int(x.func), Int(SXWIN_MAX))
    _frame(x, SXFRAME_ROWS, SXFRAME_CURRENT_ROW, 0, SXFRAME_UNBOUNDED_FOLLOWING, 0)
    var a = _win("avg(v) OVER (ROWS BETWEEN 1 FOLLOWING AND 3 FOLLOWING)")
    assert_equal(Int(a.func), Int(SXWIN_AVG))
    _frame(a, SXFRAME_ROWS, SXFRAME_FOLLOWING, 1, SXFRAME_FOLLOWING, 3)
    assert_equal(Int(_win("mean(v) OVER ()").func), Int(SXWIN_AVG))


def test_window_aggregate_misuse_refuses() raises:
    _refuses("count(DISTINCT v) OVER ()", "DISTINCT inside an OVER (window) aggregate")
    _refuses("sum(v + 1) OVER ()", "a window aggregate argument must be a plain column reference")
    _refuses("sum(v) OVER w", "a named window reference `OVER w`")
    _refuses("sum(v) OVER (w ORDER BY k)", "a named window reference `OVER (w ...)`")
    _refuses("sum(v) OVER (GROUPS 1 PRECEDING)", "')' to close the OVER clause")
    _refuses("sum(v) OVER 5", "'(' after OVER")
    _refuses("sum(v) OVER (PARTITION k)", "expected keyword 'by'")
    _refuses("sum(v) OVER (ORDER k)", "expected keyword 'by'")
    _refuses("sum(v) OVER (PARTITION BY 5)", "expected a column name in the OVER clause")
    _refuses("sum(v) OVER (PARTITION BY q.)", "expected column after '.' in OVER clause")
    _refuses("sum(v) OVER (PARTITION BY f(g))", "a window PARTITION BY key must be a plain column reference (e.g. `OVER (PARTITION BY g)`) — `f(...)`")
    _refuses("sum(v) OVER (ORDER BY f(g))", "a window ORDER BY key must be a plain column reference")
    var key_msg = _err("SELECT sum(v) OVER (ORDER BY f(g)) FROM t")
    assert_true(key_msg.endswith("which this engine cannot lower yet"), key_msg)
    _refuses("sum(v) OVER (ROWS UNBOUNDED)", "expected PRECEDING / FOLLOWING after UNBOUNDED")
    _refuses("sum(v) OVER (ROWS CURRENT)", "expected keyword 'row'")
    _refuses("sum(v) OVER (ROWS 2)", "expected PRECEDING / FOLLOWING after a frame offset")
    _refuses("sum(v) OVER (ROWS x)", "expected a frame bound")
    _refuses("sum(v) OVER (ROWS BETWEEN 1 PRECEDING 2 FOLLOWING)", "expected keyword 'and'")
    _refuses(
        "sum(v) OVER (ORDER BY k RANGE BETWEEN 18446744073709551617 PRECEDING AND CURRENT ROW)",
        "the RANGE frame offset 18446744073709551617 is past BIGINT",
    )
    _refuses(
        "sum(v) OVER (ROWS 18446744073709551617 PRECEDING)",
        "the window frame offset 18446744073709551617 is out of range for BIGINT",
    )
    var r = _win("sum(v) OVER (ORDER BY k RANGE 5 PRECEDING)")
    _frame(r, SXFRAME_RANGE, SXFRAME_PRECEDING, 5, SXFRAME_CURRENT_ROW, 0)


def test_ranking_and_distribution_windows() raises:
    assert_equal(Int(_win("row_number() OVER (ORDER BY k)").func), Int(SXWIN_ROW_NUMBER))
    assert_equal(Int(_win("rank() OVER (ORDER BY k)").func), Int(SXWIN_RANK))
    assert_equal(Int(_win("dense_rank() OVER (PARTITION BY g ORDER BY k)").func), Int(SXWIN_DENSE_RANK))
    assert_equal(Int(_win("percent_rank() OVER (ORDER BY k)").func), Int(SXWIN_PERCENT_RANK))
    assert_equal(Int(_win("cume_dist() OVER ()").func), Int(SXWIN_CUME_DIST))
    var n = _win("ntile(4) OVER (ORDER BY k)")
    assert_equal(Int(n.func), Int(SXWIN_NTILE))
    assert_equal(n.value_offset, 4)
    assert_equal(_win("percent_rank() OVER ()").value_offset, 0)
    _refuses("ntile(a) OVER ()", "ntile(...)'s bucket count must be a positive integer literal")
    _refuses("ntile(0) OVER ()", "ntile(0) — the bucket count must be greater than zero")
    _refuses("ntile(4, 2) OVER ()", "')' after ntile's bucket count")
    _refuses("percent_rank(1) OVER ()", "')' (percent_rank() takes no arguments)")
    _refuses("ntile(99999999999999999999) OVER ()", "the ntile bucket count 99999999999999999999 is out of range")


def test_value_window_offsets_and_defaults() raises:
    var lg = _win("lag(v) OVER (ORDER BY k)")
    assert_equal(Int(lg.func), Int(SXWIN_LAG))
    assert_equal(lg.arg_col, "v")
    assert_equal(lg.value_offset, 1)
    assert_false(lg.has_default)
    var ld = _win("lead(q.v, 2, 0) OVER (ORDER BY k)")
    assert_equal(Int(ld.func), Int(SXWIN_LEAD))
    assert_equal(ld.arg_qual, "q")
    assert_equal(ld.value_offset, 2)
    assert_true(ld.has_default)
    assert_equal(Int(ld.default_kind), Int(SX_INT))
    assert_equal(ld.default_int, 0)
    var neg = _win("lag(v, -1, -5) OVER ()")
    assert_equal(neg.value_offset, -1)
    assert_equal(neg.default_int, -5)
    assert_equal(_win("lag(v, 1, -9223372036854775808) OVER ()").default_int, Int64.MIN)
    var fl = _win("lag(v, 1, 2.5) OVER ()")
    assert_equal(Int(fl.default_kind), Int(SX_FLOAT))
    assert_equal(fl.default_float, 2.5)
    assert_equal(_win("lag(v, 1, -2.5) OVER ()").default_float, -2.5)
    var st = _win("lag(v, 1, 'x') OVER ()")
    assert_equal(Int(st.default_kind), Int(SX_STRING))
    assert_equal(st.default_text, "x")
    var dt = _win("lag(v, 1, date '2026-09-15') OVER ()")
    assert_equal(Int(dt.default_kind), Int(SX_DATE))
    assert_equal(dt.default_text, "2026-09-15")
    var nl = _win("lag(v, 1, NULL RESPECT NULLS) OVER ()")
    assert_false(nl.has_default)
    var fv = _win("first_value(v) OVER (ORDER BY k ROWS UNBOUNDED PRECEDING)")
    assert_equal(Int(fv.func), Int(SXWIN_FIRST_VALUE))
    assert_equal(fv.value_offset, 0)
    assert_equal(Int(_win("last_value(v RESPECT NULLS) OVER ()").func), Int(SXWIN_LAST_VALUE))
    var nv = _win("nth_value(v, 2) OVER ()")
    assert_equal(Int(nv.func), Int(SXWIN_NTH_VALUE))
    assert_equal(nv.value_offset, 2)


def test_value_window_refusals() raises:
    _refuses("lag(v, 1, a) OVER ()", "the DEFAULT of lag(col, k, default) OVER must be a literal")
    _refuses("lag(v, 1, -'x') OVER ()", "the DEFAULT of lag(col, k, default) OVER must be a literal")
    _refuses("lag(v, 1, -NULL) OVER ()", "the DEFAULT of lag(col, k, default) OVER must be a literal")
    _refuses("nth_value(v) OVER ()", "NTH_VALUE needs 2 parameters")
    _refuses("nth_value(v, 2, 3) OVER ()", "nth_value() takes two arguments, the column and n")
    _refuses("first_value(v, 1) OVER ()", "first_value() takes exactly ONE argument")
    _refuses("last_value(v, 1) OVER ()", "last_value() takes exactly ONE argument")
    _refuses("lag(v IGNORE NULLS) OVER ()", "lag(... IGNORE NULLS)")
    _refuses("lag(v RESPECT x) OVER ()", "expected keyword 'nulls'")
    _refuses("lag(1) OVER ()", "the argument of lag(...) OVER must be a plain column reference")
    _refuses("lag((v)) OVER ()", "the argument of lag(...) OVER must be a plain column reference")
    _refuses("lag(v + 1) OVER ()", "the argument of lag(...) OVER must be a plain column reference")
    _refuses("lag(q.*) OVER ()", "expected column after '.' in lag(...)")
    _refuses("lag(v, x) OVER ()", "the offset of lag(...) OVER must be an INTEGER literal")
    _refuses("nth_value(v, 1.5) OVER ()", "the n of nth_value(...) OVER must be an INTEGER literal")
    _refuses("lag(v, 18446744073709551617) OVER ()", "the offset of lag() 18446744073709551617 is out of range for BIGINT")
    _refuses("lag(v, 1, 18446744073709551617) OVER ()", "the default of lag() 18446744073709551617 is out of range for BIGINT")
    _refuses("lag(v, 1, 2 x) OVER ()", "')' to close lag(...)")
    _refuses("lag(v", "SQL syntax error: expected ')'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
