# =============================================================================
# test_key_column_view.mojo -- primitive test
# =============================================================================
#
# Covers KeyColumnView[dtype, batch_origin] (key_column_view.mojo). The view is a parametric-origin read-only
# view over an Arrow column's data buffer; State structs use it to
# borrow key-column input without wildcards.
#
# Test matrix (6 cases):
#   1. test_empty_view           -- empty() constructor returns a
#                                   zero-length view; len()/is_empty()
#                                   return 0/True.
#   2. test_int64_roundtrip      -- construct view over a heap int64
#                                   buffer, read back every value.
#   3. test_int32_roundtrip      -- same for int32 (different dtype
#                                   parameterization).
#   4. test_float64_get_ref      -- get_ref() returns a ref whose
#                                   origin is the batch origin; value
#                                   matches.
#   5. test_parametric_origin_compiles
#                                 -- demonstrate that a function
#                                    parameterized on `batch_origin`
#                                    can be called with two different
#                                    caller origins. Compile-time
#                                    proof that the parametric-origin
#                                    design doesn't require wildcards.
#   6. test_view_copy_is_cheap_and_correct
#                                 -- Copyable: copying a view gives
#                                    another view over the same buffer
#                                    with identical reads.
# =============================================================================

from std.memory import UnsafePointer, alloc
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.key_column_view import KeyColumnView

@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed null
    UnsafePointer ctor / the `_unsafe_null=()` b1 idiom).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Origin `o` is concrete; the NULL sentinel is never
    # dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# =============================================================================
# Fixture: a tiny heap-backed "column" (simulates an MmapAlignedBuffer).
# =============================================================================


struct ColumnFixture[dtype: DType](Deinitable):
    """Owns a heap buffer of Scalar[dtype] -- stand-in for an Arrow
    column's `data` field in a test context.

    Allocate with size N, then populate via `set(i, v)`. Mirrors the
    "allocate + fill" shape of MmapAlignedBuffer / PrimitiveArray without
    requiring list-literal construction (Mojo 0.26.3 list literals
    don't accept variadic positional args).
    """
    var _buf: UnsafePointer[Scalar[Self.dtype], MutUntrackedOrigin]
    var _len: Int

    def __init__(out self, n: Int):
        self._len = n
        if n == 0:
            self._buf = _null_ptr[Scalar[Self.dtype], MutUntrackedOrigin]()
            return
        self._buf = alloc[Scalar[Self.dtype]](n).unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        for i in range(n):
            self._buf[i] = Scalar[Self.dtype](0)

    def set(mut self, i: Int, v: Scalar[Self.dtype]):
        self._buf[i] = v

    def __deinit__(deinit self):
        if Int(self._buf) != 0:
            self._buf.bitcast[UInt8]().free()


# =============================================================================
# Tests
# =============================================================================


def test_empty_view() raises:
    """KeyColumnView.empty(): zero-length view. len() == 0, is_empty()."""
    # Name the origin concretely by anchoring to a throwaway Int var.
    var anchor: Int = 0
    var ap = Pointer(to=anchor)
    var v = KeyColumnView[
        DType.int64, origin_of(anchor)
    ].empty()
    assert_equal(v.len(), 0, "empty().len() == 0")
    assert_true(v.is_empty(), "empty().is_empty() true")
    _ = ap
    print("  test_empty_view PASS")


def test_int64_roundtrip() raises:
    """Construct a KeyColumnView over a heap Int64 buffer and read
    back every value."""
    var col = ColumnFixture[DType.int64](5)
    col.set(0, Int64(10))
    col.set(1, Int64(20))
    col.set(2, Int64(30))
    col.set(3, Int64(40))
    col.set(4, Int64(50))
    var view = KeyColumnView[DType.int64, origin_of(col)](
        col._buf.unsafe_mut_cast[False]().unsafe_origin_cast[origin_of(col)](),
        col._len,
    )

    assert_equal(view.len(), 5, "len == 5")
    for i in range(5):
        assert_equal(
            view.get(i), Int64((i + 1) * 10),
            "int64 value roundtrip",
        )

    _ = col^
    print("  test_int64_roundtrip PASS")


