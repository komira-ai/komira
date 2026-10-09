# =============================================================================
# test_store_races.mojo -- CalendarStore when a peer writes between its read
#   and its write, and when a writer stopped after its claim.
# =============================================================================
#
# One store on one SQLite connection never interleaves, so `RacingDb` plays
# the peer: it delegates every call to a SqliteDatabase and, armed once,
# writes the peer's rows at the moment named below. A writer that stopped
# after its claim (as on a document store, where nothing rolls the claim
# back) is planted as a held write on the calendar row. Every check runs; the
# test fails at the end naming each failed one. The defect each catches:
#
#   claim_lost     a peer's write moves the calendar's modseq just before the
#                  claim: refused with ERR_BUSY, and no event row is left.
#                  Catches a claim whose miss is ignored (two writes at one
#                  seq).
#   held_event     a planted held create is applied and finished by the next
#                  write, and the feed lists both, in order; before that the
#                  feed and the event read do not show it. Catches a held
#                  write that is lost or blocks the calendar, and a feed read
#                  past the calendar's modseq.
#   held_override  the same for a held edit: it is stored and its event is
#                  listed again at the edit's seq.
#   held_delete    a held calendar delete is finished by the next write to
#                  the calendar, which is then not found; its events are gone.
#   late_apply     a peer applies and finishes this write, then writes the
#                  same event again, before this writer applies: this
#                  writer's apply changes nothing and it succeeds. Catches an
#                  apply that moves a row back to an older seq, and a finish
#                  miss reported as a failure.
#   finished_by_peer  a peer finishes this very write (modseq at its seq)
#                  just before the finish: the writer succeeds. Catches a
#                  finish miss refused when the modseq reached the seq exactly.
#   renamed        a peer renames the calendar just before a delete's claim:
#                  the delete is refused with ERR_BUSY and the calendar and
#                  its events stay. Catches a delete claim not guarded on the
#                  version the caller named.
#   finish_behind  a peer releases the write without advancing the modseq
#                  just before the finish: ERR_BUSY. Catches a finish miss
#                  that is not checked.
#   reclaimed      after the next write finished a held write, a peer claims
#                  the calendar before it reads it again: ERR_BUSY.
#   vanished       after the next write finished a held write, a peer deletes
#                  the calendar: not found.
#   settle_fails   applying a held write fails: the error propagates, the
#                  held write stays held (rolled back), and the write after
#                  that applies it. Catches a failed settle that commits a
#                  half-applied write or releases it.
#   rename_lost    the calendar update matches no row though the version is
#                  the one read (a document store's moved updateTime):
#                  ERR_BUSY, and the calendar is unchanged.
#   any_order      the database returns rows in reverse order: calendars
#                  still list by name then id, edits by original start, and a
#                  window by first start then id. Catches a list in the
#                  database's order.
#   apply_fails    the event row write fails after the claim: the error
#                  propagates, the claim is rolled back (no held write, the
#                  modseq unmoved) and the next write runs. Catches a failed
#                  write that commits its claim.
# =============================================================================

from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_calendar_ics import ZoneTable
from komira_calendar_proto.calendar import Calendar, Event, OccurrenceOverride
from komira_datetime import posix_zone
from komira_db import Database, DbColVal, DbRow, DbRows, DbValue, Filter, Order, PodNameMinter, Pred
from komira_db_sqlite import SqliteDatabase
from komira_proto_codec import decode_json, encode_json

