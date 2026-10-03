# =============================================================================
# komira_async.reactor.socket_io — non-blocking socket FFI thunks
# =============================================================================
# (try_io fast path) + (pointer + lint discipline).
#
# Confined FFI for `recv(MSG_DONTWAIT)` and `send(MSG_DONTWAIT)` used by
# Reactor.submit's try_io fast path. Per: uses Span[UInt8]'s
# `unsafe_ptr()` accessor; the Span is a ref-only view; its storage outlives
# the submit() call (caller's stack or long-lived buffer).
#
# Pointer discipline (FFI carve-out):
#   - All public functions return Int64 (bytes-read / bytes-written / negative
#     on error) and accept Span[UInt8] / Int32 / UInt32 (typed scalars).
#   - UnsafePointer is INTERNAL TO THIS MODULE only — confined to the FFI
#     thunks below.
#   - NO wildcard origins on the public surface.
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


# Standard POSIX flag for non-blocking recv/send. Values DIFFER between
# Linux (0x40) and macOS (0x80) — pick at comptime via a runtime helper
# that the compiler folds (the @parameter if guards CompilationTarget,
# evaluating to a comptime constant).
@always_inline
def msg_dontwait() -> Int32:
    """Comptime-branched MSG_DONTWAIT flag value. Linux: 0x40; Darwin: 0x80."""
    comptime if CompilationTarget.is_macos():
        return Int32(0x80)
    else:
        return Int32(0x40)


# =============================================================================
# ★ SIGPIPE SUPPRESSION — the difference between "this connection failed" and
#   "this process no longer exists".
# =============================================================================
#
# A `send()` on a socket whose peer has closed raises SIGPIPE, and SIGPIPE's
# POSIX default disposition is TERMINATE. Without suppressing it, EVERY socket
# server built on this reactor dies
# — whole process, every connection it was serving — the first time it
# writes to a departed peer. Under strace:
#
#     sendto(7, "\210\0", 2, MSG_DONTWAIT, NULL, 0) = -1 EPIPE (Broken pipe)
#     --- SIGPIPE ---   +++ killed by SIGPIPE +++
#
# and the process exits 141 having printed NOTHING, because a signal death
# prints nothing — stdout is block-buffered and never flushes. A SILENT failure.
#
# ★ THIS ADDS NO ERROR PATH. `try_io_write` already documents "EPIPE on closed
# peer" as a value it RETURNS, and a serve loop built on this reactor maps a
# hard write error onto "drop THIS connection and keep serving". Suppressing the
# signal is what lets the process live long enough to run code that was already
# written. That is why the fix belongs HERE, at the send, and not in each
# binary's main().
#
# ⚠ THE TWO PLATFORMS DO NOT SHARE A MECHANISM — do not paper over the split.
#
#   Linux   `MSG_NOSIGNAL` (0x4000) is a PER-CALL send() flag. Complete by
#           construction: it cannot be missed on an fd this module did not
#           create, because it is a property of the CALL, not of the socket.
#
#   macOS   has NO MSG_NOSIGNAL. The equivalent is `SO_NOSIGPIPE` (0x1022), a
#           PER-SOCKET option, so `msg_nosignal()` folds to 0 there and the work
#           moves to `set_nosigpipe(fd)`, applied to every fd this reactor
#           creates (`try_io_accept` below; `socket_setup.socket_tcp_nonblocking`).
#           ⚠ SO_NOSIGPIPE is NOT inherited across accept(), which is exactly why
#           `try_io_accept` sets it on each accepted fd instead of relying on the
#           listener. ⚠ AND IT IS NOT COMPLETE: an fd created SOMEWHERE ELSE (a
#           socketpair, a TLS library's own socket, a caller's fd) reaches
#           `try_send` without it. On macOS such a caller must either call
#           `set_nosigpipe(fd)` itself or install the process-level backstop
#           `graceful_shutdown.ignore_sigpipe()`. On Linux neither is required.
#
# ⚠ THE macOS ARM IS UNVERIFIED. The test runners are linux-x86_64
#   only, so the SO_NOSIGPIPE arm is asserted from the Darwin headers and reviewed, NOT measured. The Linux arm IS
#   measured — tests/test_socket_write_no_sigpipe.mojo.

