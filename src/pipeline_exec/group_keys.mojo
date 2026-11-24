# =============================================================================
# group_keys -- key columns as 64-bit cells, and back
# =============================================================================
#
# The grouped aggregation sink keys a group by 64-bit cells and a NULL flag per
# cell. Which columns are keys, and how many cells each takes, is the sink's
# row:
#
#   KEY_DTYPE_I64, KEY_DTYPE_I32   INT8, INT16, INT32 and INT64 columns, each
#                                  widened to one Int64 cell
#   KEY_DTYPE_F64, KEY_DTYPE_F32   FLOAT32 and FLOAT64 columns, each as the bit
#                                  pattern of its value as a Float64 (a
#                                  FLOAT32 widens exactly), after two values
#                                  are made canonical: -0.0 is +0.0, and every
#                                  NaN is one NaN. Equal floats are therefore
#                                  one group, and so are all NaNs.
#   KEY_DTYPE_DATE32               DATE32 columns, the day number widened to
#                                  one Int64 cell
#   KEY_DTYPE_BOOL                 BOOL columns, one cell holding 0 or 1
#   KEY_DTYPE_DECIMAL128           DECIMAL128 columns, two cells: the low and
#                                  the high 64 bits of the unscaled value. A
#                                  column must carry the scale the sink's
#                                  output declares for it, and no more digits
#                                  than its declared precision, so equal
#                                  unscaled values are equal decimals.
#
# A composite key (`KEY_DTYPE_COMPOSITE`, `sink_string_group_agg`) reads each
# of its fixed-width columns under the row `fixed_key_dtype` names for the
# column's type, so its cells are the ones that row gives.
#
# A column of any other type, or of a family the row does not name, is refused
# by name. Every cell under a NULL is zero, and all cells of one key column
# carry that column's flag.

from std.memory import bitcast

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import RecordBatch, Schema
from byte_buffer.heap_region import HeapRegion
from physical_plan.physical_plan import (
    KEY_DTYPE_BOOL,
    KEY_DTYPE_DATE32,
    KEY_DTYPE_DECIMAL128,
    KEY_DTYPE_F32,
    KEY_DTYPE_F64,
    KEY_DTYPE_I64,
    KEY_DTYPE_NONE,
)

comptime _CANONICAL_NAN: UInt64 = 0x7FF8000000000000


struct KeyColumn(Movable):
    """One key column of a morsel as cells, `width` cells to a row; `null`
    holds one flag per row and is empty without a NULL."""

    var cells: List[Int64]
    var null: List[UInt8]
    var arrow: ArrowType
    var width: Int

    def __init__(out self):
        self.cells = List[Int64]()
        self.null = List[UInt8]()
        self.arrow = ArrowType.NULL
        self.width = 1


def is_int_key_type(t: ArrowType) -> Bool:
    return (
        t == ArrowType.INT8
        or t == ArrowType.INT16
        or t == ArrowType.INT32
        or t == ArrowType.INT64
    )


def is_float_key_type(t: ArrowType) -> Bool:
    return t == ArrowType.FLOAT32 or t == ArrowType.FLOAT64


def key_width(arrow: ArrowType) -> Int:
    """The cells a key column of this type takes: two for a DECIMAL128, one
    for every other type."""
    if arrow == ArrowType.DECIMAL128:
        return 2
    return 1


def fixed_key_dtype(t: ArrowType) -> UInt8:
    """The fixed-width row that keys a column of type `t` (I64 for every
    integer, F64 for both floats, DATE32, BOOL, DECIMAL128), or
    `KEY_DTYPE_NONE` when no fixed-width row keys it. A composite key reads
    each of its fixed-width columns under this row."""
    if is_int_key_type(t):
        return KEY_DTYPE_I64
    if is_float_key_type(t):
        return KEY_DTYPE_F64
    if t == ArrowType.DATE32:
        return KEY_DTYPE_DATE32
    if t == ArrowType.BOOL:
        return KEY_DTYPE_BOOL
    if t == ArrowType.DECIMAL128:
        return KEY_DTYPE_DECIMAL128
    return KEY_DTYPE_NONE


