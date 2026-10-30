# =============================================================================
# The segment pool and the worker reservations that draw from it
# =============================================================================
#
# What these tests prove:
#
#   * A pool with no budget grants everything and counts it; a pool with a
#     budget refuses a grant that would pass it and leaves the count as it was.
#   * Handles made by `share` address one count.
#   * A reservation draws whole blocks, serves later grows from the block it
#     holds, falls back to exactly the missing bytes when a whole block does
#     not fit, and tallies nothing when it is refused.
#   * A reservation returns its blocks to the pool when it is given back or
#     dropped.
#   * Workers on threads asking for one byte at a time until refused get,
#     together, exactly the budget: none is over-granted and none is refused
#     while a byte is left. A grant that added first and rolled back on
#     failure would over-grant for an instant and refuse a request that fits.

from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_collections.slab import Slab
from komira_pipeline_exec.segment_pool import (
    POOL_UNBOUNDED,
    SegmentPool,
    WorkerReservation,
)

comptime WORKERS = 4
comptime BUDGET = 40000
comptime ROUNDS = 10


def test_a_pool_without_a_budget_grants_and_counts() raises:
    var pool = SegmentPool()
    assert_equal(pool.budget(), POOL_UNBOUNDED)
    assert_true(pool.try_acquire(1 << 40))
    assert_true(pool.try_acquire(5))
    assert_equal(pool.granted(), (1 << 40) + 5)
    pool.give_back(5)
    assert_equal(pool.granted(), 1 << 40)


def test_a_budget_refuses_what_would_pass_it_and_keeps_the_count() raises:
    var pool = SegmentPool(100)
    assert_true(pool.try_acquire(60))
    assert_false(pool.try_acquire(41))
    assert_equal(pool.granted(), 60)
    assert_true(pool.try_acquire(40))
    assert_equal(pool.granted(), 100)
    assert_false(pool.try_acquire(1))
    pool.give_back(30)
    assert_true(pool.try_acquire(30))
    assert_equal(pool.granted(), 100)


def test_shared_handles_address_one_count() raises:
    var pool = SegmentPool(100)
    var other = pool.share()
    assert_equal(other.budget(), 100)
    assert_true(pool.try_acquire(70))
    assert_equal(other.granted(), 70)
    assert_false(other.try_acquire(31))
    assert_true(other.try_acquire(30))
    assert_equal(pool.granted(), 100)


def test_a_reservation_draws_blocks_and_falls_back_to_the_missing_bytes() raises:
    var pool = SegmentPool(150)
    var r = WorkerReservation(pool.share(), 100)
    # A whole block fits: 100 drawn for 60 used.
    assert_true(r.try_grow(60))
    assert_equal(r.held(), 100)
    assert_equal(r.used(), 60)
    assert_equal(pool.granted(), 100)
    # 40 are free in the block; 60 more need 20 beyond it. A second block
    # (200 in all) does not fit, so exactly the 20 missing are drawn.
    assert_true(r.try_grow(60))
    assert_equal(r.held(), 120)
    assert_equal(r.used(), 120)
    assert_equal(pool.granted(), 120)
    # 31 more: neither a block nor the 31 fit (151 > 150). Nothing is tallied.
    assert_false(r.try_grow(31))
    assert_equal(r.held(), 120)
    assert_equal(r.used(), 120)
    assert_equal(pool.granted(), 120)
    assert_true(r.try_grow(30))
    assert_equal(pool.granted(), 150)
    # A grow served from a block already held draws nothing.
    r.release(30)
    assert_true(r.try_grow(30))
    assert_equal(pool.granted(), 150)


def _hold_and_drop(ref pool: SegmentPool) raises:
    var b = WorkerReservation(pool.share(), 100)
    assert_true(b.try_grow(10))
    var c = WorkerReservation(pool.share(), 100)
    assert_true(c.try_grow(150))
    assert_equal(pool.granted(), 300)


def test_a_reservation_returns_its_blocks_when_given_back_or_dropped() raises:
    var pool = SegmentPool(1000)
    var a = WorkerReservation(pool.share(), 100)
    assert_true(a.try_grow(250))
    assert_equal(pool.granted(), 300)
    a.give_back_all()
    assert_equal(pool.granted(), 0)
    assert_equal(a.held(), 0)
    assert_equal(a.used(), 0)
    a.give_back_all()
    assert_equal(pool.granted(), 0)
    _hold_and_drop(pool)
    assert_equal(pool.granted(), 0)


struct _Draws(KeepAlive):
    """What the workers share: the pool, and one slot per worker for the bytes
    it was granted."""

    var pool: SegmentPool
    var got: Slab[Int]

    def __init__(out self):
        self.pool = SegmentPool(BUDGET)
        self.got = Slab[Int].create_prefilled(WORKERS)


struct _Draw(Segment):
    """One worker: ask for one byte until the pool refuses."""

    var _pad: Int32

    def __init__(out self):
        self._pad = 0

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: the test passes a `_Draws` as the dispatch state, so the
        # bitcast restores the type it was built with. Each task writes only
        # its own slot; the pool is atomic.
        var sp = UnsafePointer(to=state).bitcast[_Draws]()
        var w = Int(task_id)
        var mine = 0
        while sp[].pool.try_acquire(1):
            mine += 1
        sp[].got.get_mut_interior(w) = mine


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _one_round(mut rt: PerCoreAsyncRuntime[NoopSink]) raises:
    var draws = _Draws()
    ref disp = rt.dispatcher()
    _ = disp.run_with_state[_Draws, _Draw](
        draws, _Draw(), WORKERS, CancellationToken.new()
    )
    var total = 0
    for w in range(WORKERS):
        total += draws.got.get_mut_interior(w)
    assert_equal(total, BUDGET)
    assert_equal(draws.pool.granted(), BUDGET)


def test_workers_asking_at_once_get_exactly_the_budget() raises:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    var failure = String("")
    try:
        for _ in range(ROUNDS):
            _one_round(rt)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_pool_without_a_budget_grants_and_counts]()
    suite.test[test_a_budget_refuses_what_would_pass_it_and_keeps_the_count]()
    suite.test[test_shared_handles_address_one_count]()
    suite.test[test_a_reservation_draws_blocks_and_falls_back_to_the_missing_bytes]()
    suite.test[test_a_reservation_returns_its_blocks_when_given_back_or_dropped]()
    suite.test[test_workers_asking_at_once_get_exactly_the_budget]()
    suite^.run()
