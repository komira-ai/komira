# =============================================================================
# komira_async.reactor.epoll_subsystem — Linux epoll backend
# =============================================================================
# Per-platform comptime if
# guards. `comptime if CompilationTarget.is_linux()` is the canonical Mojo
# idiom; the deprecated `@parameter if os_is_linux()` form emits a
# deprecation warning. Both branches must type-check; only the host-matching
# branch enters codegen (verified via nm -D on the ELF binary — wrong-OS FFI
# symbols are ELIDED at codegen).
#
# Wrong-OS branch discipline: the Linux branch contains
# the FFI; the macOS branch must NOT contain any external_call references.
#
# Wires epoll_create1 / epoll_ctl / epoll_wait via external_call.
#
# Public API discipline (encapsulation rule):
#   - All functions return TYPED SCALARS (Int32 / Int / void).
#   - UnsafePointer is INTERNAL TO THIS MODULE only — confined to the FFI
#     thunks below. Does NOT cross the module boundary. Each thunk carries
#     a # SAFETY: comment per the the canonical shape.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed
    `_null_ptr[T, o]()` null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Used only for NULL syscall arguments below.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# -----------------------------------------------------------------------------
# Constants (Linux x86_64).
# -----------------------------------------------------------------------------

comptime EPOLL_CLOEXEC: Int32 = Int32(0o2000000)
comptime EPOLL_CTL_ADD: Int32 = Int32(1)
comptime EPOLL_CTL_DEL: Int32 = Int32(2)
comptime EPOLL_CTL_MOD: Int32 = Int32(3)
comptime EPOLLIN: UInt32 = UInt32(0x001)
comptime EPOLLOUT: UInt32 = UInt32(0x004)
comptime EPOLLERR: UInt32 = UInt32(0x008)
comptime EPOLLHUP: UInt32 = UInt32(0x010)
comptime EPOLLET: UInt32 = UInt32(0x80000000)

comptime MAX_EVENTS_PER_WAIT: Int = 64

# struct epoll_event layout is ARCH-DEPENDENT. On x86_64 glibc marks it `__EPOLL_PACKED`
# (`__attribute__((packed))`) -> { uint32 events; uint64 data; } = 12 bytes,
# data at offset 4. On aarch64 (and most non-x86 arches) it is NOT packed, so
# the uint64 `data` is 8-byte aligned -> 4 bytes of padding after `events`,
# total 16 bytes, data at offset 8. The kernel reads (epoll_ctl) + writes
# (epoll_wait) the struct with the NATIVE layout, so BOTH the encode and the
# decode here must match the running arch. Hardcoding the x86_64 12-byte layout
# silently corrupted the cookie on arm64 (data read from the padding = 0), so
# the HTTP serve loop's listener-readiness op_id never matched the listen fd and
# the server accepted TCP but never read/responded; x86_64 is immune, so only
# an arm64 build surfaces it.
# Selected via is_x86() (the in-tree-proven predicate; CompilationTarget has no
# is_arm64() in Mojo 1.0.0b1). x86 -> packed 12/4; every other arch (incl.
# aarch64 Linux) -> 16/8. The
# value on macOS is irrelevant: the epoll code is gated behind is_linux().
comptime EPOLL_EVENT_SIZE: Int = 12 if CompilationTarget.is_x86() else 16
comptime EPOLL_DATA_OFFSET: Int = 4 if CompilationTarget.is_x86() else 8

# EEXIST (Linux errno 17). Returned by epoll_ctl(EPOLL_CTL_ADD, ...) when the
# fd is ALREADY in the epoll set. See `epoll_ctl_add`'s ADD-or-MOD fallback.
comptime EEXIST: Int32 = Int32(17)

# EINTR (Linux errno 4). epoll_wait returns -1/EINTR when interrupted by a
# signal — POSIX requires the caller to RETRY, not fail. See epoll_wait_decode.
comptime EINTR: Int32 = Int32(4)

# Mode sentinels for register_*. Internal to this module; the Reactor
# translates user-facing "read"/"write" calls into the right epoll bitset.
comptime MODE_READ: UInt8 = 1
comptime MODE_WRITE: UInt8 = 2


