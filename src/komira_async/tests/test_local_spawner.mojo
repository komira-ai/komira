# =============================================================================
# test_local_spawner.mojo
# =============================================================================
# LocalSpawner[S] unit tests.
#
# Coverage:
#   * Construct LocalSpawner standalone; spawn-with-no-workers raises.
#   * spawn-and-join round-trip on a trivial Task; result returned by COPY.
#   * Multiple sequential spawns into ONE LocalSpawner.
#   * Multiple Task TYPES into ONE spawner — verifies per-Task fn-ptr
#     monomorphization across heterogeneous tasks.
#   * spawn_with_token normal path.
#   * Pre-cancelled token skips run() — trampoline writes _SLOT_CANCELLED.
#   * Task that raises causes JoinHandle.join() to raise.
#   * JoinHandle drop without join cancels the task.
#   * Spawner drop with un-drained entries does not panic.
#   * drain() returns the cumulative spawn count (after all tasks
#     reached terminal state).
#   * rt.spawner() accessor round-trip.
#
# Model: spawner REQUIRES at least one started worker. Every
# spawn-related test attaches workers + starts the runtime + tears
# down with shutdown.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.spawner.local_spawner import LocalSpawner
from komira_async.spawner.spawner import SpawnableTask


# ---------------------------------------------------------------------------
# Test fixtures: SpawnableTask conformers.
# ---------------------------------------------------------------------------


@fieldwise_init
struct _DoubleTask(SpawnableTask, Movable, Deinitable):
    """Trivial POD task — returns 2*x."""

    comptime T = Int

    var x: Int

    def run(mut self) raises -> Self.T:
        return self.x * 2


@fieldwise_init
struct _AddOneTask(SpawnableTask, Movable, Deinitable):
    """Different-shaped task — returns x + 1."""

    comptime T = Int

    var x: Int

    def run(mut self) raises -> Self.T:
        return self.x + 1


@fieldwise_init
struct _StringLenTask(SpawnableTask, Movable, Deinitable):
    """Heap-owning Task — String field. Drop-correctness check."""

    comptime T = Int

    var msg: String
    var multiplier: Int

    def run(mut self) raises -> Self.T:
        return self.msg.byte_length() * self.multiplier


@fieldwise_init
struct _RaiseTask(SpawnableTask, Movable, Deinitable):
    """Always-raises task — verifies error propagation."""

    comptime T = Int

    var _placeholder: UInt8

    def run(mut self) raises -> Self.T:
        raise Error("synthetic-failure-from-task")


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------


def test_local_spawner_construct_standalone() raises:
    """LocalSpawner constructs cleanly without a runtime; pending=0;
    drain=0. spawn() raises (no workers attached) — matches
    contract that spawn() requires the runtime's per-worker queues.
    """
    var sp = LocalSpawner[NoopSink]()
    assert_equal(sp.pending_count(), 0)
    assert_equal(sp.drain(), 0)
    assert_equal(sp.worker_count(), 0)


def test_spawn_no_workers_raises() raises:
    """spawn() on a runtime with zero workers
    raises the typed "no workers attached" Error."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    ref s = rt.spawner()
    var raised = False
    try:
        var _h = s.spawn[_DoubleTask](_DoubleTask(x=1))
    except:
        raised = True
    assert_true(raised)


def test_spawn_and_join_double_task() raises:
    """spawn[_DoubleTask] returns a JoinHandle
    whose join yields x*2. The trampoline runs on a worker pthread (true
    async); JoinHandle.join parks on the slot wake-word until the
    worker's drain step runs the Task.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var h = s.spawn[_DoubleTask](_DoubleTask(x=21))
    var result = h^.join()
    assert_equal(result, 42)
    rt.shutdown()


def test_spawn_multiple_same_type() raises:
    """4 sequential spawns of the same
    _DoubleTask; each returns its own JoinHandle whose join yields the
    right value.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var h1 = s.spawn[_DoubleTask](_DoubleTask(x=1))
    var h2 = s.spawn[_DoubleTask](_DoubleTask(x=2))
    var h3 = s.spawn[_DoubleTask](_DoubleTask(x=3))
    var h4 = s.spawn[_DoubleTask](_DoubleTask(x=4))
    var r1 = h1^.join()
    var r2 = h2^.join()
    var r3 = h3^.join()
    var r4 = h4^.join()
    assert_equal(r1, 2)
    assert_equal(r2, 4)
    assert_equal(r3, 6)
    assert_equal(r4, 8)
    rt.shutdown()


def test_spawn_heterogeneous_task_types() raises:
    """spawn THREE different concrete Task
    types into ONE spawner. Verifies per-Task fn-ptr monomorphization.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var h_dbl = s.spawn[_DoubleTask](_DoubleTask(x=5))           # 10
    var h_add = s.spawn[_AddOneTask](_AddOneTask(x=99))          # 100
    var h_str = s.spawn[_StringLenTask](
        _StringLenTask(msg=String("hello world"), multiplier=3)   # 33
    )
    var r_dbl = h_dbl^.join()
    var r_add = h_add^.join()
    var r_str = h_str^.join()
    assert_equal(r_dbl, 10)
    assert_equal(r_add, 100)
    assert_equal(r_str, 33)
    rt.shutdown()


