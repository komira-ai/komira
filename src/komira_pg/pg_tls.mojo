# =============================================================================
# komira_pg/pg_tls.mojo — Postgres SSLRequest preamble + TLS over the reactor
# =============================================================================
#
# The pg wire transport rides the shared `komira_async` reactor primitives: a
# `TcpStream` over `Reactor[RT.Sink]` for the raw cleartext SSLRequest
# exchange + fd lifetime, and komira_http's s2n `TlsConnection` (bound to the
# TcpStream's fd) for the handshake + post-handshake send/recv. Every
# would-block PARKS the calling thread on the reactor (`poll_completions(-1)`)
# instead of busy-spinning a bounded iteration cap; a busy-spin handshake
# only completes when the peer's handshake bytes are already buffered, and
# against a real network it exhausts the cap before any bytes land.
#
# Postgres is a WIRE protocol (not HTTP), so it does NOT use `HttpClient.send`
# or komira_http's `TlsConnector` (which couples TCP-connect + handshake with
# NO in-between cleartext seam). pg "direct TLS" requires the cleartext 8-byte
# SSLRequest + a single 'S'/'N' reply BEFORE TLS starts on the SAME socket, so
# we drive the pieces directly:
#   1. `TcpStream.connect[RT](reactor, ip_be, port)` — the shared reactor-park
#      TCP dial.
#   2. `TcpStream.write/read[RT]` — the cleartext SSLRequest send + 'S' read
#      (parks on the reactor on would-block; owns its own bytes).
#   3. `TlsConnection.new_client(config)` + `bind_fd(stream.fd())` — s2n bound
#      to the SAME fd the TcpStream owns.
#   4. handshake loop parking on the reactor on BLOCKED (the same shape as
#      komira_http's `TlsConnector.connect`: alloc_op_id → register_read/write
#      → poll_completions(-1) → deregister).
#
# TLS 1.3 is required: `set_cipher_preferences("default_tls13")` makes the
# client offer it (a fresh s2n config defaults to TLS 1.2 only in s2n 1.5.6,
# and a Postgres 16 server built on OpenSSL closes the connection before
# ServerHello).
#
# Encapsulation: no UnsafePointer crosses a module boundary; no
# wildcard-origin FIELD; no `unsafe_from_address=Int`. The public surface is
# `PgReactorStream` with send_all / recv_some over safe types (Span / List).
# The raw s2n calls are confined behind komira_http's TLS shim `# SAFETY:`
# boundary.
#
# PARK-BUFFER SAFETY: on a reactor park the pg `_rbuf` is LIVE across the
# yield. `recv_some` here OWNS its decrypt into a stack-local scratch
# `InlineArray` and copies the produced plaintext into the caller's
# `List[UInt8]` BEFORE returning — NO borrowed slice of any caller buffer is
# held across the `poll_completions` park. The handshake loop holds NO
# application bytes at all. See `connection.mojo`'s `_read_one_message` for
# the framing-side borrow discipline (the tight-scoped Span that is fully dead
# before the next recv).
# =============================================================================

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor
from komira_net.dns import resolve_host_be
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.tcp_stream import TcpStream

from komira_http_core.tls.s2n_shim import (
    TlsConfig,
    TlsConnection,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    last_s2n_errno,
    s2n_strerror_message,
)

from komira_pg.pgwire import encode_ssl_request


# -----------------------------------------------------------------------------
# Handshake iteration cap. A real TLS handshake completes in 4-6 round-trips;
# 256 is generous headroom. Each iteration PARKS on the reactor when BLOCKED
# (so the cap is only ever hit on a peer that is alive but never sends the
# next handshake record).
# -----------------------------------------------------------------------------
comptime _HANDSHAKE_ITER_CAP: Int = 256


# -----------------------------------------------------------------------------
# Non-blocking recv status (PgReactorStream.try_recv_some).
# The poll-shaped transport primitive returns one of these instead of parking
# the worker thread: DONE (bytes appended), EOF (close_notify), or PENDING (s2n
# would-block — the caller parks the FRAME on the reactor, not the thread).
# -----------------------------------------------------------------------------
comptime PG_RECV_DONE: UInt8 = 0  # n >= 1 plaintext bytes appended
comptime PG_RECV_PENDING: UInt8 = 1  # would-block; nothing appended; park the fd
comptime PG_RECV_EOF: UInt8 = 2  # peer close_notify (graceful EOF)


