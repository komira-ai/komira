# komira_tz

IANA time zones in pure Mojo. It reads TZif files (RFC 8536, versions 1 to 4)
into a `Zone`, evaluates the POSIX TZ string of their footer for instants past
the last listed transition, converts a UTC instant to local time, and converts
a local time to UTC, where a local time the clock skipped (a gap) or showed
twice (a fold) is settled by a policy the caller must name.

It bundles no zone data. A caller passes TZif bytes (`parse_tzif`) or names a
zoneinfo directory, as zic writes it (`load_zone`). komira's conformance tests
read the tz release pinned in `third_party/tzdata`. Instants are POSIX epoch
seconds: leap seconds are not modelled, and a zone with leap-second records
is refused.

## Examples

A zone from a POSIX TZ string, and the offset at an instant:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_datetime import seconds_from_fields
from komira_tz import posix_zone

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
from komira_datetime import seconds_from_fields
from komira_tz import FoldPolicy, GapPolicy, LocalKind, local_seconds, posix_zone

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
| `offset.mojo` | `ZoneOffset` (seconds east of UTC, DST flag, abbreviation), `Transition` |
| `posix_tz.mojo` | the POSIX TZ string: `parse_posix_tz`, rule dates, DST per year |
| `tzif.mojo` | `parse_tzif`, and what it refuses |
| `zone.mojo` | `Zone`: `offset_at`, `next_transition`, `resolve`, `to_utc`; the policies; `local_seconds`, `posix_zone`, `utc_zone` |
| `database.mojo` | `load_zone` from a zoneinfo directory, `check_zone_name` |
