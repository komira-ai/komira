# =============================================================================
# agg_output -- the single output row of an ungrouped aggregation
# =============================================================================
#
# The output batch has exactly the schema the plan declared, one row. Each
# declared type is a promise the sink keeps or refuses by name:
#
#   COUNT          INT64; never NULL, zero over no row
#   SUM            INT64 over an integer input (a sum outside the 64-bit range
#                  is refused, not wrapped), or DECIMAL128 of the input's scale
#                  over a DECIMAL128 input (a sum with more digits than the
#                  declared precision is refused)
#   AVG            FLOAT64 over an integer or DECIMAL128 input. The sum and the
#                  count are exact, so the answer is one conversion of the sum
#                  (for a DECIMAL128, the existing `decimal_to_float64` of the
#                  exact sum and the scale) and one division by the count, the
#                  same on every schedule
#   MIN, MAX       the input's own type: its integer type, DATE32, or a
#                  DECIMAL128 of the input's scale
#
# SUM, AVG, MIN and MAX over no non-NULL row are NULL, which the declared field
# must be able to hold.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Schema
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
)
from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import decimal_to_float64

from .agg_fold import (
    AggCell,
    IN_DATE,
    IN_DECIMAL,
    IN_INT,
    IN_NONE,
    agg_name,
)


def _wide(v: Int64) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _pow10(digits: Int) -> I128:
    var out = I128(1)
    for _ in range(digits):
        out = out * I128(10)
    return out


def _is_int_type(t: ArrowType) -> Bool:
    return (
        t == ArrowType.INT8
        or t == ArrowType.INT16
        or t == ArrowType.INT32
        or t == ArrowType.INT64
    )


def check_declared_type(
    func: UInt8, ref schema: Schema, idx: Int, ref label: String
) raises:
    """Refuse, when the sink is built, an output type the aggregate can never
    produce."""
    var t = schema.field_arrow_type(idx)
    var ok = False
    if func == AGG_COUNT:
        ok = t == ArrowType.INT64
    elif func == AGG_SUM:
        ok = t == ArrowType.INT64 or t == ArrowType.DECIMAL128
    elif func == AGG_MEAN:
        ok = t == ArrowType.FLOAT64
    elif func == AGG_MIN or func == AGG_MAX:
        ok = (
            _is_int_type(t)
            or t == ArrowType.DATE32
            or t == ArrowType.DECIMAL128
        )
    if not ok:
        raise Error(
            "komira_pipeline_exec: "
            + label
            + " cannot produce the declared output type "
            + String(t)
            + " of column "
            + String(idx)
        )


def _null_or_value_error(ref label: String) -> Error:
    return Error(
        "komira_pipeline_exec: "
        + label
        + " is NULL over no non-NULL row, and its declared output column is"
        " not nullable"
    )


def _fits_int64(v: I128) -> Bool:
    return v >= _wide(-9223372036854775807 - 1) and v <= _wide(
        9223372036854775807
    )


def _int_column[
    dtype: DType
](value: I128, is_null: Bool, arrow: ArrowType) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[dtype].allocate_nullable(1)
    if is_null:
        arr._set_null(0)
    else:
        arr.set(0, value.cast[dtype]())
    if arrow == ArrowType.DATE32:
        return Column.from_primitive_with_arrow_type[dtype](arr^, arrow)
    return Column.from_primitive[dtype](arr^)


def agg_result_column(
    func: UInt8,
    ref cell: AggCell,
    ref schema: Schema,
    idx: Int,
    ref label: String,
) raises -> Column[HeapRegion]:
    """The one-row column the declared field `idx` of `schema` asks for."""
    var t = schema.field_arrow_type(idx)
    var is_null = cell.count == 0 and func != AGG_COUNT
    if is_null and not schema.field_nullable(idx):
        raise _null_or_value_error(label)

    if func == AGG_COUNT:
        return _int_column[DType.int64](_wide(Int64(cell.count)), False, t)

    if func == AGG_MEAN:
        var arr = PrimitiveArray[DType.float64].allocate_nullable(1)
        if is_null:
            arr._set_null(0)
        else:
            var sum_f = cell.value.cast[DType.float64]()
            if cell.kind == IN_DECIMAL:
                sum_f = decimal_to_float64(cell.value, cell.scale)
            arr.set(0, sum_f / Float64(cell.count))
        return Column.from_primitive[DType.float64](arr^)

    # SUM, MIN and MAX: the value keeps the input's type.
    if cell.kind != IN_NONE:
        var same = False
        if cell.kind == IN_DECIMAL:
            same = (
                t == ArrowType.DECIMAL128
                and schema.field_decimal_scale(idx) == cell.scale
            )
        elif cell.kind == IN_DATE:
            same = t == ArrowType.DATE32
        elif func == AGG_SUM:
            same = t == ArrowType.INT64
        else:
            same = t == cell.arrow
        if not same:
            raise Error(
                "komira_pipeline_exec: "
                + label
                + " over a column of type "
                + String(cell.arrow)
                + " cannot fill the declared output type "
                + String(t)
                + " of column "
                + String(idx)
            )
    if t == ArrowType.DECIMAL128:
        var p = schema.field_decimal_precision(idx)
        var s = schema.field_decimal_scale(idx)
        var arr = Decimal128Array.allocate_nullable(1, p, s)
        if is_null:
            arr.set_null(0)
        else:
            var bound = _pow10(p)
            if cell.value >= bound or cell.value <= -bound:
                raise Error(
                    "komira_pipeline_exec: "
                    + label
                    + " has more digits than the declared DECIMAL("
                    + String(p)
                    + ","
                    + String(s)
                    + ") holds"
                )
            arr.set_i128(0, cell.value)
        return Column.from_decimal128(arr^)
    if not is_null and t == ArrowType.INT64 and not _fits_int64(cell.value):
        raise Error(
            "komira_pipeline_exec: "
            + label
            + " is outside the 64-bit range of its declared INT64 output"
        )
    if t == ArrowType.INT64:
        return _int_column[DType.int64](cell.value, is_null, t)
    if t == ArrowType.INT8:
        return _int_column[DType.int8](cell.value, is_null, t)
    if t == ArrowType.INT16:
        return _int_column[DType.int16](cell.value, is_null, t)
    return _int_column[DType.int32](cell.value, is_null, t)
