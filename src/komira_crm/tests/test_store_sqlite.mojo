# =============================================================================
# test_store_sqlite.mojo -- CrmStore on komira_db_sqlite, from the library's
#   own tests: every call, and the refusals each one makes.
# =============================================================================
#
# The store's contract on SQLite and Firestore is
# //src/tests/conformance/komira_crm_store_conformance; this file runs the
# store on SQLite (`test_deps`), so the store's own package measures its
# lines. Each check would fail on the defect its comment names. Refusals are
# compared by their exact text.
#
#   init        the counter and the six-stage default pipeline once; a store
#               whose dataset was never initialized refuses writes
#   accounts    create (times cut to the microsecond), get, list (archived
#               hidden unless asked, by id), update (version, archive), a
#               stale version, an external_id taken by another account but
#               free for a deal, an external_id that cannot change, one org
#               card behind two accounts, custom fields checked against
#               their definitions
#   links       link, relink (the role changes, one row), list by card id,
#               unlink twice, a link to a missing account
#   pipelines   create, get, list (by name, then id), update, stale, missing
#   deals       create (a stage of the pipeline, a live account), a stage
#               change writing a STAGE_CHANGED activity numbered right after
#               the deal, an update that does not move writing none, list
#               by pipeline and archived, external_id rules
#   activities  create on a deal (moving last_activity_at forward only),
#               an account and a card (an equal or older time takes no
#               number); a missing subject; list newest
#               first; update; a system activity refused; a subject change
#               refused
#   fields      create, a key taken per kind but free in another kind, list
#               by key, update of the label only
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import DbValue
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase
from komira_proto_codec import decode_json, encode_json
from komira_wkt import Timestamp
from komira_crm_proto.crm import (
    Account,
    Activity,
    ActivityKind,
    CustomFieldDef,
    Deal,
    EntityKind,
    Pipeline,
    Principal,
    StageKind,
    Status,
)

