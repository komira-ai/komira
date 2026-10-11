# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_http_transport_scripted.mojo —
#   the PRODUCTION transport `HttpPkgTransport[C]` driven end to end over a
#   scripted connector (no socket).
# =============================================================================
#
# ROWS
#   (1) a bodiless GET and a body-carrying POST each go through the shipped
#       HTTP client and come back as a `PkgResponse`: the status, the body
#       bytes, and exactly the three headers the protocol reads
#       (Content-Type, Location, Retry-After); any other header is dropped;
#       a header the server did not send reads EMPTY;
#   (2) the connector factory is handed the REQUEST's host, per call: the
#       scripted server answers with the host it was dialled for;
#   (3) a dial that fails RAISES out of `exchange`, and `try_exchange` turns
#       it into a fault (data), never an answer.
#
# Hermetic: `ScriptedConnector` (komira_http_core) claims TLS without any
# handshake and replays a canned HTTP/1.1 answer; nothing dials, and the
# hosts are a loopback name and literals, so nothing is resolved.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from kci_pkg_upload.transport import HttpPkgTransport, PkgRequest, try_exchange
from kci_pkg_upload.wire import bytes_of


# Hosts the client parses without DNS (its fast path for a loopback alias
# such as `localhost` or an IPv4 literal): the scripted connector is reached
# with no resolver call.
comptime _GET_HOST: String = "localhost"
comptime _POST_HOST: String = "127.0.0.1"
comptime _DOWN_HOST: String = "127.0.0.2"


def _answer(status_line: String, headers: String, body: String) -> List[UInt8]:
    return bytes_of(
        String("HTTP/1.1 ")
        + status_line
        + String("\r\n")
        + headers
        + String("Content-Length: ")
        + String(body.byte_length())
        + String("\r\nConnection: close\r\n\r\n")
        + body
    )


def _mk(host: String) -> ScriptedConnector:
    """The scripted server: its answer names the host it was dialled for.
    An unknown host gets a connector with no stream, whose dial fails."""
    if host == String(_GET_HOST):
        return ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script(
                _answer(
                    String("200 OK"),
                    String("Content-Type: application/json\r\n")
                    + String("Location: /next\r\n")
                    + String("Retry-After: 3\r\n")
                    + String("X-Other: dropped\r\n"),
                    String("served ") + host,
                )
            )
        )
    if host == String(_POST_HOST):
        return ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script(
                _answer(String("201 Created"), String(""), String("posted to ") + host)
            )
        )
    return ScriptedConnector()


def test_a_get_and_a_post_round_trip() raises:
    var t = HttpPkgTransport[ScriptedConnector](_mk)
    var get = PkgRequest(HTTP_METHOD_GET, String(_GET_HOST), String("/simple/p/"))
    get.with_header(String("Accept"), String("application/json"))
    var r = t.exchange(get)
    assert_equal(r.status, 200)
    assert_equal(String(unsafe_from_utf8=Span(r.body)), String("served localhost"))
    assert_equal(r.header(String("content-type")), String("application/json"))
    assert_equal(r.header(String("Location")), String("/next"))
    assert_equal(r.header(String("retry-after")), String("3"))
    assert_equal(r.header(String("X-Other")), String(""), "only the three protocol headers are lifted")
    assert_equal(len(r.header_names), 3)
    var post = PkgRequest(HTTP_METHOD_POST, String(_POST_HOST), String("/upload"))
    post.with_header(String("Content-Type"), String("application/octet-stream"))
    post.body = bytes_of(String("payload"))
    var p = t.exchange(post)
    assert_equal(p.status, 201)
    assert_equal(String(unsafe_from_utf8=Span(p.body)), String("posted to 127.0.0.1"))
    assert_equal(p.header(String("Content-Type")), String(""), "not sent, reads EMPTY")
    assert_equal(len(p.header_names), 0)
    print("  test_a_get_and_a_post_round_trip: PASS")


def test_a_failed_dial_is_a_fault() raises:
    var t = HttpPkgTransport[ScriptedConnector](_mk)
    var ex = try_exchange(t, PkgRequest(HTTP_METHOD_GET, String(_DOWN_HOST), String("/")))
    assert_false(ex.ok)
    assert_equal(ex.response.status, 0)
    assert_true(ex.fault.byte_length() > 0, "a fault says how")
    var down_post = PkgRequest(HTTP_METHOD_POST, String(_DOWN_HOST), String("/"))
    down_post.body = bytes_of(String("payload"))
    var ex2 = try_exchange(t, down_post)
    assert_false(ex2.ok)
    print("  test_a_failed_dial_is_a_fault: PASS")


def main() raises:
    test_a_get_and_a_post_round_trip()
    test_a_failed_dial_is_a_fault()
    print("test_pkg_upload_http_transport_scripted: ALL PASS")
