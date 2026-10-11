# =============================================================================
# test_round_trip_edges.mojo -- export then import on the model values a
# round trip can lose: an event with no title and a reminder, an edit that
# clears a field, an edit whose replacement equals the series' value, a CR in
# a description; a series whose start its rule does not pick, which the
# export moves to its first occurrence; series that start before 1970; and
# one with no occurrence, which the export leaves out and names, without
# resolving its zone, checking its edits or shifting the forms of the
# events after it; and an event with both a uid and an id, which the
# export names by its uid, written or left out.
#
# Events and edits are compared as the API's JSON, and every report line as
# exact text. Each test runs even when an earlier one fails, and the
# failures are listed together.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_calendar_proto.calendar import Event, OccurrenceOverride
from komira_proto_codec import decode_json, encode_json
from komira_calendar_ics import IcsEvent, IcsImport, IcsReport, ZoneTable, read_ics, write_ics


def _ev(json: String) raises -> Event:
    return decode_json[Event](json)


def _ov(json: String) raises -> OccurrenceOverride:
    return decode_json[OccurrenceOverride](json)


def _report(rep: IcsReport) -> String:
    var out = String()
    for r in rep.refused:
        out += String(r) + "\n"
    for d in rep.dropped:
        out += String(d) + "\n"
    return out^


def _back(events: List[IcsEvent]) raises -> IcsImport:
    var text = write_ics(events, ZoneTable(), 1914364800).text.copy()
    return read_ics(text.as_bytes(), ZoneTable())


def _same(var events: List[IcsEvent]) raises:
    """Exported and imported, `events` come back as they were, with a clean
    report."""
    var back = _back(events)
    assert_equal(_report(back.report), "", "report of the re-import")
    assert_equal(len(back.events), len(events))
    for i in range(len(events)):
        assert_equal(encode_json(back.events[i].event), encode_json(events[i].event))
        assert_equal(len(back.events[i].overrides), len(events[i].overrides))
        for k in range(len(events[i].overrides)):
            assert_equal(encode_json(back.events[i].overrides[k]), encode_json(events[i].overrides[k]))


def test_untitled_event_with_a_reminder() raises:
    # The alarm of an event with no title carries DESCRIPTION:Reminder (RFC
    # 5545 requires a DESCRIPTION on a DISPLAY alarm); reading it back is not
    # a dropped DESCRIPTION.
    var events = List[IcsEvent]()
    events.append(
        IcsEvent(_ev('{"uid":"untitled","showWithoutTime":true,"startDate":"2030-09-02","days":1,"reminders":[{"minutesBefore":15}]}'))
    )
    var text = write_ics(events, ZoneTable(), 1914364800).text.copy()
    assert_true(text.find("BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\n") >= 0, text)
    _same(events^)


def _series() raises -> Event:
    return _ev(
        '{"uid":"s","title":"Sync","location":"Room 4","description":"Agenda","start":"2030-09-02T09:00:00",'
        + '"timeZone":"UTC","durationSeconds":1800,"recurrence":{"freq":"DAILY","interval":1,"count":5}}'
    )


def test_edit_that_clears_fields() raises:
    var edits = List[OccurrenceOverride]()
    edits.append(_ov('{"originalStart":"2030-09-03T09:00:00","location":""}'))
    edits.append(_ov('{"originalStart":"2030-09-04T09:00:00","title":"","description":""}'))
    var events = List[IcsEvent]()
    events.append(IcsEvent(_series(), edits^))
    _same(events^)


def test_replacement_equal_to_the_series() raises:
    # The occurrence shows the same title either way: the replacement is
    # not kept, and an edit left with no change is reported as such.
    var edits = List[OccurrenceOverride]()
    edits.append(_ov('{"originalStart":"2030-09-03T09:00:00","title":"Sync","location":"Elsewhere"}'))
    edits.append(_ov('{"originalStart":"2030-09-04T09:00:00","title":"Sync"}'))
    var events = List[IcsEvent]()
    events.append(IcsEvent(_series(), edits^))
    var back = _back(events)
    assert_equal(len(back.events[0].overrides), 1)
    assert_equal(encode_json(back.events[0].overrides[0]), '{"originalStart":"2030-09-03T09:00:00","location":"Elsewhere"}')
    assert_equal(
        _report(back.report),
        "VEVENT RECURRENCE-ID (an occurrence edit that changes nothing) x1 from line 25\n",
    )


