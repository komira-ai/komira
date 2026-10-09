# =============================================================================
# test_write_order_firestore.mojo -- one live account per external id, and no
#   acknowledged create lost, with a writer paused or killed between its row
#   and its key, on FirestoreDatabase over MockFirestore.
# =============================================================================
#
# Firestore is the one backend where a create's row and its key row commit
# apart. `PausingDb` wraps the database and acts right after writer A's
# first write, the `put` of its account row:
#
#   paused  writer B creates an account with the same external id, row and
#           key, and is acknowledged; then A resumes. A's key create loses,
#           so A is refused with the taken text, and its rollback deletes its
#           row: the table holds B's row only, and B is the one account
#           listed. Catches a lost key that does not roll back, and a key
#           taken over by a writer that finds its target absent.
#   killed  A dies right after its row (no key, no rollback, as a killed
#           process leaves it); then B creates the same external id through
#           the store and is acknowledged. The table holds both rows; no get
#           or list returns A's, and B is the one account listed. Catches a
#           read that skips the key check.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_db import Database, DbColVal, DbRow, DbRows, DbValue, Filter, Order, PodNameMinter
from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore_db import DeclaredIndexSet, FirestoreDatabase, MockFirestore, MockFirestoreConnector
from komira_proto_codec import decode_json
from komira_wkt import Timestamp
from komira_crm_proto.crm import Account

from komira_crm import ACCOUNTS, CrmStore, ERR_EXTERNAL_ID_TAKEN, ERR_NOT_FOUND, EXTERNAL_IDS
from komira_crm.rows import account_row
from komira_crm.schema import account_cols, external_id_cols, strs

from komira_crm_store_conformance import Rt, new_rt

comptime _FsDb = FirestoreDatabase[MockFirestoreConnector]
comptime NONE = 0
comptime PAUSE = 1
comptime KILL = 2
comptime KILLED = "pausing db: the writer was killed"


struct PausingDb[D: Database](Database, Movable, Deinitable):
    """`D`, plus one armed action right after the next `put` on the
    accounts table (see the header). `peer` is writer B: a second database
    over the same data, outside A's transaction."""

    var inner: Self.D
    var peer: Self.D
    var mode: Int
    var dead: Bool

    def __init__(out self, var inner: Self.D, var peer: Self.D):
        self.inner = inner^
        self.peer = peer^
        self.mode = NONE
        self.dead = False

    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.begin[RT](reactor)

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.commit[RT](reactor)

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        if self.dead:
            # A killed process rolls nothing back; its next request is a new
            # process with a new transaction.
            self.dead = False
            self.inner.commit[RT](reactor)
            return
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
        var n = self.inner.put[RT](reactor, table, cols, vals)
        if table == String(ACCOUNTS) and self.mode == PAUSE:
            self.mode = NONE
            # Writer B, while A is paused: its row, then its key.
            var b = decode_json[Account]('{"orgCardId":"o","externalId":"E"}')
            b.id = String("writer-b")
            b.version = 1
            _ = self.peer.put[RT](reactor, String(ACCOUNTS), account_cols(), account_row(b))
            var key = List[DbValue]()
            key.append(DbValue.text(String("ACCOUNT")))
            key.append(DbValue.text(String("E")))
            key.append(DbValue.text(String("writer-b")))
            _ = self.peer.create_if_absent_composite[RT](
                reactor, String(EXTERNAL_IDS), strs("entity_kind", "external_id"), external_id_cols(), key^
            )
        elif table == String(ACCOUNTS) and self.mode == KILL:
            self.mode = NONE
            self.dead = True
            raise Error(String(KILLED))
        return n

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
        return self.inner.query_rows[RT](reactor, table, cols, filter, order, limit)

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


comptime Store = CrmStore[PausingDb[_FsDb]]


def _store(mut reactor: Reactor[Rt.Sink]) raises -> Store:
    var transport = MockFirestore()
    var a = FirestoreClient[MockFirestoreConnector](
        transport.connector(), String("crm-project"), String("(default)"), String("crm-bearer")
    )
    var b = FirestoreClient[MockFirestoreConnector](
        transport.connector(), String("crm-project"), String("(default)"), String("crm-bearer")
    )
    var s = Store(PausingDb[_FsDb](_FsDb(a^, DeclaredIndexSet()), _FsDb(b^, DeclaredIndexSet())))
    _ = s.init_dataset[Rt](reactor)
    return s^


def _raw_ids(mut store: Store, mut reactor: Reactor[Rt.Sink]) raises -> List[String]:
    """The ids in the accounts table, read through the database."""
    var rows = store.database().query_rows[Rt](
        reactor, String(ACCOUNTS), strs("id"), Filter.none(), List[Order](), Optional[UInt32]()
    )
    var out = List[String]()
    for i in range(rows.__len__()):
        out.append(rows.row(i).get_text(0))
    return out^


def _create_e(mut store: Store, mut reactor: Reactor[Rt.Sink]) -> String:
    try:
        return store.create_account[Rt](
            reactor, decode_json[Account]('{"orgCardId":"o","externalId":"E"}'), Timestamp(Int64(1), Int32(0))
        ).id
    except e:
        return String(e)


def check_paused() raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(reactor)
    store.database().mode = PAUSE
    assert_equal(_create_e(store, reactor), ERR_EXTERNAL_ID_TAKEN, "A loses the key B took while A was paused")
    assert_equal(store.database().mode, NONE, "B wrote")
    var raw = _raw_ids(store, reactor)
    assert_equal(len(raw), 1, "A's rollback deleted its row")
    assert_equal(raw[0], "writer-b")
    var listed = store.list_accounts[Rt](reactor, True)
    assert_equal(len(listed), 1)
    assert_equal(listed[0].id, "writer-b", "the acknowledged create is the one read")
    assert_equal(store.get_account[Rt](reactor, "writer-b").external_id, "E")


def check_killed() raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(reactor)
    store.database().mode = KILL
    assert_equal(_create_e(store, reactor), KILLED, "A died after its row")
    var b = _create_e(store, reactor)
    assert_true(b != KILLED and b != ERR_EXTERNAL_ID_TAKEN, "B is acknowledged")
    var raw = _raw_ids(store, reactor)
    assert_equal(len(raw), 2, "A's row is still in the table")
    var listed = store.list_accounts[Rt](reactor, True)
    assert_equal(len(listed), 1, "no read returns A's row")
    assert_equal(listed[0].id, b)
    var orphan = raw[0] if raw[0] != b else raw[1]
    var err = String()
    try:
        _ = store.get_account[Rt](reactor, orphan)
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND)


def main() raises:
    check_paused()
    check_killed()
    print("PASS komira_crm_store_conformance write order on komira_gcp_firestore_db")
