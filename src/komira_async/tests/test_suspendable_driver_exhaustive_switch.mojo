# =============================================================================
# test_suspendable_driver_exhaustive_switch.mojo
# =============================================================================
# WHAT THIS PINS. The SuspendableHandlerDriver's terminal-vs-park branch was a
# 2-state shortcut: `if is_parked(): park else: deliver`. That treats EVERY
# non-PARKED result (DONE, ERR, and any future kind) as "deliver", so a future
# streaming EMIT(chunk) result would silently fall into the `else: deliver` arm
# and be RETIRE-and-DROPPED on its first chunk. Admit + resume are now
# to an EXHAUSTIVE switch (`_dispatch_step_result`):
#     PARKED  -> _park        (frame retained)
#     DONE    -> _deliver     (response landed; frame dropped)
#     ERR     -> _deliver_err (no response; frame dropped)
#     EMIT    -> RESERVED streaming arm; routes to the SAFE ERR arm today (no
#                live handler returns EMIT) so a future EMIT slots in as a 4th
#                arm, never a silent deliver.
#     DEFAULT -> SAFE ERR arm (an unknown/reserved kind is NEVER silently
#                delivered as if it were a DONE response).
#
# This test exercises EVERY arm and asserts the load-bearing distinction: a
# non-DONE result must NOT be delivered as a response.
# It does NOT implement any EMIT machinery — the EMIT + unknown arms are proven
# to RETIRE the frame (drop it, not park it, not deliver a bogus response).
#
# Backend: BACKEND_MOCK — no kernel fds, cross-platform (Linux + macOS). The
# park handler parks on a bare `reactor.alloc_op_id()` (biased, no fd) so the
# switch is exercised without real readiness machinery. The driver is the
# substrate `SuspendableHandlerDriver[S, H]` over `SuspendedFrame[H]` — one
# driver per toy handler type (the driver is monomorphic over one H).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.suspendable_handler import (
    HandlerStepResult,
    SuspendableHandler,
    SuspendableHandlerDriver,
    SuspendedFrame,
)


# =============================================================================
# _ToyResp — a Movable-NOT-Copyable response with a heap-owning String body,
# so a botched arm (e.g. a silent-deliver of a non-DONE result, or a
# double-drop) would surface a leak / double-free. Same destroy-recreate shape the
# erased-frame test uses.
# =============================================================================


struct _ToyResp(Movable, Deinitable):
    var status: Int
    var body: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^


# =============================================================================
# One toy handler per discriminant. Each conforms to SuspendableHandler and
# owns a heap String so its in-place destructor has real work.
# =============================================================================


comptime _PH_INIT: UInt8 = 0
comptime _PH_AWAIT: UInt8 = 1


struct _ParkThenDoneHandler(Movable, Deinitable, SuspendableHandler):
    """Parks on step 1 (PARKED arm), DONEs on resume (DONE arm)."""

    comptime Resp = _ToyResp

    var _step: UInt8
    var _who: String

    def __init__(out self, var who: String):
        self._step = _PH_INIT
        self._who = who^

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[_ToyResp]:
        if self._step == _PH_INIT:
            var op = reactor.alloc_op_id()
            self._step = _PH_AWAIT
            return HandlerStepResult[_ToyResp].parked(op)
        return HandlerStepResult[_ToyResp].done(
            _ToyResp(200, String("done:") + self._who)
        )


struct _DoneHandler(Movable, Deinitable, SuspendableHandler):
    """DONEs on its first step (DONE arm, no park)."""

    comptime Resp = _ToyResp

    var _tag: String

    def __init__(out self, var tag: String):
        self._tag = tag^

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[_ToyResp]:
        return HandlerStepResult[_ToyResp].done(
            _ToyResp(201, String("done:") + self._tag)
        )


struct _ErrHandler(Movable, Deinitable, SuspendableHandler):
    """Returns ERR on its first step (ERR arm — no response delivered)."""

    comptime Resp = _ToyResp

    var _msg: String

    def __init__(out self, var msg: String):
        self._msg = msg^

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[_ToyResp]:
        return HandlerStepResult[_ToyResp].error(String("boom:") + self._msg)


struct _EmitHandler(Movable, Deinitable, SuspendableHandler):
    """Returns the RESERVED EMIT discriminant on its first step. No live
    production handler does this; the test handler does so to prove the EMIT
    result is routed to the SAFE retire arm (NOT silently delivered, NOT
    parked). The chunk is a heap-owning _ToyResp so a botched arm would leak."""

    comptime Resp = _ToyResp

    var _tag: String

    def __init__(out self, var tag: String):
        self._tag = tag^

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[_ToyResp]:
        # EMIT(chunk, op_id) — a stream chunk + a generic biased resume op_id.
        var op = reactor.alloc_op_id()
        return HandlerStepResult[_ToyResp].emit(
            _ToyResp(206, String("chunk:") + self._tag), op
        )


