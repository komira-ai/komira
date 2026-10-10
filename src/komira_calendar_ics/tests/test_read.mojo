# =============================================================================
# test_read.mojo -- read_ics: the whole-file refusals, each event's mapping,
# the report, the refusals of single events, and one-occurrence edits.
#
# Every refusal and every report line is asserted as exact text (code, line,
# UID, message; component, name, detail, count, first line), so a check that
# is dropped (an unknown TZID read as UTC, a property dropped without a
# report line, a floating time accepted) turns its row red, and so does a
# line number that drifts. Each kept event is asserted as the API's JSON
# (`encode_json`), so a value read into the wrong field is caught.
#
# Zones are built from POSIX TZ strings (komira_datetime.posix_zone): New York and
# London with today's rules, Kathmandu at +05:45. The dates are in 2030:
# 2 November 2030 is a Saturday, and New York leaves daylight time on
# Sunday 3 November.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import encode_json
from komira_datetime import posix_zone
from komira_calendar_ics import IcsImport, IcsLimits, IcsReport, ZoneTable, read_ics


def _zones() raises -> ZoneTable:
    var t = ZoneTable()
    t.add(posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))
    t.add(posix_zone("Europe/London", "GMT0BST,M3.5.0/1,M10.5.0"))
    t.add(posix_zone("Asia/Kathmandu", "<+0545>-5:45"))
    return t^


def _ics(body: String) -> String:
    """Lines 1-3 are the VCALENDAR header; `body` starts on line 4."""
    return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example//test//EN\r\n" + body + "END:VCALENDAR\r\n"


def _read(text: String) raises -> IcsImport:
    return read_ics(text.as_bytes(), _zones())


def _err(text: String, limits: IcsLimits = IcsLimits()) raises -> String:
    try:
        _ = read_ics(text.as_bytes(), _zones(), limits)
    except e:
        return String(e)
    raise Error("accepted: " + text)


def _report(rep: IcsReport) -> String:
    var out = String()
    for r in rep.refused:
        out += String(r) + "\n"
    for d in rep.dropped:
        out += String(d) + "\n"
    return out^


def _event(got: IcsImport, i: Int) raises -> String:
    return encode_json(got.events[i].event)


def test_file_refusals() raises:
    assert_equal(_err(""), "ics: the input holds no BEGIN:VCALENDAR")
    assert_equal(
        _err("BEGIN:VEVENT\r\nEND:VEVENT\r\n"),
        "ics: line 1: the input starts with BEGIN:VEVENT, not BEGIN:VCALENDAR",
    )
    assert_equal(
        _err("PRODID:x\r\nBEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"),
        "ics: line 1: property PRODID before BEGIN:VCALENDAR",
    )
    assert_equal(_err("END:VCALENDAR\r\n"), "ics: line 1: END:VCALENDAR closes no component")
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nEND:VCALENDAR\r\n"),
        "ics: line 4: END:VCALENDAR closes BEGIN:VEVENT of line 3",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n"),
        "ics: BEGIN:VEVENT of line 3 has no END:VEVENT",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\nBEGIN:VCALENDAR\r\n"),
        "ics: line 4: BEGIN:VCALENDAR after the END of the VCALENDAR; an input holds one VCALENDAR",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\nX-FOO:1\r\n"),
        "ics: line 4: property X-FOO after the END of the VCALENDAR",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nPRODID:x\r\nEND:VCALENDAR\r\n"),
        "ics: the VCALENDAR of line 1 has no VERSION",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:1.0\r\nEND:VCALENDAR\r\n"),
        'ics: line 2: VERSION is "1.0"; only iCalendar 2.0 (RFC 5545) is read',
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"),
        "ics: line 3: VERSION appears more than once",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nCALSCALE:ISLAMIC-CIVIL\r\nEND:VCALENDAR\r\n"),
        "ics: line 3: CALSCALE:ISLAMIC-CIVIL is not read; only GREGORIAN is",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"),
        "ics: line 3: METHOD:REQUEST is a scheduling message (iTIP); only a published calendar is imported",
    )
    var deep = String("BEGIN:VCALENDAR\r\n")
    for _ in range(8):
        deep += "BEGIN:X-A\r\n"
    assert_equal(_err(deep), "ics: line 9: BEGIN:X-A nests deeper than 8 components")
    assert_equal(
        _err(
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
            IcsLimits(max_components=2),
        ),
        "ics: line 5: more than 2 components",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION\r\nEND:VCALENDAR\r\n"),
        "content line: line 2 has no ':' after the property name",
    )
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n", IcsLimits(max_input_octets=10)),
        "content line: input is 45 octets; the limit is 10",
    )
    print("  test_file_refusals PASS")


