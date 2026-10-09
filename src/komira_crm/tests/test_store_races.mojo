# =============================================================================
# test_store_races.mojo -- CrmStore when a peer writes, or a write fails,
#   between the store's steps.
# =============================================================================
#
# One store on one SQLite connection never interleaves, so `RacingDb` plays
# the peer: it delegates every call to a SqliteDatabase and, armed once,
# acts at one named point. Each check would fail on the defect its comment
# names; where the store's refusal comes after a write, the check reads the
# table through the database directly, because a read through the store
# would hide a row its key does not name.
#
#   stage_atomic   update_deal's stage change: the activity write fails after
#                  the deal was written. The error propagates; the deal keeps
#                  its stage and version, no activity exists and the counter
#                  did not move. Catches the deal and its activity in two
#                  transactions, and a failed write that commits.
#   key_lost       a peer creates an external id's (or a custom-field key's)
#                  key row just before the store's key create: the create is
#                  refused with the taken text and its row is gone from the
#                  table. Catches a lost key that commits (an orphan row).
#   cas_lost       a peer bumps a row's version between the store's read and
#                  its compare-and-set, for an account, a deal, an activity,
#                  a pipeline and a definition: refused with the conflict
#                  text, the counter did not move. Catches a CAS whose miss is
#                  ignored and a refused write that commits its number.
#   feed_cursor    a write commits after the feed read its rows and before it
#                  answered: the next call with the returned cursor returns
#                  it. Catches a cursor taken from the counter after the rows.
#   last_activity  a peer moves a deal's last_activity_at later between
#                  create_activity's read and its guarded write: the later
#                  time stays. Catches the write without its guard.
#   erase_moved    a row's owner changes between erasure's query and its
#                  rewrite: it is not counted. Catches counting rows queried
#                  instead of rows rewritten.
#   fails          a counter write that fails inside create_pipeline,
#                  init_dataset's pipeline write that fails, and a counter
#                  write that fails inside an erasure: each error propagates
#                  and nothing is left (init runs again afterwards).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_db import Database, DbColVal, DbRow, DbRows, DbValue, Filter, Order, PodNameMinter, Pred
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
    ERR_EXTERNAL_ID_TAKEN,
    ERR_FIELD_KEY_TAKEN,
    ERR_VERSION_CONFLICT,
    EXTERNAL_IDS,
    FEED,
    FIELD_DEFS,
    FIELD_KEYS,
    PIPELINES,
    sqlite_schema,
)
from komira_crm.rows import activity_row
from komira_crm.schema import activity_cols, strs

comptime Rt = BlockingRuntime[NoopSink]
comptime OK = "ok"

comptime NO_RACE = 0
comptime PEER_KEY = 1  # before a key create on `table`: the peer holds the key
comptime PEER_BUMP = 2  # before a version CAS on `table`: the peer bumps every version
comptime FAIL_PUT = 3  # a put on `table` fails
comptime FAIL_FEED = 4  # the next counter bump fails
comptime PEER_FEED_WRITE = 5  # after the feed's last table read: the peer writes an activity
comptime PEER_LAST_ACTIVITY = 6  # before the guarded last_activity_at write: the peer moves it later
comptime PEER_OWNER = 7  # after erasure's query of `table`: the peer changes every owner
comptime PUT_FAILED = "racing db: put failed"
comptime FEED_FAILED = "racing db: counter write failed"
comptime LATER_US = Int64(9_000_000_000_000_000)