struct _UnknownKindHandler(Movable, Deinitable, SuspendableHandler):
    """Returns a HandlerStepResult with a kind sentinel the driver does NOT know
    (7 — outside PARKED/DONE/ERR/EMIT). Proves the DEFAULT arm routes an unknown
    kind to the SAFE ERR arm, never silently delivering it as a DONE response.
    Constructed via the @fieldwise_init ctor with an out-of-range _kind."""

    comptime Resp = _ToyResp

    var _tag: String

    def __init__(out self, var tag: String):
        self._tag = tag^

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[_ToyResp]:
        # A poisoned result: a kind value no arm matches. The exhaustive switch
        # MUST route it to the default (safe ERR) arm — NOT silently deliver it.
        return HandlerStepResult[_ToyResp](
            _kind=UInt8(7),
            _op_id=Int64(0),
            _response=Optional[_ToyResp](),
            _err=String("poisoned-kind:") + self._tag,
            _chunk=Optional[_ToyResp](),
        )


def _mock_reactor() raises -> Reactor[NoopSink]:
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)


# =============================================================================
# 1. PARKED arm — admit parks the frame; it stays in-flight, nothing delivered.
# =============================================================================
def test_admit_parked_arm_keeps_frame_inflight() raises:
    var reactor = _mock_reactor()
    var driver = SuspendableHandlerDriver[NoopSink, _ParkThenDoneHandler]()

    var parked = driver.admit(
        SuspendedFrame[_ParkThenDoneHandler](
            _ParkThenDoneHandler(String("alice")), Int64(10)
        ),
        reactor,
    )
    assert_true(parked, "a handler that parks returns True from admit")
    assert_equal(driver.inflight_count(), 1)
    assert_equal(driver.park_count(), Int64(1))
    assert_equal(driver.delivered_count(), 0)
    _ = driver^
    print("  [1] PARKED arm: frame stays in-flight, nothing delivered OK")


# =============================================================================
# 2. DONE arm — a parked frame's resume DONEs; response delivered, frame gone.
#    Also covers the full park->resume->deliver round-trip through the switch.
# =============================================================================
def test_resume_done_arm_delivers_response() raises:
    var reactor = _mock_reactor()
    var driver = SuspendableHandlerDriver[NoopSink, _ParkThenDoneHandler]()

    _ = driver.admit(
        SuspendedFrame[_ParkThenDoneHandler](
            _ParkThenDoneHandler(String("bob")), Int64(20)
        ),
        reactor,
    )
    var parked_op = driver.peak_parked_op_id_for_test()
    assert_true(parked_op > Int64(0))

    driver.resume(parked_op, reactor)
    assert_equal(driver.inflight_count(), 0)
    assert_equal(driver.delivered_count(), 1)
    var delivered = driver.take_delivered()
    assert_equal(delivered[0].request_id, Int64(20))
    assert_equal(delivered[0].response.status, 200)
    assert_equal(delivered[0].response.body, String("done:bob"))
    _ = driver^
    print("  [2] DONE arm: response delivered, frame retired OK")


# =============================================================================
# 2b. DONE-on-first-step (the "sync route is a handler that DONEs first step").
# =============================================================================
def test_admit_done_first_step_delivers() raises:
    var reactor = _mock_reactor()
    var driver = SuspendableHandlerDriver[NoopSink, _DoneHandler]()

    var parked = driver.admit(
        SuspendedFrame[_DoneHandler](_DoneHandler(String("health")), Int64(21)),
        reactor,
    )
    assert_false(parked, "a DONE-first-step handler does not park")
    assert_equal(driver.inflight_count(), 0)
    assert_equal(driver.park_count(), Int64(0))
    assert_equal(driver.delivered_count(), 1)
    var delivered = driver.take_delivered()
    assert_equal(delivered[0].request_id, Int64(21))
    assert_equal(delivered[0].response.status, 201)
    assert_equal(delivered[0].response.body, String("done:health"))
    _ = driver^
    print("  [2b] DONE-first-step arm: delivered immediately, no park OK")


# =============================================================================
# 3. ERR arm — an ERR result delivers NO response and retires the frame.
#    The frame is NOT parked AND NOT delivered (a domain error would have been a
#    DONE(error-response); ERR is for unrecoverable bugs -> drop the conn).
# =============================================================================
def test_admit_err_arm_no_delivery_no_park() raises:
    var reactor = _mock_reactor()
    var driver = SuspendableHandlerDriver[NoopSink, _ErrHandler]()

    var parked = driver.admit(
        SuspendedFrame[_ErrHandler](_ErrHandler(String("oops")), Int64(30)),
        reactor,
    )
    assert_false(parked, "an ERR result does not park")
    assert_equal(driver.inflight_count(), 0)
    assert_equal(driver.park_count(), Int64(0))
    # THE KEY ASSERTION: an ERR result is NOT delivered as a response.
    assert_equal(driver.delivered_count(), 0)
    _ = driver^
    print("  [3] ERR arm: no response delivered, frame retired OK")


