# =============================================================================
# src/komira_http_client/tests/test_head_response_no_body.mojo
#   regression test
# =============================================================================
#
# Per RFC 7230 §3.3.2 / RFC 7231 §4.3.2: a response to a HEAD request
# MUST NOT contain a message body, even if the response carries a
# `Content-Length` header. The CL header on a HEAD response describes
# what the server WOULD have returned for an equivalent GET — not what
# is actually on the wire.
#
# Pre-fix bug: `OutboundDriver.run` + `run_with_body` only check the
# RESPONSE-SIDE conditions (`_is_empty_status_body` — 1xx / 204 / 304)
# when deciding whether to use `RecvRingBody.new_empty` vs
# `new_content_length`. If the request method was HEAD and the response
# carries `Content-Length: N>0`, the driver hands the stream + N to
# `new_content_length`. `collect_body` then loops `try_read` waiting
# for N bytes that never arrive. On a ScriptedStream backing this
# raises `HttpError[EOF_MID_RESPONSE: short body — CL=N got=0]` once
# the script bytes are exhausted; on a real socket this would hang
# until idle timeout.
#
# Post-fix: the driver tracks an `_is_head_request: Bool` flag (set by
# the caller via `set_is_head_request(True)` before run/run_with_body),
# and the body-decision branches short-circuit to `new_empty` when
# the flag is set. The Content-Length header is preserved in the
# response headers (per RFC the value remains informational for HEAD).
#
# Pre-fix: this test FAILS (collect_body raises EOF_MID_RESPONSE).
# Post-fix: this test PASSES (empty body, status=200, CL header
# preserved as "1234").
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient, build_head_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


# =============================================================================
# Test 1 — HEAD response with CL=1234 and NO body bytes parses cleanly.
# =============================================================================


def test_head_response_with_cl_header_no_body() raises:
    """A HEAD request returning `HTTP/1.1 200 OK\r\nContent-Length:
    1234\r\nConnection: keep-alive\r\n\r\n` (no body bytes on the wire)
    must be handled cleanly:

      * `send_buffered` returns without raising.
      * `resp.status == 200`.
      * `resp.body.bytes_remaining() == 0` (empty body).
      * `resp.headers` carries `Content-Length: 1234` (preserved
        informationally per RFC 7230 §3.3.2).

    Pre-fix: this test FAILS — the driver sees CL=1234, hands the
    stream to `RecvRingBody.new_content_length`, and `collect_body`
    raises `HttpError[EOF_MID_RESPONSE: short body — CL=1234 got=0]`
    once the script is exhausted (or hangs until the iteration cap).
    """
    var url = Url.parse(String("http://127.0.0.1:8080/object"))
    var hdrs = HeaderMap()
    var req = build_head_request(url^, hdrs^)

    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 1234\r\n"
        "Connection: keep-alive\r\n"
        "\r\n"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)
    # Body must be empty — HEAD MUST NOT have body per RFC 7230 §3.3.2.
    assert_equal(resp.body.bytes_remaining(), 0,
        "HEAD response body must be empty even with CL header set",
    )
    # Content-Length header must be preserved informationally on the
    # response — per RFC 7230 §3.3.2 the value reflects what GET would
    # return and remains useful metadata for the caller.
    var cl_opt = resp.headers.get(String("content-length"))
    assert_true(cl_opt.__bool__(),
        "Content-Length header must be preserved on HEAD response",
    )
    assert_equal(cl_opt.value(), String("1234"),
        "Content-Length value must be preserved as-is",
    )


# =============================================================================
# Test 2 — HEAD response without CL header (canonical empty-body shape).
# =============================================================================


def test_head_response_no_cl_header() raises:
    """A HEAD response without a Content-Length header must also be
    handled cleanly. This is the canonical empty-body shape; it was
    already handled correctly pre-fix (the no-CL + no-chunked + 200
    branch falls through to `new_read_until_eof` which gets immediate
    EOF on the closed stream — but that's also wrong: a HEAD response
    should be empty regardless of framing headers).

    With the fix, the HEAD-flag short-circuit makes this test pass
    deterministically without depending on EOF arrival timing.
    """
    var url = Url.parse(String("http://127.0.0.1:8080/object"))
    var hdrs = HeaderMap()
    var req = build_head_request(url^, hdrs^)

    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/octet-stream\r\n"
        "Connection: close\r\n"
        "\r\n"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(resp.body.bytes_remaining(), 0,
        "HEAD response body must be empty",
    )


# =============================================================================
# Test 3 — HEAD 404 with CL header (S3 NoSuchKey-style miss).
# =============================================================================


def test_head_404_with_cl_header() raises:
    """S3-style HEAD-missing path: HEAD on a non-existent key returns
    `404 Not Found` with `Content-Length: <error-doc-len>` (the size
    of the XML error document that GET would have returned). The HEAD
    response itself has no body bytes.

    This is the exact shape S3Store.head() against MinIO produced
    when the bug was originally surfaced.
    """
    var url = Url.parse(String("http://127.0.0.1:8080/missing-object"))
    var hdrs = HeaderMap()
    var req = build_head_request(url^, hdrs^)

    var resp_script = _b(String(
        "HTTP/1.1 404 Not Found\r\n"
        "Content-Length: 213\r\n"
        "Content-Type: application/xml\r\n"
        "Connection: keep-alive\r\n"
        "\r\n"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 404)
    assert_equal(resp.reason, String("Not Found"))
    assert_equal(resp.body.bytes_remaining(), 0,
        "HEAD 404 response body must be empty",
    )
    var cl_opt = resp.headers.get(String("content-length"))
    assert_true(cl_opt.__bool__(),
        "Content-Length must be preserved on HEAD 404",
    )
    assert_equal(cl_opt.value(), String("213"))


def main() raises:
    test_head_response_with_cl_header_no_body()
    test_head_response_no_cl_header()
    test_head_404_with_cl_header()
    print(
        "[OK] test_head_response_no_body — all 3 tests passed"
    )