struct RacingDb(Database, Movable, Deinitable):
    """SQLite, plus one armed peer action at one point (see the header)."""

    var inner: SqliteDatabase
    var race: Int
    var table: String

    def __init__(out self, var inner: SqliteDatabase):
        self.inner = inner^
        self.race = NO_RACE
        self.table = String()

    def arm(mut self, race: Int, table: StaticString):
        self.race = race
        self.table = String(table)

    def _fire(mut self, race: Int, table: String) -> Bool:
        if self.race == race and self.table == table:
            self.race = NO_RACE
            return True
        return False

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
        if self._fire(FAIL_PUT, table):
            raise Error(String(PUT_FAILED))
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
        if self._fire(PEER_FEED_WRITE, table):
            # A writer commits after the feed read its last table.
            _ = self.inner.conditional_update[RT](
                reactor,
                String(FEED),
                Filter.none(),
                List[DbColVal](),
                False,
                Optional[String](String("modseq")),
                List[String](),
            )
            var top = self.inner.get_by_key[RT](reactor, String(FEED), strs("id", "modseq"), String("id"), DbValue.text(String("crm")))
            var act = decode_json[Activity]('{"subjectKind":"CARD","subjectId":"c","occurredAt":"2026-10-01T00:00:00Z"}')
            act.id = String("peer-activity")
            act.version = 1
            act.modseq = UInt64(top.value().get_int8(1))
            _ = self.inner.put[RT](reactor, String(ACTIVITIES), activity_cols(), activity_row(act))
        if len(cols) == 1 and self._fire(PEER_OWNER, table):
            var moved = List[DbColVal]()
            moved.append(DbColVal.bind(String("owner_sub"), DbValue.text(String("someone-else"))))
            _ = self.inner.conditional_update[RT](
                reactor, table, Filter.none(), moved^, False, Optional[String](), List[String]()
            )
        return rows^

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
        if table == String(FEED) and self._fire(FAIL_FEED, String()):
            raise Error(String(FEED_FAILED))
        if bump_version_col and bump_version_col.value() == "version" and self._fire(PEER_BUMP, table):
            _ = self.inner.conditional_update[RT](
                reactor, table, Filter.none(), List[DbColVal](), False, Optional[String](String("version")), List[String]()
            )
        if not bump_version_col and self._fire(PEER_LAST_ACTIVITY, table):
            var later = List[DbColVal]()
            later.append(DbColVal.bind(String("last_activity_at"), DbValue.int8(LATER_US)))
            _ = self.inner.conditional_update[RT](
                reactor, table, Filter.none(), later^, False, Optional[String](), List[String]()
            )
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
        if self._fire(PEER_KEY, table):
            var peer = List[DbValue]()
            peer.append(vals[0].copy())
            peer.append(vals[1].copy())
            peer.append(DbValue.text(String("peer-row")))
            _ = self.inner.create_if_absent_composite[RT](reactor, table, conflict_cols, cols, peer^)
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


comptime Store = CrmStore[RacingDb]


def _raw() raises -> Store:
    var db = SqliteDatabase(String(":memory:"))
    var ddl = sqlite_schema()
    for i in range(len(ddl)):
        _ = db_blocking_execute(db, ddl[i], List[DbValue]())
    return Store(RacingDb(db^))


def _store(mut reactor: Reactor[Rt.Sink]) raises -> Store:
    var s = _raw()
    _ = s.init_dataset[Rt](reactor)
    return s^


def _at(seconds: Int64) -> Timestamp:
    return Timestamp(seconds, Int32(0))


def _alice() -> Principal:
    return Principal(issuer=String("i"), subject=String("alice"))


def _count(mut store: Store, mut reactor: Reactor[Rt.Sink], table: StaticString) raises -> Int:
    """Rows in `table`, read through the database (no key check)."""
    return store.database().query_rows[Rt](
        reactor, String(table), strs("id"), Filter.none(), List[Order](), Optional[UInt32]()
    ).__len__()


def _counter(mut store: Store, mut reactor: Reactor[Rt.Sink]) raises -> Int64:
    var got = store.database().get_by_key[Rt](reactor, String(FEED), strs("id", "modseq"), String("id"), DbValue.text(String("crm")))
    return got.value().get_int8(1)


def _pid(mut store: Store, mut reactor: Reactor[Rt.Sink]) raises -> String:
    return store.list_pipelines[Rt](reactor)[0].id


def _deal_json(pid: String, stage: StaticString, extra: StaticString) -> String:
    return String('{"title":"T","pipelineId":"') + pid + '","stageKey":"' + stage + '"' + extra + "}"


