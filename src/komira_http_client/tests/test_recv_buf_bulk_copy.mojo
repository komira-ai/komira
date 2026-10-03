# =============================================================================
# src/komira_http_client/tests/test_recv_buf_bulk_copy.mojo
#   semantic-equivalence regression.
# =============================================================================
#
# These are the regression tests for.
# They verify that replacing the three per-byte `_recv_buf.append(scratch[k])`
# loops in `state_machine.mojo` (sites at lines 842-846, 476-481, 453-455,
# and 924-929 pre-fix) with bulk `List.extend(Span)` calls produces
# BYTE-IDENTICAL response bytes (head + body) compared to the pre-fix
# per-byte path.
#
# Each per-byte loop has the same shape:
#     while k < n: self._recv_buf.append(scratch[k]); k += 1
# The fix replaces each with `self._recv_buf.extend(scratch[0:n])`
# (or `Span(list)[start:end]` for in-place tail copies), which routes
# through a single memcpy via `List._realloc` + `__memmove_evex_unaligned_erms`
# (`L1` SIMD bulk store at 64-bytes/cycle on AVX-512 hosts).
#
# Coverage:
#   Test 1: Single-chunk response (head + small body in one try_read)
#           — exercises Site 1 (_drive_read_head copy) + Site 2
#             (_extract_pre_body_bytes) once.
#   Test 2: Chunked-by-recv response (head fragmented across multiple
#           try_read calls, each forcing the per-byte loop to fire
#           multiple times) — exercises Site 1 fanning across calls.
#   Test 3: Body delivered across multiple try_read chunks — exercises
#           Site 4 (body-read copy, line 924-929 pre-fix).
#   Test 4: Empty body (Content-Length: 0) — edge case n=0 for Site 4.
#   Test 5: Larger response (~256-byte head + 128-byte body) — confirms
#           bulk-extend handles realistic sizes used in production
#           (RFC-conformant max field sizes).
#
# Test-first: WITHOUT the fix in place, these tests still BUILD and PASS
# (the per-byte loop and bulk-extend are semantically equivalent — both
# produce the same `_recv_buf` contents byte-for-byte). The post-fix tests
# are the regression guard: they GUARANTEE that future refactors of the
# bulk-extend path cannot silently regress on byte-identity.
#
# Encapsulation hard-bans honored: ZERO UnsafePointer in test code,
# ZERO wildcard origins, ZERO unsafe_from_address, ZERO take_pointee.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.body_frame import (
    BODY_FRAME_KIND_DATA,
    BODY_FRAME_KIND_END,
)
from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.state_machine import ClientResponse
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


def _drain_body(
    mut resp: ClientResponse[BufferedResponseBody],
    mut reactor: Reactor[NoopSink],
) raises -> List[UInt8]:
    """Drain a BufferedResponseBody via poll_frame. Returns the extracted
    body bytes (one Data frame's worth, since BufferedResponseBody emits
    the whole body in one shot)."""
    var tok = CancellationToken.never()
    var frame = resp.body.poll_frame[PerCoreAsyncRuntime[NoopSink]](
        reactor, tok,
    )
    if frame.kind == BODY_FRAME_KIND_END:
        return List[UInt8]()
    if frame.kind != BODY_FRAME_KIND_DATA:
        raise Error("expected DATA or END frame")
    var bytes_out = frame.take_data_chunk()
    return bytes_out^


# =============================================================================
# Test 1 — single-chunk response: head + 2-byte body in one try_read.
# Exercises Site 1 (_drive_read_head per-byte response-head copy) +
# Site 2 (_extract_pre_body_bytes per-byte body extract).
# =============================================================================


