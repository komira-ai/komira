# =============================================================================
# Tests for Slab[T: Movable] -- dynamically-growing owning array
# =============================================================================
#
# Covers: basic ops, growth/resize, pop, set, swap_remove, clear, reserve,
# extend, steal_slab, destructor correctness, move semantics, borrow safety,
# edge cases, real types (Column, RecordBatch), nested arrays.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.memory import UnsafePointer, alloc

from komira_collections.slab import Slab
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# TrackedValue -- Movable-only type whose destructor increments a counter.
# =============================================================================

struct TrackedValue(Movable):
    """Test-only type that increments *_counter on destruction.

    SAFETY: _counter points to a caller-owned Int that must outlive this value.
    """
    var _id: Int
    var _counter: UnsafePointer[Int, MutUntrackedOrigin]

    def __init__(out self, id: Int, counter: UnsafePointer[Int, MutUntrackedOrigin]):
        self._id = id
        self._counter = counter

    # Auto-synthesized __moveinit__ does bitwise copy of fields.
    # The moved-from value is consumed by ^ transfer and its destructor
    # does not fire. This is correct for our counting pattern.

    def __deinit__(deinit self):
        # SAFETY: _counter points to caller's heap-allocated Int.
        self._counter[] += 1

    @always_inline
    def id(self) -> Int:
        return self._id


def _alloc_counter() -> UnsafePointer[Int, MutUntrackedOrigin]:
    """Allocate a counter on the heap, initialized to 0."""
    var ptr = alloc[Int](1)
    # SAFETY: ptr points to one Int slot. Initialize to 0.
    ptr.unsafe_write(0)
    return ptr


# =============================================================================
# Basic operations
# =============================================================================

def test_owned_array_default_empty() raises:
    """Default constructor creates empty array with zero capacity."""
    var arr = Slab[Int]()
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 0)
    assert_true(arr.is_empty())

def test_owned_array_with_capacity() raises:
    """With_capacity(n) pre-allocates n slots, initially empty."""
    var arr = Slab[Int].with_capacity(16)
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 16)
    assert_true(arr.is_empty())

def test_owned_array_create_with_capacity_alias() raises:
    """create_with_capacity() is an alias of with_capacity()."""
    var arr = Slab[Int].create_with_capacity(32)
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 32)

def test_owned_array_append_and_getitem() raises:
    """Append elements and read back via __getitem__."""
    var arr = Slab[Int]()
    arr.append(10)
    arr.append(20)
    arr.append(30)
    assert_equal(len(arr), 3)
    assert_equal(arr[0], 10)
    assert_equal(arr[1], 20)
    assert_equal(arr[2], 30)


# =============================================================================
# Growth and resize
# =============================================================================

def test_owned_array_growth_from_zero() raises:
    """Appending to a zero-capacity array triggers growth to 4."""
    var arr = Slab[Int]()
    assert_equal(arr.capacity(), 0)
    arr.append(1)
    assert_equal(arr.capacity(), 4)  # min capacity is 4
    assert_equal(arr[0], 1)

def test_owned_array_growth_4_to_8() raises:
    """Growing from capacity 4 to 8 at the boundary."""
    var arr = Slab[Int].with_capacity(4)
    arr.append(1)
    arr.append(2)
    arr.append(3)
    arr.append(4)
    assert_equal(arr.capacity(), 4)
    # This append triggers growth 4 -> 8
    arr.append(5)
    assert_equal(arr.capacity(), 8)
    assert_equal(len(arr), 5)
    # Verify all values survived reallocation
    assert_equal(arr[0], 1)
    assert_equal(arr[1], 2)
    assert_equal(arr[2], 3)
    assert_equal(arr[3], 4)
    assert_equal(arr[4], 5)

def test_owned_array_growth_8_to_16() raises:
    """Growing from capacity 8 to 16 at the boundary."""
    var arr = Slab[Int].with_capacity(8)
    for i in range(8):
        arr.append(i * 10)
    assert_equal(arr.capacity(), 8)
    arr.append(80)  # triggers growth to 16
    assert_equal(arr.capacity(), 16)
    assert_equal(len(arr), 9)
    for i in range(8):
        assert_equal(arr[i], i * 10)
    assert_equal(arr[8], 80)

