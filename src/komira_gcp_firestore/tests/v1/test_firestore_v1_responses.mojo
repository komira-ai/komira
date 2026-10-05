# The responses the generated `FirestoreClient` (komira_gcp_firestore_v1)
# decodes, each a body written here by hand from the Cloud Firestore v1 REST
# reference (no upstream test body is copied), served through komira_http_core's
# ScriptedConnector (no socket).
#
# `batchGet` and `runQuery` are server-streaming methods: over REST each
# answers with ONE body, a JSON array of responses in stream order, which the
# client returns as a List. `commit` is unary. A document's `fields` is a map
# of `Value`s, a oneof whose arms are spelled as the reference spells them:
# `integerValue` a decimal STRING (proto3 JSON int64), `bytesValue` base64,
# `timestampValue` RFC 3339, `nullValue` JSON null, `geoPointValue` an object,
# `arrayValue` / `mapValue` nested.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_firestore_v1.document import Value
from komira_gcp_firestore_v1.firestore import (
    BatchGetDocumentsRequest,
    BatchGetDocumentsResponse,
    CommitRequest,
    CommitResponse,
    FirestoreClient,
    RunQueryRequest,
    RunQueryResponse,
)
from komira_gcp_firestore_v1.write import Write
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_wkt import Timestamp


comptime _DB = "projects/demo-project/databases/(default)"
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


def _client(answer: String) raises -> _Client:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var stream = ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(stream^)
        ),
        StaticTokenSource(String("t")),
    )
    c.set_rest_host(String("firestore.googleapis.com"))
    return c^


