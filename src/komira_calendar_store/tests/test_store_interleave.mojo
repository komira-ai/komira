# =============================================================================
# test_store_interleave.mojo -- two writers and a feed reader interleaved on
#   the Firestore mock, where no transaction spans two documents.
# =============================================================================
#
# Writer A's database is `PausingDb`, a FirestoreDatabase over MockFirestore
# that, once armed, stops A at one moment of its write and runs the peer
# there: a reader that pulls the change feed of the calendar, and writer B,
# another store over a second client of the same mock (`MockFirestore.share`)
# that writes an event of its own. Then A goes on. The database declares only
# CALENDAR_DOCUMENT_INDEXES, so an undeclared query shape fails the check.
# Every check runs; the test fails at the end naming each failed one.
#
#   at_apply   A stops after its claim, before it writes its event. The
#              reader sees neither event; B finishes A's held write and then
#              its own; the reader then sees both. A succeeds. Catches a feed
#              that a reader can pass before a write lands (a calendar modseq
#              advanced before the event row is written: the reader's cursor
#              passes A's seq and A's event is never listed), and a writer
#              that fails when another finished its write.
#   at_finish  A stops after writing its event, before it finishes. The
#              reader sees the earlier event `z` but not A's (its modseq is
#              above the calendar's); after B the reader sees both, each
#              once. Catches a feed that reads past the calendar's modseq.
#   restart    a new store over another client of the same documents reads
#              the same calendar, events and feed.
#
# FirestoreDatabase is checked against the mock's model of Firestore, not
# Firestore itself.
# =============================================================================

from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_calendar_ics import ZoneTable
from komira_calendar_proto.calendar import Calendar, Event
from komira_datetime import posix_zone
from komira_db import Database, DbColVal, DbRow, DbRows, DbValue, Filter, Order, PodNameMinter
from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore_db import (
    DeclaredIndexSet,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
    TableKeys,
)
from komira_proto_codec import decode_json

from komira_calendar_store import CALENDAR_DOCUMENT_INDEXES, CalendarStore, EventChanges, T_CALENDARS, T_EVENTS

comptime Rt = BlockingRuntime[NoopSink]
comptime FsDb = FirestoreDatabase[MockFirestoreConnector]
comptime T0: Int64 = 1790000000000

comptime NO_PAUSE = 0
comptime AT_APPLY = 1
comptime AT_FINISH = 2


def _rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


def _zones() raises -> ZoneTable:
    var z = ZoneTable()
    z.add(posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))
    return z^


def _db(transport: MockFirestore) raises -> FsDb:
    var client = FirestoreClient[MockFirestoreConnector](
        transport.connector(), String("cal-project"), String("(default)"), String("cal-bearer")
    )
    return FsDb(client^, DeclaredIndexSet.parse_table(String(CALENDAR_DOCUMENT_INDEXES)), TableKeys())


def _event(uid: String) raises -> Event:
    return decode_json[Event](
        '{"uid":"' + uid + '","title":"' + uid
        + '","start":"2026-10-19T09:00:00","timeZone":"America/New_York","durationSeconds":60}'
    )


def _uids(c: EventChanges) -> String:
    var out = String()
    for i in range(len(c.changes)):
        out += c.changes[i].uid + "@" + String(c.changes[i].modseq) + " "
    return out^


