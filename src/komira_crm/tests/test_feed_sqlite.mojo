# =============================================================================
# test_feed_sqlite.mojo -- the change feed, orphan rows and erasure, on
#   komira_db_sqlite.
# =============================================================================
#
#   feed_order    every write in the dataset in one numbered sequence, each
#                 row once at its latest write; a stage change's deal and
#                 activity on consecutive numbers; walking with a page of 1
#                 gives the same sequence, each cursor the last number
#                 returned, and a page can end between a deal and its
#                 activity. Catches one number per transaction, a cursor
#                 taken from the counter, and a page that drops a table.
#   feed_limits   a cursor at or past the counter returns nothing and keeps
#                 the cursor; a page of 0 or 1001 is refused, 1000 is not.
#   orphans       rows a key does not name (a create that stopped between
#                 its row and its key: an account and a deal with an
#                 external id, a custom-field definition, planted through
#                 the database) are returned by no get, list or feed read,
#                 and the feed still pages past them (three orphans ahead
#                 of a live row with a page of 1). Catches a read without
#                 the key check and a page cut short by skipped rows.
#   erasure       two principals with the same subject at two issuers own
#                 accounts and deals and wrote activities; erasing one
#                 rewrites exactly its rows (owner emptied, actor "erased",
#                 version bumped, a new feed number each, no copy left in
#                 a body) and nothing of the other's; a second call rewrites
#                 nothing. Catches matching the subject without the issuer,
#                 a skipped table, and an erasure that leaves the owner in
#                 the body or is not in the feed.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import DbColVal, DbValue, Filter, Order, Pred
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase
from komira_proto_codec import decode_json, encode_json
from komira_wkt import Timestamp
from komira_crm_proto.crm import Account, Activity, CustomFieldDef, Deal, EntityKind, Pipeline, Principal

from komira_crm import (
    ACCOUNTS,
    ACTIVITIES,
    CrmStore,
    DEALS,
    ERR_NOT_FOUND,
    FIELD_DEFS,
    FEED,
    FIELD_KEYS,
    sqlite_schema,
)
from komira_crm.rows import account_row, deal_row, field_def_row
from komira_crm.schema import account_cols, deal_cols, field_def_cols

comptime Rt = BlockingRuntime[NoopSink]
comptime Store = CrmStore[SqliteDatabase]
comptime OK = "ok"


def _store(mut reactor: Reactor[Rt.Sink]) raises -> Store:
    var db = SqliteDatabase(String(":memory:"))
    var ddl = sqlite_schema()
    for i in range(len(ddl)):
        _ = db_blocking_execute(db, ddl[i], List[DbValue]())
    var s = Store(db^)
    _ = s.init_dataset[Rt](reactor)
    return s^


def _at(seconds: Int64) -> Timestamp:
    return Timestamp(seconds, Int32(0))


def _who(issuer: StaticString, subject: StaticString) -> Principal:
    return Principal(issuer=String(issuer), subject=String(subject))


def _feed(mut store: Store, mut reactor: Reactor[Rt.Sink], since: UInt64, limit: Int) raises -> String:
    """`KIND@n` per entry, space separated, then `|cursor`."""
    var r = store.changes[Rt](reactor, since, limit)
    var out = String()
    for e in r.changes:
        out += e.kind.json_name() + String("@") + String(e.modseq) + String(" ")
    return out + String("|") + String(r.modseq)


def _walk(mut store: Store, mut reactor: Reactor[Rt.Sink]) raises -> String:
    """The feed read one row at a time from 0 until a page is empty."""
    var out = String()
    var since = UInt64(0)
    while True:
        var r = store.changes[Rt](reactor, since, 1)
        if len(r.changes) == 0:
            assert_equal(r.modseq, since, "an empty page keeps the cursor")
            return out^
        assert_equal(len(r.changes), 1)
        assert_equal(r.modseq, r.changes[0].modseq, "the cursor is the last number returned")
        out += r.changes[0].kind.json_name() + String("@") + String(r.modseq) + String(" ")
        since = r.modseq


def _pid(mut store: Store, mut reactor: Reactor[Rt.Sink]) raises -> String:
    return store.list_pipelines[Rt](reactor)[0].id


def check_feed_order() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _pid(store, reactor)
    var a = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o"}'), _at(1))
    var d = store.create_deal[Rt](
        reactor, decode_json[Deal]('{"title":"T","pipelineId":"' + pid + '","stageKey":"discovery"}'), _at(1)
    )
    _ = store.update_deal[Rt](
        reactor, _who("i", "s"), d.id, d.version, decode_json[Deal]('{"title":"T","pipelineId":"' + pid + '","stageKey":"proposal"}'), _at(2)
    )
    _ = store.create_field_def[Rt](reactor, decode_json[CustomFieldDef]('{"entityKind":"DEAL","key":"k","label":"K"}'))
    _ = store.create_pipeline[Rt](reactor, decode_json[Pipeline]('{"name":"P","stages":[{"key":"a","label":"A"}]}'))
    _ = store.update_account[Rt](reactor, a.id, a.version, decode_json[Account]('{"orgCardId":"o2"}'), _at(3))
    comptime FULL = "PIPELINE@1 DEAL@4 ACTIVITY@5 CUSTOM_FIELD_DEF@6 PIPELINE@7 ACCOUNT@8 "
    assert_equal(_feed(store, reactor, 0, 1000), String(FULL) + "|8", "one sequence, each row at its latest write")
    assert_equal(_walk(store, reactor), FULL, "a page of one walks the same sequence")
    assert_equal(_feed(store, reactor, 3, 1), "DEAL@4 |4", "a page can end after the deal")
    assert_equal(_feed(store, reactor, 4, 1), "ACTIVITY@5 |5", "and the next starts at its activity")
    assert_equal(_feed(store, reactor, 4, 3), "ACTIVITY@5 CUSTOM_FIELD_DEF@6 PIPELINE@7 |7", "the lowest numbers first")


