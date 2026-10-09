# =============================================================================
# komira_calendar_store_conformance/checks.mojo -- the store's contract,
#   each check written once for every backend.
# =============================================================================
#
#   erasure_closed_world  every table of CALENDAR_TABLES is seeded with rows
#       of two owners (a check of an empty table proves nothing, so an
#       unseeded table fails); erasing one leaves zero rows of it in every
#       table and every row of the other; a second run deletes nothing.
#       Catches a table erasure skips, and a table listed that no write
#       reaches.
#   window_open_series    a series with no end that started months before
#       the window is in it; a finished series is not. Catches an open end
#       stored as anything but Int64.MAX.
#   override_window       an edit that moves an occurrence past the series'
#       end makes the event show in a window only the edit reaches, and its
#       removal takes it out again.
#   feed                  monotonic change numbers, each event once at its
#       latest write, tombstones, edits as changes of their event.
#   if_match              every conditional write refuses a stale version
#       with ERR_VERSION_CONFLICT and changes nothing.
#   uid_unique            a uid is unique among a calendar's live events,
#       free in another calendar and after a delete.
#   restart               another connection (a restarted process) reads the
#       same calendars, events, edits and feed.
# =============================================================================

from std.testing import assert_equal

from komira_calendar_proto.calendar import Calendar, Event, OccurrenceOverride
from komira_datetime import seconds_from_fields
from komira_db import DbValue, Filter, Order, Pred
from komira_proto_codec import decode_json

from komira_calendar_store import (
    CalendarStore,
    ERR_UID_TAKEN,
    ERR_VERSION_CONFLICT,
    EventChanges,
    OWNER_COL,
    calendar_tables,
)

from .targets import CalendarTarget, Rt, T0, new_rt, zones

comptime OK = "ok"


def _cal(name: String) raises -> Calendar:
    return decode_json[Calendar]('{"name":"' + name + '","timeZone":"America/New_York"}')


def _event(uid: String, start: String, recurrence: String = "") raises -> Event:
    var text = (
        '{"uid":"' + uid + '","title":"' + uid + '","start":"' + start
        + '","timeZone":"America/New_York","durationSeconds":3600'
    )
    if recurrence.byte_length() > 0:
        text += ',"recurrence":' + recurrence
    return decode_json[Event](text + "}")


def _edit(event_id: String, tail: String) raises -> OccurrenceOverride:
    return decode_json[OccurrenceOverride]('{"eventId":"' + event_id + '",' + tail + "}")


def _utc(month: Int, day: Int, hour: Int) raises -> Int:
    return seconds_from_fields(2026, month, day, hour, 0, 0)


def _feed(c: EventChanges) -> String:
    var out = String()
    for i in range(len(c.changes)):
        if i > 0:
            out += ","
        out += c.changes[i].uid + "@" + String(c.changes[i].modseq)
        if c.changes[i].deleted:
            out += "-"
    return out + "|" + String(c.modseq)


def _uids(events: List[Event]) -> String:
    var out = String()
    for i in range(len(events)):
        if i > 0:
            out += ","
        out += events[i].uid
    return out^


comptime WEEKLY_2 = '{"freq":"WEEKLY","interval":1,"count":2}'


def check_erasure_closed_world[T: CalendarTarget](mut t: T) raises:
    var store = CalendarStore[T.DB](t.fresh())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var z = zones()
    var owners = List[String]()
    owners.append(String("alice"))
    owners.append(String("bob"))
    for i in range(len(owners)):
        var c = store.create_calendar[Rt](reactor, owners[i], _cal("Work"), z, T0)
        var series = store.create_event[Rt](reactor, c.id, _event("series", "2026-10-19T09:00:00", WEEKLY_2), z, T0)
        _ = store.put_override[Rt](
            reactor, c.id, _edit(series.id, '"originalStart":"2026-10-26T09:00:00","title":"moved"'), UInt64(0), z
        )
        var gone = store.create_event[Rt](reactor, c.id, _event("gone", "2026-10-20T09:00:00"), z, T0)
        _ = store.delete_event[Rt](reactor, c.id, gone.id, UInt64(1))
    var tables = calendar_tables()
    var alice_before = 0
    var bob_before = List[Int]()
    for i in range(len(tables)):
        var a = _count[T](store, tables[i], "alice")
        var b = _count[T](store, tables[i], "bob")
        if a == 0 or b == 0:
            raise Error(tables[i] + ": seeding wrote no row of an owner; erasing it would prove nothing")
        alice_before += a
        bob_before.append(b)
    var counts = store.erase_owner[Rt](reactor, "alice")
    assert_equal(counts.total(), alice_before, "every row of the owner is counted")
    for i in range(len(tables)):
        assert_equal(_count[T](store, tables[i], "alice"), 0, tables[i] + ": the owner's rows are gone")
        assert_equal(_count[T](store, tables[i], "bob"), bob_before[i], tables[i] + ": another owner's rows stay")
    assert_equal(store.erase_owner[Rt](reactor, "alice").total(), 0, "a second run deletes nothing")


