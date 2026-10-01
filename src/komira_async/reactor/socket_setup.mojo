# =============================================================================
# komira_async.reactor.socket_setup — socket/bind/listen FFI helpers
# =============================================================================
# confined FFI for the listener-side setup that
# TcpListener / TcpStream need. Separate from `socket_io.mojo` (which is
# the per-IO fast-path FFI) to keep the IO module focused.
#
# Public API:
#   - socket_tcp_nonblocking() raises -> Int32           # AF_INET + SOCK_STREAM + non-blocking
#   - bind_inet(fd, ip_be, port_host) raises             # bind to ip:port
#   - listen_socket(fd, backlog) raises
#   - sockaddr_in_bytes(ip_be, port_host) -> InlineArray[UInt8, 16]
#   - inet_loopback_be() -> UInt32                       # 127.0.0.1 in network byte order
#   - inet_any_be() -> UInt32                            # 0.0.0.0 (INADDR_ANY) — bind all interfaces
#
# Pointer discipline:
#   - All public functions return typed scalars / InlineArray.
#   - UnsafePointer is INTERNAL TO THIS MODULE — confined to the FFI
#     thunks below.
#   - NO wildcard origins on the public surface.
#
# Per: listener sockets are O_NONBLOCK by construction (Linux:
# SOCK_NONBLOCK on the socket() flags arg; macOS: post-socket fcntl).
# Accepted fds are made non-blocking by `try_io_accept` (Linux: accept4
# SOCK_NONBLOCK; macOS: post-accept fcntl) — see `socket_io.mojo`.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call

# SIGPIPE suppression for the fds this module creates. On Linux this is a no-op
# (`try_send` passes MSG_NOSIGNAL per call); on macOS it is the ONLY thing
# standing between a departed peer and process death. socket_io does not import
# socket_setup, so this edge introduces no cycle.
from .socket_io import set_nosigpipe


# -----------------------------------------------------------------------------
# Constants — POSIX socket / sockaddr_in layout.
# -----------------------------------------------------------------------------

comptime _AF_INET: Int32 = Int32(2)
comptime _SOCK_STREAM: Int32 = Int32(1)
# Linux: SOCK_NONBLOCK = 0o4000 — bitwise-OR'd into the type arg of socket()
# so the resulting fd is born non-blocking. Saves the post-socket fcntl
# round-trip per
comptime _SOCK_NONBLOCK_LINUX: Int32 = Int32(0o4000)

# fcntl is variadic at the C level: `int fcntl(int fildes, int cmd, ...)`.
# Mojo 0.26.3's `external_call["fcntl", Int32]` does NOT correctly handle
# the variadic argument under Apple's ARM64 calling convention (Apple
# diverges from the standard ARM64 ABI: variadic args go on the stack,
# not in registers). The kernel reads garbage from the stack slot and
# silently sets a wrong flag bit.
#
# all fcntl call sites in this module
# now route through the non-variadic C shim
# (komira_core's native POSIX wrappers plus `_posix_shim.c`). The shims
# are statically linked into every binary that links this library.
# The aliases below
# are retained as DOCUMENTATION ONLY — do not call `external_call`
# directly with `fcntl`; use `komira_fcntl_*` shims instead.
#
# fcntl op codes (Linux + Darwin agree — POSIX values).
#   F_GETFL = 3, F_SETFL = 4, F_SETFD = 2.
# O_NONBLOCK is OS-specific (kept here for completeness; the shim's
# `komira_fcntl_set_nonblock` reads `O_NONBLOCK` from the system
# header at C compile time, which is correct per platform):
#   Linux:  0o4000 = 0x800   (`asm-generic/fcntl.h`)
#   Darwin: 0x4              (`sys/fcntl.h`)
comptime _O_NONBLOCK_LINUX: Int32 = Int32(0x800)
comptime _O_NONBLOCK_DARWIN: Int32 = Int32(0x4)

# SO_REUSEADDR — set on listener sockets to avoid TIME_WAIT bind failures
# during test loops. setsockopt(SOL_SOCKET, SO_REUSEADDR, 1).
# SOL_SOCKET differs by OS: Linux = 1; Darwin = 0xffff (sys/socket.h).
comptime _SOL_SOCKET_LINUX: Int32 = Int32(1)
comptime _SOL_SOCKET_MACOS: Int32 = Int32(0xffff)
comptime _SO_REUSEADDR_LINUX: Int32 = Int32(2)
comptime _SO_REUSEADDR_MACOS: Int32 = Int32(0x0004)
# SO_REUSEPORT — multiple sockets bound to the same port; kernel hashes
# incoming SYNs across them. The canonical primitive for per-core HTTP
# servers. Linux: 15. macOS: 0x0200 (BSD origin).
comptime _SO_REUSEPORT_LINUX: Int32 = Int32(15)
comptime _SO_REUSEPORT_MACOS: Int32 = Int32(0x0200)
# IPPROTO_TCP / TCP_NODELAY — disable Nagle on accepted conns. Required for
# low-latency HTTP/1.1 plaintext (the bench harness's headline workload).
comptime _IPPROTO_TCP: Int32 = Int32(6)
comptime _TCP_NODELAY: Int32 = Int32(1)