# -----------------------------------------------------------------------------
# EpollEvent — DECODED { uint32 events; uint64 data; } pair. The on-the-wire
# kernel struct is arch-dependent (x86_64: packed, 12 bytes, data@4; aarch64:
# 16 bytes, data@8) — the decode in epoll_wait_decode uses EPOLL_EVENT_SIZE /
# EPOLL_DATA_OFFSET to read the right bytes; this struct is the arch-neutral
# decoded form.
# -----------------------------------------------------------------------------

@fieldwise_init
struct EpollEvent(
    TrivialRegisterPassable,
    Copyable,
    ImplicitlyCopyable,
    Movable,
    Deinitable,
):
    """Decoded epoll_wait event. `events` is a bitset (EPOLLIN | EPOLLOUT |
    ...); `data` is the 8-byte cookie set at register time (we use the
    cookie to recover the op_id of the parked operation).

    TrivialRegisterPassable per Mojo 0.26.3 — the deprecated
    `@register_passable("trivial")` decorator was replaced by the trait.
    """

    var events: UInt32
    var data: UInt64


# -----------------------------------------------------------------------------
# Linux-only FFI block, behind comptime if guards.
# -----------------------------------------------------------------------------


def epoll_create_v1() raises -> Int32:
    """Create an epoll fd (Linux only). Wraps `epoll_create1(EPOLL_CLOEXEC)`.

    Returns the epoll fd. Raises on syscall error. Wrong-OS callers raise.
    """
    comptime if CompilationTarget.is_linux():
        var fd = external_call["epoll_create1", Int32](EPOLL_CLOEXEC)
        if fd < 0:
            raise Error("epoll_create1() failed")
        return fd
    else:
        raise Error("EpollSubsystem.epoll_create_v1: Linux only")


def epoll_close(epoll_fd: Int32):
    """Close an epoll fd. Idempotent if fd < 0 (already closed sentinel)."""
    comptime if CompilationTarget.is_linux():
        if epoll_fd >= 0:
            _ = external_call["close", Int32](epoll_fd)


@always_inline
def _errno_read() -> Int32:
    """Read the current pthread's errno via libc's `__errno_location()`.
    Linux-only helper (callers gate on CompilationTarget.is_linux()).

    SAFETY: `__errno_location()` returns a stable per-pthread int* address;
    we immediately dereference and read the Int32. No pointer escapes this
    thunk; UnsafePointer never crosses the module boundary.
    """
    comptime if CompilationTarget.is_linux():
        var errno_ptr = external_call[
            "__errno_location", UnsafePointer[Int32, MutUntrackedOrigin],
        ]()
        return errno_ptr[]
    else:
        return Int32(0)