# MSG_NOSIGNAL — Linux-only send() flag: return EPIPE instead of raising
# SIGPIPE. Verified against <sys/socket.h> on glibc/x86_64: 0x4000.
comptime _MSG_NOSIGNAL_LINUX: Int32 = Int32(0x4000)

# SO_NOSIGPIPE — the macOS per-socket equivalent (<sys/socket.h>: 0x1022).
# Unused on Linux.
comptime _SO_NOSIGPIPE_MACOS: Int32 = Int32(0x1022)
comptime _SOL_SOCKET_MACOS: Int32 = Int32(0xFFFF)


@always_inline
def msg_nosignal() -> Int32:
    """Comptime-branched MSG_NOSIGNAL flag value. Linux: 0x4000; Darwin: 0.

    Darwin is deliberately 0 — the flag does not exist there, and OR-ing a
    made-up bit into `send()`'s flags would be worse than useless (a future
    kernel could give that bit a meaning). Darwin's suppression is
    `set_nosigpipe(fd)`; see the block comment above.
    """
    comptime if CompilationTarget.is_macos():
        return Int32(0)
    else:
        return _MSG_NOSIGNAL_LINUX


def set_nosigpipe(fd: Int32) -> Bool:
    """macOS: `setsockopt(SOL_SOCKET, SO_NOSIGPIPE, 1)` so a write to a departed
    peer returns EPIPE instead of raising SIGPIPE. Linux: a NO-OP returning True
    — `msg_nosignal()` already covers every send `try_send` issues.

    Call on any socket fd created OUTSIDE this reactor that will be written
    through `try_send` / `try_io_write`. The reactor's own fd factories
    (`try_io_accept` here, `socket_setup.socket_tcp_nonblocking`) already call
    it; SO_NOSIGPIPE is NOT inherited across `accept()`, which is why it is
    applied per accepted fd rather than once on the listener.

    Returns True on success (always, on Linux), False if the setsockopt failed.
    Never raises: a caller in an accept loop must not be pushed into an error
    path by a hardening call.

    ⚠ UNVERIFIED on macOS — this repo's lanes are linux-x86_64 only.
    """
    comptime if CompilationTarget.is_macos():
        if fd < Int32(0):
            return False
        # SAFETY: FFI-BOUNDARY. `optval` is a stack-local int32 the kernel only
        # READS, for the duration of the syscall. No pointer escapes this fn.
        var optval = Array[Int32, 1](fill=Int32(1))
        var rc = external_call["setsockopt", Int32](
            fd,
            _SOL_SOCKET_MACOS,
            _SO_NOSIGPIPE_MACOS,
            optval.unsafe_ptr(),
            UInt32(4),  # sizeof(int32)
        )
        return rc == Int32(0)
    else:
        # Linux: nothing to do. `try_send` passes MSG_NOSIGNAL on EVERY call,
        # which is strictly more complete than a per-socket option.
        return True


@always_inline
def _eagain_errno() -> Int32:
    """Comptime-branched EAGAIN errno value. Linux: 11; Darwin: 35.
    POSIX guarantees EAGAIN == EWOULDBLOCK on each platform.
    """
    comptime if CompilationTarget.is_macos():
        return Int32(35)
    else:
        return Int32(11)


@always_inline
def errno_is_would_block(err: Int32) -> Bool:
    """Returns True iff `err` is EAGAIN/EWOULDBLOCK on the current
    platform. Used by Reactor.submit's try_io fast path to decide
    whether to fall through to the multiplexer slow path."""
    return err == _eagain_errno()


@always_inline
def errno_get() -> Int32:
    """Read the current pthread's errno via libc's `__errno_location()` (Linux)
    or `__error()` (macOS).

    Returns the int32 errno value. Used by `try_recv` / `try_send` after a
    syscall returns -1, to distinguish EAGAIN/EWOULDBLOCK (try-io fallback)
    from real errors.

    SAFETY: the libc helper returns a stable per-pthread address. We
    immediately read the int32 at that address; no pointer escapes this
    function.
    """
    comptime if CompilationTarget.is_macos():
        # Darwin: __error() returns int*.
        var errno_ptr = external_call[
            "__error", UnsafePointer[Int32, MutUntrackedOrigin],
        ]()
        return errno_ptr[]
    else:
        # Linux glibc: __errno_location() returns int*.
        var errno_ptr = external_call[
            "__errno_location", UnsafePointer[Int32, MutUntrackedOrigin],
        ]()
        return errno_ptr[]


