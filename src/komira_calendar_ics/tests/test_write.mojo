# =============================================================================
# test_write.mojo -- write_ics line by line, its VTIMEZONEs, its refusals,
# and export then import giving back the same events.
#
# The golden pins every line of one export (an all-day event, a weekly
# series in New York with an edit and a cancelled occurrence, a UTC event
# with no uid, a monthly "last Friday" series), so a field written in the
# wrong form (an UNTIL in local time, a TZID on a UTC time, a TEXT value not
# escaped) turns it red. The VTIMEZONE rows cover the three shapes: yearly
# rules from a footer, single observances from listed transitions, and a
# zone with no change. The round trip reads each export back and compares
# every event and edit as the API's JSON, with a clean report.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_calendar_proto.calendar import Event, OccurrenceOverride
from komira_datetime import seconds_from_fields
from komira_proto_codec import decode_json, encode_json
from komira_datetime import ZoneOffset, Zone, parse_posix_tz, posix_zone
from komira_calendar_ics import IcsEvent, ZoneTable, read_ics, write_ics
from komira_calendar_ics.vtimezone import write_vtimezone


def _zones() raises -> ZoneTable:
    var t = ZoneTable()
    t.add(posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))
    t.add(posix_zone("Europe/London", "GMT0BST,M3.5.0/1,M10.5.0"))
    t.add(posix_zone("Asia/Kathmandu", "<+0545>-5:45"))
    return t^


def _ev(json: String) raises -> Event:
    return decode_json[Event](json)


def _ov(json: String) raises -> OccurrenceOverride:
    return decode_json[OccurrenceOverride](json)


def _stamp() raises -> Int:
    return seconds_from_fields(2030, 9, 1)


def _lines(text: String) -> String:
    """`text` with each CRLF shown as a newline, so a diff reads by line."""
    return text.replace("\r\n", "\n")


def _events() raises -> List[IcsEvent]:
    var out = List[IcsEvent]()
    out.append(IcsEvent(_ev('{"uid":"offsite","title":"Team offsite","showWithoutTime":true,"startDate":"2030-11-04","days":3}')))
    var edits = List[OccurrenceOverride]()
    edits.append(_ov('{"originalStart":"2030-09-16T09:00:00","start":"2030-09-16T10:00:00","title":"Moved sync"}'))
    edits.append(_ov('{"originalStart":"2030-09-19T09:00:00","cancelled":true}'))
    out.append(
        IcsEvent(
            _ev(
                '{"uid":"sync","title":"Weekly sync; notes, too","description":"Agenda:\\nitem","location":"Room 4",'
                + '"start":"2030-09-02T09:00:00","timeZone":"America/New_York","durationSeconds":1800,'
                + '"recurrence":{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY","THURSDAY"],"until":"2030-12-29"},'
                + '"exdates":["2030-09-05T09:00:00"],"reminders":[{"minutesBefore":10},{"minutesBefore":1440}]}'
            ),
            edits^,
        )
    )
    out.append(
        IcsEvent(
            _ev('{"id":"evt-3","title":"Call","start":"2030-11-02T14:00:00","timeZone":"UTC","durationSeconds":2700,"status":"CANCELLED"}')
        )
    )
    out.append(
        IcsEvent(
            _ev(
                '{"uid":"review","title":"Review","showWithoutTime":true,"startDate":"2030-09-27","days":1,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"FRIDAY","count":12},'
                + '"exdates":["2030-10-25"]}'
            )
        )
    )
    return out^


comptime NY_VTIMEZONE = (
    "BEGIN:VTIMEZONE\n"
    + "TZID:America/New_York\n"
    + "BEGIN:STANDARD\n"
    + "DTSTART:20291104T020000\n"
    + "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\n"
    + "TZNAME:EST\n"
    + "TZOFFSETFROM:-0400\n"
    + "TZOFFSETTO:-0500\n"
    + "END:STANDARD\n"
    + "BEGIN:DAYLIGHT\n"
    + "DTSTART:20300310T020000\n"
    + "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\n"
    + "TZNAME:EDT\n"
    + "TZOFFSETFROM:-0500\n"
    + "TZOFFSETTO:-0400\n"
    + "END:DAYLIGHT\n"
    + "END:VTIMEZONE\n"
)


