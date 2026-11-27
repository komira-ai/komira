# =============================================================================
# agg_fold -- the fold of one aggregate
# =============================================================================
#
# An `AggCell` is the whole state of one aggregate on one worker: the count of
# the rows it folded, one 128-bit integer, one double, and the type of the
# column it saw.
#
#   COUNT(x)       count of the non-NULL rows of x (COUNT(*) is counted by the
#                  sink from the morsel, not here)
#   SUM(x)         the 128-bit sum of the unscaled values of x, or, over a
#                  float column, the double sum of its values
#   AVG(x)         the same sum and the count; the division is at the end
#   MIN(x), MAX(x) the least or greatest unscaled value of x, or float value
#   COUNT(DISTINCT x)
#                  nothing on a worker; the merge of the workers' distinct
#                  entries (`count_distinct`) sets the count of the merged cell
#   STDDEV_SAMP(x), STDDEV_POP(x), VAR_SAMP(x), VAR_POP(x)
#                  the count, the mean and the sum of squared distances from
#                  it (`mean`, `m2`) of the values of x as DuckDB's DOUBLE
#   MEDIAN(x), QUANTILE_CONT(x, q)
#                  the count of the non-NULL values; the values themselves are
#                  kept by the sink (`agg_values`), which writes the answer
#                  into `fvalue` when it merges them
#
# The unscaled value of an integer column is the integer, of a DECIMAL128
# column its 128-bit integer (the column's scale is kept beside it), and of a
# DATE32 column its day number. Their sum is an integer fold with no float in
# it, so any grouping of the rows into workers gives the same cell: the merge
# adds the sums and the counts, or takes the lesser or greater value.
#
# A FLOAT32 or FLOAT64 column folds into the double (a FLOAT32 value is
# widened first, which is exact), as DuckDB's sum, avg, min and max do:
#
#   SUM, AVG   the sum starts at +0.0 and adds each non-NULL value in row
#              order with IEEE-754 double addition; `merge_cell` adds one
#              cell's sum to another. No overflow is refused: a sum past the
#              double range is an infinity, +inf plus -inf is NaN, and a NaN
#              makes the sum NaN (query_semantics 5.7). Rounding depends on
#              the order of the additions, so the order of the merges decides
#              the last bits: a sink merges its cells in worker order, or,
#              for an ORDER_ROW_RANGE segment, one cell per source position
#              (per group, in a grouped sink) in position order, which is the
#              same on every worker count (`sink_agg`, `group_positions`; the
#              tolerance against DuckDB is in the package README).
#   MIN, MAX   DuckDB's order of floats: NaN is above every other value,
#              +inf included (query_semantics 2.7), so MAX is NaN when a NaN
#              is present and MIN is NaN only when every value is. A value
#              replaces the one kept only when it is strictly less (MIN) or
#              greater (MAX), so -0.0 and 0.0 tie and the one met first stays.
#
# The variance family folds each value as DuckDB casts it to DOUBLE (an
# integer converted, a DECIMAL128 converted and divided by 10 to its scale, a
# FLOAT32 widened) with DuckDB's Welford update, in its order of operations
# (`welford_step`), and `merge_cell` combines two cells with its parallel
# update (`welford_merge`, Chan's), so one worker's answer is DuckDB's bits; a
# merge of several workers' cells rounds in another order, and the last bits
# can differ, as for a float SUM. A large mean and a small spread keep their
# variance, which `sum(x * x) / n - mean * mean` would cancel away.
#
# What a fold refuses, by name:
#   * a sum that leaves 128 bits (the check is on the wrapped result, as for
#     any signed add: the operands share a sign the result does not). With
#     DECIMAL128 inputs of at most 38 digits that takes billions of values near
#     the largest; the verdict can differ between groupings only when a partial
#     sum leaves 128 bits while the total does not, and a total that left them
#     is refused whatever the grouping;
#   * SUM, AVG or a variance over DATE32, MEDIAN or QUANTILE_CONT over DATE32,
#     DECIMAL128 or FLOAT32 (DuckDB's answer there keeps the input's type, not
#     the DOUBLE the plan declares), and every aggregate over a type that is not a signed
#     integer, DECIMAL128, FLOAT32, FLOAT64 or DATE32 (COUNT takes any),
#     naming the type, in the ungrouped and the grouped sinks alike;
#   * a column whose type or decimal scale differs from the one the cell saw.
#
# A grouped sink reads an argument once per morsel (`widen_column`): a signed
# integer, DECIMAL128 or DATE32 column into 128-bit values, a FLOAT32 or
# FLOAT64 column into doubles (a FLOAT32 widened exactly), and folds row by
# row into the cell of each row's group (`fold_wide`) with the steps above.

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.schema import RecordBatch
from byte_buffer.heap_region import HeapRegion
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MEDIAN,
    AGG_MIN,
    AGG_QUANTILE_CONT,
    AGG_STDDEV_POP,
    AGG_STDDEV_SAMP,
    AGG_SUM,
    AGG_VAR_POP,
    AGG_VAR_SAMP,
)
from scalar_arithmetic.decimal_arith import I128

