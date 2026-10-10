# =============================================================================
# test_mock_firestore.mojo — MockFirestore is the executable stand-in for the
#   service every Firestore-backed store test runs on, so each of its answers
#   is pinned here: routing, the fault hooks, every Commit precondition arm,
#   and every RunQuery filter, value type and ordering rule it models.
# =============================================================================
#
# The Commit and routing arms are driven through `answer` directly (the HTTP
# boundary the client talks to), with the wire JSON written out, so an arm the
# real client never sends is still pinned. The query arms go through the real
# `FirestoreClient.run_query`. Each test builds its own MockFirestore.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true, assert_false

from komira_gcp_firestore.firestore_client import (
    FirestoreClient,
    FirestoreDocument,
)
from komira_gcp_firestore.firestore_value import FsValue

from komira_gcp_firestore_db import MockFirestore, MockFirestoreConnector


comptime _MockT = MockFirestoreConnector
comptime _DB: String = "projects/p/databases/(default)"
comptime _DOCS: String = "projects/p/databases/(default)/documents"


def _client(mock: MockFirestore) -> FirestoreClient[_MockT]:
    return FirestoreClient[_MockT](
        mock.connector(), String("p"), String("(default)"), String("t")
    )


def _ids(docs: List[FirestoreDocument]) -> String:
    var out = String("")
    for i in range(len(docs)):
        var name = docs[i].name
        out += String(unsafe_from_utf8=name.as_bytes()[name.rfind("/") + 1 :])
    return out^


def _commit(var writes: String) -> String:
    return String('{"database":"') + _DB + '","writes":[' + writes + "]}"


def _upd(coll: String, id: String, pre: String) -> String:
    """An update write of `coll/id` with one string field, and precondition
    `pre` (JSON, or "" for none)."""
    var out = (
        String('{"update":{"name":"') + _DOCS + "/" + coll + "/" + id
        + '","fields":{"v":{"stringValue":"' + id + '"}}}'
    )
    if pre.byte_length() > 0:
        out += String(',"currentDocument":') + pre
    return out + "}"


# =============================================================================
# 1. Routing, the fault hook, BatchGetDocuments of several names, and a name
#    that is not a document's.
# =============================================================================
def test_routing_faults_and_batch_get() raises:
    var mock = MockFirestore()
    var h = mock.share()
    var batch = String("/v1/") + _DOCS + ":batchGet"
    with assert_raises(contains="unhandled method GET"):
        _ = h.answer(String("GET"), batch, String(""))
    with assert_raises(contains="unroutable target /v1/x:listen"):
        _ = h.answer(String("POST"), String("/v1/x:listen"), String("{}"))

    var c = String("/v1/") + _DOCS + ":commit"
    var w = h.answer(String("POST"), c, _commit(_upd("col", "d1", "")))
    assert_equal(w.status, 200)

    var body = (
        String('{"database":"') + _DB + '","documents":["' + _DOCS + '/col/d1","'
        + _DOCS + '/col/d2"]}'
    )
    var gets = mock.get_count()
    var got = h.answer(String("POST"), batch, body)
    assert_equal(got.status, 200)
    assert_true(got.body.startswith(String('[{"found":{"name":"') + _DOCS + "/col/d1"), got.body)
    assert_true(
        got.body.endswith(String('},{"missing":"') + _DOCS + '/col/d2"}]'), got.body
    )
    assert_equal(mock.get_count(), gets + 1, "one BatchGetDocuments, two names")

    # Under the fault EVERY request is a 503, and a batchGet is still counted.
    h.set_fault(True)
    var down = h.answer(String("POST"), batch, body)
    assert_equal(down.status, 503)
    assert_true(down.body.find(String('"status":"UNAVAILABLE"')) >= 0, down.body)
    assert_equal(mock.get_count(), gets + 2)
    assert_equal(h.answer(String("POST"), c, String("{}")).status, 503)
    h.set_fault(False)
    assert_equal(h.answer(String("POST"), batch, body).status, 200, "the fault clears")

    var bad = String('{"database":"') + _DB + '","documents":["nowhere/col/d1"]}'
    with assert_raises(contains="not a document name: nowhere/col/d1"):
        _ = h.answer(String("POST"), batch, bad)
    var no_id = String('{"database":"') + _DB + '","documents":["' + _DOCS + '/col"]}'
    with assert_raises(contains="not a document name"):
        _ = h.answer(String("POST"), batch, no_id)
    print("    [PASS] routing, faults and BatchGetDocuments")


