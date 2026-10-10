# =============================================================================
# komira_async.runtime.tcp_stream — TcpStream + TcpListener
# =============================================================================
# long-lived registration consumers per
#
# TcpStream and TcpListener are the user-facing wrapper types that own
# ONE multiplexer registration each for their lifetime. This avoids the
# per-IO EPOLL_CTL_ADD / DEL pair that makes every IO ~1500-2500ns
# instead of the ~80-120ns try_io fast path.
#
# Lifetime model:
#   1. Construct from a raw fd (TcpListener.bind / accept produces the
#      fd; TcpStream is built from the accepted fd or a new socket).
#   2. NO multiplexer registration at construction — lazy on first
#      EWOULDBLOCK.
#   3. On the first read/write that hits EWOULDBLOCK: call
#      `Reactor.register_long_lived(fd, INTEREST_*)`, store the
#      RegistrationHandle. Subsequent IOs that hit EWOULDBLOCK with a
#      different interest call `Reactor.modify(reg, new_interest)`.
#   4. On drop: deregister (epoll_ctl_del) BEFORE close(fd), so the
#      kernel doesn't process post-close events for the now-stale fd.
#
# Movability: TcpStream + TcpListener are Movable but NOT Copyable —
# cloning would let two values race the close-fd / deregister sequence
# at drop. Mojo's borrow checker enforces single-ownership; the
# `Optional[RegistrationHandle]` field uses `Optional.take()` semantics
# (the canonical partial-move primitive — the replacement for a
# partial move through an UnsafePointer).
#
# Pointer + lint discipline:
#   - All public methods accept / return typed scalars + Span[UInt8] +
#     TryIoResult / TcpStream POD types. NO UnsafePointer in any signature.
#   - Per-call `ref reactor: Reactor[S]` parameterizes IO methods over the
#     WakerSink type S; the Reactor is provided by the caller (worker
#     loop or test). Construction-time ctx is NOT required.
#   - __del__ uses a free-fn helper (`_tcp_stream_close_helper`) per the
#     `_runtime_teardown_join` / no-mut-self-in-deinit discipline; the
#     helper takes the fd + epoll_fd directly (no Reactor reference).
# =============================================================================

from std.memory import OwnedPointer
from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    INTEREST_WRITE,
    OP_READ,
    OP_WRITE,
    OpHandle,
    RegistrationHandle,
)
from komira_async.reactor.reactor import Reactor
from komira_async.reactor.socket_io import (
    TRY_IO_ERROR,
    TRY_IO_READY,
    TRY_IO_WOULD_BLOCK,
    TryIoResult,
    try_io_accept,
    try_io_read,
    try_io_write,
)
from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    get_so_error,
    getsockname_port,
    inet_loopback_be,
    listen_socket,
    set_so_reuseaddr,
    set_so_reuseport,
    socket_tcp_nonblocking,
    sockaddr_in_bytes,
)
from komira_async.reactor.socket_io import try_io_connect, errno_is_in_progress
from komira_async.reactor.epoll_subsystem import epoll_ctl_del


# =============================================================================
# Free-fn destructor helpers — per `_runtime_teardown_join` discipline.
# =============================================================================
#
# `__del__(deinit self)` cannot call `mut self` methods on the Reactor
# (Reactor is no longer accessible — TcpStream/TcpListener don't hold a
# Reactor reference; they hold the multiplexer fd directly).
#
# `_tcp_close_helper(fd, epoll_fd, registered)`:
#   - If `registered` and `epoll_fd >= 0`: call `epoll_ctl_del(epoll_fd, fd)`.
#     Per epoll_ctl_del's existing contract this is best-effort (ENOENT
#     swallowed). Order-of-ops: deregister BEFORE close so the kernel
#     does not emit events for a stale-fd in the brief window between
#     close + a peer rejecting the fd.
#   - close(fd) via libc.
#
# Per epoll(7): "A file descriptor that is added to an epoll instance is
# automatically removed when all file descriptors referring to the
# underlying file have been closed." So close-without-deregister IS safe
# in steady state, but explicit deregister-before-close is the documented
# best practice (avoids transient race where another open fd from another
# thread keeps the file alive past our close).


def _tcp_close_helper(fd: Int32, epoll_fd: Int32, registered: Bool):
    """Free-fn destructor helper for TcpStream / TcpListener.

    Called from __del__(deinit self). Takes typed scalars only — no
    `mut self` re-entry, no Reactor reference. Best-effort on the
    deregister path (epoll_ctl_del swallows ENOENT internally).
    """
    if registered and epoll_fd >= Int32(0) and fd >= Int32(0):
        try:
            epoll_ctl_del(epoll_fd, fd)
        except:
            pass
    close_fd(fd)


def _tcp_deregister_only(fd: Int32, epoll_fd: Int32, registered: Bool):
    """Destructor helper for a BORROWED listener fd (TcpListener with
    `_owns_fd=False`).

    Same deregister step as `_tcp_close_helper` — the listener owns its OWN
    reactor registration even when it borrows the fd — but does NOT `close()`
    the fd. The fd's owner (the macOS prefork master in
    search_server_main.main()) closes it exactly once after joining all
    workers. Closing here would double-close / risk fd reuse under the other
    workers' still-live registrations.
    """
    if registered and epoll_fd >= Int32(0) and fd >= Int32(0):
        try:
            epoll_ctl_del(epoll_fd, fd)
        except:
            pass


