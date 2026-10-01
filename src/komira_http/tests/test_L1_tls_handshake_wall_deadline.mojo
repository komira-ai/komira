"""`TlsConnector.connect`'s handshake budget must be WALL-CLOCK TIME, not a
count of loop trips.

THE FAILURE SHAPE. A handshake budget counted in loop trips produces errors like

    TlsConnector.connect: handshake exceeded 256 iterations
      (s2n_errno=201326592)

201326592 = 0x0C000000 = `3 << S2N_ERR_NUM_VALUE_BITS` = the base of s2n's
`S2N_ERR_T_BLOCKED` range = `S2N_ERR_IO_BLOCKED` — "underlying I/O operation
would block" (s2n-tls error/s2n_errno.h). **s2n had not failed.** Its verdict
was "healthy, not finished", and the client hung up on it; a plain retry of the
same dial succeeds.

THE DEFECT. The loop gave up after `_HANDSHAKE_ITER_CAP = 256` iterations, and
an iteration was not a unit of time OR of progress. `poll_completions` returns
on ANY reactor event — a drained wake-eventfd contributes an EMPTY list — so an
iteration cost anywhere between ~0 µs and the 250 ms park slice. The effective
timeout was therefore somewhere in [~0 s, 64 s], was stated nowhere, and any
transient that made a handful of parks return early spent the entire budget on
a handshake that was milliseconds old.

WHAT THIS FILE FALSIFIES. Against a peer that completes the TCP handshake and
then says NOTHING — a listening socket that is never `accept()`ed, so the
kernel finishes the 3-way handshake and no ServerHello ever comes — the connect
must give up after the STATED wall-clock budget and no other quantity:

  * A trip-counted budget: both cases below burn 256 x 250 ms = 64.1 s and
    raise "exceeded 256 iterations" ⇒ RED.
  * A wall-clock budget: each case returns at its own stated deadline with a
    message naming elapsed/deadline/parks/idle_slices/direction/host ⇒ GREEN
    in ~4 s (1200 -> ~1200 ms, 2500 -> ~2500 ms).

TWO deadlines, not one, and that is the load-bearing part of the design: a
single data point is satisfied by ANY fixed constant that happens to be small.
Two different stated budgets producing two different measured walls is what
makes "the budget is the wall clock" the only surviving explanation.

⚠ WHY A TEST THAT MEASURES DURATION IS SAFE TO GATE A LIBRARY. A throughput
budget measures the machine and is unsafe in a gate with no retry. This
measures a SLEEPING wait against a stated deadline, and the two failure
directions are not symmetric:

  * the LOWER bounds cannot be violated by load at all — load never makes a
    timed wait return EARLY;
  * the UPPER bounds carry ~12x slack over the measured value (1.2 s measured
    against a 15 s ceiling) while the pre-fix value is 64 s, so the falsifier
    still holds a >4x margin. A machine would have to deschedule a sleeping
    process for thirteen seconds to red this, and would have to do so without
    reaching the 64 s that means the fix is gone.

Keep that asymmetry if you retune these numbers: tighten the LOWER bounds
freely, and never bring an UPPER bound near either the measured value or 64 s.

The peer is a loopback socket in this process. No network, no fixture server,
no thread — hermetic.
"""

from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    getsockname_port,
    inet_loopback_be,
    listen_socket,
    set_so_reuseaddr,
    socket_tcp_nonblocking,
)
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http.client.tls_connector import build_public_ca_tls_connector
from komira_http.tls import tls_init

from komira_obs.clock import now_ns


comptime _RT = BlockingRuntime[NoopSink]

# The SNI the connector dials under. It is never resolved (we hand `connect` a
# loopback ip_be directly), but it MUST appear in the give-up message: the host
# is what a reader needs to reproduce the dial, and the message this test pins
# replaced one that named no host at all.
comptime _SILENT_HOST: String = "silent-peer.invalid"

# -----------------------------------------------------------------------------
# The silent peer.
# -----------------------------------------------------------------------------
def _silent_listener() raises -> Tuple[Int32, UInt16]:
    """A loopback socket that is bound + listening and will NEVER be accepted.

    This is the whole fixture. The kernel completes the TCP 3-way handshake for
    a backlog entry with no `accept()` in sight, so the client's `connect(2)`
    succeeds and its ClientHello lands in the socket buffer — and then nothing
    ever comes back. That is precisely the state s2n reports as
    `S2N_ERR_IO_BLOCKED`, i.e. the live-deploy state, with no network, no peer
    process and no thread involved.
    """
    var fd = socket_tcp_nonblocking()
    set_so_reuseaddr(fd)
    bind_inet(fd, inet_loopback_be(), UInt16(0))
    listen_socket(fd, Int32(8))
    var port = getsockname_port(fd)
    return (fd, port)


def _dial_and_time(deadline_ms: Int, listen_port: UInt16) raises -> Tuple[
    Int64, String
]:
    """Dial the silent peer with the connector's handshake deadline set to
    `deadline_ms`.

    Returns (elapsed_ms, error_message). RAISES if `connect` somehow SUCCEEDS —
    a peer that never sent a byte cannot have produced a TLS session, and a
    connector that returned a stream here would be a worse bug than the one
    this file guards.
    """
    var connector = build_public_ca_tls_connector(String(_SILENT_HOST))
    connector.set_handshake_deadline_us(Int64(deadline_ms) * Int64(1000))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var t0 = Int64(now_ns())
    var message = String("")
    var raised = False
    try:
        var stream = connector.connect[_RT](
            reactor=reactor, ip_be=inet_loopback_be(), port=listen_port,
        )
        _ = stream^
    except e:
        raised = True
        message = String(e)
    var elapsed_ms = (Int64(now_ns()) - t0) // Int64(1_000_000)
    if not raised:
        raise Error(
            "_dial_and_time: connect() SUCCEEDED against a peer that never"
            " sent a byte — there is no session to have negotiated"
        )
    return (elapsed_ms, message^)


