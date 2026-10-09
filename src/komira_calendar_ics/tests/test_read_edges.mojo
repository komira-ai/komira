# =============================================================================
# test_read_edges.mojo -- read_ics on the rows test_read does not reach:
# a malformed UNTIL, a floating EXDATE and edit DTSTART (read on the event's
# wall clock), a floating DTEND, an all-day end before its start, alarms that
# cannot be reminders, a DURATION that is not one, and all-day edits (moved
# and lengthened, a DATE-TIME start, an end not after the start, no UID, a
# title the model refuses, an edit before its series), a timed edit too long
# for the model, and ends exactly one day or one second before the start
# (an end of -1 is an end, not a missing one).
#
# As in test_read, every refusal and report line is asserted as exact text
# and every kept event and edit as the API's JSON.
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import encode_json
from komira_datetime import posix_zone
from komira_calendar_ics import IcsImport, IcsReport, ZoneTable, read_ics


def _zones() raises -> ZoneTable:
    var t = ZoneTable()
    t.add(posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))
    return t^


def _report(rep: IcsReport) -> String:
    var out = String()
    for r in rep.refused:
        out += String(r) + "\n"
    for d in rep.dropped:
        out += String(d) + "\n"
    return out^


def _events(got: IcsImport) raises -> String:
    var out = String()
    for ref e in got.events:
        out += encode_json(e.event) + "\n"
        for ref o in e.overrides:
            out += "  " + encode_json(o) + "\n"
    return out^


comptime EDGES = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example//test//EN\r\n"  # 1-3
    + "BEGIN:VEVENT\r\n"  # 4
    + "UID:until-bad\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"
    + "DURATION:PT1H\r\n"
    + "RRULE:FREQ=DAILY;UNTIL=2030X\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 10
    + "UID:floating-ex\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"
    + "DURATION:PT1H\r\n"
    + "RRULE:FREQ=DAILY\r\n"
    + "EXDATE:20300905T090000\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 17
    + "UID:dtend-floating\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"
    + "DTEND:20300902T100000\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 22
    + "UID:allday-back\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "DTEND;VALUE=DATE:20301103\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 27
    + "UID:alarms\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "BEGIN:VALARM\r\n"  # 30
    + "TRIGGER:-P5W\r\n"
    + "BEGIN:X-NESTED\r\n"
    + "END:X-NESTED\r\n"
    + "END:VALARM\r\n"
    + "BEGIN:VALARM\r\n"  # 35
    + "TRIGGER:soon\r\n"
    + "END:VALARM\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 39
    + "UID:bad-duration\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"
    + "DURATION:soon\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 44: an edit before its series
    + "UID:allday-series\r\n"
    + "RECURRENCE-ID;VALUE=DATE:20301202\r\n"
    + "EXDATE;VALUE=DATE:20301209\r\n"  # 47
    + "SUMMARY:Changed\r\n"
    + "X-FOO:1\r\n"  # 49
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 51
    + "UID:allday-series\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "RRULE:FREQ=WEEKLY\r\n"
    + "SUMMARY:Weekly\r\n"
    + "X-FOO:2\r\n"  # 56
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 58
    + "UID:allday-series\r\n"
    + "RECURRENCE-ID;VALUE=DATE:20301111\r\n"
    + "DTSTART;VALUE=DATE:20301112\r\n"
    + "DTEND;VALUE=DATE:20301114\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 64
    + "UID:allday-series\r\n"
    + "RECURRENCE-ID;VALUE=DATE:20301118\r\n"
    + "DTSTART;TZID=America/New_York:20301118T090000\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 69
    + "UID:allday-series\r\n"
    + "RECURRENCE-ID;VALUE=DATE:20301125\r\n"
    + "DTSTART;VALUE=DATE:20301125\r\n"
    + "DTEND;VALUE=DATE:20301125\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 75
    + "RECURRENCE-ID;VALUE=DATE:20301216\r\n"
    + "SUMMARY:No uid\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 79
    + "UID:allday-series\r\n"
    + "RECURRENCE-ID;VALUE=DATE:20301216\r\n"
    + "SUMMARY:bad\\nline\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 84
    + "UID:timed-series\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"
    + "DURATION:PT1H\r\n"
    + "RRULE:FREQ=DAILY\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 90
    + "UID:timed-series\r\n"
    + "RECURRENCE-ID;TZID=America/New_York:20300903T090000\r\n"
    + "DURATION:P400D\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 95
    + "UID:timed-series\r\n"
    + "RECURRENCE-ID;TZID=America/New_York:20300904T090000\r\n"
    + "DTSTART:20300904T100000\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 100
    + "UID:one-second-back\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"
    + "DTEND;TZID=America/New_York:20300902T085959\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 105
    + "UID:allday-series\r\n"
    + "RECURRENCE-ID;VALUE=DATE:20301209\r\n"
    + "DTSTART;VALUE=DATE:20301209\r\n"
    + "DTEND;VALUE=DATE:20301208\r\n"
    + "END:VEVENT\r\n"
    + "END:VCALENDAR\r\n"
)


