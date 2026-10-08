# =============================================================================
# Direct tests of komira_sql's scalar-function table (sql_fn_table)
# =============================================================================
#
# What each test proves, and the defect (mutant) it catches:
#   1. `upper` and its alias `ucase` return one row: FNK_STRING_FN on
#      STRFN_UPPER, arity 1..1, claiming the name.
#      (mutant caught: an alias moved off its row, or the row widened to 1..2)
#   2. `strlen` (bytes) is its own row on STRFN_STRLEN and is not an alias of
#      `length` (STRFN_LENGTH, characters), whose aliases all share one row.
#      (mutant caught: `strlen` made an alias of `length`)
#   3. `coalesce` lowers to DSG_COALESCE and `ifnull` to DSG_IFNULL, both
#      FNK_DESUGAR with FN_ARITY_OWN (the lowering checks the arity).
#      (mutant caught: the DSG_COALESCE and DSG_IFNULL rows swapped)
#   4. An unknown name returns the FNK_NONE row the binder's unknown-function
#      error depends on: op 0, the open arity sentinels, no reason, claims
#      nothing. Names are looked up exactly as given (the parser lower-folds).
#      (mutant caught: the absent row built with another kind, or claiming)
#   5. A refusal row (`nextafter`) is FNK_REFUSED with its family's non-empty
#      reason and `lowers_to_a_node` False, so a UDF may take the name.
#      (mutant caught: `lowers_to_a_node` derived from `kind != FNK_NONE`,
#      which answers yes for every refusal row)
#   6. Every name in sql_date_part_universe() resolves through
#      sql_date_part_unit or sql_date_part_desugar, except the five real
#      specifiers this engine refuses (epoch, julian, timezone,
#      timezone_hour, timezone_minute), which resolve through neither; and
#      every spelling either table serves is in the universe.
#      (mutant caught: a name added to the universe with no unit or desugar
#      row, or a served spelling missing from it)
#   7. sql_date_part_supported_summary() renders exactly the served half and
#      the refused half of the universe, in universe order.
#      (mutant caught: a name filed in the wrong half, a separator dropped)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_plan_expr.expr import STRFN_LENGTH, STRFN_STRLEN, STRFN_UPPER
from komira_sql.sql_fn_table import (
    DSG_COALESCE,
    DSG_IFNULL,
    FNK_DESUGAR,
    FNK_NONE,
    FNK_REFUSED,
    FNK_STRING_FN,
    FN_ARITY_OWN,
    FN_ARITY_UNBOUNDED,
    sql_date_part_desugar,
    sql_date_part_supported_summary,
    sql_date_part_unit,
    sql_date_part_universe,
    sql_scalar_fn_spec,
)


def test_upper_and_ucase_are_one_row() raises:
    var names: List[String] = ["upper", "ucase"]
    for i in range(len(names)):
        var s = sql_scalar_fn_spec(names[i])
        assert_equal(Int(s.kind), Int(FNK_STRING_FN), names[i])
        assert_equal(Int(s.op), Int(STRFN_UPPER), names[i])
        assert_equal(s.min_args, 1, names[i])
        assert_equal(s.max_args, 1, names[i])
        assert_true(s.lowers_to_a_node, names[i])


def test_strlen_counts_bytes_on_its_own_row() raises:
    var s = sql_scalar_fn_spec("strlen")
    assert_equal(Int(s.kind), Int(FNK_STRING_FN))
    assert_equal(Int(s.op), Int(STRFN_STRLEN))
    assert_equal(s.min_args, 1)
    assert_equal(s.max_args, 1)
    var length_names: List[String] = ["length", "len", "char_length", "character_length"]
    for i in range(len(length_names)):
        var l = sql_scalar_fn_spec(length_names[i])
        assert_equal(Int(l.kind), Int(FNK_STRING_FN), length_names[i])
        assert_equal(Int(l.op), Int(STRFN_LENGTH), length_names[i])
        assert_true(Int(l.op) != Int(s.op), length_names[i])