def _with_byte(prefix: String, byte: UInt8, rest: String) -> List[UInt8]:
    var out = List[UInt8]()
    for c in prefix.as_bytes():
        out.append(c)
    out.append(byte)
    for c in rest.as_bytes():
        out.append(c)
    return out^


comptime _HEAD = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:u\r\nDTSTART;VALUE=DATE:20301104\r\n"
comptime _TAIL = "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"


def test_utf8() raises:
    # A fold between the two octets of "é" (0xC3 0xA9) is joined before the
    # line is checked, so the title is whole.
    var text = String(_HEAD) + "SUMMARY:café crème" + _TAIL
    var split = List[UInt8]()
    var b = text.as_bytes()
    var done = False
    for i in range(len(b)):
        split.append(b[i])
        if b[i] == UInt8(0xC3) and not done:
            split.append(UInt8(13))
            split.append(UInt8(10))
            split.append(UInt8(32))
            done = True
    var got = read_ics(Span(split), _zones())
    assert_equal(got.events[0].event.title, "café crème")
    assert_true(got.report.is_clean())
    # Invalid UTF-8 refuses the whole input, naming the line and the octet.
    var bad = _with_byte(_HEAD + "SUMMARY:caf", UInt8(0xFF), _TAIL)
    var msg = String()
    try:
        _ = read_ics(Span(bad), _zones())
    except e:
        msg = String(e)
    assert_equal(msg, "content line: line 6 is not valid UTF-8 (octet 11 of the unfolded line)")
    print("  test_utf8 PASS")


comptime MAPPING = (
    "BEGIN:VTIMEZONE\r\n"  # 4
    + "TZID:Eastern Standard Time\r\n"
    + "X-LIC-LOCATION:America/New_York\r\n"
    + "END:VTIMEZONE\r\n"
    + "BEGIN:VEVENT\r\n"  # 8
    + "UID:allday-3\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "DTEND;VALUE=DATE:20301107\r\n"
    + "SUMMARY:Offsite\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 14
    + "UID:allday-1\r\n"
    + "DTSTART;VALUE=DATE:20301225\r\n"
    + "SUMMARY:Holiday\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 19
    + "UID:allday-dur\r\n"
    + "DTSTART:20301228\r\n"
    + "DURATION:P2D\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 24
    + "UID:ny\r\n"
    + "DTSTAMP:20301001T000000Z\r\n"
    + "DTSTART;TZID=America/New_York:20301102T093000\r\n"
    + "DTEND;TZID=America/New_York:20301102T110000\r\n"
    + "SUMMARY:Review\\, part 2\r\n"
    + "LOCATION:Room 4\r\n"
    + "DESCRIPTION:Line one\\nLine two\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 33
    + "UID:utc\r\n"
    + "DTSTART:20301102T140000Z\r\n"
    + "DURATION:PT45M\r\n"
    + "STATUS:CANCELLED\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 39
    + "UID:flight\r\n"
    + "DTSTART;TZID=America/New_York:20301102T180000\r\n"
    + "DTEND;TZID=Europe/London:20301103T060000\r\n"
    + "SUMMARY:Flight\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 45
    + "UID:alias\r\n"
    + "DTSTART;TZID=Eastern Standard Time:20301105T080000\r\n"
    + "DURATION:P1DT1H\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 50
    + "UID:dst-day\r\n"
    + "DTSTART;TZID=America/New_York:20301102T120000\r\n"
    + "DURATION:P1D\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 55
    + "UID:weekly\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"
    + "DTEND;TZID=America/New_York:20300902T093000\r\n"
    + "RRULE:FREQ=WEEKLY;BYDAY=MO,TH;UNTIL=20301229T140000Z\r\n"
    + "EXDATE;TZID=America/New_York:20300905T090000,20300912T090000\r\n"
    + "EXDATE:20300919T130000Z\r\n"
    + "EXDATE;TZID=America/New_York:20300905T090000\r\n"
    + "SUMMARY:Sync\r\n"
    + "BEGIN:VALARM\r\n"
    + "ACTION:DISPLAY\r\n"
    + "DESCRIPTION:Sync\r\n"
    + "TRIGGER:-PT10M\r\n"
    + "END:VALARM\r\n"
    + "END:VEVENT\r\n"
)


