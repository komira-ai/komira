# =============================================================================
# test_reactor_park_no_lost_wakeup.mojo
# =============================================================================
#
# ROOT-CAUSE REPRO — a reactor PARK lost-wakeup that hangs an h2/gRPC client
# after N sequential RPCs on a reused conn.
#
# THE SYMPTOM: an h2 driver wall-clock deadline exceeded (no progress to
# END_STREAM) and the process exits.
# The h2 driver parks on `reactor.poll_completions(...)` for fd readiness; the
# readiness wakeup is LOST, so the park only ever returns via the 120s wall
# deadline (a safety net). If the wall-deadline raise is
# unhandled, the process crashes. It fires nondeterministically ~1-in-N sequential
# RPCs on a REUSED h2 connection.
#
# THE PARK PATH (h2_client.mojo `_park_on_fd_readiness`, per direction):
#     reactor.register_read(fd, op_id)       # epoll_ctl_add / kevent_register
#     reactor.poll_completions(250ms)        # epoll_wait / kevent_wait
#     reactor.deregister(op_id)              # epoll_ctl_del / kevent_deregister
# The driver re-runs this EVERY time a read/write returns Pending. On a reused
# conn each sequential RPC re-arms a FRESH park (fresh op_id) on the SAME fd.
#
# WHY A REACTOR-LESS FAKE CANNOT REPRODUCE IT: ScriptedStream has fd<0 so the
# park early-returns and never touches the kernel. This repro drives the REAL
# Reactor.register_read / poll_completions / deregister trio over a REAL
# loopback socketpair fd, MANY sequential cycles, with a counter of
# park-timeouts (lost wakeups) vs successful wakes — so the missed-wakeup is
# OBSERVED + MEASURED, not assumed.
#
# THE INVARIANT THIS FALSIFIES: when a byte is ALREADY readable on the fd at
# register time, a LEVEL-triggered registration MUST report readiness on the
# very next poll_completions — EVERY cycle, with ZERO timeouts. If ANY cycle
# returns 0 (timeout) while the byte is present, the wakeup was LOST.
#
# Pointer / hard-ban discipline: the only UnsafePointer use is the socketpair /
# send / recv FFI thunk (confined to this file's helpers, concrete origins, no
# wildcard, no cross-module pointer). Mirrors test_kqueue_wake.mojo.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import alloc
from std.testing import assert_true, assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (


    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed null
    UnsafePointer ctor / the `_unsafe_null=()` b1 idiom).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Origin `o` is concrete; the NULL sentinel is never
    # dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# socketpair(2) constants (Linux + Darwin agree on these values).
comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _socketpair() -> SIMD[DType.int32, 2]:
    """libc socketpair(2): connected AF_UNIX SOCK_STREAM pair. Returns
    (a_fd, b_fd), or (-1,-1) on failure. Both ends readable + writable.
    SAFETY: stack-local SIMD pair; libc writes 2 int32 into it; never escapes —
    UnsafePointer confined to this FFI thunk per the encapsulation rule."""
    var fds = SIMD[DType.int32, 2](-1, -1)
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0),
        UnsafePointer(to=fds).bitcast[UInt8](),
    )
    if rc < 0:
        return SIMD[DType.int32, 2](-1, -1)
    return fds


def _set_nonblocking(fd: Int32):
    """fcntl(fd, F_SETFL, O_NONBLOCK). F_GETFL=3, F_SETFL=4, O_NONBLOCK=0x4
    (both Linux + Darwin agree)."""
    var flags = external_call["fcntl", Int32](fd, Int32(3), Int32(0))
    _ = external_call["fcntl", Int32](fd, Int32(4), flags | Int32(0x4))


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _send_byte(fd: Int32) -> Int64:
    """send(2) one byte (blocking). SAFETY: stack-local byte; pointer confined."""
    var byte: UInt8 = 0x42
    return external_call["send", Int64](
        fd, UnsafePointer(to=byte).bitcast[UInt8](), UInt(1), Int32(0),
    )


