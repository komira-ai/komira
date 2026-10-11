# =============================================================================
# tests/test_L2_stream_park_coverage.mojo: every line and branch of
# transport/stream_park.mojo
# =============================================================================
#
# `park_on_pending` is the one wait a driver does on an `IoStream` it owns.
# Its contract (the function's docstring) has five parts, and each group of
# tests below holds one of them against a real reactor and a real UNIX
# socket pair:
#
#   1. The wait direction is the STREAM's answer to
#      `pending_wait_is_write(token, call_is_write)`, not the call's.
#   2. The buffered-plaintext shortcut returns True without waiting, and only
#      for a READ call on a stream that says it holds readable bytes.
#   3. A stream with no pollable fd (`fd() < 0`) returns True without waiting.
#   4. The wait is bounded: an idle slice returns False only after the whole
#      `slice_us`, a zero slice or a zero poll cap returns False without
#      looking, and another fd's readiness on the same reactor neither ends
#      the slice nor counts as this stream's (invariant (ii)).
#   5. The transient registration is removed before the function returns.
#
# The socket pair gives both answers deterministically: an end whose peer has
# sent nothing is never read-ready (an idle read wait), and a fresh end with
# an empty send buffer is always write-ready (a ready write wait). No test
# sleeps; the only clock reads are lower bounds the function itself
# guarantees (it re-polls until its own clock says the slice is spent) and
# two upper bounds (half a 30 s slice) that are three orders of magnitude
# above the work.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_clock import now_ns

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.transport.io_stream import (
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
)
from komira_http_core.transport.scripted import ScriptedStream
from komira_http_core.transport.stream_park import (
    PARK_POLLS_PER_SLICE_DEFAULT,
    PARK_SLICE_DEFAULT_US,
    park_on_pending,
)


comptime _RT = PerCoreAsyncRuntime[NoopSink]

comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)

# An idle slice long enough that a park returning early is unmistakable, and
# short enough to keep the file fast.
comptime _IDLE_SLICE_US: Int32 = 100_000

# A slice no correct park in these tests comes near: used where the park must
# return through its poll cap, never through its clock.
comptime _LONG_SLICE_US: Int32 = 30_000_000


