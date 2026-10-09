# =============================================================================
# test_firestore_db_query.mojo — query_rows' client-side IN and LIMIT,
#   delete_where's client-side IN, and the conditional_update arms that
#   answer 0 rows.
# =============================================================================
#
# Runs on the in-process `MockFirestore`. query_rows re-applies a LIMIT
# client-side; that check only acts when the backend returns MORE than the
# query asked for, which the mock never does. `_Lax` is a test exchange that
# forwards to the mock with the query's `where` and `limit` removed, standing
# in for a backend that answers an over-long result.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import (
    DbValue,
    DbColVal,
    DbRows,
    Pred,
    Filter,
    Order,
)

from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore.firestore_fake import (
    ExchangeAnswer,
    ExchangeConnector,
    HttpExchange,
)
from komira_gcp_firestore_v1.firestore import RunQueryRequest
from komira_proto_codec.codec import decode_json, encode_json

from komira_gcp_firestore_db import (
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]
comptime _LaxT = ExchangeConnector[_Lax]
comptime _LaxDb = FirestoreDatabase[_LaxT]

comptime _TABLE: String = "job"
comptime _STALE: String = (
    '{"error":{"code":400,"status":"FAILED_PRECONDITION","message":"stale"}}'
)


struct _Lax(HttpExchange, Movable, Deinitable):
    """The mock, answering every RunQuery as if it had no `where` and no
    `limit`: the whole collection (still ordered)."""

    var inner: MockFirestore

    def __init__(out self, var inner: MockFirestore):
        self.inner = inner^

    def answer(
        mut self, method: String, target: String, body: String
    ) raises -> ExchangeAnswer:
        if target.endswith(":runQuery"):
            var req = decode_json[RunQueryRequest](body)
            var q = req.structured_query.value().copy()
            q.where = None
            q.limit = None
            req.structured_query = q^
            return self.inner.answer(method, target, encode_json(req))
        return self.inner.answer(method, target, body)


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _fs_db(mock: MockFirestore) -> _FsDb:
    var client = FirestoreClient[_MockT](
        mock.connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    return _FsDb(client^)


def _lax_db(mock: MockFirestore) -> _LaxDb:
    var conn = _LaxT(ArcPointer[_Lax](_Lax(mock.share())))
    var client = FirestoreClient[_LaxT](
        conn^,
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    return _LaxDb(client^)


def _cols() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("phase"))
    out.append(String("created_at"))
    out.append(String("version"))
    return out^


def _row(id: String, phase: String, created: Int64) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(id))
    out.append(DbValue.text(phase))
    out.append(DbValue.int8(created))
    out.append(DbValue.int8(Int64(1)))
    return out^


def _seed(mut db: _FsDb, mut reactor: Reactor[NoopSink]) raises:
    """Three PENDING jobs whose creation order differs from their id order,
    and one RUNNING job created first."""
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("job-c", "PENDING", 30))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("job-a", "PENDING", 10))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("job-b", "PENDING", 20))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("job-r", "RUNNING", 5))


def _ids(rows: DbRows) raises -> String:
    var out = String("")
    var c = rows.column_index("id")
    for i in range(rows.__len__()):
        if i > 0:
            out += ","
        out += rows.row(i).get_text(c)
    return out^


def _phase_of(mut db: _FsDb, mut reactor: Reactor[NoopSink], id: String) raises -> String:
    var got = db.get_by_key[_Rt](reactor, _TABLE, _cols(), String("id"), DbValue.text(id))
    var row = got.take()
    return row.get_text(row.column_index("phase"))


# =============================================================================
# 1. query_rows: IN predicates are evaluated client-side; a LIMIT is re-applied
#    client-side; query_rows_locked is query_rows with no limit.
# =============================================================================
def test_query_rows_in_and_limit() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _seed(db, reactor)
    # A row whose phase field is NULL never matches an IN.
    var nul = List[DbValue]()
    nul.append(DbValue.text("job-n"))
    nul.append(DbValue.null(0))
    nul.append(DbValue.int8(Int64(1)))
    nul.append(DbValue.int8(Int64(1)))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), nul^)

    var vals = List[DbValue]()
    vals.append(DbValue.text("RUNNING"))
    vals.append(DbValue.text("DONE"))
    var by_in = db.query_rows[_Rt](
        reactor, _TABLE, _cols(), Filter.just(Pred.in_list(String("phase"), vals.copy())),
        List[Order](), Optional[UInt32](),
    )
    assert_equal(_ids(by_in), String("job-r"), "only the row whose phase is IN the list")

    # IN alongside a pushed predicate, and two IN predicates: both must hold.
    var preds = List[Pred]()
    preds.append(Pred.lt(String("created_at"), DbValue.int8(Int64(25))))
    var pending = List[DbValue]()
    pending.append(DbValue.text("PENDING"))
    preds.append(Pred.in_list(String("phase"), pending^))
    var ids = List[DbValue]()
    ids.append(DbValue.text("job-a"))
    ids.append(DbValue.text("job-c"))
    preds.append(Pred.in_list(String("id"), ids^))
    var both = db.query_rows[_Rt](
        reactor, _TABLE, _cols(), Filter.all_of(preds^), List[Order](),
        Optional[UInt32](),
    )
    assert_equal(_ids(both), String("job-a"), "every IN holds, and the pushed LT")

    var locked = db.query_rows_locked[_Rt](
        reactor, _TABLE, _cols(), Filter.just(Pred.in_list(String("phase"), vals^)),
        List[Order](),
    )
    assert_equal(_ids(locked), String("job-r"), "query_rows_locked reads the same rows")

    # The lax backend ignores the limit; the driver still returns at most 2.
    var lax = _lax_db(mock)
    var capped = lax.query_rows[_Rt](
        reactor, _TABLE, _cols(), Filter(), List[Order](), Optional[UInt32](UInt32(2)),
    )
    assert_equal(capped.__len__(), 2, "LIMIT is re-applied client-side")
    _ = lax^
    _ = db^
    print("    [PASS] query_rows evaluates IN and LIMIT client-side")


