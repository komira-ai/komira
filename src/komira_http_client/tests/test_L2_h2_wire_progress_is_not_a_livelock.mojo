# =============================================================================
# THE LIVELOCK DETECTOR MEASURED PROGRESS AT THE WRONG LAYER.
# =============================================================================
#
# `drive_h2_streams_to_completion` raises
#
#     HttpError[LIVELOCK]: h2 driver made no progress across 4096 consecutive
#     READY parks
#
# when `ready_no_progress` reaches `_H2_READY_NO_PROGRESS_CAP`. Before the
# fix pinned here, that counter was incremented on any trip where the retried I/O
# returned `Pending` — an **APPLICATION-layer** fact — and on a TLS stream that
# fact is routinely true while REAL BYTES CROSS THE WIRE.
#
# -----------------------------------------------------------------------------
# THE MECHANISM, read out of the s2n-tls v1.5.6 source
# -----------------------------------------------------------------------------
#
#   tls/s2n_send.c:146    `s2n_sendv_with_offset_impl` OPENS with
#
#                             /* Flush any pending I/O */
#                             POSIX_GUARD(s2n_flush(conn, blocked));
#
#                         `POSIX_GUARD` is `if (x < 0) return -1;` — an EARLY
#                         RETURN. It bypasses the ONLY path that reports a
#                         positive partial, the
#                         `s2n_errno == S2N_ERR_IO_BLOCKED && user_data_sent > 0`
#                         arm 80 lines further down (:223-230).
#
#   tls/s2n_send.c:83-102 `s2n_flush` drains `conn->out` with
#                             int w = s2n_connection_send_stuffer(...);
#                             POSIX_GUARD_RESULT(s2n_io_check_write_result(w));
#                             conn->wire_bytes_out += w;
#                         — so a PARTIAL write advances the connection and the
#                         counter, and then the loop's next iteration blocks
#                         and the whole call returns -1.
#
# ⇒ ONCE `conn->out` HOLDS AN UNDRAINED RECORD, EVERY SUBSEQUENT `s2n_send`
#   ANSWERS `(-1, S2N_BLOCKED_ON_WRITE)` WITH **ZERO PLAINTEXT ACCEPTED**,
#   however many bytes its leading flush just pushed onto the socket.
#
# The read half has the same shape for a different reason: `s2n_recv` cannot
# return plaintext until a whole record has arrived, so every TCP segment of a
# 16 KiB record that is not the last one makes the fd readable, adds to
# `conn->wire_bytes_in` (tls/s2n_recv.c:67-71) and returns
# `-1 / BLOCKED_ON_READ`.
#
# In BOTH shapes the fd genuinely becomes ready on every trip — so
# `idle_parks == 0`, the exact fingerprint the give-up message presents as
# proof of a spin — and the connection is healthy and transferring throughout.
# `HttpError[LIVELOCK]` is in the GCS client's retryable-connection set in `komira_gcp_bridge`,
# so the pre-fix outcome is: abandon a working transfer, redial, and meet the
# same congestion again.
#
# -----------------------------------------------------------------------------
# THE FIX, AND WHY IT IS NOT A WIDENED BUDGET
# -----------------------------------------------------------------------------
#
# ⛔ `_H2_READY_NO_PROGRESS_CAP` IS UNCHANGED AT 4096 AND NO DEADLINE MOVED.
# The PREDICATE changed: a trip counts toward the cap only if
# `IoStream.wire_bytes_moved()` also failed to move. That value is s2n's own
# `wire_bytes_in + wire_bytes_out`, and both counters are incremented strictly
# AFTER the I/O check that a failed syscall bails at — so a departed peer
# (EPIPE/ECONNRESET) and a closed peer (read 0) BOTH freeze it. The two spins
# that ARE real trip the cap at exactly the same count as before; §2 below is
# the assertion that says so, and the two landed fixtures
# (`test_L2_h2_over_tls_send_to_departed_peer_no_spin`,
# `test_L2_h2_over_tls_abrupt_close_no_spin`) are the other two.
#
# -----------------------------------------------------------------------------
# WHAT THIS FILE ASSERTS
# -----------------------------------------------------------------------------
#
#   §0  THE s2n CONTRACT, pinned by calling `s2n_send` DIRECTLY over the raw
#       connection: a blocked send reports ZERO accepted while
#       `s2n_connection_get_wire_bytes_out` STRICTLY INCREASES across the SAME
#       call. Immune to anything in our shim or driver; reds on an s2n bump.
#       Non-vacuity: the handshake must have reached DONE first.
#
#   §1  THE PRODUCTION DRIVE, through `HttpClient.send_buffered` -> the real
#       `drive_h2_streams_to_completion`, against a peer that answers
#       `Pending` on 6000 consecutive writes (1.46x the cap) while moving wire
#       bytes on every one of them. It must COMPLETE. Pre-fix it raises
#       `HttpError[LIVELOCK]` on trip 4096.
#
#   §2  ⭐ THE ANTI-VACUITY CONTROL, and the reason §1 is not a licence to
#       delete the detector: the SAME 6000 pendings with the wire counter
#       FROZEN must STILL raise `HttpError[LIVELOCK]`. A "fix" that merely
#       disabled the detector reds here.
#
#   §3  ATTRIBUTION. A message that prints `iters`, `elapsed_ms`, `parks`,
#       `idle_parks` and nothing else cannot be assigned to the read half or
#       the write half. The give-up must name `side=`,
#       `total_read=` and `wire_resets=`.
#
# Pointer discipline: §1-§3 use no pointers at all. §0's
# UnsafePointer use is confined to the socketpair / pthread / s2n out-param FFI
# thunks, the same carve-out as the two fixtures whose harness it clones.
#
# Mojo 1.0.0b2 (def-only).
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import alloc, unsafe_memcpy
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_2,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)