def test_spawn_with_token_normal_path() raises:
    """spawn_with_token with a not-yet-cancelled
    token runs the task normally and returns the result.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var token = CancellationToken.new()
    var h = s.spawn_with_token[_DoubleTask](_DoubleTask(x=10), token^)
    var r = h^.join()
    assert_equal(r, 20)
    rt.shutdown()


def test_spawn_with_pre_cancelled_token_skips_run() raises:
    """pre-cancelled token: trampoline observes
    the cancellation BEFORE owned[].task.run() and writes _SLOT_CANCELLED;
    JoinHandle.join raises CancelledError.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var token = CancellationToken.new()
    token.cancel(String("pre-spawn-cancel"))
    var h = s.spawn_with_token[_DoubleTask](_DoubleTask(x=99), token^)
    var raised = False
    try:
        var _r = h^.join()
    except:
        raised = True
    assert_true(raised)
    rt.shutdown()


def test_spawn_task_raises_propagates() raises:
    """task that raises causes
    JoinHandle.join() to raise via complete_slot_err.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var h = s.spawn[_RaiseTask](_RaiseTask(_placeholder=UInt8(0)))
    var raised = False
    try:
        var _r = h^.join()
    except:
        raised = True
    assert_true(raised)
    rt.shutdown()


def test_join_handle_drop_without_join_cancels() raises:
    """dropping a JoinHandle without join()
    cancels its task. The task may or may not have run yet (race with
    worker drain). Either way, the destructor runs without panic.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var h = s.spawn[_DoubleTask](_DoubleTask(x=7))
    _ = h^  # consume + drop without join
    # drain() blocks until the task either ran or was cancel-observed.
    var n = s.drain()
    assert_equal(n, 1)
    rt.shutdown()


def test_spawner_drop_with_undrained_entries_no_panic() raises:
    """dropping a runtime with un-joined
    handles (helper-fn scope) must not panic.
    """
    var probe = _drop_with_entries_helper()
    assert_equal(probe, 3)


def _drop_with_entries_helper() raises -> Int:
    """Helper for `test_spawner_drop_with_undrained_entries_no_panic`.
    Spawns 3 tasks, drops handles without joining, drains, shuts down,
    returns the cumulative spawn count.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var h1 = s.spawn[_DoubleTask](_DoubleTask(x=1))
    var h2 = s.spawn[_DoubleTask](_DoubleTask(x=2))
    var h3 = s.spawn[_DoubleTask](_DoubleTask(x=3))
    _ = h1^
    _ = h2^
    _ = h3^
    var n = s.drain()
    rt.shutdown()
    return n


def test_drain_counts_cumulative_spawns() raises:
    """drain returns the cumulative spawn
    count after all tasks reached terminal state.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    _ = s.spawn[_DoubleTask](_DoubleTask(x=1))^.join()
    assert_equal(s.drain(), 1)
    _ = s.spawn[_DoubleTask](_DoubleTask(x=2))^.join()
    _ = s.spawn[_DoubleTask](_DoubleTask(x=3))^.join()
    assert_equal(s.drain(), 3)
    rt.shutdown()


def test_spawner_accessor_via_runtime() raises:
    """round-trip through the runtime's
    `rt.spawner()` accessor.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref s = rt.spawner()
    var h = s.spawn[_DoubleTask](_DoubleTask(x=11))
    var result = h^.join()
    assert_equal(result, 22)
    rt.shutdown()


def main() raises:
    test_local_spawner_construct_standalone()
    test_spawn_no_workers_raises()
    test_spawn_and_join_double_task()
    test_spawn_multiple_same_type()
    test_spawn_heterogeneous_task_types()
    test_spawn_with_token_normal_path()
    test_spawn_with_pre_cancelled_token_skips_run()
    test_spawn_task_raises_propagates()
    test_join_handle_drop_without_join_cancels()
    test_spawner_drop_with_undrained_entries_no_panic()
    test_drain_counts_cumulative_spawns()
    test_spawner_accessor_via_runtime()
    print(
        "PASS komira_async.spawner.local_spawner"
        " (cross-pthread enqueue)"
    )
