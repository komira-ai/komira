# =============================================================================
# test_store_sqlite.mojo -- CalendarStore on komira_db_sqlite: calendars,
#   events, the time window and the change feed.
# =============================================================================
#
# Each check gets a new in-memory database with the migration chain applied.
# Zones come from POSIX rules (America/New_York EST5EDT, Europe/London
# GMT0BST), so no zone data is read. Every check runs; the test fails at the
# end naming each failed one. The defect each catches:
#
#   calendars   an unknown zone or a bad name stored; calendars_of not sorted
#               by name then id; a stale or missing calendar updated
#   events      a uid not minted when empty, taken twice in one calendar, or
#               refused in another; a stale version written; a uid changed;
#               created_at moved by an update; a deleted event still read; a
#               deleted uid not free again; an unknown zone or a refused
#               event stored
#   window      an open series that started before the window missed (OPEN_END
#               stored as 0); an event ending exactly at the window's start or
#               starting exactly at its end listed (the bounds off by one); a
#               deleted event listed; the order not by first start then id
#   feed        a write without its own modseq; a delete without a tombstone;
#               an entry past the calendar's modseq; a cursor at the head not
#               empty
#   migrations  a re-run applying a step; a table the chain creates that is
#               not in CALENDAR_TABLES, or the reverse
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_calendar_ics import ZoneTable
from komira_calendar_proto.calendar import Calendar, Event
from komira_datetime import posix_zone, seconds_from_fields
from komira_db import DbValue, MigrationRunner
from komira_db.blocking import db_blocking_query
from komira_db_sqlite import SqliteDatabase
from komira_proto_codec import decode_json

from komira_calendar_store import (
    CALENDAR_MIGRATION_LEDGER,
    CalendarStore,
    ERR_NOT_FOUND,
    ERR_UID_TAKEN,
    ERR_VERSION_CONFLICT,
    EventChanges,
    calendar_migrations,
    calendar_tables,
    migrate,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime Store = CalendarStore[SqliteDatabase]
comptime OK = "ok"
comptime T0: Int64 = 1790000000000
comptime NO_SUCH_ID = "00000000-0000-7000-8000-000000000000"


def _rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


def _zones() raises -> ZoneTable:
    var z = ZoneTable()
    z.add(posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))
    z.add(posix_zone("Europe/London", "GMT0BST,M3.5.0/1,M10.5.0"))
    return z^


def _store() raises -> Store:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = migrate[Rt, SqliteDatabase](SqliteDatabase(String(":memory:")), reactor)
    return Store(db^)


def _cal(name: String, zone: String = "America/New_York") raises -> Calendar:
    return decode_json[Calendar]('{"name":"' + name + '","timeZone":"' + zone + '"}')


def _timed(start: String, duration: Int, uid: String = "", recurrence: String = "") raises -> Event:
    var text = '{"title":"t","start":"' + start + '","timeZone":"America/New_York","durationSeconds":' + String(duration)
    if uid.byte_length() > 0:
        text += ',"uid":"' + uid + '"'
    if recurrence.byte_length() > 0:
        text += ',"recurrence":' + recurrence
    return decode_json[Event](text + "}")


def _utc(month: Int, day: Int, hour: Int) raises -> Int:
    return seconds_from_fields(2026, month, day, hour, 0, 0)


def _feed(c: EventChanges) -> String:
    """`uid@modseq` per change (`-` after a tombstone), then `|<cursor>`."""
    var out = String()
    for i in range(len(c.changes)):
        if i > 0:
            out += ","
        out += c.changes[i].uid + "@" + String(c.changes[i].modseq)
        if c.changes[i].deleted:
            out += "-"
    return out + "|" + String(c.modseq)


def _titles(events: List[Event]) -> String:
    var out = String()
    for i in range(len(events)):
        if i > 0:
            out += ","
        out += events[i].title
    return out^


