# =============================================================================
# test_parked_morsel_slab.mojo
# =============================================================================
# ParkedMorselSlab[State] unit tests.
#
# Coverage:
#   * empty slab predicates
#   * park + take roundtrip
#   * take of unknown op_id returns None
#   * multiple parks, takes in arbitrary order
#   * contains() predicate
#   * compact-on-take preserves remaining keys
#   * State that holds heap (List[Int]) round-trips intact
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.runtime.parked_morsel_slab import ParkedMorselSlab


@fieldwise_init
struct _MorselState(Movable, Deinitable):
    """Test-only morsel state — Movable, holds a heap-tracking field
    (List[Int]) to exercise the slab's drop / take paths against
    non-trivial T."""
    var page_id: Int
    var bytes: List[Int]


def _mk_state(page_id: Int, fill: Int) -> _MorselState:
    """Helper to build a _MorselState with a given page_id + a single-
    element bytes list. Avoids the brittle `List[Int](e1, e2, ...)`
    positional literal — Mojo 0.26.3 List has no positional ctor."""
    var b = List[Int]()
    b.append(fill)
    return _MorselState(page_id=page_id, bytes=b^)


def test_parked_morsel_slab_empty() raises:
    var slab = ParkedMorselSlab[_MorselState]()
    assert_true(slab.is_empty())
    assert_equal(slab.len(), 0)
    assert_false(slab.contains(Int64(0)))
    assert_false(slab.contains(Int64(99)))


def test_parked_morsel_slab_park_then_take() raises:
    var slab = ParkedMorselSlab[_MorselState]()
    slab.park(op_id=Int64(7), state=_mk_state(page_id=42, fill=99)^)
    assert_false(slab.is_empty())
    assert_equal(slab.len(), 1)
    assert_true(slab.contains(Int64(7)))
    var taken = slab.take(Int64(7))
    assert_true(taken.__bool__())
    var v = taken.take()
    assert_equal(v.page_id, 42)
    assert_equal(len(v.bytes), 1)
    assert_equal(v.bytes[0], 99)
    # Slab is empty after take.
    assert_true(slab.is_empty())
    assert_false(slab.contains(Int64(7)))


def test_parked_morsel_slab_take_unknown_returns_none() raises:
    var slab = ParkedMorselSlab[_MorselState]()
    var taken = slab.take(Int64(123))
    assert_false(taken.__bool__())
    # park one, then take an unrelated op_id.
    slab.park(op_id=Int64(1), state=_mk_state(page_id=0, fill=0)^)
    var taken2 = slab.take(Int64(999))
    assert_false(taken2.__bool__())
    # Original entry untouched.
    assert_equal(slab.len(), 1)
    assert_true(slab.contains(Int64(1)))


def test_parked_morsel_slab_multiple_parks_arbitrary_take_order() raises:
    var slab = ParkedMorselSlab[_MorselState]()
    var i = 0
    while i < 8:
        slab.park(
            op_id=Int64(i),
            state=_mk_state(page_id=i * 10, fill=i)^,
        )
        i = i + 1
    assert_equal(slab.len(), 8)

    # Take in an arbitrary order: 3, 0, 7, 5, 1, 6, 4, 2.
    var order = List[Int64]()
    order.append(Int64(3))
    order.append(Int64(0))
    order.append(Int64(7))
    order.append(Int64(5))
    order.append(Int64(1))
    order.append(Int64(6))
    order.append(Int64(4))
    order.append(Int64(2))
    var j = 0
    while j < len(order):
        var op_id = order[j]
        var taken = slab.take(op_id)
        assert_true(taken.__bool__())
        var v = taken.take()
        assert_equal(v.page_id, Int(op_id) * 10)
        assert_equal(len(v.bytes), 1)
        assert_equal(v.bytes[0], Int(op_id))
        j = j + 1
    assert_true(slab.is_empty())


def test_parked_morsel_slab_compact_on_take_preserves_remaining() raises:
    """Take from the middle and verify the shift-on-take leaves all
    OTHER op_ids reachable + correctly mapped to their states."""
    var slab = ParkedMorselSlab[_MorselState]()
    slab.park(op_id=Int64(10), state=_mk_state(page_id=100, fill=1)^)
    slab.park(op_id=Int64(20), state=_mk_state(page_id=200, fill=2)^)
    slab.park(op_id=Int64(30), state=_mk_state(page_id=300, fill=3)^)
    # Take the middle.
    var taken = slab.take(Int64(20))
    assert_true(taken.__bool__())
    assert_equal(taken.value().page_id, 200)
    assert_equal(slab.len(), 2)
    # Both remaining entries still findable + correctly mapped.
    assert_true(slab.contains(Int64(10)))
    assert_true(slab.contains(Int64(30)))
    var t10 = slab.take(Int64(10))
    var t30 = slab.take(Int64(30))
    assert_true(t10.__bool__())
    assert_true(t30.__bool__())
    assert_equal(t10.value().page_id, 100)
    assert_equal(t30.value().page_id, 300)
    assert_true(slab.is_empty())


def test_parked_morsel_slab_capacity_ctor() raises:
    """Capacity-presized ctor produces a usable slab."""
    var slab = ParkedMorselSlab[_MorselState](capacity=64)
    assert_true(slab.is_empty())
    slab.park(op_id=Int64(42), state=_mk_state(page_id=4, fill=0)^)
    assert_equal(slab.len(), 1)


def main() raises:
    test_parked_morsel_slab_empty()
    test_parked_morsel_slab_park_then_take()
    test_parked_morsel_slab_take_unknown_returns_none()
    test_parked_morsel_slab_multiple_parks_arbitrary_take_order()
    test_parked_morsel_slab_compact_on_take_preserves_remaining()
    test_parked_morsel_slab_capacity_ctor()
    print(
        "PASS komira_async.runtime.parked_morsel_slab"
    )
