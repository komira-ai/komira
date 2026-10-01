"""FALSIFIER — TLS buffered-plaintext lost-wakeup (an h2 request that waits
out its 120s wall deadline).

ROOT CAUSE:
s2n decrypts TLS in ~16KB RECORD units (`s2n_recv`) while the h2/h1 drivers
read in fixed 4096-byte chunks. ONE `recv_into_span` drains a whole TLS
record off the kernel socket into s2n's USERSPACE buffer and hands back only
4096 bytes, leaving the remainder buffered INSIDE s2n. When s2n then returns
`BLOCKED_ON_READ`, the driver parks on SOCKET fd read-readiness — but the
kernel socket has NO more bytes (s2n already pulled them all), so the fd
never becomes readable, the bounded park rides its deadline, and the 120s
h2 wall-deadline eventually fires: `HttpError[TIMEOUT]: ... no progress to
END_STREAM`. The data the driver needs is sitting in s2n's buffer, not on
the socket.

THE FIX: `IoStream.has_buffered_readable()` (default-False; overridden by
`TlsClientStream` to `s2n_peek(conn) > 0`). The park sites consult it BEFORE
parking on a read-Pending and SKIP the park (re-read immediately) when s2n
holds buffered plaintext.

FALSIFIER SHAPE (real s2n loopback over a socketpair; no network):
  1. Full client<->server TLS handshake to DONE.
  2. Server `send()`s a >4KB plaintext payload in ONE write -> one big TLS
     record on the wire.
  3. Client reads ONE 4096-byte chunk via `recv_into_span`. This drains the
     WHOLE record off the socket into s2n's buffer; the kernel socket now has
     ZERO readable bytes, but s2n holds (payload - 4096) decrypted bytes.

  PROOF (the load-bearing INVARIANT, NOT an exact byte count):
   * There is an instant where `conn.bytes_buffered() > 0` AND
     `conn.has_buffered_readable() == True` — s2n IS holding decrypted
     plaintext above the fd.
   * At that same instant a non-blocking kernel `recv(MSG_PEEK)` on the
     client fd returns EWOULDBLOCK — the socket fd is momentarily DEAD (no
     bytes). A park on its read-readiness would NEVER wake. **This is the
     bug condition.**
   * Re-reading via `recv_into_span` returns the buffered plaintext WITHOUT
     any new socket activity — the bytes were already decrypted in s2n; the
     whole payload is eventually recovered byte-intact with NO futile-park
     wedge.

  WHY NOT AN EXACT COUNT (segmentation portability): macOS loopback
  delivers a whole TLS record in one socket read, so one 4096-byte recv
  drains the WHOLE record into s2n and leaves exactly `sent_len - 4096`
  buffered. LINUX loopback SEGMENTS the record across TCP segments with
  inter-segment gaps, so "one recv drains the whole record" is NOT
  portably reproducible — a too-eager settle reads only the arrived
  portion. So we assert the INVARIANT (buffered plaintext above a
  momentarily-dead fd, recovered byte-intact without a wedge), reached via
  a bounded loop, rather than any exact `sent_len - 4096` remainder.

THREE TESTS:
   * bug1 — the INVARIANT proof: reach an instant where s2n holds buffered
     plaintext (`bytes_buffered() > 0`, `has_buffered_readable() == True`)
     above a momentarily-dead fd (MSG_PEEK -> EWOULDBLOCK), then GUARDED-
     drain the whole record (re-read while buffered; park on the fd only
     when s2n empties + bytes are owed) and verify the full payload is
     received byte-intact with the futile parks counted + capped (no wedge).
     No exact buffered count anywhere.
   * bug2 — the POST-FIX park-guard MODEL: a 4096-chunk drain that consults
     `has_buffered_readable()` before parking reads the whole record without
     ever wedging on a dead fd.
   * bug3 — the BEHAVIORAL wedge: the REAL reactor (kqueue/epoll — the same
     `park_on_fds` primitive the production park sites drive) is parked on
     the dead client fd, exactly as the PRE-FIX park sites did
     unconditionally. The park RIDES ITS FULL 200ms deadline (returns 0
     ready fds) while s2n holds the decrypted plaintext. In production, that
     futile park re-fires every loop iter until the 120s h2 wall-deadline
     trips. The guard (asserted True here) is what makes the production park
     sites skip this futile wait. Segmentation-robust: the wedge instant is
     reached via a bounded loop (a late segment landing during a park just
     triggers a drain + retry), and the whole payload is recovered intact.

FALSIFIES: the pre-fix tree (no `s2n_peek` binding, no
`has_buffered_readable`, unconditional park). On the pre-fix tree this file
does not even COMPILE (the trait method + the override + the binding do not
exist), and bug3 reproduces the futile-park wedge that fires the 120s
wall-deadline. On the post-fix tree it compiles and PASSES.

Test-only; never used in production. The leaf cert/key fixtures are the
shared TLS artifacts.
"""

from std.ffi import external_call
from std.sys.info import CompilationTarget


from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_http.tls import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)
from std.pathlib import Path


# -----------------------------------------------------------------------------
# Fixtures + libc helpers (mirror test_L1_tls_session_resumption.mojo)
# -----------------------------------------------------------------------------

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1
# We rely on the client fd being O_NONBLOCK (set below) so a plain recv()
# with flags=MSG_PEEK returns EWOULDBLOCK (-1) when the socket is empty,
# and otherwise peeks (does not consume) a byte. MSG_PEEK is 2 on both
# Linux and macOS.
comptime _MSG_PEEK: Int32 = 2


def _leaf_cert() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_key.pem").read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    var sv_ptr = UnsafePointer(to=sv).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[Int32]()
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv_ptr,
    )
    if rc != Int32(0):
        raise Error("socketpair() returned " + String(Int(rc)))
    return (sv[0], sv[1])


def _close_fd(fd: Int32):
    if fd < 0:
        return
    var _rc = external_call["close", Int32](fd)


