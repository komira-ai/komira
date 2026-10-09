# =============================================================================
# src/komira_http_client/tests/test_recv_ring_body.mojo
# =============================================================================
# RecvRingBody acceptance suite.
#
# Drives the recv-ring streaming body conformer over ScriptedStream
# fixtures. Asserts the chunk-boundary / EOF / trailers / large-body /
# multi-chunk / Pending / cancellation / origin-borrow-checker contracts
# documented in `src/komira_http_client/response_body.mojo` §3.

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_clock import now_ns as _now_ns

from komira_http_client.body_frame import (
    BODY_FRAME_KIND_DATA,
    BODY_FRAME_KIND_END,
    BodyFrame,
)
from komira_http_client.header_map import HeaderMap
# Module-private, imported on purpose: it is the value the driver stamps
# (`_effective_deadline_us`), and test_outbound_budget_rule pins it equal to
# the public `OUTBOUND_BUDGET_DEFAULT_US`.
from komira_http_client.state_machine import _HEAD_DRIVE_DEFAULT_TIMEOUT_US
from komira_http_client.response_body import (
    RecvRingBody,
    ResponseBody,
    collect_body,
)
from komira_http_core.transport.scripted import ScriptedStream


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var i = 0
    while i < len(bytes_ref):
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _bytes_eq(buf: List[UInt8], s: String) -> Bool:
    var bytes_ref = s.as_bytes()
    if buf.__len__() != len(bytes_ref):
        return False
    var i = 0
    while i < buf.__len__():
        if buf[i] != bytes_ref[i]:
            return False
        i = i + 1
    return True


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _stamp_as_the_driver_does(mut body: RecvRingBody[ScriptedStream]):
    """Stamp `body` with the deadline an `OutboundDriver` with no configured
    request timeout stamps on every body it builds: now plus the driver's own
    default, `_HEAD_DRIVE_DEFAULT_TIMEOUT_US` (`_effective_deadline_us`).

    WHY THE LARGE-BODY CASES STAMP. A hand-built body carries no stamp, and
    `collect_body` bounds an unstamped drain by `_UNSTAMPED_DRAIN_BACKSTOP_US`
    (400 ms) of WALL time, progress or not: that backstop is a detector for a
    construction site that forgot to stamp (`response_body.mojo`), and
    `test_body_drain_deadline` holds it to stopping a peer that keeps
    delivering bytes. Decoding 256 KiB or 2.5 MB is CPU work whose wall time is
    the build's: at -O3 it fits in 400 ms; under coverage instrumentation the
    2.5 MB drain was cut at 163-282 KB. These cases check what the decoder
    returns at size, not how fast, so they drain the body a real request
    drains: one the driver stamped. The small cases stay unstamped; they are
    the hand-built shape the backstop is sized for."""
    body.set_deadline_us(
        Int(_now_ns() // UInt64(1000)) + _HEAD_DRIVE_DEFAULT_TIMEOUT_US
    )


# =============================================================================
# Test 1: zero-byte body — first poll yields End directly.
# =============================================================================


def test_recv_ring_empty_body() raises:
    """new_empty(stream) yields End on first poll; subsequent calls
    idempotent."""
    var stream = ScriptedStream.empty()
    var body = RecvRingBody[ScriptedStream].new_empty(stream^)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    assert_false(body.is_done())
    var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f.is_end())
    assert_true(body.is_done())
    # Idempotent.
    var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f2.is_end())


# =============================================================================
# Test 2: Content-Length-framed body — single chunk from pre-body bytes.
# =============================================================================


def test_recv_ring_cl_pre_body_only() raises:
    """All CL bytes were already buffered by the head parse (pre_body
    covers the whole body). First poll emits one Data frame; second
    poll emits End."""
    var pre = _make_bytes(String("hello"))
    var stream = ScriptedStream.empty()
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, cl_total=5, pre_body_bytes=pre^,
        max_body_bytes=100 * 1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f1.is_data())
    assert_equal(f1.chunk_len(), 5)
    var chunk = f1.take_data_chunk()
    assert_true(_bytes_eq(chunk, String("hello")))

    var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f2.is_end())


# =============================================================================
# Test 3: CL-framed body — pre-body + multi-chunk reads from the wire.
# =============================================================================


def test_recv_ring_cl_streaming_from_wire() raises:
    """CL=20 body. Pre-body has 3 bytes; remaining 17 come from the
    ScriptedStream in two reads (10 + 7). collect_body produces all 20."""
    var pre = _make_bytes(String("ABC"))
    var wire = _make_bytes(String("DEFGHIJKLMNOPQRSTU"))  # 18 bytes; only 17 will be consumed
    var stream = ScriptedStream.from_read_script(wire^)
    stream.set_max_read_per_call(10)  # Force partial-read loop
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, cl_total=20, pre_body_bytes=pre^,
        max_body_bytes=100 * 1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var all_bytes = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        body, reactor, tok,
    )
    assert_equal(all_bytes.__len__(), 20)
    assert_true(_bytes_eq(all_bytes, String("ABCDEFGHIJKLMNOPQRST")))