from komira_crm import (
    CrmStore,
    ERR_EXTERNAL_ID_TAKEN,
    ERR_FIELD_KEY_TAKEN,
    ERR_NOT_FOUND,
    ERR_NOT_INITIALIZED,
    ERR_SYSTEM_ACTIVITY,
    ERR_VERSION_CONFLICT,
    FEED,
    sqlite_schema,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime Store = CrmStore[SqliteDatabase]
comptime OK = "ok"
comptime NO_SUCH_ID = "00000000-0000-7000-8000-000000000000"


def _raw_store() raises -> Store:
    var db = SqliteDatabase(String(":memory:"))
    var ddl = sqlite_schema()
    for i in range(len(ddl)):
        _ = db_blocking_execute(db, ddl[i], List[DbValue]())
    return Store(db^)


def _store(mut reactor: Reactor[Rt.Sink]) raises -> Store:
    var s = _raw_store()
    _ = s.init_dataset[Rt](reactor)
    return s^


def _at(seconds: Int64) -> Timestamp:
    return Timestamp(seconds, Int32(0))


def _alice() -> Principal:
    return Principal(issuer=String("https://idp.example"), subject=String("alice"))


def _account(json: StaticString) raises -> Account:
    return decode_json[Account](String(json))


def _deal(json: String) raises -> Deal:
    return decode_json[Deal](json)


def _default_pipeline(mut store: Store, mut reactor: Reactor[Rt.Sink]) raises -> Pipeline:
    return store.list_pipelines[Rt](reactor)[0].copy()


def check_init() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _raw_store()
    var got = String(OK)
    try:
        _ = store.create_account[Rt](reactor, _account('{"orgCardId":"c"}'), _at(1))
    except e:
        got = String(e)
    assert_equal(got, ERR_NOT_INITIALIZED, "no counter row: the write is refused")
    assert_equal(len(store.list_accounts[Rt](reactor, True)), 0, "and rolled back")
    try:
        _ = store.changes[Rt](reactor, 0, 10)
    except e:
        got = String(e)
    assert_equal(got, ERR_NOT_INITIALIZED, "the feed needs the counter too")
    assert_true(store.init_dataset[Rt](reactor), "the first init creates the dataset")
    assert_false(store.init_dataset[Rt](reactor), "the second finds it")
    var ps = store.list_pipelines[Rt](reactor)
    assert_equal(len(ps), 1, "one default pipeline, not one per init")
    assert_equal(ps[0].name, "Sales")
    assert_equal(ps[0].version, UInt64(1))
    assert_equal(ps[0].modseq, UInt64(1))
    var keys = String()
    for s in ps[0].stages:
        keys += s.key + String(":") + s.kind.json_name() + String(" ")
    assert_equal(
        keys,
        "qualification:OPEN discovery:OPEN proposal:OPEN negotiation:OPEN closed_won:WON closed_lost:LOST ",
    )


def check_accounts() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var a = store.create_account[Rt](
        reactor,
        _account('{"orgCardId":"org1","domain":"example.org","owner":{"issuer":"i","subject":"s"}}'),
        Timestamp(Int64(1790000000), Int32(123456789)),
    )
    assert_equal(a.version, UInt64(1))
    assert_equal(a.modseq, UInt64(2), "the pipeline took 1")
    assert_equal(a.created_at.value().nanos, Int32(123456000), "cut to the microsecond")
    var got = store.get_account[Rt](reactor, a.id)
    assert_equal(encode_json(got), encode_json(a), "every field reads back")
    assert_equal(got.owner.value().subject, "s")
    var b = store.create_account[Rt](reactor, _account('{"orgCardId":"org1","externalId":"E1"}'), _at(2))
    assert_equal(b.org_card_id, a.org_card_id, "one org card behind two accounts")
    var err = String(OK)
    try:
        _ = store.create_account[Rt](reactor, _account('{"orgCardId":"org2","externalId":"E1"}'), _at(3))
    except e:
        err = String(e)
    assert_equal(err, ERR_EXTERNAL_ID_TAKEN, "E1 is an account's already")
    assert_equal(len(store.list_accounts[Rt](reactor, True)), 2, "the refused create left no row")
    var d = store.create_deal[Rt](
        reactor,
        _deal('{"title":"T","pipelineId":"' + _default_pipeline(store, reactor).id + '","stageKey":"discovery","externalId":"E1"}'),
        _at(4),
    )
    assert_equal(d.external_id, "E1", "a deal may carry an account's external id")
    # update: archive, version, external id rules
    var upd = _account('{"orgCardId":"org3","status":"ARCHIVED"}')
    var b2 = store.update_account[Rt](reactor, b.id, b.version, upd, _at(5))
    assert_equal(b2.version, UInt64(2))
    assert_equal(b2.external_id, "E1", "an empty external id keeps it")
    assert_equal(b2.created_at.value().seconds, Int64(2), "created_at is kept")
    assert_equal(b2.updated_at.value().seconds, Int64(5))
    assert_true(b2.modseq > d.modseq, "an update takes a new number")
    assert_equal(encode_json(store.get_account[Rt](reactor, b.id)), encode_json(b2), "the archived account resolves")
    assert_equal(len(store.list_accounts[Rt](reactor, False)), 1, "archived accounts are not listed")
    var all = store.list_accounts[Rt](reactor, True)
    assert_equal(len(all), 2)
    assert_true(all[0].id < all[1].id, "listed by id")
    try:
        _ = store.update_account[Rt](reactor, b.id, b.version, upd, _at(6))
    except e:
        err = String(e)
    assert_equal(err, ERR_VERSION_CONFLICT, "a stale version")
    try:
        _ = store.update_account[Rt](reactor, b.id, b2.version, _account('{"orgCardId":"o","externalId":"E9"}'), _at(6))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid externalId: cannot change")
    var same = store.update_account[Rt](reactor, b.id, b2.version, _account('{"orgCardId":"o","externalId":"E1"}'), _at(6))
    assert_equal(same.version, UInt64(3), "naming the same external id is not a change")
    try:
        _ = store.update_account[Rt](reactor, NO_SUCH_ID, 1, upd, _at(6))
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)
    try:
        _ = store.get_account[Rt](reactor, NO_SUCH_ID)
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)
    try:
        _ = store.create_account[Rt](reactor, _account("{}"), _at(6))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid orgCardId: required", "validated before the transaction")


