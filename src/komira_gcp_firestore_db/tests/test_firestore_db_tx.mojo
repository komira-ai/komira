# =============================================================================
# test_firestore_db_tx.mojo — the compensating transaction journal, the
#   non-key lookups, both create_if_absent arms, the composite create, and the
#   error arms that must propagate rather than read as "absent" or "lost".
# =============================================================================
#
# Everything runs on the in-process `MockFirestore`. The error arms use its
# two fault hooks: `set_fault(True)` makes every request answer 503
# UNAVAILABLE; `fail_next_commit(status, body)` refuses the next Commit only.
# A 503 is neither "not found", "already exists" nor "precondition failed",
# so every op must RAISE it: swallowing it would report a missing row, a lost
# key or a lost race for what is really an unreachable backend. Each test
# builds its own MockFirestore, so no state crosses tests.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import DbValue, DbColVal, Pred, Filter

from komira_gcp_firestore.firestore_client import FirestoreClient

from komira_gcp_firestore_db import (
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]

comptime _TABLE: String = "thing"
comptime _UNAVAILABLE: String = (
    '{"error":{"code":503,"status":"UNAVAILABLE","message":"down"}}'
)


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


def _cols() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("owner"))
    out.append(String("dedupe_key"))
    return out^


def _row(id: String, owner: String, dedupe: String) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(id))
    out.append(DbValue.text(owner))
    out.append(DbValue.text(dedupe))
    return out^


def _exists(mut db: _FsDb, doc_id: String) raises -> Bool:
    """Whether the document named `doc_id` exists, read by NAME through the
    client (not through a driver lookup that might route around the name)."""
    try:
        _ = db.client_ref().get_document(_TABLE, doc_id)
        return True
    except e:
        if String(e).find(String("FirestoreNotFound")) >= 0:
            return False
        raise e^


# =============================================================================
# 1. begin -> writes -> rollback deletes every create since begin; commit keeps
#    them; a write outside a transaction is never journaled.
# =============================================================================
def test_rollback_compensates_every_create_since_begin() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)

    # A write with no surrounding begin stands on its own: a later rollback
    # must not touch it.
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("t-outside", "o", "k0"))

    db.begin[_Rt](reactor)
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("t-put", "o", "k1"))
    assert_true(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("id"), DbValue.text("t-cia"), _cols(),
            _row("t-cia", "o", "k2"),
        )
    )
    var conflict = List[String]()
    conflict.append(String("owner"))
    conflict.append(String("dedupe_key"))
    assert_true(
        db.create_if_absent_composite[_Rt](
            reactor, _TABLE, conflict.copy(), _cols(), _row("t-comp", "o", "k3")
        )
    )
    # A create through arm (b) (the dedup column is not the key) is journaled
    # too.
    assert_true(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("dedupe_key"), DbValue.text("k4"), _cols(),
            _row("t-armb", "o", "k4"),
        )
    )
    assert_true(_exists(db, "t-put"))
    assert_true(_exists(db, "o~k3"))
    assert_true(_exists(db, "t-armb"))
    db.rollback[_Rt](reactor)

    assert_false(_exists(db, "t-put"), "rollback deletes the put since begin")
    assert_false(_exists(db, "t-cia"), "rollback deletes the create_if_absent")
    assert_false(_exists(db, "o~k3"), "rollback deletes the composite create")
    assert_false(_exists(db, "t-armb"), "rollback deletes the arm (b) create")
    assert_true(_exists(db, "t-outside"), "a write before begin is not journaled")

    # commit keeps the writes and closes the journal: a rollback after it has
    # nothing to compensate.
    db.begin[_Rt](reactor)
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("t-kept", "o", "k5"))
    db.commit[_Rt](reactor)
    db.rollback[_Rt](reactor)
    assert_true(_exists(db, "t-kept"), "a committed write survives a later rollback")

    # A rollback whose journaled doc is already gone is best effort (404 is
    # swallowed), and the transaction closes: the next put is not journaled.
    db.begin[_Rt](reactor)
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("t-gone", "o", "k6"))
    _ = db.delete_by_key[_Rt](reactor, _TABLE, String("id"), DbValue.text("t-gone"))
    db.rollback[_Rt](reactor)
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("t-after", "o", "k7"))
    db.rollback[_Rt](reactor)
    assert_true(_exists(db, "t-after"), "rollback closed the transaction")
    _ = db^
    print("    [PASS] rollback compensates creates since begin; commit keeps them")


