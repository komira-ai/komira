# =============================================================================
# test_firestore_database_standalone.mojo — `FirestoreDatabase` is a WORKING
#   `komira_db.Database` on its own: this package, komira_gcp_firestore and
#   komira_db, and nothing of any service above them.
# =============================================================================
#
# It drives the neutral ops end to end against the in-process
# `MockFirestore`, so a missing encoder arm or a lost CAS is RED here.
#
# ZERO network, ZERO GCP: every call lands on the in-process mock, which models
# Firestore's real atomicity (create-if-absent, updateTime-CAS) and its structured
# query WHERE evaluator.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import (
    DbValue,
    DbColVal,
    Pred,
    Filter,
    Order,
    LOGICAL_TIMESTAMPTZ,
)

from komira_gcp_firestore.firestore_client import (
    FirestoreClient,
    FirestoreDocument,
)
from komira_gcp_firestore.firestore_value import FsValue

from komira_proto_codec.codec import decode_json
from komira_gcp_firestore_v1.query import StructuredQuery_Filter
from komira_gcp_firestore_db.mock_firestore import (
    FILTER_COMPOSITE,
    FILTER_FIELD,
    FILTER_UNARY,
)
from komira_gcp_firestore_db import (
    DeclaredIndexSet,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
    TableKeys,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]

# A synthetic collection with a text PK (`id`), a scope column (`owner`), a phase
# column the CAS moves, and a nullable timestamp. Not declared in any
# `TableKeys`, so this exercises the default key (`id`); test 6 declares one.
comptime _TABLE: String = "widget"
comptime _OWNER: String = "owner-A"


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _fs_db(var transport: MockFirestore) -> _FsDb:
    """A FirestoreDatabase over the in-process mock + a static-token client."""
    var client = FirestoreClient[_MockT](
        transport.connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    return _FsDb(client^)


def _cols() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("owner"))
    out.append(String("phase"))
    out.append(String("version"))
    out.append(String("archived_at"))
    return out^


def _row(id: String, phase: String) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(id))
    out.append(DbValue.text(_OWNER))
    out.append(DbValue.text(phase))
    out.append(DbValue.int8(Int64(1)))
    out.append(DbValue.null(LOGICAL_TIMESTAMPTZ))
    return out^


def _owner_filter() raises -> Filter:
    var preds = List[Pred]()
    preds.append(Pred.eq(String("owner"), DbValue.text(_OWNER)))
    return Filter.all_of(preds^)


# =============================================================================
# 1. put -> get_by_key: a row round-trips through the DbValue<->document encoder.
# =============================================================================
def test_put_then_get_by_key_roundtrip() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())

    var n = db.put[_Rt](reactor, _TABLE, _cols(), _row(String("w-1"), String("PENDING")))
    assert_equal(n, UInt64(1), "put reports one row affected")

    var got = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("id"), DbValue.text(String("w-1"))
    )
    assert_true(got.__bool__(), "get_by_key finds the doc it just created")
    var row = got.take()
    assert_equal(
        row.get_text(row.column_index(String("phase"))),
        String("PENDING"),
        "the phase column survives the document encode/decode round-trip",
    )
    assert_true(
        row.is_null(row.column_index(String("archived_at"))),
        "an explicit NULL decodes back as NULL, not as an empty string",
    )

    # A miss is a genuine absence (404 -> None), not an error.
    var missing = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("id"), DbValue.text(String("w-nope"))
    )
    assert_false(missing.__bool__(), "get_by_key on an absent doc returns None")
    _ = db^
    print("    [PASS] put -> get_by_key round-trips (incl. a present NULL)")


