# =============================================================================
# test_io_lane_two_lane_storage.mojo
# =============================================================================
# Two-lane
# `PerCoreAsyncRuntime[S]` storage + lifecycle coverage.
#
# Targets `attach_io_workers` / `io_worker_count` and the load-bearing
# firewall: the IO lane workers go into the same `_workers` / `_thread_ids`
# slabs (so they get pthreads + are joined on shutdown) but are NOT registered
# with the dispatcher, so `worker_count()` (the fork-join shard count) stays
# COMPUTE-only. Covers:
#   * IO lane attach: worker_count() == compute count, io_worker_count() == IO
#     count, total pthread count == compute + IO.
#   * NON-SMT / IO-lane-disabled degenerate case: attach_io_workers(0) is a
#     no-op -> identical to single-lane behavior (the strict superset).
#   * attach_io_workers before any compute worker raises (the IO lane is a tail
#     of the worker slab).
#   * full start() + shutdown() cycle with both lanes (every pthread joined).
#   * DESTROY-RECREATE cycle (byte-reuse / teardown-ordering hazards only
#     manifest across construct/drop/reconstruct cycles, so parallel-path
#     changes need an integration-style destroy-recreate exercise).
#
# BACKEND_MOCK so no epoll fd is opened per worker (matches
# test_multi_worker_storage). The mock backend bounds the destroy-recreate
# cycle count to stay under the documented Mojo 0.26.3 EPOLL-teardown ceiling
# — MOCK has no such ceiling.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import external_call
from std.memory import alloc, ArcPointer, OwnedPointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PLACEMENT_MAX_SPREAD,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.shared_erasure import ErasableWork, STEP_DONE


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# -----------------------------------------------------------------------------
# IO-lane DELIVERY fixtures (the regression guard for the dead-lane bug).
# -----------------------------------------------------------------------------


struct _HitFlag(Movable, Deinitable):
    """A heap-stable shared atomic counter an IO-lane task can bump.

    `Atomic` is non-Movable, so it cannot go directly inside an `ArcPointer`
    (which requires `T: Movable`). Wrapping it in an `OwnedPointer` inside a
    Movable struct is the in-tree shape for exactly this (`_SleepingFlag` in
    `wake_primitives.mojo`). The counter therefore outlives both the posting
    thread's local and the posted task, refcount-tracked.
    """

    var cell: OwnedPointer[AtomicI64]

    def __init__(out self):
        var raw = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we exclusively own, handed straight to the
        # OwnedPointer. Exactly one init, no aliasing.
        raw[] = AtomicI64(Int64(0))
        self.cell = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw
        )

    def bump(mut self):
        _ = self.cell[].fetch_add(Int64(1))

    def load(self) -> Int64:
        return self.cell[].load()


struct _IoHitWork(ErasableWork):
    """A SELF-CONTAINED IO-lane payload that records the fact it ran.

    Holds an `ArcPointer` clone of the shared flag — it OWNS its reach (no borrow
    of the poster's stack, nothing governed by a fork-join barrier), which is the
    `post_to_io_lane` contract. `run()` is the void arm the IO worker invokes
    BLIND via `drain_task_queue`.
    """

    var _flag: ArcPointer[_HitFlag]

    def __init__(out self, var flag: ArcPointer[_HitFlag]):
        self._flag = flag^

    def run(mut self) raises -> None:
        self._flag[].bump()

    def step(mut self) raises -> Int:
        return STEP_DONE


def _spin_until_hit(flag: ArcPointer[_HitFlag], want: Int64, budget_ms: Int) -> Bool:
    """Bounded wait for the IO lane to run `want` posted tasks. True iff it did
    within the budget. Deliberately a BOUNDED wait, not a `shutdown()` — the
    whole point is to prove the work runs while the runtime is LIVE."""
    var deadline = UInt64(perf_counter_ns()) + UInt64(budget_ms) * UInt64(
        1_000_000
    )
    while UInt64(perf_counter_ns()) < deadline:
        if flag[].load() >= want:
            return True
        _ = external_call["usleep", Int32](UInt32(1_000))
    return flag[].load() >= want


# -----------------------------------------------------------------------------
# IO lane attach — counts + firewall
# -----------------------------------------------------------------------------


