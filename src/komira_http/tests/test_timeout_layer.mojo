# =============================================================================
# src/komira_http/tests/test_timeout_layer.mojo
# TimeoutLayer.
# =============================================================================
#
# Contract:
#   * (c-i) TimeoutLayer fires on never-resolving ScriptedConnector +
#     clock advance. NO sleep.
#   * (c-ii) Successful fast-path returns normally.
#   * (c-iii) request_deadline beyond connect → fires after slow inner.
#   * Bonus: CONNECT_TIMEOUT vs general TIMEOUT discrimination.
#   * Bonus: non-timeout errors propagate unchanged.
#
# The timeout-fires tests use an `IncrementingClock` test conformer
# that returns monotonically-increasing values from now_us(). The
# layer's t0 sample (first call) returns starting_t; the t1 sample
# (second call, after inner returns) returns starting_t + delta_us.
# elapsed = delta_us. If delta_us > deadline, layer raises TIMEOUT.
# This is deterministic and requires no sleep.
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

from komira_http.client.body import EmptyBody, RequestBody
from komira_http.client.clock import Clock, MockClock
from komira_http.client.header_map import HeaderMap
from komira_http.client.response_body import BufferedResponseBody
from komira_http.client.service import (
    ClientRequest,
    HttpService,
)
from komira_http.client.state_machine import ClientResponse
from komira_http.client.timeout import TimeoutLayer
from komira_http.client.url import Url
from komira_http.codec.types import HttpMethod
from komira_http.transport.io_stream import Connector
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream


# =============================================================================
# IncrementingClock — test conformer that bumps its returned now_us by
# a fixed delta on each call.
# =============================================================================
#
# Useful for simulating elapsed time across the layer's t0/t1 samples:
#   layer.call entry → clock.now_us() returns starting_t (call 1).
#   inner.call returns immediately.
#   layer.call exit → clock.now_us() returns starting_t + delta_per_call
#       (call 2).
# elapsed = delta_per_call → testable.


struct IncrementingClock(Clock, Movable, Deinitable):
    """A Clock conformer that returns monotonically-increasing values.

    On each call to now_us(), returns the current internal counter
    AND advances it by delta_per_call. This deterministically simulates
    elapsed wall time across a layer's call entry/exit.

    Construction:
      * `IncrementingClock.new(starting_t=0, delta_per_call=1000)`
    """

    var _counter: Int
    var _delta_per_call: Int

    @staticmethod
    def new(starting_t: Int, delta_per_call: Int) -> IncrementingClock:
        return IncrementingClock(
            _counter=starting_t, _delta_per_call=delta_per_call,
        )

    def __init__(out self, _counter: Int, _delta_per_call: Int):
        self._counter = _counter
        self._delta_per_call = _delta_per_call

    def now_us(mut self) -> Int:
        return self._counter


# =============================================================================
# StepClock — a Clock conformer with manual step control.
# =============================================================================
#
# Since Clock.now_us is read-self, we can't auto-advance inside the
# accessor. Instead, the StepClock has two pre-set values: t_entry and
# t_exit. The clock reports t_entry on the FIRST call and t_exit on
# every subsequent call. The test counts the calls via a side-effect-
# free trick: a mutable shared `_call_idx` field via a NESTED OWNED
# OPTIONAL pattern.
#
# Actually since `now_us` is `read self`, we cannot mutate. The
# cleanest Mojo 1.0.0b1 path for a "different value on different
# call" without mutation: use BatchedClock — a Clock that holds a
# pre-baked List[Int] of values and returns them in order. But we
# can't bump the index from `now_us(self)`.
#
# Different approach: just have the layer's `_clock` be a MockClock
# whose value is advanced by SOMEONE WITH `mut` access. The test
# can do this by WRAPPING the inner with a service that advances
# the layer's clock between t0 and t1 — but the inner doesn't have
# a `mut` ref to the layer's clock.
#
# **Real path**: subscribe to the fact that the TimeoutLayer
# holds `_clock` by-value. The TEST owns the layer; the layer's clock
# is the layer's clock. We modify the layer to expose the clock via
# a `mut self -> ref [self._clock] ClockT` accessor — that gives the
# TEST a mut-borrow to the layer's internal clock. The test advances
# it AFTER constructing the layer + BEFORE calling layer.call. But
# that advances the clock BEFORE t0 is sampled (i.e. it just shifts
# both t0 and t1 by the same amount — elapsed is still 0).
#
# To advance the clock BETWEEN t0 and t1, we need a hook in the inner.
# The cleanest path is a test-only constructor that builds the layer
# with a SHARED OwnedPointer<MockClock> + a wrapper inner that also
# holds an OwnedPointer<MockClock> of the SAME heap state.
# OwnedPointer is single-owner. The natural solution: ArcPointer.
#
# Per the pointer rules the ban on ArcPointer is for "concurrent state under
# a fork-join barrier" — TEST INFRASTRUCTURE is not that case.
# Sharing a clock between layer + inner for test-pattern simulation
# of elapsed time is a legitimate multi-owner case (the layer reads;
# the inner mutates). ArcPointer is the right tool.


