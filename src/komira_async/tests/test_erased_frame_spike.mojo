# =============================================================================
# test_erased_frame_spike.mojo
# =============================================================================
# THE DE-RISKING TEST for the unified async-handler design. Locks the
# type-erasure compile shape (`ErasedHandlerFrame[S]` + `make_erased_handler_frame[H, S]` + the
# top-level parametric trampolines) independently of any live serve path.
#
# Proves the two requirements the design rests on:
#
#   (1) MULTIPLEXING — TWO DISTINCT `SuspendableHandler` structs (a PARK handler
#       that parks on step 1 + DONEs on resume; a SYNC handler that DONEs on its
#       first step) live in ONE `Slab[ErasedHandlerFrame[NoopSink]]` and are stepped
#       BLIND through `_step_fn`. One driver multiplexes N handler types — no
#       `KomiraSuspendableHandler` sum, no per-handler driver monomorph. This is
#       the exact pattern `Worker.drain` uses to call `_TaskEntry.run_fnptr`
#       blind across heterogeneous tasks.
#
#   (2) MOVABLE-RESPONSE ROUND-TRIP — the DONE response (`_ToyResp`, Movable but
#       NOT Copyable, holding a heap-owning String + a status Int) travels OUT
#       through the thin fn-ptr (heap-boxed in `ErasedStepResult`) and is
#       reconstructed BYTE-IDENTICAL at the seam (status + body match what the
#       handler produced). No double-free / leak: the heap-box is consumed
#       exactly once by `take_response[_ToyResp]()`, and each handler SM's own
#       String field is destroyed exactly once by `_erased_drop_for[H]`.
#
# `_ToyResp` (Movable-not-Copyable, heap-owning String field) is deliberately
# the destroy-recreate shape: a Movable struct with a heap-owning inner field traveling
# through the erasure. The substrate stays `komira_http`-free — `Resp` is the
# handler's associated alias, here a local toy type, NOT HttpResponse.
#
# Backend: BACKEND_MOCK — no kernel fds, cross-platform (Linux + macOS), and the
# PARK handler parks on a bare `reactor.alloc_op_id()` (no fd registration), so
# the test exercises the erasure shape WITHOUT real I/O readiness machinery.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_MOCK,
    OP_ID_ALLOC_BASE,
    Reactor,
)
from komira_async.runtime.shared_erasure import (
    ErasedHandlerFrame,
    make_erased_handler_frame,
)
from komira_async.runtime.suspendable_handler import (
    HANDLER_OP_ID_BIAS,
    HandlerStepResult,
    SuspendableHandler,
)

from komira_collections.slab import Slab


# =============================================================================
# _ToyResp — a Movable-NOT-Copyable response (the destroy-recreate shape: heap-owning
# String field). Stands in for HttpResponse (the substrate stays HTTP-free).
# =============================================================================


struct _ToyResp(Movable, Deinitable):
    """A toy terminal response: a status code + a heap-owning body String. NOT
    Copyable (single ownership; moved through the erasure). The heap-owning
    String field is what makes the round-trip a genuine test — a botched
    erasure would corrupt or double-free it."""

    var status: Int
    var body: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^


# =============================================================================
# _ParkHandler — a SuspendableHandler that PARKS on step 1, DONEs on resume.
# =============================================================================


comptime _PH_INIT: UInt8 = 0
comptime _PH_AWAIT: UInt8 = 1


struct _ParkHandler(Movable, Deinitable, SuspendableHandler):
    """Parks once (returns PARKED(op_id) on the first step), then DONEs on the
    resume step. The op_id is a bare `reactor.alloc_op_id()` (biased above the
    fd range) — no fd registration, so the test needs no real readiness. Owns a
    heap String (`_who`) so its destructor has real work — exercises
    `_erased_drop_for[_ParkHandler]` running the SM destructor in-place."""

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
        # Resume: produce the terminal response (heap-owning body).
        return HandlerStepResult[_ToyResp].done(
            _ToyResp(200, String("park-done:") + self._who)
        )


