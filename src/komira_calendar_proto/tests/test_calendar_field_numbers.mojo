# =============================================================================
# test_calendar_field_numbers.mojo
# =============================================================================
#
# THE WIRE CENSUS for `komira.calendar.v1`: field numbers as binary bytes,
# field names as proto3 JSON keys, enum numbers as their names.
#
# A proto field number is what the binary form stores, and a JSON key is
# what the API's clients send. Renumbering a field, or renaming one, is
# legal to protoc and compiles clean; a stored or sent message then decodes
# as the WRONG field, or a client's key is refused. Nothing in the toolchain
# objects, so this file is the guard.
#
# BINARY. For every message, a byte stream is written by hand here, field by
# field, with the number and wire type the proto declares and a value no
# other field of that message of the same wire type holds. Then:
#   1. it is decoded, and every field is read back BY NAME. This catches two
#      fields of one wire type swapping numbers, which a pure round trip
#      would not see.
#   2. the decoded message is encoded again and must give the hand-written
#      bytes back exactly. The encoder writes fields in declaration order
#      (which is number order in this file) and each repeated element as its
#      own tagged record. This catches a field moved to an unused number and
#      a changed wire type.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
#
# JSON. A fully set Event and OccurrenceOverride are encoded as proto3 JSON
# and compared with a literal document: every key (the lowerCamel JSON name)
# and every value form (an int64/uint64 as a string, an enum as its name, a
# Timestamp as RFC 3339).
#
# ENUMS. Each value's number and name, both ways.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from komira_wkt import Timestamp
from komira_calendar_proto.calendar import (
    ApiError,
    Calendar,
    ErrorResponse,
    Event,
    EventStatus,
    Frequency,
    OccurrenceOverride,
    Recurrence,
    Reminder,
    Weekday,
)


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    """A varint record: tag (wire type 0), then the value."""
    _varint(b, UInt64(field << 3))
    _varint(b, v)


def _int32(mut b: List[UInt8], field: Int, v: Int32):
    """A proto `int32` record: a negative value sign-extends to 64 bits."""
    _uint(b, field, UInt64(Int64(v)))


def _str(mut b: List[UInt8], field: Int, s: String):
    """A length-delimited record (wire type 2) holding `s`."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _msg(mut b: List[UInt8], field: Int, m: List[UInt8]):
    """A length-delimited record (wire type 2) holding an encoded message."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _timestamp(seconds: UInt64, nanos: UInt64) -> List[UInt8]:
    """google.protobuf.Timestamp: 1 seconds (int64), 2 nanos (int32).
    komira_wkt's Timestamp writes both, a zero nanos included."""
    var b = List[UInt8]()
    _uint(b, 1, seconds)
    _uint(b, 2, nanos)
    return b^


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
    return out


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(_hex(got), _hex(want), what + ": re-encode differs from the hand-written bytes")


def _recurrence_bytes() -> List[UInt8]:
    var b = List[UInt8]()
    _uint(b, 1, 2)  # freq WEEKLY
    _uint(b, 2, 3)  # interval
    _uint(b, 3, 1)  # weekdays MONDAY
    _uint(b, 3, 4)  # weekdays THURSDAY
    _uint(b, 4, 15)  # month_day
    _int32(b, 5, -1)  # ordinal (the last)
    _uint(b, 6, 5)  # ordinal_weekday FRIDAY
    _uint(b, 7, 12)  # count
    _str(b, 8, "2026-12-31")  # until
    return b^


def _reminder_bytes(minutes: UInt64) -> List[UInt8]:
    var b = List[UInt8]()
    _uint(b, 1, minutes)
    return b^


