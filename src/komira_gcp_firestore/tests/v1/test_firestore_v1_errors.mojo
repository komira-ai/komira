# How the generated `FirestoreClient` (komira_gcp_firestore_v1) fails, and
# where its bearer token comes from, through komira_http_core's
# ScriptedConnector (no socket).
#
#   - A non-2xx answer raises through komira_gcp_core's `gcp_status_error`:
#     the verb, the method, the HTTP status and the google.rpc.Code, never a
#     byte of the body (an `error.message` names resources).
#   - A streamed method that fails AFTER its 200 ends the JSON array with an
#     `{"error": ...}` element; it raises the same way, with the code the
#     element names.
#   - A 200 whose streamed body is not a JSON array is refused by its size.
#   - Each request asks the token source once and sends one `Bearer`; a
#     source with no token stops the request before anything is dialled.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import (
    CODE_ABORTED,
    CODE_ALREADY_EXISTS,
    CODE_FAILED_PRECONDITION,
    CODE_NOT_FOUND,
    GcpTokenSource,
    StaticTokenSource,
    gcp_status_error,
    gcp_status_error_code,
)
from komira_gcp_firestore_v1.firestore import (
    BatchGetDocumentsRequest,
    CommitRequest,
    FirestoreClient,
    RunQueryRequest,
)
from komira_gcp_firestore_v1.write import Write
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _DB = "projects/demo-project/databases/(default)"
comptime _RT = BlockingRuntime[NoopSink]


struct CountingTokenSource(GcpTokenSource, Movable, Deinitable):
    """Hands out `token-1`, `token-2`, ... and counts the calls in a cell
    the test keeps."""

    var calls: ArcPointer[Int]

    def __init__(out self, calls: ArcPointer[Int]):
        self.calls = calls

    def access_token(mut self) raises -> String:
        self.calls[] += 1
        return String("token-") + String(self.calls[])


struct FailingTokenSource(GcpTokenSource, Movable, Deinitable):
    """A source with no credential to give."""

    def __init__(out self):
        pass

    def access_token(mut self) raises -> String:
        raise Error("no credential available")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status_line: String, body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(
    status_line: String, body: String
) raises -> FirestoreClient[ScriptedConnector, StaticTokenSource]:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = FirestoreClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(
                    _answer(status_line, body), capture
                )
            )
        ),
        StaticTokenSource(String("t")),
    )
    c.set_rest_host(String("firestore.googleapis.com"))
    return c^


def _commit_req() -> CommitRequest:
    return CommitRequest(String(_DB), List[Write](), List[UInt8](), None)


def _query_req() -> RunQueryRequest:
    return RunQueryRequest(
        String(_DB) + "/documents", None, None, 0, None, 0, None, None, None
    )


def _commit_error(status_line: String, body: String) -> String:
    try:
        var c = _client(status_line, body)
        var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        _ = c.commit[_RT](_commit_req(), reactor)
    except e:
        return String(e)
    return String("")


def _query_error(status_line: String, body: String) -> String:
    try:
        var c = _client(status_line, body)
        var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        _ = c.run_query[_RT](_query_req(), reactor)
    except e:
        return String(e)
    return String("")


def test_conflict_is_the_status_error_with_its_code() raises:
    var body = String(
        '{"error":{"code":409,"message":"Document already exists: '
        + _DB + '/documents/secret/doc","status":"ALREADY_EXISTS"}}'
    )
    var err = _commit_error(String("409 Conflict"), body)
    assert_equal(
        err,
        String(gcp_status_error(String("POST"), String("Commit"), 409, _bytes(body))),
    )
    assert_false(String("secret") in err, err)
    assert_equal(
        gcp_status_error_code(String("POST"), String("Commit"), err),
        CODE_ALREADY_EXISTS,
    )


def test_failed_precondition_and_absent_database() raises:
    var cas = _commit_error(
        String("400 Bad Request"),
        String('{"error":{"code":400,"status":"FAILED_PRECONDITION"}}'),
    )
    assert_equal(
        gcp_status_error_code(String("POST"), String("Commit"), cas),
        CODE_FAILED_PRECONDITION,
    )
    # A query against a database that does not exist: NOT_FOUND on a method
    # that never answers NOT_FOUND for a document.
    var absent = _query_error(
        String("404 Not Found"),
        String('{"error":{"code":404,"message":"The database x does not exist","status":"NOT_FOUND"}}'),
    )
    assert_equal(
        gcp_status_error_code(String("POST"), String("RunQuery"), absent),
        CODE_NOT_FOUND,
    )
    assert_false(String("does not exist") in absent, absent)