def test_int32_roundtrip() raises:
    """Same as above but with a different dtype parameterization."""
    var col = ColumnFixture[DType.int32](4)
    col.set(0, Int32(-1))
    col.set(1, Int32(0))
    col.set(2, Int32(1))
    col.set(3, Int32(2))
    var view = KeyColumnView[DType.int32, origin_of(col)](
        col._buf.unsafe_mut_cast[False]().unsafe_origin_cast[origin_of(col)](),
        col._len,
    )

    assert_equal(view.len(), 4, "int32 len")
    assert_equal(view.get(0), Int32(-1), "int32[0]")
    assert_equal(view.get(1), Int32(0), "int32[1]")
    assert_equal(view.get(2), Int32(1), "int32[2]")
    assert_equal(view.get(3), Int32(2), "int32[3]")

    _ = col^
    print("  test_int32_roundtrip PASS")


def test_float64_get_ref() raises:
    """get_ref() returns a ref whose origin is `batch_origin`. The
    value is the expected float."""
    var col = ColumnFixture[DType.float64](3)
    col.set(0, Float64(1.5))
    col.set(1, Float64(2.5))
    col.set(2, Float64(3.5))
    var view = KeyColumnView[DType.float64, origin_of(col)](
        col._buf.unsafe_mut_cast[False]().unsafe_origin_cast[origin_of(col)](),
        col._len,
    )

    # get_ref: value-at-slot via reference.
    ref slot1 = view.get_ref(1)
    assert_equal(slot1, Float64(2.5), "get_ref roundtrip")
    ref slot2 = view.get_ref(2)
    assert_equal(slot2, Float64(3.5), "get_ref [2]")

    _ = col^
    print("  test_float64_get_ref PASS")


# -- Parametric-origin demonstration ------------------------------------------


def _sum_view[
    dtype: DType, o: Origin[mut=False]
](view: KeyColumnView[dtype, o]) -> Scalar[dtype]:
    """Function parameterized on caller origin. Compile-time proof
    that KeyColumnView composes with parametric-origin callers."""
    var acc = Scalar[dtype](0)
    for i in range(view.len()):
        acc = acc + view.get(i)
    return acc


def test_parametric_origin_compiles() raises:
    """Call _sum_view[_, _] twice, each time with a DIFFERENT caller
    origin. If this compiles and runs, the parametric-origin design
    is working correctly for typical call sites."""
    # First call: origin is `col_a`.
    var col_a = ColumnFixture[DType.int64](3)
    col_a.set(0, Int64(1))
    col_a.set(1, Int64(2))
    col_a.set(2, Int64(3))
    var view_a = KeyColumnView[DType.int64, origin_of(col_a)](
        col_a._buf.unsafe_mut_cast[False]().unsafe_origin_cast[origin_of(col_a)](),
        col_a._len,
    )
    var s_a = _sum_view[DType.int64, origin_of(col_a)](view_a)
    assert_equal(s_a, Int64(6), "parametric-origin sum A")

    # Second call: origin is `col_b` -- distinct from col_a's origin.
    var col_b = ColumnFixture[DType.int64](2)
    col_b.set(0, Int64(100))
    col_b.set(1, Int64(200))
    var view_b = KeyColumnView[DType.int64, origin_of(col_b)](
        col_b._buf.unsafe_mut_cast[False]().unsafe_origin_cast[origin_of(col_b)](),
        col_b._len,
    )
    var s_b = _sum_view[DType.int64, origin_of(col_b)](view_b)
    assert_equal(s_b, Int64(300), "parametric-origin sum B")

    _ = col_a^
    _ = col_b^
    print("  test_parametric_origin_compiles PASS")


def test_view_copy_is_cheap_and_correct() raises:
    """KeyColumnView is Copyable. Copy yields a view over the same
    buffer; reads from the copy match the original."""
    var col = ColumnFixture[DType.int64](3)
    col.set(0, Int64(7))
    col.set(1, Int64(8))
    col.set(2, Int64(9))
    var v1 = KeyColumnView[DType.int64, origin_of(col)](
        col._buf.unsafe_mut_cast[False]().unsafe_origin_cast[origin_of(col)](),
        col._len,
    )
    # Implicit copy via function-arg pass-by-value (Copyable).
    var v2 = v1

    assert_equal(v1.len(), v2.len(), "copy length")
    for i in range(3):
        assert_equal(
            v1.get(i), v2.get(i),
            "copied view reads match original",
        )

    _ = col^
    print("  test_view_copy_is_cheap_and_correct PASS")


def main() raises:
    test_empty_view()
    test_int64_roundtrip()
    test_int32_roundtrip()
    test_float64_get_ref()
    test_parametric_origin_compiles()
    test_view_copy_is_cheap_and_correct()
    print("PASS")