comptime IN_NONE: UInt8 = 0
comptime IN_INT: UInt8 = 1
comptime IN_DECIMAL: UInt8 = 2
comptime IN_DATE: UInt8 = 3
comptime IN_FLOAT: UInt8 = 4


struct AggCell(Copyable, Movable):
    """The state of one aggregate on one worker."""

    var count: Int
    var value: I128
    var kind: UInt8
    var arrow: ArrowType
    var precision: Int
    var scale: Int
    # The float fold (`IN_FLOAT`): the sum, or the least or greatest value.
    # MEDIAN and QUANTILE_CONT: the answer, written when the values are
    # merged (`agg_values`).
    var fvalue: Float64
    # The variance family (`is_welford`): the mean of the values folded and
    # the sum of their squared distances from it, DuckDB's `dsquared`.
    var mean: Float64
    var m2: Float64

    def __init__(out self):
        self.count = 0
        self.value = I128(0)
        self.kind = IN_NONE
        self.arrow = ArrowType.NULL
        self.precision = 0
        self.scale = 0
        self.fvalue = 0.0
        self.mean = 0.0
        self.m2 = 0.0


def is_welford(func: UInt8) -> Bool:
    """Whether `func` is one of the variance family the sinks fold with
    Welford's update: STDDEV_SAMP, STDDEV_POP, VAR_SAMP and VAR_POP."""
    return (
        func == AGG_STDDEV_SAMP
        or func == AGG_STDDEV_POP
        or func == AGG_VAR_SAMP
        or func == AGG_VAR_POP
    )


def keeps_values(func: UInt8) -> Bool:
    """Whether `func` keeps every value of its group (`agg_values`): MEDIAN
    and QUANTILE_CONT."""
    return func == AGG_MEDIAN or func == AGG_QUANTILE_CONT


comptime SERVED_AGGREGATES = (
    "SUM, COUNT, COUNT(DISTINCT), MIN, MAX, AVG, STDDEV_SAMP, STDDEV_POP,"
    " VAR_SAMP, VAR_POP, MEDIAN and QUANTILE_CONT are"
)
"""The aggregates the sinks serve, as their refusal of another names them."""


def sink_serves(func: UInt8) -> Bool:
    """Whether the aggregation sinks fold `func`."""
    return (
        func == AGG_SUM
        or func == AGG_COUNT
        or func == AGG_COUNT_DISTINCT
        or func == AGG_MIN
        or func == AGG_MAX
        or func == AGG_MEAN
        or is_welford(func)
        or keeps_values(func)
    )


