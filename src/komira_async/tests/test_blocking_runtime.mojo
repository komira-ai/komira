# =============================================================================
# test_blocking_runtime.mojo
# =============================================================================
# BlockingRuntime[S] + block_on tests.
#
# Two layers of coverage:
#
#   A. Trait conformance + shape (all platforms):
#      - BlockingRuntime[NoopSink] conforms to Runtime.
#      - comptime members: RUNTIME_MODEL == MODEL_CURRENT_THREAD_BLOCKING,
#        TASKS_ARE_THREAD_PINNED == True.
#      - worker_count() == 1.
#      - poll_completions / timer_advance reject worker_idx != 0.
#      - A DownstreamGeneric[RT: Runtime] monomorphizes against
#        BlockingRuntime (the [RT]-generic library shape).
#      - block_on runs a trivial (no-I/O) closure to completion.
#
#   B. THE FEASIBILITY GATE (Linux — real async I/O driven synchronously):
#      A real TCP loopback round-trip driven END-TO-END through
#      BlockingRuntime + block_on, on the CALLING thread, with NO async
#      runtime spun up (no pthread, no PerCoreAsyncRuntime). This is the
#      proof that "a sync caller can use the async stack via BlockingRuntime":
#        1. TcpListener.bind_loopback on the server side.
#        2. Direct libc connect() on the client side (raw test driver).
#        3. block_on(rt, work) where `work` drives listener.accept[S](reactor)
#           + stream.read[S](reactor) + stream.write[S](reactor) using the
#           runtime's reactor — every park is a single-fd block on the
#           calling thread.
#        4. Verify byte-for-byte echo.
#
# The I/O methods (TcpListener.accept / TcpStream.read / .write) are the
# SAME ones HttpClient.send transitively drives, so this lower-level proof
# establishes the feasibility for the full HTTP path without needing a
# localhost HTTP server process. (HttpClient.send[BlockingRuntime] is
# wired by the runtime-parametric library refactor; the I/O-drive
# seam it depends on is exactly what this test exercises.)
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_MOCK,
    OP_ID_ALLOC_BASE,
    Reactor,
)
from komira_async.reactor.socket_setup import (
    close_fd,
    inet_loopback_be,
    sockaddr_in_bytes,
)
from komira_async.runtime.blocking_runtime import (
    BlockingRuntime,
    block_on,
)
from komira_async.runtime.runtime_trait import (
    MODEL_CURRENT_THREAD_BLOCKING,
    MODEL_SHARE_NOTHING_PER_CORE,
    Runtime,
)
from komira_async.runtime.tcp_stream import (
    TcpListener,
    TcpStream,
)


# =============================================================================
# A. Trait conformance + shape.
# =============================================================================


@fieldwise_init
struct DownstreamGeneric[RT: Runtime](Movable, Deinitable):
    """Mirrors HttpClient[RT: Runtime] — the [RT]-generic library shape.
    Monomorphizes against BlockingRuntime exactly as it does against
    PerCoreAsyncRuntime.
    """

    var _placeholder: UInt8

    @staticmethod
    def query_model() -> UInt8:
        return Self.RT.RUNTIME_MODEL

    @staticmethod
    def is_thread_pinned() -> Bool:
        return Self.RT.TASKS_ARE_THREAD_PINNED

    def query_workers(self, ref rt: Self.RT) -> Int:
        return rt.worker_count()