def row_keys_type(key_dtype: UInt8, t: ArrowType) -> Bool:
    """True when the sink row `key_dtype` keys a column of type `t`."""
    if key_dtype == KEY_DTYPE_F64 or key_dtype == KEY_DTYPE_F32:
        return is_float_key_type(t)
    if key_dtype == KEY_DTYPE_DATE32:
        return t == ArrowType.DATE32
    if key_dtype == KEY_DTYPE_BOOL:
        return t == ArrowType.BOOL
    if key_dtype == KEY_DTYPE_DECIMAL128:
        return t == ArrowType.DECIMAL128
    return is_int_key_type(t)


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


def _read_bool(
    mut out: KeyColumn, ref col: Column[HeapRegion], rows: Int
) raises:
    var arr = col.as_boolean()
    var has_nulls = col.null_count() > 0
    out.cells.reserve(rows)
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            out.null.append(1)
            out.cells.append(0)
        else:
            out.cells.append(Int64(1) if arr.get(r) else Int64(0))
            if has_nulls:
                out.null.append(0)


def _read_decimal(
    mut out: KeyColumn, ref col: Column[HeapRegion], rows: Int
) raises:
    var arr = col.as_decimal128()
    var has_nulls = col.null_count() > 0
    out.width = 2
    out.cells.reserve(rows * 2)
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            out.null.append(1)
            out.cells.append(0)
            out.cells.append(0)
        else:
            out.cells.append(arr.get_low(r))
            out.cells.append(arr.get_high(r))
            if has_nulls:
                out.null.append(0)


def _refuse_family(ref label: String, t: ArrowType, key_dtype: UInt8) -> Error:
    var keys: String
    if key_dtype == KEY_DTYPE_F64 or key_dtype == KEY_DTYPE_F32:
        keys = "the F64 and F32 rows key FLOAT32 and FLOAT64"
    elif key_dtype == KEY_DTYPE_DATE32:
        keys = "the DATE32 row keys DATE32"
    elif key_dtype == KEY_DTYPE_BOOL:
        keys = "the BOOL row keys BOOL"
    elif key_dtype == KEY_DTYPE_DECIMAL128:
        keys = "the DECIMAL128 row keys DECIMAL128"
    else:
        keys = "the I64 and I32 rows key INT8 to INT64"
    return Error(
        "pipeline_exec: " + label + " is a " + String(t) + " column; " + keys
    )


def read_key_column(
    ref batch: RecordBatch,
    col_idx: Int,
    rows: Int,
    key_dtype: UInt8,
    ref declared: Schema,
    declared_idx: Int,
    ref label: String,
) raises -> KeyColumn:
    """Column `col_idx` (`rows` rows) of `batch` as key cells, for the sink
    row `key_dtype`. A DECIMAL128 column is checked against field
    `declared_idx` of `declared`, the type the sink outputs for this key."""
    ref col = batch.column_at(col_idx)
    var t = col.arrow_type
    if col.length() != rows:
        raise Error(
            "pipeline_exec: "
            + label
            + " got a column of "
            + String(col.length())
            + " rows for "
            + String(rows)
            + " selected rows"
        )
    if not row_keys_type(key_dtype, t):
        raise _refuse_family(label, t, key_dtype)
    var out = KeyColumn()
    out.arrow = t
    if t == ArrowType.FLOAT64:
        _read_float[DType.float64](out, col, rows)
    elif t == ArrowType.FLOAT32:
        _read_float[DType.float32](out, col, rows)
    elif t == ArrowType.INT64:
        _read_int[DType.int64](out, col, rows)
    elif t == ArrowType.INT32 or t == ArrowType.DATE32:
        _read_int[DType.int32](out, col, rows)
    elif t == ArrowType.INT16:
        _read_int[DType.int16](out, col, rows)
    elif t == ArrowType.INT8:
        _read_int[DType.int8](out, col, rows)
    elif t == ArrowType.BOOL:
        _read_bool(out, col, rows)
    else:
        var scale = declared.field_decimal_scale(declared_idx)
        var precision = declared.field_decimal_precision(declared_idx)
        if (
            col.decimal_scale() != scale
            or col.decimal_precision() > precision
        ):
            raise Error(
                "pipeline_exec: "
                + label
                + " is a DECIMAL("
                + String(col.decimal_precision())
                + ", "
                + String(col.decimal_scale())
                + ") column, and the sink declares the key DECIMAL("
                + String(precision)
                + ", "
                + String(scale)
                + ")"
            )
        _read_decimal(out, col, rows)
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