def test_an_error_after_the_stream_started() raises:
    var err = _query_error(
        String("200 OK"),
        String(
            '[{"readTime":"2026-09-03T00:00:00Z"},'
            + '{"error":{"code":409,"status":"ABORTED","message":"secret"}}]'
        ),
    )
    assert_true(err.startswith("POST RunQuery: HTTP 200, ABORTED (code 10)"), err)
    assert_false(String("secret") in err, err)
    assert_equal(
        gcp_status_error_code(String("POST"), String("RunQuery"), err),
        CODE_ABORTED,
    )


def test_a_stream_body_that_is_not_an_array() raises:
    var err = _query_error(String("200 OK"), String('{"document":"secret"}'))
    assert_true(String("is not a JSON array") in err, err)
    assert_false(String("secret") in err, err)


def _authorization_lines(wire: String) -> List[String]:
    var out = List[String]()
    var lines = wire.split("\r\n")
    for i in range(len(lines)):
        if String(lines[i]).startswith("authorization:"):
            out.append(String(lines[i]))
    return out^


def test_each_request_asks_the_source() raises:
    var calls = ArcPointer[Int](0)
    var first = ArcPointer[List[UInt8]](List[UInt8]())
    var second = ArcPointer[List[UInt8]](List[UInt8]())
    var ok = _answer(String("200 OK"), String('{"writeResults":[]}'))
    var connector = ScriptedConnector.with_stream_tls(
        ScriptedStream.from_read_script_with_capture(ok.copy(), first)
    )
    connector.arm_next(ScriptedStream.from_read_script_with_capture(ok^, second))
    var c = FirestoreClient[ScriptedConnector, CountingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(connector^),
        CountingTokenSource(calls),
    )
    c.set_rest_host(String("firestore.googleapis.com"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.commit[_RT](_commit_req(), reactor)
    assert_equal(calls[], 1)
    _ = c.commit[_RT](_commit_req(), reactor)
    assert_equal(calls[], 2)
    var a1 = _authorization_lines(String(unsafe_from_utf8=Span(first[])))
    var a2 = _authorization_lines(String(unsafe_from_utf8=Span(second[])))
    assert_equal(len(a1), 1)
    assert_equal(a1[0], "authorization: Bearer token-1")
    assert_equal(len(a2), 1)
    assert_equal(a2[0], "authorization: Bearer token-2")
    assert_equal(c._client._connector.connect_call_count(), 2)
    assert_equal(c._client._connector.dial_host_at(0), "firestore.googleapis.com")


def test_no_token_no_request() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = FirestoreClient[ScriptedConnector, FailingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(
                    _answer(String("200 OK"), String("[]")), capture
                )
            )
        ),
        FailingTokenSource(),
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = c.batch_get_documents[_RT](
            BatchGetDocumentsRequest(
                String(_DB), List[String](), None, None, 0, None, None, None
            ),
            reactor,
        )
    except e:
        raised = String(e)
    assert_equal(raised, "no credential available")
    assert_equal(c._client._connector.connect_call_count(), 0)
    assert_equal(len(capture[]), 0)


def test_an_emulator_endpoint_is_plaintext_on_its_port() raises:
    # `set_rest_endpoint` with `plaintext`: an `http` URL to host:port, over
    # a plaintext connector (a TLS-claiming one would be refused).
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = FirestoreClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream(
                ScriptedStream.from_read_script_with_capture(
                    _answer(String("200 OK"), String('{"writeResults":[]}')), capture
                )
            )
        ),
        StaticTokenSource(String("owner")),
    )
    c.set_rest_endpoint(String("127.0.0.1"), UInt16(8080), True)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.commit[_RT](_commit_req(), reactor)
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(
        wire.startswith(
            "POST /v1/projects/demo-project/databases/%28default%29/documents:commit HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8080\r\n"
        ),
        wire,
    )
    assert_equal(c._client._connector.dial_host_at(0), "127.0.0.1")


def main() raises:
    test_conflict_is_the_status_error_with_its_code()
    test_failed_precondition_and_absent_database()
    test_an_error_after_the_stream_started()
    test_a_stream_body_that_is_not_an_array()
    test_each_request_asks_the_source()
    test_no_token_no_request()
    test_an_emulator_endpoint_is_plaintext_on_its_port()
    print("OK")
