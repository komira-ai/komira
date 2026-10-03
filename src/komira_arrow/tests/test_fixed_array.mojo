# =============================================================================
# Tests for Slab[T: Movable] -- fixed-capacity owning array
# =============================================================================
#
# Covers: basic operations, capacity enforcement, ref safety, move semantics,
# destructor correctness, edge cases, real types (Column, RecordBatch), nested.
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
# TrackedValue -- a Movable-only type whose destructor increments a counter.
# Used to verify exact destructor call counts (no double-free, no leaks).
# =============================================================================

struct TrackedValue(Movable):
    """Test-only type that increments *_counter on destruction.

    SAFETY: _counter points to a caller-owned Int that must outlive this value.
    This is only used in tests where the counter lives in the test function scope.
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
        # After auto-synthesized move, _counter in the new location is
        # valid. The moved-from object is consumed and never destroyed.
        self._counter[] += 1

    @always_inline
    def id(self) -> Int:
        return self._id


# =============================================================================
# Helper: create a counter pointer for TrackedValue tests
# =============================================================================

def _alloc_counter() -> UnsafePointer[Int, MutUntrackedOrigin]:
    """Allocate a counter on the heap, initialized to 0.

    Returns: pointer to Int. Caller must free it.
    """
    var ptr = alloc[Int](1)
    # SAFETY: ptr points to one Int slot. Initialize to 0.
    ptr.unsafe_write(0)
    return ptr


# =============================================================================
# Basic operations
# =============================================================================

def test_fixed_array_create_empty() raises:
    """Default constructor creates empty array with zero capacity."""
    var arr = Slab[Int]()
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 0)
    assert_true(arr.is_empty())
    assert_true(arr.is_full())  # 0 == 0

def test_fixed_array_create_with_capacity() raises:
    """Create(n) allocates n slots, initially empty."""
    var arr = Slab[Int].create(10)
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 10)
    assert_true(arr.is_empty())
    assert_false(arr.is_full())

def test_fixed_array_append_and_getitem() raises:
    """Append elements and read them back via __getitem__."""
    var arr = Slab[Int].create(5)
    arr.append(10)
    arr.append(20)
    arr.append(30)
    assert_equal(len(arr), 3)
    assert_equal(arr[0], 10)
    assert_equal(arr[1], 20)
    assert_equal(arr[2], 30)

def test_fixed_array_fill_to_capacity() raises:
    """Append exactly capacity elements -- array becomes full."""
    var arr = Slab[Int].create(4)
    arr.append(1)
    arr.append(2)
    arr.append(3)
    arr.append(4)
    assert_equal(len(arr), 4)
    assert_equal(arr.capacity(), 4)
    assert_true(arr.is_full())
    assert_false(arr.is_empty())
    assert_equal(arr[0], 1)
    assert_equal(arr[1], 2)
    assert_equal(arr[2], 3)
    assert_equal(arr[3], 4)

def test_fixed_array_set_replaces_element() raises:
    """Set replaces an element at the given index."""
    var arr = Slab[Int].create(3)
    arr.append(10)
    arr.append(20)
    arr.append(30)
    arr.set(1, 99)
    assert_equal(arr[0], 10)
    assert_equal(arr[1], 99)
    assert_equal(arr[2], 30)

def test_fixed_array_clear() raises:
    """Clear destroys all elements, keeps capacity."""
    var arr = Slab[Int].create(5)
    arr.append(1)
    arr.append(2)
    arr.append(3)
    arr.clear()
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 5)
    assert_true(arr.is_empty())
    assert_false(arr.is_full())

def test_fixed_array_clear_then_refill() raises:
    """After clear, array can be refilled via append."""
    var arr = Slab[Int].create(3)
    arr.append(1)
    arr.append(2)
    arr.append(3)
    arr.clear()
    arr.append(10)
    arr.append(20)
    assert_equal(len(arr), 2)
    assert_equal(arr[0], 10)
    assert_equal(arr[1], 20)


# =============================================================================
# Ref safety -- verify borrow returns correct value
# =============================================================================

def test_fixed_array_ref_access() raises:
    """Ref returned by __getitem__ gives correct value."""
    var arr = Slab[Int].create(3)
    arr.append(42)
    arr.append(99)
    var v0 = arr[0]
    var v1 = arr[1]
    assert_equal(v0, 42)
    assert_equal(v1, 99)


# =============================================================================
# Move semantics
# =============================================================================

def test_fixed_array_move() raises:
    """Moving Slab transfers ownership; original becomes empty."""
    var arr = Slab[Int].create(5)
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

def test_fixed_array_destructor_on_drop() raises:
    """Dropping a Slab destroys all elements exactly once."""
    var ctr = _alloc_counter()
    # Scope block: inner array is destroyed when function returns
    var arr = Slab[TrackedValue].create(3)
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    arr.append(TrackedValue(3, ctr))
    _ = arr^  # explicit drop
    assert_equal(ctr[], 3)
    ctr.free()

def test_fixed_array_destructor_on_clear() raises:
    """Clear destroys all elements, then dropping destroys nothing extra."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue].create(3)
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    arr.append(TrackedValue(3, ctr))
    assert_equal(ctr[], 0)  # none destroyed yet
    arr.clear()
    assert_equal(ctr[], 3)  # all 3 destroyed by clear
    _ = arr^  # drop -- destructor runs but _size == 0
    assert_equal(ctr[], 3)  # no additional destructions
    ctr.free()

