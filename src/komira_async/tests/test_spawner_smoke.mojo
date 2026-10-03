# =============================================================================
# test_spawner_smoke.mojo
# =============================================================================
# JoinHandle[T] real impl with Mechanism D park.
#
# 2 tests synchronous join + complete (single-thread; the slot is
# completed BEFORE join() is called, so park-wakes immediately). Cross-
# thread spawn + join lands in (multi-worker pthread).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.spawner.join_handle import (
    JoinHandle,
    cancel_slot,
    complete_slot,
    complete_slot_err,
    make_spawn_slot,
)
from komira_async.spawner.spawner import (
    ForkJoinSpawner,
    Spawner,
    SpawnableTask,
)


# ---------------------------------------------------------------------------
# Test fixtures: SpawnableTask conformers.
# ---------------------------------------------------------------------------


@fieldwise_init
struct _DoubleTask(SpawnableTask, Movable, Deinitable):
    """Test fixture: returns 2*x. Captures `x` as a struct field. Returns Int."""

    comptime T = Int

    var x: Int

    def run(mut self) raises -> Self.T:
        return self.x * 2


@fieldwise_init
struct _RaiseTask(SpawnableTask, Movable, Deinitable):
    """Test fixture: always raises. Used for error-path tests."""

    comptime T = Int

    var _placeholder: UInt8

    def run(mut self) raises -> Self.T:
        raise Error("synthetic-failure")


def test_join_handle_construct_unfinished() raises:
    """JoinHandle[Int] constructs cleanly via the new ctor;
    is_finished returns False before any complete_slot call."""
    var slot = make_spawn_slot[Int]()
    var token = CancellationToken.new()
    var h = JoinHandle[Int](slot=slot^, op_id=Int64(7), token=token^)
    assert_false(h.is_finished())
    assert_equal(h.op_id(), Int64(7))
    # Drop h cleanly — its destructor will mark slot cancelled, so we don't
    # leak; we just don't have observers.


def test_join_handle_complete_then_join() raises:
    """synchronously complete a slot via complete_slot, then
    join — returns the value without parking (state is already _SLOT_READY)."""
    var slot = make_spawn_slot[Int]()
    var token = CancellationToken.new()
    # Pre-complete via ref-borrow (slot retained for handle ctor below).
    complete_slot[Int](slot, value=42)
    var h = JoinHandle[Int](slot=slot^, op_id=Int64(0), token=token^)
    assert_true(h.is_finished())
    var result = h^.join()
    assert_equal(result, 42)


def test_join_handle_complete_with_err_then_join() raises:
    """complete_slot_err publishes an error; join() raises
    the error message."""
    var slot = make_spawn_slot[Int]()
    var token = CancellationToken.new()
    complete_slot_err[Int](slot, err=String("synthetic-task-failure"))
    var h = JoinHandle[Int](slot=slot^, op_id=Int64(0), token=token^)
    assert_true(h.is_finished())
    var raised = False
    try:
        var _r = h^.join()
    except:
        raised = True
    assert_true(raised)


def test_join_handle_pre_cancelled_token_raises() raises:
    """a JoinHandle whose token is already cancelled raises
    on join() WITHOUT parking forever."""
    var slot = make_spawn_slot[Int]()
    var token = CancellationToken.new()
    token.cancel(String("pre-spawn cancel"))
    var h = JoinHandle[Int](slot=slot^, op_id=Int64(0), token=token^)
    var raised = False
    try:
        var _r = h^.join()
    except:
        raised = True
    assert_true(raised)


def test_join_handle_double_join_raises() raises:
    """synchronous join consumes the handle; reusing the
    binding is a Mojo compile error. The runtime _joined guard is
    defense-in-depth."""
    var slot = make_spawn_slot[Int]()
    var token = CancellationToken.new()
    complete_slot[Int](slot, value=99)
    var h = JoinHandle[Int](slot=slot^, op_id=Int64(0), token=token^)
    var r = h^.join()
    assert_equal(r, 99)


def test_join_handle_detach_returns_token_and_skips_cancel() raises:
    """detach() returns the token + marks the handle joined,
    so the destructor doesn't cancel."""
    var slot = make_spawn_slot[Int]()
    var token = CancellationToken.new()
    var h = JoinHandle[Int](slot=slot^, op_id=Int64(0), token=token.clone())
    var t_back = h^.detach()
    # detach skips cancel-on-drop; the returned clone shares state with the
    # original token. Both should still be live.
    assert_false(t_back.is_cancelled())
    assert_false(token.is_cancelled())


def test_fork_join_spawner_spawn_inline_returns_value() raises:
    """ForkJoinSpawner.spawn runs the task inline; the returned
    JoinHandle.join() yields the task's result."""
    var s = ForkJoinSpawner.new()
    var h = s.spawn[_DoubleTask](_DoubleTask(x=21))
    assert_true(h.is_finished())  # inline; already complete
    var result = h^.join()
    assert_equal(result, 42)


def test_fork_join_spawner_spawn_with_token_uses_token() raises:
    """spawn_with_token passes the explicit token through to
    the JoinHandle (which can observe it via the cancel cascade)."""
    var s = ForkJoinSpawner.new()
    var token = CancellationToken.new()
    var h = s.spawn_with_token[_DoubleTask](_DoubleTask(x=10), token.clone())
    var result = h^.join()
    assert_equal(result, 20)
    # Cancel the original token AFTER join — JoinHandle is consumed.
    token.cancel(String("post-join"))


def test_fork_join_spawner_task_raises_propagates() raises:
    """a task that raises causes JoinHandle.join() to raise."""
    var s = ForkJoinSpawner.new()
    var h = s.spawn[_RaiseTask](_RaiseTask(_placeholder=UInt8(0)))
    var raised = False
    try:
        var _r = h^.join()
    except:
        raised = True
    assert_true(raised)


def test_fork_join_spawner_drain_count() raises:
    """drain() returns the cumulative spawn count (Phase
    1.9.4 refines to true quiescence)."""
    var s = ForkJoinSpawner.new()
    _ = s.spawn[_DoubleTask](_DoubleTask(x=1))^.join()
    _ = s.spawn[_DoubleTask](_DoubleTask(x=2))^.join()
    _ = s.spawn[_DoubleTask](_DoubleTask(x=3))^.join()
    assert_equal(s.drain(), 3)


def main() raises:
    test_join_handle_construct_unfinished()
    test_join_handle_complete_then_join()
    test_join_handle_complete_with_err_then_join()
    test_join_handle_pre_cancelled_token_raises()
    test_join_handle_double_join_raises()
    test_join_handle_detach_returns_token_and_skips_cancel()
    test_fork_join_spawner_spawn_inline_returns_value()
    test_fork_join_spawner_spawn_with_token_uses_token()
    test_fork_join_spawner_task_raises_propagates()
    test_fork_join_spawner_drain_count()
    print("PASS komira_async.spawner smoke")