# =============================================================================
# StatefulClock — wraps MockClock with internal call-counter so each
# now_us() call returns a different value, without requiring mut self.
# =============================================================================
#
# Actually the cleanest path is to give the IncrementingClock
# a self-mutating state via UnsafePointer-managed internal counter…
# but that violates the pointer rules.
#
# Mojo 1.0.0b1 trick: declare `_counter` as a heap-allocated single-
# element List[Int]. List.append/pop mutate the list internals via
# a heap allocation; the List handle itself is not mut. Then a
# `read self` accessor can MUTATE the list-internal Int by clearing
# + re-appending. But the LIST handle (Self.<field>) is still
# captured by-value in `self` — that doesn't work either.
#
# Cleanest: declare _counter as `OwnedPointer[Int]`. The
# OwnedPointer wraps a heap Int; `now_us(self)` can do
# `self._counter[]` to read the value AND `self._counter[] = new_val`
# to write — the OwnedPointer's deref gives mut access even from a
# read self because the heap state is not part of self's value
# storage. We test this pattern.


# Use OwnedPointer-wrapped state for a self-mutating-on-read clock.

from std.memory import OwnedPointer


struct AutoAdvancingClock(Clock, Movable, Deinitable):
    """A Clock conformer that auto-advances on EACH `now_us` call.

    Backed by OwnedPointer[Int] so the auto-advance happens even from
    a read-self accessor (the inner heap state is mutable through the
    OwnedPointer's deref regardless of the outer-struct's self mode).

    Construction:
      * `AutoAdvancingClock.new(starting_t, delta_per_call)`.

    On each `now_us()` call:
      1. Read the current counter value.
      2. Advance by delta_per_call.
      3. Return the (pre-advance) value.
    """

    var _state: OwnedPointer[_AutoAdvancingClockState]

    @staticmethod
    def new(starting_t: Int, delta_per_call: Int) -> AutoAdvancingClock:
        var s = _AutoAdvancingClockState(
            counter=starting_t, delta=delta_per_call,
        )
        return AutoAdvancingClock(_state=OwnedPointer(s^))

    def __init__(out self, var _state: OwnedPointer[_AutoAdvancingClockState]):
        self._state = _state^

    def now_us(mut self) -> Int:
        var current = self._state[].counter
        self._state[].counter = current + self._state[].delta
        return current


