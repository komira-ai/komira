# =============================================================================
# src/komira_http_client/retry.mojo — RetryLayer + RetryPolicy + BackoffCurve
# =============================================================================
#
# The tower Layer-vs-Policy split:
#   Retry is NOT a built-in HttpClient feature — it is a RetryLayer, one
#   HttpLayer in the Service/Layer stack. RetryLayer is the mechanism
#   (wrap inner service, catch error, re-invoke); RetryPolicy is the
#   policy (when, how many times, how long to wait).
#
# This file ships the deliverable:
#   * `BackoffCurve` — exponential backoff with jitter (fixed-point math;
#     no Float). Configurable base/multiplier/max/jitter band.
#   * `RetryPolicy` — pluggable policy: max_attempts, BackoffCurve,
#     retry_on_status_codes (List[UInt16]), is_retryable(err) classifier.
#   * `RetryLayer[Inner, RngT]` — wraps an HttpService.
#
# Backoff "sleep" via Clock advance is a follow-up (requires reactor
# coordination);'s tests use MockClock.advance for deterministic
# verification — the LAYER itself computes the delay via the
# BackoffCurve + injectable RNG, but does not block the calling thread.
# The diagnostic `compute_planned_delay_us(attempt)` lets tests verify
# the backoff calculation is correct. In production use, the
# retry loop runs back-to-back (no inter-attempt delay) — acceptable
# for the deliverable since the layer's RETRY-CORRECTNESS
# (idempotent vs non-idempotent, max_attempts, classifier) is the
# load-bearing guarantee. Backoff-as-pause is+ via reactor-timer.
#
# Request reconstruction across retries:
#   * For EmptyBody-backed requests (the buffered shape with body=
#     EmptyBody marker; request_bytes carries the wire form), the
#     layer stashes (method, url, headers, request_bytes) BEFORE the
#     first inner.call, and reconstructs ClientRequest from stashes
#     on retry. The retry layer is parametric on B=EmptyBody for now v1.
#   * For BytesBody / StreamingBody requests, retry is NOT supported in
#     the layer surfaces the error unretried
#     "fail loud, do not guess".
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee` (Optional.take + stdlib swap suffice).
#   * ZERO new ArcPointer.
#   * The layer is parametric on Inner/RngT — monomorphizes per
#     consumer call site, no fn-ptr dispatch.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import BytesBody, EmptyBody, RequestBody
from komira_http_client.clock import Rng
from komira_http_client.error import (
    HTTP_ERROR_PROTOCOL_STATUS,
    HTTP_ERROR_RETRYABLE_TRANSPORT,
    HttpError,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import (
    ClientRequest,
    HttpLayer,
    HttpService,
)
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector


# =============================================================================
# §1 — BackoffCurve — exponential backoff with jitter.
# =============================================================================
#
# Fixed-point arithmetic to avoid Float (Mojo 1.0.0b1's Int math is
# faster + more predictable). The curve produces a delay in microseconds:
#
#   raw_delay_us = base_delay_us * (multiplier_x100/100)^(attempt-1)
#   capped       = min(raw_delay_us, max_delay_us)
#   jitter_range = (capped * jitter_frac_x100) / 100
#   jitter_offs  = (rng.next_u64() % (2 * jitter_range + 1)) - jitter_range
#   final        = capped + jitter_offs  (clamped to [0, max_delay_us])
#
# `attempt` is 1-based: attempt=1 → first retry (after first failure),
# attempt=2 → second retry, etc.
#
# Default constants: base=100ms, multiplier=2x, max=10s,
# jitter=25%.


@fieldwise_init
struct BackoffCurve(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Exponential backoff with jitter, parameterized by fixed-point
    knobs. Consumed by RetryLayer.compute_planned_delay_us.

    Fields:
      base_delay_us       — first-retry delay (default 100_000 = 100ms).
      multiplier_x100     — exponent base, x100 (default 200 = 2x).
                            multiplier_x100=200 means each attempt's
                            base delay is 2x the previous.
      max_delay_us        — hard cap on per-attempt delay (default
                            10_000_000 = 10s; prevents runaway).
      jitter_frac_x100    — jitter band as percent of capped delay
                            (default 25 = ±25% band).
    """

    var base_delay_us: Int
    var multiplier_x100: Int
    var max_delay_us: Int
    var jitter_frac_x100: Int

    @staticmethod
    def defaults() -> BackoffCurve:
        return BackoffCurve(
            base_delay_us=100_000,
            multiplier_x100=200,
            max_delay_us=10_000_000,
            jitter_frac_x100=25,
        )

    def compute_delay_us[R: Rng](
        self, attempt: Int, mut rng: R,
    ) -> Int:
        """Compute the delay (in microseconds) before the `attempt`-th
        retry (1-based). The RNG advances by one call.

        Algorithm matches the docstring header — no Float, all
        fixed-point Int math. `attempt <= 0` returns 0 (the layer never
        calls with attempt=0; defensive)."""
        if attempt <= 0:
            return 0
        # raw_delay = base * multiplier_x100^(attempt-1) / 100^(attempt-1).
        var raw = self.base_delay_us
        var e = attempt - 1
        var i = 0
        while i < e:
            raw = (raw * self.multiplier_x100) // 100
            if raw >= self.max_delay_us:
                raw = self.max_delay_us
                break
            i = i + 1
        var capped = raw if raw < self.max_delay_us else self.max_delay_us
        # Jitter.
        var band = (capped * self.jitter_frac_x100) // 100
        if band == 0:
            return capped
        # rng.next_u64() % (2*band+1) gives uniform [0, 2*band];
        # subtract band → uniform [-band, +band].
        var roll_u64 = rng.next_u64()
        var roll = Int(roll_u64 % UInt64(2 * band + 1))
        var jittered = capped + (roll - band)
        if jittered < 0:
            return 0
        if jittered > self.max_delay_us:
            return self.max_delay_us
        return jittered


# =============================================================================
# §2 — Method-idempotency table.
# =============================================================================


@always_inline
def is_idempotent_method(method: HttpMethod) -> Bool:
    """True iff `method` is RFC 7231 §4.2.2 idempotent.
    GET, HEAD, OPTIONS, TRACE, PUT, DELETE → True.
    POST, PATCH → False (caller must opt-in via
    RetryPolicy.allow_post_patch_retry)."""
    var name = method.name()
    if name == String("GET"):
        return True
    if name == String("HEAD"):
        return True
    if name == String("OPTIONS"):
        return True
    if name == String("TRACE"):
        return True
    if name == String("PUT"):
        return True
    if name == String("DELETE"):
        return True
    return False


# =============================================================================
# §3 — RetryPolicy — pluggable policy object.
# =============================================================================


struct RetryPolicy(Movable, Deinitable):
    """Pluggable RetryPolicy. Configures a RetryLayer.

    Fields:
      max_attempts              — total attempts (default 3: 1 try + 2
                                  retries). max_attempts=1 disables retry.
      backoff                   — BackoffCurve.
      retry_on_status_codes     — list of HTTP status codes that trigger
                                  retry beyond RETRYABLE_TRANSPORT.
                                  Default: empty ( — 5xx/429
                                  retry is the consumer's policy, not
                                  the default).
      allow_post_patch_retry    — opt-in retry for POST/PATCH
                                  (non-idempotent). Default False.

    NOT Copyable — the inner List[UInt16] is owned; cloning is explicit
    via `.copy()`."""

    var max_attempts: UInt32
    var backoff: BackoffCurve
    var retry_on_status_codes: List[UInt16]
    var allow_post_patch_retry: Bool

    @staticmethod
    def defaults() -> RetryPolicy:
        return RetryPolicy(
            max_attempts=UInt32(3),
            backoff=BackoffCurve.defaults(),
            retry_on_status_codes=List[UInt16](),
            allow_post_patch_retry=False,
        )

    def __init__(
        out self,
        max_attempts: UInt32,
        backoff: BackoffCurve,
        var retry_on_status_codes: List[UInt16],
        allow_post_patch_retry: Bool,
    ):
        self.max_attempts = max_attempts
        self.backoff = backoff
        self.retry_on_status_codes = retry_on_status_codes^
        self.allow_post_patch_retry = allow_post_patch_retry

    def copy(self) -> RetryPolicy:
        """Explicit clone — List[UInt16] is Copyable (UInt16 is POD)."""
        var codes = List[UInt16]()
        var i = 0
        while i < self.retry_on_status_codes.__len__():
            codes.append(self.retry_on_status_codes[i])
            i = i + 1
        return RetryPolicy(
            max_attempts=self.max_attempts,
            backoff=self.backoff,
            retry_on_status_codes=codes^,
            allow_post_patch_retry=self.allow_post_patch_retry,
        )

    @always_inline
    def is_retryable_error(self, err_kind: UInt8) -> Bool:
        """True iff the error kind warrants a retry per this policy.
        Currently only RETRYABLE_TRANSPORT is retryable by default."""
        return err_kind == HTTP_ERROR_RETRYABLE_TRANSPORT

    def matches_retry_status(self, status: UInt16) -> Bool:
        """True iff `status` appears in retry_on_status_codes."""
        var n = self.retry_on_status_codes.__len__()
        var i = 0
        while i < n:
            if self.retry_on_status_codes[i] == status:
                return True
            i = i + 1
        return False


# =============================================================================
# §4 — RetryLayer — the middleware.
# =============================================================================
#
# Parametric over the inner HttpService + the Rng. The Rng for jitter
# is injected so tests use DeterministicRng for byte-deterministic
# backoff verification.
#
# `_last_attempt_count` — diagnostic field. After call() returns, this
# field reports how many attempts were spent on the most recent call
# (1..max_attempts). Resets to 0 on each new call entry.
#
# `_last_planned_delay_us` — diagnostic field. After call() returns,
# this field reports the SUM of computed backoff delays across all
# retry transitions in the most recent call (0 if no retry happened).
#
# RetryLayer is parametric on `B: RequestBody = EmptyBody` for now v1:
# only EmptyBody-backed requests support replay reconstruction. Mixing
# the type-parameter on the call method itself runs into the
# Mojo 1.0.0b1 monomorphization where call's B parameter is bound by
# the inner HttpService trait; we re-bind the layer's B on the wrap.


struct RetryLayer[
    Inner: HttpService, RngT: Rng,
](HttpService, HttpLayer, Movable, Deinitable):
    """ RetryLayer.

    Construction:
      `RetryLayer.wrap(inner, policy, rng)`.

    On `call`:
      1. Stash (method, url.copy, headers.copy, request_bytes.copy) for
         potential replay (only EmptyBody-backed requests; B param
         enforced at call site).
      2. Invoke inner.call(req).
      3. If success: check resp.status against retry_on_status_codes;
         if matches AND attempts remaining → compute backoff, advance
         the planned-delay diagnostic, reconstruct req, loop.
      4. If raises with RETRYABLE_TRANSPORT-shaped Error AND idempotent
         method (or opt-in) AND attempts remaining: compute backoff,
         reconstruct req, loop.
      5. Else: re-raise / return.

    The "wait" between attempts is NOT plumbed to a real-time sleep in
    production wait is+ via reactor-timer. The
    BackoffCurve's delay is computed (for diagnostics and to advance
    the RNG state for jitter-determinism tests) but back-to-back retry
    is acceptable in since the LAYER's correctness contract
    (idempotency / max_attempts / classifier / per-request counter) is
    the load-bearing guarantee."""

    var _inner: Self.Inner
    var _policy: RetryPolicy
    var _rng: Self.RngT
    var _last_attempt_count: UInt32
    var _last_planned_delay_us: Int

    @staticmethod
    def wrap(
        var inner: Self.Inner,
        var policy: RetryPolicy,
        var rng: Self.RngT,
    ) -> RetryLayer[Self.Inner, Self.RngT]:
        return RetryLayer[Self.Inner, Self.RngT](
            _inner=inner^,
            _policy=policy^,
            _rng=rng^,
            _last_attempt_count=UInt32(0),
            _last_planned_delay_us=0,
        )

    def __init__(
        out self,
        var _inner: Self.Inner,
        var _policy: RetryPolicy,
        var _rng: Self.RngT,
        _last_attempt_count: UInt32,
        _last_planned_delay_us: Int,
    ):
        self._inner = _inner^
        self._policy = _policy^
        self._rng = _rng^
        self._last_attempt_count = _last_attempt_count
        self._last_planned_delay_us = _last_planned_delay_us

    def layer_name(self) -> String:
        return String("retry")

    @always_inline
    def last_attempt_count(self) -> UInt32:
        """Diagnostic: how many attempts the most recent call spent.
        1 = success on first try; max_attempts = exhausted retries."""
        return self._last_attempt_count

    @always_inline
    def last_planned_delay_us(self) -> Int:
        """Diagnostic: sum of BackoffCurve-computed delays the most
        recent call would have slept (0 if no retries happened)."""
        return self._last_planned_delay_us

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """HttpService.call trait method.

        this trait-required method runs the inner service ONCE
        with no retry replay — the trait-parametric B has no
        general-purpose default constructor in Mojo 1.0.0b1 (RequestBody
        conformers are Movable-not-Copyable; replaying B requires
        Body.replayable).

        For RETRY-ENABLED CALLS, use `call_empty` directly — its
        ClientRequest[EmptyBody] signature has a known-replayable B
        (zero-byte body; request_bytes carries the full wire form).
        ObjectStoreHttp + most idempotent-method use cases (GET / HEAD
        / DELETE / OPTIONS / TRACE) construct ClientRequest[EmptyBody]
        — they are the load-bearing consumers.
        """
        # pass-through with no retry for the B-parametric trait
        # method. Retry replay lives on `call_empty`.
        self._last_attempt_count = UInt32(1)
        self._last_planned_delay_us = 0
        return self._inner.call[RT, C, B](req^, connector, reactor)

    def assert_body_replayable[B: RequestBody](
        self, ref req: ClientRequest[B],
    ) raises:
        """B-parametric pre-flight check. Raises
        HttpError[BODY_NOT_REPLAYABLE] if `req.body` is not replayable.
        Idempotent + no side effects on req.

         fail-loud, callers that want retry semantics on
        B-parametric requests MUST gate their retry attempt on this
        assertion. The full B-parametric retry LOOP (with rewind +
        request re-issue) is — the trait method extension that
        ClientRequest[B] needs (Body.clone_for_replay() so the body
        can be cloned without a default ctor) is more substantial scope
        than this slot's wall.

        For the common idempotent-replay case (B = EmptyBody), use
        `call_empty` directly — the existing replay reconstruction
        path is hardcoded to EmptyBody but functional.
        """
        if not req.body:
            # No body on the request — trivially replayable (empty).
            return
        ref body = req.body.value()
        if not body.replayable():
            raise Error(
                "HttpError[BODY_NOT_REPLAYABLE]: request body is not"
                " replayable (rewind unavailable); use BytesBody or"
                " EmptyBody for retry-eligible requests"
            )

    def call_empty[RT: Runtime, C: Connector](
        mut self,
        var req: ClientRequest[EmptyBody],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """The retry-aware call for ClientRequest[EmptyBody] —
        the idempotent-method-replay path. See struct docstring.
        """
        # Reset per-request counters.
        self._last_attempt_count = UInt32(0)
        self._last_planned_delay_us = 0

        # Stash for replay reconstruction.
        var stashed_method = req.method
        var stashed_url = _clone_url(req.url)
        var stashed_headers = _clone_header_map(req.headers)
        var stashed_request_bytes = _clone_bytes(req.request_bytes)
        # ⛔ STASHED BECAUSE A REBUILD DROPS IT OTHERWISE. A `TimeoutLayer`
        # wrapping THIS layer stamps its deadline on the request that reaches
        # attempt 1; every later attempt runs on a request reconstructed from
        # these stashes, so a budget left out here is a deadline that binds on
        # the first attempt and on none of the retries — the exact "only as
        # good as the last frame that forwards it" shape.
        #
        # ⚠ PER-ATTEMPT, NOT PER-CALL, AND THAT IS THE SAME SCOPE THIS LAYER
        # ALREADY HAD: the carrier is a RELATIVE budget, so attempt N gets the
        # full number and the call total is bounded by `max_attempts x budget`
        # plus the planned backoff. A true call-total would need an ABSOLUTE
        # deadline, which the carrier deliberately is not (see
        # `ClientRequest._request_budget_us`).
        var stashed_budget_us = req.request_budget_us()
        var idempotent = is_idempotent_method(stashed_method)
        var method_retryable = (
            idempotent or self._policy.allow_post_patch_retry
        )

        var max_attempts = Int(self._policy.max_attempts)
        if max_attempts < 1:
            max_attempts = 1

        # First attempt consumes req by move.
        var attempt = 1
        var current_req = req^
        while True:
            self._last_attempt_count = UInt32(attempt)
            # Try the inner service.
            try:
                var resp = self._inner.call[RT, C, EmptyBody](
                    current_req^, connector, reactor,
                )
                # Check retry_on_status_codes for retryable HTTP statuses.
                var status_u16 = UInt16(Int(resp.status))
                if (
                    self._policy.matches_retry_status(status_u16)
                    and method_retryable
                    and attempt < max_attempts
                ):
                    var delay = self._policy.backoff.compute_delay_us[
                        Self.RngT
                    ](attempt, self._rng)
                    self._last_planned_delay_us = (
                        self._last_planned_delay_us + delay
                    )
                    attempt = attempt + 1
                    # Reconstruct request from stashes for next iter.
                    current_req = _reconstruct_empty_request(
                        stashed_method,
                        _clone_url(stashed_url),
                        _clone_header_map(stashed_headers),
                        _clone_bytes(stashed_request_bytes),
                        stashed_budget_us,
                    )
                    continue
                # Success path (or non-retryable status) — return.
                return resp^
            except e:
                # Determine the error kind by message prefix.
                var msg = String(e)
                var is_retryable_kind = (
                    _err_msg_is_retryable_transport(msg)
                )
                if (
                    is_retryable_kind
                    and method_retryable
                    and attempt < max_attempts
                ):
                    var delay = self._policy.backoff.compute_delay_us[
                        Self.RngT
                    ](attempt, self._rng)
                    self._last_planned_delay_us = (
                        self._last_planned_delay_us + delay
                    )
                    attempt = attempt + 1
                    current_req = _reconstruct_empty_request(
                        stashed_method,
                        _clone_url(stashed_url),
                        _clone_header_map(stashed_headers),
                        _clone_bytes(stashed_request_bytes),
                        stashed_budget_us,
                    )
                    continue
                # Not retryable — propagate the exact message.
                raise Error(msg)


# =============================================================================
# §5 — Clone helpers + replay reconstruction.
# =============================================================================
#
# ClientRequest[B] consumes its members by move, so the layer cannot
# re-pass the same object. We deep-copy each owned member for the stash
# and re-clone per retry attempt.
#
# Replay reconstruction (`_reconstruct_request_for_retry[B]`) requires
# constructing a default B. for now, only B = EmptyBody is supported
# via a Mojo `__type_of` check at compile time. Other B parameters
# (BytesBody, StreamingBody) will fail to compile this helper; the
# RetryLayer's `call` method will then surface the original error
# without retrying — the "fail loud" path


def _clone_bytes(ref src: List[UInt8]) -> List[UInt8]:
    """Deep-copy a List[UInt8]."""
    var out = List[UInt8]()
    var n = src.__len__()
    var i = 0
    while i < n:
        out.append(src[i])
        i = i + 1
    return out^


def _clone_url(ref src: Url) -> Url:
    """Deep-copy a Url. Uses the 4-arg ctor (scheme/host/port/path),
    then assigns the optional fields (userinfo/query/fragment) post-
    construction to fully preserve all 7 fields."""
    var out = Url(
        scheme=String(src.scheme),
        host=String(src.host),
        port=src.port,
        path=String(src.path),
    )
    out.userinfo = String(src.userinfo)
    out.query = String(src.query)
    out.fragment = String(src.fragment)
    return out^


def _clone_header_map(ref src: HeaderMap) raises -> HeaderMap:
    """Deep-copy a HeaderMap. `raises` propagates from HeaderMap.append
    """
    var out = HeaderMap()
    var n = src.len()
    var i = 0
    while i < n:
        var entry = src.entry_at(i)
        out.append(String(entry.name), String(entry.value))
        i = i + 1
    return out^


def _reconstruct_empty_request(
    method: HttpMethod,
    var url: Url,
    var headers: HeaderMap,
    var request_bytes: List[UInt8],
    request_budget_us: Int,
) -> ClientRequest[EmptyBody]:
    """Reconstruct a ClientRequest[EmptyBody] for a retry attempt.

    contract: retry replay is hardcoded to EmptyBody requests.
    The body bytes (if any) live in `request_bytes` which carries the
    wire form (post-build, the body has already been serialized into
    request_bytes per the buffered shape — see service.mojo,
    `ClientRequest`).

    StreamingBody-aware retry is a follow-up via Body.replayable +
    Body.clone_for_replay trait hooks.

    ⚠ `request_budget_us` IS A REQUIRED PARAMETER, NOT A DEFAULTED ONE. A
    default of 0 here would make "I forgot to carry the deadline" and "this
    request states no deadline" the same call, which is the absent-vs-empty
    trap. There are two call sites and both
    must say what the replayed attempt is allowed to spend."""
    var out = ClientRequest[EmptyBody](
        method=method,
        url=url^,
        headers=headers^,
        request_bytes=request_bytes^,
        body=EmptyBody.new(),
    )
    out.set_request_budget_us(request_budget_us)
    return out^


# =============================================================================
# §6 — Error-kind extraction from the raised Error message.
# =============================================================================


def _err_msg_is_retryable_transport(ref msg: String) -> Bool:
    """Return True iff `msg` starts with the RETRYABLE_TRANSPORT
    HttpError prefix.

    Contract: HttpError-raising sites format `Error` messages as
       'HttpError[KIND]: ...detail...'
    We match the prefix substring."""
    var needle = String("HttpError[RETRYABLE_TRANSPORT]")
    return _str_starts_with(msg, needle)


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