from komira_http_core.tls import (
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)
from komira_http_core.tls.ffi import (
    S2N_BLOCKED_ON_WRITE,
    _S2N_FFI_ORIGIN,
)
from std.pathlib import Path


# =============================================================================
# §1-§3 fixtures — a peer that is PENDING at the application layer and MOVING
# at the wire layer. No sockets, no TLS, no syscalls: `fd() == -1` makes
# `park_on_pending` return True without parking, which is precisely the
# "READY park" the detector counts, and it makes the whole file sub-second.
# =============================================================================

# 6000 > `_H2_READY_NO_PROGRESS_CAP` (4096) by 1.46x. The margin is the point:
# a peer whose drain is merely SLOW must not be able to reach a verdict that
# says the driver SPUN, no matter how slow.
comptime _WRITE_PENDINGS: Int = 6000

# Bytes the peer moves on the wire per pending write. Any non-zero value works
# — the driver only ever asks whether two samples DIFFER — but a realistic one
# reads better in a failure message. 64 is about what a congested socket frees
# per wakeup once the receiver's window has collapsed.
comptime _WIRE_STEP: Int = 64

comptime _BODY_BYTES: Int = 4096


struct SlowDrainPeer(IoStream, Movable, Deinitable):
    """A peer that accepts writes only after `_pendings_left` refusals, and
    that moves `_wire_step` bytes ACROSS THE WIRE on every one of them.

    Models the s2n state the file header walks: `conn->out` holds an undrained
    record, so `s2n_send` reports zero plaintext accepted while its leading
    `s2n_flush` writes to a slow-draining socket. §0 proves that state is real
    on a live TLS connection; this models it deterministically so §1-§3 can
    exercise the driver 6000 trips deep in milliseconds.

    `_wire_step == 0` is the FROZEN variant — a genuine spin (departed peer /
    closed peer), where s2n's counters do not move because the syscall failed
    before they are incremented. §2 uses it as the anti-vacuity control."""

    var _script: List[UInt8]
    var _cursor: Int
    var _pendings_left: Int
    var _wire_step: Int
    var _wire: Int

    def __init__(out self, var script: List[UInt8], pendings: Int, wire_step: Int):
        self._script = script^
        self._cursor = 0
        self._pendings_left = pendings
        self._wire_step = wire_step
        self._wire = 0

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        _ = reactor
        # The peer says nothing until it has taken the whole request. Pending
        # rather than Eof: an Eof here would end the drive on the FIRST read
        # and §1 would never reach the write-side run it exists to measure.
        if self._pendings_left > 0:
            return StreamIo.pending(Int64(0))
        var remaining = len(self._script) - self._cursor
        if remaining <= 0:
            return StreamIo.eof()
        var n = remaining
        if len(dst) < n:
            n = len(dst)
        # SAFETY: `dst` is a caller-frame-rooted Span[UInt8, o]; the source is
        # this struct's own List. Both are valid for this frame; neither
        # pointer is stored. Same encapsulated bulk-copy shape as
        # `ScriptedStream.try_read`.
        unsafe_memcpy(
            dest=dst.unsafe_ptr(),
            src=self._script.unsafe_ptr() + self._cursor,
            count=n,
        )
        self._cursor = self._cursor + n
        return StreamIo.ready(Int64(n))

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        _ = reactor
        if self._pendings_left > 0:
            self._pendings_left = self._pendings_left - 1
            # ★ THE WHOLE POINT. Zero bytes ACCEPTED, `_wire_step` bytes MOVED.
            # That is not a contradiction — it is what `s2n_send` does once
            # `conn->out` holds an undrained record.
            self._wire = self._wire + self._wire_step
            return StreamIo.pending(Int64(0))
        return StreamIo.ready(Int64(len(src)))

    def fd(self) -> Int32:
        # No pollable fd: `park_on_pending` returns True without waiting, which
        # is the "READY park" the detector counts. Keeps the file hermetic and
        # sub-second while exercising the identical branch.
        return Int32(-1)

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_2

    def wire_bytes_moved(self) -> Int:
        """IoStream override — the whole subject of this file. See
        `TlsConnection.wire_bytes_moved` for the production implementation
        (s2n's `wire_bytes_in + wire_bytes_out`)."""
        return self._wire

    def close(var self):
        _ = self._script^


