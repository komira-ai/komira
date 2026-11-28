# =============================================================================
# Tests for column_kernels.strptime_format
# =============================================================================
#
# Every expected value and error text below is DuckDB v1.5's answer for the
# same input (`try_strptime` for the value, `strptime` for the error), so each case holds one rule of DuckDB's
# grammar: the value, or the outcome class and the exact message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.string_array import StringArray

from column_kernels.temporal_parse import TP_FORMAT, TP_INFINITE, TP_OK, TP_RANGE
from column_kernels.strptime_format import (
    StrptimeFormat,
    compile_strptime_format,
    strptime_column,
    strptime_error,
    strptime_parse,
)


def _ok(s: String, fmt: String, micros: Int64) raises:
    """Both modes answer `micros` for `s` under `fmt`."""
    var f = compile_strptime_format(fmt)
    for mode in range(2):
        var o = strptime_parse(f, s.as_bytes(), mode == 1)
        assert_equal(Int(o.status), Int(TP_OK), "status of '" + s + "' / '" + fmt + "'")
        assert_equal(o.value, micros, "value of '" + s + "' / '" + fmt + "'")


def _bad(s: String, fmt: String, message: String) raises:
    """Strict strptime raises exactly `message`; try_strptime answers NULL."""
    var f = compile_strptime_format(fmt)
    var o = strptime_parse(f, s.as_bytes(), False)
    assert_true(o.status != TP_OK, "'" + s + "' / '" + fmt + "' parsed")
    assert_equal(strptime_error(s, f, o), message)
    var sa = StringArray.from_strings([s])
    var col = strptime_column(sa, f, True)
    assert_true(col.is_null(0), "try_strptime of '" + s + "' / '" + fmt + "' is not NULL")
    var raised = String("")
    try:
        _ = strptime_column(sa, f, False)
    except e:
        raised = String(e)
    assert_equal(raised, message)


def _compile_error(fmt: String) raises -> String:
    try:
        _ = compile_strptime_format(fmt)
    except e:
        return String(e)
    return "no error"


def test_strptime_directive_values_1() raises:
    """Directive by directive, the TIMESTAMP DuckDB answers."""
    _ok(String("09/15/2026"), String("%m/%d/%Y"), 1789430400000000)
    _ok(String("9/5/2026"), String("%m/%d/%Y"), 1788566400000000)
    _ok(String("9/5/2026"), String("%-m/%-d/%Y"), 1788566400000000)
    _ok(String("15 Sep 2026"), String("%d %b %Y"), 1789430400000000)
    _ok(String("15 sep 2026"), String("%d %h %Y"), 1789430400000000)
    _ok(String("15 SEPTEMBER 2026"), String("%d %B %Y"), 1789430400000000)
    _ok(String("Tue, 15 Sep 2026"), String("%a, %d %b %Y"), 1789430400000000)
    _ok(String("Tuesday 15 Sep 2026"), String("%A %d %b %Y"), 1789430400000000)
    _ok(String("26-09-15"), String("%y-%m-%d"), 1789430400000000)
    _ok(String("68-09-15"), String("%y-%m-%d"), 3114892800000000)
    _ok(String("69-09-15"), String("%y-%m-%d"), -9331200000000)
    _ok(String("6-09-15"), String("%-y-%m-%d"), 1158278400000000)
    _ok(String("2026-09-15 10:11:12"), String("%Y-%m-%d %H:%M:%S"), 1789467072000000)
    _ok(String("2026-09-15 1:2:3"), String("%Y-%m-%d %-H:%-M:%-S"), 1789434123000000)


