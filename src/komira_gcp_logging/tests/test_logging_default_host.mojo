# The host a client sends to when its caller names none. Cloud Logging's
# `LoggingServiceV2` declares `option (google.api.default_host) =
# "logging.googleapis.com"`, and the generated client starts there: a
# caller that never calls `set_rest_host` dials logging.googleapis.com and
# names it in the request's Host header, so its bearer token goes to the
# service it was minted for and to no other host.
#
# The connector is komira_http_core's ScriptedConnector, which records the
# host of every dial (`dial_host_at`) and captures what was written; no
# socket is used.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_logging.logging import (
    ListLogEntriesRequest,
    LoggingServiceV2Client,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]


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


def _host_lines(wire: String) -> List[String]:
    var out = List[String]()
    var lines = wire.split("\r\n")
    for i in range(len(lines)):
        if String(lines[i]).lower().startswith("host:"):
            out.append(String(lines[i]))
    return out^


def test_no_set_rest_host_dials_the_default_host() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = LoggingServiceV2Client[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(), capture)
            )
        ),
        StaticTokenSource(String("test-access-token")),
    )
    # No `set_rest_host`: the client's own default is what is dialled.
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.list_log_entries[_RT](_req(), reactor)

    assert_equal(c._client._connector.connect_call_count(), 1)
    assert_equal(c._client._connector.dial_hosts_len(), 1)
    assert_equal(c._client._connector.dial_host_at(0), "logging.googleapis.com")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(
        wire.startswith("POST /v2/entries:list HTTP/1.1\r\n"),
        "the request line is not the ListLogEntries call",
    )
    var hosts = _host_lines(wire)
    assert_equal(len(hosts), 1)
    assert_equal(hosts[0], "Host: logging.googleapis.com")


def test_set_rest_host_still_overrides_the_default() raises:
    # A caller pointing the client at another endpoint (here a local test
    # server, which resolves without the network) is dialled there instead.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = LoggingServiceV2Client[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(), capture)
            )
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.list_log_entries[_RT](_req(), reactor)

    assert_equal(c._client._connector.dial_hosts_len(), 1)
    assert_equal(c._client._connector.dial_host_at(0), "localhost")
    var hosts = _host_lines(String(unsafe_from_utf8=Span(capture[])))
    assert_equal(len(hosts), 1)
    assert_equal(hosts[0], "Host: localhost")


def main() raises:
    test_no_set_rest_host_dials_the_default_host()
    test_set_rest_host_still_overrides_the_default()
    print("OK")
