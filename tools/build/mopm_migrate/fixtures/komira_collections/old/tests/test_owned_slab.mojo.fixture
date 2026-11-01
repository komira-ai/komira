# =============================================================================
# Tests for Slab[T: Movable] -- heap primitive with auto-synth move
# =============================================================================
#
# Coverage:
#   - Construction (empty, with_capacity, zero/negative capacity)
#   - len / capacity / is_empty
#   - append + grow (past initial capacity, geometric)
#   - set / get
#   - Move semantics (empty slab move, populated slab move)
#   - Drop-on-destruct (TrackedValue counter)
#   - resize grow + no-op
#   - unsafe_ptr raw access round-trip
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.memory import UnsafePointer, alloc

from komira_collections.slab import Slab


# =============================================================================
# TrackedValue -- Movable-only type whose destructor increments a counter.
# =============================================================================

struct TrackedValue(Movable):
    """Test-only type that increments *_counter on destruction.

    SAFETY: _counter points to a caller-owned Int that must outlive this value.
    Movable-only: no __copyinit__ is defined, so List[TrackedValue] would
    fail to compile. This is precisely the constraint Slab is designed
    to satisfy.
    """
    var _id: Int
    var _counter: UnsafePointer[Int, MutUntrackedOrigin]

    def __init__(out self, id: Int, counter: UnsafePointer[Int, MutUntrackedOrigin]):
        self._id = id
        self._counter = counter

    # Auto-synth __moveinit__: bitwise copy of fields. Moved-from source is
    # consumed by `^` transfer; its destructor does NOT fire (this is Mojo's
    # standard move semantics). Only the final owner's __del__ increments.

    def __deinit__(deinit self):
        # SAFETY: _counter points to caller's heap-allocated Int live for
        # the duration of this test.
        self._counter[] += 1

    @always_inline
    def id(self) -> Int:
        return self._id


def _alloc_counter() -> UnsafePointer[Int, MutUntrackedOrigin]:
    var ptr = alloc[Int](1)
    ptr.unsafe_write(0)
    return ptr


# =============================================================================
# Plain-data test type (bitwise-trivial, no destructor side effect).
# =============================================================================

struct PlainT(Movable):
    var a: Int64
    var b: Int64

    def __init__(out self, a: Int64, b: Int64):
        self.a = a
        self.b = b


# =============================================================================
# Tests
# =============================================================================

def test_empty_construction() raises:
    """Default constructor yields a slab with zero len and zero capacity."""
    var slab = Slab[PlainT]()
    assert_equal(slab.len(), 0)
    assert_equal(slab.capacity(), 0)
    assert_true(slab.is_empty())


def test_with_capacity() raises:
    """Construction with capacity allocates but leaves len at 0."""
    var slab = Slab[PlainT](capacity=16)
    assert_equal(slab.len(), 0)
    assert_equal(slab.capacity(), 16)
    assert_true(slab.is_empty())


def test_with_zero_capacity() raises:
    """capacity=0 should behave like the default constructor (no alloc)."""
    var slab = Slab[PlainT](capacity=0)
    assert_equal(slab.len(), 0)
    assert_equal(slab.capacity(), 0)


def test_append_and_get_plain() raises:
    """Append a few PlainT values and read them back via get()."""
    var slab = Slab[PlainT](capacity=4)
    slab.append(PlainT(1, 10))
    slab.append(PlainT(2, 20))
    slab.append(PlainT(3, 30))

    assert_equal(slab.len(), 3)
    assert_equal(slab.capacity(), 4)
    assert_equal(slab.get(0).a, Int64(1))
    assert_equal(slab.get(0).b, Int64(10))
    assert_equal(slab.get(1).a, Int64(2))
    assert_equal(slab.get(2).a, Int64(3))
    assert_equal(slab.get(2).b, Int64(30))