def test_mapping() raises:
    var got = _read(_ics(MAPPING))
    assert_equal(_report(got.report), "")
    assert_equal(len(got.events), 9)
    assert_equal(
        _event(got, 0),
        '{"uid":"allday-3","title":"Offsite","showWithoutTime":true,"startDate":"2030-11-04","days":3}',
    )
    assert_equal(
        _event(got, 1),
        '{"uid":"allday-1","title":"Holiday","showWithoutTime":true,"startDate":"2030-12-25","days":1}',
    )
    assert_equal(_event(got, 2), '{"uid":"allday-dur","showWithoutTime":true,"startDate":"2030-12-28","days":2}')
    assert_equal(
        _event(got, 3),
        '{"uid":"ny","title":"Review, part 2","description":"Line one\\nLine two","location":"Room 4",'
        + '"start":"2030-11-02T09:30:00","timeZone":"America/New_York","durationSeconds":5400}',
    )
    assert_equal(
        _event(got, 4),
        '{"uid":"utc","start":"2030-11-02T14:00:00","timeZone":"UTC","durationSeconds":2700,"status":"CANCELLED"}',
    )
    # 18:00 EDT (22:00Z) to 06:00 GMT (06:00Z): eight hours.
    assert_equal(
        _event(got, 5),
        '{"uid":"flight","title":"Flight","start":"2030-11-02T18:00:00","timeZone":"America/New_York","durationSeconds":28800}',
    )
    # The TZID is mapped through the VTIMEZONE's X-LIC-LOCATION.
    assert_equal(
        _event(got, 6),
        '{"uid":"alias","start":"2030-11-05T08:00:00","timeZone":"America/New_York","durationSeconds":90000}',
    )
    # P1D is a day on the wall clock: 12:00 EDT to 12:00 EST is 25 hours.
    assert_equal(
        _event(got, 7),
        '{"uid":"dst-day","start":"2030-11-02T12:00:00","timeZone":"America/New_York","durationSeconds":90000}',
    )
    # UNTIL 14:00Z on 29 December is 09:00 EST, the last start; the UTC
    # EXDATE is 09:00 EDT; the repeated EXDATE counts once.
    assert_equal(
        _event(got, 8),
        '{"uid":"weekly","title":"Sync","start":"2030-09-02T09:00:00","timeZone":"America/New_York",'
        + '"durationSeconds":1800,"recurrence":{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY","THURSDAY"],'
        + '"until":"2030-12-29"},"exdates":["2030-09-05T09:00:00","2030-09-12T09:00:00","2030-09-19T09:00:00"],'
        + '"reminders":[{"minutesBefore":10}]}',
    )
    print("  test_mapping PASS")


