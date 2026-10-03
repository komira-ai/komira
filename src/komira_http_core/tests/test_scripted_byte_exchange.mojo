# =============================================================================
# src/komira_http_core/tests/test_scripted_byte_exchange.mojo
# =============================================================================
#
# test:
# "A scripted byte exchange round-trips over ScriptedStream."
#
# Also exercises the named §9a.2 features the mock exists to provide:
#   * Pre-loaded read script returns Ready with the script bytes.
#   * Pre-armed Pending forces try_read to return StreamIo.pending(...)
#     before serving real bytes (exercises park/wake path).
#   * Pre-armed Eof returns StreamIo.eof() (mid-response RST simulation).
#   * Pre-armed Error returns StreamIo.error(errno) (hard-error path).
#   * Write capture inspectable post-exchange.
#   * Partial reads via max_read_per_call (loop-on-partial-read).
#
# Critically: the mock is parametric on `[RT: Runtime]` identically to
# KernelTcpConnector — Acceptance test (c) "traits compile with KernelTcp
# AND Scripted conformers monomorphized" is exercised here implicitly via
# both tests (KernelTcp loopback + Scripted byte exchange) running in the
# same binary at the same trait surface.
#
# Mock semantics: the reactor parameter is accepted but ignored — the
# script is replayed deterministically without driving any I/O. Tests
# that need to exercise park-wake substitute a Pending-armed script.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_http_core.transport.io_stream import (
    NEGOTIATED_HTTP_1_1,
    NEGOTIATED_HTTP_2,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import (
    ScriptedConnector,
    ScriptedStream,
)


# =============================================================================
# Helpers
# =============================================================================

def _bytes_from_str(s: StringLiteral) -> List[UInt8]:
    """Encode a string literal as a List[UInt8] script. Mojo 1.0.0b1
    doesn't have direct String-to-bytes; we hand-encode short literals
    via codepoints. The tests use ASCII fragments only."""
    var out = List[UInt8]()
    var i = 0
    var n = s.byte_length()
    while i < n:
        out.append(UInt8(ord(s[byte=i])))
        i = i + 1
    return out^


def _build_test_reactor() raises -> Reactor[NoopSink]:
    """Construct a BACKEND_MOCK reactor — no fd allocation, safe to
    construct without any system resources. The scripted stream
    ignores the reactor anyway; this just gives the trait method a
    typed argument."""
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )


# =============================================================================
# Tests
# =============================================================================

def test_scripted_connector_transport_kind() raises:
    """The mock pretends to be kernel TCP — the codec layer above
    cannot tell the difference (the point of the test seam)."""
    var c = ScriptedConnector()
    assert_equal(Int(c.transport_kind()), Int(TRANSPORT_KIND_KERNEL_TCP))


def test_scripted_stream_empty_read_returns_eof() raises:
    """Empty-script stream: first try_read returns Eof (no bytes
    scripted)."""
    var stream = ScriptedStream.empty()
    var reactor = _build_test_reactor()
    var buf = Array[UInt8, 4](fill=UInt8(0))
    var dst = Span[UInt8](buf)
    var r = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r.is_eof())


def test_scripted_stream_basic_read_returns_script_bytes() raises:
    """Pre-loaded script → try_read returns Ready with the bytes."""
    var script = _bytes_from_str("HELLO")
    var stream = ScriptedStream.from_read_script(script^)
    var reactor = _build_test_reactor()
    var buf = Array[UInt8, 8](fill=UInt8(0))
    var dst = Span[UInt8](buf)
    var r = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r.is_ready())
    assert_equal(r.n_bytes(), Int64(5))
    assert_equal(Int(buf[0]), Int(UInt8(ord('H'))))
    assert_equal(Int(buf[1]), Int(UInt8(ord('E'))))
    assert_equal(Int(buf[2]), Int(UInt8(ord('L'))))
    assert_equal(Int(buf[3]), Int(UInt8(ord('L'))))
    assert_equal(Int(buf[4]), Int(UInt8(ord('O'))))

    # Second read: cursor at end → Eof.
    var r2 = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r2.is_eof())


def test_scripted_stream_partial_reads_via_max_read_per_call() raises:
    """Forces the client to loop on partial reads. Verifies the
    max_read_per_call clamp."""
    var script = _bytes_from_str("ABCDEFGH")
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(3)  # Force 3-byte reads.
    var reactor = _build_test_reactor()
    var buf = Array[UInt8, 16](fill=UInt8(0))
    var dst = Span[UInt8](buf)

    # First read returns 3 bytes.
    var r1 = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r1.is_ready())
    assert_equal(r1.n_bytes(), Int64(3))

    # Second read returns 3 more.
    var r2 = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r2.is_ready())
    assert_equal(r2.n_bytes(), Int64(3))

    # Third read returns the final 2.
    var r3 = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r3.is_ready())
    assert_equal(r3.n_bytes(), Int64(2))

    # Fourth read → Eof.
    var r4 = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r4.is_eof())


def test_scripted_stream_pending_then_ready() raises:
    """Pre-arm 2 Pending returns before the script bytes. Exercises
    the park/wake state-machine path."""
    var script = _bytes_from_str("X")
    var stream = ScriptedStream.from_read_script(script^)
    stream.queue_read_pending(2)
    var reactor = _build_test_reactor()
    var buf = Array[UInt8, 4](fill=UInt8(0))
    var dst = Span[UInt8](buf)

    # First two reads return Pending.
    var r1 = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r1.is_pending())

    var r2 = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r2.is_pending())

    # Third read returns the script byte.
    var r3 = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r3.is_ready())
    assert_equal(r3.n_bytes(), Int64(1))
    assert_equal(Int(buf[0]), Int(UInt8(ord('X'))))


