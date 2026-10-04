# =============================================================================
# src/komira_http_client/tests/test_retry_layer.mojo
# RetryLayer + RetryPolicy + BackoffCurve.
# =============================================================================
#
# Contract:
#   (a-i)   idempotent (GET/HEAD/PUT/DELETE) retried on RETRYABLE_TRANSPORT
#   (a-ii)  non-idempotent (POST/PATCH) NOT retried by default
#   (a-iii) per-request counter resets on each new call
#   (a-iv)  deterministic backoff via DeterministicRng over the BackoffCurve
#   (a-v)   custom RetryPolicy with retry_on_status_codes triggers retry
#
# The tests use a `ScriptedHttpService` test-conformer that scripts a
# sequence of (success / failure / status) outcomes per call. This is
# the standard mocking idiom; ScriptedConnector is for the IoStream
# layer, but the LAYER itself wraps an HttpService — so the test
# conformer is an HttpService that returns canned outcomes deterministically.
#
# This is a Tier-2 (small/medium) test running over
# deterministic mocks — no sockets, no real HTTP round-trip.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import EmptyBody, RequestBody
from komira_http_client.clock import DeterministicRng
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.retry import (
    BackoffCurve,
    RetryLayer,
    RetryPolicy,
    is_idempotent_method,
)
from komira_http_client.service import (
    ClientRequest,
    HttpService,
)
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


# =============================================================================
# ScriptedHttpService — test conformer.
# =============================================================================
#
# A scripted inner service that returns one outcome per call:
#   * outcome=0 → return ClientResponse with status code from outcomes[i].
#   * outcome=1 → raise HttpError[RETRYABLE_TRANSPORT].
#   * outcome=2 → raise HttpError[STATUS_LINE_INVALID] (non-retryable).
#
# Used to script the inner.call sequence deterministically.


struct ScriptedHttpService(
    HttpService, Movable, Deinitable,
):
    var _outcomes: List[Int]    # 0=success, 1=retryable, 2=non-retryable
    var _statuses: List[Int]    # status code per outcome (used iff outcome=0)
    var _call_count: Int

    @staticmethod
    def new(
        var outcomes: List[Int], var statuses: List[Int],
    ) -> ScriptedHttpService:
        return ScriptedHttpService(
            _outcomes=outcomes^, _statuses=statuses^, _call_count=0,
        )

    def __init__(
        out self,
        var _outcomes: List[Int],
        var _statuses: List[Int],
        _call_count: Int,
    ):
        self._outcomes = _outcomes^
        self._statuses = _statuses^
        self._call_count = _call_count

    def call_count(self) -> Int:
        return self._call_count

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        var idx = self._call_count
        self._call_count = self._call_count + 1
        if idx >= self._outcomes.__len__():
            raise Error(
                "HttpError[STATUS_LINE_INVALID]: scripted outcomes "
                "exhausted (call #" + String(idx) + ")"
            )
        var outcome = self._outcomes[idx]
        if outcome == 1:
            raise Error(
                "HttpError[RETRYABLE_TRANSPORT]: scripted retryable "
                "transient (call #" + String(idx) + ")"
            )
        if outcome == 2:
            raise Error(
                "HttpError[STATUS_LINE_INVALID]: scripted non-retryable "
                "(call #" + String(idx) + ")"
            )
        # outcome==0 → success with the scripted status.
        var status = self._statuses[idx]
        var resp_body = BufferedResponseBody.from_bytes(List[UInt8]())
        var resp = ClientResponse[BufferedResponseBody](resp_body^)
        resp.status = Int32(status)
        resp.reason = String("Scripted")
        resp.headers = HeaderMap()
        resp.connection_close = False
        # Consume req so the trait method signature is honored.
        _ = req^
        return resp^


# =============================================================================
# Test helpers.
# =============================================================================


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _make_connector() -> ScriptedConnector:
    var stream = ScriptedStream.empty()
    return ScriptedConnector.with_stream(stream^)