# =============================================================================
# 2. Commit: one write only; delete with and without exists; an unsupported
#    write; the create, CAS and upsert preconditions; the one-shot refusal.
# =============================================================================
def test_commit_arms() raises:
    var mock = MockFirestore()
    var h = mock.share()
    var c = String("/v1/") + _DOCS + ":commit"

    with assert_raises(contains="one write per commit"):
        _ = h.answer(
            String("POST"), c,
            _commit(_upd("col", "a", "") + "," + _upd("col", "b", "")),
        )
    assert_equal(mock.count(String("a")), 0, "nothing of a refused commit is written")

    var gone = String('{"delete":"') + _DOCS + '/col/zz","currentDocument":{"exists":true}}'
    var r404 = h.answer(String("POST"), c, _commit(gone))
    assert_equal(r404.status, 404)
    assert_true(r404.body.find(String("NOT_FOUND")) >= 0)
    var blind = String('{"delete":"') + _DOCS + '/col/zz"}'
    assert_equal(
        h.answer(String("POST"), c, _commit(blind)).status, 200,
        "a delete with no precondition of a missing document succeeds",
    )

    var transform = (
        String('{"transform":{"document":"') + _DOCS + '/col/a","fieldTransforms":[]}}'
    )
    with assert_raises(contains="unsupported write"):
        _ = h.answer(String("POST"), c, _commit(transform))

    # A create, then the same create again.
    var create = _upd("col", "a", String('{"exists":false}'))
    var made = h.answer(String("POST"), c, _commit(create))
    assert_equal(made.status, 200)
    assert_true(made.body.find(String('"updateTime":"2026-10-01T00:00:01Z"')) >= 0, made.body)
    assert_equal(h.answer(String("POST"), c, _commit(create)).status, 409)

    # A CAS on a missing document, on a stale version, and on the current one.
    var cas_missing = _upd("col", "b", String('{"updateTime":"2026-10-01T00:00:01Z"}'))
    assert_equal(h.answer(String("POST"), c, _commit(cas_missing)).status, 404)
    var stale = _upd("col", "a", String('{"updateTime":"2026-10-01T00:00:09Z"}'))
    var r400 = h.answer(String("POST"), c, _commit(stale))
    assert_equal(r400.status, 400)
    assert_true(r400.body.find(String("FAILED_PRECONDITION")) >= 0)
    var stale_nanos = _upd(
        "col", "a", String('{"updateTime":"2026-10-01T00:00:01.5Z"}')
    )
    assert_equal(
        h.answer(String("POST"), c, _commit(stale_nanos)).status, 400,
        "the nanos are compared too",
    )
    var fresh = _upd("col", "a", String('{"updateTime":"2026-10-01T00:00:01Z"}'))
    var ok = h.answer(String("POST"), c, _commit(fresh))
    assert_equal(ok.status, 200)
    assert_true(ok.body.find(String("2026-10-01T00:00:02Z")) >= 0, "a fresh updateTime")

    # The same id in another collection is another document.
    _ = h.answer(String("POST"), c, _commit(_upd("other", "a", "")))
    assert_equal(mock.count(String("a")), 2)

    # The one-shot refusal answers once, writes nothing, and clears.
    h.fail_next_commit(418, String('{"x":1}'))
    var refused = h.answer(String("POST"), c, _commit(_upd("col", "c", "")))
    assert_equal(refused.status, 418)
    assert_equal(refused.body, String('{"x":1}'))
    assert_equal(mock.count(String("c")), 0)
    assert_equal(h.answer(String("POST"), c, _commit(_upd("col", "c", ""))).status, 200)
    assert_equal(mock.count(String("c")), 1)
    print("    [PASS] every Commit arm")


# =============================================================================
# 3. RunQuery: the collection, every operator, every value type, the ordering
#    rules, the limit, and the request log.
# =============================================================================
def _fields(
    n: Int, s: String, var extra_keys: List[String], var extra_vals: List[FsValue]
) -> FsValue:
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("n"))
    vals.append(FsValue.integer(String(n)))
    keys.append(String("s"))
    vals.append(FsValue.string(String(s)))
    for i in range(len(extra_keys)):
        keys.append(String(extra_keys[i]))
        vals.append(extra_vals[i].copy())
    return FsValue.map_of(keys^, vals^)


def _q(where: String) -> String:
    return String('{"from":[{"collectionId":"q"}],"where":') + where + "}"


