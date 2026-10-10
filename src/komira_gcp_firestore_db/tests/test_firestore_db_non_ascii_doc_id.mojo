# =============================================================================
# test_firestore_db_non_ascii_doc_id.mojo — a document id that is not ASCII
#   keeps its UTF-8 bytes through every path that names a document: the
#   doc-id encoders, the name -> id reader, and the multi-row operations
#   (conditional_update's query arm, delete_where, claim_rows) and the
#   create-if-absent arms that go through them.
# =============================================================================
#
# The defect these cases catch: the encoders and `_last_name_segment` once
# appended each UTF-8 byte as its own code point (`chr(byte)`), so `é` (C3 A9)
# came back as `Ã©` (C3 83 C2 A9). A row keyed `é-1` was then addressed as
# `Ã©-1`: the multi-row update raised NOT_FOUND, delete_where counted a delete
# that never happened, and claim_rows could not claim the row.
#
# Every case runs on the in-process MockFirestore. The keys hold no `%` and no
# `/`, so the percent-encoding scheme itself is not what these cases test.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import (
    DbValue,
    DbColVal,
    Pred,
    Filter,
    Order,
    PodNameMinter,
)

from komira_gcp_firestore.firestore_client import FirestoreClient

from komira_gcp_firestore_db import (
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
)
from komira_gcp_firestore_db.firestore_database import (
    _encode_composite_part,
    _encode_doc_id_part,
    _last_name_segment,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]

comptime _TABLE: String = "t"
# Two-, three- and four-byte UTF-8 sequences in one id.
comptime _ID: String = "é-1-漢-🙂"


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
    assert_true(Bool(got), "the row is still there")
    var row = got.take()
    return row.get_text(row.column_index("owner"))


# =============================================================================
# 1. The pure pieces keep multi-byte UTF-8 whole, and still escape what they
#    escape around it.
# =============================================================================
def test_encoders_keep_utf8_whole() raises:
    assert_equal(_encode_doc_id_part(_ID), _ID, "nothing to escape: unchanged")
    assert_equal(_encode_doc_id_part(String("é%ü/漢")), String("é%25ü%2F漢"))
    # Only the composite encoder escapes `~` (its separator); a single-column
    # doc id keeps it, because put and get_by_key name the document by the raw id.
    assert_equal(
        _encode_doc_id_part(String("é~ü")), String("é~ü"), "doc ids keep ~"
    )
    assert_equal(_encode_composite_part(_ID), _ID, "nothing to escape: unchanged")
    assert_equal(
        _encode_composite_part(String("é~ü%/🙂")), String("é%7Eü%25%2F🙂")
    )
    assert_equal(
        _last_name_segment(
            String("projects/p/databases/(default)/documents/t/") + _ID
        ),
        _ID,
    )
    assert_equal(_last_name_segment(String("ü")), String("ü"), "no slash")
    assert_equal(_last_name_segment(String("a/")), String(""), "trailing slash")
    print("    [PASS] the encoders keep UTF-8 whole")


# =============================================================================
# 2. conditional_update's multi-row arm (no PK predicate) writes the row.
# =============================================================================
def test_multirow_update_finds_a_non_ascii_row() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row(_ID, "o"))
    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("owner"), DbValue.text("p")))
    var n = db.conditional_update[_Rt](
        reactor,
        _TABLE,
        Filter.just(Pred.eq(String("owner"), DbValue.text("o"))),
        updates,
        False,
        None,
        List[String](),
    )
    assert_equal(n, UInt64(1), "one row updated")
    assert_equal(_owner_of(db, reactor, _ID), String("p"), "the update landed")
    _ = db^
    print("    [PASS] multi-row conditional_update writes a non-ASCII row")


# =============================================================================
# 3. delete_where deletes the row it counts.
# =============================================================================
def test_delete_where_deletes_a_non_ascii_row() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row(_ID, "o"))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("ascii-1", "keep"))
    var n = db.delete_where[_Rt](
        reactor, _TABLE, Filter.just(Pred.eq(String("owner"), DbValue.text("o")))
    )
    assert_equal(n, UInt64(1))
    var got = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("id"), DbValue.text(_ID)
    )
    assert_false(Bool(got), "the counted row is gone")
    assert_equal(mock.count(_ID), 0)
    assert_equal(_owner_of(db, reactor, "ascii-1"), String("keep"))
    _ = db^
    print("    [PASS] delete_where deletes a non-ASCII row")


# =============================================================================
# 4. claim_rows claims a non-ASCII row (its CAS and re-read name the doc).
# =============================================================================
def test_claim_rows_claims_a_non_ascii_row() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    var cols = List[String]()
    cols.append(String("id"))
    cols.append(String("phase"))
    cols.append(String("created_at"))
    var vals = List[DbValue]()
    vals.append(DbValue.text(_ID))
    vals.append(DbValue.text("PENDING"))
    vals.append(DbValue.int8(Int64(1)))
    _ = db.put[_Rt](reactor, _TABLE, cols, vals)
    var rows = db.claim_rows[_Rt](
        reactor, _TABLE, 1, Filter(), List[Order](), String("phase"),
        String("PENDING"), String("RUNNING"), List[DbColVal](), PodNameMinter(),
        Optional[String](), List[String](),
    )
    assert_equal(rows.__len__(), 1, "the row is claimed")
    assert_equal(rows.row(0).get_text(rows.column_index("id")), _ID)
    assert_equal(
        rows.row(0).get_text(rows.column_index("phase")), String("RUNNING")
    )
    var got = db.get_by_key[_Rt](
        reactor, _TABLE, cols, String("id"), DbValue.text(_ID)
    )
    var row = got.take()
    assert_equal(row.get_text(row.column_index("phase")), String("RUNNING"))
    _ = db^
    print("    [PASS] claim_rows claims a non-ASCII row")


# =============================================================================
# 5. create_if_absent and create_if_absent_composite mint the id from the
#    value's own bytes, so get_by_key finds what create_if_absent made.
# =============================================================================
def test_create_if_absent_mints_the_utf8_id() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    assert_true(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("id"), DbValue.text(_ID), _cols(),
            _row(_ID, "o"),
        )
    )
    assert_equal(mock.count(_ID), 1, "the doc is named by the id's own bytes")
    assert_equal(_owner_of(db, reactor, _ID), String("o"))

    # A `~` in a single-column id stays raw, so get_by_key finds the row.
    var tilde_id = String("é~ü")
    assert_true(
        db.create_if_absent[_Rt](
            reactor, _TABLE, String("id"), DbValue.text(tilde_id), _cols(),
            _row(tilde_id, "t"),
        )
    )
    assert_equal(mock.count(tilde_id), 1, "the doc keeps the raw ~")
    assert_equal(_owner_of(db, reactor, tilde_id), String("t"))

    var conflict = List[String]()
    conflict.append(String("id"))
    conflict.append(String("owner"))
    assert_true(
        db.create_if_absent_composite[_Rt](
            reactor, String("u"), conflict, _cols(), _row("ü", "漢")
        )
    )
    assert_equal(mock.count(String("ü~漢")), 1, "the composite id keeps UTF-8")
    _ = db^
    print("    [PASS] create_if_absent mints the UTF-8 id")


def main() raises:
    print("test_firestore_db_non_ascii_doc_id")
    test_encoders_keep_utf8_whole()
    test_multirow_update_finds_a_non_ascii_row()
    test_delete_where_deletes_a_non_ascii_row()
    test_claim_rows_claims_a_non_ascii_row()
    test_create_if_absent_mints_the_utf8_id()
