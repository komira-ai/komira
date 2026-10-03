# =============================================================================
# test_gcp_cloud_run_runtime.mojo
# =============================================================================
# GcpCloudRunRuntime is a
# SINGLE inline reactor, NOT a worker-pthread pool.
#
# Asserts:
#   * TRAIT CONFORMANCE — GcpCloudRunRuntime[NoopSink] satisfies `Runtime`
#     (binds where a `[RT: Runtime]`-generic helper expects one; comptime
#     members read back: MODEL_CLOUD_RUN + TASKS_ARE_THREAD_PINNED=False).
#     RUNTIME_MODEL stays MODEL_CLOUD_RUN (NOT MODEL_CURRENT_THREAD_BLOCKING) —
#     the per-request flush-before-freeze gates on this comptime sentinel,
#     so the Cloud-Run identity is LOAD-BEARING.
#   * SINGLE INLINE REACTOR — worker_count() == 1 always (concurrency=1; scale
#     by instances). No attach step; the reactor is constructed in the ctor.
#   * NO WORKER PTHREADS SPAWNED (the whole point of the collapse) — building,
#     using, and dropping the inline runtime does NOT grow the process's live
#     thread count. This is the proof the worker pool is gone: the serving
#     process has the serve thread (+ a log-flush thread if any), but NOT N
#     GcpCloudRun worker pthreads.
#   * poll_completions drives the single reactor on the current thread; an
#     out-of-range worker_idx raises (single-worker bounds-check contract).
#
# BACKEND_MOCK keeps the fd footprint small (no real epoll fd per reactor).
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime_trait import (
    MODEL_CLOUD_RUN,
    MODEL_CURRENT_THREAD_BLOCKING,
    Runtime,
)
from komira_async.runtime.gcp_cloud_run_runtime import GcpCloudRunRuntime


def _make_noop_sink() -> NoopSink:
    """Nullary sink factory."""
    return NoopSink(_placeholder=UInt8(0))


def _live_thread_count() -> Int64:
    """Count threads in the current process. Cross-platform.

    Linux: /proc/self/task entry count. Darwin: Mach task_threads via the
    `_posix_shim.c` `komira_mac_thread_count` non-variadic FFI shim. Other:
    -1 (caller skips the assertion). Same probe as
    tests/test_worker_no_leak_after_runtime_drop.mojo —
    the canonical no-pthread-leak signal."""
    comptime if CompilationTarget.is_linux():
        var path = String("/proc/self/task")
        var dirp = external_call["opendir", Int](
            path.as_c_string_slice().unsafe_ptr()
        )
        if dirp == Int(0):
            return Int64(-1)
        var count = Int64(0)
        while True:
            var entry = external_call["readdir", Int](dirp)
            if entry == Int(0):
                break
            count += 1
        _ = external_call["closedir", Int32](dirp)
        # Subtract "." and ".." which readdir always returns.
        return count - 2
    elif CompilationTarget.is_macos():
        return external_call["komira_mac_thread_count", Int64]()
    else:
        return Int64(-1)


# =============================================================================
# Trait-conformance — a `[RT: Runtime]`-generic helper the conformer binds to.
# =============================================================================
def _runtime_worker_count[RT: Runtime](rt: RT) -> Int:
    """A trivially-generic helper requiring `RT: Runtime`. If
    GcpCloudRunRuntime conforms, this compiles + returns its worker_count.
    The mere fact this instantiates is the conformance proof."""
    return rt.worker_count()


def _runtime_model[RT: Runtime]() -> UInt8:
    """Read the comptime RUNTIME_MODEL through the trait-generic boundary."""
    return RT.RUNTIME_MODEL


def _runtime_pinned[RT: Runtime]() -> Bool:
    """Read the comptime TASKS_ARE_THREAD_PINNED through the trait boundary."""
    return RT.TASKS_ARE_THREAD_PINNED


def test_trait_conformance_and_comptime_members() raises:
    """GcpCloudRunRuntime[NoopSink] conforms to `Runtime`; its comptime
    members read MODEL_CLOUD_RUN + TASKS_ARE_THREAD_PINNED=False.

    LOAD-BEARING: RUNTIME_MODEL must be MODEL_CLOUD_RUN, NOT
    MODEL_CURRENT_THREAD_BLOCKING — even though the internals now mirror
    BlockingRuntime, the Cloud-Run identity gates the per-request
    flush-before-freeze."""
    assert_equal(
        Int(_runtime_model[GcpCloudRunRuntime[NoopSink]]()),
        Int(MODEL_CLOUD_RUN),
    )
    # Explicitly NOT BlockingRuntime's model — the collapse mirrors the
    # internals but MUST keep the distinct Cloud-Run sentinel.
    assert_true(
        Int(_runtime_model[GcpCloudRunRuntime[NoopSink]]())
        != Int(MODEL_CURRENT_THREAD_BLOCKING),
        String("GcpCloudRunRuntime must NOT be MODEL_CURRENT_THREAD_BLOCKING"),
    )
    assert_equal(_runtime_pinned[GcpCloudRunRuntime[NoopSink]](), False)

    # An inline runtime binds where a `[RT: Runtime]` helper expects one.
    var rt = GcpCloudRunRuntime[NoopSink](_make_noop_sink(), BACKEND_MOCK)
    assert_equal(_runtime_worker_count(rt), 1)
    _ = rt^