def test_strptime_directive_values_2() raises:
    """Directive by directive, the TIMESTAMP DuckDB answers."""
    _ok(String("2026-09-15 12:30 AM"), String("%Y-%m-%d %I:%M %p"), 1789432200000000)
    _ok(String("2026-09-15 12:30 pm"), String("%Y-%m-%d %I:%M %p"), 1789475400000000)
    _ok(String("2026-09-15 01:30 PM"), String("%Y-%m-%d %I:%M %p"), 1789479000000000)
    _ok(String("2026-09-15 11:30 am"), String("%Y-%m-%d %-I:%M %p"), 1789471800000000)
    _ok(String("2026-09-15 00:30 AM"), String("%Y-%m-%d %H:%M %p"), 1789432200000000)
    _ok(String("2026-09-15 10:11:12.5"), String("%Y-%m-%d %H:%M:%S.%f"), 1789467072500000)
    _ok(String("2026-09-15 10:11:12.123456"), String("%Y-%m-%d %H:%M:%S.%f"), 1789467072123456)
    _ok(String("2026-09-15 10:11:12.12"), String("%Y-%m-%d %H:%M:%S.%g"), 1789467072120000)
    _ok(String("2026-258"), String("%Y-%j"), 1789430400000000)
    _ok(String("2026-1"), String("%Y-%-j"), 1767225600000000)
    _ok(String("2026-365"), String("%Y-%j"), 1798675200000000)
    _ok(String("2026-366"), String("%Y-%j"), 1798761600000000)
    _ok(String("2028-366"), String("%Y-%j"), 1861833600000000)
    _ok(String("100 2026"), String("%j %Y"), 1775779200000000)


def test_strptime_directive_values_3() raises:
    """Directive by directive, the TIMESTAMP DuckDB answers."""
    _ok(String("2026-09 100"), String("%Y-%m %j"), 1788220800000000)
    _ok(String("2026-09-15 10:11:12"), String("%c"), 1789467072000000)
    _ok(String("2026-09-15"), String("%x"), 1789430400000000)
    _ok(String("10:11:12"), String("%X"), -2208952128000000)
    _ok(String("10:11:12"), String("%T"), -2208952128000000)
    _ok(String("2026-09-15T10:11:12"), String("%xT%X"), 1789467072000000)
    _ok(String("100%"), String("%j%%"), -2200435200000000)
    _ok(String("  2026-09-15  "), String("%Y-%m-%d"), 1789430400000000)
    _ok(String("2026  09-15"), String("%Y %m-%d"), 1789430400000000)
    _ok(String("2026"), String("%Y"), 1767225600000000)
    _ok(String("26"), String("%Y"), -61346678400000000)
    _ok(String("6"), String("%Y"), -61977830400000000)
    _ok(String("0000-01-01"), String("%Y-%m-%d"), -62167219200000000)
    _ok(String("abc"), String("abc"), -2208988800000000)


def test_strptime_directive_values_4() raises:
    """Directive by directive, the TIMESTAMP DuckDB answers."""
    _ok(String("2026-9-5"), String("%Y-%m-%d"), 1788566400000000)
    _ok(String("Sep"), String("%b"), -2187993600000000)
    _ok(String("09/15/2026 14:05"), String("%m/%d/%Y %H:%M"), 1789481100000000)
    _ok(String("15.09.2026"), String("%d.%m.%Y"), 1789430400000000)
    _ok(String("2026\t09"), String("%Y %m"), 1788220800000000)
    _ok(String("2026 "), String("%Y"), 1767225600000000)
    _ok(String("Sep 2026"), String("%b %Y"), 1788220800000000)
    _ok(String("2026 PM"), String("%Y %p"), 1767268800000000)
    _ok(String("02 PM"), String("%I %p"), -2208938400000000)
    _ok(String("12 PM 2026"), String("%I %p %Y"), 1767268800000000)
    _ok(String("1:02:03.000001"), String("%H:%M:%S.%f"), -2208985076999999)


