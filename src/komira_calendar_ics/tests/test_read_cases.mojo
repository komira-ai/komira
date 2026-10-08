# =============================================================================
# test_read_cases.mojo -- read_ics on what a cancelled occurrence edit
# carries, enumerated values in any case (RFC 5545 §2.1), a series whose
# DTSTART its RRULE does not pick, a report kept small when a file names
# many distinct properties (and its overflow entry made by a merge), two
# series edited at the same start, and an alarm's `Reminder` text on a
# titled event.
#
# Every refusal and report line is asserted as exact text. Each test runs
# even when an earlier one fails, and the failures are listed together.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import encode_json
from komira_calendar_ics import (
    MAX_DROPPED_KINDS,
    OVERFLOW_DETAIL,
    IcsImport,
    IcsReport,
    ZoneTable,
    read_ics,
)


def _report(rep: IcsReport) -> String:
    var out = String()
    for r in rep.refused:
        out += String(r) + "\n"
    for d in rep.dropped:
        out += String(d) + "\n"
    return out^


def _err(text: String) raises -> String:
    try:
        _ = read_ics(text.as_bytes(), ZoneTable())
    except e:
        return String(e)
    raise Error("read")


comptime CANCELLED = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example//test//EN\r\n"  # 1-3
    + "BEGIN:VEVENT\r\n"  # 4
    + "UID:s\r\n"
    + "DTSTART:20300902T090000Z\r\n"
    + "DURATION:PT1H\r\n"
    + "RRULE:FREQ=DAILY\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 10
    + "UID:s\r\n"
    + "RECURRENCE-ID:20300903T090000Z\r\n"
    + "DTSTART:20300903T100000Z\r\n"  # 13: moved, and then cancelled
    + "STATUS:CANCELLED\r\n"
    + "SUMMARY:Changed\r\n"  # 15
    + "X-FOO:bar\r\n"
    + "COMMENT:hi\r\n"
    + "BEGIN:VALARM\r\n"  # 18
    + "TRIGGER:-PT5M\r\n"
    + "END:VALARM\r\n"
    + "BEGIN:VTODO\r\n"  # 21
    + "END:VTODO\r\n"
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\n"  # 24: as an export writes a cancelled occurrence
    + "UID:s\r\n"
    + "DTSTAMP:20300901T000000Z\r\n"
    + "RECURRENCE-ID:20300904T090000Z\r\n"
    + "DTSTART:20300904T090000Z\r\n"
    + "STATUS:Cancelled\r\n"
    + "END:VEVENT\r\n"
    + "END:VCALENDAR\r\n"
)


def test_cancelled_edit_reports_what_it_carries() raises:
    var got = read_ics(CANCELLED.as_bytes(), ZoneTable())
    assert_equal(len(got.events), 1)
    assert_equal(len(got.events[0].overrides), 2)
    assert_equal(encode_json(got.events[0].overrides[0]), '{"originalStart":"2030-09-03T09:00:00","cancelled":true}')
    assert_equal(encode_json(got.events[0].overrides[1]), '{"originalStart":"2030-09-04T09:00:00","cancelled":true}')
    assert_equal(
        _report(got.report),
        'COMPONENT_OUT_OF_SUBSET at line 21 (UID ""): VTODO inside a VEVENT is outside the subset (only VALARM is read there)\n'
        + "VEVENT DTSTART (on a cancelled occurrence) x1 from line 13\n"
        + "VEVENT SUMMARY (on a cancelled occurrence) x1 from line 15\n"
        + "VEVENT X-FOO (on a cancelled occurrence) x1 from line 16\n"
        + "VEVENT COMMENT (on a cancelled occurrence) x1 from line 17\n"
        + "VEVENT VALARM (on a cancelled occurrence) x1 from line 18\n",
    )


comptime _ONE = (
    "BEGIN:VEVENT\r\nUID:c\r\nDTSTART;VALUE=DATE:20301104\r\nSTATUS:cancelled\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
)


def test_status_in_any_case() raises:
    # RFC 5545 §2.1: enumerated property values are case-insensitive.
    var got = read_ics(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + _ONE).as_bytes(), ZoneTable())
    assert_equal(_report(got.report), "")
    assert_equal(
        encode_json(got.events[0].event),
        '{"uid":"c","showWithoutTime":true,"startDate":"2030-11-04","days":1,"status":"CANCELLED"}',
    )


