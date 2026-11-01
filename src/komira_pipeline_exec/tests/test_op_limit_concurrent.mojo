# =============================================================================
# The limit's row budget under contention
# =============================================================================
#
# Several workers of the runtime's threaded dispatcher draw from one
# `LimitBudget` in a tight loop, each worker taking a different number of rows
# per call. What this proves:
#
#   * The "before" counts the calls get back describe ranges of rows that do not
#     overlap and, together, leave no gap: every row counted by some call is
#     counted by exactly one.
#   * When every worker is done, the budget has counted the sum of what the
#     workers took.
#
# A budget that read the count and stored it back in two steps would hand two
# workers the same range, or lose a take; both show here.

from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_collections.slab import Slab
from komira_pipeline_exec.op_limit import LimitBudget

comptime WORKERS = 4
comptime CALLS = 20000
comptime ROUNDS = 5


struct _Draws(KeepAlive):
    """What the workers share: the budget, and one slot per call to record the
    count it returned (worker `w`, call `k` writes slot `w * CALLS + k`)."""

    var budget: LimitBudget
    var before: Slab[Int]

    def __init__(out self):
        self.budget = LimitBudget()
        self.before = Slab[Int].create_prefilled(WORKERS * CALLS)


struct _Draw(Segment):
    """One worker: `CALLS` takes of `worker + 1` rows each."""

    var _pad: Int32

    def __init__(out self):
        self._pad = 0

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: the test passes a `_Draws` as the dispatch state, so the
        # bitcast restores the type it was built with. Each task writes only
        # the slots of its own worker id; the budget is atomic.
        var sp = UnsafePointer(to=state).bitcast[_Draws]()
        var w = Int(task_id)
        for k in range(CALLS):
            var got = sp[].budget.take(w + 1)
            sp[].before.get_mut_interior(w * CALLS + k) = got


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
        total += (w + 1) * CALLS
    assert_equal(draws.budget.taken(), total)
    var counted = List[Bool](length=total, fill=False)
    for w in range(WORKERS):
        for k in range(CALLS):
            var start = draws.before.get_mut_interior(w * CALLS + k)
            assert_true(start >= 0 and start + w + 1 <= total)
            for r in range(start, start + w + 1):
                assert_false(counted[r], "row " + String(r) + " counted twice")
                counted[r] = True
    for r in range(total):
        assert_true(counted[r], "row " + String(r) + " counted by no call")


def test_workers_counting_at_once_get_disjoint_ranges_and_lose_none() raises:
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
    suite.test[test_workers_counting_at_once_get_disjoint_ranges_and_lose_none]()
    suite^.run()
