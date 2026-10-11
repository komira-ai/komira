# =============================================================================
# test_rfc5545.mojo -- komira_calendar_ics against the examples of RFC 5545.
#
#   §3.6.1  the four VEVENT examples, in one VCALENDAR: UTC times, an
#           all-day yearly event, an eleven-day event; CLASS, CATEGORIES and
#           TRANSP reported dropped
#   §4      the five iCalendar objects: the conference (a folded
#           DESCRIPTION with escapes, ORGANIZER dropped), the zoned review
#           meeting with its VTIMEZONE (ATTENDEE, CREATED ... dropped), and
#           the VTODO, VJOURNAL and VFREEBUSY objects, each refused as out of
#           subset
#   §3.8.5.3 every RRULE example: each one the subset holds is read into the
#           structured rule (UNTIL as the last local date it allows), each
#           other refused with the reason
#   §3.6.5  the America/New_York VTIMEZONE with yearly rules, which
#           write_vtimezone writes for the 2007 rules
#
# Changed from the RFC: the §3.6.1 SUMMARY that names a person is replaced
# by "Sensitivity awareness class."; the §4 VJOURNAL DESCRIPTION is cut
# after its third item (the rest names people); LAST-MODIFIED is left out of
# the §3.6.5 VTIMEZONE (the writer does not write it). The RFC shows bare
# VEVENTs in §3.6.1 and §3.8.5.3; they are wrapped in a VCALENDAR here.
# The 1990s examples are read with New York's rules of those years
# (rfc_zones).
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import encode_json
from komira_calendar_ics import read_ics
from komira_calendar_ics.vtimezone import write_vtimezone
from komira_datetime import seconds_from_fields
from komira_datetime import posix_zone
from komira_calendar_ics_conformance import crlf, events_text, report_text, rfc_zones


comptime S361 = (
    "BEGIN:VCALENDAR\n"  # 1
    + "VERSION:2.0\n"
    + "PRODID:-//example//rfc5545 3.6.1//EN\n"
    + "BEGIN:VEVENT\n"  # 4
    + "UID:19970901T130000Z-123401@example.com\n"
    + "DTSTAMP:19970901T130000Z\n"
    + "DTSTART:19970903T163000Z\n"
    + "DTEND:19970903T190000Z\n"
    + "SUMMARY:Annual Employee Review\n"
    + "CLASS:PRIVATE\n"  # 10
    + "CATEGORIES:BUSINESS,HUMAN RESOURCES\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"  # 13
    + "UID:19970901T130000Z-123402@example.com\n"
    + "DTSTAMP:19970901T130000Z\n"
    + "DTSTART:19970401T163000Z\n"
    + "DTEND:19970402T010000Z\n"
    + "SUMMARY:Sensitivity awareness class.\n"
    + "CLASS:PUBLIC\n"  # 19
    + "CATEGORIES:BUSINESS,HUMAN RESOURCES\n"
    + "TRANSP:TRANSPARENT\n"  # 21
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"  # 23
    + "UID:19970901T130000Z-123403@example.com\n"
    + "DTSTAMP:19970901T130000Z\n"
    + "DTSTART;VALUE=DATE:19971102\n"
    + "SUMMARY:Our Blissful Anniversary\n"
    + "TRANSP:TRANSPARENT\n"
    + "CLASS:CONFIDENTIAL\n"
    + "CATEGORIES:ANNIVERSARY,PERSONAL,SPECIAL OCCASION\n"
    + "RRULE:FREQ=YEARLY\n"
    + "END:VEVENT\n"
    + "BEGIN:VEVENT\n"  # 33
    + "UID:20070423T123432Z-541111@example.com\n"
    + "DTSTAMP:20070423T123432Z\n"
    + "DTSTART;VALUE=DATE:20070628\n"
    + "DTEND;VALUE=DATE:20070709\n"
    + "SUMMARY:Festival International de Jazz de Montreal\n"
    + "TRANSP:TRANSPARENT\n"
    + "END:VEVENT\n"
    + "END:VCALENDAR\n"
)