def check_custom_fields() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var tier = store.create_field_def[Rt](
        reactor, decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"tier","label":"Tier"}')
    )
    _ = store.create_field_def[Rt](
        reactor, decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"size","label":"Size","type":"NUMBER"}')
    )
    var deal_tier = store.create_field_def[Rt](
        reactor, decode_json[CustomFieldDef]('{"entityKind":"DEAL","key":"tier","label":"Tier"}')
    )
    assert_true(deal_tier.id != tier.id, "one key in two kinds")
    var err = String(OK)
    try:
        _ = store.create_field_def[Rt](
            reactor, decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"tier","label":"Again"}')
        )
    except e:
        err = String(e)
    assert_equal(err, ERR_FIELD_KEY_TAKEN)
    var listed = store.list_field_defs[Rt](reactor, EntityKind.ACCOUNT)
    assert_equal(len(listed), 2, "the refused create left no definition")
    assert_equal(listed[0].key, "size", "by key")
    assert_equal(listed[1].key, "tier")
    assert_equal(len(store.list_field_defs[Rt](reactor, EntityKind.CARD)), 0)
    var ok = store.create_account[Rt](
        reactor, _account('{"orgCardId":"o","customFields":{"tier":"gold","size":"12.5"}}'), _at(1)
    )
    assert_equal(store.get_account[Rt](reactor, ok.id).custom_fields["size"], "12.5")
    try:
        _ = store.create_account[Rt](reactor, _account('{"orgCardId":"o","customFields":{"size":"big"}}'), _at(1))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid customFields: a NUMBER value must be a decimal")
    try:
        _ = store.create_account[Rt](reactor, _account('{"orgCardId":"o","customFields":{"color":"red"}}'), _at(1))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid customFields: no custom field with this key for this kind")
    # update: the label only
    var relabeled = decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"tier","label":"Level"}')
    var t2 = store.update_field_def[Rt](reactor, tier.id, tier.version, relabeled)
    assert_equal(t2.label, "Level")
    assert_equal(t2.version, UInt64(2))
    assert_equal(encode_json(store.get_field_def[Rt](reactor, tier.id)), encode_json(t2))
    try:
        _ = store.update_field_def[Rt](reactor, tier.id, tier.version, relabeled)
    except e:
        err = String(e)
    assert_equal(err, ERR_VERSION_CONFLICT)
    try:
        _ = store.update_field_def[Rt](
            reactor, tier.id, t2.version, decode_json[CustomFieldDef]('{"entityKind":"DEAL","key":"tier","label":"L"}')
        )
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid entityKind: cannot change")
    try:
        _ = store.update_field_def[Rt](
            reactor, tier.id, t2.version, decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"rank","label":"L"}')
        )
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid key: cannot change")
    try:
        _ = store.update_field_def[Rt](
            reactor,
            tier.id,
            t2.version,
            decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"tier","label":"L","type":"BOOL"}'),
        )
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid type: cannot change")
    try:
        _ = store.get_field_def[Rt](reactor, NO_SUCH_ID)
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)


def check_links() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var a = store.create_account[Rt](reactor, _account('{"orgCardId":"o"}'), _at(1))
    var l1 = store.link_contact[Rt](reactor, a.id, "card-b", "buyer")
    assert_equal(l1.role, "buyer")
    _ = store.link_contact[Rt](reactor, a.id, "card-b", "user")
    _ = store.link_contact[Rt](reactor, a.id, "card-a", "")
    var links = store.list_contacts[Rt](reactor, a.id)
    assert_equal(len(links), 2, "a relink is one row")
    assert_equal(links[0].card_id, "card-a", "by card id")
    assert_equal(links[1].role, "user", "the relink changed the role")
    assert_equal(links[1].account_id, a.id)
    assert_true(store.unlink_contact[Rt](reactor, a.id, "card-b"))
    assert_false(store.unlink_contact[Rt](reactor, a.id, "card-b"), "already unlinked")
    assert_equal(len(store.list_contacts[Rt](reactor, a.id)), 1)
    var err = String(OK)
    try:
        _ = store.link_contact[Rt](reactor, NO_SUCH_ID, "card-a", "")
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)
    try:
        _ = store.link_contact[Rt](reactor, a.id, "", "")
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid cardId: required")
    try:
        _ = store.link_contact[Rt](reactor, a.id, "c", "r\n")
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid role: must be one line with no control characters")