# =============================================================================
# THE DIAL DEADLINE — there is NO input that yields an unbounded dial.
# =============================================================================
#
# ⛔ THE DEFECT CLASS THIS CLOSES, AND IT IS A CLASS — NOT AN INSTANCE.
#
# `TcpStream.connect` is the ONE choke point every outbound TCP connection in
# this tree passes through: `Connector.connect` takes an ALREADY-RESOLVED
# `ip_be: UInt32` and bottoms out here, for `KernelTcpConnector`, for
# `TlsConnector` (which delegates), for `pg_tls`, for every future conformer.
# Until 2026-09-22 its deadline was an OPTIONAL ARGUMENT WHOSE DEFAULT WAS
# `Int32(-1)` = **park forever**, and the only reason production dials were
# bounded at all is that ONE conformer happened to pass a literal
# (`kernel_tcp._CONNECT_TIMEOUT_US`). A bound that has to be re-stated at each
# call site is missing at call site N+1 — and here N+1 had already arrived:
# `komira_db_postgres/wire/pg_tls.mojo` and `komira_pipeline_runtime/socket_black_box_
# service.mojo` both dialled on the default and therefore on the UNBOUNDED arm.
#
# ⛔ AND THE UNBOUNDED ARM WAS ALSO WRONG ON ITS OWN TERMS. It did ONE
# `poll_completions(timeout_us=Int32(-1))` and then read `SO_ERROR` — exactly
# the premature read the bounded arm's own comment forbids by name, because
# `poll_completions` returns on ANY reactor event (a drained wake-eventfd
# contributes an EMPTY list and still ends the syscall; so does a FOREIGN fd's
# completion — invariant (ii), `stream_park.park_on_pending`). On a
# still-in-flight connect `SO_ERROR` reads 0, because EINPROGRESS lives in
# `connect()`'s RETURN and not in the socket-level error. So a wake belonging
# to somebody else made this function hand back a socket that was NOT
# CONNECTED, and the caller's first write then parked in
# `_read_or_write_loop`'s `poll_completions(-1)` — a permanent, zero-egress,
# zero-stdout hang of the calling thread. On a single-threaded serve loop
# (typical for a small service) that is a total outage of every route.
#
# ── THE RULE ─────────────────────────────────────────────────────────────────
#
# FAIL-SAFE BY CONSTRUCTION, the same shape `tls_connector._resolve_handshake_
# deadline_us` already ships one layer up: every rejection path (unset, zero,
# negative, the historical `-1` sentinel) returns the DEFAULT. There is no
# input that yields "no deadline". A caller that knows its own share states it
# and gets it VERBATIM; a caller that states nothing gets a bound anyway.
#
# ⚠ THIS IS NOT A TUNING KNOB AND MUST NOT BE READ AS ONE. `KernelTcpConnector`
# still states 5s and still gets 5s. What changed is what happens when NOBODY
# states anything, which used to be "wait forever" and is now "10s".
#
# ⛔ AND IT IS DELIBERATELY NOT THREADED THROUGH `Connector.connect`. That
# trait has 22 conformers and takes an already-resolved address; a deadline
# parameter there would bound the TCP connect (bounded here) and the TLS
# handshake (already 30s wall) and would change NO worst case, while adding 22
# places for the next one to go missing. The deadline belongs at the ONE place
# every dial reaches.
#
# ⚠ WHAT THIS DOES **NOT** BOUND, STATED SO IT IS NOT MIS-CITED: DNS.
# `getaddrinfo(3)` runs STRICTLY BEFORE any connector is entered
# (`komira_http/client/client.mojo:_ip_be_from_host`), takes no timeout and
# cannot be cancelled. It remains the one structurally unbounded phase of a
# cold dial, and it is INVISIBLE to `container/network/*` on Cloud Run because
# the resolver is link-local. Bounding it needs a resolver this runtime can
# abandon, not a check at a call site. Named, not silently omitted.
# =============================================================================

comptime CONNECT_DEADLINE_DEFAULT_US: Int32 = Int32(10_000_000)
"""The dial deadline for a caller that states none (10s).

⚠ DERIVED, NOT MEASURED, AND SAID SO. The only number in this tree anybody
has ever AUTHORED for a TCP dial is `kernel_tcp._CONNECT_TIMEOUT_US` (5s), and
the only ceiling a dial provably runs inside is a Cloud Run request (300s).
10s is 2x the one authored bound and far under the one real ceiling; it is not
a claim about how long a dial takes, because nothing here measured that. The
number is not the point — the point is that "nobody stated a deadline" and
"wait forever" stop being the same bytes. If a real dial-latency distribution
is ever measured, THIS is the line that should change."""

comptime CONNECT_PARK_SLICE_US: Int64 = 50_000
"""The bounded park slice inside the dial loop (50ms).

⚠ HOW LONG ONE PARK MAY BLOCK, NOT HOW LONG THE DIAL MAY TAKE. Conflating the
two is the bug `tls_connector.mojo`'s banner describes. The slice exists so
a park that is woken by nothing (or by somebody else's completion) RETURNS to
the loop, which re-reads the monotonic clock and can therefore fail the dial;
the DEADLINE is what ends it."""

comptime CONNECT_DEADLINE_EXPIRED: Int64 = Int64(-1)
"""`connect_park_slice_us`'s verdict "the deadline has passed — raise, do not
park". A distinguished NEGATIVE value, because every legal slice is >= 1: a
caller cannot mistake it for a timeout to pass to `poll_completions`, which is
precisely how "remaining budget went negative" becomes "unbounded wait"
elsewhere."""