def test_method_in_any_case() raises:
    var got = read_ics(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:publish\r\n" + _ONE).as_bytes(), ZoneTable())
    assert_equal(len(got.events), 1)
    assert_equal(
        _err("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:request\r\n" + _ONE),
        "ics: line 3: METHOD:request is a scheduling message (iTIP); only a published calendar is imported",
    )


def test_start_not_an_occurrence() raises:
    var text = (
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
        + "BEGIN:VEVENT\r\nUID:first-friday\r\nDTSTART;VALUE=DATE:20300902\r\n"  # 3: a Monday
        + "RRULE:FREQ=MONTHLY;COUNT=10;BYDAY=1FR\r\nEND:VEVENT\r\n"
        + "BEGIN:VEVENT\r\nUID:on-a-friday\r\nDTSTART;VALUE=DATE:20300906\r\n"  # 8
        + "RRULE:FREQ=MONTHLY;COUNT=10;BYDAY=1FR\r\nEND:VEVENT\r\n"
        + "END:VCALENDAR\r\n"
    )
    var got = read_ics(text.as_bytes(), ZoneTable())
    assert_equal(
        _report(got.report),
        'RRULE_OUT_OF_SUBSET at line 3 (UID "first-friday"): '
        + "DTSTART is not an occurrence of its RRULE; RFC 5545 leaves such a recurrence set undefined\n",
    )
    assert_equal(len(got.events), 1)
    assert_equal(got.events[0].event.uid, "on-a-friday")


def test_many_distinct_names_are_capped() raises:
    # 300 distinct X- names on the VCALENDAR and 300 more on one event, each
    # twice: the report itemises MAX_DROPPED_KINDS kinds and counts the rest
    # in one entry.
    var text = String("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n")
    for i in range(300):
        text += "X-CAL-" + String(i) + ":a\r\nX-CAL-" + String(i) + ":b\r\n"  # lines 3 + 2i, 4 + 2i
    text += "BEGIN:VEVENT\r\nUID:x\r\nDTSTART;VALUE=DATE:20301104\r\n"  # 603-605
    for i in range(300):
        text += "X-EV-" + String(i) + ":a\r\nX-EV-" + String(i) + ":b\r\n"  # 606 + 2i
    text += "END:VEVENT\r\nEND:VCALENDAR\r\n"
    var got = read_ics(text.as_bytes(), ZoneTable())
    assert_equal(len(got.events), 1)
    assert_equal(MAX_DROPPED_KINDS, 256)
    assert_equal(len(got.report.dropped), MAX_DROPPED_KINDS + 1)
    assert_equal(String(got.report.dropped[0]), "VCALENDAR X-CAL-0 x2 from line 3")
    assert_equal(String(got.report.dropped[255]), "VCALENDAR X-CAL-255 x2 from line 513")
    # 44 calendar kinds and 300 event kinds, twice each, past the cap; the
    # first of them is X-CAL-256 on line 515.
    assert_equal(
        String(got.report.dropped[256]),
        "* * (" + OVERFLOW_DETAIL + ") x688 from line 515",
    )


def test_merge_adds_counts() raises:
    var a = IcsReport()
    a.drop("VEVENT", "X-A", "", 9)
    a.drop("VEVENT", "X-A", "", 4)
    a.drop("VEVENT", "X-B", "detail", 5)
    var b = IcsReport()
    b.drop("VEVENT", "X-A", "", 7)
    b.merge(a)
    assert_equal(_report(b), "VEVENT X-A x3 from line 4\nVEVENT X-B (detail) x1 from line 5\n")
    # A triple whose parts run into each other is its own kind.
    var c = IcsReport()
    c.drop("VEVENT", "X-AB", "", 1)
    c.drop("VEVENT", "X-A", "B", 2)
    assert_equal(len(c.dropped), 2)


def test_overflow_entry_made_by_merge() raises:
    # Nothing dropped on the VCALENDAR; one event drops 300 distinct X- names,
    # twice each. The event's own report counts 44 kinds twice in its `* *`
    # entry, and merging it into the file's report makes that entry there
    # with all 88.
    var text = String("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;VALUE=DATE:20301104\r\n")
    for i in range(300):
        text += "X-EV-" + String(i) + ":a\r\nX-EV-" + String(i) + ":b\r\n"  # lines 6 + 2i, 7 + 2i
    text += "END:VEVENT\r\nEND:VCALENDAR\r\n"
    var got = read_ics(text.as_bytes(), ZoneTable())
    assert_equal(len(got.events), 1)
    assert_equal(len(got.report.dropped), MAX_DROPPED_KINDS + 1)
    assert_equal(String(got.report.dropped[0]), "VEVENT X-EV-0 x2 from line 6")
    assert_equal(String(got.report.dropped[255]), "VEVENT X-EV-255 x2 from line 516")
    assert_equal(String(got.report.dropped[256]), "* * (" + OVERFLOW_DETAIL + ") x88 from line 518")


comptime TWO_SERIES = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
    + "BEGIN:VEVENT\r\nUID:a\r\nDTSTART:20300902T090000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY\r\nEND:VEVENT\r\n"  # 3
    + "BEGIN:VEVENT\r\nUID:b\r\nDTSTART:20300902T090000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY\r\nEND:VEVENT\r\n"  # 9
    + "BEGIN:VEVENT\r\nUID:a\r\nRECURRENCE-ID:20300903T090000Z\r\nSUMMARY:A\r\nEND:VEVENT\r\n"  # 15
    + "BEGIN:VEVENT\r\nUID:b\r\nRECURRENCE-ID:20300903T090000Z\r\nSUMMARY:B\r\nEND:VEVENT\r\n"  # 20
    + "END:VCALENDAR\r\n"
)