def test_carriage_return_comes_back_as_line_feed() raises:
    # TEXT has one escape for a line break, `\n`: CR and CRLF are written as
    # it and read back as LF.
    var events = List[IcsEvent]()
    events.append(
        IcsEvent(_ev('{"uid":"cr","description":"a\\r\\nb\\rc","showWithoutTime":true,"startDate":"2030-09-02","days":1}'))
    )
    var text = write_ics(events, ZoneTable(), 1914364800).text.copy()
    assert_true(text.find("DESCRIPTION:a\\nb\\nc\r\n") >= 0, text)
    var back = read_ics(text.as_bytes(), ZoneTable())
    assert_equal(_report(back.report), "")
    assert_equal(back.events[0].event.description, "a\nb\nc")


def _moved(json: String, want: String, dtstart: String) raises:
    """The event `json`, whose start its rule does not pick, is written with
    DTSTART line `dtstart` and comes back as `want` with a clean report."""
    var events = List[IcsEvent]()
    events.append(IcsEvent(_ev(json)))
    var text = write_ics(events, ZoneTable(), 1914364800).text.copy()
    assert_true(text.find("\r\n" + dtstart + "\r\n") >= 0, text)
    var back = read_ics(text.as_bytes(), ZoneTable())
    assert_equal(_report(back.report), "", "report of the re-import")
    assert_equal(len(back.events), 1)
    assert_equal(encode_json(back.events[0].event), encode_json(_ev(want)))


def test_export_moves_a_start_its_rule_skips() raises:
    # The model never picks a day before the first one its rule picks, and
    # counts periods from the one holding the start; so the series started
    # on its first occurrence has the same occurrences (COUNT and UNTIL
    # included), and DTSTART is then one of them (RFC 5545 §3.8.5.3).
    var rule = String('"recurrence":{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"FRIDAY","count":10}}')
    _moved(
        '{"uid":"first-friday","showWithoutTime":true,"startDate":"2030-09-02","days":2,' + rule,
        '{"uid":"first-friday","showWithoutTime":true,"startDate":"2030-09-06","days":2,' + rule,
        "DTSTART;VALUE=DATE:20300906\r\nDTEND;VALUE=DATE:20300908",
    )
    rule = '"recurrence":{"freq":"WEEKLY","interval":2,"weekdays":["TUESDAY","THURSDAY"],"until":"2030-12-31"}}'
    _moved(
        '{"uid":"tue-thu","start":"2030-09-02T09:00:00","timeZone":"UTC","durationSeconds":60,' + rule,
        '{"uid":"tue-thu","start":"2030-09-03T09:00:00","timeZone":"UTC","durationSeconds":60,' + rule,
        "DTSTART:20300903T090000Z\r\nDURATION:PT1M",
    )
    rule = '"recurrence":{"freq":"MONTHLY","interval":2,"monthDay":31}}'
    _moved(
        '{"uid":"31st","start":"2030-09-02T09:00:00","timeZone":"UTC","durationSeconds":60,' + rule,
        '{"uid":"31st","start":"2031-01-31T09:00:00","timeZone":"UTC","durationSeconds":60,' + rule,
        "DTSTART:20310131T090000Z",
    )
    # The same rule from a start it picks is written as it is.
    var c = List[IcsEvent]()
    c.append(
        IcsEvent(
            _ev(
                '{"uid":"first-friday","showWithoutTime":true,"startDate":"2030-09-06","days":1,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"FRIDAY","count":10}}'
            )
        )
    )
    _same(c^)


