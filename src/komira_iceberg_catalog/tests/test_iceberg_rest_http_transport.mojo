# =============================================================================
# test_iceberg_rest_http_transport.mojo — HttpIcebergRestTransport, the
#   production transport, over in-process connectors (no socket, no DNS: the
#   host is an IP literal, which the HTTP client parses instead of resolving).
# =============================================================================
#
# An echo connector answers every request with the request head it received
# as the response body (lines joined by " | "), under a status and a TLS flag
# the connector factory picks. Each case names the defect it would catch:
#   * the request line carries the request's path, and the Host header its
#     host and port (a transport that dropped the port, or the path, differs);
#     the HTTP client writes header names in lower case;
#   * every request header reaches the wire, Accept and Authorization by
#     value (a transport that dropped the header loop, or one header, differs);
#   * the response status and body are returned as received, and a non-200
#     status is returned, not raised (the client maps it, not the transport);
#   * the URL scheme follows the connector: `https` over a TLS connector,
#     `http` over a plaintext one. The HTTP client refuses a mismatched pair,
#     so a transport that always picked one scheme raises on the other;
#   * `request_timeout_us` bounds the request: a peer that sends a head and
#     then stalls fails with the client's TIMEOUT, not with the end-of-stream
#     error the stall ends in once its finite pending reads run out (a
#     transport that dropped the timeout waits for the peer instead).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_iceberg_catalog.iceberg_rest_transport import (
    HttpIcebergRestTransport,
    IcebergRestRequest,
)


comptime _HOST: String = "192.0.2.1"
comptime _STALL_PENDING_READS: Int = 200_000
comptime _BUDGET_US: Int = 150_000


# =============================================================================
# the echo connector
# =============================================================================


def _head_of(written: List[UInt8]) -> String:
    var n = len(written)
    var end = n
    for i in range(n - 3):
        if (
            written[i] == UInt8(13)
            and written[i + 1] == UInt8(10)
            and written[i + 2] == UInt8(13)
            and written[i + 3] == UInt8(10)
        ):
            end = i
            break
    var head = String(unsafe_from_utf8=Span(written)[0:end])
    return head.replace("\r\n", " | ")