def test_io_lane_attach_keeps_worker_count_compute_only() raises:
    """The fork-join firewall: with 4 compute + 2 IO workers, `worker_count()`
    (the dispatcher shard count) stays 4 (COMPUTE only); `io_worker_count()`
    reports 2. The IO workers are present in `_workers` (they get pthreads +
    are joined) but absent from the dispatcher's shard set.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    rt.attach_io_workers(2, _noop_sink_factory, BACKEND_MOCK)
    # Compute lane (fork-join shard count) unchanged by the IO attach.
    assert_equal(rt.worker_count(), 4)
    # IO lane reported separately.
    assert_equal(rt.io_worker_count(), 2)
    # The IO workers ARE in the worker slab (global ids 4, 5 follow the
    # compute lane 0..3).
    assert_equal(Int(rt.worker_at(4).worker_id()), 4)
    assert_equal(Int(rt.worker_at(5).worker_id()), 5)


def test_io_lane_zero_is_noop_non_smt_path() raises:
    """NON-SMT / HT-disabled / IO-lane-disabled path: `attach_io_workers(0)`
    is a no-op. `engine_io_cpus()` is EMPTY on a non-SMT box, so the engine
    passes 0 here -> no IO lane is created, worker_count() is unchanged, and
    io_worker_count() is 0 — byte-for-byte today's single-lane behavior.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    rt.attach_io_workers(0, _noop_sink_factory, BACKEND_MOCK)
    assert_equal(rt.worker_count(), 4)
    assert_equal(rt.io_worker_count(), 0)


def test_no_io_lane_worker_count_identical_to_single_lane() raises:
    """When NO IO lane is attached at all, `worker_count()` is exactly
    `_workers.len()` — the pre-Part-B value. This is the guard that the
    The compute/IO split field addition does not perturb the single-lane count.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    rt.attach_workers(3, _noop_sink_factory, BACKEND_MOCK)
    assert_equal(rt.worker_count(), 3)
    assert_equal(rt.io_worker_count(), 0)


def test_io_lane_before_compute_raises() raises:
    """`attach_io_workers` before any compute worker raises — the IO lane is
    a tail of the worker slab; there must be a compute lane to be the head.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    var raised = False
    try:
        rt.attach_io_workers(2, _noop_sink_factory, BACKEND_MOCK)
    except:
        raised = True
    assert_true(raised)


