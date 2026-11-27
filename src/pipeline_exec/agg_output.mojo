# =============================================================================
# agg_output -- the single output row of an ungrouped aggregation
# =============================================================================
#
# The output batch has exactly the schema the plan declared, one row. Each
# declared type is a promise the sink keeps or refuses by name:
#
#   COUNT          INT64; never NULL, zero over no row
#   COUNT(DISTINCT)
#                  INT64 like COUNT: the number of distinct non-NULL values,
#                  never NULL, zero over no row or only NULLs
#   SUM            INT64 over an integer input (a sum outside the 64-bit range
#                  is refused, not wrapped), or DECIMAL(38, 0) over an integer
#                  input when the plan declares that (the SQL integer sum: the
#                  128-bit total is written as it is, and one with more than 38
#                  digits is refused), or DECIMAL128 of the input's scale
#                  over a DECIMAL128 input (a sum with more digits than the
#                  declared precision is refused), or FLOAT64 over a FLOAT32
#                  or FLOAT64 input (DuckDB's sum of a FLOAT is a DOUBLE)
#   AVG            FLOAT64 over an integer or DECIMAL128 input. The sum and the
#                  count are exact, so the answer is DuckDB's: its long-double
#                  steps on the exact sum, the count and the scale
#                  (`avg_integer_float64`, `avg_decimal_float64`), the same on
#                  every schedule. Over a float input, the double sum divided
#                  by the count in double, as DuckDB's avg of a DOUBLE: its
#                  last bits follow the sum's (`agg_fold`)
#   MIN, MAX       the input's own type: its integer type, DATE32, a
#                  DECIMAL128 of the input's scale, FLOAT32 or FLOAT64
#   STDDEV_SAMP, STDDEV_POP, VAR_SAMP, VAR_POP
#                  FLOAT64: DuckDB's finalize of the Welford state, m2 / (n - 1)
#                  for VAR_SAMP and m2 / n for VAR_POP, the square root for the
#                  STDDEVs. The sample forms are NULL over one value, the
#                  population forms 0.0; an answer that is not finite (an
#                  infinite or NaN input) is refused by name, as DuckDB refuses
#                  it ("out of range")
#   MEDIAN, QUANTILE_CONT
#                  FLOAT64: the interpolated value `agg_values` wrote
#
# The declared precision is the plan's (DuckDB declares DECIMAL(38,s) for a
# decimal SUM): the sink takes it as given and checks only that the value has
# no more digits.
#
# Every aggregate but the counts is NULL over no non-NULL row, which the
# declared field must be able to hold.

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Schema
from byte_buffer.heap_region import HeapRegion
from std.math import isfinite, sqrt

from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_STDDEV_SAMP,
    AGG_SUM,
    AGG_VAR_POP,
    AGG_VAR_SAMP,
)
from scalar_arithmetic.decimal_arith import I128
from scalar_arithmetic.decimal_avg import (
    avg_decimal_float64,
    avg_integer_float64,
)

from .agg_fold import (
    AggCell,
    IN_DATE,
    IN_DECIMAL,
    IN_FLOAT,
    IN_INT,
    IN_NONE,
    agg_name,
    is_welford,
    keeps_values,
)


def _int_bits(t: ArrowType) -> Int:
    """The width of a signed integer type: the one fact that picks the way
    DuckDB averages it (`scalar_arithmetic.decimal_avg`)."""
    if t == ArrowType.INT8:
        return 8
    if t == ArrowType.INT16:
        return 16
    if t == ArrowType.INT32:
        return 32
    return 64