def agg_name(func: UInt8) -> String:
    """The SQL name of an aggregate tag the sink serves, else its number."""
    if func == AGG_SUM:
        return "SUM"
    if func == AGG_COUNT:
        return "COUNT"
    if func == AGG_MIN:
        return "MIN"
    if func == AGG_MAX:
        return "MAX"
    if func == AGG_MEAN:
        return "AVG"
    if func == AGG_COUNT_DISTINCT:
        return "COUNT(DISTINCT)"
    if func == AGG_STDDEV_SAMP:
        return "STDDEV_SAMP"
    if func == AGG_STDDEV_POP:
        return "STDDEV_POP"
    if func == AGG_VAR_SAMP:
        return "VAR_SAMP"
    if func == AGG_VAR_POP:
        return "VAR_POP"
    if func == AGG_MEDIAN:
        return "MEDIAN"
    if func == AGG_QUANTILE_CONT:
        return "QUANTILE_CONT"
    return "aggregate " + String(Int(func))


@always_inline
def _step(
    mut cell: AggCell, func: UInt8, v: I128, ref label: String
) raises:
    if cell.count == 0:
        cell.value = v
    elif func == AGG_MIN:
        if v < cell.value:
            cell.value = v
    elif func == AGG_MAX:
        if v > cell.value:
            cell.value = v
    else:
        var n = cell.value + v
        if ((cell.value ^ n) & (v ^ n)) < I128(0):
            raise Error(
                "pipeline_exec: " + label + " left the 128-bit range"
            )
        cell.value = n
    cell.count += 1


@always_inline
def _float_less(a: Float64, b: Float64) -> Bool:
    """`a < b` in DuckDB's order of floats: NaN is above every other value,
    and two NaNs tie."""
    if a != a:
        return False
    if b != b:
        return True
    return a < b


@always_inline
def float_step(mut value: Float64, count: Int, func: UInt8, v: Float64):
    """Fold the float `v` into `value`, the float fold of `count` values
    before it (SUM and AVG start at +0.0): the least (MIN) or greatest (MAX)
    in DuckDB's order of floats, the first kept on a tie, else the sum. The
    caller adds one to the count."""
    if func == AGG_MIN:
        if count == 0 or _float_less(v, value):
            value = v
    elif func == AGG_MAX:
        if count == 0 or _float_less(value, v):
            value = v
    else:
        # From +0.0, so a sum of -0.0 values is +0.0, as DuckDB's is.
        value += v


@always_inline
def _fstep(mut cell: AggCell, func: UInt8, v: Float64):
    float_step(cell.fvalue, cell.count, func, v)
    cell.count += 1


@always_inline
def welford_step(mut cell: AggCell, x: Float64):
    """Fold the double `x` into the variance state of `cell`, with the steps
    and the order of DuckDB's STDDEV/VAR update."""
    cell.count += 1
    var mean_differential = (x - cell.mean) / Float64(cell.count)
    var new_mean = cell.mean + mean_differential
    var dsquared_increment = (x - new_mean) * (x - cell.mean)
    cell.m2 = cell.m2 + dsquared_increment
    cell.mean = new_mean


def pow10_f64(scale: Int) -> Float64:
    """10 to the power `scale` as a double: exact up to 22."""
    var out = Float64(1)
    for _ in range(scale):
        out *= 10.0
    return out


@always_inline
def as_double(ref cell: AggCell, v: I128) -> Float64:
    """The unscaled value `v` of the column `cell` saw, as DuckDB casts it to
    DOUBLE: an integer converted, a DECIMAL128 converted and divided by 10 to
    its scale."""
    var d = v.cast[DType.float64]()
    if cell.kind == IN_DECIMAL and cell.scale > 0:
        return d / pow10_f64(cell.scale)
    return d


def _fold_float[
    dtype: DType
](mut cell: AggCell, func: UInt8, ref col: Column[HeapRegion], rows: Int) raises:
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    var welford = is_welford(func)
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            continue
        if welford:
            welford_step(cell, arr.get(r).cast[DType.float64]())
        else:
            _fstep(cell, func, arr.get(r).cast[DType.float64]())


def _fold_signed[
    dtype: DType
](
    mut cell: AggCell,
    func: UInt8,
    ref col: Column[HeapRegion],
    rows: Int,
    ref label: String,
) raises:
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    var welford = is_welford(func)
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            continue
        if welford:
            welford_step(cell, arr.get(r).cast[DType.float64]())
        else:
            _step(cell, func, arr.get(r).cast[DType.int128](), label)