def test_fixed_array_destructor_on_set() raises:
    """Set destroys the old element."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue].create(3)
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))
    assert_equal(ctr[], 0)
    # Replace element 0 -- old TrackedValue(1) should be destroyed
    arr.set(0, TrackedValue(99, ctr))
    assert_equal(ctr[], 1)  # one destruction from set
    _ = arr^  # drop -- 2 remaining elements destroyed
    assert_equal(ctr[], 3)  # 1 from set + 2 from drop
    ctr.free()

def test_fixed_array_destructor_empty_array() raises:
    """Dropping an empty Slab calls no destructors."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue].create(10)
    _ = arr^  # drop
    assert_equal(ctr[], 0)
    ctr.free()

def test_fixed_array_destructor_zero_capacity() raises:
    """Dropping a zero-capacity Slab is a no-op."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue]()
    _ = arr^
    assert_equal(ctr[], 0)
    ctr.free()


# =============================================================================
# steal_slab (returns a new Slab, not a raw pointer tuple).
# =============================================================================

def test_fixed_array_steal_slab() raises:
    """steal_slab moves contents into a new Slab, leaves source empty."""
    var ctr = _alloc_counter()
    var arr = Slab[TrackedValue].create(4)
    arr.append(TrackedValue(1, ctr))
    arr.append(TrackedValue(2, ctr))

    var stolen = arr.steal_slab()

    # Source is empty, no elements destroyed (moved to stolen)
    assert_equal(len(arr), 0)
    assert_equal(arr.capacity(), 0)
    assert_equal(ctr[], 0)

    # Stolen Slab owns the original elements
    assert_equal(len(stolen), 2)
    assert_equal(stolen[0].id(), 1)
    assert_equal(stolen[1].id(), 2)

    # Drop stolen -- destroys the 2 elements
    _ = stolen^
    assert_equal(ctr[], 2)
    ctr.free()


# =============================================================================
# Edge cases
# =============================================================================

def test_fixed_array_capacity_zero() raises:
    """Zero-capacity Slab: len=0, is_empty, is_full."""
    var arr = Slab[Int]()
    assert_equal(len(arr), 0)
    assert_true(arr.is_empty())
    assert_true(arr.is_full())

def test_fixed_array_capacity_one() raises:
    """Capacity-1 Slab: append one element, full."""
    var arr = Slab[Int].create(1)
    assert_false(arr.is_full())
    arr.append(42)
    assert_true(arr.is_full())
    assert_equal(arr[0], 42)

def test_fixed_array_large_capacity() raises:
    """Slab with 100K elements -- all accessible."""
    var arr = Slab[Int].create(100000)
    for i in range(100000):
        arr.append(i)
    assert_equal(len(arr), 100000)
    assert_true(arr.is_full())
    # Spot check
    assert_equal(arr[0], 0)
    assert_equal(arr[999], 999)
    assert_equal(arr[50000], 50000)
    assert_equal(arr[99999], 99999)


# =============================================================================
# With real types: Slab[Column]
# =============================================================================

def test_fixed_array_column() raises:
    """Slab[Column[HeapRegion]] -- the actual hot-path use case."""
    var vals_i64: List[Scalar[DType.int64]] = [1, 2, 3]
    var vals_f64: List[Scalar[DType.float64]] = [1.0, 2.0, 3.0]
    var a0 = PrimitiveArray[DType.int64].from_list(vals_i64)
    var a1 = PrimitiveArray[DType.float64].from_list(vals_f64)

    var arr = Slab[Column[HeapRegion]].create(2)
    arr.append(Column.from_primitive[DType.int64](a0))
    arr.append(Column.from_primitive[DType.float64](a1))

    assert_equal(len(arr), 2)
    assert_true(arr.is_full())
    # Verify column types via arrow_type
    assert_equal(arr[0].arrow_type, ArrowType.INT64)
    assert_equal(arr[1].arrow_type, ArrowType.FLOAT64)

def test_fixed_array_recordbatch() raises:
    """Slab[RecordBatch] -- morsel storage use case."""
    # Build a simple RecordBatch
    var sb = SchemaBuilder()
    sb.add_field(Field("x", DType.int64, nullable=False))
    var schema = sb.build()

    var vals: List[Scalar[DType.int64]] = [10, 20, 30]
    var a0 = PrimitiveArray[DType.int64].from_list(vals)
    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](a0))
    var batch = builder.build(schema^)

    # Store in Slab
    var arr = Slab[RecordBatch].create(1)
    arr.append(batch^)
    assert_equal(len(arr), 1)
    assert_equal(arr[0].num_rows(), 3)


# =============================================================================
# Nested: Slab[Slab[Int]]
# =============================================================================

def test_fixed_array_nested() raises:
    """Nested Slab -- verifies Slab[T] is Movable."""
    var outer = Slab[Slab[Int]].create(3)

    var inner1 = Slab[Int].create(2)
    inner1.append(10)
    inner1.append(20)
    outer.append(inner1^)

    var inner2 = Slab[Int].create(2)
    inner2.append(30)
    inner2.append(40)
    outer.append(inner2^)

    assert_equal(len(outer), 2)
    assert_equal(len(outer[0]), 2)
    assert_equal(outer[0][0], 10)
    assert_equal(outer[0][1], 20)
    assert_equal(outer[1][0], 30)
    assert_equal(outer[1][1], 40)

def test_fixed_array_nested_destructor() raises:
    """Nested Slab destruction -- all inner elements destroyed."""
    var ctr = _alloc_counter()
    var outer = Slab[Slab[TrackedValue]].create(2)

    var inner1 = Slab[TrackedValue].create(2)
    inner1.append(TrackedValue(1, ctr))
    inner1.append(TrackedValue(2, ctr))
    outer.append(inner1^)

    var inner2 = Slab[TrackedValue].create(3)
    inner2.append(TrackedValue(3, ctr))
    inner2.append(TrackedValue(4, ctr))
    inner2.append(TrackedValue(5, ctr))
    outer.append(inner2^)

    _ = outer^  # drop -- destroys 2 inner arrays, each destroys elements
    assert_equal(ctr[], 5)
    ctr.free()


# =============================================================================
# Main -- discover and run all tests
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