def test_strptime_mismatch_errors_1() raises:
    """Each way a text fails to match: DuckDB's message under strptime, NULL
    under try_strptime."""
    _bad(String("15 September 2026"), String("%d %b %Y"), String("Invalid Input Error: Could not parse string \"15 September 2026\" according to format specifier \"%d %b %Y\"\n15 September 2026\n      ^\nError: Space does not match, expected  "))
    _bad(String("Xyz 15 Sep 2026"), String("%a %d %b %Y"), String("Invalid Input Error: Could not parse string \"Xyz 15 Sep 2026\" according to format specifier \"%a %d %b %Y\"\nXyz 15 Sep 2026\n^\nError: Expected an abbreviated day name (Mon, Tue, Wed, Thu, Fri, Sat, Sun)"))
    _bad(String("Tue 15 Sep 2026"), String("%A %d %b %Y"), String("Invalid Input Error: Could not parse string \"Tue 15 Sep 2026\" according to format specifier \"%A %d %b %Y\"\nTue 15 Sep 2026\n^\nError: Expected a full day name (Monday, Tuesday, etc...)"))
    _bad(String("15 Sept 2026"), String("%d %b %Y"), String("Invalid Input Error: Could not parse string \"15 Sept 2026\" according to format specifier \"%d %b %Y\"\n15 Sept 2026\n      ^\nError: Space does not match, expected  "))
    _bad(String("15 Foo 2026"), String("%d %B %Y"), String("Invalid Input Error: Could not parse string \"15 Foo 2026\" according to format specifier \"%d %B %Y\"\n15 Foo 2026\n   ^\nError: Expected a full month name (January, February, etc...)"))
    _bad(String("2026-09-15 24:00:00"), String("%Y-%m-%d %H:%M:%S"), String("Invalid Input Error: Could not parse string \"2026-09-15 24:00:00\" according to format specifier \"%Y-%m-%d %H:%M:%S\"\n2026-09-15 24:00:00\n           ^\nError: Hour out of range, expected a value between 0 and 23"))
    _bad(String("2026-09-15 10:60:00"), String("%Y-%m-%d %H:%M:%S"), String("Invalid Input Error: Could not parse string \"2026-09-15 10:60:00\" according to format specifier \"%Y-%m-%d %H:%M:%S\"\n2026-09-15 10:60:00\n              ^\nError: Minutes out of range, expected a value between 0 and 59"))
    _bad(String("2026-09-15 10:11:60"), String("%Y-%m-%d %H:%M:%S"), String("Invalid Input Error: Could not parse string \"2026-09-15 10:11:60\" according to format specifier \"%Y-%m-%d %H:%M:%S\"\n2026-09-15 10:11:60\n                 ^\nError: Seconds out of range, expected a value between 0 and 59"))
    _bad(String("2026-09-15 13:30 PM"), String("%Y-%m-%d %H:%M %p"), String("Invalid Input Error: Could not parse string \"2026-09-15 13:30 PM\" according to format specifier \"%Y-%m-%d %H:%M %p\"\n\nError: Invalid hour: 13 AM/PM, expected an hour within the range [0..12]"))
    _bad(String("2026-09-15 00:30"), String("%Y-%m-%d %I:%M"), String("Invalid Input Error: Could not parse string \"2026-09-15 00:30\" according to format specifier \"%Y-%m-%d %I:%M\"\n2026-09-15 00:30\n           ^\nError: Hour12 out of range, expected a value between 1 and 12"))
    _bad(String("2026-09-15 13:30"), String("%Y-%m-%d %I:%M"), String("Invalid Input Error: Could not parse string \"2026-09-15 13:30\" according to format specifier \"%Y-%m-%d %I:%M\"\n2026-09-15 13:30\n           ^\nError: Hour12 out of range, expected a value between 1 and 12"))
    _bad(String("2026-09-15 10:30 XM"), String("%Y-%m-%d %I:%M %p"), String("Invalid Input Error: Could not parse string \"2026-09-15 10:30 XM\" according to format specifier \"%Y-%m-%d %I:%M %p\"\n2026-09-15 10:30 XM\n                 ^\nError: Expected AM/PM"))


