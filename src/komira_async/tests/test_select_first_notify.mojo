# =============================================================================
# test_select_first_notify.mojo
# =============================================================================
# SelectFirstNotify tests.
#
# Combinator that races two notify sources; whichever fires first wins.
# Second fires are no-ops on the gate. Used by's
# PendingCheckout late-binding race.
#
# Test plan (10 sub-tests):
#   1. construct_init_state_no_fire — gate is 0 on construction.
#   2. source_0_fires_first — fire 0, await returns 0.
#   3. source_1_fires_first — fire 1, await returns 1.
#   4. idempotent_second_fires — fire 0 then 1, await returns 0.
#   5. idempotent_second_fires_reverse — fire 1 then 0, await returns 1.
#   6. double_fire_same_source — fire 0 twice, await returns 0.
#   7. construct_destruct_no_leak — construct + drop, no panic.
#   8. await_first_after_concurrent_fires — fork-join fanout, both
#      sources fire from different workers; await returns one of {0, 1}.
#   9. await_first_or_timeout_expires — no fire, timeout returns None.
#  10. await_first_or_timeout_fires_first — fire then timeout-await
#      returns Some(0).
#
# MOJO 1.0.0: sub-test 8 previously raced its two fires with the
# stdlib `parallelize`, which 1.0.0 removed (`std.algorithm` no longer contains
# it). It now races them on the REPO'S OWN fork-join —
# `parallel_fork_join_shared` over a real 2-worker `PerCoreAsyncRuntime` +
# `LocalDispatcher` — which is the substrate `src/` itself moved onto in
# and which `test_parallel_fork_join.mojo` in the
# sibling `runtime/` directory already drives. The claim is UNCHANGED: two
# workers on two OS threads fire two different sources at one shared gate, and
# exactly one CAS wins. It is not a serial rewrite — a serial rewrite would make
# the winner deterministic and assert nothing about the race.
# =============================================================================

from std.memory import UnsafePointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.parallel_fork_join_shared import (
    parallel_fork_join_shared,
)
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.sync.select import SelectFirstNotify
from komira_async_api.shared_chunk_work import SharedChunkWork


# -----------------------------------------------------------------------------
# Construction
# -----------------------------------------------------------------------------


def test_construct_init_state_no_fire() raises:
    """Fresh SelectFirstNotify has gate=0 and wake_word=0."""
    var n = SelectFirstNotify.new()
    assert_equal(Int(n.gate_value()), 0)
    assert_equal(Int(n.wake_word_value()), 0)
    _ = n^


# -----------------------------------------------------------------------------
# Single-source fire paths
# -----------------------------------------------------------------------------


def test_source_0_fires_first() raises:
    """fire_source_0 then await_first returns 0."""
    var n = SelectFirstNotify.new()
    n.fire_source_0()
    assert_equal(Int(n.gate_value()), 1)
    var winner = n.await_first()
    assert_equal(Int(winner), 0)


def test_source_1_fires_first() raises:
    """fire_source_1 then await_first returns 1."""
    var n = SelectFirstNotify.new()
    n.fire_source_1()
    assert_equal(Int(n.gate_value()), 2)
    var winner = n.await_first()
    assert_equal(Int(winner), 1)


# -----------------------------------------------------------------------------
# Idempotency — second fires after the gate is set are no-ops.
# -----------------------------------------------------------------------------


def test_idempotent_second_fires() raises:
    """fire_source_0 then fire_source_1: gate stays at 1; await returns 0."""
    var n = SelectFirstNotify.new()
    n.fire_source_0()
    n.fire_source_1()
    # Gate must NOT have transitioned to 2 — first-fires wins.
    assert_equal(Int(n.gate_value()), 1)
    var winner = n.await_first()
    assert_equal(Int(winner), 0)


def test_idempotent_second_fires_reverse() raises:
    """fire_source_1 then fire_source_0: gate stays at 2; await returns 1."""
    var n = SelectFirstNotify.new()
    n.fire_source_1()
    n.fire_source_0()
    # Gate must NOT have transitioned to 1 — first-fires wins.
    assert_equal(Int(n.gate_value()), 2)
    var winner = n.await_first()
    assert_equal(Int(winner), 1)


def test_double_fire_same_source() raises:
    """fire_source_0 × 2 is idempotent; await returns 0 once."""
    var n = SelectFirstNotify.new()
    n.fire_source_0()
    var gate_after_first = n.gate_value()
    n.fire_source_0()
    var gate_after_second = n.gate_value()
    # Gate stable at 1 across both fires.
    assert_equal(Int(gate_after_first), 1)
    assert_equal(Int(gate_after_second), 1)
    var winner = n.await_first()
    assert_equal(Int(winner), 0)


# -----------------------------------------------------------------------------
# Construct + destruct round-trip (drops the ArcPointer cleanly).
# -----------------------------------------------------------------------------


def test_construct_destruct_no_leak() raises:
    """Construct + drop without firing; ArcPointer should drop cleanly."""
    var n = SelectFirstNotify.new()
    # Confirm we can read the gate before drop.
    assert_equal(Int(n.gate_value()), 0)
    # Explicit consume to force the drop point.
    _ = n^


# -----------------------------------------------------------------------------
# Concurrent fires via the repo's own fork-join.
# -----------------------------------------------------------------------------
# Both workers fire DIFFERENT sources from their own clones of the
# shared state. After the join, exactly one of {0, 1} is the winner;
# both outcomes are valid (non-deterministic by design — that's the
# point of the race).