def _count[T: CalendarTarget](mut store: CalendarStore[T.DB], table: String, owner: String) raises -> Int:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var cols = List[String]()
    cols.append(String("id"))
    return store.database().query_rows[Rt](
        reactor,
        table,
        cols^,
        Filter.just(Pred.eq(String(OWNER_COL), DbValue.text(owner.copy()))),
        List[Order](),
        Optional[UInt32](),
    ).__len__()


def check_window_open_series[T: CalendarTarget](mut t: T) raises:
    var store = CalendarStore[T.DB](t.fresh())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var z = zones()
    var c = store.create_calendar[Rt](reactor, "alice", _cal("Work"), z, T0)
    _ = store.create_event[Rt](reactor, c.id, _event("open", "2026-09-07T09:00:00", '{"freq":"WEEKLY","interval":1}'), z, T0)
    _ = store.create_event[Rt](reactor, c.id, _event("ended", "2026-09-08T09:00:00", '{"freq":"WEEKLY","interval":1,"count":3}'), z, T0)
    _ = store.create_event[Rt](reactor, c.id, _event("single", "2026-10-14T09:00:00"), z, T0)
    var found = store.events_in_window[Rt](reactor, c.id, _utc(10, 12, 0), _utc(10, 19, 0))
    assert_equal(_uids(found), "open,single")


def check_override_window[T: CalendarTarget](mut t: T) raises:
    var store = CalendarStore[T.DB](t.fresh())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var z = zones()
    var c = store.create_calendar[Rt](reactor, "alice", _cal("Work"), z, T0)
    var e = store.create_event[Rt](reactor, c.id, _event("series", "2026-10-19T09:00:00", WEEKLY_2), z, T0)
    assert_equal(len(store.events_in_window[Rt](reactor, c.id, _utc(11, 14, 23), _utc(11, 15, 0))), 0)
    var edit = store.put_override[Rt](
        reactor, c.id, _edit(e.id, '"originalStart":"2026-10-26T09:00:00","start":"2026-11-14T18:00:00"'), UInt64(0), z
    )
    assert_equal(_uids(store.events_in_window[Rt](reactor, c.id, _utc(11, 14, 23), _utc(11, 15, 0))), "series")
    store.delete_override[Rt](reactor, c.id, e.id, "2026-10-26T09:00:00", edit.version, z)
    assert_equal(len(store.events_in_window[Rt](reactor, c.id, _utc(11, 14, 23), _utc(11, 15, 0))), 0)


def check_feed[T: CalendarTarget](mut t: T) raises:
    var store = CalendarStore[T.DB](t.fresh())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var z = zones()
    var c = store.create_calendar[Rt](reactor, "alice", _cal("Work"), z, T0)
    var a = store.create_event[Rt](reactor, c.id, _event("a", "2026-10-19T09:00:00"), z, T0)
    var b = store.create_event[Rt](reactor, c.id, _event("b", "2026-10-19T10:00:00"), z, T0)
    var s = store.create_event[Rt](reactor, c.id, _event("s", "2026-10-19T11:00:00", WEEKLY_2), z, T0)
    assert_equal(_feed(store.changes[Rt](reactor, c.id, 0)), "a@1,b@2,s@3|3")
    _ = store.update_event[Rt](reactor, c.id, a.id, UInt64(1), _event("a", "2026-10-19T09:30:00"), z, T0)
    _ = store.delete_event[Rt](reactor, c.id, b.id, UInt64(1))
    _ = store.put_override[Rt](reactor, c.id, _edit(s.id, '"originalStart":"2026-10-26T11:00:00","cancelled":true'), UInt64(0), z)
    assert_equal(_feed(store.changes[Rt](reactor, c.id, 0)), "a@4,b@5-,s@6|6")
    assert_equal(_feed(store.changes[Rt](reactor, c.id, 4)), "b@5-,s@6|6")
    assert_equal(_feed(store.changes[Rt](reactor, c.id, 6)), "|6")


