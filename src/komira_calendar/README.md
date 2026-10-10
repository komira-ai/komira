# `komira_calendar`

## Responsibility

A simple calendar's model and its validation: what a client may write to a
calendar, an event and a one-occurrence edit
([`komira_calendar_proto`](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_proto/README.md)'s messages),
checked field by field. Each check returns the first rule the value breaks as
a `Refusal`: a stable `code` a client may branch on, the JSON path of the
field (`recurrence.until`, `reminders[5].minutesBefore`) and a sentence.
`error_response` writes a refusal as the API's error body.

The model is deliberately not iCalendar. An event is all-day or timed, never
floating; a recurrence is a structured rule (DAILY, WEEKLY with weekdays,
MONTHLY by day of the month or by ordinal weekday, YEARLY; an interval of 1
to 999; an end by count or by date), never RRULE text; there are no
attendees.

`expand` lists an event's occurrences in a window and `series_span` bounds
them all, on the event's wall clock (see Expansion below).

Not here: whether a named time zone exists (only its shape is checked),
turning local times into UTC instants, storage, and HTTP.

## API

| name | file | what it is |
|---|---|---|
| `check_calendar`, `check_event`, `check_override` | [validate.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/validate.mojo) | the first rule a value breaks, or None |
| `check_recurrence` | [recurrence.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/recurrence.mojo) | the recurrence rule's checks, given the event's first day |
| `expand`, `series_span`, `Occurrence`, `SeriesSpan`, `OPEN_END`, `MAX_WINDOW_OCCURRENCES` | [expand.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/expand.mojo) | the occurrences overlapping a window; the first start to the last end |
| `Refusal`, `RefusalCode`, `error_response` | [refusal.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/refusal.mojo) | a refusal, its codes, the API error body |
| `parse_local_date`, `parse_local_datetime`, `LocalDateTime` (`seconds()`), `is_time_zone_name`, `MAX_TIME_ZONE_BYTES` | [local_time.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/local_time.mojo) | `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM:SS`, the shape of an IANA zone name |
| `MAX_*` | [limits.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/limits.mojo) | the bounds: 5 reminders, interval 999, count 10000, 1000 exdates, 366 days, text lengths |

## Rules

| field | rule | code |
|---|---|---|
| calendar `name` | required, one line, at most 256 bytes | `NAME_REQUIRED`, `TEXT_TOO_LONG`, `TEXT_CONTROL_CHARACTER` |
| calendar `color` | empty or `#rrggbb` | `COLOR_MALFORMED` |
| calendar or timed event `timeZone` | required, shaped like an IANA name | `TIME_ZONE_REQUIRED`, `TIME_ZONE_MALFORMED` |
| `uid`, `title`, `location`, `description` | at most 255, 1024, 1024, 65536 bytes; no control character (a description may hold tab, LF and CR) | `TEXT_TOO_LONG`, `TEXT_CONTROL_CHARACTER` |
| `status` | CONFIRMED or CANCELLED | `STATUS_UNKNOWN` |
| all-day event | `startDate` a local date and `days` 1 to 366; no `timeZone`, `start` or `durationSeconds` | `START_DATE_REQUIRED`, `START_MALFORMED`, `DAYS_OUT_OF_RANGE`, `ALL_DAY_WITH_ZONE`, `ALL_DAY_WITH_TIME` |
| timed event | `start` a local date-time, `durationSeconds` 1 to 366 days; no `startDate` or `days` | `START_REQUIRED`, `START_MALFORMED`, `DURATION_ZERO`, `DURATION_TOO_LONG`, `TIMED_WITH_DATE` |
| `recurrence` | a known `freq`; `interval` 1 to 999; `weekdays` on WEEKLY only, known, no repeats; MONTHLY exactly one of `monthDay` (1 to 31) or `ordinal` (1 to 4, or -1) with `ordinalWeekday`, and neither on another frequency; `count` (at most 10000) or `until` (a local date on or after the first day), not both | `FREQUENCY_REQUIRED`, `FREQUENCY_UNKNOWN`, `INTERVAL_OUT_OF_RANGE`, `WEEKDAYS_NOT_WEEKLY`, `WEEKDAY_UNKNOWN`, `WEEKDAY_DUPLICATE`, `MONTHLY_RULE_REQUIRED`, `MONTHLY_RULE_AMBIGUOUS`, `MONTH_DAY_OUT_OF_RANGE`, `ORDINAL_REQUIRED`, `ORDINAL_OUT_OF_RANGE`, `ORDINAL_WEEKDAY_REQUIRED`, `MONTHLY_FIELDS_NOT_MONTHLY`, `COUNT_WITH_UNTIL`, `COUNT_OUT_OF_RANGE`, `UNTIL_MALFORMED`, `UNTIL_BEFORE_START` |
| `exdates` | on a recurring event only, at most 1000, each in the event's form (a date when all-day), no repeats | `EXDATES_WITHOUT_RECURRENCE`, `TOO_MANY_EXDATES`, `EXDATE_MALFORMED`, `EXDATE_DUPLICATE` |
| `reminders` | at most 5, each at most 40320 minutes before, no repeats | `TOO_MANY_REMINDERS`, `REMINDER_OUT_OF_RANGE`, `REMINDER_DUPLICATE` |
| override | of a recurring event; `originalStart` and `start` in the event's form; cancelled with no replacement, or kept with at least one; `days` for an all-day event, `durationSeconds` for a timed one | `OVERRIDE_WITHOUT_RECURRENCE`, `ORIGINAL_START_MALFORMED`, `OVERRIDE_CANCELLED_WITH_CHANGES`, `OVERRIDE_EMPTY`, and the event codes above |

## Expansion

Times are local seconds: seconds since 1970-01-01T00:00:00 on the event's
wall clock, with no zone applied (`parse_local_datetime(text).seconds()`). An
occurrence starts on a day the rule picks, at the event's time of day
(midnight for an all-day event), and lasts `durationSeconds` or `days` whole
days. Since the rule is expanded on the wall clock, a weekly 09:00 event is at
09:00 local on every occurrence; the instant that is depends on the zone.

| rule | the days it picks |
|---|---|
| DAILY | every `interval`-th day from the first |
| WEEKLY | the named `weekdays` (else the first day's weekday) of every `interval`-th Monday-to-Sunday week |
| MONTHLY `monthDay` | that day of every `interval`-th month; a month without it is skipped (the 31st skips November) |
| MONTHLY `ordinal` | the `ordinal`-th `ordinalWeekday` of every `interval`-th month; -1 is the last |
| YEARLY | the first day's month and day every `interval`-th year; 29 February skips common years |

A day before the event's first day is never an occurrence, and the first day
is one only if the rule picks it (a WEEKLY Monday rule written to start on a
Wednesday begins the next Monday). `count` counts occurrences before
`exdates` remove any; `until` is inclusive. Nothing after 9999-12-31 is
picked. `expand` returns the occurrences that overlap the window (start
before its end, end after its start), at most 10000 per call.
`series_span` gives the first start and the last end; a series with neither
`count` nor `until` ends at `OPEN_END` (`Int64.MAX`), so a stored span is a
plain range and a window query is `first_start < to AND last_end > from`.

The last Friday of each month, for three months:

```mojo
from komira_calendar import expand, parse_local_datetime, series_span
from komira_calendar_proto.calendar import Event
from komira_proto_codec import decode_json
from std.testing import assert_equal

var review = decode_json[Event](
    '{"title":"Review","start":"2026-10-30T15:00:00","timeZone":"America/New_York","durationSeconds":3600,'
    + '"recurrence":{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"FRIDAY","count":3}}'
)
var all = expand(
    review,
    parse_local_datetime("2026-10-01T00:00:00").seconds(),
    parse_local_datetime("2027-01-01T00:00:00").seconds(),
)
assert_equal(len(all), 3)
assert_equal(all[1].start, parse_local_datetime("2026-11-27T15:00:00").seconds())
assert_equal(series_span(review).value().last_end, parse_local_datetime("2026-12-25T16:00:00").seconds())
```

## Example

Every example below runs as a test when the package is built.

An all-day event that names a time zone is refused, and the refusal is sent
as the API's error body:

```mojo
from komira_calendar import RefusalCode, check_event, error_response
from komira_calendar_proto.calendar import Event
from komira_proto_codec import decode_json, encode_json
from std.testing import assert_equal

var event = decode_json[Event](
    '{"title":"Offsite","showWithoutTime":true,"startDate":"2026-11-02","days":2,"timeZone":"Europe/Paris"}'
)
var refusal = check_event(event)
assert_equal(refusal.value().code, RefusalCode.ALL_DAY_WITH_ZONE)
assert_equal(
    encode_json(error_response(refusal.value())),
    '{"error":{"code":"ALL_DAY_WITH_ZONE","message":"an all-day event has no time zone","field":"timeZone"}}',
)
```

A monthly meeting on the last Friday, edited for one occurrence:

```mojo
from komira_calendar import check_event, check_override
from komira_calendar_proto.calendar import Event, OccurrenceOverride
from komira_proto_codec import decode_json
from std.testing import assert_equal, assert_false

var review = decode_json[Event](
    '{"title":"Review","start":"2026-10-30T15:00:00","timeZone":"America/New_York","durationSeconds":3600,'
    + '"recurrence":{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"FRIDAY"}}'
)
assert_false(Bool(check_event(review)))

var moved = decode_json[OccurrenceOverride]('{"originalStart":"2026-11-27T15:00:00","start":"2026-11-26T15:00:00"}')
assert_false(Bool(check_override(moved, review)))

var empty = decode_json[OccurrenceOverride]('{"originalStart":"2026-11-27T15:00:00"}')
assert_equal(check_override(empty, review).value().code, "OVERRIDE_EMPTY")
```

The text forms are exact:

```mojo
from komira_calendar import is_time_zone_name, parse_local_date, parse_local_datetime
from std.testing import assert_equal, assert_false, assert_true

assert_equal(parse_local_date("1970-01-02"), 1)
assert_equal(parse_local_datetime("1970-01-02T00:01:05").second_of_day, 65)
assert_true(is_time_zone_name("America/Argentina/Buenos_Aires"))
assert_false(is_time_zone_name("Europe//London"))
```
