# =============================================================================
# Tests for PrimitiveArray (the core packages)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false


from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_buffer.byte_view import ByteView


def test_allocate_zeros() raises:
    """PrimitiveArray.allocate() creates a zero-initialized array."""
    var arr = PrimitiveArray[DType.int32].allocate(10)
    assert_equal(arr.length, 10)
    assert_equal(arr.null_count, 0)
    for i in range(10):
        assert_equal(arr.get(i), Scalar[DType.int32](0))


def test_from_list() raises:
    """PrimitiveArray.from_list stores and retrieves values."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
    ]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    assert_equal(arr.length, 3)
    assert_equal(arr.get(0), Scalar[DType.int32](10))
    assert_equal(arr.get(1), Scalar[DType.int32](20))
    assert_equal(arr.get(2), Scalar[DType.int32](30))


def test_set_value() raises:
    """set() writes a value at the given index."""
    var arr = PrimitiveArray[DType.int64].allocate(5)
    arr.set(2, Scalar[DType.int64](42))
    assert_equal(arr.get(2), Scalar[DType.int64](42))
    assert_equal(arr.get(0), Scalar[DType.int64](0))


def test_get_out_of_bounds() raises:
    """get() raises on out-of-bounds access."""
    var arr = PrimitiveArray[DType.int32].allocate(3)
    var raised = False
    try:
        _ = arr.get(5)
    except:
        raised = True
    assert_true(raised)


def test_set_out_of_bounds() raises:
    """set() raises on out-of-bounds access."""
    var arr = PrimitiveArray[DType.int32].allocate(3)
    var raised = False
    try:
        arr.set(10, Scalar[DType.int32](1))
    except:
        raised = True
    assert_true(raised)


def test_allocate_nullable() raises:
    """allocate_nullable creates an array with validity bitmap."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(4)
    assert_equal(arr.length, 4)
    assert_equal(arr.null_count, 0)
    # All elements start valid
    for i in range(4):
        assert_false(arr.is_null(i))


def test_is_null_no_bitmap() raises:
    """is_null returns False for non-nullable arrays."""
    var arr = PrimitiveArray[DType.int32].allocate(3)
    for i in range(3):
        assert_false(arr.is_null(i))


def test_simd_load_store() raises:
    """SIMD load/store round-trips values correctly."""
    var arr = PrimitiveArray[DType.float64].allocate(4)
    var vec = SIMD[DType.float64, 4](1.0, 2.0, 3.0, 4.0)
    arr.store[4](0, vec)
    var loaded = arr.load[4](0)
    assert_equal(loaded[0], 1.0)
    assert_equal(loaded[1], 2.0)
    assert_equal(loaded[2], 3.0)
    assert_equal(loaded[3], 4.0)


def test_float64_from_list() raises:
    """PrimitiveArray works with float64 values."""
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.5),
        Scalar[DType.float64](2.7),
    ]
    var arr = PrimitiveArray[DType.float64].from_list(values)
    assert_equal(arr.length, 2)
    assert_equal(arr.get(0), Scalar[DType.float64](1.5))
    assert_equal(arr.get(1), Scalar[DType.float64](2.7))


def test_empty_array() raises:
    """Allocating a zero-length array is valid."""
    var arr = PrimitiveArray[DType.int32].allocate(0)
    assert_equal(arr.length, 0)


# =============================================================================
# PrimitiveArray._set_null tests
# =============================================================================