from komira_calendar_store import (
    CalendarStore,
    ERR_BUSY,
    ERR_NOT_FOUND,
    EventChanges,
    T_CALENDARS,
    T_EVENTS,
    migrate,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime OK = "ok"
comptime T0: Int64 = 1790000000000

comptime NO_RACE = 0
comptime CLAIM_LOST = 1
comptime LATE_APPLY = 2
comptime FINISH_BEHIND = 3
comptime RECLAIMED = 4
comptime VANISHED = 5
comptime RENAME_LOST = 6
comptime APPLY_FAILS = 7
comptime REVERSE = 8
comptime FINISHED_BY_PEER = 9
comptime RENAMED_BEFORE_CLAIM = 10
comptime APPLY_FAILED = "racing db: event write failed"


def _by_id(id: String) -> Filter:
    return Filter.just(Pred.eq(String("id"), DbValue.text(String(id))))


def _set(col: StaticString, v: DbValue) -> List[DbColVal]:
    var out = List[DbColVal]()
    out.append(DbColVal.bind(String(col), v.copy()))
    return out^


struct RacingDb(Database, Movable, Deinitable):
    """SQLite, plus one armed peer write (`race`, on calendar `cal` and event
    `event`), applied once at the moment its name says."""

    var inner: SqliteDatabase
    var race: Int
    var cal: String
    var event: String
    var seq: Int

    def __init__(out self, var inner: SqliteDatabase):
        self.inner = inner^
        self.race = NO_RACE
        self.cal = String()
        self.event = String()
        self.seq = 0

    def arm(mut self, race: Int, cal: String, event: String, seq: Int):
        self.race = race
        self.cal = String(cal)
        self.event = String(event)
        self.seq = seq

    def _peer[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], table: StaticString, id: String, var sets: List[DbColVal]) raises:
        _ = self.inner.conditional_update[RT](
            reactor, String(table), _by_id(id), sets^, False, Optional[String](), List[String]()
        )

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
        var rows = self.inner.query_rows[RT](reactor, table, cols, filter, order, limit)
        if self.race != REVERSE:
            return rows^
        # A database that returns rows in the opposite order (it promises none).
        var out = List[DbRow]()
        var i = rows.__len__() - 1
        while i >= 0:
            out.append(rows.row(i).copy())
            i -= 1
        var names = List[String]()
        for c in range(rows.column_count()):
            names.append(rows.column_name(c))
        return DbRows(out^, names^)

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
        var first = updates[0].col.copy() if len(updates) > 0 else String()
        var calendars = table == String(T_CALENDARS)
        if self.race == CLAIM_LOST and calendars and first == String("pending_seq"):
            # The peer's own write advanced the calendar first.
            self.race = NO_RACE
            self._peer[RT](reactor, T_CALENDARS, self.cal.copy(), _set("modseq", DbValue.int8(Int64(self.seq))))
        elif self.race == RENAMED_BEFORE_CLAIM and calendars and first == String("pending_seq"):
            # The peer renamed the calendar (its version moved, its modseq did not).
            self.race = NO_RACE
            self._peer[RT](reactor, T_CALENDARS, self.cal.copy(), _set("version", DbValue.int8(Int64(2))))
        elif self.race == FINISH_BEHIND and calendars and first == String("modseq"):
            # The peer released the write without advancing the calendar.
            self.race = NO_RACE
            self._peer[RT](reactor, T_CALENDARS, self.cal.copy(), _set("pending_seq", DbValue.int8(Int64(0))))
        elif self.race == FINISHED_BY_PEER and calendars and first == String("modseq"):
            # The peer finished exactly this write: modseq at its seq, released.
            self.race = NO_RACE
            var done = List[DbColVal]()
            done.append(DbColVal.bind(String("modseq"), DbValue.int8(Int64(self.seq))))
            done.append(DbColVal.bind(String("pending_seq"), DbValue.int8(Int64(0))))
            self._peer[RT](reactor, T_CALENDARS, self.cal.copy(), done^)
        elif self.race == RENAME_LOST and calendars and first == String("name"):
            # A document store's CAS that lost to a moved updateTime.
            self.race = NO_RACE
            return UInt64(0)
        var n = self.inner.conditional_update[RT](reactor, table, guard, updates, coalesce, bump_version_col, now_cols)
        if self.race == RECLAIMED and calendars and first == String("modseq"):
            # The peer claims the calendar right after the finish.
            self.race = NO_RACE
            self._peer[RT](reactor, T_CALENDARS, self.cal.copy(), _set("pending_seq", DbValue.int8(Int64(99))))
        elif self.race == VANISHED and calendars and first == String("modseq"):
            # The peer deletes the calendar right after the finish.
            self.race = NO_RACE
            _ = self.inner.delete_by_key[RT](reactor, table, String("id"), DbValue.text(self.cal.copy()))
        return n

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
        if self.race == APPLY_FAILS and table == String(T_EVENTS):
            self.race = NO_RACE
            raise Error(String(APPLY_FAILED))
        if self.race == LATE_APPLY and table == String(T_EVENTS):
            # The peer finished this write and wrote the event again.
            self.race = NO_RACE
            var sets = List[DbColVal]()
            sets.append(DbColVal.bind(String("modseq"), DbValue.int8(Int64(self.seq + 1))))
            sets.append(DbColVal.bind(String("version"), DbValue.int8(Int64(9))))
            self._peer[RT](reactor, T_EVENTS, self.event.copy(), sets^)
            var cal = List[DbColVal]()
            cal.append(DbColVal.bind(String("modseq"), DbValue.int8(Int64(self.seq + 1))))
            cal.append(DbColVal.bind(String("pending_seq"), DbValue.int8(Int64(0))))
            self._peer[RT](reactor, T_CALENDARS, self.cal.copy(), cal^)
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