def _set_nonblock(fd: Int32) raises:
    var rc = external_call["komira_fcntl_set_nonblock", Int32](fd)
    if rc < Int32(0):
        raise Error("_set_nonblock returned " + String(Int(rc)))


def _socket_has_readable_bytes(fd: Int32) -> Bool:
    """Non-blocking MSG_PEEK on the RAW kernel socket fd: does the socket
    itself have any unread bytes ABOVE s2n? Returns True iff recv() peeked
    >= 1 byte. The fd is O_NONBLOCK, so an empty socket returns -1
    (EWOULDBLOCK) and this returns False — i.e. a park on this fd's
    read-readiness would NOT wake.

    This is the "dead fd" detector that proves the lost-wakeup condition:
    after s2n drains a whole record off the socket, the socket is empty
    even though decrypted plaintext is still buffered inside s2n.
    """
    var probe = Array[UInt8, 1](fill=UInt8(0))
    var probe_ptr = UnsafePointer(to=probe).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[UInt8]()
    # recv(fd, buf, 1, MSG_PEEK) — peek does not consume. fd is O_NONBLOCK
    # so an empty socket returns -1/EWOULDBLOCK instead of blocking.
    var n = external_call["recv", Int64](
        fd, probe_ptr, Int64(1), _MSG_PEEK,
    )
    return n >= Int64(1)


def _sleep_ms(ms: Int):
    """Sleep `ms` milliseconds via libc `usleep`. Used only by the
    segmentation-settle loop to give in-flight TCP segments a real wall
    window to land between raw-socket peeks (loopback segments arrive in
    microseconds, so a couple of ms is comfortably sufficient + keeps the
    test fast).

    We deliberately use `usleep` (NOT `nanosleep` / stdlib `time.sleep`):
    this test imports the komira_async reactor, which declares its OWN
    `external_call["nanosleep", ...]`; a second `nanosleep` decl in this
    TU triggers a 'conflicting nanosleep signature' legalization failure
    `usleep` is a DISTINCT symbol, so it sidesteps the conflict.
    """
    if ms <= 0:
        return
    var _rc = external_call["usleep", Int32](UInt32(ms * 1000))


def _socket_peekable_bytes(fd: Int32) -> Int:
    """Count how many WIRE bytes are currently sitting on the RAW kernel
    socket fd, WITHOUT consuming them (recv with MSG_PEEK into a large
    scratch buffer). Returns 0 on an empty (EWOULDBLOCK) socket.

    Used by `_wait_for_full_record_on_socket` to observe TCP-segment
    arrival directly. macOS loopback delivers a whole TLS record in one
    socket read; LINUX loopback SEGMENTS the record across TCP segments,
    so the count grows over a few hundred microseconds as segments land.
    Peeking (not consuming) lets us wait for the count to stop growing
    WITHOUT pulling any bytes into s2n — preserving the "one 4096-byte
    recv drains the whole record into s2n" precondition on both platforms.

    The scratch buffer is sized to comfortably exceed any single TLS
    record's wire size for the test's payloads (a ~12000-byte plaintext
    record is < 16KB plaintext + a few dozen bytes of TLS framing). We
    only ever PEEK, so the buffer is never partially consumed.
    """
    var scratch = Array[UInt8, 32768](fill=UInt8(0))
    var scratch_ptr = UnsafePointer(to=scratch).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[UInt8]()
    var n = external_call["recv", Int64](
        fd, scratch_ptr, Int64(32768), _MSG_PEEK,
    )
    if n <= Int64(0):
        return 0
    return Int(n)


def _wait_for_full_record_on_socket(fd: Int32) raises -> Int:
    """Block until the WHOLE TLS record the server just sent has fully
    arrived on the client's kernel socket and the socket has QUIESCED
    (no new wire bytes across a real settle window). Returns the peeked
    wire-byte count once settled (> 0).

    WHY THIS EXISTS (segmentation robustness): the falsifier's core
    precondition is "ONE 4096-byte recv drains the WHOLE record off the
    socket into s2n's buffer, leaving the kernel socket DEAD while s2n
    holds the remainder". On macOS loopback the whole record lands in one
    socket read, so that precondition holds the instant the server sends.
    On LINUX loopback the record is SEGMENTED across TCP segments that
    arrive over time; if the client reads its 4096-byte chunk while
    segments are still in flight, s2n only decrypts the arrived portion
    and the socket is NOT yet dead (more segments inbound). That made the
    exact-remainder + dead-fd assertions racy on Linux.

    The fix: BEFORE the first 4096-byte read, peek the raw socket
    (consuming nothing — see `_socket_peekable_bytes`) and wait until the
    peeked count stops growing across a REAL wall window (a fixed
    `nanosleep` between polls — NOT a reactor park, which returns
    instantly once any byte is present and therefore would not actually
    wait for in-flight segments). Once settled, the entire record's wire
    bytes are present, so the subsequent single `recv_into_span(4096)`
    pulls + decrypts the whole record into s2n in one readv exactly as it
    does on macOS — and the dead-fd / exact-remainder assertions hold on
    both platforms WITHOUT consuming any plaintext or weakening what the
    test verifies about the fix.

    Determinism: the settle window is a real `nanosleep` (not a busy
    spin / not a park), so an in-flight loopback segment (microseconds
    away) is guaranteed to have landed before we declare quiescence. We
    require the peeked count to be > 0 and unchanged across TWO
    consecutive post-sleep polls. Bounded at 200 polls (~2s wall) so a
    genuinely stuck socket fails loud instead of hanging the suite.
    """
    var last_count = -1
    var stable_polls = 0
    var iters = 0
    while iters < 200:
        iters = iters + 1
        var count = _socket_peekable_bytes(fd)
        if count > 0 and count == last_count:
            # No growth since the previous post-sleep poll. Require TWO
            # consecutive stable observations (each separated by a real
            # sleep) so we don't latch onto a transient gap between two
            # segments — by the second stable poll any segment that was
            # in flight at the first has had a full settle window to land.
            stable_polls = stable_polls + 1
            if stable_polls >= 2:
                return count
        else:
            stable_polls = 0
        last_count = count
        # Real wall window so in-flight loopback segments land between
        # polls. 2ms is >> the loopback segment inter-arrival (µs) yet
        # keeps the whole settle to a few ms in the common case.
        _sleep_ms(2)
    raise Error(
        "_wait_for_full_record_on_socket: socket never quiesced with a"
        " full record after 200 polls (last peeked count="
        + String(last_count) + "). Expected the whole TLS record to"
        " arrive + settle on loopback."
    )


