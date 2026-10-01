# =============================================================================
# test_cancellation_state_machine.mojo
# =============================================================================
# cancellation surface for the state-machine track.
#
# Covers:
#   - IoOp.wait_with_token raises CancelledError when the token is cancelled
#     at entry.
#   - IoOp.wait_with_token returns the value when token is NOT cancelled
#     and the op is Ready (synthetic ready short-circuit).
#   - TaskContext.is_cancelled forwards correctly through clone().
#   - TaskContext.clone() preserves cancellation observability across clones.
#
# Cross-link: (cancellation cascade) + (v0.1
# scope: state-machine track ONLY; async/await track has NO cancellation
# RED on force_destroy).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.io_op import IoOp, ioop_ready
from komira_async.ops.waker_sink import NoopSink
from komira_async.primitives.never_origin import never_origin
from komira_async.runtime.task_context import TaskContext


def test_ioop_wait_with_token_pre_cancelled_raises() raises:
    """IoOp.wait_with_token raises immediately if token is
    cancelled at entry — even if the op itself is in Ready state.
    """
    var op = ioop_ready[Int, NoopSink, never_origin](value=42)
    var token = CancellationToken.new()
    token.cancel(String("test_reason_xyz"))
    var raised = False
    var msg = String("")
    try:
        var _v = op^.wait_with_token(token)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    # Verify the message contains "CancelledError" + the reason.
    assert_true(String("CancelledError") in msg)
    assert_true(String("test_reason_xyz") in msg)


def test_ioop_wait_with_token_uncancelled_returns() raises:
    """IoOp.wait_with_token returns the value if token is not
    cancelled and the op is Ready. Synthetic ready short-circuit.
    """
    var op = ioop_ready[Int, NoopSink, never_origin](value=99)
    var token = CancellationToken.new()
    var v = op^.wait_with_token(token)
    assert_equal(v, 99)


def test_task_context_construct() raises:
    """TaskContext bundles addr/addr/cancellation cleanly."""
    var token = CancellationToken.new()
    var ctx = TaskContext.make(
        worker_addr=Int(0xDEAD_BEEF),
        reactor_addr=Int(0xCAFE_BABE),
        cancellation=token^,
    )
    assert_equal(ctx.worker_addr, Int(0xDEAD_BEEF))
    assert_equal(ctx.reactor_addr, Int(0xCAFE_BABE))
    assert_false(ctx.is_cancelled())


def test_task_context_clone_observes_cancellation() raises:
    """clones share the underlying cancellation slot — cancelling
    via one observable handle is visible from the clone.
    """
    var token = CancellationToken.new()
    var ctx = TaskContext.make(
        worker_addr=Int(1),
        reactor_addr=Int(2),
        cancellation=token^,
    )
    var ctx_clone = ctx.clone()
    assert_false(ctx.is_cancelled())
    assert_false(ctx_clone.is_cancelled())
    # Cancel via the original.
    ctx.cancellation.cancel(String("x"))
    assert_true(ctx.is_cancelled())
    assert_true(ctx_clone.is_cancelled())


def test_task_context_clone_independent_descendants() raises:
    """cloning ctx via TaskContext.clone() preserves the
    parent-cancellation cascade (any-ancestor-cancelled means cancelled).
    """
    var parent_token = CancellationToken.new()
    var child_token = parent_token.child()
    var ctx_parent = TaskContext.make(
        worker_addr=Int(0), reactor_addr=Int(0),
        cancellation=parent_token^,
    )
    var ctx_child = TaskContext.make(
        worker_addr=Int(0), reactor_addr=Int(0),
        cancellation=child_token^,
    )
    assert_false(ctx_parent.is_cancelled())
    assert_false(ctx_child.is_cancelled())
    # Cancel parent — child observes via shared ancestor chain entry.
    ctx_parent.cancellation.cancel(String("parent dies"))
    assert_true(ctx_parent.is_cancelled())
    assert_true(ctx_child.is_cancelled())


def main() raises:
    test_ioop_wait_with_token_pre_cancelled_raises()
    print("PASS test_ioop_wait_with_token_pre_cancelled_raises")
    test_ioop_wait_with_token_uncancelled_returns()
    print("PASS test_ioop_wait_with_token_uncancelled_returns")
    test_task_context_construct()
    print("PASS test_task_context_construct")
    test_task_context_clone_observes_cancellation()
    print("PASS test_task_context_clone_observes_cancellation")
    test_task_context_clone_independent_descendants()
    print("PASS test_task_context_clone_independent_descendants")
    print("PASS komira_async cancellation state-machine track")