def resolve_connect_timeout_us(requested: Int32) -> Int32:
    """The dial deadline a connect actually gets, in microseconds. ALWAYS > 0.

    THE TABLE (there is no other outcome):

      requested > 0   -> requested, VERBATIM. A caller that knows its own share
                         keeps it (`KernelTcpConnector`'s 5s).
      requested <= 0  -> CONNECT_DEADLINE_DEFAULT_US. Covers unset (`0`), the
                         historical "unbounded" sentinel (`-1`), and a
                         remaining-budget subtraction that went NEGATIVE —
                         which is the shape that turns a bound into its
                         opposite in the direction that fails OPEN.

    ⛔ THERE IS NO ARM THAT RETURNS A NON-POSITIVE VALUE, AND THAT IS THE WHOLE
    FUNCTION. A `0` returned here would be read downstream as "no timeout" by
    `Reactor.poll_completions` (which maps `0` to a non-blocking poll and any
    NEGATIVE to `epoll_wait(-1)`, i.e. block forever), so the one thing this
    must never do is pass a caller's zero through."""
    if requested <= Int32(0):
        return CONNECT_DEADLINE_DEFAULT_US
    return requested


def connect_park_slice_us(deadline_ns: Int64, now_ns: Int64) -> Int64:
    """The next bounded park slice for the dial loop, or
    `CONNECT_DEADLINE_EXPIRED` when the deadline has passed.

    THE TERMINATION ARGUMENT, in three lines, because this is the recurrence
    the whole wedge class lives in:

      1. The verdict is computed from a FRESHLY READ monotonic `now_ns` every
         iteration, never from a remaining-budget counter carried across them.
         A counter can be decremented by the wrong amount; a clock cannot.
      2. Every slice is CLAMPED to the remaining time, so the loop can never
         park past its own deadline, and
      3. every slice is at least 1 microsecond, so the clock STRICTLY advances
         on every iteration and the loop cannot spin between clock ticks.

    (1) + (2) + (3) ⇒ the loop reaches `CONNECT_DEADLINE_EXPIRED` in at most
    `ceil(budget_us / CONNECT_PARK_SLICE_US) + 1` iterations, for EVERY
    reachable `(deadline_ns, now_ns)` pair. `test_tcp_connect_dial_deadline.mojo`
    drives that to exhaustion rather than asserting the bound exists."""
    var remaining_ns = deadline_ns - now_ns
    if remaining_ns <= Int64(0):
        return CONNECT_DEADLINE_EXPIRED
    var remaining_us = remaining_ns // Int64(1000)
    var slice_us = remaining_us
    if slice_us > CONNECT_PARK_SLICE_US:
        slice_us = CONNECT_PARK_SLICE_US
    if slice_us <= Int64(0):
        # Sub-microsecond remainder. Park for the smallest observable slice
        # rather than 0: `poll_completions(0)` is a NON-BLOCKING poll, so a 0
        # here would pin a core until the clock ticked over.
        slice_us = Int64(1)
    return slice_us


# =============================================================================
# TcpStream — single TCP connection (read/write).
# =============================================================================


