# =============================================================================
# THE HANDSHAKE ARM OF `_error_typed_outcome`.
# =============================================================================
#
# THREE s2n entry points use `_error_typed_outcome` rather than
# `_blocked_status_to_outcome` — `send`, `shutdown` and `handshake`. The send
# arm is covered by `test_L2_h2_over_tls_send_to_departed_peer_no_spin`; this
# file covers the handshake arm. The reading it rests on
# (`tls/s2n_handshake_io.c`, s2n-tls v1.5.6):
#
#   :1626   `s2n_negotiate_impl` sets `*blocked = S2N_BLOCKED_ON_WRITE` BEFORE
#           the write it is about to attempt.
#   :1658   ...and `S2N_BLOCKED_ON_READ` before the read.
#   :1691   `*blocked = S2N_NOT_BLOCKED` is reached ONLY by COMPLETING the
#           whole handshake.
#
# ⇒ a peer that departs MID-HANDSHAKE — a load balancer reaping a half-open
#   connection, a server that RSTs on a cert it dislikes, a GFE draining —
#   comes back from `s2n_negotiate` as `(-1, S2N_BLOCKED_ON_*)`.
#
# ★★ AND THE MEASUREMENT BOUNDS THE SEVERITY. Believing `*blocked` might be
# expected to "park on a dead fd — which is permanently ready in both
# directions — and spin to its wall deadline instead of failing in
# microseconds with the s2n error."
#
# **MEASURED HERE: THE MISREPORT IS EXACTLY ONE CALL DEEP.** Probe 1 sets a
# direction and fails; probes 2..64 short-circuit on the connection's now-closed
# io-status BEFORE the `*blocked` assignment at :1626/:1658, so `*blocked` keeps
# the CALLER's initial value (`S2N_NOT_BLOCKED`), and
# `_blocked_status_to_outcome` maps `(NOT_BLOCKED, rc<0)` to
# `TLS_OUTCOME_ERROR`. So the cost of believing `*blocked` on the handshake
# arm is ONE WASTED PARK, not a burnt wall budget.
#
# ⚠ THE ERROR-TYPED MAPPING IS STILL RIGHT — s2n knows on call 1 — but a reader
# who re-derives the severity from the source alone will overstate it, so the
# quantity is asserted rather than described: §0 pins the misreport DEPTH at 1,
# and §1 pins the ERROR to trip 1 rather than trip 2.
#
# ⛔ THE SEND ARM IS A DIFFERENT AND GENUINELY WORSE CASE, and this file does
# not weaken it: there the misreport IS permanent, because a failed `write(2)`
# never sets `conn->write_closed`, so there is no closed-status short-circuit to
# reach. `test_L2_h2_over_tls_send_to_departed_peer_no_spin`
# measures 128/128.
#
# ⚠ THIS IS A DIFFERENT PEER FROM
# `test_L1_tls_handshake_wall_deadline.mojo`, AND THAT IS WHY THAT FILE DOES
# NOT COVER THIS. There the peer completes the TCP handshake and then says
# NOTHING — the fd never becomes ready, every park is IDLE, and the correct
# verdict IS the wall clock. Here the peer GOES AWAY, the fd is permanently
# ready, and burning the wall clock is a bug: s2n knew the answer on the first
# call and the shim threw it away. A silent peer and a departed peer are the
# two halves, they have opposite fingerprints (`idle_parks` high vs zero), and
# only one of them had a test.
#
# WHAT THIS FILE ASSERTS
#
#   §0  THE s2n CONTRACT, pinned by calling `s2n_negotiate` DIRECTLY over the
#       raw connection pointer — immune to any change in our shim, and it reds
#       on an s2n bump. Four assertions: the departure is PERMANENT (every
#       probe fails); the error TYPE says dead on every probe (so it, and not
#       `*blocked`, is the disambiguator); the FIRST probe DOES misreport a
#       BLOCKED_ON_* direction (so there is something to correct); and the
#       misreport DEPTH is exactly 1 (so nobody restates the wall-budget claim).
#
#   §1  THE SHIM: `TlsConnection.handshake()` must answer `TLS_OUTCOME_ERROR`
#       on THE FIRST trip after the departure. PRE-FIX
#       (`_blocked_status_to_outcome`) trip 1 answers
#       `TLS_OUTCOME_BLOCKED_ON_READ` and the ERROR lands on trip 2 ⇒ RED on
#       the trip-count assertion.
#
# Pointer discipline: UnsafePointer use is confined to the
# socketpair / pthread / s2n out-param FFI thunks (concrete or
# MutExternalOrigin AT the FFI boundary, never crossing a non-FFI module) — the
# same carve-out as the two fixtures whose harness this clones.
#
# Mojo 1.0.0b2 (def-only).
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import alloc
from std.testing import assert_equal, assert_true

