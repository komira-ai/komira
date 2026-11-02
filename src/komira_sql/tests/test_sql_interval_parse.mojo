# =============================================================================
# sql_parser: the INTERVAL literal
# =============================================================================
#
# What each test proves, and the defect it would catch:
#   1. Every interval spelling TPC-H uses (`'90' day`, `'3' month`,
#      `'1' year`, `'1' month`) parses to an SX_INTERVAL carrying the count
#      and the unit, as the right operand of an SXOP_ADD / SXOP_SUB whose left
#      operand is the DATE literal. (catches: the unit or count dropped; `-`
#      read as `+`)
#   2. Plural units, WEEK, signed counts, a bare integer count, and upper-case
#      keywords. (catches: `years` refused; the sign of `'-5'` lost)
#   3. `interval` stays a column name when no count follows it.
#      (catches: the keyword reading taken unconditionally)
#   4. The refusals, each named: a unit inside the string, a non-integer
#      count, a count beyond 10^9, a missing unit, and the units outside the
#      accepted set. (catches: `'3 month'` silently read as 3 of nothing)

from std.testing import TestSuite, assert_equal, assert_true

from komira_sql.sql_ast import (
    SqlExpr, SqlStatement, SXIVL_DAY, SXIVL_MONTH, SXIVL_WEEK, SXIVL_YEAR,
    SXOP_ADD, SXOP_SUB, SX_BINARY, SX_COLUMN, SX_DATE, SX_INTERVAL,
)
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _e(expr: String) raises -> SqlExpr:
    var st = parse_sql(tokenize("SELECT " + expr + " FROM t"))
    return st.query.select_items[0].expr.copy()


def _err(expr: String) raises -> String:
    try:
        _ = parse_sql(tokenize("SELECT " + expr + " FROM t"))
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + expr)


def _shift(expr: String, op: UInt8, date_text: String, count: Int, unit: UInt8) raises:
    """`expr` is `date '<date_text>' <+|-> interval ...` with these parts."""
    var e = _e(expr)
    assert_equal(Int(e.tag), Int(SX_BINARY), expr)
    assert_equal(Int(e.op), Int(op), expr)
    var l = e._binary.value().left[].copy()
    var r = e._binary.value().right[].copy()
    assert_equal(Int(l.tag), Int(SX_DATE), expr)
    assert_equal(l.text, date_text, expr)
    assert_equal(Int(r.tag), Int(SX_INTERVAL), expr)
    assert_equal(Int(r.int_val), count, expr)
    assert_equal(Int(r.op), Int(unit), expr)


def test_every_tpch_interval_form_parses() raises:
    _shift("date '1998-12-01' - interval '90' day", SXOP_SUB, "1998-12-01", 90, SXIVL_DAY)
    _shift("date '1993-07-01' + interval '3' month", SXOP_ADD, "1993-07-01", 3, SXIVL_MONTH)
    _shift("date '1994-01-01' + interval '1' year", SXOP_ADD, "1994-01-01", 1, SXIVL_YEAR)
    _shift("date '1995-09-01' + interval '1' month", SXOP_ADD, "1995-09-01", 1, SXIVL_MONTH)


def test_interval_spellings() raises:
    _shift("date '2000-01-01' + interval '2' years", SXOP_ADD, "2000-01-01", 2, SXIVL_YEAR)
    _shift("date '2000-01-01' + interval '2' months", SXOP_ADD, "2000-01-01", 2, SXIVL_MONTH)
    _shift("date '2000-01-01' + interval '2' days", SXOP_ADD, "2000-01-01", 2, SXIVL_DAY)
    _shift("date '2000-01-01' + interval '2' week", SXOP_ADD, "2000-01-01", 2, SXIVL_WEEK)
    _shift("date '2000-01-01' + interval '2' weeks", SXOP_ADD, "2000-01-01", 2, SXIVL_WEEK)
    _shift("date '2000-01-01' + interval '-5' day", SXOP_ADD, "2000-01-01", -5, SXIVL_DAY)
    _shift("date '2000-01-01' + interval '+5' day", SXOP_ADD, "2000-01-01", 5, SXIVL_DAY)
    _shift("date '2000-01-01' + interval 7 day", SXOP_ADD, "2000-01-01", 7, SXIVL_DAY)
    _shift("date '2000-01-01' + interval -3 day", SXOP_ADD, "2000-01-01", -3, SXIVL_DAY)
    _shift("date '2000-01-01' + interval +3 months", SXOP_ADD, "2000-01-01", 3, SXIVL_MONTH)
    _shift("date '2000-01-01' - interval -3 year", SXOP_SUB, "2000-01-01", -3, SXIVL_YEAR)
    _shift("DATE '2000-01-01' + INTERVAL '1' YEAR", SXOP_ADD, "2000-01-01", 1, SXIVL_YEAR)
    _shift("date '2000-01-01' + interval '1000000000' day", SXOP_ADD, "2000-01-01", 1000000000, SXIVL_DAY)


