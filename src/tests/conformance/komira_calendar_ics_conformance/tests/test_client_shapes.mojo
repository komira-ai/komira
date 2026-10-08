# =============================================================================
# test_client_shapes.mojo -- files in the shape calendar clients export.
#
# Each file is ours (the events, UIDs and dates are made up; every date is
# in 2030, or in 2007 and earlier), written in the shape one client's export takes:
#   Google      METHOD:PUBLISH, X-WR-* calendar properties, a weekly series
#               with WKST and EXDATE, an exception VEVENT that copies every
#               field and moves one occurrence, the -P0DT0H10M0S TRIGGER form
#   Apple       properties in no fixed order, its VTIMEZONE, a weekly series
#               with INTERVAL=1 and a UTC UNTIL at 04:59:59, an AUDIO alarm
#               with Apple's alarm properties
#   Outlook     a Windows zone name as TZID (quoted), whose VTIMEZONE names
#               no IANA zone: that series is refused, the all-day event is
#               kept; SUMMARY;LANGUAGE
#   Thunderbird a TZID of its own (/mozilla.org/...) mapped through
#               X-LIC-LOCATION; TRIGGER;VALUE=DURATION
# Each is read with today's zone rules, asserted event by event and report
# line by line, then written back with write_ics and read again: the events
# are the same and the second report is empty.
# =============================================================================

from std.testing import assert_equal

from komira_calendar_ics import IcsImport, read_ics, write_ics
from komira_datetime import seconds_from_fields
from komira_calendar_ics_conformance import client_zones, crlf, events_text, report_text


def _round_trip(got: IcsImport) raises:
    var text = write_ics(got.events, client_zones(), seconds_from_fields(2030, 10, 2)).text.copy()
    var again = read_ics(text.as_bytes(), client_zones())
    assert_equal(report_text(again.report), "", "report of the re-import")
    assert_equal(events_text(again), events_text(got))


comptime GOOGLE = (
    "BEGIN:VCALENDAR\n"  # 1
    + "PRODID:-//Google Inc//Google Calendar 70.9054//EN\n"
    + "VERSION:2.0\n"
    + "CALSCALE:GREGORIAN\n"
    + "METHOD:PUBLISH\n"
    + "X-WR-CALNAME:Team\n"  # 6
    + "X-WR-TIMEZONE:Europe/London\n"
    + "BEGIN:VEVENT\n"  # 8
    + "DTSTART;TZID=Europe/London:20301007T093000\n"
    + "DTEND;TZID=Europe/London:20301007T100000\n"
    + "RRULE:FREQ=WEEKLY;WKST=MO;BYDAY=MO\n"
    + "EXDATE;TZID=Europe/London:20301021T093000\n"
    + "DTSTAMP:20301001T120000Z\n"
    + "UID:5k2b9q0planning@example.com\n"
    + "CREATED:20300920T101500Z\n"  # 15
    + "LAST-MODIFIED:20300930T080000Z\n"
    + "SEQUENCE:1\n"
    + "STATUS:CONFIRMED\n"
    + "SUMMARY:Planning\n"
    + "TRANSP:OPAQUE\n"  # 20
    + "BEGIN:VALARM\n"
    + "ACTION:DISPLAY\n"
    + "DESCRIPTION:This is an event reminder\n"  # 23
    + "TRIGGER:-P0DT0H10M0S\n"
    + "END:VALARM\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"  # 27
    + "DTSTART;TZID=Europe/London:20301014T110000\n"
    + "DTEND;TZID=Europe/London:20301014T113000\n"
    + "DTSTAMP:20301001T120000Z\n"
    + "UID:5k2b9q0planning@example.com\n"
    + "RECURRENCE-ID;TZID=Europe/London:20301014T093000\n"
    + "CREATED:20300920T101500Z\n"
    + "LAST-MODIFIED:20300930T080000Z\n"
    + "SEQUENCE:2\n"
    + "STATUS:CONFIRMED\n"
    + "SUMMARY:Planning\n"
    + "TRANSP:OPAQUE\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"  # 40
    + "DTSTART;VALUE=DATE:20301225\n"
    + "DTEND;VALUE=DATE:20301226\n"
    + "DTSTAMP:20301001T120000Z\n"
    + "UID:closed-1225@example.com\n"
    + "SUMMARY:Office closed\n"
    + "TRANSP:TRANSPARENT\n"
    + "END:VEVENT\n"
    + "END:VCALENDAR\n"
)