def test_set_null_marks_element_null() raises:
    """_set_null marks a previously-valid element as null."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(4)
    arr.set(0, Scalar[DType.int32](10))
    arr.set(1, Scalar[DType.int32](20))
    arr.set(2, Scalar[DType.int32](30))
    arr.set(3, Scalar[DType.int32](40))
    # All should be valid initially
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))
    assert_false(arr.is_null(2))
    assert_false(arr.is_null(3))
    # null_count starts at 0 (all-valid via allocate_nullable).
    assert_equal(arr.null_count, 0)
    # Now mark index 2 as null
    arr._set_null(2)
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))
    assert_true(arr.is_null(2))
    assert_false(arr.is_null(3))
    # _set_null must bump null_count (mirrors BooleanArray._set_null). A drifted null_count==0
    # silently drops the null in every null_count-gated writer (ORC PRESENT,
    # arrow IPC validity buffer, parquet def-levels).
    assert_equal(arr.null_count, 1)


def test_set_null_then_set_valid_via_set() raises:
    """Setting a value on a null element restores it to valid."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(3)
    arr.set(0, Scalar[DType.int32](100))
    arr.set(1, Scalar[DType.int32](200))
    arr.set(2, Scalar[DType.int32](300))
    # Mark index 1 as null
    arr._set_null(1)
    assert_true(arr.is_null(1))
    assert_equal(arr.null_count, 1)
    # Now set it back to a value — should restore validity AND decrement
    # null_count (set/_set_null are symmetric inverses).
    arr.set(1, Scalar[DType.int32](999))
    assert_false(arr.is_null(1))
    assert_equal(arr.get(1), Scalar[DType.int32](999))
    assert_equal(arr.null_count, 0)


