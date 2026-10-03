# =============================================================================
# komira_http_core/transport/stream_park.mojo — THE park primitive.
# =============================================================================
#
# ONE way for a driver to wait on a stream. Every driver that owns an
# `IoStream` and must wait for it parks HERE, and nowhere else.
#
# =============================================================================
# WHY THIS EXISTS.
# =============================================================================
#
# WHAT THIS FILE IS FOR:
#
#   1. **One decision, made once.** Every driver that waits for a stream it
#      owns must decide the wait DIRECTION; independent park helpers that each
#      decide it on their own drift apart. This is the one place it is decided.
#   2. **A future s2n bump, kTLS, QUIC or a non-s2n peer is safe BY
#      CONSTRUCTION.** The direction is asked of the conformer that authored
#      the Pending, so a transport that DOES invert it is correct here without
#      touching any driver.
#
# ⚠ It is NOT a fix for an observed direction inversion: s2n-tls 1.5.6
# structurally cannot answer a send with BLOCKED_ON_READ or a recv with
# BLOCKED_ON_WRITE (confirmed in the s2n source and across real TLS 1.3
# rekeys). `SSL_write` -> `SSL_ERROR_WANT_READ` is OPENSSL semantics, not
# s2n's. A spin with `idle_parks=0` on a reaped pooled connection is an
# ABRUPT PEER CLOSE, handled one layer down in `s2n_shim._recv_outcome_and_n`
# (falsifier `test_L2_h2_over_tls_abrupt_close_no_spin`); a park cannot
# distinguish "ready" from "usable", but its non-waiting returns are what make
# such a failure a SPIN rather than a stall.
#
# =============================================================================
# THE DESIGN — what is shared, what is not, and why.
# =============================================================================
#
# ## What is shared here
#
# * **The mechanism.** A transient op-id registration + `poll_completions`
#   parks on exactly ONE fd. `Reactor.park_on_fds` is the wrong tool for that:
#     - it returns `epoll_wait`'s raw event count on the SHARED reactor epoll
#       fd, so a FOREIGN fd's readiness ends the park and is counted as this
#       stream's own (invariant (ii) below);
#     - `park_on_fds(want_write=True)` arms `EPOLLIN | EPOLLOUT` — BOTH
#       directions — so it is direction-inversion-immune only by accident.
#
# * **The buffered-plaintext shortcut's gate.** It is valid "only when the
#   PENDING I/O ITSELF was a read" — that is `not call_is_write`, exactly. It
#   is DERIVED here, so no caller can get it wrong.
#
# * **The direction argument itself.** This is the load-bearing part:
#   **this function does not take a direction.** It takes the Pending TOKEN and
#   the direction of the CALL that produced it — two facts — and asks the
#   stream. There is no parameter for a caller to pass a literal into.
#
# ## What stays with the caller
#
# * **The loop.** h2 multiplexes N streams against an iteration + wall budget;
#   h1 is a linear state machine on a spin budget; a long-lived receive is a
#   third shape. Those loops share nothing but the wait, and this function is
#   the wait. It deliberately does not own iteration counting, wall clocks, or
#   completion checks.
#
# * **The slice budget.** h2 wants 250 ms / 4096 polls; h1 wants 50 ms.
#   Parameters, not a policy this file picks.
#
# * **The RETURN VALUE.** h2 needs `ready` vs `idle` to make its give-up
#   message say whether the loop WAITED or was woken by somebody else
#   (`idle_parks` vs `parks`). Callers that do not need it ignore it.
#
# ## A driver that owns the s2n connection does not use this
#
# A transport that owns the `TlsConnection` directly (rather than an
# `IoStream`) branches on the raw `TLS_OUTCOME_BLOCKED_ON_WRITE` the send/recv
# just returned — the SAME fact `pending_wait_is_write` decodes, read one
# layer LOWER. Encoding that outcome into a fake Pending token purely so this
# function could decode it back would be ceremony, not unification.
# `TlsConnector`'s own handshake loop is the same shape and the same verdict.
#
# The rule both honour: *never pass a literal direction to a readiness wait;
# derive it from the thing that produced the Pending.* There are exactly two
# sanctioned oracles — this function's `pending_wait_is_write` (for `IoStream`
# drivers) and the raw `TLS_OUTCOME_BLOCKED_ON_WRITE` (for a driver that owns
# the s2n conn).
# =============================================================================