def test_append_past_initial_capacity_triggers_grow() raises:
    """Appending beyond capacity doubles the buffer (min 4)."""
    var slab = Slab[PlainT]()  # cap=0
    # First append grows to 4
    slab.append(PlainT(100, 1))
    assert_equal(slab.capacity(), 4)
    slab.append(PlainT(101, 2))
    slab.append(PlainT(102, 3))
    slab.append(PlainT(103, 4))
    assert_equal(slab.capacity(), 4)
    # Fifth append grows to 8
    slab.append(PlainT(104, 5))
    assert_equal(slab.capacity(), 8)
    assert_equal(slab.len(), 5)
    # Verify all 5 elements survived the realloc
    assert_equal(slab.get(0).a, Int64(100))
    assert_equal(slab.get(4).a, Int64(104))
    assert_equal(slab.get(4).b, Int64(5))


def test_resize_preserves_elements() raises:
    """Explicit resize grow keeps existing elements in order."""
    var slab = Slab[PlainT](capacity=2)
    slab.append(PlainT(1, 1))
    slab.append(PlainT(2, 2))
    slab.resize(32)
    assert_equal(slab.capacity(), 32)
    assert_equal(slab.len(), 2)
    assert_equal(slab.get(0).a, Int64(1))
    assert_equal(slab.get(1).a, Int64(2))


def test_resize_noop_when_smaller() raises:
    """resize(new_cap <= cap) is a no-op, no shrink."""
    var slab = Slab[PlainT](capacity=32)
    slab.append(PlainT(7, 7))
    slab.resize(4)
    assert_equal(slab.capacity(), 32)
    assert_equal(slab.len(), 1)


def test_set_replaces_element() raises:
    """set() destroys old slot and moves in new value."""
    var slab = Slab[PlainT](capacity=4)
    slab.append(PlainT(1, 1))
    slab.append(PlainT(2, 2))
    slab.set(1, PlainT(99, 99))
    assert_equal(slab.get(1).a, Int64(99))
    assert_equal(slab.get(1).b, Int64(99))
    assert_equal(slab.get(0).a, Int64(1))  # unchanged


def test_unsafe_ptr_roundtrip() raises:
    """The base pointer gives reads that match get().

    There is no public `unsafe_ptr()` (it would leak a raw pointer across
    the API). `_unsafe_ptr()` is the module-internal accessor and is
    origin-TIED to `self` rather than wildcard.
    """
    var slab = Slab[PlainT](capacity=4)
    slab.append(PlainT(11, 22))
    slab.append(PlainT(33, 44))
    var ptr = slab._unsafe_ptr()
    assert_equal((ptr + 0)[].a, Int64(11))
    assert_equal((ptr + 0)[].b, Int64(22))
    assert_equal((ptr + 1)[].a, Int64(33))
    assert_equal((ptr + 1)[].b, Int64(44))


# =============================================================================
# Drop-count tests using TrackedValue
# =============================================================================

def _build_and_drop_three(counter: UnsafePointer[Int, MutUntrackedOrigin]) raises:
    """Helper: build a slab with 3 TrackedValues and let it drop on return."""
    var slab = Slab[TrackedValue](capacity=4)
    slab.append(TrackedValue(1, counter))
    slab.append(TrackedValue(2, counter))
    slab.append(TrackedValue(3, counter))
    assert_equal(slab.len(), 3)
    # Note: can't assert counter[] == 0 here because Mojo's ASAP destruction
    # may have already fired after the last use of `slab`. We assert the
    # post-drop count in the caller.


def test_destructor_runs_on_all_live_elements() raises:
    """Dropping the slab runs __del__ on each live element exactly once."""
    var counter = _alloc_counter()
    _build_and_drop_three(counter)
    # Slab went out of scope when helper returned -- each of the 3
    # TrackedValues had __del__ run.
    assert_equal(counter[], 3)
    counter.unsafe_deinit_pointee()
    counter.free()


def _build_grow_five(counter: UnsafePointer[Int, MutUntrackedOrigin]) raises:
    """Helper: build a slab that grows across reallocations."""
    var slab = Slab[TrackedValue](capacity=2)
    slab.append(TrackedValue(1, counter))
    slab.append(TrackedValue(2, counter))
    # Trigger grow -- bytes are memcpy'd, but moved-from slots are
    # abandoned without running __del__.
    slab.append(TrackedValue(3, counter))
    slab.append(TrackedValue(4, counter))
    slab.append(TrackedValue(5, counter))  # grow to 8
    assert_equal(slab.len(), 5)