def _wide(v: Int64) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _pow10(digits: Int) raises -> I128:
    if digits < 0 or digits > 38:
        raise Error(
            "pipeline_exec: a DECIMAL128 precision of "
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
    if func == AGG_COUNT or func == AGG_COUNT_DISTINCT:
        ok = t == ArrowType.INT64
    elif func == AGG_SUM:
        ok = (
            t == ArrowType.INT64
            or t == ArrowType.DECIMAL128
            or t == ArrowType.FLOAT64
        )
    elif func == AGG_MEAN or is_welford(func) or keeps_values(func):
        ok = t == ArrowType.FLOAT64
    elif func == AGG_MIN or func == AGG_MAX:
        ok = (
            _is_int_type(t)
            or t == ArrowType.DATE32
            or t == ArrowType.DECIMAL128
            or t == ArrowType.FLOAT32
            or t == ArrowType.FLOAT64
        )
    if not ok:
        raise Error(
            "pipeline_exec: "
            + label
            + " cannot produce the declared output type "
            + String(t)
            + " of column "
            + String(idx)
        )


def welford_answer(
    func: UInt8, ref cell: AggCell, ref label: String
) raises -> Float64:
    """The answer of the variance aggregate `func` over the state of `cell`,
    which folded at least one value (two for the sample forms): DuckDB's
    finalize, which refuses an answer that is not finite."""
    var n = Float64(cell.count)
    var out: Float64
    if func == AGG_VAR_SAMP:
        out = cell.m2 / (n - 1.0)
    elif func == AGG_STDDEV_SAMP:
        out = sqrt(cell.m2 / (n - 1.0))
    elif func == AGG_VAR_POP:
        out = cell.m2 / n if cell.count > 1 else 0.0
    else:
        out = sqrt(cell.m2 / n) if cell.count > 1 else 0.0
    if not isfinite(out):
        raise Error(
            "pipeline_exec: "
            + label
            + " is out of range: the answer is not finite (an infinite or NaN"
            " value, or one past the double range), which DuckDB refuses too"
        )
    return out


def _null_or_value_error(ref label: String) -> Error:
    return Error(
        "pipeline_exec: "
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


def _float_column[
    dtype: DType
](
    ref cells: List[AggCell],
    first: Int,
    stride: Int,
    ref nulls: List[Bool],
) raises -> Column[HeapRegion]:
    var rows = len(nulls)
    var arr = PrimitiveArray[dtype].allocate_nullable(rows)
    for r in range(rows):
        if nulls[r]:
            arr._set_null(r)
        else:
            # A FLOAT32 output holds a MIN or MAX of FLOAT32 values, each
            # widened exactly, so the narrowing is exact.
            arr.set(r, cells[first + r * stride].fvalue.cast[dtype]())
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
    var counts = func == AGG_COUNT or func == AGG_COUNT_DISTINCT
    var sample = func == AGG_STDDEV_SAMP or func == AGG_VAR_SAMP
    var nulls = List[Bool](capacity=rows)
    for r in range(rows):
        ref cell = cells[first + r * stride]
        var is_null = cell.count == 0 and not counts
        if sample and cell.count == 1:
            is_null = True
        if is_null and not nullable:
            raise _null_or_value_error(label)
        nulls.append(is_null)

    if counts:
        var values = List[I128](capacity=rows)
        var no_nulls = List[Bool](capacity=rows)
        for r in range(rows):
            values.append(_wide(Int64(cells[first + r * stride].count)))
            no_nulls.append(False)
        return _int_column[DType.int64](values, no_nulls, t)

    if is_welford(func):
        var arr = PrimitiveArray[DType.float64].allocate_nullable(rows)
        for r in range(rows):
            if nulls[r]:
                arr._set_null(r)
            else:
                arr.set(r, welford_answer(func, cells[first + r * stride], label))
        return Column.from_primitive[DType.float64](arr^)

    if keeps_values(func):
        var arr = PrimitiveArray[DType.float64].allocate_nullable(rows)
        for r in range(rows):
            if nulls[r]:
                arr._set_null(r)
            else:
                arr.set(r, cells[first + r * stride].fvalue)
        return Column.from_primitive[DType.float64](arr^)

    if func == AGG_MEAN:
        var arr = PrimitiveArray[DType.float64].allocate_nullable(rows)
        for r in range(rows):
            if nulls[r]:
                arr._set_null(r)
            else:
                ref cell = cells[first + r * stride]
                if cell.kind == IN_FLOAT:
                    arr.set(r, cell.fvalue / Float64(cell.count))
                elif cell.kind == IN_DECIMAL:
                    arr.set(
                        r,
                        avg_decimal_float64(
                            cell.value, cell.count, cell.precision, cell.scale
                        ),
                    )
                else:
                    arr.set(
                        r,
                        avg_integer_float64(
                            cell.value, cell.count, _int_bits(cell.arrow)
                        ),
                    )
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
            elif cell.kind == IN_FLOAT:
                same = t == (ArrowType.FLOAT64 if func == AGG_SUM else cell.arrow)
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
                    "pipeline_exec: "
                    + label
                    + " over a column of type "
                    + String(cell.arrow)
                    + " cannot fill the declared output type "
                    + String(t)
                    + " of column "
                    + String(idx)
                )
        values.append(cell.value)
    if t == ArrowType.FLOAT64:
        return _float_column[DType.float64](cells, first, stride, nulls)
    if t == ArrowType.FLOAT32:
        return _float_column[DType.float32](cells, first, stride, nulls)
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
                        "pipeline_exec: "
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
                    "pipeline_exec: "
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
