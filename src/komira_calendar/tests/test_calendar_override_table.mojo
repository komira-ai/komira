# =============================================================================
# test_calendar_override_table.mojo: check_calendar, check_override and the
# error envelope, row by row.
#
# As in test_validation_table.mojo: a valid baseline, then one changed field
# per row with the refusal's exact code, JSON field path and message, so a
# dropped or weakened check turns its row red. test_error_envelope pins the
# JSON a refusal is sent as, byte for byte.
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import decode_json, encode_json
from komira_calendar_proto.calendar import (
    Calendar,
    Event,
    OccurrenceOverride,
)
from komira_calendar import Refusal, check_calendar, check_override, error_response


comptime CALENDAR = '{"name":"Work","color":"#A0b1C2","timeZone":"America/Argentina/Buenos_Aires"}'
comptime SERIES = (
    '{"uid":"standup","title":"Standup","start":"2026-10-12T09:30:00",'
    + '"timeZone":"Asia/Kathmandu","durationSeconds":900,'
    + '"recurrence":{"freq":"DAILY","interval":1,"count":30}}'
)
comptime ALL_DAY_SERIES = (
    '{"uid":"payday","title":"Payday","showWithoutTime":true,"startDate":"2026-10-30",'
    + '"days":1,"recurrence":{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"FRIDAY"}}'
)


def _refused(r: Optional[Refusal], code: String, field: String, message: String) raises:
    if not r:
        raise Error("accepted; want " + code + " at " + field)
    ref got = r.value()
    assert_equal(got.code, code, "code (the refusal was: " + String(got) + ")")
    assert_equal(got.field, field, code + ": field")
    assert_equal(got.message, message, code + ": message")


def _accepted(r: Optional[Refusal], what: String) raises:
    if r:
        raise Error(what + ": refused: " + String(r.value()))


def _calendar() raises -> Calendar:
    return decode_json[Calendar](CALENDAR)


def _edit(json: String) raises -> OccurrenceOverride:
    return decode_json[OccurrenceOverride](json)


def test_calendar() raises:
    _accepted(check_calendar(_calendar()), "the baseline calendar")
    var c = _calendar()
    c.color = ""
    _accepted(check_calendar(c), "a calendar with no color")

    c = _calendar()
    c.name = ""
    _refused(check_calendar(c), "NAME_REQUIRED", "name", "a calendar needs a name")

    c = _calendar()
    var long = String("")
    for _ in range(257):
        long += "n"
    c.name = long
    _refused(check_calendar(c), "TEXT_TOO_LONG", "name", "name is 257 bytes; at most 256 are allowed")

    c = _calendar()
    c.name = "Work\nHome"
    _refused(check_calendar(c), "TEXT_CONTROL_CHARACTER", "name", "name holds control character 0xa at byte 4")

    for bad in ["#12345", "red", "#12345g", "A0B1C2#"]:
        c = _calendar()
        c.color = bad
        _refused(check_calendar(c), "COLOR_MALFORMED", "color", "color is empty or #rrggbb (six hex digits)")

    c = _calendar()
    c.time_zone = ""
    _refused(check_calendar(c), "TIME_ZONE_REQUIRED", "timeZone", "a calendar needs a default time zone")

    for bad in ["Europe/", "/UTC", "../etc/passwd", "Europe/Lon don", "1Zone"]:
        c = _calendar()
        c.time_zone = bad
        _refused(
            check_calendar(c),
            "TIME_ZONE_MALFORMED",
            "timeZone",
            "timeZone is not shaped like an IANA time zone name",
        )