def test_calendar() raises:
    """Calendar: 1 id, 2 owner, 3 name, 4 color, 5 time_zone, 6 version,
    7 created_at, 8 updated_at."""
    var b = List[UInt8]()
    _str(b, 1, "cal-1")
    _str(b, 2, "subject-1")
    _str(b, 3, "Work")
    _str(b, 4, "#a0b1c2")
    _str(b, 5, "Europe/London")
    _uint(b, 6, 7)
    _msg(b, 7, _timestamp(1790000000, 5))
    _msg(b, 8, _timestamp(1790000100, 6))
    var c = decode_proto[Calendar](b.copy())
    assert_equal(c.id, "cal-1")
    assert_equal(c.owner, "subject-1")
    assert_equal(c.name, "Work")
    assert_equal(c.color, "#a0b1c2")
    assert_equal(c.time_zone, "Europe/London")
    assert_equal(c.version, UInt64(7))
    assert_equal(c.created_at.value().seconds, Int64(1790000000))
    assert_equal(c.created_at.value().nanos, Int32(5))
    assert_equal(c.updated_at.value().seconds, Int64(1790000100))
    _same(encode_proto(c), b, "Calendar")


def test_recurrence() raises:
    """Recurrence: 1 freq, 2 interval, 3 weekdays (repeated enum), 4
    month_day, 5 ordinal (int32: -1 is a sign-extended 10-byte varint), 6
    ordinal_weekday, 7 count, 8 until."""
    var b = _recurrence_bytes()
    var r = decode_proto[Recurrence](b.copy())
    assert_equal(r.freq.value, Frequency.WEEKLY)
    assert_equal(r.interval, UInt32(3))
    assert_equal(len(r.weekdays), 2)
    assert_equal(r.weekdays[0].value, Weekday.MONDAY)
    assert_equal(r.weekdays[1].value, Weekday.THURSDAY)
    assert_equal(r.month_day, UInt32(15))
    assert_equal(r.ordinal, Int32(-1))
    assert_equal(r.ordinal_weekday.value, Weekday.FRIDAY)
    assert_equal(r.count, UInt32(12))
    assert_equal(r.until, "2026-12-31")
    _same(encode_proto(r), b, "Recurrence")


def test_reminder() raises:
    """Reminder: 1 minutes_before."""
    var b = _reminder_bytes(45)
    assert_equal(decode_proto[Reminder](b.copy()).minutes_before, UInt32(45))
    _same(encode_proto(decode_proto[Reminder](b.copy())), b, "Reminder")


def _event_bytes() -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, "evt-1")
    _str(b, 2, "cal-1")
    _str(b, 3, "uid-1")
    _str(b, 4, "Title")
    _str(b, 5, "Description")
    _str(b, 6, "Location")
    _uint(b, 7, 1)  # show_without_time
    _str(b, 8, "2026-11-02")  # start_date
    _uint(b, 9, 3)  # days
    _str(b, 10, "2026-10-12T09:00:00")  # start
    _str(b, 11, "Asia/Kathmandu")  # time_zone
    _uint(b, 12, 1800)  # duration_seconds
    _uint(b, 13, 1)  # status CANCELLED
    _msg(b, 14, _recurrence_bytes())
    _str(b, 15, "2026-10-15T09:00:00")  # exdates[0]
    _str(b, 15, "2026-10-22T09:00:00")  # exdates[1]
    _msg(b, 16, _reminder_bytes(10))
    _msg(b, 16, _reminder_bytes(60))
    _uint(b, 17, 42)  # version
    _msg(b, 18, _timestamp(1790000000, 0))
    _msg(b, 19, _timestamp(1791000000, 0))
    return b^


def test_event() raises:
    """Event: 1 id, 2 calendar_id, 3 uid, 4 title, 5 description, 6 location,
    7 show_without_time, 8 start_date, 9 days, 10 start, 11 time_zone, 12
    duration_seconds, 13 status, 14 recurrence, 15 exdates, 16 reminders, 17
    version, 18 created_at, 19 updated_at."""
    var b = _event_bytes()
    var e = decode_proto[Event](b.copy())
    assert_equal(e.id, "evt-1")
    assert_equal(e.calendar_id, "cal-1")
    assert_equal(e.uid, "uid-1")
    assert_equal(e.title, "Title")
    assert_equal(e.description, "Description")
    assert_equal(e.location, "Location")
    assert_true(e.show_without_time)
    assert_equal(e.start_date, "2026-11-02")
    assert_equal(e.days, UInt32(3))
    assert_equal(e.start, "2026-10-12T09:00:00")
    assert_equal(e.time_zone, "Asia/Kathmandu")
    assert_equal(e.duration_seconds, UInt32(1800))
    assert_equal(e.status.value, EventStatus.CANCELLED)
    assert_equal(e.recurrence.value().count, UInt32(12))
    assert_equal(len(e.exdates), 2)
    assert_equal(e.exdates[1], "2026-10-22T09:00:00")
    assert_equal(len(e.reminders), 2)
    assert_equal(e.reminders[1].minutes_before, UInt32(60))
    assert_equal(e.version, UInt64(42))
    assert_equal(e.created_at.value().seconds, Int64(1790000000))
    assert_equal(e.updated_at.value().seconds, Int64(1791000000))
    _same(encode_proto(e), b, "Event")