def test_google() raises:
    var got = read_ics(crlf(GOOGLE).as_bytes(), client_zones())
    assert_equal(
        events_text(got),
        '{"uid":"5k2b9q0planning@example.com","title":"Planning","start":"2030-10-07T09:30:00",'
        + '"timeZone":"Europe/London","durationSeconds":1800,"recurrence":{"freq":"WEEKLY","interval":1,'
        + '"weekdays":["MONDAY"]},"exdates":["2030-10-21T09:30:00"],"reminders":[{"minutesBefore":10}]}\n'
        + '  {"originalStart":"2030-10-14T09:30:00","start":"2030-10-14T11:00:00"}\n'
        + '{"uid":"closed-1225@example.com","title":"Office closed","showWithoutTime":true,'
        + '"startDate":"2030-12-25","days":1}\n',
    )
    assert_equal(
        report_text(got.report),
        "VCALENDAR X-WR-CALNAME x1 from line 6\n"
        + "VCALENDAR X-WR-TIMEZONE x1 from line 7\n"
        + "VALARM DESCRIPTION x1 from line 23\n"
        + "VEVENT CREATED x2 from line 15\n"
        + "VEVENT LAST-MODIFIED x2 from line 16\n"
        + "VEVENT SEQUENCE x2 from line 17\n"
        + "VEVENT TRANSP x3 from line 20\n",
    )
    _round_trip(got)
    print("  test_google PASS")


comptime APPLE = (
    "BEGIN:VCALENDAR\n"  # 1
    + "METHOD:PUBLISH\n"
    + "VERSION:2.0\n"
    + "X-WR-CALNAME:Home\n"  # 4
    + "PRODID:-//Apple Inc.//macOS 15.0//EN\n"
    + "X-APPLE-CALENDAR-COLOR:#1BADF8\n"  # 6
    + "X-WR-TIMEZONE:America/New_York\n"
    + "CALSCALE:GREGORIAN\n"
    + "BEGIN:VTIMEZONE\n"  # 9
    + "TZID:America/New_York\n"
    + "BEGIN:DAYLIGHT\n"
    + "TZOFFSETFROM:-0500\n"
    + "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\n"
    + "DTSTART:20070311T020000\n"
    + "TZNAME:EDT\n"
    + "TZOFFSETTO:-0400\n"
    + "END:DAYLIGHT\n"
    + "BEGIN:STANDARD\n"  # 18
    + "TZOFFSETFROM:-0400\n"
    + "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\n"
    + "DTSTART:20071104T020000\n"
    + "TZNAME:EST\n"
    + "TZOFFSETTO:-0500\n"
    + "END:STANDARD\n"
    + "END:VTIMEZONE\n"
    + "BEGIN:VEVENT\n"  # 26
    + "TRANSP:OPAQUE\n"  # 27
    + "DTEND;TZID=America/New_York:20301105T183000\n"
    + "UID:0D9F3C1A-2B4E-4F6A-9C1D-ABCDEF012345\n"
    + "DTSTAMP:20301001T120000Z\n"
    + "LOCATION:Gym\n"
    + "SEQUENCE:0\n"  # 32
    + "X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC\n"
    + "SUMMARY:Climbing\n"
    + "LAST-MODIFIED:20301001T115900Z\n"  # 35
    + "CREATED:20301001T115800Z\n"
    + "DTSTART;TZID=America/New_York:20301105T170000\n"
    + "RRULE:FREQ=WEEKLY;INTERVAL=1;UNTIL=20301231T045959Z\n"
    + "BEGIN:VALARM\n"  # 39
    + "X-WR-ALARMUID:5E1F6A2B-0C3D-4E5F-8A9B-0123456789AB\n"
    + "UID:5E1F6A2B-0C3D-4E5F-8A9B-0123456789AB\n"
    + "TRIGGER:-PT30M\n"
    + "ATTACH;VALUE=URI:Chord\n"  # 43
    + "ACTION:AUDIO\n"
    + "X-APPLE-DEFAULT-ALARM:TRUE\n"
    + "ACKNOWLEDGED:20301001T120000Z\n"  # 46
    + "END:VALARM\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"  # 49
    + "TRANSP:TRANSPARENT\n"
    + "DTEND;VALUE=DATE:20301129\n"
    + "UID:7C2E9B40-5D1A-4B3C-A2E1-FEDCBA987654\n"
    + "DTSTAMP:20301001T120000Z\n"
    + "SUMMARY:Family weekend\n"
    + "DTSTART;VALUE=DATE:20301127\n"
    + "SEQUENCE:0\n"
    + "END:VEVENT\n"
    + "END:VCALENDAR\n"
)