def _fold_decimal(
    mut cell: AggCell,
    func: UInt8,
    ref col: Column[HeapRegion],
    rows: Int,
    ref label: String,
) raises:
    var arr = col.as_decimal128()
    var has_nulls = col.null_count() > 0
    var welford = is_welford(func)
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            continue
        if welford:
            welford_step(cell, as_double(cell, arr.get_i128(r)))
        else:
            _step(cell, func, arr.get_i128(r), label)


def _kind_of(ref col: Column[HeapRegion], logical: ArrowType) -> UInt8:
    var at = col.arrow_type
    if logical == ArrowType.DATE32 or at == ArrowType.DATE32:
        return IN_DATE
    if (
        at == ArrowType.INT8
        or at == ArrowType.INT16
        or at == ArrowType.INT32
        or at == ArrowType.INT64
    ):
        return IN_INT
    if at == ArrowType.DECIMAL128:
        return IN_DECIMAL
    if at == ArrowType.FLOAT64 or at == ArrowType.FLOAT32:
        return IN_FLOAT
    return IN_NONE


struct ColBind(Copyable, Movable):
    """What a column is to a fold: its input kind, the type a cell keeps and,
    for a DECIMAL128, its precision and scale."""

    var kind: UInt8
    var arrow: ArrowType
    var precision: Int
    var scale: Int

    def __init__(out self):
        self.kind = IN_NONE
        self.arrow = ArrowType.NULL
        self.precision = 0
        self.scale = 0


def bind_column(
    func: UInt8, ref batch: RecordBatch, col_idx: Int, ref label: String
) raises -> ColBind:
    """The `ColBind` of column `col_idx`, refusing by name a column type the
    aggregate `func` does not serve. COUNT takes any type and binds to
    `IN_NONE`."""
    var out = ColBind()
    if func == AGG_COUNT:
        return out^
    ref col = batch.column_at(col_idx)
    var logical = batch.schema.field_arrow_type(col_idx)
    var kind = _kind_of(col, logical)
    var numeric = func != AGG_MIN and func != AGG_MAX
    var values = keeps_values(func)
    if (
        kind == IN_NONE
        or (kind == IN_DATE and numeric)
        or (
            values
            and (kind == IN_DECIMAL or col.arrow_type == ArrowType.FLOAT32)
        )
    ):
        raise Error(
            "pipeline_exec: "
            + label
            + " is not served over this column type ("
            + String(col.arrow_type)
            + "): SUM, AVG, STDDEV_SAMP, STDDEV_POP, VAR_SAMP and VAR_POP"
            " take signed integers, DECIMAL128, FLOAT32 and FLOAT64; MIN and"
            " MAX also DATE32; MEDIAN and QUANTILE_CONT signed integers and"
            " FLOAT64 (over a DECIMAL128 or a FLOAT32 DuckDB's answer keeps"
            " the input's type, not the DOUBLE the plan declares)"
        )
    out.kind = kind
    if kind == IN_DECIMAL:
        out.precision = col.decimal_precision()
        out.scale = col.decimal_scale()
        if out.precision <= 0:
            out.precision = batch.schema.field_decimal_precision(col_idx)
            out.scale = batch.schema.field_decimal_scale(col_idx)
    out.arrow = ArrowType.DATE32 if kind == IN_DATE else col.arrow_type
    return out^


def adopt_bind(
    mut cell: AggCell, ref b: ColBind, ref label: String
) raises:
    """Give an empty cell the type of `b`, or refuse a cell that saw another."""
    if cell.kind == IN_NONE:
        cell.kind = b.kind
        cell.arrow = b.arrow
        cell.precision = b.precision
        cell.scale = b.scale
    elif cell.kind != b.kind or cell.arrow != b.arrow or cell.scale != b.scale:
        raise Error(
            "pipeline_exec: "
            + label
            + " saw a column of another type or scale than the morsels before"
            " it"
        )