def test_edges() raises:
    var got = read_ics(EDGES.as_bytes(), _zones())
    assert_equal(
        _report(got.report),
        'RRULE_MALFORMED at line 4 (UID "until-bad"): RRULE UNTIL "2030X" is not a DATE-TIME (YYYYMMDDTHHMMSS, optionally ending in Z)\n'
        + 'FLOATING_TIME at line 17 (UID "dtend-floating"): DTEND is a floating time (no TZID, no Z)\n'
        + "NOT_AFTER_START at line 22 (UID \"allday-back\"): the event's end is not after its start\n"
        + 'VALUE_MALFORMED at line 39 (UID "bad-duration"): "soon" is not a DURATION (it starts with P, after an optional sign)\n'
        + "NOT_AFTER_START at line 100 (UID \"one-second-back\"): the event's end is not after its start\n"
        + "FORM_MISMATCH at line 64 (UID \"allday-series\"): DTSTART is a DATE-TIME but the event's DTSTART is a DATE\n"
        + "NOT_AFTER_START at line 69 (UID \"allday-series\"): the occurrence's end is not after its start\n"
        + 'UID_MISSING at line 75 (UID ""): the VEVENT has no UID\n'
        + 'TEXT_CONTROL_CHARACTER at line 79 (UID "allday-series"): the event breaks the calendar model at title: title holds control character 0xa at byte 3\n'
        + 'DURATION_TOO_LONG at line 90 (UID "timed-series"): the occurrence lasts 34560000 seconds; at most 31622400 are allowed\n'
        + "NOT_AFTER_START at line 105 (UID \"allday-series\"): the occurrence's end is not after its start\n"
        + "VALARM a component inside VALARM x1 from line 30\n"
        + "VALARM TRIGGER (more than 40320 minutes before) x1 from line 31\n"
        + "VALARM TRIGGER (not a DURATION) x1 from line 36\n"
        + "VEVENT X-FOO x2 from line 49\n"
        + "VEVENT EXDATE (on an occurrence edit) x1 from line 47\n",
    )
    assert_equal(
        _events(got),
        '{"uid":"floating-ex","start":"2030-09-02T09:00:00","timeZone":"America/New_York","durationSeconds":3600,'
        + '"recurrence":{"freq":"DAILY","interval":1},"exdates":["2030-09-05T09:00:00"]}\n'
        + '{"uid":"alarms","showWithoutTime":true,"startDate":"2030-11-04","days":1}\n'
        + '{"uid":"allday-series","title":"Weekly","showWithoutTime":true,"startDate":"2030-11-04","days":1,'
        + '"recurrence":{"freq":"WEEKLY","interval":1}}\n'
        + '  {"originalStart":"2030-12-02","title":"Changed"}\n'
        + '  {"originalStart":"2030-11-11","start":"2030-11-12","days":2}\n'
        + '{"uid":"timed-series","start":"2030-09-02T09:00:00","timeZone":"America/New_York","durationSeconds":3600,'
        + '"recurrence":{"freq":"DAILY","interval":1}}\n'
        + '  {"originalStart":"2030-09-04T09:00:00","start":"2030-09-04T10:00:00"}\n',
    )
    print("  test_edges PASS")


def main() raises:
    print("test_read_edges")
    test_edges()
    print("ALL TESTS PASS")
