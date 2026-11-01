# =============================================================================
# src/komira_http_core/tests/test_cov_kernel_tcp_pushback.mojo
# =============================================================================
#
# TcpIoStream (transport/kernel_tcp.mojo) over a loopback connection, the
# paths its round-trip test does not take:
#
#   * `unread` pushback is served before the socket, front-first, with a
#     second `unread` placed IN FRONT of the first, and drained partially
#     when the destination is shorter than what is held;
#   * a read on a connection with nothing to read is Pending with the read
#     token (fd << 1); a zero-length write is Ready(0), not Eof;
#   * the TryIoResult mapping of an error (the errno) and of a would-block
#     write (the write token (fd << 1) | 1);
#   * the connector is not TLS, the two-argument constructor keeps its
#     protocol, and close is an EOF at the peer;
#   * a full send buffer is Pending with the write token, and a peer that
#     closes with bytes unread is a reset the next read reports.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, Reactor
from komira_async.reactor.socket_io import (
    TRY_IO_ERROR,
    TRY_IO_IN_PROGRESS,
    TRY_IO_READY,
    TRY_IO_WOULD_BLOCK,
    TryIoResult,
)
from komira_async.reactor.socket_setup import inet_loopback_be
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.tcp_stream import TcpListener, TcpStream

from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2, StreamIo
from komira_http_core.transport.kernel_tcp import KernelTcpConnector, TcpIoStream

comptime RT = PerCoreAsyncRuntime[NoopSink]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var r = s.as_bytes()
    for i in range(len(r)):
        out.append(r[i])
    return out^


def _text(buf: List[UInt8], n: Int) -> String:
    var s = String()
    for i in range(n):
        s += chr(Int(buf[i]))
    return s^


def _read_ready(
    mut c: TcpIoStream, mut reactor: Reactor[NoopSink], cap: Int,
) raises -> String:
    """try_read until Ready (driving the reactor on Pending, bounded)."""
    var buf = List[UInt8](length=cap, fill=UInt8(0))
    var r = c.try_read[RT](reactor=reactor, dst=Span[UInt8](buf))
    var guard = 0
    while r.is_pending() and guard < 50:
        _ = reactor.poll_completions(timeout_us=Int32(100_000))
        r = c.try_read[RT](reactor=reactor, dst=Span[UInt8](buf))
        guard += 1
    assert_true(r.is_ready(), "read did not become ready")
    return _text(buf, Int(r.n_bytes()))


def test_pushback_order_and_partial_drain() raises:
    """Bytes already on the socket ("xy") wait behind the pushback; a second
    unread ("AB") goes in front of the first ("CD"); a 3-byte read takes
    "ABC" and leaves "D", which the next read serves alone, before "xy"."""
    comptime if not CompilationTarget.is_linux():
        return
    var listener = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(4))
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    var conn = KernelTcpConnector.new()
    var client = conn.connect[RT](
        reactor=reactor, ip_be=inet_loopback_be(), port=listener.local_port(),
    )
    var ar = listener.try_accept()
    assert_true(ar.is_ready())
    var server = TcpStream(Int32(Int(ar.value())))

    # Nothing sent yet: Pending, with the read token.
    var empty = List[UInt8](length=4, fill=UInt8(0))
    var p = client.try_read[RT](reactor=reactor, dst=Span[UInt8](empty))
    assert_true(p.is_pending())
    assert_equal(p.pending_token(), Int64(client.fd()) << 1)

    var xy = _bytes(String("xy"))
    assert_equal(server.write[NoopSink](reactor, Span[UInt8](xy)), Int64(2))

    assert_false(client.has_buffered_readable())
    var none = List[UInt8]()
    client.unread(Span[UInt8](none))
    assert_false(client.has_buffered_readable())
    var cd = _bytes(String("CD"))
    client.unread(Span[UInt8](cd))
    var ab = _bytes(String("AB"))
    client.unread(Span[UInt8](ab))
    assert_true(client.has_buffered_readable())

    assert_equal(_read_ready(client, reactor, 3), String("ABC"))
    assert_true(client.has_buffered_readable())
    assert_equal(_read_ready(client, reactor, 8), String("D"))
    assert_false(client.has_buffered_readable())
    assert_equal(_read_ready(client, reactor, 8), String("xy"))

    # A zero-length destination does not touch the pushback.
    client.unread(Span[UInt8](cd))
    var zero = List[UInt8]()
    _ = client.try_read[RT](reactor=reactor, dst=Span[UInt8](zero))
    assert_true(client.has_buffered_readable())
    assert_equal(_read_ready(client, reactor, 8), String("CD"))


def test_zero_length_write_is_ready_zero() raises:
    """send of zero bytes returns 0: on the write side that is Ready(0),
    never the Eof a zero-byte read means."""
    comptime if not CompilationTarget.is_linux():
        return
    var listener = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(4))
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    var conn = KernelTcpConnector.new()
    var client = conn.connect[RT](
        reactor=reactor, ip_be=inet_loopback_be(), port=listener.local_port(),
    )
    var ar = listener.try_accept()
    assert_true(ar.is_ready())
    var _server = TcpStream(Int32(Int(ar.value())))
    var none = List[UInt8]()
    var w = client.try_write[RT](reactor=reactor, src=Span[UInt8](none))
    assert_true(w.is_ready())
    assert_false(w.is_eof())
    assert_equal(w.n_bytes(), Int64(0))


def _row(
    mut states: List[UInt8], mut values: List[Int64], mut writes: List[Bool],
    state: UInt8, value: Int64, is_write: Bool,
):
    states.append(state)
    values.append(value)
    writes.append(is_write)


