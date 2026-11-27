# =============================================================================
# The DATEFORMAT and TIMESTAMPFORMAT of a COPY write what DuckDB writes
# =============================================================================
#
# Covers: `csv_temporal_format.TemporalFormat` parses a format as DuckDB's
# COPY does and writes dates and microsecond timestamps with it; every
# expected text below is what DuckDB's COPY ... TO (DATEFORMAT ...) or
# (TIMESTAMPFORMAT ...) wrote for the same value, in a session whose time zone
# is UTC.
#
# What each test proves:
#   * test_every_date_specifier: one format holding every specifier DuckDB
#     knows (padded and unpadded numbers, names, weekdays, the three week
#     numbers, the ISO year, %z %Z, %c %x %X %T, %%, %f %g), over eighteen
#     dates: years 5, 999, 1, 1 BC (year 0), 2 BC, 101 BC, 12345, the epoch
#     and the day before it, and days that put the ISO week and year in the
#     year before or after (2005-01-01, 2008-12-29, 2010-01-03, 2021-01-03),
#     leap years' last days. Catches a year padded or signed otherwise than
#     DuckDB (`-1`, `0000`, `12345`), %y of a BC year, a weekday off by one,
#     a week counted from the wrong day, the ISO week of a year's edge, the
#     ISO year of a BC year (DuckDB writes `7295` for -1), and a compound
#     specifier expanded otherwise.
#   * test_timestamp_specifiers: the time of day in 24- and 12-hour form
#     (midnight and noon as 12), AM and PM, the microseconds and
#     milliseconds, a time before 1970 (the day before at 23:59:59.999999),
#     44 BC, DuckDB's largest and smallest timestamps, and `UTC` for %Z only
#     on a zoned timestamp; infinity and -infinity whatever the format.
#     Catches a time of day taken by truncating toward zero, an hour 0
#     written as 0 on the 12-hour clock, and %Z written on a naive value.
#   * test_literal_text: text around the specifiers, a multi-byte character
#     and a format with no specifier are written as they are.
#   * test_refused_formats: an empty format, a trailing `%`, `%%%`, an
#     unknown letter, `%-` with nothing or with a letter that has no unpadded
#     form, `%-%`, an unknown multi-byte specifier (named whole), each with
#     DuckDB's own reason by exact message; `%n` is refused by name.
#     Catches a format DuckDB refuses written anyway, and an error that
#     names another specifier than the one written.

from std.testing import TestSuite, assert_equal, assert_true

from csv.csv_temporal_format import TemporalFormat

comptime _ALL = (
    "%Y|%y|%-y|%m|%-m|%d|%-d|%j|%-j|%a|%A|%b|%h|%B|%w|%u|%U|%W|%V|%G|%H|%I|"
    "%p|%z|%Z|%c|%x|%X|%T|%%|%f|%g"
)


def _date(fmt: TemporalFormat, days: Int, want: String) raises:
    assert_equal(fmt.date_text(days), want, "day " + String(days))


