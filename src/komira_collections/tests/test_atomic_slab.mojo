# =============================================================================
# Unit tests for AtomicSlab[T]
# =============================================================================
# Verifies:
#   1. Construction with zero-init
#   2. In-place init via get_mut_interior
#   3. Element access via __getitem__
#   4. Destruction calls destroy_pointee on each slot
#   5. Works with Atomic-containing types (the primary use case)
#   6. Works with Movable-only types (secondary use case)
#   7. Move semantics (source nulled, no double-free)
#   8. Empty slab (size=0)

from std.testing import TestSuite, assert_equal, assert_true
from komira_atomic_alias import AtomicI64
from std.memory import UnsafePointer, alloc

from komira_collections.slab import Slab


# =============================================================================
# Test type: struct with Atomic fields (non-Movable)
# =============================================================================

struct AtomicCounter:
    """Test struct with Atomic field. Non-Movable in Mojo 0.26.3."""
    var value: AtomicI64
    var label: Int


# =============================================================================
# Test type: struct with Movable-only fields (no Atomic)
# =============================================================================

struct SlotWithList:
    """Test struct with List field (Movable, not trivially copyable)."""
    var items: List[Int]
    var tag: Int


# =============================================================================
# Tests
# =============================================================================

def test_empty_slab() raises:
    """AtomicSlab with size=0 is valid and destroys cleanly."""
    var slab = Slab[AtomicCounter].create_prefilled(0)
    assert_equal(len(slab), 0)
    assert_true(slab.is_empty())
    # __del__ runs without crash (null pointer guard).


def test_atomic_counter_slab() raises:
    """Init and access Atomic-containing slots."""
    var slab = Slab[AtomicCounter].create_prefilled(4)
    assert_equal(len(slab), 4)
    assert_true(not slab.is_empty())

    # Initialize each slot in-place.
    for i in range(4):
        ref slot = slab.get_mut_interior(i)
        slot.value = AtomicI64(Int64(i * 10))
        slot.label = i

    # Read back via __getitem__.
    assert_equal(Int(slab[0].value.load()), 0)
    assert_equal(slab[0].label, 0)
    assert_equal(Int(slab[1].value.load()), 10)
    assert_equal(slab[1].label, 1)
    assert_equal(Int(slab[2].value.load()), 20)
    assert_equal(slab[2].label, 2)
    assert_equal(Int(slab[3].value.load()), 30)
    assert_equal(slab[3].label, 3)

    # Mutate the Atomic field (atomic operations are always in-place).
    _ = slab.get_mut_interior(2).value.fetch_add(5)
    assert_equal(Int(slab[2].value.load()), 25)  # was 20, now 25


def test_slot_with_list_slab() raises:
    """Init slots containing Movable-only fields (List)."""
    var slab = Slab[SlotWithList].create_prefilled(3)

    for i in range(3):
        ref slot = slab.get_mut_interior(i)
        UnsafePointer(to=slot.items).unsafe_write(
            List[Int](capacity=8)
        )
        slot.tag = i

    # Append to the list through the slab.
    for i in range(3):
        ref slot = slab.get_mut_interior(i)
        slot.items.append(i * 100)
        slot.items.append(i * 100 + 1)

    # Verify.
    assert_equal(len(slab[0].items), 2)
    assert_equal(slab[0].items[0], 0)
    assert_equal(slab[0].items[1], 1)
    assert_equal(slab[1].items[0], 100)
    assert_equal(slab[2].tag, 2)

    # __del__ destroys each slot, which destroys each List (frees heap).


def test_destructor_runs_without_crash() raises:
    """Verify slab destruction does not crash with initialized slots.

    We cannot use global variables in Mojo 0.26 to count destructors,
    so this test verifies the slab can be created, populated, and
    destroyed without segfault or double-free.
    """
    var slab = Slab[SlotWithList].create_prefilled(5)
    for i in range(5):
        ref slot = slab.get_mut_interior(i)
        UnsafePointer(to=slot.items).unsafe_write(List[Int]())
        slot.tag = i
        # Add some heap data to make destructors non-trivial.
        slot.items.append(i)
    # Explicit destroy.
    _ = slab^  # explicit destroy (1.0.0: `__del__` is `__deinit__`, not callable)
    # If we reach here, no crash occurred.
    assert_true(True)


def test_move_semantics() raises:
    """Moving a slab transfers ownership; source is empty."""
    var slab1 = Slab[AtomicCounter].create_prefilled(3)
    for i in range(3):
        ref slot = slab1.get_mut_interior(i)
        slot.value = AtomicI64(Int64(i))
        slot.label = i

    # Move slab1 into slab2.
    var slab2 = slab1^

    # slab2 has the data.
    assert_equal(len(slab2), 3)
    assert_equal(slab2[0].label, 0)
    assert_equal(slab2[1].label, 1)
    assert_equal(slab2[2].label, 2)

    # slab2 destroys cleanly (no double-free from moved-from slab1).


def test_base_ptr_offset_matches_element_access() raises:
    """The base pointer's offset arithmetic agrees with element access.

    `_unsafe_ptr()` is the base accessor and is origin-TIED to `self`
    (a base accessor with a wildcard origin would leak the pointer OUT of the
    slab untracked).
    """
    var slab = Slab[AtomicCounter].create_prefilled(4)
    for i in range(4):
        ref slot = slab.get_mut_interior(i)
        slot.value = AtomicI64(Int64(0))
        slot.label = i

    var base = slab._unsafe_ptr()
    # Verify offset arithmetic matches element access.
    for i in range(4):
        assert_equal((base + i)[].label, slab[i].label)


def test_single_element() raises:
    """AtomicSlab with size=1 (the SchedulerState pattern)."""
    var slab = Slab[AtomicCounter].create_prefilled(1)
    assert_equal(len(slab), 1)

    slab.get_mut_interior(0).value = AtomicI64(42)
    slab.get_mut_interior(0).label = 7

    assert_equal(Int(slab[0].value.load()), 42)
    assert_equal(slab[0].label, 7)


def test_atomic_fetch_add_through_slab() raises:
    """Verify Atomic operations work through slab element references."""
    var slab = Slab[AtomicCounter].create_prefilled(2)
    for i in range(2):
        ref slot = slab.get_mut_interior(i)
        slot.value = AtomicI64(0)
        slot.label = i

    # Use atomic operations through the slab.
    ref slot0 = slab.get_mut_interior(0)
    _ = slot0.value.fetch_add(5)
    _ = slot0.value.fetch_add(3)

    ref slot1 = slab.get_mut_interior(1)
    _ = slot1.value.fetch_add(10)

    assert_equal(Int(slab[0].value.load()), 8)
    assert_equal(Int(slab[1].value.load()), 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