# =============================================================================
# 2. get_by_key / delete_by_key on a NON-key column find the document by field
#    and act on its real (key-named) document.
# =============================================================================
def test_non_key_lookup_finds_the_document_by_field() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("t-1", "alice", "k1"))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("t-2", "bob", "k2"))
    var before = mock.run_query_count()

    var got = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("owner"), DbValue.text("bob")
    )
    assert_true(got.__bool__(), "a lookup by a non-key column finds the row")
    var row = got.take()
    assert_equal(row.get_text(row.column_index("id")), String("t-2"))
    assert_equal(mock.run_query_count(), before + 1, "it is ONE query")

    var none = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("owner"), DbValue.text("carol")
    )
    assert_false(none.__bool__(), "no row has that value -> None")

    var n = db.delete_by_key[_Rt](
        reactor, _TABLE, String("owner"), DbValue.text("alice")
    )
    assert_equal(n, UInt64(1), "a delete by a non-key column deletes the row")
    assert_false(_exists(db, "t-1"), "the document named by its KEY is gone")
    assert_true(_exists(db, "t-2"), "the other row is untouched")
    assert_equal(
        db.delete_by_key[_Rt](reactor, _TABLE, String("owner"), DbValue.text("alice")),
        UInt64(0),
        "no row has that value any more -> 0",
    )
    _ = db^
    print("    [PASS] non-key get_by_key / delete_by_key route through a query")


# =============================================================================
# 3. create_if_absent arm (b): the dedup column is NOT the key. The document
#    is named after the key; a second row with the same dedup value loses.
# =============================================================================
def test_create_if_absent_on_a_non_key_dedup_column() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)

    assert_true(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("dedupe_key"), DbValue.text("dk"), _cols(),
            _row("t-1", "o", "dk"),
        ),
        "the first row with a dedup value wins",
    )
    assert_true(_exists(db, "t-1"), "the document is named after the KEY, not the dedup value")
    assert_false(_exists(db, "dk"))
    assert_false(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("dedupe_key"), DbValue.text("dk"), _cols(),
            _row("t-2", "o", "dk"),
        ),
        "a second row with the same dedup value loses",
    )
    assert_false(_exists(db, "t-2"), "and the loser wrote nothing")
    assert_true(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("dedupe_key"), DbValue.text("dk2"), _cols(),
            _row("t-3", "o", "dk2"),
        ),
        "a different dedup value wins",
    )
    _ = db^
    print("    [PASS] create_if_absent on a non-key column dedups by query")