def _until_of(rule: String, start: String) raises -> String:
    var body = (
        "BEGIN:VEVENT\r\nUID:u\r\n" + start + "\r\n"
        + ("" if start.find("VALUE=DATE") >= 0 else "DURATION:PT30M\r\n")
        + "RRULE:" + rule + "\r\nEND:VEVENT\r\n"
    )
    var got = _read(_ics(body))
    if len(got.events) != 1:
        raise Error(rule + ": " + _report(got.report))
    return got.events[0].event.recurrence.value().until.copy()


def test_until() raises:
    var ny = String("DTSTART;TZID=America/New_York:20300902T090000")
    assert_equal(_until_of("FREQ=DAILY;UNTIL=20301229T140000Z", ny), "2030-12-29")
    assert_equal(_until_of("FREQ=DAILY;UNTIL=20301229T135959Z", ny), "2030-12-28")
    assert_equal(_until_of("FREQ=DAILY;UNTIL=20301229T090000", ny), "2030-12-29")
    assert_equal(_until_of("FREQ=DAILY;UNTIL=20301229T085959", ny), "2030-12-28")
    assert_equal(_until_of("FREQ=DAILY;UNTIL=20301229", ny), "2030-12-29")
    # +05:45: 19:15Z on 28 December is 01:00 on the 29th, the last start;
    # its UTC date is the 28th.
    assert_equal(
        _until_of("FREQ=DAILY;UNTIL=20301228T191500Z", "DTSTART;TZID=Asia/Kathmandu:20300902T010000"),
        "2030-12-29",
    )
    assert_equal(
        _until_of("FREQ=YEARLY;UNTIL=20351231T235959Z", "DTSTART;VALUE=DATE:20300902"),
        "2035-12-31",
    )
    print("  test_until PASS")


comptime REPORTED = (
    "CALSCALE:GREGORIAN\r\n"  # 4
    + "METHOD:PUBLISH\r\n"
    + "X-WR-CALNAME:Work\r\n"  # 6
    + "BEGIN:VEVENT\r\n"  # 7
    + "UID:r1\r\n"
    + "DTSTAMP:20300901T000000Z\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"  # 10
    + "DTEND;TZID=America/New_York:20300902T100000\r\n"
    + "SUMMARY;LANGUAGE=en:Planning\r\n"  # 12
    + "ORGANIZER:mailto:a@example.com\r\n"
    + "ATTENDEE:mailto:b@example.com\r\n"  # 14
    + "ATTENDEE:mailto:c@example.com\r\n"
    + "STATUS:TENTATIVE\r\n"  # 16
    + "RDATE;TZID=America/New_York:20300910T090000\r\n"
    + "X-FOO:bar\r\n"  # 18
    + "BEGIN:VALARM\r\n"
    + "ACTION:EMAIL\r\n"  # 20
    + "TRIGGER:-PT15M\r\n"
    + "DESCRIPTION:Planning\r\n"  # 22
    + "SUMMARY:mail\r\n"
    + "END:VALARM\r\n"  # 24
    + "BEGIN:VALARM\r\n"
    + "ACTION:DISPLAY\r\n"  # 26
    + "TRIGGER;VALUE=DATE-TIME:20300902T120000Z\r\n"
    + "END:VALARM\r\n"  # 28
    + "BEGIN:VALARM\r\n"
    + "TRIGGER;RELATED=END:-PT5M\r\n"  # 30
    + "END:VALARM\r\n"
    + "BEGIN:VALARM\r\n"  # 32
    + "ACTION:DISPLAY\r\n"
    + "TRIGGER:-PT15M\r\n"  # 34
    + "DESCRIPTION:Something else\r\n"
    + "END:VALARM\r\n"  # 36
    + "BEGIN:VALARM\r\n"
    + "ACTION:AUDIO\r\n"  # 38
    + "TRIGGER:PT5M\r\n"
    + "END:VALARM\r\n"  # 40
    + "BEGIN:VALARM\r\n"
    + "TRIGGER:-PT30S\r\n"  # 42
    + "END:VALARM\r\n"
    + "BEGIN:VALARM\r\n"  # 44
    + "ACTION:DISPLAY\r\n"
    + "TRIGGER:-P1D\r\n"  # 46
    + "REPEAT:2\r\n"
    + "DURATION:PT5M\r\n"  # 48
    + "END:VALARM\r\n"
    + "BEGIN:VALARM\r\n"  # 50
    + "ACTION:DISPLAY\r\n"
    + "END:VALARM\r\n"  # 52
    + "END:VEVENT\r\n"
)


