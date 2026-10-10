# =============================================================================
# test_store_overrides.mojo -- CalendarStore on komira_db_sqlite:
#   one-occurrence edits, deleting a calendar, and erasure.
# =============================================================================
#
# Each check gets a new in-memory database with the migration chain applied;
# zones come from POSIX rules. Every check runs; the test fails at the end
# naming each failed one. The defect each catches:
#
#   overrides  an edit of a time the series does not start at (or an
#              excluded one) stored; a refused edit stored; If-Match not
#              applied (a stale version, or a version for an edit that is not
#              there); the version not continuing after a delete; an edit
#              that moves an occurrence not widening the event's window; an
#              edit not listed in the feed as its event's change
#   delete     a stale calendar delete applied; a deleted calendar's events
#              or edits left behind
#   erasure    a table of CALENDAR_TABLES not erased; another owner's rows
#              erased; a second run deleting anything
# =============================================================================

from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_calendar_ics import ZoneTable
from komira_calendar_proto.calendar import Calendar, Event, OccurrenceOverride
from komira_datetime import posix_zone, seconds_from_fields
from komira_db import DbValue, Filter, Order, Pred
from komira_db_sqlite import SqliteDatabase
from komira_proto_codec import decode_json

from komira_calendar_store import (
    CalendarStore,
    ERR_NOT_FOUND,
    ERR_VERSION_CONFLICT,
    EventChanges,
    OWNER_COL,
    T_EVENTS,
    T_OVERRIDES,
    calendar_tables,
    migrate,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime Store = CalendarStore[SqliteDatabase]
comptime OK = "ok"
comptime T0: Int64 = 1790000000000
comptime WEEKLY = '{"freq":"WEEKLY","interval":1,"count":4}'


def _rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


def _zones() raises -> ZoneTable:
    var z = ZoneTable()
    z.add(posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))
    return z^


def _store() raises -> Store:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = migrate[Rt, SqliteDatabase](SqliteDatabase(String(":memory:")), reactor)
    return Store(db^)


def _cal(name: String) raises -> Calendar:
    return decode_json[Calendar]('{"name":"' + name + '","timeZone":"America/New_York"}')


def _series(title: String = "series") raises -> Event:
    # Mondays 19 and 26 October, 2 and 9 November 2026, 09:00 New York; 26
    # October is excluded.
    return decode_json[Event](
        '{"title":"' + title + '","start":"2026-10-19T09:00:00","timeZone":"America/New_York",'
        + '"durationSeconds":3600,"recurrence":' + WEEKLY + ',"exdates":["2026-10-26T09:00:00"]}'
    )


def _edit(event_id: String, json_tail: String) raises -> OccurrenceOverride:
    return decode_json[OccurrenceOverride]('{"eventId":"' + event_id + '",' + json_tail + "}")


def _utc(month: Int, day: Int, hour: Int) raises -> Int:
    return seconds_from_fields(2026, month, day, hour, 0, 0)


def _starts(xs: List[OccurrenceOverride]) -> String:
    var out = String()
    for i in range(len(xs)):
        if i > 0:
            out += ","
        out += xs[i].original_start + "#" + String(xs[i].version)
    return out^


def _feed(c: EventChanges) -> String:
    var out = String()
    for i in range(len(c.changes)):
        if i > 0:
            out += ","
        out += c.changes[i].uid + "@" + String(c.changes[i].modseq)
    return out + "|" + String(c.modseq)


def _ids() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    return out^


def _count(mut store: Store, table: String, col: StaticString, value: String) raises -> Int:
    var rt = _rt()
    ref reactor = rt.reactor()
    var rows = store.database().query_rows[Rt](
        reactor,
        table,
        _ids(),
        Filter.just(Pred.eq(String(col), DbValue.text(value))),
        List[Order](),
        Optional[UInt32](),
    )
    return rows.__len__()