def test_single_inline_reactor_worker_count_is_one() raises:
    """The inline runtime has exactly ONE reactor (Cloud Run concurrency=1;
    scale by instances) -> worker_count() == 1 always. There is no attach
    step; the reactor is built in the ctor."""
    var rt = GcpCloudRunRuntime[NoopSink](_make_noop_sink(), BACKEND_MOCK)
    assert_equal(Int(rt.worker_count()), 1)
    # The `.new()` factory comptime-selects the host backend; under BACKEND_MOCK
    # we pass it explicitly so the test has no real fd. Both paths yield 1.
    _ = rt^


def test_new_factory_builds_inline_runtime() raises:
    """The `.new(sink)` factory builds the inline runtime with the
    host-appropriate backend comptime-selected, and worker_count() == 1.

    On a non-mock backend this allocates a real reactor fd; we just assert it
    constructs + reports 1 (the fd-leak / thread-leak shape is covered by the
    no-pthread test below)."""
    var rt = GcpCloudRunRuntime[NoopSink].new(_make_noop_sink())
    assert_equal(Int(rt.worker_count()), 1)
    _ = rt^


def test_poll_completions_out_of_range_raises() raises:
    """Single-worker bounds-check contract: poll_completions with a
    worker_idx != 0 raises (mirrors BlockingRuntime)."""
    var rt = GcpCloudRunRuntime[NoopSink](_make_noop_sink(), BACKEND_MOCK)
    var raised = False
    try:
        _ = rt.poll_completions(1, Int32(0))
    except e:
        _ = e
        raised = True
    assert_true(raised, String("worker_idx=1 must raise on a 1-worker runtime"))
    # worker_idx=0 is the valid drive (non-blocking poll; 0 completions on a
    # freshly-built mock reactor).
    var n = rt.poll_completions(0, Int32(0))
    assert_true(n >= 0)
    _ = rt^


def test_signal_shutdown_all_is_trivial_noop() raises:
    """signal_shutdown_all() is a trivial no-op (no worker pthreads to signal).
    Calling it must not raise, change worker_count, or affect the reactor —
    the real serving shutdown is the binary's SIGTERM handler + final_flush."""
    var rt = GcpCloudRunRuntime[NoopSink](_make_noop_sink(), BACKEND_MOCK)
    rt.signal_shutdown_all()
    rt.signal_shutdown_all()  # idempotent.
    assert_equal(Int(rt.worker_count()), 1)
    _ = rt^


def test_no_worker_pthreads_spawned() raises:
    """THE COLLAPSE PROOF: the inline GcpCloudRunRuntime
    spawns ZERO worker pthreads. Building it, driving a poll cycle, calling
    signal_shutdown_all, and dropping it does NOT grow the process's live
    thread count.

    FALSIFIES the old worker-pool shape: the prior GcpCloudRunRuntime
    launched N worker pthreads on start() — this test
    would FAIL on that code (thread count would jump by N while the runtime
    was alive). With the single inline reactor there are no worker pthreads,
    so the count stays at baseline (±2 for libc transients).

    100 construct/poll/drop cycles also confirm no zombie-thread accumulation
    (the same shape as the PerCore no-leak soak, but here the ASSERTION is
    'never grew at all', not 'returned to baseline after a join')."""
    var baseline = _live_thread_count()
    if baseline < Int64(0):
        # Platform outside the Linux + Darwin probe matrix; skip.
        return

    # Single inline runtime alive — count must NOT grow (no worker pthread).
    var rt = GcpCloudRunRuntime[NoopSink](_make_noop_sink(), BACKEND_MOCK)
    _ = rt.poll_completions(0, Int32(0))
    rt.signal_shutdown_all()
    var during = _live_thread_count()
    var grow = during - baseline
    if grow < Int64(0):
        grow = -grow
    assert_true(
        grow <= Int64(2),
        String(
            "inline GcpCloudRunRuntime must spawn NO worker pthread:"
            " baseline="
        )
        + String(baseline)
        + String(" during=")
        + String(during)
        + String(" grow=")
        + String(grow),
    )
    _ = rt^

    # 100 cycles — no zombie-thread accumulation.
    for _ in range(100):
        var r = GcpCloudRunRuntime[NoopSink](_make_noop_sink(), BACKEND_MOCK)
        _ = r.poll_completions(0, Int32(0))
        _ = r^

    var final = _live_thread_count()
    if final < Int64(0):
        return
    var delta = final - baseline
    if delta < Int64(0):
        delta = -delta
    assert_true(
        delta <= Int64(2),
        String("thread leak across 100 inline-runtime cycles: baseline=")
        + String(baseline)
        + String(" final=")
        + String(final)
        + String(" delta=")
        + String(delta),
    )


def main() raises:
    test_trait_conformance_and_comptime_members()
    test_single_inline_reactor_worker_count_is_one()
    test_new_factory_builds_inline_runtime()
    test_poll_completions_out_of_range_raises()
    test_signal_shutdown_all_is_trivial_noop()
    test_no_worker_pthreads_spawned()
    print(
        "PASS komira_async.runtime.test_gcp_cloud_run_runtime"
        " (single inline reactor,"
        " no worker pthreads)"
    )