# =============================================================================
# 2. delete_where deletes only the rows whose field is IN the list.
# =============================================================================
def test_delete_where_in() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _seed(db, reactor)
    var ids = List[DbValue]()
    ids.append(DbValue.text("job-a"))
    ids.append(DbValue.text("job-r"))
    ids.append(DbValue.text("job-x"))
    var n = db.delete_where[_Rt](
        reactor, _TABLE, Filter.just(Pred.in_list(String("id"), ids^))
    )
    assert_equal(n, UInt64(2), "the two existing members are deleted")
    var left = db.query_rows[_Rt](
        reactor, _TABLE, _cols(), Filter(), List[Order](), Optional[UInt32](),
    )
    # Only the set is pinned: with no orderBy the service answers in document
    # name order and the mock in insertion order, and this test is not about
    # either.
    var kept = _ids(left)
    assert_true(
        kept == String("job-b,job-c") or kept == String("job-c,job-b"),
        String("the non-members are kept: ") + kept,
    )
    _ = db^
    print("    [PASS] delete_where evaluates IN client-side")


# =============================================================================
# 3. conditional_update answers 0 rows for: a key guard on an absent document;
#    a candidate that passes the pushed equality but fails the rest; a lost
#    CAS. And a guard on `key` addresses the document named by that key.
#    (A guard with no equality at all is not tested here: it updates nothing,
#    which komira-ai/komira#678 reports as a divergence from the trait.)
# =============================================================================
def test_conditional_update_zero_row_arms() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _seed(db, reactor)
    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("phase"), DbValue.text("DONE")))

    assert_equal(
        db.conditional_update[_Rt](
            reactor, _TABLE, Filter.just(Pred.eq(String("id"), DbValue.text("job-zz"))),
            updates, False, Optional[String](), List[String](),
        ),
        UInt64(0),
        "a key guard on an absent document updates nothing",
    )

    # phase == PENDING is pushed (three candidates); created_at < 15 holds for
    # job-a only.
    var g = List[Pred]()
    g.append(Pred.eq(String("phase"), DbValue.text("PENDING")))
    g.append(Pred.lt(String("created_at"), DbValue.int8(Int64(15))))
    assert_equal(
        db.conditional_update[_Rt](
            reactor, _TABLE, Filter.all_of(g^), updates, False,
            Optional[String](), List[String](),
        ),
        UInt64(1),
        "only the candidate satisfying the whole guard is written",
    )
    assert_equal(_phase_of(db, reactor, "job-a"), String("DONE"))
    assert_equal(_phase_of(db, reactor, "job-b"), String("PENDING"))

    # A lost CAS on the multi-row arm and on the key arm: 0, nothing written.
    var fault = mock.share()
    fault.fail_next_commit(400, String(_STALE))
    assert_equal(
        db.conditional_update[_Rt](
            reactor, _TABLE, Filter.just(Pred.eq(String("phase"), DbValue.text("RUNNING"))),
            updates, False, Optional[String](), List[String](),
        ),
        UInt64(0),
        "a lost CAS on the multi-row arm is 0 rows",
    )
    fault.fail_next_commit(400, String(_STALE))
    assert_equal(
        db.conditional_update[_Rt](
            reactor, _TABLE, Filter.just(Pred.eq(String("id"), DbValue.text("job-b"))),
            updates, False, Optional[String](), List[String](),
        ),
        UInt64(0),
        "a lost CAS on the key arm is 0 rows",
    )
    assert_equal(_phase_of(db, reactor, "job-r"), String("RUNNING"))
    assert_equal(_phase_of(db, reactor, "job-b"), String("PENDING"))

    # A table with no `id` column keys its documents on the create_if_absent
    # value; a guard on `key` addresses that document directly.
    var kcols = List[String]()
    kcols.append(String("key"))
    kcols.append(String("state"))
    var kvals = List[DbValue]()
    kvals.append(DbValue.text("idem-1"))
    kvals.append(DbValue.text("NEW"))
    assert_true(
        db.create_if_absent[_Rt](
            reactor, String("idem"), String("key"), DbValue.text("idem-1"), kcols,
            kvals^,
        )
    )
    var set_state = List[DbColVal]()
    set_state.append(DbColVal.bind(String("state"), DbValue.text("USED")))
    var before_key = mock.run_query_count()
    assert_equal(
        db.conditional_update[_Rt](
            reactor, String("idem"),
            Filter.just(Pred.eq(String("key"), DbValue.text("idem-1"))),
            set_state, False, Optional[String](), List[String](),
        ),
        UInt64(1),
    )
    assert_equal(mock.run_query_count(), before_key, "the key guard sends no query")
    var doc = db.client_ref().get_document(String("idem"), String("idem-1"))
    assert_equal(doc.get_field(String("state")).as_string(), String("USED"))
    _ = db^
    print("    [PASS] conditional_update's zero-row arms and the `key` guard")


def main() raises:
    test_query_rows_in_and_limit()
    test_delete_where_in()
    test_conditional_update_zero_row_arms()
    print("PASS test_firestore_db_query")