# =============================================================================
# 2. create_if_absent: the ATOMIC conditional-create. Exactly one of two racers
#    wins the same key. This is the op every idempotency guard is built on.
# =============================================================================
def test_create_if_absent_is_atomic() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())

    var first = db.create_if_absent[_Rt](
        reactor,
        _TABLE,
        String("id"),
        DbValue.text(String("w-unique")),
        _cols(),
        _row(String("w-unique"), String("PENDING")),
    )
    assert_true(first, "the first create_if_absent WINS the key")

    var second = db.create_if_absent[_Rt](
        reactor,
        _TABLE,
        String("id"),
        DbValue.text(String("w-unique")),
        _cols(),
        _row(String("w-unique"), String("PENDING")),
    )
    assert_false(second, "the second create_if_absent LOSES the key (ALREADY_EXISTS)")
    _ = db^
    print("    [PASS] create_if_absent is atomic (exactly one winner per key)")


# =============================================================================
# 3. query_rows: the structured-query translation returns the scoped rows.
# =============================================================================
def test_query_rows_scopes_by_filter() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())

    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row(String("w-1"), String("PENDING")))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row(String("w-2"), String("PENDING")))
    # A row owned by somebody else — must NOT come back under the owner filter.
    var other = List[DbValue]()
    other.append(DbValue.text(String("w-other")))
    other.append(DbValue.text(String("owner-B")))
    other.append(DbValue.text(String("PENDING")))
    other.append(DbValue.int8(Int64(1)))
    other.append(DbValue.null(LOGICAL_TIMESTAMPTZ))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), other^)

    var rows = db.query_rows[_Rt](
        reactor,
        _TABLE,
        _cols(),
        _owner_filter(),
        List[Order](),
        Optional[UInt32](),
    )
    assert_equal(rows.__len__(), 2, "query_rows returns exactly the two owner-A rows")
    _ = db^
    print("    [PASS] query_rows scopes by the structured-query WHERE filter")


# =============================================================================
# 4. conditional_update: the updateTime-CAS. A guard that matches applies the
#    update + bumps the version; a guard that has gone stale affects ZERO rows
#    (which is what every caller translates into a concurrent-modification error).
# =============================================================================
def test_conditional_update_cas() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row(String("w-1"), String("PENDING")))

    var guard_preds = List[Pred]()
    guard_preds.append(Pred.eq(String("id"), DbValue.text(String("w-1"))))
    guard_preds.append(Pred.eq(String("phase"), DbValue.text(String("PENDING"))))
    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("phase"), DbValue.text(String("RUNNING"))))

    var hit = db.conditional_update[_Rt](
        reactor,
        _TABLE,
        Filter.all_of(guard_preds^),
        updates,
        False,
        Optional[String](String("version")),
        List[String](),
    )
    assert_equal(hit, UInt64(1), "a MATCHING guard updates exactly one row")

    var after_opt = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("id"), DbValue.text(String("w-1"))
    )
    assert_true(after_opt.__bool__(), "the CAS-updated doc is still readable")
    var after = after_opt.take()
    assert_equal(
        after.get_text(after.column_index(String("phase"))),
        String("RUNNING"),
        "the CAS applied the update",
    )
    assert_equal(
        after.get_int8(after.column_index(String("version"))),
        Int64(2),
        "the CAS bumped the version column",
    )

    # Re-issue the SAME guard: `phase` is no longer PENDING, so it is now stale.
    var stale_preds = List[Pred]()
    stale_preds.append(Pred.eq(String("id"), DbValue.text(String("w-1"))))
    stale_preds.append(Pred.eq(String("phase"), DbValue.text(String("PENDING"))))
    var stale_updates = List[DbColVal]()
    stale_updates.append(
        DbColVal.bind(String("phase"), DbValue.text(String("DONE")))
    )
    var miss = db.conditional_update[_Rt](
        reactor,
        _TABLE,
        Filter.all_of(stale_preds^),
        stale_updates,
        False,
        Optional[String](String("version")),
        List[String](),
    )
    assert_equal(miss, UInt64(0), "a STALE guard affects zero rows (the CAS loses)")
    _ = db^
    print("    [PASS] conditional_update CAS: guard hit updates+bumps, stale guard is a no-op")