def test_owned_array_growth_16_to_32() raises:
    """Growing from capacity 16 to 32 at the boundary."""
    var arr = Slab[Int].with_capacity(16)
    for i in range(16):
        arr.append(i)
    assert_equal(arr.capacity(), 16)
    arr.append(16)  # triggers growth to 32
    assert_equal(arr.capacity(), 32)
    assert_equal(len(arr), 17)

def test_owned_array_with_capacity_no_resize() raises:
    """Pre-allocating 1000 and appending 1000 -- no resize."""
    var arr = Slab[Int].with_capacity(1000)
    for i in range(1000):
        arr.append(i)
    assert_equal(arr.capacity(), 1000)  # no resize occurred
    assert_equal(len(arr), 1000)
    assert_equal(arr[0], 0)
    assert_equal(arr[999], 999)


# =============================================================================
# pop() -- returns Optional[T]
# =============================================================================

def test_owned_array_pop_lifo() raises:
    """Pop returns elements in LIFO order."""
    var arr = Slab[Int]()
    arr.append(10)
    arr.append(20)
    arr.append(30)
    var v3 = arr.pop()
    assert_true(v3.__bool__())
    assert_equal(v3.value(), 30)
    var v2 = arr.pop()
    assert_true(v2.__bool__())
    assert_equal(v2.value(), 20)
    var v1 = arr.pop()
    assert_true(v1.__bool__())
    assert_equal(v1.value(), 10)
    assert_equal(len(arr), 0)
    assert_true(arr.is_empty())

def test_owned_array_pop_empty_returns_none() raises:
    """Pop on empty array returns None."""
    var arr = Slab[Int]()
    var result = arr.pop()
    assert_false(result.__bool__())


# =============================================================================
# set() -- replace element
# =============================================================================

def test_owned_array_set_replaces_element() raises:
    """Set replaces element, old value is destroyed."""
    var arr = Slab[Int]()
    arr.append(10)
    arr.append(20)
    arr.append(30)
    arr.set(1, 99)
    assert_equal(arr[0], 10)
    assert_equal(arr[1], 99)
    assert_equal(arr[2], 30)


# =============================================================================
# swap_remove() -- O(1) unordered removal
# =============================================================================

def test_owned_array_swap_remove_middle() raises:
    """Swap_remove from middle swaps last element into the gap."""
    var arr = Slab[Int]()
    arr.append(10)
    arr.append(20)
    arr.append(30)
    var removed = arr.swap_remove(0)
    assert_equal(removed, 10)
    assert_equal(len(arr), 2)
    # Element 30 moved to position 0
    assert_equal(arr[0], 30)
    assert_equal(arr[1], 20)

def test_owned_array_swap_remove_last() raises:
    """Swap_remove on last element is equivalent to pop."""
    var arr = Slab[Int]()
    arr.append(10)
    arr.append(20)
    arr.append(30)
    var removed = arr.swap_remove(2)
    assert_equal(removed, 30)
    assert_equal(len(arr), 2)
    assert_equal(arr[0], 10)
    assert_equal(arr[1], 20)

def test_owned_array_swap_remove_single() raises:
    """Swap_remove on single-element array empties it."""
    var arr = Slab[Int]()
    arr.append(42)
    var removed = arr.swap_remove(0)
    assert_equal(removed, 42)
    assert_equal(len(arr), 0)
    assert_true(arr.is_empty())


# =============================================================================
# clear()
# =============================================================================

def test_owned_array_clear() raises:
    """Clear destroys all elements, keeps buffer capacity."""
    var arr = Slab[Int].with_capacity(8)
    arr.append(1)
    arr.append(2)
    arr.append(3)
    arr.clear()
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 8)  # buffer retained
    assert_true(arr.is_empty())

def test_owned_array_clear_then_reuse() raises:
    """After clear, array can be refilled without reallocation."""
    var arr = Slab[Int].with_capacity(4)
    arr.append(1)
    arr.append(2)
    arr.clear()
    arr.append(10)
    arr.append(20)
    assert_equal(len(arr), 2)
    assert_equal(arr[0], 10)
    assert_equal(arr[1], 20)


