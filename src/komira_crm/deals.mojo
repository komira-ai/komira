# =============================================================================
# komira_crm/deals.mojo -- deals, and the stage_changed activity a stage
#   change writes.
# =============================================================================
#
# A deal with an `external_id` is guarded by its key row (DEAL, external_id)
# in crm_external_ids, as an account is (accounts.mojo). A deal's stage is a
# key of its pipeline's stages; its account, when it names one, is a live
# account.
#
# A STAGE CHANGE (an update that changes `stage_key` or `pipeline_id`) writes
# the deal and a system activity of kind STAGE_CHANGED in one transaction:
# the deal takes feed number n and the activity n + 1, so a feed page can
# end between them and the next page still returns the activity.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, Filter, Order, Pred, generate_uuidv7
from komira_wkt import Timestamp

from komira_crm_proto.crm import Activity, ActivityKind, Deal, EntityKind, Principal, Status

from komira_crm.accounts import claim_external_id, external_id_live, find_account
from komira_crm.core import cas, load, next_modseq, no_limit, order_of, row_updates
from komira_crm.errors import invalid, not_found
from komira_crm.fields import check_custom_fields
from komira_crm.pipelines import check_stage
from komira_crm.rows import activity_row, deal_from_row, deal_row, micros, text, to_micro
from komira_crm.schema import ACTIVITIES, DEALS, activity_cols, deal_cols, strs
from komira_crm.validate import check_deal, check_principal


def _check_refs[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink], d: Deal) raises:
    """The deal's stage is in its pipeline, its account (if any) is live, and
    its custom fields have their definitions' types."""
    check_stage[DB, RT](db, reactor, d.pipeline_id, d.stage_key)
    if d.account_id.byte_length() > 0:
        if not find_account[DB, RT](db, reactor, d.account_id):
            raise invalid("accountId", "no such account")
    check_custom_fields[DB, RT](db, reactor, EntityKind.DEAL, d.custom_fields)


def create_deal[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], deal: Deal, now: Timestamp) raises -> Deal:
    check_deal(deal)
    var d = deal.copy()
    d.id = generate_uuidv7().to_hyphenated()
    d.version = UInt64(1)
    d.last_activity_at = Optional[Timestamp]()
    d.created_at = Optional[Timestamp](to_micro(now))
    d.updated_at = Optional[Timestamp](to_micro(now))
    db.begin[RT](reactor)
    try:
        _check_refs[DB, RT](db, reactor, d)
        d.modseq = next_modseq[DB, RT](db, reactor)
        _ = db.put[RT](reactor, String(DEALS), deal_cols(), deal_row(d))
        if d.external_id.byte_length() > 0:
            claim_external_id[DB, RT](db, reactor, EntityKind.DEAL, d.external_id, d.id)
        db.commit[RT](reactor)
        return d^
    except e:
        db.rollback[RT](reactor)
        raise e^


def find_deal[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink], id: String) raises -> Optional[Deal]:
    """A live deal, archived or not; None when there is none."""
    var got = load[DB, RT](db, reactor, DEALS, deal_cols(), id)
    if not got:
        return Optional[Deal]()
    var d = deal_from_row(got.take())
    if not external_id_live[DB, RT](db, reactor, EntityKind.DEAL, d.external_id, d.id):
        return Optional[Deal]()
    return Optional[Deal](d^)


def get_deal[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink], id: String) raises -> Deal:
    """A live deal, archived or not."""
    var got = find_deal[DB, RT](db, reactor, id)
    if not got:
        raise not_found()
    return got.take()


def list_deals[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], pipeline_id: String, include_archived: Bool) raises -> List[Deal]:
    """The live deals of one pipeline (every pipeline when `pipeline_id` is
    empty), by id; the archived ones only when asked. A deal of an archived
    account is listed."""
    var preds = List[Pred]()
    if pipeline_id.byte_length() > 0:
        preds.append(Pred.eq(String("pipeline_id"), text(pipeline_id)))
    if not include_archived:
        preds.append(Pred.eq(String("status"), text(Status(Status.ACTIVE).json_name())))
    var rows = db.query_rows[RT](reactor, String(DEALS), deal_cols(), Filter.all_of(preds^), List[Order](), no_limit())
    var live = List[Deal]()
    var keys = List[String]()
    for i in range(rows.__len__()):
        var d = deal_from_row(rows.row(i))
        if external_id_live[DB, RT](db, reactor, EntityKind.DEAL, d.external_id, d.id):
            keys.append(d.id)
            live.append(d^)
    var out = List[Deal]()
    for i in order_of(keys):
        out.append(live[i].copy())
    return out^


def update_deal[
    DB: Database, RT: Runtime
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    actor: Principal,
    id: String,
    expected_version: UInt64,
    deal: Deal,
    now: Timestamp,
) raises -> Deal:
    """Replace a live deal's fields (archiving is `status`) if its version is
    still `expected_version`. `external_id` cannot change (an empty one keeps
    it) and `last_activity_at` is the store's. A stage change also writes a
    STAGE_CHANGED system activity by `actor`, in the same transaction."""
    check_deal(deal)
    check_principal(Optional[Principal](actor.copy()), "actor")
    var at = to_micro(now)
    db.begin[RT](reactor)
    try:
        var cur = get_deal[DB, RT](db, reactor, id)
        if deal.external_id.byte_length() > 0 and deal.external_id != cur.external_id:
            raise invalid("externalId", "cannot change")
        _check_refs[DB, RT](db, reactor, deal)
        var d = deal.copy()
        d.id = String(id)
        d.external_id = cur.external_id
        d.created_at = cur.created_at
        d.updated_at = Optional[Timestamp](at)
        d.last_activity_at = cur.last_activity_at
        d.version = expected_version + 1
        var moved = d.stage_key != cur.stage_key or d.pipeline_id != cur.pipeline_id
        if moved and (not cur.last_activity_at or micros(cur.last_activity_at.value()) < micros(at)):
            d.last_activity_at = Optional[Timestamp](at)
        d.modseq = next_modseq[DB, RT](db, reactor)
        cas[DB, RT](db, reactor, DEALS, id, expected_version, row_updates(deal_cols(), deal_row(d), strs()))
        if moved:
            var act = Activity(
                id=generate_uuidv7().to_hyphenated(),
                kind=ActivityKind(ActivityKind.STAGE_CHANGED),
                subject_kind=EntityKind(EntityKind.DEAL),
                subject_id=String(id),
                body=String(),
                actor=Optional[Principal](actor.copy()),
                occurred_at=Optional[Timestamp](at),
                system=True,
                version=UInt64(1),
                modseq=UInt64(0),
                from_stage_key=cur.stage_key,
                to_stage_key=d.stage_key,
            )
            act.modseq = next_modseq[DB, RT](db, reactor)
            _ = db.put[RT](reactor, String(ACTIVITIES), activity_cols(), activity_row(act))
        db.commit[RT](reactor)
        return d^
    except e:
        db.rollback[RT](reactor)
        raise e^