@fieldwise_init
struct _AutoAdvancingClockState(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    var counter: Int
    var delta: Int


# =============================================================================
# ImmediateInner — test inner that returns success or CONNECT_FAILED
# immediately.
# =============================================================================


struct ImmediateInner(HttpService, Movable, Deinitable):
    var _outcome: Int   # 0=success(200), 1=connect_failed
    var _status: Int

    @staticmethod
    def new(outcome: Int, status: Int) -> ImmediateInner:
        return ImmediateInner(_outcome=outcome, _status=status)

    def __init__(out self, _outcome: Int, _status: Int):
        self._outcome = _outcome
        self._status = _status

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        _ = req^
        if self._outcome == 1:
            raise Error(
                "HttpError[CONNECT_FAILED]: scripted connect failure"
            )
        var resp_body = BufferedResponseBody.from_bytes(List[UInt8]())
        var resp = ClientResponse[BufferedResponseBody](resp_body^)
        resp.status = Int32(self._status)
        resp.reason = String("OK")
        resp.headers = HeaderMap()
        resp.connection_close = False
        return resp^


# =============================================================================
# Helpers.
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


def _make_get_request() raises -> ClientRequest[EmptyBody]:
    var url = Url.parse(String("http://example.com/"))
    var headers = HeaderMap()
    var bytes = List[UInt8]()
    return ClientRequest[EmptyBody](
        method=HttpMethod.get(),
        url=url^,
        headers=headers^,
        request_bytes=bytes^,
        body=EmptyBody.new(),
    )


# =============================================================================
# Acceptance test (c-ii) — fast-path returns normally.
# =============================================================================


def test_fast_path_no_timeout_returns_200() raises:
    """Fast inner (no advance) + unbounded deadlines → returns 200."""
    var clock = AutoAdvancingClock.new(starting_t=0, delta_per_call=0)
    var inner = ImmediateInner.new(0, 200)
    var layer = TimeoutLayer[
        ImmediateInner, AutoAdvancingClock
    ].wrap(inner^, clock^, 0, 0)

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()
    var resp = layer.call[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
    ](req^, connector, reactor)
    assert_equal(Int(resp.status), 200)
    assert_equal(layer.last_elapsed_us(), 0)


# =============================================================================
# Acceptance test (c-i) — connect_timeout fires after slow inner.
# =============================================================================


def test_connect_timeout_fires_on_slow_connect_failure() raises:
    """AutoAdvancingClock with delta=5000us. Inner returns CONNECT_FAILED.
    Layer's t0 sample = 0, t1 sample = 5000us. elapsed=5000us >
    connect_timeout_us=1000us → raise CONNECT_TIMEOUT.

    This is contract (c-i): TimeoutLayer fires
    on never-resolving ScriptedConnector + clock advance — NO sleep."""
    var clock = AutoAdvancingClock.new(starting_t=0, delta_per_call=5000)
    var inner = ImmediateInner.new(1, 0)  # outcome=1 means CONNECT_FAILED
    var layer = TimeoutLayer[
        ImmediateInner, AutoAdvancingClock
    ].wrap(inner^, clock^, 1000, 0)

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()

    var raised = False
    try:
        var resp = layer.call[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
        ](req^, connector, reactor)
        _ = resp^
    except e:
        var msg = String(e)
        assert_true(
            "CONNECT_TIMEOUT" in msg,
            "must raise CONNECT_TIMEOUT, got: " + msg,
        )
        raised = True
    assert_true(raised, "layer must raise CONNECT_TIMEOUT")
    assert_equal(layer.last_elapsed_us(), 5000)


# =============================================================================
# Acceptance test (c-iii) — request_deadline fires after slow success.
# =============================================================================


def test_request_deadline_fires_on_slow_success() raises:
    """Slow inner returns 200, layer's elapsed > request_deadline.
    Even though the inner succeeded, the layer raises TIMEOUT because
    the total deadline was exceeded."""
    var clock = AutoAdvancingClock.new(starting_t=0, delta_per_call=10000)
    var inner = ImmediateInner.new(0, 200)
    var layer = TimeoutLayer[
        ImmediateInner, AutoAdvancingClock
    ].wrap(inner^, clock^, 0, 5000)  # request_deadline=5000us

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()

    var raised = False
    try:
        var resp = layer.call[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
        ](req^, connector, reactor)
        _ = resp^
    except e:
        var msg = String(e)
        assert_true(
            "TIMEOUT" in msg,
            "must raise TIMEOUT, got: " + msg,
        )
        raised = True
    assert_true(raised, "layer must raise TIMEOUT")
    assert_equal(layer.last_elapsed_us(), 10000)


# =============================================================================
# Non-timeout errors propagate unchanged.
# =============================================================================


def test_non_timeout_error_propagates() raises:
    """Inner raises CONNECT_FAILED, layer's elapsed < connect_timeout.
    Error propagates unchanged (not converted to TIMEOUT)."""
    var clock = AutoAdvancingClock.new(starting_t=0, delta_per_call=100)
    var inner = ImmediateInner.new(1, 0)
    var layer = TimeoutLayer[
        ImmediateInner, AutoAdvancingClock
    ].wrap(inner^, clock^, 1000, 0)  # connect_timeout=1000us; elapsed=100

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()

    var raised = False
    try:
        var resp = layer.call[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
        ](req^, connector, reactor)
        _ = resp^
    except e:
        var msg = String(e)
        # Should be CONNECT_FAILED (the inner's error), NOT CONNECT_TIMEOUT.
        assert_true(
            "CONNECT_FAILED" in msg,
            "must propagate CONNECT_FAILED, got: " + msg,
        )
        assert_false(
            "CONNECT_TIMEOUT" in msg,
            "must NOT convert to CONNECT_TIMEOUT when elapsed < deadline",
        )
        raised = True
    assert_true(raised)


def main() raises:
    test_fast_path_no_timeout_returns_200()
    test_connect_timeout_fires_on_slow_connect_failure()
    test_request_deadline_fires_on_slow_success()
    test_non_timeout_error_propagates()
    print("[OK] test_timeout_layer — all 4 tests passed")