def _outcome_str(o: UInt8) -> StaticString:
    """The name of a `TLS_OUTCOME_*` ordinal, for this test's diagnostic lines.

    ⚠ `-> StaticString`, NOT `-> String` — the standard shape.
    As `-> String` this five-arm literal-return ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references an
    `--emit shared-lib` link binds INDEPENDENTLY. `StaticString` keeps the
    literals literal: ZERO register-indexed constant-table loads.
    This helper is copied across the TLS tests; the template is fixed here so
    the next copy is born safe.
    """
    if o == TLS_OUTCOME_DONE:
        return "DONE"
    if o == TLS_OUTCOME_BLOCKED_ON_READ:
        return "BLOCKED_ON_READ"
    if o == TLS_OUTCOME_BLOCKED_ON_WRITE:
        return "BLOCKED_ON_WRITE"
    if o == TLS_OUTCOME_ERROR:
        return "ERROR"
    return "UNKNOWN"


def _make_reactor() raises -> Reactor[NoopSink]:
    """Build the real reactor (epoll on Linux, kqueue on macOS) — the same
    primitive the production h2/h1 park sites drive. Mirrors
    test_L2_h2_client_driver.mojo:_make_reactor."""
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _drive_to_done(
    mut server: TlsConnection, mut client: TlsConnection
) raises -> Tuple[UInt8, UInt8]:
    """Alternating-call handshake driver — calls server.handshake() and
    client.handshake() in turn until both report DONE, or until 64 iters
    elapse (failure)."""
    var sv_out: UInt8 = UInt8(255)
    var cl_out: UInt8 = UInt8(255)
    var sv_done = False
    var cl_done = False
    var i = 0
    # 256 alternations — the handshake needs both sides to make several
    # write/read round-trips; a non-blocking socketpair occasionally needs
    # extra spins when a record straddles a write-readiness boundary.
    while i < 256:
        if not sv_done:
            sv_out = server.handshake()
            if sv_out == TLS_OUTCOME_ERROR:
                return (sv_out, cl_out)
            if sv_out == TLS_OUTCOME_DONE:
                sv_done = True
        if not cl_done:
            cl_out = client.handshake()
            if cl_out == TLS_OUTCOME_ERROR:
                return (sv_out, cl_out)
            if cl_out == TLS_OUTCOME_DONE:
                cl_done = True
        if sv_done and cl_done:
            return (TLS_OUTCOME_DONE, TLS_OUTCOME_DONE)
        i = i + 1
    raise Error(
        "_drive_to_done: exceeded 256 iterations "
        + "(server=" + _outcome_str(sv_out)
        + ", client=" + _outcome_str(cl_out) + ")"
    )


def _build_server_config() raises -> TlsConfig:
    """Minimal server config — NO session tickets (avoids post-handshake
    NewSessionTicket records that would muddy the buffered-plaintext
    assertions)."""
    var config = TlsConfig()
    config.load_cert(_leaf_cert(), _leaf_key())
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def _build_client_config() raises -> TlsConfig:
    """Minimal client config — wipe trust + disable verify (in-process
    socketpair shortcut), NO session tickets, ALPN http/1.1."""
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def _server_send_one_shot(
    mut server: TlsConnection, payload: List[UInt8]
) raises -> Int:
    """Send `payload` via the TLS server in ONE non-blocking send. Returns
    the number of plaintext bytes s2n accepted into the socket (one TLS
    record). The caller picks a payload comfortably larger than 4096 but
    small enough that one socketpair write accepts > 4096 of it; the
    returned count is the AUTHORITATIVE landed-bytes value the caller uses
    for its expected-remainder math (robust to whatever the socketpair
    buffer size happens to be).

    Raises if the send accepts <= 4096 bytes — then there is no buffered
    remainder after the client's first 4096-byte read and the scenario
    can't be exercised (the caller should shrink the payload so it fits
    one write, or the buffer is pathologically small)."""
    var view = Span[UInt8](payload).as_imm()
    var res = server.send(view)
    var outcome = res[0]
    var n = res[1]
    if outcome == TLS_OUTCOME_ERROR:
        raise Error(
            "_server_send_one_shot: send ERROR errno="
            + String(Int(last_s2n_errno()))
        )
    if n <= 4096:
        raise Error(
            "_server_send_one_shot: send accepted only " + String(n)
            + " plaintext bytes in one shot (need > 4096 so the client's"
            + " first 4096-byte recv leaves a buffered remainder). The"
            + " socketpair send buffer is too small for this payload;"
            + " shrink the payload."
        )
    return n


# -----------------------------------------------------------------------------
# §1 — Core proof: s2n buffers the >4KB-record remainder above a dead socket
# -----------------------------------------------------------------------------