def test_interval_left_operand_and_chain() raises:
    var e = _e("interval '1' day + date '2000-01-01'")
    assert_equal(Int(e._binary.value().left[].tag), Int(SX_INTERVAL))
    assert_equal(Int(e._binary.value().right[].tag), Int(SX_DATE))
    # Left-associative: ((date + year) - day).
    var c = _e("date '2000-01-01' + interval '1' year - interval '1' day")
    assert_equal(Int(c.op), Int(SXOP_SUB))
    assert_equal(Int(c._binary.value().right[].tag), Int(SX_INTERVAL))
    assert_equal(Int(c._binary.value().left[].tag), Int(SX_BINARY))
    assert_equal(Int(c._binary.value().left[]._binary.value().right[].op), Int(SXIVL_YEAR))


def test_interval_is_still_a_column_name() raises:
    assert_equal(Int(_e("interval").tag), Int(SX_COLUMN))
    assert_equal(_e("interval").text, "interval")
    assert_equal(Int(_e("interval + 1").tag), Int(SX_BINARY))
    assert_equal(Int(_e("interval + 1")._binary.value().left[].tag), Int(SX_COLUMN))


def test_signed_bare_count_needs_a_unit_to_be_an_interval() raises:
    # Without a unit word after the integer, `interval - 3` is a column minus 3.
    var e = _e("interval - 3")
    assert_equal(Int(e.tag), Int(SX_BINARY))
    assert_equal(Int(e.op), Int(SXOP_SUB))
    assert_equal(Int(e._binary.value().left[].tag), Int(SX_COLUMN))
    var f = _e("interval -3 + 1")
    assert_equal(Int(f.op), Int(SXOP_ADD))
    assert_equal(Int(f._binary.value().left[].tag), Int(SX_BINARY))
    assert_equal(Int(f._binary.value().left[]._binary.value().left[].tag), Int(SX_COLUMN))


def _refuses(expr: String, needle: String) raises:
    var m = _err(expr)
    assert_true(needle in m, "`" + expr + "` raised: " + m)


def test_interval_refusals_are_named() raises:
    _refuses("interval '3 month'", "is not a plain integer count")
    _refuses("interval '3 month' + date '2000-01-01'", "unit outside the quotes")
    _refuses("interval '1.5' day", "is not a plain integer count")
    _refuses("interval '' day", "is not a plain integer count")
    _refuses("interval '-' day", "is not a plain integer count")
    _refuses("interval '1000000001' day", "beyond +/-10^9")
    _refuses("interval '-1000000001' day", "beyond +/-10^9")
    _refuses("interval '99999999999' day", "is not a plain integer count")
    _refuses("interval 99999999999999999999 day", "beyond 10^9")
    _refuses("(interval '1')", "needs a unit")
    _refuses("interval '1' + 2", "needs a unit")
    _refuses("interval -3 hour", "INTERVAL unit 'hour'")
    _refuses("interval -1000000001 day", "beyond +/-10^9")
    _refuses("interval '1' hour", "INTERVAL unit 'hour'")
    _refuses("interval '1' minute", "INTERVAL unit 'minute'")
    _refuses("interval '1' second", "INTERVAL unit 'second'")
    _refuses("interval '1' quarter", "INTERVAL unit 'quarter'")
    _refuses("interval '1' decade", "INTERVAL unit 'decade'")
    _refuses("interval '1' millisecond", "INTERVAL unit 'millisecond'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
