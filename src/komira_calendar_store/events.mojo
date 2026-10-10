# =============================================================================
# komira_calendar_store/events.mojo -- event and override writes and reads.
# =============================================================================
#
# Every write here runs inside begin/commit, rolls back on any refusal, and
# changes rows only through `run_intent` (protocol.mojo). Each refusal is
# decided after `quiet_calendar` read the calendar holding no write and
# before the claim, and the claim requires the calendar's modseq to be the
# one read; so no other write can land between a check and the write it
# allows (store.mojo, THE WRITE PROTOCOL).
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_calendar import check_event, check_override, expand, parse_local_date, parse_local_datetime
from komira_calendar_ics import ZoneSource
from komira_calendar_proto.calendar import Event, OccurrenceOverride
from komira_datetime import Zone
from komira_db import Database, DbRow, Order, Pred, generate_uuidv7
from komira_proto_codec import decode_json_lenient, encode_json
from komira_wkt import Timestamp

from .errors import (
    ERR_UID_TAKEN,
    NO_SUCH_OCCURRENCE,
    TIME_ZONE_UNKNOWN,
    UID_CHANGED,
    WINDOW_EMPTY,
    invalid,
    invalid_field,
    not_found,
    version_conflict,
)
from .protocol import quiet_calendar, run_intent, settle
from .rows import (
    Intent,
    KIND_EVENT,
    KIND_OVERRIDE,
    all_of,
    eq,
    event_from_row,
    flag,
    i64,
    override_from_row,
    read_calendar,
    ts,
    txt,
)
from .schema import T_EVENTS, T_OVERRIDES, event_cols, override_cols, override_key, strs
from .span import NO_END, NO_START, SECONDS_PER_DAY, UtcSpan, utc_span


def known_zone[Z: ZoneSource](name: String, zones: Z) raises -> Zone:
    """The zone `name`; refused as TIME_ZONE_UNKNOWN when `zones` has none."""
    try:
        return zones.zone(name)
    except e:
        raise invalid_field(TIME_ZONE_UNKNOWN, "timeZone", String(e))


def _zone_of[Z: ZoneSource](event: Event, zones: Z) raises -> Optional[Zone]:
    """The zone of a timed event; None for an all-day one."""
    if event.show_without_time:
        return None
    return known_zone(event.time_zone, zones)


def _checked(event: Event) raises:
    var refusal = check_event(event)
    if refusal:
        raise invalid(refusal.value())


def _intent(kind: Int, id: String, body: String, deleted: Bool, span: UtcSpan) -> Intent:
    return Intent(kind, id.copy(), body.copy(), deleted, span.first_start_utc, span.last_end_utc)


def live_event[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String, event_id: String) raises -> Event:
    """The live event `event_id` of `calendar_id`; not found when it is in
    another calendar or deleted."""
    var got = db.get_by_key[RT](reactor, String(T_EVENTS), event_cols(), String("id"), txt(event_id))
    if not got:
        raise not_found()
    var row = got.take()
    if row.get_text(2) != calendar_id or row.get_int8(4) != 0:
        raise not_found()
    return event_from_row(row)


def live_overrides[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String, event_id: String) raises -> List[OccurrenceOverride]:
    """The live overrides of an event, by original start."""
    var rows = db.query_rows[RT](
        reactor,
        String(T_OVERRIDES),
        override_cols(),
        all_of(eq("calendar_id", txt(calendar_id)), eq("event_id", txt(event_id)), eq("deleted", flag(False))),
        List[Order](),
        Optional[UInt32](),
    )
    var out = List[OccurrenceOverride]()
    for i in range(rows.__len__()):
        out.append(override_from_row(rows.row(i)))
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].original_start > out[j].original_start:
            var t = out[j - 1].copy()
            out[j - 1] = out[j].copy()
            out[j] = t^
            j -= 1
    return out^


def _without(overrides: List[OccurrenceOverride], original_start: String) -> List[OccurrenceOverride]:
    var out = List[OccurrenceOverride]()
    for i in range(len(overrides)):
        if overrides[i].original_start != original_start:
            out.append(overrides[i].copy())
    return out^


def _is_occurrence(event: Event, original_start: String) raises -> Bool:
    """True when an occurrence of `event` (after its exdates) starts at
    `original_start`."""
    var s: Int
    if event.show_without_time:
        s = parse_local_date(original_start) * SECONDS_PER_DAY
    else:
        s = parse_local_datetime(original_start).seconds()
    var found = expand(event, s, s + 1)
    for i in range(len(found)):
        if found[i].start == s:
            return True
    return False