def test_bug1_s2n_buffers_record_remainder_above_dead_fd() raises:
    """FAILS ON CURRENT CODE (pre-fix tree): does not compile — neither
    `TlsConnection.bytes_buffered()` / `.has_buffered_readable()` nor the
    `s2n_peek` binding exist on the pre-fix tree. Models the production
    wedge: after one 4096-byte read drains a >4KB TLS record off the
    socket, s2n holds the remainder while the kernel socket fd is DEAD —
    a park on fd-readiness would never wake. before the fix.

    POST-FIX: passes. `has_buffered_readable()` reports the buffered
    remainder so the driver re-reads instead of parking on the dead fd.

    PORTABLE INVARIANT (NOT an exact-count check). The fix's contract is:
    *whenever s2n holds ANY decrypted plaintext above the fd,
    `has_buffered_readable()` is True so the driver re-reads instead of
    futilely parking on a fd that will never wake.* The EXACT buffered
    count is irrelevant — and is NOT portably reproducible: macOS loopback
    delivers a whole TLS record in one socket read, but LINUX loopback
    SEGMENTS the record across TCP segments with inter-segment gaps, so
    "one recv drains the WHOLE record" (the old exact `sent_len - 4096`
    remainder assertion) is unreachable there. This test instead asserts
    the INVARIANT the fix actually relies on, in three parts:

      (1) After the first 4096-byte read, find the production wedge
          PRECONDITION: an instant where s2n holds buffered plaintext
          (`bytes_buffered() > 0`, `has_buffered_readable() == True`) AND
          the kernel fd is momentarily NOT readable (recv(MSG_PEEK) ->
          EWOULDBLOCK). That instant IS the lost-wakeup: a park on the fd
          here would never wake, yet the data is sitting in s2n. We reach
          it with a bounded loop (robust to Linux segmentation) rather
          than asserting any exact count.
      (2) Drain the whole record in a GUARDED loop: while
          `has_buffered_readable()`, re-read WITHOUT parking; only when
          s2n empties and bytes are still owed do we park on the fd for
          the next TCP segment. Futile parks (park rode its deadline with
          0 ready) are COUNTED + capped — proving the guard prevents the
          unbounded futile-park wedge.
      (3) The full plaintext that was sent is eventually received INTACT
          (byte-correct), with NO wedge. No exact buffered count anywhere.
    """
    print("  test_bug1_s2n_buffers_record_remainder_above_dead_fd...")
    tls_init()
    var server_config = _build_server_config()
    var client_config = _build_client_config()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    try:
        var server_conn = TlsConnection(server_config)
        server_conn.bind_fd(server_fd)
        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        var outcomes = _drive_to_done(server_conn, client_conn)
        if outcomes[0] != TLS_OUTCOME_DONE or outcomes[1] != TLS_OUTCOME_DONE:
            var sv_msg = String("")
            if outcomes[0] == TLS_OUTCOME_ERROR:
                sv_msg = s2n_strerror_message(last_s2n_errno())
            raise Error(
                "handshake did not reach DONE: server="
                + _outcome_str(outcomes[0]) + " client="
                + _outcome_str(outcomes[1])
                + " (sv_errno_msg='" + sv_msg + "')"
            )

        # Real reactor (epoll/kqueue) — the same `park_on_fds` primitive
        # the production h2/h1 park sites drive. Used for the legitimate
        # "s2n empty, park on the fd for the next segment" path during the
        # guarded drain below (load-bearing on Linux, where the record is
        # segmented).
        var reactor = _make_reactor()

        # Server sends a payload in one logical send -> one TLS record
        # (>> the client's 4096-byte read chunk). The full payload is
        # built (positionally-encoded bytes for byte-exact verification);
        # only the bytes ONE socketpair write accepts actually land, and
        # `sent_len` is that authoritative count (robust to the socketpair
        # buffer size). It MUST exceed 4096 so the first 4096-byte recv
        # leaves a buffered remainder inside s2n.
        var payload_len = 12000
        var payload = List[UInt8]()
        var p = 0
        while p < payload_len:
            payload.append(UInt8((p * 31 + 7) & 0xFF))
            p = p + 1
        var sent_len = _server_send_one_shot(server_conn, payload)

        # Give the record a moment to arrive on the client socket (best
        # effort — NOT load-bearing for correctness; the bounded
        # precondition loop + the guarded drain below are robust to
        # however the record is segmented across the wire).
        var _wire = _wait_for_full_record_on_socket(client_fd)

        # ---- Accumulator for ALL received plaintext. ----
        var got = List[UInt8]()
        var chunk_cap = 4096

        # First 4096-byte read. This drains (part or all of) the arrived
        # record off the socket into s2n's buffer and hands back up to
        # 4096 bytes.
        var chunk0 = List[UInt8]()
        var z = 0
        while z < chunk_cap:
            chunk0.append(UInt8(0))
            z = z + 1
        var r0 = client_conn.recv_into_span(Span[UInt8](chunk0))
        var out0 = r0[0]
        var n0 = r0[1]
        if out0 == TLS_OUTCOME_ERROR:
            raise Error(
                "first recv ERROR errno=" + String(Int(last_s2n_errno()))
            )
        if n0 <= 0:
            raise Error(
                "first recv returned " + String(n0)
                + " bytes, expected > 0 (the record had arrived)"
            )
        var k0 = 0
        while k0 < n0:
            got.append(chunk0[k0])
            k0 = k0 + 1

        # ---- LOAD-BEARING INVARIANT: reach the wedge PRECONDITION. ----
        # The production wedge precondition is: s2n holds decrypted
        # plaintext above the fd (so a re-read WILL produce bytes without
        # touching the socket) WHILE the kernel fd is momentarily NOT
        # readable (a park on it would never wake). We do NOT assert any
        # exact buffered count — only that THIS shape occurs at least once.
        #
        # The 12000-byte send fragments DIFFERENTLY per platform: macOS
        # delivers it as ONE ~8KB record (the first 4096-byte read above
        # already buffers the ~4KB remainder above a dead fd — the
        # precondition holds on iteration 1). Linux fragments it into
        # MULTIPLE records (e.g. ~8KB + ~4KB observed): after reading
        # record 1, record 2's wire bytes are still on the socket (fd
        # readable), so the precondition is NOT yet met — we drain record
        # 1's buffered plaintext, then a read of record 2 (the LAST record)
        # pulls its whole plaintext into s2n's buffer and empties the
        # socket, yielding "buffered remainder above a dead fd". The bounded
        # loop drains arrived bytes (into `got`) until it observes the
        # precondition; a genuinely stuck socket fails loud at the cap.
        #
        # `probe_chunk` is the small per-read size for this drain (NOT
        # 4096): s2n decrypts a WHOLE TLS record per recv, so a 4096 read of
        # the LAST record (~4KB plaintext) would return the whole record and
        # buffer NOTHING, and the wedge instant would never appear. A small
        # read makes s2n buffer the rest of the last record while the socket
        # is empty. Must be < any single record's plaintext.
        var probe_chunk = 256
        var hit_wedge_precondition = False
        var precond_iters = 0
        var precond_parks = 0
        while precond_iters < 100000:
            precond_iters = precond_iters + 1
            var buffered_now = client_conn.bytes_buffered()
            var fd_readable = _socket_has_readable_bytes(client_fd)
            if buffered_now > 0 and not fd_readable:
                # THE WEDGE PRECONDITION: s2n holds plaintext above a dead
                # fd. The guard MUST report it (else the driver parks on a
                # fd that will never wake).
                if not client_conn.has_buffered_readable():
                    raise Error(
                        "has_buffered_readable() == False while s2n holds "
                        + String(buffered_now) + " decrypted bytes above a"
                        + " momentarily-dead fd — the guard would wrongly"
                        + " let the driver park on the dead fd (the wedge)"
                    )
                hit_wedge_precondition = True
                break
            # Not yet the wedge shape. If the socket has bytes, read them
            # (advance toward the record boundary that leaves a buffered
            # remainder). If the socket is momentarily empty AND s2n is
            # empty AND we still owe bytes, park for the next segment (the
            # CORRECT park — the fd IS the source here). If everything is
            # drained, stop (the whole record fit in one read with no
            # remainder — degenerate, but not a failure of the invariant).
            #
            # SEGMENTATION/MULTI-RECORD ROBUSTNESS: read in a SMALL chunk
            # (`probe_chunk`), NOT 4096. s2n decrypts a WHOLE TLS record per
            # recv but on Linux a 12000-byte send fragments into MULTIPLE
            # records (e.g. ~8KB + ~4KB observed). A 4096 read of the LAST
            # record returns the whole record and buffers nothing, so the
            # "buffered remainder above a dead fd" instant never appears. A
            # small read of the last record makes s2n decrypt the whole
            # record into its buffer and hand back only `probe_chunk`,
            # leaving the rest buffered WHILE the socket is now empty — the
            # exact production wedge. (The production 4096 driver hits this
            # whenever a record's plaintext exceeds 4096, which the
            # large-record h2 case does; reading small here just makes the
            # falsifier reach it portably regardless of how s2n chunked the
            # records.)
            if fd_readable:
                var buf = List[UInt8]()
                var zz = 0
                while zz < probe_chunk:
                    buf.append(UInt8(0))
                    zz = zz + 1
                var rr = client_conn.recv_into_span(Span[UInt8](buf))
                if rr[0] == TLS_OUTCOME_ERROR:
                    raise Error(
                        "precond drain recv ERROR errno="
                        + String(Int(last_s2n_errno()))
                    )
                var kk = 0
                while kk < rr[1]:
                    got.append(buf[kk])
                    kk = kk + 1
                continue
            # fd not readable AND s2n not buffered (buffered_now == 0).
            if len(got) >= sent_len:
                # Whole record already drained without ever leaving a
                # buffered-remainder-above-dead-fd instant (e.g. a tiny
                # record that fit one read). Not the scenario this test
                # targets; verified-intact check below still applies.
                break
            # Still owe bytes; park for the next segment (legitimate). Bound
            # the park budget so a genuinely stuck socket fails loud in
            # seconds, not hours (the server already sent every byte, so a
            # segment WILL land — this park resolves in ms in practice).
            precond_parks = precond_parks + 1
            if precond_parks > 100:
                raise Error(
                    "precond loop parked > 100 times waiting for in-flight"
                    + " segments while owing "
                    + String(sent_len - len(got)) + " bytes — the sent"
                    + " record never fully arrived on the socket"
                )
            var park_fds = List[Int32]()
            park_fds.append(client_fd)
            var _ready = reactor.park_on_fds(
                park_fds, Int32(200_000), want_write=False,
            )
        if not hit_wedge_precondition:
            raise Error(
                "never observed the wedge precondition (s2n buffered"
                + " plaintext above a momentarily-dead fd) after "
                + String(precond_iters) + " iterations — the >4KB record"
                + " never left a buffered remainder above the fd. Shrink"
                + " the payload or check the socketpair buffer size."
            )

        # ---- GUARDED DRAIN of the remainder, counting futile parks. ----
        # While `has_buffered_readable()`, re-read WITHOUT parking; when
        # s2n empties but bytes are still owed, park on the fd for the next
        # segment. `_drain_guarded` returns (rest, wedged); `wedged` is
        # True only if the data NEVER arrives (futile parks exceed the
        # cap) — the unbounded-futile-park wedge the fix prevents. We
        # assert it never wedges.
        var owed = sent_len - len(got)
        var rest_wedged = _drain_guarded(
            reactor, client_conn, client_fd, owed, chunk_cap
        )
        var rest = rest_wedged[0].copy()
        var wedged = rest_wedged[1]
        if wedged:
            raise Error(
                "guarded drain WEDGED (futile parks exceeded the cap while"
                + " bytes remained) — has_buffered_readable() failed to"
                + " fire on the buffered remainder, so the driver parked on"
                + " a dead fd: the exact pre-fix lost-wakeup"
            )
        var ri = 0
        while ri < len(rest):
            got.append(rest[ri])
            ri = ri + 1

        # ---- The data was reachable all along: full payload INTACT. ----
        if len(got) != sent_len:
            raise Error(
                "received " + String(len(got)) + " plaintext bytes,"
                + " expected the " + String(sent_len) + " sent (the whole"
                + " record must be recoverable without a wedge)"
            )
        var v = 0
        while v < sent_len:
            if got[v] != payload[v]:
                raise Error(
                    "received byte " + String(v) + " mismatch: got "
                    + String(Int(got[v])) + ", expected "
                    + String(Int(payload[v]))
                )
            v = v + 1
        # After the full drain, s2n's buffer is empty again.
        if client_conn.has_buffered_readable():
            raise Error(
                "has_buffered_readable() still True after draining the"
                + " whole payload — should be empty"
            )

        _ = reactor^
        _ = server_conn^
        _ = client_conn^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    _ = server_config^
    _ = client_config^
    print(
        "    OK — reached the wedge precondition (s2n buffered plaintext"
        " above a momentarily-dead fd); has_buffered_readable() reported"
        " it; the guarded drain recovered the whole payload byte-intact"
        " without a futile-park wedge"
    )