struct PausingDb(Database, Movable, Deinitable):
    """Writer A's database: FirestoreDatabase, plus one pause (`pause`) at
    which the reader reads and writer B writes (`peer`). `log` records what
    the reader saw: `<when>: <uid@modseq ...>|<cursor>;`."""

    var inner: FsDb
    var peer: CalendarStore[FsDb]
    var zones: ZoneTable
    var pause: Int
    var cal: String
    var cursor: Int
    var log: String

    def __init__(out self, var inner: FsDb, var peer: FsDb) raises:
        self.inner = inner^
        self.peer = CalendarStore[FsDb](peer^)
        self.zones = _zones()
        self.pause = NO_PAUSE
        self.cal = String()
        self.cursor = 0
        self.log = String()

    def arm(mut self, pause: Int, cal: String):
        self.pause = pause
        self.cal = String(cal)

    def read_feed[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], when: StaticString) raises:
        var c = self.peer.changes[RT](reactor, self.cal, self.cursor)
        self.log += String(when) + ": " + _uids(c) + "|" + String(c.modseq) + ";"
        self.cursor = c.modseq

    def _run_peer[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.pause = NO_PAUSE
        self.read_feed[RT](reactor, "paused")
        _ = self.peer.create_event[RT](reactor, self.cal, _event("b"), self.zones, T0)
        self.read_feed[RT](reactor, "after b")

    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.begin[RT](reactor)

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.commit[RT](reactor)

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.rollback[RT](reactor)

    def get_by_key[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], key_col: String, key_val: DbValue
    ) raises -> Optional[DbRow]:
        return self.inner.get_by_key[RT](reactor, table, cols, key_col, key_val)

    def put[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], vals: List[DbValue]) raises -> UInt64:
        return self.inner.put[RT](reactor, table, cols, vals)

    def delete_by_key[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, key_col: String, key_val: DbValue) raises -> UInt64:
        return self.inner.delete_by_key[RT](reactor, table, key_col, key_val)

    def query_rows[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
        limit: Optional[UInt32],
    ) raises -> DbRows:
        return self.inner.query_rows[RT](reactor, table, cols, filter, order, limit)

    def query_rows_locked[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], filter: Filter, order: List[Order]
    ) raises -> DbRows:
        return self.inner.query_rows_locked[RT](reactor, table, cols, filter, order)

    def conditional_update[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        guard: Filter,
        updates: List[DbColVal],
        coalesce: Bool,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> UInt64:
        if self.pause == AT_FINISH and table == String(T_CALENDARS) and updates[0].col == String("modseq"):
            self._run_peer[RT](reactor)
        return self.inner.conditional_update[RT](reactor, table, guard, updates, coalesce, bump_version_col, now_cols)

    def delete_where[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, filter: Filter) raises -> UInt64:
        return self.inner.delete_where[RT](reactor, table, filter)

    def create_if_absent[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        unique_col: String,
        unique_val: DbValue,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        if self.pause == AT_APPLY and table == String(T_EVENTS):
            self._run_peer[RT](reactor)
        return self.inner.create_if_absent[RT](reactor, table, unique_col, unique_val, cols, vals)

    def create_if_absent_composite[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        conflict_cols: List[String],
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        return self.inner.create_if_absent_composite[RT](reactor, table, conflict_cols, cols, vals)

    def claim_rows[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        n: Int,
        filter: Filter,
        order: List[Order],
        phase_col: String,
        from_phase: String,
        to_phase: String,
        extra: List[DbColVal],
        per_row_mint: PodNameMinter,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> DbRows:
        return self.inner.claim_rows[RT](
            reactor, table, n, filter, order, phase_col, from_phase, to_phase, extra, per_row_mint, bump_version_col, now_cols
        )


def _interleave(pause: Int) raises -> String:
    """After event `z`, A writes event `a` with the pause armed; returns the reader's log and
    then, after A, the feed from the reader's cursor and the whole feed."""
    var mock = MockFirestore()
    var store = CalendarStore[PausingDb](PausingDb(_db(mock), _db(mock.share())))
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = decode_json[Calendar]('{"name":"Work","timeZone":"America/New_York"}')
    var c = store.create_calendar[Rt](reactor, "alice", cal, zones, T0)
    _ = store.create_event[Rt](reactor, c.id, _event("z"), zones, T0)
    store.database().arm(pause, c.id)
    var a = store.create_event[Rt](reactor, c.id, _event("a"), zones, T0)
    assert_equal(a.version, UInt64(1), "writer A succeeds")
    store.database().read_feed[Rt](reactor, "after a")
    var whole = store.changes[Rt](reactor, c.id, 0)
    return store.database().log + " whole: " + _uids(whole) + "|" + String(whole.modseq)


def check_at_apply() raises:
    assert_equal(
        _interleave(AT_APPLY),
        "paused: z@1 |1;after b: a@2 b@3 |3;after a: |3; whole: z@1 a@2 b@3 |3",
    )


def check_at_finish() raises:
    assert_equal(
        _interleave(AT_FINISH),
        "paused: z@1 |1;after b: a@2 b@3 |3;after a: |3; whole: z@1 a@2 b@3 |3",
    )


def check_restart() raises:
    var mock = MockFirestore()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var first = CalendarStore[FsDb](_db(mock))
    var cal = decode_json[Calendar]('{"name":"Work","timeZone":"America/New_York"}')
    var c = first.create_calendar[Rt](reactor, "alice", cal, zones, T0)
    var e = first.create_event[Rt](reactor, c.id, _event("kept"), zones, T0)
    var again = CalendarStore[FsDb](_db(mock.share()))
    assert_equal(again.get_calendar[Rt](reactor, c.id).name, "Work")
    assert_equal(again.get_event[Rt](reactor, c.id, e.id).title, "kept")
    assert_equal(_uids(again.changes[Rt](reactor, c.id, 0)), "kept@1 ")
    assert_equal(len(first.calendars_of[Rt](reactor, "alice")), 1)


def main() raises:
    var failures = String()
    try:
        check_at_apply()
    except e:
        failures += "FAIL at_apply: " + String(e) + "\n"
    try:
        check_at_finish()
    except e:
        failures += "FAIL at_finish: " + String(e) + "\n"
    try:
        check_restart()
    except e:
        failures += "FAIL restart: " + String(e) + "\n"
    assert_equal(failures, String(), "test_store_interleave")
    print("PASS test_store_interleave: 3 checks")