from komira_clock import now_ns as _mono_now_ns

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.transport.io_stream import IoStream


# Default bounded slice for one park. A stuck park RETURNS to the caller's
# loop so the caller's own budget can terminate a wedged conn; it is NEVER an
# unbounded `poll_completions(-1)`. Observed on the REACTOR clock
# (epoll_wait / kevent timeout), so the bound itself cannot be lost to a
# missed wakeup.
comptime PARK_SLICE_DEFAULT_US: Int32 = 250_000

# CPU brake for invariant (ii)'s re-poll: bounds how many times one slice may
# re-enter `poll_completions` when foreign completions keep returning it
# early at ~0 cost. Not a timeout — the slice's own microsecond budget is.
comptime PARK_POLLS_PER_SLICE_DEFAULT: Int = 4096


def park_on_pending[S: IoStream, RT: Runtime](
    ref stream: S,
    mut reactor: Reactor[RT.Sink],
    pending_token: Int64,
    call_is_write: Bool,
    slice_us: Int32 = PARK_SLICE_DEFAULT_US,
    polls_per_slice_cap: Int = PARK_POLLS_PER_SLICE_DEFAULT,
) raises -> Bool:
    """Park the calling thread on `stream`'s fd until it is ready for the
    direction THE STREAM SAYS to wait on, or until `slice_us` elapses. Then
    deregister and return.

    THE ONLY WAY A DRIVER WAITS ON A STREAM. `pending_token` is the payload of
    the `StreamIo.pending` the I/O just returned; `call_is_write` says which
    method produced it (`try_write` -> True).

    ⚠ **THERE IS NO DIRECTION PARAMETER, AND THAT IS THE POINT.** The wait
    direction is `stream.pending_wait_is_write(pending_token, call_is_write)`
    — the conformer's OWN answer, computed inside this function so no caller
    can pass a literal. A kernel-socket conformer inherits the trait default
    (`return call_is_write`: a Pending means EWOULDBLOCK in the direction of
    the call, so that direction is exactly right). `TlsClientStream` overrides
    it to decode the direction bit it wrote into the token. The token's
    ENCODING never leaves the conformer that authored it.

    **BUFFERED-PLAINTEXT LOST-WAKEUP GUARD, DERIVED NOT PARAMETERISED.** On a
    read Pending, if the stream already holds decrypted plaintext ABOVE the
    socket fd (s2n drained a >4 KiB record into its userspace buffer and
    handed back only a chunk), the fd has NO more bytes and parking on its
    read-readiness would hang out the whole slice. We skip the park and return
    True so the caller re-reads immediately. The guard applies iff the PENDING
    I/O ITSELF WAS A READ — buffered *plaintext* cannot unblock a write that
    is waiting for a TLS *record* off the socket, and taking the shortcut
    there re-spins the same wait one layer down. So the gate is exactly
    `not call_is_write`; it is computed here rather than passed, because the
    one caller that carried it as a parameter had to document that its only
    correct value was this expression. Root cause: a TLS stream can hold decrypted bytes in its own buffer that
    socket readiness cannot see, so a park there would miss its wakeup.

    **BOUNDED, NEVER `poll_completions(-1)`.** An unbounded park was the root
    cause of a multi-chunk object-store read hang: an
    unresponsive peer or a missed wakeup left the park blocked forever, so the
    caller's loop never regained control to re-check completion or its own
    budget. Bounding the slice makes a stuck park RETURN, and the caller's
    budget turns a wedge into a typed deadline instead of an infinite hang.

    **NO FALSE TIMEOUT ON A HEALTHY-SLOW RPC.** Registration is LEVEL-
    triggered (`edge_triggered=False` on macOS / plain EPOLLIN|EPOLLOUT on
    Linux), so bytes arriving at ANY point during the park — including between
    the caller's last WouldBlock and this registration — return
    `poll_completions` immediately, well inside the bound. The bound fires
    only when the fd genuinely produced no readiness for the whole slice, and
    the caller then re-parks.

    **INVARIANT (ii): A POLL THAT RETURNS WITHOUT *THIS* OP BECOMING READY
    RE-POLLS FOR THE REMAINDER OF THE SLICE.** `Reactor.poll_completions`
    returns on ANY reactor event — a wake-channel completion contributes an
    EMPTY list and still ends the syscall, and so does a foreign fd's
    completion. Code that treats any early return as "the peer answered" takes
    somebody else's readiness for its own. Each such return costs ~0 µs, so a
    caller's whole budget can evaporate in about a second and surface as a
    spurious deadline 12-50x early, with unrelated services failing
    identically because the defect is in the park, not in any service. `polls_per_slice_cap` is
    the CPU brake for the case where those early returns cost no measurable
    time.

    RETURNS **True** iff the caller may usefully re-attempt the I/O: this fd
    became ready, OR parking did not apply (buffered plaintext already
    decrypted / no pollable fd). **False** iff we parked a whole slice and
    this fd never became ready — an IDLE slice.

    ★ **THE THREE PATHS THAT RETURN True WITHOUT WAITING ARE THE WHOLE HAZARD
    SURFACE OF THIS FUNCTION**, because a caller that re-Pendings after one of
    them spins at zero cost per trip: (1) the buffered-plaintext shortcut,
    (2) `fd < 0`, (3) the poll loop finding this fd genuinely READY. Path (3)
    is how a closed peer spins — a CLOSED socket is permanently
    read-ready. Nothing here can distinguish "ready" from "usable"; that has to
    be right in the conformer, and when it is not, `idle_parks == 0` in a
    caller's give-up message is the fingerprint. h2 counts those so its give-up
    message can say whether it WAITED or was merely woken by somebody else
    (`idle_parks` ~= `parks` is a peer/network fault; `idle_parks` <<
    `parks` is a reactor-side wake storm). Callers that do not distinguish the
    two may discard it.

    SAFETY/LIVENESS: registers interest on the BORROWED fd for one bounded
    park, then deregisters. The fd is owned by `stream` (alive for this call);
    we never close it. `op_id` is reactor-allocated so it cannot collide with
    another in-flight op, and the deregister keeps this transient registration
    from colliding with a long-lived one. Conformers with no pollable fd
    (`ScriptedStream` returns -1) cannot be parked — they return True and the
    caller's bounded busy-loop is the contract, which is byte-for-byte the
    prior behaviour for those conformers.

    Encapsulation: no `UnsafePointer`, no wildcard origin. Returns a POD
    `Bool`.

    ⚠ `stream` is `ref`, NOT `mut` — WAITING DOES NOT MUTATE THE STREAM, and
    the signature now says so. The three methods used here (`fd`,
    `has_buffered_readable`, `pending_wait_is_write`) are all borrowing `self`
    on the trait. h2's helper took `mut` and never needed it; h1's took `ref`,
    which is why the first build of this collapse failed with "value passed to
    mutable argument 'stream' must be mutable" — h1 parks from a `ref self`
    frame and CANNOT hand out a mutable borrow. The stricter of the two
    conventions is the correct one, and it is the one that lets all three
    callers in.
    """
    # DERIVED, not parameterised — see the docstring. Read side only.
    if not call_is_write and stream.has_buffered_readable():
        return True
    var fd = stream.fd()
    if fd < Int32(0):
        # Readiness is unobservable on this conformer; the caller's bounded
        # busy-loop is the contract. Not an idle slice.
        return True
    # ⚠ THE DIRECTION COMES FROM THE STREAM. There is deliberately no
    # parameter for it, and no `if is_write` a caller can reach.
    var wait_is_write = stream.pending_wait_is_write(pending_token, call_is_write)
    var op_id = reactor.alloc_op_id()
    if wait_is_write:
        reactor.register_write(fd, op_id, UInt16(0))
    else:
        reactor.register_read(fd, op_id, UInt16(0))
    var slice_start_ns = Int64(_mono_now_ns())
    var slice_budget_us = Int64(slice_us)
    var ready = False
    var polls = 0
    while polls < polls_per_slice_cap:
        var waited_us = (Int64(_mono_now_ns()) - slice_start_ns) // Int64(1000)
        var left_us = slice_budget_us - waited_us
        if left_us <= Int64(0):
            break
        var _drained = reactor.poll_completions(timeout_us=Int32(left_us))
        polls = polls + 1
        # INVARIANT (ii): only THIS op's readiness counts.
        if reactor.is_ready(op_id):
            ready = True
            break
    reactor.deregister(op_id)
    return ready
