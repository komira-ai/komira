# =============================================================================
# bulk_columns.mojo — nullable typed columns for the `_bulk` DocBatch
# =============================================================================
#
# The three column builders bulk.mojo uses for its inferred fields: a nullable
# STRING (keyword), INT64 or FLOAT64 column built from a value List and a
# per-row validity List (False = a null cell).
# =============================================================================

from std.sys import size_of

from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


def str_col_nullable(
    values: List[String], valid: List[Bool]
) raises -> Column[HeapRegion]:
    """A nullable STRING (keyword) fast-field column (mirrors the unit-fixture
    helper)."""
    return Column.from_string(
        StringArray.from_strings_with_validity(values, valid)
    )


def i64_col_nullable(
    raw: List[Int64], valid: List[Bool]
) raises -> Column[HeapRegion]:
    """A nullable INT64 fast-field column (mirrors the unit-fixture helper, but
    takes a per-row validity List rather than a null-index list)."""
    var n = len(raw)
    comptime es = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * es)
    for i in range(n):
        buf.set_typed[Scalar[DType.int64]](i, raw[i])
    buf.set_length(Int64(n * es))
    var bm = Bitmap.create_all_valid(n)
    var null_count = 0
    for i in range(n):
        if not valid[i]:
            bm.clear(i)
            null_count += 1
    var arr = PrimitiveArray[DType.int64](
        buf^, n, Optional[Bitmap[HeapRegion]](bm^), null_count, 0
    )
    return Column.from_primitive[DType.int64](arr)


def f64_col_nullable(
    raw: List[Float64], valid: List[Bool]
) raises -> Column[HeapRegion]:
    """A nullable FLOAT64 fast-field column (NET-NEW, doc 18 §A4 — no
    _f64_col_nullable existed in the unit fixtures; this mirrors
    _i64_col_nullable with DType.float64)."""
    var n = len(raw)
    comptime es = size_of[Scalar[DType.float64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * es)
    for i in range(n):
        buf.set_typed[Scalar[DType.float64]](i, raw[i])
    buf.set_length(Int64(n * es))
    var bm = Bitmap.create_all_valid(n)
    var null_count = 0
    for i in range(n):
        if not valid[i]:
            bm.clear(i)
            null_count += 1
    var arr = PrimitiveArray[DType.float64](
        buf^, n, Optional[Bitmap[HeapRegion]](bm^), null_count, 0
    )
    return Column.from_primitive[DType.float64](arr)
