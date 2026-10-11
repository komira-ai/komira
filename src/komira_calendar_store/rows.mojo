# =============================================================================
# komira_calendar_store/rows.mojo -- values, predicates and the row forms of
#   the three tables.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbColVal, DbRow, DbValue, Filter, Pred
from komira_proto_codec import decode_json_lenient
from komira_wkt import Timestamp

from komira_calendar_proto.calendar import Calendar, Event, OccurrenceOverride

from .schema import T_CALENDARS, calendar_cols


def txt(s: String) -> DbValue:
    return DbValue.text(String(s))


def i64(v: Int) -> DbValue:
    return DbValue.int8(Int64(v))


def flag(b: Bool) -> DbValue:
    return DbValue.int8(Int64(1) if b else Int64(0))


def eq(col: StaticString, var v: DbValue) -> Pred:
    return Pred.eq(String(col), v^)


def all_of(var a: Pred) -> Filter:
    return Filter.just(a^)


def all_of(var a: Pred, var b: Pred) -> Filter:
    var ps = List[Pred]()
    ps.append(a^)
    ps.append(b^)
    return Filter.all_of(ps^)


def all_of(var a: Pred, var b: Pred, var c: Pred) -> Filter:
    var ps = List[Pred]()
    ps.append(a^)
    ps.append(b^)
    ps.append(c^)
    return Filter.all_of(ps^)


def all_of(var a: Pred, var b: Pred, var c: Pred, var d: Pred) -> Filter:
    var ps = List[Pred]()
    ps.append(a^)
    ps.append(b^)
    ps.append(c^)
    ps.append(d^)
    return Filter.all_of(ps^)


def set_to(col: StaticString, var v: DbValue) -> DbColVal:
    return DbColVal.bind(String(col), v^)


def ts(ms: Int64) -> Timestamp:
    """`ms` milliseconds since the epoch as a Timestamp."""
    var s = ms // 1000
    return Timestamp(s, Int32((ms - s * 1000) * 1000000))


def update_rows[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], table: StaticString, guard: Filter, var updates: List[DbColVal]) raises -> Int:
    """`UPDATE table SET updates WHERE guard`; the rows updated."""
    return Int(
        db.conditional_update[RT](
            reactor, String(table), guard, updates^, False, Optional[String](), List[String]()
        )
    )


def delete_all[RT: Runtime, DB: Database](mut db: DB, mut reactor: Reactor[RT.Sink], table: String, filter: Filter) raises -> Int:
    """Delete every row of `table` matching `filter`, repeating until none is
    left (a document store deletes at most a batch per call); the rows
    deleted."""
    var total = 0
    while True:
        var n = Int(db.delete_where[RT](reactor, table, filter))
        if n == 0:
            return total
        total += n


# ---- calendars ----------------------------------------------------------------

comptime KIND_NONE = 0
comptime KIND_EVENT = 1
comptime KIND_OVERRIDE = 2
comptime KIND_CALENDAR_DELETE = 3


@fieldwise_init
struct Intent(Copyable, Movable):
    """A write a calendar row holds while it is applied (store.mojo, THE
    WRITE PROTOCOL). `body` is the event's (KIND_EVENT) or the override's
    (KIND_OVERRIDE) proto3 JSON as it is to be stored; `deleted` makes it a
    tombstone; `first` and `last` are the event's new UTC span. `id` is the
    event's id (both kinds)."""

    var kind: Int
    var id: String
    var body: String
    var deleted: Bool
    var first: Int
    var last: Int


@fieldwise_init
struct CalendarRecord(Copyable, Movable):
    """A calendar row: the calendar, its change number, and the write it
    holds (`pending_seq` 0: none)."""

    var calendar: Calendar
    var modseq: Int
    var pending_seq: Int
    var pending: Intent


def calendar_row(c: Calendar, now_ms: Int64) -> List[DbValue]:
    """A new calendar `c`, created and updated at `now_ms`, in
    `calendar_cols()` order: change number 0, holding no write."""
    var out = List[DbValue]()
    out.append(txt(c.id))
    out.append(txt(c.owner))
    out.append(txt(c.name))
    out.append(txt(c.color))
    out.append(txt(c.time_zone))
    out.append(i64(Int(c.version)))
    out.append(DbValue.int8(now_ms))
    out.append(DbValue.int8(now_ms))
    out.append(i64(0))
    out.append(i64(0))
    out.append(i64(KIND_NONE))
    out.append(txt(String()))
    out.append(txt(String()))
    out.append(flag(False))
    out.append(i64(0))
    out.append(i64(0))
    return out^


def calendar_from_row(row: DbRow) raises -> CalendarRecord:
    var c = Calendar(
        row.get_text(0),
        row.get_text(1),
        row.get_text(2),
        row.get_text(3),
        row.get_text(4),
        UInt64(row.get_int8(5)),
        Optional[Timestamp](ts(row.get_int8(6))),
        Optional[Timestamp](ts(row.get_int8(7))),
    )
    var intent = Intent(
        Int(row.get_int8(10)),
        row.get_text(11),
        row.get_text(12),
        row.get_int8(13) != 0,
        Int(row.get_int8(14)),
        Int(row.get_int8(15)),
    )
    return CalendarRecord(c^, Int(row.get_int8(8)), Int(row.get_int8(9)), intent^)


def read_calendar[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String) raises -> Optional[CalendarRecord]:
    var got = db.get_by_key[RT](reactor, String(T_CALENDARS), calendar_cols(), String("id"), txt(calendar_id))
    if not got:
        return None
    return calendar_from_row(got.take())


# ---- events and overrides -----------------------------------------------------


def event_from_row(row: DbRow) raises -> Event:
    """A live event row's event (its `body` column, read leniently: a body
    written by a newer schema keeps the fields this one knows)."""
    return decode_json_lenient[Event](row.get_text(9))


def override_from_row(row: DbRow) raises -> OccurrenceOverride:
    return decode_json_lenient[OccurrenceOverride](row.get_text(8))