def _override_bytes() -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, "evt-1")
    _str(b, 2, "2026-10-14T09:30:00")  # original_start
    _uint(b, 3, 1)  # cancelled
    _str(b, 4, "Moved")  # title
    _str(b, 5, "2026-10-14T11:00:00")  # start
    _uint(b, 6, 1200)  # duration_seconds
    _str(b, 7, "Room 2")  # location
    _str(b, 8, "Notes")  # description
    _uint(b, 9, 2)  # days
    _uint(b, 10, 9)  # version
    return b^


def test_occurrence_override() raises:
    """OccurrenceOverride: 1 event_id, 2 original_start, 3 cancelled, 4 title,
    5 start, 6 duration_seconds, 7 location, 8 description, 9 days, 10
    version. 4 to 9 have presence: unset is absent, an empty or zero value
    set is written."""
    var b = _override_bytes()
    var o = decode_proto[OccurrenceOverride](b.copy())
    assert_equal(o.event_id, "evt-1")
    assert_equal(o.original_start, "2026-10-14T09:30:00")
    assert_true(o.cancelled)
    assert_equal(o.title.value(), "Moved")
    assert_equal(o.start.value(), "2026-10-14T11:00:00")
    assert_equal(o.duration_seconds.value(), UInt32(1200))
    assert_equal(o.location.value(), "Room 2")
    assert_equal(o.description.value(), "Notes")
    assert_equal(o.days.value(), UInt32(2))
    assert_equal(o.version, UInt64(9))
    _same(encode_proto(o), b, "OccurrenceOverride")

    # The binary encoder writes an implicit-presence field at zero too, so
    # these streams set cancelled and version; only 4 to 9 vary.
    var unset = List[UInt8]()
    _str(unset, 1, "evt-1")
    _str(unset, 2, "2026-10-14T09:30:00")
    _uint(unset, 3, 1)
    _uint(unset, 10, 9)
    var u = decode_proto[OccurrenceOverride](unset.copy())
    assert_false(Bool(u.title), "field 4 absent decodes unset")
    assert_false(Bool(u.days), "field 9 absent decodes unset")
    _same(encode_proto(u), unset, "OccurrenceOverride with no replacement")

    var empty = List[UInt8]()
    _str(empty, 1, "evt-1")
    _str(empty, 2, "2026-10-14T09:30:00")
    _uint(empty, 3, 1)
    _str(empty, 4, "")
    _uint(empty, 6, 0)
    _uint(empty, 10, 9)
    var z = decode_proto[OccurrenceOverride](empty.copy())
    assert_true(Bool(z.title), "field 4 present as empty is set")
    assert_equal(z.title.value(), "")
    assert_true(Bool(z.duration_seconds), "field 6 present as 0 is set")
    _same(encode_proto(z), empty, "OccurrenceOverride with an empty title and a zero duration")


def test_error_envelope() raises:
    """ApiError: 1 code, 2 message, 3 field. ErrorResponse: 1 error."""
    var inner = List[UInt8]()
    _str(inner, 1, "DURATION_ZERO")
    _str(inner, 2, "a message")
    _str(inner, 3, "durationSeconds")
    var a = decode_proto[ApiError](inner.copy())
    assert_equal(a.code, "DURATION_ZERO")
    assert_equal(a.message, "a message")
    assert_equal(a.field, "durationSeconds")
    _same(encode_proto(a), inner, "ApiError")

    var outer = List[UInt8]()
    _msg(outer, 1, inner)
    var r = decode_proto[ErrorResponse](outer.copy())
    assert_equal(r.error.value().code, "DURATION_ZERO")
    _same(encode_proto(r), outer, "ErrorResponse")