# -----------------------------------------------------------------------------
# §2 — Driver model: guarded chunk-drain COMPLETES; unguarded would WEDGE
# -----------------------------------------------------------------------------


def _drain_guarded(
    mut reactor: Reactor[NoopSink],
    mut client: TlsConnection,
    client_fd: Int32,
    total: Int,
    chunk_cap: Int,
) raises -> Tuple[List[UInt8], Bool]:
    """POST-FIX park-guard model: read in `chunk_cap` chunks. On a read
    that returns BLOCKED_ON_READ, consult `has_buffered_readable()` BEFORE
    deciding to park: if True, re-read (continue) instead of parking; if
    the socket fd is also dead (no bytes) AND s2n has nothing buffered,
    THEN a genuine park on the socket fd is warranted (the socket is the
    real source — more TCP segments inbound).

    Returns (bytes, wedged). `wedged == True` ONLY if the data NEVER
    arrives — i.e. we exhaust a generous park budget while bytes remain
    unread, neither in s2n NOR ever appearing on the socket. That is the
    impossible state given the server sent everything; it would only
    happen if the guard mis-reported and we'd have parked forever on a
    dead fd.

    SEGMENTATION ROBUSTNESS: the load-bearing distinction the guard must
    make is "s2n holds buffered plaintext -> re-read (the fd would never
    wake)" vs "s2n is empty + the socket is the real source -> park on the
    fd". On Linux loopback the record is SEGMENTED, so mid-drain a recv
    can legitimately return BLOCKED with s2n empty AND the socket
    momentarily empty (the next segment is microseconds in flight). That
    is NOT a wedge — it is exactly the case where a park on the fd is the
    CORRECT action: the park wakes when the next segment lands. The PRE-FIX
    bug was parking on the fd when s2n DID hold the bytes (the fd never
    wakes); this model still proves the guard prevents THAT by re-reading
    whenever `has_buffered_readable()` is True. A genuine park here (s2n
    empty) is legitimate and resolves as soon as the segment arrives."""
    var out = List[UInt8]()
    var iters = 0
    var futile_parks = 0
    while len(out) < total:
        iters = iters + 1
        if iters > 1_000_000:
            raise Error("_drain_guarded: iteration cap")
        var cap = chunk_cap
        var remaining = total - len(out)
        if cap > remaining:
            cap = remaining
        var buf = List[UInt8]()
        var z = 0
        while z < cap:
            buf.append(UInt8(0))
            z = z + 1
        var r = client.recv_into_span(Span[UInt8](buf))
        var outcome = r[0]
        var n = r[1]
        if outcome == TLS_OUTCOME_ERROR:
            raise Error(
                "_drain_guarded: recv ERROR errno="
                + String(Int(last_s2n_errno()))
            )
        if n > 0:
            var k = 0
            while k < n:
                out.append(buf[k])
                k = k + 1
            futile_parks = 0
            continue
        # n == 0 with BLOCKED_ON_READ -> the park decision point.
        # THE GUARD (post-fix): if s2n has buffered plaintext, re-read
        # WITHOUT parking. This is the load-bearing assertion of the fix:
        # the fd would never wake (s2n already pulled the bytes), so a
        # park here is the wedge the pre-fix code hit. Re-reading drains
        # the buffered remainder.
        if client.has_buffered_readable():
            futile_parks = 0
            continue
        # s2n is empty. The socket fd is the real source now. If it has
        # bytes, loop to read them. If it is momentarily empty (a TCP
        # segment is in flight on Linux), PARK on read-readiness — this is
        # the CORRECT park (s2n holds nothing, so the fd genuinely is the
        # source and WILL wake when the next segment lands). Only if the
        # park rides its full deadline repeatedly (data never arrives) do
        # we declare a wedge.
        if _socket_has_readable_bytes(client_fd):
            futile_parks = 0
            continue
        var park_fds = List[Int32]()
        park_fds.append(client_fd)
        var ready = reactor.park_on_fds(
            park_fds, Int32(200_000), want_write=False,
        )
        if ready == 0:
            # Park rode its deadline: no segment arrived. Tolerate a few
            # of these (loopback can be momentarily quiet), but if the
            # data genuinely never comes, declare the wedge.
            futile_parks = futile_parks + 1
            if futile_parks >= 25:
                return (out^, True)
        else:
            futile_parks = 0
    return (out^, False)