def test_3_6_1_events() raises:
    var got = read_ics(crlf(S361).as_bytes(), rfc_zones())
    assert_equal(
        events_text(got),
        '{"uid":"19970901T130000Z-123401@example.com","title":"Annual Employee Review",'
        + '"start":"1997-09-03T16:30:00","timeZone":"UTC","durationSeconds":9000}\n'
        + '{"uid":"19970901T130000Z-123402@example.com","title":"Sensitivity awareness class.",'
        + '"start":"1997-04-01T16:30:00","timeZone":"UTC","durationSeconds":30600}\n'
        + '{"uid":"19970901T130000Z-123403@example.com","title":"Our Blissful Anniversary",'
        + '"showWithoutTime":true,"startDate":"1997-11-02","days":1,"recurrence":{"freq":"YEARLY","interval":1}}\n'
        + '{"uid":"20070423T123432Z-541111@example.com","title":"Festival International de Jazz de Montreal",'
        + '"showWithoutTime":true,"startDate":"2007-06-28","days":11}\n',
    )
    assert_equal(
        report_text(got.report),
        "VEVENT CLASS x3 from line 10\nVEVENT CATEGORIES x3 from line 11\nVEVENT TRANSP x3 from line 21\n",
    )
    print("  test_3_6_1_events PASS")


comptime S4_CONFERENCE = (
    "BEGIN:VCALENDAR\n"  # 1
    + "PRODID:-//xyz Corp//NONSGML PDA Calendar Version 1.0//EN\n"
    + "VERSION:2.0\n"
    + "BEGIN:VEVENT\n"  # 4
    + "DTSTAMP:19960704T120000Z\n"
    + "UID:uid1@example.com\n"
    + "ORGANIZER:mailto:jsmith@example.com\n"  # 7
    + "DTSTART:19960918T143000Z\n"
    + "DTEND:19960920T220000Z\n"
    + "STATUS:CONFIRMED\n"
    + "CATEGORIES:CONFERENCE\n"  # 11
    + "SUMMARY:Networld+Interop Conference\n"
    + "DESCRIPTION:Networld+Interop Conference\n"
    + "  and Exhibit\\nAtlanta World Congress Center\\n\n"
    + " Atlanta\\, Georgia\n"
    + "END:VEVENT\n"
    + "END:VCALENDAR\n"
)

comptime S4_REVIEW = (
    "BEGIN:VCALENDAR\n"  # 1
    + "PRODID:-//RDU Software//NONSGML HandCal//EN\n"
    + "VERSION:2.0\n"
    + "BEGIN:VTIMEZONE\n"  # 4
    + "TZID:America/New_York\n"
    + "BEGIN:STANDARD\n"
    + "DTSTART:19981025T020000\n"
    + "TZOFFSETFROM:-0400\n"
    + "TZOFFSETTO:-0500\n"
    + "TZNAME:EST\n"
    + "END:STANDARD\n"
    + "BEGIN:DAYLIGHT\n"  # 12
    + "DTSTART:19990404T020000\n"
    + "TZOFFSETFROM:-0500\n"
    + "TZOFFSETTO:-0400\n"
    + "TZNAME:EDT\n"
    + "END:DAYLIGHT\n"
    + "END:VTIMEZONE\n"
    + "BEGIN:VEVENT\n"  # 19
    + "DTSTAMP:19980309T231000Z\n"
    + "UID:guid-1.example.com\n"
    + "ORGANIZER;ROLE=CHAIR:mailto:mrbig@example.com\n"  # 22
    + "ATTENDEE;RSVP=TRUE;ROLE=REQ-PARTICIPANT;CUTYPE=GROUP:\n"  # 23
    + " mailto:employee-A@example.com\n"
    + "DESCRIPTION:Project XYZ Review Meeting\n"
    + "CATEGORIES:MEETING\n"  # 26
    + "CLASS:PUBLIC\n"
    + "CREATED:19980309T130000Z\n"
    + "SUMMARY:XYZ Project Review\n"
    + "DTSTART;TZID=America/New_York:19980312T083000\n"
    + "DTEND;TZID=America/New_York:19980312T093000\n"
    + "LOCATION:1CP Conference Room 4350\n"
    + "END:VEVENT\n"
    + "END:VCALENDAR\n"
)

