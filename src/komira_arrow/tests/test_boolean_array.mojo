# =============================================================================
# Tests for BooleanArray — Arrow-spec 1-bit-packed boolean column
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap


def test_allocate_all_false() raises:
    """allocate() creates a non-nullable array with all False values."""
    var arr = BooleanArray.allocate(16)
    assert_equal(len(arr), 16)
    assert_equal(arr.null_count, 0)
    assert_equal(arr.true_count(), 0)
    assert_equal(arr.false_count(), 16)
    for i in range(16):
        assert_false(arr.get(i))


def test_set_individual_bits() raises:
    """Setting individual bits to True and verifying them."""
    var arr = BooleanArray.allocate(8)
    arr.set(0, True)
    arr.set(3, True)
    arr.set(7, True)
    assert_true(arr.get(0))
    assert_false(arr.get(1))
    assert_false(arr.get(2))
    assert_true(arr.get(3))
    assert_false(arr.get(4))
    assert_false(arr.get(5))
    assert_false(arr.get(6))
    assert_true(arr.get(7))


def test_set_then_clear() raises:
    """Setting a bit to True then False returns to original state."""
    var arr = BooleanArray.allocate(8)
    arr.set(5, True)
    assert_true(arr.get(5))
    arr.set(5, False)
    assert_false(arr.get(5))


def test_get_boundary_positions() raises:
    """get() works at byte and word boundaries: 0, 1, 7, 8, 63, 64."""
    var arr = BooleanArray.allocate(128)
    var positions: List[Int] = [0, 1, 7, 8, 63, 64, 127]
    for pos in positions:
        arr.set(pos, True)
    for pos in positions:
        assert_true(arr.get(pos))
    # Check some positions that should still be False
    assert_false(arr.get(2))
    assert_false(arr.get(9))
    assert_false(arr.get(62))
    assert_false(arr.get(65))


def test_true_count_false_count() raises:
    """true_count() and false_count() are consistent."""
    var arr = BooleanArray.allocate(16)
    assert_equal(arr.true_count(), 0)
    assert_equal(arr.false_count(), 16)
    arr.set(0, True)
    arr.set(5, True)
    arr.set(15, True)
    assert_equal(arr.true_count(), 3)
    assert_equal(arr.false_count(), 13)
    assert_equal(arr.true_count() + arr.false_count(), len(arr))


def test_nullable_allocate() raises:
    """allocate_nullable() creates a nullable array, all valid, all False."""
    var arr = BooleanArray.allocate_nullable(10)
    assert_equal(len(arr), 10)
    assert_equal(arr.null_count, 0)
    for i in range(10):
        assert_false(arr.is_null(i))
        assert_false(arr.get(i))


def test_is_null_default_non_nullable() raises:
    """is_null() returns False for non-nullable arrays."""
    var arr = BooleanArray.allocate(8)
    for i in range(8):
        assert_false(arr.is_null(i))


def test_set_null() raises:
    """_set_null() marks elements as null."""
    var arr = BooleanArray.allocate_nullable(8)
    arr._set_null(3)
    assert_true(arr.is_null(3))
    assert_false(arr.is_null(0))
    assert_equal(arr.null_count, 1)
    arr._set_null(7)
    assert_true(arr.is_null(7))
    assert_equal(arr.null_count, 2)


def test_set_null_on_non_nullable_creates_validity() raises:
    """_set_null() on a non-nullable array creates a validity bitmap."""
    var arr = BooleanArray.allocate(8)
    assert_false(arr.is_null(0))
    arr._set_null(2)
    assert_true(arr.is_null(2))
    assert_false(arr.is_null(0))
    assert_equal(arr.null_count, 1)


def test_set_valid() raises:
    """_set_valid() restores a null element to valid."""
    var arr = BooleanArray.allocate_nullable(8)
    arr._set_null(4)
    assert_true(arr.is_null(4))
    assert_equal(arr.null_count, 1)
    arr._set_valid(4)
    assert_false(arr.is_null(4))
    assert_equal(arr.null_count, 0)


def test_from_bitmap() raises:
    """from_bitmap() wraps an existing Bitmap as a BooleanArray."""
    var bm = Bitmap.create(16)
    bm.set(0)
    bm.set(5)
    bm.set(15)
    var arr = BooleanArray.from_bitmap(bm^)
    assert_equal(len(arr), 16)
    assert_true(arr.get(0))
    assert_false(arr.get(1))
    assert_true(arr.get(5))
    assert_true(arr.get(15))
    assert_equal(arr.true_count(), 3)
    assert_equal(arr.null_count, 0)