def epoll_ctl_add(epoll_fd: Int32, fd: Int32, events: UInt32, cookie: UInt64) raises:
    """`epoll_ctl`(epoll_fd, EPOLL_CTL_ADD, fd, &event{events, data=cookie}).
    `cookie` is the 8-byte data-field used to recover the op_id when
    epoll_wait reports readiness.

    ADD-or-MOD idempotency:
    epoll, unlike kqueue, is NOT idempotent on a re-ADD of an fd already in
    the set — EPOLL_CTL_ADD returns -1/EEXIST. kqueue's EV_ADD silently
    UPDATES the existing (ident, filter) registration (man kevent), so the
    SAME higher-level "register interest" call works on macOS but crashed on
    linux. Strace of a server connecting to TLS Postgres:

        epoll_ctl(4, EPOLL_CTL_ADD, 6, {EPOLLOUT|EPOLLET, data=0x6})  = 0   # connect
        epoll_ctl(4, EPOLL_CTL_MOD, 6, {EPOLLIN|EPOLLET,  data=0x6})  = 0   # connected
        epoll_ctl(4, EPOLL_CTL_ADD, 6, {EPOLLIN,          data=0x1})  = -1 EEXIST  # TLS/pgwire read re-registers fd 6

    The connect phase registers fd 6 (op_id 0x6); the post-connect TLS
    handshake / pgwire read phase re-registers the SAME fd 6 with a new
    interest set + cookie (op_id 0x1) without an intervening EPOLL_CTL_DEL.
    Chosen fix: try ADD; on EEXIST fall back to EPOLL_CTL_MOD with the NEW
    events+cookie — this UPDATES the interest set + op_id cookie in place,
    matching kqueue's idempotent-EV_ADD semantics and benefiting EVERY
    register path (register_read / register_write / register_long_lived),
    not just the pg connect→TLS handoff. Preferred over a connect-phase
    EPOLL_CTL_DEL because (a) it's one code point vs every fd-ownership
    handoff site, and (b) it carries no delete-then-add window where an
    edge-triggered readiness event could be lost between the two syscalls.
    """
    comptime if CompilationTarget.is_linux():
        # SAFETY: ev is stack-local. The kernel reads only and does not retain
        # the pointer past the syscall return. Confined to this FFI thunk;
        # UnsafePointer never crosses the module boundary. Layout is arch-aware
        # (EPOLL_EVENT_SIZE / EPOLL_DATA_OFFSET) — see those constants.
        var ev = Array[UInt8, EPOLL_EVENT_SIZE](fill=UInt8(0))
        ev[0] = UInt8(events & UInt32(0xFF))
        ev[1] = UInt8((events >> UInt32(8)) & UInt32(0xFF))
        ev[2] = UInt8((events >> UInt32(16)) & UInt32(0xFF))
        ev[3] = UInt8((events >> UInt32(24)) & UInt32(0xFF))
        for i in range(8):
            ev[EPOLL_DATA_OFFSET + i] = UInt8(
                (cookie >> UInt64(8 * i)) & UInt64(0xFF)
            )
        var rc = external_call["epoll_ctl", Int32](
            epoll_fd, EPOLL_CTL_ADD, fd, ev.unsafe_ptr(),
        )
        if rc < 0:
            # Distinguish EEXIST (fd already registered) from a genuine
            # failure. errno_read() must be called BEFORE any other libc
            # call that could clobber errno.
            if _errno_read() == EEXIST:
                # fd is already in the set under a prior register call. Update
                # its interest set + cookie in place via EPOLL_CTL_MOD (same
                # arch-aware event encoding; only the op code changes).
                var rc_mod = external_call["epoll_ctl", Int32](
                    epoll_fd, EPOLL_CTL_MOD, fd, ev.unsafe_ptr(),
                )
                if rc_mod < 0:
                    raise Error("epoll_ctl(ADD->MOD on EEXIST) failed")
            else:
                raise Error("epoll_ctl(ADD) failed")
    else:
        raise Error("EpollSubsystem.epoll_ctl_add: Linux only")


def epoll_ctl_del(epoll_fd: Int32, fd: Int32) raises:
    """`epoll_ctl`(epoll_fd, EPOLL_CTL_DEL, fd, NULL). Removes the fd from
    the epoll set. Per the kernel contract, the event arg is ignored
    in EPOLL_CTL_DEL on Linux >= 2.6.9 but we pass a non-null sentinel
    for older kernels."""
    comptime if CompilationTarget.is_linux():
        # SAFETY: ev stack-local sentinel; kernel ignores in DEL. Arch-aware
        # size for consistency with the ADD/MOD encoders.
        var ev = Array[UInt8, EPOLL_EVENT_SIZE](fill=UInt8(0))
        var rc = external_call["epoll_ctl", Int32](
            epoll_fd, EPOLL_CTL_DEL, fd, ev.unsafe_ptr(),
        )
        if rc < 0:
            # ENOENT is benign — fd was never added or already removed.
            # We don't distinguish here; callers treat deregister as
            # best-effort.
            pass