def test_coalesce_and_ifnull_desugar_with_their_own_arity() raises:
    var c = sql_scalar_fn_spec("coalesce")
    assert_equal(Int(c.kind), Int(FNK_DESUGAR))
    assert_equal(Int(c.op), Int(DSG_COALESCE))
    assert_equal(c.min_args, FN_ARITY_OWN)
    assert_true(c.lowers_to_a_node)
    var f = sql_scalar_fn_spec("ifnull")
    assert_equal(Int(f.kind), Int(FNK_DESUGAR))
    assert_equal(Int(f.op), Int(DSG_IFNULL))
    assert_equal(f.min_args, FN_ARITY_OWN)
    assert_true(f.lowers_to_a_node)
    assert_true(Int(DSG_COALESCE) != Int(DSG_IFNULL))


def test_an_unknown_name_is_the_absent_row() raises:
    # A typo, an empty name, an upper-case spelling of a served name and a
    # PostgreSQL name DuckDB does not have.
    var unknown: List[String] = ["no_such_fn", "", "UPPER", "isoweek"]
    for i in range(len(unknown)):
        var s = sql_scalar_fn_spec(unknown[i])
        assert_equal(Int(s.kind), Int(FNK_NONE), unknown[i])
        assert_equal(Int(s.op), 0, unknown[i])
        assert_equal(s.min_args, FN_ARITY_OWN, unknown[i])
        assert_equal(s.max_args, FN_ARITY_UNBOUNDED, unknown[i])
        assert_equal(s.reason, String(""), unknown[i])
        assert_false(s.lowers_to_a_node, unknown[i])


def test_a_refusal_row_states_a_reason_and_claims_nothing() raises:
    var s = sql_scalar_fn_spec("nextafter")
    assert_equal(Int(s.kind), Int(FNK_REFUSED))
    assert_true(s.reason.byte_length() > 0)
    assert_true(s.reason.startswith("SQL not supported: `nextafter`"))
    assert_true("MATH2_" in s.reason)
    assert_false(s.lowers_to_a_node)


def _refused_specifiers() -> List[String]:
    return ["epoch", "julian", "timezone", "timezone_hour", "timezone_minute"]


def _in(names: List[String], n: String) -> Bool:
    for i in range(len(names)):
        if names[i] == n:
            return True
    return False


def test_every_universe_name_resolves_or_is_a_measured_refusal() raises:
    var uni = sql_date_part_universe()
    var refused = _refused_specifiers()
    var resolved = 0
    for i in range(len(uni)):
        var hit = Bool(sql_date_part_unit(uni[i])) or Bool(sql_date_part_desugar(uni[i]))
        assert_equal(hit, not _in(refused, uni[i]), uni[i])
        if hit:
            resolved += 1
    assert_equal(resolved, len(uni) - len(refused))
    for i in range(len(refused)):
        assert_true(_in(uni, refused[i]), refused[i])
    # The other direction: a served spelling missing from the universe would
    # be left out of the refusal message. These are the desugar spellings and
    # the spellings that differ most from their unit's name.
    var served: List[String] = [
        "century", "centuries", "cent", "decade", "decades", "dec", "decs",
        "millennium", "millennia", "mil", "mils", "era", "dow", "doy", "w",
        "msecond", "useconds", "m", "dayofmonth", "yearweek",
    ]
    for i in range(len(served)):
        assert_true(_in(uni, served[i]), served[i])


def test_the_refusal_summary_is_derived_from_the_tables() raises:
    var expected = String(
        "this engine serves year, years, yr, yrs, y, quarter, quarters, month,"
        " months, mon, mons, day, days, d, dayofmonth, hour, hours, h, hr, hrs,"
        " minute, minutes, min, mins, m, second, seconds, s, sec, secs,"
        " dayofweek, dow, weekday, isodow, dayofyear, doy, week, weeks,"
        " weekofyear, w, isoyear, yearweek, millisecond, milliseconds, msec,"
        " msecs, ms, msecond, mseconds, microsecond, microseconds, usec, usecs,"
        " us, usecond, useconds, century, centuries, cent, decade, decades, dec,"
        " decs, millennium, millennia, mil, mils, era. It does NOT serve epoch,"
        " julian, timezone, timezone_hour, timezone_minute, each of which IS a"
        " real v1.5.3 specifier with a measured blocker (epoch / julian read a"
        " RAW value no unit on this wire carries; the timezone reads answer 0"
        " for every naive timestamp and are refused rather than served as a"
        " plausible zero). This list is DERIVED from the specifier tables, not"
        " written beside them"
    )
    assert_equal(sql_date_part_supported_summary(), expected)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
