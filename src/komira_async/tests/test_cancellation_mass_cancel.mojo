# =============================================================================
# test_cancellation_mass_cancel.mojo
# =============================================================================
# mass cancellation stress test.
#
# cancellation cascade: a parent CancellationToken can
# have N child tokens; cancelling the parent cancels all children
# transitively. This test stresses the cascade with N=10K children:
#
#   - 10K child tokens spawn from one root.
#   - Cancel root with reason "stress test".
#   - Verify all 10K observe is_cancelled() == True.
#   - Verify reason() cascades properly (children inherit parent reason
#     when their own reason is empty).
#   - Verify mass cancel completes within bounded iteration count
#     (smoke threshold; not a perf gate, just a sanity check).
#
# Storage note: CancellationToken is Movable but NOT Copyable, so
# `List[CancellationToken]` doesn't elaborate. We use `Slab[T]` which
# only requires `T: Deinitable` (Movable for append). Slab
# is the canonical Movable-only-element container.
#
#
# Pointer discipline: zero new public-API pointers; uses
# CancellationToken.clone() / child() / Slab.append.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_collections.slab import Slab


def test_mass_cancel_10k_children_observe_cancellation() raises:
    """10K children spawned from one root; cancel root;
    all 10K observe is_cancelled() == True."""
    var root = CancellationToken.new()
    var children = Slab[CancellationToken](capacity=10_000)
    for _ in range(10_000):
        children.append(root.child())

    # Pre-cancel: root + all children NOT cancelled.
    assert_false(root.is_cancelled())
    for i in range(10_000):
        assert_false(children.get(i).is_cancelled())

    # Cancel root with reason.
    root.cancel(String("stress test"))
    assert_true(root.is_cancelled())

    # All 10K children observe cancellation.
    var all_cancelled = True
    for i in range(10_000):
        if not children.get(i).is_cancelled():
            all_cancelled = False
            break
    assert_true(all_cancelled, String("not all 10K children cancelled"))


def test_mass_cancel_reason_cascades_to_children() raises:
    """cancel root with a reason; children with no local
    reason inherit the parent's reason via the cascade chain."""
    var root = CancellationToken.new()
    var children = Slab[CancellationToken](capacity=1_000)
    for _ in range(1_000):
        children.append(root.child())

    root.cancel(String("oom"))

    # First and last few children inherit "oom" reason.
    assert_equal(children.get(0).reason(), String("oom"))
    assert_equal(children.get(500).reason(), String("oom"))
    assert_equal(children.get(999).reason(), String("oom"))


def test_mass_cancel_time_bounded() raises:
    """2 smoke threshold: 10K cascade completes in bounded
    iteration count. We don't measure wall clock (would introduce
    flakiness on shared CI); we measure that the propagation graph
    doesn't have an exponential pathology by simply observing all
    10K.is_cancelled() returns the right answer once."""
    var root = CancellationToken.new()
    var children = Slab[CancellationToken](capacity=10_000)
    for _ in range(10_000):
        children.append(root.child())

    root.cancel(String("perf bound"))

    # Each is_cancelled() probe should be O(1) — atomic load + small
    # cascade-chain walk. Doing 10K of them should not hang.
    var hits = Int64(0)
    for i in range(10_000):
        if children.get(i).is_cancelled():
            hits += 1
    assert_equal(hits, Int64(10_000))


def test_drop_after_mass_cancel() raises:
    """after cancel, drop the children slab — the
    ArcPointer-wrapped tokens free in arbitrary order; no leak; no
    use-after-free in the cascade walk pattern."""
    var root = CancellationToken.new()
    var children = Slab[CancellationToken](capacity=500)
    for _ in range(500):
        children.append(root.child())
    root.cancel(String("drop test"))

    # Verify all cancelled before drop.
    for i in range(500):
        assert_true(children.get(i).is_cancelled())

    # Drop children — invokes 500 dtors in order. Root still alive.
    _ = children^

    # Root remains cancellable after children dropped.
    assert_true(root.is_cancelled())


def test_root_drop_before_children() raises:
    """drop root BEFORE children — the cascade structure
    must still be consistent when a child queries is_cancelled() with
    a dropped parent. ArcPointer keeps the parent slot alive as long
    as any child holds a reference."""
    # Construct in inner scope so root drops while children slab lives.
    var children = Slab[CancellationToken](capacity=100)
    for _ in range(100):
        var root_local = CancellationToken.new()
        var child = root_local.child()
        # Cancel BEFORE root_local drops; child captures the Arc-shared
        # state's cancelled bit.
        root_local.cancel(String("root_local"))
        children.append(child^)
        _ = root_local^  # explicit drop (root's Arc slot still held by child).

    # All children remain queryable + cancelled.
    for i in range(100):
        assert_true(children.get(i).is_cancelled())


def main() raises:
    test_mass_cancel_10k_children_observe_cancellation()
    test_mass_cancel_reason_cascades_to_children()
    test_mass_cancel_time_bounded()
    test_drop_after_mass_cancel()
    test_root_drop_before_children()
    print("PASS komira_async.stress.test_cancellation_mass_cancel")