def check_pipelines() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var p = store.create_pipeline[Rt](
        reactor, decode_json[Pipeline]('{"name":"Alpha","stages":[{"key":"a","label":"A"}]}')
    )
    var q = store.create_pipeline[Rt](
        reactor, decode_json[Pipeline]('{"name":"Alpha","stages":[{"key":"b","label":"B","kind":"WON"}]}')
    )
    var ps = store.list_pipelines[Rt](reactor)
    assert_equal(len(ps), 3)
    assert_equal(ps[0].name, "Alpha", "by name")
    assert_equal(ps[1].name, "Alpha")
    assert_true(ps[0].id < ps[1].id, "then by id")
    assert_true(ps[0].id == p.id or ps[0].id == q.id)
    assert_equal(ps[2].name, "Sales")
    var p2 = store.update_pipeline[Rt](
        reactor, p.id, p.version, decode_json[Pipeline]('{"name":"Beta","stages":[{"key":"c","label":"C"}]}')
    )
    assert_equal(p2.version, UInt64(2))
    assert_equal(encode_json(store.get_pipeline[Rt](reactor, p.id)), encode_json(p2))
    var err = String(OK)
    try:
        _ = store.update_pipeline[Rt](reactor, p.id, p.version, p2)
    except e:
        err = String(e)
    assert_equal(err, ERR_VERSION_CONFLICT)
    try:
        _ = store.update_pipeline[Rt](reactor, NO_SUCH_ID, 1, p2)
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)
    try:
        _ = store.create_pipeline[Rt](reactor, decode_json[Pipeline]('{"name":"Empty"}'))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid stages: a pipeline has 1 to 50 stages")


def check_deals() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _default_pipeline(store, reactor).id
    var acct = store.create_account[Rt](reactor, _account('{"orgCardId":"o"}'), _at(1))
    var base = String('{"title":"T","pipelineId":"') + pid + String('","stageKey":"qualification"')
    var d = store.create_deal[Rt](
        reactor,
        _deal(base + ',"accountId":"' + acct.id + '","amountMinor":"125000","currency":"EUR","closeDate":"2026-12-31","owner":{"issuer":"i","subject":"s"},"lastActivityAt":"2026-01-01T00:00:00Z"}'),
        _at(10),
    )
    assert_false(Bool(d.last_activity_at), "a client cannot set last_activity_at")
    assert_equal(encode_json(store.get_deal[Rt](reactor, d.id)), encode_json(d), "every field reads back")
    var err = String(OK)
    try:
        _ = store.create_deal[Rt](reactor, _deal(String('{"title":"T","pipelineId":"') + pid + '","stageKey":"nope"}'), _at(1))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid stageKey: not a stage of the pipeline")
    try:
        _ = store.create_deal[Rt](reactor, _deal('{"title":"T","pipelineId":"nope","stageKey":"a"}'), _at(1))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid pipelineId: no such pipeline")
    try:
        _ = store.create_deal[Rt](reactor, _deal(base + ',"accountId":"' + NO_SUCH_ID + '"}'), _at(1))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid accountId: no such account")
    # an update that does not move the deal writes no activity
    var moved_not = _deal(String('{"title":"T2","pipelineId":"') + pid + '","stageKey":"qualification","accountId":"' + acct.id + '"}')
    var d2 = store.update_deal[Rt](reactor, _alice(), d.id, d.version, moved_not, _at(20))
    assert_equal(d2.version, UInt64(2))
    assert_equal(d2.title, "T2")
    assert_equal(d2.amount_minor, Int64(0), "an update replaces every client field")
    assert_false(Bool(d2.last_activity_at))
    assert_equal(len(store.list_activities[Rt](reactor, EntityKind.DEAL, d.id)), 0)
    # a stage change writes the activity, numbered right after the deal
    var to_proposal = _deal(String('{"title":"T2","pipelineId":"') + pid + '","stageKey":"proposal"}')
    var d3 = store.update_deal[Rt](reactor, _alice(), d.id, d2.version, to_proposal, _at(30))
    assert_equal(d3.last_activity_at.value().seconds, Int64(30), "a stage change is an activity")
    var acts = store.list_activities[Rt](reactor, EntityKind.DEAL, d.id)
    assert_equal(len(acts), 1)
    assert_equal(acts[0].kind.value, ActivityKind.STAGE_CHANGED)
    assert_true(acts[0].system)
    assert_equal(acts[0].from_stage_key, "qualification")
    assert_equal(acts[0].to_stage_key, "proposal")
    assert_equal(acts[0].actor.value().subject, "alice")
    assert_equal(acts[0].occurred_at.value().seconds, Int64(30))
    assert_equal(acts[0].modseq, d3.modseq + 1, "n for the deal, n + 1 for its activity")
    try:
        _ = store.update_activity[Rt](reactor, acts[0].id, acts[0].version, decode_json[Activity]('{"subjectKind":"DEAL","subjectId":"' + d.id + '"}'))
    except e:
        err = String(e)
    assert_equal(err, ERR_SYSTEM_ACTIVITY)
    # a stage change at an earlier time leaves last_activity_at
    var back = _deal(String('{"title":"T2","pipelineId":"') + pid + '","stageKey":"discovery"}')
    var d4 = store.update_deal[Rt](reactor, _alice(), d.id, d3.version, back, _at(25))
    assert_equal(d4.last_activity_at.value().seconds, Int64(30), "the latest activity time is kept")
    # a pipeline change is a move too
    var other = store.create_pipeline[Rt](
        reactor, decode_json[Pipeline]('{"name":"Other","stages":[{"key":"discovery","label":"D"}]}')
    )
    var d5 = store.update_deal[Rt](
        reactor,
        _alice(),
        d.id,
        d4.version,
        _deal(String('{"title":"T2","pipelineId":"') + other.id + '","stageKey":"discovery","status":"ARCHIVED"}'),
        _at(40),
    )
    assert_equal(len(store.list_activities[Rt](reactor, EntityKind.DEAL, d.id)), 3, "same key, other pipeline: a move")
    assert_equal(d5.last_activity_at.value().seconds, Int64(40))
    assert_equal(len(store.list_deals[Rt](reactor, String(), False)), 0, "archived deals are not listed")
    assert_equal(len(store.list_deals[Rt](reactor, other.id, True)), 1)
    assert_equal(len(store.list_deals[Rt](reactor, pid, True)), 0, "listed by pipeline")
    var e2 = store.create_deal[Rt](reactor, _deal(base + ',"externalId":"X"}'), _at(50))
    var e1 = store.create_deal[Rt](reactor, _deal(base + "}"), _at(50))
    var listed = store.list_deals[Rt](reactor, String(), False)
    assert_equal(len(listed), 2)
    assert_true(listed[0].id < listed[1].id, "by id")
    assert_true(listed[0].id == e2.id or listed[1].id == e2.id)
    assert_true(listed[0].id == e1.id or listed[1].id == e1.id)
    try:
        _ = store.create_deal[Rt](reactor, _deal(base + ',"externalId":"X"}'), _at(50))
    except e:
        err = String(e)
    assert_equal(err, ERR_EXTERNAL_ID_TAKEN)
    try:
        _ = store.update_deal[Rt](reactor, _alice(), e2.id, e2.version, _deal(base + ',"externalId":"Y"}'), _at(51))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid externalId: cannot change")
    try:
        _ = store.update_deal[Rt](reactor, _alice(), e2.id, e2.version + 5, _deal(base + "}"), _at(51))
    except e:
        err = String(e)
    assert_equal(err, ERR_VERSION_CONFLICT)
    try:
        _ = store.update_deal[Rt](reactor, _alice(), NO_SUCH_ID, 1, _deal(base + "}"), _at(51))
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)
    try:
        _ = store.get_deal[Rt](reactor, NO_SUCH_ID)
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)
    try:
        _ = store.update_deal[Rt](
            reactor, Principal(issuer=String("i"), subject=String()), e2.id, e2.version, _deal(base + "}"), _at(51)
        )
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid actor: issuer and subject are both set or both empty")