# =============================================================================
# _SyncHandler — a SuspendableHandler that DONEs on its FIRST step (no park).
# The design's "sync route is just a handler that DONEs first step" claim.
# =============================================================================


struct _SyncHandler(Movable, Deinitable, SuspendableHandler):
    """Never parks: DONEs on its first step. Same trait, same interface — a
    "sync" handler is indistinguishable from an async one at the erasure
    boundary. Also owns a heap String to exercise the in-place SM destructor."""

    comptime Resp = _ToyResp

    var _tag: String

    def __init__(out self, var tag: String):
        self._tag = tag^

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[_ToyResp]:
        return HandlerStepResult[_ToyResp].done(
            _ToyResp(201, String("sync-done:") + self._tag)
        )


comptime _ToyFrame = ErasedHandlerFrame[NoopSink]


# =============================================================================
# 1. MULTIPLEXING — two distinct handler types in ONE Slab[ErasedHandlerFrame],
#    stepped BLIND. The park one returns PARKED; the sync one returns DONE.
# =============================================================================
def test_one_slab_multiplexes_two_handler_types() raises:
    """`make_erased_handler_frame[_ParkHandler, NoopSink]` + `make_erased_handler_frame[_SyncHandler,
    NoopSink]` land in ONE `Slab[ErasedHandlerFrame[NoopSink]]`. Stepping both BLIND
    through `_step_fn` returns PARKED for the park handler and DONE for the sync
    handler — in the same slab, same loop, no sum type. This is the proof that
    one driver multiplexes N handler types."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)

    var frames = Slab[_ToyFrame]()
    # Frame 0: the PARK handler. Frame 1: the SYNC handler. request_id is a toy
    # routing key (the conn fd in production).
    frames.append(make_erased_handler_frame[_ParkHandler, NoopSink](
        _ParkHandler(String("alice")), Int64(100)
    ))
    frames.append(make_erased_handler_frame[_SyncHandler, NoopSink](
        _SyncHandler(String("health")), Int64(101)
    ))
    assert_equal(frames.len(), 2)

    # Step the PARK frame (index 0) BLIND — it parks on a biased op_id.
    var sr0 = frames[0].step(reactor)
    assert_true(sr0.is_parked(), "the park handler returns PARKED on step 1")
    assert_false(sr0.is_done())
    var parked_op = sr0.op_id()
    assert_true(
        parked_op >= HANDLER_OP_ID_BIAS,
        "the parked op_id is biased above the fd range (== OP_ID_ALLOC_BASE)",
    )
    assert_equal(HANDLER_OP_ID_BIAS, OP_ID_ALLOC_BASE)
    frames[0].set_parked_op_id(parked_op)

    # Step the SYNC frame (index 1) BLIND — it DONEs immediately. Same loop,
    # same Slab, NO type discrimination at the step site.
    var sr1 = frames[1].step(reactor)
    assert_true(sr1.is_done(), "the sync handler returns DONE on step 1")
    assert_false(sr1.is_parked())
    # The sync handler's response round-trips through the erasure (see test 2
    # for the byte-identical assertion; here just confirm it unboxes).
    var resp1 = sr1.take_response[_ToyResp]()
    assert_equal(resp1.status, 201)
    assert_equal(resp1.body, String("sync-done:health"))

    # RESUME the PARK frame (index 0) BLIND — now it DONEs.
    var sr0b = frames[0].step(reactor)
    assert_true(sr0b.is_done(), "the park handler DONEs on resume")
    var resp0 = sr0b.take_response[_ToyResp]()
    assert_equal(resp0.status, 200)
    assert_equal(resp0.body, String("park-done:alice"))

    # The frames drop here (Slab teardown) — `_erased_drop_for[H]` runs each
    # SM's String destructor in-place exactly once, then the blob frees. A
    # double-free / leak would surface under the leak-sanitizer / asan harness.
    _ = frames^

    print("  [1] multiplexing: 2 distinct handler types, one slab, stepped blind OK")


# =============================================================================
# 2. MOVABLE-RESPONSE ROUND-TRIP — the DONE response (Movable-not-Copyable,
#    heap-owning body) travels OUT through the thin fn-ptr, heap-boxed, and is
#    reconstructed BYTE-IDENTICAL.
# =============================================================================
def test_movable_response_round_trips_through_fn_ptr() raises:
    """A `_ToyResp` (Movable-not-Copyable, owning a heap String body) produced
    by a handler's DONE travels OUT through `_step_fn` (heap-boxed in
    `ErasedStepResult._resp_blob`) and is reconstructed intact at the seam:
    status + body byte-identical to what the handler built. The box is consumed
    exactly once (`take_response`) — no double-free, no leak."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)

    # A sync handler whose response body is a non-trivial heap String (forces a
    # real heap buffer to survive the alloc -> bitcast -> own -> unbox journey).
    var long_tag = String("the-quick-brown-fox-jumps-over-the-lazy-dog-0123456789")
    var frame = make_erased_handler_frame[_SyncHandler, NoopSink](
        _SyncHandler(long_tag), Int64(202)
    )

    var sr = frame.step(reactor)
    assert_true(sr.is_done())
    # Reconstruct the concrete Resp from the heap-box. This is the seam's
    # `_type_is_eq`-proven unbox (here the test supplies the same _ToyResp the
    # producer used).
    var resp = sr.take_response[_ToyResp]()
    assert_equal(resp.status, 201)
    assert_equal(
        resp.body,
        String("sync-done:the-quick-brown-fox-jumps-over-the-lazy-dog-0123456789"),
        "the heap-owning body round-trips byte-identical through the fn-ptr",
    )

    # `resp` drops here (its String freed once). `sr` is now an empty DONE
    # (box taken) — its drop frees nothing. `frame` drops at scope end:
    # `_erased_drop_for[_SyncHandler]` runs the SM's `_tag` String destructor
    # in-place once, then the blob frees the SM home. Exactly-once everywhere.
    _ = frame^

    print("  [2] movable-response round-trip: byte-identical, consumed once OK")