struct SlowDrainConnector(Connector, Movable, Deinitable):
    comptime Stream = SlowDrainPeer

    var _armed: Optional[SlowDrainPeer]

    def __init__(out self, var stream: SlowDrainPeer):
        self._armed = Optional[SlowDrainPeer](stream^)

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> SlowDrainPeer:
        _ = reactor
        _ = ip_be
        _ = port
        if not self._armed:
            raise Error("SlowDrainConnector.connect: no stream armed")
        return self._armed.take()

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return True

    def set_dial_host(mut self, var host: String):
        _ = host^


def _build_h2_response_script() raises -> List[UInt8]:
    """SETTINGS(empty) + HEADERS(:status 200) + one DATA frame with
    END_STREAM."""
    var script = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, script)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        UInt32(1), block^, end_stream=False, end_headers=True, out=script
    )
    var payload = List[UInt8]()
    var pi = 0
    while pi < _BODY_BYTES:
        payload.append(UInt8(0x41))
        pi = pi + 1
    encode_data_frame(UInt32(1), payload^, True, script)
    return script^


def _drive_against(pendings: Int, wire_step: Int) raises -> Tuple[Int, Int, String]:
    """Run the REAL `HttpClient.send_buffered` h2 path against a
    `SlowDrainPeer`. Returns `(status, body_len, raise_message)`; on a raise the
    status is -1 and the message is the raise text."""
    var peer = SlowDrainPeer(_build_h2_response_script(), pendings, wire_step)
    var connector = SlowDrainConnector(peer^)
    var client = HttpClient[SlowDrainConnector].with_defaults(connector^)
    var url = Url.https(
        String("storage.googleapis.com"), UInt16(443), String("/storage/v1/b/x/o")
    )
    var headers = HeaderMap()
    var req = build_get_request(url^, headers^)
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    try:
        var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req^, reactor
        )
        ref body = cr.body.bytes_ref()
        return (Int(cr.status), len(body), String(""))
    except e:
        return (-1, 0, String(e))


# -----------------------------------------------------------------------------
# §1 — THE PRODUCTION DRIVE. A slow-draining peer is NOT a livelock.
# -----------------------------------------------------------------------------


def test_wire_progress_defeats_the_livelock_verdict() raises:
    """6000 consecutive write-Pendings — 1.46x `_H2_READY_NO_PROGRESS_CAP` —
    each one moving `_WIRE_STEP` bytes across the wire. The drive must COMPLETE.

    PRE-FIX this raises `HttpError[LIVELOCK]: h2 driver made no progress across
    4096 consecutive READY parks`, because `ready_no_progress` was incremented
    on every Pending regardless of what the transport did. That verdict is in
    the connection-level retry set, so in production the effect was: abandon a
    transfer that was working, redial, meet the same congestion, repeat."""
    print("  test_wire_progress_defeats_the_livelock_verdict...")

    var res = _drive_against(_WRITE_PENDINGS, _WIRE_STEP)
    var status = res[0]
    var body_len = res[1]
    var msg = res[2]

    assert_true(
        status != -1,
        "a peer that answers Pending "
        + String(_WRITE_PENDINGS)
        + " times WHILE MOVING WIRE BYTES is slow, not livelocked — the drive"
        " must complete. Got a raise: "
        + msg,
    )
    assert_equal(status, 200, "the slow-draining peer's response is a 200")
    assert_equal(
        body_len, _BODY_BYTES,
        "the full body must arrive once the peer finally accepts the request",
    )
    print("    [OK] completed 200 with", body_len, "body bytes after",
          _WRITE_PENDINGS, "zero-accepted writes")


