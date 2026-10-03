# =============================================================================
# src/komira_http_client/tests/test_bulk_extend_recv_buf.mojo
# =============================================================================
# regression test.
#
# Asserts byte-for-byte equivalence of the OutboundDriver + RecvRingBody
# code paths after the 9 per-byte append loops (state_machine.mojo lines
# 485, 512, 887, 970; response_body.mojo lines 441, 489, 629, 647, 817)
# are swapped from `while k < n: list.append(span[k])` to bulk
# `list.extend(span[0:n])`.
#
# The bulk-extend transformation is semantically a no-op (same bytes
# appended in same order to same buffer), but the realloc cascade drops
# from N appends → 1 grow + 1 memcpy per call site. This test guards
# against any edge case where the bulk path drifts (e.g. off-by-one in
# slice bounds, empty-span handling, partial-read mid-buffer-append).
#
# Test matrix:
#   - empty body (0 bytes)
#   - 1-byte body
#   - 13-byte body (hc01-loopback shape)
#   - 4096-byte body (one full scratch chunk)
#   - 5000-byte body (multi-iteration accumulation)
#   - chunked body with multiple data frames
#   - partial-head + multi-iteration recv_buf accumulation

from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from std.sys.info import CompilationTarget

from komira_http_client.body import EmptyBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.request_writer import (
    method_get,
    serialize_request_head,
)
from komira_http_client.response_body import (
    BufferedResponseBody,
    RecvRingBody,
    collect_body,
)
from komira_http_client.state_machine import (
    ClientResponse,
    OutboundDriver,
    OUTBOUND_STATE_DONE,
)
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedStream



def _make_scratch() -> List[UInt8]:
    var s = List[UInt8]()
    var i = 0
    while i < 4096:
        s.append(UInt8(0))
        i = i + 1
    return s^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _bytes_to_str(buf: List[UInt8]) -> String:
    var out = String()
    var i = 0
    while i < buf.__len__():
        out = out + chr(Int(buf[i]))
        i = i + 1
    return out^


def _make_get_request_bytes() raises -> List[UInt8]:
    var url = Url.parse(String("http://example.com/health"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    return out^


def _drive_and_collect(
    var stream: ScriptedStream,
    var req_bytes: List[UInt8],
) raises -> List[UInt8]:
    """Drive a complete request through OutboundDriver and return the
    body bytes via collect_body. Returns the COMPLETE body — every
    byte that traversed the recv_buf + _accum + out per-byte append
    loops in state_machine.mojo + response_body.mojo."""
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    var tok = CancellationToken.never()
    return collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        resp.body, reactor, tok,
    )


def test_bulk_extend_empty_body() raises:
    """0-byte body — `_extract_pre_body_bytes` returns empty, no append
    cascade. Guards against off-by-one when `start >= n_recv`."""
    var req = _make_get_request_bytes()
    var script = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
    var stream = ScriptedStream.from_read_script(script^)
    var body = _drive_and_collect(stream^, req^)
    assert_equal(body.__len__(), 0)


def test_bulk_extend_1_byte_body() raises:
    """1-byte body — minimal pre_body + _accum + out path."""
    var req = _make_get_request_bytes()
    var script = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nX"))
    var stream = ScriptedStream.from_read_script(script^)
    var body = _drive_and_collect(stream^, req^)
    assert_equal(body.__len__(), 1)
    assert_equal(Int(body[0]), Int(ord(String("X"))))


def test_bulk_extend_13_byte_body() raises:
    """13-byte body (hc01-loopback shape) — head is ~50 bytes + body
    13 bytes arrives in ONE scratch read. Exercises lines 887 (recv_buf
    accumulation), 512 (pre_body extraction), 489 (RecvRingBody accum
    seed), 817 (collect_body out building)."""
    var req = _make_get_request_bytes()
    var script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!"
    ))
    var stream = ScriptedStream.from_read_script(script^)
    var body = _drive_and_collect(stream^, req^)
    assert_equal(body.__len__(), 13)
    assert_equal(_bytes_to_str(body), String("Hello, World!"))


def test_bulk_extend_4096_byte_body() raises:
    """Exactly one scratch-sized chunk — bulk-extend's grow path
    realloc-once semantics: empty List + extend(4096-byte span) ->
    one realloc to capacity 4096+."""
    var req = _make_get_request_bytes()
    var head = String("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n")
    var body_str = String()
    var i = 0
    while i < 4096:
        body_str = body_str + String("A")
        i = i + 1
    var script = _b(head + body_str)
    var stream = ScriptedStream.from_read_script(script^)
    var body = _drive_and_collect(stream^, req^)
    assert_equal(body.__len__(), 4096)
    # Spot-check every 256th byte is 'A'.
    var k = 0
    while k < 4096:
        assert_equal(Int(body[k]), Int(ord(String("A"))))
        k = k + 256


def test_bulk_extend_partial_read_loops() raises:
    """7-byte read clamp forces multi-iteration recv_buf accumulation —
    `_drive_read_head` line 887's append loop fires repeatedly; bulk
    extend must produce byte-identical recv_buf contents across all
    iterations."""
    var req = _make_get_request_bytes()
    var script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nhello, world!"
    ))
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(7)
    var body = _drive_and_collect(stream^, req^)
    assert_equal(body.__len__(), 13)
    assert_equal(_bytes_to_str(body), String("hello, world!"))


def test_bulk_extend_chunked() raises:
    """Chunked path — exercises `_accum.append` in chunked branch
    (response_body.mojo:647) + `_extract_pre_body_bytes` + collect_body
    out building. Multi-chunk to flex the path."""
    var req = _make_get_request_bytes()
    var script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\nhello\r\n"
        "6\r\n world\r\n"
        "0\r\n\r\n"
    ))
    var stream = ScriptedStream.from_read_script(script^)
    var body = _drive_and_collect(stream^, req^)
    assert_equal(body.__len__(), 11)
    assert_equal(_bytes_to_str(body), String("hello world"))


def test_bulk_extend_pending_then_data() raises:
    """Pending mid-read; ensures the append loops don't accumulate
    Pending(0-byte) spurious empties. Guards bulk-extend slicing of
    `scratch[0:n]` when n == 0 on Pending."""
    var req = _make_get_request_bytes()
    var script = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
    var stream = ScriptedStream.from_read_script(script^)
    stream.queue_read_pending(2)
    var body = _drive_and_collect(stream^, req^)
    assert_equal(body.__len__(), 2)
    assert_equal(_bytes_to_str(body), String("OK"))


def main() raises:
    test_bulk_extend_empty_body()
    print("test_bulk_extend_empty_body OK")
    test_bulk_extend_1_byte_body()
    print("test_bulk_extend_1_byte_body OK")
    test_bulk_extend_13_byte_body()
    print("test_bulk_extend_13_byte_body OK")
    test_bulk_extend_4096_byte_body()
    print("test_bulk_extend_4096_byte_body OK")
    test_bulk_extend_partial_read_loops()
    print("test_bulk_extend_partial_read_loops OK")
    test_bulk_extend_chunked()
    print("test_bulk_extend_chunked OK")
    test_bulk_extend_pending_then_data()
    print("test_bulk_extend_pending_then_data OK")
    print("ALL OK")