def check_stage_atomic() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _pid(store, reactor)
    var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", "")), _at(1))
    var before = _counter(store, reactor)
    store.database().arm(FAIL_PUT, ACTIVITIES)
    var err = String(OK)
    try:
        _ = store.update_deal[Rt](reactor, _alice(), d.id, d.version, decode_json[Deal](_deal_json(pid, "proposal", "")), _at(2))
    except e:
        err = String(e)
    assert_equal(err, PUT_FAILED, "the activity write failed after the deal's")
    assert_equal(store.database().race, NO_RACE, "the failing write ran")
    var now = store.get_deal[Rt](reactor, d.id)
    assert_equal(now.stage_key, "discovery", "the deal's write was rolled back with it")
    assert_equal(now.version, d.version)
    assert_equal(now.modseq, d.modseq)
    assert_equal(_count(store, reactor, ACTIVITIES), 0, "no activity")
    assert_equal(_counter(store, reactor), before, "no number taken")
    # and the same change succeeds afterwards
    _ = store.update_deal[Rt](reactor, _alice(), d.id, d.version, decode_json[Deal](_deal_json(pid, "proposal", "")), _at(3))
    assert_equal(_count(store, reactor, ACTIVITIES), 1)


def _create_err_account(mut store: Store, mut reactor: Reactor[Rt.Sink], ext: StaticString) -> String:
    try:
        _ = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o","externalId":"' + String(ext) + '"}'), _at(1))
        return String(OK)
    except e:
        return String(e)


def check_key_lost() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _pid(store, reactor)
    var before = _counter(store, reactor)
    store.database().arm(PEER_KEY, EXTERNAL_IDS)
    assert_equal(_create_err_account(store, reactor, "E"), ERR_EXTERNAL_ID_TAKEN, "the peer won the key")
    assert_equal(store.database().race, NO_RACE)
    assert_equal(_count(store, reactor, ACCOUNTS), 0, "the account row is gone, not left as an orphan")
    assert_equal(_counter(store, reactor), before)
    store.database().arm(PEER_KEY, EXTERNAL_IDS)
    var err = String(OK)
    try:
        _ = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", ',"externalId":"D"')), _at(1))
    except e:
        err = String(e)
    assert_equal(err, ERR_EXTERNAL_ID_TAKEN)
    assert_equal(_count(store, reactor, DEALS), 0, "the deal row is gone")
    store.database().arm(PEER_KEY, FIELD_KEYS)
    try:
        _ = store.create_field_def[Rt](reactor, decode_json[CustomFieldDef]('{"entityKind":"DEAL","key":"k","label":"K"}'))
    except e:
        err = String(e)
    assert_equal(err, ERR_FIELD_KEY_TAKEN)
    assert_equal(_count(store, reactor, FIELD_DEFS), 0, "the definition row is gone")
    assert_equal(_counter(store, reactor), before, "no number kept")


def check_cas_lost() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _pid(store, reactor)
    var a = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o"}'), _at(1))
    var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", "")), _at(1))
    var act = store.create_activity[Rt](
        reactor, _alice(), decode_json[Activity]('{"subjectKind":"CARD","subjectId":"c"}'), _at(1)
    )
    var f = store.create_field_def[Rt](reactor, decode_json[CustomFieldDef]('{"entityKind":"DEAL","key":"k","label":"K"}'))
    var p = store.list_pipelines[Rt](reactor)[0].copy()
    var before = _counter(store, reactor)
    var errs = String()
    store.database().arm(PEER_BUMP, ACCOUNTS)
    try:
        _ = store.update_account[Rt](reactor, a.id, a.version, decode_json[Account]('{"orgCardId":"o2"}'), _at(2))
    except e:
        errs += String(e) + "|"
    store.database().arm(PEER_BUMP, DEALS)
    try:
        _ = store.update_deal[Rt](reactor, _alice(), d.id, d.version, decode_json[Deal](_deal_json(pid, "proposal", "")), _at(2))
    except e:
        errs += String(e) + "|"
    store.database().arm(PEER_BUMP, ACTIVITIES)
    try:
        _ = store.update_activity[Rt](reactor, act.id, act.version, decode_json[Activity]('{"subjectKind":"CARD","subjectId":"c","body":"b"}'))
    except e:
        errs += String(e) + "|"
    store.database().arm(PEER_BUMP, FIELD_DEFS)
    try:
        _ = store.update_field_def[Rt](reactor, f.id, f.version, decode_json[CustomFieldDef]('{"entityKind":"DEAL","key":"k","label":"L"}'))
    except e:
        errs += String(e) + "|"
    store.database().arm(PEER_BUMP, PIPELINES)
    try:
        _ = store.update_pipeline[Rt](reactor, p.id, p.version, p)
    except e:
        errs += String(e) + "|"
    var want = String()
    for _ in range(5):
        want += String(ERR_VERSION_CONFLICT) + "|"
    assert_equal(errs, want, "every compare-and-set lost to the peer")
    assert_equal(store.database().race, NO_RACE)
    assert_equal(_counter(store, reactor), before, "no refused write kept its number")
    assert_equal(store.get_deal[Rt](reactor, d.id).stage_key, "discovery")
    assert_equal(_count(store, reactor, ACTIVITIES), 1, "the lost stage change wrote no activity")


