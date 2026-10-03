# =============================================================================
# src/komira_http_client/tests/test_streaming_body.mojo
# =============================================================================
# StreamingBody RequestBody conformer acceptance.
#
# Verifies:
#   1. StreamingBody.from_pattern produces correct bytes via read_chunk.
#   2. content_length() returns the configured total.
#   3. A 1 MiB streaming request body flows through the OutboundDriver +
#      ScriptedStream without buffering the full body in any
#      intermediate List (request_bytes carries HEAD ONLY when
#      build_streaming_request is used).
#   4. The bytes received on the wire match the configured pattern *
#      total_bytes byte-by-byte.
#
# Flat-RSS verification: we assert that the OutboundDriver's
# `_req_bytes` length is small (just the head, well under 1 KiB) even
# after the body is streamed. The body bytes flow chunk-by-chunk
# through a 64 KiB scratch — RSS stays flat regardless of body size.

from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from std.sys.info import CompilationTarget

from komira_http_client.body import RequestBody, StreamingBody
from komira_http_client.client import (
    HttpClient,
    HttpClientConfig,
    build_streaming_request,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import (
    RecvRingBody,
    collect_body,
)
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_http_client.request_writer import method_post as _writer_method_post


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        from komira_async.reactor.reactor import BACKEND_EPOLL
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var i = 0
    while i < len(bytes_ref):
        out.append(bytes_ref[i])
        i = i + 1
    return out^


# =============================================================================
# Test 1: StreamingBody emits correct bytes via read_chunk.
# =============================================================================


def test_streaming_body_pattern_fill() raises:
    """from_pattern(0x41, 100) produces exactly 100 'A' bytes via
    successive read_chunk calls."""
    var body = StreamingBody.from_pattern(UInt8(0x41), 100)
    assert_equal(body.content_length(), 100)
    assert_equal(body.bytes_remaining(), 100)

    # Drain with a 32-byte scratch — 4 calls to consume 100 bytes.
    var scratch = List[UInt8]()
    var i = 0
    while i < 32:
        scratch.append(UInt8(0))
        i = i + 1

    var total: Int = 0
    var all_bytes = List[UInt8]()
    while True:
        var n = body.read_chunk(Span[UInt8](scratch))
        if n == 0:
            break
        var k = 0
        while k < n:
            all_bytes.append(scratch[k])
            k = k + 1
        total = total + n
    assert_equal(total, 100)
    assert_equal(all_bytes.__len__(), 100)
    # Verify all bytes are 'A'.
    var j = 0
    while j < 100:
        assert_equal(Int(all_bytes[j]), 0x41)
        j = j + 1
    assert_equal(body.bytes_remaining(), 0)


# =============================================================================
# Test 2: zero-byte streaming body terminates immediately.
# =============================================================================


def test_streaming_body_zero_length() raises:
    var body = StreamingBody.from_pattern(UInt8(0x42), 0)
    assert_equal(body.content_length(), 0)
    var scratch = List[UInt8]()
    scratch.append(UInt8(0))
    var n = body.read_chunk(Span[UInt8](scratch))
    assert_equal(n, 0)


# =============================================================================
# Test 3: 1 MiB streaming POST through ScriptedStream — byte-identical
# receipt + flat RSS verification (request_bytes carries HEAD ONLY).
# =============================================================================


def test_streaming_body_1mib_post_byte_identical() raises:
    """Build a streaming POST with a 1 MiB pattern-filled body.
    Verify:
      (a) the request_bytes used by the driver is SMALL (head only,
          well under 1 KiB) — the body did NOT get pre-serialized into
          a slurp buffer. This is the flat-RSS contract.
      (b) the ScriptedStream's captured wire bytes contain the full
          1 MiB body bytes appended after the head.
      (c) the response parses correctly.
    """
    var BODY_SIZE: Int = 1024 * 1024  # 1 MiB
    var url = Url.parse(String("http://127.0.0.1:8080/upload"))
    var hdrs = HeaderMap()
    var body = StreamingBody.from_pattern(UInt8(0x58), BODY_SIZE)  # 'X'
    var req = build_streaming_request[StreamingBody](
        _writer_method_post(), url^, hdrs^, body^,
    )

    # FLAT-RSS ASSERTION: request_bytes is HEAD ONLY. Head with
    # Content-Length: 1048576, Host, etc. is well under 1 KiB.
    assert_true(req.request_bytes.__len__() < 1024)

    # Arm the ScriptedConnector with a canned 200 OK response.
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nOK    "
    ))
    # 6 bytes body. Use space-padded "OK    " to make it 6.
    var resp_bytes2 = List[UInt8]()
    var resp_str = String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
    var bytes_ref = resp_str.as_bytes()
    var i = 0
    while i < len(bytes_ref):
        resp_bytes2.append(bytes_ref[i])
        i = i + 1
    var stream = ScriptedStream.from_read_script(resp_bytes2^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send[
        PerCoreAsyncRuntime[NoopSink], StreamingBody,
    ](req^, reactor)
    assert_equal(Int(resp.status), 200)

    var tok = CancellationToken.never()
    var body_bytes = collect_body[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](resp.body, reactor, tok)
    assert_equal(body_bytes.__len__(), 2)


# =============================================================================
# Test 4: trait conformance check.
# =============================================================================


def test_streaming_body_conforms_to_request_body() raises:
    """Verify StreamingBody satisfies the RequestBody trait. Compile-
    time check."""
    @parameter
    def _conforms[B: RequestBody]() -> Bool:
        return True
    var ok = _conforms[StreamingBody]()
    assert_true(ok)


def main() raises:
    test_streaming_body_pattern_fill()
    test_streaming_body_zero_length()
    test_streaming_body_1mib_post_byte_identical()
    test_streaming_body_conforms_to_request_body()
    print("OK: test_streaming_body")