# =============================================================================
# reserve()
# =============================================================================

def test_owned_array_reserve() raises:
    """Reserve(n) ensures space for n additional elements."""
    var arr = Slab[Int]()
    arr.reserve(100)
    assert_true(arr.capacity() >= 100)
    assert_equal(len(arr), 0)

def test_owned_array_reserve_no_op() raises:
    """Reserve is a no-op when sufficient spare capacity exists."""
    var arr = Slab[Int].with_capacity(100)
    arr.append(1)
    arr.reserve(10)
    assert_equal(arr.capacity(), 100)  # unchanged


# =============================================================================
# extend()
# =============================================================================

def test_owned_array_extend() raises:
    """Extend moves all elements from another Slab."""
    var a = Slab[Int]()
    a.append(1)
    a.append(2)
    var b = Slab[Int]()
    b.append(3)
    b.append(4)
    # Uses the `extend(mut src)` overload on Slab. After the call, b is
    # empty.
    a.extend(b)
    assert_equal(len(a), 4)
    assert_equal(a[0], 1)
    assert_equal(a[1], 2)
    assert_equal(a[2], 3)
    assert_equal(a[3], 4)
    # b is now empty
    assert_equal(len(b), 0)

def test_owned_array_extend_empty() raises:
    """Extend with empty source is a no-op."""
    var a = Slab[Int]()
    a.append(1)
    var b = Slab[Int]()
    a.extend(b)
    assert_equal(len(a), 1)
    assert_equal(a[0], 1)


# =============================================================================
# steal_slab()
# =============================================================================

def test_owned_array_steal_slab() raises:
    """Steal_slab returns valid Slab, leaves array empty."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue]()
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    arr.append(TrackedValue(3, ctr))

    var slab = arr.steal_slab()

    assert_equal(len(slab), 3)
    assert_true(slab.capacity() >= 3)
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 0)
    assert_equal(ctr[], 0)  # elements NOT destroyed (still in slab)

    # Verify element access via slab.get()
    assert_equal(slab.get(0).id(), 1)
    assert_equal(slab.get(1).id(), 2)
    assert_equal(slab.get(2).id(), 3)

    # Slab destructor handles cleanup
    _ = slab^
    assert_equal(ctr[], 3)
    ctr.free()


# =============================================================================
# Move semantics
# =============================================================================

def test_owned_array_move() raises:
    """Moving Slab transfers ownership; data survives."""
    var arr = Slab[Int]()
    arr.append(10)
    arr.append(20)
    arr.append(30)
    var moved = arr^
    assert_equal(len(moved), 3)
    assert_equal(moved[0], 10)
    assert_equal(moved[1], 20)
    assert_equal(moved[2], 30)


# =============================================================================
# Destructor correctness with TrackedValue
# =============================================================================

def test_owned_array_destructor_on_drop() raises:
    """Dropping Slab destroys all elements exactly once."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue]()
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    arr.append(TrackedValue(3, ctr))
    _ = arr^  # explicit drop
    assert_equal(ctr[], 3)
    ctr.free()

def test_owned_array_destructor_on_pop() raises:
    """Pop moves element out; caller owns it. Original not double-destroyed."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue]()
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    # Pop removes last element -- caller now owns it
    var popped = arr.pop()
    assert_equal(ctr[], 0)  # nothing destroyed yet (popped is alive)
    # Drop popped
    _ = popped^
    assert_equal(ctr[], 1)  # popped destroyed
    # Drop arr -- TrackedValue(1) destroyed
    _ = arr^
    assert_equal(ctr[], 2)  # 1 from popped + 1 from arr drop
    ctr.free()

def test_owned_array_destructor_on_set() raises:
    """Set destroys old element, new element lives until drop."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue]()
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    assert_equal(ctr[], 0)
    arr.set(0, TrackedValue(99, ctr))
    assert_equal(ctr[], 1)  # old TrackedValue(1) destroyed
    _ = arr^  # drop destroys TrackedValue(99) and TrackedValue(2)
    assert_equal(ctr[], 3)
    ctr.free()

