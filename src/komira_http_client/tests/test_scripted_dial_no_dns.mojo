# =============================================================================
# test_scripted_dial_no_dns.mojo — a request over a ScriptedConnector to a
# host NAME resolves nothing.
# =============================================================================
#
# `HttpClient` turns the URL's host into an `ip_be` before it calls
# `Connector.connect`. ScriptedConnector conforms to `NoDialAddress`: it opens
# no socket and never reads that address, so the client must not ask the
# system resolver about the name. The hosts below end in `.invalid`, a
# top-level domain RFC 2606 reserves so that it never resolves: a send that
# reached getaddrinfo would raise, so a send that completes did not.
#
# The name must still reach the wire. Each test also reads back what the
# scripted stream captured (the `Host` header) and what the client pushed to
# the connector (`set_dial_host`), so a client that dropped the host to avoid
# the lookup fails here too.
#
# Two dial paths are driven: `send_buffered` (the client's own connector) and
# `call` (an explicit connector, which runs the free-function dial helper).
#
# HERMETIC: a scripted byte transport; no socket, no resolver.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _ok_response() -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(
        Span(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK").as_bytes())
    )
    return out^


def _scripted(written: ArcPointer[List[UInt8]]) raises -> ScriptedConnector:
    var stream = ScriptedStream.from_read_script_with_capture(
        _ok_response(), written
    )
    return ScriptedConnector.with_stream(stream^)


def _wire_has_host(written: ArcPointer[List[UInt8]], line: String) -> Bool:
    var wire = String(unsafe_from_utf8=Span(written[].copy()))
    return wire.lower().find(line) >= 0


def test_send_buffered_to_a_name_resolves_nothing() raises:
    var written = ArcPointer[List[UInt8]](List[UInt8]())
    var client = HttpClient[ScriptedConnector].with_defaults(_scripted(written))
    var reactor = _make_reactor()
    var url = Url.parse(String("http://service.invalid:8080/health"))
    var req = build_get_request(url^, HeaderMap())
    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(client._connector.connect_call_count(), 1)
    assert_equal(client._connector.dial_hosts_len(), 1)
    assert_equal(client._connector.dial_host_at(0), String("service.invalid"))
    assert_true(_wire_has_host(written, String("host: service.invalid:8080\r\n")))


def test_call_with_an_explicit_connector_resolves_nothing() raises:
    var written = ArcPointer[List[UInt8]](List[UInt8]())
    var connector = _scripted(written)
    var client = HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector()
    )
    var reactor = _make_reactor()
    var url = Url.parse(String("http://other.invalid:8081/x"))
    var req = build_get_request(url^, HeaderMap())
    var resp = client.call[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        req^, connector, reactor
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(connector.connect_call_count(), 1)
    assert_equal(connector.dial_host_at(0), String("other.invalid"))
    assert_true(_wire_has_host(written, String("host: other.invalid:8081\r\n")))


def main() raises:
    test_send_buffered_to_a_name_resolves_nothing()
    test_call_with_an_explicit_connector_resolves_nothing()
    print("test_scripted_dial_no_dns: ok")