def check_overrides() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal("Work"), zones, T0)
    var ev = store.create_event[Rt](reactor, cal.id, _series(), zones, T0)
    var single = _series("single")
    single.recurrence = None
    single.exdates = List[String]()
    var one = store.create_event[Rt](reactor, cal.id, single, zones, T0)

    var got = String(OK)
    try:
        _ = store.put_override[Rt](reactor, cal.id, _edit(ev.id, '"originalStart":"2026-10-20T09:00:00","title":"x"'), UInt64(0), zones)
    except e:
        got = String(e)
    assert_equal(got, "calendar: invalid NO_SUCH_OCCURRENCE at originalStart: no occurrence of the event starts at 2026-10-20T09:00:00")
    got = String(OK)
    try:
        _ = store.put_override[Rt](reactor, cal.id, _edit(ev.id, '"originalStart":"2026-10-26T09:00:00","title":"x"'), UInt64(0), zones)
    except e:
        got = String(e)
    assert_equal(
        got,
        "calendar: invalid NO_SUCH_OCCURRENCE at originalStart: no occurrence of the event starts at 2026-10-26T09:00:00",
        "an excluded occurrence has nothing to edit",
    )
    got = String(OK)
    try:
        _ = store.put_override[Rt](reactor, cal.id, _edit(ev.id, '"originalStart":"2026-10-19T09:00:00"'), UInt64(0), zones)
    except e:
        got = String(e)
    assert_equal(
        got,
        "calendar: invalid OVERRIDE_EMPTY at cancelled: an override cancels the occurrence or replaces at least one field",
    )
    got = String(OK)
    try:
        _ = store.put_override[Rt](reactor, cal.id, _edit(ev.id, '"originalStart":"2026-11-02T09:00:00","title":"x"'), UInt64(1), zones)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_VERSION_CONFLICT), "If-Match on an edit that is not there")
    got = String(OK)
    try:
        _ = store.put_override[Rt](reactor, cal.id, _edit(one.id, '"originalStart":"2026-10-19T09:00:00","title":"x"'), UInt64(0), zones)
    except e:
        got = String(e)
    assert_equal(got, "calendar: invalid OVERRIDE_WITHOUT_RECURRENCE at eventId: only a recurring event has occurrences to edit")
    assert_equal(len(store.overrides[Rt](reactor, cal.id, ev.id)), 0, "refused edits are not stored")

    # 9 November moves to Saturday 14 November, 18:00: past the series' end.
    var moved = store.put_override[Rt](
        reactor, cal.id, _edit(ev.id, '"originalStart":"2026-11-09T09:00:00","start":"2026-11-14T18:00:00"'), UInt64(0), zones
    )
    assert_equal(moved.version, UInt64(1))
    var titled = store.put_override[Rt](
        reactor, cal.id, _edit(ev.id, '"originalStart":"2026-10-19T09:00:00","title":"first"'), UInt64(0), zones
    )
    titled = store.put_override[Rt](
        reactor, cal.id, _edit(ev.id, '"originalStart":"2026-10-19T09:00:00","title":"first!"'), UInt64(1), zones
    )
    assert_equal(titled.version, UInt64(2))
    got = String(OK)
    try:
        _ = store.put_override[Rt](reactor, cal.id, _edit(ev.id, '"originalStart":"2026-10-19T09:00:00","title":"stale"'), UInt64(1), zones)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_VERSION_CONFLICT))
    assert_equal(_starts(store.overrides[Rt](reactor, cal.id, ev.id)), "2026-10-19T09:00:00#2,2026-11-09T09:00:00#1")
    assert_equal(store.overrides[Rt](reactor, cal.id, ev.id)[0].title.value(), "first!")

    # Only the moved occurrence reaches 14 November.
    var window = store.events_in_window[Rt](reactor, cal.id, _utc(11, 14, 23), _utc(11, 15, 0))
    assert_equal(len(window), 1, "the moved occurrence widens the event's window")
    # Every write to the event or its edits is one change of the event.
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), one.uid + "@2," + ev.uid + "@5|5")

    got = String(OK)
    try:
        store.delete_override[Rt](reactor, cal.id, ev.id, "2026-11-09T09:00:00", UInt64(2), zones)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_VERSION_CONFLICT))
    store.delete_override[Rt](reactor, cal.id, ev.id, "2026-11-09T09:00:00", UInt64(1), zones)
    assert_equal(_starts(store.overrides[Rt](reactor, cal.id, ev.id)), "2026-10-19T09:00:00#2")
    assert_equal(len(store.events_in_window[Rt](reactor, cal.id, _utc(11, 14, 23), _utc(11, 15, 0))), 0, "the window narrows again")
    got = String(OK)
    try:
        store.delete_override[Rt](reactor, cal.id, ev.id, "2026-11-09T09:00:00", UInt64(2), zones)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND), "a deleted edit is not deleted again")
    got = String(OK)
    try:
        store.delete_override[Rt](reactor, cal.id, ev.id, "2026-11-02T09:00:00", UInt64(1), zones)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND), "an edit never written")
    var back = store.put_override[Rt](
        reactor, cal.id, _edit(ev.id, '"originalStart":"2026-11-09T09:00:00","cancelled":true'), UInt64(0), zones
    )
    assert_equal(back.version, UInt64(3), "the version continues past the deleted edit")

    _ = store.delete_event[Rt](reactor, cal.id, ev.id, UInt64(1))
    assert_equal(_count(store, String(T_OVERRIDES), "event_id", ev.id), 0, "a deleted event's edits are removed")

    # An all-day series: its occurrences are dates.
    var days = store.create_event[Rt](
        reactor,
        cal.id,
        decode_json[Event]('{"title":"d","showWithoutTime":true,"startDate":"2026-10-19","days":1,"recurrence":' + WEEKLY + "}"),
        zones,
        T0,
    )
    got = String(OK)
    try:
        _ = store.put_override[Rt](reactor, cal.id, _edit(days.id, '"originalStart":"2026-10-27","title":"x"'), UInt64(0), zones)
    except e:
        got = String(e)
    assert_equal(got, "calendar: invalid NO_SUCH_OCCURRENCE at originalStart: no occurrence of the event starts at 2026-10-27")
    var day_edit = store.put_override[Rt](reactor, cal.id, _edit(days.id, '"originalStart":"2026-10-26","days":3'), UInt64(0), zones)
    assert_equal(day_edit.version, UInt64(1))