def test_set_null_multiple_elements() raises:
    """_set_null works on multiple elements in the same array."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(5)
    for i in range(5):
        arr.set(i, Scalar[DType.int32](i * 10))
    arr._set_null(0)
    arr._set_null(2)
    arr._set_null(4)
    assert_true(arr.is_null(0))
    assert_false(arr.is_null(1))
    assert_true(arr.is_null(2))
    assert_false(arr.is_null(3))
    assert_true(arr.is_null(4))
    # 3 _set_null calls => null_count == 3 (a count left at 0 silently drops
    # the nulls in every null_count-gated writer).
    assert_equal(arr.null_count, 3)


# =============================================================================
# PrimitiveArray.from_view tests. The factory builds a non-owning
# PrimitiveArray over a ByteView; the MmapAlignedBuffer field uses a
# capacity=0 sentinel so __del__ is a no-op. The regression tests below
# exercise the wildcard-origin alias-analysis path (writes through the owner observed through the borrow,
# and vice versa) -- if the writes were silently elided the assertions
# would fail.
# =============================================================================


def test_from_view_borrow_observes_owner_writes() raises:
    """from_view: writes through owner are observable through the borrow.

    Regression for the wildcard-origin alias-analysis trap: the wildcard
    origin on the MmapAlignedBuffer field
    can let the compiler elide writes through the owner before reads
    through the borrow. The test would fail if those writes were elided.
    """
    var owner = SharedAlignedBuffer[HeapRegion].heap_owned(64)
    owner.zero()
    # Write 8 float64 values via owner.set_typed.
    for i in range(8):
        owner.set_typed[Scalar[DType.float64]](
            i, Scalar[DType.float64](Float64(i) * 1.5)
        )
    # Borrow the entire buffer (offset=0, length=8 elems = 64 bytes).
    # from_owner holds an Arc keepalive on owner's region, so the borrow
    # stays valid even if `owner` is ASAP-dropped before the read loop.
    var arr = PrimitiveArray[DType.float64].from_owner(owner, 8)
    # Verify the borrow sees the owner's writes (would fail if elided).
    for i in range(8):
        assert_equal(arr.get(i), Scalar[DType.float64](Float64(i) * 1.5))


def test_from_view_owner_observes_borrow_writes() raises:
    """from_view: writes through the borrow are observable through owner.

    The borrow is non-owning but its writes alias the owner's bytes.
    Mirror of the previous test from the opposite direction; both must
    pass for the alias relationship to be sound.
    """
    var owner = SharedAlignedBuffer[HeapRegion].heap_owned(32)
    owner.zero()
    var arr = PrimitiveArray[DType.float64].from_owner(owner, 4)
    # Mutate via the borrow's set (it is mutable through PrimitiveArray.set).
    arr.set(0, Scalar[DType.float64](3.14))
    arr.set(1, Scalar[DType.float64](-2.5))
    arr.set(2, Scalar[DType.float64](100.0))
    arr.set(3, Scalar[DType.float64](0.0625))
    # Owner observes the writes through its typed accessor.
    assert_equal(
        owner.get_typed[Scalar[DType.float64]](0),
        Scalar[DType.float64](3.14),
    )
    assert_equal(
        owner.get_typed[Scalar[DType.float64]](1),
        Scalar[DType.float64](-2.5),
    )
    assert_equal(
        owner.get_typed[Scalar[DType.float64]](2),
        Scalar[DType.float64](100.0),
    )
    assert_equal(
        owner.get_typed[Scalar[DType.float64]](3),
        Scalar[DType.float64](0.0625),
    )


def test_from_view_with_offset() raises:
    """from_view honors the `offset` argument (the shape of a morsel column borrow).

    The owner has 16 elements; the borrow exposes elements [4, 12) by
    requesting offset=4, length=8. Reads through the borrow address
    elements 0..7 from the borrow's perspective, which map to elements
    4..11 in the owner.
    """
    var owner = SharedAlignedBuffer[HeapRegion].heap_owned(128)  # 16 * 8 bytes
    owner.zero()
    for i in range(16):
        owner.set_typed[Scalar[DType.float64]](
            i, Scalar[DType.float64](Float64(i * 7))
        )
    # from_owner slices owner at element offset=4, exposing 8 elements.
    var arr = PrimitiveArray[DType.float64].from_owner(owner, 8, 4)
    assert_equal(arr.length, 8)
    # Borrow's element i corresponds to owner's element (4 + i).
    for i in range(8):
        assert_equal(
            arr.get(i), Scalar[DType.float64](Float64((4 + i) * 7))
        )


def test_from_view_drop_does_not_free_owner() raises:
    """from_view returns a non-owning array; dropping it must NOT free owner.

    If the borrow's __del__ erroneously called free(), subsequent reads
    through the owner would return garbage / SIGSEGV. The test would
    fail (or crash) if the capacity-0 sentinel were not honored.
    """
    var owner = SharedAlignedBuffer[HeapRegion].heap_owned(32)
    owner.zero()
    owner.set_typed[Scalar[DType.float64]](0, Scalar[DType.float64](42.0))
    owner.set_typed[Scalar[DType.float64]](1, Scalar[DType.float64](99.0))
    # Take a borrow, drop it.
    var arr = PrimitiveArray[DType.float64].from_owner(owner, 4)
    _ = arr^
    # Owner survived -- subsequent reads / writes must work.
    assert_equal(
        owner.get_typed[Scalar[DType.float64]](0),
        Scalar[DType.float64](42.0),
    )
    assert_equal(
        owner.get_typed[Scalar[DType.float64]](1),
        Scalar[DType.float64](99.0),
    )
    owner.set_typed[Scalar[DType.float64]](2, Scalar[DType.float64](-1.0))
    assert_equal(
        owner.get_typed[Scalar[DType.float64]](2),
        Scalar[DType.float64](-1.0),
    )


def test_from_view_simd_load() raises:
    """from_view-backed arrays support SIMD load (the morsel hot path)."""
    var owner = SharedAlignedBuffer[HeapRegion].heap_owned(64)
    owner.zero()
    for i in range(8):
        owner.set_typed[Scalar[DType.float64]](
            i, Scalar[DType.float64](Float64(i) + 0.5)
        )
    var arr = PrimitiveArray[DType.float64].from_owner(owner, 8)
    var v = arr.load[4](0)
    assert_equal(v[0], Float64(0.5))
    assert_equal(v[1], Float64(1.5))
    assert_equal(v[2], Float64(2.5))
    assert_equal(v[3], Float64(3.5))
    var v2 = arr.load[4](4)
    assert_equal(v2[0], Float64(4.5))
    assert_equal(v2[1], Float64(5.5))
    assert_equal(v2[2], Float64(6.5))
    assert_equal(v2[3], Float64(7.5))


# =============================================================================
# validity_load[W] tests
# =============================================================================
#
# A SIMD-friendly validity reader that returns SIMD[DType.bool, W] for W
# contiguous elements.


def test_validity_load_no_bitmap_all_true() raises:
    """validity_load on a no-validity-bitmap array returns all-True."""
    var arr = PrimitiveArray[DType.int64].allocate(8)
    var v = arr.validity_load[4](0)
    assert_true(v[0])
    assert_true(v[1])
    assert_true(v[2])
    assert_true(v[3])
    # Second chunk also all-True.
    var v2 = arr.validity_load[4](4)
    assert_true(v2[0])
    assert_true(v2[1])
    assert_true(v2[2])
    assert_true(v2[3])


def test_validity_load_all_valid_returns_all_true() raises:
    """validity_load on a fully-valid nullable array returns all-True."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(8)
    for i in range(8):
        arr.set(i, Scalar[DType.int32](i * 11))
    var v = arr.validity_load[8](0)
    for j in range(8):
        assert_true(v[j])