def test_export_before_1970() raises:
    # Days before 1970-01-01 count negative (1969-12-31 is day -1); a series
    # starting there exports and comes back like any other.
    var a = List[IcsEvent]()
    a.append(
        IcsEvent(
            _ev('{"uid":"bday","showWithoutTime":true,"startDate":"1965-03-14","days":1,"recurrence":{"freq":"YEARLY","interval":1}}')
        )
    )
    a.append(
        IcsEvent(
            _ev(
                '{"uid":"eve","start":"1969-12-31T09:00:00","timeZone":"UTC","durationSeconds":60,'
                + '"recurrence":{"freq":"WEEKLY","interval":1,"weekdays":["WEDNESDAY"]}}'
            )
        )
    )
    a.append(
        IcsEvent(
            _ev(
                '{"uid":"june","showWithoutTime":true,"startDate":"1969-06-01","days":1,'
                + '"recurrence":{"freq":"DAILY","interval":1,"count":3}}'
            )
        )
    )
    _same(a^)
    # The 31st from 5 December 1969: the first occurrence is day -1.
    var rule = String('"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":31}}')
    _moved(
        '{"uid":"31st","start":"1969-12-05T09:00:00","timeZone":"UTC","durationSeconds":60,' + rule,
        '{"uid":"31st","start":"1969-12-31T09:00:00","timeZone":"UTC","durationSeconds":60,' + rule,
        "DTSTART:19691231T090000Z",
    )


def test_export_skips_a_series_with_no_occurrence() raises:
    # No 31st from 2 September to 30 October 2030: the model's series is
    # empty (komira_calendar.check_event accepts it), and no VEVENT reads
    # back as it. It is left out with its edit and named in `skipped`; the
    # events around it are written and come back as they were.
    var edits = List[OccurrenceOverride]()
    edits.append(_ov('{"originalStart":"2030-09-02T09:00:00","title":"Moved"}'))
    var a = List[IcsEvent]()
    a.append(IcsEvent(_ev('{"uid":"before","showWithoutTime":true,"startDate":"2030-09-01","days":1}')))
    a.append(
        IcsEvent(
            _ev(
                '{"uid":"never","start":"2030-09-02T09:00:00","timeZone":"UTC","durationSeconds":60,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2030-10-30"}}'
            ),
            edits^,
        )
    )
    a.append(
        IcsEvent(
            _ev(
                '{"uid":"after","start":"2030-09-03T09:00:00","timeZone":"UTC","durationSeconds":60,'
                + '"recurrence":{"freq":"WEEKLY","interval":1,"weekdays":["TUESDAY"],"count":3}}'
            )
        )
    )
    var exported = write_ics(a, ZoneTable(), 1914364800)
    assert_equal(len(exported.skipped), 1, "skipped")
    assert_equal(exported.skipped[0], "never")
    assert_equal(exported.text.find("never"), -1, exported.text)
    assert_equal(exported.text.find("Moved"), -1, exported.text)
    var back = read_ics(exported.text.as_bytes(), ZoneTable())
    assert_equal(_report(back.report), "", "report of the re-import")
    assert_equal(len(back.events), 2)
    assert_equal(encode_json(back.events[0].event), encode_json(a[0].event))
    assert_equal(encode_json(back.events[1].event), encode_json(a[2].event))
    # The same series with an until on the 31st is written.
    var b = List[IcsEvent]()
    b.append(
        IcsEvent(
            _ev(
                '{"uid":"once","start":"2030-09-02T09:00:00","timeZone":"UTC","durationSeconds":60,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2030-10-31"}}'
            )
        )
    )
    assert_equal(len(write_ics(b, ZoneTable(), 1914364800).skipped), 0)


def test_skipped_series_names_no_zone() raises:
    # A left-out series counts toward neither the VTIMEZONEs written nor the
    # unknown-zone refusal: its zone, unknown to an empty table, is not
    # resolved and gets no VTIMEZONE.
    var a = List[IcsEvent]()
    a.append(
        IcsEvent(
            _ev(
                '{"uid":"berlin","start":"2030-09-02T09:00:00","timeZone":"Europe/Berlin","durationSeconds":60,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2030-10-30"}}'
            )
        )
    )
    var exported = write_ics(a, ZoneTable(), 1914364800)
    assert_equal(len(exported.skipped), 1, "skipped")
    assert_equal(exported.skipped[0], "berlin")
    assert_equal(exported.text.find("VTIMEZONE"), -1, exported.text)
    assert_equal(exported.text.find("Europe/Berlin"), -1, exported.text)


