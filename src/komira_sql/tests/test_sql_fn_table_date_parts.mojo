# =============================================================================
# Row pins: the date_part specifier tables and the date_trunc period table
# =============================================================================
#
# What it proves: every spelling on every row of sql_date_part_unit (56),
# sql_date_part_desugar (12) and sql_date_trunc_unit (57) resolves to its
# row's unit, and a specifier resolves in exactly one of the two specifier
# tables (they return different vocabularies). Names on no row return None.
# Mutants it catches: a spelling moved to another unit (`dow` truncating to
# the week, `m` read as month), an alias dropped from a row, a desugar
# specifier given an EXTRACT_* unit as well.
# The lists were generated from the rows.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_plan_expr.expr import (
    EXTRACT_DAY,
    EXTRACT_DAYOFWEEK,
    EXTRACT_DAYOFYEAR,
    EXTRACT_HOUR,
    EXTRACT_ISODOW,
    EXTRACT_ISOYEAR,
    EXTRACT_MICROSECOND,
    EXTRACT_MILLISECOND,
    EXTRACT_MINUTE,
    EXTRACT_MONTH,
    EXTRACT_QUARTER,
    EXTRACT_SECOND,
    EXTRACT_TRUNC_DAY,
    EXTRACT_TRUNC_HOUR,
    EXTRACT_TRUNC_MICROSECOND,
    EXTRACT_TRUNC_MILLISECOND,
    EXTRACT_TRUNC_MINUTE,
    EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_QUARTER,
    EXTRACT_TRUNC_SECOND,
    EXTRACT_TRUNC_WEEK,
    EXTRACT_TRUNC_YEAR,
    EXTRACT_WEEK,
    EXTRACT_YEAR,
    EXTRACT_YEARWEEK,
)
from komira_sql.sql_fn_table import (
    DSG_CENTURY,
    DSG_DECADE,
    DSG_ERA,
    DSG_MILLENNIUM,
    sql_date_part_desugar,
    sql_date_part_unit,
    sql_date_trunc_unit,
)


def _unit(unit: UInt8, names: List[String]) raises:
    for i in range(len(names)):
        var u = sql_date_part_unit(names[i])
        assert_true(u, names[i])
        assert_equal(Int(u.value()), Int(unit), names[i])
        assert_false(sql_date_part_desugar(names[i]), names[i])


def _desugar(tag: UInt8, names: List[String]) raises:
    for i in range(len(names)):
        var d = sql_date_part_desugar(names[i])
        assert_true(d, names[i])
        assert_equal(Int(d.value()), Int(tag), names[i])
        assert_false(sql_date_part_unit(names[i]), names[i])


def _trunc(unit: UInt8, names: List[String]) raises:
    for i in range(len(names)):
        var u = sql_date_trunc_unit(names[i])
        assert_true(u, names[i])
        assert_equal(Int(u.value()), Int(unit), names[i])


def test_specifier_units() raises:
    _unit(
        EXTRACT_YEAR,
        [
            "year", "years", "yr", "yrs", "y",
        ],
    )
    _unit(
        EXTRACT_QUARTER,
        [
            "quarter", "quarters",
        ],
    )
    _unit(
        EXTRACT_MONTH,
        [
            "month", "months", "mon", "mons",
        ],
    )
    _unit(
        EXTRACT_DAY,
        [
            "day", "days", "d", "dayofmonth",
        ],
    )
    _unit(
        EXTRACT_HOUR,
        [
            "hour", "hours", "h", "hr", "hrs",
        ],
    )
    _unit(
        EXTRACT_MINUTE,
        [
            "minute", "minutes", "min", "mins", "m",
        ],
    )
    _unit(
        EXTRACT_SECOND,
        [
            "second", "seconds", "s", "sec", "secs",
        ],
    )
    _unit(
        EXTRACT_DAYOFWEEK,
        [
            "dayofweek", "dow", "weekday",
        ],
    )
    _unit(
        EXTRACT_ISODOW,
        [
            "isodow",
        ],
    )
    _unit(
        EXTRACT_DAYOFYEAR,
        [
            "dayofyear", "doy",
        ],
    )
    _unit(
        EXTRACT_WEEK,
        [
            "week", "weeks", "weekofyear", "w",
        ],
    )
    _unit(
        EXTRACT_ISOYEAR,
        [
            "isoyear",
        ],
    )
    _unit(
        EXTRACT_YEARWEEK,
        [
            "yearweek",
        ],
    )
    _unit(
        EXTRACT_MILLISECOND,
        [
            "millisecond", "milliseconds", "msec", "msecs", "ms", "msecond",
            "mseconds",
        ],
    )
    _unit(
        EXTRACT_MICROSECOND,
        [
            "microsecond", "microseconds", "usec", "usecs", "us", "usecond",
            "useconds",
        ],
    )


def test_specifier_desugars() raises:
    _desugar(
        DSG_CENTURY,
        [
            "century", "centuries", "cent",
        ],
    )
    _desugar(
        DSG_DECADE,
        [
            "decade", "decades", "dec", "decs",
        ],
    )
    _desugar(
        DSG_MILLENNIUM,
        [
            "millennium", "millennia", "mil", "mils",
        ],
    )
    _desugar(
        DSG_ERA,
        [
            "era",
        ],
    )


def test_trunc_periods() raises:
    _trunc(
        EXTRACT_TRUNC_YEAR,
        [
            "year", "years", "yr", "yrs", "y",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_QUARTER,
        [
            "quarter", "quarters",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_MONTH,
        [
            "month", "months", "mon", "mons",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_WEEK,
        [
            "week", "weeks", "w", "weekofyear", "yearweek",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_DAY,
        [
            "day", "days", "d", "dayofmonth", "dayofweek", "dow", "weekday", "isodow",
            "dayofyear", "doy", "julian",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_HOUR,
        [
            "hour", "hours", "h", "hr", "hrs",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_MINUTE,
        [
            "minute", "minutes", "min", "mins", "m",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_SECOND,
        [
            "second", "seconds", "s", "sec", "secs", "epoch",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_MILLISECOND,
        [
            "millisecond", "milliseconds", "msec", "msecs", "ms", "msecond",
            "mseconds",
        ],
    )
    _trunc(
        EXTRACT_TRUNC_MICROSECOND,
        [
            "microsecond", "microseconds", "usec", "usecs", "us", "usecond",
            "useconds",
        ],
    )


def test_names_on_no_row_return_none() raises:
    # Real DuckDB specifiers this engine refuses, a FUNCTION-only name, the
    # PostgreSQL `isoweek`, an upper-case spelling (the parser lower-folds
    # before the lookup) and the empty string.
    var none: List[String] = [
        "epoch", "julian", "timezone", "nanosecond", "isoweek", "YEAR", "",
    ]
    for i in range(len(none)):
        assert_false(sql_date_part_unit(none[i]), none[i])
        assert_false(sql_date_part_desugar(none[i]), none[i])
    var no_period: List[String] = ["decade", "century", "millennium", "isoyear", "YEAR", ""]
    for i in range(len(no_period)):
        assert_false(sql_date_trunc_unit(no_period[i]), no_period[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