def test_every_date_specifier() raises:
    var f = TemporalFormat("DATEFORMAT", _ALL)
    assert_equal(f.text, String(_ALL))
    var t = "|00|12|AM|+00||"
    var z = " 00:00:00"
    var tail = "|00:00:00|00:00:00|%|000000|000"
    _date(f, 12849, "2005|05|5|03|3|07|7|066|66|Mon|Monday|Mar|Mar|March|1|1|10|10|10|2005" + t + "2005-03-07" + z + "|2005-03-07" + tail)
    _date(f, -717701, "0005|05|5|01|1|01|1|001|1|Sat|Saturday|Jan|Jan|January|6|6|00|00|53|0004" + t + "0005-01-01" + z + "|0005-01-01" + tail)
    _date(f, -354286, "0999|99|99|12|12|31|31|365|365|Tue|Tuesday|Dec|Dec|December|2|2|52|52|01|1000" + t + "0999-12-31" + z + "|0999-12-31" + tail)
    _date(f, -719162, "0001|01|1|01|1|01|1|001|1|Mon|Monday|Jan|Jan|January|1|1|00|01|01|0001" + t + "0001-01-01" + z + "|0001-01-01" + tail)
    _date(f, -719163, "0000|00|0|12|12|31|31|366|366|Sun|Sunday|Dec|Dec|December|0|7|53|52|52|0000" + t + "0000-12-31" + z + "|0000-12-31" + tail)
    _date(f, -719742, "-1|01|1|06|6|01|1|152|152|Tue|Tuesday|Jun|Jun|June|2|2|22|22|22|7295" + t + "-1-06-01" + z + "|-1-06-01" + tail)
    _date(f, -756052, "-100|00|0|01|1|01|1|001|1|Mon|Monday|Jan|Jan|January|1|1|00|01|01|7196" + t + "-100-01-01" + z + "|-100-01-01" + tail)
    _date(f, 12418, "2004|04|4|01|1|01|1|001|1|Thu|Thursday|Jan|Jan|January|4|4|00|00|01|2004" + t + "2004-01-01" + z + "|2004-01-01" + tail)
    _date(f, 12784, "2005|05|5|01|1|01|1|001|1|Sat|Saturday|Jan|Jan|January|6|6|00|00|53|2004" + t + "2005-01-01" + z + "|2005-01-01" + tail)
    _date(f, 12785, "2005|05|5|01|1|02|2|002|2|Sun|Sunday|Jan|Jan|January|0|7|01|00|53|2004" + t + "2005-01-02" + z + "|2005-01-02" + tail)
    _date(f, 14242, "2008|08|8|12|12|29|29|364|364|Mon|Monday|Dec|Dec|December|1|1|52|52|01|2009" + t + "2008-12-29" + z + "|2008-12-29" + tail)
    _date(f, 14612, "2010|10|10|01|1|03|3|003|3|Sun|Sunday|Jan|Jan|January|0|7|01|00|53|2009" + t + "2010-01-03" + z + "|2010-01-03" + tail)
    _date(f, 18627, "2020|20|20|12|12|31|31|366|366|Thu|Thursday|Dec|Dec|December|4|4|52|52|53|2020" + t + "2020-12-31" + z + "|2020-12-31" + tail)
    _date(f, 0, "1970|70|70|01|1|01|1|001|1|Thu|Thursday|Jan|Jan|January|4|4|00|00|01|1970" + t + "1970-01-01" + z + "|1970-01-01" + tail)
    _date(f, -1, "1969|69|69|12|12|31|31|365|365|Wed|Wednesday|Dec|Dec|December|3|3|52|52|01|1970" + t + "1969-12-31" + z + "|1969-12-31" + tail)
    _date(f, 3789575, "12345|45|45|07|7|04|4|185|185|Wed|Wednesday|Jul|Jul|July|3|3|26|27|27|2345" + t + "12345-07-04" + z + "|12345-07-04" + tail)
    _date(f, 18630, "2021|21|21|01|1|03|3|003|3|Sun|Sunday|Jan|Jan|January|0|7|01|00|53|2020" + t + "2021-01-03" + z + "|2021-01-03" + tail)
    _date(f, 20784, "2026|26|26|11|11|27|27|331|331|Fri|Friday|Nov|Nov|November|5|5|47|47|48|2026" + t + "2026-11-27" + z + "|2026-11-27" + tail)


def both(f: TemporalFormat, micros: Int64, naive: String, rest: String) raises:
    """`micros` naive (no %Z text) and zoned (`UTC`)."""
    assert_equal(f.timestamp_text(micros, False), naive + "||" + rest)
    assert_equal(f.timestamp_text(micros, True), naive + "|UTC|" + rest)