def test_skipped_series_edits_are_not_checked() raises:
    # Edits are checked only for a series the export writes: an edit that
    # neither cancels nor changes anything, on a left-out series, does not
    # refuse the calendar.
    var edits = List[OccurrenceOverride]()
    edits.append(_ov('{"originalStart":"2030-09-02T09:00:00"}'))
    var a = List[IcsEvent]()
    a.append(
        IcsEvent(
            _ev(
                '{"uid":"never","start":"2030-09-02T09:00:00","timeZone":"UTC","durationSeconds":60,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2030-10-30"}}'
            ),
            edits^,
        )
    )
    var exported = write_ics(a, ZoneTable(), 1914364800)
    assert_equal(len(exported.skipped), 1, "skipped")
    assert_equal(exported.skipped[0], "never")
    assert_equal(exported.text.find("VEVENT"), -1, exported.text)


def test_skipped_all_day_series_before_a_timed_one() raises:
    # A left-out all-day series, then a timed one: the timed event is
    # written with its own form (a UTC DTSTART), not the all-day form of
    # the series before it.
    var a = List[IcsEvent]()
    a.append(
        IcsEvent(
            _ev(
                '{"uid":"never","showWithoutTime":true,"startDate":"2030-09-02","days":1,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2030-10-30"}}'
            )
        )
    )
    a.append(IcsEvent(_ev('{"uid":"timed","start":"2030-09-03T09:00:00","timeZone":"UTC","durationSeconds":60}')))
    var exported = write_ics(a, ZoneTable(), 1914364800)
    assert_equal(len(exported.skipped), 1, "skipped")
    assert_equal(exported.skipped[0], "never")
    assert_true(exported.text.find("DTSTART:20300903T090000Z") >= 0, exported.text)
    var back = read_ics(exported.text.as_bytes(), ZoneTable())
    assert_equal(_report(back.report), "", "report of the re-import")
    assert_equal(len(back.events), 1)
    assert_equal(encode_json(back.events[0].event), encode_json(a[1].event))


def test_skipped_series_without_uid_is_named_by_id() raises:
    # A left-out series with an empty uid is named in `skipped` by its id.
    var a = List[IcsEvent]()
    a.append(
        IcsEvent(
            _ev(
                '{"id":"e9","uid":"","start":"2030-09-02T09:00:00","timeZone":"UTC","durationSeconds":60,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2030-10-30"}}'
            )
        )
    )
    var exported = write_ics(a, ZoneTable(), 1914364800)
    assert_equal(len(exported.skipped), 1, "skipped")
    assert_equal(exported.skipped[0], "e9")
    assert_equal(exported.text.find("VEVENT"), -1, exported.text)


def test_uid_is_written_over_the_id() raises:
    # A stored event carries both an id and a uid; the uid is what an .ics
    # names it by, on the series and on each edit.
    var edits = List[OccurrenceOverride]()
    edits.append(_ov('{"originalStart":"2030-09-10T09:00:00","title":"Moved"}'))
    var a = List[IcsEvent]()
    a.append(
        IcsEvent(
            _ev(
                '{"id":"e10","uid":"u10","start":"2030-09-03T09:00:00","timeZone":"UTC","durationSeconds":60,'
                + '"recurrence":{"freq":"WEEKLY","interval":1,"weekdays":["TUESDAY"],"count":3}}'
            ),
            edits^,
        )
    )
    var exported = write_ics(a, ZoneTable(), 1914364800)
    assert_equal(len(exported.skipped), 0, "skipped")
    assert_equal(exported.text.count("UID:u10"), 2, exported.text)
    assert_equal(exported.text.find("e10"), -1, exported.text)
    var back = read_ics(exported.text.as_bytes(), ZoneTable())
    assert_equal(_report(back.report), "", "report of the re-import")
    assert_equal(len(back.events), 1)
    assert_equal(back.events[0].event.uid, "u10")
    assert_equal(len(back.events[0].overrides), 1)