def test_override() raises:
    var series = decode_json[Event](SERIES)
    var all_day = decode_json[Event](ALL_DAY_SERIES)
    _accepted(check_override(_edit('{"originalStart":"2026-10-14T09:30:00","cancelled":true}'), series), "cancel")
    _accepted(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","title":"Standup (moved)",'
        + '"start":"2026-10-14T11:00:00","durationSeconds":1200}'), series),
        "move one occurrence",
    )
    _accepted(
        check_override(_edit('{"originalStart":"2026-11-27","days":2,"start":"2026-11-26"}'), all_day),
        "an all-day occurrence over two days",
    )
    _accepted(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","description":"Notes"}'), series),
        "a description-only edit",
    )
    _accepted(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","description":"line one\\n\\tline two"}'), series),
        "a multi-line description on one occurrence",
    )

    var single = decode_json[Event](SERIES)
    single.recurrence = None
    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","cancelled":true}'), single),
        "OVERRIDE_WITHOUT_RECURRENCE",
        "eventId",
        "only a recurring event has occurrences to edit",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14","cancelled":true}'), series),
        "ORIGINAL_START_MALFORMED",
        "originalStart",
        "originalStart is not a local date-time (YYYY-MM-DDTHH:MM:SS): a local date-time is"
        + " YYYY-MM-DDTHH:MM:SS, nineteen bytes",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","cancelled":true,"title":"x"}'), series),
        "OVERRIDE_CANCELLED_WITH_CHANGES",
        "cancelled",
        "a cancelled occurrence carries no replacement fields",
    )

    _refused(
        check_override(
            _edit('{"originalStart":"2026-10-14T09:30:00","cancelled":true,"description":"Notes"}'), series
        ),
        "OVERRIDE_CANCELLED_WITH_CHANGES",
        "cancelled",
        "a cancelled occurrence carries no replacement fields",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00"}'), series),
        "OVERRIDE_EMPTY",
        "cancelled",
        "an override cancels the occurrence or replaces at least one field",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","title":"Stand\\nup"}'), series),
        "TEXT_CONTROL_CHARACTER",
        "title",
        "title holds control character 0xa at byte 5",
    )

    var long_title = String('{"originalStart":"2026-10-14T09:30:00","title":"')
    for _ in range(1025):
        long_title += "t"
    long_title += '"}'
    _refused(
        check_override(_edit(long_title), series),
        "TEXT_TOO_LONG",
        "title",
        "title is 1025 bytes; at most 1024 are allowed",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","description":"agenda\\u0001"}'), series),
        "TEXT_CONTROL_CHARACTER",
        "description",
        "description holds control character 0x1 at byte 6",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","location":"Room\\n2"}'), series),
        "TEXT_CONTROL_CHARACTER",
        "location",
        "location holds control character 0xa at byte 4",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","start":"2026-10-14T25:00:00"}'), series),
        "START_MALFORMED",
        "start",
        "start is not a local date-time (YYYY-MM-DDTHH:MM:SS): the time of day is outside 00:00:00..23:59:59",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","durationSeconds":0}'), series),
        "DURATION_ZERO",
        "durationSeconds",
        "a timed event lasts at least one second",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-10-14T09:30:00","days":1}'), series),
        "TIMED_WITH_DATE",
        "days",
        "a timed event lasts durationSeconds, not days",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-11-27","durationSeconds":60}'), all_day),
        "ALL_DAY_WITH_TIME",
        "durationSeconds",
        "an all-day event lasts days, not durationSeconds",
    )

    _refused(
        check_override(_edit('{"originalStart":"2026-11-27","days":0}'), all_day),
        "DAYS_OUT_OF_RANGE",
        "days",
        "days 0 is outside 1..366",
    )


def test_error_envelope() raises:
    var r = check_calendar(decode_json[Calendar]('{"name":"Work","timeZone":"Europe//Paris"}'))
    assert_equal(
        encode_json(error_response(r.value())),
        '{"error":{"code":"TIME_ZONE_MALFORMED","message":"timeZone is not shaped like an IANA time zone'
        + ' name","field":"timeZone"}}',
    )


def main() raises:
    print("test_calendar_override_table: check_calendar, check_override, error_response")
    test_calendar()
    test_override()
    test_error_envelope()
    print("ALL check_calendar / check_override ROWS PASSED")