# -----------------------------------------------------------------------------
# §2 — ⭐ ANTI-VACUITY. A FROZEN wire counter is still a livelock.
# -----------------------------------------------------------------------------


def test_frozen_wire_counter_still_trips_the_detector() raises:
    """THE CONTROL THAT MAKES §1 MEAN SOMETHING. Identical peer, identical
    6000 pendings, `_wire_step = 0` — the state a DEPARTED or CLOSED peer
    produces, where s2n's counters cannot move because the syscall failed
    before `conn->wire_bytes_out += w` / `conn->wire_bytes_in += r`.

    This MUST still raise `HttpError[LIVELOCK]` naming the consecutive-park
    run. A change that fixed §1 by weakening or deleting the detector reds
    here, and so do the two live-TLS fixtures
    (`test_L2_h2_over_tls_send_to_departed_peer_no_spin`,
    `test_L2_h2_over_tls_abrupt_close_no_spin`)."""
    print("  test_frozen_wire_counter_still_trips_the_detector...")

    var res = _drive_against(_WRITE_PENDINGS, 0)
    var status = res[0]
    var msg = res[2]

    assert_equal(
        status, -1,
        "a peer that moves NOTHING at either layer must NOT be allowed to"
        " complete — that is the real spin the detector exists for",
    )
    assert_true(
        String("HttpError[LIVELOCK]") in msg,
        "the frozen-wire peer must still raise the LIVELOCK class; got: " + msg,
    )
    assert_true(
        String("made no progress across") in msg,
        "and it must be the CONSECUTIVE-PARK arm, not the iteration cap or the"
        " wall clock — those two mean different things and have different"
        " remedies. Got: " + msg,
    )
    print("    [OK] frozen wire counter still reaches the cap")


# -----------------------------------------------------------------------------
# §3 — ATTRIBUTION. The give-up must name the half it counted.
# -----------------------------------------------------------------------------


def test_livelock_message_names_the_side_it_counted() raises:
    """An `HttpError[LIVELOCK]` that prints
    `iters / elapsed_ms / parks / idle_parks` and NOTHING about which half of
    the loop counted them cannot say which half an operator is looking at,
    IN PRINCIPLE.

    A counter that cannot name the branch it counted is an unattributable
    counter. This asserts the three facts that make the next sighting
    diagnosable from its own text."""
    print("  test_livelock_message_names_the_side_it_counted...")

    var res = _drive_against(_WRITE_PENDINGS, 0)
    var msg = res[2]

    assert_true(
        String("side=write(pending->park-ready)") in msg,
        "the give-up must name the BRANCH that incremented the run — here the"
        " write-side park. Got: " + msg,
    )
    assert_true(
        String("total_read=0") in msg,
        "and whether the peer had answered at all: `total_read` is the"
        " discriminator the write-error path already uses to decide whether a"
        " request is re-issuable. Got: " + msg,
    )
    assert_true(
        String("wire_resets=0") in msg,
        "and whether the connection ever moved a byte on this drive."
        " `wire_resets>0` would say the give-up is about RATE, not liveness —"
        " a different fault with a different remedy. Got: " + msg,
    )
    print("    [OK] the give-up names side / total_read / wire_resets")


# =============================================================================
# §0 — THE s2n CONTRACT, MEASURED DIRECTLY ON A LIVE TLS CONNECTION.
#
# Immune to our shim, our driver and the model in §1: it calls `s2n_send`
# itself over the raw connection pointer and reads s2n's own counter.
# =============================================================================

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1