def check_feed_cursor() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    _ = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o"}'), _at(1))
    store.database().arm(PEER_FEED_WRITE, FIELD_DEFS)
    var first = store.changes[Rt](reactor, 0, 1000)
    assert_equal(store.database().race, NO_RACE, "the peer wrote during the read")
    assert_equal(len(first.changes), 2, "the peer's write is not in this page")
    assert_equal(first.modseq, UInt64(2), "the cursor is the last row returned")
    var next = store.changes[Rt](reactor, first.modseq, 1000)
    assert_equal(len(next.changes), 1, "the next call returns the peer's write")
    assert_equal(next.changes[0].id, "peer-activity")
    assert_equal(next.modseq, UInt64(3))


def check_last_activity() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    var pid = _pid(store, reactor)
    var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", "")), _at(1))
    store.database().arm(PEER_LAST_ACTIVITY, DEALS)
    _ = store.create_activity[Rt](
        reactor, _alice(), decode_json[Activity]('{"subjectKind":"DEAL","subjectId":"' + d.id + '"}'), _at(100)
    )
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    var got = store.get_deal[Rt](reactor, d.id).last_activity_at.value()
    assert_equal(got.seconds, LATER_US // 1_000_000, "the peer's later time stays")


def check_erase_moved() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _store(reactor)
    _ = store.create_account[Rt](
        reactor, decode_json[Account]('{"orgCardId":"o","owner":{"issuer":"i","subject":"alice"}}'), _at(1)
    )
    store.database().arm(PEER_OWNER, ACCOUNTS)
    var counts = store.erase_subject[Rt](reactor, "i", "alice")
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    assert_equal(counts.accounts, UInt32(0), "the row no longer named the principal")
    var a = store.list_accounts[Rt](reactor, True)[0].copy()
    assert_equal(a.owner.value().subject, "someone-else", "and was left alone")


def check_fails() raises:
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = _raw()
    store.database().arm(FAIL_PUT, PIPELINES)
    var err = String(OK)
    try:
        _ = store.init_dataset[Rt](reactor)
    except e:
        err = String(e)
    assert_equal(err, PUT_FAILED, "the default pipeline's write failed")
    assert_equal(_count(store, reactor, FEED), 0, "the counter row was rolled back with it")
    assert_true(store.init_dataset[Rt](reactor), "so the next init creates the dataset")
    store.database().arm(FAIL_FEED, "")
    try:
        _ = store.create_pipeline[Rt](reactor, decode_json[Pipeline]('{"name":"P","stages":[{"key":"a","label":"A"}]}'))
    except e:
        err = String(e)
    assert_equal(err, FEED_FAILED)
    assert_equal(len(store.list_pipelines[Rt](reactor)), 1, "no pipeline written")
    _ = store.create_account[Rt](
        reactor, decode_json[Account]('{"orgCardId":"o","owner":{"issuer":"i","subject":"alice"}}'), _at(1)
    )
    store.database().arm(FAIL_FEED, "")
    try:
        _ = store.erase_subject[Rt](reactor, "i", "alice")
    except e:
        err = String(e)
    assert_equal(err, FEED_FAILED)
    assert_equal(store.list_accounts[Rt](reactor, True)[0].owner.value().subject, "alice", "nothing rewritten")
    assert_equal(encode_json(store.erase_subject[Rt](reactor, "i", "alice")), '{"accounts":1}', "the next call does it")


def main() raises:
    check_stage_atomic()
    check_key_lost()
    check_cas_lost()
    check_feed_cursor()
    check_last_activity()
    check_erase_moved()
    check_fails()
    print("PASS komira_crm test_store_races")