def check_calendars() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var got = String(OK)
    try:
        _ = store.create_calendar[Rt](reactor, "alice", _cal("Mars", "Mars/Olympus"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, 'calendar: invalid TIME_ZONE_UNKNOWN at timeZone: unknown time zone "Mars/Olympus"')
    got = String(OK)
    try:
        _ = store.create_calendar[Rt](reactor, "alice", _cal(""), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, "calendar: invalid NAME_REQUIRED at name: a calendar needs a name")
    assert_equal(len(store.calendars_of[Rt](reactor, "alice")), 0, "refused calendars are not stored")

    var work = store.create_calendar[Rt](reactor, "alice", _cal("Work"), zones, T0)
    var home_a = store.create_calendar[Rt](reactor, "alice", _cal("Home"), zones, T0)
    var home_b = store.create_calendar[Rt](reactor, "alice", _cal("Home", "Europe/London"), zones, T0)
    _ = store.create_calendar[Rt](reactor, "bob", _cal("Bob's"), zones, T0)
    assert_equal(work.owner, "alice")
    assert_equal(work.version, UInt64(1))
    assert_equal(work.created_at.value().seconds, Int64(1790000000))
    var read = store.get_calendar[Rt](reactor, work.id)
    assert_equal(read.name, "Work")
    assert_equal(read.time_zone, "America/New_York")
    assert_equal(read.updated_at.value().seconds, Int64(1790000000))

    var mine = store.calendars_of[Rt](reactor, "alice")
    var low = home_a.id.copy()
    var high = home_b.id.copy()
    if high < low:
        low = home_b.id.copy()
        high = home_a.id.copy()
    assert_equal(len(mine), 3)
    assert_equal(mine[0].id, low, "Home, lower id first")
    assert_equal(mine[1].id, high)
    assert_equal(mine[2].id, work.id, "Work after Home")

    var renamed = store.update_calendar[Rt](reactor, work.id, UInt64(1), _cal("Office", "Europe/London"), zones, T0 + 5000)
    assert_equal(renamed.name, "Office")
    assert_equal(renamed.version, UInt64(2))
    assert_equal(renamed.time_zone, "Europe/London")
    assert_equal(renamed.updated_at.value().seconds, Int64(1790000005))
    assert_equal(renamed.created_at.value().seconds, Int64(1790000000))
    got = String(OK)
    try:
        _ = store.update_calendar[Rt](reactor, work.id, UInt64(1), _cal("Stale"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_VERSION_CONFLICT))
    assert_equal(store.get_calendar[Rt](reactor, work.id).name, "Office", "a stale update changes nothing")
    got = String(OK)
    try:
        _ = store.update_calendar[Rt](reactor, work.id, UInt64(2), _cal("Mars", "Mars/Olympus"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, 'calendar: invalid TIME_ZONE_UNKNOWN at timeZone: unknown time zone "Mars/Olympus"')
    got = String(OK)
    try:
        _ = store.update_calendar[Rt](reactor, NO_SUCH_ID, UInt64(1), _cal("X"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))
    got = String(OK)
    try:
        _ = store.get_calendar[Rt](reactor, NO_SUCH_ID)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))