comptime EVENT_JSON = (
    '{"id":"evt-1","calendarId":"cal-1","uid":"uid-1","title":"Title","description":"Description",'
    + '"location":"Location","showWithoutTime":true,"startDate":"2026-11-02","days":3,'
    + '"start":"2026-10-12T09:00:00","timeZone":"Asia/Kathmandu","durationSeconds":1800,'
    + '"status":"CANCELLED","recurrence":{"freq":"WEEKLY","interval":3,"weekdays":["MONDAY","THURSDAY"],'
    + '"monthDay":15,"ordinal":-1,"ordinalWeekday":"FRIDAY","count":12,"until":"2026-12-31"},'
    + '"exdates":["2026-10-15T09:00:00","2026-10-22T09:00:00"],'
    + '"reminders":[{"minutesBefore":10},{"minutesBefore":60}],"version":"42",'
    + '"createdAt":"2026-09-21T14:13:20Z","updatedAt":"2026-10-03T04:00:00Z"}'
)

comptime OVERRIDE_JSON = (
    '{"eventId":"evt-1","originalStart":"2026-10-14T09:30:00","cancelled":true,"title":"Moved",'
    + '"start":"2026-10-14T11:00:00","durationSeconds":1200,"location":"Room 2","description":"Notes",'
    + '"days":2,"version":"9"}'
)


comptime CALENDAR_JSON = (
    '{"id":"cal-1","owner":"subject-1","name":"Work","color":"#a0b1c2","timeZone":"Europe/London","version":"7",'
    + '"createdAt":"2026-09-21T14:13:20Z","updatedAt":"2026-10-03T04:00:00Z"}'
)


def test_json_names() raises:
    """Every JSON key and value form of Event (with Recurrence and Reminder),
    OccurrenceOverride and Calendar, both ways."""
    var e = decode_proto[Event](_event_bytes())
    assert_equal(encode_json(e), EVENT_JSON)
    assert_equal(encode_json(decode_json[Event](EVENT_JSON)), EVENT_JSON)
    var o = decode_proto[OccurrenceOverride](_override_bytes())
    assert_equal(encode_json(o), OVERRIDE_JSON)
    assert_equal(encode_json(decode_json[OccurrenceOverride](OVERRIDE_JSON)), OVERRIDE_JSON)
    var c = Calendar(
        "cal-1",
        "subject-1",
        "Work",
        "#a0b1c2",
        "Europe/London",
        UInt64(7),
        Timestamp(Int64(1790000000), Int32(0)),
        Timestamp(Int64(1791000000), Int32(0)),
    )
    assert_equal(encode_json(c), CALENDAR_JSON)
    assert_equal(encode_json(decode_json[Calendar](CALENDAR_JSON)), CALENDAR_JSON)


def test_enums() raises:
    """Each enum value's number and JSON name."""
    assert_equal(EventStatus(0).json_name(), "CONFIRMED")
    assert_equal(EventStatus(1).json_name(), "CANCELLED")
    var freqs = ["FREQUENCY_UNSPECIFIED", "DAILY", "WEEKLY", "MONTHLY", "YEARLY"]
    for i in range(len(freqs)):
        assert_equal(Frequency(i).json_name(), freqs[i])
        assert_equal(Frequency.from_json_name(freqs[i]).value, i)
    var days = ["WEEKDAY_UNSPECIFIED", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
    for i in range(len(days)):
        assert_equal(Weekday(i).json_name(), days[i])
        assert_equal(Weekday.from_json_name(days[i]).value, i)


def main() raises:
    print("test_calendar_field_numbers: the komira.calendar.v1 wire census")
    test_calendar()
    test_recurrence()
    test_reminder()
    test_event()
    test_occurrence_override()
    test_error_envelope()
    test_json_names()
    test_enums()
    print("ALL komira.calendar.v1 FIELD-NUMBER TESTS PASSED")