# =============================================================================
# Test 4: chunked-encoded body — multi-chunk + trailer.
# =============================================================================


def test_recv_ring_chunked_multi_chunk_with_trailer() raises:
    """Chunked TE body: two chunks then last-chunk + empty trailer.
    collect_body produces the concatenated payload."""
    # Wire format: 5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n
    var pre = _make_bytes(
        String("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
    )
    var stream = ScriptedStream.empty()
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=pre^, max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var all_bytes = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        body, reactor, tok,
    )
    assert_equal(all_bytes.__len__(), 11)
    assert_true(_bytes_eq(all_bytes, String("hello world")))


# =============================================================================
# Test 5: chunked body — multi-chunk where chunks arrive in separate reads.
# =============================================================================


def test_recv_ring_chunked_chunks_in_separate_reads() raises:
    """Chunked TE body where the SECOND chunk arrives only after the
    state-machine reads more bytes from the wire. Exercises the
    incremental-decoder path."""
    # Pre-body: first chunk only — "3\r\nABC\r\n"
    var pre = _make_bytes(String("3\r\nABC\r\n"))
    # Wire: second chunk + last-chunk — "4\r\nDEFG\r\n0\r\n\r\n"
    var wire = _make_bytes(String("4\r\nDEFG\r\n0\r\n\r\n"))
    var stream = ScriptedStream.from_read_script(wire^)
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=pre^, max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var all_bytes = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        body, reactor, tok,
    )
    assert_equal(all_bytes.__len__(), 7)
    assert_true(_bytes_eq(all_bytes, String("ABCDEFG")))


# =============================================================================
# Test 6: large body — 256 KiB streaming over multiple reads.
# =============================================================================


def test_recv_ring_large_body_streaming() raises:
    """256 KiB Content-Length body, read in 8 KiB chunks. Tests that
    the body is correctly streamed and reassembled."""
    # Build a 256 KiB body of repeating ABCD.
    var total: Int = 256 * 1024
    var wire = List[UInt8]()
    var i = 0
    while i < total:
        wire.append(UInt8(0x41 + (i & 3)))  # A B C D rotating
        i = i + 1
    var stream = ScriptedStream.from_read_script(wire^)
    stream.set_max_read_per_call(8 * 1024)
    var pre = List[UInt8]()
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, cl_total=total, pre_body_bytes=pre^,
        max_body_bytes=100 * 1024 * 1024,
    )
    _stamp_as_the_driver_does(body)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var all_bytes = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        body, reactor, tok,
    )
    assert_equal(all_bytes.__len__(), total)
    # Spot-check a few positions.
    assert_equal(Int(all_bytes[0]), 0x41)  # 'A'
    assert_equal(Int(all_bytes[1]), 0x42)  # 'B'
    assert_equal(Int(all_bytes[100]), 0x41 + (100 & 3))
    assert_equal(Int(all_bytes[total - 1]), 0x41 + ((total - 1) & 3))


# =============================================================================
# Test 7: Pending frame surfaced when stream returns Pending.
# =============================================================================


def test_recv_ring_pending_surfaced() raises:
    """ScriptedStream armed with queue_read_pending(2). The first
    poll_frame call sees a Pending from try_read and surfaces it as
    BodyFrame.pending(); the next polls eventually produce Data."""
    var wire = _make_bytes(String("hello"))
    var stream = ScriptedStream.from_read_script(wire^)
    stream.queue_read_pending(2)
    var pre = List[UInt8]()
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, cl_total=5, pre_body_bytes=pre^,
        max_body_bytes=100 * 1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    # First poll: should surface Pending (script returns Pending once).
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f1.is_pending())
    # Second poll: same (script returns Pending again).
    var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f2.is_pending())
    # Third poll: script now returns Ready(5).
    var f3 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f3.is_data())
    assert_equal(f3.chunk_len(), 5)
    # Fourth poll: End (CL fully consumed).
    var f4 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f4.is_end())


# =============================================================================
# Test 8: EOF mid-CL-body → Error frame.
# =============================================================================


def test_recv_ring_eof_mid_body_yields_error() raises:
    """CL=10 but stream only has 3 bytes + EOF. Should surface
    BodyFrame.error() once short-EOF is detected."""
    var pre = _make_bytes(String("abc"))
    var stream = ScriptedStream.empty()
    # stream.arm_eof() means the next try_read returns Eof.
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, cl_total=10, pre_body_bytes=pre^,
        max_body_bytes=100 * 1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    # First poll: emits the 3 pre-body bytes as Data.
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f1.is_data())
    # Second poll: tries to read more; ScriptedStream.empty() returns
    # eof(). Should surface Error (CL=10, only got 3).
    var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f2.is_error())
    var detail = f2.error_detail()
    # The detail string should mention EOF_MID_RESPONSE.
    assert_true(
        detail.find(String("EOF_MID_RESPONSE")) >= 0,
    )