def test_owned_array_destructor_on_clear() raises:
    """Clear destroys all elements; drop after clear adds nothing."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue]()
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    arr.append(TrackedValue(3, ctr))
    arr.clear()
    assert_equal(ctr[], 3)  # all 3 destroyed by clear
    _ = arr^  # drop -- no extra from drop
    assert_equal(ctr[], 3)
    ctr.free()

def test_owned_array_destructor_on_swap_remove() raises:
    """Swap_remove moves element out; only remaining destroyed on drop."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue]()
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    arr.append(TrackedValue(3, ctr))
    var removed = arr.swap_remove(0)
    assert_equal(removed.id(), 1)
    assert_equal(ctr[], 0)  # nothing destroyed yet
    _ = removed^  # drop removed
    assert_equal(ctr[], 1)
    _ = arr^  # arr has [3, 2] left, drop destroys both
    assert_equal(ctr[], 3)
    ctr.free()

def test_owned_array_destructor_on_extend() raises:
    """Extend moves elements; source array drop is a no-op."""
    var ctr = _alloc_counter()
    var a = Slab[TrackedValue]()
    a.append(TrackedValue(1, ctr))

    var b = Slab[TrackedValue]()
    b.append(TrackedValue(2, ctr))
    b.append(TrackedValue(3, ctr))

    a.extend(b)
    assert_equal(len(a), 3)
    assert_equal(len(b), 0)
    _ = b^  # b drop -- _size is 0 so no destructions
    assert_equal(ctr[], 0)
    _ = a^  # a drop -- 3 elements destroyed
    assert_equal(ctr[], 3)
    ctr.free()

