# =============================================================================
# test_epoll_cycle_regression.mojo
# =============================================================================
# Teardown regression guard. Verifies the
# `PerCoreAsyncRuntime[BACKEND_EPOLL]` RAII teardown survives ≥40
# ctor+dispatch+dtor cycles in one process under the production-relevant
# multi-worker (N>=2) configuration.
#
# What this test guards:
#   A runtime that does the signal+join inline in its destructor
#   exhibits a tcmalloc heap
#   corruption on the 2nd RAII ctor+dispatch+dtor cycle under
#   BACKEND_EPOLL with N>=2 workers. The crash signature is a tcmalloc
#   delete-path abort triggered on the next process-level allocation
#   (typically the `_PthreadArg` heap-alloc inside the next runtime's
#   `start()`). The fix routes the destructor's signal+join through an
#   out-of-line `_runtime_teardown_join` free function (NOT a `mut self`
#   method) so that `__del__(deinit self)` does not re-enter `mut self`
#   method dispatch on `self`.
#
#   See `src/komira_async/runtime/runtime.mojo:__del__` for the full
#   commentary on what was tried + what works.
#
# This test exists so any future regression in the destructor body
# resurrects the bug AND triggers test failure (rather than a silent
# tcmalloc corruption in production engine workloads). Existing engine
# tests with 12-32 EngineContexts per file would flake under the bug;
# pinning the cycle count at 40 here guards against ≥99% of the engine
# corpus's lifecycle profile.
#
# Cycle threshold rationale:
#   * The engine's morsel-pipeline test: 32 EngineContexts in one
#     process — worst-case file in the existing test corpus.
#   * Bundled engine suites: up to 6 files concatenated; ~50
#     EngineContexts in one process.
#   * 40 cycles covers the worst-case single-file shape; the test runs
#     in a fresh process so cross-file accumulation is not an issue here.
#
# Test isolation:
#   Each cycle constructs + destructs a fresh runtime with N=2 workers.
#   The runtime's RAII destructor signals shutdown + joins both pthreads
#   + drops all heap allocations. If the destructor leaves heap
#   corruption behind, the NEXT cycle's pthread_create + arg alloc
#   aborts in tcmalloc.
# =============================================================================

from std.memory import OwnedPointer, alloc
from std.sys.info import CompilationTarget
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async_api.worker_pool_traits import KeepAlive, Segment


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# -----------------------------------------------------------------------------
# Counter state for dispatch probe.
# -----------------------------------------------------------------------------


struct _CounterState(KeepAlive, Movable, Deinitable):
    """Per-dispatch State: heap-stable atomic counter so workers can
    record their fan-out."""

    var counter: OwnedPointer[AtomicI64]

    def __init__(out self):
        var raw = alloc[AtomicI64](1)
        raw[] = AtomicI64(Int64(0))
        self.counter = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw,
        )

    def load(self) -> Int64:
        return self.counter[].load()


@fieldwise_init
struct _CountSegment(Segment, Deinitable):
    """Per-task: bumps the counter by 1."""

    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_CounterState]()
        _ = sp[].counter[].fetch_add(Int64(1))
        _ = worker_id
        _ = task_id


# -----------------------------------------------------------------------------
# Cycle helpers.
# -----------------------------------------------------------------------------


def _one_cycle_no_dispatch(num_workers: Int) raises -> Int:
    """Construct a runtime, query worker_count, drop. RAII path only —
    no explicit `shutdown()`. The pre-fix bug fires here on N>=2 within
    2-3 cycles; the fix makes this stable across ≥40 cycles.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=num_workers,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_EPOLL,
        placement=PLACEMENT_FIXED,
    )
    return rt.worker_count()


def _one_cycle_with_dispatch(num_workers: Int) raises -> Int64:
    """Construct a runtime, dispatch n=num_workers tasks via
    `dispatcher().run_with_state(...)`, drop. Verifies the full
    construct + dispatch + drop path also survives the cycle limit.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=num_workers,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_EPOLL,
        placement=PLACEMENT_FIXED,
    )
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var seg_back = d.run_with_state[_CounterState, _CountSegment](
        s, seg^, num_workers, CancellationToken.never(),
    )
    _ = seg_back^
    return s.load()


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_epoll_no_dispatch_40_cycles_n2() raises:
    """RAII teardown across 40 cycles with N=2 workers, no dispatch.

    Pre-fix: cycle 2-3 crash (non-deterministic). Post-fix: 40/40 green.
    """
    var i = 0
    while i < 40:
        var got = _one_cycle_no_dispatch(num_workers=2)
        assert_equal(got, 2)
        i = i + 1


def test_epoll_no_dispatch_40_cycles_n4() raises:
    """RAII teardown across 40 cycles with N=4 workers, no dispatch.

    Pre-fix: cycle 1-2 crash. Post-fix: 40/40 green.
    """
    var i = 0
    while i < 40:
        var got = _one_cycle_no_dispatch(num_workers=4)
        assert_equal(got, 4)
        i = i + 1


def test_epoll_with_dispatch_40_cycles_n2() raises:
    """RAII teardown + dispatch across 40 cycles with N=2 workers.

    Each cycle dispatches n=2 tasks (matching worker count). Counter
    asserted at the value 2 per cycle. This is the production-shape
    cycle: ctor + dispatch + dtor; the engine's EngineContext
    lifecycle has the same shape.
    """
    var i = 0
    while i < 40:
        var got = _one_cycle_with_dispatch(num_workers=2)
        assert_equal(got, Int64(2))
        i = i + 1


def main() raises:
    # ⛔ BACKEND_EPOLL IS A LINUX MECHANISM AND THE RUNTIME SAYS SO AT RUN TIME:
    # constructing `PerCoreAsyncRuntime[..., backend=BACKEND_EPOLL]` on macOS
    # raises "BACKEND_EPOLL requires Linux". Without this guard the three bodies
    # below would run unconditionally, so on a mac this file would exit
    # non-zero — and as a gated test of the library, that would fail every
    # mac build of the library.
    #
    # The guard is the pattern this package already uses for its other
    # Linux-only reactor test — see `test_epoll_double_add_eexist.mojo`,
    # `comptime if CompilationTarget.is_linux()`. On macOS the equivalent
    # coverage is the kqueue pair (`test_kqueue_wake`, `test_kqueue_accept_tcp`),
    # which are in the same gated `tests =` list; the epoll teardown claim is
    # UNTESTABLE here, not untested elsewhere. On Linux — where this
    # gate does its work — nothing about this file changes.
    comptime if CompilationTarget.is_linux():
        test_epoll_no_dispatch_40_cycles_n2()
        test_epoll_no_dispatch_40_cycles_n4()
        test_epoll_with_dispatch_40_cycles_n2()
        print("PASS komira_async.runtime EPOLL cycle regression")
    else:
        print(
            "SKIP komira_async.runtime EPOLL cycle regression: BACKEND_EPOLL"
            " requires Linux (the runtime raises that verbatim). The macOS"
            " reactor guards are test_kqueue_wake / test_kqueue_accept_tcp."
        )