def insert_event[
    RT: Runtime, DB: Database, Z: ZoneSource
](
    mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String, event: Event, zones: Z, now_ms: Int64
) raises -> Event:
    _checked(event)
    var zone = _zone_of(event, zones)
    var out = event.copy()
    out.id = generate_uuidv7().to_hyphenated()
    out.calendar_id = calendar_id.copy()
    if out.uid.byte_length() == 0:
        out.uid = out.id.copy()
    out.version = UInt64(1)
    out.created_at = Optional[Timestamp](ts(now_ms))
    out.updated_at = Optional[Timestamp](ts(now_ms))
    var span = utc_span(out, List[OccurrenceOverride](), zone)
    settle[RT, DB](db, reactor, calendar_id)
    db.begin[RT](reactor)
    try:
        var rec = quiet_calendar[RT, DB](db, reactor, calendar_id)
        var taken = db.query_rows[RT](
            reactor,
            String(T_EVENTS),
            strs("id"),
            all_of(eq("calendar_id", txt(calendar_id)), eq("uid", txt(out.uid)), eq("deleted", flag(False))),
            List[Order](),
            Optional[UInt32](),
        )
        if taken.__len__() > 0:
            raise Error(String(ERR_UID_TAKEN))
        _ = run_intent[RT, DB](db, reactor, rec, _intent(KIND_EVENT, out.id, encode_json(out), False, span), None)
        db.commit[RT](reactor)
        return out^
    except e:
        db.rollback[RT](reactor)
        raise e^


def replace_event[
    RT: Runtime, DB: Database, Z: ZoneSource
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    calendar_id: String,
    event_id: String,
    expected_version: UInt64,
    event: Event,
    zones: Z,
    now_ms: Int64,
) raises -> Event:
    _checked(event)
    var zone = _zone_of(event, zones)
    settle[RT, DB](db, reactor, calendar_id)
    db.begin[RT](reactor)
    try:
        var rec = quiet_calendar[RT, DB](db, reactor, calendar_id)
        var current = live_event[RT, DB](db, reactor, calendar_id, event_id)
        if current.version != expected_version:
            raise version_conflict()
        if event.uid.byte_length() > 0 and event.uid != current.uid:
            raise invalid_field(UID_CHANGED, "uid", String("an event's uid cannot change"))
        var out = event.copy()
        out.id = event_id.copy()
        out.calendar_id = calendar_id.copy()
        out.uid = current.uid.copy()
        out.version = expected_version + 1
        out.created_at = current.created_at.copy()
        out.updated_at = Optional[Timestamp](ts(now_ms))
        var span = utc_span(out, live_overrides[RT, DB](db, reactor, calendar_id, event_id), zone)
        _ = run_intent[RT, DB](db, reactor, rec, _intent(KIND_EVENT, out.id, encode_json(out), False, span), None)
        db.commit[RT](reactor)
        return out^
    except e:
        db.rollback[RT](reactor)
        raise e^


def remove_event[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String, event_id: String, expected_version: UInt64) raises -> Int:
    settle[RT, DB](db, reactor, calendar_id)
    db.begin[RT](reactor)
    try:
        var rec = quiet_calendar[RT, DB](db, reactor, calendar_id)
        var gone = live_event[RT, DB](db, reactor, calendar_id, event_id)
        if gone.version != expected_version:
            raise version_conflict()
        gone.version = expected_version + 1
        var seq = run_intent[RT, DB](
            db, reactor, rec, _intent(KIND_EVENT, event_id, encode_json(gone), True, UtcSpan(NO_START, NO_END)), None
        )
        db.commit[RT](reactor)
        return seq
    except e:
        db.rollback[RT](reactor)
        raise e^


def _override_row[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], event_id: String, original_start: String) raises -> Optional[DbRow]:
    return db.get_by_key[RT](
        reactor, String(T_OVERRIDES), override_cols(), String("id"), txt(override_key(event_id, original_start))
    )