# =============================================================================
# 5. delete_by_key + delete_where: single-doc delete is idempotent; the filtered
#    delete removes the matching set and leaves the rest.
# =============================================================================
def test_deletes() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row(String("w-1"), String("PENDING")))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row(String("w-2"), String("PENDING")))

    var deleted = db.delete_by_key[_Rt](
        reactor, _TABLE, String("id"), DbValue.text(String("w-1"))
    )
    assert_equal(deleted, UInt64(1), "delete_by_key removes the addressed doc")
    var again = db.delete_by_key[_Rt](
        reactor, _TABLE, String("id"), DbValue.text(String("w-1"))
    )
    assert_equal(again, UInt64(0), "a repeat delete is a no-op (404 swallowed)")

    var swept = db.delete_where[_Rt](reactor, _TABLE, _owner_filter())
    assert_equal(swept, UInt64(1), "delete_where removes the one remaining owner-A row")
    var rows = db.query_rows[_Rt](
        reactor,
        _TABLE,
        _cols(),
        _owner_filter(),
        List[Order](),
        Optional[UInt32](),
    )
    assert_equal(rows.__len__(), 0, "the collection is drained of owner-A rows")
    _ = db^
    print("    [PASS] delete_by_key is idempotent; delete_where sweeps the filtered set")


# =============================================================================
# 6. TableKeys: a table keyed on a column other than `id`.
# =============================================================================
comptime _GADGET: String = "gadget"


def _gadget_cols() -> List[String]:
    var out = List[String]()
    out.append(String("sku"))
    out.append(String("owner"))
    return out^


def _gadget_row(sku: String) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(sku))
    out.append(DbValue.text(_OWNER))
    return out^


def _keyed_db(var transport: MockFirestore) -> _FsDb:
    var keys = TableKeys()
    keys.declare(String(_GADGET), String("sku"))
    var client = FirestoreClient[_MockT](
        transport.connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    return _FsDb(client^, DeclaredIndexSet(), keys^)


def test_declared_table_keys() raises:
    var keys = TableKeys()
    assert_equal(keys.pk_col(String("anything")), String("id"))
    keys.declare(String("gadget"), String("sku"))
    keys.declare(String("ledger"), String(""))
    assert_equal(keys.pk_col(String("gadget")), String("sku"))
    assert_equal(keys.pk_col(String("ledger")), String(""))
    keys.declare(String("gadget"), String("code"))  # a re-declaration replaces
    assert_equal(keys.pk_col(String("gadget")), String("code"))

    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _keyed_db(MockFirestore())
    _ = db.put[_Rt](reactor, _GADGET, _gadget_cols(), _gadget_row(String("g-1")))
    # The document is NAMED after `sku`: a direct GET of `gadget/g-1` finds it.
    # (`get_by_key` / `delete_by_key` below would also pass with the key
    # ignored, because a non-key lookup falls back to a query; this GET would
    # 404 and raise.)
    var direct = db.client_ref().get_document(_GADGET, String("g-1"))
    assert_true(
        direct.name.endswith(String("/g-1")),
        "the document id is the declared key's value: " + direct.name,
    )
    # So a delete by `sku` takes the direct path and removes it.
    var got = db.get_by_key[_Rt](
        reactor, _GADGET, _gadget_cols(), String("sku"), DbValue.text(String("g-1"))
    )
    assert_true(got.__bool__(), "get_by_key on the declared key finds the doc")
    var n = db.delete_by_key[_Rt](
        reactor, _GADGET, String("sku"), DbValue.text(String("g-1"))
    )
    assert_equal(n, UInt64(1), "delete_by_key on the declared key deletes it")
    var gone = db.get_by_key[_Rt](
        reactor, _GADGET, _gadget_cols(), String("sku"), DbValue.text(String("g-1"))
    )
    assert_false(gone.__bool__(), "and it is gone")

    # A projection that LACKS the declared key is refused, never minted.
    var lacks = List[String]()
    lacks.append(String("owner"))
    var only_owner = List[DbValue]()
    only_owner.append(DbValue.text(_OWNER))
    var refused = False
    try:
        _ = db.put[_Rt](reactor, _GADGET, lacks.copy(), only_owner.copy())
    except e:
        refused = True
        assert_true(String(e).find(String("primary key \"sku\"")) >= 0, String(e))
    assert_true(refused, "put without the declared key column must raise")

    # An UNDECLARED table whose projection has no `id` still mints (the
    # default is not refused).
    _ = db.put[_Rt](reactor, String("undeclared"), lacks^, only_owner^)
    _ = db^
    print("    [PASS] TableKeys: a declared key names the document; a missing one is refused")


# =============================================================================
# 7. The mock's absent-field rules are the live service's: a document that
#    lacks a field matches no filter on it and drops out of an orderBy on it;
#    only an explicit null is IS_NULL.
# =============================================================================
def _sparse(var phase: Optional[FsValue]) -> FsValue:
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("owner"))
    vals.append(FsValue.string(String(_OWNER)))
    if phase:
        keys.append(String("phase"))
        vals.append(phase.take())
    return FsValue.map_of(keys^, vals^)


