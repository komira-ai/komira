# =============================================================================
# Tests for column_kernels.temporal_parse
# =============================================================================
#
# Every expected value and error text below is DuckDB v1.5's answer for the
# same input (`TRY_CAST(<text> AS DATE)` / `AS TIMESTAMP` for the value, `CAST` for the error), so each case holds one rule of DuckDB's
# grammar: the value, or the outcome class and the exact message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.string_array import StringArray

from column_kernels.temporal_parse import (
    TP_FORMAT,
    TP_INFINITE,
    TP_NON_UTC,
    TP_OK,
    TP_RANGE,
    cast_string_to_date32,
    cast_string_to_timestamp_us,
    parse_date_text,
    parse_timestamp_text,
)


def _date(s: String, status: UInt8, days: Int64) raises:
    var r = parse_date_text(s.as_bytes())
    assert_equal(Int(r.status), Int(status), "DATE status of '" + s + "'")
    assert_equal(r.value, days, "DATE value of '" + s + "'")


def _ts(s: String, status: UInt8, micros: Int64) raises:
    var r = parse_timestamp_text(s.as_bytes())
    assert_equal(Int(r.status), Int(status), "TIMESTAMP status of '" + s + "'")
    assert_equal(r.value, micros, "TIMESTAMP value of '" + s + "'")


def _date_error(s: String) raises -> String:
    var sa = StringArray.from_strings([s])
    try:
        _ = cast_string_to_date32(sa, False)
    except e:
        return String(e)
    return "no error"


def _ts_error(s: String) raises -> String:
    var sa = StringArray.from_strings([s])
    try:
        _ = cast_string_to_timestamp_us(sa, False)
    except e:
        return String(e)
    return "no error"


def test_date_cast_grammar_1() raises:
    """CAST(<text> AS DATE): value or outcome class, case by case."""
    _date(String("2026-09-15"), TP_OK, 20711)
    _date(String(" 2026-9-5 "), TP_OK, 20701)
    _date(String("2026/09/15"), TP_OK, 20711)
    _date(String("2026 09 15"), TP_OK, 20711)
    _date(String("2026\\09\\15"), TP_OK, 20711)
    _date(String("2026-09/15"), TP_FORMAT, 0)
    _date(String("2026-02-30"), TP_RANGE, 0)
    _date(String("2028-02-29"), TP_OK, 21243)
    _date(String("2026-02-29"), TP_RANGE, 0)
    _date(String("2026-09-15 10:11:12"), TP_OK, 20711)
    _date(String("2026-09-15T10:11"), TP_OK, 20711)
    _date(String("15 Sep 2026"), TP_FORMAT, 0)
    _date(String("20260915"), TP_FORMAT, 0)
    _date(String("12026-01-01"), TP_OK, 3672879)
    _date(String("-2044-03-15"), TP_OK, -1466010)


def test_date_cast_grammar_2() raises:
    """CAST(<text> AS DATE): value or outcome class, case by case."""
    _date(String("2044-03-15 (BC)"), TP_OK, -1465645)
    _date(String("2044-03-15 (bc)"), TP_OK, -1465645)
    _date(String("0000-01-01 (BC)"), TP_FORMAT, 0)
    _date(String("-2044-03-15 (BC)"), TP_FORMAT, 0)
    _date(String("epoch"), TP_OK, 0)
    _date(String(" EPOCH "), TP_OK, 0)
    _date(String("-epoch"), TP_OK, 0)
    _date(String("epochx"), TP_FORMAT, 0)
    _date(String("2026-09-15abc"), TP_OK, 20711)
    _date(String("2026-09-150"), TP_FORMAT, 0)
    _date(String(""), TP_FORMAT, 0)
    _date(String("   "), TP_FORMAT, 0)
    _date(String("6-01-01"), TP_OK, -717336)
    _date(String("26-01-01"), TP_OK, -710031)
    _date(String("2026-13-01"), TP_RANGE, 0)


def test_date_cast_grammar_3() raises:
    """CAST(<text> AS DATE): value or outcome class, case by case."""
    _date(String("2026-00-01"), TP_RANGE, 0)
    _date(String("2026-1-001"), TP_FORMAT, 0)
    _date(String("2026-09-15 25:00:00"), TP_OK, 20711)
    _date(String("2026-09-15  "), TP_OK, 20711)
    _date(String("+2026-09-15"), TP_FORMAT, 0)
    _date(String("2026-09-00"), TP_RANGE, 0)
    _date(String("2026-04-31"), TP_RANGE, 0)
    _date(String("2100-02-29"), TP_RANGE, 0)
    _date(String("2400-02-29"), TP_OK, 157113)
    _date(String("\t2026-09-15\n"), TP_OK, 20711)
    _date(String("2026-09"), TP_FORMAT, 0)
    _date(String("2026-09-"), TP_FORMAT, 0)
    _date(String("2026-"), TP_FORMAT, 0)
    _date(String("2026"), TP_FORMAT, 0)
    _date(String("-"), TP_FORMAT, 0)