def test_len() raises:
    """__len__ returns the correct length for various sizes."""
    var arr1 = BooleanArray.allocate(0)
    assert_equal(len(arr1), 0)
    var arr8 = BooleanArray.allocate(8)
    assert_equal(len(arr8), 8)
    var arr100 = BooleanArray.allocate(100)
    assert_equal(len(arr100), 100)


def test_boundary_sizes() raises:
    """BooleanArray works correctly at boundary sizes: 1, 8, 9, 64, 65."""
    # Size 1
    var arr1 = BooleanArray.allocate(1)
    arr1.set(0, True)
    assert_true(arr1.get(0))
    assert_equal(arr1.true_count(), 1)

    # Size 8 (exact byte)
    var arr8 = BooleanArray.allocate(8)
    for i in range(8):
        arr8.set(i, True)
    assert_equal(arr8.true_count(), 8)
    assert_equal(arr8.false_count(), 0)

    # Size 9 (one past byte boundary)
    var arr9 = BooleanArray.allocate(9)
    arr9.set(8, True)
    assert_true(arr9.get(8))
    assert_equal(arr9.true_count(), 1)
    assert_equal(arr9.false_count(), 8)

    # Size 64 (exact 8-byte / word boundary)
    var arr64 = BooleanArray.allocate(64)
    arr64.set(0, True)
    arr64.set(63, True)
    assert_true(arr64.get(0))
    assert_true(arr64.get(63))
    assert_equal(arr64.true_count(), 2)

    # Size 65 (one past word boundary)
    var arr65 = BooleanArray.allocate(65)
    arr65.set(64, True)
    assert_true(arr65.get(64))
    assert_false(arr65.get(63))
    assert_equal(arr65.true_count(), 1)


def test_get_out_of_bounds() raises:
    """get() raises on out-of-bounds index."""
    var arr = BooleanArray.allocate(8)
    var caught = False
    try:
        _ = arr.get(8)
    except:
        caught = True
    assert_true(caught)

    caught = False
    try:
        _ = arr.get(-1)
    except:
        caught = True
    assert_true(caught)


def test_is_null_out_of_bounds() raises:
    """is_null() raises on out-of-bounds index."""
    var arr = BooleanArray.allocate(8)
    var caught = False
    try:
        _ = arr.is_null(8)
    except:
        caught = True
    assert_true(caught)


def test_set_null_is_idempotent() raises:
    """`_set_null` on an ALREADY-NULL row must not change `null_count`.

    ⛔ REGRESSION GUARD. The eight PATTERN entry points of
    `string_comparison.mojo` call `_apply_validity`, which ASSIGNS
    `null_count` from the finished bitmap. The `EXPR_STRING_OP` PROJECTION
    arm of the column evaluator then re-imposes the child's validity with a
    `_set_null` loop, so an UNCONDITIONAL `null_count += 1` here counts
    every NULL row twice. The validity BITMAP stays correct, so value
    assertions all pass and only the count diverges (expected 1, got 2).

    ⚠ THIS IS NOT AN INTERNAL DETAIL. `null_count` rides the Arrow IPC
    `FieldNode` (`ipc_encoder_dispatch.mojo`) and the C-Data
    `ArrowArray.null_count` (`c_data_interface.mojo`), so a wrong value is
    wire-format corruption a pyarrow/DuckDB consumer reads and validates
    against.

    The sibling `_set_valid` already recomputes the count from the bitmap;
    this is the same invariant stated on the other direction.
    """
    var arr = BooleanArray.allocate(4)
    assert_equal(arr.null_count, 0, "freshly allocated: no nulls")

    arr._set_null(1)
    assert_true(arr.is_null(1), "row 1 is NULL after the first mark")
    assert_equal(arr.null_count, 1, "the first mark counts one NULL")

    arr._set_null(1)
    assert_true(arr.is_null(1), "row 1 is still NULL after re-marking")
    assert_equal(
        arr.null_count,
        1,
        "re-marking an ALREADY-NULL row must not bump null_count",
    )

    arr._set_null(3)
    assert_true(arr.is_null(3), "row 3 is NULL")
    assert_equal(arr.null_count, 2, "a DIFFERENT row still increments")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