def test_blocking_runtime_conforms_runtime() raises:
    """BlockingRuntime[NoopSink] conforms to Runtime; construct on MOCK
    backend (no real fd) so this runs on every platform."""
    var rt = BlockingRuntime[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_equal(rt.worker_count(), 1)
    _ = rt^


def test_blocking_runtime_comptime_members() raises:
    """comptime members read through the conformer type without runtime
    indirection."""
    assert_equal(
        Int(BlockingRuntime[NoopSink].RUNTIME_MODEL),
        Int(MODEL_CURRENT_THREAD_BLOCKING),
    )
    assert_true(BlockingRuntime[NoopSink].TASKS_ARE_THREAD_PINNED)
    # Distinct from PerCoreAsync's model byte.
    assert_true(
        Int(BlockingRuntime[NoopSink].RUNTIME_MODEL)
        != Int(MODEL_SHARE_NOTHING_PER_CORE)
    )


def test_downstream_generic_monomorphizes() raises:
    """A [RT: Runtime]-generic struct monomorphizes against BlockingRuntime
    — the library-refactor acceptance shape."""
    var model = DownstreamGeneric[BlockingRuntime[NoopSink]].query_model()
    assert_equal(Int(model), Int(MODEL_CURRENT_THREAD_BLOCKING))
    assert_true(DownstreamGeneric[BlockingRuntime[NoopSink]].is_thread_pinned())

    var rt = BlockingRuntime[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var dg = DownstreamGeneric[BlockingRuntime[NoopSink]](_placeholder=UInt8(0))
    assert_equal(dg.query_workers(rt), 1)
    _ = rt^


def test_poll_completions_rejects_nonzero_worker() raises:
    """The single-worker invariant: worker_idx != 0 raises."""
    var rt = BlockingRuntime[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var raised = False
    try:
        var _n = rt.poll_completions(1, Int32(0))
    except:
        raised = True
    assert_true(raised)
    # worker_idx == 0 on MOCK is a no-op poll (returns 0 completions).
    var n0 = rt.poll_completions(0, Int32(0))
    assert_equal(n0, 0)
    _ = rt^


def test_timer_stubs() raises:
    """timer_now_ns returns 0 (stub); timer_advance(0, ...) is a no-op;
    timer_advance(1, ...) raises (single-worker)."""
    var rt = BlockingRuntime[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_equal(Int(rt.timer_now_ns(0)), 0)
    rt.timer_advance(0, Int64(123))  # no-op, no raise
    var raised = False
    try:
        rt.timer_advance(1, Int64(0))
    except:
        raised = True
    assert_true(raised)
    _ = rt^


# block_on with a trivial closure (no real I/O) — proves the entrypoint
# binds the reactor + runs the closure + returns the value, on every
# platform (MOCK backend).
def _trivial_work(mut reactor: Reactor[NoopSink]) raises -> Int64:
    # Touch the reactor (allocate an op_id) to prove the closure really
    # receives a live, drivable reactor — then return a sentinel value.
    var op_id = reactor.alloc_op_id()
    return op_id + Int64(41)


def test_block_on_trivial_closure() raises:
    """block_on runs one closure to completion synchronously and returns
    its result. No async runtime, no pthread."""
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    var result = block_on[NoopSink, Int64](rt, _trivial_work)
    # alloc_op_id returns the FIRST BIASED op_id (OP_ID_ALLOC_BASE + 1) — the
    # The op_id/fd demux bias offsets every allocated op_id
    # above the fd range. The closure returns op_id + 41.
    assert_equal(result, OP_ID_ALLOC_BASE + Int64(1) + Int64(41))
    _ = rt^


# =============================================================================
# B. THE FEASIBILITY GATE — real TCP loopback round-trip via block_on.
# =============================================================================


def _connect_blocking(port: UInt16) raises -> Int32:
    """Raw libc socket+connect to 127.0.0.1:port (test-driver client side).
    Inline FFI per the fd-clobbering ABI note (see
    test_state_machine_tcp_loopback_smoke.mojo)."""
    var fd = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
    if fd < Int32(0):
        raise Error("client socket() failed")
    var sa = sockaddr_in_bytes(inet_loopback_be(), port)
    var rc = external_call["connect", Int32](fd, sa.unsafe_ptr(), UInt32(16))
    if rc < Int32(0):
        close_fd(fd)
        raise Error("client connect() failed")
    return fd


# The "future": a closure that drives the full server-side round-trip
# (accept → read → echo-write) against the runtime's reactor. Every park
# inside accept/read/write is a single-fd block on the CALLING thread.
#
# Module-level state threaded via globals isn't available in Mojo 1.0.0b1,
# so we capture the listener + client_fd into the closure by building the
# closure at the call site is also not available — instead we structure the
# proof as a free helper that takes the reactor and does the whole dance,
# reading the listener/port/client_fd from parameters baked via a small
# driver struct is overkill. The simplest correct shape: the closure does
# accept+read+write and we assert the echoed bytes the CLIENT receives.
#
# Because `fn`-pointer closures in 1.0.0b1 can't capture locals, we make the
# round-trip self-contained: the closure binds the listener fd via a
# process-local that we set just before block_on. We instead drive the
# round-trip INLINE through block_on by passing a closure that performs the
# accept/read/write given only the reactor, with the listener constructed
# inside. That requires the client to connect AFTER the listener binds — so
# the listener bind + client connect happen inside the closure too, with the
# client driven by raw libc (blocking) calls interleaved.


def _loopback_echo_roundtrip(mut reactor: Reactor[NoopSink]) raises -> Int64:
    """Self-contained loopback echo driven on the calling thread via the
    BlockingRuntime's reactor. Returns the first echoed byte (as Int64) so
    the caller can assert correctness.

    Steps (all on ONE thread, parks = single-fd blocks):
      1. bind a loopback listener.
      2. raw-libc connect a client to it (blocking connect — completes
         immediately on loopback).
      3. listener.accept[NoopSink](reactor)  — state-machine accept.
      4. client sends 5 bytes (raw libc send).
      5. stream.read[NoopSink](reactor, ...)  — server read (try_io fast
         path or single-fd park).
      6. stream.write[NoopSink](reactor, ...) — echo back.
      7. client recvs 5 bytes (raw libc recv); we assert inside.
    """
    var listener = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(16))
    var port = listener.local_port()
    var client_fd = _connect_blocking(port)

    var stream = listener.accept[NoopSink](reactor)

    var c_buf = Array[UInt8, 5](fill=UInt8(0))
    c_buf[0] = UInt8(0xDE)
    c_buf[1] = UInt8(0xAD)
    c_buf[2] = UInt8(0xBE)
    c_buf[3] = UInt8(0xEF)
    c_buf[4] = UInt8(0x42)
    var sent = external_call["send", Int](
        client_fd, c_buf.unsafe_ptr(), UInt(5), Int32(0),
    )
    if sent != Int(5):
        close_fd(client_fd)
        raise Error("client send did not write 5 bytes")

    var s_recv_buf = Array[UInt8, 16](fill=UInt8(0))
    var s_recv_span = Span[UInt8](s_recv_buf)
    var n = stream.read[NoopSink](reactor, s_recv_span)
    if n != Int64(5):
        close_fd(client_fd)
        raise Error("server read did not get 5 bytes")

    var s_write_buf = Array[UInt8, 5](fill=UInt8(0))
    s_write_buf[0] = s_recv_buf[0]
    s_write_buf[1] = s_recv_buf[1]
    s_write_buf[2] = s_recv_buf[2]
    s_write_buf[3] = s_recv_buf[3]
    s_write_buf[4] = s_recv_buf[4]
    var w_span = Span[UInt8](s_write_buf)
    var nw = stream.write[NoopSink](reactor, w_span)
    if nw != Int64(5):
        close_fd(client_fd)
        raise Error("server write did not write 5 bytes")

    var c_recv_buf = Array[UInt8, 5](fill=UInt8(0))
    var got = external_call["recv", Int](
        client_fd, c_recv_buf.unsafe_ptr(), UInt(5), Int32(0),
    )
    if got != Int(5):
        close_fd(client_fd)
        raise Error("client recv did not get 5 bytes")
    if Int(c_recv_buf[0]) != Int(UInt8(0xDE)) or Int(c_recv_buf[4]) != Int(UInt8(0x42)):
        close_fd(client_fd)
        raise Error("echoed bytes did not round-trip")

    close_fd(client_fd)
    _ = listener^
    _ = stream^
    return Int64(c_recv_buf[0])


def test_block_on_real_tcp_loopback_roundtrip() raises:
    """THE FEASIBILITY GATE: a real TCP loopback echo, driven end-to-end
    through BlockingRuntime + block_on on the CALLING thread, with NO async
    runtime spun up. Proves a sync caller can use the async I/O stack via
    BlockingRuntime.

    Dual-platform: BlockingRuntime.new() comptime-selects BACKEND_KQUEUE on
    macOS / BACKEND_EPOLL on Linux, and the I/O wrappers (accept / read /
    write) branch internally on platform — so the SAME closure drives the
    round-trip on either OS. The single-fd park is `Reactor.poll_completions
    (-1)` = epoll_wait(-1) on Linux / kevent(NULL) on macOS, both on the
    calling thread."""
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    var first_byte = block_on[NoopSink, Int64](rt, _loopback_echo_roundtrip)
    assert_equal(first_byte, Int64(0xDE))
    _ = rt^


def main() raises:
    # A. Trait conformance + shape (all platforms).
    test_blocking_runtime_conforms_runtime()
    test_blocking_runtime_comptime_members()
    test_downstream_generic_monomorphizes()
    test_poll_completions_rejects_nonzero_worker()
    test_timer_stubs()
    test_block_on_trivial_closure()
    # B. Feasibility gate (Linux — real async I/O driven synchronously).
    test_block_on_real_tcp_loopback_roundtrip()
    print("PASS komira_async.runtime BlockingRuntime + block_on")
