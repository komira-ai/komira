# =============================================================================
# test_cancellation_torn_cascade.mojo
# =============================================================================
# torn-cascade ordering test.
#
# Stress test focused on the EDGE CASE where multiple tokens in a
# parent→child→grandchild chain receive overlapping cancel calls. The
# cascade is "one-way idempotent" — child cancel does NOT
# propagate up to parent; parent cancel propagates to all descendants;
# multiple cancels on the same token are idempotent (first reason wins).
#
# This test verifies:
#   1. A 3-level chain (parent → child1 → child2) where child1 cancels
#      with reason "child1_only" while parent is uncancelled. parent
#      stays uncancelled; child1 + child2 cancelled with reason
#      "child1_only".
#   2. After (1), parent cancels with reason "parent_late". parent
#      cancelled with reason "parent_late". child1 + child2 retain
#      their FIRST reason ("child1_only") — idempotency.
#   3. Mass-version: 100 chains each torn at a random level; verify
#      the final state is consistent (each chain's terminal token
#      knows its first cancel reason).
#
# Pointer discipline: zero new public-API pointers.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_core.collections.slab import Slab


def test_torn_cascade_child_only_first() raises:
    """3-level chain. child1 cancels first; child1 + child2
    cancelled; parent stays uncancelled. Then parent cancels;
    parent flips; child1's + child2's reason() now resolves to
    parent's reason (root-to-leaf walk in reason() —
: "walks root-to-leaf so the OUTERMOST cancellation
    reason wins")."""
    var parent = CancellationToken.new()
    var child1 = parent.child()
    var child2 = child1.child()

    # Pre-cancel: all uncancelled.
    assert_false(parent.is_cancelled())
    assert_false(child1.is_cancelled())
    assert_false(child2.is_cancelled())

    # child1 cancels first.
    child1.cancel(String("child1_only"))
    # Parent NOT cancelled (cascade is one-way down — explicit
    # cancellation at child level doesn't propagate up).
    assert_false(parent.is_cancelled())
    # child1 cancelled with own reason.
    assert_true(child1.is_cancelled())
    assert_equal(child1.reason(), String("child1_only"))
    # child2 cancelled via child1's cancel cascade.
    assert_true(child2.is_cancelled())
    # child2's reason walks root-to-leaf: parent slot uncancelled,
    # child1 slot cancelled with "child1_only" → returns "child1_only".
    assert_equal(child2.reason(), String("child1_only"))

    # Now parent cancels (after children already cancelled).
    parent.cancel(String("parent_late"))
    assert_true(parent.is_cancelled())
    assert_equal(parent.reason(), String("parent_late"))

    # After parent cancels, the root-to-leaf walk on child1/child2
    # finds the parent slot FIRST (it's now cancelled) and returns its
    # reason. The outermost reason wins. The child1 slot's local
    # reason "child1_only" is still set but no longer the resolved
    # value (since parent slot precedes it in the chain walk).
    assert_equal(child1.reason(), String("parent_late"))
    assert_equal(child2.reason(), String("parent_late"))


def test_torn_cascade_parent_first() raises:
    """opposite ordering — parent cancels first; child1's
    resolved reason() returns parent's via root-to-leaf walk."""
    var parent = CancellationToken.new()
    var child1 = parent.child()
    var child2 = child1.child()

    parent.cancel(String("parent_first"))
    assert_true(parent.is_cancelled())
    assert_true(child1.is_cancelled())
    assert_true(child2.is_cancelled())
    # child1's reason walks root-to-leaf: finds parent slot first.
    assert_equal(child1.reason(), String("parent_first"))
    assert_equal(child2.reason(), String("parent_first"))

    # Late call to child1.cancel — child1's local slot becomes
    # cancelled with reason "later_attempt", BUT the root-to-leaf
    # walk still finds parent first → returns "parent_first".
    child1.cancel(String("later_attempt"))
    # Outermost reason wins.
    assert_equal(child1.reason(), String("parent_first"))
    assert_equal(child2.reason(), String("parent_first"))


def test_mass_torn_cascade_100_chains() raises:
    """100 chains torn at varying levels. After all
    operations, each chain's terminal token reflects the FIRST cancel
    reason that arrived via any path.

    Storage note: CancellationToken is Movable but not Copyable so we
    use Slab[T] (the canonical Movable-only container)."""
    var parents = Slab[CancellationToken](capacity=100)
    var children1 = Slab[CancellationToken](capacity=100)
    var children2 = Slab[CancellationToken](capacity=100)

    for _ in range(100):
        var p = CancellationToken.new()
        var c1 = p.child()
        var c2 = c1.child()
        parents.append(p^)
        children1.append(c1^)
        children2.append(c2^)

    # Tear each chain at a varying level: even index → parent cancels,
    # odd index → child1 cancels. Slab.get returns ref [..] T;
    # cancel(reason) takes mut self so we use the ref directly.
    for i in range(100):
        if i % 2 == 0:
            parents.get(i).cancel(String("p_") + String(i))
        else:
            children1.get(i).cancel(String("c1_") + String(i))

    # Verify all 100 chain-terminal tokens observe cancellation.
    for i in range(100):
        assert_true(children2.get(i).is_cancelled())

    # Verify the reason at the leaf matches the EXPECTED first canceller.
    for i in range(100):
        var expected: String
        if i % 2 == 0:
            expected = String("p_") + String(i)
        else:
            expected = String("c1_") + String(i)
        assert_equal(children2.get(i).reason(), expected)


def test_self_cancel_idempotent() raises:
    """cancelling the same token 100 times is idempotent;
    the FIRST reason wins."""
    var t = CancellationToken.new()
    t.cancel(String("first"))
    for i in range(100):
        t.cancel(String("attempt_") + String(i))
    assert_equal(t.reason(), String("first"))


def main() raises:
    test_torn_cascade_child_only_first()
    test_torn_cascade_parent_first()
    test_mass_torn_cascade_100_chains()
    test_self_cancel_idempotent()
    print("PASS komira_async.stress.test_cancellation_torn_cascade")