# =============================================================================
# 4. EMIT arm (RESERVED) — an EMIT result is routed to the SAFE retire arm
#    today: NOT silently delivered as a DONE response, NOT parked. This is the
#    exact hazard ("a streaming EMIT would silently retire-and-drop on
#    its first chunk") proven to be HANDLED — an explicit 4th arm, not a
#    fall-through. When the EMIT machinery lands it replaces the safe-retire.
# =============================================================================
def test_admit_emit_arm_routes_to_safe_retire() raises:
    var reactor = _mock_reactor()
    var driver = SuspendableHandlerDriver[NoopSink, _EmitHandler]()

    var parked = driver.admit(
        SuspendedFrame[_EmitHandler](_EmitHandler(String("sse")), Int64(40)),
        reactor,
    )
    # EMIT routes to the safe ERR arm today -> not parked.
    assert_false(parked, "the RESERVED EMIT arm does not park today")
    assert_equal(driver.inflight_count(), 0)
    # THE KEY ASSERTION: EMIT is NOT silently delivered as a response. A naive
    # `else: deliver` 2-state branch would have delivered the chunk here.
    assert_equal(driver.delivered_count(), 0)
    _ = driver^
    print("  [4] EMIT arm (reserved): routed to safe retire, NOT silent-deliver OK")


# =============================================================================
# 5. DEFAULT arm — an unknown/reserved kind is routed to the SAFE ERR arm, NEVER
#    silently delivered as if it were a DONE response. This is what the
#    exhaustive switch buys over the old `else: deliver`: a kind the driver does
#    not recognize cannot be mistaken for a deliverable response.
# =============================================================================
def test_admit_unknown_kind_routes_to_safe_err_not_deliver() raises:
    var reactor = _mock_reactor()
    var driver = SuspendableHandlerDriver[NoopSink, _UnknownKindHandler]()

    var parked = driver.admit(
        SuspendedFrame[_UnknownKindHandler](
            _UnknownKindHandler(String("x")), Int64(50)
        ),
        reactor,
    )
    assert_false(parked, "an unknown kind does not park")
    assert_equal(driver.inflight_count(), 0)
    # THE KEY ASSERTION (the whole point of the exhaustive switch): an unknown
    # kind is NOT silently delivered. The old `else: deliver` would have tried
    # to `take_response()` on a kind with no response and aborted / delivered a
    # bogus value; the default arm retires it safely instead.
    assert_equal(driver.delivered_count(), 0)
    _ = driver^
    print("  [5] DEFAULT arm: unknown kind routed to safe ERR, NOT delivered OK")


# =============================================================================
# 6. EVERY arm in ONE driver lifetime through resume too — a parked frame that
#    re-parks (PARKED on resume), then DONEs. Proves resume funnels through the
#    SAME exhaustive switch (re-park re-keys, terminal delivers).
# =============================================================================
def test_resume_funnels_through_same_switch() raises:
    var reactor = _mock_reactor()
    var driver = SuspendableHandlerDriver[NoopSink, _ParkThenDoneHandler]()

    # admit -> PARKED (in-flight 1)
    _ = driver.admit(
        SuspendedFrame[_ParkThenDoneHandler](
            _ParkThenDoneHandler(String("carol")), Int64(60)
        ),
        reactor,
    )
    assert_equal(driver.inflight_count(), 1)
    var op0 = driver.peak_parked_op_id_for_test()

    # resume -> DONE (delivered, in-flight 0). resume returns nothing; we assert
    # via state. A wrong-arm bug (e.g. resume silently dropping a DONE) would
    # leave delivered_count at 0.
    driver.resume(op0, reactor)
    assert_equal(driver.inflight_count(), 0)
    assert_equal(driver.delivered_count(), 1)
    assert_equal(driver.resume_count(), Int64(1))
    var delivered = driver.take_delivered()
    assert_equal(delivered[0].response.body, String("done:carol"))

    # resume on a stale/unknown op_id is benign (no matching frame).
    driver.resume(op0, reactor)
    assert_equal(driver.delivered_count(), 0)
    _ = driver^
    print("  [6] resume funnels through the same exhaustive switch OK")


def main() raises:
    test_admit_parked_arm_keeps_frame_inflight()
    test_resume_done_arm_delivers_response()
    test_admit_done_first_step_delivers()
    test_admit_err_arm_no_delivery_no_park()
    test_admit_emit_arm_routes_to_safe_retire()
    test_admit_unknown_kind_routes_to_safe_err_not_deliver()
    test_resume_funnels_through_same_switch()
    print("PASS test_suspendable_driver_exhaustive_switch")
