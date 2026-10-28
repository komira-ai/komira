# =============================================================================
# partition_value_fns -- LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE
# =============================================================================
#
# A value function answers with a cell of another row of the partition. Each
# is computed in two steps: first the SOURCE ROW of every output row (or none),
# then one typed copy of the value column at those rows.
#
#   * LAG(x, n) / LEAD(x, n): the row `n` before / after, inside the
#     partition. They ignore the frame (SQL). Past the partition edge there is
#     no source row: the answer is the DEFAULT if the plan gives a non-NULL one
#     (`value_fn_has_default`), else NULL (§9.4). A negative `n` looks the
#     other way.
#   * FIRST_VALUE(x) / LAST_VALUE(x): the first / last row of the row's FRAME
#     (`partition_frame_index`), NULL over an empty frame. Under the default
#     frame of an ordered window, `RANGE BETWEEN UNBOUNDED PRECEDING AND
#     CURRENT ROW`, LAST_VALUE is the value of the current row's LAST PEER.
#   * NTH_VALUE(x, n): the n-th row of the frame, counting from 1 and counting
#     NULL rows; NULL when the frame has fewer than n rows.
#
# All five RESPECT NULLS (§9.10): a source row whose value is NULL answers
# NULL. Value columns: INT64, FLOAT64, STRING; another type raises.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_counters.strdrain_counter import (
    SD_SITE_PARTITION_EVAL,
    strdrain_note_site,
)
from komira_plan_expr.partition_expr import (
    PF_FIRST_VALUE,
    PF_LAG,
    PF_LAST_VALUE,
    PF_LEAD,
    PF_NTH_VALUE,
    PartitionExpr,
    value_fn_has_default,
)

from .partition_frame_index import frame_index
from .partition_keys import _segment_ends


# The source-row sentinel: no source row (the default, or NULL, answers).
comptime _NO_ROW: Int = -1


def _offset_sources(
    bounds: List[Int], n: Int, shift: Int
) -> List[Int]:
    """Per row, the row `shift` rows later inside its partition, or `_NO_ROW`.
    LAG is a negative shift, LEAD a positive one."""
    var ends = _segment_ends(bounds, n)
    var src = List[Int](capacity=n)
    for _ in range(n):
        src.append(_NO_ROW)
    for p in range(len(bounds)):
        var s = bounds[p]
        var e = ends[p]
        for row in range(s, e):
            var r = row + shift
            if r >= s and r < e:
                src[row] = r
    return src^


def _value_sources(
    batch: RecordBatch,
    bounds: List[Int],
    order_keys: List[String],
    descending: List[Bool],
    expr: PartitionExpr,
) raises -> List[Int]:
    """Per row, the row whose value `expr` answers with, or `_NO_ROW`."""
    var n = batch.num_rows()
    if expr.func == PF_LAG:
        return _offset_sources(bounds, n, -expr.offset)
    elif expr.func == PF_LEAD:
        return _offset_sources(bounds, n, expr.offset)
    var fi = frame_index(batch, bounds, order_keys, descending, expr.frame)
    var src = List[Int](capacity=n)
    for row in range(n):
        var lo = fi.lo[row]
        var hi = fi.hi[row]
        var pick = _NO_ROW
        if hi > lo:
            if expr.func == PF_FIRST_VALUE:
                pick = lo
            elif expr.func == PF_LAST_VALUE:
                pick = hi - 1
            elif expr.func == PF_NTH_VALUE:
                if expr.offset >= 1 and lo + expr.offset - 1 < hi:
                    pick = lo + expr.offset - 1
            else:
                raise Error(
                    "partition_value_fns: not a value function "
                    + String(Int(expr.func))
                )
        src.append(pick)
    return src^


def _gather_numeric[
    dt: DType
](
    col: Column[HeapRegion],
    src: List[Int],
    has_default: Bool,
    default_value: Scalar[dt],
) raises -> Column[HeapRegion]:
    """Copy `col` at the rows of `src`; `_NO_ROW` takes the default or NULL."""
    var n = len(src)
    var in_nulls = col.has_validity_buffer()
    var need_nulls = in_nulls
    if not has_default:
        for i in range(n):
            if src[i] == _NO_ROW:
                need_nulls = True
                break
    var arr: PrimitiveArray[dt]
    if need_nulls:
        arr = PrimitiveArray[dt].allocate_nullable(n)
    else:
        arr = PrimitiveArray[dt].allocate(n)
    for i in range(n):
        var r = src[i]
        if r == _NO_ROW:
            if has_default:
                arr.store[1](i, default_value)
            else:
                arr.store[1](i, Scalar[dt](0))
                arr._set_null(i)
        elif in_nulls and col.is_null_at(r):
            arr.store[1](i, Scalar[dt](0))
            arr._set_null(i)
        else:
            arr.store[1](i, col._data.get_typed[Scalar[dt]](col._offset + r))
    return Column.from_primitive[dt](arr)


def _gather_string(
    col: Column[HeapRegion],
    src: List[Int],
    has_default: Bool,
    default_value: String,
) raises -> Column[HeapRegion]:
    """STRING sibling of `_gather_numeric`."""
    var n = len(src)
    var sa = col.as_string()
    var values = List[String](capacity=n)
    var valid = List[Bool](capacity=n)
    for i in range(n):
        var r = src[i]
        if r == _NO_ROW:
            if has_default:
                values.append(default_value)
                valid.append(True)
            else:
                values.append(String(""))
                valid.append(False)
        elif sa.is_null(r):
            values.append(String(""))
            valid.append(False)
        else:
            values.append(sa.get(r))
            valid.append(True)
    strdrain_note_site(SD_SITE_PARTITION_EVAL, n)
    return Column.from_string(StringArray.from_strings_with_validity(values, valid))


def eval_value_fn(
    batch: RecordBatch,
    bounds: List[Int],
    order_keys: List[String],
    descending: List[Bool],
    expr: PartitionExpr,
) raises -> Column[HeapRegion]:
    """Evaluate one value function (LAG / LEAD / FIRST_VALUE / LAST_VALUE /
    NTH_VALUE) over `batch`, sorted by (partition keys ++ order keys), whose
    partitions start at `bounds`."""
    ref col = batch.column_at(batch.schema.column_index(expr.column))
    var src = _value_sources(batch, bounds, order_keys, descending, expr)
    var has_default = value_fn_has_default(expr)
    if col.arrow_type == ArrowType.INT64:
        var dv = Int64(0)
        if has_default:
            if expr.default_value.dtype.is_floating_point():
                dv = Int64(expr.default_value.float_val)
            else:
                dv = expr.default_value.int_val
        return _gather_numeric[DType.int64](col, src, has_default, dv)
    elif col.arrow_type == ArrowType.FLOAT64:
        var dvf = Float64(0.0)
        if has_default:
            if expr.default_value.dtype.is_floating_point():
                dvf = expr.default_value.float_val
            else:
                dvf = Float64(expr.default_value.int_val)
        return _gather_numeric[DType.float64](col, src, has_default, dvf)
    elif col.arrow_type == ArrowType.STRING:
        var dvs = String("")
        if has_default:
            dvs = expr.default_value.string_val.copy()
        return _gather_string(col, src, has_default, dvs)
    raise Error(
        "partition_value_fns: unsupported value column type "
        + String(col.arrow_type)
        + " (INT64, FLOAT64 and STRING are served)"
    )