def test_date_cast_grammar_4() raises:
    """CAST(<text> AS DATE): value or outcome class, case by case."""
    _date(String("x2026-09-15"), TP_FORMAT, 0)
    _date(String("5881580-07-10"), TP_OK, 2147483646)
    _date(String("5881580-07-11"), TP_RANGE, 0)
    _date(String("-5877641-06-25"), TP_OK, -2147483646)
    _date(String("-5877641-06-24"), TP_RANGE, 0)
    _date(String("100000000-01-01"), TP_RANGE, 0)
    _date(String("99999999-01-01"), TP_RANGE, 0)
    _date(String("-2026-09-15"), TP_OK, -1459252)
    _date(String(" -2026-09-15"), TP_OK, -1459252)
    _date(String("2026--09-15"), TP_FORMAT, 0)
    _date(String("2026-09-15 (BC"), TP_OK, 20711)
    _date(String("2026-9-5(BC)"), TP_OK, 20701)
    _date(String("2026-09-15" + chr(11) + ""), TP_OK, 20711)


def test_timestamp_cast_grammar_1() raises:
    """CAST(<text> AS TIMESTAMP): value or outcome class, case by case."""
    _ts(String("2026-09-15"), TP_OK, 1789430400000000)
    _ts(String("2026-09-15 10:11:12"), TP_OK, 1789467072000000)
    _ts(String("2026-09-15T10:11:12.123456"), TP_OK, 1789467072123456)
    _ts(String("2026-09-15 10:11:12.1234567"), TP_OK, 1789467072123456)
    _ts(String("2026-09-15 10:11"), TP_OK, 1789467060000000)
    _ts(String("2026-09-15 10:"), TP_OK, 1789466400000000)
    _ts(String("2026-09-15 10"), TP_FORMAT, 0)
    _ts(String("2026-09-15 "), TP_FORMAT, 0)
    _ts(String("2026-09-15T"), TP_FORMAT, 0)
    _ts(String("2026-09-15 24:00:00"), TP_OK, 1789516800000000)
    _ts(String("2026-09-15 24:00:01"), TP_RANGE, 0)
    _ts(String("2026-09-15 23:59:60"), TP_FORMAT, 0)
    _ts(String("2026-09-15 23:60:00"), TP_FORMAT, 0)
    _ts(String("2026-09-15 1:2:3"), TP_OK, 1789434123000000)
    _ts(String("2026-09-15   10:11:12"), TP_OK, 1789467072000000)


