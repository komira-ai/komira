# =============================================================================
# THE recv PATH SILENTLY DISCARDS DECRYPTED PLAINTEXT — the send-side bug that
# was fixed and never mirrored.
# =============================================================================
#
# `TlsConnection.send` special-cases a POSITIVE return BEFORE it consults
# `*blocked` (s2n_shim.mojo, the landed partial-send fix): "s2n CONSUMED rc
# bytes AND the socket is now full" is surfaced as DONE-with-n, because the
# caller MUST advance by exactly rc. `recv_into_span` does NOT do this, and the
# asymmetry is DATA LOSS, not a stylistic difference.
#
# THE MECHANISM, from the s2n-tls v1.5.6 source, not from
# a plausible story about one. `tls/s2n_recv.c:s2n_recv_impl` sets
#
#     *blocked = S2N_BLOCKED_ON_READ;            /* line ~176, unconditional */
#
# on entry and resets it EXACTLY ONCE, at the very end:
#
#     if (s2n_stuffer_data_available(&conn->in) == 0) {
#         *blocked = S2N_NOT_BLOCKED;
#     }
#     return bytes_read;
#
# So `*blocked` does not mean "the socket would block". It means "s2n's own
# `conn->in` still holds decrypted plaintext you did not have room for". Every
# read whose destination buffer is SMALLER than the record it lands on returns
#
#     rc = bytes_read > 0   WITH   *blocked = S2N_BLOCKED_ON_READ
#
# and those bytes are ALREADY GONE from `conn->in` — `s2n_stuffer_erase_and_read`
# copied them into the caller's buffer and erased them. There is no re-read.
#
# `_blocked_status_to_outcome` maps that pair to TLS_OUTCOME_BLOCKED_ON_READ,
# and then a consumer that trusts the outcome throws the count away:
#
#   * tls_connector.mojo `_map_tls_outcome_to_stream_io` -> `StreamIo.pending(token)`
#     — `n` is not a field of a Pending. THE h1/h2 CLIENT PATH.
#   * state_machine.mojo `_drive_read_head` / `_drive_read_body` -> `return False`
#   * any TLS receive loop that appends only on DONE -> appends NOTHING
#
# ⚠ 4096 IS THE h1 CLIENT'S READ SCRATCH SIZE (`client.mojo:397`
# `_read_head_scratch: InlineArray[UInt8, 4096]`; `state_machine.mojo:1318`
# `scratch_size: Int = 4096`), and s2n's default outgoing fragment is 8087
# bytes (`S2N_DEFAULT_RECORD_LENGTH 8092` − 5-byte header,
# tls/s2n_tls_parameters.h:220). 4096 < 8087, so this is not an exotic edge —
# it is the ORDINARY read. Per 8087-byte record the first 4096-byte read is
# answered BLOCKED_ON_READ-with-4096 and dropped; the second gets the 3991-byte
# remainder with `conn->in` empty and is answered DONE. Just over HALF of every
# large TLS response is discarded.
#
# WHAT THE TWO TESTS HERE SPLIT:
#
#   §1 THE LOSS. Real TLS 1.3 session, real cert, real handshake, 64 KiB pushed
#      through it, drained via the REAL production `TlsClientStream.try_read`
#      seam with the REAL 4096-byte h1 scratch — and every byte is checked
#      against the sender's, by value and by count. This is the test that reds.
#
#   §2 THE MECHANISM, pinned so a future s2n bump reds HERE and not in production:
#      `recv_into_span` must never answer with a non-DONE outcome while
#      reporting n > 0. §2 accumulates `n` unconditionally, so it measures the
#      OUTCOME LABEL alone and is unaffected by whether callers compensate.
#
# ⛔ WHAT THIS FILE DELIBERATELY DOES NOT ASSERT: liveness. "The read returned
# something" and "no exception was raised" are both TRUE on the broken code —
# the defect is SILENT partial loss, so a liveness test would have passed
# throughout. Both tests below assert BYTE-EXACT CONTENT or an exact zero
# count.
#
# NON-VACUITY, because a green run of a test that never reached the shape would
# be worse than no test (the sibling rekey harness measured ZERO rekeys on its
# first draft and would have shipped green). Both tests REQUIRE, and fail
# without:
#   * at least one read that filled the scratch completely AND left plaintext
#     buffered inside s2n afterwards — that IS the (rc>0, blocked=READ) shape,
#     and it is observable identically before and after the fix (the fix
#     changes the LABEL, not the buffering);
#   * a payload strictly larger than the scratch, and more than one read.
#
# Pointer discipline: UnsafePointer use is confined to the
# socketpair / setsockopt FFI thunks (concrete or MutExternalOrigin AT the FFI
# boundary, never crossing a non-FFI module) — the same carve-out as the
# harness this clones (test_L2_h2_over_tls_real_rekey.mojo).
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.testing import assert_true, assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.tcp_stream import TcpStream