def test_io_lane_attach_after_start_raises() raises:
    """Once start() has launched pthreads, attach_io_workers must raise
    (cannot grow the worker set; would invalidate launched FFI addresses).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    var raised = False
    try:
        rt.attach_io_workers(1, _noop_sink_factory, BACKEND_MOCK)
    except:
        raised = True
    assert_true(raised)
    rt.shutdown()


# -----------------------------------------------------------------------------
# Lifecycle — start + shutdown both lanes
# -----------------------------------------------------------------------------


def test_start_shutdown_cycle_two_lane() raises:
    """Full start + shutdown with both lanes: 4 compute + 2 IO = 6 pthreads
    launched and joined. worker_count() stays 4, io_worker_count() stays 2.
    Reaching the end == both lanes' pthreads joined without panic (gap7
    teardown-ordering: shutdown signals + joins every slot in `_workers`,
    which spans both lanes).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    rt.attach_io_workers(2, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    rt.shutdown()
    assert_equal(rt.worker_count(), 4)
    assert_equal(rt.io_worker_count(), 2)
    # Idempotent.
    rt.shutdown()
    assert_equal(rt.worker_count(), 4)


def _two_lane_cycle_once() raises -> Int:
    """One construct -> attach both lanes -> start -> shutdown -> drop cycle.

    Returns the compute worker_count so the caller can assert the cycle
    produced a well-formed runtime. The runtime drops at fn-return (RAII),
    exercising the two-lane teardown + slab drop path.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _noop_sink_factory, BACKEND_MOCK)
    rt.attach_io_workers(1, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    rt.shutdown()
    return rt.worker_count()


def test_destroy_recreate_cycles_two_lane() raises:
    """DESTROY-RECREATE: construct + start + shutdown + drop the two-lane
    runtime N times in the same process. destroy-recreate (tcmalloc byte reuse under a
    reconstructed struct's lifetime) and gap7 (teardown ordering) only
    manifest across construct/drop/reconstruct cycles — unit tests that build
    one runtime never trigger them. This is the charter-mandated integration-
    style exercise for the parallel-path change.

    BACKEND_MOCK avoids the documented Mojo 0.26.3 BACKEND_EPOLL N>=2 teardown
    ceiling, so we can run a healthy cycle
    count. Each cycle attaches a fresh IO lane (the `_io_lane_start` / IO
    sender slab must reset cleanly on every fresh construct).
    """
    var cycle = 0
    while cycle < 8:
        var wc = _two_lane_cycle_once()
        assert_equal(wc, 2)
        cycle = cycle + 1


# -----------------------------------------------------------------------------
# IO-lane DELIVERY — the regression guard for the DEAD LANE
# -----------------------------------------------------------------------------


def test_io_lane_post_runs_on_a_parked_io_worker() raises:
    """★ THE FALSIFIER for the dead-lane bug.

    BUG CLASS: work posted to the IO lane was never observed by the IO worker,
    so every IO-lane consumer was silently inert. `MpscSender.try_send_back` is a
    pure lock-free Vyukov push that signals NOTHING, and the worker's park is
    `poll_completions(PARK_TIMEOUT_US)` with `PARK_TIMEOUT_US = -1`, i.e.
    INDEFINITE. `_attach_one_io_worker` DROPPED the IO worker's wake handle
    (`_ = worker.wake_handle()`) on the stated premise that "the IO worker's own
    park/poll loop drains the queue" — which is false once it has parked. So a
    posted task sat in the queue until `shutdown()`'s final drain ran it at
    TEARDOWN. The counters said `posts > 0` and the lane looked wired.

    FAILS ON CURRENT CODE (pre-fix): after the 120 ms settle below, the single IO
    worker has spun out its window and parked indefinitely. `post_to_io_lane`
    pushes and does not wake, so `_spin_until_hit` exhausts its budget with the
    flag still 0 and the `assert_true` fails. The assertion is deliberately made
    BEFORE `shutdown()`, because a post-shutdown assertion would pass even on the
    broken code (the final drain runs it) — that is exactly how the bug hid.

    Uses BACKEND_EPOLL because the wake is a real `eventfd_write`; a MOCK reactor
    cannot exercise the park/wake path this guards. ONE ctor/dtor cycle only, to
    stay under the documented Mojo EPOLL-teardown ceiling (see test_raii_ergonomics).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _noop_sink_factory, BACKEND_EPOLL)
    rt.attach_io_workers(1, _noop_sink_factory, BACKEND_EPOLL)
    rt.start()

    # SETTLE: let the IO worker exhaust its spin window and PARK. Without this
    # the pre-fix code could pass spuriously by draining the post while still
    # spinning — the guard would then not falsify the bug it exists for.
    _ = external_call["usleep", Int32](UInt32(120_000))

    var flag = ArcPointer[_HitFlag](_HitFlag())
    assert_equal(flag[].load(), Int64(0))

    var accepted = rt.dispatcher().post_to_io_lane[_IoHitWork](
        _IoHitWork(ArcPointer[_HitFlag](copy=flag))
    )
    assert_true(accepted)

    # THE ASSERTION THAT MATTERS — the work ran while the runtime was LIVE.
    assert_true(_spin_until_hit(flag, Int64(1), 3000))
    assert_equal(flag[].load(), Int64(1))

    rt.shutdown()


def test_io_lane_post_without_a_lane_returns_false_and_drops() raises:
    """DEFAULT / INLINE path: with NO IO lane attached, `post_to_io_lane`
    returns False and the work is destroyed (not leaked, not queued onto a
    COMPUTE worker — the firewall). The caller's inline fallback is what covers
    correctness, which is why False must be cheap and total."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _noop_sink_factory, BACKEND_MOCK)
    rt.start()

    var flag = ArcPointer[_HitFlag](_HitFlag())
    var accepted = rt.dispatcher().post_to_io_lane[_IoHitWork](
        _IoHitWork(ArcPointer[_HitFlag](copy=flag))
    )
    assert_true(not accepted)
    # Never ran, and — the firewall — never handed to a compute worker either.
    assert_equal(flag[].load(), Int64(0))
    assert_equal(rt.worker_count(), 2)
    assert_equal(rt.io_worker_count(), 0)
    rt.shutdown()


def test_io_lane_accepted_post_is_never_lost_at_shutdown() raises:
    """NO-LOSS ON SHUTDOWN. An accepted post that has not run yet MUST still run
    before the runtime drops: the worker loop exits with a final UNBOUNDED
    `drain_task_queue`, and `shutdown()` JOINS the IO pthread. So `shutdown()` is
    a completion point for the IO lane even though `post_to_io_lane` itself
    offers no join.

    Uses BACKEND_MOCK (no wake syscall) precisely so the post is very likely
    still SITTING in the queue when shutdown is signalled — this exercises the
    final-drain path rather than the wake path, which is the complement of
    `test_io_lane_post_runs_on_a_parked_io_worker`.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _noop_sink_factory, BACKEND_MOCK)
    rt.attach_io_workers(1, _noop_sink_factory, BACKEND_MOCK)
    rt.start()

    var flag = ArcPointer[_HitFlag](_HitFlag())
    var accepted = rt.dispatcher().post_to_io_lane[_IoHitWork](
        _IoHitWork(ArcPointer[_HitFlag](copy=flag))
    )
    assert_true(accepted)

    rt.shutdown()
    # After the join, the accepted post has definitely run.
    assert_equal(flag[].load(), Int64(1))