def test_scripted_stream_eof_arm() raises:
    """Pre-armed Eof returns StreamIo.eof() — mid-response RST
    simulation."""
    var script = _bytes_from_str("REST_OF_RESPONSE")
    var stream = ScriptedStream.from_read_script(script^)
    stream.arm_eof()
    var reactor = _build_test_reactor()
    var buf = Array[UInt8, 32](fill=UInt8(0))
    var dst = Span[UInt8](buf)

    # Eof fires even though script has bytes left.
    var r = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r.is_eof())


def test_scripted_stream_error_arm() raises:
    """Pre-armed Error returns StreamIo.error(errno) — hard-error
    path."""
    var stream = ScriptedStream.empty()
    stream.arm_error(Int64(104))  # ECONNRESET
    var reactor = _build_test_reactor()
    var buf = Array[UInt8, 4](fill=UInt8(0))
    var dst = Span[UInt8](buf)

    var r = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r.is_error())
    assert_equal(r.errno(), Int64(104))


def test_scripted_stream_write_capture() raises:
    """Bytes written to try_write are captured for post-exchange
    inspection. Verifies the symmetric write-side behavior."""
    var stream = ScriptedStream.empty()
    var reactor = _build_test_reactor()
    var send_bytes = _bytes_from_str("GET / HTTP/1.1\r\n")
    var send_span = Span[UInt8](send_bytes)

    var r = stream.try_write[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, src=send_span,
    )
    assert_true(r.is_ready())
    assert_equal(r.n_bytes(), Int64(16))  # "GET / HTTP/1.1\r\n" is 16 bytes.

    # Capture: should hold the same bytes.
    assert_equal(stream.capture_len(), 16)
    var capture = stream.capture_view()
    assert_equal(Int(capture[0]), Int(UInt8(ord('G'))))
    assert_equal(Int(capture[1]), Int(UInt8(ord('E'))))
    assert_equal(Int(capture[2]), Int(UInt8(ord('T'))))
    assert_equal(Int(capture[14]), Int(UInt8(13)))   # \r
    assert_equal(Int(capture[15]), Int(UInt8(10)))   # \n


def test_scripted_connector_round_trip() raises:
    """The first-class acceptance: ScriptedConnector hands out a
    pre-armed stream; the client side runs a write then read cycle
    against it. Mirrors the KernelTcp loopback round-trip in shape but
    over the mock — zero sockets, fully deterministic."""
    var server_response = _bytes_from_str("HTTP/1.1 200 OK\r\n")
    var stream = ScriptedStream.from_read_script(server_response^)

    var connector = ScriptedConnector.with_stream(stream^)
    var reactor = _build_test_reactor()

    # Connect (mock — ignores ip/port).
    var client_stream = connector.connect[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
    )
    assert_equal(
        Int(client_stream.negotiated_protocol()),
        Int(NEGOTIATED_HTTP_1_1),
    )

    # Client writes a request line.
    var req_bytes = _bytes_from_str("GET / HTTP/1.1\r\n")
    var req_span = Span[UInt8](req_bytes)
    var w = client_stream.try_write[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, src=req_span,
    )
    assert_true(w.is_ready())
    assert_equal(w.n_bytes(), Int64(16))

    # Client reads the response.
    var resp_buf = Array[UInt8, 32](fill=UInt8(0))
    var resp_span = Span[UInt8](resp_buf)
    var r = client_stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=resp_span,
    )
    assert_true(r.is_ready())
    assert_equal(r.n_bytes(), Int64(17))  # "HTTP/1.1 200 OK\r\n" is 17 bytes.
    # Verify first 4 chars are "HTTP".
    assert_equal(Int(resp_buf[0]), Int(UInt8(ord('H'))))
    assert_equal(Int(resp_buf[1]), Int(UInt8(ord('T'))))
    assert_equal(Int(resp_buf[2]), Int(UInt8(ord('T'))))
    assert_equal(Int(resp_buf[3]), Int(UInt8(ord('P'))))

    # And verify the write side captured the request.
    assert_equal(client_stream.capture_len(), 16)


def test_scripted_connector_raises_without_arm() raises:
    """ScriptedConnector with no armed stream raises on connect — test
    bug detection."""
    var connector = ScriptedConnector()
    var reactor = _build_test_reactor()
    var raised = False
    try:
        var _s = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
        )
    except:
        raised = True
    assert_true(raised)


def test_scripted_stream_negotiated_h2_override() raises:
    """Stream construction defaults to H1.1; tests with H2 ALPN flows
    can override post-construction via set_negotiated_protocol."""
    var stream = ScriptedStream.empty()
    assert_equal(
        Int(stream.negotiated_protocol()),
        Int(NEGOTIATED_HTTP_1_1),
    )
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    assert_equal(
        Int(stream.negotiated_protocol()),
        Int(NEGOTIATED_HTTP_2),
    )


def main() raises:
    test_scripted_connector_transport_kind()
    test_scripted_stream_empty_read_returns_eof()
    test_scripted_stream_basic_read_returns_script_bytes()
    test_scripted_stream_partial_reads_via_max_read_per_call()
    test_scripted_stream_pending_then_ready()
    test_scripted_stream_eof_arm()
    test_scripted_stream_error_arm()
    test_scripted_stream_write_capture()
    test_scripted_connector_round_trip()
    test_scripted_connector_raises_without_arm()
    test_scripted_stream_negotiated_h2_override()
