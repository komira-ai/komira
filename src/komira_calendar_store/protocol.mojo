# =============================================================================
# komira_calendar_store/protocol.mojo -- the write protocol every event and
#   override write goes through (store.mojo's header says why).
# =============================================================================
#
#   settle            read the calendar row; when it holds a write, apply that
#                     write and finish it, in a transaction of its own (so it
#                     stands whatever the caller does next)
#   quiet_calendar    read the calendar row inside the caller's transaction;
#                     ERR_BUSY when it holds a write
#   run_intent        claim:  CAS the row from (modseq M, no write) to
#                             (modseq M, write W at seq M + 1)
#                     apply:  write W's rows, each guarded on `modseq < M + 1`
#                     finish: CAS the row from (write at M + 1) to
#                             (modseq M + 1, no write)
#
# Applying is idempotent and never moves a row backwards: an event or
# override row is created when absent, else updated only while its modseq is
# below the write's seq. So any writer may apply a write it finds held, and a
# writer that finds its own write already finished by another has succeeded.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbColVal, DbValue, Filter, Pred
from komira_proto_codec import decode_json

from komira_calendar_proto.calendar import Event, OccurrenceOverride

from .errors import busy, not_found
from .rows import (
    CalendarRecord,
    Intent,
    KIND_CALENDAR_DELETE,
    KIND_EVENT,
    KIND_NONE,
    all_of,
    delete_all,
    eq,
    flag,
    i64,
    read_calendar,
    set_to,
    txt,
    update_rows,
)
from .schema import (
    T_CALENDARS,
    T_EVENTS,
    T_OVERRIDES,
    event_cols,
    override_cols,
    override_key,
)


def settle[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String) raises:
    """Apply and finish the write the calendar row holds, if any, in a
    transaction of its own. Raises not found."""
    var got = read_calendar[RT, DB](db, reactor, calendar_id)
    if not got:
        raise not_found()
    var rec = got.take()
    if rec.pending_seq == 0:
        return
    db.begin[RT](reactor)
    try:
        apply_intent[RT, DB](db, reactor, calendar_id, rec.calendar.owner, rec.pending_seq, rec.pending)
        finish_intent[RT, DB](db, reactor, calendar_id, rec.pending_seq, rec.pending.kind)
        db.commit[RT](reactor)
    except e:
        db.rollback[RT](reactor)
        raise e^


def quiet_calendar[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String) raises -> CalendarRecord:
    """The calendar row, which must hold no write: ERR_BUSY when another
    writer claimed it since `settle`. Raises not found."""
    var got = read_calendar[RT, DB](db, reactor, calendar_id)
    if not got:
        raise not_found()
    var rec = got.take()
    if rec.pending_seq != 0:
        raise busy()
    return rec^


def run_intent[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    rec: CalendarRecord,
    intent: Intent,
    calendar_version: Optional[UInt64],
) raises -> Int:
    """Claim, apply and finish `intent` on the calendar `rec` was read from,
    at seq `rec.modseq + 1`, which it returns. The claim also requires the
    calendar's version to be `calendar_version` when one is given. Raises
    ERR_BUSY when the claim loses."""
    var seq = rec.modseq + 1
    var cid = rec.calendar.id.copy()
    var guard = List[Pred]()
    guard.append(eq("id", txt(cid)))
    guard.append(eq("modseq", i64(rec.modseq)))
    guard.append(eq("pending_seq", i64(0)))
    if calendar_version:
        guard.append(eq("version", i64(Int(calendar_version.value()))))
    var claim = List[DbColVal]()
    claim.append(set_to("pending_seq", i64(seq)))
    claim.append(set_to("pending_kind", i64(intent.kind)))
    claim.append(set_to("pending_id", txt(intent.id)))
    claim.append(set_to("pending_body", txt(intent.body)))
    claim.append(set_to("pending_deleted", flag(intent.deleted)))
    claim.append(set_to("pending_first", i64(intent.first)))
    claim.append(set_to("pending_last", i64(intent.last)))
    if update_rows[RT, DB](db, reactor, T_CALENDARS, Filter.all_of(guard^), claim^) != 1:
        raise busy()
    apply_intent[RT, DB](db, reactor, cid, rec.calendar.owner, seq, intent)
    finish_intent[RT, DB](db, reactor, cid, seq, intent.kind)
    return seq


def _stored_body(intent: Intent) -> String:
    """The body a row keeps: none for a tombstone."""
    if intent.deleted:
        return String()
    return intent.body.copy()