def write_override[
    RT: Runtime, DB: Database, Z: ZoneSource
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    calendar_id: String,
    edit: OccurrenceOverride,
    expected_version: UInt64,
    zones: Z,
) raises -> OccurrenceOverride:
    settle[RT, DB](db, reactor, calendar_id)
    db.begin[RT](reactor)
    try:
        var rec = quiet_calendar[RT, DB](db, reactor, calendar_id)
        var event = live_event[RT, DB](db, reactor, calendar_id, edit.event_id)
        var refusal = check_override(edit, event)
        if refusal:
            raise invalid(refusal.value())
        if not _is_occurrence(event, edit.original_start):
            raise invalid_field(
                NO_SUCH_OCCURRENCE, "originalStart", String("no occurrence of the event starts at ") + edit.original_start
            )
        var prior = 0
        var live = False
        var row = _override_row[RT, DB](db, reactor, edit.event_id, edit.original_start)
        if row:
            prior = Int(row.value().get_int8(6))
            live = row.value().get_int8(5) == 0
        if expected_version != 0 and (not live or UInt64(prior) != expected_version):
            raise version_conflict()
        var out = edit.copy()
        out.version = UInt64(prior + 1)
        var all = _without(live_overrides[RT, DB](db, reactor, calendar_id, edit.event_id), edit.original_start)
        all.append(out.copy())
        var span = utc_span(event, all, _zone_of(event, zones))
        _ = run_intent[RT, DB](db, reactor, rec, _intent(KIND_OVERRIDE, event.id, encode_json(out), False, span), None)
        db.commit[RT](reactor)
        return out^
    except e:
        db.rollback[RT](reactor)
        raise e^


def remove_override[
    RT: Runtime, DB: Database, Z: ZoneSource
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    calendar_id: String,
    event_id: String,
    original_start: String,
    expected_version: UInt64,
    zones: Z,
) raises:
    settle[RT, DB](db, reactor, calendar_id)
    db.begin[RT](reactor)
    try:
        var rec = quiet_calendar[RT, DB](db, reactor, calendar_id)
        var event = live_event[RT, DB](db, reactor, calendar_id, event_id)
        var row = _override_row[RT, DB](db, reactor, event_id, original_start)
        if not row or row.value().get_int8(5) != 0:
            raise not_found()
        var gone = override_from_row(row.value())
        if gone.version != expected_version:
            raise version_conflict()
        gone.version = expected_version + 1
        var rest = _without(live_overrides[RT, DB](db, reactor, calendar_id, event_id), original_start)
        var span = utc_span(event, rest, _zone_of(event, zones))
        _ = run_intent[RT, DB](db, reactor, rec, _intent(KIND_OVERRIDE, event_id, encode_json(gone), True, span), None)
        db.commit[RT](reactor)
    except e:
        db.rollback[RT](reactor)
        raise e^


def window_events[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], calendar_id: String, from_utc: Int, to_utc: Int) raises -> List[Event]:
    """The live events whose stored UTC span overlaps [from_utc, to_utc), by
    first start then id. The caller expands them."""
    if to_utc <= from_utc:
        raise invalid_field(WINDOW_EMPTY, "to", String("the window's end is not after its start"))
    if not read_calendar[RT, DB](db, reactor, calendar_id):
        raise not_found()
    var rows = db.query_rows[RT](
        reactor,
        String(T_EVENTS),
        strs("first_start_utc", "id", "body"),
        all_of(
            eq("calendar_id", txt(calendar_id)),
            eq("deleted", flag(False)),
            Pred.lt(String("first_start_utc"), i64(to_utc)),
            Pred.gte(String("last_end_utc"), i64(from_utc + 1)),
        ),
        List[Order](),
        Optional[UInt32](),
    )
    var order = List[Int]()
    var firsts = List[Int]()
    var ids = List[String]()
    for i in range(rows.__len__()):
        order.append(i)
        firsts.append(Int(rows.row(i).get_int8(0)))
        ids.append(rows.row(i).get_text(1))
    for i in range(1, len(order)):
        var j = i
        while j > 0 and _after(firsts, ids, order[j - 1], order[j]):
            var t = order[j - 1]
            order[j - 1] = order[j]
            order[j] = t
            j -= 1
    var out = List[Event]()
    for i in range(len(order)):
        out.append(event_from_row_body(rows.row(order[i])))
    return out^


def _after(firsts: List[Int], ids: List[String], a: Int, b: Int) -> Bool:
    if firsts[a] != firsts[b]:
        return firsts[a] > firsts[b]
    return ids[a] > ids[b]


def event_from_row_body(row: DbRow) raises -> Event:
    return decode_json_lenient[Event](row.get_text(2))
