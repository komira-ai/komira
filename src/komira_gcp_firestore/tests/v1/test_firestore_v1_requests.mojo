# The requests the generated `FirestoreClient` (komira_gcp_firestore_v1) puts
# on the wire, through komira_http_core's ScriptedConnector with a shared
# write capture: the request line, the Host, the headers and the JSON body.
# No socket, no network.
#
# The expected forms are written here from the Cloud Firestore v1 REST
# reference: `projects.databases.documents.commit` (POST
# /v1/{database}/documents:commit), `batchGet` (POST
# /v1/{database}/documents:batchGet) and `runQuery` (POST
# /v1/{parent}:runQuery), each a JSON body whose keys are the fields' JSON
# names. The database id `(default)` is one path segment of `{database}`,
# and its parentheses are percent-encoded there (RFC 3986 sub-delims, which
# the generated path expansion encodes); the service reads `%28default%29`
# as `(default)`.
#
# Two parts of the bodies are NOT from the reference: the default-valued
# keys komira_proto_codec's JsonEncoder writes today (`"transaction":""`,
# `"updateTransforms":[]`), as test_logging_requests explains for Cloud
# Logging. The API reads each as unset.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_firestore_v1.common import Precondition
from komira_gcp_firestore_v1.document import Document, Value
from komira_gcp_firestore_v1.firestore import (
    BatchGetDocumentsRequest,
    CommitRequest,
    FirestoreClient,
    RunQueryRequest,
)
from komira_gcp_firestore_v1.query import StructuredQuery
from komira_gcp_firestore_v1.write import DocumentTransform_FieldTransform, Write
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json, encode_json
from komira_wkt import Timestamp


comptime _HOST = "firestore.googleapis.com"
comptime _DB = "projects/demo-project/databases/(default)"
comptime _DB_PATH = "/v1/projects/demo-project/databases/%28default%29"
comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = FirestoreClient[ScriptedConnector, StaticTokenSource]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(capture: ArcPointer[List[UInt8]], answer: String) raises -> _Client:
    var stream = ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(stream^)
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String(_HOST))
    return c^


def _expected(path: String, body: String) -> String:
    return (
        String("POST ")
        + path
        + " HTTP/1.1\r\n"
        + "Host: firestore.googleapis.com\r\n"
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\n"
        + "authorization: Bearer test-access-token\r\n"
        + "content-type: application/json\r\n"
        + "\r\n"
        + body
    )


def _string_value(s: String) raises -> Value:
    var v = decode_json[Value](String('{"stringValue":"x"}'))
    v.string_value = s.copy()
    return v^


def _document(name: String) raises -> Document:
    var fields = Dict[String, Value]()
    fields[String("value")] = _string_value(String("v"))
    return Document(name.copy(), fields^, None, None)


def _update(name: String, var precondition: Optional[Precondition]) raises -> Write:
    return Write(
        None,
        List[DocumentTransform_FieldTransform](),
        precondition^,
        1,
        _document(name),
        None,
        None,
    )


def test_commit_create_if_absent() raises:
    # One `update` write that must not overwrite: `currentDocument.exists`
    # false, the conditional create.
    var name = String(_DB) + "/documents/items/a"
    var cond = Precondition(1, False, None)
    var writes = List[Write]()
    writes.append(_update(name, cond^))
    var req = CommitRequest(String(_DB), writes^, List[UInt8](), None)
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String('{"writeResults":[{}],"commitTime":"2026-09-02T10:00:00Z"}'))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.commit[_RT](req, reactor)
    var body = String(
        '{"database":"projects/demo-project/databases/(default)",'
        + '"writes":[{"updateTransforms":[],"currentDocument":{"exists":false},'
        + '"update":{"name":"projects/demo-project/databases/(default)/documents/items/a",'
        + '"fields":{"value":{"stringValue":"v"}}}}],"transaction":""}'
    )
    assert_equal(
        String(unsafe_from_utf8=Span(capture[])),
        _expected(String(_DB_PATH) + "/documents:commit", body),
    )