def test_spill_prefetcher_carries_a_wake_handle_per_sender() raises:
    """The poster's two slabs must stay index-parallel: one wake handle per IO
    sender. Pre-fix `make_spill_prefetcher` cloned senders ONLY (the handles had
    been dropped at attach), so `wake_handle_count()` would be 0 against
    `io_lane_count() == 2` and this fails."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(3, _noop_sink_factory, BACKEND_MOCK)
    rt.attach_io_workers(2, _noop_sink_factory, BACKEND_MOCK)
    rt.start()

    var pf = rt.dispatcher().make_spill_prefetcher()
    assert_true(pf.is_active())
    assert_equal(pf.io_lane_count(), 2)
    assert_equal(pf.wake_handle_count(), pf.io_lane_count())
    # A post is accepted and accounted; on MOCK the wake is a no-op, so `wakes`
    # is only asserted to be bounded by `posts` (elision is legal).
    assert_true(pf.prefetch_chunk(String("/nonexistent/io_lane_probe"), 0))
    assert_equal(pf.posts(), 1)
    assert_true(pf.wakes() <= pf.posts())

    rt.shutdown()


def main() raises:
    test_io_lane_attach_keeps_worker_count_compute_only()
    test_io_lane_zero_is_noop_non_smt_path()
    test_no_io_lane_worker_count_identical_to_single_lane()
    test_io_lane_before_compute_raises()
    test_io_lane_attach_after_start_raises()
    test_start_shutdown_cycle_two_lane()
    test_destroy_recreate_cycles_two_lane()
    # DELIVERY guards. The MOCK-backend ones first; the single
    # BACKEND_EPOLL cycle LAST so its teardown cannot perturb the others.
    test_io_lane_post_without_a_lane_returns_false_and_drops()
    test_spill_prefetcher_carries_a_wake_handle_per_sender()
    test_io_lane_accepted_post_is_never_lost_at_shutdown()
    # ⛔ THE ONLY LINUX-ONLY BODY IN THIS FILE, AND IT IS GUARDED RATHER THAN
    # THE WHOLE MAIN. It is the one test here that takes BACKEND_EPOLL
    # 284-285) because the wake it asserts IS a real `eventfd_write`; on macOS
    # the runtime raises "BACKEND_EPOLL requires Linux" and the file would
    # exit non-zero — and as a gated test of the library, that would fail
    # every mac build of the library.
    # The other eleven bodies are MOCK-backend and still run here.
    comptime if CompilationTarget.is_linux():
        test_io_lane_post_runs_on_a_parked_io_worker()
    else:
        print(
            "  test_io_lane_post_runs_on_a_parked_io_worker SKIPPED: it takes"
            " BACKEND_EPOLL because the wake under test is a real"
            " eventfd_write, and both are Linux kernel mechanisms."
        )
    print(
        "PASS komira_async.runtime two-lane (compute/IO) storage + lifecycle"
        " + delivery"
    )
