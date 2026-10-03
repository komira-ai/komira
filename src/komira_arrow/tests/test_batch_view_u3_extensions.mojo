# =============================================================================
# test_batch_view_u3_extensions.mojo — BatchView / ColView extensions
# =============================================================================
#
# Validates two BatchView/ColView surface additions:
#
#   1. BatchView.col_date32(idx) — semantic alias for col_i32 (Date32 ↔
#      Int32 days-since-epoch storage).
#   2. ColView[T, origin].gather[W](indices, start) — comptime-unrolled
#      SIMD gather (the same shape as the parquet dictionary's
#      `resolve_int32`). AVX-512 emits vpgatherdq; NEON falls through to
#      scalar per-lane loads.
#
# Both serve typed inner-loop program walkers.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.column import Column
from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_arrow.batch_view import BatchView, batch_view_over


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _build_i64_batch(vals: List[Int64]) raises -> RecordBatch:
    """Single-column Int64 RecordBatch."""
    var prim = List[Scalar[DType.int64]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.int64](vals[i]))
    var arr = PrimitiveArray[DType.int64].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return RecordBatch.from_columns_1(sb.build(), arr^)


def _build_i32_batch(vals: List[Int32]) raises -> RecordBatch:
    """Single-column Int32 RecordBatch (used as Date32 surrogate)."""
    var prim = List[Scalar[DType.int32]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.int32](vals[i]))
    var arr = PrimitiveArray[DType.int32].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.INT32, False))
    # `from_columns_1` is the int64-only backward-compat constructor; an
    # Int32 (Date32 surrogate) column must go through the type-erased
    # `from_typed_columns_1` path via `Column.from_primitive`.
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.int32](arr^)
    )


def _build_index_array(idx_vals: List[Int32]) -> PrimitiveArray[DType.int32]:
    """Build a PrimitiveArray[Int32] of row indices for gather tests."""
    var prim = List[Scalar[DType.int32]]()
    for i in range(len(idx_vals)):
        prim.append(Scalar[DType.int32](idx_vals[i]))
    return PrimitiveArray[DType.int32].from_list(prim)


# ---------------------------------------------------------------------------
# col_date32 tests — semantic alias of col_i32 (Int32 storage)
# ---------------------------------------------------------------------------


def test_col_date32_returns_int32_view() raises:
    """col_date32(idx).load[1](k) == underlying Int32 value (no widening)."""
    var dates: List[Int32] = [
        Int32(19000),  # a day number in Int32 storage
        Int32(19365),  # 365 days later
        Int32(20000),  # a round day number
        Int32(20461),  # a later day number
    ]
    var batch = _build_i32_batch(dates)
    var bv = batch_view_over(batch)
    var view = bv.col_date32(0)
    assert_equal(view.length(), 4)
    assert_equal(view.load[1](0)[0], Int32(19000))
    assert_equal(view.load[1](1)[0], Int32(19365))
    assert_equal(view.load[1](2)[0], Int32(20000))
    assert_equal(view.load[1](3)[0], Int32(20461))


def test_col_date32_simd_load_matches_col_i32() raises:
    """col_date32 and col_i32 over the same column produce identical SIMD loads."""
    var dates: List[Int32] = [
        Int32(1),
        Int32(2),
        Int32(3),
        Int32(4),
        Int32(5),
        Int32(6),
        Int32(7),
        Int32(8),
    ]
    var batch = _build_i32_batch(dates)
    var bv = batch_view_over(batch)
    var d_view = bv.col_date32(0)
    var i_view = bv.col_i32(0)
    # Both views should produce the same SIMD load.
    var d_lanes = d_view.load[4](0)
    var i_lanes = i_view.load[4](0)
    for k in range(4):
        assert_equal(d_lanes[k], i_lanes[k])


# ---------------------------------------------------------------------------
# ColView.gather[W] tests — SIMD-friendly per-lane gather
# ---------------------------------------------------------------------------