def check_feed_limits() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    assert_equal(_feed(store, reactor, 1, 10), "|1", "at the counter: nothing")
    assert_equal(_feed(store, reactor, 0, 1000), "PIPELINE@1 |1")
    assert_equal(_feed(store, reactor, 50, 10), "|50", "past the counter: the cursor is kept")
    var err = String(OK)
    try:
        _ = store.changes[Rt](reactor, 0, 0)
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid limit: must be 1 to 1000")
    err = String(OK)
    try:
        _ = store.changes[Rt](reactor, 0, 1001)
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid limit: must be 1 to 1000")


def _plant(mut store: Store, mut reactor: Reactor[Rt.Sink], table: StaticString, cols: List[String], vals: List[DbValue]) raises:
    _ = store.database().put[Rt](reactor, String(table), cols, vals)


def check_orphans() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _pid(store, reactor)
    # Orphans ahead of the live rows, rows a create wrote before its key:
    # three accounts (numbers 2, 3 and 4), a deal (2) and two definitions
    # (3 and 4), at numbers the counter has passed (taken directly: no live
    # row holds them).
    for n in range(3):
        _ = store.database().conditional_update[Rt](
            reactor,
            String(FEED),
            Filter.just(Pred.eq(String("id"), DbValue.text(String("crm")))),
            List[DbColVal](),
            False,
            Optional[String](String("modseq")),
            List[String](),
        )
        var ghost = decode_json[Account]('{"orgCardId":"o","externalId":"GHOST' + String(n) + '"}')
        ghost.id = String("ghost-account-") + String(n)
        ghost.version = 1
        ghost.modseq = UInt64(2 + n)
        _plant(store, reactor, ACCOUNTS, account_cols(), account_row(ghost))
    var gd = decode_json[Deal]('{"title":"T","pipelineId":"' + pid + '","stageKey":"discovery","externalId":"GD"}')
    gd.id = String("ghost-deal")
    gd.version = 1
    gd.modseq = 2
    _plant(store, reactor, DEALS, deal_cols(), deal_row(gd))
    var gf = decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"ghost","label":"G"}')
    gf.id = String("ghost-field")
    gf.version = 1
    gf.modseq = 3
    _plant(store, reactor, FIELD_DEFS, field_def_cols(), field_def_row(gf))
    # a definition whose key names another definition
    var real = store.create_field_def[Rt](reactor, decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"real","label":"R"}'))
    var dup = real.copy()
    dup.id = String("ghost-dup")
    dup.modseq = 4
    _plant(store, reactor, FIELD_DEFS, field_def_cols(), field_def_row(dup))
    var live = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o","externalId":"LIVE"}'), _at(1))
    # reads by id
    for id in ["ghost-account-0", "ghost-account-2"]:
        var err = String(OK)
        try:
            _ = store.get_account[Rt](reactor, String(id))
        except e:
            err = String(e)
        assert_equal(err, ERR_NOT_FOUND, id)
    var err = String(OK)
    try:
        _ = store.get_deal[Rt](reactor, "ghost-deal")
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)
    err = String(OK)
    try:
        _ = store.get_field_def[Rt](reactor, "ghost-dup")
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND, "a key naming another row")
    # lists
    var accts = store.list_accounts[Rt](reactor, True)
    assert_equal(len(accts), 1)
    assert_equal(accts[0].id, live.id)
    assert_equal(len(store.list_deals[Rt](reactor, String(), True)), 0)
    var defs = store.list_field_defs[Rt](reactor, EntityKind.ACCOUNT)
    assert_equal(len(defs), 1)
    assert_equal(defs[0].id, real.id)
    # the feed: the orphans' numbers are passed over
    comptime FULL = "PIPELINE@1 CUSTOM_FIELD_DEF@5 ACCOUNT@6 "
    assert_equal(_feed(store, reactor, 0, 1000), String(FULL) + "|6")
    assert_equal(_walk(store, reactor), FULL, "a page of one pages past three orphans")
    assert_equal(_feed(store, reactor, 4, 2), "CUSTOM_FIELD_DEF@5 ACCOUNT@6 |6")
    assert_equal(_feed(store, reactor, 1, 1), "CUSTOM_FIELD_DEF@5 |5", "a page of one reads past the orphans of every table")
    # the next create of an orphan's external id wins the key
    var again = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o","externalId":"GHOST1"}'), _at(2))
    assert_equal(store.get_account[Rt](reactor, again.id).external_id, "GHOST1")


