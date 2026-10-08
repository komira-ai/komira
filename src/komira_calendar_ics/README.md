# `komira_calendar_ics`

## Responsibility

The `.ics` edge of a simple calendar. `read_ics` reads an iCalendar file
(RFC 5545) into
[`komira_calendar`](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/README.md)'s
model (`komira_calendar_proto`'s `Event` and `OccurrenceOverride`) and
reports everything the model does not hold; `write_ics` writes the model
back as iCalendar. Reading what `write_ics` wrote gives the same events and
an empty report.

It is not a full iCalendar implementation. It reads a declared subset and
refuses or reports the rest, so nothing is lost without a line in the
report. Time zone rules come from a `ZoneSource`: `komira_datetime` zones read
from a zoneinfo directory (`ZoneinfoDirectory`) or built by the caller
(`ZoneTable`). A VTIMEZONE's own rules are never used.

## The subset

| iCalendar | read as | not held |
|---|---|---|
| VCALENDAR | one per input; VERSION 2.0 | another VERSION, a CALSCALE other than GREGORIAN, a METHOD other than PUBLISH (a scheduling message) refuse the input; other properties but PRODID are reported |
| VEVENT | an event (with no RECURRENCE-ID) or a one-occurrence edit | VTODO, VJOURNAL, VFREEBUSY and any other component are refused |
| UID | `uid` | missing: refused; a second series with the same UID: refused |
| DTSTART, DTEND, DURATION | a DATE start: all-day, `days` from DTEND or DURATION (whole days), one day without either; a DATE-TIME start: timed in the zone of its TZID, or `UTC` for a `Z` time, lasting the exact time to DTEND (in its own zone) or DURATION | a floating time, an unknown TZID, DTEND with DURATION, an end not after the start, a timed event with no end: refused |
| SUMMARY, DESCRIPTION, LOCATION | `title`, `description`, `location` (TEXT unescaped) | their parameters (LANGUAGE, ALTREP) are reported |
| STATUS | CANCELLED, else CONFIRMED | TENTATIVE and other values are reported as read as CONFIRMED |
| RRULE | the structured rule (`rrule.mojo`): DAILY, WEEKLY with weekdays, MONTHLY by day or one ordinal weekday, YEARLY; INTERVAL up to 999; COUNT or UNTIL (as the last local date it allows) | anything else is refused as out of subset; so is a second RRULE |
| EXDATE | `exdates`, on the event's wall clock | on an event that does not recur: reported; a DATE on a timed event or the reverse: refused |
| RECURRENCE-ID | an edit of the imported series of its UID: what differs from the series (start, length, title, location, description), or a cancelled occurrence | RANGE: refused; an edit of nothing: reported; an edit without a recurring series: refused |
| VALARM | a reminder: a TRIGGER relative to the start, at or before it, in whole minutes up to four weeks; at most 5 | an absolute or end-relative trigger, one after the start, a repeat, ACTION other than DISPLAY, DESCRIPTION other than the title, other alarm properties: reported |
| VTIMEZONE | its TZID's X-LIC-LOCATION, an IANA name tried when the TZID itself is no known zone | its observances |
| DTSTAMP | read, not reported (when the file was written) | |
| anything else | | reported, per component, name and detail, with a count and its first line |

`write_ics` writes VERSION 2.0, a PRODID, CALSCALE GREGORIAN, a VTIMEZONE
per zone used (yearly RRULE observances from the zone's footer, or each
listed change), and one VEVENT per event and per edit. A timed event's
length is written as DURATION, an all-day one's as DTEND; UNTIL is written
in UTC for a timed event, as RFC 5545 requires next to a zoned DTSTART.

## API

| name | file | what it is |
|---|---|---|
| `read_ics`, `IcsImport` | [read.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_ics/read.mojo) | a file to events and a report; raises when the input as a whole is refused |
| `write_ics`, `PRODID` | [write.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_ics/write.mojo) | events to a file; raises for an event that breaks the model or names an unknown zone |
| `IcsEvent` | [read_event.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_ics/read_event.mojo) | an event and its one-occurrence edits |
| `IcsReport`, `IcsRefusal`, `IcsDropped`, `IcsCode` | [report.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_ics/report.mojo) | the report: `refused` and `dropped`, `refuse`, `drop`, `merge`, `is_clean`; the refusal codes |
| `ZoneSource`, `ZoneinfoDirectory`, `ZoneTable` | [zones.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_ics/zones.mojo) | where zone rules come from; `ZoneTable.add`, `zone` |
| `IcsLimits` | [tree.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_ics/tree.mojo) | input octets, line octets and components per import |

## Examples

Every example below runs as a test when the package is built.

A weekly meeting exported by a client, with a property the model does not
hold:

```mojo
from komira_calendar_ics import IcsLimits, ZoneTable, read_ics
from komira_proto_codec import encode_json
from komira_datetime import posix_zone
from std.testing import assert_equal, assert_true

var zones = ZoneTable()
zones.add(posix_zone("Europe/London", "GMT0BST,M3.5.0/1,M10.5.0"))
var ics = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example//EN\r\n"
    + "BEGIN:VEVENT\r\nUID:sync-1\r\nDTSTAMP:20300901T000000Z\r\n"
    + "DTSTART;TZID=Europe/London:20301007T093000\r\nDTEND;TZID=Europe/London:20301007T100000\r\n"
    + "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10\r\nSUMMARY:Sync\r\nCATEGORIES:WORK\r\n"
    + "END:VEVENT\r\nEND:VCALENDAR\r\n"
)
var got = read_ics(ics.as_bytes(), zones, IcsLimits(max_components=100))
assert_equal(
    encode_json(got.events[0].event),
    '{"uid":"sync-1","title":"Sync","start":"2030-10-07T09:30:00","timeZone":"Europe/London",'
    + '"durationSeconds":1800,"recurrence":{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"],"count":10}}',
)
assert_true(not got.report.is_clean())
assert_equal(String(got.report.dropped[0]), "VEVENT CATEGORIES x1 from line 11")
```

A rule outside the subset is refused, with its reason:

```mojo
from komira_calendar_ics import IcsCode, ZoneTable, read_ics
from std.testing import assert_equal

var ics = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example//EN\r\n"
    + "BEGIN:VEVENT\r\nUID:hourly\r\nDTSTART:20301007T093000Z\r\nDURATION:PT5M\r\n"
    + "RRULE:FREQ=HOURLY\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
)
var got = read_ics(ics.as_bytes(), ZoneTable())
assert_equal(len(got.events), 0)
assert_equal(got.report.refused[0].code, IcsCode.RRULE_OUT_OF_SUBSET)
assert_equal(
    got.report.refused[0].message,
    "RRULE FREQ=HOURLY is outside the subset (DAILY, WEEKLY, MONTHLY, YEARLY)",
)
```

Export and import again:

```mojo
from komira_calendar_ics import IcsEvent, PRODID, ZoneTable, read_ics, write_ics
from komira_calendar_proto.calendar import Event
from komira_proto_codec import decode_json, encode_json
from std.testing import assert_equal, assert_true

var events = List[IcsEvent]()
events.append(
    IcsEvent(
        decode_json[Event](
            '{"uid":"offsite","title":"Team offsite","showWithoutTime":true,"startDate":"2030-11-04","days":3}'
        )
    )
)
var text = write_ics(events, ZoneTable(), 1914364800)
assert_true(text.find("PRODID:" + PRODID + "\r\n") >= 0)
assert_true(text.find("DTSTART;VALUE=DATE:20301104\r\nDTEND;VALUE=DATE:20301107\r\n") >= 0)
var back = read_ics(text.as_bytes(), ZoneTable())
assert_true(back.report.is_clean())
assert_equal(encode_json(back.events[0].event), encode_json(events[0].event))
```

## Conformance

`src/tests/conformance/komira_calendar_ics_conformance` holds the RFC 5545
examples (§3.6.1, §4, every §3.8.5.3 RRULE, the §3.6.5 VTIMEZONE) and files
in the shape Google, Apple, Outlook and Thunderbird export.
