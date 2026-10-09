# =============================================================================
# komira_calendar_store/store.mojo -- calendars, events, one-occurrence edits,
#   the change feed and erasure on any komira_db `Database`.
# =============================================================================
#
# `CalendarStore[DB]` uses only the backend-neutral `Database` operations, so
# the same code runs on SQLite and on Firestore (schema.mojo lists the
# tables). It checks what it writes (komira_calendar's check_* and the time
# zones a `ZoneSource` knows) and does not decide who may call it: the
# caller's router asks the authorization port first.
#
# THE WRITE PROTOCOL (events and overrides). A document store has no
# transaction over two documents, so a write is held on its calendar's row
# while it is applied (protocol.mojo):
#
#   1. read the calendar row; if it holds a write, apply and finish that one
#      in a transaction of its own, then read the row again
#   2. check the write (the event's version for If-Match, a uid not live in
#      the calendar, an occurrence that exists)
#   3. claim: CAS the calendar row from (modseq M, no write) to (modseq M,
#      this write at seq M + 1)
#   4. apply: write the event or override row with modseq M + 1, each write
#      guarded so it never moves a row back to an older seq
#   5. finish: CAS the calendar row to (modseq M + 1, no write)
#
# One write is held per calendar at a time; a second writer that read the
# same M loses the claim and is refused with ERR_BUSY. The change feed reads
# the rows whose modseq is above the client's cursor and at most the
# calendar's modseq, and a write's rows get their modseq before the
# calendar's modseq reaches it, so a reader never passes a change that has
# not landed yet. A writer that stops after its claim leaves the write held:
# the next write to the calendar applies and finishes it (step 1), so a write
# whose call failed may still take effect, exactly once. A write refused in
# step 2 never claims, so it changes nothing. On SQL backends each write is
# also one transaction, so a failure there rolls back to the state before it.
#
# Calendar rows themselves (create, rename, delete) are one-row writes; a
# delete is held and applied like an event write, removing the calendar's
# events and overrides before its row.
#
# Erasure deletes, table by table in CALENDAR_TABLES order, every row whose
# owner is the subject. It is idempotent. A write already past its claim when
# erasure runs on a document store can land after it; running erasure again
# removes that too.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_calendar import check_calendar
from komira_calendar_ics import ZoneSource
from komira_calendar_proto.calendar import Calendar, Event, OccurrenceOverride
from komira_db import Database, DbColVal, DbValue, Order, Pred, generate_uuidv7
from komira_wkt import Timestamp

from .errors import busy, invalid, not_found, version_conflict
from .events import (
    insert_event,
    known_zone,
    live_event,
    live_overrides,
    remove_event,
    remove_override,
    replace_event,
    window_events,
    write_override,
)
from .protocol import quiet_calendar, run_intent, settle
from .rows import (
    CalendarRecord,
    Intent,
    KIND_CALENDAR_DELETE,
    all_of,
    calendar_from_row,
    calendar_row,
    delete_all,
    eq,
    i64,
    read_calendar,
    set_to,
    ts,
    txt,
    update_rows,
)
from .schema import OWNER_COL, T_CALENDARS, T_EVENTS, calendar_cols, calendar_tables, strs


@fieldwise_init
struct EventChange(Copyable, Movable):
    """One event written or deleted after a cursor: its id and uid, the
    change number of its latest write, and whether that write deleted it."""

    var event_id: String
    var uid: String
    var modseq: Int
    var deleted: Bool


@fieldwise_init
struct EventChanges(Copyable, Movable):
    """The changes after a cursor, in modseq order; `modseq` is the cursor
    for the next call."""

    var changes: List[EventChange]
    var modseq: Int


@fieldwise_init
struct EraseCounts(Copyable, Movable):
    """The rows erasure deleted, per table of CALENDAR_TABLES, in order."""

    var tables: List[String]
    var rows: List[Int]

    def total(self) -> Int:
        var n = 0
        for i in range(len(self.rows)):
            n += self.rows[i]
        return n


def _check_calendar(calendar: Calendar) raises:
    var refusal = check_calendar(calendar)
    if refusal:
        raise invalid(refusal.value())