def test_report() raises:
    var got = _read(_ics(REPORTED))
    assert_equal(
        _event(got, 0),
        '{"uid":"r1","title":"Planning","start":"2030-09-02T09:00:00","timeZone":"America/New_York",'
        + '"durationSeconds":3600,"reminders":[{"minutesBefore":15},{"minutesBefore":1440}]}',
    )
    assert_equal(
        _report(got.report),
        "VCALENDAR X-WR-CALNAME x1 from line 6\n"
        + "VEVENT STATUS (TENTATIVE is read as CONFIRMED) x1 from line 16\n"
        + "VALARM ACTION (EMAIL, read as a reminder to the owner) x1 from line 20\n"
        + "VALARM SUMMARY x1 from line 23\n"
        + "VALARM TRIGGER (an absolute time) x1 from line 27\n"
        + "VALARM TRIGGER (relative to the end) x1 from line 30\n"
        + "VALARM DESCRIPTION x1 from line 35\n"
        + "VALARM VALARM (repeats an earlier reminder) x1 from line 32\n"
        + "VALARM ACTION (AUDIO, read as a reminder to the owner) x1 from line 38\n"
        + "VALARM TRIGGER (after the start) x1 from line 39\n"
        + "VALARM TRIGGER (not whole minutes) x1 from line 42\n"
        + "VALARM REPEAT x1 from line 47\n"
        + "VALARM DURATION x1 from line 48\n"
        + "VALARM VALARM (no TRIGGER) x1 from line 50\n"
        + "VEVENT SUMMARY;LANGUAGE x1 from line 12\n"
        + "VEVENT ORGANIZER x1 from line 13\n"
        + "VEVENT ATTENDEE x2 from line 14\n"
        + "VEVENT RDATE x1 from line 17\n"
        + "VEVENT X-FOO x1 from line 18\n",
    )
    print("  test_report PASS")