def test_strptime_mismatch_errors_2() raises:
    """Each way a text fails to match: DuckDB's message under strptime, NULL
    under try_strptime."""
    _bad(String("2026-09-15 10:30 Ax"), String("%Y-%m-%d %I:%M %p"), String("Invalid Input Error: Could not parse string \"2026-09-15 10:30 Ax\" according to format specifier \"%Y-%m-%d %I:%M %p\"\n2026-09-15 10:30 Ax\n                 ^\nError: Expected AM/PM"))
    _bad(String("2026-09-15 10:30 A"), String("%Y-%m-%d %I:%M %p"), String("Invalid Input Error: Could not parse string \"2026-09-15 10:30 A\" according to format specifier \"%Y-%m-%d %I:%M %p\"\n2026-09-15 10:30 A\n                 ^\nError: Expected AM/PM"))
    _bad(String("2026-09-15 10:11:12.1234567"), String("%Y-%m-%d %H:%M:%S.%f"), String("Invalid Input Error: Could not parse string \"2026-09-15 10:11:12.1234567\" according to format specifier \"%Y-%m-%d %H:%M:%S.%f\"\n2026-09-15 10:11:12.1234567\n                          ^\nError: Full specifier did not match: trailing characters"))
    _bad(String("2026-09-15 10:11:12.1234"), String("%Y-%m-%d %H:%M:%S.%g"), String("Invalid Input Error: Could not parse string \"2026-09-15 10:11:12.1234\" according to format specifier \"%Y-%m-%d %H:%M:%S.%g\"\n2026-09-15 10:11:12.1234\n                       ^\nError: Full specifier did not match: trailing characters"))
    _bad(String("2026-367"), String("%Y-%j"), String("Invalid Input Error: Could not parse string \"2026-367\" according to format specifier \"%Y-%j\"\n2026-367\n     ^\nError: Year day out of range, expected a value between 1 and 366"))
    _bad(String("2026-000"), String("%Y-%j"), String("Invalid Input Error: Could not parse string \"2026-000\" according to format specifier \"%Y-%j\"\n2026-000\n     ^\nError: Year day out of range, expected a value between 1 and 366"))
    _bad(String("100 200"), String("%j %j"), String("Invalid Input Error: Could not parse string \"100 200\" according to format specifier \"%j %j\"\n100 200\n    ^\nError: Multiple year offsets specified"))
    _bad(String("100%x"), String("%j%%"), String("Invalid Input Error: Could not parse string \"100%x\" according to format specifier \"%j%%\"\n100%x\n    ^\nError: Full specifier did not match: trailing characters"))
    _bad(String("2026-09-15"), String("%Y %m-%d"), String("Invalid Input Error: Could not parse string \"2026-09-15\" according to format specifier \"%Y %m-%d\"\n2026-09-15\n    ^\nError: Space does not match, expected  "))
    _bad(String("2026x09-15"), String("%Y-%m-%d"), String("Invalid Input Error: Could not parse string \"2026x09-15\" according to format specifier \"%Y-%m-%d\"\n2026x09-15\n     ^\nError: Literal does not match, expected -"))
    _bad(String("2026-09-15x"), String("%Y-%m-%d"), String("Invalid Input Error: Could not parse string \"2026-09-15x\" according to format specifier \"%Y-%m-%d\"\n2026-09-15x\n          ^\nError: Full specifier did not match: trailing characters"))
    _bad(String("2026-09"), String("%Y-%m-%d"), String("Invalid Input Error: Could not parse string \"2026-09\" according to format specifier \"%Y-%m-%d\"\n2026-09\n        ^\nError: Literal does not match, expected -"))


