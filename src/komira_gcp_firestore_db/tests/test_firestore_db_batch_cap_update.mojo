# =============================================================================
# test_firestore_db_batch_cap_update.mojo — the FS_DB_BATCH_MAX chunk cap on
#   the multi-row conditional_update: one call writes at most FS_DB_BATCH_MAX
#   documents, and a second call takes the rest.
# =============================================================================
#
# Its own test binary because it writes FS_DB_BATCH_MAX + 1 documents (about
# a thousand requests to the mock); the delete_where cap is its sibling,
# test_firestore_db_batch_cap_delete, so neither runs long under coverage.
# =============================================================================

from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import DbValue, DbColVal, Pred, Filter, Order

from komira_gcp_firestore.firestore_client import FirestoreClient

from komira_gcp_firestore_db import (
    FS_DB_BATCH_MAX,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]
comptime _TABLE: String = "bulk"


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _cols() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("owner"))
    out.append(String("flag"))
    return out^


def _count(mut db: _FsDb, mut reactor: Reactor[NoopSink], var f: Filter) raises -> Int:
    return db.query_rows[_Rt](
        reactor, _TABLE, _cols(), f^, List[Order](), Optional[UInt32]()
    ).__len__()


def _seeded(mut reactor: Reactor[NoopSink]) raises -> _FsDb:
    """FS_DB_BATCH_MAX + 1 documents, all owned by "o", flag 0."""
    var mock = MockFirestore()
    var client = FirestoreClient[_MockT](
        mock.connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var db = _FsDb(client^)
    for i in range(FS_DB_BATCH_MAX + 1):
        var v = List[DbValue]()
        v.append(DbValue.text(String("b-") + String(i)))
        v.append(DbValue.text("o"))
        v.append(DbValue.int8(Int64(0)))
        _ = db.put[_Rt](reactor, _TABLE, _cols(), v^)
    return db^


def test_one_update_writes_at_most_the_batch_cap() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _seeded(reactor)
    var set_flag = List[DbColVal]()
    set_flag.append(DbColVal.bind(String("flag"), DbValue.int8(Int64(1))))
    var owner = Filter.just(Pred.eq(String("owner"), DbValue.text("o")))
    var updated = db.conditional_update[_Rt](
        reactor, _TABLE, owner^, set_flag, False, Optional[String](),
        List[String](),
    )
    assert_equal(updated, UInt64(FS_DB_BATCH_MAX), "one UPDATE stops at the cap")
    var flagged = Filter.just(Pred.eq(String("flag"), DbValue.int8(Int64(1))))
    assert_equal(_count(db, reactor, flagged.copy()), FS_DB_BATCH_MAX)
    # The rest is taken by the next call (a guard on the unflagged ones).
    var unflagged = List[Pred]()
    unflagged.append(Pred.eq(String("owner"), DbValue.text("o")))
    unflagged.append(Pred.eq(String("flag"), DbValue.int8(Int64(0))))
    assert_equal(
        db.conditional_update[_Rt](
            reactor, _TABLE, Filter.all_of(unflagged^), set_flag, False,
            Optional[String](), List[String](),
        ),
        UInt64(1),
    )
    assert_equal(_count(db, reactor, flagged^), FS_DB_BATCH_MAX + 1)
    _ = db^
    print("    [PASS] conditional_update stops at FS_DB_BATCH_MAX")


def main() raises:
    test_one_update_writes_at_most_the_batch_cap()
    print("PASS test_firestore_db_batch_cap_update")
