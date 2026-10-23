# komira_datetime

Calendar arithmetic, timestamp text and IANA time zones, in pure Mojo with no
dependencies. It converts between a day count since the Unix epoch (day 0)
and a (year, month, day) in the proleptic Gregorian calendar, between epoch
seconds and UTC fields, and reads and writes ISO 8601 / RFC 3339 timestamps
(with offsets and fractions), plain `YYYY-MM-DD` dates, the compact
`YYYYMMDDTHHMMSSZ` form and the HTTP-date. A date or time that does not exist
is refused, never rolled over. It has no clock and no leap-second table.

Its time zones are the IANA ones. It reads TZif files (versions 1 to 3 of RFC
8536, and version 4 of RFC 9636, which obsoletes it) into a `Zone`, evaluates
the POSIX TZ string of their footer for instants past the last listed
transition, converts a UTC instant to local time, and converts a local time
to UTC, where a local time the clock skipped (a gap) or showed twice (a fold)
is settled by a policy the caller must name. It bundles no zone data: a
caller passes TZif bytes (`parse_tzif`) or names a zoneinfo directory, as zic
writes it (`load_zone`). komira's conformance tests read the tz release
pinned in `third_party/tzdata`. Instants are POSIX epoch seconds: leap seconds
are not modelled, and a zone with leap-second records is refused.

## Examples

Days, dates and weekdays:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_datetime import civil_from_days, days_from_civil, format_iso_date, is_leap_year, weekday_from_days

var leap_day = days_from_civil(2028, 2, 29)
assert_equal(leap_day, 21243)
assert_equal(weekday_from_days(leap_day), 2)  # 0 = Sunday, so a Tuesday
assert_equal(format_iso_date(leap_day + 1), "2028-03-01")
assert_equal(civil_from_days(leap_day + 366).year, 2029)
assert_true(is_leap_year(2400) and not is_leap_year(2100))
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

assert_equal(format_http_date(1793954977), "Fri, 06 Nov 2026 08:49:37 GMT")
assert_equal(parse_http_date("Fri, 06 Nov 2026 08:49:37 GMT"), 1793954977)
```

A date that does not exist is refused:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_datetime import days_from_date

var message = String()
try:
    _ = days_from_date(2027, 2, 29)
except e:
    message = String(e)
assert_equal(message, "day 29 does not exist in month 2 of year 2027")
```

A zone from a POSIX TZ string, and the offset at an instant:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_datetime import posix_zone, seconds_from_fields

var ny = posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0")
var summer = ny.offset_at(seconds_from_fields(2030, 7, 4, 16))
assert_equal(summer.utc_offset, -14400)
assert_equal(summer.abbreviation, "EDT")
assert_true(summer.is_dst)
assert_equal(ny.local_fields(seconds_from_fields(2030, 7, 4, 16)).hour, 12)
```

Local time to UTC. On 10 March 2030 New York's clocks skip from 02:00 to
03:00, and on 3 November they show 01:00 to 02:00 twice:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_datetime import FoldPolicy, GapPolicy, LocalKind, local_seconds, posix_zone, seconds_from_fields

var ny = posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0")
var skipped = local_seconds(2030, 3, 10, 2, 30)
assert_true(ny.resolve(skipped).kind == LocalKind.GAP)
# SHIFT_FORWARD reads 02:30 in the offset before the gap: 03:30 EDT.
assert_equal(
    ny.to_utc(skipped, GapPolicy.SHIFT_FORWARD, FoldPolicy.EARLIER),
    seconds_from_fields(2030, 3, 10, 7, 30),
)
var twice = local_seconds(2030, 11, 3, 1, 30)
assert_equal(
    ny.to_utc(twice, GapPolicy.SHIFT_FORWARD, FoldPolicy.LATER),
    seconds_from_fields(2030, 11, 3, 6, 30),
)
```

## The policies

| local time | policy | instant |
|---|---|---|
| in a gap | `GapPolicy.SHIFT_FORWARD` | read in the offset before the gap, so the wall time moves forward by the gap's length (RFC 5545 section 3.3.5) |
| in a gap | `GapPolicy.SHIFT_BACKWARD` | read in the offset after the gap |
| in a fold | `FoldPolicy.EARLIER` / `FoldPolicy.LATER` | the first or the second instant showing it |
| either | `REFUSE` | raises, naming the zone and the local time |

`Zone.resolve` returns both candidate instants and the kind (`UNIQUE`, `GAP`,
`FOLD`) for a caller that decides itself.

## Files

| file | what it holds |
|---|---|
| `civil.mojo` | days to and from (year, month, day), leap years, weekdays |
| `timestamp.mojo` | epoch seconds to and from UTC fields; RFC 3339, `YYYY-MM-DD`, `YYYYMMDDTHHMMSSZ` |
| `http_date.mojo` | the HTTP-date (IMF-fixdate) |
| `zone_offset.mojo` | `ZoneOffset` (seconds east of UTC, DST flag, abbreviation), `Transition` |
| `posix_tz.mojo` | the POSIX TZ string: `parse_posix_tz`, rule dates, DST from the latest rule instant |
| `tzif.mojo` | `parse_tzif`, and what it refuses |
| `zone.mojo` | `Zone`: `offset_at`, `next_transition`, `resolve`, `to_utc`; the policies; `local_seconds`, `posix_zone`, `utc_zone` |
| `zoneinfo.mojo` | `load_zone` from a zoneinfo directory, `check_zone_name` |

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_datetime`, version 0.1.0
(`mopm.toml`). The library is `src/komira_datetime/` (the files of the table above), its tests are `tests/`. The
package has no native archive and calls no foreign function: it is Mojo over `List`, `Span` and `String`. The files
that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN`: the least line coverage `:coverage` may measure; `:coverage_floor` fails when it falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_datetime:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_datetime-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_datetime` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs the
README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the tests are not run again.