# =============================================================================
# 3. PARK handler full round-trip in isolation (admit -> park -> resume -> DONE)
#    + its heap-owning response round-trips too.
# =============================================================================
def test_park_handler_full_round_trip() raises:
    """Drives a single PARK handler through its full lifecycle via the erased
    frame: step 1 PARKS (biased op_id), step 2 (resume) DONEs with a heap-owning
    body that round-trips intact. Confirms a multi-step (genuinely suspending)
    handler works through the same erasure as the one-step sync handler."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)

    var frame = make_erased_handler_frame[_ParkHandler, NoopSink](
        _ParkHandler(String("bob")), Int64(303)
    )
    assert_equal(frame.request_id(), Int64(303))

    var sr1 = frame.step(reactor)
    assert_true(sr1.is_parked())
    assert_false(sr1.is_done())
    assert_false(sr1.is_error())
    # PARKED carries no response; nothing to unbox. The frame stays steppable.
    frame.set_parked_op_id(sr1.op_id())
    assert_equal(frame.parked_op_id(), sr1.op_id())

    var sr2 = frame.step(reactor)
    assert_true(sr2.is_done())
    var resp = sr2.take_response[_ToyResp]()
    assert_equal(resp.status, 200)
    assert_equal(resp.body, String("park-done:bob"))

    _ = frame^
    print("  [3] park handler full round-trip (park -> resume -> DONE) OK")


def main() raises:
    test_one_slab_multiplexes_two_handler_types()
    test_movable_response_round_trips_through_fn_ptr()
    test_park_handler_full_round_trip()
    print("PASS test_erased_frame_spike")
