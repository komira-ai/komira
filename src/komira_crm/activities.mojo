# =============================================================================
# komira_crm/activities.mojo -- notes, calls, meetings and logged emails on
#   an account, a deal or a card.
# =============================================================================
#
# An activity has no key table and no archive. Its actor is the caller that
# wrote it, never a client field. An activity on an account or a deal names a
# live one; an activity on a card names the card by id (the cards are the
# contacts store's). A system activity (STAGE_CHANGED, deals.mojo) refuses
# every update.
#
# An activity on a deal also moves the deal's `last_activity_at` forward to
# its `occurred_at`, with a feed number of its own, in the same transaction;
# the guard (`last_activity_at < occurred_at`) makes that a maximum, so an
# older activity leaves it. An update of an activity does not move it.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbColVal, DbValue, Filter, Order, Pred, generate_uuidv7
from komira_wkt import Timestamp

from komira_crm_proto.crm import Activity, EntityKind, Principal

from komira_crm.accounts import find_account
from komira_crm.core import cas, load, next_modseq, no_limit, order_of, padded, row_updates
from komira_crm.deals import find_deal
from komira_crm.errors import ERR_SYSTEM_ACTIVITY, invalid, not_found
from komira_crm.rows import activity_from_row, activity_row, int8, kind_name, micros, text, to_micro
from komira_crm.schema import ACTIVITIES, DEALS, activity_cols, strs
from komira_crm.validate import check_activity, check_principal


def create_activity[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], actor: Principal, activity: Activity, now: Timestamp) raises -> Activity:
    """Record an activity by `actor`; `occurred_at` defaults to `now`."""
    check_activity(activity)
    check_principal(Optional[Principal](actor.copy()), "actor")
    var a = activity.copy()
    a.id = generate_uuidv7().to_hyphenated()
    a.actor = Optional[Principal](actor.copy())
    a.system = False
    a.version = UInt64(1)
    a.from_stage_key = String()
    a.to_stage_key = String()
    a.occurred_at = Optional[Timestamp](to_micro(activity.occurred_at.value() if activity.occurred_at else now))
    var at = micros(a.occurred_at.value())
    db.begin[RT](reactor)
    try:
        var deal_last = Int64(-1)
        if a.subject_kind.value == EntityKind.DEAL:
            var d = find_deal[DB, RT](db, reactor, a.subject_id)
            if not d:
                raise invalid("subjectId", "no such deal")
            ref last = d.value().last_activity_at
            deal_last = micros(last.value()) if last else Int64(0)
        elif a.subject_kind.value == EntityKind.ACCOUNT:
            if not find_account[DB, RT](db, reactor, a.subject_id):
                raise invalid("subjectId", "no such account")
        a.modseq = next_modseq[DB, RT](db, reactor)
        _ = db.put[RT](reactor, String(ACTIVITIES), activity_cols(), activity_row(a))
        if deal_last >= 0 and deal_last < at:
            var guard = List[Pred]()
            guard.append(Pred.eq(String("id"), text(a.subject_id)))
            guard.append(Pred.lt(String("last_activity_at"), DbValue.int8(at)))
            var updates = List[DbColVal]()
            updates.append(DbColVal.bind(String("last_activity_at"), DbValue.int8(at)))
            updates.append(DbColVal.bind(String("modseq"), int8(next_modseq[DB, RT](db, reactor))))
            _ = db.conditional_update[RT](
                reactor, String(DEALS), Filter.all_of(guard^), updates^, False, Optional[String](), List[String]()
            )
        db.commit[RT](reactor)
        return a^
    except e:
        db.rollback[RT](reactor)
        raise e^


def get_activity[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink], id: String) raises -> Activity:
    var got = load[DB, RT](db, reactor, ACTIVITIES, activity_cols(), id)
    if not got:
        raise not_found()
    return activity_from_row(got.take())


def list_activities[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], subject_kind: Int, subject_id: String) raises -> List[Activity]:
    """The activities of one subject, newest `occurred_at` first (then the
    higher id first)."""
    var preds = List[Pred]()
    preds.append(Pred.eq(String("subject_kind"), text(kind_name(subject_kind))))
    preds.append(Pred.eq(String("subject_id"), text(subject_id)))
    var rows = db.query_rows[RT](
        reactor, String(ACTIVITIES), activity_cols(), Filter.all_of(preds^), List[Order](), no_limit()
    )
    var all = List[Activity]()
    var keys = List[String]()
    for i in range(rows.__len__()):
        var a = activity_from_row(rows.row(i))
        keys.append(padded(UInt64(micros(a.occurred_at.value()))) + a.id)
        all.append(a^)
    var asc = order_of(keys)
    var out = List[Activity]()
    for i in range(len(asc) - 1, -1, -1):
        out.append(all[asc[i]].copy())
    return out^


def update_activity[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], id: String, expected_version: UInt64, activity: Activity) raises -> Activity:
    """Replace a client activity's kind, body and `occurred_at` (absent keeps
    it) if its version is still `expected_version`. Its subject and actor
    cannot change; a system activity cannot be changed at all."""
    check_activity(activity)
    db.begin[RT](reactor)
    try:
        var cur = get_activity[DB, RT](db, reactor, id)
        if cur.system:
            raise Error(String(ERR_SYSTEM_ACTIVITY))
        if activity.subject_kind.value != cur.subject_kind.value or activity.subject_id != cur.subject_id:
            raise invalid("subjectId", "cannot change")
        var a = cur.copy()
        a.kind = activity.kind
        a.body = activity.body
        if activity.occurred_at:
            a.occurred_at = Optional[Timestamp](to_micro(activity.occurred_at.value()))
        a.version = expected_version + 1
        a.modseq = next_modseq[DB, RT](db, reactor)
        cas[DB, RT](
            db, reactor, ACTIVITIES, id, expected_version, row_updates(activity_cols(), activity_row(a), strs())
        )
        db.commit[RT](reactor)
        return a^
    except e:
        db.rollback[RT](reactor)
        raise e^