def test_map_error_and_pending_tokens() raises:
    """An error result carries its errno on either side; WouldBlock and
    InProgress are Pending, with bit 0 of the token set only for a write;
    Ready(0) is Ready(0) for a write and Eof for a read.
    The rows are read from lists, so no argument is a compile-time
    constant at the (inlined) mapping."""
    var states = List[UInt8]()
    var values = List[Int64]()
    var writes = List[Bool]()
    _row(states, values, writes, TRY_IO_ERROR, Int64(104), False)
    _row(states, values, writes, TRY_IO_ERROR, Int64(32), True)
    _row(states, values, writes, TRY_IO_WOULD_BLOCK, Int64(0), True)
    _row(states, values, writes, TRY_IO_IN_PROGRESS, Int64(0), False)
    _row(states, values, writes, TRY_IO_IN_PROGRESS, Int64(0), True)
    _row(states, values, writes, TRY_IO_WOULD_BLOCK, Int64(0), False)
    _row(states, values, writes, TRY_IO_READY, Int64(0), True)
    _row(states, values, writes, TRY_IO_READY, Int64(0), False)
    _row(states, values, writes, TRY_IO_READY, Int64(5), False)
    var tokens = List[Int64]()
    tokens.append(Int64(-1))
    tokens.append(Int64(-1))
    tokens.append(Int64(43))
    tokens.append(Int64(42))
    tokens.append(Int64(43))
    tokens.append(Int64(42))
    var kinds = List[Int]()  # 0 error, 1 pending, 2 ready, 3 eof
    for _ in range(2):
        kinds.append(0)
    for _ in range(4):
        kinds.append(1)
    kinds.append(2)
    kinds.append(3)
    kinds.append(2)
    for i in range(len(states)):
        var m = TcpIoStream._map_try_io_to_stream_io(
            TryIoResult(_state=states[i], _value=values[i]),
            fd=Int32(21), is_write=writes[i],
        )
        if kinds[i] == 0:
            assert_true(m.is_error(), String(i))
            assert_equal(m.errno(), values[i])
        elif kinds[i] == 1:
            assert_true(m.is_pending(), String(i))
            assert_equal(m.pending_token(), tokens[i], String(i))
        elif kinds[i] == 2:
            assert_true(m.is_ready(), String(i))
            assert_equal(m.n_bytes(), values[i])
        else:
            assert_true(m.is_eof(), String(i))


def test_connector_and_stream_surface() raises:
    """Kernel TCP is not TLS and ignores a dial host; the two-argument
    constructor keeps the negotiated protocol it is given; close drops the
    connection, which the peer reads as EOF."""
    comptime if not CompilationTarget.is_linux():
        return
    var conn = KernelTcpConnector.new()
    assert_false(conn.is_tls())
    conn.set_dial_host(String("origin.example.com"))
    assert_false(conn.is_tls())
    var listener = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(4))
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    var client = conn.connect[RT](
        reactor=reactor, ip_be=inet_loopback_be(), port=listener.local_port(),
    )
    var ar = listener.try_accept()
    assert_true(ar.is_ready())
    var peer = TcpIoStream(TcpStream(Int32(Int(ar.value()))), NEGOTIATED_HTTP_2)
    assert_equal(Int(peer.negotiated_protocol()), Int(NEGOTIATED_HTTP_2))
    client^.close()
    var buf = List[UInt8](length=4, fill=UInt8(0))
    var r = peer.try_read[RT](reactor=reactor, dst=Span[UInt8](buf))
    var guard = 0
    while r.is_pending() and guard < 50:
        _ = reactor.poll_completions(timeout_us=Int32(100_000))
        r = peer.try_read[RT](reactor=reactor, dst=Span[UInt8](buf))
        guard += 1
    assert_true(r.is_eof())


def test_real_write_would_block_and_reset() raises:
    """Through the socket rather than a constructed result: writing 64 KiB
    at a time to a peer that never reads ends in Pending with the write
    token; the peer then closing with those bytes unread sends a reset,
    which the next read reports as Error(ECONNRESET = 104)."""
    comptime if not CompilationTarget.is_linux():
        return
    var listener = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(4))
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    var conn = KernelTcpConnector.new()
    var client = conn.connect[RT](
        reactor=reactor, ip_be=inet_loopback_be(), port=listener.local_port(),
    )
    var ar = listener.try_accept()
    assert_true(ar.is_ready())
    var server = TcpStream(Int32(Int(ar.value())))
    var chunk = List[UInt8](length=65536, fill=UInt8(0x5A))
    var w = client.try_write[RT](reactor=reactor, src=Span[UInt8](chunk))
    var rounds = 0
    while w.is_ready() and rounds < 4096:
        w = client.try_write[RT](reactor=reactor, src=Span[UInt8](chunk))
        rounds += 1
    assert_true(w.is_pending(), "the send buffer never filled")
    assert_equal(w.pending_token(), (Int64(client.fd()) << 1) | Int64(1))
    _ = server^
    var buf = List[UInt8](length=16, fill=UInt8(0))
    var r = client.try_read[RT](reactor=reactor, dst=Span[UInt8](buf))
    var guard = 0
    while r.is_pending() and guard < 50:
        _ = reactor.poll_completions(timeout_us=Int32(100_000))
        r = client.try_read[RT](reactor=reactor, dst=Span[UInt8](buf))
        guard += 1
    assert_true(r.is_error(), "expected a reset")
    assert_equal(r.errno(), Int64(104))


def main() raises:
    test_pushback_order_and_partial_drain()
    test_zero_length_write_is_ready_zero()
    test_map_error_and_pending_tokens()
    test_connector_and_stream_surface()
    test_real_write_would_block_and_reset()
    print("PASS test_cov_kernel_tcp_pushback")