# ⚠ SOL_SOCKET / SO_SNDBUF ARE NOT PORTABLE, AND GETTING THEM WRONG FAILS
# SILENTLY — which is exactly what happened here and is why §0 measured
# nothing on darwin for five days.
#
#   SOL_SOCKET : Linux 1       (asm-generic/socket.h)
#                Darwin 0xffff (sys/socket.h)
#   SO_SNDBUF  : Linux 7       Darwin 0x1001
#
# With the LINUX pair on darwin, `setsockopt(fd, 1, 7, ...)` on an AF_UNIX
# socketpair returns -1/ENOTSUP(102) and the send buffer keeps its 8192-byte
# default. On darwin: 8192 > 8109 == one default_tls13 record on the
# wire (8087 plaintext + 22 AES-GCM overhead), so the FIRST record is absorbed
# WHOLE. s2n's leading flush then succeeds, `user_data_sent` goes to 8087, and
# the block happens on record #2 — where `s2n_send` takes its
# `user_data_sent > 0` partial-acknowledge arm (tls/s2n_send.c:222) and returns
# a POSITIVE n that this probe deliberately does not count. Every later probe
# faces a 100%-full buffer a non-reading peer never drains, so write(2) accepts
# 0 and `wire_bytes_out` is frozen: 7 blocked probes, 0 with wire progress.
#
# The asserted state needs the blocking flush to be the FIRST one — i.e.
# `user_data_sent == 0` AND that write(2) already moved >0 bytes. That requires
# a PARTIAL first write, which requires the buffer to be STRICTLY SMALLER than
# one record. Sibling `test_L2_h2_over_tls_real_rekey.mojo:306-345` already
# carries this same picker and the same warning.
comptime _SOL_SOCKET_LINUX: Int32 = Int32(1)
comptime _SOL_SOCKET_MACOS: Int32 = Int32(0xFFFF)
comptime _SO_SNDBUF_LINUX: Int32 = Int32(7)
comptime _SO_SNDBUF_MACOS: Int32 = Int32(0x1001)


def _sol_socket() -> Int32:
    comptime if CompilationTarget.is_linux():
        return _SOL_SOCKET_LINUX
    return _SOL_SOCKET_MACOS


def _so_sndbuf() -> Int32:
    comptime if CompilationTarget.is_linux():
        return _SO_SNDBUF_LINUX
    return _SO_SNDBUF_MACOS


# Large enough that it cannot fit in a squeezed socket buffer, so the FIRST
# `s2n_send` is guaranteed to block part-way through its own flush.
comptime _BIG_SEND: Int = 512 * 1024


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. Origin `o` is
    # concrete; the NULL sentinel is never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


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


def _squeeze_sndbuf(fd: Int32, want: Int32) raises:
    """Shrink the send buffer BELOW ONE TLS RECORD, so the FIRST flush's
    write(2) is a PARTIAL and s2n blocks with `user_data_sent == 0`
    (tls/s2n_send.c:222) — the ONLY state in which `s2n_send` reports zero
    plaintext accepted while `wire_bytes_out` rises.

    ⛔ NOT best-effort, and THE VALUE IS LOAD-BEARING. Measured on darwin
    against this repo's own libs2n: a grant of 8108 produces the asserted
    state and 8109 (== the record's wire size) does not. The call site asks
    for 4096, comfortably inside the window.

    ⛔ AND IT MUST NOT FAIL SILENTLY. The discarded rc here is precisely what
    let a no-op squeeze ship: on darwin the hardcoded Linux optnames returned
    -1/ENOTSUP and nobody heard it, so §0 ran against an 8192-byte buffer and
    measured a contract it had made unreachable. A squeeze that cannot happen
    makes the probe VACUOUS, so a failed setsockopt is a hard precondition
    failure, not a warning.
    """
    # ⚠ HEAP buffer, not `UnsafePointer(to=<stack local>)`. Taking the address
    # of a local and handing it to an `external_call` is NOT reliable here: the
    # compiler does not see the callee read through it, so the slot can be left
    # unmaterialised and the kernel reads GARBAGE. Measured on darwin with the
    # stack-local form and the correct optnames, the SAME binary alternated
    # between rc=0 with a nonsense grant (6) and rc=-1 — because the option
    # value the kernel saw was whatever happened to be in that slot.
    var val_buf = alloc[UInt8](8).unsafe_origin_cast[MutUntrackedOrigin]()
    val_buf.bitcast[Int32]()[] = want
    var rc = external_call["setsockopt", Int32](
        fd, _sol_socket(), _so_sndbuf(), val_buf, Int32(4)
    )
    val_buf.free()
    if rc != Int32(0):
        raise Error(
            "PRECONDITION: setsockopt(level="
            + String(Int(_sol_socket()))
            + ", opt="
            + String(Int(_so_sndbuf()))
            + ", "
            + String(Int(want))
            + ") failed rc="
            + String(Int(rc))
            + " — without it the socket cannot be congested below one TLS"
            " record and §0 measures nothing."
        )
    # Report the GRANT for diagnosis. Deliberately NOT asserted against a
    # numeric bound: Linux doubles the request (sock_setsockopt clamps to
    # max(val*2, SOCK_MIN_SNDBUF)) and reads back 8192, which is LARGER than
    # one 8109-byte record — yet Linux still produces the partial first write
    # because unix_stream_sendmsg chunks each skb well below that. A
    # "grant < record size" assertion would red on Linux.
    #
    # ⚠ HEAP buffers, not stack locals: the compiler cannot see that an
    # `external_call` wrote to a local, so reading one back can fold to the
    # initialiser and print a FALSE value.
    var out_buf = alloc[UInt8](8).unsafe_origin_cast[MutUntrackedOrigin]()
    var len_buf = alloc[UInt8](8).unsafe_origin_cast[MutUntrackedOrigin]()
    out_buf.bitcast[Int32]()[] = Int32(0)
    len_buf.bitcast[Int32]()[] = Int32(4)
    var grc = external_call["getsockopt", Int32](
        fd, _sol_socket(), _so_sndbuf(), out_buf, len_buf
    )
    print(
        "    [squeeze] SO_SNDBUF requested="
        + String(Int(want))
        + " getsockopt_rc="
        + String(Int(grc))
        + " granted="
        + String(Int(out_buf.bitcast[Int32]()[]))
    )
    out_buf.free()
    len_buf.free()