struct _RaceInput(Deinitable):
    """Read-only, shared, and deliberately empty: this race carries no
    per-chunk input. The fork-join driver still requires an `In`, so the
    unit type is spelled out rather than smuggled in through the payload."""

    var _placeholder: UInt8

    def __init__(out self):
        self._placeholder = UInt8(0)


struct _RaceHandles(Movable, Deinitable):
    """The MUTABLE shared payload: the two per-worker handles.

    They are distinct `ArcPointer` clones of ONE `SelectFirstNotify` state —
    which is precisely what makes this a race and not two independent fires.
    """

    var h0: SelectFirstNotify
    var h1: SelectFirstNotify

    def __init__(
        out self, var h0: SelectFirstNotify, var h1: SelectFirstNotify
    ):
        self.h0 = h0^
        self.h1 = h1^


@fieldwise_init
struct _FireRace(SharedChunkWork):
    """Chunk 0 fires source 0; chunk 1 fires source 1.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: chunk 0 touches ONLY `payload.h0`, chunk 1 ONLY
        `payload.h1`. The two are distinct struct fields and distinct
        `ArcPointer` clones, so no two chunks write one Mojo-level slot. The
        CONTENTION they do share is the atomic gate inside the refcounted
        state, which is the thing under test — `fire_source_*` reaches it
        through a CAS.
      * Liveness: the payload is MOVED onto the driver's State, so it is OWNED
        across the barrier rather than borrowed, and `_RaceInput` arrives as
        `ref [in_o] input` with a CONCRETE origin pinned to the caller's frame.
        `fork_join_shared`'s `run_with_state` is a synchronous fork-join
        barrier — no worker can outlive it.
      * No-realloc: `fire_source_*` is CAS + atomic fetch_add +
        wake_one_by_address. No allocation, no resize, nothing to move under a
        peer chunk.
    """

    var _placeholder: UInt8

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut payload: P,
    ) raises:
        # SAFETY: the call site below instantiates the driver with
        # In=_RaceInput and P=_RaceHandles; the bitcast recovers the concrete
        # payload type. The pointer does not escape this function.
        var pp = UnsafePointer(to=payload).bitcast[_RaceHandles]()
        if chunk_id == 0:
            pp[].h0.fire_source_0()
        else:
            pp[].h1.fire_source_1()


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_await_first_after_concurrent_fires() raises:
    """Fork-join-driven race on a REAL 2-worker runtime: both fire, exactly
    one wins, await returns that one. Not flaky: any of {0, 1} is acceptable.
    """
    var n = SelectFirstNotify.new()
    # Clone handles for the two workers (each gets its own ArcPointer
    # copy of the shared state).
    var handle_0 = n.from_handle()
    var handle_1 = n.from_handle()

    # A REAL multi-worker runtime — two chunks on two worker threads. Anything
    # with fewer than 2 workers, or the `_serial` entry, would run the two
    # fires in program order and the "race" would assert nothing.
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    var ct = CancellationToken.new()
    ref disp = rt.dispatcher()
    var disp_ptr = Pointer(to=disp)

    var race_input = _RaceInput()
    var handles = parallel_fork_join_shared[
        _FireRace,
        _RaceInput,
        _RaceHandles,
        origin_of(race_input),
        origin_of(disp),
    ](
        _FireRace(UInt8(0)),
        race_input,
        _RaceHandles(handle_0^, handle_1^),
        2,
        disp_ptr,
        ct.clone(),
    )
    rt.shutdown()

    # After the fork-join, the gate is set by whichever fire's CAS
    # won. Both outcomes (1 or 2 = winner is 0 or 1) are valid.
    var gate = n.gate_value()
    assert_true(Int(gate) == 1 or Int(gate) == 2)

    var winner = n.await_first()
    var winner_int = Int(winner)
    assert_true(winner_int == 0 or winner_int == 1)

    # Winner index must agree with the gate state (1↔0, 2↔1).
    if Int(gate) == 1:
        assert_equal(winner_int, 0)
    else:
        assert_equal(winner_int, 1)

    _ = handles^


# -----------------------------------------------------------------------------
# Timeout variant.
# -----------------------------------------------------------------------------


def test_await_first_or_timeout_expires() raises:
    """No fire; await_first_or_timeout returns None after the deadline."""
    var n = SelectFirstNotify.new()
    # 1ms deadline — small but non-zero so we exercise the actual park.
    var result = n.await_first_or_timeout(total_timeout_ns=Int64(1_000_000))
    assert_false(result)


def test_await_first_or_timeout_fires_first() raises:
    """Fire source 0 first; await_first_or_timeout returns Some(0)."""
    var n = SelectFirstNotify.new()
    n.fire_source_0()
    # Generous deadline (1s) — the fast-path gate check should return
    # immediately without parking.
    var result = n.await_first_or_timeout(
        total_timeout_ns=Int64(1_000_000_000),
    )
    assert_true(result)
    assert_equal(Int(result.value()), 0)


# -----------------------------------------------------------------------------
# Top-level driver
# -----------------------------------------------------------------------------


def main() raises:
    test_construct_init_state_no_fire()
    test_source_0_fires_first()
    test_source_1_fires_first()
    test_idempotent_second_fires()
    test_idempotent_second_fires_reverse()
    test_double_fire_same_source()
    test_construct_destruct_no_leak()
    test_await_first_after_concurrent_fires()
    test_await_first_or_timeout_expires()
    test_await_first_or_timeout_fires_first()
    print("PASS komira_async.sync.select — 10 tests")
