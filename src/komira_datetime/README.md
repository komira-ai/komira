# komira_datetime

Calendar arithmetic and timestamp text, in pure Mojo with no dependencies. It
converts between a day count since 1970-01-01 and a (year, month, day) in the
proleptic Gregorian calendar, between epoch seconds and UTC fields, and reads
and writes ISO 8601 / RFC 3339 timestamps (with offsets and fractions), plain
`YYYY-MM-DD` dates, the compact `YYYYMMDDTHHMMSSZ` form and the HTTP-date. A
date or time that does not exist is refused, never rolled over. It has no
clock, no time zones beyond fixed offsets, and no leap-second table.

## Examples

Days, dates and weekdays:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_datetime import civil_from_days, days_from_civil, format_iso_date, is_leap_year, weekday_from_days

var leap_day = days_from_civil(2024, 2, 29)
assert_equal(leap_day, 19782)
assert_equal(weekday_from_days(leap_day), 4)  # 0 = Sunday, so a Thursday
assert_equal(format_iso_date(leap_day + 1), "2024-03-01")
assert_equal(civil_from_days(leap_day + 366).year, 2025)
assert_true(is_leap_year(2000) and not is_leap_year(1900))
```

Read an RFC 3339 timestamp with an offset, and write it back in UTC:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_datetime import format_rfc3339, parse_rfc3339, seconds_from_fields

var ts = parse_rfc3339("2026-09-15T14:00:00.25+02:00")
assert_equal(ts.seconds, seconds_from_fields(2026, 9, 15, hour=12))
assert_equal(ts.nanos, 250_000_000)
assert_equal(format_rfc3339(ts), "2026-09-15T12:00:00Z")
assert_equal(format_rfc3339(ts, fraction_digits=3), "2026-09-15T12:00:00.250Z")
```

The HTTP-date, both ways:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_datetime import format_http_date, parse_http_date

assert_equal(format_http_date(784111777), "Sun, 06 Nov 1994 08:49:37 GMT")
assert_equal(parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"), 784111777)
```

A date that does not exist is refused:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_datetime import days_from_date

var message = String()
try:
    _ = days_from_date(2023, 2, 29)
except e:
    message = String(e)
assert_equal(message, "day 29 does not exist in month 2 of year 2023")
```