def test_bug2_guarded_chunk_drain_completes_without_wedging() raises:
    """FAILS ON CURRENT CODE (pre-fix tree): does not compile (the guard
    method does not exist) and models the wedge the pre-fix driver hit.
    The pre-fix `_park_on_fd_readiness` / `_park_on_stream_fd` parked
    UNCONDITIONALLY on the socket fd when recv returned BLOCKED_ON_READ —
    but after a 4096-byte read drained the whole >4KB record into s2n, the
    socket fd was dead, so the park rode the wall-deadline -> TIMEOUT.
    before the fix.

    POST-FIX: the guarded drain reads ALL 8192 payload bytes in 4096-byte
    chunks, consulting `has_buffered_readable()` before any park, and
    completes with `wedged == False`."""
    print("  test_bug2_guarded_chunk_drain_completes_without_wedging...")
    tls_init()
    var server_config = _build_server_config()
    var client_config = _build_client_config()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    try:
        var server_conn = TlsConnection(server_config)
        server_conn.bind_fd(server_fd)
        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        var outcomes = _drive_to_done(server_conn, client_conn)
        if outcomes[0] != TLS_OUTCOME_DONE or outcomes[1] != TLS_OUTCOME_DONE:
            raise Error(
                "handshake did not reach DONE: server="
                + _outcome_str(outcomes[0]) + " client="
                + _outcome_str(outcomes[1])
            )

        # Real reactor for the legitimate "s2n empty, park on the fd for
        # the next TCP segment" path inside _drain_guarded (load-bearing
        # on Linux where the record is segmented).
        var reactor = _make_reactor()

        var payload_len = 12000
        var payload = List[UInt8]()
        var p = 0
        while p < payload_len:
            payload.append(UInt8((p * 17 + 3) & 0xFF))
            p = p + 1
        # Only the bytes ONE socketpair write accepts land; `sent_len` is
        # the authoritative count the guarded drain must read back (> 4096
        # so the 4096-chunk drain hits the buffered-remainder park point).
        var sent_len = _server_send_one_shot(server_conn, payload)

        var drained = _drain_guarded(
            reactor, client_conn, client_fd, sent_len, 4096
        )
        var got = drained[0].copy()
        var wedged = drained[1]
        if wedged:
            raise Error(
                "guarded drain reached the WEDGE state (socket dead + s2n"
                + " empty while bytes remained) — the has_buffered_readable"
                + " guard failed to fire on the buffered remainder"
            )
        if len(got) != sent_len:
            raise Error(
                "guarded drain read " + String(len(got)) + " bytes,"
                + " expected " + String(sent_len)
            )
        var v = 0
        while v < sent_len:
            if got[v] != payload[v]:
                raise Error(
                    "drained byte " + String(v) + " mismatch"
                )
            v = v + 1

        _ = reactor^
        _ = server_conn^
        _ = client_conn^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    _ = server_config^
    _ = client_config^
    print(
        "    OK — guarded chunk-drain read the whole record byte-exact,"
        " never wedged on a dead fd"
    )