def _build_client_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
    config.set_cipher_preferences(String("default_tls13"))
    var alpn = List[String]()
    alpn.append(String("h2"))
    config.set_alpn_protocols(alpn)
    return config^


def _build_server_config_from_pem(cert: String, key: String) raises -> TlsConfig:
    var config = TlsConfig()
    config.load_cert(cert, key)
    config.set_cipher_preferences(String("default_tls13"))
    var alpn = List[String]()
    alpn.append(String("h2"))
    config.set_alpn_protocols(alpn)
    return config^


@fieldwise_init
struct _ServerArg(Copyable, Movable, Deinitable):
    var server_fd: Int32
    var cert_ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var cert_len: Int
    var key_ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var key_len: Int
    # 0 = running, 1 = handshake done + parked (NOT reading), 2 = error.
    var done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin]


def _run_server(
    server_fd: Int32,
    cert_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    cert_len: Int,
    key_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    key_len: Int,
    done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin],
) -> Bool:
    """Handshake to DONE, report it, then STOP READING and hold the fd open.

    ⚠ IT MUST NOT CLOSE. A close would make this the DEPARTED-PEER fixture,
    which is a different (and already-covered) contract: there `s2n_send` fails
    with `S2N_ERR_T_IO` and the wire counter FREEZES. Here the peer is alive
    and merely not draining, which is the congestion state — `S2N_ERR_T_BLOCKED`
    with the wire counter RISING."""
    try:
        var cert_bytes = List[UInt8]()
        var ci = 0
        while ci < cert_len:
            cert_bytes.append(cert_ptr[ci])
            ci = ci + 1
        var key_bytes = List[UInt8]()
        var ki = 0
        while ki < key_len:
            key_bytes.append(key_ptr[ki])
            ki = ki + 1
        var cert = String(unsafe_from_utf8=Span(cert_bytes))
        var key = String(unsafe_from_utf8=Span(key_bytes))
        var config = _build_server_config_from_pem(cert, key)

        var conn = TlsConnection(config)
        conn.bind_fd(server_fd)

        var hs_iters = 0
        while hs_iters < 5_000_000:
            hs_iters = hs_iters + 1
            var o = conn.handshake()
            if o == TLS_OUTCOME_DONE:
                break
            if o == TLS_OUTCOME_ERROR:
                return False
            _ = external_call["usleep", Int32](UInt32(100))
        if hs_iters >= 5_000_000:
            return False

        done_flag_ptr[] = Int32(1)
        # Hold the connection OPEN and UNREAD for the duration of the probe.
        var held = 0
        while held < 400:
            held = held + 1
            _ = external_call["usleep", Int32](UInt32(5000))
        _ = conn^
        return True
    except:
        return False


