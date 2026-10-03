# The generated client's one credential hook: each request asks its
# komira_gcp_core `GcpTokenSource` for a token and sends it as
# `Authorization: Bearer <token>`. The client holds no credential of its
# own and caches nothing: a second request asks again, so a source that
# refreshes (komira_gcp_core's CachingTokenSource) is what decides when a
# token changes. A source that cannot give a token stops the request
# before anything is dialled.
#
# The connector is komira_http_core's ScriptedConnector with one shared
# write capture per dial (komira_http's h1 path dials once per request
# here, as every answer closes its connection); no socket is used.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import GcpTokenSource
from komira_gcp_logging.logging import (
    ListLogEntriesRequest,
    LoggingServiceV2Client,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


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


def _ok() -> List[UInt8]:
    var body = String('{"entries":[]}')
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _req() -> ListLogEntriesRequest:
    var names = List[String]()
    names.append(String("projects/demo-project"))
    return ListLogEntriesRequest(
        names^, String(""), String("timestamp asc"), Int32(10), String("")
    )


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
    var connector = ScriptedConnector.with_stream_tls(
        ScriptedStream.from_read_script_with_capture(_ok(), first)
    )
    connector.arm_next(ScriptedStream.from_read_script_with_capture(_ok(), second))
    var c = LoggingServiceV2Client[ScriptedConnector, CountingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(connector^),
        CountingTokenSource(calls),
    )
    c.set_rest_host(String("logging.googleapis.com"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    _ = c.list_log_entries[_RT](_req(), reactor)
    assert_equal(calls[], 1)
    _ = c.list_log_entries[_RT](_req(), reactor)
    assert_equal(calls[], 2)

    # One Authorization header per request, the bare token behind one
    # `Bearer ` (the source returns no prefix; the client adds exactly one).
    var a1 = _authorization_lines(String(unsafe_from_utf8=Span(first[])))
    var a2 = _authorization_lines(String(unsafe_from_utf8=Span(second[])))
    assert_equal(len(a1), 1)
    assert_equal(a1[0], "authorization: Bearer token-1")
    assert_equal(len(a2), 1)
    assert_equal(a2[0], "authorization: Bearer token-2")
    # Two requests, two dials, each for the host that was set: the count
    # the no-token case below expects to stay at 0.
    assert_equal(c._client._connector.connect_call_count(), 2)
    assert_equal(c._client._connector.dial_hosts_len(), 2)
    assert_equal(c._client._connector.dial_host_at(0), "logging.googleapis.com")


def test_no_token_no_request() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = LoggingServiceV2Client[ScriptedConnector, FailingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(), capture)
            )
        ),
        FailingTokenSource(),
    )
    c.set_rest_host(String("logging.googleapis.com"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = c.list_log_entries[_RT](_req(), reactor)
    except e:
        raised = String(e)
    assert_equal(raised, "no credential available")
    # Nothing dialled, not only nothing written: a client that connected and
    # failed before its first write would leave the capture empty too.
    assert_equal(c._client._connector.connect_call_count(), 0)
    assert_equal(c._client._connector.dial_hosts_len(), 0)
    assert_equal(len(capture[]), 0)


def main() raises:
    test_each_request_asks_the_source()
    test_no_token_no_request()
    print("OK")