def check_events() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal("Work"), zones, T0)
    var other = store.create_calendar[Rt](reactor, "alice", _cal("Other"), zones, T0)

    var minted = store.create_event[Rt](reactor, cal.id, _timed("2026-10-12T09:00:00", 3600), zones, T0)
    assert_equal(minted.uid, minted.id, "an empty uid becomes the id")
    assert_equal(minted.calendar_id, cal.id)
    assert_equal(minted.version, UInt64(1))
    var standup = store.create_event[Rt](reactor, cal.id, _timed("2026-10-13T09:00:00", 900, "standup"), zones, T0)
    assert_equal(standup.uid, "standup")
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _timed("2026-10-14T09:00:00", 900, "standup"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_UID_TAKEN))
    _ = store.create_event[Rt](reactor, other.id, _timed("2026-10-14T09:00:00", 900, "standup"), zones, T0)
    got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, NO_SUCH_ID, _timed("2026-10-14T09:00:00", 900), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))
    got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _timed("2026-10-14T09:00:00", 0), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, "calendar: invalid DURATION_ZERO at durationSeconds: a timed event lasts at least one second")
    got = String(OK)
    try:
        var mars = _timed("2026-10-14T09:00:00", 60)
        mars.time_zone = "Mars/Olympus"
        _ = store.create_event[Rt](reactor, cal.id, mars, zones, T0)
    except e:
        got = String(e)
    assert_equal(got, 'calendar: invalid TIME_ZONE_UNKNOWN at timeZone: unknown time zone "Mars/Olympus"')

    var read = store.get_event[Rt](reactor, cal.id, standup.id)
    assert_equal(read.title, "t")
    assert_equal(read.start, "2026-10-13T09:00:00")
    got = String(OK)
    try:
        _ = store.get_event[Rt](reactor, other.id, standup.id)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND), "an event is read only through its own calendar")

    var edit = _timed("2026-10-13T10:00:00", 1800)
    edit.title = "moved"
    got = String(OK)
    try:
        _ = store.update_event[Rt](reactor, cal.id, standup.id, UInt64(7), edit, zones, T0 + 1000)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_VERSION_CONFLICT))
    got = String(OK)
    try:
        var renamed = edit.copy()
        renamed.uid = "other-uid"
        _ = store.update_event[Rt](reactor, cal.id, standup.id, UInt64(1), renamed, zones, T0 + 1000)
    except e:
        got = String(e)
    assert_equal(got, "calendar: invalid UID_CHANGED at uid: an event's uid cannot change")
    var updated = store.update_event[Rt](reactor, cal.id, standup.id, UInt64(1), edit, zones, T0 + 1000)
    assert_equal(updated.version, UInt64(2))
    assert_equal(updated.uid, "standup", "an empty uid keeps the uid")
    assert_equal(updated.created_at.value().seconds, Int64(1790000000))
    assert_equal(updated.updated_at.value().seconds, Int64(1790000001))
    assert_equal(store.get_event[Rt](reactor, cal.id, standup.id).title, "moved")

    got = String(OK)
    try:
        _ = store.delete_event[Rt](reactor, cal.id, standup.id, UInt64(1))
    except e:
        got = String(e)
    assert_equal(got, String(ERR_VERSION_CONFLICT))
    _ = store.delete_event[Rt](reactor, cal.id, standup.id, UInt64(2))
    got = String(OK)
    try:
        _ = store.get_event[Rt](reactor, cal.id, standup.id)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND), "a tombstone is not read")
    got = String(OK)
    try:
        _ = store.delete_event[Rt](reactor, cal.id, standup.id, UInt64(3))
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND), "a tombstone is not deleted again")
    var again = store.create_event[Rt](reactor, cal.id, _timed("2026-10-15T09:00:00", 900, "standup"), zones, T0)
    assert_equal(again.uid, "standup", "a deleted event's uid is free again")


