# =============================================================================
# cd_parallel_emit -- the output columns of the grouped COUNT(DISTINCT)
# driver: integer group keys, NULL group keys, and the fixed aggregates
# =============================================================================
#
# Output semantics are DuckDB's:
#   * a NULL group key reads back as NULL (a validity bit), never as the 0 /
#     '' its stored value is;
#   * COUNT(*) and COUNT(col) are never NULL (0 is an answer);
#   * SUM / MIN / MAX / AVG of a group with no non-NULL input are NULL;
#   * integer SUM / AVG / MIN / MAX come from an exact 128-bit accumulator,
#     and float MIN / MAX were folded in DuckDB's order (NaN above +inf);
#   * an integer SUM whose exact total is outside the output column's range
#     is refused with `komira_op_agg_state`'s `int_sum_overflow_message`
#     (DuckDB widens to HUGEINT; this engine's SUM column is INT64), never
#     wrapped; AVG divides the exact total, so it still answers;
#   * each column has the type its output field declares; a field type the
#     input cannot produce is refused, not cast.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import AGG_COUNT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM
from komira_scalar_arithmetic.decimal_avg import avg_integer_float64

from komira_op_agg_state.int_sum_overflow import (
    i128_total_fits_i64,
    int_sum_overflow_message,
)


@fieldwise_init
struct CDFixedCell(Copyable, Movable, ImplicitlyCopyable):
    """One (group, fixed aggregate) accumulator of the grouped driver.

    `i_acc` is the integer lane in 128 bits: the exact SUM of up to 2^64 INT64
    rows cannot leave it, so a total that fits INT64 is answered whatever the
    row order (a 64-bit cell with a per-step check would refuse MAX, 1, -1),
    and a total that does not is refused at emit rather than wrapped. MIN / MAX
    hold an INT64 value in it. `f_acc` is the FLOAT64 lane. `n` counts the
    contributing rows; `n == 0` makes SUM / MIN / MAX / AVG NULL and `n == 1`
    seeds MIN / MAX."""

    var i_acc: Scalar[DType.int128]
    var f_acc: Float64
    var n: Int64


@always_inline
def cd_fixed_cell_identity() -> CDFixedCell:
    return CDFixedCell(Scalar[DType.int128](0), Float64(0.0), Int64(0))


def cd_stamp_nulls(mut col: Column[HeapRegion], nulls: List[Bool]) raises:
    """Give a freshly built, unsliced column a validity bitmap with row `i`
    NULL where `nulls[i]`. No-op when no row is NULL."""
    var n = len(nulls)
    if n != col._length:
        raise Error(
            "cd_stamp_nulls: " + String(n) + " flags for "
            + String(col._length) + " rows"
        )
    var count = 0
    for i in range(n):
        if nulls[i]:
            count += 1
    if count == 0:
        return
    var bm = Bitmap.create_all_valid(n)
    for i in range(n):
        if nulls[i]:
            bm.clear(i)
    col._validity = bm^
    col._null_count = count


def cd_int_key_column(
    keys: List[Int], rows: List[Int], bounded: Bool, n: Int, as_i32: Bool
) raises -> Column[HeapRegion]:
    """An INT32 or INT64 group-key column: `keys[g]` for g in `0 .. n`, or for
    g in `rows` when `bounded`."""
    var n_emit = len(rows) if bounded else n
    if as_i32:
        var a32 = PrimitiveArray[DType.int32].allocate(n_emit)
        for i in range(n_emit):
            a32.set(i, Int32(keys[rows[i] if bounded else i]))
        return Column.from_primitive[DType.int32](a32^)
    var a64 = PrimitiveArray[DType.int64].allocate(n_emit)
    for i in range(n_emit):
        a64.set(i, Int64(keys[rows[i] if bounded else i]))
    return Column.from_primitive[DType.int64](a64^)


def cd_fixed_column(
    cells: List[CDFixedCell],
    func: UInt8,
    out_at: ArrowType,
    int_lane: Bool,
    what: String,
    mut any_null: Bool,
) raises -> Column[HeapRegion]:
    """The output column of one fixed aggregate over every group's cell.

    Args:
        cells: One cell per output group, in output order.
        func: AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX or AGG_MEAN.
        out_at: The output field's type.
        int_lane: True when the input was INT32 / INT64 (the cell's `i_acc`
            holds the answer), False for FLOAT64 (`f_acc`).
        what: The aggregand, as an integer SUM past the output range names it
            in `int_sum_overflow_message`.
        any_null: Set to True when a row of the column is NULL, so the caller
            can mark the output field nullable.
    """
    var n = len(cells)
    any_null = False
    if func == AGG_COUNT:
        var c = PrimitiveArray[DType.int64].allocate(n)
        for g in range(n):
            c.set(g, cells[g].n)
        return Column.from_primitive[DType.int64](c^)
    if func != AGG_SUM and func != AGG_MIN and func != AGG_MAX and func != AGG_MEAN:
        raise Error(
            "grouped COUNT(DISTINCT) driver: unsupported aggregate function "
            + String(Int(func))
        )
    for g in range(n):
        if cells[g].n == 0:
            any_null = True
            break
    var int_out = out_at == ArrowType.INT64 or out_at == ArrowType.INT32
    if func == AGG_MEAN or not int_out:
        if out_at != ArrowType.FLOAT64:
            raise Error(
                "grouped COUNT(DISTINCT) driver: aggregate " + String(Int(func))
                + " cannot produce output type " + String(out_at.type_id)
            )
        var fa = PrimitiveArray[DType.float64].allocate_nullable(n)
        for g in range(n):
            ref c = cells[g]
            if c.n == 0:
                fa._set_null(g)
                continue
            # AVG divides the exact total: no INT64 narrowing on this path.
            var v: Float64
            if func == AGG_MEAN and int_lane:
                # An INT32 / INT64 input: DuckDB's long double average.
                v = avg_integer_float64(c.i_acc, Int(c.n), 64)
            else:
                v = c.i_acc.cast[DType.float64]() if int_lane else c.f_acc
                if func == AGG_MEAN:
                    v = v / Float64(c.n)
            fa.set(g, v)
        return Column.from_primitive[DType.float64](fa^)
    if not int_lane:
        raise Error(
            "grouped COUNT(DISTINCT) driver: a FLOAT64 input cannot produce"
            " integer output type " + String(out_at.type_id)
        )
    if out_at == ArrowType.INT32:
        var ia = PrimitiveArray[DType.int32].allocate_nullable(n)
        for g in range(n):
            if cells[g].n == 0:
                ia._set_null(g)
            else:
                var t = cells[g].i_acc
                if t > Int32.MAX.cast[DType.int128]() or t < Int32.MIN.cast[
                    DType.int128
                ]():
                    raise Error(
                        "grouped COUNT(DISTINCT) driver: the total of aggregate "
                        + String(Int(func)) + " over " + what
                        + " does not fit its INT32 output column"
                    )
                ia.set(g, t.cast[DType.int32]())
        return Column.from_primitive[DType.int32](ia^)
    var la = PrimitiveArray[DType.int64].allocate_nullable(n)
    for g in range(n):
        if cells[g].n == 0:
            la._set_null(g)
        else:
            var t = cells[g].i_acc
            if not i128_total_fits_i64(t):
                # Only a SUM can get here: MIN / MAX hold an input value.
                raise Error(int_sum_overflow_message(what))
            la.set(g, t.cast[DType.int64]())
    return Column.from_primitive[DType.int64](la^)
