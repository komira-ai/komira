# =============================================================================
# test_span.mojo -- utc_span against instants worked out by hand.
# =============================================================================
#
# The zone is America/New_York from its POSIX rule alone (EST5EDT: UTC-5,
# UTC-4 from the second Sunday of March 02:00 to the first Sunday of
# November 02:00), so no zone data is read. The clock skips 02:00-03:00 on
# 14 March 2027 and shows 01:00-02:00 twice on 1 November 2026; 19 and
# 26 October and 2 November 2026 are Mondays. Expected instants are written
# as UTC fields (komira_datetime.seconds_from_fields), not through the zone.
#
# Every row runs, and the test fails at the end naming each wrong row. The
# defect each row catches:
#   single        the zone not applied (local seconds stored as UTC)
#   dst_end       the last occurrence read with the first one's offset
#   open          an open series stored with an end other than OPEN_END
#   all_day       the all-day slack missing or applied the wrong way
#   gap           a start in a gap given its later instant
#   fold          an end in a fold given its earlier instant
#   moved_later   an override's start not widening the end
#   moved_earlier an override's start not widening the start
#   longer        an override's duration ignored
#   all_day_days  an all-day override's days ignored
#   open_override an override's end replacing OPEN_END (max not taken)
#   cancelled     a cancelled override changing the range
#   no_pick       a rule that picks no day given a range a window can match
# =============================================================================

from std.testing import assert_equal

from komira_calendar import OPEN_END
from komira_calendar_proto.calendar import Event, OccurrenceOverride
from komira_datetime import Zone, posix_zone, seconds_from_fields
from komira_proto_codec import decode_json

from komira_calendar_store import ALL_DAY_SLACK_SECONDS, NO_END, NO_START, UtcSpan, utc_span


def _ny() raises -> Optional[Zone]:
    return Optional[Zone](posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))


def _utc(month: Int, day: Int, hour: Int, minute: Int = 0) raises -> Int:
    return seconds_from_fields(2026, month, day, hour, minute, 0)


def _utc27(month: Int, day: Int, hour: Int, minute: Int = 0) raises -> Int:
    return seconds_from_fields(2027, month, day, hour, minute, 0)


def _timed(start: String, duration: Int, recurrence: String = "") raises -> Event:
    var text = '{"title":"t","start":"' + start + '","timeZone":"America/New_York","durationSeconds":' + String(
        duration
    )
    if recurrence.byte_length() > 0:
        text += ',"recurrence":' + recurrence
    return decode_json[Event](text + "}")


def _all_day(start_date: String, days: Int, recurrence: String = "") raises -> Event:
    var text = '{"title":"d","showWithoutTime":true,"startDate":"' + start_date + '","days":' + String(days)
    if recurrence.byte_length() > 0:
        text += ',"recurrence":' + recurrence
    return decode_json[Event](text + "}")


def _edits(json: String) raises -> List[OccurrenceOverride]:
    var out = List[OccurrenceOverride]()
    out.append(decode_json[OccurrenceOverride](json))
    return out^


def _none() -> List[OccurrenceOverride]:
    return List[OccurrenceOverride]()


def _row(mut failures: String, name: String, got: UtcSpan, first: Int, last: Int):
    var want = UtcSpan(first, last)
    if got != want:
        failures += "FAIL " + name + ": got " + String(got) + ", want " + String(want) + "\n"


comptime WEEKLY_2 = '{"freq":"WEEKLY","interval":1,"count":2}'


def main() raises:
    var f = String()
    var ny = _ny()
    var day = ALL_DAY_SLACK_SECONDS

    _row(f, "single", utc_span(_timed("2026-10-12T09:00:00", 3600), _none(), ny), _utc(10, 12, 13), _utc(10, 12, 14))
    _row(
        f,
        "dst_end",
        utc_span(_timed("2026-10-19T09:00:00", 3600, '{"freq":"WEEKLY","interval":1,"count":3}'), _none(), ny),
        _utc(10, 19, 13),
        _utc(11, 2, 15),
    )
    _row(
        f,
        "open",
        utc_span(_timed("2026-10-12T09:00:00", 3600, '{"freq":"DAILY","interval":1}'), _none(), ny),
        _utc(10, 12, 13),
        OPEN_END,
    )
    _row(f, "all_day", utc_span(_all_day("2026-10-12", 2), _none(), None), _utc(10, 12, 0) - day, _utc(10, 14, 0) + day)
    _row(f, "gap", utc_span(_timed("2027-03-14T02:30:00", 1800), _none(), ny), _utc27(3, 14, 6, 30), _utc27(3, 14, 8))
    _row(f, "fold", utc_span(_timed("2026-11-01T01:30:00", 1800), _none(), ny), _utc(11, 1, 5, 30), _utc(11, 1, 7))

    var weekly = _timed("2026-10-19T09:00:00", 3600, WEEKLY_2)
    _row(
        f,
        "moved_later",
        utc_span(
            weekly, _edits('{"eventId":"e","originalStart":"2026-10-26T09:00:00","start":"2026-11-05T18:00:00"}'), ny
        ),
        _utc(10, 19, 13),
        _utc(11, 6, 0),
    )
    _row(
        f,
        "moved_earlier",
        utc_span(
            weekly, _edits('{"eventId":"e","originalStart":"2026-10-19T09:00:00","start":"2026-10-10T08:00:00"}'), ny
        ),
        _utc(10, 10, 12),
        _utc(10, 26, 14),
    )
    _row(
        f,
        "longer",
        utc_span(weekly, _edits('{"eventId":"e","originalStart":"2026-10-26T09:00:00","durationSeconds":36000}'), ny),
        _utc(10, 19, 13),
        _utc(10, 26, 23),
    )
    _row(
        f,
        "all_day_days",
        utc_span(
            _all_day("2026-10-19", 1, WEEKLY_2), _edits('{"eventId":"e","originalStart":"2026-10-26","days":5}'), None
        ),
        _utc(10, 19, 0) - day,
        _utc(10, 31, 0) + day,
    )
    _row(
        f,
        "open_override",
        utc_span(
            _timed("2026-10-12T09:00:00", 3600, '{"freq":"DAILY","interval":1}'),
            _edits('{"eventId":"e","originalStart":"2026-10-13T09:00:00","start":"2026-10-14T10:00:00"}'),
            ny,
        ),
        _utc(10, 12, 13),
        OPEN_END,
    )
    _row(
        f,
        "cancelled",
        utc_span(weekly, _edits('{"eventId":"e","originalStart":"2026-10-26T09:00:00","cancelled":true}'), ny),
        _utc(10, 19, 13),
        _utc(10, 26, 14),
    )
    _row(
        f,
        "no_pick",
        utc_span(
            _timed("2026-11-30T09:00:00", 3600, '{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2026-12-30"}'),
            _none(),
            ny,
        ),
        NO_START,
        NO_END,
    )
    assert_equal(f, String(), "utc_span rows")
    # The form the failure lines above print a span in.
    assert_equal(String(UtcSpan(1, 2)), "[1, 2)")
    print("PASS test_span: 13 rows")