def test_timestamp_specifiers() raises:
    var f = TemporalFormat(
        "TIMESTAMPFORMAT", "%Y-%m-%d %H:%M:%S.%f|%-H|%I|%-I|%p|%-M|%-S|%g|%z|%Z|%c"
    )

    both(f, 1110200645123456, "2005-03-07 13:04:05.123456|13|01|1|PM|4|5|123|+00", "2005-03-07 13:04:05")
    both(f, 1110153600000000, "2005-03-07 00:00:00.000000|0|12|12|AM|0|0|000|+00", "2005-03-07 00:00:00")
    both(f, 1110196800000001, "2005-03-07 12:00:00.000001|12|12|12|PM|0|0|000|+00", "2005-03-07 12:00:00")
    both(f, 1110196799999000, "2005-03-07 11:59:59.999000|11|11|11|AM|59|59|999|+00", "2005-03-07 11:59:59")
    both(f, -1, "1969-12-31 23:59:59.999999|23|11|11|PM|59|59|999|+00", "1969-12-31 23:59:59")
    both(f, -63517780800000000, "-43-03-15 12:00:00.000000|12|12|12|PM|0|0|000|+00", "-43-03-15 12:00:00")
    both(f, 9223372036854775806, "294247-01-10 04:00:54.775806|4|04|4|AM|0|54|775|+00", "294247-01-10 04:00:54")
    both(f, -9223372022400000000, "-290308-12-22 00:00:00.000000|0|12|12|AM|0|0|000|+00", "-290308-12-22 00:00:00")
    assert_equal(f.timestamp_text(Int64.MAX, False), "infinity")
    assert_equal(f.timestamp_text(-Int64.MAX, False), "-infinity")
    assert_equal(f.timestamp_text(Int64.MAX, True), "infinity")
    assert_equal(f.timestamp_text(-Int64.MAX, True), "-infinity")


def test_literal_text() raises:
    var f = TemporalFormat("DATEFORMAT", "é %Y€ day %d,%m")
    assert_equal(f.date_text(12849), "é 2005€ day 07,03")
    assert_equal(TemporalFormat("DATEFORMAT", "abc").date_text(12849), "abc")
    assert_equal(TemporalFormat("DATEFORMAT", "a%%").date_text(12849), "a%")
    assert_equal(
        TemporalFormat("TIMESTAMPFORMAT", "%d/%m/%Y %H:%M").timestamp_text(
            1110200645123456, False
        ),
        "07/03/2005 13:04",
    )


def _refused(option: String, text: String, want: String) raises:
    try:
        _ = TemporalFormat(option, text)
    except e:
        assert_equal(String(e), want)
        return
    assert_true(False, "not refused: " + text)


def test_refused_formats() raises:
    var head = "CSV_DIALECT_INVALID: COPY ... (DATEFORMAT '"
    _refused("DATEFORMAT", "", head + "'): Failed to parse format specifier : Empty format string")
    _refused("DATEFORMAT", "%", head + "%'): Failed to parse format specifier %: Trailing format character %")
    _refused("DATEFORMAT", "%%%", head + "%%%'): Failed to parse format specifier %%%: Trailing format character %")
    _refused(
        "DATEFORMAT", "%d %Q",
        head + "%d %Q'): Failed to parse format specifier %d %Q: Unrecognized format for strftime/strptime: %Q",
    )
    _refused(
        "DATEFORMAT", "%e",
        head + "%e'): Failed to parse format specifier %e: Unrecognized format for strftime/strptime: %e",
    )
    _refused(
        "DATEFORMAT", "%-",
        head + "%-'): Failed to parse format specifier %-: Unrecognized format for strftime/strptime: %-",
    )
    _refused(
        "DATEFORMAT", "%-Y",
        head + "%-Y'): Failed to parse format specifier %-Y: Unrecognized format for strftime/strptime: %-Y",
    )
    _refused(
        "DATEFORMAT", "%-a",
        head + "%-a'): Failed to parse format specifier %-a: Unrecognized format for strftime/strptime: %-a",
    )
    _refused(
        "DATEFORMAT", "%-Q",
        head + "%-Q'): Failed to parse format specifier %-Q: Unrecognized format for strftime/strptime: %-Q",
    )
    _refused(
        "DATEFORMAT", "%-%",
        head + "%-%'): Failed to parse format specifier %-%: Unrecognized format for strftime/strptime: %-%",
    )
    _refused(
        "DATEFORMAT", "%éx",
        head + "%éx'): Failed to parse format specifier %éx: Unrecognized format for strftime/strptime: %é",
    )
    _refused(
        "TIMESTAMPFORMAT", "it's %Q",
        "CSV_DIALECT_INVALID: COPY ... (TIMESTAMPFORMAT 'it''s %Q'): Failed to parse format specifier it's %Q: Unrecognized format for strftime/strptime: %Q",
    )
    _refused(
        "TIMESTAMPFORMAT", "%S.%n",
        "CSV_DIALECT_UNSUPPORTED: COPY ... (TIMESTAMPFORMAT '%S.%n'): %n, which DuckDB's COPY writes padded with spaces beside another specifier; write %f for the microseconds",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