def _ff(field: String, op: String, value: String) -> String:
    return (
        String('{"fieldFilter":{"field":{"fieldPath":"') + field + '"},"op":"' + op
        + '","value":' + value + "}}"
    )


def _ord(field: String, dir: String) -> String:
    return (
        String('{"from":[{"collectionId":"q"}],"orderBy":[{"field":{"fieldPath":"')
        + field + '"},"direction":"' + dir + '"}]}'
    )


def test_run_query_arms() raises:
    var mock = MockFirestore()
    var client = _client(mock)
    var k1 = List[String]()
    var v1 = List[FsValue]()
    k1.append(String("b"))
    v1.append(FsValue.boolean(True))
    k1.append(String("t"))
    v1.append(FsValue.timestamp(String("2026-10-02T00:00:00Z")))
    k1.append(String("f"))
    v1.append(FsValue.double(1.5))
    var arr1 = List[FsValue]()
    arr1.append(FsValue.string(String("x")))
    arr1.append(FsValue.string(String("y")))
    k1.append(String("arr"))
    v1.append(FsValue.array_of(arr1^))
    k1.append(String("m"))
    v1.append(FsValue.null())
    _ = client.patch_document(String("q"), String("d1"), _fields(3, "b", k1^, v1^))
    var k2 = List[String]()
    var v2 = List[FsValue]()
    k2.append(String("b"))
    v2.append(FsValue.boolean(False))
    k2.append(String("m"))
    v2.append(FsValue.null())
    _ = client.patch_document(String("q"), String("d2"), _fields(1, "c", k2^, v2^))
    var k3 = List[String]()
    var v3 = List[FsValue]()
    k3.append(String("m"))
    v3.append(FsValue.string(String("k")))
    _ = client.patch_document(String("q"), String("d3"), _fields(2, "a", k3^, v3^))
    _ = client.patch_document(
        String("p"), String("e1"), _fields(0, "a", List[String](), List[FsValue]())
    )

    var before = mock.run_query_count()
    assert_equal(
        _ids(client.run_query(String('{"from":[{"collectionId":"q"}]}'))),
        String("d1d2d3"),
        "only the `from` collection",
    )
    assert_equal(mock.run_query_count(), before + 1)
    assert_true(
        mock.run_query_body(before).find(String('"collectionId":"q"')) >= 0,
        mock.run_query_body(before),
    )

    # Integers compare numerically, strings by text; each operator.
    var two = String('{"integerValue":"2"}')
    assert_equal(_ids(client.run_query(_q(_ff("n", "LESS_THAN_OR_EQUAL", two)))), String("d2d3"))
    assert_equal(_ids(client.run_query(_q(_ff("n", "GREATER_THAN", two)))), String("d1"))
    assert_equal(_ids(client.run_query(_q(_ff("n", "GREATER_THAN_OR_EQUAL", two)))), String("d1d3"))
    assert_equal(
        _ids(client.run_query(_q(_ff("n", "LESS_THAN", String('{"integerValue":"10"}'))))),
        String("d1d2d3"),
        "numeric, not text (10 > 3)",
    )
    var b = String('{"stringValue":"b"}')
    assert_equal(_ids(client.run_query(_q(_ff("s", "LESS_THAN", b)))), String("d3"))
    assert_equal(_ids(client.run_query(_q(_ff("s", "GREATER_THAN", b)))), String("d2"))
    assert_equal(_ids(client.run_query(_q(_ff("s", "GREATER_THAN_OR_EQUAL", b)))), String("d1d2"))
    assert_equal(_ids(client.run_query(_q(_ff("s", "LESS_THAN_OR_EQUAL", b)))), String("d1d3"))
    # A range never matches a null or absent field, nor a null bound.
    assert_equal(
        _ids(client.run_query(_q(_ff("m", "GREATER_THAN", String('{"stringValue":""}'))))),
        String("d3"),
    )
    assert_equal(
        _ids(client.run_query(_q(_ff("n", "LESS_THAN", String('{"nullValue":null}'))))),
        String(""),
    )
    # A timestamp range against a timestamp bound (the service compares only
    # values of one type): only the document carrying the field, and only
    # when its value is below the bound.
    assert_equal(
        _ids(client.run_query(_q(_ff("t", "LESS_THAN",
            String('{"timestampValue":"2026-10-03T00:00:00Z"}'))))),
        String("d1"),
        "only the document carrying the field",
    )
    assert_equal(
        _ids(client.run_query(_q(_ff("t", "LESS_THAN",
            String('{"timestampValue":"2026-10-01T00:00:00Z"}'))))),
        String(""),
        "a timestamp above the bound",
    )

    # The value types the filter reads as text.
    assert_equal(
        _ids(client.run_query(_q(_ff("b", "EQUAL", String('{"booleanValue":true}'))))),
        String("d1"),
    )
    assert_equal(
        _ids(client.run_query(_q(_ff("b", "EQUAL", String('{"booleanValue":false}'))))),
        String("d2"),
    )
    assert_equal(
        _ids(client.run_query(_q(_ff("t", "EQUAL",
            String('{"timestampValue":"2026-10-02T00:00:00Z"}'))))),
        String("d1"),
    )
    assert_equal(
        _ids(client.run_query(_q(_ff("f", "EQUAL", String('{"doubleValue":1.5}'))))),
        String("d1"),
    )
    assert_equal(
        _ids(client.run_query(_q(_ff("f", "EQUAL", String('{"doubleValue":2.5}'))))),
        String(""),
    )

    # ARRAY_CONTAINS: an element of an array field; never a scalar field.
    var y = String('{"stringValue":"y"}')
    assert_equal(_ids(client.run_query(_q(_ff("arr", "ARRAY_CONTAINS", y)))), String("d1"))
    assert_equal(
        _ids(client.run_query(_q(_ff("arr", "ARRAY_CONTAINS", String('{"stringValue":"q"}'))))),
        String(""),
    )
    assert_equal(
        _ids(client.run_query(_q(_ff("s", "ARRAY_CONTAINS", String('{"stringValue":"a"}'))))),
        String(""),
        "a scalar field is not an array",
    )
    assert_equal(
        _ids(client.run_query(_q(_ff("missing", "ARRAY_CONTAINS", y)))), String("")
    )

    # An operator the double does not model fails closed (matches nothing).
    # Driven with NOT_IN over every value present, so empty is also what the
    # service answers.
    assert_equal(
        _ids(client.run_query(_q(_ff("n", "NOT_IN", String('{"arrayValue":{"values":['
            '{"integerValue":"1"},{"integerValue":"2"},{"integerValue":"3"}]}}'))))),
        String(""),
    )
    assert_equal(
        _ids(client.run_query(_q(String('{"unaryFilter":{"field":{"fieldPath":"n"},"op":"IS_NAN"}}')))),
        String(""),
    )
    assert_equal(
        _ids(client.run_query(_q(String("{}")))), String("d1d2d3"), "an empty filter is no filter"
    )

    # Ordering: integers numerically, strings by text, nulls first.
    assert_equal(_ids(client.run_query(_ord("n", "ASCENDING"))), String("d2d3d1"))
    assert_equal(_ids(client.run_query(_ord("n", "DESCENDING"))), String("d1d3d2"))
    assert_equal(_ids(client.run_query(_ord("s", "ASCENDING"))), String("d3d1d2"))
    assert_equal(_ids(client.run_query(_ord("s", "DESCENDING"))), String("d2d1d3"))
    assert_equal(_ids(client.run_query(_ord("m", "ASCENDING"))), String("d1d2d3"), "nulls first")
    # Descending puts the nulls last. d1 and d2 tie (both null); the service
    # breaks a tie by document name, the double by insertion order, so the
    # order within the tie is not pinned.
    var m_desc = _ids(client.run_query(_ord("m", "DESCENDING")))
    assert_true(
        m_desc == String("d3d1d2") or m_desc == String("d3d2d1"),
        String("nulls last: ") + m_desc,
    )
    assert_equal(_ids(client.run_query(_ord("t", "ASCENDING"))), String("d1"))

    # The limit cuts the ordered result.
    assert_equal(
        _ids(client.run_query(String('{"from":[{"collectionId":"q"}],"orderBy":[{"field":'
            '{"fieldPath":"n"}}],"limit":2}'))),
        String("d2d3"),
    )
    assert_equal(
        _ids(client.run_query(String('{"from":[{"collectionId":"q"}],"limit":5}'))),
        String("d1d2d3"),
        "a limit above the count cuts nothing",
    )
    print("    [PASS] every RunQuery arm")


def main() raises:
    test_routing_faults_and_batch_get()
    test_commit_arms()
    test_run_query_arms()
    print("PASS test_mock_firestore")