comptime GOLDEN = (
    "BEGIN:VCALENDAR\n"
    + "VERSION:2.0\n"
    + "PRODID:-//komira//komira_calendar_ics//EN\n"
    + "CALSCALE:GREGORIAN\n"
    + NY_VTIMEZONE
    + "BEGIN:VEVENT\n"
    + "UID:offsite\n"
    + "DTSTAMP:20300901T000000Z\n"
    + "DTSTART;VALUE=DATE:20301104\n"
    + "DTEND;VALUE=DATE:20301107\n"
    + "SUMMARY:Team offsite\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"
    + "UID:sync\n"
    + "DTSTAMP:20300901T000000Z\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\n"
    + "DURATION:PT30M\n"
    + "SUMMARY:Weekly sync\\; notes\\, too\n"
    + "LOCATION:Room 4\n"
    + "DESCRIPTION:Agenda:\\nitem\n"
    + "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;UNTIL=20301229T140000Z\n"
    + "EXDATE;TZID=America/New_York:20300905T090000\n"
    + "BEGIN:VALARM\n"
    + "ACTION:DISPLAY\n"
    + "DESCRIPTION:Weekly sync\\; notes\\, too\n"
    + "TRIGGER:-PT10M\n"
    + "END:VALARM\n"
    + "BEGIN:VALARM\n"
    + "ACTION:DISPLAY\n"
    + "DESCRIPTION:Weekly sync\\; notes\\, too\n"
    + "TRIGGER:-PT1440M\n"
    + "END:VALARM\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"
    + "UID:sync\n"
    + "DTSTAMP:20300901T000000Z\n"
    + "RECURRENCE-ID;TZID=America/New_York:20300916T090000\n"
    + "DTSTART;TZID=America/New_York:20300916T100000\n"
    + "DURATION:PT30M\n"
    + "SUMMARY:Moved sync\n"
    + "LOCATION:Room 4\n"
    + "DESCRIPTION:Agenda:\\nitem\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"
    + "UID:sync\n"
    + "DTSTAMP:20300901T000000Z\n"
    + "RECURRENCE-ID;TZID=America/New_York:20300919T090000\n"
    + "DTSTART;TZID=America/New_York:20300919T090000\n"
    + "STATUS:CANCELLED\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"
    + "UID:evt-3\n"
    + "DTSTAMP:20300901T000000Z\n"
    + "DTSTART:20301102T140000Z\n"
    + "DURATION:PT45M\n"
    + "SUMMARY:Call\n"
    + "STATUS:CANCELLED\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"
    + "UID:review\n"
    + "DTSTAMP:20300901T000000Z\n"
    + "DTSTART;VALUE=DATE:20300927\n"
    + "DTEND;VALUE=DATE:20300928\n"
    + "SUMMARY:Review\n"
    + "RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=12\n"
    + "EXDATE;VALUE=DATE:20301025\n"
    + "END:VEVENT\n"
    + "END:VCALENDAR\n"
)


def test_golden() raises:
    var text = write_ics(_events(), _zones(), _stamp()).text.copy()
    assert_equal(_lines(text), GOLDEN)
    # Every line ends in CRLF: the CRLF count equals the line count.
    assert_equal(len(text.split("\r\n")), len(GOLDEN.split("\n")))
    print("  test_golden PASS")


