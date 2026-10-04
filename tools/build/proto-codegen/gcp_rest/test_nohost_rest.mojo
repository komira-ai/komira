# A generated REST client of a service with no `google.api.default_host`.
#
# `NoHostServiceClient` has no host to start at, and it does not invent one:
# until its caller names a host with `set_rest_host`, every call raises a
# refusal naming the service and `set_rest_host`, before it asks its
# GcpTokenSource for a token and before anything is dialled. A placeholder
# host would have sent the bearer token to whatever answers there.
#
# The connector is komira_http_core's ScriptedConnector (every dial's host
# recorded, every written byte captured); no socket is used.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import GcpTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_gcp_nohost_rest.nohost import GetThingRequest, NoHostServiceClient


comptime _RT = BlockingRuntime[NoopSink]


struct CountingTokenSource(GcpTokenSource, Movable, Deinitable):
    """Hands out one fixed token and counts the calls in a cell the test
    keeps."""

    var calls: ArcPointer[Int]

    def __init__(out self, calls: ArcPointer[Int]):
        self.calls = calls

    def access_token(mut self) raises -> String:
        self.calls[] += 1
        return String("test-access-token")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok() -> List[UInt8]:
    var body = String('{"name":"things/a","size":"3"}')
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(
    calls: ArcPointer[Int], capture: ArcPointer[List[UInt8]]
) -> NoHostServiceClient[ScriptedConnector, CountingTokenSource]:
    return NoHostServiceClient[ScriptedConnector, CountingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(), capture)
            )
        ),
        CountingTokenSource(calls),
    )


def test_no_host_refuses_before_any_dial() raises:
    var calls = ArcPointer[Int](0)
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(calls, capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = c.get_thing[_RT](GetThingRequest(String("things/a")), reactor)
    except e:
        raised = String(e)
    assert_true(
        raised.find("NoHostServiceClient.get_thing: no REST host") >= 0,
        "the refusal does not name the client and method: " + raised,
    )
    assert_true(
        raised.find("example.nohost.v1.NoHostService declares no google.api.default_host") >= 0,
        "the refusal does not name the service: " + raised,
    )
    assert_true(
        raised.find("set_rest_host") >= 0,
        "the refusal does not name set_rest_host: " + raised,
    )
    # Refused before the token hook and before any dial: no token asked, no
    # dial host pushed, nothing connected, nothing written.
    assert_equal(calls[], 0)
    assert_equal(c._client._connector.dial_hosts_len(), 0)
    assert_equal(c._client._connector.connect_call_count(), 0)
    assert_equal(len(capture[]), 0)


def test_a_set_host_is_dialled() raises:
    var calls = ArcPointer[Int](0)
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(calls, capture)
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var thing = c.get_thing[_RT](GetThingRequest(String("things/a")), reactor)
    assert_equal(thing.name, "things/a")
    assert_equal(calls[], 1)
    assert_equal(c._client._connector.dial_hosts_len(), 1)
    assert_equal(c._client._connector.dial_host_at(0), "localhost")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(
        wire.startswith("GET /v1/things/a HTTP/1.1\r\nHost: localhost\r\n"),
        "unexpected request head: " + wire,
    )


def main() raises:
    test_no_host_refuses_before_any_dial()
    test_a_set_host_is_dialled()
    print("OK")
