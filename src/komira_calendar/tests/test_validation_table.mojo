# =============================================================================
# test_validation_table.mojo: check_event, row by row.
#
# Two valid events are the baselines: a timed weekly series (TIMED) and an
# all-day event (ALL_DAY), each read from the API's JSON form. Every row below
# changes ONE field of a baseline and asserts the refusal's exact code, JSON
# field path and message, so a check that is dropped, weakened or renamed
# turns its row red: the event is then accepted ("accepted; want <code>"),
# or refused by a later check with another code. The boundary rows
# (test_event_accepts_each_bound) pin each limit's last allowed value, so a
# check that tightens a bound by one turns red too.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from komira_calendar_proto.calendar import (
    Event,
    EventStatus,
    Frequency,
    Recurrence,
    Reminder,
    Weekday,
)
from komira_calendar import Refusal, check_event


comptime TIMED = (
    '{"uid":"weekly-sync","title":"Weekly sync","start":"2026-10-12T09:00:00",'
    + '"timeZone":"Europe/London","durationSeconds":1800,'
    + '"recurrence":{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY","THURSDAY"],'
    + '"until":"2026-12-31"},'
    + '"exdates":["2026-10-15T09:00:00"],'
    + '"reminders":[{"minutesBefore":10},{"minutesBefore":60}]}'
)
comptime ALL_DAY = (
    '{"uid":"offsite","title":"Team offsite","showWithoutTime":true,'
    + '"startDate":"2026-11-02","days":3}'
)


def _timed() raises -> Event:
    return decode_json[Event](TIMED)


def _all_day() raises -> Event:
    return decode_json[Event](ALL_DAY)


