# =============================================================================
# test_firestore_kv_store.mojo — the Firestore document/KV seam conformer
#   FALSIFIER.
# =============================================================================
#
# THE FALSIFIERS over a ScriptedFirestore (canned HTTP answers per call, ZERO
# sockets, ZERO network) — proving a caller can use Firestore as a document
# store through the minimal DocumentStore seam:
#
#   (1) get/put/delete/query ROUND-TRIP: put an FsValue field-map, get it back
#       (the typed fields survive), query a collection, delete. FALSIFIER: a
#       dropped field / a wrong verb / a mis-built request.
#   (2) get on a MISSING document (a `missing` result) returns None — the KV
#       absent case, NOT an error. FALSIFIER: if it propagated as an error, a
#       caller could not distinguish "no such key" from "failure".
#   (3) delete of an ABSENT key is IDEMPOTENT (a no-op, not an error) — the
#       KV-delete contract. FALSIFIER: if a re-delete raised, a
#       delete-after-delete would spuriously fail.
#   (4) put is an unconditional Commit (an upsert) carrying the fields; the seam maps
#       the KV verbs onto the right document operations.
#
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_firestore.firestore_value import (
    FsValue,
    FS_T_STRING,
    FS_T_INTEGER,
)
from komira_http_core.transport.scripted import ScriptedConnector
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore
from komira_gcp_firestore.document_store import (
    DocumentStore,
    FirestoreDocumentStore,
    DocumentEntry,
)


comptime _PROJECT: String = "example-project"
comptime _DATABASE: String = "(default)"
comptime _BEARER: String = "ya29.test-access-token"


def _store(
    mut script: ScriptedFirestore,
) raises -> FirestoreDocumentStore[ScriptedConnector]:
    return FirestoreDocumentStore[ScriptedConnector](
        script.take_connector(), String(_PROJECT), String(_DATABASE), String(_BEARER)
    )


def _profile_fields(var email: String, var visits: String) -> FsValue:
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("email"))
    vals.append(FsValue.string(email^))
    keys.append(String("visits"))
    vals.append(FsValue.integer(visits^))
    return FsValue.map_of(keys^, vals^)


def _commit_ok() -> String:
    return String('{"writeResults":[{"updateTime":"2026-10-01T00:00:01Z"}]}')


def _document_echo(doc_id: String, email: String, visits: String) -> String:
    """A BatchGetDocuments answer finding the document with these fields."""
    var out = String('[{"found":{')
    out += '"name":"projects/example-project/databases/(default)/documents/profiles/'
    out += doc_id
    out += '","fields":{"email":{"stringValue":"'
    out += email
    out += '"},"visits":{"integerValue":"'
    out += visits
    out += '"}}}}]'
    return out^


# =============================================================================
# (1) + (4) put (an upsert) then get round-trips the typed fields.
# =============================================================================
def test_put_then_get_roundtrip() raises:
    var t = ScriptedFirestore()
    t.queue_response(200, _commit_ok())  # put
    t.queue_response(200, _document_echo(String("u1"), String("u1@x.com"), String("3")))  # get
    var store = _store(t)

    store.put(String("profiles"), String("u1"), _profile_fields(String("u1@x.com"), String("3")))
    var got = store.get(String("profiles"), String("u1"))
    assert_true(Bool(got), msg="get after put must return the document")
    var fields = got.take()
    assert_equal(fields.map_get(String("email")).type_tag, FS_T_STRING)
    assert_equal(fields.map_get(String("email")).as_string(), String("u1@x.com"))
    assert_equal(fields.map_get(String("visits")).type_tag, FS_T_INTEGER)
    assert_equal(fields.map_get(String("visits")).as_string(), String("3"))

    # The put was an unconditional Commit (an upsert) carrying the fields.
    assert_equal(
        t.call_path(0),
        String("/v1/projects/example-project/databases/%28default%29/documents:commit"),
    )
    assert_true(_contains(t.call_body(0), String('"stringValue":"u1@x.com"')))
    assert_false(_contains(t.call_body(0), String("currentDocument")))
    # The get was a BatchGetDocuments.
    assert_equal(
        t.call_path(1),
        String("/v1/projects/example-project/databases/%28default%29/documents:batchGet"),
    )


