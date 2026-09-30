# =============================================================================
# test_column_builder.mojo — `ColumnBuilder[dtype]`
# =============================================================================
#
# Unit tests for `ColumnBuilder[dtype]` (single-materialize discipline, plus
# the passthrough-projection fast path).
#
# Coverage:
#   1. with_capacity + sequential append (computed-projection shape).
#   2. append_simd[W] — bulk SIMD write.
#   3. append_at(idx, value) — indexed write for two-pass survivor shape.
#   4. append_null — lazy validity allocation + null tracking.
#   5. from_existing_array — passthrough-projection fast path (no copy
#      semantics at the buffer-move level).
#   6. materialize() — produces a Column round-trip.
#   7. Grow-on-demand — append beyond initial capacity.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.arrow_types import ArrowType

from komira_core.collections.column_builder import ColumnBuilder


# ---------------------------------------------------------------------------
# with_capacity + sequential append
# ---------------------------------------------------------------------------


def test_column_builder_i64_append_basic() raises:
    """with_capacity(N) + N appends + materialize round-trips."""
    var b = ColumnBuilder[DType.int64].with_capacity(4)
    b.append(Scalar[DType.int64](10))
    b.append(Scalar[DType.int64](20))
    b.append(Scalar[DType.int64](30))
    b.append(Scalar[DType.int64](40))
    assert_equal(b.length(), 4)
    assert_false(b.has_nulls())
    var col = b^.materialize()
    assert_equal(col._length, 4)
    assert_equal(col.arrow_type, ArrowType.INT64)


def test_column_builder_f64_append_basic() raises:
    """Float64 builder sequential append."""
    var b = ColumnBuilder[DType.float64].with_capacity(3)
    b.append(Scalar[DType.float64](1.5))
    b.append(Scalar[DType.float64](2.5))
    b.append(Scalar[DType.float64](3.5))
    assert_equal(b.length(), 3)
    var col = b^.materialize()
    assert_equal(col._length, 3)


def test_column_builder_grow_on_demand() raises:
    """Appending beyond initial capacity triggers _grow."""
    var b = ColumnBuilder[DType.int64].with_capacity(2)
    assert_equal(b.capacity(), 2)
    b.append(Scalar[DType.int64](1))
    b.append(Scalar[DType.int64](2))
    b.append(Scalar[DType.int64](3))  # triggers _grow
    b.append(Scalar[DType.int64](4))
    b.append(Scalar[DType.int64](5))
    assert_equal(b.length(), 5)
    assert_true(b.capacity() >= 5)


# ---------------------------------------------------------------------------
# append_simd[W]
# ---------------------------------------------------------------------------


def test_column_builder_append_simd_w4() raises:
    """append_simd[4] writes 4 values at the current logical end."""
    var b = ColumnBuilder[DType.int64].with_capacity(4)
    var vec = SIMD[DType.int64, 4](100, 200, 300, 400)
    b.append_simd[4](vec)
    assert_equal(b.length(), 4)
    var col = b^.materialize()
    assert_equal(col._length, 4)


def test_column_builder_append_simd_then_scalar() raises:
    """Mixed simd append + scalar append produce contiguous results."""
    var b = ColumnBuilder[DType.int64].with_capacity(8)
    var vec = SIMD[DType.int64, 4](1, 2, 3, 4)
    b.append_simd[4](vec)
    b.append(Scalar[DType.int64](5))
    b.append(Scalar[DType.int64](6))
    assert_equal(b.length(), 6)


# ---------------------------------------------------------------------------
# append_at — indexed writes for two-pass survivor shape
# ---------------------------------------------------------------------------


def test_column_builder_append_at_sequential() raises:
    """Sequential append_at(0, ...), append_at(1, ...) == append() sequence."""
    var b = ColumnBuilder[DType.int64].with_capacity(3)
    b.append_at(0, Scalar[DType.int64](111))
    b.append_at(1, Scalar[DType.int64](222))
    b.append_at(2, Scalar[DType.int64](333))
    assert_equal(b.length(), 3)