# -----------------------------------------------------------------------------
# Host → IPv4-big-endian resolution. "localhost" / "127.0.0.1" / "" and
# dotted-quad literals take the IP-literal FAST PATH (no getaddrinfo). Any
# other name falls through to getaddrinfo via `resolve_host_be`, so a DNS name
# (for example a Kubernetes service name) resolves rather than raising.
#
# Placement: pg connects on a blocking caller thread, so the blocking
# getaddrinfo happens on THIS (calling) thread, before TcpStream.connect; the
# reactor only ever sees the resolved ip_be. The IP-literal fast path inside
# resolve_host_be ensures literals never hit getaddrinfo.
# -----------------------------------------------------------------------------
def _resolve_host_be(host: String) raises -> UInt32:
    # The port is only used to populate getaddrinfo's `service` hint; pg's
    # actual connect port comes from elsewhere. Pass 5432 for a correct hint.
    return resolve_host_be(host, port=UInt16(5432))


# =============================================================================
# PgReactorStream — the encrypted channel over the shared reactor.
# =============================================================================
struct PgReactorStream(Movable, Deinitable):
    """A TLS-encrypted byte channel to a Postgres server, riding the shared
    `komira_async` reactor. The wire methods are METHOD-`[RT]`-parametric
    (`send_all[RT]` / `recv_some[RT]`), NOT struct-`[RT]` — the SAME shape
    `HttpClient.send[RT]` uses (the struct holds NO RT-dependent field; the
    runtime's reactor is supplied at CALL time). So one `PgReactorStream`
    value can be driven by a `BlockingRuntime[NoopSink]` reactor (a
    single-shot caller) OR a `PerCoreAsyncRuntime` reactor (concurrent /
    pipelined reads) — the caller picks the runtime and threads its reactor
    in.

    Owns the `TlsConfig` (s2n) + the `TlsConnection` (s2n) + the underlying
    `TcpStream` (which owns the fd + its reactor registration). NOT Copyable
    (a socket cannot be duplicated). Move via `^`.

    Field declaration order is load-bearing for teardown: Mojo destroys
    fields in REVERSE declaration order. `_config` FIRST + `_conn` AFTER means
    `_conn` (the s2n connection) drops BEFORE `_config` (the s2n config). s2n's
    contract requires the config to outlive every connection that references it
    (s2n_connection holds a non-owning ref via s2n_connection_set_config).
    `_stream` (the fd owner) drops LAST so the fd is closed AFTER the s2n
    connection is freed — s2n_connection_free does not touch the fd (the fd is
    caller-owned per the shim contract), so this ordering is belt-and-braces.

    Heap audit: every field is a single-level Movable struct (TlsConfig /
    TlsConnection are OwnedPointer-of-handle-backed; TcpStream is
    OwnedPointer[Int32] + Optional[RegistrationHandle]). None nests a
    heap-owning element in a byte-slab. This stream lives as a struct FIELD on
    PgConnection (on the stack / inside the connection value), never inside a
    Slab[UInt8].
    """

    var _config: TlsConfig
    var _conn: TlsConnection
    var _stream: TcpStream

    def __init__(
        out self,
        var config: TlsConfig,
        var conn: TlsConnection,
        var stream: TcpStream,
    ):
        self._config = config^
        self._conn = conn^
        self._stream = stream^

    @always_inline
    def fd(self) -> Int32:
        """The underlying socket fd (owned by `self._stream`). A plain Int32 —
        no pointer crosses any boundary. A poll-shaped op parks on read-
        readiness of this fd. -1 if there is no real fd."""
        return self._stream.fd()

    def send_all[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], data: Span[UInt8, _]
    ) raises:
        """Encrypt + send all `data` bytes over the TLS channel, parking on the
        reactor when s2n returns BLOCKED.

        PARK-BUFFER SAFETY: `data` is a borrowed Span the CALLER owns and keeps
        alive for the whole call (the caller's pgwire encode buffer). We never
        retain a slice past the park; s2n consumes `data[off:n]` synchronously
        each send call. On BLOCKED we park on the fd, then re-attempt — `data`
        is still the caller's live buffer, unchanged."""
        var off = 0
        var n = len(data)
        var guard = 0
        while off < n and guard < 1_000_000:
            var res = self._conn.send(data[off:n])
            var outcome = res[0]
            var sent = res[1]
            if outcome == TLS_OUTCOME_ERROR:
                var en = last_s2n_errno()
                raise Error(
                    "pg_tls.send_all: TLS error (s2n_errno="
                    + String(Int(en)) + " '" + s2n_strerror_message(en) + "')"
                )
            if outcome == TLS_OUTCOME_DONE:
                if sent > 0:
                    off += sent
            else:
                # BLOCKED_ON_WRITE (common) / BLOCKED_ON_READ (TLS rekey, rare).
                # Park on the fd for the awaited direction, then re-attempt.
                if sent > 0:
                    off += sent
                self._park[RT](reactor, outcome)
            guard += 1
        if off < n:
            raise Error("pg_tls.send_all: could not flush all bytes")

    def recv_some[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut into: List[UInt8],
        max_bytes: Int,
    ) raises -> Int:
        """Receive + decrypt up to `max_bytes` plaintext bytes, appending them
        to `into`. Returns the number of bytes read. 0 means the peer sent a
        TLS close_notify (graceful EOF). Parks on the reactor when s2n returns
        BLOCKED.

        This BLOCKING method is a thin wrapper over the non-blocking
        `try_recv_some` — `try_recv_some` is the whole decrypt body WITHOUT the
        park; the blocking path adds exactly the `_park` + retry loop: a single
        drain attempt, and on BLOCKED a `_park` then a re-attempt, until DONE /
        EOF / error. The poll-shaped `PgQueryOp` calls `try_recv_some` directly
        and re-parks on the reactor itself (no in-method park).

        PARK-BUFFER SAFETY (the load-bearing park-buffer sign-off): the decrypt
        target is a stack-local `scratch` InlineArray OWNED by `try_recv_some`'s
        frame. The reactor park (`_park` → `poll_completions(-1)`) here happens
        while NO borrowed slice of `into` (the caller's `_rbuf`) is live — the
        prior `try_recv_some` call has fully returned (its scratch is dead and
        the produced plaintext is already copied into `into`) before we park. So
        `_rbuf` being live across the yield is benign: nothing reads or writes it
        during the park, and the next `try_recv_some` re-borrows it fresh."""
        var guard = 0
        while guard < 1_000_000:
            var res = self.try_recv_some[RT](reactor, into, max_bytes)
            var status = res[0]
            var got = res[1]
            if status == PG_RECV_DONE:
                return got
            if status == PG_RECV_EOF:
                return 0  # close_notify / EOF
            # PG_RECV_PENDING: s2n returned BLOCKED. Park on the fd for the
            # awaited direction, then re-attempt.
            self._park[RT](reactor, res[2])
            guard += 1
        raise Error("pg_tls.recv_some: spun without progress")

    def try_recv_some[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut into: List[UInt8],
        max_bytes: Int,
    ) raises -> Tuple[UInt8, Int, UInt8]:
        """Non-blocking single decrypt attempt. Returns `(status, n, blocked)`:
          * status == PG_RECV_DONE   — `n` plaintext bytes were appended to
                                       `into` (n >= 1). The caller has more to
                                       do (there may be more buffered records)
                                       but THIS call made progress.
          * status == PG_RECV_EOF    — peer sent close_notify (`n == 0`).
          * status == PG_RECV_PENDING — s2n would block (no plaintext available
                                       right now); `n == 0` and `blocked` is the
                                       TLS_OUTCOME_BLOCKED_ON_{READ,WRITE} the
                                       caller parks the fd on. NOTHING was
                                       appended to `into`.

        This is the body of `recv_some` WITHOUT the `_park` — the poll-shaped
        transport primitive the `PgQueryOp` frame drives. The op kicks off a
        read, and on PENDING parks the FRAME on the reactor (freeing the worker
        to serve another request) instead of parking the worker thread here.

        `reactor` is threaded for signature parity with `recv_some` (the
        decrypt itself does not touch the reactor — s2n's BLOCKED return is what
        signals would-block; the reactor park is the CALLER's job here).

        PARK-BUFFER SAFETY: the decrypt target is a stack-local `scratch`
        InlineArray OWNED by this frame; s2n writes into it via a Span and does
        not retain the pointer. The produced plaintext is copied into `into`
        BEFORE this method returns. No borrowed slice of `into` escapes. Because
        this method NEVER parks, `into` (the caller's `_rbuf`) is never live
        across a yield inside it — the framing-cursor discipline is
        in a tight scope, before the next try_recv_some)."""
        _ = reactor  # parity with recv_some; decrypt does not touch the reactor
        var scratch = Array[UInt8, 16384](fill=0)
        var cap = max_bytes if max_bytes < 16384 else 16384
        var res = self._conn.recv_into_span(Span[UInt8](scratch)[0:cap])
        var outcome = res[0]
        var got = res[1]
        if outcome == TLS_OUTCOME_ERROR:
            var en = last_s2n_errno()
            raise Error(
                "pg_tls.try_recv_some: TLS error (s2n_errno="
                + String(Int(en)) + " '" + s2n_strerror_message(en) + "')"
            )
        if outcome == TLS_OUTCOME_DONE:
            if got <= 0:
                return (PG_RECV_EOF, 0, UInt8(0))  # close_notify / EOF
            # Copy the decrypted plaintext OUT of the owned scratch into the
            # caller's buffer. No park happens in this method, so this copy is
            # safe even while `into` is the caller's live `_rbuf`.
            for i in range(got):
                into.append(scratch[i])
            return (PG_RECV_DONE, got, UInt8(0))
        # BLOCKED_ON_READ (common) / BLOCKED_ON_WRITE (TLS rekey, rare). Nothing
        # appended; the caller parks the fd on `outcome`'s direction.
        return (PG_RECV_PENDING, 0, outcome)

    def _park[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], outcome: UInt8
    ) raises:
        """Park the calling thread on the bound fd until it is ready for the
        direction s2n is BLOCKED on, then return so the caller re-attempts.

        Mirrors komira_http's `TlsConnector.connect` BLOCKED branch: alloc a
        reactor op-id, register the fd
        for the awaited direction, `poll_completions(-1)` (block until ready —
        for a single-task BlockingRuntime this IS the park), then deregister so
        this transient registration never collides with the TcpStream's OWN
        lazy long-lived registration.

        SAFETY/LIVENESS: the fd is owned by `self._stream` (alive for this
        method via `mut self`); we never close it here. op_id is reactor-
        allocated so it can't collide with another in-flight op."""
        var fd = self._stream.fd()
        if fd < Int32(0):
            # No real fd (should not happen post-connect) — nothing to park on.
            return
        var op_id = reactor.alloc_op_id()
        if outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
            reactor.register_write(fd, op_id, UInt16(0))
        else:
            reactor.register_read(fd, op_id, UInt16(0))
        var _drained = reactor.poll_completions(timeout_us=Int32(-1))
        reactor.deregister(op_id)

    def close(mut self):
        """Graceful close: best-effort TLS close_notify, then drop. The
        TcpStream's __del__ deregisters + closes the fd; TlsConnection's
        __del__ frees the s2n connection. Field-declaration order ensures the
        s2n conn frees before the config."""
        var _o = self._conn.shutdown()  # best-effort close_notify
        # The fd close + reactor deregister happen in self._stream.__del__ when
        # the stream drops; we do not double-close here.