def test_validity_load_w4_mixed_nulls() raises:
    """validity_load[W=4] reflects the per-element null state correctly."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(8)
    for i in range(8):
        arr.set(i, Scalar[DType.int32](i))
    # Null indices 1 and 3 (so the W=4 chunk at offset 0 is T F T F).
    arr._set_null(1)
    arr._set_null(3)
    var v = arr.validity_load[4](0)
    assert_true(v[0])
    assert_false(v[1])
    assert_true(v[2])
    assert_false(v[3])
    # Second chunk at offset 4: all True (no nulls placed there).
    var v2 = arr.validity_load[4](4)
    assert_true(v2[0])
    assert_true(v2[1])
    assert_true(v2[2])
    assert_true(v2[3])


def test_validity_load_w8_mixed_nulls() raises:
    """validity_load[W=8] across a byte boundary reads bits correctly."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(16)
    for i in range(16):
        arr.set(i, Scalar[DType.int64](i * 100))
    # Null every odd index in [0, 8).
    arr._set_null(1)
    arr._set_null(3)
    arr._set_null(5)
    arr._set_null(7)
    var v = arr.validity_load[8](0)
    assert_true(v[0])
    assert_false(v[1])
    assert_true(v[2])
    assert_false(v[3])
    assert_true(v[4])
    assert_false(v[5])
    assert_true(v[6])
    assert_false(v[7])


def test_validity_load_out_of_bounds_raises() raises:
    """validity_load raises when index + W > length."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(4)
    var raised = False
    try:
        _ = arr.validity_load[4](2)  # would read indices 2..5; length=4
    except:
        raised = True
    assert_true(raised)


def test_set_null_is_idempotent() raises:
    """`_set_null` on an ALREADY-NULL row must not change `null_count`.

    ⛔ REGRESSION GUARD. An UNCONDITIONAL `null_count += 1` double-counts:
    when one writer ASSIGNS the count from a finished bitmap and a second
    writer then re-imposes the same validity, every NULL row is counted
    TWICE (`BooleanArray._set_null` has the same guard).

    ⚠ "A caller that also stamps `null_count` with an ASSIGNMENT overwrites
    this increment" only holds when the assignment comes AFTER. With an
    assignment FIRST, then the loop, nothing overwrites it.

    ⚠ NOT AN INTERNAL DETAIL. `null_count` rides the Arrow IPC `FieldNode` and
    the C-Data `ArrowArray.null_count`, so a wrong value is wire-format
    corruption a pyarrow/DuckDB consumer reads and validates.

    The sibling `_set_valid` already recomputes from the bitmap; this asserts
    the same invariant on the other direction. It also asserts that a DIFFERENT
    row still increments, so the guard cannot be satisfied by deleting the bump.
    """
    var arr = PrimitiveArray[DType.int32].allocate_nullable(4)
    assert_equal(arr.null_count, 0, "freshly allocated nullable: no nulls")

    arr._set_null(1)
    assert_true(arr.is_null(1), "row 1 is NULL after the first mark")
    assert_equal(arr.null_count, 1, "the first mark counts one NULL")

    arr._set_null(1)
    assert_true(arr.is_null(1), "row 1 is still NULL after re-marking")
    assert_equal(arr.null_count, 1, "re-marking an ALREADY-NULL row counts nothing")

    # ⛔ THE OTHER DIRECTION, so deleting the increment cannot satisfy this test.
    arr._set_null(2)
    assert_true(arr.is_null(2), "row 2 is NULL")
    assert_equal(arr.null_count, 2, "a DIFFERENT row still increments")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
