# =============================================================================
# test_local_dispatcher_barrier_leak_stress.mojo
# =============================================================================
# Dispatch use-after-free — the HANG face. A HIGH-RATE falsifier for the residual
# barrier leak, driving the dispatch substrate directly instead of through a
# multi-second TPC-H soak invocation.
#
# WHY A DIRECT-DRIVE STRESS AND NOT MORE SOAK. A query soak leaks on roughly
# 0.2% of invocations, and each invocation is ~5.3 s of query work that performs only a
# few thousand dispatches. That is ~1e-6 per dispatch — meaning the soak spends
# essentially all of its wall on parquet decode and aggregation, and almost none
# of it on the substrate that actually contains the defect. This test strips the
# query away and dispatches an EMPTY body across the same 20-worker MOCK pool, so
# the same number of dispatch-substrate trials costs milliseconds instead of
# hours. If the leak lives in the fork-join substrate (enqueue / delivery /
# generation guard / barrier), this reaches the same trial count ~1000x faster.
#
# WHAT IT ASSERTS, and why each one is the RIGHT observable:
#
#   * `in_flight_snapshot() == 0` after EVERY dispatch — the barrier predicate
#     itself. Non-zero on exit means a live borrower still holds a
#     `_DispatchCtx` pointer into a stack frame that is about to be popped.
#   * `entry_leftover_snapshot() == 0` — no dispatch may ever START with a
#     charge outstanding from the previous one. This is the counter the entry
#     `store(1)` used to erase, which is why the leak stayed invisible.
#   * `stale_shard_refusals_snapshot() == 0` — the fix-4 generation guard must
#     NEVER fire on legitimate traffic. A refusal here is not a save, it is the
#     bug: the refused shard's charge is never released, so the refusal is
#     precisely what converts the old UAF into today's HANG.
#   * every task body ran EXACTLY once — a leak that manifests as dropped work
#     rather than a stuck counter still fails.
#
# THE DISPATCH SHAPE IS THE FIELD SHAPE. `n` cycles WIDE (n >> workers, so each
# shard owns a multi-task range — the n=64 COMBINE wave) / NARROW (n == workers,
# the n=20 RADIX-DRAIN wave) / TINY (n=1, which rewrites only slot 0 and leaves
# every higher `_shard_buf` slot holding the previous generation's bytes). That
# WIDE-then-NARROW-then-TINY alternation is exactly the slot-recycling pattern
# a core dump of the fault captured (slot wid=8 holding an n=64 shard while
# the n=20 wave owned the slab).
#
# NOTE ON PINNING. The field defect is observed ONLY with pinned workers.
# Pinning is applied inside `_worker_pthread_entry` from the runtime's
# `EnginePlacement`; pass `--pin` to this program to reproduce the field
# scheduling. It is a valid invariant test either way, which is why the gated
# form does not force it.
#
# ITERATION COUNT comes from `--stress=long|tiny` on the command line, so the
# same file serves as a cheap gated guard AND as the hunt vehicle without a
# second artifact. The default is small enough for the gated run.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import OwnedPointer, alloc
from std.testing import assert_equal, assert_true
from std.sys import argv
from std.time import perf_counter_ns

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_host.engine_placement import EnginePlacement


# The field compute pool on the box that produces the defect.
comptime _N_WORKERS: Int = 20
# Default cycles for the per-commit lane. One cycle is 4 dispatches (the
# WIDE / NARROW / TINY / NARROW rotation below).
comptime _DEFAULT_CYCLES: Int = 250


struct _CounterState(KeepAlive, Movable, Deinitable):
    """A heap-cell task ledger owned by the TEST frame (which outlives every
    dispatch), so reading it after a dispatch is sound no matter what happened
    to the dispatcher's stack frames."""

    var _ran: OwnedPointer[AtomicI64]

    def __init__(out self):
        var p = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own; ownership transfers to OwnedPointer,
        # whose __del__ frees it.
        p[] = AtomicI64(Int64(0))
        self._ran = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=p,
        )

    def ran(self) -> Int64:
        return self._ran[].load()

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _TickSegment(Segment, Deinitable):
    """The emptiest legitimate body: one atomic increment. Keeping the body
    trivial is the whole point — it maximizes dispatches per second, which is
    what maximizes trials of the substrate under test."""

    var _pad: Int64

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_CounterState]()
        _ = sp[]._ran[].fetch_add(Int64(1))
        _ = worker_id
        _ = task_id

    def __keep_alive(mut self):
        pass


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _engine_placement() -> EnginePlacement:
    """Worker CPU placement: `--pin` on the command line pins workers (the
    field scheduling); the gated test run passes no arguments and pins nothing."""
    var p = EnginePlacement()
    var args = argv()
    for k in range(1, len(args)):
        if String(args[k]) == "--pin":
            p.pin_workers = True
    return p


def _stress_cycles() -> Int:
    """Trial count. `--stress=long` on the command line selects the hunt
    setting, `--stress=tiny` the rate-probe setting; the gated test run passes
    no arguments and keeps the default."""
    var args = argv()
    for k in range(1, len(args)):
        var a = String(args[k])
        if a == "--stress=long":
            return 200_000
        if a == "--stress=tiny":
            return 5
    return _DEFAULT_CYCLES


