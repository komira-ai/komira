# =============================================================================
# group_keys -- key columns as 64-bit cells, and back
# =============================================================================
#
# The grouped aggregation sink keys a group by one 64-bit cell per key column
# and a NULL flag. Which columns are keys is the sink's row:
#
#   KEY_DTYPE_I64, KEY_DTYPE_I32   INT8, INT16, INT32 and INT64 columns, each
#                                  widened to an Int64 cell
#   KEY_DTYPE_F64, KEY_DTYPE_F32   FLOAT32 and FLOAT64 columns, each as the bit
#                                  pattern of its value as a Float64 (a
#                                  FLOAT32 widens exactly), after two values
#                                  are made canonical: -0.0 is +0.0, and every
#                                  NaN is one NaN. Equal floats are therefore
#                                  one group, and so are all NaNs.
#
# A column of any other type, or of a family the row does not name, is refused
# by name. The cell under a NULL is zero.

from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch, Schema
from komira_buffer.heap_region import HeapRegion

comptime _CANONICAL_NAN: UInt64 = 0x7FF8000000000000


struct KeyColumn(Movable):
    """One key column of a morsel as cells; `null` is empty without a NULL."""

    var cells: List[Int64]
    var null: List[UInt8]
    var arrow: ArrowType

    def __init__(out self):
        self.cells = List[Int64]()
        self.null = List[UInt8]()
        self.arrow = ArrowType.NULL


def is_int_key_type(t: ArrowType) -> Bool:
    return (
        t == ArrowType.INT8
        or t == ArrowType.INT16
        or t == ArrowType.INT32
        or t == ArrowType.INT64
    )


def is_float_key_type(t: ArrowType) -> Bool:
    return t == ArrowType.FLOAT32 or t == ArrowType.FLOAT64


@always_inline
def float_cell(v: Float64) -> Int64:
    if v != v:
        return bitcast[DType.int64](_CANONICAL_NAN)
    if v == 0.0:
        return Int64(0)
    return bitcast[DType.int64](v)


def _read_int[
    dtype: DType
](mut out: KeyColumn, ref col: Column[HeapRegion], rows: Int) raises:
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    out.cells.reserve(rows)
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            out.null.append(1)
            out.cells.append(0)
        else:
            out.cells.append(Int64(arr.get(r).cast[DType.int64]()))
            if has_nulls:
                out.null.append(0)


def _read_float[
    dtype: DType
](mut out: KeyColumn, ref col: Column[HeapRegion], rows: Int) raises:
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    out.cells.reserve(rows)
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            out.null.append(1)
            out.cells.append(0)
        else:
            out.cells.append(float_cell(arr.get(r).cast[DType.float64]()))
            if has_nulls:
                out.null.append(0)


def read_key_column(
    ref batch: RecordBatch,
    col_idx: Int,
    rows: Int,
    floats: Bool,
    ref label: String,
) raises -> KeyColumn:
    """Column `col_idx` (`rows` rows) of `batch` as key cells. `floats` says
    whether the sink's row keys floats or integers."""
    ref col = batch.column_at(col_idx)
    var t = col.arrow_type
    if col.length() != rows:
        raise Error(
            "komira_pipeline_exec: "
            + label
            + " got a column of "
            + String(col.length())
            + " rows for "
            + String(rows)
            + " selected rows"
        )
    var out = KeyColumn()
    out.arrow = t
    if floats:
        if not is_float_key_type(t):
            raise Error(
                "komira_pipeline_exec: "
                + label
                + " is a "
                + String(t)
                + " column; the F64 and F32 rows key FLOAT32 and FLOAT64"
            )
        if t == ArrowType.FLOAT64:
            _read_float[DType.float64](out, col, rows)
        else:
            _read_float[DType.float32](out, col, rows)
    else:
        if not is_int_key_type(t):
            raise Error(
                "komira_pipeline_exec: "
                + label
                + " is a "
                + String(t)
                + " column; the I64 and I32 rows key INT8 to INT64"
            )
        if t == ArrowType.INT64:
            _read_int[DType.int64](out, col, rows)
        elif t == ArrowType.INT32:
            _read_int[DType.int32](out, col, rows)
        elif t == ArrowType.INT16:
            _read_int[DType.int16](out, col, rows)
        else:
            _read_int[DType.int8](out, col, rows)
    return out^


def _int_out[
    dtype: DType
](
    ref cells: List[Int64],
    ref nulls: List[UInt8],
    nk: Int,
    k: Int,
    rows: Int,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[dtype].allocate_nullable(rows)
    for g in range(rows):
        if nulls[g * nk + k] != 0:
            arr._set_null(g)
        else:
            arr.set(g, cells[g * nk + k].cast[dtype]())
    return Column.from_primitive[dtype](arr^)


def _float_out[
    dtype: DType
](
    ref cells: List[Int64],
    ref nulls: List[UInt8],
    nk: Int,
    k: Int,
    rows: Int,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[dtype].allocate_nullable(rows)
    for g in range(rows):
        if nulls[g * nk + k] != 0:
            arr._set_null(g)
        else:
            arr.set(
                g, bitcast[DType.float64](cells[g * nk + k]).cast[dtype]()
            )
    return Column.from_primitive[dtype](arr^)


def key_output_column(
    ref cells: List[Int64],
    ref nulls: List[UInt8],
    nk: Int,
    k: Int,
    rows: Int,
    arrow: ArrowType,
) raises -> Column[HeapRegion]:
    """Key column `k` of `rows` groups whose keys are stored `nk` cells to a
    group, as a column of type `arrow`."""
    if arrow == ArrowType.INT64:
        return _int_out[DType.int64](cells, nulls, nk, k, rows)
    if arrow == ArrowType.INT32:
        return _int_out[DType.int32](cells, nulls, nk, k, rows)
    if arrow == ArrowType.INT16:
        return _int_out[DType.int16](cells, nulls, nk, k, rows)
    if arrow == ArrowType.INT8:
        return _int_out[DType.int8](cells, nulls, nk, k, rows)
    if arrow == ArrowType.FLOAT64:
        return _float_out[DType.float64](cells, nulls, nk, k, rows)
    return _float_out[DType.float32](cells, nulls, nk, k, rows)