# -----------------------------------------------------------------------------
# The falsifier.
# -----------------------------------------------------------------------------
def test_bug_handshake_budget_is_wall_clock_not_iterations() raises:
    """RED pre-fix (both cases take ~64 s and say "exceeded 256 iterations"),
    GREEN post-fix (each case returns at ITS OWN stated deadline)."""
    print("  test_bug_handshake_budget_is_wall_clock_not_iterations...")
    tls_init()

    var listener = _silent_listener()
    var listen_fd = listener[0]
    var listen_port = listener[1]

    # ---- case A: a 1200 ms budget --------------------------------------
    var a = _dial_and_time(1200, listen_port)
    var a_ms = a[0]
    var a_msg = a[1]
    print(
        "    case A: deadline_ms=1200 -> elapsed_ms=" + String(a_ms)
    )

    # LOWER bound. The give-up must have WAITED. A budget that is spent
    # without waiting is the exact half of this defect that made a
    # millisecond-old handshake look exhausted, so "fails fast" is a FAILURE
    # here, not a pass.
    if a_ms < Int64(600):
        close_fd(listen_fd)
        raise Error(
            "handshake gave up after only " + String(a_ms) + " ms of a"
            " 1200 ms budget — the loop did not WAIT, which is the defect"
            " (it spent budget on parks that returned without readiness)."
            " message: " + a_msg
        )
    # UPPER bound. Pre-fix this is 64075 (256 x the 250 ms park slice) and the
    # env var is ignored entirely. Deliberately far above the measured 1202 ms
    # AND far below 64 s — see the docstring on why the slack is asymmetric.
    if a_ms > Int64(15000):
        close_fd(listen_fd)
        raise Error(
            "handshake ran " + String(a_ms) + " ms against a stated 1200 ms"
            " budget — the budget is not the wall clock. message: " + a_msg
        )

    # ---- case B: a 2500 ms budget --------------------------------------
    # A DIFFERENT stated budget must produce a DIFFERENT wall. One data point
    # is satisfied by any small constant; two are not.
    var b = _dial_and_time(2500, listen_port)
    var b_ms = b[0]
    var b_msg = b[1]
    print(
        "    case B: deadline_ms=2500 -> elapsed_ms=" + String(b_ms)
    )
    if b_ms < Int64(1500) or b_ms > Int64(20000):
        close_fd(listen_fd)
        raise Error(
            "handshake ran " + String(b_ms) + " ms against a stated 2500 ms"
            " budget — the wall does not track the stated deadline."
            " message: " + b_msg
        )
    # A fixed constant would make A and B equal; only a budget that TRACKS the
    # stated value separates them. Combined with B's >= 1500 ms floor this rules
    # out every constant, not just the small ones.
    if b_ms <= a_ms:
        close_fd(listen_fd)
        raise Error(
            "raising the budget 1200 -> 2500 ms did not lengthen the wall"
            " (A=" + String(a_ms) + " ms, B=" + String(b_ms) + " ms) — the"
            " give-up is governed by something other than the deadline"
        )

    # ---- the message must carry the evidence ---------------------------
    # The string this replaced was `handshake exceeded 256 iterations
    # (s2n_errno=201326592)`: 256 of what, for how long, waiting on which
    # direction, against which host — none of it recoverable. Each field
    # below is one of those questions.
    var required = List[String]()
    required.append(String("deadline_ms=1200"))  # the budget is STATED
    required.append(String("elapsed_ms="))  # ... and it was MEASURED
    required.append(String("parks="))  # how many slices were spent
    required.append(String("idle_slices="))  # ... how many actually waited
    required.append(String("blocked_on=READ"))  # which direction stalled
    required.append(_SILENT_HOST)  # against which peer
    required.append(String("s2n_errno=201326592"))  # s2n's own verdict
    for i in range(len(required)):
        if required[i] not in a_msg:
            close_fd(listen_fd)
            raise Error(
                "give-up message is missing '" + required[i] + "' — it cannot"
                " be diagnosed without a rebuild. message: " + a_msg
            )
    # And it must NOT re-state the budget in the broken unit.
    if String("iterations") in a_msg:
        close_fd(listen_fd)
        raise Error(
            "give-up message still reports ITERATIONS — the unit is the"
            " defect. message: " + a_msg
        )

    close_fd(listen_fd)
    print(
        "    OK — the handshake budget tracks the STATED wall-clock deadline"
        " (1200 ms -> " + String(a_ms) + " ms, 2500 ms -> " + String(b_ms)
        + " ms) and the give-up names elapsed/parks/idle_slices/direction/host"
    )


def main() raises:
    print("== TLS handshake wall-clock-deadline falsifier ==")
    test_bug_handshake_budget_is_wall_clock_not_iterations()
    print("== TLS handshake wall-clock-deadline PASSED (1 test) ==")