from komira_http.client.tls_connector import TlsClientStream
from komira_http.transport.io_stream import (
    STREAM_IO_EOF,
    STREAM_IO_ERROR,
    STREAM_IO_PENDING,
    STREAM_IO_READY,
)
from komira_http.transport.kernel_tcp import TcpIoStream

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


comptime _RT = PerCoreAsyncRuntime[NoopSink]

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1

# THE h1 CLIENT'S READ SCRATCH, not a number chosen to provoke anything.
# `client.mojo:397` holds `InlineArray[UInt8, 4096]` for the response head and
# `state_machine.mojo:1318` allocates 4096 for the body. s2n's default outgoing
# fragment is 8087 plaintext bytes, so this is smaller than a record and the
# (rc>0, blocked=READ) shape is what an ordinary https GET produces.
comptime _SCRATCH: Int = 4096

# 64 KiB. Large enough to span many records (>= 8 at the 8087-byte default
# fragment) so the loss is unambiguous rather than a boundary coincidence.
comptime _PAYLOAD_LEN: Int = 65536

# Bytes offered to `send` per call. Not load-bearing — the pump advances by
# exactly what s2n reports consuming.
comptime _SEND_CHUNK: Int = 8192

# Consecutive no-progress iterations before the drain concludes the peer has
# nothing left. An AF_UNIX socketpair delivers synchronously inside the kernel,
# so once `send` returns the bytes ARE in the receiver's buffer and idleness is
# immediate and truthful — this is a safety bound, not a timing wait.
comptime _IDLE_CAP: Int = 64

comptime _SPIN_CAP: Int = 2_000_000


# -----------------------------------------------------------------------------
# Fixtures + libc helpers (same shape as test_L2_h2_over_tls_real_rekey.mojo).
# -----------------------------------------------------------------------------