def test_commit_update_time_precondition_and_delete() raises:
    # The version CAS (`currentDocument.updateTime`) and a delete, in one
    # commit: the timestamp is RFC 3339 with the shortest exact fraction.
    var name = String(_DB) + "/documents/items/a"
    var cond = Precondition(2, None, Timestamp(Int64(1788343200), Int32(123456000)))
    var writes = List[Write]()
    writes.append(_update(name, cond^))
    var del_ = _update(name, None)
    del_._oneof0_case = 2
    del_.update = None
    del_.delete = String(_DB) + "/documents/items/b"
    writes.append(del_^)
    var req = CommitRequest(String(_DB), writes^, List[UInt8](), None)
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String('{"writeResults":[{},{}]}'))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.commit[_RT](req, reactor)
    var body = String(
        '{"database":"projects/demo-project/databases/(default)",'
        + '"writes":[{"updateTransforms":[],'
        + '"currentDocument":{"updateTime":"2026-09-02T10:00:00.123456Z"},'
        + '"update":{"name":"projects/demo-project/databases/(default)/documents/items/a",'
        + '"fields":{"value":{"stringValue":"v"}}}},'
        + '{"updateTransforms":[],'
        + '"delete":"projects/demo-project/databases/(default)/documents/items/b"}],'
        + '"transaction":""}'
    )
    assert_equal(
        String(unsafe_from_utf8=Span(capture[])),
        _expected(String(_DB_PATH) + "/documents:commit", body),
    )


def test_batch_get_names_the_documents() raises:
    var docs = List[String]()
    docs.append(String(_DB) + "/documents/items/a")
    docs.append(String(_DB) + "/documents/items/b")
    var req = BatchGetDocumentsRequest(
        String(_DB), docs^, None, None, 0, None, None, None
    )
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String("[]"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.batch_get_documents[_RT](req, reactor)
    assert_equal(len(got), 0)
    var body = String(
        '{"database":"projects/demo-project/databases/(default)",'
        + '"documents":["projects/demo-project/databases/(default)/documents/items/a",'
        + '"projects/demo-project/databases/(default)/documents/items/b"]}'
    )
    assert_equal(
        String(unsafe_from_utf8=Span(capture[])),
        _expected(String(_DB_PATH) + "/documents:batchGet", body),
    )


def test_run_query_posts_the_structured_query() raises:
    # The query a store sends: one collection, one equality filter, a limit.
    var q_text = String(
        '{"from":[{"collectionId":"items"}],'
        + '"where":{"fieldFilter":{"field":{"fieldPath":"state"},'
        + '"op":"EQUAL","value":{"stringValue":"live"}}},'
        + '"limit":10}'
    )
    var q = decode_json[StructuredQuery](q_text)
    var req = RunQueryRequest(
        String(_DB) + "/documents", None, None, 1, q^, 0, None, None, None
    )
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String('[{"readTime":"2026-09-02T10:00:00Z"}]'))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.run_query[_RT](req, reactor)
    assert_equal(len(got), 1)
    var wire = String(unsafe_from_utf8=Span(capture[]))
    var head = String(
        "POST " + String(_DB_PATH) + "/documents:runQuery HTTP/1.1\r\n"
        + "Host: firestore.googleapis.com\r\n"
    )
    assert_true(wire.startswith(head), wire)
    assert_true(String("authorization: Bearer test-access-token\r\n") in wire)
    var at = wire.find("\r\n\r\n")
    var body = String(unsafe_from_utf8=wire.as_bytes()[at + 4 :])
    assert_true(
        body.startswith(
            '{"parent":"projects/demo-project/databases/(default)/documents",'
        ),
        body,
    )
    # The query the body carries is the one that was set, read back
    # strictly (an unknown key would raise).
    var back = decode_json[RunQueryRequest](body)
    assert_equal(back._oneof0_case, 1)
    assert_equal(
        encode_json(back.structured_query.value()), encode_json(req.structured_query.value())
    )
    assert_true(String('"collectionId":"items"') in body)
    assert_true(String('"op":"EQUAL"') in body)
    assert_true(String('"limit":10') in body)


def main() raises:
    test_commit_create_if_absent()
    test_commit_update_time_precondition_and_delete()
    test_batch_get_names_the_documents()
    test_run_query_posts_the_structured_query()
    print("OK")