def check_window() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal("Work"), zones, T0)
    var daily = _timed("2026-09-07T08:00:00", 600, "", '{"freq":"DAILY","interval":1}')
    daily.title = "open"
    _ = store.create_event[Rt](reactor, cal.id, daily, zones, T0)
    # The window is [2026-10-12T13:00Z, 2026-10-12T15:00Z), 09:00-11:00 New York.
    var ends_at_from = _timed("2026-10-12T08:00:00", 3600)
    ends_at_from.title = "ends_at_from"
    _ = store.create_event[Rt](reactor, cal.id, ends_at_from, zones, T0)
    var starts_at_to = _timed("2026-10-12T11:00:00", 60)
    starts_at_to.title = "starts_at_to"
    _ = store.create_event[Rt](reactor, cal.id, starts_at_to, zones, T0)
    var last_second = _timed("2026-10-12T10:59:59", 60)
    last_second.title = "last_second"
    _ = store.create_event[Rt](reactor, cal.id, last_second, zones, T0)
    var first_second = _timed("2026-10-12T08:00:01", 3600)
    first_second.title = "first_second"
    _ = store.create_event[Rt](reactor, cal.id, first_second, zones, T0)
    var allday = decode_json[Event]('{"title":"allday","showWithoutTime":true,"startDate":"2026-10-12","days":1}')
    _ = store.create_event[Rt](reactor, cal.id, allday, zones, T0)
    var gone = _timed("2026-10-12T09:30:00", 60)
    gone.title = "gone"
    var g = store.create_event[Rt](reactor, cal.id, gone, zones, T0)
    _ = store.delete_event[Rt](reactor, cal.id, g.id, UInt64(1))
    var a = _timed("2026-10-12T09:00:00", 60)
    a.title = "same_start_a"
    var b = a.copy()
    b.title = "same_start_b"
    var ea = store.create_event[Rt](reactor, cal.id, a, zones, T0)
    var eb = store.create_event[Rt](reactor, cal.id, b, zones, T0)
    var same = String("same_start_a,same_start_b")
    if eb.id < ea.id:
        same = String("same_start_b,same_start_a")

    var found = store.events_in_window[Rt](reactor, cal.id, _utc(10, 12, 13), _utc(10, 12, 15))
    assert_equal(_titles(found), "open,allday,first_second," + same + ",last_second")
    var got = String(OK)
    try:
        _ = store.events_in_window[Rt](reactor, cal.id, _utc(10, 12, 15), _utc(10, 12, 15))
    except e:
        got = String(e)
    assert_equal(got, "calendar: invalid WINDOW_EMPTY at to: the window's end is not after its start")
    got = String(OK)
    try:
        _ = store.events_in_window[Rt](reactor, NO_SUCH_ID, _utc(10, 12, 13), _utc(10, 12, 15))
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))


def check_feed() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal("Work"), zones, T0)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "|0", "a new calendar has no changes")
    var a = store.create_event[Rt](reactor, cal.id, _timed("2026-10-12T09:00:00", 60, "a"), zones, T0)
    var b = store.create_event[Rt](reactor, cal.id, _timed("2026-10-12T10:00:00", 60, "b"), zones, T0)
    _ = store.create_event[Rt](reactor, cal.id, _timed("2026-10-12T11:00:00", 60, "c"), zones, T0)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "a@1,b@2,c@3|3")
    _ = store.update_event[Rt](reactor, cal.id, a.id, UInt64(1), _timed("2026-10-12T09:30:00", 60), zones, T0)
    var tomb = store.delete_event[Rt](reactor, cal.id, b.id, UInt64(1))
    assert_equal(tomb, 5)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "c@3,a@4,b@5-|5", "each event once, at its latest")
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 3)), "a@4,b@5-|5")
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 4)), "b@5-|5")
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 5)), "|5")
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 9)), "|5")
    var got = String(OK)
    try:
        _ = store.changes[Rt](reactor, NO_SUCH_ID, 0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))


def check_migrations() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var runner = MigrationRunner[SqliteDatabase](SqliteDatabase(String(":memory:")), String(CALENDAR_MIGRATION_LEDGER))
    var steps = calendar_migrations()
    assert_equal(runner.run[Rt](reactor, steps), len(steps))
    assert_equal(runner.run[Rt](reactor, steps), 0, "a re-run applies nothing")
    var rows = db_blocking_query(
        runner.db(),
        String(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            " AND name != '_komira_calendar_migrations' ORDER BY name"
        ),
        List[DbValue](),
    )
    var created = String()
    for i in range(rows.__len__()):
        created += rows.row(i).get_text(0) + "\n"
    var declared = calendar_tables()
    var listed = String()
    for i in range(len(declared)):
        listed += declared[i] + "\n"
    assert_equal(created, listed, "the chain creates exactly CALENDAR_TABLES")


def main() raises:
    var failures = String()
    try:
        check_calendars()
    except e:
        failures += "FAIL calendars: " + String(e) + "\n"
    try:
        check_events()
    except e:
        failures += "FAIL events: " + String(e) + "\n"
    try:
        check_window()
    except e:
        failures += "FAIL window: " + String(e) + "\n"
    try:
        check_feed()
    except e:
        failures += "FAIL feed: " + String(e) + "\n"
    try:
        check_migrations()
    except e:
        failures += "FAIL migrations: " + String(e) + "\n"
    assert_equal(failures, String(), "test_store_sqlite")
    print("PASS test_store_sqlite: 5 checks")