def _owned(json_tail: String, iss: StaticString, sub: StaticString) -> String:
    return String('{"owner":{"issuer":"') + iss + '","subject":"' + sub + '"}' + json_tail + "}"


def check_erasure() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _pid(store, reactor)
    var deal_tail = String(',"title":"T","pipelineId":"') + pid + '","stageKey":"discovery"'
    var a_acct = store.create_account[Rt](reactor, decode_json[Account](_owned(',"orgCardId":"o"', "https://one.example", "u")), _at(1))
    var b_acct = store.create_account[Rt](reactor, decode_json[Account](_owned(',"orgCardId":"o"', "https://two.example", "u")), _at(1))
    var a_deal = store.create_deal[Rt](reactor, decode_json[Deal](_owned(deal_tail, "https://one.example", "u")), _at(1))
    var b_deal = store.create_deal[Rt](reactor, decode_json[Deal](_owned(deal_tail, "https://two.example", "u")), _at(1))
    var on_deal = String('{"subjectKind":"DEAL","subjectId":"') + b_deal.id + '","body":"note"}'
    var a1 = store.create_activity[Rt](reactor, _who("https://one.example", "u"), decode_json[Activity](on_deal), _at(2))
    var a2 = store.create_activity[Rt](reactor, _who("https://one.example", "u"), decode_json[Activity](on_deal), _at(3))
    var b1 = store.create_activity[Rt](reactor, _who("https://two.example", "u"), decode_json[Activity](on_deal), _at(4))
    var before = store.changes[Rt](reactor, 0, 1000).modseq
    var b_before = encode_json(store.get_account[Rt](reactor, b_acct.id))
    var bd_before = encode_json(store.get_deal[Rt](reactor, b_deal.id))
    var b1_before = encode_json(store.get_activity[Rt](reactor, b1.id))
    var counts = store.erase_subject[Rt](reactor, "https://one.example", "u")
    assert_equal(encode_json(counts), '{"accounts":1,"deals":1,"activities":2}')
    # the erased principal's rows
    var ea = store.get_account[Rt](reactor, a_acct.id)
    assert_false(Bool(ea.owner), "the account is unowned")
    assert_equal(ea.version, a_acct.version + 1, "a rewrite bumps the version")
    var ed = store.get_deal[Rt](reactor, a_deal.id)
    assert_false(Bool(ed.owner), "the deal is unowned")
    assert_equal(ed.version, a_deal.version + 1)
    for id in [a1.id, a2.id]:
        var act = store.get_activity[Rt](reactor, id)
        assert_equal(act.actor.value().issuer, "")
        assert_equal(act.actor.value().subject, "erased")
        assert_equal(act.version, UInt64(2))
    # the other principal's rows are untouched
    assert_equal(encode_json(store.get_account[Rt](reactor, b_acct.id)), b_before, "same subject, other issuer")
    assert_equal(encode_json(store.get_deal[Rt](reactor, b_deal.id)), bd_before)
    assert_equal(encode_json(store.get_activity[Rt](reactor, b1.id)), b1_before)
    # each rewrite is in the feed with a number of its own
    var after = store.changes[Rt](reactor, before, 1000)
    assert_equal(len(after.changes), 4)
    assert_equal(after.changes[0].kind.value, EntityKind.ACCOUNT)
    assert_equal(after.changes[0].id, a_acct.id)
    assert_equal(after.changes[1].kind.value, EntityKind.DEAL)
    assert_equal(after.changes[2].kind.value, EntityKind.ACTIVITY)
    assert_equal(after.changes[3].kind.value, EntityKind.ACTIVITY)
    assert_equal(after.changes[3].modseq, before + 4, "one number per row")
    # no copy of the principal is left in any row of the three tables
    for t in [ACCOUNTS, DEALS, ACTIVITIES]:
        var cols = List[String]()
        cols.append(String("body"))
        var rows = store.database().query_rows[Rt](reactor, String(t), cols^, Filter.none(), List[Order](), Optional[UInt32]())
        for i in range(rows.__len__()):
            assert_false("https://one.example" in rows.row(i).get_text(0), String(t))
            assert_false("https://two.example" in rows.row(i).get_text(0), "nor of anyone: the owner is never in the body")
    # a second call rewrites nothing
    assert_equal(encode_json(store.erase_subject[Rt](reactor, "https://one.example", "u")), "{}")
    assert_equal(store.changes[Rt](reactor, 0, 1000).modseq, after.modseq, "and takes no number")
    var err = String(OK)
    try:
        _ = store.erase_subject[Rt](reactor, "", "u")
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid subject: issuer and subject are both required")
    err = String(OK)
    try:
        _ = store.erase_subject[Rt](reactor, "https://one.example", "")
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid subject: issuer and subject are both required")


def main() raises:
    check_feed_order()
    check_feed_limits()
    check_orphans()
    check_erasure()
    print("PASS komira_crm test_feed_sqlite")
