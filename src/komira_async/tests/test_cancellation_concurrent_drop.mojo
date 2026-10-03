# =============================================================================
# test_cancellation_concurrent_drop.mojo
# =============================================================================
# concurrent drop of cancellation tokens.
#
# Stress the cascade structure under varying drop scenarios that
# might surface ordering bugs:
#
#   - Drop children in REVERSE order (LIFO via Slab.pop()).
#   - Drop children via whole-slab drop (FIFO walk + bulk free).
#   - Drop root concurrently with children (interleaved scope drops).
#   - Drop uncancelled root while children survive.
#   - Clone the root + cancel via clone propagates correctly.
#
# This exercises ArcPointer refcount drop ordering — the cascade-chain
# walk in CancellationToken.is_cancelled() reads the parent slot via
# ArcPointer, so any drop-order pathology in the Arc implementation
# would surface here.
#
# Pointer discipline: zero new public-API pointers; standard
# CancellationToken.clone() / child() / Slab pattern.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_core.collections.slab import Slab


def test_drop_children_lifo() raises:
    """drop 1000 children in reverse-construction order.
    Slab.pop() returns Optional[T] — drops via Optional dtor."""
    var root = CancellationToken.new()
    var children = Slab[CancellationToken](capacity=1_000)
    for _ in range(1_000):
        children.append(root.child())
    root.cancel(String("lifo drop"))

    # LIFO drop via Slab.pop().
    while len(children) > 0:
        var c_opt = children.pop()
        # c_opt drops at end of iteration scope.
        assert_true(c_opt.value().is_cancelled())
    # Root remains cancellable.
    assert_true(root.is_cancelled())


def test_drop_children_bulk() raises:
    """drop 1000 children via whole-slab drop (FIFO walk
    by destructor order — Slab destroys live slots [0, len) in
    forward order)."""
    var root = CancellationToken.new()
    var children = Slab[CancellationToken](capacity=1_000)
    for _ in range(1_000):
        children.append(root.child())
    root.cancel(String("bulk drop"))

    # Verify all cancelled before drop.
    for i in range(1_000):
        assert_true(children.get(i).is_cancelled())
    _ = children^  # whole-slab drop.
    assert_true(root.is_cancelled())


def test_interleaved_construct_drop() raises:
    """alternate construction + drop of children. After
    each pair, root remains stable + cancellable."""
    var root = CancellationToken.new()
    for _ in range(500):
        var c = root.child()
        # Drop c immediately. Root's Arc-shared slot retains all
        # state; cascade is consistent.
        _ = c^
    # Cancel after all children dropped.
    root.cancel(String("interleaved"))
    assert_true(root.is_cancelled())


def test_drop_uncancelled_root_then_query_children() raises:
    """drop root WITHOUT cancelling, while children
    survive. Children's is_cancelled() must remain consistent (False,
    since neither parent nor child cancelled)."""
    # Inner scope: root drops here; children captured first.
    var children = Slab[CancellationToken](capacity=100)
    for _ in range(100):
        var root_local = CancellationToken.new()
        var child = root_local.child()
        children.append(child^)
        _ = root_local^  # root dies; child still holds Arc slot.

    # All children remain query-able and NOT cancelled.
    for i in range(100):
        assert_false(children.get(i).is_cancelled())


def test_root_clone_preserves_cancel_propagation() raises:
    """clone the root (second handle on same Arc slot);
    cancel via either handle propagates to all children."""
    var root_a = CancellationToken.new()
    var root_b = root_a.clone()
    var children = Slab[CancellationToken](capacity=100)
    for _ in range(100):
        children.append(root_a.child())

    # Cancel via root_b — root_a + children all observe.
    root_b.cancel(String("via clone"))
    assert_true(root_a.is_cancelled())
    assert_true(root_b.is_cancelled())
    for i in range(100):
        assert_true(children.get(i).is_cancelled())


def main() raises:
    test_drop_children_lifo()
    test_drop_children_bulk()
    test_interleaved_construct_drop()
    test_drop_uncancelled_root_then_query_children()
    test_root_clone_preserves_cancel_propagation()
    print("PASS komira_async.stress.test_cancellation_concurrent_drop")
