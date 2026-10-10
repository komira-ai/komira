# =============================================================================
# test_worker_shutdown_park_race.mojo
# =============================================================================
# A shutdown signal that lands while a worker is about to park must not be
# lost.
#
# The worker loop parks in three steps: it checks the shutdown flag, stores
# its sleeping flag (1), then makes a NON-blocking poll of its reactor
# (`poll_completions(0)`) before the blocking one (`poll_completions(-1)`).
# The non-blocking poll drains the worker's wake eventfd and does not report
# the wake. `Worker.signal_shutdown` stores the flag, then writes that
# eventfd. When the write lands between the flag check and the non-blocking
# poll, the poll consumes it, and a worker that does not check the flag again
# before the blocking poll waits forever: `PerCoreAsyncRuntime.shutdown` (or
# its destructor) then never returns from pthread_join.
#
# How the test aims at that window: it starts a one-worker runtime, waits
# until the worker's sleeping flag reads 1 (the worker is between storing it
# and returning from its park), then signals shutdown at once. A worker that
# saw the shutdown leaves the park bracket and stores 0; a worker that lost
# the wake keeps 1 forever. So a sleeping flag still at 1 a full second after
# the signal is a lost wake: the test then writes the eventfd once more (so
# the worker exits and the join returns) and fails, naming the trial.
#
# Under the release build the window is a few hundred nanoseconds wide, so a
# single trial hits it rarely; the test runs TRIALS of them. Under a
# coverage run (kcov's breakpoints slow the worker's first pass through each
# line) the window is wide, and a runtime of four workers hung on its first
# destruction (test_epoll_cycle_regression).
#
# The defect it catches: removing the flag check after the non-blocking poll
# in `Worker.run_until_shutdown`.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal
from std.time import perf_counter_ns

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)


comptime TRIALS: Int = 2000
# How long a signalled worker may keep its sleeping flag at 1 before the wake
# counts as lost. A worker that saw the signal clears it within microseconds;
# a second is far above any scheduling delay of a loaded build host.
comptime LOST_AFTER_NS: Int = 1_000_000_000
# How long the test waits for a fresh worker to reach its first park.
comptime PARK_DEADLINE_NS: Int = 10_000_000_000


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _backend() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    else:
        return BACKEND_KQUEUE


def _one_trial(trial: Int) raises -> Bool:
    """Runs one trial; True when the worker lost the shutdown wake."""
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_noop_sink_factory,
        backend=_backend(),
        placement=PLACEMENT_FIXED,
    )
    var h = rt.worker_at(0).wake_handle()
    var t0 = perf_counter_ns()
    while h.sleeping_flag_load() == Int32(0):
        if Int(perf_counter_ns() - t0) > PARK_DEADLINE_NS:
            raise Error(
                "trial " + String(trial)
                + ": the worker did not reach its park within 10 s"
            )
    rt.worker_at(0).signal_shutdown()
    var t1 = perf_counter_ns()
    var lost = False
    while h.sleeping_flag_load() != Int32(0):
        if Int(perf_counter_ns() - t1) > LOST_AFTER_NS:
            lost = True
            # Wake it again so that it exits and the join below returns.
            h.wake()
            break
    rt.shutdown()
    return lost


def test_shutdown_signal_at_park_is_not_lost() raises:
    var trial = 0
    while trial < TRIALS:
        if _one_trial(trial):
            print(
                "FAIL: trial", trial, "of", TRIALS, "lost the shutdown wake:"
                " the worker parked with the shutdown flag set and its"
                " eventfd already drained"
            )
            assert_equal(trial, -1, "a shutdown wake was lost")
        trial = trial + 1


def main() raises:
    test_shutdown_signal_at_park_is_not_lost()
    print("PASS komira_async.runtime worker shutdown at park is not lost")