struct TcpStream(Movable):
    """One TCP connection. Owns the fd + at-most-one multiplexer
    registration for the connection's lifetime.

    Movable but NOT Copyable: cloning would let two TcpStream values
    race the close-fd at drop. The `_registration` field uses
    `Optional[RegistrationHandle]` so partial-move semantics are
    explicit (Optional.take() is the canonical partial-move
    primitive).

    Construction-time ctx is NOT required. The fd is provided
    by the caller (e.g., from `TcpListener.try_accept()` or
    `socket_tcp_nonblocking()` + connect). The first IO that hits
    EWOULDBLOCK lazily registers with whichever Reactor the caller
    threads in.

    Field set:
      var _fd: OwnedPointer[Int32]          — the fd (-1 once released)
      var _registration: Optional[RegistrationHandle]
                                            — None until first EWOULDBLOCK
      var _epoll_fd: OwnedPointer[Int32]    — multiplexer fd captured at
                                              registration time; -1
                                              sentinel before registration.

    Why OwnedPointer for the two Int32 fds: a bare Int32 field is
    trivially Copyable, so the auto-synthesized __moveinit__ bitcopies
    the value into the new struct AND leaves it in the moved-from
    source. The source's __del__ then runs (Mojo runs destructors on
    moved-from values), calling close() on a fd that the destination
    is now using. OwnedPointer[Int32] is Movable-only, which propagates
    the single-owner discipline up to the parent struct: synth-moveinit
    moves the OwnedPointer (consuming the source), and the source's
    __del__ runs on a now-empty handle whose drop is a no-op.
    """

    var _fd: OwnedPointer[Int32]
    var _registration: Optional[RegistrationHandle]
    var _epoll_fd: OwnedPointer[Int32]

    def __init__(out self, fd: Int32):
        """Construct from a raw fd. The caller is responsible for ensuring
        the fd is non-blocking (e.g., via `socket_tcp_nonblocking()` or
        `try_io_accept()` which sets SOCK_NONBLOCK on the accepted fd).

        Does NOT register with any reactor.
        """
        self._fd = OwnedPointer[Int32](fd)
        self._registration = Optional[RegistrationHandle]()
        self._epoll_fd = OwnedPointer[Int32](Int32(-1))

    # The synthesized __moveinit__ moves the OwnedPointer fields, consuming
    # the source (no double-close).

    def __deinit__(deinit self):
        """Drop: deregister (if registered) + close.

        Free-fn helper (`_tcp_close_helper`) per the no-mut-self-in-deinit
        discipline. The helper takes typed scalars; no Reactor reference
        needed (the epoll_fd was captured at registration time).
        """
        var registered = self._registration.__bool__()
        var fd = self._fd[]
        var epoll_fd = self._epoll_fd[]
        # Drop the Optional (releases the RegistrationHandle storage) BEFORE
        # the helper fires the kernel deregister.
        _ = self._registration^
        _tcp_close_helper(fd, epoll_fd, registered)

    @always_inline
    def fd(self) -> Int32:
        """Public accessor for the underlying fd. Used by tests + by the
        worker loop's reactor-direct path."""
        return self._fd[]

    def release_fd(mut self) -> Int32:
        """Give up the fd without closing it, and return it. The stream
        then holds -1 and its drop neither closes nor deregisters the
        number, so a stream whose fd was closed behind its back and reused
        can be dropped without closing the new owner's descriptor."""
        var fd = self._fd[]
        self._fd[] = Int32(-1)
        return fd

    @always_inline
    def is_registered(self) -> Bool:
        """True iff the lazy registration has been materialized
        (the first EWOULDBLOCK has fired). Used by tests to verify the
        long-lived-registration invariant (one register, N modify, one
        deregister)."""
        return self._registration.__bool__()

    # -------------------------------------------------------------------------
    # Outbound-connection constructors — sibling to TcpListener.bind / accept.
    # They support
    # an HTTP client's connector. The HTTP client side needs to
    # *dial* peers (outbound connections); the existing TcpStream API only
    # supports being-accepted streams. `connect` builds a non-blocking
    # TCP socket, posts the connect(2) syscall, and parks for completion
    # on the reactor.
    # -------------------------------------------------------------------------

    @staticmethod
    def connect[
        S: WakerSink & Movable & Deinitable,
    ](
        mut reactor: Reactor[S],
        ip_be: UInt32,
        port: UInt16,
        connect_timeout_us: Int32 = Int32(0),
    ) raises -> TcpStream:
        """Outbound connect to ip_be:port. Returns a TcpStream wrapping the
        connected fd.

        Algorithm (mirror of TcpListener.accept's spin-then-park shape):
          1. socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK).
          2. try_io_connect(fd, sockaddr_in_bytes(ip_be, port)).
          3. If Ready: connect completed eagerly (rare on cross-host
             TCP; common on loopback / AF_UNIX). Return TcpStream(fd).
          4. If InProgress (EINPROGRESS): register WRITE interest on
             the fd, park on poll_completions until the fd surfaces
             writable, then call getsockopt(SO_ERROR) to recover the
             actual connect result. If SO_ERROR == 0: connect
             succeeded — return TcpStream(fd). Non-zero: raise with
             the errno.
          5. If WouldBlock: route same as InProgress (POSIX says
             connect returns EINPROGRESS, but some kernels return
             EAGAIN for AF_UNIX).
          6. If Error: close fd + raise.

        On ANY failure, the socket fd is closed before the error
        propagates — no leak. On EINPROGRESS, the wrapped TcpStream
        takes ownership immediately and the fd is closed via the
        normal TcpStream drop path if a subsequent step raises.


        `connect_timeout_us` bounds the EINPROGRESS park so a hung / slow
        dial against a saturated backend FAILS FAST (then the caller's
        existing retry/backoff handles it) instead of parking forever.

        ⛔ THERE IS NO UNBOUNDED ARM ANY MORE. `connect_timeout_us`
        is resolved through `resolve_connect_timeout_us`, which returns
        `CONNECT_DEADLINE_DEFAULT_US` for EVERY non-positive input — unset
        (`0`), the historical "park forever" sentinel (`-1`), and a
        remaining-budget subtraction that went negative. See that function and
        the module-level banner above it for the whole argument; the short
        version is that the default used to be "wait forever" and two
        production callers took it.

        The dial then parks in bounded slices against a MONOTONIC deadline
        (`perf_counter_ns`, re-read every iteration — never a carried-forward
        remaining-budget counter). On each slice:
              - our fd surfaced AND SO_ERROR == 0 → connected; return the
                stream.
              - our fd surfaced AND SO_ERROR == EINPROGRESS → a spurious early
                wake; still dialing, loop until the deadline.
              - our fd surfaced AND SO_ERROR == anything else → connect failed
                (raise with the errno).
              - our fd did NOT surface (an empty poll, or only FOREIGN
                completions / a drained wake-eventfd) → the connect is still in
                flight; loop until the deadline. ⛔ SO_ERROR IS NOT READ HERE,
                and that is load-bearing: on a still-in-flight connect it reads
                0 (EINPROGRESS lives in `connect()`'s return, not in the
                socket-level error), so a read here would hand back a socket
                that is NOT CONNECTED. The deleted unbounded arm did exactly
                that after a single `poll_completions(-1)`.
            When the deadline elapses with the connect still in progress,
            raise `TcpStream.connect: connect timed out` so the dialer
            fails fast. The stream's __del__ closes + deregisters the fd.
        This prevents a multi-second indefinite-park stall when a fresh
        dial meets a saturated object-store endpoint.

        SAFETY: the addr bytes are stack-local; try_io_connect's FFI
        boundary does not retain the pointer past the syscall return.
        """
        var fd = socket_tcp_nonblocking()
        # Take ownership of the fd as a TcpStream IMMEDIATELY, so any
        # later raise drops the stream and closes the fd via __del__.
        # This is the same pattern TcpListener.bind uses (it wraps fd
        # in TcpListener before letting subsequent failures propagate).
        var addr = sockaddr_in_bytes(ip_be, port)
        var r = try_io_connect(fd, Span[UInt8](addr))
        if r.is_ready():
            # Eager completion — common on loopback.
            return TcpStream(fd)
        if r.is_error():
            # Hard error before the kernel even queued the SYN.
            close_fd(fd)
            raise Error("TcpStream.connect: connect() error")
        # InProgress / WouldBlock → park on WRITE readiness.
        var stream = TcpStream(fd)
        # Ensure WRITE registration; lazy on first park.
        stream._ensure_registered[S](reactor, is_read=False)

        # ⛔ NO `if connect_timeout_us < 0` ARM. Deleted it was
        # ONE `poll_completions(-1)` followed by a premature SO_ERROR read, so
        # a foreign completion made it return an UNCONNECTED socket, and
        # otherwise it blocked the calling thread forever. The resolver below
        # makes every value a caller can supply a POSITIVE deadline.
        var deadline_budget_us = resolve_connect_timeout_us(connect_timeout_us)

        # Bounded park against a monotonic deadline (fail-fast dial).
        #
        # Readiness signal: the WRITE registration's completion `op_id` is
        # the fd itself (Reactor.register_long_lived uses the fd as the
        # kqueue udata / epoll ev.data cookie). The connect is RESOLVED
        # only once our fd surfaces writable — at that point getsockopt
        # SO_ERROR carries the real connect result (0 = success; non-zero
        # = ECONNREFUSED / EHOSTUNREACH / ...). We must NOT read SO_ERROR
        # before the fd surfaces: on a still-in-flight connect SO_ERROR
        # reads 0 (EINPROGRESS lives in connect()'s return, not in the
        # socket-level error), so a premature read would falsely report
        # "connected". Therefore: keep polling in bounded slices until
        # EITHER our fd's completion arrives (then read SO_ERROR) OR the
        # deadline elapses (fail fast).
        var our_fd_op_id = Int64(stream.fd())
        var deadline_ns = Int64(perf_counter_ns()) + Int64(
            deadline_budget_us
        ) * Int64(1000)
        while True:
            # ⚠ THE CLOCK IS RE-READ EVERY ITERATION. The verdict is never
            # carried in a decremented counter: a counter can be decremented
            # by the wrong amount (or go negative and be read as "unbounded"),
            # a monotonic clock cannot.
            var slice_us = connect_park_slice_us(
                deadline_ns, Int64(perf_counter_ns())
            )
            if slice_us == CONNECT_DEADLINE_EXPIRED:
                # Deadline elapsed — the connect never completed. Fail
                # fast; stream's __del__ closes + deregisters the fd.
                raise Error(
                    "TcpStream.connect: connect timed out after "
                    + String(deadline_budget_us)
                    + "us",
                )
            var completions = reactor.poll_completions(
                timeout_us=Int32(slice_us),
            )
            # Did OUR fd surface (writable / error / hangup)?
            var our_fd_ready = False
            for ci in range(len(completions)):
                if completions[ci].op_id == our_fd_op_id:
                    our_fd_ready = True
                    break
            if not our_fd_ready:
                # Either a timeout (empty list) or only unrelated fds /
                # wakes surfaced — the connect is still in flight. Loop
                # until the deadline.
                continue
            # Our fd surfaced — the connect result is now resolved.
            var so_err = get_so_error(stream.fd())
            if so_err == Int32(0):
                return stream^
            if errno_is_in_progress(so_err):
                # Defensive: a spurious early wake before the SYN-ACK
                # fully resolved. Keep waiting until the deadline.
                continue
            # Hard connect error (ECONNREFUSED / EHOSTUNREACH / ...).
            raise Error(
                "TcpStream.connect: connect failed (errno="
                + String(so_err)
                + ")",
            )

    @staticmethod
    def connect_loopback[
        S: WakerSink & Movable & Deinitable,
    ](
        mut reactor: Reactor[S], port: UInt16,
    ) raises -> TcpStream:
        """Convenience: connect to 127.0.0.1:port. Useful for tests + the
        KernelTcpConnector's loopback test path.
        """
        return Self.connect[S](reactor, inet_loopback_be(), port)

    # -------------------------------------------------------------------------
    # Sync (state-machine track) APIs — block until ready by polling the
    # reactor inline. Useful for tests and for the state-machine track that
    # spin-then-park rather than suspending a coroutine.
    # -------------------------------------------------------------------------

    def read[
        S: WakerSink & Movable & Deinitable
    ](
        mut self, mut reactor: Reactor[S], buf: Span[UInt8, _],
    ) raises -> Int64:
        """Blocking read. Returns bytes-read.

        Algorithm:
          1. try_io_read on the fd.
          2. If Ready: return bytes.
          3. If Error: raise with the errno.
          4. If WouldBlock: ensure long-lived registration is up
             (register on first hit; modify if interest needs to switch
             from write→read), then poll_completions in a loop until
             our fd surfaces. Re-loop to step 1 (the EPOLLET drain
             discipline — after a ready event, drain to EAGAIN).

        For the 0-byte EOF case (peer cleanly closed): try_io_read
        returns Ready(0); caller treats as EOF.
        """
        return self._read_or_write_loop[S](
            reactor, buf, is_read=True,
        )

    def write[
        S: WakerSink & Movable & Deinitable
    ](
        mut self, mut reactor: Reactor[S], buf: Span[UInt8, _],
    ) raises -> Int64:
        """Blocking write. Returns bytes-written (may be < len(buf) on
        a short kernel write; caller is responsible for looping on the
        remainder).

        Algorithm: symmetric to `read` but using try_io_write +
        INTEREST_WRITE.
        """
        return self._read_or_write_loop[S](
            reactor, buf, is_read=False,
        )

    def _read_or_write_loop[
        S: WakerSink & Movable & Deinitable
    ](
        mut self,
        mut reactor: Reactor[S],
        buf: Span[UInt8, _],
        is_read: Bool,
    ) raises -> Int64:
        """Shared body for `read` and `write`. Branches on `is_read`
        because the two paths share the spin-then-park structure;
        only the syscall + interest-set differ.
        """
        # Outer loop: try_io → on WouldBlock, ensure registration + park.
        while True:
            var r: TryIoResult
            if is_read:
                r = try_io_read(self._fd[], buf)
            else:
                r = try_io_write(self._fd[], buf)

            if r.is_ready():
                return r.value()
            if r.is_error():
                raise Error("TcpStream IO error")
            # WouldBlock: ensure registration, then park.
            self._ensure_registered[S](reactor, is_read)
            # Park on poll_completions until our fd surfaces. Use a
            # bounded timeout to allow shutdown signals to fire; in
            # the awaitable layer this is replaced by
            # _suspend_async.
            var _drained = reactor.poll_completions(timeout_us=Int32(-1))
            # Loop back and re-try the syscall (EPOLLET drain-to-EAGAIN
            # discipline).

    # ---- Cancellation-aware variants -------------------------------

    def read_with_token[
        S: WakerSink & Movable & Deinitable
    ](
        mut self, mut reactor: Reactor[S], buf: Span[UInt8, _],
        token: CancellationToken,
    ) raises -> Int64:
        """Cancellation-aware blocking read.

        Polls `token.is_cancelled()` BEFORE every reactor.poll_completions
        iteration. On cancellation, deregisters (if registered) and raises
        `Error("CancelledError: " + reason)`.

        Pre-entry cancel check is a fast-path without touching the
        reactor. Per-iter cancel check uses a bounded poll timeout
        (default 100ms) so the loop responds to cancellation within a
        bounded latency even if no IO event arrives.
        """
        if token.is_cancelled():
            raise Error("CancelledError: " + token.reason())
        return self._read_or_write_loop_with_token[S](
            reactor, buf, is_read=True, token=token,
        )

    def write_with_token[
        S: WakerSink & Movable & Deinitable
    ](
        mut self, mut reactor: Reactor[S], buf: Span[UInt8, _],
        token: CancellationToken,
    ) raises -> Int64:
        """Cancellation-aware blocking write."""
        if token.is_cancelled():
            raise Error("CancelledError: " + token.reason())
        return self._read_or_write_loop_with_token[S](
            reactor, buf, is_read=False, token=token,
        )

    def _read_or_write_loop_with_token[
        S: WakerSink & Movable & Deinitable
    ](
        mut self,
        mut reactor: Reactor[S],
        buf: Span[UInt8, _],
        is_read: Bool,
        token: CancellationToken,
    ) raises -> Int64:
        """Shared body for cancellation-aware read/write. Per-iter polling
        of token cancellation between bounded poll_completions intervals.

        Cancellation latency: bounded by the per-iter poll_timeout_us
        (100_000 us = 100ms; matches typical signal-handler latencies).
        Production tuning may want lower values; 100ms is the v0.1 default.
        """
        comptime CANCEL_POLL_TIMEOUT_US: Int32 = 100_000  # 100ms
        while True:
            # Pre-iter cancel check.
            if token.is_cancelled():
                raise Error("CancelledError: " + token.reason())

            var r: TryIoResult
            if is_read:
                r = try_io_read(self._fd[], buf)
            else:
                r = try_io_write(self._fd[], buf)

            if r.is_ready():
                return r.value()
            if r.is_error():
                raise Error("TcpStream IO error")
            # WouldBlock: ensure registration, then park with bounded
            # timeout so cancellation can be observed.
            self._ensure_registered[S](reactor, is_read)
            var _drained = reactor.poll_completions(
                timeout_us=CANCEL_POLL_TIMEOUT_US,
            )
            # Loop back and re-try (with cancel check at top).

    def _ensure_registered[
        S: WakerSink & Movable & Deinitable
    ](
        mut self,
        mut reactor: Reactor[S],
        is_read: Bool,
    ) raises:
        """Lazy-on-EWOULDBLOCK registration helper.

        On the first EWOULDBLOCK, materializes a long-lived registration
        with INTEREST_READ or INTEREST_WRITE based on `is_read`.

        On subsequent EWOULDBLOCK with a different direction, calls
        Reactor.modify to switch the interest set. The Reactor.modify
        no-op fast path skips the syscall when the interest
        set is unchanged.
        """
        var desired_interest: UInt8
        if is_read:
            desired_interest = INTEREST_READ
        else:
            desired_interest = INTEREST_WRITE

        if self._registration.__bool__():
            # Already registered. Switch interest if needed (no-op fast
            # path inside reactor.modify avoids the syscall when
            # already-armed for this direction).
            var current_reg = self._registration.value()
            if current_reg.interest_set() != desired_interest:
                reactor.modify(current_reg, desired_interest)
                # Update our stored handle's interest bitmask so future
                # _ensure_registered calls hit the no-op fast path. The
                # RegistrationHandle is POD (Copyable);
                # we replace the Optional with a fresh handle carrying
                # the new interest set.
                self._registration = Optional[RegistrationHandle](
                    RegistrationHandle(
                        _fd=current_reg.fd(),
                        _interest_set=desired_interest,
                    ),
                )
            return

        # First-EWOULDBLOCK path: register_long_lived + cache.
        var reg = reactor.register_long_lived(self._fd[], desired_interest)
        self._registration = Optional[RegistrationHandle](reg)
        self._epoll_fd[] = reactor.epoll_fd()

    # -------------------------------------------------------------------------
    # Async (async/await track) — SKETCH ONLY.
    # The signatures here exist so the API surface compiles and the full
    # awaitable bodies have a slot to fill in without additive-API churn.
    # -------------------------------------------------------------------------

    # A sketch (commented out — would require ReadAwaitable /
    # WriteAwaitable types that do not exist):
    #
    # fn read_async[ctx_origin: Origin[mut=True]](
    #     mut self,
    #     ref [ctx_origin] ctx: TaskContext,
    #     buf: Span[UInt8, _],
    # ) -> ReadAwaitable: ...
    #
    # fn write_async[ctx_origin: Origin[mut=True]](
    #     mut self,
    #     ref [ctx_origin] ctx: TaskContext,
    #     buf: Span[UInt8, _],
    # ) -> WriteAwaitable: ...