def test_apple() raises:
    var got = read_ics(crlf(APPLE).as_bytes(), client_zones())
    # UNTIL 04:59:59Z on 31 December is 23:59:59 EST on the 30th.
    assert_equal(
        events_text(got),
        '{"uid":"0D9F3C1A-2B4E-4F6A-9C1D-ABCDEF012345","title":"Climbing","location":"Gym",'
        + '"start":"2030-11-05T17:00:00","timeZone":"America/New_York","durationSeconds":5400,'
        + '"recurrence":{"freq":"WEEKLY","interval":1,"until":"2030-12-30"},"reminders":[{"minutesBefore":30}]}\n'
        + '{"uid":"7C2E9B40-5D1A-4B3C-A2E1-FEDCBA987654","title":"Family weekend","showWithoutTime":true,'
        + '"startDate":"2030-11-27","days":2}\n',
    )
    assert_equal(
        report_text(got.report),
        "VCALENDAR X-WR-CALNAME x1 from line 4\n"
        + "VCALENDAR X-APPLE-CALENDAR-COLOR x1 from line 6\n"
        + "VCALENDAR X-WR-TIMEZONE x1 from line 7\n"
        + "VALARM X-WR-ALARMUID x1 from line 40\n"
        + "VALARM UID x1 from line 41\n"
        + "VALARM ATTACH x1 from line 43\n"
        + "VALARM ACTION (AUDIO, read as a reminder to the owner) x1 from line 44\n"
        + "VALARM X-APPLE-DEFAULT-ALARM x1 from line 45\n"
        + "VALARM ACKNOWLEDGED x1 from line 46\n"
        + "VEVENT TRANSP x2 from line 27\n"
        + "VEVENT SEQUENCE x2 from line 32\n"
        + "VEVENT X-APPLE-TRAVEL-ADVISORY-BEHAVIOR x1 from line 33\n"
        + "VEVENT LAST-MODIFIED x1 from line 35\n"
        + "VEVENT CREATED x1 from line 36\n",
    )
    _round_trip(got)
    print("  test_apple PASS")


comptime OUTLOOK = (
    "BEGIN:VCALENDAR\n"  # 1
    + "PRODID:-//Microsoft Corporation//Outlook 16.0 MIMEDIR//EN\n"
    + "VERSION:2.0\n"
    + "METHOD:PUBLISH\n"
    + "X-MS-OLK-FORCEINSPECTOROPEN:TRUE\n"  # 5
    + "BEGIN:VTIMEZONE\n"
    + "TZID:Eastern Standard Time\n"
    + "BEGIN:STANDARD\n"
    + "DTSTART:16011104T020000\n"
    + "RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11\n"
    + "TZOFFSETFROM:-0400\n"
    + "TZOFFSETTO:-0500\n"
    + "END:STANDARD\n"
    + "BEGIN:DAYLIGHT\n"
    + "DTSTART:16010311T020000\n"
    + "RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3\n"
    + "TZOFFSETFROM:-0500\n"
    + "TZOFFSETTO:-0400\n"
    + "END:DAYLIGHT\n"
    + "END:VTIMEZONE\n"
    + "BEGIN:VEVENT\n"  # 21
    + "CLASS:PUBLIC\n"
    + "CREATED:20301001T120000Z\n"
    + "DESCRIPTION:\\n\n"
    + 'DTEND;TZID="Eastern Standard Time":20301106T110000\n'
    + "DTSTAMP:20301001T120000Z\n"
    + 'DTSTART;TZID="Eastern Standard Time":20301106T100000\n'
    + "LAST-MODIFIED:20301001T120000Z\n"
    + "PRIORITY:5\n"
    + "RRULE:FREQ=MONTHLY;COUNT=6;BYDAY=1WE\n"
    + "SEQUENCE:0\n"
    + "SUMMARY;LANGUAGE=en-us:Monthly review\n"
    + "TRANSP:OPAQUE\n"
    + "UID:040000008200E00074C5B7101A82E00800000000A0B1C2D3E4F5A6B7C8D9E0F1A2B3C4D5\n"
    + "X-MICROSOFT-CDO-BUSYSTATUS:BUSY\n"
    + "BEGIN:VALARM\n"
    + "TRIGGER:-PT15M\n"
    + "ACTION:DISPLAY\n"
    + "DESCRIPTION:Reminder\n"
    + "END:VALARM\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"  # 42
    + "CLASS:PUBLIC\n"  # 43
    + "DESCRIPTION:Bring the slides\\n\n"
    + "DTEND;VALUE=DATE:20301204\n"
    + "DTSTAMP:20301001T120000Z\n"
    + "DTSTART;VALUE=DATE:20301203\n"
    + "SUMMARY;LANGUAGE=en-us:Quarterly offsite\n"  # 48
    + "TRANSP:TRANSPARENT\n"
    + "UID:040000008200E00074C5B7101A82E00800000000F1E2D3C4B5A6978877665544332211FF\n"
    + "X-MICROSOFT-CDO-ALLDAYEVENT:TRUE\n"  # 51
    + "END:VEVENT\n"
    + "END:VCALENDAR\n"
)