def _ids(docs: List[FirestoreDocument]) -> String:
    var out = String("")
    for i in range(len(docs)):
        var name = docs[i].name
        out += String(unsafe_from_utf8=name.as_bytes()[name.rfind("/") + 1 :])
    return out^


def test_a_document_lacking_the_field_matches_no_filter_on_it() raises:
    var mock = MockFirestore()
    var client = FirestoreClient[_MockT](
        mock.connector(), String("test-project"), String("(default)"), String("t")
    )
    _ = client.patch_document(
        String(_TABLE), String("a"), _sparse(FsValue.string(String("P")))
    )
    _ = client.patch_document(String(_TABLE), String("b"), _sparse(None))
    _ = client.patch_document(String(_TABLE), String("c"), _sparse(FsValue.null()))

    var from_ = String('{"from":[{"collectionId":"') + _TABLE + '"}],'
    var field = String('{"field":{"fieldPath":"phase"},')
    assert_equal(
        _ids(client.run_query(from_ + '"where":{"fieldFilter":' + field
            + '"op":"NOT_EQUAL","value":{"stringValue":"Q"}}}}')),
        String("a"),
        "NOT_EQUAL skips a missing field and an explicit null",
    )
    assert_equal(
        _ids(client.run_query(from_ + '"where":{"unaryFilter":' + field
            + '"op":"IS_NULL"}}}')),
        String("c"),
        "IS_NULL is an explicit null only",
    )
    assert_equal(
        _ids(client.run_query(from_ + '"where":{"unaryFilter":' + field
            + '"op":"IS_NOT_NULL"}}}')),
        String("a"),
    )
    assert_equal(
        _ids(client.run_query(from_ + '"orderBy":[{"field":{"fieldPath":"phase"}}]}')),
        String("ca"),
        "an orderBy drops the document that lacks the field; null sorts first",
    )
    assert_equal(
        _ids(client.run_query(from_ + '"where":{"fieldFilter":{"field":'
            + '{"fieldPath":"owner"},"op":"EQUAL","value":{"stringValue":"'
            + _OWNER + '"}}}}')),
        String("abc"),
    )


def test_mock_filter_arms_are_the_generated_decoders() raises:
    assert_equal(
        decode_json[StructuredQuery_Filter](String('{"compositeFilter":{}}'))._oneof0_case,
        FILTER_COMPOSITE,
    )
    assert_equal(
        decode_json[StructuredQuery_Filter](String('{"fieldFilter":{}}'))._oneof0_case,
        FILTER_FIELD,
    )
    assert_equal(
        decode_json[StructuredQuery_Filter](String('{"unaryFilter":{}}'))._oneof0_case,
        FILTER_UNARY,
    )


def main() raises:
    test_put_then_get_by_key_roundtrip()
    test_create_if_absent_is_atomic()
    test_query_rows_scopes_by_filter()
    test_conditional_update_cas()
    test_deletes()
    test_declared_table_keys()
    test_a_document_lacking_the_field_matches_no_filter_on_it()
    test_mock_filter_arms_are_the_generated_decoders()
    print(
        "PASS test_firestore_database_standalone (FirestoreDatabase drives the"
        " neutral Database ops)"
    )