def epoll_ctl_mod(
    epoll_fd: Int32, fd: Int32, events: UInt32, cookie: UInt64,
) raises:
    """Epoll_ctl(epoll_fd, EPOLL_CTL_MOD, fd,
    &event{events, data=cookie}).

    Switches the armed interest set on a previously-EPOLL_CTL_ADD'd fd.
    Used by `Reactor.modify` to flip a long-lived registration between
    READ / WRITE / both. Same encoding shape as
    `epoll_ctl_add` (12-byte struct epoll_event); only the op code
    changes.

    On error: raises (typically EBADF on a closed fd, or ENOENT if the
    fd was never registered — caller should not hit this if the
    RegistrationHandle is alive).
    """
    comptime if CompilationTarget.is_linux():
        # SAFETY: ev is stack-local. The kernel reads only and does not
        # retain the pointer past the syscall return. Confined to this
        # FFI thunk; UnsafePointer never crosses the module boundary. Layout
        # is arch-aware (EPOLL_EVENT_SIZE / EPOLL_DATA_OFFSET).
        var ev = Array[UInt8, EPOLL_EVENT_SIZE](fill=UInt8(0))
        ev[0] = UInt8(events & UInt32(0xFF))
        ev[1] = UInt8((events >> UInt32(8)) & UInt32(0xFF))
        ev[2] = UInt8((events >> UInt32(16)) & UInt32(0xFF))
        ev[3] = UInt8((events >> UInt32(24)) & UInt32(0xFF))
        for i in range(8):
            ev[EPOLL_DATA_OFFSET + i] = UInt8(
                (cookie >> UInt64(8 * i)) & UInt64(0xFF)
            )
        var rc = external_call["epoll_ctl", Int32](
            epoll_fd, EPOLL_CTL_MOD, fd, ev.unsafe_ptr(),
        )
        if rc < 0:
            raise Error("epoll_ctl(MOD) failed")
    else:
        raise Error("EpollSubsystem.epoll_ctl_mod: Linux only")


def epoll_wait_decode(
    epoll_fd: Int32,
    mut events: List[EpollEvent],
    timeout_ms: Int32,
) raises -> Int:
    """`epoll_wait` — block up to `timeout_ms` for ready events; decode into
    `events` (cleared first). Returns the number of ready events.

    SAFETY: raw is stack-local, kernel writes up to MAX_EVENTS_PER_WAIT *
    EPOLL_EVENT_SIZE bytes (arch-aware: 16 on arm64, 12 on x86) and returns the
    count. UnsafePointer never crosses the module boundary.
    """
    comptime if CompilationTarget.is_linux():
        var raw = Array[UInt8, MAX_EVENTS_PER_WAIT * EPOLL_EVENT_SIZE](
            fill=UInt8(0)
        )
        # EINTR retry: epoll_wait
        # returns -1/EINTR when interrupted by a signal — a BENIGN, expected
        # condition that POSIX requires the caller to retry, NOT a fatal error.
        # The broker-coordinator's HttpServer serve loop blocks in epoll_wait;
        # under container signal traffic it caught EINTR and raised
        # "epoll_wait() failed", killing the serve loop (the container then
        # restart-looped and every broker heartbeat / curl saw a TCP-accept but
        # zero response bytes). Loop-retry on EINTR; raise (with the errno) on
        # any other error. macOS kqueue_wait_decode has the same latent shape;
        # only the Linux serve path surfaced it under container load.
        # The decode is INSIDE the retry loop (under `n >= 0`) rather than
        # after it: that way `n` is declared AT its only assignment. The
        # previous shape declared `var n = Int32(0)` before the loop, and
        # that dead initializer was the single highest-multiplicity
        # compiler warning in the whole build — 513 emitted lines from this
        # one line, because every package that transitively imports the
        # reactor re-reports it.
        while True:
            var n = external_call["epoll_wait", Int32](
                epoll_fd,
                raw.unsafe_ptr(),
                Int32(MAX_EVENTS_PER_WAIT),
                timeout_ms,
            )
            if n >= 0:
                while len(events) > 0:
                    _ = events.pop()
                for i in range(Int(n)):
                    var off = i * EPOLL_EVENT_SIZE
                    var ev_u32 = (
                        UInt32(raw[off + 0])
                        | (UInt32(raw[off + 1]) << UInt32(8))
                        | (UInt32(raw[off + 2]) << UInt32(16))
                        | (UInt32(raw[off + 3]) << UInt32(24))
                    )
                    var data_u64 = UInt64(0)
                    for k in range(8):
                        data_u64 = data_u64 | (
                            UInt64(raw[off + EPOLL_DATA_OFFSET + k])
                            << UInt64(8 * k)
                        )
                    events.append(EpollEvent(events=ev_u32, data=data_u64))
                return Int(n)
            var err = _errno_read()
            if err == EINTR:  # interrupted by signal; retry.
                continue
            raise Error("epoll_wait() failed (errno=" + String(Int(err)) + ")")
    else:
        raise Error("EpollSubsystem.epoll_wait_decode: Linux only")