def _upsert[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    cols: List[String],
    vals: List[DbValue],
    seq: Int,
) raises:
    """Create the row `vals` (its id first), or, when the id exists, set its
    other columns while its modseq is below `seq`."""
    if db.create_if_absent[RT](reactor, String(table), String("id"), vals[0].copy(), cols, vals):
        return
    var sets = List[DbColVal]()
    for i in range(1, len(cols)):
        sets.append(DbColVal.bind(cols[i].copy(), vals[i].copy()))
    _ = update_rows[RT, DB](
        db, reactor, table, all_of(eq("id", vals[0].copy()), Pred.lt(String("modseq"), i64(seq))), sets^
    )


def apply_intent[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    calendar_id: String,
    owner: String,
    seq: Int,
    intent: Intent,
) raises:
    """Write `intent`'s rows at `seq` (module header)."""
    if intent.kind == KIND_CALENDAR_DELETE:
        _ = delete_all[RT, DB](db, reactor, String(T_OVERRIDES), all_of(eq("calendar_id", txt(calendar_id))))
        _ = delete_all[RT, DB](db, reactor, String(T_EVENTS), all_of(eq("calendar_id", txt(calendar_id))))
        _ = db.delete_by_key[RT](reactor, String(T_CALENDARS), String("id"), txt(calendar_id))
        return
    if intent.kind == KIND_EVENT:
        var ev = decode_json[Event](intent.body)
        var vals = List[DbValue]()
        vals.append(txt(ev.id))
        vals.append(txt(owner))
        vals.append(txt(calendar_id))
        vals.append(txt(ev.uid))
        vals.append(flag(intent.deleted))
        vals.append(i64(Int(ev.version)))
        vals.append(i64(seq))
        vals.append(i64(intent.first))
        vals.append(i64(intent.last))
        vals.append(txt(_stored_body(intent)))
        _upsert[RT, DB](db, reactor, T_EVENTS, event_cols(), vals, seq)
        if intent.deleted:
            _ = delete_all[RT, DB](db, reactor, String(T_OVERRIDES), all_of(eq("event_id", txt(ev.id))))
        return
    # KIND_OVERRIDE: the override row, then its event's span and modseq.
    var ov = decode_json[OccurrenceOverride](intent.body)
    var vals = List[DbValue]()
    vals.append(txt(override_key(ov.event_id, ov.original_start)))
    vals.append(txt(owner))
    vals.append(txt(calendar_id))
    vals.append(txt(ov.event_id))
    vals.append(txt(ov.original_start))
    vals.append(flag(intent.deleted))
    vals.append(i64(Int(ov.version)))
    vals.append(i64(seq))
    vals.append(txt(_stored_body(intent)))
    _upsert[RT, DB](db, reactor, T_OVERRIDES, override_cols(), vals, seq)
    var span = List[DbColVal]()
    span.append(set_to("modseq", i64(seq)))
    span.append(set_to("first_start_utc", i64(intent.first)))
    span.append(set_to("last_end_utc", i64(intent.last)))
    _ = update_rows[RT, DB](
        db, reactor, T_EVENTS, all_of(eq("id", txt(ov.event_id)), Pred.lt(String("modseq"), i64(seq))), span^
    )


def finish_intent[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String, seq: Int, kind: Int) raises:
    """Advance the calendar's modseq to `seq` and release its write. A
    calendar delete removed the row: nothing to finish. When the release
    misses, another writer finished this write (the row's modseq reached
    `seq`, or the row is gone); otherwise raises ERR_BUSY."""
    if kind == KIND_CALENDAR_DELETE:
        return
    var done = List[DbColVal]()
    done.append(set_to("modseq", i64(seq)))
    done.append(set_to("pending_seq", i64(0)))
    done.append(set_to("pending_kind", i64(KIND_NONE)))
    done.append(set_to("pending_id", txt(String())))
    done.append(set_to("pending_body", txt(String())))
    done.append(set_to("pending_deleted", flag(False)))
    done.append(set_to("pending_first", i64(0)))
    done.append(set_to("pending_last", i64(0)))
    var guard = all_of(eq("id", txt(calendar_id)), eq("pending_seq", i64(seq)))
    if update_rows[RT, DB](db, reactor, T_CALENDARS, guard, done^) == 1:
        return
    var got = read_calendar[RT, DB](db, reactor, calendar_id)
    if got and got.value().modseq < seq:
        raise busy()
