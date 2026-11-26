# =============================================================================
# partition_narrow_int -- window SUM / AVG / MIN / MAX over INT8, INT16, INT32
# =============================================================================
#
# The window aggregate kernels read INT64 and FLOAT64 columns only. A narrow
# integer argument is served by widening it once: `partition_scan_sink` runs
# the kernels over a batch that carries the widened column under
# `WIDENED_COLUMN` (a name no user column can have, so the original, which may
# be the RANGE order key, stays untouched), then narrows a MIN / MAX result back
# to the declared type.
#
#   SUM, MIN, MAX          INT8 / INT16 / INT32 -> INT64 (NULLs kept)
#   AVG over INT32         INT64: the kernels average an INT64 in long double,
#                          as DuckDB does for a 32-bit column
#   AVG over INT8 / INT16  FLOAT64: DuckDB averages a column of 16 bits or
#                          fewer in double (`scalar_arithmetic.decimal_avg`),
#                          and an integer total below 2^53 is exact in double
#   MIN, MAX result        INT64 -> the input type; lossless, since the result
#                          is one of the input values
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from plan_expr.partition_expr import PF_AVG, PF_MAX, PF_MIN, PF_SUM, PartitionExpr

from .partition_null_policy import cell_is_null


comptime WIDENED_COLUMN = "\x00window_widened_argument"
"""The name of the widened argument column in the batch the kernels read."""


def is_narrow_int(t: ArrowType) -> Bool:
    """True for INT8, INT16 and INT32."""
    return t == ArrowType.INT8 or t == ArrowType.INT16 or t == ArrowType.INT32


def narrow_int_arg_type(batch: RecordBatch, expr: PartitionExpr) raises -> ArrowType:
    """The narrow integer type `expr` aggregates over, or `ArrowType.NULL` when
    `expr` is not a SUM / AVG / MIN / MAX of an INT8, INT16 or INT32 column."""
    if not (
        expr.func == PF_SUM
        or expr.func == PF_AVG
        or expr.func == PF_MIN
        or expr.func == PF_MAX
    ):
        return ArrowType.NULL
    var at = batch.schema.column_index(expr.column)
    var t = batch.column_at(at).arrow_type
    if is_narrow_int(t):
        return t
    return ArrowType.NULL


@always_inline
def _narrow_cell(col: Column[HeapRegion], row: Int) -> Int64:
    var at = col._offset + row
    if col.arrow_type == ArrowType.INT8:
        return Int64(col._data.get_typed[Scalar[DType.int8]](at))
    elif col.arrow_type == ArrowType.INT16:
        return Int64(col._data.get_typed[Scalar[DType.int16]](at))
    return Int64(col._data.get_typed[Scalar[DType.int32]](at))


def widen_to_i64(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """An INT8, INT16 or INT32 column as an INT64 column of the same values,
    NULLs kept."""
    var n = col.length()
    var nulls = col.has_validity_buffer()
    var arr: PrimitiveArray[DType.int64]
    if nulls:
        arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    else:
        arr = PrimitiveArray[DType.int64].allocate(n)
    for row in range(n):
        if nulls and cell_is_null(col, row):
            arr._set_null(row)
        else:
            arr.store[1](row, _narrow_cell(col, row))
    return Column.from_primitive[DType.int64](arr)


def widen_to_f64(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """An INT8 or INT16 column as a FLOAT64 column of the same values, NULLs
    kept (exact: every value is below 2^53)."""
    var n = col.length()
    var nulls = col.has_validity_buffer()
    var arr: PrimitiveArray[DType.float64]
    if nulls:
        arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    else:
        arr = PrimitiveArray[DType.float64].allocate(n)
    for row in range(n):
        if nulls and cell_is_null(col, row):
            arr._set_null(row)
        else:
            arr.store[1](row, Float64(_narrow_cell(col, row)))
    return Column.from_primitive[DType.float64](arr)


def narrow_from_i64(col: Column[HeapRegion], to: ArrowType) raises -> Column[HeapRegion]:
    """An INT64 MIN / MAX result as a column of `to` (INT8, INT16 or INT32).
    The result is one of the input values, so no value changes; NULLs kept."""
    var n = col.length()
    var nulls = col.has_validity_buffer()
    if to == ArrowType.INT8:
        var arr8: PrimitiveArray[DType.int8]
        if nulls:
            arr8 = PrimitiveArray[DType.int8].allocate_nullable(n)
        else:
            arr8 = PrimitiveArray[DType.int8].allocate(n)
        for row in range(n):
            if nulls and cell_is_null(col, row):
                arr8._set_null(row)
            else:
                arr8.store[1](row, Int8(Int(col._data.get_typed[Scalar[DType.int64]](col._offset + row))))
        return Column.from_primitive[DType.int8](arr8)
    elif to == ArrowType.INT16:
        var arr16: PrimitiveArray[DType.int16]
        if nulls:
            arr16 = PrimitiveArray[DType.int16].allocate_nullable(n)
        else:
            arr16 = PrimitiveArray[DType.int16].allocate(n)
        for row in range(n):
            if nulls and cell_is_null(col, row):
                arr16._set_null(row)
            else:
                arr16.store[1](row, Int16(Int(col._data.get_typed[Scalar[DType.int64]](col._offset + row))))
        return Column.from_primitive[DType.int16](arr16)
    var arr32: PrimitiveArray[DType.int32]
    if nulls:
        arr32 = PrimitiveArray[DType.int32].allocate_nullable(n)
    else:
        arr32 = PrimitiveArray[DType.int32].allocate(n)
    for row in range(n):
        if nulls and cell_is_null(col, row):
            arr32._set_null(row)
        else:
            arr32.store[1](row, Int32(Int(col._data.get_typed[Scalar[DType.int64]](col._offset + row))))
    return Column.from_primitive[DType.int32](arr32)


def widened_batch(
    batch: RecordBatch, expr: PartitionExpr, source: ArrowType
) raises -> RecordBatch:
    """`batch` with its columns shared and one more, `WIDENED_COLUMN`: the
    argument of `expr` widened for its kernel (FLOAT64 for an AVG over INT8 or
    INT16, INT64 otherwise)."""
    var at = batch.schema.column_index(expr.column)
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    for i in range(batch.num_columns()):
        builder.add_column(batch.column_at(i).share())
        sb.add_field(batch.schema.field_at(i))
    ref arg = batch.column_at(at)
    if expr.func == PF_AVG and source != ArrowType.INT32:
        builder.add_column(widen_to_f64(arg))
        sb.add_field(Field(String(WIDENED_COLUMN), ArrowType.FLOAT64, arg.has_validity_buffer()))
    else:
        builder.add_column(widen_to_i64(arg))
        sb.add_field(Field(String(WIDENED_COLUMN), ArrowType.INT64, arg.has_validity_buffer()))
    return builder.build(sb.build())


def widened_expr(expr: PartitionExpr) -> PartitionExpr:
    """A copy of `expr` whose argument column is `WIDENED_COLUMN`."""
    var out = expr.copy()
    out.column = String(WIDENED_COLUMN)
    return out^