# -----------------------------------------------------------------------------
# timerfd FFI — Linux only. 3.
# -----------------------------------------------------------------------------
# A timerfd is the Linux primitive that turns "wake me at deadline T" into an
# ordinary fd-readiness completion: `timerfd_create` returns an fd that becomes
# read-readable when the armed deadline elapses, so it routes through epoll
# EXACTLY like a socket read (epoll_ctl_add under the op_id cookie, then a
# normal EPOLLIN completion). That is the whole point — a parked stream's
# "re-park on a timer" becomes the same code path as "re-park on a PG read",
# with zero driver change.
#
# One timerfd is allocated PER PARKED STREAM (one-shot deadline). The orphaned
# `TimerWheel` is for many cheap in-process timers sharing one tick; it is NOT
# wired here (the per-stream timerfd is the right primitive for a long-lived
# idle park — the wheel would re-introduce an in-process tick the reactor does
# not have). HAZARD: one fd per idle stream — RLIMIT_NOFILE becomes the ceiling
# on concurrent idle streams. See the Reactor.register_timer docstring.
#
# All functions return typed scalars; UnsafePointer is confined to the FFI
# thunks (struct itimerspec encode + the 8-byte drain read).

comptime CLOCK_MONOTONIC: Int32 = Int32(1)
comptime TFD_NONBLOCK: Int32 = 0o4000      # O_NONBLOCK
comptime TFD_CLOEXEC: Int32 = 0o2000000    # O_CLOEXEC


def timerfd_create_monotonic() raises -> Int32:
    """Create a CLOCK_MONOTONIC timerfd with TFD_NONBLOCK | TFD_CLOEXEC.

    Returns the timerfd fd (read-readable when the armed deadline elapses).
    Raises on syscall error. Wrong-OS callers raise. The macOS path uses
    EVFILT_TIMER (kevent_register_timer); this is the Linux primitive only.
    """
    comptime if CompilationTarget.is_linux():
        var fd = external_call["timerfd_create", Int32](
            CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC,
        )
        if fd < 0:
            raise Error("timerfd_create() failed")
        return fd
    else:
        raise Error("timerfd_create_monotonic: Linux only")


def timerfd_arm_relative(fd: Int32, deadline_ns: Int64) raises:
    """Arm `fd` to fire ONCE after `deadline_ns` nanoseconds from now
    (relative, CLOCK_MONOTONIC). A one-shot timer: it_interval is zero, so it
    fires exactly once. `deadline_ns <= 0` arms a ~1ns timer (fires almost
    immediately — a zero-delay idle wake; a TRUE zero itimerspec would DISARM
    the timer, which we never want here).

    SAFETY: `spec` is a stack-local struct itimerspec (4 × int64 = 32 bytes on
    Linux x86_64/aarch64: it_interval{tv_sec,tv_nsec}, it_value{tv_sec,tv_nsec}).
    The kernel reads it during the syscall and does not retain the pointer.
    Confined to this thunk; no UnsafePointer crosses the module boundary.
    """
    comptime if CompilationTarget.is_linux():
        var ns = deadline_ns
        if ns <= Int64(0):
            ns = Int64(1)
        var sec = ns // Int64(1_000_000_000)
        var nsec = ns % Int64(1_000_000_000)
        # struct itimerspec layout (LP64): it_interval.tv_sec @0,
        # it_interval.tv_nsec @8, it_value.tv_sec @16, it_value.tv_nsec @24.
        var spec = Array[Int64, 4](fill=Int64(0))
        # it_interval = 0 (one-shot, no auto-rearm). it_value = the deadline.
        spec[2] = sec
        spec[3] = nsec
        # timerfd_settime(fd, flags=0 (relative), &new, NULL (old)).
        var rc = external_call["timerfd_settime", Int32](
            fd,
            Int32(0),
            spec.unsafe_ptr(),
            _null_ptr[Int64, MutUntrackedOrigin](),
        )
        # Anchor the stack buffer past the syscall.
        _ = spec[3]
        if rc < 0:
            raise Error("timerfd_settime() failed")
    else:
        raise Error("timerfd_arm_relative: Linux only")