comptime REFUSED = (
    "BEGIN:VEVENT\r\n"  # 4
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 7
    + "UID:no-start\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 10
    + "UID:floating\r\n"
    + "DTSTART:20301104T090000\r\n"
    + "DURATION:PT1H\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 15
    + "UID:unknown-tz\r\n"
    + "DTSTART;TZID=Mars/Olympus_Mons:20301104T090000\r\n"
    + "DURATION:PT1H\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 20
    + "UID:both-ends\r\n"
    + "DTSTART;TZID=Europe/London:20301104T090000\r\n"
    + "DTEND;TZID=Europe/London:20301104T100000\r\n"
    + "DURATION:PT1H\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 26
    + "UID:mixed\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "DTEND;TZID=Europe/London:20301104T100000\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 31
    + "UID:backwards\r\n"
    + "DTSTART;TZID=Europe/London:20301104T100000\r\n"
    + "DTEND;TZID=Europe/London:20301104T100000\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 36
    + "UID:no-end\r\n"
    + "DTSTART;TZID=Europe/London:20301104T100000\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 40
    + "UID:hourly\r\n"
    + "DTSTART;TZID=Europe/London:20301104T100000\r\n"
    + "DURATION:PT1H\r\n"
    + "RRULE:FREQ=HOURLY\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 46
    + "UID:two-rules\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "RRULE:FREQ=DAILY\r\n"
    + "RRULE:FREQ=WEEKLY\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 52
    + "UID:twice\r\n"
    + "SUMMARY:a\r\n"
    + "SUMMARY:b\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 58
    + "UID:bad-date\r\n"
    + "DTSTART;VALUE=DATE:20301132\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 62
    + "UID:two-lines\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "SUMMARY:one\\ntwo\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VTODO\r\n"  # 67
    + "UID:todo-1\r\n"
    + "SUMMARY:Task\r\n"
    + "END:VTODO\r\n"
    + "BEGIN:VEVENT\r\n"  # 71
    + "UID:kept\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "BEGIN:VTODO\r\n"  # 74
    + "END:VTODO\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 77
    + "UID:kept\r\n"
    + "DTSTART;VALUE=DATE:20301105\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VFREEBUSY\r\n"  # 81
    + "END:VFREEBUSY\r\n"
    + "BEGIN:VEVENT\r\n"  # 83
    + "UID:alias-unknown\r\n"
    + "DTSTART;TZID=Custom:20301104T090000\r\n"
    + "DURATION:PT1H\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VTIMEZONE\r\n"  # 88
    + "TZID:Custom\r\n"
    + "X-LIC-LOCATION:Mars/Base\r\n"
    + "END:VTIMEZONE\r\n"
    + "BEGIN:VEVENT\r\n"  # 92
    + "UID:dur-days\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "DURATION:PT12H\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 97
    + "UID:negative\r\n"
    + "DTSTART;TZID=Europe/London:20301104T100000\r\n"
    + "DURATION:-PT1H\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 102
    + "UID:exdate-form\r\n"
    + "DTSTART;TZID=Europe/London:20301104T100000\r\n"
    + "DURATION:PT1H\r\n"
    + "RRULE:FREQ=DAILY\r\n"
    + "EXDATE;VALUE=DATE:20301105\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 109
    + "UID:too-long\r\n"
    + "DTSTART;TZID=Europe/London:20301104T100000\r\n"
    + "DURATION:P367D\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 114
    + "UID:six\r\n"
    + "DTSTART;VALUE=DATE:20301201\r\n"
    + "BEGIN:VALARM\r\nTRIGGER:-PT1M\r\nEND:VALARM\r\n"  # 117
    + "BEGIN:VALARM\r\nTRIGGER:-PT2M\r\nEND:VALARM\r\n"  # 120
    + "BEGIN:VALARM\r\nTRIGGER:-PT3M\r\nEND:VALARM\r\n"  # 123
    + "BEGIN:VALARM\r\nTRIGGER:-PT4M\r\nEND:VALARM\r\n"  # 126
    + "BEGIN:VALARM\r\nTRIGGER:-PT5M\r\nEND:VALARM\r\n"  # 129
    + "BEGIN:VALARM\r\nTRIGGER:-PT6M\r\nEND:VALARM\r\n"  # 132
    + "EXDATE;VALUE=DATE:20301202\r\n"  # 135
    + "END:VEVENT\r\n"
)