comptime Store = CalendarStore[RacingDb]


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
    return Store(RacingDb(db^))


def _cal() raises -> Calendar:
    return decode_json[Calendar]('{"name":"Work","timeZone":"America/New_York"}')


def _event(uid: String, recurring: Bool = False) raises -> Event:
    var text = '{"uid":"' + uid + '","title":"' + uid + '","start":"2026-10-19T09:00:00","timeZone":"America/New_York","durationSeconds":60'
    if recurring:
        text += ',"recurrence":{"freq":"WEEKLY","interval":1,"count":3}'
    return decode_json[Event](text + "}")


def _feed(c: EventChanges) -> String:
    var out = String()
    for i in range(len(c.changes)):
        if i > 0:
            out += ","
        out += c.changes[i].uid + "@" + String(c.changes[i].modseq)
        if c.changes[i].deleted:
            out += "-"
    return out + "|" + String(c.modseq)


def _plant(mut store: Store, cal: String, seq: Int, kind: Int, id: String, body: String, deleted: Bool) raises:
    """A held write at `seq`, as a writer that stopped after its claim
    leaves it."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var sets = List[DbColVal]()
    sets.append(DbColVal.bind(String("pending_seq"), DbValue.int8(Int64(seq))))
    sets.append(DbColVal.bind(String("pending_kind"), DbValue.int8(Int64(kind))))
    sets.append(DbColVal.bind(String("pending_id"), DbValue.text(String(id))))
    sets.append(DbColVal.bind(String("pending_body"), DbValue.text(String(body))))
    sets.append(DbColVal.bind(String("pending_deleted"), DbValue.int8(Int64(1) if deleted else Int64(0))))
    sets.append(DbColVal.bind(String("pending_first"), DbValue.int8(Int64(0))))
    sets.append(DbColVal.bind(String("pending_last"), DbValue.int8(Int64(4000000000))))
    store.database().inner.begin[Rt](reactor)
    _ = store.database().inner.conditional_update[Rt](
        reactor, String(T_CALENDARS), _by_id(cal), sets^, False, Optional[String](), List[String]()
    )
    store.database().inner.commit[Rt](reactor)


def _event_count(mut store: Store, cal: String) raises -> Int:
    var rt = _rt()
    ref reactor = rt.reactor()
    var ids = List[String]()
    ids.append(String("id"))
    return store.database().inner.query_rows[Rt](
        reactor,
        String(T_EVENTS),
        ids^,
        Filter.just(Pred.eq(String("calendar_id"), DbValue.text(String(cal)))),
        List[Order](),
        Optional[UInt32](),
    ).__len__()


def check_claim_lost() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    store.database().arm(CLAIM_LOST, cal.id, String(), 7)
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_BUSY))
    assert_equal(_event_count(store, cal.id), 0, "no event row")
    _ = store.create_event[Rt](reactor, cal.id, _event("b"), zones, T0)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "b@1|1", "the calendar is free for the next write")


def check_held_event() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    var planted = _event("planted")
    planted.id = "planted-id"
    planted.calendar_id = cal.id.copy()
    planted.version = UInt64(1)
    _plant(store, cal.id, 1, 1, planted.id, encode_json(planted), False)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "|0", "a held write is not in the feed")
    var got = String(OK)
    try:
        _ = store.get_event[Rt](reactor, cal.id, planted.id)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))
    _ = store.create_event[Rt](reactor, cal.id, _event("next"), zones, T0)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "planted@1,next@2|2")
    assert_equal(store.get_event[Rt](reactor, cal.id, planted.id).title, "planted")


def check_held_override() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    var ev = store.create_event[Rt](reactor, cal.id, _event("series", True), zones, T0)
    var edit = decode_json[OccurrenceOverride](
        '{"eventId":"' + ev.id + '","originalStart":"2026-10-26T09:00:00","title":"held","version":"1"}'
    )
    _plant(store, cal.id, 2, 2, ev.id, encode_json(edit), False)
    _ = store.create_event[Rt](reactor, cal.id, _event("next"), zones, T0)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "series@2,next@3|3")
    var edits = store.overrides[Rt](reactor, cal.id, ev.id)
    assert_equal(len(edits), 1)
    assert_equal(edits[0].title.value(), "held")


def check_held_delete() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    _ = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    _plant(store, cal.id, 2, 3, String(), String(), True)
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _event("b"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))
    assert_equal(_event_count(store, cal.id), 0)
    got = String(OK)
    try:
        _ = store.get_calendar[Rt](reactor, cal.id)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))


def check_late_apply() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    var ev = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    store.database().arm(LATE_APPLY, cal.id, ev.id, 2)
    var edit = _event("a")
    edit.title = "late"
    var out = store.update_event[Rt](reactor, cal.id, ev.id, UInt64(1), edit, zones, T0)
    assert_equal(out.version, UInt64(2), "the writer succeeds")
    var now = store.get_event[Rt](reactor, cal.id, ev.id)
    assert_equal(now.title, "a", "the late apply did not overwrite the peer's later write")
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "a@3|3")


def check_finish_behind() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    store.database().arm(FINISH_BEHIND, cal.id, String(), 0)
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_BUSY))


def check_finished_by_peer() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    store.database().arm(FINISHED_BY_PEER, cal.id, String(), 1)
    var a = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    assert_equal(a.version, UInt64(1))
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "a@1|1")


def check_renamed() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    _ = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    store.database().arm(RENAMED_BEFORE_CLAIM, cal.id, String(), 0)
    var got = String(OK)
    try:
        store.delete_calendar[Rt](reactor, cal.id, UInt64(1))
    except e:
        got = String(e)
    assert_equal(got, String(ERR_BUSY))
    assert_equal(_event_count(store, cal.id), 1)
    # The peer's rename ran on the store's connection, so the rollback undid it.
    assert_equal(store.get_calendar[Rt](reactor, cal.id).name, "Work")


def check_reclaimed() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    var planted = _event("planted")
    planted.id = "planted-id"
    planted.calendar_id = cal.id.copy()
    _plant(store, cal.id, 1, 1, planted.id, encode_json(planted), False)
    store.database().arm(RECLAIMED, cal.id, String(), 0)
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_BUSY))


def check_vanished() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    var planted = _event("planted")
    planted.id = "planted-id"
    planted.calendar_id = cal.id.copy()
    _plant(store, cal.id, 1, 1, planted.id, encode_json(planted), False)
    store.database().arm(VANISHED, cal.id, String(), 0)
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_NOT_FOUND))


def check_settle_fails() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    var planted = _event("planted")
    planted.id = "planted-id"
    planted.calendar_id = cal.id.copy()
    _plant(store, cal.id, 1, 1, planted.id, encode_json(planted), False)
    store.database().arm(APPLY_FAILS, cal.id, String(), 0)
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _event("b"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(APPLY_FAILED))
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "|0")
    assert_equal(_event_count(store, cal.id), 0)
    _ = store.create_event[Rt](reactor, cal.id, _event("c"), zones, T0)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "planted@1,c@2|2")


def check_any_order() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var home1 = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    var home2 = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    var alpha = _cal()
    alpha.name = "Alpha"
    var a = store.create_calendar[Rt](reactor, "alice", alpha, zones, T0)
    var cid = home1.id.copy()
    var series = store.create_event[Rt](reactor, cid, _event("series", True), zones, T0)
    var late = _event("late")
    late.start = "2026-10-19T10:00:00"
    _ = store.create_event[Rt](reactor, cid, late, zones, T0)
    var tie = store.create_event[Rt](reactor, cid, _event("tie"), zones, T0)
    var whens = List[String]()
    whens.append(String("2026-11-02T09:00:00"))
    whens.append(String("2026-10-19T09:00:00"))
    whens.append(String("2026-10-26T09:00:00"))
    for wi in range(len(whens)):
        var edit = decode_json[OccurrenceOverride](
            '{"eventId":"' + series.id + '","originalStart":"' + whens[wi] + '","title":"e"}'
        )
        _ = store.put_override[Rt](reactor, cid, edit, UInt64(0), zones)
    store.database().arm(REVERSE, cid, String(), 0)
    var cals = store.calendars_of[Rt](reactor, "alice")
    var want_cals = a.id + "," + home1.id + "," + home2.id
    if home2.id < home1.id:
        want_cals = a.id + "," + home2.id + "," + home1.id
    assert_equal(cals[0].id + "," + cals[1].id + "," + cals[2].id, want_cals)
    var edits = store.overrides[Rt](reactor, cid, series.id)
    assert_equal(edits[0].original_start + "," + edits[1].original_start + "," + edits[2].original_start, "2026-10-19T09:00:00,2026-10-26T09:00:00,2026-11-02T09:00:00")
    var found = store.events_in_window[Rt](reactor, cid, 0, 4000000000)
    var want = String("series,tie,late")
    if tie.id < series.id:
        want = String("tie,series,late")
    assert_equal(found[0].uid + "," + found[1].uid + "," + found[2].uid, want)


def check_rename_lost() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    store.database().arm(RENAME_LOST, cal.id, String(), 0)
    var renamed = _cal()
    renamed.name = "Renamed"
    var got = String(OK)
    try:
        _ = store.update_calendar[Rt](reactor, cal.id, UInt64(1), renamed, zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(ERR_BUSY))
    var now = store.get_calendar[Rt](reactor, cal.id)
    assert_equal(now.name, "Work")
    assert_equal(now.version, UInt64(1))


def check_apply_fails() raises:
    var store = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var zones = _zones()
    var cal = store.create_calendar[Rt](reactor, "alice", _cal(), zones, T0)
    store.database().arm(APPLY_FAILS, cal.id, String(), 0)
    var got = String(OK)
    try:
        _ = store.create_event[Rt](reactor, cal.id, _event("a"), zones, T0)
    except e:
        got = String(e)
    assert_equal(got, String(APPLY_FAILED))
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "|0", "the modseq did not move")
    _ = store.create_event[Rt](reactor, cal.id, _event("b"), zones, T0)
    assert_equal(_feed(store.changes[Rt](reactor, cal.id, 0)), "b@1|1", "no held write was left")


def main() raises:
    var failures = String()
    try:
        check_claim_lost()
    except e:
        failures += "FAIL claim_lost: " + String(e) + "\n"
    try:
        check_held_event()
    except e:
        failures += "FAIL held_event: " + String(e) + "\n"
    try:
        check_held_override()
    except e:
        failures += "FAIL held_override: " + String(e) + "\n"
    try:
        check_held_delete()
    except e:
        failures += "FAIL held_delete: " + String(e) + "\n"
    try:
        check_late_apply()
    except e:
        failures += "FAIL late_apply: " + String(e) + "\n"
    try:
        check_finish_behind()
    except e:
        failures += "FAIL finish_behind: " + String(e) + "\n"
    try:
        check_finished_by_peer()
    except e:
        failures += "FAIL finished_by_peer: " + String(e) + "\n"
    try:
        check_renamed()
    except e:
        failures += "FAIL renamed: " + String(e) + "\n"
    try:
        check_reclaimed()
    except e:
        failures += "FAIL reclaimed: " + String(e) + "\n"
    try:
        check_vanished()
    except e:
        failures += "FAIL vanished: " + String(e) + "\n"
    try:
        check_settle_fails()
    except e:
        failures += "FAIL settle_fails: " + String(e) + "\n"
    try:
        check_any_order()
    except e:
        failures += "FAIL any_order: " + String(e) + "\n"
    try:
        check_rename_lost()
    except e:
        failures += "FAIL rename_lost: " + String(e) + "\n"
    try:
        check_apply_fails()
    except e:
        failures += "FAIL apply_fails: " + String(e) + "\n"
    assert_equal(failures, String(), "test_store_races")
    print("PASS test_store_races: 14 checks")
