# =============================================================================
# test_cancellation_smoke.mojo
# =============================================================================
# real-impl tests for komira_async.cancellation.
#   - Token tree: child cancels when parent cancels.
#   - cancel(reason) is idempotent.
#   - ExecutionBudget.check() exhausts after N calls and cancels its bound token.
#   - never() returns a token that is never cancellable.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.budget import ExecutionBudget
from komira_async.cancellation.cancelled_error import CancelledError
from komira_async.cancellation.token import Cancellable, CancellationToken


def test_token_default_not_cancelled() raises:
    """a freshly constructed token is not cancelled."""
    var t = CancellationToken.new()
    assert_false(t.is_cancelled())
    assert_equal(t.reason(), String(""))


def test_token_cancel_idempotent() raises:
    """cancel(reason) flips the flag; reason() returns the reason.
    Calling cancel twice is idempotent — the first reason wins."""
    var t = CancellationToken.new()
    t.cancel(String("oom"))
    assert_true(t.is_cancelled())
    assert_equal(t.reason(), String("oom"))
    # Second cancel is a no-op (idempotent); the first reason wins.
    t.cancel(String("second"))
    assert_true(t.is_cancelled())
    assert_equal(t.reason(), String("oom"))


def test_token_child_cancels_when_parent_cancels() raises:
    """child token cascades from parent cancel."""
    var parent = CancellationToken.new()
    var child = parent.child()
    assert_false(parent.is_cancelled())
    assert_false(child.is_cancelled())
    parent.cancel(String("parent reason"))
    assert_true(parent.is_cancelled())
    assert_true(child.is_cancelled())
    # Child sees parent's reason since child's local reason is empty.
    assert_equal(child.reason(), String("parent reason"))


def test_token_parent_not_cancelled_when_child_cancels() raises:
    """cancellation is one-way — child cancel does NOT cascade up."""
    var parent = CancellationToken.new()
    var child = parent.child()
    child.cancel(String("child only"))
    assert_true(child.is_cancelled())
    assert_false(parent.is_cancelled())
    assert_equal(child.reason(), String("child only"))


def test_token_never() raises:
    """never() returns a token that is never cancellable."""
    var t = CancellationToken.never()
    assert_false(t.is_cancelled())
    # cancel() on a never-token is a no-op (silently ignored).
    t.cancel(String("ignore me"))
    assert_false(t.is_cancelled())


def test_token_clone_shares_state() raises:
    """CancellationToken.clone() returns a second handle pointing
    at the SAME shared slot. Cancelling either handle cancels both.

    NOT Copyable (Mojo 0.26.3 cannot synthesize implicit copy for
    List[ArcPointer[T]] field; explicit clone() matches engine's
    DynamicFilter.copy() pattern at runtime/dynamic_filter.mojo:58)."""
    var t1 = CancellationToken.new()
    var t2 = t1.clone()
    assert_false(t1.is_cancelled())
    assert_false(t2.is_cancelled())
    t1.cancel(String("via t1"))
    assert_true(t1.is_cancelled())
    assert_true(t2.is_cancelled())
    assert_equal(t2.reason(), String("via t1"))


def test_cancelled_error_imports() raises:
    """CancelledError re-export still works."""
    var e = CancelledError(op_id=Int64(0), reason=String(""))
    assert_true(e.reason.byte_length() == 0)


def test_execution_budget_morsels_exhausts() raises:
    """ExecutionBudget(morsels=N).check() succeeds N times then
    cancels the bound token + raises CancelledError."""
    var t = CancellationToken.new()
    # Clone token into budget so we retain a handle for is_cancelled() check.
    var b = ExecutionBudget(deadline_ns=Int64(0), morsels=Int64(3), bound_token=t.clone())
    # First three checks succeed without raising.
    b.check()
    b.check()
    b.check()
    # Fourth check exhausts the budget; cancels token; raises.
    var raised = False
    try:
        b.check()
    except:
        raised = True
    assert_true(raised)
    assert_true(t.is_cancelled())


def test_execution_budget_zero_morsels_immediate_cancel() raises:
    """budget with 0 morsels cancels on the first check."""
    var t = CancellationToken.new()
    var b = ExecutionBudget(deadline_ns=Int64(0), morsels=Int64(0), bound_token=t.clone())
    var raised = False
    try:
        b.check()
    except:
        raised = True
    assert_true(raised)
    assert_true(t.is_cancelled())


# Cancellable trait conformance smoke — define a tiny struct that conforms.
@fieldwise_init
struct _TinyCancellable(Cancellable, Deinitable):
    var token: CancellationToken

    def cancellation_token(self) -> CancellationToken:
        # Return-by-value of a non-Copyable type from `self` requires
        # explicit clone() (refcount bump on each slot).
        return self.token.clone()

    def is_cancelled(self) -> Bool:
        return self.token.is_cancelled()


def test_cancellable_trait_conformance() raises:
    """Cancellable trait elaborates against a user struct."""
    var t = CancellationToken.new()
    # Clone t into the test struct so we retain a handle for cancel.
    var c = _TinyCancellable(token=t.clone())
    assert_false(c.is_cancelled())
    t.cancel(String("via token"))
    assert_true(c.is_cancelled())


def main() raises:
    test_token_default_not_cancelled()
    test_token_cancel_idempotent()
    test_token_child_cancels_when_parent_cancels()
    test_token_parent_not_cancelled_when_child_cancels()
    test_token_never()
    test_token_clone_shares_state()
    test_cancelled_error_imports()
    test_execution_budget_morsels_exhausts()
    test_execution_budget_zero_morsels_immediate_cancel()
    test_cancellable_trait_conformance()
    print("PASS komira_async.cancellation smoke")