def _repeat(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s


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


def test_baselines_are_valid() raises:
    _accepted(check_event(_timed()), "TIMED")
    _accepted(check_event(_all_day()), "ALL_DAY")
    var e = _timed()
    assert_equal(e.duration_seconds, UInt32(1800))
    assert_equal(len(e.recurrence.value().weekdays), 2)
    assert_true(_all_day().show_without_time)


def test_event_text() raises:
    var e = _timed()
    e.title = _repeat("t", 1025)
    _refused(check_event(e), "TEXT_TOO_LONG", "title", "title is 1025 bytes; at most 1024 are allowed")

    e = _timed()
    e.title = "Weekly\nsync"
    _refused(check_event(e), "TEXT_CONTROL_CHARACTER", "title", "title holds control character 0xa at byte 6")

    e = _timed()
    e.uid = _repeat("u", 256)
    _refused(check_event(e), "TEXT_TOO_LONG", "uid", "uid is 256 bytes; at most 255 are allowed")

    e = _timed()
    e.location = _repeat("l", 1025)
    _refused(check_event(e), "TEXT_TOO_LONG", "location", "location is 1025 bytes; at most 1024 are allowed")

    e = _timed()
    e.location = "Room\r1"
    _refused(check_event(e), "TEXT_CONTROL_CHARACTER", "location", "location holds control character 0xd at byte 4")

    e = _timed()
    e.description = _repeat("d", 65537)
    _refused(
        check_event(e), "TEXT_TOO_LONG", "description", "description is 65537 bytes; at most 65536 are allowed"
    )

    e = _timed()
    e.description = "agenda" + chr(1)
    _refused(
        check_event(e), "TEXT_CONTROL_CHARACTER", "description", "description holds control character 0x1 at byte 6"
    )

    e = _timed()
    e.description = "line one\nline two\r\n\tindented"
    _accepted(check_event(e), "a multi-line description")


def test_event_status() raises:
    var e = _timed()
    e.status = EventStatus(7)
    _refused(check_event(e), "STATUS_UNKNOWN", "status", "status 7 is not CONFIRMED or CANCELLED")
    e.status = EventStatus(EventStatus.CANCELLED)
    _accepted(check_event(e), "a cancelled event")


def test_timed_event() raises:
    var e = _timed()
    e.start_date = "2026-10-12"
    _refused(check_event(e), "TIMED_WITH_DATE", "startDate", "a timed event starts on start, not startDate")

    e = _timed()
    e.days = 1
    _refused(check_event(e), "TIMED_WITH_DATE", "days", "a timed event lasts durationSeconds, not days")

    e = _timed()
    e.start = ""
    _refused(check_event(e), "START_REQUIRED", "start", "a timed event needs start")

    e = _timed()
    e.start = "2026-10-12 09:00:00"
    _refused(
        check_event(e),
        "START_MALFORMED",
        "start",
        "start is not a local date-time (YYYY-MM-DDTHH:MM:SS): a local date-time has 'T' between the date and the time",
    )

    e = _timed()
    e.start = "2026-10-12T09:00:00Z"
    _refused(
        check_event(e),
        "START_MALFORMED",
        "start",
        "start is not a local date-time (YYYY-MM-DDTHH:MM:SS): a local date-time is YYYY-MM-DDTHH:MM:SS, nineteen bytes",
    )

    e = _timed()
    e.start = "2026-10-12T24:00:00"
    _refused(
        check_event(e),
        "START_MALFORMED",
        "start",
        "start is not a local date-time (YYYY-MM-DDTHH:MM:SS): the time of day is outside 00:00:00..23:59:59",
    )

    e = _timed()
    e.time_zone = ""
    _refused(
        check_event(e),
        "TIME_ZONE_REQUIRED",
        "timeZone",
        "a timed event needs timeZone; floating times are not supported",
    )

    e = _timed()
    e.time_zone = "Europe//London"
    _refused(check_event(e), "TIME_ZONE_MALFORMED", "timeZone", "timeZone is not shaped like an IANA time zone name")

    e = _timed()
    e.duration_seconds = 0
    _refused(check_event(e), "DURATION_ZERO", "durationSeconds", "a timed event lasts at least one second")

    e = _timed()
    e.duration_seconds = UInt32(366 * 86400 + 1)
    _refused(check_event(e), "DURATION_TOO_LONG", "durationSeconds", "durationSeconds 31622401 is above 31622400")


def test_all_day_event() raises:
    # The all-day-with-a-zone row is read from JSON, as a client sends it.
    var zoned = decode_json[Event](
        '{"showWithoutTime":true,"startDate":"2026-11-02","days":1,"timeZone":"Europe/Paris"}'
    )
    _refused(check_event(zoned), "ALL_DAY_WITH_ZONE", "timeZone", "an all-day event has no time zone")

    var e = _all_day()
    e.start = "2026-11-02T09:00:00"
    _refused(check_event(e), "ALL_DAY_WITH_TIME", "start", "an all-day event starts on startDate, not start")

    e = _all_day()
    e.duration_seconds = 3600
    _refused(
        check_event(e), "ALL_DAY_WITH_TIME", "durationSeconds", "an all-day event lasts days, not durationSeconds"
    )

    e = _all_day()
    e.start_date = ""
    _refused(check_event(e), "START_DATE_REQUIRED", "startDate", "an all-day event needs startDate")

    e = _all_day()
    e.start_date = "2027-02-30"
    _refused(
        check_event(e),
        "START_MALFORMED",
        "startDate",
        "startDate is not a local date (YYYY-MM-DD): day 30 does not exist in month 2 of year 2027",
    )

    e = _all_day()
    e.days = 0
    _refused(check_event(e), "DAYS_OUT_OF_RANGE", "days", "days 0 is outside 1..366")

    e = _all_day()
    e.days = 367
    _refused(check_event(e), "DAYS_OUT_OF_RANGE", "days", "days 367 is outside 1..366")


def _rule(freq: Int) -> Recurrence:
    return Recurrence(Frequency(freq), UInt32(1), List[Weekday](), UInt32(0), Int32(0), Weekday(0), UInt32(0), "")


def _with_rule(var rule: Recurrence) raises -> Event:
    var e = _timed()
    e.exdates = List[String]()
    e.recurrence = Optional[Recurrence](rule^)
    return e^


def test_recurrence_frequency_and_interval() raises:
    var e = _timed()
    e.recurrence.value().freq = Frequency(Frequency.FREQUENCY_UNSPECIFIED)
    _refused(
        check_event(e),
        "FREQUENCY_REQUIRED",
        "recurrence.freq",
        "a recurrence needs freq: DAILY, WEEKLY, MONTHLY or YEARLY",
    )

    e = _timed()
    e.recurrence.value().freq = Frequency(9)
    _refused(
        check_event(e),
        "FREQUENCY_UNKNOWN",
        "recurrence.freq",
        "freq 9 is not DAILY, WEEKLY, MONTHLY or YEARLY",
    )

    e = _timed()
    e.recurrence.value().interval = 0
    _refused(check_event(e), "INTERVAL_OUT_OF_RANGE", "recurrence.interval", "interval 0 is outside 1..999")

    e = _timed()
    e.recurrence.value().interval = 1000
    _refused(check_event(e), "INTERVAL_OUT_OF_RANGE", "recurrence.interval", "interval 1000 is outside 1..999")


def test_recurrence_weekdays() raises:
    var daily = _rule(Frequency.DAILY)
    daily.weekdays.append(Weekday(Weekday.MONDAY))
    _refused(
        check_event(_with_rule(daily^)),
        "WEEKDAYS_NOT_WEEKLY",
        "recurrence.weekdays",
        "weekdays apply to a WEEKLY rule only",
    )

    var e = _timed()
    e.recurrence.value().weekdays.append(Weekday(Weekday.WEEKDAY_UNSPECIFIED))
    _refused(
        check_event(e),
        "WEEKDAY_UNKNOWN",
        "recurrence.weekdays[2]",
        "weekday 0 is not MONDAY..SUNDAY",
    )

    e = _timed()
    e.recurrence.value().weekdays.append(Weekday(8))
    _refused(check_event(e), "WEEKDAY_UNKNOWN", "recurrence.weekdays[2]", "weekday 8 is not MONDAY..SUNDAY")

    e = _timed()
    e.recurrence.value().weekdays.append(Weekday(Weekday.MONDAY))
    _refused(check_event(e), "WEEKDAY_DUPLICATE", "recurrence.weekdays[2]", "MONDAY is named twice")


def test_recurrence_monthly() raises:
    var both = _rule(Frequency.MONTHLY)
    both.month_day = 12
    both.ordinal = 2
    both.ordinal_weekday = Weekday(Weekday.MONDAY)
    _refused(
        check_event(_with_rule(both^)),
        "MONTHLY_RULE_AMBIGUOUS",
        "recurrence.monthDay",
        "a MONTHLY rule names monthDay or ordinal with ordinalWeekday, not both",
    )

    _refused(
        check_event(_with_rule(_rule(Frequency.MONTHLY))),
        "MONTHLY_RULE_REQUIRED",
        "recurrence.monthDay",
        "a MONTHLY rule names monthDay, or ordinal with ordinalWeekday",
    )

    var day = _rule(Frequency.MONTHLY)
    day.month_day = 32
    _refused(
        check_event(_with_rule(day^)),
        "MONTH_DAY_OUT_OF_RANGE",
        "recurrence.monthDay",
        "monthDay 32 is outside 1..31",
    )

    for bad in [5, -2]:
        var ord = _rule(Frequency.MONTHLY)
        ord.ordinal = Int32(bad)
        ord.ordinal_weekday = Weekday(Weekday.FRIDAY)
        _refused(
            check_event(_with_rule(ord^)),
            "ORDINAL_OUT_OF_RANGE",
            "recurrence.ordinal",
            "ordinal " + String(bad) + " is not 1 to 4, or -1 for the last",
        )

    var no_weekday = _rule(Frequency.MONTHLY)
    no_weekday.ordinal = -1
    _refused(
        check_event(_with_rule(no_weekday^)),
        "ORDINAL_WEEKDAY_REQUIRED",
        "recurrence.ordinalWeekday",
        "an ordinal needs ordinalWeekday",
    )

    var no_ordinal = _rule(Frequency.MONTHLY)
    no_ordinal.ordinal_weekday = Weekday(Weekday.FRIDAY)
    _refused(
        check_event(_with_rule(no_ordinal^)),
        "ORDINAL_REQUIRED",
        "recurrence.ordinal",
        "ordinalWeekday needs an ordinal: 1 to 4, or -1 for the last",
    )

    var bad_weekday = _rule(Frequency.MONTHLY)
    bad_weekday.ordinal = 1
    bad_weekday.ordinal_weekday = Weekday(8)
    _refused(
        check_event(_with_rule(bad_weekday^)),
        "WEEKDAY_UNKNOWN",
        "recurrence.ordinalWeekday",
        "weekday 8 is not MONDAY..SUNDAY",
    )

    var weekly_day = _rule(Frequency.WEEKLY)
    weekly_day.month_day = 3
    _refused(
        check_event(_with_rule(weekly_day^)),
        "MONTHLY_FIELDS_NOT_MONTHLY",
        "recurrence.monthDay",
        "monthDay applies to a MONTHLY rule only",
    )

    var yearly_ord = _rule(Frequency.YEARLY)
    yearly_ord.ordinal = 1
    yearly_ord.ordinal_weekday = Weekday(Weekday.MONDAY)
    _refused(
        check_event(_with_rule(yearly_ord^)),
        "MONTHLY_FIELDS_NOT_MONTHLY",
        "recurrence.ordinal",
        "ordinal applies to a MONTHLY rule only",
    )

    var daily_wd = _rule(Frequency.DAILY)
    daily_wd.ordinal_weekday = Weekday(Weekday.MONDAY)
    _refused(
        check_event(_with_rule(daily_wd^)),
        "MONTHLY_FIELDS_NOT_MONTHLY",
        "recurrence.ordinalWeekday",
        "ordinalWeekday applies to a MONTHLY rule only",
    )


def test_recurrence_end() raises:
    var e = _timed()
    e.recurrence.value().count = 5
    _refused(
        check_event(e),
        "COUNT_WITH_UNTIL",
        "recurrence.count",
        "a recurrence ends by count or by until, not both",
    )

    e = _timed()
    e.recurrence.value().until = ""
    e.recurrence.value().count = 10001
    _refused(check_event(e), "COUNT_OUT_OF_RANGE", "recurrence.count", "count 10001 is above 10000")

    e = _timed()
    e.recurrence.value().until = "2027-13-01"
    _refused(
        check_event(e),
        "UNTIL_MALFORMED",
        "recurrence.until",
        "until is not a local date (YYYY-MM-DD): month 13 is outside 1..12",
    )

    e = _timed()
    e.recurrence.value().until = "2026-10-11"
    _refused(
        check_event(e),
        "UNTIL_BEFORE_START",
        "recurrence.until",
        "until 2026-10-11 is before the event's first day",
    )


def test_exdates() raises:
    var e = _timed()
    e.recurrence = None
    _refused(
        check_event(e),
        "EXDATES_WITHOUT_RECURRENCE",
        "exdates",
        "only a recurring event has occurrences to exclude",
    )

    e = _timed()
    e.exdates = List[String]()
    for i in range(1001):
        e.exdates.append(String(i))
    _refused(check_event(e), "TOO_MANY_EXDATES", "exdates", "exdates holds 1001; at most 1000 are allowed")

    e = _timed()
    e.exdates.append("2026-10-19")
    _refused(
        check_event(e),
        "EXDATE_MALFORMED",
        "exdates[1]",
        "exdates[1] is not a local date-time (YYYY-MM-DDTHH:MM:SS): a local date-time is YYYY-MM-DDTHH:MM:SS,"
        + " nineteen bytes",
    )

    var a = _all_day()
    a.recurrence = Optional[Recurrence](_rule(Frequency.YEARLY))
    a.exdates.append("2027-11-02T00:00:00")
    _refused(
        check_event(a),
        "EXDATE_MALFORMED",
        "exdates[0]",
        "exdates[0] is not a local date (YYYY-MM-DD): a date is YYYY-MM-DD, ten bytes",
    )

    e = _timed()
    e.exdates.append("2026-10-15T09:00:00")
    _refused(check_event(e), "EXDATE_DUPLICATE", "exdates[1]", "2026-10-15T09:00:00 is excluded twice")


def test_reminders() raises:
    var e = _timed()
    for m in [0, 5, 15, 30]:
        e.reminders.append(Reminder(UInt32(m)))
    _refused(check_event(e), "TOO_MANY_REMINDERS", "reminders", "reminders holds 6; at most 5 are allowed")

    e = _timed()
    e.reminders.append(Reminder(UInt32(40321)))
    _refused(
        check_event(e),
        "REMINDER_OUT_OF_RANGE",
        "reminders[2].minutesBefore",
        "minutesBefore 40321 is above 40320",
    )

    e = _timed()
    e.reminders.append(Reminder(UInt32(10)))
    _refused(
        check_event(e),
        "REMINDER_DUPLICATE",
        "reminders[2].minutesBefore",
        "a reminder 10 minutes before is set twice",
    )


def test_event_accepts_each_bound() raises:
    var e = _timed()
    e.title = _repeat("t", 1024)
    e.uid = _repeat("u", 255)
    e.location = _repeat("l", 1024)
    e.description = _repeat("d", 65536)
    e.duration_seconds = UInt32(366 * 86400)
    for m in [0, 15, 40320]:
        e.reminders.append(Reminder(UInt32(m)))
    e.recurrence.value().interval = 999
    e.recurrence.value().until = "2026-10-12"
    _accepted(check_event(e), "every timed bound at its limit")

    var a = _all_day()
    a.days = 366
    _accepted(check_event(a), "days 366")

    var counted = _rule(Frequency.DAILY)
    counted.count = 10000
    _accepted(check_event(_with_rule(counted^)), "count 10000")

    var last_friday = _rule(Frequency.MONTHLY)
    last_friday.ordinal = -1
    last_friday.ordinal_weekday = Weekday(Weekday.FRIDAY)
    _accepted(check_event(_with_rule(last_friday^)), "the last Friday of each month")

    var day31 = _rule(Frequency.MONTHLY)
    day31.month_day = 31
    _accepted(check_event(_with_rule(day31^)), "day 31 of each month")

    var many = _timed()
    many.exdates = List[String]()
    for i in range(1000):
        var d = 1 + i % 28
        var m = 1 + (i // 28) % 12
        var y = 2027 + i // 336
        var text = String(y) + "-" + ("0" if m < 10 else "") + String(m) + "-"
        text += ("0" if d < 10 else "") + String(d) + "T09:00:00"
        many.exdates.append(text)
    _accepted(check_event(many), "1000 exdates")


def main() raises:
    print("test_validation_table: check_event")
    test_baselines_are_valid()
    test_event_text()
    test_event_status()
    test_timed_event()
    test_all_day_event()
    test_recurrence_frequency_and_interval()
    test_recurrence_weekdays()
    test_recurrence_monthly()
    test_recurrence_end()
    test_exdates()
    test_reminders()
    test_event_accepts_each_bound()
    print("ALL check_event ROWS PASSED")