def test_two_series_edited_at_the_same_start() raises:
    # An occurrence is edited twice only within one series: two series each
    # edited at 2030-09-03 09:00 keep both edits.
    var got = read_ics(TWO_SERIES.as_bytes(), ZoneTable())
    assert_equal(_report(got.report), "")
    assert_equal(len(got.events), 2)
    assert_equal(len(got.events[0].overrides), 1)
    assert_equal(len(got.events[1].overrides), 1)
    assert_equal(encode_json(got.events[0].overrides[0]), '{"originalStart":"2030-09-03T09:00:00","title":"A"}')
    assert_equal(encode_json(got.events[1].overrides[0]), '{"originalStart":"2030-09-03T09:00:00","title":"B"}')


comptime TITLED_REMINDER = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
    + "BEGIN:VEVENT\r\nUID:t\r\nDTSTART:20300902T090000Z\r\nDURATION:PT1H\r\nSUMMARY:Sync\r\n"  # 3-7
    + "BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n"  # 8-12
    + "END:VEVENT\r\n"
    + "BEGIN:VEVENT\r\nUID:u\r\nDTSTART:20300902T090000Z\r\nDURATION:PT1H\r\n"  # 14-17
    + "BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n"  # 18-22
    + "END:VEVENT\r\n"
    + "END:VCALENDAR\r\n"
)


def test_reminder_text_on_a_titled_event() raises:
    # `Reminder` is the text an export gives the alarm of an event with no
    # title; on an event titled "Sync" it is text the model does not keep.
    var got = read_ics(TITLED_REMINDER.as_bytes(), ZoneTable())
    assert_equal(_report(got.report), "VALARM DESCRIPTION x1 from line 10\n")
    assert_equal(len(got.events), 2)
    assert_equal(len(got.events[0].event.reminders), 1)
    assert_equal(len(got.events[1].event.reminders), 1)


def main() raises:
    print("test_read_cases")
    var failed = List[String]()
    try:
        test_cancelled_edit_reports_what_it_carries()
        print("  test_cancelled_edit_reports_what_it_carries PASS")
    except e:
        failed.append("test_cancelled_edit_reports_what_it_carries: " + String(e))
    try:
        test_status_in_any_case()
        print("  test_status_in_any_case PASS")
    except e:
        failed.append("test_status_in_any_case: " + String(e))
    try:
        test_method_in_any_case()
        print("  test_method_in_any_case PASS")
    except e:
        failed.append("test_method_in_any_case: " + String(e))
    try:
        test_start_not_an_occurrence()
        print("  test_start_not_an_occurrence PASS")
    except e:
        failed.append("test_start_not_an_occurrence: " + String(e))
    try:
        test_many_distinct_names_are_capped()
        print("  test_many_distinct_names_are_capped PASS")
    except e:
        failed.append("test_many_distinct_names_are_capped: " + String(e))
    try:
        test_merge_adds_counts()
        print("  test_merge_adds_counts PASS")
    except e:
        failed.append("test_merge_adds_counts: " + String(e))
    try:
        test_overflow_entry_made_by_merge()
        print("  test_overflow_entry_made_by_merge PASS")
    except e:
        failed.append("test_overflow_entry_made_by_merge: " + String(e))
    try:
        test_two_series_edited_at_the_same_start()
        print("  test_two_series_edited_at_the_same_start PASS")
    except e:
        failed.append("test_two_series_edited_at_the_same_start: " + String(e))
    try:
        test_reminder_text_on_a_titled_event()
        print("  test_reminder_text_on_a_titled_event PASS")
    except e:
        failed.append("test_reminder_text_on_a_titled_event: " + String(e))
    for f in failed:
        print("  FAIL " + f)
    assert_true(len(failed) == 0, String(len(failed)) + " tests failed")
    print("ALL TESTS PASS")