def _make_get_request() -> ClientRequest[EmptyBody]:
    var url = Url.http(String("example.com"), UInt16(80), String("/"))
    var headers = HeaderMap()
    var req_bytes = List[UInt8]()
    return ClientRequest[EmptyBody](
        method=HttpMethod.get(),
        url=url^,
        headers=headers^,
        request_bytes=req_bytes^,
        body=EmptyBody.new(),
    )


def _make_post_request() -> ClientRequest[EmptyBody]:
    var url = Url.http(String("example.com"), UInt16(80), String("/"))
    var headers = HeaderMap()
    var req_bytes = List[UInt8]()
    return ClientRequest[EmptyBody](
        method=HttpMethod.post(),
        url=url^,
        headers=headers^,
        request_bytes=req_bytes^,
        body=EmptyBody.new(),
    )


# =============================================================================
# Acceptance test (a-i) — idempotent retry succeeds after transient.
# =============================================================================


def test_idempotent_get_retries_on_retryable_transport() raises:
    """GET with sequence [retryable, retryable, success(200)] → final
    status=200, attempts=3, per-request counter = 3."""
    var outcomes = List[Int]()
    outcomes.append(1)  # transient
    outcomes.append(1)  # transient
    outcomes.append(0)  # success
    var statuses = List[Int]()
    statuses.append(0)
    statuses.append(0)
    statuses.append(200)
    var inner = ScriptedHttpService.new(outcomes^, statuses^)
    var policy = RetryPolicy.defaults()
    var rng = DeterministicRng.from_seed(UInt64(42))
    var layer = RetryLayer[ScriptedHttpService, DeterministicRng].wrap(
        inner^, policy^, rng^,
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()

    var resp = layer.call_empty[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        req^, connector, reactor,
    )
    assert_equal(Int(resp.status), 200, "final status should be 200")
    assert_equal(
        Int(layer.last_attempt_count()), 3,
        "should have spent 3 attempts (2 retries)",
    )


# =============================================================================
# Acceptance test (a-ii) — POST not retried by default.
# =============================================================================


def test_post_not_retried_by_default() raises:
    """POST with sequence [retryable] → raises after first attempt
    because POST is non-idempotent and allow_post_patch_retry=False."""
    var outcomes = List[Int]()
    outcomes.append(1)
    var statuses = List[Int]()
    statuses.append(0)
    var inner = ScriptedHttpService.new(outcomes^, statuses^)
    var policy = RetryPolicy.defaults()
    var rng = DeterministicRng.from_seed(UInt64(42))
    var layer = RetryLayer[ScriptedHttpService, DeterministicRng].wrap(
        inner^, policy^, rng^,
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_post_request()

    var raised = False
    try:
        var resp = layer.call_empty[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
            req^, connector, reactor,
        )
        _ = resp^
    except e:
        var msg = String(e)
        assert_true(
            "RETRYABLE_TRANSPORT" in msg,
            "raised message must mention RETRYABLE_TRANSPORT, got: " + msg,
        )
        raised = True
    assert_true(raised, "POST must raise on first retryable error")
    assert_equal(
        Int(layer.last_attempt_count()), 1,
        "POST must have spent exactly 1 attempt (no retry)",
    )


# =============================================================================
# Acceptance test (a-ii-b) — POST retried when allow_post_patch_retry=True.
# =============================================================================


def test_post_retried_with_explicit_opt_in() raises:
    """With allow_post_patch_retry=True, POST gets retried."""
    var outcomes = List[Int]()
    outcomes.append(1)
    outcomes.append(0)
    var statuses = List[Int]()
    statuses.append(0)
    statuses.append(201)  # POST often returns 201 Created
    var inner = ScriptedHttpService.new(outcomes^, statuses^)
    var policy = RetryPolicy(
        max_attempts=UInt32(3),
        backoff=BackoffCurve.defaults(),
        retry_on_status_codes=List[UInt16](),
        allow_post_patch_retry=True,
    )
    var rng = DeterministicRng.from_seed(UInt64(42))
    var layer = RetryLayer[ScriptedHttpService, DeterministicRng].wrap(
        inner^, policy^, rng^,
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_post_request()

    var resp = layer.call_empty[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        req^, connector, reactor,
    )
    assert_equal(Int(resp.status), 201)
    assert_equal(Int(layer.last_attempt_count()), 2)


# =============================================================================
# Acceptance test (a-iii) — per-request counter resets.
# =============================================================================


def test_per_request_counter_resets_on_each_call() raises:
    """Two successive calls — the second's last_attempt_count reflects
    only the second call, not cumulative."""
    var outcomes = List[Int]()
    outcomes.append(1)  # call 1: retryable
    outcomes.append(0)  # call 1: success
    outcomes.append(0)  # call 2: success immediately
    var statuses = List[Int]()
    statuses.append(0)
    statuses.append(200)
    statuses.append(200)
    var inner = ScriptedHttpService.new(outcomes^, statuses^)
    var policy = RetryPolicy.defaults()
    var rng = DeterministicRng.from_seed(UInt64(42))
    var layer = RetryLayer[ScriptedHttpService, DeterministicRng].wrap(
        inner^, policy^, rng^,
    )

    var reactor = _make_reactor()
    var connector = _make_connector()

    # First call — 2 attempts.
    var req1 = _make_get_request()
    var resp1 = layer.call_empty[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        req1^, connector, reactor,
    )
    assert_equal(Int(resp1.status), 200)
    assert_equal(Int(layer.last_attempt_count()), 2)
    _ = resp1^

    # Second call — 1 attempt (resets).
    var req2 = _make_get_request()
    var resp2 = layer.call_empty[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        req2^, connector, reactor,
    )
    assert_equal(Int(resp2.status), 200)
    assert_equal(
        Int(layer.last_attempt_count()), 1,
        "counter must reset to 1 on new call (not cumulate)",
    )


# =============================================================================
# Acceptance test (a-iv) — deterministic backoff via DeterministicRng.
# =============================================================================


def test_deterministic_backoff_curve() raises:
    """Two RetryLayer instances with the SAME seed produce
    byte-identical planned-delay sequences."""
    # Build identical scripts: 2 retries then success.
    def _build_layer(
        seed: UInt64,
    ) -> RetryLayer[ScriptedHttpService, DeterministicRng]:
        var outcomes = List[Int]()
        outcomes.append(1)
        outcomes.append(1)
        outcomes.append(0)
        var statuses = List[Int]()
        statuses.append(0)
        statuses.append(0)
        statuses.append(200)
        var inner = ScriptedHttpService.new(outcomes^, statuses^)
        var policy = RetryPolicy.defaults()
        var rng = DeterministicRng.from_seed(seed)
        return RetryLayer[ScriptedHttpService, DeterministicRng].wrap(
            inner^, policy^, rng^,
        )

    var layer_a = _build_layer(UInt64(12345))
    var layer_b = _build_layer(UInt64(12345))

    var reactor_a = _make_reactor()
    var connector_a = _make_connector()
    var req_a = _make_get_request()
    var resp_a = layer_a.call_empty[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](req_a^, connector_a, reactor_a)
    _ = resp_a^

    var reactor_b = _make_reactor()
    var connector_b = _make_connector()
    var req_b = _make_get_request()
    var resp_b = layer_b.call_empty[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](req_b^, connector_b, reactor_b)
    _ = resp_b^

    # Same seed → same backoff sum.
    assert_equal(
        layer_a.last_planned_delay_us(),
        layer_b.last_planned_delay_us(),
        "deterministic RNG must produce identical backoff totals",
    )
    assert_true(
        layer_a.last_planned_delay_us() > 0,
        "with 2 retries, the planned-delay total must be > 0",
    )


# =============================================================================
# Acceptance test (a-v) — custom RetryPolicy with retry_on_status_codes.
# =============================================================================


def test_custom_retry_on_status_codes() raises:
    """Custom RetryPolicy with retry_on_status_codes=[503, 429]:
    sequence [success(503), success(503), success(200)] → final 200
    after 3 attempts. The status-retry branch fires."""
    var outcomes = List[Int]()
    outcomes.append(0)
    outcomes.append(0)
    outcomes.append(0)
    var statuses = List[Int]()
    statuses.append(503)
    statuses.append(503)
    statuses.append(200)
    var inner = ScriptedHttpService.new(outcomes^, statuses^)
    var retry_codes = List[UInt16]()
    retry_codes.append(UInt16(503))
    retry_codes.append(UInt16(429))
    var policy = RetryPolicy(
        max_attempts=UInt32(3),
        backoff=BackoffCurve.defaults(),
        retry_on_status_codes=retry_codes^,
        allow_post_patch_retry=False,
    )
    var rng = DeterministicRng.from_seed(UInt64(42))
    var layer = RetryLayer[ScriptedHttpService, DeterministicRng].wrap(
        inner^, policy^, rng^,
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()

    var resp = layer.call_empty[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        req^, connector, reactor,
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(Int(layer.last_attempt_count()), 3)


# =============================================================================
# Idempotency table — confirm GET/HEAD/etc. classification.
# =============================================================================


def test_idempotency_table() raises:
    assert_true(is_idempotent_method(HttpMethod.get()))
    assert_true(is_idempotent_method(HttpMethod.put()))
    assert_true(is_idempotent_method(HttpMethod.delete()))
    assert_false(is_idempotent_method(HttpMethod.post()))


# =============================================================================
# BackoffCurve unit tests.
# =============================================================================


def test_backoff_curve_attempt_1_is_base() raises:
    """attempt=1 → delay ≈ base ± jitter. With jitter=25%, the range
    is [base*0.75, base*1.25]."""
    var curve = BackoffCurve.defaults()  # base=100ms, jitter=25%
    var rng = DeterministicRng.from_seed(UInt64(12345))
    var d = curve.compute_delay_us[DeterministicRng](1, rng)
    # base=100_000, jitter band=25_000 → range [75_000, 125_000]
    assert_true(d >= 75_000, "delay must be >= base - jitter; got " + String(d))
    assert_true(d <= 125_000, "delay must be <= base + jitter; got " + String(d))


def test_backoff_curve_attempt_grows_exponentially() raises:
    """attempt=2 should yield delay roughly 2x attempt=1 (modulo jitter)."""
    var curve = BackoffCurve.defaults()
    # No jitter to make the comparison exact.
    var curve_no_jitter = BackoffCurve(
        base_delay_us=100_000,
        multiplier_x100=200,
        max_delay_us=10_000_000,
        jitter_frac_x100=0,
    )
    var rng = DeterministicRng.from_seed(UInt64(1))
    var d1 = curve_no_jitter.compute_delay_us[DeterministicRng](1, rng)
    var d2 = curve_no_jitter.compute_delay_us[DeterministicRng](2, rng)
    var d3 = curve_no_jitter.compute_delay_us[DeterministicRng](3, rng)
    assert_equal(d1, 100_000)
    assert_equal(d2, 200_000)
    assert_equal(d3, 400_000)


def test_backoff_curve_caps_at_max() raises:
    """With max_delay=1s and aggressive growth, a high attempt count
    should saturate at the cap."""
    var curve = BackoffCurve(
        base_delay_us=1_000_000,
        multiplier_x100=400,  # 4x
        max_delay_us=2_000_000,  # 2s cap
        jitter_frac_x100=0,
    )
    var rng = DeterministicRng.from_seed(UInt64(1))
    var d10 = curve.compute_delay_us[DeterministicRng](10, rng)
    assert_equal(d10, 2_000_000, "must cap at max_delay_us")


def main() raises:
    test_idempotent_get_retries_on_retryable_transport()
    test_post_not_retried_by_default()
    test_post_retried_with_explicit_opt_in()
    test_per_request_counter_resets_on_each_call()
    test_deterministic_backoff_curve()
    test_custom_retry_on_status_codes()
    test_idempotency_table()
    test_backoff_curve_attempt_1_is_base()
    test_backoff_curve_attempt_grows_exponentially()
    test_backoff_curve_caps_at_max()
    print("[OK] test_retry_layer — all 10 tests passed")