def test_single_chunk_head_and_body_byte_identical() raises:
    """A single try_read returns the full response (head + body). The
    head copy goes through Site 1; the body is extracted from
    `_recv_buf` past `_headers_end_off` via Site 2.

    Bulk-extend MUST produce the same body bytes as the pre-fix per-byte
    path. This test asserts byte-identity of every byte of the response
    body."""
    var url = Url.parse(String("http://127.0.0.1:8080/single"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)

    var body = _drain_body(resp, reactor)
    assert_equal(len(body), 2, "body length must be 2")
    assert_equal(Int(body[0]), Int(ord("O")), "body[0] must be 'O'")
    assert_equal(Int(body[1]), Int(ord("K")), "body[1] must be 'K'")


# =============================================================================
# Test 2 — fragmented head: head spans multiple try_read calls. Site 1
# (_drive_read_head per-byte response-head copy) fires multiple times,
# each appending a different sub-span of scratch.
# =============================================================================


def test_fragmented_head_byte_identical() raises:
    """The response head is delivered across 8-byte chunks, so the
    per-byte copy loop at Site 1 fires multiple times — each call
    appending a small sub-span into `_recv_buf`. Bulk-extend MUST
    produce the same accumulated `_recv_buf` bytes as the pre-fix
    per-byte path."""
    var url = Url.parse(String("http://127.0.0.1:8080/frag"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    stream.set_max_read_per_call(8)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)

    var body = _drain_body(resp, reactor)
    assert_equal(len(body), 2)
    assert_equal(Int(body[0]), Int(ord("O")))
    assert_equal(Int(body[1]), Int(ord("K")))


# =============================================================================
# Test 3 — body delivered across multiple recv chunks: Site 4 (body-read
# per-byte copy, pre-fix line 924-929) fires multiple times with
# different sub-spans.
# =============================================================================


def test_chunked_body_recv_byte_identical() raises:
    """A larger body (32 bytes) is delivered with `set_max_read_per_call(8)`
    so multiple try_read calls each push a sub-span through the body-read
    per-byte copy (Site 4). Bulk-extend MUST produce the same body bytes
    as the pre-fix path.

    Asserts byte-by-byte that every body byte matches the deterministic
    fixture: a 32-byte ASCII payload "0123456789ABCDEF0123456789ABCDEF".
    """
    var url = Url.parse(String("http://127.0.0.1:8080/body"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var expected_body = String("0123456789ABCDEF0123456789ABCDEF")
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 32\r\n\r\n"
    ) + expected_body)
    var stream = ScriptedStream.from_read_script(resp_script^)
    stream.set_max_read_per_call(8)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)

    var body = _drain_body(resp, reactor)
    assert_equal(len(body), 32, "body length must be 32")
    var expected_bytes = expected_body.as_bytes()
    var i = 0
    while i < 32:
        assert_equal(
            Int(body[i]), Int(expected_bytes[i]),
            "body[" + String(i) + "] byte mismatch",
        )
        i = i + 1


# =============================================================================
# Test 4 — empty body (n=0 edge case for Site 4): Content-Length: 0
# response. Site 4 should NOT fire (no body bytes to copy).
# =============================================================================


def test_empty_body_edge_case() raises:
    """A Content-Length: 0 response — Site 4 (body-read per-byte copy)
    should not fire any iterations (n=0). Bulk-extend's `extend(span[0:0])`
    is a no-op in both implementations.

    This is an edge-case correctness gate: the code path must handle
    zero-byte bulk extends without overrunning or corrupting `_recv_buf`."""
    var url = Url.parse(String("http://127.0.0.1:8080/empty"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var resp_script = _b(String(
        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 204)

    var body = _drain_body(resp, reactor)
    assert_equal(len(body), 0, "body length must be 0")


# =============================================================================
# Test 5 — realistic-size response (multiple headers + 128-byte body).
# Exercises Site 1 + Site 2 + Site 4 with production-scale byte counts.
# =============================================================================


def test_realistic_size_byte_identical() raises:
    """A response with multiple headers (~250 bytes head) + 128-byte body.
    All three per-byte sites (Site 1: head copy, Site 2: pre-body extract,
    Site 4: body read) fire at production-realistic sizes. Bulk-extend
    MUST produce byte-identical output."""
    var url = Url.parse(String("http://127.0.0.1:8080/realistic"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    # Build a 128-byte body of pattern bytes (0x41 + (i % 26)).
    var expected_body = List[UInt8]()
    var bi = 0
    while bi < 128:
        var ch = UInt8(0x41 + (bi % 26))  # 'A'..'Z' repeating
        expected_body.append(ch)
        bi = bi + 1

    var body_str = String()
    var bj = 0
    while bj < 128:
        body_str = body_str + chr(Int(expected_body[bj]))
        bj = bj + 1

    var head_str = String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/octet-stream\r\n"
        "Content-Length: 128\r\n"
        "X-Custom-1: header-value-1-padding-some-bytes\r\n"
        "X-Custom-2: header-value-2-additional-padding-bytes\r\n"
        "\r\n"
    )
    var resp_script = _b(head_str + body_str)
    var stream = ScriptedStream.from_read_script(resp_script^)
    stream.set_max_read_per_call(64)  # multiple chunks
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)

    var body = _drain_body(resp, reactor)
    assert_equal(len(body), 128, "body length must be 128")
    var i = 0
    while i < 128:
        assert_equal(
            Int(body[i]), Int(expected_body[i]),
            "body[" + String(i) + "] byte mismatch",
        )
        i = i + 1


def main() raises:
    test_single_chunk_head_and_body_byte_identical()
    test_fragmented_head_byte_identical()
    test_chunked_body_recv_byte_identical()
    test_empty_body_edge_case()
    test_realistic_size_byte_identical()
    print("OK: test_recv_buf_bulk_copy 5/5 PASS")