def _stale(got: String, what: String) raises:
    assert_equal(got, String(ERR_VERSION_CONFLICT), what)


def check_if_match[T: CalendarTarget](mut t: T) raises:
    var store = CalendarStore[T.DB](t.fresh())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var z = zones()
    var c = store.create_calendar[Rt](reactor, "alice", _cal("Work"), z, T0)
    var s = store.create_event[Rt](reactor, c.id, _event("s", "2026-10-19T11:00:00", WEEKLY_2), z, T0)
    var edit = store.put_override[Rt](reactor, c.id, _edit(s.id, '"originalStart":"2026-10-26T11:00:00","title":"x"'), UInt64(0), z)
    var got = String(OK)
    try:
        _ = store.update_event[Rt](reactor, c.id, s.id, UInt64(2), _event("s", "2026-10-19T12:00:00", WEEKLY_2), z, T0)
    except e:
        got = String(e)
    _stale(got, "update_event")
    got = String(OK)
    try:
        _ = store.delete_event[Rt](reactor, c.id, s.id, UInt64(2))
    except e:
        got = String(e)
    _stale(got, "delete_event")
    got = String(OK)
    try:
        _ = store.put_override[Rt](reactor, c.id, _edit(s.id, '"originalStart":"2026-10-26T11:00:00","title":"y"'), UInt64(2), z)
    except e:
        got = String(e)
    _stale(got, "put_override")
    got = String(OK)
    try:
        store.delete_override[Rt](reactor, c.id, s.id, "2026-10-26T11:00:00", UInt64(2), z)
    except e:
        got = String(e)
    _stale(got, "delete_override")
    got = String(OK)
    try:
        _ = store.update_calendar[Rt](reactor, c.id, UInt64(2), _cal("Stale"), z, T0)
    except e:
        got = String(e)
    _stale(got, "update_calendar")
    got = String(OK)
    try:
        store.delete_calendar[Rt](reactor, c.id, UInt64(2))
    except e:
        got = String(e)
    _stale(got, "delete_calendar")
    assert_equal(store.get_event[Rt](reactor, c.id, s.id).start, "2026-10-19T11:00:00", "nothing changed")
    assert_equal(store.overrides[Rt](reactor, c.id, s.id)[0].title.value(), "x")
    assert_equal(store.get_calendar[Rt](reactor, c.id).name, "Work")
    assert_equal(_feed(store.changes[Rt](reactor, c.id, 0)), "s@2|2")
    assert_equal(edit.version, UInt64(1))


def check_uid_unique[T: CalendarTarget](mut t: T) raises:
    var store = CalendarStore[T.DB](t.fresh())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var z = zones()
    var c = store.create_calendar[Rt](reactor, "alice", _cal("Work"), z, T0)
    var other = store.create_calendar[Rt](reactor, "alice", _cal("Other"), z, T0)
    var first = store.create_event[Rt](reactor, c.id, _event("u", "2026-10-19T09:00:00"), z, T0)
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, c.id, _event("u", "2026-10-20T09:00:00"), z, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_UID_TAKEN))
    _ = store.create_event[Rt](reactor, other.id, _event("u", "2026-10-20T09:00:00"), z, T0)
    _ = store.delete_event[Rt](reactor, c.id, first.id, UInt64(1))
    _ = store.create_event[Rt](reactor, c.id, _event("u", "2026-10-21T09:00:00"), z, T0)


def check_restart[T: CalendarTarget](mut t: T) raises:
    var first = CalendarStore[T.DB](t.fresh())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var z = zones()
    var c = first.create_calendar[Rt](reactor, "alice", _cal("Work"), z, T0)
    var s = first.create_event[Rt](reactor, c.id, _event("s", "2026-10-19T11:00:00", WEEKLY_2), z, T0)
    _ = first.put_override[Rt](reactor, c.id, _edit(s.id, '"originalStart":"2026-10-26T11:00:00","title":"x"'), UInt64(0), z)
    var again = CalendarStore[T.DB](t.reopen())
    assert_equal(again.get_calendar[Rt](reactor, c.id).name, "Work")
    assert_equal(again.get_event[Rt](reactor, c.id, s.id).uid, "s")
    assert_equal(again.overrides[Rt](reactor, c.id, s.id)[0].title.value(), "x")
    assert_equal(_feed(again.changes[Rt](reactor, c.id, 0)), "s@2|2")
    # The first connection is still in use after the second read.
    assert_equal(len(first.calendars_of[Rt](reactor, "alice")), 1)