def test_strptime_mismatch_errors_3() raises:
    """Each way a text fails to match: DuckDB's message under strptime, NULL
    under try_strptime."""
    _bad(String(""), String("%Y"), String("Invalid Input Error: Could not parse string \"\" according to format specifier \"%Y\"\n\n^\nError: Expected a number"))
    _bad(String("   "), String("%Y"), String("Invalid Input Error: Could not parse string \"   \" according to format specifier \"%Y\"\n   \n^\nError: Expected a number"))
    _bad(String("epochs"), String("%Y"), String("Invalid Input Error: Could not parse string \"epochs\" according to format specifier \"%Y\"\nepochs\n     ^\nError: Special timestamp did not match: trailing characters"))
    _bad(String("20261"), String("%Y"), String("Invalid Input Error: Could not parse string \"20261\" according to format specifier \"%Y\"\n20261\n    ^\nError: Full specifier did not match: trailing characters"))
    _bad(String("2026-02-30"), String("%Y-%m-%d"), String("Conversion Error: Date out of range: 2026-2-30"))
    _bad(String("2026-02-29"), String("%Y-%m-%d"), String("Conversion Error: Date out of range: 2026-2-29"))
    _bad(String("2026-13-01"), String("%Y-%m-%d"), String("Invalid Input Error: Could not parse string \"2026-13-01\" according to format specifier \"%Y-%m-%d\"\n2026-13-01\n     ^\nError: Month out of range, expected a value between 1 and 12"))
    _bad(String("2026-00-01"), String("%Y-%m-%d"), String("Invalid Input Error: Could not parse string \"2026-00-01\" according to format specifier \"%Y-%m-%d\"\n2026-00-01\n     ^\nError: Month out of range, expected a value between 1 and 12"))
    _bad(String("2026-01-32"), String("%Y-%m-%d"), String("Invalid Input Error: Could not parse string \"2026-01-32\" according to format specifier \"%Y-%m-%d\"\n2026-01-32\n        ^\nError: Day out of range, expected a value between 1 and 31"))
    _bad(String("2026-01-00"), String("%Y-%m-%d"), String("Invalid Input Error: Could not parse string \"2026-01-00\" according to format specifier \"%Y-%m-%d\"\n2026-01-00\n        ^\nError: Day out of range, expected a value between 1 and 31"))
    _bad(String("abd"), String("abc"), String("Invalid Input Error: Could not parse string \"abd\" according to format specifier \"abc\"\nabd\n   ^\nError: Literal does not match, expected abc"))
    _bad(String("ab"), String("abc"), String("Invalid Input Error: Could not parse string \"ab\" according to format specifier \"abc\"\nab\n   ^\nError: Literal does not match, expected abc"))


def test_strptime_mismatch_errors_4() raises:
    """Each way a text fails to match: DuckDB's message under strptime, NULL
    under try_strptime."""
    _bad(String("2026"), String("%Y abc"), String("Invalid Input Error: Could not parse string \"2026\" according to format specifier \"%Y abc\"\n2026\n    ^\nError: Space does not match, expected  abc"))
    _bad(String("2026-123"), String("%Y-%m"), String("Invalid Input Error: Could not parse string \"2026-123\" according to format specifier \"%Y-%m\"\n2026-123\n       ^\nError: Full specifier did not match: trailing characters"))
    _bad(String("2026"), String("%Y "), String("Invalid Input Error: Could not parse string \"2026\" according to format specifier \"%Y \"\n2026\n    ^\nError: Space does not match, expected  "))
    _bad(String("2026-09-15 10"), String("%Y-%m-%d %H:%M"), String("Invalid Input Error: Could not parse string \"2026-09-15 10\" according to format specifier \"%Y-%m-%d %H:%M\"\n2026-09-15 10\n              ^\nError: Literal does not match, expected :"))


def test_specials_differ_between_strict_and_try() raises:
    """DuckDB's own split: strict strptime reads `epoch` as the Unix epoch and
    `infinity` as an infinite timestamp (refused here by name: an Arrow
    column cannot hold it); try_strptime answers the format's default
    fields (year 1900, January, day 1, midnight) for both."""
    var f = compile_strptime_format("%Y")
    var strict_epoch = strptime_parse(f, String("  epoch  ").as_bytes(), False)
    assert_equal(Int(strict_epoch.status), Int(TP_OK))
    assert_equal(strict_epoch.value, Int64(0))
    var try_epoch = strptime_parse(f, String("epoch").as_bytes(), True)
    assert_equal(try_epoch.value, Int64(-2208988800000000))
    var try_inf = strptime_parse(f, String("infinity").as_bytes(), True)
    assert_equal(Int(try_inf.status), Int(TP_OK))
    assert_equal(try_inf.value, Int64(-2208988800000000))
    var strict_inf = strptime_parse(f, String("-infinity").as_bytes(), False)
    assert_equal(Int(strict_inf.status), Int(TP_INFINITE))
    assert_equal(
        strptime_error("-infinity", f, strict_inf),
        "SQL not supported: strptime of \"-infinity\" is an INFINITE TIMESTAMP"
        " in DuckDB, and an Arrow timestamp column has no infinite value to"
        " hold it.",
    )
    var sa = StringArray.from_strings([String("infinity")])
    var raised = String("")
    try:
        _ = strptime_column(sa, f, False)
    except e:
        raised = String(e)
    assert_true(raised.startswith("SQL not supported: strptime of \"infinity\""))
    # `-inf ` is not a special (the prefix must end the text), so it is
    # matched against the format and fails there.
    var not_special = strptime_parse(f, String("-inf ").as_bytes(), False)
    assert_equal(Int(not_special.status), Int(TP_FORMAT))