def check_activities() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _default_pipeline(store, reactor).id
    var acct = store.create_account[Rt](reactor, _account('{"orgCardId":"o"}'), _at(1))
    var d = store.create_deal[Rt](
        reactor, _deal(String('{"title":"T","pipelineId":"') + pid + '","stageKey":"discovery"}'), _at(1)
    )
    var on_deal = String('{"subjectKind":"DEAL","subjectId":"') + d.id + String('"')
    var n1 = store.create_activity[Rt](reactor, _alice(), decode_json[Activity](on_deal + ',"body":"hi","actor":{"issuer":"x","subject":"y"},"system":true}'), _at(100))
    assert_equal(n1.actor.value().subject, "alice", "the actor is the caller, never the body")
    assert_false(n1.system, "a client never writes a system activity")
    assert_equal(n1.occurred_at.value().seconds, Int64(100), "occurred_at defaults to now")
    var dd = store.get_deal[Rt](reactor, d.id)
    assert_equal(dd.last_activity_at.value().seconds, Int64(100), "the deal's last activity moved")
    assert_equal(dd.modseq, n1.modseq + 1, "with a number of its own")
    assert_equal(dd.version, d.version, "not a client edit: the version stays")
    var older = store.create_activity[Rt](
        reactor, _alice(), decode_json[Activity](on_deal + ',"occurredAt":"1970-01-01T00:01:00Z"}'), _at(200)
    )
    var same = store.create_activity[Rt](
        reactor, _alice(), decode_json[Activity](on_deal + ',"occurredAt":"1970-01-01T00:01:40Z","kind":"CALL"}'), _at(300)
    )
    var dd2 = store.get_deal[Rt](reactor, d.id)
    assert_equal(dd2.last_activity_at.value().seconds, Int64(100), "older and equal activities leave it")
    assert_equal(dd2.modseq, dd.modseq, "and write nothing to the deal")
    var cols = List[String]()
    cols.append(String("id"))
    cols.append(String("modseq"))
    var counter = store.database().get_by_key[Rt](reactor, String(FEED), cols^, String("id"), DbValue.text(String("crm")))
    assert_equal(UInt64(counter.value().get_int8(1)), same.modseq, "nor take a number for it")
    var listed = store.list_activities[Rt](reactor, EntityKind.DEAL, d.id)
    assert_equal(len(listed), 3)
    var hi = same.id if same.id > n1.id else n1.id
    var lo = n1.id if same.id > n1.id else same.id
    assert_equal(listed[0].id, hi, "newest first; the higher id first in a tie")
    assert_equal(listed[1].id, lo)
    assert_equal(listed[2].id, older.id)
    var on_acct = store.create_activity[Rt](
        reactor, _alice(), decode_json[Activity]('{"subjectKind":"ACCOUNT","subjectId":"' + acct.id + '"}'), _at(5)
    )
    assert_equal(encode_json(store.get_activity[Rt](reactor, on_acct.id)), encode_json(on_acct))
    _ = store.create_activity[Rt](
        reactor, _alice(), decode_json[Activity]('{"subjectKind":"CARD","subjectId":"any-card"}'), _at(5)
    )
    assert_equal(len(store.list_activities[Rt](reactor, EntityKind.CARD, "any-card")), 1)
    var err = String(OK)
    try:
        _ = store.create_activity[Rt](reactor, _alice(), decode_json[Activity]('{"subjectKind":"DEAL","subjectId":"x"}'), _at(5))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid subjectId: no such deal")
    try:
        _ = store.create_activity[Rt](reactor, _alice(), decode_json[Activity]('{"subjectKind":"ACCOUNT","subjectId":"x"}'), _at(5))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid subjectId: no such account")
    try:
        _ = store.create_activity[Rt](
            reactor, Principal(issuer=String(), subject=String("s")), decode_json[Activity](on_deal + "}"), _at(5)
        )
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid actor: issuer and subject are both set or both empty")
    # update
    var u = store.update_activity[Rt](reactor, n1.id, n1.version, decode_json[Activity](on_deal + ',"body":"edited","kind":"MEETING"}'))
    assert_equal(u.body, "edited")
    assert_equal(u.kind.value, ActivityKind.MEETING)
    assert_equal(u.version, UInt64(2))
    assert_equal(u.occurred_at.value().seconds, Int64(100), "absent occurred_at keeps it")
    assert_equal(u.actor.value().subject, "alice")
    var u2 = store.update_activity[Rt](reactor, n1.id, u.version, decode_json[Activity](on_deal + ',"occurredAt":"1970-01-01T00:00:07Z"}'))
    assert_equal(u2.occurred_at.value().seconds, Int64(7))
    assert_equal(encode_json(store.get_activity[Rt](reactor, n1.id)), encode_json(u2))
    try:
        _ = store.update_activity[Rt](reactor, n1.id, u.version, decode_json[Activity](on_deal + "}"))
    except e:
        err = String(e)
    assert_equal(err, ERR_VERSION_CONFLICT)
    try:
        _ = store.update_activity[Rt](reactor, n1.id, u2.version, decode_json[Activity]('{"subjectKind":"DEAL","subjectId":"other"}'))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid subjectId: cannot change")
    try:
        _ = store.update_activity[Rt](reactor, n1.id, u2.version, decode_json[Activity]('{"subjectKind":"CARD","subjectId":"' + d.id + '"}'))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid subjectId: cannot change", "the kind is part of the subject")
    try:
        _ = store.get_activity[Rt](reactor, NO_SUCH_ID)
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)


def main() raises:
    check_init()
    check_accounts()
    check_custom_fields()
    check_links()
    check_pipelines()
    check_deals()
    check_activities()
    print("PASS komira_crm test_store_sqlite")