def test_column_builder_append_at_grows_buffer() raises:
    """append_at beyond capacity grows the buffer."""
    var b = ColumnBuilder[DType.int64].with_capacity(2)
    b.append_at(0, Scalar[DType.int64](1))
    b.append_at(5, Scalar[DType.int64](2))  # idx=5 > capacity=2; grow
    assert_equal(b.length(), 6)  # length tracks max-idx+1
    assert_true(b.capacity() >= 6)


# ---------------------------------------------------------------------------
# append_null — lazy validity bitmap
# ---------------------------------------------------------------------------


def test_column_builder_append_null_first_call_allocates_validity() raises:
    """First append_null lazy-allocates validity; back-fills prior slots
    as VALID."""
    var b = ColumnBuilder[DType.int64].with_capacity(4)
    b.append(Scalar[DType.int64](10))  # row 0: valid
    b.append(Scalar[DType.int64](20))  # row 1: valid
    assert_false(b.has_nulls())
    b.append_null()                        # row 2: NULL (lazy-allocates)
    b.append(Scalar[DType.int64](40))  # row 3: valid
    assert_true(b.has_nulls())
    assert_equal(b.length(), 4)


def test_column_builder_append_null_only_route() raises:
    """All-null builder is a valid degenerate shape."""
    var b = ColumnBuilder[DType.int64].with_capacity(3)
    b.append_null()
    b.append_null()
    b.append_null()
    assert_equal(b.length(), 3)
    assert_true(b.has_nulls())


# ---------------------------------------------------------------------------
# from_existing_array — passthrough-projection fast path
# ---------------------------------------------------------------------------