def _server_entry(
    raw: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    """Detached server thread. ABI matches pthread `void* (*)(void*)`.

    SAFETY (FFI-BOUNDARY): `raw` is the heap `_ServerArg` this thread solely
    owns; it reads the POD fields, frees the arg, then drives the server s2n
    connection. The cert/key buffers are freed by the MAIN thread after the
    probe. The body is wrapped so a raise sets done_flag=2 instead of unwinding
    across the FFI boundary."""
    var arg = raw.bitcast[_ServerArg]()
    var server_fd = arg[].server_fd
    var cert_ptr = arg[].cert_ptr
    var cert_len = arg[].cert_len
    var key_ptr = arg[].key_ptr
    var key_len = arg[].key_len
    var done_flag_ptr = arg[].done_flag_ptr
    arg.bitcast[UInt8]().free()

    var ok = _run_server(
        server_fd, cert_ptr, cert_len, key_ptr, key_len, done_flag_ptr
    )
    if not ok:
        done_flag_ptr[] = Int32(2)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _spawn_server_thread(
    server_fd: Int32,
    cert: String,
    key: String,
    done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin],
) raises -> Tuple[
    UnsafePointer[UInt8, MutUntrackedOrigin],
    UnsafePointer[UInt8, MutUntrackedOrigin],
]:
    var cert_len = cert.byte_length()
    var key_len = key.byte_length()
    var cert_buf = alloc[UInt8](cert_len).unsafe_origin_cast[MutUntrackedOrigin]()
    var key_buf = alloc[UInt8](key_len).unsafe_origin_cast[MutUntrackedOrigin]()
    var cs = cert.as_bytes()
    for i in range(cert_len):
        cert_buf[i] = cs[i]
    var ks = key.as_bytes()
    for i in range(key_len):
        key_buf[i] = ks[i]
    var raw = alloc[_ServerArg](1)
    UnsafePointer(to=raw[]).unsafe_write(
        _ServerArg(
            server_fd=server_fd,
            cert_ptr=cert_buf,
            cert_len=cert_len,
            key_ptr=key_buf,
            key_len=key_len,
            done_flag_ptr=done_flag_ptr,
        )
    )
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    var tid: Int64 = 0
    var slot = UnsafePointer(to=tid)
    var rc = external_call["pthread_create", Int32](
        slot.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _server_entry,
        raw_void,
    )
    if rc != Int32(0):
        raise Error("pthread_create returned " + String(Int(rc)))
    _ = external_call["pthread_detach", Int32](tid)
    return (cert_buf, key_buf)