def test_owned_array_destructor_growth() raises:
    """Elements survive reallocation without double-free."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue]()
    # Append 5 elements (capacity grows: 0->4->8)
    for i in range(5):
        arr.append(TrackedValue(i, ctr))
    assert_equal(ctr[], 0)  # no destructions during growth
    assert_equal(len(arr), 5)
    _ = arr^
    assert_equal(ctr[], 5)  # all 5 destroyed on drop
    ctr.free()


# =============================================================================
# Borrow safety
# =============================================================================
#
# DESIGN REQUIREMENT: Slab MUST NOT allow mutation while references are
# outstanding. The ref return from __getitem__ borrows self immutably.
# append(mut self) requires mutable access. The Mojo compiler SHOULD reject
# code that holds a ref and calls append simultaneously.
#
# We cannot write a compile-error test in Mojo's test framework (there is no
# compiletest-rs equivalent). Instead we document the expected behavior.
#
# The following code should be rejected by the compiler:
#
#   var arr = Slab[Int]()
#   arr.append(1)
#   var r = arr[0]       # immutable borrow via ref[arr._data]
#   arr.append(2)        # mutable borrow -- CONFLICT with ref
#   print(r)             # use of invalidated ref
#
# COMPILER GAP NOTE (Mojo 0.26.3): If the compiler does not reject this
# pattern, it is a known limitation. The ref[self._data] origin tracking
# is the correct mechanism, and future compiler versions may enforce it.
# No runtime tracking is added because:
#   1. It would add overhead to the hot path (__getitem__)
#   2. The correct fix is compiler enforcement, not runtime checks
#   3. Slab (the hot-path type) has no resize, so the problem
#      cannot occur there
#
# We verify the ref return type works correctly when used properly:

def test_owned_array_ref_access_correct() raises:
    """Ref access works when no mutation occurs between borrow and use."""
    var arr = Slab[Int]()
    arr.append(42)
    arr.append(99)
    var v = arr[0]
    assert_equal(v, 42)
    var w = arr[1]
    assert_equal(w, 99)

def test_owned_array_ref_survives_no_realloc() raises:
    """Ref is valid as long as no reallocation occurs."""
    var arr = Slab[Int].with_capacity(10)
    arr.append(100)
    arr.append(200)
    assert_equal(arr[0], 100)
    assert_equal(arr[1], 200)


# =============================================================================
# Edge cases
# =============================================================================

def test_owned_array_empty_pop() raises:
    """Pop on never-appended array returns None."""
    var arr = Slab[Int]()
    var r = arr.pop()
    assert_false(r.__bool__())

def test_owned_array_single_element() raises:
    """Single element: append, getitem, pop all work."""
    var arr = Slab[Int]()
    arr.append(42)
    assert_equal(len(arr), 1)
    assert_equal(arr[0], 42)
    var v = arr.pop()
    assert_true(v.__bool__())
    assert_equal(v.value(), 42)
    assert_equal(len(arr), 0)

def test_owned_array_large() raises:
    """100K elements -- verify all accessible after many resizes."""
    var arr = Slab[Int]()
    for i in range(100000):
        arr.append(i)
    assert_equal(len(arr), 100000)
    assert_equal(arr[0], 0)
    assert_equal(arr[999], 999)
    assert_equal(arr[50000], 50000)
    assert_equal(arr[99999], 99999)

def test_owned_array_with_capacity_zero() raises:
    """With_capacity(0) is equivalent to default constructor."""
    var arr = Slab[Int].with_capacity(0)
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 0)

def test_owned_array_with_capacity_negative() raises:
    """With_capacity(-1) is equivalent to default constructor."""
    var arr = Slab[Int].with_capacity(-1)
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 0)


# =============================================================================
# With real types
# =============================================================================

def test_owned_array_column() raises:
    """Slab[Column[HeapRegion]] -- the builder/optimizer use case."""
    var arr = Slab[Column[HeapRegion]]()
    var vals_i64: List[Scalar[DType.int64]] = [1, 2, 3]
    var vals_f64: List[Scalar[DType.float64]] = [1.0, 2.0, 3.0]
    var a0 = PrimitiveArray[DType.int64].from_list(vals_i64)
    var a1 = PrimitiveArray[DType.float64].from_list(vals_f64)
    arr.append(Column.from_primitive[DType.int64](a0))
    arr.append(Column.from_primitive[DType.float64](a1))
    assert_equal(len(arr), 2)
    assert_equal(arr[0].arrow_type, ArrowType.INT64)
    assert_equal(arr[1].arrow_type, ArrowType.FLOAT64)

def test_owned_array_recordbatch() raises:
    """Slab[RecordBatch] for accumulating batches."""
    var batches = Slab[RecordBatch]()

    # Build two small batches
    for batch_idx in range(2):
        var sb = SchemaBuilder()
        sb.add_field(Field("v", DType.int64, nullable=False))
        var schema = sb.build()
        var vals: List[Scalar[DType.int64]] = [Int64(batch_idx * 10), Int64(batch_idx * 10 + 1)]
        var a0 = PrimitiveArray[DType.int64].from_list(vals)
        var builder = RecordBatchBuilder()
        builder.add_column(Column.from_primitive[DType.int64](a0))
        batches.append(builder.build(schema^))

    assert_equal(len(batches), 2)
    assert_equal(batches[0].num_rows(), 2)
    assert_equal(batches[1].num_rows(), 2)


# =============================================================================
# Nested: Slab[Slab[Int]]
# =============================================================================

def test_owned_array_nested() raises:
    """Nested Slab -- verifies Slab is Movable."""
    var outer = Slab[Slab[Int]]()

    var inner1 = Slab[Int]()
    inner1.append(10)
    inner1.append(20)
    outer.append(inner1^)

    var inner2 = Slab[Int]()
    inner2.append(30)
    inner2.append(40)
    inner2.append(50)
    outer.append(inner2^)

    assert_equal(len(outer), 2)
    assert_equal(len(outer[0]), 2)
    assert_equal(len(outer[1]), 3)
    assert_equal(outer[0][0], 10)
    assert_equal(outer[0][1], 20)
    assert_equal(outer[1][0], 30)
    assert_equal(outer[1][2], 50)

def test_owned_array_nested_destructor() raises:
    """Nested Slab destruction -- all inner elements destroyed."""
    var ctr = _alloc_counter()
    var outer = Slab[Slab[TrackedValue]]()

    var inner1 = Slab[TrackedValue]()
    inner1.append(TrackedValue(1, ctr))
    inner1.append(TrackedValue(2, ctr))
    outer.append(inner1^)

    var inner2 = Slab[TrackedValue]()
    inner2.append(TrackedValue(3, ctr))
    outer.append(inner2^)

    _ = outer^
    assert_equal(ctr[], 3)
    ctr.free()


# =============================================================================
# Cross-type nesting: Slab[Slab[Int]]
# =============================================================================

def test_owned_array_of_fixed_array() raises:
    """Slab containing FixedArrays -- both are Movable."""
    var outer = Slab[Slab[Int]]()
    var fa = Slab[Int].create(3)
    fa.append(1)
    fa.append(2)
    fa.append(3)
    outer.append(fa^)

    assert_equal(len(outer), 1)
    assert_equal(len(outer[0]), 3)
    assert_equal(outer[0][0], 1)
    assert_equal(outer[0][2], 3)


# =============================================================================
# mut_ptr / unsafe_as_pointer -- canonical mutable-access escapes
# =============================================================================

def test_mut_ptr_mutates_backing_storage() raises:
    """mut_ptr(i) returns a pointer that mutates through to the slot."""
    var arr = Slab[Int]()
    arr.append(10)
    arr.append(20)
    arr.append(30)

    # Mutate via the raw pointer.
    arr._mut_ptr(0)[] = 100
    arr._mut_ptr(2)[] = 300

    # Reads via __getitem__ must see the mutations.
    assert_equal(arr[0], 100)
    assert_equal(arr[1], 20)
    assert_equal(arr[2], 300)

def test_mut_ptr_matches_getitem_for_read() raises:
    """mut_ptr(i)[] dereferences the same slot as __getitem__."""
    var arr = Slab[Int]()
    arr.append(42)
    arr.append(99)
    assert_equal(arr._mut_ptr(0)[], 42)
    assert_equal(arr._mut_ptr(1)[], 99)

def test_mut_ptr_pointer_arithmetic() raises:
    """mut_ptr(0) + k addresses the same slot as mut_ptr(k)."""
    var arr = Slab[Int]()
    for i in range(5):
        arr.append(i * 10)
    var base = arr._mut_ptr(0)
    for i in range(5):
        # Read via (base + i)[] and compare against __getitem__ read.
        var via_ptr: Int = (base + i)[]
        var via_idx: Int = arr[i]
        assert_equal(via_ptr, via_idx)

def test_unsafe_as_pointer_is_slab_base() raises:
    """unsafe_as_pointer() returns the base pointer -- write via base, read via [i]."""
    var arr = Slab[Int]()
    for i in range(4):
        arr.append(i + 1)
    var base = arr._unsafe_as_pointer()
    # Base must point at slot 0; slot i must equal (base + i)[]. We verify
    # by writing through base and reading back via arr[i] (which is known
    # to deref correctly through __getitem__).
    (base + 0)[] = 10
    (base + 1)[] = 20
    (base + 2)[] = 30
    (base + 3)[] = 40
    assert_equal(arr[0], 10)
    assert_equal(arr[1], 20)
    assert_equal(arr[2], 30)
    assert_equal(arr[3], 40)

def test_unsafe_as_pointer_write_through() raises:
    """Writing through unsafe_as_pointer() mutates the array."""
    var arr = Slab[Int].with_capacity(4)
    arr.append(1)
    arr.append(2)
    arr.append(3)
    var base = arr._unsafe_as_pointer()
    (base + 0)[] = 777
    (base + 2)[] = 999
    assert_equal(arr[0], 777)
    assert_equal(arr[1], 2)
    assert_equal(arr[2], 999)

def test_unsafe_as_pointer_matches_mut_ptr_zero() raises:
    """unsafe_as_pointer() and mut_ptr(0) point at the same slot."""
    var arr = Slab[Int]()
    arr.append(123)
    # Write through unsafe_as_pointer(); read via mut_ptr(0)[].
    var p_base = arr._unsafe_as_pointer()
    (p_base + 0)[] = 456
    assert_equal(arr._mut_ptr(0)[], 456)
    # Write through mut_ptr(0); read via arr[0].
    arr._mut_ptr(0)[] = 789
    assert_equal(arr[0], 789)


# =============================================================================
# Main -- discover and run all tests
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