from komira_http.tls import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    tls_init,
)
from komira_http.tls.ffi import (
    S2N_BLOCKED_ON_READ,
    S2N_BLOCKED_ON_WRITE,
    S2nOpaquePtr,
    _S2N_FFI_ORIGIN,
    s2n_error_get_type,
    s2n_negotiate,
)


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1

# `s2n_error_type` (api/s2n.h). ⚠ THE ENUM IS COMMENT-INTERLEAVED — the values
# are consecutive from 0 and do NOT line up with the header's line numbers.
comptime _S2N_ERR_T_OK: Int32 = Int32(0)
comptime _S2N_ERR_T_IO: Int32 = Int32(1)
comptime _S2N_ERR_T_CLOSED: Int32 = Int32(2)
comptime _S2N_ERR_T_BLOCKED: Int32 = Int32(3)

# How many `handshake()` trips §1 allows before it calls the answer permanent.
# Generous: a healthy handshake on a socketpair completes in single digits, and
# the pre-fix behaviour is BLOCKED on every one of an unbounded number.
comptime _HANDSHAKE_TRIP_CAP: Int = 512

# How many raw `s2n_negotiate` probes §0 makes. The shim's correctness needs
# the post-departure state to be PERMANENT, so the LAST probe is asserted too.
comptime _POST_DEPARTURE_PROBES: Int = 64


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


def _errtype_str(t: Int32) -> StaticString:
    """Name of an `s2n_error_type` ordinal, for the diagnostic lines below.

    ⚠ `-> StaticString`, NOT `-> String` — the standard shape."""
    if t == _S2N_ERR_T_OK:
        return "S2N_ERR_T_OK"
    if t == _S2N_ERR_T_IO:
        return "S2N_ERR_T_IO"
    if t == _S2N_ERR_T_CLOSED:
        return "S2N_ERR_T_CLOSED"
    if t == _S2N_ERR_T_BLOCKED:
        return "S2N_ERR_T_BLOCKED"
    return "S2N_ERR_T_OTHER"


def _outcome_str(o: UInt8) -> StaticString:
    if o == TLS_OUTCOME_DONE:
        return "TLS_OUTCOME_DONE"
    if o == TLS_OUTCOME_BLOCKED_ON_READ:
        return "TLS_OUTCOME_BLOCKED_ON_READ"
    if o == TLS_OUTCOME_BLOCKED_ON_WRITE:
        return "TLS_OUTCOME_BLOCKED_ON_WRITE"
    if o == TLS_OUTCOME_ERROR:
        return "TLS_OUTCOME_ERROR"
    return "TLS_OUTCOME_OTHER"


def _build_client_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
    config.set_cipher_preferences(String("default_tls13"))
    return config^


# -----------------------------------------------------------------------------
# The PEER, on a detached helper pthread.
#
# ⚠ IT NEVER SPEAKS TLS. It reads whatever the client's ClientHello puts on the
# wire — so the client has genuinely STARTED a handshake and is waiting on a
# ServerHello — and then closes the fd abruptly, with no alert and no
# close_notify. That is what a load balancer does to a half-open connection and
# what a draining frontend does to one it will not serve.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _PeerArg(Copyable, Movable, Deinitable):
    var peer_fd: Int32
    # 0 = running, 1 = read the ClientHello + closed, 2 = error.
    var done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin]


