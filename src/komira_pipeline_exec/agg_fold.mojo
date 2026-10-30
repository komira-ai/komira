# =============================================================================
# agg_fold -- the exact fold of one ungrouped aggregate
# =============================================================================
#
# An `AggCell` is the whole state of one aggregate on one worker: the count of
# the rows it folded, one 128-bit integer, and the type of the column it saw.
#
#   COUNT(x)       count of the non-NULL rows of x (COUNT(*) is counted by the
#                  sink from the morsel, not here)
#   SUM(x)         the 128-bit sum of the unscaled values of x
#   AVG(x)         the same sum and the count; the division is at the end
#   MIN(x), MAX(x) the least or greatest unscaled value of x
#
# The unscaled value of an integer column is the integer, of a DECIMAL128
# column its 128-bit integer (the column's scale is kept beside it), and of a
# DATE32 column its day number. The sum is an integer fold with no float in it,
# so any grouping of the rows into workers gives the same cell: the merge adds
# the sums and the counts, or takes the lesser or greater value.
#
# What a fold refuses, by name:
#   * a sum that leaves 128 bits (the check is on the wrapped result, as for
#     any signed add: the operands share a sign the result does not). With
#     DECIMAL128 inputs of at most 38 digits that takes billions of values near
#     the largest; the verdict can differ between groupings only when a partial
#     sum leaves 128 bits while the total does not, and a total that left them
#     is refused whatever the grouping;
#   * SUM or AVG over DATE32, and every aggregate over a type that is not a
#     signed integer, DECIMAL128 or DATE32 (COUNT takes any): floats wait for
#     the float machinery of the design, which fixes the order of a float fold;
#   * a column whose type or decimal scale differs from the one the cell saw.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
)
from komira_scalar_arithmetic.decimal_arith import I128

comptime IN_NONE: UInt8 = 0
comptime IN_INT: UInt8 = 1
comptime IN_DECIMAL: UInt8 = 2
comptime IN_DATE: UInt8 = 3


struct AggCell(Copyable, Movable):
    """The state of one aggregate on one worker."""

    var count: Int
    var value: I128
    var kind: UInt8
    var arrow: ArrowType
    var precision: Int
    var scale: Int

    def __init__(out self):
        self.count = 0
        self.value = I128(0)
        self.kind = IN_NONE
        self.arrow = ArrowType.NULL
        self.precision = 0
        self.scale = 0


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
                "komira_pipeline_exec: " + label + " left the 128-bit range"
            )
        cell.value = n
    cell.count += 1


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
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            continue
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
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            continue
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
    var sums = func == AGG_SUM or func == AGG_MEAN
    if kind == IN_NONE or (kind == IN_DATE and sums):
        raise Error(
            "komira_pipeline_exec: "
            + label
            + " is not served over this column type ("
            + String(col.arrow_type)
            + "): SUM and AVG take signed integers and DECIMAL128, MIN and"
            " MAX also DATE32"
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
            "komira_pipeline_exec: "
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
            "komira_pipeline_exec: "
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
    if b.kind == IN_DECIMAL:
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
    """One aggregate argument of a morsel read once into 128-bit values, so
    the rows can be folded into different cells by a grouped sink. `valid` is
    empty when the column has no NULL. A COUNT argument holds no values."""

    var bind: ColBind
    var vals: List[I128]
    var valid: List[Bool]

    def __init__(out self):
        self.bind = ColBind()
        self.vals = List[I128]()
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
            "komira_pipeline_exec: "
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
    if out.bind.kind == IN_DECIMAL:
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
                "komira_pipeline_exec: "
                + label
                + " saw columns of different types on different workers"
            )
    if other.count == 0:
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
                "komira_pipeline_exec: " + label + " left the 128-bit range"
            )
        into.value = n
    into.count += other.count