def try_recv(fd: Int32, buf: Span[UInt8, _]) -> Int64:
    """Try_io — `recv(fd, buf, MSG_DONTWAIT)`.

    Returns:
      - >=  0: bytes actually read into buf.
      - == -EAGAIN / -EWOULDBLOCK: would block; caller should park (fall
        through to slow path).
      - <   0 (other negative): -errno for any other error; caller raises.

    SAFETY: buf.unsafe_ptr() is laundered into the FFI; the kernel writes
    up to buf.size bytes and does not retain the pointer past the syscall
    return. Span[UInt8] is a ref-only view; its storage outlives this
    call (caller's stack or long-lived buffer) per
    """
    if fd < 0 or len(buf) == 0:
        return Int64(0)
    var n = external_call["recv", Int64](
        fd,
        buf.unsafe_ptr(),
        UInt64(len(buf)),
        msg_dontwait(),
    )
    if n >= Int64(0):
        return n
    # -1 from recv: read errno to distinguish EAGAIN from real errors.
    var err = errno_get()
    return Int64(-Int(err))


def try_send(fd: Int32, buf: Span[UInt8, _]) -> Int64:
    """Try_io — `send(fd, buf, MSG_DONTWAIT | MSG_NOSIGNAL)`.

    Same return convention as `try_recv`. In particular a peer that has closed
    yields `-EPIPE` (-32) — an ORDINARY error the caller already handles — and
    NOT a SIGPIPE that would kill the whole process.

    ★ `msg_nosignal()` IS LOAD-BEARING, NOT HARDENING. Without it this single
    line terminated every socket server in the repo on the first write to a
    departed peer, with exit 141 and an empty log. See the SIGPIPE block comment
    above for the measured strace and the Linux/macOS split (on Darwin
    `msg_nosignal()` is 0 and the work is `set_nosigpipe(fd)` at fd creation).
    Regression guard:
    tests/test_socket_write_no_sigpipe.mojo.
    """
    if fd < 0 or len(buf) == 0:
        return Int64(0)
    var n = external_call["send", Int64](
        fd,
        buf.unsafe_ptr(),
        UInt64(len(buf)),
        msg_dontwait() | msg_nosignal(),
    )
    if n >= Int64(0):
        return n
    var err = errno_get()
    return Int64(-Int(err))


# =============================================================================
# TryIoResult + standalone try_io_* fast-path fns.
# =============================================================================
#
# Extracts the try_io fast path into standalone functions so that
# multiple call sites can share it:
#   - Reactor.submit (slow-path fall-through if WouldBlock).
#   - The awaitable layer — read_async/write_async call try_io
#     BEFORE submitting.
#   - State-machine track callers (TcpStream.read / TcpStream.write —).
#   - User code that wants tokio-style try_read / try_write semantics.
#
# Per the cost model, the fast path saves ~750-1500ns per IO when the
# kernel buffer has data — the difference between a Pending → park → recv →
# resume cycle and a single inline recv. We expose it as standalone fns so
# callers can hit the fast path WITHOUT going through Reactor.submit's op-id
# allocator.
#
# The TryIoResult shape is the canonical "tokio TryIo" three-state pattern
# (Ready / WouldBlock / Error) plus an InProgress state for connect (which
# returns EINPROGRESS, not EWOULDBLOCK, on a non-blocking socket per POSIX).
# =============================================================================


# State discriminators for TryIoResult._state. POD UInt8 sentinels (no enum
# syntax in 0.26.3 with payload differentiation; mirrors the OpHandle pattern
# from completion_queue.mojo).

comptime TRY_IO_READY: UInt8 = 0
"""Syscall succeeded; `_value` carries the typed result (bytes or accepted
fd). Caller proceeds without parking."""

