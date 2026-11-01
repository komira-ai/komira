# =============================================================================
# test_firestore_db_doc_id_escape.mojo — a key holding `%` or `/` names the
#   same document on every path that addresses a row by its key: put,
#   get_by_key, delete_by_key, conditional_update's PK arm and both
#   create_if_absent arms.
# =============================================================================
#
# The defect these cases catch: create_if_absent percent-encoded the document
# id (`%` -> `%25`, `/` -> `%2F`) and the other paths used the raw key text. A
# row create_if_absent made under `50%` was stored as `t/50%25`, and
# get_by_key, conditional_update and delete_by_key looked for `t/50%` and
# missed it. A row put under `a/b` was written as document `b` of a
# collection `t/a`, because Firestore reads `/` in a name as a path separator.
#
# Every case runs on the in-process MockFirestore, which splits a document
# name at its last `/` the way Firestore does.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

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

comptime _TABLE: String = "t"


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
    return out^


def _row(id: String, owner: String) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(id))
    out.append(DbValue.text(owner))
    return out^


def _owner_of(
    mut db: _FsDb, mut reactor: Reactor[NoopSink], id: String
) raises -> String:
    var got = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("id"), DbValue.text(id)
    )
    assert_true(Bool(got), "get_by_key finds the row")
    var row = got.take()
    return row.get_text(row.column_index("owner"))


def _set_owner(
    mut db: _FsDb, mut reactor: Reactor[NoopSink], id: String, owner: String
) raises -> UInt64:
    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("owner"), DbValue.text(owner)))
    return db.conditional_update[_Rt](
        reactor,
        _TABLE,
        Filter.just(Pred.eq(String("id"), DbValue.text(id))),
        updates,
        False,
        None,
        List[String](),
    )


# =============================================================================
# 1. A row create_if_absent made under a `%` key is found, updated and deleted
#    by that key.
# =============================================================================
def test_create_if_absent_row_is_addressable_by_its_key() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    var key = String("50%")
    assert_true(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("id"), DbValue.text(key), _cols(),
            _row(key, "o"),
        )
    )
    assert_equal(mock.count(String("50%25")), 1, "stored under the encoded id")
    assert_equal(_owner_of(db, reactor, key), String("o"))
    assert_equal(_set_owner(db, reactor, key, "p"), UInt64(1), "one row updated")
    assert_equal(_owner_of(db, reactor, key), String("p"), "the update landed")
    assert_equal(
        db.delete_by_key[_Rt](reactor, _TABLE, String("id"), DbValue.text(key)),
        UInt64(1),
        "one row deleted",
    )
    assert_equal(mock.count(String("50%25")), 0, "the document is gone")
    _ = db^
    print("    [PASS] a create_if_absent row is addressable by its % key")


# =============================================================================
# 2. put names the document by the same encoded id, so a `/` stays inside the
#    id and create_if_absent sees the row put wrote.
# =============================================================================
def test_put_encodes_the_key_like_create_if_absent() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    var key = String("a/b%c")
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row(key, "o"))
    assert_equal(
        mock.count(String("a%2Fb%25c")), 1, "one document, under the encoded id"
    )
    assert_equal(mock.count(String("b%c")), 0, "no document split at the /")
    assert_equal(_owner_of(db, reactor, key), String("o"))
    assert_false(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("id"), DbValue.text(key), _cols(),
            _row(key, "other"),
        ),
        "create_if_absent sees the row put wrote",
    )
    assert_equal(_owner_of(db, reactor, key), String("o"), "first write kept")
    _ = db^
    print("    [PASS] put encodes the key like create_if_absent")


# =============================================================================
# 3. The create_if_absent arm whose dedup column is not the PK names the
#    document by the encoded PK, and the PK paths find it.
# =============================================================================
def test_non_pk_dedup_arm_row_is_addressable_by_its_key() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    var key = String("x/1%")
    assert_true(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("owner"), DbValue.text("o"), _cols(),
            _row(key, "o"),
        )
    )
    assert_equal(mock.count(String("x%2F1%25")), 1, "stored under the encoded id")
    assert_equal(_owner_of(db, reactor, key), String("o"))
    assert_equal(_set_owner(db, reactor, key, "q"), UInt64(1), "one row updated")
    assert_equal(
        db.delete_by_key[_Rt](reactor, _TABLE, String("id"), DbValue.text(key)),
        UInt64(1),
        "one row deleted",
    )
    _ = db^
    print("    [PASS] the non-PK dedup arm's row is addressable by its key")


def main() raises:
    print("test_firestore_db_doc_id_escape")
    test_create_if_absent_row_is_addressable_by_its_key()
    test_put_encodes_the_key_like_create_if_absent()
    test_non_pk_dedup_arm_row_is_addressable_by_its_key()