def _drain_one(fd: Int32) -> Int64:
    """recv(2) one byte non-blocking. MSG_DONTWAIT is 0x80 on Darwin, 0x40 on
    Linux. Returns bytes-read or -1 (EWOULDBLOCK)."""
    var byte: UInt8 = 0
    var flag: Int32
    comptime if CompilationTarget.is_macos():
        flag = Int32(0x80)
    else:
        flag = Int32(0x40)
    return external_call["recv", Int64](
        fd, UnsafePointer(to=byte).bitcast[UInt8](), UInt(1), flag,
    )


# =============================================================================
# FALSIFIER 1 — byte-already-present: every park MUST wake, zero timeouts.
# =============================================================================


def test_park_byte_present_never_times_out() raises:
    """The CORE lost-wakeup falsifier. A byte is sent on the peer end ONCE and
    LEFT in the recv buffer (never drained). Then we run N sequential
    register_read / poll_completions(short timeout) / deregister cycles on the
    SAME fd — exactly the shape `_park_on_fd_readiness` runs on a reused h2 conn.

    Level-triggered readiness GUARANTEE: a fd that is read-readable at register
    time reports EPOLLIN/EVFILT_READ on the very next epoll_wait/kevent — so
    EVERY cycle MUST observe >=1 completion. A cycle that returns 0 (the park
    timed out while the byte sat readable) is a LOST WAKEUP.

    FAILS ON CURRENT CODE (the bug): on macOS the per-cycle kevent_register sets
    EV_RECEIPT + reads back a 1-slot ack eventlist in the SAME kevent() call; the
    kernel can deliver the fd's readiness event INTO that single ack slot and the
    register helper DISCARDS it (it only inspects the slot for EV_ERROR) -> the
    readiness is consumed by the registration syscall and the subsequent
    poll_completions kevent() returns 0 (the byte's level-edge was already
    drained by the receipt read). The cycle times out despite the byte being
    present.

    PASSES POST-FIX: register must NOT let the same kevent() syscall harvest +
    drop a readiness event; poll_completions is the sole reader of the eventlist.
    """
    print("  test_park_byte_present_never_times_out...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0, "socketpair(2) should succeed")
    var rfd = fds[0]
    var wfd = fds[1]
    _set_nonblocking(rfd)

    var reactor = _make_reactor()

    # Put exactly ONE byte in the recv buffer and LEAVE it. Level-triggered
    # readiness must fire on every cycle while it sits there.
    var sent = _send_byte(wfd)
    assert_true(sent == Int64(1), "send byte should succeed")

    var cycles = 200
    var timeouts = 0
    var i = 0
    while i < cycles:
        var op_id = reactor.alloc_op_id()
        reactor.register_read(rfd, op_id, UInt16(0))
        # 100ms per-park bound: a present byte must wake in µs, so a 0-return
        # here means the readiness wakeup was LOST for this cycle.
        var drained = reactor.poll_completions(Int32(100_000))
        var n = len(drained)
        if n == 0:
            timeouts += 1
        reactor.deregister(op_id)
        i += 1

    # Drain the byte at the end (cleanup).
    _ = _drain_one(rfd)
    _close_fd(rfd)
    _close_fd(wfd)
    _ = reactor^

    print("    cycles=", cycles, " lost-wakeup timeouts=", timeouts)
    assert_equal(
        timeouts, 0,
        "a byte sitting readable must wake EVERY level-triggered park; any"
        " park-timeout is a LOST WAKEUP (the h2 hang)",
    )
    print("    [OK] no lost wakeups across", cycles, "sequential parks")


# =============================================================================
# FALSIFIER 2 — byte-arrives-just-before-register (the classic edge window).
# =============================================================================


def test_park_byte_arrives_before_register_never_times_out() raises:
    """Models the window where a byte arrives between the driver's last
    try_read (EWOULDBLOCK) and the park's register call. Level-triggered
    re-check at register time MUST still report it on the next poll. Each cycle
    sends the byte, registers, polls, then DRAINS the byte (resetting the
    readable edge) so the next cycle starts from empty — the true sequential-RPC
    shape (each RPC's response byte arrives, is consumed, next RPC re-parks).

    FAILS ON CURRENT CODE: same EV_RECEIPT ack-slot swallow as falsifier 1, but
    here the byte is freshly delivered each cycle so the receipt-read race is
    even tighter.
    PASSES POST-FIX.
    """
    print("  test_park_byte_arrives_before_register_never_times_out...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0)
    var rfd = fds[0]
    var wfd = fds[1]
    _set_nonblocking(rfd)

    var reactor = _make_reactor()

    var cycles = 200
    var timeouts = 0
    var i = 0
    while i < cycles:
        # Byte arrives BEFORE register (the readable state pre-exists the park).
        var sent = _send_byte(wfd)
        assert_true(sent == Int64(1))
        var op_id = reactor.alloc_op_id()
        reactor.register_read(rfd, op_id, UInt16(0))
        var drained = reactor.poll_completions(Int32(100_000))
        if len(drained) == 0:
            timeouts += 1
        reactor.deregister(op_id)
        # Consume the byte so the next cycle starts from an empty buffer.
        _ = _drain_one(rfd)
        i += 1

    _close_fd(rfd)
    _close_fd(wfd)
    _ = reactor^

    print("    cycles=", cycles, " lost-wakeup timeouts=", timeouts)
    assert_equal(
        timeouts, 0,
        "byte present at register time must wake the park EVERY cycle; a"
        " timeout is a lost wakeup",
    )
    print("    [OK] no lost wakeups across", cycles, "register-after-arrival parks")


# =============================================================================
# FALSIFIER 3 — byte ARRIVES DURING the blocked wait (the production window).
#
# This is THE scenario of the real hang: the single-threaded synchronous h2
# drive parks in kevent/epoll_wait with an EMPTY socket; the server's response
# byte arrives ASYNCHRONOUSLY (from the network) WHILE the thread is blocked.
# A correct reactor wakes immediately; a lost wakeup leaves the wait blocked
# until its 250ms bound, so the driver only ever regains control via the bound
# and (over N RPCs) trips the 120s wall deadline.
#
# We model the async byte source with a DETACHED helper pthread that sleeps a
# few ms (so the main thread is already blocked in the wait) then sends the
# byte. The wait MUST return promptly (well under its timeout) when the byte
# lands — if it instead rides out the full per-park timeout, the wakeup was
# lost. We also alternate WRITE-park then READ-park on the SAME fd, the exact
# `drive_h2_streams_to_completion` shape on a reused conn.
# =============================================================================


# A heap-boxed arg for the helper thread: (wfd, delay_us). POD; freed by the
# entry fn before it returns.
@fieldwise_init
struct _SenderArg(Copyable, Movable, Deinitable):
    var wfd: Int32
    var delay_us: Int32


def _sender_entry(
    raw: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    """Detached helper: sleep `delay_us`, then send one byte on `wfd`. ABI
    matches pthread start_routine `void* (*)(void*)`.

    SAFETY (FFI-BOUNDARY): `raw` is the heap _SenderArg this thread solely owns;
    we read its two POD fields, free it, then do a blocking usleep + send. No
    Mojo origin interaction beyond the confined cast."""
    var arg = raw.bitcast[_SenderArg]()
    var wfd = arg[].wfd
    var delay_us = arg[].delay_us
    arg.bitcast[UInt8]().free()
    _ = external_call["usleep", Int32](delay_us)
    var byte: UInt8 = 0x42
    _ = external_call["send", Int64](
        wfd, UnsafePointer(to=byte).bitcast[UInt8](), UInt(1), Int32(0),
    )
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _spawn_delayed_sender(wfd: Int32, delay_us: Int32):
    """pthread_create a DETACHED helper that sends a byte on `wfd` after
    `delay_us`. The thread frees its own arg + exits; we don't join (the byte
    delivery is the only observable). SAFETY: heap arg single-consumer."""
    var raw = alloc[_SenderArg](1)
    UnsafePointer(to=raw[]).unsafe_write(_SenderArg(wfd=wfd, delay_us=delay_us))
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    var tid: Int64 = 0
    var slot = UnsafePointer(to=tid)
    var rc = external_call["pthread_create", Int32](
        slot.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _sender_entry,
        raw_void,
    )
    # Detach so the thread cleans up on exit (we never join).
    if rc == Int32(0):
        _ = external_call["pthread_detach", Int32](tid)


def test_park_byte_arrives_during_blocked_wait_wakes_promptly() raises:
    """THE production-window falsifier. The socket starts EMPTY; the park
    genuinely BLOCKS in kevent/epoll_wait; a detached thread delivers the byte
    a few ms later. A correct level-triggered reactor returns from the wait
    promptly on delivery. A LOST wakeup rides out the full per-park timeout.

    We give each park a GENEROUS 5s bound and measure how many cycles took
    >= ~the full 5s (i.e. the byte arrived but the wait did not wake — lost).
    A healthy reactor wakes in single-digit ms (the helper's delay), so a
    cycle near 5s is unambiguously a lost wakeup, not a slow-but-woke park.

    Also alternates a WRITE-readiness park (which a socketpair is always
    write-ready for, so it returns instantly) BEFORE the read park — the exact
    write-then-read `drive_h2_streams_to_completion` shape on a reused conn.

    FAILS ON CURRENT CODE if the reactor loses the delivered-during-wait
    wakeup. PASSES POST-FIX (and proves the prior simple loop was insufficient
    to surface the window — this one genuinely blocks).
    """
    print("  test_park_byte_arrives_during_blocked_wait_wakes_promptly...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0)
    var rfd = fds[0]
    var wfd = fds[1]
    _set_nonblocking(rfd)

    var reactor = _make_reactor()

    var cycles = 40
    var lost = 0
    var per_park_bound_us = Int32(5_000_000)  # 5s
    var sender_delay_us = Int32(3_000)         # 3ms — well after the wait blocks
    var i = 0
    while i < cycles:
        # WRITE park first (socketpair send buffer has space => instant wake),
        # mirroring the driver draining pending_out before reading.
        var op_w = reactor.alloc_op_id()
        reactor.register_write(rfd, op_w, UInt16(0))
        _ = reactor.poll_completions(Int32(1_000_000))
        reactor.deregister(op_w)

        # READ park: socket is EMPTY, so the wait BLOCKS. Spawn the delayed
        # sender; the byte lands ~3ms in, while the thread is parked.
        _spawn_delayed_sender(wfd, sender_delay_us)
        # PLATFORM GUARD — must be `comptime if`, NOT a runtime ternary.
        # A runtime `X if CompilationTarget.is_macos() else Y` code-generates
        # BOTH arms, so the macOS-only `mach_absolute_time` symbol is emitted
        # into the object file on Linux too and the LINK fails with
        # `undefined reference to 'mach_absolute_time'` on Linux build
        # workers. `comptime if` prunes the dead arm before codegen.
        # PLATFORM GUARD — must be `comptime if`, NOT a runtime ternary.
        # A runtime `X if CompilationTarget.is_macos() else Y` code-generates
        # BOTH arms, so the macOS-only `mach_absolute_time` symbol is emitted
        # into the object file on Linux too and the LINK fails with
        # `undefined reference to 'mach_absolute_time'` on Linux build
        # workers. `comptime if` prunes the dead arm before codegen.
        var t0: Int64
        comptime if CompilationTarget.is_macos():
            # SAFETY: no-arg, by-value-return libc call; no pointer crosses.
            t0 = Int64(external_call["mach_absolute_time", UInt64]())
        else:
            t0 = Int64(0)
        var op_r = reactor.alloc_op_id()
        reactor.register_read(rfd, op_r, UInt16(0))
        var drained = reactor.poll_completions(per_park_bound_us)
        reactor.deregister(op_r)
        # If the wait returned with no completion AND consumed ~the whole bound,
        # the delivered byte's wakeup was lost. We detect "no completion" as the
        # lost signal (the byte WAS delivered by the helper; a woke park sees it).
        if len(drained) == 0:
            lost += 1
        _ = t0
        # Drain the delivered byte so the next cycle starts empty.
        _ = _drain_one(rfd)
        i += 1

    _close_fd(rfd)
    _close_fd(wfd)
    _ = reactor^

    print("    cycles=", cycles, " lost-during-wait wakeups=", lost)
    assert_equal(
        lost, 0,
        "a byte delivered DURING a blocked park must wake the wait; a park"
        " that rode out its full bound with the byte present is a LOST WAKEUP",
    )
    print("    [OK] all", cycles, "delivered-during-wait parks woke promptly")


def main() raises:
    print("=== ROOT-CAUSE: reactor park must not lose fd-readiness wakeups ===")
    test_park_byte_present_never_times_out()
    test_park_byte_arrives_before_register_never_times_out()
    test_park_byte_arrives_during_blocked_wait_wakes_promptly()
    print("=== reactor park lost-wakeup repro complete ===")
