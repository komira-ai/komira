# =============================================================================
# fake_dispatch -- dispatchers that run the tasks of a wave one after another
# =============================================================================
#
# `ParallelDispatch` conformers for tests that need the order of the workers to
# be a fact of the test rather than of a scheduler: `InlineDispatch` runs task 0
# first, `ReverseDispatch` runs the highest task first. Each task runs to
# completion before the next starts, on the calling thread.

from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment


struct InlineDispatch(ParallelDispatch, Movable, Deinitable):
    """Runs tasks 0, 1, ..., n-1 in that order."""

    var _workers: Int

    def __init__(out self, workers: Int = 8):
        self._workers = workers

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        _ = cancel_token^
        for t in range(n):
            seg.execute[State](state, Int32(t), Int64(t))
        return seg^

    def worker_count(self) -> Int:
        return self._workers


struct ReverseDispatch(ParallelDispatch, Movable, Deinitable):
    """Runs tasks n-1, n-2, ..., 0 in that order."""

    var _workers: Int

    def __init__(out self, workers: Int = 8):
        self._workers = workers

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        _ = cancel_token^
        var t = n - 1
        while t >= 0:
            seg.execute[State](state, Int32(t), Int64(t))
            t -= 1
        return seg^

    def worker_count(self) -> Int:
        return self._workers