def test_invariant_dispatch_substrate_never_leaks_a_barrier_charge() raises:
    """Dispatch use-after-free — the barrier must be a PROOF across high-rate
    dispatch traffic with the field's slot-recycling shape.

    FAILS ON CURRENT CODE if the residual leak lives in the fork-join substrate:
    the leaking dispatch either (a) trips `in_flight_snapshot() != 0` on exit,
    (b) is caught by the NEXT dispatch's `entry_leftover_snapshot()`, (c) shows
    up as a `stale_shard_refusals_snapshot()` bump (the fix-4 guard firing on
    live traffic, which is what turns the leak into a hang), or (d) HANGS in
    `_drain_in_flight_barrier` — in which case the barrier's own stall dump
    prints the `posted` / `entered` / `refusals` attribution after ~10 s and the
    test times out. All four are RED; only a clean sweep is GREEN.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](
        placement=PLACEMENT_FIXED, engine_placement=_engine_placement()
    )
    rt.attach_workers(_N_WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    var w = d.worker_count()
    assert_equal(w, _N_WORKERS, "expected the full field-size compute pool")

    var state = _CounterState()
    var expected = Int64(0)
    var cycles = _stress_cycles()
    var t_start = perf_counter_ns()
    var t_prev = t_start

    for _c in range(cycles):
        # Progress heartbeat: separates "the substrate is SLOW under host
        # contention" (steady rate, keeps advancing) from "a barrier is STUCK"
        # (rate goes to zero and the barrier's own stall dump fires). Without
        # this the two look identical from outside — which is how a contention
        # artifact could be mistaken for the leak.
        if _c > 0 and (_c % 100) == 0:
            var now = perf_counter_ns()
            print(
                "[stress] cycle=", _c,
                " dispatches=", _c * 4,
                " last100_ms=", (now - t_prev) // 1_000_000,
                " total_ms=", (now - t_start) // 1_000_000,
                " in_flight=", d.in_flight_snapshot(),
                " refusals=", d.stale_shard_refusals_snapshot(),
                " leftovers=", d.entry_leftover_snapshot(),
            )
            t_prev = now
        # WIDE (multi-task ranges, the n=64 combine shape) / NARROW (one task
        # per worker, the n=20 drain shape) / TINY (rewrites slot 0 only, so
        # slots 1..19 keep the previous generation's bytes) / NARROW again.
        for phase in range(4):
            var n: Int
            if phase == 0:
                n = 64
            elif phase == 2:
                n = 1
            else:
                n = w
            var seg = _TickSegment(_pad=Int64(0))
            var back = d.run_with_state[_CounterState, _TickSegment](
                state, seg^, n, CancellationToken.never(),
            )
            _ = back^
            expected += Int64(n)
            # THE barrier predicate. Checked after EVERY dispatch, not once at
            # the end — a leak that self-heals on the next dispatch's entry
            # `store(1)` would otherwise be invisible.
            assert_equal(
                d.in_flight_snapshot(),
                Int64(0),
                "in_flight must be zero on every barrier exit",
            )

    # These two are the leak's fingerprints; either being non-zero means some
    # dispatch's barrier returned while a charge was still outstanding.
    assert_equal(
        d.entry_leftover_snapshot(),
        Int64(0),
        "no dispatch may begin with a charge left over from the previous one",
    )
    assert_equal(
        d.stale_shard_refusals_snapshot(),
        Int64(0),
        "the generation guard must never fire on legitimate traffic — a"
        " refusal never releases its charge, which is what turns the leak"
        " into a hang",
    )
    assert_equal(
        state.ran(),
        expected,
        "every task must have executed exactly once across all generations",
    )
    _ = state^
    _ = rt^
    print(
        "[stress] fixed-shape cycles=", cycles,
        " dispatches=", cycles * 4,
        " tasks=", expected,
    )


def test_invariant_dispatch_substrate_survives_worker_count_churn() raises:
    """Same invariant under the OTHER field variable: `n` sweeping across the
    whole 1..2*workers range so `n_workers = min(worker_count, n)` changes on
    almost every dispatch. That is what makes the `_shard_buf` high slots go
    stale and un-stale repeatedly, which is the precondition the generation
    stamp exists to survive.

    FAILS ON CURRENT CODE the same four ways as the sibling test above.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](
        placement=PLACEMENT_FIXED, engine_placement=_engine_placement()
    )
    rt.attach_workers(_N_WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    var w = d.worker_count()
    assert_true(w >= 2, "expected a multi-worker pool")

    var state = _CounterState()
    var expected = Int64(0)
    var cycles = _stress_cycles() // 8
    if cycles < 1:
        cycles = 1

    for _c in range(cycles):
        for n in range(1, 2 * w + 1):
            var seg = _TickSegment(_pad=Int64(0))
            var back = d.run_with_state[_CounterState, _TickSegment](
                state, seg^, n, CancellationToken.never(),
            )
            _ = back^
            expected += Int64(n)
            assert_equal(
                d.in_flight_snapshot(),
                Int64(0),
                "in_flight must be zero on every barrier exit",
            )

    assert_equal(
        d.entry_leftover_snapshot(),
        Int64(0),
        "no dispatch may begin with a charge left over from the previous one",
    )
    assert_equal(
        d.stale_shard_refusals_snapshot(),
        Int64(0),
        "the generation guard must never fire on legitimate traffic",
    )
    assert_equal(
        state.ran(),
        expected,
        "every task must have executed exactly once across all generations",
    )
    _ = state^
    _ = rt^
    print(
        "[stress] churn cycles=", cycles,
        " dispatches=", cycles * 2 * w,
        " tasks=", expected,
    )


def main() raises:
    test_invariant_dispatch_substrate_never_leaks_a_barrier_charge()
    test_invariant_dispatch_substrate_survives_worker_count_churn()
    print("OK test_local_dispatcher_barrier_leak_stress")