# =============================================================================
# Test 9: trait-conformance comptime check.
# =============================================================================


# =============================================================================
# Test 6b: large CHUNKED body — 2.5 MB delivered in TLS-record-sized reads.
#
# ★ A SHAPE THAT BREAKS REAL CALLERS. Test 6 above
# is 256 KiB and CONTENT-LENGTH framed, so the chunked decoder's behaviour AT
# SIZE was covered by nothing — and `monitoring.googleapis.com` answers
# `timeSeries.list` over a 24h window with ~2.5 MB framed
# `Transfer-Encoding: chunked` (measured: HTTP/1.1, no Content-Length). A
# client reading it can fail with a transport fault after minutes while the
# same request over a 10-minute window — a small response — passes.
#
# `set_max_read_per_call(4096)` is not arbitrary: it models what s2n hands back
# per `try_read` on the TLS path, which is the real delivery shape and the one that makes the number of decoder invocations large.
# =============================================================================


def _append_hex_lower(mut out: List[UInt8], v: Int):
    """Append `v` as a lowercase hex chunk-size line value (RFC 7230 §4.1)."""
    if v == 0:
        out.append(UInt8(0x30))
        return
    var digits = String("0123456789abcdef")
    var buf = List[UInt8]()
    var n = v
    while n > 0:
        buf.append(UInt8(ord(digits[byte = n & 0xF])))
        n = n >> 4
    var i = buf.__len__() - 1
    while i >= 0:
        out.append(buf[i])
        i = i - 1


def _append_crlf(mut out: List[UInt8]):
    out.append(UInt8(0x0D))
    out.append(UInt8(0x0A))


def test_recv_ring_large_chunked_body_streaming() raises:
    """2.5 MB Transfer-Encoding: chunked body in 16 KiB chunks, read 4 KiB at a
    time. collect_body must return every payload byte, in order."""
    var total: Int = 2_500_000
    var chunk_sz: Int = 16 * 1024

    # Build the chunked wire AND the expected plaintext in one pass, so the
    # oracle is the payload itself rather than a re-derivation of it.
    var wire = List[UInt8]()
    var produced = 0
    while produced < total:
        var this_chunk = chunk_sz
        if total - produced < this_chunk:
            this_chunk = total - produced
        _append_hex_lower(wire, this_chunk)
        _append_crlf(wire)
        var k = 0
        while k < this_chunk:
            # A B C D rotating over the WHOLE payload (not per-chunk), so a
            # dropped or duplicated chunk shifts the phase and is detected.
            wire.append(UInt8(0x41 + ((produced + k) & 3)))
            k = k + 1
        _append_crlf(wire)
        produced = produced + this_chunk
    # last-chunk + empty trailer: "0\r\n\r\n"
    _append_hex_lower(wire, 0)
    _append_crlf(wire)
    _append_crlf(wire)

    var stream = ScriptedStream.from_read_script(wire^)
    stream.set_max_read_per_call(4096)
    var pre = List[UInt8]()
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=pre^, max_body_bytes=100 * 1024 * 1024,
    )
    _stamp_as_the_driver_does(body)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var all_bytes = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        body, reactor, tok,
    )
    assert_equal(all_bytes.__len__(), total)
    assert_equal(Int(all_bytes[0]), 0x41)
    assert_equal(Int(all_bytes[1]), 0x42)
    # Straddle the first chunk boundary — the phase must not restart.
    assert_equal(Int(all_bytes[chunk_sz - 1]), 0x41 + ((chunk_sz - 1) & 3))
    assert_equal(Int(all_bytes[chunk_sz]), 0x41 + (chunk_sz & 3))
    assert_equal(Int(all_bytes[total - 1]), 0x41 + ((total - 1) & 3))


def test_recv_ring_conforms_to_response_body() raises:
    """Verify RecvRingBody[ScriptedStream] satisfies the ResponseBody
    trait bound. If trait conformance breaks, this test fails to
    COMPILE."""
    @parameter
    def _conforms[RB: ResponseBody]() -> Bool:
        return True
    var ok = _conforms[RecvRingBody[ScriptedStream]]()
    assert_true(ok)


def main() raises:
    test_recv_ring_empty_body()
    test_recv_ring_cl_pre_body_only()
    test_recv_ring_cl_streaming_from_wire()
    test_recv_ring_chunked_multi_chunk_with_trailer()
    test_recv_ring_chunked_chunks_in_separate_reads()
    test_recv_ring_large_body_streaming()
    test_recv_ring_large_chunked_body_streaming()
    test_recv_ring_pending_surfaced()
    test_recv_ring_eof_mid_body_yields_error()
    test_recv_ring_conforms_to_response_body()
    print("OK: test_recv_ring_body")