@always_inline
def _sol_socket_value() -> Int32:
    """SOL_SOCKET optlevel — Linux: 1; Darwin: 0xffff (sys/socket.h:354)."""
    comptime if CompilationTarget.is_macos():
        return _SOL_SOCKET_MACOS
    else:
        return _SOL_SOCKET_LINUX


@always_inline
def _so_reuseaddr_value() -> Int32:
    """SO_REUSEADDR optname — Linux: 2; Darwin: 0x0004 (sys/socket.h:124)."""
    comptime if CompilationTarget.is_macos():
        return _SO_REUSEADDR_MACOS
    else:
        return _SO_REUSEADDR_LINUX


@always_inline
def _so_reuseport_value() -> Int32:
    """SO_REUSEPORT optname — Linux: 15; Darwin: 0x0200."""
    comptime if CompilationTarget.is_macos():
        return _SO_REUSEPORT_MACOS
    else:
        return _SO_REUSEPORT_LINUX


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


@always_inline
def inet_loopback_be() -> UInt32:
    """127.0.0.1 in network byte order (big-endian on the wire).

    127.0.0.1 = 0x7F000001 in host order; on the wire it's
    0x0100007F (little-endian host -> big-endian net).
    """
    return UInt32(0x0100007F)


@always_inline
def inet_any_be() -> UInt32:
    """INADDR_ANY (0.0.0.0) in network byte order — bind all interfaces.

    0.0.0.0 = 0x00000000 in host order; byte-swapping all-zero leaves it
    unchanged, so the network-byte-order value is also UInt32(0). A
    listener bound to INADDR_ANY accepts connections on every local
    interface (loopback, the pod's eth0, the host NIC) — required so a
    container/k8s Service or readiness probe can reach the server from
    OUTSIDE the pod's own netns. (A 127.0.0.1-bound listener is only
    reachable from inside its own network namespace.) Note that 0.0.0.0
    still serves loopback connections, so this is a strict superset of
    `inet_loopback_be()`.
    """
    return UInt32(0)


def sockaddr_in_bytes(ip_be: UInt32, port_host: UInt16) -> Array[UInt8, 16]:
    """Build a struct sockaddr_in (AF_INET) as a 16-byte InlineArray.

    Layout (POSIX, host byte order for the family field on Linux but
    network byte order for sin_port and sin_addr):
      [0:2]   sin_family   = AF_INET (2) — Linux uses host byte order
                            (sin_family is __SOCKADDR_COMMON);
                            macOS sets sin_len in [0] and sin_family in [1]
                            BUT both kernels accept either layout for AF_INET
                            in practice. We use the Linux shape.
      [2:4]   sin_port     = port in network byte order
      [4:8]   sin_addr     = IPv4 address in network byte order
      [8:16]  sin_zero     = 8 bytes of zero padding

    The InlineArray return type makes the buffer stack-local; the caller
    builds a Span over it and passes to bind/connect FFI.
    """
    var buf = Array[UInt8, 16](fill=UInt8(0))
    # sin_family = AF_INET (2). On Linux, this is a u16 in host byte order.
    # On macOS, it's `{ uint8_t sin_len; uint8_t sin_family; }` — for AF_INET
    # the kernel autoderives sin_len so writing 2 in [0] (Linux) or [1]
    # (macOS) both work. We use the Linux shape.
    buf[0] = UInt8(_AF_INET)
    buf[1] = UInt8(0)
    # sin_port (network byte order = big-endian, regardless of host).
    buf[2] = UInt8((Int(port_host) >> 8) & 0xFF)
    buf[3] = UInt8(Int(port_host) & 0xFF)
    # sin_addr (4 bytes, network byte order — caller already supplies
    # ip_be in network byte order).
    buf[4] = UInt8(Int(ip_be) & 0xFF)
    buf[5] = UInt8((Int(ip_be) >> 8) & 0xFF)
    buf[6] = UInt8((Int(ip_be) >> 16) & 0xFF)
    buf[7] = UInt8((Int(ip_be) >> 24) & 0xFF)
    # sin_zero remains 0-filled.
    return buf^


# -----------------------------------------------------------------------------
# socket() — create an AF_INET TCP socket, born non-blocking + CLOEXEC.
# -----------------------------------------------------------------------------


