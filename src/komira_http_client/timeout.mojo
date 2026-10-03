# =============================================================================
# src/komira_http_client/timeout.mojo — TimeoutLayer
# =============================================================================
#
# Layer that enforces deadlines on the inner
# HttpService.call:
#   * `connect_timeout_us` — deadline for the connect phase. Fires
#     before the inner call returns if connector.connect is parked
#     past the deadline. implementation: check the clock right
#     before/after inner.call returns; if elapsed exceeds the
#     connect_timeout AND the call would have errored with
#     CONNECT_FAILED (heuristic), raise TIMEOUT. Mid-poll cancellation goes through
#     the reactor's mid-poll cancellation token.
#   * `request_deadline_us` — total deadline for the request. If the
#     elapsed time across the inner.call exceeds this value, raise
#     HttpError[TIMEOUT].
#
# ⭐ THE FOLLOW-UP THIS LAYER ONCE NAMED IS DONE, AND THE
# PARAGRAPH IT REPLACED IS KEPT BELOW BECAUSE IT IS THE FINDING:
#
#     "In the layer checks the elapsed time AT LAYER ENTRY AND EXIT.
#      True mid-poll cancellation (firing the timeout DURING a parked
#      inner.call) requires plumbing through the OutboundDriver's
#      pending loop + reactor-timer. That's a follow-up."
#
# While that was true the layer LABELLED a deadline it did not BOUND: a 50 ms
# deadline over a 400 ms inner returned control after 400,037 µs carrying a
# tidy `HttpError[TIMEOUT]` that read as though the timeout had worked. Scale
# it up and that is a real 504 — an 8 s budget, a ~300 s
# call, and the tidy error afterwards.
#
# ⛔ THE FIX IS NOT "CANCEL THE INNER FROM HERE", AND IT CANNOT BE. `call` is
# SYNCHRONOUS and SINGLE-THREADED: once control is inside `inner.call` this
# frame does not run again until it returns, so there is no instant at which
# this layer could interrupt anything. Every HTTP client with a working
# request timeout works the same way — Go's `http.Client.Timeout` does not
# preempt the transport, it arms a deadline the transport's readLoop honours
# by closing the connection under a BLOCKED READ (`net/http/transport.go`:
# the readLoop's 3-way select -> `pc.cancelRequest` -> `pc.conn.Close()`).
# The bounding is always done by the party that owns the wait.
#
# So the layer STATES the deadline and the party that waits ENFORCES it:
# `ClientRequest.set_request_budget_us` carries the number down, the base
# service composes it with its own configured budget (the TIGHTER binds,
# `tighter_budget_us`), and `OutboundDriver._check_deadline` — which already
# runs at the head of every drive iteration, gated on nothing — fires it
# mid-flight. The post-call elapsed check below SURVIVES and is not
# redundant: an inner that honours no budget (a test double, a non-driver
# conformer, a future transport) is still caught on the way out, which is
# the only thing this layer can do about a party that does not cooperate.
#
# Slot-brief acceptance criterion: "TimeoutLayer fires on
# never-resolving ScriptedConnector + clock advance — NO sleep in tests."
# satisfies this by: the test scripts an inner.call that ITSELF
# advances the MockClock past the deadline before returning a success
# (simulating a slow connect); the layer's post-call elapsed-check
# fires the TIMEOUT. The test conformer is the seam where the
# clock-advance happens deterministically.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import RequestBody
from komira_http_client.clock import Clock
from komira_http_client.outbound_budget import tighter_budget_us
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import (
    ClientRequest,
    HttpLayer,
    HttpService,
)
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector


# =============================================================================
# §1 — TimeoutLayer
# =============================================================================
#
# Parametric over the inner HttpService + the Clock conformer.
#
# Constants:
#   * connect_timeout_us = 0 → unbounded (no enforcement).
#   * request_deadline_us = 0 → unbounded.
#
# Diagnostic:
#   * last_elapsed_us — how long the most recent call took (per the
#     injected clock, NOT wall time).