# =============================================================================
# pg_reactor_connect[RT] — TCP -> SSLRequest -> 'S' -> TLS, all over the reactor.
# =============================================================================
def pg_reactor_connect[
    RT: Runtime,
](
    mut reactor: Reactor[RT.Sink],
    host: String,
    port: UInt16,
    server_name: String,
    require_tls: Bool,
    verify_cert: Bool,
) raises -> PgReactorStream:
    """Connect to host:port over the shared reactor, perform the Postgres
    SSLRequest preamble on the CLEARTEXT TcpStream, and complete the s2n TLS
    1.3 handshake on the same fd — parking on the reactor at every would-block.

    Returns a `PgReactorStream[RT]` ready for the StartupMessage.

    `set_cipher_preferences("default_tls13")` makes the client offer TLS 1.3.
    `verify_cert=False` skips X.509 verification (self-signed dev certs).
    `verify_cert=True` keeps the s2n config's default verification; a
    caller-supplied CA is not wired."""
    # ── Step 1: TCP connect over the reactor (parks on EINPROGRESS). ──
    var ip_be = _resolve_host_be(host)
    var stream = TcpStream.connect[RT.Sink](reactor, ip_be, port)

    # ── Step 2: SSLRequest preamble on the CLEARTEXT TcpStream. ──
    # The 8-byte SSLRequest then a single 'S'/'N' reply byte, parking on the
    # reactor on would-block. `_write_all` / `_read_exact` own their own bytes.
    var ssl_req = encode_ssl_request()
    _write_all[RT](stream, reactor, Span[UInt8](ssl_req))
    var reply = _read_one_byte[RT](stream, reactor)
    if reply != UInt8(ord("S")):
        if require_tls:
            raise Error(
                "pg_tls: server refused TLS (SSLRequest reply='"
                + chr(Int(reply)) + "' != 'S'); require_tls=True"
            )
        raise Error(
            "pg_tls: server refused TLS and plaintext fallback is not "
            "implemented"
        )

    # ── Step 3: s2n client-mode TLS bound to the SAME fd (TLS 1.3). ──
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))  # THE fix
    if not verify_cert:
        config.disable_verify()  # self-signed dev cert
    var conn = TlsConnection.new_client(config)
    conn.bind_fd(stream.fd())
    if len(server_name.as_bytes()) > 0:
        conn.set_server_name(server_name)

    # ── Step 4: handshake to DONE, PARKING on the reactor on BLOCKED. ──
    # The reactor park: register the fd for the awaited
    # direction, poll_completions(-1), deregister, re-attempt.
    var fd = stream.fd()
    var iters = 0
    while iters < _HANDSHAKE_ITER_CAP:
        var outcome = conn.handshake()
        if outcome == TLS_OUTCOME_DONE:
            return PgReactorStream(config^, conn^, stream^)
        if outcome == TLS_OUTCOME_ERROR:
            var en = last_s2n_errno()
            raise Error(
                "pg_tls: TLS handshake ERROR at iter " + String(iters)
                + " (s2n_errno=" + String(Int(en)) + " '"
                + s2n_strerror_message(en) + "')"
            )
        # BLOCKED_ON_READ / BLOCKED_ON_WRITE — park the calling thread on the
        # fd until ready, then re-attempt. The fd is owned by `stream` (alive
        # for this scope); we never close it here.
        if fd >= Int32(0):
            var op_id = reactor.alloc_op_id()
            if outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
                reactor.register_write(fd, op_id, UInt16(0))
            else:
                reactor.register_read(fd, op_id, UInt16(0))
            var _drained = reactor.poll_completions(timeout_us=Int32(-1))
            reactor.deregister(op_id)
        iters += 1

    var en = last_s2n_errno()
    raise Error(
        "pg_tls: TLS handshake exceeded " + String(_HANDSHAKE_ITER_CAP)
        + " iterations (s2n_errno=" + String(Int(en)) + ")"
    )