def test_gather_int64_w4_basic() raises:
    """gather[4] over Int64 column at sparse index set returns the right lanes."""
    # Column: [100, 200, 300, 400, 500, 600, 700, 800].
    var vals: List[Int64] = [100, 200, 300, 400, 500, 600, 700, 800]
    var batch = _build_i64_batch(vals)
    var bv = batch_view_over(batch)
    var col = bv.col_i64(0)

    # Gather rows 0, 3, 5, 7 -> values [100, 400, 600, 800].
    var idx_vals: List[Int32] = [Int32(0), Int32(3), Int32(5), Int32(7)]
    var indices = _build_index_array(idx_vals)
    var lanes = col.gather[4](indices, 0)
    assert_equal(lanes[0], Int64(100))
    assert_equal(lanes[1], Int64(400))
    assert_equal(lanes[2], Int64(600))
    assert_equal(lanes[3], Int64(800))


def test_gather_int64_w4_with_start_offset() raises:
    """gather[4] honors the `start` offset into the indices array."""
    var vals: List[Int64] = [10, 20, 30, 40, 50, 60, 70, 80]
    var batch = _build_i64_batch(vals)
    var bv = batch_view_over(batch)
    var col = bv.col_i64(0)

    # indices = [0, 1, 2, 3, 4, 5, 6, 7]; gather[4] from start=2 -> rows 2,3,4,5.
    var idx_vals: List[Int32] = [
        Int32(0), Int32(1), Int32(2), Int32(3),
        Int32(4), Int32(5), Int32(6), Int32(7),
    ]
    var indices = _build_index_array(idx_vals)
    var lanes = col.gather[4](indices, 2)
    assert_equal(lanes[0], Int64(30))  # rows[2] = 30
    assert_equal(lanes[1], Int64(40))
    assert_equal(lanes[2], Int64(50))
    assert_equal(lanes[3], Int64(60))


def test_gather_int32_w8_avx_friendly() raises:
    """gather[8] over Int32 column — AVX-512 width path."""
    var vals = List[Int32]()
    for i in range(32):
        vals.append(Int32(i * 100))
    var batch = _build_i32_batch(vals)
    var bv = batch_view_over(batch)
    var col = bv.col_i32(0)

    # Gather every-4th row starting at row 0: rows 0, 4, 8, 12, 16, 20, 24, 28.
    var idx_vals = List[Int32]()
    for i in range(8):
        idx_vals.append(Int32(i * 4))
    var indices = _build_index_array(idx_vals)

    var lanes = col.gather[8](indices, 0)
    for k in range(8):
        assert_equal(lanes[k], Int32(k * 400))


def test_gather_duplicate_indices() raises:
    """gather[4] with duplicate indices produces duplicate lanes."""
    var vals: List[Int64] = [11, 22, 33, 44]
    var batch = _build_i64_batch(vals)
    var bv = batch_view_over(batch)
    var col = bv.col_i64(0)

    # Repeated rows 0, 0, 0, 0 -> all lanes = 11.
    var idx_vals: List[Int32] = [Int32(0), Int32(0), Int32(0), Int32(0)]
    var indices = _build_index_array(idx_vals)
    var lanes = col.gather[4](indices, 0)
    for k in range(4):
        assert_equal(lanes[k], Int64(11))


def test_gather_canonical_filter_survivor_shape() raises:
    """End-to-end shape of a TPC-H Q6-style filter-then-gather.

    Filter produces a survivor index list; downstream code gathers
    against that index list to read filtered column values.
    """
    # Column: [0, 100, 200, 300, 400, 500, 600, 700, 800, 900].
    var vals = List[Int64]()
    for i in range(10):
        vals.append(Int64(i * 100))
    var batch = _build_i64_batch(vals)
    var bv = batch_view_over(batch)
    var col = bv.col_i64(0)

    # Survivors of a hypothetical `col > 300` filter: rows 4, 5, 6, 7, 8, 9.
    var idx_vals: List[Int32] = [
        Int32(4), Int32(5), Int32(6), Int32(7),
        Int32(8), Int32(9),
    ]
    var indices = _build_index_array(idx_vals)

    # gather[4] first lane (4 survivors)
    var lanes_a = col.gather[4](indices, 0)
    assert_equal(lanes_a[0], Int64(400))
    assert_equal(lanes_a[1], Int64(500))
    assert_equal(lanes_a[2], Int64(600))
    assert_equal(lanes_a[3], Int64(700))

    # gather[2] tail (remaining 2 survivors)
    var lanes_b = col.gather[2](indices, 4)
    assert_equal(lanes_b[0], Int64(800))
    assert_equal(lanes_b[1], Int64(900))


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