def test_refusals() raises:
    var got = _read(_ics(REFUSED))
    assert_equal(
        _report(got.report),
        'UID_MISSING at line 4 (UID ""): the VEVENT has no UID\n'
        + 'DTSTART_MISSING at line 7 (UID "no-start"): the VEVENT has no DTSTART\n'
        + 'FLOATING_TIME at line 10 (UID "floating"): DTSTART "20301104T090000" is a floating time (no TZID, no Z); the calendar keeps zoned times only\n'
        + 'UNKNOWN_TZID at line 15 (UID "unknown-tz"): TZID "Mars/Olympus_Mons" names no time zone known here\n'
        + 'END_AND_DURATION at line 20 (UID "both-ends"): DTEND and DURATION are both given; RFC 5545 allows one\n'
        + "FORM_MISMATCH at line 26 (UID \"mixed\"): DTEND is a DATE-TIME but the event's DTSTART is a DATE\n"
        + "NOT_AFTER_START at line 31 (UID \"backwards\"): the event's end is not after its start\n"
        + 'NOT_AFTER_START at line 36 (UID "no-end"): a timed event with neither DTEND nor DURATION lasts no time; the calendar needs at least one second\n'
        + 'RRULE_OUT_OF_SUBSET at line 40 (UID "hourly"): RRULE FREQ=HOURLY is outside the subset (DAILY, WEEKLY, MONTHLY, YEARLY)\n'
        + 'RRULE_OUT_OF_SUBSET at line 46 (UID "two-rules"): the VEVENT has 2 RRULEs; the subset keeps one\n'
        + 'PROPERTY_REPEATED at line 52 (UID "twice"): SUMMARY appears more than once\n'
        + 'VALUE_MALFORMED at line 58 (UID "bad-date"): DTSTART "20301132" names no day: day 32 does not exist in month 11 of year 2030\n'
        + 'TEXT_CONTROL_CHARACTER at line 62 (UID "two-lines"): the event breaks the calendar model at title: title holds control character 0xa at byte 3\n'
        + 'COMPONENT_OUT_OF_SUBSET at line 67 (UID "todo-1"): VTODO is outside the subset: only VEVENT (with VALARM) and VTIMEZONE are read\n'
        + 'COMPONENT_OUT_OF_SUBSET at line 74 (UID ""): VTODO inside a VEVENT is outside the subset (only VALARM is read there)\n'
        + 'UID_DUPLICATE at line 77 (UID "kept"): an earlier VEVENT has UID "kept"\n'
        + 'COMPONENT_OUT_OF_SUBSET at line 81 (UID ""): VFREEBUSY is outside the subset: only VEVENT (with VALARM) and VTIMEZONE are read\n'
        + 'UNKNOWN_TZID at line 83 (UID "alias-unknown"): TZID "Custom" names no time zone known here, nor does its VTIMEZONE\'s X-LIC-LOCATION "Mars/Base"\n'
        + 'FORM_MISMATCH at line 92 (UID "dur-days"): DURATION "PT12H" of an all-day event is not whole days\n'
        + 'NOT_AFTER_START at line 97 (UID "negative"): DURATION "-PT1H" is negative\n'
        + "FORM_MISMATCH at line 102 (UID \"exdate-form\"): EXDATE is a DATE but the event's DTSTART is a DATE-TIME\n"
        + 'DURATION_TOO_LONG at line 109 (UID "too-long"): the event lasts 31708800 seconds; at most 31622400 are allowed\n'
        + "VEVENT EXDATE (on an event that does not recur) x1 from line 135\n"
        + "VALARM VALARM (past the 5 reminders an event keeps) x1 from line 132\n",
    )
    assert_equal(len(got.events), 2)
    assert_equal(_event(got, 0), '{"uid":"kept","showWithoutTime":true,"startDate":"2030-11-04","days":1}')
    assert_equal(
        _event(got, 1),
        '{"uid":"six","showWithoutTime":true,"startDate":"2030-12-01","days":1,"reminders":'
        + '[{"minutesBefore":1},{"minutesBefore":2},{"minutesBefore":3},{"minutesBefore":4},{"minutesBefore":5}]}',
    )
    print("  test_refusals PASS")