struct CalendarStore[DB: Database](Movable):
    """Calendars, events, overrides, the change feed and erasure over one
    `Database` (module header). Owns the database by value. Times are
    milliseconds since the epoch, given by the caller."""

    var _db: Self.DB

    def __init__(out self, var db: Self.DB):
        self._db = db^

    def database(ref self) -> ref [self._db] Self.DB:
        """Borrow the underlying database."""
        return self._db

    # ---- calendars ------------------------------------------------------------

    def create_calendar[
        RT: Runtime, Z: ZoneSource
    ](mut self, mut reactor: Reactor[RT.Sink], owner: String, calendar: Calendar, zones: Z, now_ms: Int64) raises -> Calendar:
        """Store a new calendar of `owner` with the client's name, color and
        time zone."""
        _check_calendar(calendar)
        _ = known_zone(calendar.time_zone, zones)
        var out = calendar.copy()
        out.id = generate_uuidv7().to_hyphenated()
        out.owner = owner.copy()
        out.version = UInt64(1)
        out.created_at = Optional[Timestamp](ts(now_ms))
        out.updated_at = Optional[Timestamp](ts(now_ms))
        _ = self._db.put[RT](reactor, String(T_CALENDARS), calendar_cols(), calendar_row(out, now_ms))
        return out^

    def get_calendar[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], calendar_id: String) raises -> Calendar:
        var got = read_calendar[RT, Self.DB](self._db, reactor, calendar_id)
        if not got:
            raise not_found()
        return got.value().calendar.copy()

    def calendars_of[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], owner: String) raises -> List[Calendar]:
        """The calendars of `owner`, by name, then id."""
        var rows = self._db.query_rows[RT](
            reactor, String(T_CALENDARS), calendar_cols(), all_of(eq("owner", txt(owner))), List[Order](), Optional[UInt32]()
        )
        var out = List[Calendar]()
        for i in range(rows.__len__()):
            out.append(calendar_from_row(rows.row(i)).calendar.copy())
        for i in range(1, len(out)):
            var j = i
            while j > 0 and _calendar_after(out[j - 1], out[j]):
                var t = out[j - 1].copy()
                out[j - 1] = out[j].copy()
                out[j] = t^
                j -= 1
        return out^

    def update_calendar[
        RT: Runtime, Z: ZoneSource
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        calendar_id: String,
        expected_version: UInt64,
        calendar: Calendar,
        zones: Z,
        now_ms: Int64,
    ) raises -> Calendar:
        """Replace the name, color and time zone if the calendar's version is
        still `expected_version`."""
        _check_calendar(calendar)
        _ = known_zone(calendar.time_zone, zones)
        var sets = List[DbColVal]()
        sets.append(set_to("name", txt(calendar.name)))
        sets.append(set_to("color", txt(calendar.color)))
        sets.append(set_to("time_zone", txt(calendar.time_zone)))
        sets.append(set_to("version", i64(Int(expected_version) + 1)))
        sets.append(set_to("updated_ms", DbValue.int8(now_ms)))
        var n = update_rows[RT, Self.DB](
            self._db,
            reactor,
            T_CALENDARS,
            all_of(eq("id", txt(calendar_id)), eq("version", i64(Int(expected_version)))),
            sets^,
        )
        var got = read_calendar[RT, Self.DB](self._db, reactor, calendar_id)
        if not got:
            raise not_found()
        var now = got.value().calendar.copy()
        if n != 1:
            if now.version != expected_version:
                raise version_conflict()
            raise busy()
        return now^

    def delete_calendar[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], calendar_id: String, expected_version: UInt64) raises:
        """Delete the calendar, its events and its overrides, if its version
        is still `expected_version`."""
        settle[RT, Self.DB](self._db, reactor, calendar_id)
        self._db.begin[RT](reactor)
        try:
            var rec = quiet_calendar[RT, Self.DB](self._db, reactor, calendar_id)
            if rec.calendar.version != expected_version:
                raise version_conflict()
            var intent = Intent(KIND_CALENDAR_DELETE, String(), String(), True, 0, 0)
            _ = run_intent[RT, Self.DB](self._db, reactor, rec, intent, Optional[UInt64](expected_version))
            self._db.commit[RT](reactor)
        except e:
            self._db.rollback[RT](reactor)
            raise e^

    # ---- events -----------------------------------------------------------------

    def create_event[
        RT: Runtime, Z: ZoneSource
    ](mut self, mut reactor: Reactor[RT.Sink], calendar_id: String, event: Event, zones: Z, now_ms: Int64) raises -> Event:
        """Store a new event. An empty `uid` becomes the event's id; a uid
        live in the calendar is refused."""
        return insert_event[RT, Self.DB, Z](self._db, reactor, calendar_id, event, zones, now_ms)

    def get_event[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], calendar_id: String, event_id: String) raises -> Event:
        return live_event[RT, Self.DB](self._db, reactor, calendar_id, event_id)

    def update_event[
        RT: Runtime, Z: ZoneSource
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        calendar_id: String,
        event_id: String,
        expected_version: UInt64,
        event: Event,
        zones: Z,
        now_ms: Int64,
    ) raises -> Event:
        """Replace a live event's fields if its version is still
        `expected_version`. The uid cannot change (an empty one keeps it)."""
        return replace_event[RT, Self.DB, Z](self._db, reactor, calendar_id, event_id, expected_version, event, zones, now_ms)

    def delete_event[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], calendar_id: String, event_id: String, expected_version: UInt64) raises -> Int:
        """Delete a live event if its version is still `expected_version`. It
        stays as a tombstone for the change feed, its overrides are removed,
        and its uid is free again. Returns the tombstone's modseq."""
        return remove_event[RT, Self.DB](self._db, reactor, calendar_id, event_id, expected_version)

    def events_in_window[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], calendar_id: String, from_utc: Int, to_utc: Int) raises -> List[Event]:
        """The live events that may have an occurrence in [from_utc, to_utc)
        (UTC epoch seconds), by first start, then id."""
        return window_events[RT, Self.DB](self._db, reactor, calendar_id, from_utc, to_utc)

    # ---- one-occurrence edits ---------------------------------------------------

    def put_override[
        RT: Runtime, Z: ZoneSource
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        calendar_id: String,
        edit: OccurrenceOverride,
        expected_version: UInt64,
        zones: Z,
    ) raises -> OccurrenceOverride:
        """Create or replace the edit of one occurrence of a recurring event.
        `expected_version` 0 writes whatever is stored; otherwise the live
        edit must be at that version."""
        return write_override[RT, Self.DB, Z](self._db, reactor, calendar_id, edit, expected_version, zones)

    def delete_override[
        RT: Runtime, Z: ZoneSource
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        calendar_id: String,
        event_id: String,
        original_start: String,
        expected_version: UInt64,
        zones: Z,
    ) raises:
        """Remove a live edit if its version is still `expected_version`."""
        remove_override[RT, Self.DB, Z](self._db, reactor, calendar_id, event_id, original_start, expected_version, zones)

    def overrides[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], calendar_id: String, event_id: String) raises -> List[OccurrenceOverride]:
        """The live edits of an event, by original start."""
        return live_overrides[RT, Self.DB](self._db, reactor, calendar_id, event_id)

    # ---- the change feed ----------------------------------------------------------

    def changes[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], calendar_id: String, since: Int) raises -> EventChanges:
        """The events written or deleted after change number `since`, in
        modseq order, each once at its latest write. An override write is a
        change of its event."""
        var got = read_calendar[RT, Self.DB](self._db, reactor, calendar_id)
        if not got:
            raise not_found()
        var head = got.value().modseq
        var out = List[EventChange]()
        if since < head:
            var order = List[Order]()
            order.append(Order.asc_explicit(String("modseq")))
            var rows = self._db.query_rows[RT](
                reactor,
                String(T_EVENTS),
                strs("id", "uid", "modseq", "deleted"),
                all_of(
                    eq("calendar_id", txt(calendar_id)),
                    Pred.gte(String("modseq"), i64(since + 1)),
                    Pred.le(String("modseq"), i64(head)),
                ),
                order^,
                Optional[UInt32](),
            )
            for i in range(rows.__len__()):
                ref r = rows.row(i)
                out.append(EventChange(r.get_text(0), r.get_text(1), Int(r.get_int8(2)), r.get_int8(3) != 0))
        return EventChanges(out^, head)

    # ---- erasure ------------------------------------------------------------------

    def erase_owner[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], owner: String) raises -> EraseCounts:
        """Delete every row of every table in CALENDAR_TABLES whose owner is
        `owner`. Running it again deletes nothing more."""
        var tables = calendar_tables()
        var rows = List[Int]()
        for i in range(len(tables)):
            rows.append(
                delete_all[RT, Self.DB](self._db, reactor, tables[i], all_of(Pred.eq(String(OWNER_COL), txt(owner))))
            )
        return EraseCounts(tables^, rows^)


def _calendar_after(a: Calendar, b: Calendar) -> Bool:
    if a.name != b.name:
        return a.name > b.name
    return a.id > b.id