def fold_column(
    mut cell: AggCell,
    func: UInt8,
    ref batch: RecordBatch,
    col_idx: Int,
    rows: Int,
    ref label: String,
) raises:
    """Fold `rows` rows of column `col_idx` of `batch` into `cell`. `label`
    names the aggregate in an error."""
    ref col = batch.column_at(col_idx)
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
    if func == AGG_COUNT:
        cell.count += rows - col.null_count()
        return
    var b = bind_column(func, batch, col_idx, label)
    adopt_bind(cell, b, label)
    if rows == 0:
        return
    if keeps_values(func):
        # The values themselves are kept by the sink (`agg_values`); the
        # cell counts them.
        cell.count += rows - col.null_count()
        return
    if b.kind == IN_FLOAT:
        if b.arrow == ArrowType.FLOAT64:
            _fold_float[DType.float64](cell, func, col, rows)
        else:
            _fold_float[DType.float32](cell, func, col, rows)
    elif b.kind == IN_DECIMAL:
        _fold_decimal(cell, func, col, rows, label)
    elif b.arrow == ArrowType.INT64:
        _fold_signed[DType.int64](cell, func, col, rows, label)
    elif b.arrow == ArrowType.INT8:
        _fold_signed[DType.int8](cell, func, col, rows, label)
    elif b.arrow == ArrowType.INT16:
        _fold_signed[DType.int16](cell, func, col, rows, label)
    else:
        # INT32, and DATE32 whose storage is the same 32-bit day number.
        _fold_signed[DType.int32](cell, func, col, rows, label)


struct WideColumn(Movable):
    """One aggregate argument of a morsel read once, so the rows can be folded
    into different cells by a grouped sink: into 128-bit values (`vals`), or,
    for a float column, into doubles (`fvals`). `valid` is empty when the
    column has no NULL. A COUNT argument holds no values."""

    var bind: ColBind
    var vals: List[I128]
    var fvals: List[Float64]
    var valid: List[Bool]

    def __init__(out self):
        self.bind = ColBind()
        self.vals = List[I128]()
        self.fvals = List[Float64]()
        self.valid = List[Bool]()


def _widen_signed[
    dtype: DType
](mut out: WideColumn, ref col: Column[HeapRegion], rows: Int) raises:
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    out.vals.reserve(rows)
    for r in range(rows):
        if has_nulls:
            out.valid.append(not arr.is_null(r))
        out.vals.append(arr.get(r).cast[DType.int128]())


def _widen_float[
    dtype: DType
](mut out: WideColumn, ref col: Column[HeapRegion], rows: Int) raises:
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    out.fvals.reserve(rows)
    for r in range(rows):
        if has_nulls:
            out.valid.append(not arr.is_null(r))
        out.fvals.append(arr.get(r).cast[DType.float64]())


def widen_column(
    func: UInt8,
    ref batch: RecordBatch,
    col_idx: Int,
    rows: Int,
    ref label: String,
) raises -> WideColumn:
    """Read column `col_idx` (`rows` rows) for `fold_wide`, with the refusals
    of `fold_column`."""
    var out = WideColumn()
    ref col = batch.column_at(col_idx)
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
    out.bind = bind_column(func, batch, col_idx, label)
    var has_nulls = col.null_count() > 0
    if func == AGG_COUNT:
        if has_nulls:
            for r in range(rows):
                out.valid.append(not col.is_null_at(r))
        return out^
    if out.bind.kind == IN_FLOAT:
        if out.bind.arrow == ArrowType.FLOAT64:
            _widen_float[DType.float64](out, col, rows)
        else:
            _widen_float[DType.float32](out, col, rows)
    elif out.bind.kind == IN_DECIMAL:
        var arr = col.as_decimal128()
        out.vals.reserve(rows)
        for r in range(rows):
            if has_nulls:
                out.valid.append(not arr.is_null(r))
            out.vals.append(arr.get_i128(r))
    elif out.bind.arrow == ArrowType.INT64:
        _widen_signed[DType.int64](out, col, rows)
    elif out.bind.arrow == ArrowType.INT8:
        _widen_signed[DType.int8](out, col, rows)
    elif out.bind.arrow == ArrowType.INT16:
        _widen_signed[DType.int16](out, col, rows)
    else:
        _widen_signed[DType.int32](out, col, rows)
    return out^