def _peer_entry(
    raw: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    """Detached peer thread. ABI matches pthread `void* (*)(void*)`.

    SAFETY (FFI-BOUNDARY): `raw` is the heap `_PeerArg` this thread solely
    owns; it reads the POD fields, frees the arg, then drains and closes. No
    Mojo exception can cross the FFI boundary from here — the body raises
    nothing."""
    var arg = raw.bitcast[_PeerArg]()
    var peer_fd = arg[].peer_fd
    var done_flag_ptr = arg[].done_flag_ptr
    arg.bitcast[UInt8]().free()

    # Drain whatever the client sent (the ClientHello). Non-blocking fd, so
    # poll with a bounded number of sleeps rather than blocking forever.
    var buf = alloc[UInt8](8192).unsafe_origin_cast[MutUntrackedOrigin]()
    var total = 0
    var spins = 0
    while spins < 4000 and total == 0:
        spins = spins + 1
        # ⚠ `recv`, NOT `read`: the Mojo stdlib RESERVES the libc `read`
        # symbol with its own binding, and a second declaration with a
        # differing signature fails MLIR legalization at archive-lower time on
        # LINUX ONLY. `scripts`' package lint refuses it by name; `recv` is the
        # spelling the other socket fixtures in this tree use
        # (`test_e2e_bring_up.mojo:127`).
        var n = external_call["recv", Int64](
            peer_fd, buf, UInt64(8192), Int32(0)
        )
        if n > Int64(0):
            total = total + Int(n)
            break
        _ = external_call["usleep", Int32](UInt32(500))
    buf.free()

    if total == 0:
        done_flag_ptr[] = Int32(2)
        return _null_ptr[NoneType, MutUntrackedOrigin]()

    # ★ THE DEPARTURE. Bare close(2) — a FIN, no TLS alert, no close_notify,
    # and no ServerHello ever written.
    _close_fd(peer_fd)
    done_flag_ptr[] = Int32(1)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _spawn_peer_thread(
    peer_fd: Int32,
    done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin],
) raises:
    var raw = alloc[_PeerArg](1)
    UnsafePointer(to=raw[]).unsafe_write(
        _PeerArg(peer_fd=peer_fd, done_flag_ptr=done_flag_ptr)
    )
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    var tid: Int64 = 0
    var slot = UnsafePointer(to=tid)
    var rc = external_call["pthread_create", Int32](
        slot.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _peer_entry,
        raw_void,
    )
    if rc != Int32(0):
        raise Error("pthread_create returned " + String(Int(rc)))
    _ = external_call["pthread_detach", Int32](tid)


# -----------------------------------------------------------------------------
# §0 — THE s2n CONTRACT, MEASURED DIRECTLY. Immune to our own shim.
# -----------------------------------------------------------------------------