# -----------------------------------------------------------------------------
# §3 — Behavioral wedge: a REAL reactor park on the dead fd TIMES OUT while
#       decrypted plaintext sits buffered. This is the exact pre-fix hang.
# -----------------------------------------------------------------------------


def test_bug3_park_on_dead_fd_times_out_proving_wedge() raises:
    """FAILS ON CURRENT CODE (pre-fix tree): does not compile (the buffered
    -readable API does not exist) and DEMONSTRATES the exact production
    wedge behaviorally. After a 4096-byte read drains a TLS record into
    s2n, this parks the REAL reactor (kqueue/epoll — the same
    `park_on_fds` primitive the production h2/h1 park sites drive) on the
    client socket fd, exactly as the PRE-FIX `_park_on_fd_readiness` /
    `_park_on_stream_fd` did UNCONDITIONALLY. The park RIDES ITS FULL
    DEADLINE (returns 0 ready fds) even though `bytes_buffered() > 0` —
    proving the park is futile: the socket fd will never wake because s2n
    already pulled the bytes. In production, that 250ms-bounded park
    re-fires every loop iter until the 120s h2 wall-deadline trips ->
    `HttpError[TIMEOUT]`. before the fix.

    POST-FIX: the guard (`has_buffered_readable()`) short-circuits the park
    here, so the wedge never materializes — this test asserts BOTH that the
    raw park times out (the wedge condition is real) AND that the guard
    correctly reports the buffered bytes that make the park futile.

    PORTABLE (segmentation-robust): the wedge precondition is "s2n holds
    buffered plaintext WHILE the socket fd is momentarily dead". On macOS
    one 4096-byte read drains the whole record, so the precondition holds
    at once. On Linux the record is TCP-segmented, so we reach the
    precondition with a bounded loop (drain arrived chunks until s2n holds
    a record remainder above a momentarily-dead fd), asserting NO exact
    count. We then park the real reactor on the dead fd: if it rides its
    deadline (0 ready) the wedge is demonstrated; if a late segment lands
    DURING the park (Linux) the park returns ready -> drain it and retry.
    Once the whole record is drained into s2n the socket is permanently
    dead, so the demonstration terminates reliably on both platforms.
    """
    print("  test_bug3_park_on_dead_fd_times_out_proving_wedge...")
    tls_init()
    var server_config = _build_server_config()
    var client_config = _build_client_config()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    try:
        var server_conn = TlsConnection(server_config)
        server_conn.bind_fd(server_fd)
        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        var outcomes = _drive_to_done(server_conn, client_conn)
        if outcomes[0] != TLS_OUTCOME_DONE or outcomes[1] != TLS_OUTCOME_DONE:
            raise Error(
                "handshake did not reach DONE: server="
                + _outcome_str(outcomes[0]) + " client="
                + _outcome_str(outcomes[1])
            )

        # Build the real reactor AFTER the handshake (it is needed only for
        # the post-handshake park demonstration; constructing it earlier is
        # unnecessary).
        var reactor = _make_reactor()

        var payload_len = 12000
        var payload = List[UInt8]()
        var p = 0
        while p < payload_len:
            payload.append(UInt8((p * 13 + 5) & 0xFF))
            p = p + 1
        var sent_len = _server_send_one_shot(server_conn, payload)

        # Best-effort settle (NOT load-bearing — the bounded
        # precondition+park loop below is robust to segmentation).
        var _wire = _wait_for_full_record_on_socket(client_fd)

        var chunk_cap = 4096
        var got = List[UInt8]()

        # First 4096-byte read — drains (part or all of) the arrived
        # record into s2n's buffer.
        var chunk0 = List[UInt8]()
        var z = 0
        while z < chunk_cap:
            chunk0.append(UInt8(0))
            z = z + 1
        var r0 = client_conn.recv_into_span(Span[UInt8](chunk0))
        if r0[1] <= 0:
            raise Error(
                "first recv returned " + String(r0[1])
                + " bytes, expected > 0 (the record had arrived)"
            )
        var k0 = 0
        while k0 < r0[1]:
            got.append(chunk0[k0])
            k0 = k0 + 1

        # ---- THE WEDGE, demonstrated on the REAL reactor primitive. ----
        # Find a moment where s2n holds buffered plaintext above a
        # momentarily-dead fd, then park the real reactor on that fd. A
        # park that rides its deadline (0 ready) while s2n holds plaintext
        # IS the pre-fix wedge. On Linux a late segment may land during the
        # park (park returns ready) — that is not a failure of the
        # demonstration; drain it and retry. The whole record being sent
        # guarantees a terminal instant where s2n holds a record remainder
        # and the socket is permanently dead, where the park is guaranteed
        # to ride its deadline.
        # Small read size for the precondition drain (multi-record
        # robustness — see the leg-1 comment): a 4096 read of the LAST TLS
        # record would return the whole record and buffer nothing, so the
        # "buffered above a dead fd" wedge instant would never appear on
        # Linux (where a 12000-byte send fragments into multiple records).
        var probe_chunk = 256
        var demonstrated_wedge = False
        var loop_iters = 0
        var legit_parks = 0
        while loop_iters < 100000:
            loop_iters = loop_iters + 1
            var buffered_now = client_conn.bytes_buffered()
            var fd_readable = _socket_has_readable_bytes(client_fd)
            if buffered_now > 0 and not fd_readable:
                # Wedge precondition. The guard MUST report the buffered
                # plaintext (else the production park site would park here).
                if not client_conn.has_buffered_readable():
                    raise Error(
                        "has_buffered_readable() == False while s2n holds "
                        + String(buffered_now) + " decrypted bytes above a"
                        + " momentarily-dead fd"
                    )
                # Park the REAL reactor on the dead fd, exactly as the
                # PRE-FIX park sites did unconditionally.
                var park_fds = List[Int32]()
                park_fds.append(client_fd)
                var ready = reactor.park_on_fds(
                    park_fds, Int32(200_000), want_write=False,
                )
                if ready == 0:
                    # The park rode its full 200ms deadline while
                    # `buffered_now` bytes sat decrypted in s2n. THAT is the
                    # wedge: the socket fd never woke because s2n already
                    # pulled the bytes. The fix's guard
                    # (has_buffered_readable, True here) makes the
                    # production park sites skip this futile wait and
                    # re-read instead.
                    demonstrated_wedge = True
                    break
                # A late TCP segment landed during the park (Linux): the fd
                # became readable, so this was not yet the terminal dead-fd
                # instant. Fall through to drain arrived bytes + retry.
            if fd_readable:
                var buf = List[UInt8]()
                var zz = 0
                while zz < probe_chunk:
                    buf.append(UInt8(0))
                    zz = zz + 1
                var rr = client_conn.recv_into_span(Span[UInt8](buf))
                if rr[0] == TLS_OUTCOME_ERROR:
                    raise Error(
                        "drain recv ERROR errno="
                        + String(Int(last_s2n_errno()))
                    )
                var kk = 0
                while kk < rr[1]:
                    got.append(buf[kk])
                    kk = kk + 1
                continue
            if buffered_now > 0:
                # s2n buffered but the park above returned ready without
                # the fd actually delivering (rare); re-read from s2n.
                var buf2 = List[UInt8]()
                var zz2 = 0
                while zz2 < probe_chunk:
                    buf2.append(UInt8(0))
                    zz2 = zz2 + 1
                var rr2 = client_conn.recv_into_span(Span[UInt8](buf2))
                var kk2 = 0
                while kk2 < rr2[1]:
                    got.append(buf2[kk2])
                    kk2 = kk2 + 1
                continue
            # s2n empty + fd empty. If we still owe bytes, park for the
            # next segment (legitimate). Otherwise everything is drained.
            if len(got) >= sent_len:
                break
            legit_parks = legit_parks + 1
            if legit_parks > 100:
                raise Error(
                    "leg-3 loop parked > 100 times (s2n empty + fd empty)"
                    + " while owing " + String(sent_len - len(got))
                    + " bytes — the sent record never fully arrived"
                )
            var park_fds2 = List[Int32]()
            park_fds2.append(client_fd)
            var _r = reactor.park_on_fds(
                park_fds2, Int32(200_000), want_write=False,
            )
        if not demonstrated_wedge:
            raise Error(
                "never demonstrated the futile-park wedge (no instant where"
                + " a real-reactor park on a dead fd rode its deadline while"
                + " s2n held buffered plaintext) after " + String(loop_iters)
                + " iterations"
            )

        # Proof the data was reachable all along: drain the rest from s2n /
        # the socket and verify the full payload is INTACT.
        var owed = sent_len - len(got)
        var rest_wedged = _drain_guarded(
            reactor, client_conn, client_fd, owed, chunk_cap
        )
        if rest_wedged[1]:
            raise Error(
                "post-demonstration guarded drain WEDGED — the buffered"
                + " plaintext was not recoverable, which contradicts the"
                + " guard reporting it"
            )
        var rest = rest_wedged[0].copy()
        var ri = 0
        while ri < len(rest):
            got.append(rest[ri])
            ri = ri + 1
        if len(got) != sent_len:
            raise Error(
                "recovered " + String(len(got)) + " plaintext bytes,"
                + " expected the " + String(sent_len) + " sent"
            )
        var v = 0
        while v < sent_len:
            if got[v] != payload[v]:
                raise Error("recovered byte " + String(v) + " mismatch")
            v = v + 1

        _ = reactor^
        _ = server_conn^
        _ = client_conn^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    _ = server_config^
    _ = client_config^
    print(
        "    OK — REAL reactor park on the dead fd rode its 200ms deadline"
        " (0 ready) while s2n held the plaintext: the pre-fix wedge"
        " reproduced; the guard reports the buffered bytes that avert it,"
        " and the whole payload was recoverable byte-intact"
    )


def main() raises:
    """Drive the TLS buffered-plaintext lost-wakeup falsifiers."""
    print("== TLS buffered-plaintext lost-wakeup falsifier ==")
    test_bug1_s2n_buffers_record_remainder_above_dead_fd()
    test_bug2_guarded_chunk_drain_completes_without_wedging()
    test_bug3_park_on_dead_fd_times_out_proving_wedge()
    print("== TLS buffered-plaintext lost-wakeup PASSED (3 tests) ==")