def test_column_builder_from_existing_array_basic() raises:
    """from_existing_array moves an existing PrimitiveArray into the builder."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
        Scalar[DType.int64](3),
        Scalar[DType.int64](4),
    ]
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var b = ColumnBuilder[DType.int64].from_existing_array(arr^)
    assert_equal(b.length(), 4)
    var col = b^.materialize()
    assert_equal(col._length, 4)


def test_column_builder_from_existing_then_materialize() raises:
    """from_existing_array + materialize round-trip preserves values."""
    var vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.0),
        Scalar[DType.float64](2.0),
        Scalar[DType.float64](3.0),
    ]
    var arr = PrimitiveArray[DType.float64].from_list(vals)
    var b = ColumnBuilder[DType.float64].from_existing_array(arr^)
    var col = b^.materialize()
    assert_equal(col._length, 3)
    assert_equal(col.arrow_type, ArrowType.FLOAT64)


# ---------------------------------------------------------------------------
# BOOL — the layout the Arrow spec requires, not the layout `List[Scalar]` has
# ---------------------------------------------------------------------------
#
# `column_builder.mojo`'s header defers "String / Bool" together as "separate
# primitives needed". They are NOT the same edge, and the difference is the
# whole reason these tests exist:
#
#   * STRING does not type-check at all — `Scalar[DType]` cannot hold one, so
#     the refusal is a compile error and nothing wrong can be emitted.
#   * BOOL type-checks, runs, and emits a column whose `arrow_type` says BOOL
#     while its data buffer holds ONE BYTE PER VALUE. Arrow BOOLEAN is
#     1-bit-packed (`boolean_array.mojo` header: "8x more compact than using
#     1 byte per boolean (PrimitiveArray[DType.bool])"), and every consumer
#     reads it that way — `Column.as_boolean()` copies `(length + 7) >> 3`
#     bytes and calls `Bitmap.test(i)`.
#
# So Bool's edge is the SILENT one, and it is reachable from the customer
# surface today: `Map1[..., DType.bool, ...]` (`typed_udf_sugar.mojo`, whose
# `_dtag_of_dtype` maps `DType.bool` -> `DT_BOOL`) lands in
# `EvaluatorAdapterFor_Map.emit_projected`, which builds
# `MultiColumnBuilder[ColumnSlot[F.OutType]]` -> `ColumnBuilder[DType.bool]`.
# ---------------------------------------------------------------------------


def test_column_builder_bool_materializes_bit_packed() raises:
    """A BOOL column must round-trip through `Column.as_boolean()`.

    A `materialize()` that routes every dtype through `Column.from_primitive`
    memcpys `length * size_of[Scalar[dt]]()` bytes — 8 bytes for 8 booleans —
    and stamps `ArrowType.BOOL` on the result. `as_boolean()` then
    reinterprets the first `(8 + 7) >> 3 == 1` of those bytes AS THE BIT
    DATA.

    For the alternating pattern [T,F,T,F,T,F,T,F] the byte buffer is
    `01 00 01 00 01 00 01 00`; byte 0 is `0x01`, so the bitmap reads back
    as [T,F,F,F,F,F,F,F] — WRONG at rows 2, 4 and 6, right at rows
    0,1,3,5,7. A row-count assertion passes clean either way.
    """
    var b = ColumnBuilder[DType.bool].with_capacity(8)
    for i in range(8):
        b.append(Scalar[DType.bool](i % 2 == 0))
    assert_equal(b.length(), 8)

    var col = b^.materialize()
    assert_equal(col.arrow_type, ArrowType.BOOL)
    assert_equal(col._length, 8)

    var arr = col.as_boolean()
    assert_equal(arr.length, 8)
    for i in range(8):
        assert_equal(
            arr.get(i),
            i % 2 == 0,
            String("bool row ") + String(i) + String(" round-trip"),
        )


def test_column_builder_bool_all_true_not_truncated() raises:
    """9 True values: the 9th lives in byte 1 of the bitmap.

    A byte-per-value buffer fails this for a second, independent reason: it
    is 9 bytes of `01`, so `as_boolean()` copies `(9+7)>>3 == 2` bytes —
    `01 01` — and reads [T,F,F,F,F,F,F,F, T]. Rows 1..7 are wrong.
    """
    var b = ColumnBuilder[DType.bool].with_capacity(9)
    for _i in range(9):
        b.append(Scalar[DType.bool](True))
    var col = b^.materialize()
    var arr = col.as_boolean()
    assert_equal(arr.length, 9)
    for i in range(9):
        assert_true(arr.get(i), String("bool row ") + String(i) + String(" must be True"))


def test_column_builder_bool_nulls_keep_validity_separate() raises:
    """A null BOOL slot is distinct from a False BOOL value.

    The validity bitmap says NULL; the data bit says False. Both are read
    from separate buffers, so a builder that conflates them is wrong in a
    way no value assertion alone would catch.
    """
    var b = ColumnBuilder[DType.bool].with_capacity(4)
    b.append(Scalar[DType.bool](True))
    b.append_null()
    b.append(Scalar[DType.bool](False))
    b.append(Scalar[DType.bool](True))
    assert_equal(b.length(), 4)
    assert_equal(b.null_count(), 1)

    var col = b^.materialize()
    assert_equal(col.arrow_type, ArrowType.BOOL)
    var arr = col.as_boolean()
    assert_equal(arr.length, 4)
    assert_equal(arr.null_count, 1)
    assert_true(arr.get(0), "row 0 True")
    assert_true(arr.is_null(1), "row 1 NULL")
    assert_false(arr.get(2), "row 2 False (present, not null)")
    assert_false(arr.is_null(2), "row 2 is NOT null")
    assert_true(arr.get(3), "row 3 True")


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_builder_i64_append_basic]()
    suite.test[test_column_builder_f64_append_basic]()
    suite.test[test_column_builder_grow_on_demand]()
    suite.test[test_column_builder_append_simd_w4]()
    suite.test[test_column_builder_append_simd_then_scalar]()
    suite.test[test_column_builder_append_at_sequential]()
    suite.test[test_column_builder_append_at_grows_buffer]()
    suite.test[test_column_builder_append_null_first_call_allocates_validity]()
    suite.test[test_column_builder_append_null_only_route]()
    suite.test[test_column_builder_from_existing_array_basic]()
    suite.test[test_column_builder_from_existing_then_materialize]()
    suite.test[test_column_builder_bool_materializes_bit_packed]()
    suite.test[test_column_builder_bool_all_true_not_truncated]()
    suite.test[test_column_builder_bool_nulls_keep_validity_separate]()
    suite^.run()