def test_s2n_negotiate_answers_departed_peer_with_blocked_status() raises:
    """PINS THE s2n BEHAVIOUR §1 RESTS ON, by calling `s2n_negotiate` itself
    over the raw connection pointer.

    THE CLAIM (`tls/s2n_handshake_io.c:1626/1658/1691`): after the peer departs
    mid-handshake, `s2n_negotiate` returns rc < 0 with `*blocked` STILL naming
    a direction — because the only write of `S2N_NOT_BLOCKED` is reached by
    COMPLETING the handshake — and the sole disambiguator is
    `s2n_error_get_type(s2n_errno)`, which must NOT be `S2N_ERR_T_BLOCKED`.

    Non-vacuity, in order:
      1. the peer thread must report that it read a ClientHello and closed —
         otherwise this measures a handshake that never started;
      2. the first probe must actually FAIL (rc < 0);
      3. the LAST probe must answer identically, because the shim's fix depends
         on the state being PERMANENT, not a transient one call would clear.
    """
    print("  test_s2n_negotiate_answers_departed_peer_with_blocked_status...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    tls_init()
    var client_config = _build_client_config()
    var fds = _socketpair()
    var peer_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(peer_fd)
    _set_nonblock(client_fd)

    var done_flag: Int32 = 0
    var done_flag_ptr = UnsafePointer(to=done_flag).unsafe_origin_cast[
        MutUntrackedOrigin
    ]()

    var blocked_status_hits = 0
    var non_blocked_type_hits = 0
    var rc_neg_hits = 0
    var probes_made = 0
    var first_errtype: Int32 = -1
    var last_errtype: Int32 = -1
    var first_blocked: Int32 = -1
    var last_blocked: Int32 = -1
    try:
        _spawn_peer_thread(peer_fd, done_flag_ptr)

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        # ONE handshake step to put the ClientHello on the wire. It cannot
        # complete (nothing will answer), so a BLOCKED return here is expected
        # and is the precondition, not the measurement.
        var _first = client_conn.handshake()

        var wait_iters = 0
        while done_flag == 0 and wait_iters < 2000:
            wait_iters = wait_iters + 1
            _ = external_call["usleep", Int32](UInt32(5000))
        assert_equal(
            Int(done_flag), 1,
            "PRECONDITION: the peer thread must read the ClientHello and then"
            " close (done_flag 1); 0 = still running, 2 = it never saw a"
            " ClientHello, which would mean this measures a handshake that"
            " never started",
        )

        # ---- THE MEASUREMENT. Raw `s2n_negotiate`, repeatedly. ----
        var raw = client_conn._raw_conn_ptr_for_test()
        var probe = 0
        while probe < _POST_DEPARTURE_PROBES:
            probe = probe + 1
            probes_made = probes_made + 1
            # SAFETY: stack-local out-parameter for the blocked status; the
            # external_call writes it once before returning and we read it
            # immediately. `raw` is the live s2n connection, alive for the call.
            var blocked_local = Int32(0)
            var blocked_ptr = UnsafePointer(to=blocked_local).unsafe_mut_cast[
                False
            ]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
            var rc = s2n_negotiate(raw, blocked_ptr)
            if rc >= Int32(0):
                continue
            rc_neg_hits = rc_neg_hits + 1
            var et = s2n_error_get_type(last_s2n_errno())
            if first_errtype < 0:
                first_errtype = et
                first_blocked = blocked_local
            last_errtype = et
            last_blocked = blocked_local
            if (
                blocked_local == S2N_BLOCKED_ON_READ
                or blocked_local == S2N_BLOCKED_ON_WRITE
            ):
                blocked_status_hits = blocked_status_hits + 1
            if et != _S2N_ERR_T_BLOCKED:
                non_blocked_type_hits = non_blocked_type_hits + 1

        _ = client_conn^
    finally:
        _close_fd(client_fd)
        _close_fd(peer_fd)

    assert_equal(
        probes_made, _POST_DEPARTURE_PROBES,
        "PRECONDITION: every probe must have been made",
    )
    assert_equal(
        rc_neg_hits, _POST_DEPARTURE_PROBES,
        "PRECONDITION: the departure must be PERMANENT — every probe must"
        " fail. A probe that succeeded would mean the peer had not departed.",
    )
    assert_equal(
        non_blocked_type_hits, _POST_DEPARTURE_PROBES,
        "THE DISAMBIGUATOR: the error TYPE must say the connection is dead on"
        " EVERY probe — first=" + String(_errtype_str(first_errtype))
        + " last=" + String(_errtype_str(last_errtype))
        + ". If this were S2N_ERR_T_BLOCKED then `*blocked` was telling the"
        " truth and `_error_typed_outcome` would have nothing to correct.",
    )

    # ★★ THE MISREPORT IS EXACTLY ONE CALL DEEP, AND THAT IS A MEASUREMENT,
    # NOT AN ASSUMPTION. The departed-peer state does NOT make the connect loop
    # "spin to its wall deadline", and this is the assertion that pins the real
    # depth so nobody re-derives the stronger claim from the source alone:
    #
    #   probe 1  — `s2n_negotiate_impl` reaches the `*blocked = BLOCKED_ON_*`
    #              at tls/s2n_handshake_io.c:1626/1658, THEN the I/O fails.
    #              `*blocked` names a direction and the return says -1: the
    #              misreport.
    #   probe 2+ — the connection is now marked closed, so the call
    #              short-circuits at its io-status check BEFORE the `*blocked`
    #              assignment. `*blocked` is left at whatever the CALLER
    #              initialised it to (0 = S2N_NOT_BLOCKED here), and the
    #              pre-fix `_blocked_status_to_outcome` maps (NOT_BLOCKED,
    #              rc<0) to TLS_OUTCOME_ERROR.
    #
    # ⇒ the pre-fix cost of the handshake arm is ONE WASTED PARK, not a burnt
    #   wall budget. The fix is still right — s2n knew on call 1 — but the
    #   severity in that commit message is overstated, and §1 asserts the
    #   corrected quantity (the ERROR must land on trip 1, not trip 2).
    assert_true(
        first_blocked == S2N_BLOCKED_ON_READ
        or first_blocked == S2N_BLOCKED_ON_WRITE,
        "THE MISREPORT: the FIRST post-departure `s2n_negotiate` must still"
        " name a BLOCKED_ON_* direction — that is the pre-set at"
        " tls/s2n_handshake_io.c:1626/1658, which the failing I/O never gets"
        " to clear. Got *blocked=" + String(Int(first_blocked))
        + ". Zero here would mean there is nothing for"
        " `_error_typed_outcome` to correct on this path.",
    )
    assert_equal(
        blocked_status_hits, 1,
        "AND IT IS EXACTLY ONE CALL DEEP. Probes 2.."
        + String(_POST_DEPARTURE_PROBES)
        + " short-circuit on the connection's closed io-status BEFORE the"
        " `*blocked` assignment, so `*blocked` keeps the caller's initial"
        " value. Measured "
        + String(blocked_status_hits) + " misreporting probe(s); last"
        " *blocked=" + String(Int(last_blocked))
        + ". If this ever becomes " + String(_POST_DEPARTURE_PROBES)
        + ", an s2n bump has made the handshake arm as severe as the SEND arm"
        " (`test_L2_h2_over_tls_send_to_departed_peer_no_spin`, where the"
        " misreport IS permanent) and the connect loop can spin again.",
    )
    print(
        "    [OK] misreport depth =", blocked_status_hits, "of",
        _POST_DEPARTURE_PROBES, "probes; error type",
        _errtype_str(last_errtype), "on every one",
    )


# -----------------------------------------------------------------------------
# §1 — THE SHIM. `handshake()` must say ERROR, not BLOCKED, and say it FAST.
# -----------------------------------------------------------------------------


def test_handshake_reports_error_not_blocked_after_peer_departs() raises:
    """`TlsConnection.handshake()` must answer `TLS_OUTCOME_ERROR` once the
    peer has departed mid-handshake.

    Under `_blocked_status_to_outcome` alone, trip 1
    answers `TLS_OUTCOME_BLOCKED_ON_READ` — s2n's pre-set — and the ERROR lands
    on trip 2, because by then the connection is marked closed and
    `s2n_negotiate` short-circuits before touching `*blocked`. So the
    discriminator is the TRIP NUMBER, and §0 is what establishes that it is 2
    and not "forever": the misreport is one call deep.

    ⚠ THE ASSERTION IS ON THE OUTCOME AND THE TRIP, NOT ON A DURATION. A
    wall-clock assertion would be satisfied by any change that merely made the
    loop faster; the defect is that the shim reported the WRONG FACT, and its
    cost is one park spent re-asking a question s2n had already answered.

    ⚠ AND IT IS DELIBERATELY NOT A `_HANDSHAKE_TRIP_CAP`-SIZED CLAIM. Writing
    "it would spin forever" here would be restating the overstatement §0
    measures away."""
    print("  test_handshake_reports_error_not_blocked_after_peer_departs...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    tls_init()
    var client_config = _build_client_config()
    var fds = _socketpair()
    var peer_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(peer_fd)
    _set_nonblock(client_fd)

    var done_flag: Int32 = 0
    var done_flag_ptr = UnsafePointer(to=done_flag).unsafe_origin_cast[
        MutUntrackedOrigin
    ]()

    var trips = 0
    var final_outcome: UInt8 = TLS_OUTCOME_DONE
    var saw_error = False
    try:
        _spawn_peer_thread(peer_fd, done_flag_ptr)

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        var _first = client_conn.handshake()

        var wait_iters = 0
        while done_flag == 0 and wait_iters < 2000:
            wait_iters = wait_iters + 1
            _ = external_call["usleep", Int32](UInt32(5000))
        assert_equal(
            Int(done_flag), 1,
            "PRECONDITION: the peer must read the ClientHello and then close",
        )

        while trips < _HANDSHAKE_TRIP_CAP:
            trips = trips + 1
            final_outcome = client_conn.handshake()
            if final_outcome == TLS_OUTCOME_ERROR:
                saw_error = True
                break
            if final_outcome == TLS_OUTCOME_DONE:
                break

        _ = client_conn^
    finally:
        _close_fd(client_fd)
        _close_fd(peer_fd)

    assert_true(
        saw_error,
        "`TlsConnection.handshake()` must report TLS_OUTCOME_ERROR once the"
        " peer has departed. Got "
        + String(_outcome_str(final_outcome))
        + " on all " + String(trips) + " trips.",
    )
    assert_equal(
        trips, 1,
        "AND IT MUST SAY SO ON THE FIRST TRIP. s2n already knew — the error"
        " type on that very call is not S2N_ERR_T_BLOCKED (§0) — so a second"
        " trip is a park spent on a dead fd re-asking an answered question."
        " Under `_blocked_status_to_outcome` this is 2: trip 1 returns"
        " TLS_OUTCOME_BLOCKED_ON_READ from s2n's pre-set, and only trip 2"
        " reaches the (NOT_BLOCKED, rc<0) -> ERROR arm. Took "
        + String(trips) + ".",
    )
    print("    [OK] TLS_OUTCOME_ERROR on trip", trips)


def main() raises:
    test_s2n_negotiate_answers_departed_peer_with_blocked_status()
    test_handshake_reports_error_not_blocked_after_peer_departs()
    print("PASS test_L1_tls_handshake_departed_peer_fails_fast")