# =============================================================================
# 4. create_if_absent_composite: the doc-id is the tuple, encoded so no two
#    tuples collide; the same tuple loses; a bad conflict list raises.
# =============================================================================
def test_composite_create_is_keyed_on_the_encoded_tuple() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    var conflict = List[String]()
    conflict.append(String("owner"))
    conflict.append(String("dedupe_key"))

    # (a, bc) and (ab, c) join to the same text without a separator.
    assert_true(
        db.create_if_absent_composite[_Rt](
            reactor, _TABLE, conflict.copy(), _cols(), _row("t-1", "a", "bc")
        )
    )
    assert_true(
        db.create_if_absent_composite[_Rt](
            reactor, _TABLE, conflict.copy(), _cols(), _row("t-2", "ab", "c")
        ),
        "(ab, c) does not collide with (a, bc)",
    )
    assert_true(_exists(db, "a~bc"))
    assert_true(_exists(db, "ab~c"))
    assert_false(
        db.create_if_absent_composite[_Rt](
            reactor, _TABLE, conflict.copy(), _cols(), _row("t-9", "a", "bc")
        ),
        "the same tuple loses",
    )

    # `%`, `/` and `~` in a part are escaped, so the separator stays unique.
    assert_true(
        db.create_if_absent_composite[_Rt](
            reactor, _TABLE, conflict.copy(), _cols(), _row("t-3", "x/y", "p~q%")
        )
    )
    assert_true(_exists(db, "x%2Fy~p%7Eq%25"), "parts are percent-encoded")

    # The conflict columns are matched by NAME, in the conflict list's order.
    var reversed = List[String]()
    reversed.append(String("dedupe_key"))
    reversed.append(String("owner"))
    assert_true(
        db.create_if_absent_composite[_Rt](
            reactor, _TABLE, reversed^, _cols(), _row("t-4", "m", "n")
        )
    )
    assert_true(_exists(db, "n~m"))

    with assert_raises(contains="empty conflict_cols"):
        _ = db.create_if_absent_composite[_Rt](
            reactor, _TABLE, List[String](), _cols(), _row("t-5", "a", "b")
        )
    var missing = List[String]()
    missing.append(String("owner"))
    missing.append(String("tenant"))
    with assert_raises(contains='conflict column "tenant" is not in the inserted cols'):
        _ = db.create_if_absent_composite[_Rt](
            reactor, _TABLE, missing^, _cols(), _row("t-6", "a", "b")
        )
    _ = db^
    print("    [PASS] create_if_absent_composite keys on the encoded tuple")


# =============================================================================
# 5. A backend failure is RAISED by every op, never read as absent / lost.
# =============================================================================
def test_backend_failures_propagate() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("t-1", "o", "k1"))

    var fault = mock.share()
    fault.set_fault(True)
    with assert_raises(contains="UNAVAILABLE"):
        _ = db.get_by_key[_Rt](
            reactor, _TABLE, _cols(), String("id"), DbValue.text("t-1")
        )
    with assert_raises(contains="UNAVAILABLE"):
        _ = db.delete_by_key[_Rt](reactor, _TABLE, String("id"), DbValue.text("t-1"))
    fault.set_fault(False)

    # A create refused with anything but ALREADY_EXISTS is not "we lost".
    fault.fail_next_commit(503, String(_UNAVAILABLE))
    with assert_raises(contains="UNAVAILABLE"):
        _ = db.create_if_absent[_Rt](
            reactor, _TABLE, String("id"), DbValue.text("t-2"), _cols(),
            _row("t-2", "o", "k2"),
        )
    var conflict = List[String]()
    conflict.append(String("owner"))
    fault.fail_next_commit(503, String(_UNAVAILABLE))
    with assert_raises(contains="UNAVAILABLE"):
        _ = db.create_if_absent_composite[_Rt](
            reactor, _TABLE, conflict^, _cols(), _row("t-3", "o", "k3")
        )

    # A CAS refused with anything but FAILED_PRECONDITION is not "a racer won".
    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("owner"), DbValue.text("p")))
    fault.fail_next_commit(503, String(_UNAVAILABLE))
    with assert_raises(contains="UNAVAILABLE"):
        _ = db.conditional_update[_Rt](
            reactor, _TABLE, Filter.just(Pred.eq(String("id"), DbValue.text("t-1"))),
            updates, False, Optional[String](), List[String](),
        )

    # The row is still there and unchanged: nothing above wrote.
    var got = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("id"), DbValue.text("t-1")
    )
    assert_true(got.__bool__())
    var row = got.take()
    assert_equal(row.get_text(row.column_index("owner")), String("o"))
    assert_false(_exists(db, "t-2"))
    _ = db^
    print("    [PASS] backend failures propagate from every op")


def main() raises:
    test_rollback_compensates_every_create_since_begin()
    test_non_key_lookup_finds_the_document_by_field()
    test_create_if_absent_on_a_non_key_dedup_column()
    test_composite_create_is_keyed_on_the_encoded_tuple()
    test_backend_failures_propagate()
    print("PASS test_firestore_db_tx")