# =============================================================================
# Helpers
# =============================================================================


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _socketpair() raises -> Array[Int32, 2]:
    """SAFETY: `pair` is stack-local; the kernel writes two fds into it and
    does not keep the pointer."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr(),
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _send_one_byte(fd: Int32) raises:
    """SAFETY: `buf` is stack-local and outlives the call."""
    var buf = Array[UInt8, 1](fill=UInt8(0x5A))
    var w = external_call["send", Int](fd, buf.unsafe_ptr(), UInt(1), Int32(0))
    if w != Int(1):
        raise Error("send() failed")


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _elapsed_us(start_ns: UInt64) -> Int64:
    return (Int64(now_ns()) - Int64(start_ns)) // Int64(1000)


struct _ProbeStream(IoStream, Movable, Deinitable):
    """An `IoStream` whose three answers the park reads are set by the test.

    `token_is_direction=True` makes it answer `pending_wait_is_write` from
    bit 0 of the Pending token and ignore `call_is_write` (as
    `TlsClientStream` decodes the bit it wrote), so a test can ask for the
    direction OPPOSITE to the call. `False` makes it answer like the trait
    default (`return call_is_write`, the kernel-socket answer); the trait's
    own default body runs only in `_DefaultDirectionStream`, below. The park
    never reads or writes through the stream, so `try_read` and `try_write`
    raise."""

    var _fd: Int32
    var _buffered: Bool
    var _token_is_direction: Bool

    def __init__(out self, fd: Int32, buffered: Bool, token_is_direction: Bool):
        self._fd = fd
        self._buffered = buffered
        self._token_is_direction = token_is_direction

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        raise Error("_ProbeStream.try_read: the park must not read")

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        raise Error("_ProbeStream.try_write: the park must not write")

    def close(var self):
        pass

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_1_1

    def fd(self) -> Int32:
        return self._fd

    def has_buffered_readable(self) -> Bool:
        return self._buffered

    def pending_wait_is_write(
        self, pending_token: Int64, call_is_write: Bool,
    ) -> Bool:
        if self._token_is_direction:
            return (pending_token & Int64(1)) != Int64(0)
        return call_is_write


struct _DefaultDirectionStream(IoStream, Movable, Deinitable):
    """An `IoStream` that does NOT define `pending_wait_is_write` or
    `has_buffered_readable`, so the park runs the trait's own default bodies
    for both (as a kernel-socket conformer does)."""

    var _fd: Int32

    def __init__(out self, fd: Int32):
        self._fd = fd

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        raise Error("_DefaultDirectionStream.try_read: the park must not read")

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        raise Error("_DefaultDirectionStream.try_write: the park must not write")

    def close(var self):
        pass

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_1_1

    def fd(self) -> Int32:
        return self._fd


def _kernel_like(fd: Int32) -> _ProbeStream:
    """No buffered bytes; the direction is the call's (a probe answering
    like the trait default)."""
    return _ProbeStream(fd, buffered=False, token_is_direction=False)


def _token_directed(fd: Int32, buffered: Bool) -> _ProbeStream:
    """The direction is bit 0 of the token, whatever the call was."""
    return _ProbeStream(fd, buffered=buffered, token_is_direction=True)


comptime _TOKEN_WAIT_READ: Int64 = Int64(0b10)
comptime _TOKEN_WAIT_WRITE: Int64 = Int64(0b11)


def _assert_no_registration_left(mut reactor: Reactor[NoopSink]) raises:
    """A zero-timeout poll on a reactor holding no registration returns no
    completion; a registration left on a ready fd would (level-triggered)."""
    var left = reactor.poll_completions(timeout_us=Int32(0))
    assert_equal(len(left), 0)


# =============================================================================
# 1. The direction is the stream's answer
# =============================================================================


def test_trait_default_write_call_waits_for_write_and_is_ready() raises:
    """The trait's own `pending_wait_is_write` body (a conformer that does
    not define it), write call: the park waits for write readiness, which a
    fresh socket has, so it returns True. Waiting for read here would idle."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _DefaultDirectionStream(sp[0])
    assert_true(park_on_pending[_DefaultDirectionStream, _RT](
        s, reactor, pending_token=Int64(1), call_is_write=True,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_trait_default_read_call_on_quiet_socket_idles() raises:
    """The trait's own default body, read call, nothing sent: the park waits
    for read readiness and returns False. The token's bit 0 is set, so a
    default that decoded the token instead of the call would wait for write
    and return True."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _DefaultDirectionStream(sp[0])
    assert_false(park_on_pending[_DefaultDirectionStream, _RT](
        s, reactor, pending_token=_TOKEN_WAIT_WRITE, call_is_write=False,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_kernel_like_write_call_waits_for_write_and_is_ready() raises:
    """A probe answering like the trait default, write call: the park waits for write readiness, which a
    fresh socket has, so it returns True. Waiting for read here would idle."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    assert_true(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=True,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_kernel_like_read_call_on_quiet_socket_idles() raises:
    """A probe answering like the trait default, read call, nothing sent: the park waits for read
    readiness, never gets it, and returns False. Waiting for write here
    would return True at once."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    assert_false(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=False,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_kernel_like_read_call_with_a_byte_waiting_is_ready() raises:
    """A probe answering like the trait default, read call, one byte sent by the peer: read-ready, True.
    (Level-triggered: a byte that arrived before the registration counts.)"""
    var reactor = _make_reactor()
    var sp = _socketpair()
    _send_one_byte(sp[1])
    var s = _kernel_like(sp[0])
    assert_true(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=False,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_read_call_whose_stream_says_wait_write_is_ready() raises:
    """A read call whose stream answers "wait for write" (a TLS read blocked
    on a write) waits for write: True on a fresh socket. A park that used
    the call's direction would wait for read and idle."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _token_directed(sp[0], buffered=False)
    assert_true(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=_TOKEN_WAIT_WRITE, call_is_write=False,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_write_call_whose_stream_says_wait_read_idles() raises:
    """A write call whose stream answers "wait for read" (a TLS write blocked
    on a read) waits for read: nothing arrives, False. A park that used the
    call's direction would find the socket writable and return True."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _token_directed(sp[0], buffered=False)
    assert_false(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=_TOKEN_WAIT_READ, call_is_write=True,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


# =============================================================================
# 2. The buffered-plaintext shortcut: read calls only
# =============================================================================


def test_read_call_with_buffered_bytes_returns_true_without_waiting() raises:
    """A read call on a stream holding readable bytes above the fd returns
    True although the fd itself is not read-ready (the same stream and
    socket idle without the buffered bytes, below)."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _token_directed(sp[0], buffered=True)
    assert_true(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=_TOKEN_WAIT_READ, call_is_write=False,
        slice_us=_LONG_SLICE_US,
    ))
    _assert_no_registration_left(reactor)
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_read_call_without_buffered_bytes_parks() raises:
    """The control of the test above: no buffered bytes, the same read wait
    on the same quiet socket, and the park idles (False)."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _token_directed(sp[0], buffered=False)
    assert_false(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=_TOKEN_WAIT_READ, call_is_write=False,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_write_call_ignores_buffered_bytes() raises:
    """A write call is not unblocked by buffered plaintext: with buffered
    bytes, a write call whose stream says "wait for read" still parks on the
    quiet socket and idles (False), where the shortcut would return True."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _token_directed(sp[0], buffered=True)
    assert_false(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=_TOKEN_WAIT_READ, call_is_write=True,
        slice_us=_IDLE_SLICE_US,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


# =============================================================================
# 3. No pollable fd
# =============================================================================


def test_scripted_stream_has_no_fd_and_returns_true() raises:
    """`ScriptedStream` reports fd -1: readiness is unobservable, so the park
    returns True for a read and for a write, and registers nothing."""
    var reactor = _make_reactor()
    var s = ScriptedStream()
    assert_equal(s.fd(), Int32(-1))
    assert_true(park_on_pending[ScriptedStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=False,
        slice_us=_LONG_SLICE_US,
    ))
    assert_true(park_on_pending[ScriptedStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=True,
        slice_us=_LONG_SLICE_US,
    ))
    _assert_no_registration_left(reactor)


def test_fd_minus_one_with_a_read_wait_returns_true() raises:
    """fd -1 with a read wait and no buffered bytes: the one case where the
    fd test alone decides (a read wait on a real quiet fd would idle)."""
    var reactor = _make_reactor()
    var s = _token_directed(Int32(-1), buffered=False)
    assert_true(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=_TOKEN_WAIT_READ, call_is_write=False,
        slice_us=_LONG_SLICE_US,
    ))


# =============================================================================
# 4. The bound: slice, poll cap, and another fd's readiness
# =============================================================================


def test_idle_slice_waits_the_whole_slice() raises:
    """An idle read wait returns False and not before `slice_us` has passed
    on the monotonic clock: the park waits, it does not spin out. The poll
    cap (64) is far above the one or two polls a waiting park makes and far
    below what a non-waiting poll loop would need to fill the slice."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    var t0 = now_ns()
    var ready = park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=False,
        slice_us=_IDLE_SLICE_US, polls_per_slice_cap=64,
    )
    var waited = _elapsed_us(t0)
    assert_false(ready)
    assert_true(
        waited >= Int64(_IDLE_SLICE_US),
        "idle park returned after " + String(waited) + " us",
    )
    _assert_no_registration_left(reactor)
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_default_slice_is_250_ms() raises:
    """Called without `slice_us`, an idle read wait lasts at least
    `PARK_SLICE_DEFAULT_US`, which is 250 ms (the slice h2 documents)."""
    assert_equal(PARK_SLICE_DEFAULT_US, Int32(250_000))
    assert_equal(PARK_POLLS_PER_SLICE_DEFAULT, 4096)
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    var t0 = now_ns()
    var ready = park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=False,
    )
    var waited = _elapsed_us(t0)
    assert_false(ready)
    assert_true(
        waited >= Int64(PARK_SLICE_DEFAULT_US),
        "default park returned after " + String(waited) + " us",
    )
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_zero_slice_returns_false_without_polling() raises:
    """`slice_us=0` on a write-READY socket returns False: the spent slice
    ends the park before the first poll, so readiness is never looked at.
    (Against a `left_us <= 0` -> `< 0` mutant this goes red only when the
    park's two clock reads are less than 1000 ns apart, the normal case.)"""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    assert_false(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=True,
        slice_us=Int32(0),
    ))
    _assert_no_registration_left(reactor)
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_zero_poll_cap_returns_false_without_polling() raises:
    """`polls_per_slice_cap=0` on a write-ready socket returns False: no poll
    is allowed, so readiness is never looked at."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    assert_false(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=True,
        slice_us=_IDLE_SLICE_US, polls_per_slice_cap=0,
    ))
    _assert_no_registration_left(reactor)
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_one_poll_cap_sees_a_ready_socket() raises:
    """The boundary above: one poll is enough to see a write-ready socket."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    assert_true(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=True,
        slice_us=_IDLE_SLICE_US, polls_per_slice_cap=1,
    ))
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_ready_park_returns_at_once_not_at_the_slice_end() raises:
    """A park that sees its own readiness stops polling: on a write-ready
    socket with a 30 s slice and no effective poll cap, it returns True in
    far less than the slice. A loop that kept polling after the fd became
    ready would re-see the level-triggered readiness on every poll and run
    until the slice ended (30 s), then fail the time bound."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    var t0 = now_ns()
    var ready = park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=True,
        slice_us=_LONG_SLICE_US, polls_per_slice_cap=Int(1) << 40,
    )
    var waited = _elapsed_us(t0)
    assert_true(ready)
    assert_true(
        waited < Int64(_LONG_SLICE_US) // Int64(2),
        "ready park returned after " + String(waited) + " us",
    )
    _assert_no_registration_left(reactor)
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_foreign_readiness_storm_is_not_ours_and_the_cap_ends_it() raises:
    """Invariant (ii) and the CPU brake. Another fd on the same reactor is
    permanently read-ready (a byte is waiting, level-triggered), so every
    poll returns at once with a foreign completion. The park's own quiet fd
    never becomes ready: it returns False (the foreign readiness is not its
    own) after 8 polls, long before its 30 s slice (the poll cap, not the
    clock, ends it)."""
    var reactor = _make_reactor()
    var own = _socketpair()
    var foreign = _socketpair()
    _send_one_byte(foreign[1])
    var foreign_op = reactor.alloc_op_id()
    reactor.register_read(foreign[0], foreign_op, UInt16(0))
    var s = _kernel_like(own[0])
    var t0 = now_ns()
    var ready = park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=False,
        slice_us=_LONG_SLICE_US, polls_per_slice_cap=8,
    )
    var waited = _elapsed_us(t0)
    assert_false(ready)
    assert_true(
        waited < Int64(_LONG_SLICE_US) // Int64(2),
        "8 polls took " + String(waited) + " us",
    )
    assert_true(reactor.is_ready(foreign_op))
    reactor.deregister(foreign_op)
    _close_fd(own[0])
    _close_fd(own[1])
    _close_fd(foreign[0])
    _close_fd(foreign[1])


def test_foreign_wakeup_does_not_end_the_slice() raises:
    """Invariant (ii), the re-poll: a foreign one-shot timer fires 10 ms into
    a 100 ms idle park. The poll it ends is not this op's readiness, so the
    park re-polls for the rest of its slice and returns False only after
    the whole 100 ms. The timer's readiness is checked after one more
    zero-timeout poll, so a thread stalled past the slice before the park's
    first poll (the park then never polls) still observes the fired timer;
    that check is about the fixture, not the park."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var timer_op = reactor.register_timer(Int64(10_000_000))
    var s = _kernel_like(sp[0])
    var t0 = now_ns()
    var ready = park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=False,
        slice_us=_IDLE_SLICE_US,
    )
    var waited = _elapsed_us(t0)
    assert_false(ready)
    assert_true(
        waited >= Int64(_IDLE_SLICE_US),
        "park ended after " + String(waited) + " us",
    )
    var _drained = reactor.poll_completions(timeout_us=Int32(0))
    assert_true(reactor.is_ready(timer_op))
    reactor.deregister(timer_op)
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_closed_peer_is_read_ready() raises:
    """The documented hazard (path 3): a peer that closed leaves the socket
    permanently read-ready, so a read park returns True at once. The park
    cannot tell "ready" from "usable"; a caller that re-Pendings spins."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    _close_fd(sp[1])
    var s = _kernel_like(sp[0])
    assert_true(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=False,
        slice_us=_LONG_SLICE_US,
    ))
    _close_fd(sp[0])


# =============================================================================
# 5. The registration is removed
# =============================================================================


def test_ready_park_leaves_no_registration() raises:
    """After a park that saw its write-ready socket, a zero-timeout poll of
    the same reactor finds nothing: the transient registration was removed
    (left in place, the still-writable fd would complete again)."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    assert_true(park_on_pending[_ProbeStream, _RT](
        s, reactor, pending_token=Int64(0), call_is_write=True,
        slice_us=_IDLE_SLICE_US,
    ))
    _assert_no_registration_left(reactor)
    _close_fd(sp[0])
    _close_fd(sp[1])


def test_two_parks_on_one_fd_answer_alike() raises:
    """The same fd parked twice gives the same answer both times, for a
    ready write wait and then an idle read wait on one reactor."""
    var reactor = _make_reactor()
    var sp = _socketpair()
    var s = _kernel_like(sp[0])
    for _ in range(2):
        assert_true(park_on_pending[_ProbeStream, _RT](
            s, reactor, pending_token=Int64(0), call_is_write=True,
            slice_us=_IDLE_SLICE_US,
        ))
    for _ in range(2):
        assert_false(park_on_pending[_ProbeStream, _RT](
            s, reactor, pending_token=Int64(0), call_is_write=False,
            slice_us=Int32(20_000),
        ))
    _assert_no_registration_left(reactor)
    _close_fd(sp[0])
    _close_fd(sp[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