def test_vtimezones() raises:
    var from_utc = seconds_from_fields(2030, 6, 1)
    # No change at all: one observance at 1970, both offsets the same.
    assert_equal(
        _lines(write_vtimezone("Asia/Kathmandu", posix_zone("Asia/Kathmandu", "<+0545>-5:45"), from_utc)),
        "BEGIN:VTIMEZONE\nTZID:Asia/Kathmandu\nBEGIN:STANDARD\nDTSTART:19700101T000000\nTZNAME:+0545\n"
        + "TZOFFSETFROM:+0545\nTZOFFSETTO:+0545\nEND:STANDARD\nEND:VTIMEZONE\n",
    )
    # Listed transitions and no footer: one observance per change in the
    # span, each at the wall time before the change.
    var types = List[ZoneOffset]()
    types.append(ZoneOffset(3600, False, "CET"))
    types.append(ZoneOffset(7200, True, "CEST"))
    var times = List[Int]()
    times.append(seconds_from_fields(2030, 3, 31, 1))
    times.append(seconds_from_fields(2030, 10, 27, 1))
    var kinds = List[Int]()
    kinds.append(1)
    kinds.append(0)
    var listed = Zone("Test/Listed", times^, kinds^, types^, False, parse_posix_tz("CET-1"))
    assert_equal(
        _lines(write_vtimezone("Test/Listed", listed, from_utc)),
        "BEGIN:VTIMEZONE\nTZID:Test/Listed\n"
        + "BEGIN:DAYLIGHT\nDTSTART:20300331T020000\nTZNAME:CEST\nTZOFFSETFROM:+0100\nTZOFFSETTO:+0200\nEND:DAYLIGHT\n"
        + "BEGIN:STANDARD\nDTSTART:20301027T030000\nTZNAME:CET\nTZOFFSETFROM:+0200\nTZOFFSETTO:+0100\nEND:STANDARD\n"
        + "END:VTIMEZONE\n",
    )
    # A "last Sunday" rule (week 5 of the POSIX string) is BYDAY=-1SU; the
    # end comes first in this span, so STANDARD is written first.
    var london = posix_zone("Europe/London", "GMT0BST,M3.5.0/1,M10.5.0")
    assert_equal(
        _lines(write_vtimezone("Europe/London", london, from_utc)),
        "BEGIN:VTIMEZONE\nTZID:Europe/London\n"
        + "BEGIN:STANDARD\nDTSTART:20291028T020000\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\nTZNAME:GMT\n"
        + "TZOFFSETFROM:+0100\nTZOFFSETTO:+0000\nEND:STANDARD\n"
        + "BEGIN:DAYLIGHT\nDTSTART:20300331T010000\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\nTZNAME:BST\n"
        + "TZOFFSETFROM:+0000\nTZOFFSETTO:+0100\nEND:DAYLIGHT\n"
        + "END:VTIMEZONE\n",
    )
    # Southern hemisphere rules (daylight time spans the new year): the two
    # observances are written in the order of their first onsets in the span.
    var sydney = posix_zone("Australia/Sydney", "AEST-10AEDT,M10.1.0,M4.1.0/3")
    assert_equal(
        _lines(write_vtimezone("Australia/Sydney", sydney, from_utc)),
        "BEGIN:VTIMEZONE\nTZID:Australia/Sydney\n"
        + "BEGIN:DAYLIGHT\nDTSTART:20291007T020000\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=1SU\nTZNAME:AEDT\n"
        + "TZOFFSETFROM:+1000\nTZOFFSETTO:+1100\nEND:DAYLIGHT\n"
        + "BEGIN:STANDARD\nDTSTART:20300407T030000\nRRULE:FREQ=YEARLY;BYMONTH=4;BYDAY=1SU\nTZNAME:AEST\n"
        + "TZOFFSETFROM:+1100\nTZOFFSETTO:+1000\nEND:STANDARD\n"
        + "END:VTIMEZONE\n",
    )
    # Footer rules not in the Mm.w.d form (Jn): every change is written as
    # its own observance, one year before `from_utc` to 100 years after:
    # 27 October 2029 to 1 March 2130, 101 of each kind, no RRULE.
    var julian = write_vtimezone("Test/Julian", posix_zone("Test/Julian", "EST5EDT,J60,J300"), from_utc)
    assert_equal(len(julian.split("BEGIN:DAYLIGHT")) - 1, 101)
    assert_equal(len(julian.split("BEGIN:STANDARD")) - 1, 101)
    assert_equal(julian.find("RRULE"), -1)
    assert_true(julian.find("BEGIN:STANDARD\r\nDTSTART:20291027T020000\r\n") >= 0)
    assert_true(julian.find("BEGIN:DAYLIGHT\r\nDTSTART:21300301T020000\r\n") >= 0)
    assert_equal(julian.find("DTSTART:21301027"), -1)
    print("  test_vtimezones PASS")


def _export_err(var events: List[IcsEvent]) raises -> String:
    try:
        _ = write_ics(events, _zones(), 0)
    except e:
        return String(e)
    raise Error("exported")


def test_refusals() raises:
    var a = List[IcsEvent]()
    a.append(IcsEvent(_ev('{"uid":"bad","start":"2030-09-02T09:00:00","timeZone":"America/New_York"}')))
    assert_equal(
        _export_err(a^),
        'ics export: event "bad": DURATION_ZERO at durationSeconds: a timed event lasts at least one second',
    )
    var b = List[IcsEvent]()
    b.append(IcsEvent(_ev('{"uid":"mars","start":"2030-09-02T09:00:00","timeZone":"Mars/Base","durationSeconds":60}')))
    assert_equal(_export_err(b^), 'ics export: event "mars": TZID "Mars/Base" names no time zone known here')
    var c = List[IcsEvent]()
    c.append(IcsEvent(_ev('{"title":"anonymous","showWithoutTime":true,"startDate":"2030-09-02","days":1}')))
    assert_equal(_export_err(c^), "ics export: an event has neither uid nor id")
    var d = List[IcsEvent]()
    var edits = List[OccurrenceOverride]()
    edits.append(_ov('{"originalStart":"2030-09-02","cancelled":true}'))
    d.append(IcsEvent(_ev('{"uid":"single","showWithoutTime":true,"startDate":"2030-09-02","days":1}'), edits^))
    assert_equal(
        _export_err(d^),
        'ics export: event "single", occurrence 2030-09-02: OVERRIDE_WITHOUT_RECURRENCE at eventId: '
        + "only a recurring event has occurrences to edit",
    )
    print("  test_refusals PASS")