def _response(status: Int, var body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ")
        + String(status)
        + " Echo\r\nContent-Type: text/plain\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^


struct _EchoStream(IoStream, Movable, Deinitable):
    var _status: Int
    var _written: List[UInt8]
    var _answer: ScriptedStream
    var _answered: Bool

    def __init__(out self, status: Int):
        self._status = status
        self._written = List[UInt8]()
        self._answer = ScriptedStream()
        self._answered = False

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        if not self._answered:
            self._answered = True
            self._answer = ScriptedStream.from_read_script(
                _response(self._status, _head_of(self._written))
            )
        return self._answer.try_read[RT, o](reactor, dst)

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        self._written.extend(src)
        return StreamIo.ready(Int64(len(src)))

    def unread(mut self, src: Span[UInt8, _]) raises:
        self._answer.unread(src)

    def close(var self):
        pass

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_1_1

    def fd(self) -> Int32:
        return Int32(-1)


struct _EchoConnector(Connector, Movable, Deinitable):
    comptime Stream = _EchoStream

    var _status: Int
    var _tls: Bool

    def __init__(out self, status: Int, tls: Bool):
        self._status = status
        self._tls = tls

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> _EchoStream:
        _ = ip_be
        _ = port
        return _EchoStream(self._status)

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return self._tls

    def set_dial_host(mut self, var host: String):
        _ = host^


def _echo_200_plain() raises -> _EchoConnector:
    return _EchoConnector(200, False)


def _echo_200_tls() raises -> _EchoConnector:
    return _EchoConnector(200, True)


def _echo_404_tls() raises -> _EchoConnector:
    return _EchoConnector(404, True)


def _echo_503_plain() raises -> _EchoConnector:
    return _EchoConnector(503, False)


def _refusing() raises -> _EchoConnector:
    raise Error("connector setup failed")


def _request(path: String, port: UInt16) -> IcebergRestRequest:
    var names = List[String]()
    var values = List[String]()
    names.append(String("Accept"))
    values.append(String("application/json"))
    names.append(String("Authorization"))
    values.append(String("Bearer t0k"))
    names.append(String("X-Iceberg-Access-Delegation"))
    values.append(String("vended-credentials"))
    return IcebergRestRequest(String(_HOST), port, path, names^, values^)


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# =============================================================================
# cases
# =============================================================================


def _assert_echoed_request(body: String, path: String, host: String) raises:
    assert_true(body.startswith(String("GET ") + path + " HTTP/1.1 | "), body)
    assert_true(_has(body, String(" | Host: ") + host), body)
    assert_true(_has(body, String(" | accept: application/json")), body)
    assert_true(_has(body, String(" | authorization: Bearer t0k")), body)
    assert_true(
        _has(body, String(" | x-iceberg-access-delegation: vended-credentials")),
        body,
    )


def test_plaintext_get_sends_path_headers_and_returns_body() raises:
    var tr = HttpIcebergRestTransport[_EchoConnector](_echo_200_plain)
    var resp = tr.get(_request(String("/v1/p/namespaces/db/tables/t"), 8181))
    assert_equal(resp.status, 200)
    _assert_echoed_request(
        resp.body, String("/v1/p/namespaces/db/tables/t"), String("192.0.2.1:8181")
    )


def test_tls_get_uses_https() raises:
    # Over a plaintext URL the HTTP client refuses a TLS connector; that this
    # call succeeds is the scheme proof. Port 443 is https's default, so the
    # Host header carries no port.
    var tr = HttpIcebergRestTransport[_EchoConnector](_echo_200_tls)
    var resp = tr.get(_request(String("/v1/config"), 443))
    assert_equal(resp.status, 200)
    _assert_echoed_request(resp.body, String("/v1/config"), String("192.0.2.1"))
    assert_true(not _has(resp.body, String("192.0.2.1:")), resp.body)


def test_non_200_is_returned_not_raised() raises:
    var tls = HttpIcebergRestTransport[_EchoConnector](_echo_404_tls)
    var r404 = tls.get(_request(String("/v1/config"), 9443))
    assert_equal(r404.status, 404)
    assert_true(r404.body.startswith(String("GET /v1/config HTTP/1.1 | ")))
    var plain = HttpIcebergRestTransport[_EchoConnector](_echo_503_plain)
    var r503 = plain.get(_request(String("/v1/x"), 80))
    assert_equal(r503.status, 503)
    assert_true(_has(r503.body, String(" | Host: 192.0.2.1")), r503.body)
    assert_true(not _has(r503.body, String("192.0.2.1:")), r503.body)


def test_each_call_dials_a_fresh_connector() raises:
    # Two GETs through one transport: the echo stream answers once, so a
    # transport that reused one stream would read nothing on the second.
    var tr = HttpIcebergRestTransport[_EchoConnector](_echo_200_plain)
    var a = tr.get(_request(String("/v1/a"), 8181))
    var b = tr.get(_request(String("/v1/b"), 8181))
    assert_true(a.body.startswith(String("GET /v1/a ")), a.body)
    assert_true(b.body.startswith(String("GET /v1/b ")), b.body)


def test_connector_factory_failure_propagates() raises:
    var tr = HttpIcebergRestTransport[_EchoConnector](_refusing)
    var msg = String("")
    try:
        var _r = tr.get(_request(String("/v1/config"), 8181))
    except e:
        msg = String(e)
    assert_equal(msg, String("connector setup failed"))


def _stalled_head() raises -> ScriptedConnector:
    var head = String(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        + "Content-Length: 1000\r\n\r\n{"
    )
    var b = List[UInt8]()
    b.extend(Span(head.as_bytes()))
    var s = ScriptedStream.from_read_script(b^)
    s.set_pending_after_script(_STALL_PENDING_READS)
    return ScriptedConnector.with_stream(s^)


def test_request_timeout_bounds_a_stalled_peer() raises:
    var tr = HttpIcebergRestTransport[ScriptedConnector](
        _stalled_head, request_timeout_us=_BUDGET_US
    )
    var msg = String("")
    try:
        var _r = tr.get(_request(String("/v1/config"), 8181))
    except e:
        msg = String(e)
    assert_true(_has(msg, String("TIMEOUT")), msg)


def main() raises:
    test_plaintext_get_sends_path_headers_and_returns_body()
    test_tls_get_uses_https()
    test_non_200_is_returned_not_raised()
    test_each_call_dials_a_fresh_connector()
    test_connector_factory_failure_propagates()
    test_request_timeout_bounds_a_stalled_peer()
    print("test_iceberg_rest_http_transport: ALL PASS")
