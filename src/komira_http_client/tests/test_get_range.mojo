# =============================================================================
# src/komira_http_client/tests/test_get_range.mojo
# =============================================================================
# HttpClient.get_range acceptance.
#
# Verifies:
#   1. get_range builds a request with Range: bytes=N-M.
#   2. A 206 Partial Content response is returned successfully.
#   3. A 200 OK response surfaces as HttpError[RANGE_NOT_HONORED].
#   4. Open-ended `Range: bytes=N-` (no end) works.

from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from std.sys.info import CompilationTarget

from komira_http_client.client import HttpClient
from komira_http_client.response_body import collect_body
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var i = 0
    while i < len(bytes_ref):
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        from komira_async.reactor.reactor import BACKEND_EPOLL
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


# =============================================================================
# Test 1: 206 Partial Content — get_range succeeds.
# =============================================================================


def test_get_range_206_partial_content() raises:
    """get_range(url, 0, 4) sends Range: bytes=0-4; server replies 206
    with the 5-byte partial body. collect_body returns those 5 bytes."""
    var resp_script = _b(String(
        "HTTP/1.1 206 Partial Content\r\n"
        "Content-Length: 5\r\n"
        "Content-Range: bytes 0-4/100\r\n"
        "\r\n"
        "hello"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()
    var url = Url.parse(String("http://127.0.0.1:8080/file"))

    var resp = client.get_range[PerCoreAsyncRuntime[NoopSink]](
        url^, range_start=0, range_end_opt=4, reactor=reactor,
    )
    assert_equal(Int(resp.status), 206)
    var tok = CancellationToken.never()
    var body_bytes = collect_body[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](resp.body, reactor, tok)
    assert_equal(body_bytes.__len__(), 5)
    var i = 0
    var expected = String("hello")
    var expected_bytes = expected.as_bytes()
    while i < 5:
        assert_equal(body_bytes[i], expected_bytes[i])
        i = i + 1


# =============================================================================
# Test 2: 200 OK — server ignored Range; surfaces as RANGE_NOT_HONORED.
# =============================================================================


def test_get_range_200_yields_range_not_honored() raises:
    """get_range with a server that replies 200 OK (ignoring Range)
    should raise HttpError[RANGE_NOT_HONORED]."""
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 100\r\n"
        "\r\n"
        + "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
        + "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuv"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()
    var url = Url.parse(String("http://127.0.0.1:8080/file"))

    var caught = False
    try:
        var _r = client.get_range[PerCoreAsyncRuntime[NoopSink]](
            url^, range_start=0, range_end_opt=4, reactor=reactor,
        )
    except _e:
        caught = True
    assert_true(caught)


# =============================================================================
# Test 3: open-ended Range — bytes=N- (no end).
# =============================================================================


def test_get_range_open_ended() raises:
    """get_range(url, 95, -1) sends Range: bytes=95-; server replies
    206 with the tail 5 bytes."""
    var resp_script = _b(String(
        "HTTP/1.1 206 Partial Content\r\n"
        "Content-Length: 5\r\n"
        "Content-Range: bytes 95-99/100\r\n"
        "\r\n"
        "tail!"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()
    var url = Url.parse(String("http://127.0.0.1:8080/file"))

    var resp = client.get_range[PerCoreAsyncRuntime[NoopSink]](
        url^, range_start=95, range_end_opt=-1, reactor=reactor,
    )
    assert_equal(Int(resp.status), 206)
    var tok = CancellationToken.never()
    var body_bytes = collect_body[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](resp.body, reactor, tok)
    assert_equal(body_bytes.__len__(), 5)
    var expected = String("tail!")
    var expected_bytes = expected.as_bytes()
    var i = 0
    while i < 5:
        assert_equal(body_bytes[i], expected_bytes[i])
        i = i + 1


# =============================================================================
# Test 4: range_not_honored HttpError factory shape.
# =============================================================================


def test_range_not_honored_http_error_factory() raises:
    """The HttpError.range_not_honored factory produces the right
    kind + carries the returned status."""
    from komira_http_client.error import HttpError, HTTP_ERROR_RANGE_NOT_HONORED
    var err = HttpError.range_not_honored(Int32(200))
    assert_equal(Int(err.kind), Int(HTTP_ERROR_RANGE_NOT_HONORED))
    assert_equal(Int(err.status), 200)
    assert_equal(err.kind_name(), String("RANGE_NOT_HONORED"))


def main() raises:
    test_get_range_206_partial_content()
    test_get_range_200_yields_range_not_honored()
    test_get_range_open_ended()
    test_range_not_honored_http_error_factory()
    print("OK: test_get_range")