def _leaf_cert() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_key.pem").read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    """# SAFETY: stack-local 2-element array handed to socketpair for the
    duration of the synchronous call; the pointer does not escape this frame.
    """
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


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


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


def _payload_byte(k: Int) -> UInt8:
    """Positional encoding — a dropped RUN of bytes shifts every byte after it,
    so a truncation AND a mis-splice both fail the byte-exact check below."""
    return UInt8((k * 37 + 13) & 0xFF)


def _build_payload() -> List[UInt8]:
    var payload = List[UInt8]()
    payload.reserve(_PAYLOAD_LEN)
    var p = 0
    while p < _PAYLOAD_LEN:
        payload.append(_payload_byte(p))
        p = p + 1
    return payload^


def _build_client_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
    config.set_cipher_preferences(String("default_tls13"))
    return config^


def _build_server_config_from_pem(cert: String, key: String) raises -> TlsConfig:
    var config = TlsConfig()
    config.load_cert(cert, key)
    config.set_cipher_preferences(String("default_tls13"))
    return config^


def _handshake_both(mut server: TlsConnection, mut client: TlsConnection) raises:
    """Same-thread interleaved handshake to DONE on both peers."""
    var sv_done = False
    var cl_done = False
    var i = 0
    while i < 512 and not (sv_done and cl_done):
        i = i + 1
        if not sv_done:
            var so = server.handshake()
            if so == TLS_OUTCOME_ERROR:
                raise Error(
                    "server handshake ERROR: "
                    + s2n_strerror_message(last_s2n_errno())
                )
            if so == TLS_OUTCOME_DONE:
                sv_done = True
        if not cl_done:
            var co = client.handshake()
            if co == TLS_OUTCOME_ERROR:
                raise Error(
                    "client handshake ERROR: "
                    + s2n_strerror_message(last_s2n_errno())
                )
            if co == TLS_OUTCOME_DONE:
                cl_done = True
    if not (sv_done and cl_done):
        raise Error("handshake did not reach DONE on both peers")


# =============================================================================
# §1 — THE LOSS, through the REAL production read seam.
# =============================================================================


def test_h1_scratch_read_over_tls_loses_no_plaintext() raises:
    """64 KiB through a REAL TLS 1.3 session, drained through the REAL
    production `TlsClientStream.try_read` seam with the REAL 4096-byte h1
    scratch, asserted BYTE-EXACT.

    WHY THE PRODUCTION SEAM AND NOT THE SHIM. The shim hands back `(outcome, n)`
    and the bytes are already in the caller's buffer; the DISCARD happens one
    layer up, in `tls_connector.mojo:_map_tls_outcome_to_stream_io`, which turns
    any non-DONE outcome into `StreamIo.pending(token)` — a variant with no
    byte-count field. So the loss is only visible from a consumer that speaks
    StreamIo, which is exactly what `_drive_read_head` / `_drive_read_body` are.
    The loop below is those drivers' shape: READY -> append n bytes; PENDING ->
    re-read if `has_buffered_readable()`, else conclude the peer is idle.

    ⛔ THIS ASSERTS CONTENT, NEVER LIVENESS. On the broken code the loop
    terminates cleanly, raises nothing, and returns a healthy-looking ~32 KiB.
    The failure is that the bytes are the WRONG bytes and there are too few of
    them, which is why the assertion is a full byte-by-byte comparison and a
    count, and why a "did it return something" test would have passed for as
    long as this defect has existed.

    FAILS ON CURRENT CODE: `s2n_recv` answers a 4096-byte read of an 8087-byte
    record with `rc=4096, *blocked=S2N_BLOCKED_ON_READ` (tls/s2n_recv.c — the
    reset to NOT_BLOCKED is gated on `conn->in` being fully drained), the shim
    labels that BLOCKED_ON_READ, the connector maps it to a Pending, and the
    4096 bytes s2n already erased out of `conn->in` are gone. Expect roughly
    half the payload delivered, and the first mismatch at the first record
    boundary."""
    print("  test_h1_scratch_read_over_tls_loses_no_plaintext...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    tls_init()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)

    var got = List[UInt8]()
    var sent = 0
    var reads_ready = 0
    var reads_pending = 0
    # NON-VACUITY COUNTER — and note WHAT IT IS NOT KEYED ON. The first draft of
    # this test counted reads that came back READY with n == _SCRATCH, and it
    # could never fire on the broken code, because the broken code labels
    # exactly those reads PENDING. A non-vacuity signal read off the branch the
    # bug suppresses measures the fix, not the shape. This one is keyed on
    # `has_buffered_readable()` AFTER the read: s2n holds a decrypted remainder
    # in `conn->in` iff the record was larger than what we asked for, which IS
    # the (rc>0, blocked=READ) shape — and it is TRUE identically before and
    # after the fix, because the fix changes the outcome LABEL, not s2n's
    # buffering.
    var reads_leaving_remainder = 0
    var pendings_with_remainder = 0

    try:
        var server_config = _build_server_config_from_pem(
            _leaf_cert(), _leaf_key()
        )
        var client_config = _build_client_config()

        var server = TlsConnection(server_config)
        server.bind_fd(server_fd)
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(client_fd)
        client.set_server_name(String("localhost"))
        _handshake_both(server, client)

        # The client half moves into the REAL production stream type. From here
        # every read goes through `TlsClientStream.try_read` ->
        # `recv_into_span` -> `_map_tls_outcome_to_stream_io`, which is the h1
        # and h2 client read path verbatim.
        var client_tcp = TcpIoStream(TcpStream(client_fd))
        var client_stream = TlsClientStream[TcpIoStream](
            client_tcp^, client^,
        )
        var reactor = _make_reactor()

        var payload = _build_payload()
        var scratch = Array[UInt8, _SCRATCH](fill=UInt8(0))

        var idle = 0
        var spins = 0
        while spins < _SPIN_CAP:
            spins = spins + 1
            var progress = False

            # ---- PUSH: advance by exactly what s2n reports consuming. ----
            if sent < _PAYLOAD_LEN:
                var end = sent + _SEND_CHUNK
                if end > _PAYLOAD_LEN:
                    end = _PAYLOAD_LEN
                var sres = server.send(
                    Span[UInt8](payload)[sent:end].as_imm()
                )
                if sres[0] == TLS_OUTCOME_ERROR:
                    raise Error(
                        "server send ERROR: "
                        + s2n_strerror_message(last_s2n_errno())
                    )
                if sres[1] > 0:
                    sent = sent + sres[1]
                    progress = True
            else:
                # Everything is CONSUMED by s2n, but a partial flush can leave
                # records in `conn->out`. A zero-length send IS a flush
                # (`s2n_sendv_with_offset_impl` runs `s2n_flush` before it looks
                # at the payload).
                var fres = server.send(
                    Span[UInt8](payload)[0:0].as_imm()
                )
                if fres[0] == TLS_OUTCOME_ERROR:
                    raise Error(
                        "server flush ERROR: "
                        + s2n_strerror_message(last_s2n_errno())
                    )

            # ---- DRAIN: the production driver's own loop shape. ----
            var res = client_stream.try_read[_RT](
                reactor, Span[UInt8](scratch)
            )
            if res._state == STREAM_IO_ERROR:
                raise Error(
                    "client try_read ERROR errno=" + String(Int(res._payload))
                )
            if res._state == STREAM_IO_EOF:
                break
            # LABEL-INDEPENDENT shape probe, taken before branching on the
            # outcome: a decrypted remainder still inside s2n means this read
            # landed on a record bigger than the scratch.
            var left_remainder = client_stream.has_buffered_readable()
            if left_remainder:
                reads_leaving_remainder = reads_leaving_remainder + 1

            if res._state == STREAM_IO_READY:
                reads_ready = reads_ready + 1
                var n = Int(res._payload)
                var k = 0
                while k < n:
                    got.append(scratch[k])
                    k = k + 1
                if n > 0:
                    progress = True
            elif res._state == STREAM_IO_PENDING:
                reads_pending = reads_pending + 1
                if left_remainder:
                    pendings_with_remainder = pendings_with_remainder + 1
                # The lost-wakeup guard: s2n may hold decrypted plaintext above
                # a socket that has nothing left, so re-read rather than park.
                if left_remainder:
                    progress = True

            if progress:
                idle = 0
            else:
                idle = idle + 1
                if idle >= _IDLE_CAP and sent >= _PAYLOAD_LEN:
                    break

        _ = reactor^
        _ = client_stream^
        _ = server^
        _ = server_config^
        _ = client_config^
        _ = payload^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)

    # ---- NON-VACUITY: the harness reached the shape it is about. ----
    assert_equal(
        sent, _PAYLOAD_LEN,
        "the SENDER never accepted the whole payload (consumed " + String(sent)
        + " of " + String(_PAYLOAD_LEN) + "), so nothing below is a statement"
        " about the reader",
    )
    assert_true(
        reads_ready > 1,
        "only " + String(reads_ready) + " READY read(s) — the payload did not"
        " span multiple reads, so a 4096-byte scratch was never smaller than"
        " what was available and the shape under test never occurred",
    )
    assert_true(
        reads_leaving_remainder > 0,
        "NEVER observed a read that left decrypted plaintext buffered inside"
        " s2n. That is the (rc>0, blocked=READ) shape this test exists for;"
        " without it a green result below means the record size happened to"
        " divide the " + String(_SCRATCH) + "-byte scratch, NOT that the recv"
        " path is correct.",
    )

    # ---- THE MEASUREMENT: every byte, by value. ----
    assert_equal(
        len(got), _PAYLOAD_LEN,
        "TLS RECV DISCARDED DECRYPTED PLAINTEXT: the peer sent "
        + String(_PAYLOAD_LEN) + " bytes and the production read seam"
        " delivered " + String(len(got)) + " (" + String(reads_ready)
        + " READY / " + String(reads_pending) + " PENDING reads, of which "
        + String(pendings_with_remainder) + " were PENDING while s2n still held"
        " a decrypted remainder). `s2n_recv` answers a read smaller than the"
        " record with rc>0 AND *blocked=BLOCKED_ON_READ, and those bytes are"
        " already erased out of conn->in —"
        " `_map_tls_outcome_to_stream_io` turns that into a Pending, which has"
        " no byte count. Mirror `send`'s rc>0 special case in"
        " `recv_into_span`.",
    )
    var v = 0
    while v < _PAYLOAD_LEN:
        if got[v] != _payload_byte(v):
            raise Error(
                "TLS RECV SPLICED THE STREAM: byte " + String(v)
                + " is " + String(Int(got[v])) + ", expected "
                + String(Int(_payload_byte(v)))
                + ". The count matched but the CONTENT did not, so a run of"
                " decrypted bytes was dropped and the stream re-joined past the"
                " hole."
            )
        v = v + 1

    print(
        "    [OK] " + String(_PAYLOAD_LEN) + " bytes byte-exact through the"
        " production TlsClientStream.try_read seam at a " + String(_SCRATCH)
        + "-byte scratch (" + String(reads_ready) + " READY / "
        + String(reads_pending) + " PENDING reads; "
        + String(reads_leaving_remainder)
        + " read(s) left a decrypted remainder inside s2n)"
    )


# =============================================================================
# §2 — THE MECHANISM, pinned at the shim.
# =============================================================================


def test_recv_into_span_never_reports_a_positive_partial_as_blocked() raises:
    """`recv_into_span` MUST NOT answer with a non-DONE outcome while reporting
    n > 0. A positive n means s2n already erased those bytes out of `conn->in`
    and copied them into the caller's buffer; there is no way to ask for them
    again. Labelling that a block invites every caller to discard them, and in
    this repo SIX callers do.

    This is the exact contract `send` already keeps (s2n_shim.mojo: "surface a
    positive `rc` as DONE-with-n, and reserve BLOCKED-with-0 for the case where
    s2n accepted NOTHING"), stated for the mirror direction.

    WHY THIS TEST EXISTS SEPARATELY FROM §1. §1 measures the LOSS through one
    consumer. This measures the OUTCOME LABEL itself, and it accumulates `n`
    unconditionally, so it stays true regardless of whether any given caller
    happens to compensate. It is the assertion an s2n bump should red — the
    `*blocked` semantics here are s2n's, and they are not documented as stable.

    FAILS ON CURRENT CODE: every 4096-byte read that lands on an 8087-byte
    record returns (BLOCKED_ON_READ, 4096)."""
    print("  test_recv_into_span_never_reports_a_positive_partial_as_blocked...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    tls_init()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)

    var sent = 0
    var delivered = 0
    var positive_partial_blocked = 0
    var worst_offender = String("")
    # Same label-independent shape probe as §1 — see the comment there for why
    # a counter keyed on the DONE branch would be blind on the broken code.
    var reads_leaving_remainder = 0

    try:
        var server_config = _build_server_config_from_pem(
            _leaf_cert(), _leaf_key()
        )
        var client_config = _build_client_config()

        var server = TlsConnection(server_config)
        server.bind_fd(server_fd)
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(client_fd)
        client.set_server_name(String("localhost"))
        _handshake_both(server, client)

        var payload = _build_payload()
        var scratch = Array[UInt8, _SCRATCH](fill=UInt8(0))

        var idle = 0
        var spins = 0
        while spins < _SPIN_CAP:
            spins = spins + 1
            var progress = False

            if sent < _PAYLOAD_LEN:
                var end = sent + _SEND_CHUNK
                if end > _PAYLOAD_LEN:
                    end = _PAYLOAD_LEN
                var sres = server.send(
                    Span[UInt8](payload)[sent:end].as_imm()
                )
                if sres[0] == TLS_OUTCOME_ERROR:
                    raise Error(
                        "server send ERROR: "
                        + s2n_strerror_message(last_s2n_errno())
                    )
                if sres[1] > 0:
                    sent = sent + sres[1]
                    progress = True
            else:
                var fres = server.send(
                    Span[UInt8](payload)[0:0].as_imm()
                )
                if fres[0] == TLS_OUTCOME_ERROR:
                    raise Error(
                        "server flush ERROR: "
                        + s2n_strerror_message(last_s2n_errno())
                    )

            var rres = client.recv_into_span(Span[UInt8](scratch))
            var outcome = rres[0]
            var n = rres[1]
            if outcome == TLS_OUTCOME_ERROR:
                raise Error(
                    "client recv ERROR: "
                    + s2n_strerror_message(last_s2n_errno())
                )
            var left_remainder = client.has_buffered_readable()
            if left_remainder:
                reads_leaving_remainder = reads_leaving_remainder + 1
            if n > 0:
                # Accumulate REGARDLESS of the label — this test is about the
                # label, not about whether a caller compensates for it.
                delivered = delivered + n
                progress = True
                if outcome != TLS_OUTCOME_DONE:
                    positive_partial_blocked = positive_partial_blocked + 1
                    if worst_offender.byte_length() == 0:
                        worst_offender = (
                            String("first at delivered=") + String(delivered - n)
                            + ", n=" + String(n) + ", outcome="
                            + _outcome_str(outcome)
                        )
            elif outcome != TLS_OUTCOME_DONE and left_remainder:
                progress = True

            if progress:
                idle = 0
            else:
                idle = idle + 1
                if idle >= _IDLE_CAP and sent >= _PAYLOAD_LEN:
                    break

        _ = server^
        _ = client^
        _ = server_config^
        _ = client_config^
        _ = payload^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)

    # ---- NON-VACUITY. ----
    assert_equal(
        sent, _PAYLOAD_LEN,
        "the SENDER never accepted the whole payload (consumed " + String(sent)
        + " of " + String(_PAYLOAD_LEN) + ")",
    )
    assert_equal(
        delivered, _PAYLOAD_LEN,
        "accumulating n unconditionally must recover every byte; got "
        + String(delivered) + " of " + String(_PAYLOAD_LEN)
        + " — if THIS is short the harness is broken, not the label",
    )
    assert_true(
        reads_leaving_remainder > 0,
        "NEVER observed a read that left decrypted plaintext buffered inside"
        " s2n at a " + String(_SCRATCH) + "-byte scratch — the shape under test"
        " never occurred, so the assertion below is vacuous",
    )

    # ---- THE MEASUREMENT. ----
    assert_equal(
        positive_partial_blocked, 0,
        "recv_into_span answered a POSITIVE PARTIAL as a block "
        + String(positive_partial_blocked) + " time(s) (" + worst_offender
        + "). Those bytes are already erased out of s2n's conn->in and cannot"
        " be re-read, and a caller that trusts the outcome drops them"
        " (tls_connector `_map_tls_outcome_to_stream_io` -> Pending, a TLS"
        " receive loop that appends only on DONE -> appends nothing)."
        " `send` already reserves BLOCKED for"
        " accepted-NOTHING; recv must do the same.",
    )

    print(
        "    [OK] " + String(delivered) + " bytes across "
        + String(reads_leaving_remainder)
        + " read(s) that left a decrypted remainder inside s2n:"
        " recv_into_span never labelled a positive partial as a block"
    )


def main() raises:
    print("=== TLS recv: positive-partial plaintext must not be discarded ===")
    test_h1_scratch_read_over_tls_loses_no_plaintext()
    test_recv_into_span_never_reports_a_positive_partial_as_blocked()
    print("=== recv partial-plaintext verification complete ===")