# =============================================================================
# TcpListener — accept-side wrapper.
# =============================================================================


struct TcpListener(Movable):
    """Listening TCP socket. Owns the listener fd + at-most-one
    multiplexer registration (similar shape to TcpStream).

    Movability + Copyability rules: same as TcpStream (Movable, NOT
    Copyable; cloning would race close at drop). Both fd fields use
    `OwnedPointer[Int32]` for the same single-owner-on-move discipline
    documented on TcpStream.

    Field set:
      var _fd: OwnedPointer[Int32]          — listener fd (heap-stashed
                                              for Movable-only semantics)
      var _registration: Optional[RegistrationHandle]
                                            — None until first
                                              EWOULDBLOCK on accept
      var _epoll_fd: OwnedPointer[Int32]    — captured at registration time
      var _owns_fd: Bool                    — True for self-bound sockets
                                              (bind/bind_reuseport); False
                                              for a SHARED listener fd handed
                                              in via `from_listening_fd`.
                                              When False, `__del__` still
                                              deregisters THIS listener's own
                                              reactor registration (which it
                                              owns) but does NOT close the fd
                                              — the fd's owner (the
                                              macOS prefork master of a
                                              shared-accept server) closes
                                              it exactly once after joining all
                                              workers. This is a
                                              POD Bool flag, NOT a
                                              lifetime-defeating pattern (no
                                              pointer, no wildcard origin).

    Construction: `TcpListener.bind(ip_be, port)` (or `bind_loopback(port)`)
    builds the socket + bind + listen + non-blocking + SO_REUSEADDR.
    Pass port=0 to let the kernel pick an ephemeral port; the bound
    port is read back via `local_port()`.
    """

    var _fd: OwnedPointer[Int32]
    var _registration: Optional[RegistrationHandle]
    var _epoll_fd: OwnedPointer[Int32]
    # POD ownership flag — see the struct doc. True on every self-bind path
    # (bind / bind_loopback / bind_reuseport via the raw-fd ctor); False only
    # for a borrowed SHARED listener fd (`from_listening_fd`, owns_fd=False).
    var _owns_fd: Bool

    def __init__(out self, fd: Int32):
        """Construct from a raw listener fd. Does NOT register with any
        reactor (lazy on first EWOULDBLOCK). OWNS the fd (closes it on drop) —
        this is the self-bind path used by bind / bind_reuseport. For a
        SHARED, externally-owned fd use `from_listening_fd(fd, owns_fd=False)`.
        """
        self._fd = OwnedPointer[Int32](fd)
        self._registration = Optional[RegistrationHandle]()
        self._epoll_fd = OwnedPointer[Int32](Int32(-1))
        self._owns_fd = True

    @staticmethod
    def from_listening_fd(fd: Int32, owns_fd: Bool) -> TcpListener:
        """Construct a TcpListener wrapping a PRE-BOUND, already-`listen()`ing
        fd, with explicit fd ownership.

        macOS shared-accept (prefork) path: the master binds ONE listening
        socket in main() and hands the fd to all N workers; each worker wraps
        the SAME fd in its own TcpListener with `owns_fd=False`, registers it
        for READ on its OWN reactor, and `try_accept()`s on it. The kernel's
        single accept queue then load-balances new connections across whichever
        worker's accept runs next. Only the master (the fd's owner) closes the
        fd, after joining all workers; the borrowing listeners must NOT close
        it on drop (else double-close / fd-reuse hazard).

        `owns_fd=True` is equivalent to the raw-fd `__init__` (self-bind
        ownership). `owns_fd=False` is the borrowed-shared-fd shape: `__del__`
        deregisters this listener's own reactor registration (which it DOES
        own — each worker has its own registration on its own reactor) but
        leaves the fd open.

        Does NOT register with any reactor here (lazy on first EWOULDBLOCK,
        same as `__init__`).
        """
        var self = TcpListener(fd)
        self._owns_fd = owns_fd
        return self^

    # Mojo 0.26.3 synthesizes __moveinit__ for Movable types whose fields
    # are all Movable. The OwnedPointer fields propagate Movable-only
    # semantics so the source is properly consumed on move.

    def __deinit__(deinit self):
        """Drop: deregister (if registered) + close IFF this listener owns the
        fd. A borrowed SHARED listener fd (`_owns_fd=False`, the macOS
        shared-accept path) is deregistered from THIS listener's reactor but
        the fd is left open for its owner (the prefork master) to close once."""
        var registered = self._registration.__bool__()
        var fd = self._fd[]
        var epoll_fd = self._epoll_fd[]
        var owns_fd = self._owns_fd
        _ = self._registration^
        if owns_fd:
            _tcp_close_helper(fd, epoll_fd, registered)
        else:
            _tcp_deregister_only(fd, epoll_fd, registered)

    @always_inline
    def fd(self) -> Int32:
        """Public accessor for the listener fd."""
        return self._fd[]

    @always_inline
    def is_registered(self) -> Bool:
        """True iff the lazy registration has been materialized."""
        return self._registration.__bool__()

    @staticmethod
    def bind(ip_be: UInt32, port: UInt16, backlog: Int32) raises -> TcpListener:
        """Construct a TcpListener bound to ip:port with the given backlog.

        Steps:
          1. socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK).
          2. setsockopt(SO_REUSEADDR=1) — avoid TIME_WAIT failures.
          3. bind(ip:port).
          4. listen(backlog).

        Pass port=0 to let the kernel pick an ephemeral port; query the
        actual port with `local_port()`.
        """
        var fd = socket_tcp_nonblocking()
        try:
            set_so_reuseaddr(fd)
            bind_inet(fd, ip_be, port)
            listen_socket(fd, backlog)
        except e:
            # SAFETY: close the fd before propagating; consume `e^` so
            # the Error moves out (Error is non-implicitly-copyable on
            # 0.26.3).
            close_fd(fd)
            raise e^
        return TcpListener(fd)

    @staticmethod
    def bind_loopback(port: UInt16, backlog: Int32) raises -> TcpListener:
        """Convenience: bind to 127.0.0.1:port. Useful for tests."""
        return Self.bind(inet_loopback_be(), port, backlog)

    @staticmethod
    def bind_reuseport(
        ip_be: UInt32, port: UInt16, backlog: Int32,
    ) raises -> TcpListener:
        """Construct a TcpListener with SO_REUSEPORT enabled — lets multiple
        sockets bind the same port; the kernel hashes incoming SYNs across
        them.

        This is the canonical primitive for per-core HTTP servers: N pthreads each open a SO_REUSEPORT listener on the
        SAME port; the kernel distributes new conns deterministically (by
        client (ip, port) hash on Linux post-3.9).

        Steps:
          1. socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK).
          2. setsockopt(SO_REUSEADDR=1) — same as bind().
          3. setsockopt(SO_REUSEPORT=1) — enables port-sharing.
          4. bind(ip:port).
          5. listen(backlog).

        On failure at any step, the fd is closed before propagating.
        """
        var fd = socket_tcp_nonblocking()
        try:
            set_so_reuseaddr(fd)
            set_so_reuseport(fd)
            bind_inet(fd, ip_be, port)
            listen_socket(fd, backlog)
        except e:
            close_fd(fd)
            raise e^
        return TcpListener(fd)

    def local_port(self) raises -> UInt16:
        """Read back the kernel-assigned ephemeral port (when port=0
        was passed to bind)."""
        return getsockname_port(self._fd[])

    # -------------------------------------------------------------------------
    # try_accept (non-blocking) — exposes the try_io_accept fast path
    # directly. Useful for tests and for the state-machine track's
    # accept-loop body.
    # -------------------------------------------------------------------------

    def try_accept(self) -> TryIoResult:
        """Non-blocking accept. Returns:
          - Ready(new_fd) on success — the caller wraps the fd in a
            new TcpStream.
          - WouldBlock if no pending connection.
          - Error(errno) on syscall failure.

        On Linux, the accepted fd is born non-blocking (accept4
        SOCK_NONBLOCK); on macOS, try_io_accept posts the follow-up
        fcntl per
        """
        return try_io_accept(self._fd[])

    def accept[
        S: WakerSink & Movable & Deinitable
    ](
        mut self, mut reactor: Reactor[S],
    ) raises -> TcpStream:
        """Blocking accept (state-machine track). Returns a TcpStream
        wrapping the accepted fd.

        Algorithm: same shape as TcpStream._read_or_write_loop:
          1. try_io_accept.
          2. If Ready: wrap fd in TcpStream + return.
          3. If Error: raise.
          4. If WouldBlock: ensure listener registration (READ) + park
             on poll_completions; loop.
        """
        while True:
            var r = self.try_accept()
            if r.is_ready():
                # try_io_accept returns the new fd in `value` as Int64;
                # narrow to Int32 for the TcpStream ctor.
                var new_fd = Int32(Int(r.value()))
                return TcpStream(new_fd)
            if r.is_error():
                raise Error("TcpListener.accept: syscall error")
            # WouldBlock — ensure READ registration + park.
            self._ensure_registered[S](reactor)
            var _drained = reactor.poll_completions(timeout_us=Int32(-1))

    def accept_with_token[
        S: WakerSink & Movable & Deinitable
    ](
        mut self, mut reactor: Reactor[S],
        token: CancellationToken,
    ) raises -> TcpStream:
        """Cancellation-aware blocking accept.

        Polls `token.is_cancelled()` at entry and between every park
        cycle; raises CancelledError on cancellation. Per-iter poll
        timeout = 100ms so the loop responds to cancellation within a
        bounded latency.
        """
        comptime CANCEL_POLL_TIMEOUT_US: Int32 = 100_000  # 100ms
        if token.is_cancelled():
            raise Error("CancelledError: " + token.reason())
        while True:
            if token.is_cancelled():
                raise Error("CancelledError: " + token.reason())
            var r = self.try_accept()
            if r.is_ready():
                var new_fd = Int32(Int(r.value()))
                return TcpStream(new_fd)
            if r.is_error():
                raise Error("TcpListener.accept_with_token: syscall error")
            self._ensure_registered[S](reactor)
            var _drained = reactor.poll_completions(
                timeout_us=CANCEL_POLL_TIMEOUT_US,
            )

    def _ensure_registered[
        S: WakerSink & Movable & Deinitable
    ](
        mut self, mut reactor: Reactor[S],
    ) raises:
        """Lazy-on-EWOULDBLOCK registration helper for the listener
        (READ-only — listener readability is the accept-readiness
        signal). Mirror of TcpStream._ensure_registered but always for
        INTEREST_READ.
        """
        if self._registration.__bool__():
            return
        var reg = reactor.register_long_lived(self._fd[], INTEREST_READ)
        self._registration = Optional[RegistrationHandle](reg)
        self._epoll_fd[] = reactor.epoll_fd()