def socket_tcp_nonblocking() raises -> Int32:
    """Create an AF_INET TCP socket. The fd is non-blocking from birth on
    Linux (SOCK_NONBLOCK in the type arg); macOS posts a follow-up fcntl
    F_SETFL O_NONBLOCK call. Raises on syscall failure.

    Returns the fd. Caller is responsible for close(fd) on cleanup.
    """
    var fd: Int32
    comptime if CompilationTarget.is_linux():
        fd = external_call["socket", Int32](
            _AF_INET, _SOCK_STREAM | _SOCK_NONBLOCK_LINUX, Int32(0),
        )
        if fd < Int32(0):
            raise Error("socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK) failed")
    else:
        # macOS: SOCK_NONBLOCK not available; post-socket fcntl via the
        # non-variadic C shim. replaced
        # the prior `external_call["fcntl", Int32](fd, F_GETFL, ...)` +
        # `(fd, F_SETFL, flags | O_NONBLOCK)` pair with a single
        # `komira_fcntl_set_nonblock(fd)` call. The shim is a non-
        # variadic C function (3 lines, see
        # `src/komira_async/reactor/_posix_shim.c`) so Mojo's
        # external_call passes the fd correctly on every platform —
        # including darwin-arm64 where Apple's variadic ABI puts varargs
        # on the stack while Mojo's external_call passes args in
        # registers (the prior bug). The shim is statically linked into
        # every binary that links this library.
        # Regression test:
        # `test_socket_nonblock_mac.mojo`
        # (FAILS pre-fix; PASSES post-fix).
        fd = external_call["socket", Int32](
            _AF_INET, _SOCK_STREAM, Int32(0),
        )
        if fd < Int32(0):
            raise Error("socket(AF_INET, SOCK_STREAM) failed")
        var rc = external_call["komira_fcntl_set_nonblock", Int32](fd)
        if rc < Int32(0):
            # Best-effort: log via the return code rather than raising —
            # mirrors the pre-shim Linux branch's "if SOCK_NONBLOCK fails,
            # the socket() call would have raised already" no-op semantic.
            # If the shim itself fails the listener will exhibit blocking
            # behavior at first accept; the regression test catches that.
            pass
    # ★ SIGPIPE: no-op on Linux (`try_send` passes MSG_NOSIGNAL per call);
    # on macOS this is SO_NOSIGPIPE, without which the first write to a
    # departed peer TERMINATES the process. Best-effort — a failure degrades
    # to the behaviour without SO_NOSIGPIPE and must not fail socket creation.
    # See socket_io.mojo's SIGPIPE block comment. ⚠ macOS arm UNVERIFIED.
    _ = set_nosigpipe(fd)
    return fd


def set_so_reuseaddr(fd: Int32) raises:
    """Setsockopt(SOL_SOCKET, SO_REUSEADDR, 1). Best-practice on listener
    sockets (avoids TIME_WAIT failures on rebind during tests / restarts).
    Best-effort: failure is non-fatal but raises so the caller can log.
    """
    if fd < Int32(0):
        return
    # SAFETY: optval stack-local int32; kernel reads only. Confined to
    # this FFI thunk.
    var optval = Array[Int32, 1](fill=Int32(1))
    var rc = external_call["setsockopt", Int32](
        fd,
        _sol_socket_value(),
        _so_reuseaddr_value(),
        optval.unsafe_ptr(),
        UInt32(4),                # sizeof(int32)
    )
    if rc < Int32(0):
        raise Error("setsockopt(SO_REUSEADDR) failed")


def set_so_reuseport(fd: Int32) raises:
    """Setsockopt(SOL_SOCKET, SO_REUSEPORT, 1) — multiple sockets bound to
    the same port; kernel hashes incoming SYNs across them.

    The canonical primitive for per-core HTTP servers — N pthreads each
    open a SO_REUSEPORT-bound listener on the same port; the kernel
    distributes new conns across them. A per-core HTTP server uses
    this.

    SAFETY: optval stack-local int32; kernel reads only. Confined FFI.
    """
    if fd < Int32(0):
        return
    var optval = Array[Int32, 1](fill=Int32(1))
    var rc = external_call["setsockopt", Int32](
        fd,
        _sol_socket_value(),
        _so_reuseport_value(),
        optval.unsafe_ptr(),
        UInt32(4),
    )
    if rc < Int32(0):
        raise Error("setsockopt(SO_REUSEPORT) failed")


def set_tcp_nodelay(fd: Int32) raises:
    """Setsockopt(IPPROTO_TCP, TCP_NODELAY, 1) — disable Nagle's algorithm.

    Critical for low-latency HTTP/1.1 plaintext (request/response
    workloads). Should be set on EVERY
    accepted connection fd, not just the listener.

    SAFETY: optval stack-local int32; kernel reads only. Confined FFI.
    """
    if fd < Int32(0):
        return
    var optval = Array[Int32, 1](fill=Int32(1))
    var rc = external_call["setsockopt", Int32](
        fd,
        _IPPROTO_TCP,
        _TCP_NODELAY,
        optval.unsafe_ptr(),
        UInt32(4),
    )
    if rc < Int32(0):
        raise Error("setsockopt(TCP_NODELAY) failed")


