# =============================================================================
# agg_output -- the single output row of an ungrouped aggregation
# =============================================================================
#
# The output batch has exactly the schema the plan declared, one row. Each
# declared type is a promise the sink keeps or refuses by name:
#
#   COUNT          INT64; never NULL, zero over no row
#   SUM            INT64 over an integer input (a sum outside the 64-bit range
#                  is refused, not wrapped), or DECIMAL(38, 0) over an integer
#                  input when the plan declares that (the SQL integer sum: the
#                  128-bit total is written as it is, and one with more than 38
#                  digits is refused), or DECIMAL128 of the input's scale
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
# The declared precision is the plan's (DuckDB declares DECIMAL(38,s) for a
# decimal SUM): the sink takes it as given and checks only that the value has
# no more digits.
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


def _pow10(digits: Int) raises -> I128:
    if digits < 0 or digits > 38:
        raise Error(
            "komira_pipeline_exec: a DECIMAL128 precision of "
            + String(digits)
            + " is outside 0 to 38"
        )
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
](
    ref values: List[I128], ref nulls: List[Bool], arrow: ArrowType
) raises -> Column[HeapRegion]:
    var rows = len(values)
    var arr = PrimitiveArray[dtype].allocate_nullable(rows)
    for r in range(rows):
        if nulls[r]:
            arr._set_null(r)
        else:
            arr.set(r, values[r].cast[dtype]())
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
    var cells = List[AggCell]()
    cells.append(cell.copy())
    return agg_result_column_rows(func, cells, 0, 1, 1, schema, idx, label)


def agg_result_column_rows(
    func: UInt8,
    ref cells: List[AggCell],
    first: Int,
    stride: Int,
    rows: Int,
    ref schema: Schema,
    idx: Int,
    ref label: String,
) raises -> Column[HeapRegion]:
    """The `rows`-row column the declared field `idx` of `schema` asks for;
    row `r` is the aggregate in `cells[first + r * stride]`. Every row is held
    to the rules of the one-row column."""
    var t = schema.field_arrow_type(idx)
    var nullable = schema.field_nullable(idx)
    var nulls = List[Bool](capacity=rows)
    for r in range(rows):
        ref cell = cells[first + r * stride]
        var is_null = cell.count == 0 and func != AGG_COUNT
        if is_null and not nullable:
            raise _null_or_value_error(label)
        nulls.append(is_null)

    if func == AGG_COUNT:
        var values = List[I128](capacity=rows)
        var no_nulls = List[Bool](capacity=rows)
        for r in range(rows):
            values.append(_wide(Int64(cells[first + r * stride].count)))
            no_nulls.append(False)
        return _int_column[DType.int64](values, no_nulls, t)

    if func == AGG_MEAN:
        var arr = PrimitiveArray[DType.float64].allocate_nullable(rows)
        for r in range(rows):
            if nulls[r]:
                arr._set_null(r)
            else:
                ref cell = cells[first + r * stride]
                var sum_f = cell.value.cast[DType.float64]()
                if cell.kind == IN_DECIMAL:
                    sum_f = decimal_to_float64(cell.value, cell.scale)
                arr.set(r, sum_f / Float64(cell.count))
        return Column.from_primitive[DType.float64](arr^)

    # SUM, MIN and MAX: the value keeps the input's type.
    var values = List[I128](capacity=rows)
    for r in range(rows):
        ref cell = cells[first + r * stride]
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
                # An integer sum is INT64, or DECIMAL(38, 0): the carrier of
                # the SQL integer sum (DuckDB's HUGEINT), whose total the
                # fold already holds in 128 bits.
                same = t == ArrowType.INT64 or (
                    t == ArrowType.DECIMAL128
                    and schema.field_decimal_precision(idx) == 38
                    and schema.field_decimal_scale(idx) == 0
                )
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
        values.append(cell.value)
    if t == ArrowType.DECIMAL128:
        var p = schema.field_decimal_precision(idx)
        var s = schema.field_decimal_scale(idx)
        var arr = Decimal128Array.allocate_nullable(rows, p, s)
        var bound = _pow10(p)
        for r in range(rows):
            if nulls[r]:
                arr.set_null(r)
            else:
                if values[r] >= bound or values[r] <= -bound:
                    raise Error(
                        "komira_pipeline_exec: "
                        + label
                        + " has more digits than the declared DECIMAL("
                        + String(p)
                        + ","
                        + String(s)
                        + ") holds"
                    )
                arr.set_i128(r, values[r])
        return Column.from_decimal128(arr^)
    if t == ArrowType.INT64:
        for r in range(rows):
            if not nulls[r] and not _fits_int64(values[r]):
                raise Error(
                    "komira_pipeline_exec: "
                    + label
                    + " is outside the 64-bit range of its declared INT64"
                    " output"
                )
        return _int_column[DType.int64](values, nulls, t)
    if t == ArrowType.INT8:
        return _int_column[DType.int8](values, nulls, t)
    if t == ArrowType.INT16:
        return _int_column[DType.int16](values, nulls, t)
    return _int_column[DType.int32](values, nulls, t)