comptime S4_TODO = (
    "BEGIN:VCALENDAR\n"
    + "VERSION:2.0\n"
    + "PRODID:-//ABC Corporation//NONSGML My Product//EN\n"
    + "BEGIN:VTODO\n"  # 4
    + "DTSTAMP:19980130T134500Z\n"
    + "SEQUENCE:2\n"
    + "UID:uid4@example.com\n"
    + "ORGANIZER:mailto:unclesam@example.com\n"
    + "ATTENDEE;PARTSTAT=ACCEPTED:mailto:jqpublic@example.com\n"
    + "DUE:19980415T000000\n"
    + "STATUS:NEEDS-ACTION\n"
    + "SUMMARY:Submit Income Taxes\n"
    + "BEGIN:VALARM\n"
    + "ACTION:AUDIO\n"
    + "TRIGGER:19980403T120000Z\n"
    + "ATTACH;FMTTYPE=audio/basic:http://example.com/pub/audio-\n"
    + " files/ssbanner.aud\n"
    + "REPEAT:4\n"
    + "DURATION:PT1H\n"
    + "END:VALARM\n"
    + "END:VTODO\n"
    + "END:VCALENDAR\n"
)

comptime S4_JOURNAL = (
    "BEGIN:VCALENDAR\n"
    + "VERSION:2.0\n"
    + "PRODID:-//ABC Corporation//NONSGML My Product//EN\n"
    + "BEGIN:VJOURNAL\n"  # 4
    + "DTSTAMP:19970324T120000Z\n"
    + "UID:uid5@example.com\n"
    + "ORGANIZER:mailto:jsmith@example.com\n"
    + "STATUS:DRAFT\n"
    + "CLASS:PUBLIC\n"
    + "CATEGORIES:Project Report,XYZ,Weekly Meeting\n"
    + "DESCRIPTION:Project xyz Review Meeting Minutes\\n\n"
    + " Agenda\\n1. Review of project version 1.0 requirements.\\n2.\n"
    + "  Definition\n"
    + " of project processes.\\n3. Review of project schedule.\n"
    + "END:VJOURNAL\n"
    + "END:VCALENDAR\n"
)

comptime S4_FREEBUSY = (
    "BEGIN:VCALENDAR\n"
    + "VERSION:2.0\n"
    + "PRODID:-//RDU Software//NONSGML HandCal//EN\n"
    + "BEGIN:VFREEBUSY\n"  # 4
    + "ORGANIZER:mailto:jsmith@example.com\n"
    + "DTSTART:19980313T141711Z\n"
    + "DTEND:19980410T141711Z\n"
    + "FREEBUSY:19980314T233000Z/19980315T003000Z\n"
    + "FREEBUSY:19980316T153000Z/19980316T163000Z\n"
    + "FREEBUSY:19980318T030000Z/19980318T040000Z\n"
    + "URL:http://www.example.com/calendar/busytime/jsmith.ifb\n"
    + "END:VFREEBUSY\n"
    + "END:VCALENDAR\n"
)


def test_4_objects() raises:
    var conf = read_ics(crlf(S4_CONFERENCE).as_bytes(), rfc_zones())
    assert_equal(
        events_text(conf),
        '{"uid":"uid1@example.com","title":"Networld+Interop Conference",'
        + '"description":"Networld+Interop Conference and Exhibit\\nAtlanta World Congress Center\\nAtlanta, Georgia",'
        + '"start":"1996-09-18T14:30:00","timeZone":"UTC","durationSeconds":199800}\n',
    )
    assert_equal(report_text(conf.report), "VEVENT ORGANIZER x1 from line 7\nVEVENT CATEGORIES x1 from line 11\n")

    var review = read_ics(crlf(S4_REVIEW).as_bytes(), rfc_zones())
    assert_equal(
        events_text(review),
        '{"uid":"guid-1.example.com","title":"XYZ Project Review","description":"Project XYZ Review Meeting",'
        + '"location":"1CP Conference Room 4350","start":"1998-03-12T08:30:00","timeZone":"America/New_York",'
        + '"durationSeconds":3600}\n',
    )
    assert_equal(
        report_text(review.report),
        "VEVENT ORGANIZER x1 from line 22\nVEVENT ATTENDEE x1 from line 23\nVEVENT CATEGORIES x1 from line 26\n"
        + "VEVENT CLASS x1 from line 27\nVEVENT CREATED x1 from line 28\n",
    )

    var todo = read_ics(crlf(S4_TODO).as_bytes(), rfc_zones())
    assert_equal(events_text(todo), "")
    assert_equal(
        report_text(todo.report),
        'COMPONENT_OUT_OF_SUBSET at line 4 (UID "uid4@example.com"): VTODO is outside the subset: '
        + "only VEVENT (with VALARM) and VTIMEZONE are read\n",
    )
    var journal = read_ics(crlf(S4_JOURNAL).as_bytes(), rfc_zones())
    assert_equal(events_text(journal), "")
    assert_equal(
        report_text(journal.report),
        'COMPONENT_OUT_OF_SUBSET at line 4 (UID "uid5@example.com"): VJOURNAL is outside the subset: '
        + "only VEVENT (with VALARM) and VTIMEZONE are read\n",
    )
    var busy = read_ics(crlf(S4_FREEBUSY).as_bytes(), rfc_zones())
    assert_equal(events_text(busy), "")
    assert_equal(
        report_text(busy.report),
        'COMPONENT_OUT_OF_SUBSET at line 4 (UID ""): VFREEBUSY is outside the subset: '
        + "only VEVENT (with VALARM) and VTIMEZONE are read\n",
    )
    print("  test_4_objects PASS")