comptime TRY_IO_WOULD_BLOCK: UInt8 = 1
"""EAGAIN / EWOULDBLOCK — caller must register interest with the multiplexer
and park. `_value` is 0 (sentinel)."""

comptime TRY_IO_IN_PROGRESS: UInt8 = 2
"""EINPROGRESS — connect() on a non-blocking socket has been issued but
hasn't completed yet. Caller registers for write-readiness and parks; on
wake, calls `getsockopt(SO_ERROR)` to recover the connect result.

`_value` is 0 (sentinel). Distinct from WouldBlock so the caller can
choose connect-specific resume semantics (SO_ERROR check) vs. just
re-driving the syscall.
"""

comptime TRY_IO_ERROR: UInt8 = 3
"""Non-recoverable error (ECONNRESET, EBADF, ENOTCONN, etc.). `_value`
carries the positive errno. Caller raises (state-machine track) or
completes the OpHandle as Err (async/await track)."""


@fieldwise_init
struct TryIoResult(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Three-state result of a try_io_* call.

    Discriminator: `_state` is one of TRY_IO_READY / TRY_IO_WOULD_BLOCK /
    TRY_IO_IN_PROGRESS / TRY_IO_ERROR.

    Inline payload: `_value` holds:
      - bytes-read / bytes-written / accepted-fd (Int64) when state ==
        TRY_IO_READY (for `try_io_accept`, `_value` is the new fd cast to
        Int64; caller narrows to Int32).
      - errno (positive Int64) when state == TRY_IO_ERROR.
      - 0 sentinel for TRY_IO_WOULD_BLOCK / TRY_IO_IN_PROGRESS.

    POD: trivially Movable + Copyable. No UnsafePointer in fields. Mirrors
    the OpHandle pattern from
    """

    var _state: UInt8
    var _value: Int64

    @always_inline
    def state(self) -> UInt8:
        """Public accessor for the discriminator."""
        return self._state

    @always_inline
    def value(self) -> Int64:
        """Public accessor for the inline payload. Caller must check
        state() first to interpret correctly (bytes / fd / errno / 0)."""
        return self._value

    @always_inline
    def is_ready(self) -> Bool:
        """Convenience: state == TRY_IO_READY."""
        return self._state == TRY_IO_READY

    @always_inline
    def is_would_block(self) -> Bool:
        """Convenience: state == TRY_IO_WOULD_BLOCK."""
        return self._state == TRY_IO_WOULD_BLOCK

    @always_inline
    def is_in_progress(self) -> Bool:
        """Convenience: state == TRY_IO_IN_PROGRESS."""
        return self._state == TRY_IO_IN_PROGRESS

    @always_inline
    def is_error(self) -> Bool:
        """Convenience: state == TRY_IO_ERROR."""
        return self._state == TRY_IO_ERROR


# -----------------------------------------------------------------------------
# Standalone try_io_* — public surface for the fast path.
# -----------------------------------------------------------------------------


def try_io_read(fd: Int32, buf: Span[UInt8, _]) -> TryIoResult:
    """Try `recv(fd, buf, MSG_DONTWAIT)`. Standalone fast-path
    def that callers (TcpStream, awaitables, Reactor.submit) invoke
    BEFORE touching the multiplexer.

    Returns:
      - TRY_IO_READY with `_value = bytes-read` on success (including 0
        bytes — peer cleanly closed the read side).
      - TRY_IO_WOULD_BLOCK on EAGAIN / EWOULDBLOCK — caller registers
        interest + parks.
      - TRY_IO_ERROR with `_value = errno` for any other syscall error.

    SAFETY: delegates to `try_recv`; same FFI shape (Span[UInt8] is a
    ref-only view, kernel does not retain the pointer past the syscall
    return).
    """
    var n = try_recv(fd, buf)
    if n >= Int64(0):
        return TryIoResult(_state=TRY_IO_READY, _value=n)
    var err = Int32(-Int(n))
    if errno_is_would_block(err):
        return TryIoResult(_state=TRY_IO_WOULD_BLOCK, _value=Int64(0))
    return TryIoResult(_state=TRY_IO_ERROR, _value=Int64(Int(err)))


def try_io_write(fd: Int32, buf: Span[UInt8, _]) -> TryIoResult:
    """Try `send(fd, buf, MSG_DONTWAIT)`. Standalone fast-path
    def that callers invoke BEFORE touching the multiplexer.

    Returns:
      - TRY_IO_READY with `_value = bytes-written` (may be < len(buf) —
        kernel may accept a short write; caller is responsible for
        looping on the remainder).
      - TRY_IO_WOULD_BLOCK on EAGAIN / EWOULDBLOCK.
      - TRY_IO_ERROR with `_value = errno` for any other syscall error
        (EPIPE on closed peer, etc.).

    SAFETY: delegates to `try_send`; same FFI shape as `try_io_read`.
    """
    var n = try_send(fd, buf)
    if n >= Int64(0):
        return TryIoResult(_state=TRY_IO_READY, _value=n)
    var err = Int32(-Int(n))
    if errno_is_would_block(err):
        return TryIoResult(_state=TRY_IO_WOULD_BLOCK, _value=Int64(0))
    return TryIoResult(_state=TRY_IO_ERROR, _value=Int64(Int(err)))


# Sockaddr-as-bytes shape:
#   The caller passes the sockaddr struct as a `Span[UInt8, _]` so this
#   module stays free of platform-specific sockaddr_in/sockaddr_in6 layout
#   knowledge. The TcpStream / TcpListener wrapper is the
#   layer that builds the sockaddr_in bytes (4-byte family+port, 4-byte
#   ipv4, 8-byte zero pad).


@always_inline
def _einprogress_errno() -> Int32:
    """EINPROGRESS errno value. Linux & Darwin agree on 36."""
    comptime if CompilationTarget.is_macos():
        return Int32(36)
    else:
        return Int32(115)


@always_inline
def errno_is_in_progress(err: Int32) -> Bool:
    """Returns True iff `err` is EINPROGRESS on the current platform.
    Used by `try_io_connect` to distinguish the connect-specific
    "in-flight" path from EAGAIN / hard error."""
    return err == _einprogress_errno()


def try_io_connect(fd: Int32, addr: Span[UInt8, _]) -> TryIoResult:
    """Try `connect(fd, addr, len(addr))` on a non-blocking
    socket. Standalone fast-path fn for TcpStream::connect (shipped so the
    fast-path API surface is complete).

    Returns:
      - TRY_IO_READY with `_value = 0` if connect completed eagerly
        (rare for cross-host TCP; common for AF_UNIX or loopback).
      - TRY_IO_IN_PROGRESS if EINPROGRESS — connect is in flight; caller
        registers interest in WRITE on the fd and parks. On wake, calls
        `getsockopt(SO_ERROR)` to recover the actual connect result.
      - TRY_IO_WOULD_BLOCK on EAGAIN — should not happen for connect()
        (POSIX says EINPROGRESS) but we route the same way for safety.
      - TRY_IO_ERROR with `_value = errno` for any other failure
        (ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, ...).

    SAFETY: addr.unsafe_ptr() is laundered into the FFI; the kernel reads
    `addr_len` bytes and does not retain the pointer past the syscall.
    Span[UInt8] is a ref-only view; storage outlives this call.
    """
    if fd < 0 or len(addr) == 0:
        return TryIoResult(
            _state=TRY_IO_ERROR, _value=Int64(22),  # EINVAL
        )
    var rc = external_call["connect", Int32](
        fd, addr.unsafe_ptr(), UInt32(len(addr)),
    )
    if rc == Int32(0):
        return TryIoResult(_state=TRY_IO_READY, _value=Int64(0))
    var err = errno_get()
    if errno_is_in_progress(err):
        return TryIoResult(_state=TRY_IO_IN_PROGRESS, _value=Int64(0))
    if errno_is_would_block(err):
        return TryIoResult(_state=TRY_IO_WOULD_BLOCK, _value=Int64(0))
    return TryIoResult(_state=TRY_IO_ERROR, _value=Int64(Int(err)))


# accept4 SOCK_NONBLOCK flag (Linux only).
comptime _SOCK_NONBLOCK_LINUX: Int32 = Int32(0o4000)


def try_io_accept(listen_fd: Int32) -> TryIoResult:
    """Try to accept a pending connection on a non-blocking
    listener fd.

    On Linux: uses `accept4(listen_fd, NULL, NULL, SOCK_NONBLOCK)` so
    the accepted fd is born non-blocking (one syscall, no follow-up
    fcntl). Per, this avoids the post-accept fcntl race window.

    On macOS: uses `accept(listen_fd, NULL, NULL)` then `fcntl(F_SETFL,
    O_NONBLOCK)` (accept4 not available). The caller still observes a
    born-non-blocking fd; the syscall pair is hidden inside this fn.

    Returns:
      - TRY_IO_READY with `_value = accepted_fd` (cast to Int64) on
        success. Caller narrows to Int32 and constructs a TcpStream.
      - TRY_IO_WOULD_BLOCK on EAGAIN / EWOULDBLOCK — no pending
        connections; caller registers READ interest on the listener +
        parks.
      - TRY_IO_ERROR with `_value = errno` for any other error
        (EBADF on closed listener, EMFILE on per-process fd limit, etc.).
    """
    if listen_fd < 0:
        return TryIoResult(
            _state=TRY_IO_ERROR, _value=Int64(9),  # EBADF
        )
    comptime if CompilationTarget.is_linux():
        # accept4(listen_fd, NULL, NULL, SOCK_NONBLOCK).
        var new_fd = external_call["accept4", Int32](
            listen_fd,
            _null_ptr[UInt8, MutUntrackedOrigin](),
            _null_ptr[UInt32, MutUntrackedOrigin](),
            _SOCK_NONBLOCK_LINUX,
        )
        if new_fd >= Int32(0):
            # No SIGPIPE work needed on Linux: `try_send` passes MSG_NOSIGNAL
            # on every call, so it covers this fd and any other.
            return TryIoResult(
                _state=TRY_IO_READY, _value=Int64(Int(new_fd)),
            )
        var err = errno_get()
        if errno_is_would_block(err):
            return TryIoResult(_state=TRY_IO_WOULD_BLOCK, _value=Int64(0))
        return TryIoResult(_state=TRY_IO_ERROR, _value=Int64(Int(err)))
    else:
        # macOS: accept(listen_fd, NULL, NULL) then fcntl O_NONBLOCK.
        var new_fd = external_call["accept", Int32](
            listen_fd,
            _null_ptr[UInt8, MutUntrackedOrigin](),
            _null_ptr[UInt32, MutUntrackedOrigin](),
        )
        if new_fd < Int32(0):
            var err = errno_get()
            if errno_is_would_block(err):
                return TryIoResult(
                    _state=TRY_IO_WOULD_BLOCK, _value=Int64(0),
                )
            return TryIoResult(
                _state=TRY_IO_ERROR, _value=Int64(Int(err)),
            )
        # Set O_NONBLOCK on the accepted fd. Best-effort; if the shim
        # fails we still return Ready with the raw fd, and the caller's
        # first try_io will surface the issue.
        #
        # use the non-variadic
        # `komira_fcntl_set_nonblock` shim instead of
        # `external_call["fcntl", Int32]` to bypass the Apple ARM64
        # variadic-ABI gap. See `_posix_shim.c` for the rationale and
        # `socket_setup.mojo:socket_tcp_nonblocking` for the matching
        # listener-side fix. The shim (komira_core's POSIX wrappers) is
        # statically linked into every
        # binary that links this library.
        _ = external_call["komira_fcntl_set_nonblock", Int32](new_fd)
        # ★ SO_NOSIGPIPE PER ACCEPTED FD — macOS has no MSG_NOSIGNAL, and
        # SO_NOSIGPIPE is NOT inherited from the listener, so setting it on the
        # listener would silently do nothing for the connections that actually
        # get written to. Without it, a macOS server dies on the first write to
        # a departed peer (see the SIGPIPE block comment at the top). Best-
        # effort by design: an accept loop must not be pushed into an error
        # path by a hardening call, and a failure here degrades to exactly the
        # behaviour without SO_NOSIGPIPE rather than dropping the connection.
        # ⚠ UNVERIFIED — no macOS lane in this repo.
        _ = set_nosigpipe(new_fd)
        return TryIoResult(_state=TRY_IO_READY, _value=Int64(Int(new_fd)))