# -----------------------------------------------------------------------------
# Cleartext TcpStream helpers — used ONLY for the SSLRequest preamble (before
# TLS starts on the socket). Each owns its bytes; TcpStream.read/write park on
# the reactor on would-block (the shared primitive).
# -----------------------------------------------------------------------------
def _write_all[
    RT: Runtime,
](
    mut stream: TcpStream, mut reactor: Reactor[RT.Sink], data: Span[UInt8, _]
) raises:
    """Write all of `data` on the cleartext TcpStream, looping on short writes.
    `data` is a borrowed Span the caller keeps alive across the call."""
    var off = 0
    var n = len(data)
    var guard = 0
    while off < n and guard < 1_000_000:
        var wrote = stream.write[RT.Sink](reactor, data[off:n])
        if wrote <= Int64(0):
            raise Error("pg_tls: cleartext write returned <= 0")
        off += Int(wrote)
        guard += 1
    if off < n:
        raise Error("pg_tls: could not flush SSLRequest preamble")


def _read_one_byte[
    RT: Runtime,
](mut stream: TcpStream, mut reactor: Reactor[RT.Sink]) raises -> UInt8:
    """Read exactly one cleartext byte (the SSLRequest 'S'/'N' reply). The
    decrypt target is a stack-local InlineArray owned by this frame; no
    borrowed slice escapes the reactor park inside TcpStream.read."""
    var b = Array[UInt8, 1](fill=0)
    var got = stream.read[RT.Sink](reactor, Span[UInt8](b)[0:1])
    if got != Int64(1):
        raise Error(
            "pg_tls: reading SSLRequest reply returned " + String(got)
        )
    return b[0]