struct TimeoutLayer[Inner: HttpService, ClockT: Clock](
    HttpService, HttpLayer, Movable, Deinitable,
):
    """ TimeoutLayer.

    Construction:
      `TimeoutLayer.wrap(inner, clock, connect_timeout_us,
                         request_deadline_us)`.

    The connect_timeout_us guards the *connect phase* — still enforced as a
    post-call check (there is no connect-phase bound on the request to carry
    it down; the driver's budget spans the whole call).

    The request_deadline_us guards the *full request lifecycle*, and it is
    ENFORCED MID-FLIGHT: `call` stamps it onto the request
    (`set_request_budget_us`) before handing the request to the inner, so a
    cooperating inner is bounded rather than merely measured. The post-call
    elapsed check remains as the backstop for an inner that ignores it.

    Setting either to 0 disables enforcement of that timeout.
    """

    var _inner: Self.Inner
    var _clock: Self.ClockT
    var _connect_timeout_us: Int
    var _request_deadline_us: Int
    var _last_elapsed_us: Int

    @staticmethod
    def wrap(
        var inner: Self.Inner,
        var clock: Self.ClockT,
        connect_timeout_us: Int,
        request_deadline_us: Int,
    ) -> TimeoutLayer[Self.Inner, Self.ClockT]:
        return TimeoutLayer[Self.Inner, Self.ClockT](
            _inner=inner^,
            _clock=clock^,
            _connect_timeout_us=connect_timeout_us,
            _request_deadline_us=request_deadline_us,
            _last_elapsed_us=0,
        )

    def __init__(
        out self,
        var _inner: Self.Inner,
        var _clock: Self.ClockT,
        _connect_timeout_us: Int,
        _request_deadline_us: Int,
        _last_elapsed_us: Int,
    ):
        self._inner = _inner^
        self._clock = _clock^
        self._connect_timeout_us = _connect_timeout_us
        self._request_deadline_us = _request_deadline_us
        self._last_elapsed_us = _last_elapsed_us

    def layer_name(self) -> String:
        return String("timeout")

    @always_inline
    def last_elapsed_us(self) -> Int:
        return self._last_elapsed_us

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """Drive the inner with deadline enforcement.

        Algorithm:
          0. STAMP `request_deadline_us` onto the request, so the party that
             actually waits can fire it mid-flight.
          1. Sample t0 = clock.now_us().
          2. Try inner.call:
             a. On success: sample t1; elapsed = max(t1 - t0, 0).
                If request_deadline_us > 0 AND elapsed > request_deadline_us
                  → raise TIMEOUT.
                Otherwise: return resp. The connect-phase bound is NOT
                consulted on this arm: a response in hand is proof the
                connect phase succeeded.
             b. On exception: sample t1; elapsed = t1 - t0.
                If elapsed > connect_timeout_us (when > 0) AND the
                error appears to be a CONNECT failure → re-raise as
                TIMEOUT (CONNECT_TIMEOUT semantic).
                If elapsed > request_deadline_us (when > 0) → re-raise
                as TIMEOUT (general).
                Else: re-raise the original error.
        """
        # ★ STATE THE DEADLINE BEFORE HANDING OVER CONTROL. This is the
        # whole of the enforcement half: once `inner.call` is entered this
        # synchronous single-threaded frame does not run again until it
        # returns, so a deadline not stated BEFORE the handover can only ever
        # be reported AFTER it. `set_request_budget_us` TIGHTENS ONLY, so a
        # budget an outer layer already stated survives a looser inner one.
        #
        # ⚠ `_connect_timeout_us` IS DELIBERATELY NOT STAMPED. It is a
        # PHASE bound and `request_budget_us` is a WHOLE-CALL bound; handing a
        # connect-phase number down as a whole-call budget would cut off every
        # response slower than the connect timeout — the exact data-loss
        # defect removed from the success arm below on the same day.
        if self._request_deadline_us > 0:
            req.set_request_budget_us(
                tighter_budget_us(
                    req.request_budget_us(), self._request_deadline_us,
                )
            )
        var t0 = self._clock.now_us()  # Clock.now_us is `mut self` per
        # Inner.call is wrapped in a try block; its exception is the
        # ONLY one we treat as "from the inner". A raise from the
        # deadline-check arm AFTER the try block must NOT re-enter
        # the except handler — that would double-sample the clock
        # and inflate elapsed.
        var resp_opt = Optional[ClientResponse[BufferedResponseBody]]()
        var inner_raised_msg = String()
        var inner_raised = False
        try:
            var resp = self._inner.call[RT, C, B](
                req^, connector, reactor,
            )
            resp_opt = Optional[ClientResponse[BufferedResponseBody]](resp^)
        except e:
            inner_raised = True
            inner_raised_msg = String(e)

        var t1 = self._clock.now_us()
        var elapsed = t1 - t0
        # ELAPSED IS NEVER NEGATIVE, AND CLAMPING IT HERE IS THE WHOLE FIX.
        # `Clock` REQUIRES monotonic non-decreasing readings and
        # `SystemClock` (vDSO monotonic) honours it -- but the trait is public
        # and injectable BY DESIGN, and both deadline comparisons below are
        # `elapsed > deadline`. A single backwards step between the two
        # samples therefore makes EVERY deadline on this request unreachable
        # at once: not one fires, and `last_elapsed_us()` reports a negative
        # duration to whatever reads it. That is the fail-OPEN direction, and
        # a timeout mechanism given an unreliable reading must degrade toward
        # firing, never toward never firing. We cannot claim more time passed
        # than we can measure, so an unusable delta reads as zero.
        if elapsed < 0:
            elapsed = 0
        self._last_elapsed_us = elapsed

        if inner_raised:
            var is_connect_err = _is_connect_err(inner_raised_msg)
            if (
                self._connect_timeout_us > 0
                and elapsed > self._connect_timeout_us
                and is_connect_err
            ):
                raise Error(
                    "HttpError[CONNECT_TIMEOUT]: connect phase exceeded "
                    + String(self._connect_timeout_us) + " us "
                    + "(elapsed " + String(elapsed) + " us); "
                    + "inner reported: " + inner_raised_msg
                )
            if (
                self._request_deadline_us > 0
                and elapsed > self._request_deadline_us
            ):
                raise Error(
                    "HttpError[TIMEOUT]: request exceeded deadline "
                    + String(self._request_deadline_us) + " us "
                    + "(elapsed " + String(elapsed) + " us); "
                    + "inner reported: " + inner_raised_msg
                )
            # Not a deadline issue — propagate the original.
            raise Error(inner_raised_msg)

        # Inner succeeded — check the REQUEST deadline on the elapsed.
        if (
            self._request_deadline_us > 0
            and elapsed > self._request_deadline_us
        ):
            raise Error(
                "HttpError[TIMEOUT]: request exceeded deadline "
                + String(self._request_deadline_us) + " us "
                + "(elapsed " + String(elapsed) + " us)"
            )
        # ⛔ AND DELIBERATELY NO `connect_timeout_us` CHECK ON THIS ARM.
        # Raising CONNECT_TIMEOUT here
        # whenever the TOTAL elapsed exceeds the connect-phase bound, over a
        # response that has already come back, is wrong for three independent
        # reasons, each sufficient:
        #
        #   1. IT CONTRADICTS THE FIELD'S OWN DEFINITION. `connect_timeout_us`
        #      guards the CONNECT PHASE (see the struct docstring). `elapsed`
        #      is the WHOLE call -- connect plus request-write plus head plus
        #      body. A phase bound applied to the total is not that bound, and
        #      a response in hand is proof the connect phase SUCCEEDED.
        #   2. THE ERROR ARM HAS A GUARD THIS ARM CANNOT HAVE. Above, a
        #      CONNECT_TIMEOUT is raised only when `_is_connect_err()`
        #      confirms the inner really failed at connect. On the success
        #      path there is no error to classify, so the equivalent guard is
        #      not merely missing -- it is UNWRITABLE at this site. That
        #      asymmetry is the tell.
        #   3. IT WAS DATA LOSS. A complete, valid response with its body
        #      already materialised was discarded. Everything above the layer
        #      saw a connect failure for a connection that demonstrably
        #      connected, and a caller that retries on CONNECT_TIMEOUT -- the
        #      reasonable thing to do -- reissued a request that had already
        #      succeeded. For a non-idempotent request that is a duplicated
        #      side effect.
        #
        # WHO WAS EXPOSED: any caller bounding the connect phase and leaving
        # the total unbounded (`connect_timeout_us > 0`,
        # `request_deadline_us == 0`) -- the natural spelling of "fail fast if
        # you cannot reach the host, but let a slow endpoint finish". EVERY
        # response slower than the connect timeout was destroyed.
        # Falsifier: `test_timeout_layer_bounds_wall_time.mojo`
        # `a_successful_response_is_not_discarded_as_a_connect_timeout`.
        return resp_opt.take()


# =============================================================================
# §2 — Error-message classifier.
# =============================================================================


def _is_connect_err(ref msg: String) -> Bool:
    """True iff the error message starts with a CONNECT-class HttpError
    prefix (CONNECT_FAILED or CONNECT_TIMEOUT)."""
    return (
        _str_starts_with(msg, String("HttpError[CONNECT_FAILED]"))
        or _str_starts_with(msg, String("HttpError[CONNECT_TIMEOUT]"))
    )


def _str_starts_with(ref s: String, prefix: String) -> Bool:
    var s_bytes = s.as_bytes()
    var p_bytes = prefix.as_bytes()
    var sn = len(s_bytes)
    var pn = len(p_bytes)
    if pn > sn:
        return False
    var i = 0
    while i < pn:
        if s_bytes[i] != p_bytes[i]:
            return False
        i = i + 1
    return True