def drain_timerfd(fd: Int32):
    """Drain a timerfd by reading the 8-byte expiration count, resetting its
    read-readiness (level-triggered, like the eventfd drain). Best-effort:
    silent on EAGAIN (NONBLOCK; not yet expired) or EBADF (closed).

    SAFETY: val is a stack-local 8-byte buffer; the libc helper writes 8 bytes
    via the kernel (or -1/EAGAIN with no write). UnsafePointer never crosses the
    module boundary.

    Uses libc's `eventfd_read(int fd, uint64_t *value)` helper (glibc ≥ 2.7),
    which is `read(fd, value, 8)` under the hood and works identically on a
    timerfd's 8-byte expiration counter. This sidesteps the Mojo stdlib's own
    `read` external binding — a direct `external_call["read", ...]` declares a
    second `read` symbol with a conflicting signature and fails MLIR
    legalization at archive-lower time on Linux (same rationale, and same shim,
    as drain_eventfd in wake_primitives.mojo).
    """
    comptime if CompilationTarget.is_linux():
        if fd >= 0:
            var val: UInt64 = 0
            var typed_ptr = UnsafePointer(to=val)
            # SAFETY: launder typed pointer through the FFI carve-out (matches
            # drain_eventfd). The kernel writes 8 bytes; val outlives the call.
            var raw_ptr = UnsafePointer[UInt64, MutUntrackedOrigin](
                unsafe_from_address=Int(typed_ptr)
            )
            var rc = external_call["eventfd_read", Int32](fd, raw_ptr)
            _ = rc   # ignore: EAGAIN benign


def close_timerfd(fd: Int32):
    """Close a timerfd. Idempotent if fd < 0 (sentinel). Best-effort."""
    comptime if CompilationTarget.is_linux():
        if fd >= 0:
            _ = external_call["close", Int32](fd)


# -----------------------------------------------------------------------------
# EpollSubsystem — convenience handle (one fd) constructable on Linux.
# -----------------------------------------------------------------------------
# Reactor[S] holds a stand-alone `_epoll_fd: Int32` and calls the free fns
# above; EpollSubsystem is a thin RAII wrapper that callers instantiate when
# they want subsystem-level construction (e.g., the IoSubsystem dispatcher
# in 1.5+). Reactor itself does not need to wrap; it owns the fd directly.
# -----------------------------------------------------------------------------


struct EpollSubsystem(Deinitable):
    """Linux epoll backend (RAII handle).

    Constructed via `EpollSubsystem.create()` on Linux only. On macOS /
    other OSes, `create()` raises an explicit "Linux only" error per the
    wrong-OS branch discipline.
    """

    var _epoll_fd: Int32

    def __init__(out self, epoll_fd: Int32):
        self._epoll_fd = epoll_fd

    def __deinit__(deinit self):
        epoll_close(self._epoll_fd)

    @staticmethod
    def create() raises -> EpollSubsystem:
        """Linux-only constructor."""
        comptime if CompilationTarget.is_linux():
            var fd = epoll_create_v1()
            return EpollSubsystem(epoll_fd=fd)
        else:
            raise Error("EpollSubsystem available on Linux only")

    def fd(self) -> Int32:
        """Underlying epoll fd. Used by Reactor for direct epoll_ctl /
        epoll_wait calls; the typed-scalar return preserves the
        encapsulation rule (no UnsafePointer crosses)."""
        return self._epoll_fd