# =============================================================================
# (2) get on a MISSING document returns None (the KV absent case).
# =============================================================================
def test_get_missing_returns_none() raises:
    var t = ScriptedFirestore()
    t.queue_response(
        200,
        String(
            '[{"missing":"projects/example-project/databases/(default)/documents/profiles/ghost"}]'
        ),
    )
    var store = _store(t)
    var got = store.get(String("profiles"), String("ghost"))
    assert_false(
        Bool(got),
        msg="get on a missing document must return None, not raise",
    )


# =============================================================================
# (3) delete is idempotent — deleting an absent key is a no-op, not an error
#     (the client reports the missing document; the store swallows it).
# =============================================================================
def test_delete_is_idempotent() raises:
    # First delete succeeds (200).
    var t = ScriptedFirestore()
    t.queue_response(200, _document_echo(String("u1"), String("u1@x.com"), String("3")))  # delete #1 reads it
    t.queue_response(200, String('{"writeResults":[{}]}'))  # delete #1 -> ok
    t.queue_response(
        200,
        String('[{"missing":"projects/example-project/databases/(default)/documents/profiles/u1"}]'),
    )  # delete #2 reads it: absent
    var store = _store(t)

    store.delete(String("profiles"), String("u1"))  # ok
    # Re-deleting (now absent) is a no-op — must NOT raise.
    var raised = False
    try:
        store.delete(String("profiles"), String("u1"))
    except e:
        raised = True
    assert_false(
        raised,
        msg="deleting an absent key must be a no-op (idempotent KV-delete)",
    )

    # Read + delete, then a read that finds nothing and writes nothing.
    assert_equal(t.call_count(), 3)
    assert_true(_contains(t.call_body(1), String('"delete":"projects/example-project/databases/(default)/documents/profiles/u1"')))
    assert_true(_contains(t.call_path(2), String(":batchGet")))


# =============================================================================
# (1) query returns (key, fields) entries; the key is the doc-id path segment.
# =============================================================================
def test_query_returns_key_and_fields() raises:
    var stream = String(
        "["
        + '{"document":{"name":"projects/example-project/databases/(default)/documents/profiles/u1",'
        + '"fields":{"email":{"stringValue":"u1@x.com"}}},'
        + '"readTime":"2026-10-01T00:00:01Z"},'
        + '{"document":{"name":"projects/example-project/databases/(default)/documents/profiles/u2",'
        + '"fields":{"email":{"stringValue":"u2@x.com"}}},'
        + '"readTime":"2026-10-01T00:00:02Z"}'
        + "]"
    )
    var t = ScriptedFirestore()
    t.queue_response(200, stream)
    var store = _store(t)
    var entries = store.query(
        String("profiles"),
        String('{"from":[{"collectionId":"profiles"}]}'),
    )
    assert_equal(len(entries), 2)
    # The key is the last path segment (the document id).
    assert_equal(entries[0].key, String("u1"))
    assert_equal(entries[1].key, String("u2"))
    # The typed fields survive.
    assert_equal(entries[0].fields.map_get(String("email")).as_string(), String("u1@x.com"))
    assert_equal(entries[1].fields.map_get(String("email")).as_string(), String("u2@x.com"))

    assert_equal(t.call_method(0), String("POST"))
    assert_equal(
        t.call_path(0),
        String("/v1/projects/example-project/databases/%28default%29/documents:runQuery"),
    )


# =============================================================================
# The seam is generic: a helper that takes ANY DocumentStore proves the trait is
# usable through the abstraction (a caller codes against DocumentStore).
# =============================================================================
def _put_through_seam[S: DocumentStore](
    mut store: S, collection: String, key: String, fields: FsValue
) raises:
    store.put(collection, key, fields)


def test_seam_is_generic_over_backend() raises:
    var t = ScriptedFirestore()
    t.queue_response(200, _commit_ok())
    var store = _store(t)
    _put_through_seam(store, String("profiles"), String("g1"), _profile_fields(String("g1@x.com"), String("1")))
    assert_equal(
        t.call_path(0),
        String("/v1/projects/example-project/databases/%28default%29/documents:commit"),
    )


# ---- a tiny substring helper (no general search dep) ----
def _contains(haystack: String, needle: String) -> Bool:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0 or len(nb) > len(hb):
        return len(nb) == 0
    for s in range(0, len(hb) - len(nb) + 1):
        var ok = True
        for j in range(len(nb)):
            if hb[s + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


def main() raises:
    test_put_then_get_roundtrip()
    test_get_missing_returns_none()
    test_delete_is_idempotent()
    test_query_returns_key_and_fields()
    test_seam_is_generic_over_backend()
    print("test_firestore_kv_store: ALL PASS")