def bind_inet(fd: Int32, ip_be: UInt32, port_host: UInt16) raises:
    """Bind(fd, sockaddr_in{family=AF_INET, ip=ip_be, port=port_host}).
    Builds the sockaddr_in inline; the address bytes are stack-local.

    SAFETY: sockaddr stack-local; kernel reads 16 bytes and does not
    retain the pointer past the syscall return.
    """
    if fd < Int32(0):
        raise Error("bind_inet: bad fd")
    var sa = sockaddr_in_bytes(ip_be, port_host)
    var rc = external_call["bind", Int32](
        fd, sa.unsafe_ptr(), UInt32(16),
    )
    if rc < Int32(0):
        raise Error("bind() failed")


def listen_socket(fd: Int32, backlog: Int32) raises:
    """Listen(fd, backlog). Marks the socket as a passive listener."""
    if fd < Int32(0):
        raise Error("listen_socket: bad fd")
    var rc = external_call["listen", Int32](fd, backlog)
    if rc < Int32(0):
        raise Error("listen() failed")


def getsockname_port(fd: Int32) raises -> UInt16:
    """Getsockname(fd, &sockaddr_in, &len) — read the port the kernel
    actually bound the socket to (used when the caller passed port=0
    to let the kernel pick an ephemeral port).

    SAFETY: sa + len_buf are stack-local; kernel writes up to 16 bytes
    of sockaddr + 4 bytes of length and does not retain the pointers
    past the syscall return.
    """
    if fd < Int32(0):
        raise Error("getsockname_port: bad fd")
    var sa = Array[UInt8, 16](fill=UInt8(0))
    var len_buf = Array[UInt32, 1](fill=UInt32(16))
    var rc = external_call["getsockname", Int32](
        fd, sa.unsafe_ptr(), len_buf.unsafe_ptr(),
    )
    if rc < Int32(0):
        raise Error("getsockname() failed")
    # Decode big-endian port from bytes [2:4].
    return UInt16(Int(sa[2]) << 8 | Int(sa[3]))


def close_fd(fd: Int32):
    """Close(fd) — best-effort; idempotent on bad fds. Returns no error."""
    if fd >= Int32(0):
        _ = external_call["close", Int32](fd)


# SO_ERROR optname value — differs by OS (the original comment claiming
# "Linux & Darwin both use 0x1007" was empirically wrong):
#   Linux:  SO_ERROR = 4       (asm-generic/socket.h)
#   Darwin: SO_ERROR = 0x1007  (xnu sys/socket.h)
#
# Mirrors the _SOL_SOCKET_LINUX/_MACOS + _sol_socket_value() pattern at
# lines 72-93 above.
comptime _SO_ERROR_OPTNAME_LINUX: Int32 = Int32(4)
comptime _SO_ERROR_OPTNAME_MACOS: Int32 = Int32(0x1007)


@always_inline
def _so_error_optname() -> Int32:
    """SO_ERROR optname — Linux: 4 (asm-generic/socket.h);
    Darwin: 0x1007 (xnu sys/socket.h)."""
    comptime if CompilationTarget.is_macos():
        return _SO_ERROR_OPTNAME_MACOS
    else:
        return _SO_ERROR_OPTNAME_LINUX


def get_so_error(fd: Int32) raises -> Int32:
    """Getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errlen) — read and
    CONSUME the pending socket-level error code.

    Used after a non-blocking `connect()` that returned EINPROGRESS and
    subsequently fired EPOLLOUT/EVFILT_WRITE: the actual connect result
    (success 0, or ECONNREFUSED / EHOSTUNREACH / ENETUNREACH / etc.) is
    pending on the socket. `SO_ERROR` returns it and atomically clears
    the pending state.

    Returns the errno value (0 if connect succeeded, non-zero on error).
    Raises if the getsockopt syscall itself fails (would mean fd is bad
    or we're calling this on a non-socket — programmer error, not a
    network error).

    SAFETY: optval/optlen stack-local; kernel writes back via the
    pointers and does not retain them past the syscall return.
    """
    if fd < Int32(0):
        raise Error("get_so_error: bad fd")
    var optval = Array[Int32, 1](fill=Int32(0))
    var optlen = Array[UInt32, 1](fill=UInt32(4))
    var rc = external_call["getsockopt", Int32](
        fd,
        _sol_socket_value(),
        _so_error_optname(),
        optval.unsafe_ptr(),
        optlen.unsafe_ptr(),
    )
    if rc < Int32(0):
        raise Error("getsockopt(SO_ERROR) failed")
    return optval[0]