def check_delete_calendar() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal("Work"), zones, T0)
    var keep = store.create_calendar[Rt](reactor, "alice", _cal("Keep"), zones, T0)
    var ev = store.create_event[Rt](reactor, cal.id, _series(), zones, T0)
    _ = store.create_event[Rt](reactor, keep.id, _series(), zones, T0)
    _ = store.put_override[Rt](reactor, cal.id, _edit(ev.id, '"originalStart":"2026-10-19T09:00:00","title":"x"'), UInt64(0), zones)
    var got = String(OK)
    try:
        store.delete_calendar[Rt](reactor, cal.id, UInt64(2))
    except e:
        got = String(e)
    assert_equal(got, String(ERR_VERSION_CONFLICT))
    assert_equal(len(store.overrides[Rt](reactor, cal.id, ev.id)), 1, "a stale delete removes nothing")
    store.delete_calendar[Rt](reactor, cal.id, UInt64(1))
    got = String(OK)
    try:
        _ = store.get_calendar[Rt](reactor, cal.id)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))
    assert_equal(_count(store, String(T_EVENTS), "calendar_id", cal.id), 0)
    assert_equal(_count(store, String(T_OVERRIDES), "calendar_id", cal.id), 0)
    assert_equal(_count(store, String(T_EVENTS), "calendar_id", keep.id), 1, "another calendar keeps its events")
    got = String(OK)
    try:
        store.delete_calendar[Rt](reactor, cal.id, UInt64(1))
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))


def check_erasure() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var tables = calendar_tables()
    var owners = List[String]()
    owners.append(String("alice"))
    owners.append(String("bob"))
    for oi in range(len(owners)):
        var owner = owners[oi].copy()
        for name_i in range(2):
            var cal = store.create_calendar[Rt](reactor, owner, _cal(String("A") if name_i == 0 else String("B")), zones, T0)
            var ev = store.create_event[Rt](reactor, cal.id, _series(), zones, T0)
            _ = store.create_event[Rt](reactor, cal.id, _series(), zones, T0)
            _ = store.put_override[Rt](
                reactor, cal.id, _edit(ev.id, '"originalStart":"2026-10-19T09:00:00","title":"x"'), UInt64(0), zones
            )
    var before = List[Int]()
    for i in range(len(tables)):
        before.append(_count(store, tables[i], OWNER_COL, "bob"))
        assert_true_count(_count(store, tables[i], OWNER_COL, "alice"), tables[i])
    var counts = store.erase_owner[Rt](reactor, "alice")
    var shown = String()
    for i in range(len(counts.tables)):
        shown += counts.tables[i] + "=" + String(counts.rows[i]) + " "
    assert_equal(shown, "calendar_calendars=2 calendar_events=4 calendar_overrides=2 ")
    assert_equal(counts.total(), 8)
    for i in range(len(tables)):
        assert_equal(_count(store, tables[i], OWNER_COL, "alice"), 0, tables[i] + ": alice's rows are gone")
        assert_equal(_count(store, tables[i], OWNER_COL, "bob"), before[i], tables[i] + ": bob's rows stay")
    assert_equal(store.erase_owner[Rt](reactor, "alice").total(), 0, "a second run deletes nothing")
    assert_equal(len(store.calendars_of[Rt](reactor, "bob")), 2)


def assert_true_count(n: Int, table: String) raises:
    """Seeding wrote rows of the owner into `table`: an erasure check of an
    empty table proves nothing."""
    if n == 0:
        raise Error(table + ": no rows were seeded")


def main() raises:
    var failures = String()
    try:
        check_overrides()
    except e:
        failures += "FAIL overrides: " + String(e) + "\n"
    try:
        check_delete_calendar()
    except e:
        failures += "FAIL delete_calendar: " + String(e) + "\n"
    try:
        check_erasure()
    except e:
        failures += "FAIL erasure: " + String(e) + "\n"
    assert_equal(failures, String(), "test_store_overrides")
    print("PASS test_store_overrides: 3 checks")