def test_skipped_series_with_uid_and_id_is_named_by_uid() raises:
    # A left-out series that has both is named in `skipped` by its uid.
    var a = List[IcsEvent]()
    a.append(
        IcsEvent(
            _ev(
                '{"id":"e10","uid":"u10","start":"2030-09-02T09:00:00","timeZone":"UTC","durationSeconds":60,'
                + '"recurrence":{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2030-10-30"}}'
            )
        )
    )
    var exported = write_ics(a, ZoneTable(), 1914364800)
    assert_equal(len(exported.skipped), 1, "skipped")
    assert_equal(exported.skipped[0], "u10")
    assert_equal(exported.text.find("VEVENT"), -1, exported.text)


def main() raises:
    print("test_round_trip_edges")
    var failed = List[String]()
    try:
        test_untitled_event_with_a_reminder()
        print("  test_untitled_event_with_a_reminder PASS")
    except e:
        failed.append("test_untitled_event_with_a_reminder: " + String(e))
    try:
        test_edit_that_clears_fields()
        print("  test_edit_that_clears_fields PASS")
    except e:
        failed.append("test_edit_that_clears_fields: " + String(e))
    try:
        test_replacement_equal_to_the_series()
        print("  test_replacement_equal_to_the_series PASS")
    except e:
        failed.append("test_replacement_equal_to_the_series: " + String(e))
    try:
        test_carriage_return_comes_back_as_line_feed()
        print("  test_carriage_return_comes_back_as_line_feed PASS")
    except e:
        failed.append("test_carriage_return_comes_back_as_line_feed: " + String(e))
    try:
        test_export_moves_a_start_its_rule_skips()
        print("  test_export_moves_a_start_its_rule_skips PASS")
    except e:
        failed.append("test_export_moves_a_start_its_rule_skips: " + String(e))
    try:
        test_export_before_1970()
        print("  test_export_before_1970 PASS")
    except e:
        failed.append("test_export_before_1970: " + String(e))
    try:
        test_export_skips_a_series_with_no_occurrence()
        print("  test_export_skips_a_series_with_no_occurrence PASS")
    except e:
        failed.append("test_export_skips_a_series_with_no_occurrence: " + String(e))
    try:
        test_skipped_series_names_no_zone()
        print("  test_skipped_series_names_no_zone PASS")
    except e:
        failed.append("test_skipped_series_names_no_zone: " + String(e))
    try:
        test_skipped_series_edits_are_not_checked()
        print("  test_skipped_series_edits_are_not_checked PASS")
    except e:
        failed.append("test_skipped_series_edits_are_not_checked: " + String(e))
    try:
        test_skipped_all_day_series_before_a_timed_one()
        print("  test_skipped_all_day_series_before_a_timed_one PASS")
    except e:
        failed.append("test_skipped_all_day_series_before_a_timed_one: " + String(e))
    try:
        test_skipped_series_without_uid_is_named_by_id()
        print("  test_skipped_series_without_uid_is_named_by_id PASS")
    except e:
        failed.append("test_skipped_series_without_uid_is_named_by_id: " + String(e))
    try:
        test_uid_is_written_over_the_id()
        print("  test_uid_is_written_over_the_id PASS")
    except e:
        failed.append("test_uid_is_written_over_the_id: " + String(e))
    try:
        test_skipped_series_with_uid_and_id_is_named_by_uid()
        print("  test_skipped_series_with_uid_and_id_is_named_by_uid PASS")
    except e:
        failed.append("test_skipped_series_with_uid_and_id_is_named_by_uid: " + String(e))
    for f in failed:
        print("  FAIL " + f)
    assert_true(len(failed) == 0, String(len(failed)) + " tests failed")
    print("ALL TESTS PASS")
