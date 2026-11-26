# =============================================================================
# cast_bool: CAST between BOOLEAN and the fixed-width numeric types
# =============================================================================
#
# DuckDB's rule for both directions, read from the pinned release:
#   * BOOLEAN -> INT8..INT64, UINT8..UINT64, FLOAT, DOUBLE: true is 1, false
#     is 0, NULL stays NULL.
#   * INT8..INT64, UINT8..UINT64, FLOAT, DOUBLE -> BOOLEAN: a value is true
#     when it is not equal to zero, so NaN is true and -0.0 is false; NULL
#     stays NULL.
# Neither direction has a value that fails, so CAST and TRY_CAST give the
# same answer and nothing here reads the TRY flag.
#
# A NULL row is written as 0 (or a false data bit), never as whatever the
# source slot held: the bool consumers read data bits without the validity
# bitmap, so a NULL must carry a false bit.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.bitmap import Bitmap
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from byte_buffer.heap_region import HeapRegion


def _bool_to_numeric[
    dst: DType
](arr: BooleanArray) raises -> PrimitiveArray[dst]:
    """1 for a true row, 0 for a false or NULL row; the null mask is kept."""
    var n = arr.length
    var out = PrimitiveArray[dst].allocate(n)
    var one = Scalar[dst](1)
    if arr.validity:
        ref valid = arr.validity.value()
        for i in range(n):
            if valid.test(i) and arr.data.test(i):
                out.set(i, one)
        var kept = Bitmap.copy_slice_from(valid, 0, n)
        out.null_count = kept.null_count()
        out.validity = kept^
    else:
        for i in range(n):
            if arr.data.test(i):
                out.set(i, one)
    return out^


def _numeric_to_bool[src: DType](arr: PrimitiveArray[src]) raises -> BooleanArray:
    """True for a row not equal to zero, false for zero or NULL; the null
    mask is kept."""
    var n = arr.length
    var zero = Scalar[src](0)
    if arr.validity:
        var out = BooleanArray.allocate(n)
        var kept = Bitmap.copy_slice_from(arr.validity.value(), arr.offset, n)
        for i in range(n):
            if kept.test(i) and arr.get(i) != zero:
                out.set(i, True)
        out.null_count = kept.null_count()
        out.validity = kept^
        return out^
    var out = BooleanArray.allocate(n)
    for i in range(n):
        if arr.get(i) != zero:
            out.set(i, True)
    return out^


def _is_bool_cast_numeric(at: ArrowType) -> Bool:
    """The types a BOOLEAN casts to and from here."""
    return (
        at == ArrowType.INT8
        or at == ArrowType.INT16
        or at == ArrowType.INT32
        or at == ArrowType.INT64
        or at == ArrowType.UINT8
        or at == ArrowType.UINT16
        or at == ArrowType.UINT32
        or at == ArrowType.UINT64
        or at == ArrowType.FLOAT32
        or at == ArrowType.FLOAT64
    )


def _from_bool[dst: DType](col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    return Column.from_primitive[dst](_bool_to_numeric[dst](col.as_boolean()))


def _cast_from_bool(
    col: Column[HeapRegion], target: DType
) raises -> Column[HeapRegion]:
    """CAST of a BOOLEAN column to `target`, one of `_is_bool_cast_numeric`."""
    if target == DType.int8:
        return _from_bool[DType.int8](col)
    if target == DType.int16:
        return _from_bool[DType.int16](col)
    if target == DType.int32:
        return _from_bool[DType.int32](col)
    if target == DType.int64:
        return _from_bool[DType.int64](col)
    if target == DType.uint8:
        return _from_bool[DType.uint8](col)
    if target == DType.uint16:
        return _from_bool[DType.uint16](col)
    if target == DType.uint32:
        return _from_bool[DType.uint32](col)
    if target == DType.uint64:
        return _from_bool[DType.uint64](col)
    if target == DType.float32:
        return _from_bool[DType.float32](col)
    return _from_bool[DType.float64](col)


def _to_bool[src: DType](col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    return Column.from_boolean(_numeric_to_bool[src](col.as_primitive[src]()))


def _cast_to_bool(
    col: Column[HeapRegion], src_at: ArrowType
) raises -> Column[HeapRegion]:
    """CAST of a column of `src_at`, one of `_is_bool_cast_numeric`, to
    BOOLEAN."""
    if src_at == ArrowType.INT8:
        return _to_bool[DType.int8](col)
    if src_at == ArrowType.INT16:
        return _to_bool[DType.int16](col)
    if src_at == ArrowType.INT32:
        return _to_bool[DType.int32](col)
    if src_at == ArrowType.INT64:
        return _to_bool[DType.int64](col)
    if src_at == ArrowType.UINT8:
        return _to_bool[DType.uint8](col)
    if src_at == ArrowType.UINT16:
        return _to_bool[DType.uint16](col)
    if src_at == ArrowType.UINT32:
        return _to_bool[DType.uint32](col)
    if src_at == ArrowType.UINT64:
        return _to_bool[DType.uint64](col)
    if src_at == ArrowType.FLOAT32:
        return _to_bool[DType.float32](col)
    return _to_bool[DType.float64](col)