comptime EDITS = (
    "BEGIN:VEVENT\r\n"  # 4
    + "UID:series\r\n"
    + "DTSTART;TZID=America/New_York:20300902T090000\r\n"
    + "DTEND;TZID=America/New_York:20300902T100000\r\n"
    + "RRULE:FREQ=WEEKLY;BYDAY=MO\r\n"
    + "SUMMARY:Standup\r\n"
    + "LOCATION:Room 1\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 12
    + "UID:series\r\n"
    + "RECURRENCE-ID;TZID=America/New_York:20300909T090000\r\n"
    + "DTSTART;TZID=Europe/London:20300909T150000\r\n"
    + "DTEND;TZID=Europe/London:20300909T163000\r\n"
    + "SUMMARY:Standup\r\n"
    + "LOCATION:Room 2\r\n"
    + "BEGIN:VALARM\r\n"  # 19
    + "TRIGGER:-PT5M\r\n"
    + "END:VALARM\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 23
    + "UID:series\r\n"
    + "RECURRENCE-ID:20300916T130000Z\r\n"
    + "STATUS:CANCELLED\r\n"
    + "DTSTART:20300916T130000Z\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 29
    + "UID:series\r\n"
    + "RECURRENCE-ID;TZID=America/New_York:20300923T090000\r\n"
    + "DTSTART;TZID=America/New_York:20300923T090000\r\n"
    + "DTEND;TZID=America/New_York:20300923T100000\r\n"
    + "SUMMARY:Standup\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 36
    + "UID:series\r\n"
    + "RECURRENCE-ID;TZID=America/New_York:20300909T090000\r\n"
    + "SUMMARY:Again\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 41
    + "UID:orphan\r\n"
    + "RECURRENCE-ID;TZID=America/New_York:20300909T090000\r\n"
    + "DTSTART;TZID=America/New_York:20300909T090000\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 46
    + "UID:series\r\n"
    + "RECURRENCE-ID;RANGE=THISANDFUTURE;TZID=America/New_York:20300930T090000\r\n"
    + "SUMMARY:Later\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 51
    + "UID:series\r\n"
    + "RECURRENCE-ID;VALUE=DATE:20301007\r\n"
    + "SUMMARY:x\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 56
    + "UID:series\r\n"
    + "RECURRENCE-ID;TZID=America/New_York:20301014T090000\r\n"
    + "SUMMARY:Retro\r\n"
    + "RRULE:FREQ=DAILY\r\n"  # 60
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 62
    + "UID:single\r\n"
    + "DTSTART;VALUE=DATE:20301104\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 66
    + "UID:single\r\n"
    + "RECURRENCE-ID;VALUE=DATE:20301104\r\n"
    + "SUMMARY:x\r\n"
    + "END:VEVENT\r\n"
)


def test_edits() raises:
    var got = _read(_ics(EDITS))
    assert_equal(
        _report(got.report),
        'OVERRIDE_DUPLICATE at line 36 (UID "series"): the occurrence 2030-09-09T09:00:00 is edited twice\n'
        + 'OVERRIDE_WITHOUT_SERIES at line 41 (UID "orphan"): RECURRENCE-ID edits an occurrence of UID "orphan", and no recurring event of that UID was imported\n'
        + 'RANGE_OUT_OF_SUBSET at line 46 (UID "series"): RECURRENCE-ID;RANGE=THISANDFUTURE edits this and later occurrences; only one occurrence is edited here\n'
        + "FORM_MISMATCH at line 51 (UID \"series\"): RECURRENCE-ID is a DATE but the event's DTSTART is a DATE-TIME\n"
        + 'OVERRIDE_WITHOUT_SERIES at line 66 (UID "single"): RECURRENCE-ID edits an occurrence of UID "single", and no recurring event of that UID was imported\n'
        + "VEVENT VALARM (on an occurrence edit, which keeps its series' reminders) x1 from line 19\n"
        + "VEVENT RECURRENCE-ID (an occurrence edit that changes nothing) x1 from line 29\n"
        + "VEVENT RRULE (on an occurrence edit) x1 from line 60\n",
    )
    assert_equal(len(got.events), 2)
    ref edits = got.events[0].overrides
    assert_equal(len(edits), 3)
    # 15:00 BST is 10:00 EDT; 15:00 to 16:30 is 5400 seconds.
    assert_equal(
        encode_json(edits[0]),
        '{"originalStart":"2030-09-09T09:00:00","start":"2030-09-09T10:00:00","durationSeconds":5400,"location":"Room 2"}',
    )
    assert_equal(encode_json(edits[1]), '{"originalStart":"2030-09-16T09:00:00","cancelled":true}')
    assert_equal(encode_json(edits[2]), '{"originalStart":"2030-10-14T09:00:00","title":"Retro"}')
    assert_equal(len(got.events[1].overrides), 0)
    print("  test_edits PASS")


def main() raises:
    print("test_read")
    test_file_refusals()
    test_utf8()
    test_mapping()
    test_until()
    test_report()
    test_refusals()
    test_edits()
    print("ALL TESTS PASS")