def test_s2n_send_reports_zero_accepted_while_the_wire_advances() raises:
    """PINS THE s2n BEHAVIOUR THE FIX RESTS ON, by calling `s2n_send` itself
    over the raw connection pointer and reading s2n's own
    `s2n_connection_get_wire_bytes_out` — so it keeps telling the truth after
    any change to our shim, our driver or §1's model, and reds if an s2n bump
    changes the contract.

    THE CLAIM: against a peer that is ALIVE but NOT DRAINING, `s2n_send`
    returns `rc < 0` with `*blocked == S2N_BLOCKED_ON_WRITE` and ZERO plaintext
    accepted, while `wire_bytes_out` STRICTLY INCREASED across that same call.

    That pair is the whole defect: the return value says "nothing happened" and
    the counter says "16 KiB left the process". `s2n_sendv_with_offset_impl`
    cannot report both, because its leading `POSIX_GUARD(s2n_flush(conn,
    blocked))` (tls/s2n_send.c:146) is an early return that never reaches the
    `user_data_sent > 0` partial-acknowledge arm at :223-230.

    Non-vacuity, in order:
      1. the handshake must have reached DONE — otherwise this measures a
         failed handshake and not a congested one;
      2. the probe must actually have BLOCKED (rc < 0), or there is no claim;
      3. the delta must be STRICTLY positive — an unchanged counter would mean
         the send moved nothing and the pre-fix accounting was right.
    """
    print("  test_s2n_send_reports_zero_accepted_while_the_wire_advances...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    tls_init()
    var client_config = _build_client_config()
    var cert = Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text()
    var key = Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    # Squeeze BOTH ends: the client's send buffer and the server's receive
    # buffer both bound how much the kernel will absorb before `write(2)`
    # returns EAGAIN.
    _squeeze_sndbuf(client_fd, Int32(4096))

    var done_flag: Int32 = 0
    var done_flag_ptr = UnsafePointer(to=done_flag).unsafe_origin_cast[
        MutUntrackedOrigin
    ]()

    var cert_buf = _null_ptr[UInt8, MutUntrackedOrigin]()
    var key_buf = _null_ptr[UInt8, MutUntrackedOrigin]()
    var spawned = False
    var blocked_zero_accepted_with_wire_progress = 0
    var blocked_probes = 0
    var first_delta = 0
    try:
        var bufs = _spawn_server_thread(server_fd, cert, key, done_flag_ptr)
        cert_buf = bufs[0]
        key_buf = bufs[1]
        spawned = True

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        var hs_iters = 0
        var cl_done = False
        while hs_iters < 5_000_000:
            hs_iters = hs_iters + 1
            var o = client_conn.handshake()
            if o == TLS_OUTCOME_DONE:
                cl_done = True
                break
            if o == TLS_OUTCOME_ERROR:
                raise Error(
                    "client handshake ERROR: "
                    + s2n_strerror_message(last_s2n_errno())
                )
            _ = external_call["usleep", Int32](UInt32(100))
        assert_true(
            cl_done,
            "PRECONDITION: the client handshake must reach DONE, or this test"
            " measures a broken handshake and not a congested peer",
        )

        var wait_iters = 0
        while done_flag == 0 and wait_iters < 2000:
            wait_iters = wait_iters + 1
            _ = external_call["usleep", Int32](UInt32(5000))
        assert_equal(
            Int(done_flag), 1,
            "PRECONDITION: the server thread must report handshake-done and"
            " then stop reading (done_flag 1); 0 = still running, 2 = errored",
        )

        # ---- THE MEASUREMENT. Same buffer every time, exactly as the shim's
        # contract requires (`s2n_send` retries must present the same bytes).
        var payload = List[UInt8]()
        var si = 0
        while si < _BIG_SEND:
            payload.append(UInt8(65))
            si = si + 1

        var probe = 0
        while probe < 8:
            probe = probe + 1
            var before = client_conn.wire_bytes_moved()
            var sent = client_conn.send(Span(payload).as_imm())
            var after = client_conn.wire_bytes_moved()
            var outcome = sent[0]
            var n = sent[1]
            if outcome == TLS_OUTCOME_DONE and n == len(payload):
                # The kernel absorbed everything: this box's socket buffer is
                # too large to congest. Nothing to measure on this probe.
                continue
            if n <= 0:
                blocked_probes = blocked_probes + 1
                if after > before:
                    blocked_zero_accepted_with_wire_progress = (
                        blocked_zero_accepted_with_wire_progress + 1
                    )
                    if first_delta == 0:
                        first_delta = after - before
            # Give the (non-reading) peer no chance to drain; the point is that
            # the state persists.
            _ = external_call["usleep", Int32](UInt32(1000))

        _ = client_conn^
    finally:
        _close_fd(client_fd)
        if spawned:
            var drain = 0
            while done_flag == 0 and drain < 400:
                drain = drain + 1
                _ = external_call["usleep", Int32](UInt32(5000))
        _close_fd(server_fd)
        if spawned:
            cert_buf.free()
            key_buf.free()

    assert_true(
        blocked_probes > 0,
        "PRECONDITION: at least one `s2n_send` must have BLOCKED with zero"
        " accepted, or there is nothing to measure. Squeeze the send buffer"
        " harder or raise `_BIG_SEND`.",
    )
    assert_true(
        blocked_zero_accepted_with_wire_progress > 0,
        "THE CONTRACT: a blocked `s2n_send` reported ZERO plaintext accepted"
        " while `wire_bytes_out` STRICTLY INCREASED across the same call."
        " Measured "
        + String(blocked_zero_accepted_with_wire_progress)
        + " of " + String(blocked_probes)
        + " blocked probes. Zero here would mean the pre-fix"
        " application-layer accounting was right and the h2 driver's"
        " `ready_no_progress` needs no wire-layer veto.",
    )
    print(
        "    [OK]", blocked_zero_accepted_with_wire_progress, "of",
        blocked_probes,
        "blocked sends moved wire bytes with ZERO accepted (first delta",
        first_delta, "bytes)",
    )


def main() raises:
    test_wire_progress_defeats_the_livelock_verdict()
    test_frozen_wire_counter_still_trips_the_detector()
    test_livelock_message_names_the_side_it_counted()
    test_s2n_send_reports_zero_accepted_while_the_wire_advances()
    print("PASS test_L2_h2_wire_progress_is_not_a_livelock")