def _batch_get(answer: String) raises -> List[BatchGetDocumentsResponse]:
    var c = _client(answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    return c.batch_get_documents[_RT](
        BatchGetDocumentsRequest(
            String(_DB), List[String](), None, None, 0, None, None, None
        ),
        reactor,
    )


def _run_query(answer: String) raises -> List[RunQueryResponse]:
    var c = _client(answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    return c.run_query[_RT](
        RunQueryRequest(
            String(_DB) + "/documents", None, None, 0, None, 0, None, None, None
        ),
        reactor,
    )


def _commit(answer: String) raises -> CommitResponse:
    var c = _client(answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    return c.commit[_RT](
        CommitRequest(String(_DB), List[Write](), List[UInt8](), None), reactor
    )


comptime _EVERY_ARM = (
    '{"n":{"nullValue":null},'
    + '"b":{"booleanValue":true},'
    + '"i":{"integerValue":"-9223372036854775808"},'
    + '"d":{"doubleValue":2.5},'
    + '"t":{"timestampValue":"2026-09-02T10:00:00.123456Z"},'
    + '"s":{"stringValue":"caf\\u00e9 \\"q\\""},'
    + '"y":{"bytesValue":"AAEC/w=="},'
    + '"r":{"referenceValue":"projects/demo-project/databases/(default)/documents/c/x"},'
    + '"g":{"geoPointValue":{"latitude":51.5,"longitude":-0.125}},'
    + '"a":{"arrayValue":{"values":[{"integerValue":"1"},{"stringValue":"two"}]}},'
    + '"e":{"arrayValue":{}},'
    + '"m":{"mapValue":{"fields":{"inner":{"mapValue":{"fields":{"k":{"booleanValue":false}}}}}}}}'
)


def _arm(fields: Dict[String, Value], key: String) raises -> Value:
    return fields[key].copy()


def test_batch_get_found_and_missing() raises:
    var answer = (
        String('[{"found":{"name":"') + _DB + '/documents/c/a","fields":'
        + _EVERY_ARM
        + ',"createTime":"2026-09-01T00:00:00Z",'
        + '"updateTime":"2026-09-02T10:00:00.5Z"},'
        + '"readTime":"2026-09-03T00:00:00Z","futureField":{"x":1}},'
        + '{"missing":"' + _DB + '/documents/c/b",'
        + '"readTime":"2026-09-03T00:00:00Z"}]'
    )
    var got = _batch_get(answer)
    assert_equal(len(got), 2)
    # First: the document, every Value arm.
    assert_equal(got[0]._oneof0_case, 1)
    var doc = got[0].found.value().copy()
    assert_equal(doc.name, String(_DB) + "/documents/c/a")
    assert_equal(doc.update_time.value().seconds, Int64(1788343200))
    assert_equal(doc.update_time.value().nanos, Int32(500000000))
    assert_equal(doc.create_time.value().seconds, Int64(1788220800))
    var f = doc.fields.copy()
    assert_equal(len(f), 12)
    assert_equal(_arm(f, "n")._oneof0_case, 1)
    assert_equal(_arm(f, "b")._oneof0_case, 2)
    assert_true(_arm(f, "b").boolean_value.value())
    assert_equal(_arm(f, "i")._oneof0_case, 3)
    assert_equal(_arm(f, "i").integer_value.value(), Int64.MIN)
    assert_equal(_arm(f, "d")._oneof0_case, 4)
    assert_equal(_arm(f, "d").double_value.value(), 2.5)
    assert_equal(_arm(f, "t")._oneof0_case, 5)
    assert_equal(_arm(f, "t").timestamp_value.value().nanos, Int32(123456000))
    assert_equal(_arm(f, "s")._oneof0_case, 6)
    assert_equal(_arm(f, "s").string_value.value(), String('café "q"'))
    assert_equal(_arm(f, "y")._oneof0_case, 7)
    var y = _arm(f, "y").bytes_value.value().copy()
    assert_equal(len(y), 4)
    assert_equal(Int(y[3]), 255)
    assert_equal(_arm(f, "r")._oneof0_case, 8)
    assert_equal(_arm(f, "g")._oneof0_case, 9)
    assert_equal(_arm(f, "g").geo_point_value.value().longitude, -0.125)
    assert_equal(_arm(f, "a")._oneof0_case, 10)
    var arr = _arm(f, "a").array_value[0].values.copy()
    assert_equal(len(arr), 2)
    assert_equal(arr[0].integer_value.value(), Int64(1))
    assert_equal(arr[1].string_value.value(), String("two"))
    # An empty array is still the array arm.
    assert_equal(_arm(f, "e")._oneof0_case, 10)
    assert_equal(len(_arm(f, "e").array_value[0].values), 0)
    assert_equal(_arm(f, "m")._oneof0_case, 11)
    var inner = _arm(f, "m").map_value[0].fields[String("inner")].copy()
    assert_equal(inner._oneof0_case, 11)
    assert_false(inner.map_value[0].fields[String("k")].boolean_value.value())
    # Second: the name of a document that does not exist.
    assert_equal(got[1]._oneof0_case, 2)
    assert_equal(got[1].missing.value(), String(_DB) + "/documents/c/b")


def test_run_query_documents_and_markers() raises:
    # A partial-progress element (readTime only), one document, then the
    # stream's end marker.
    var answer = (
        String('[{"readTime":"2026-09-03T00:00:00Z"},')
        + '{"document":{"name":"' + _DB + '/documents/c/a",'
        + '"fields":{"v":{"stringValue":"x"}},'
        + '"updateTime":"2026-09-02T10:00:00Z"},'
        + '"readTime":"2026-09-03T00:00:00Z","skippedResults":0},'
        + '{"readTime":"2026-09-03T00:00:00Z","done":true}]'
    )
    var got = _run_query(answer)
    assert_equal(len(got), 3)
    assert_false(Bool(got[0].document))
    assert_equal(got[0].read_time.value().seconds, Int64(1788393600))
    assert_true(Bool(got[1].document))
    assert_equal(
        got[1].document.value().fields[String("v")].string_value.value(),
        String("x"),
    )
    assert_equal(got[2]._oneof0_case, 1)
    assert_true(got[2].done.value())


def test_run_query_empty_stream() raises:
    assert_equal(len(_run_query(String("[]"))), 0)


def test_commit_write_results() raises:
    var got = _commit(
        String(
            '{"writeResults":[{"updateTime":"2026-09-02T10:00:00.25Z"},{}],'
            + '"commitTime":"2026-09-02T10:00:00.25Z"}'
        )
    )
    assert_equal(len(got.write_results), 2)
    assert_equal(got.write_results[0].update_time.value().nanos, Int32(250000000))
    # A delete's result carries no update time.
    assert_false(Bool(got.write_results[1].update_time))
    assert_equal(got.commit_time.value().seconds, Int64(1788343200))


def main() raises:
    test_batch_get_found_and_missing()
    test_run_query_documents_and_markers()
    test_run_query_empty_stream()
    test_commit_write_results()
    print("OK")