def test_timestamp_cast_grammar_2() raises:
    """CAST(<text> AS TIMESTAMP): value or outcome class, case by case."""
    _ts(String("2026-09-15 10:11:12Z"), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11:12+02"), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11:12+02:30"), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11:12-0530"), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11:12+02:30:15"), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11+02"), TP_FORMAT, 0)
    _ts(String("2026-09-15 10:11:12 UTC"), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11:12 utc"), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11:12 Europe/Berlin"), TP_NON_UTC, 0)
    _ts(String("2026-09-15 10:11:12x"), TP_NON_UTC, 0)
    _ts(String("2026-09-15 10:11:12 "), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11 "), TP_FORMAT, 0)
    _ts(String("2026-09-15 10:11:12."), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11:12.5"), TP_OK, 1789467072500000)
    _ts(String("2026-09-15abc"), TP_FORMAT, 0)


def test_timestamp_cast_grammar_3() raises:
    """CAST(<text> AS TIMESTAMP): value or outcome class, case by case."""
    _ts(String("2026-09-15x10:11"), TP_FORMAT, 0)
    _ts(String("epoch"), TP_OK, 0)
    _ts(String("2026-02-30 10:00"), TP_RANGE, 0)
    _ts(String("2026-09-15 100:00"), TP_RANGE, 0)
    _ts(String("2026-09-15 10:11:12Z "), TP_OK, 1789467072000000)
    _ts(String("2026-09-15 10:11:12Zx"), TP_FORMAT, 0)
    _ts(String("2026-09-15 10:11:12+2"), TP_NON_UTC, 0)
    _ts(String("2026-09-15 10:11:12 +02"), TP_NON_UTC, 0)
    _ts(String("abc"), TP_FORMAT, 0)
    _ts(String(""), TP_FORMAT, 0)
    _ts(String("2044-03-15 (BC) 10:00"), TP_OK, -126631692000000000)
    _ts(String("-2044-03-15 10:00:00"), TP_OK, -126663228000000000)
    _ts(String("2026-09-15 10:11:12.000001"), TP_OK, 1789467072000001)
    _ts(String("-2026-09-15 23:59:59.999999"), TP_OK, -126079286400000001)
    _ts(String("294247-01-10 04:00:54.775806"), TP_OK, 9223372036854775806)


def test_timestamp_cast_grammar_4() raises:
    """CAST(<text> AS TIMESTAMP): value or outcome class, case by case."""
    _ts(String("294247-01-10 04:00:54.775807"), TP_RANGE, 0)
    _ts(String("294248-01-01"), TP_RANGE, 0)
    _ts(String("-290308-12-21 19:59:05.224193"), TP_RANGE, 0)
    _ts(String("-290308-12-21 19:59:05.224192"), TP_RANGE, 0)
    _ts(String("2026-09-15 10:11:12 UTCx"), TP_NON_UTC, 0)
    _ts(String("2026-09-15 10:11:12  UTC"), TP_FORMAT, 0)
    _ts(String("2026-09-15 07:08:09.1 +0000"), TP_NON_UTC, 0)
    _ts(String("2026-09-15 1000000000:00"), TP_FORMAT, 0)
    _ts(String("2026-09-15 999999999:00"), TP_RANGE, 0)
    _ts(String("2026-09-15 10:7"), TP_OK, 1789466820000000)
    _ts(String("2026-09-15 10:07:5"), TP_OK, 1789466825000000)


def test_strict_cast_raises_duckdbs_message() raises:
    """A strict CAST raises DuckDB's exact text for each failure class."""
    assert_equal(_date_error(String("2026-09/15")), String("Conversion Error: invalid date field format: \"2026-09/15\", expected format is (YYYY-MM-DD)"))
    assert_equal(_date_error(String("2026-02-30")), String("Conversion Error: date field value out of range: \"2026-02-30\""))
    assert_equal(_ts_error(String("2026-09-15 10")), String("Conversion Error: invalid timestamp field format: \"2026-09-15 10\", expected format is (YYYY-MM-DD HH:MM:SS[.US][±HH[:MM[:SS]]| ZONE])"))
    assert_equal(_ts_error(String("2026-09-15 24:00:01")), String("Conversion Error: timestamp field value out of range: \"2026-09-15 24:00:01\""))
    assert_equal(_ts_error(String("2026-09-15 10:11:12 Europe/Berlin")), String("Conversion Error: timestamp field value \"2026-09-15 10:11:12 Europe/Berlin\" has a timestamp that is not UTC.\nUse the TIMESTAMPTZ type with the ICU extension loaded to handle non-UTC timestamps."))


def test_infinite_values_are_refused_in_both_modes() raises:
    """DuckDB answers an infinite DATE / TIMESTAMP for `infinity`; an Arrow
    column cannot hold one, so it is refused by name under CAST and TRY_CAST
    alike, never turned into NULL."""
    _date(String("infinity"), TP_INFINITE, 0)
    _date(String(" -INF"), TP_INFINITE, 0)
    # An abbreviation must end the text: DuckDB answers NULL for ' -INF '.
    _date(String(" -INF "), TP_FORMAT, 0)
    _ts(String("infinity"), TP_INFINITE, 0)
    _ts(String("-infinity"), TP_INFINITE, 0)
    _date(String("infin"), TP_FORMAT, 0)
    var sa = StringArray.from_strings([String("2026-09-15"), String("infinity")])
    for mode in range(2):
        var raised = String("")
        try:
            _ = cast_string_to_date32(sa, mode == 1)
        except e:
            raised = String(e)
        assert_equal(
            raised,
            "SQL not supported: the text \"infinity\" parses to an INFINITE"
            " DATE in DuckDB, and an Arrow date column has no infinite value"
            " to hold it. Refused rather than answered with NULL or a finite"
            " stand-in, under TRY as well.",
        )
        var traised = String("")
        try:
            _ = cast_string_to_timestamp_us(sa, mode == 1)
        except e:
            traised = String(e)
        assert_true(traised.startswith("SQL not supported: the text \"infinity\" parses to an INFINITE TIMESTAMP"))


def test_column_null_in_null_out_and_try_nulls_bad_rows() raises:
    """NULL in gives NULL out in both modes; under TRY a row that does not
    parse (bad text, Feb 30) is NULL and the good rows keep their values."""
    var sa = StringArray.from_strings_with_validity(
        [String("2026-09-15"), String(""), String("not a date"), String("2026-02-30"), String("2028-02-29")],
        [True, False, True, True, True],
    )
    var d = cast_string_to_date32(sa, True)
    assert_equal(d.null_count, 3)
    assert_false(d.is_null(0))
    assert_equal(d.get(0), Int32(20711))
    assert_true(d.is_null(1))
    assert_true(d.is_null(2))
    assert_true(d.is_null(3))
    assert_equal(d.get(4), Int32(21243))
    var t = cast_string_to_timestamp_us(sa, True)
    assert_equal(t.null_count, 3)
    assert_equal(t.get(0), Int64(1789430400000000))
    assert_true(t.is_null(1))
    assert_true(t.is_null(3))
    assert_equal(t.get(4), Int64(1835395200000000))
    var only_valid = StringArray.from_strings_with_validity(
        [String("2026-09-15"), String("")], [True, False]
    )
    var strict = cast_string_to_date32(only_valid, False)
    assert_equal(strict.null_count, 1)
    assert_equal(strict.get(0), Int32(20711))
    assert_true(strict.is_null(1))
    var strict_ts = cast_string_to_timestamp_us(only_valid, False)
    assert_equal(strict_ts.null_count, 1)
    assert_true(strict_ts.is_null(1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