def fold_wide(
    mut cell: AggCell,
    func: UInt8,
    ref w: WideColumn,
    row: Int,
    ref label: String,
) raises:
    """Fold row `row` of `w` into `cell`: the same fold, row by row, that
    `fold_column` makes over a whole column."""
    if len(w.valid) > 0 and not w.valid[row]:
        # A NULL row still gives an empty cell its type, as a column does.
        if func != AGG_COUNT:
            adopt_bind(cell, w.bind, label)
        return
    if func == AGG_COUNT:
        cell.count += 1
        return
    adopt_bind(cell, w.bind, label)
    if keeps_values(func):
        cell.count += 1
        return
    if is_welford(func):
        if w.bind.kind == IN_FLOAT:
            welford_step(cell, w.fvals[row])
        else:
            welford_step(cell, as_double(cell, w.vals[row]))
        return
    if w.bind.kind == IN_FLOAT:
        _fstep(cell, func, w.fvals[row])
        return
    _step(cell, func, w.vals[row], label)


def merge_cell(
    mut into: AggCell, ref other: AggCell, func: UInt8, ref label: String
) raises:
    """Fold the state `other` into `into`, as if `into` had seen the rows of
    both."""
    if other.kind != IN_NONE:
        if into.kind == IN_NONE:
            into.kind = other.kind
            into.arrow = other.arrow
            into.precision = other.precision
            into.scale = other.scale
        elif (
            into.kind != other.kind
            or into.arrow != other.arrow
            or into.scale != other.scale
        ):
            raise Error(
                "pipeline_exec: "
                + label
                + " saw columns of different types on different workers"
            )
    if other.count == 0:
        return
    if is_welford(func):
        welford_merge(into, other)
        return
    if keeps_values(func):
        # The values are merged by the sink (`agg_values`).
        into.count += other.count
        return
    if into.kind == IN_FLOAT:
        if func == AGG_MIN:
            if into.count == 0 or _float_less(other.fvalue, into.fvalue):
                into.fvalue = other.fvalue
        elif func == AGG_MAX:
            if into.count == 0 or _float_less(into.fvalue, other.fvalue):
                into.fvalue = other.fvalue
        else:
            # SUM and AVG: `into` holds +0.0 while it is empty.
            into.fvalue += other.fvalue
        into.count += other.count
        return
    if into.count == 0:
        into.value = other.value
    elif func == AGG_MIN:
        if other.value < into.value:
            into.value = other.value
    elif func == AGG_MAX:
        if other.value > into.value:
            into.value = other.value
    elif func == AGG_SUM or func == AGG_MEAN:
        var n = into.value + other.value
        if ((into.value ^ n) & (other.value ^ n)) < I128(0):
            raise Error(
                "pipeline_exec: " + label + " left the 128-bit range"
            )
        into.value = n
    into.count += other.count


def welford_merge(mut into: AggCell, ref other: AggCell):
    """Fold the variance state `other` into `into` with the steps and the
    order of DuckDB's STDDEV/VAR combine (Chan's parallel update)."""
    if other.count == 0:
        return
    if into.count == 0:
        into.count = other.count
        into.mean = other.mean
        into.m2 = other.m2
        return
    var count = Float64(into.count + other.count)
    var source_count = Float64(other.count)
    var target_count = Float64(into.count)
    var mean = (
        source_count * other.mean + target_count * into.mean
    ) / count
    var delta = other.mean - into.mean
    into.m2 = (
        other.m2 + into.m2 + delta * delta * source_count * target_count / count
    )
    into.mean = mean
    into.count += other.count