def _bool_out(
    ref cells: List[Int64],
    ref nulls: List[UInt8],
    nk: Int,
    k: Int,
    rows: Int,
) raises -> Column[HeapRegion]:
    var arr = BooleanArray.allocate_nullable(rows)
    for g in range(rows):
        if nulls[g * nk + k] != 0:
            arr._set_null(g)
        else:
            arr.set(g, cells[g * nk + k] != 0)
    return Column.from_boolean(arr^)


def _date_out(
    ref cells: List[Int64],
    ref nulls: List[UInt8],
    nk: Int,
    k: Int,
    rows: Int,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(rows)
    for g in range(rows):
        if nulls[g * nk + k] != 0:
            arr._set_null(g)
        else:
            arr.set(g, cells[g * nk + k].cast[DType.int32]())
    return Column.from_primitive_with_arrow_type[DType.int32](
        arr^, ArrowType.DATE32
    )


def _decimal_out(
    ref cells: List[Int64],
    ref nulls: List[UInt8],
    nk: Int,
    k: Int,
    rows: Int,
    precision: Int,
    scale: Int,
) raises -> Column[HeapRegion]:
    var arr = Decimal128Array.allocate_nullable(rows, precision, scale)
    for g in range(rows):
        if nulls[g * nk + k] != 0:
            arr.set_null(g)
        else:
            arr.set_raw(g, cells[g * nk + k], cells[g * nk + k + 1])
    return Column.from_decimal128(arr^)


def key_output_column(
    ref cells: List[Int64],
    ref nulls: List[UInt8],
    nk: Int,
    k: Int,
    rows: Int,
    ref schema: Schema,
    field: Int,
) raises -> Column[HeapRegion]:
    """The key whose cells start at cell `k` of `rows` groups, stored `nk`
    cells to a group, as a column of the type of field `field` of
    `schema`."""
    var arrow = schema.field_arrow_type(field)
    if arrow == ArrowType.INT64:
        return _int_out[DType.int64](cells, nulls, nk, k, rows)
    if arrow == ArrowType.INT32:
        return _int_out[DType.int32](cells, nulls, nk, k, rows)
    if arrow == ArrowType.INT16:
        return _int_out[DType.int16](cells, nulls, nk, k, rows)
    if arrow == ArrowType.INT8:
        return _int_out[DType.int8](cells, nulls, nk, k, rows)
    if arrow == ArrowType.DATE32:
        return _date_out(cells, nulls, nk, k, rows)
    if arrow == ArrowType.BOOL:
        return _bool_out(cells, nulls, nk, k, rows)
    if arrow == ArrowType.DECIMAL128:
        return _decimal_out(
            cells,
            nulls,
            nk,
            k,
            rows,
            schema.field_decimal_precision(field),
            schema.field_decimal_scale(field),
        )
    if arrow == ArrowType.FLOAT64:
        return _float_out[DType.float64](cells, nulls, nk, k, rows)
    return _float_out[DType.float32](cells, nulls, nk, k, rows)