def test_outlook() raises:
    var got = read_ics(crlf(OUTLOOK).as_bytes(), client_zones())
    assert_equal(
        events_text(got),
        '{"uid":"040000008200E00074C5B7101A82E00800000000F1E2D3C4B5A6978877665544332211FF",'
        + '"title":"Quarterly offsite","description":"Bring the slides\\n","showWithoutTime":true,'
        + '"startDate":"2030-12-03","days":1}\n',
    )
    assert_equal(
        report_text(got.report),
        'UNKNOWN_TZID at line 21 (UID "040000008200E00074C5B7101A82E00800000000A0B1C2D3E4F5A6B7C8D9E0F1A2B3C4D5"): '
        + 'TZID "Eastern Standard Time" names no time zone known here\n'
        + "VCALENDAR X-MS-OLK-FORCEINSPECTOROPEN x1 from line 5\n"
        + "VEVENT SUMMARY;LANGUAGE x1 from line 48\n"
        + "VEVENT CLASS x1 from line 43\n"
        + "VEVENT TRANSP x1 from line 49\n"
        + "VEVENT X-MICROSOFT-CDO-ALLDAYEVENT x1 from line 51\n",
    )
    _round_trip(got)
    print("  test_outlook PASS")


comptime THUNDERBIRD = (
    "BEGIN:VCALENDAR\n"  # 1
    + "PRODID:-//Mozilla.org/NONSGML Mozilla Calendar V1.1//EN\n"
    + "VERSION:2.0\n"
    + "BEGIN:VTIMEZONE\n"
    + "TZID:/mozilla.org/20070129_1/Europe/Berlin\n"
    + "X-LIC-LOCATION:Europe/Berlin\n"
    + "BEGIN:DAYLIGHT\n"
    + "TZOFFSETFROM:+0100\n"
    + "TZOFFSETTO:+0200\n"
    + "TZNAME:CEST\n"
    + "DTSTART:19700329T020000\n"
    + "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\n"
    + "END:DAYLIGHT\n"
    + "BEGIN:STANDARD\n"
    + "TZOFFSETFROM:+0200\n"
    + "TZOFFSETTO:+0100\n"
    + "TZNAME:CET\n"
    + "DTSTART:19701025T030000\n"
    + "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\n"
    + "END:STANDARD\n"
    + "END:VTIMEZONE\n"
    + "BEGIN:VEVENT\n"  # 22
    + "CREATED:20301001T120000Z\n"  # 23
    + "LAST-MODIFIED:20301001T120000Z\n"
    + "DTSTAMP:20301001T120000Z\n"
    + "UID:3c0f6b52-7a3c-4c8e-9a51-0123456789ab\n"
    + "SUMMARY:Dentist\n"
    + "DTSTART;TZID=/mozilla.org/20070129_1/Europe/Berlin:20301112T081500\n"
    + "DTEND;TZID=/mozilla.org/20070129_1/Europe/Berlin:20301112T090000\n"
    + "LOCATION:Main street 1\n"
    + "X-MOZ-GENERATION:1\n"  # 31
    + "BEGIN:VALARM\n"
    + "ACTION:DISPLAY\n"
    + "TRIGGER;VALUE=DURATION:-PT1H\n"
    + "DESCRIPTION:Mozilla Alarm: Dentist\n"  # 35
    + "END:VALARM\n"
    + "END:VEVENT\n"
    + "END:VCALENDAR\n"
)


def test_thunderbird() raises:
    var got = read_ics(crlf(THUNDERBIRD).as_bytes(), client_zones())
    assert_equal(
        events_text(got),
        '{"uid":"3c0f6b52-7a3c-4c8e-9a51-0123456789ab","title":"Dentist","location":"Main street 1",'
        + '"start":"2030-11-12T08:15:00","timeZone":"Europe/Berlin","durationSeconds":2700,'
        + '"reminders":[{"minutesBefore":60}]}\n',
    )
    assert_equal(
        report_text(got.report),
        "VALARM DESCRIPTION x1 from line 35\n"
        + "VEVENT CREATED x1 from line 23\n"
        + "VEVENT LAST-MODIFIED x1 from line 24\n"
        + "VEVENT X-MOZ-GENERATION x1 from line 31\n",
    )
    _round_trip(got)
    print("  test_thunderbird PASS")


def main() raises:
    print("test_client_shapes")
    test_google()
    test_apple()
    test_outlook()
    test_thunderbird()
    print("ALL TESTS PASS")
