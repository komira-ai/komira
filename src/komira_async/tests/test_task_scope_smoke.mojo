# =============================================================================
# test_task_scope_smoke.mojo
# =============================================================================
# TaskScope + ComputeTaskScope smoke.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.io_op import IoOp, ioop_ready
from komira_async.ops.waker_sink import NoopSink
from komira_async.primitives.never_origin import never_origin
from komira_async.spawner.join_handle import (
    JoinHandle,
    complete_slot,
    make_spawn_slot,
)
from komira_async.spawner.spawner import (
    ForkJoinSpawner,
    SpawnableTask,
)
from komira_async.spawner.task_scope import (
    ComputeTaskScope,
    TaskScope,
)


@fieldwise_init
struct _FixedTask(SpawnableTask, Movable, Deinitable):
    comptime T = Int
    var x: Int

    def run(mut self) raises -> Self.T:
        return self.x


def test_compute_task_scope_construct_empty() raises:
    """a fresh ComputeTaskScope with no children waits cleanly."""
    var scope = ComputeTaskScope[Int].new()
    var results = scope.wait_all()
    assert_equal(len(results), 0)


def test_compute_task_scope_with_children() raises:
    """spawn 3 tasks via spawner; add to scope; wait_all
    collects 3 results."""
    var scope = ComputeTaskScope[Int].new()
    var spawner = ForkJoinSpawner.new()
    var h1 = spawner.spawn[_FixedTask](_FixedTask(x=10))
    var h2 = spawner.spawn[_FixedTask](_FixedTask(x=20))
    var h3 = spawner.spawn[_FixedTask](_FixedTask(x=30))
    scope.add(h1^)
    scope.add(h2^)
    scope.add(h3^)
    var results = scope.wait_all()
    assert_equal(len(results), 3)
    # ForkJoinSpawner runs inline so results are in spawn order.
    assert_equal(results[0], 10)
    assert_equal(results[1], 20)
    assert_equal(results[2], 30)


def test_compute_task_scope_double_wait_raises() raises:
    """calling wait_all twice raises."""
    var scope = ComputeTaskScope[Int].new()
    _ = scope.wait_all()
    var raised = False
    try:
        _ = scope.wait_all()
    except:
        raised = True
    assert_true(raised)


def test_compute_task_scope_token_clones_share_state() raises:
    """scope.token() returns a clone; scope.cancel() cascades
    to the clone (shared state)."""
    var scope = ComputeTaskScope[Int].new()
    var t = scope.token()
    assert_false(t.is_cancelled())
    scope.cancel()
    assert_true(t.is_cancelled())
    # Drain the scope so __del__ doesn't print the violation message.
    var _r = scope.wait_all()
    _ = _r^


def test_task_scope_construct_empty() raises:
    """TaskScope with IoOp children — empty scope waits cleanly."""
    var scope = TaskScope[Int, NoopSink, never_origin].new()
    var results = scope.wait_all()
    assert_equal(len(results), 0)


def test_task_scope_with_synthetic_ready_children() raises:
    """spawn 3 synthetic-ready IoOp children; wait_all returns
    3 results."""
    var scope = TaskScope[Int, NoopSink, never_origin].new()
    scope.spawn(ioop_ready[Int, NoopSink, never_origin](7))
    scope.spawn(ioop_ready[Int, NoopSink, never_origin](8))
    scope.spawn(ioop_ready[Int, NoopSink, never_origin](9))
    var results = scope.wait_all()
    assert_equal(len(results), 3)
    assert_equal(results[0], 7)
    assert_equal(results[1], 8)
    assert_equal(results[2], 9)


def main() raises:
    test_compute_task_scope_construct_empty()
    test_compute_task_scope_with_children()
    test_compute_task_scope_double_wait_raises()
    test_compute_task_scope_token_clones_share_state()
    test_task_scope_construct_empty()
    test_task_scope_with_synthetic_ready_children()
    print("PASS komira_async.spawner.task_scope smoke")