def _round_trip(var events: List[IcsEvent]) raises:
    var text = write_ics(events, _zones(), _stamp()).text.copy()
    var back = read_ics(text.as_bytes(), _zones())
    var report = String()
    for r in back.report.refused:
        report += String(r) + "\n"
    for x in back.report.dropped:
        report += String(x) + "\n"
    assert_equal(report, "", "report of the re-import")
    assert_equal(len(back.events), len(events))
    for i in range(len(events)):
        assert_equal(encode_json(back.events[i].event), encode_json(events[i].event))
        assert_equal(len(back.events[i].overrides), len(events[i].overrides))
        for k in range(len(events[i].overrides)):
            assert_equal(encode_json(back.events[i].overrides[k]), encode_json(events[i].overrides[k]))


def test_round_trip() raises:
    var events = _events()
    # The UTC event has no uid: its id is written as the UID, and is read
    # back as the uid.
    events[2].event.uid = "evt-3"
    events[2].event.id = ""
    _round_trip(events^)
    var more = List[IcsEvent]()
    var long_title = String()
    for _ in range(12):
        long_title += "Ünïcødé "
    more.append(
        IcsEvent(
            _ev(
                '{"uid":"long","title":"' + long_title + '","description":"a\\\\b; c, d\\nnext line\\n",'
                + '"start":"2030-03-31T00:30:00","timeZone":"Europe/London","durationSeconds":7200,'
                + '"recurrence":{"freq":"DAILY","interval":3,"until":"2030-04-30"},"reminders":[{"minutesBefore":0}]}'
            )
        )
    )
    var edits = List[OccurrenceOverride]()
    edits.append(_ov('{"originalStart":"2030-04-03T00:30:00","durationSeconds":3600,"location":"Elsewhere"}'))
    edits.append(_ov('{"originalStart":"2030-04-06T00:30:00","description":"changed"}'))
    more.append(
        IcsEvent(
            _ev(
                '{"uid":"kathmandu","title":"Stand-up","start":"2030-09-02T09:15:00","timeZone":"Asia/Kathmandu",'
                + '"durationSeconds":900,"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":2,"until":"2031-09-02"}}'
            )
        )
    )
    more.append(
        IcsEvent(
            _ev(
                '{"uid":"edits","title":"Edited","start":"2030-04-01T00:30:00","timeZone":"Europe/London",'
                + '"durationSeconds":1800,"recurrence":{"freq":"DAILY","interval":1,"count":10}}'
            ),
            edits^,
        )
    )
    more.append(
        IcsEvent(
            _ev(
                '{"uid":"yearly","title":"Birthday","showWithoutTime":true,"startDate":"2032-02-29","days":1,'
                + '"recurrence":{"freq":"YEARLY","interval":1,"until":"2040-03-01"},"reminders":[{"minutesBefore":40320}]}'
            )
        )
    )
    # A third London event starting before the other two: London's
    # VTIMEZONE covers a year before it, so its first DAYLIGHT onset is 25
    # March 2029 (from the first London event it would be 31 March 2030).
    more.append(
        IcsEvent(
            _ev('{"uid":"early","title":"Early","start":"2030-01-15T08:00:00","timeZone":"Europe/London","durationSeconds":600}')
        )
    )
    var text = write_ics(more, _zones(), _stamp()).text.copy()
    assert_true(text.find("TZID:Europe/London\r\nBEGIN:DAYLIGHT\r\nDTSTART:20290325T010000\r\n") >= 0)
    _round_trip(more^)
    print("  test_round_trip PASS")


def test_fold() raises:
    # A title longer than one line is folded at 75 octets without cutting a
    # character in two, and every physical line is at most 75 octets.
    var title = String()
    for _ in range(40):
        title += "é"
    var events = List[IcsEvent]()
    events.append(IcsEvent(_ev('{"uid":"f","title":"' + title + '","showWithoutTime":true,"startDate":"2030-09-02","days":1}')))
    var text = write_ics(events, _zones(), _stamp()).text.copy()
    var longest = 0
    for line in text.split("\r\n"):
        if line.byte_length() > longest:
            longest = line.byte_length()
    assert_true(longest <= 75, "a line of " + String(longest) + " octets")
    assert_true(text.find("SUMMARY:éé") >= 0)
    assert_true(text.find("\r\n é") >= 0)
    var back = read_ics(text.as_bytes(), _zones())
    assert_equal(back.events[0].event.title, title)
    print("  test_fold PASS")


def main() raises:
    print("test_write")
    test_golden()
    test_vtimezones()
    test_refusals()
    test_round_trip()
    test_fold()
    print("ALL TESTS PASS")