def test_destructor_runs_after_grow() raises:
    """After a realloc, old T slots are bitwise-relocated; only final
    destructors fire, not one-per-old-slot. Count == final len, not 2 * len.
    """
    var counter = _alloc_counter()
    _build_grow_five(counter)
    # All 5 live elements destroyed on slab drop.
    assert_equal(counter[], 5)
    counter.unsafe_deinit_pointee()
    counter.free()


def _build_set_replace(counter: UnsafePointer[Int, MutUntrackedOrigin]) raises:
    """Helper: build, set-replace slot 0, assert mid-call count, return."""
    var slab = Slab[TrackedValue](capacity=4)
    slab.append(TrackedValue(1, counter))
    slab.append(TrackedValue(2, counter))
    # Replace slot 0 -- one destructor should fire immediately.
    slab.set(0, TrackedValue(99, counter))
    assert_equal(counter[], 1)
    assert_equal(slab.get(0).id(), 99)


def test_set_destroys_replaced_slot() raises:
    """Verify set() runs __del__ on the old value exactly once."""
    var counter = _alloc_counter()
    _build_set_replace(counter)
    # Slab drop runs destructors for the 2 remaining live slots (net: 1 + 2 = 3).
    assert_equal(counter[], 3)
    counter.unsafe_deinit_pointee()
    counter.free()


# =============================================================================
# Move semantics (auto-synthesized)
# =============================================================================

def test_move_empty_slab() raises:
    """Moving an empty slab leaves the destination empty and source inert."""
    var src = Slab[PlainT]()
    var dst = src^
    assert_equal(dst.len(), 0)
    assert_equal(dst.capacity(), 0)


def _move_populated(counter: UnsafePointer[Int, MutUntrackedOrigin]) raises:
    """Helper: build src, move to dst, verify dst, let dst drop on return."""
    var src = Slab[TrackedValue](capacity=4)
    src.append(TrackedValue(10, counter))
    src.append(TrackedValue(20, counter))
    src.append(TrackedValue(30, counter))
    var dst = src^
    assert_equal(dst.len(), 3)
    assert_equal(dst.get(0).id(), 10)
    assert_equal(dst.get(2).id(), 30)


def test_move_populated_slab() raises:
    """Moving a populated slab transfers ownership; the source becomes
    inert (no extra destructor calls from the moved-from source), and on
    destination drop every element fires its destructor exactly once.
    """
    var counter = _alloc_counter()
    _move_populated(counter)
    # Net 3 destructors total: only the destination dropped 3 live elements.
    # If the moved-from `src` had also run destructors, this would be > 3.
    assert_equal(counter[], 3)
    counter.unsafe_deinit_pointee()
    counter.free()


# =============================================================================
# Test runner
# =============================================================================

def main() raises:
    # Inline sequencing: TestSuite.discover_tests has surfaced spurious heap
    # corruption on similar test layouts.
    print("test_empty_construction...")
    test_empty_construction()
    print("  ok")

    print("test_with_capacity...")
    test_with_capacity()
    print("  ok")

    print("test_with_zero_capacity...")
    test_with_zero_capacity()
    print("  ok")

    print("test_append_and_get_plain...")
    test_append_and_get_plain()
    print("  ok")

    print("test_append_past_initial_capacity_triggers_grow...")
    test_append_past_initial_capacity_triggers_grow()
    print("  ok")

    print("test_resize_preserves_elements...")
    test_resize_preserves_elements()
    print("  ok")

    print("test_resize_noop_when_smaller...")
    test_resize_noop_when_smaller()
    print("  ok")

    print("test_set_replaces_element...")
    test_set_replaces_element()
    print("  ok")

    print("test_unsafe_ptr_roundtrip...")
    test_unsafe_ptr_roundtrip()
    print("  ok")

    print("test_destructor_runs_on_all_live_elements...")
    test_destructor_runs_on_all_live_elements()
    print("  ok")

    print("test_destructor_runs_after_grow...")
    test_destructor_runs_after_grow()
    print("  ok")

    print("test_set_destroys_replaced_slot...")
    test_set_destroys_replaced_slot()
    print("  ok")

    print("test_move_empty_slab...")
    test_move_empty_slab()
    print("  ok")

    print("test_move_populated_slab...")
    test_move_populated_slab()
    print("  ok")

    print("ALL 14 TESTS PASSED")