def test_format_errors_and_refused_directives() raises:
    """DuckDB's own errors for a malformed format, and every directive this
    engine does not serve refused by its name."""
    assert_equal(
        _compile_error(""),
        "Invalid Input Error: Failed to parse format specifier : Empty format string",
    )
    assert_equal(
        _compile_error("%"),
        "Invalid Input Error: Failed to parse format specifier %: Trailing format character %",
    )
    assert_equal(
        _compile_error("%q"),
        "Invalid Input Error: Failed to parse format specifier %q: Unrecognized"
        " format for strftime/strptime: %q",
    )
    assert_equal(
        _compile_error("%-q"),
        "Invalid Input Error: Failed to parse format specifier %-q: Unrecognized"
        " format for strftime/strptime: %-q",
    )
    assert_equal(
        _compile_error("%Y%-"),
        "Invalid Input Error: Failed to parse format specifier %Y%-: Unrecognized"
        " format for strftime/strptime: %-",
    )
    assert_equal(
        _compile_error("%Y %z"),
        "SQL not supported: the strptime directive %z. DuckDB's strptime returns"
        " TIMESTAMP WITH TIME ZONE when the format holds %z or %Z, and the"
        " instant that names depends on a session time zone this engine does"
        " not have. Parse the text without its zone.",
    )
    assert_true(_compile_error("%Z").startswith("SQL not supported: the strptime directive %Z."))
    assert_equal(
        _compile_error("%S.%n"),
        "SQL not supported: the strptime directive %n. DuckDB's strptime returns"
        " TIMESTAMP_NS (nanoseconds) when the format holds %n, and this"
        " engine's strptime returns TIMESTAMP (microseconds). %f reads up to"
        " six fraction digits.",
    )
    var weeks: List[String] = ["%G", "%V", "%u", "%U", "%W", "%w"]
    for w in weeks:
        assert_equal(
            _compile_error(w),
            "SQL not supported: the strptime directive " + w + ". It is one of"
            " the week-based directives (%G %V %u %U %W %w), which DuckDB turns"
            " into a date through ISO and Sunday- or Monday-first week rules"
            " that this engine does not reproduce. Use %Y with %m and %d, or %j.",
        )


def test_compiled_shape() raises:
    """A format compiles to literal / directive pairs; `%%` is a literal `%`
    and `%c` expands to its ISO shape with the text before it kept."""
    var f = compile_strptime_format("at %c%%")
    assert_equal(len(f.specs), 6)
    assert_equal(len(f.literals), 7)
    assert_equal(f.literals[0], "at ")
    assert_equal(f.literals[3], " ")
    assert_equal(f.literals[6], "%")
    assert_equal(f.text, "at %c%%")


def test_column_null_in_null_out() raises:
    """NULL in gives NULL out in both modes, and the other rows keep their
    values."""
    var f = compile_strptime_format("%m/%d/%Y")
    var sa = StringArray.from_strings_with_validity(
        [String("09/15/2026"), String(""), String("13/01/2026")], [True, False, True]
    )
    var t = strptime_column(sa, f, True)
    assert_equal(t.null_count, 2)
    assert_equal(t.get(0), Int64(1789430400000000))
    assert_true(t.is_null(1))
    assert_true(t.is_null(2))
    var good = StringArray.from_strings_with_validity(
        [String("09/15/2026"), String("")], [True, False]
    )
    var s = strptime_column(good, f, False)
    assert_equal(s.null_count, 1)
    assert_equal(s.get(0), Int64(1789430400000000))
    assert_true(s.is_null(1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