def _rule(dtstart: String, rrule: String) raises -> String:
    """The recurrence an RRULE example gives, as JSON, or its refusal."""
    var text = crlf(
        "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//example//rfc5545 3.8.5.3//EN\nBEGIN:VEVENT\nUID:rule\n"
        + "DTSTART;TZID=America/New_York:" + dtstart + "\nDURATION:PT1H\nRRULE:" + rrule
        + "\nEND:VEVENT\nEND:VCALENDAR\n"
    )
    var got = read_ics(text.as_bytes(), rfc_zones())
    if len(got.events) == 1:
        return encode_json(got.events[0].event.recurrence.value())
    return got.report.refused[0].code + ": " + got.report.refused[0].message


comptime T0 = "19970902T090000"
comptime OUT = "RRULE_OUT_OF_SUBSET: "


def test_3_8_5_3_rules() raises:
    # Daily for 10 occurrences; daily until 24 December 1997 (00:00Z is
    # 19:00 EST on the 23rd, so the 23rd is the last day); every other day;
    # every 10 days, 5 occurrences.
    assert_equal(_rule(T0, "FREQ=DAILY;COUNT=10"), '{"freq":"DAILY","interval":1,"count":10}')
    assert_equal(_rule(T0, "FREQ=DAILY;UNTIL=19971224T000000Z"), '{"freq":"DAILY","interval":1,"until":"1997-12-23"}')
    assert_equal(_rule(T0, "FREQ=DAILY;INTERVAL=2"), '{"freq":"DAILY","interval":2}')
    assert_equal(_rule(T0, "FREQ=DAILY;INTERVAL=10;COUNT=5"), '{"freq":"DAILY","interval":10,"count":5}')
    # Every day in January, for 3 years.
    assert_equal(
        _rule("19980101T090000", "FREQ=YEARLY;UNTIL=20000131T140000Z;BYMONTH=1;BYDAY=SU,MO,TU,WE,TH,FR,SA"),
        OUT + "RRULE BYDAY on a YEARLY rule is outside the subset",
    )
    assert_equal(
        _rule("19980101T090000", "FREQ=DAILY;UNTIL=20000131T140000Z;BYMONTH=1"),
        OUT + "RRULE BYDAY, BYMONTHDAY or BYMONTH on a DAILY rule is outside the subset",
    )
    # Weekly.
    assert_equal(_rule(T0, "FREQ=WEEKLY;COUNT=10"), '{"freq":"WEEKLY","interval":1,"count":10}')
    assert_equal(_rule(T0, "FREQ=WEEKLY;UNTIL=19971224T000000Z"), '{"freq":"WEEKLY","interval":1,"until":"1997-12-23"}')
    assert_equal(_rule(T0, "FREQ=WEEKLY;INTERVAL=2;WKST=SU"), '{"freq":"WEEKLY","interval":2}')
    assert_equal(
        _rule(T0, "FREQ=WEEKLY;UNTIL=19971007T000000Z;WKST=SU;BYDAY=TU,TH"),
        '{"freq":"WEEKLY","interval":1,"weekdays":["TUESDAY","THURSDAY"],"until":"1997-10-06"}',
    )
    assert_equal(
        _rule(T0, "FREQ=WEEKLY;COUNT=10;WKST=SU;BYDAY=TU,TH"),
        '{"freq":"WEEKLY","interval":1,"weekdays":["TUESDAY","THURSDAY"],"count":10}',
    )
    assert_equal(
        _rule("19970901T090000", "FREQ=WEEKLY;INTERVAL=2;UNTIL=19971224T000000Z;WKST=SU;BYDAY=MO,WE,FR"),
        '{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY","WEDNESDAY","FRIDAY"],"until":"1997-12-23"}',
    )
    assert_equal(
        _rule(T0, "FREQ=WEEKLY;INTERVAL=2;COUNT=8;WKST=SU;BYDAY=TU,TH"),
        '{"freq":"WEEKLY","interval":2,"weekdays":["TUESDAY","THURSDAY"],"count":8}',
    )
    # Monthly.
    assert_equal(
        _rule("19970905T090000", "FREQ=MONTHLY;COUNT=10;BYDAY=1FR"),
        '{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"FRIDAY","count":10}',
    )
    assert_equal(
        _rule("19970905T090000", "FREQ=MONTHLY;UNTIL=19971224T000000Z;BYDAY=1FR"),
        '{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"FRIDAY","until":"1997-12-23"}',
    )
    assert_equal(
        _rule("19970907T090000", "FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU"),
        OUT + "RRULE BYDAY on a MONTHLY rule is one weekday in the subset",
    )
    assert_equal(
        _rule("19970922T090000", "FREQ=MONTHLY;COUNT=6;BYDAY=-2MO"),
        OUT + "RRULE ordinal -2 is outside 1..4 and -1",
    )
    assert_equal(
        _rule("19970928T090000", "FREQ=MONTHLY;BYMONTHDAY=-3"),
        OUT + "RRULE BYMONTHDAY on a MONTHLY rule is one day 1..31 in the subset",
    )
    assert_equal(
        _rule(T0, "FREQ=MONTHLY;COUNT=10;BYMONTHDAY=2,15"),
        OUT + "RRULE BYMONTHDAY on a MONTHLY rule is one day 1..31 in the subset",
    )
    assert_equal(
        _rule("19970930T090000", "FREQ=MONTHLY;COUNT=10;BYMONTHDAY=1,-1"),
        OUT + "RRULE BYMONTHDAY on a MONTHLY rule is one day 1..31 in the subset",
    )
    assert_equal(
        _rule("19970910T090000", "FREQ=MONTHLY;INTERVAL=18;COUNT=10;BYMONTHDAY=10,11,12,13,14,15"),
        OUT + "RRULE BYMONTHDAY on a MONTHLY rule is one day 1..31 in the subset",
    )
    assert_equal(
        _rule(T0, "FREQ=MONTHLY;INTERVAL=2;BYDAY=TU"),
        OUT + "RRULE BYDAY on a MONTHLY rule needs an ordinal (1..4 or -1) in the subset",
    )
    # Yearly.
    assert_equal(
        _rule("19970610T090000", "FREQ=YEARLY;COUNT=10;BYMONTH=6,7"),
        OUT + "RRULE BYMONTH on a YEARLY rule is the start's month in the subset",
    )
    assert_equal(
        _rule("19970310T090000", "FREQ=YEARLY;INTERVAL=2;COUNT=10;BYMONTH=1,2,3"),
        OUT + "RRULE BYMONTH on a YEARLY rule is the start's month in the subset",
    )
    assert_equal(
        _rule("19970101T090000", "FREQ=YEARLY;INTERVAL=3;COUNT=10;BYYEARDAY=1,100,200"),
        OUT + "RRULE part BYYEARDAY is outside the subset (FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS, WKST)",
    )
    assert_equal(_rule("19970519T090000", "FREQ=YEARLY;BYDAY=20MO"), OUT + "RRULE BYDAY on a YEARLY rule is outside the subset")
    assert_equal(
        _rule("19970512T090000", "FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO"),
        OUT + "RRULE part BYWEEKNO is outside the subset (FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS, WKST)",
    )
    assert_equal(
        _rule("19970313T090000", "FREQ=YEARLY;BYMONTH=3;BYDAY=TH"),
        OUT + "RRULE BYDAY on a YEARLY rule is outside the subset",
    )
    assert_equal(
        _rule("19970605T090000", "FREQ=YEARLY;BYDAY=TH;BYMONTH=6,7,8"),
        OUT + "RRULE BYDAY on a YEARLY rule is outside the subset",
    )
    assert_equal(
        _rule(T0, "FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13"),
        OUT + "RRULE BYMONTHDAY with BYDAY on a MONTHLY rule is outside the subset",
    )
    assert_equal(
        _rule("19970913T090000", "FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=7,8,9,10,11,12,13"),
        OUT + "RRULE BYMONTHDAY with BYDAY on a MONTHLY rule is outside the subset",
    )
    assert_equal(
        _rule("19961105T090000", "FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8"),
        OUT + "RRULE BYDAY on a YEARLY rule is outside the subset",
    )
    assert_equal(
        _rule("19970904T090000", "FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3"),
        OUT + "RRULE BYDAY on a MONTHLY rule is one weekday in the subset",
    )
    assert_equal(
        _rule("19970929T090000", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2"),
        OUT + "RRULE BYDAY on a MONTHLY rule is one weekday in the subset",
    )
    # Sub-daily frequencies.
    assert_equal(
        _rule(T0, "FREQ=HOURLY;INTERVAL=3;UNTIL=19970902T170000Z"),
        OUT + "RRULE FREQ=HOURLY is outside the subset (DAILY, WEEKLY, MONTHLY, YEARLY)",
    )
    assert_equal(
        _rule(T0, "FREQ=MINUTELY;INTERVAL=15;COUNT=6"),
        OUT + "RRULE FREQ=MINUTELY is outside the subset (DAILY, WEEKLY, MONTHLY, YEARLY)",
    )
    assert_equal(
        _rule(T0, "FREQ=DAILY;BYHOUR=9,10,11,12,13,14,15,16;BYMINUTE=0,20,40"),
        OUT + "RRULE part BYHOUR is outside the subset (FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS, WKST)",
    )
    # The WKST example: the same days, other weeks.
    assert_equal(
        _rule("19970805T090000", "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO"),
        '{"freq":"WEEKLY","interval":2,"weekdays":["TUESDAY","SUNDAY"],"count":4}',
    )
    assert_equal(
        _rule("19970805T090000", "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU"),
        OUT + "RRULE WKST=SU groups this rule's days into other weeks than a week starting on Monday",
    )
    # A month without the day is skipped: the 15th and 30th is refused; the
    # 31st of each month (the start's day) is held.
    assert_equal(
        _rule("20070115T090000", "FREQ=MONTHLY;BYMONTHDAY=15,30;COUNT=5"),
        OUT + "RRULE BYMONTHDAY on a MONTHLY rule is one day 1..31 in the subset",
    )
    assert_equal(
        _rule("20070131T090000", "FREQ=MONTHLY;INTERVAL=1;COUNT=5"),
        '{"freq":"MONTHLY","interval":1,"monthDay":31,"count":5}',
    )
    print("  test_3_8_5_3_rules PASS")


comptime S365_NEW_YORK = (
    "BEGIN:VTIMEZONE\n"
    + "TZID:America/New_York\n"
    + "BEGIN:DAYLIGHT\n"
    + "DTSTART:20070311T020000\n"
    + "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\n"
    + "TZNAME:EDT\n"
    + "TZOFFSETFROM:-0500\n"
    + "TZOFFSETTO:-0400\n"
    + "END:DAYLIGHT\n"
    + "BEGIN:STANDARD\n"
    + "DTSTART:20071104T020000\n"
    + "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\n"
    + "TZNAME:EST\n"
    + "TZOFFSETFROM:-0400\n"
    + "TZOFFSETTO:-0500\n"
    + "END:STANDARD\n"
    + "END:VTIMEZONE\n"
)


def test_3_6_5_vtimezone() raises:
    var ny = posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0")
    var text = write_vtimezone("America/New_York", ny, seconds_from_fields(2007, 12, 1))
    assert_equal(text, crlf(S365_NEW_YORK))
    print("  test_3_6_5_vtimezone PASS")


def main() raises:
    print("test_rfc5545")
    test_3_6_1_events()
    test_4_objects()
    test_3_8_5_3_rules()
    test_3_6_5_vtimezone()
    print("ALL TESTS PASS")
