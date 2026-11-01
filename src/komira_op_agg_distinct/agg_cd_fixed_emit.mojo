# =============================================================================
# agg_cd_fixed_emit — the output columns of the COUNT(DISTINCT) sink's
# fixed aggregates (SUM, COUNT, MIN, MAX, MEAN)
# =============================================================================
#
# A fixed aggregate's merged per-group cells become one column at the type the
# plan declares for it, and an empty result carries every declared column at
# its declared type. A group no row contributed to reads back as NULL.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_plan_expr.agg_expr import AGG_MEAN
from komira_op_agg_distinct.streaming_agg_count_distinct import FixedAggCell




def _fixed_int_column[
    dt: DType
](
    ref cells: List[FixedAggCell], num_groups: Int, anynull: Bool
) raises -> Column[]:
    """An integer column over the merged cells of one fixed aggregate: the
    integer accumulator, NULL for a group no row contributed to."""
    var arr: PrimitiveArray[dt]
    if anynull:
        arr = PrimitiveArray[dt].allocate_nullable(num_groups)
    else:
        arr = PrimitiveArray[dt].allocate(num_groups)
    var nulls = 0
    for g in range(num_groups):
        ref cell = cells[g]
        if cell.n == Int64(0):
            arr._typed_ptr_mut()[g] = Scalar[dt](0)
            arr.validity.value().clear(g)
            nulls += 1
        else:
            arr._typed_ptr_mut()[g] = cell.i_acc.cast[dt]()
    if anynull:
        arr.null_count = nulls
    return Column.from_primitive[dt](arr^)


def _fixed_float_column[
    dt: DType
](
    ref cells: List[FixedAggCell],
    num_groups: Int,
    anynull: Bool,
    func: UInt8,
    int_lane: Bool,
) raises -> Column[]:
    """A floating-point column over the merged cells of one fixed aggregate.
    MEAN divides the lane's sum by the row count (an integer lane divides the
    exact integer sum once); every other aggregate emits the lane's value.
    NULL for a group no row contributed to."""
    var arr: PrimitiveArray[dt]
    if anynull:
        arr = PrimitiveArray[dt].allocate_nullable(num_groups)
    else:
        arr = PrimitiveArray[dt].allocate(num_groups)
    var nulls = 0
    for g in range(num_groups):
        ref cell = cells[g]
        if cell.n == Int64(0):
            arr._typed_ptr_mut()[g] = Scalar[dt](0)
            arr.validity.value().clear(g)
            nulls += 1
            continue
        var v = Float64(cell.i_acc) if int_lane else cell.f_acc
        if func == AGG_MEAN:
            v = v / Float64(cell.n)
        arr._typed_ptr_mut()[g] = v.cast[dt]()
    if anynull:
        arr.null_count = nulls
    return Column.from_primitive[dt](arr^)


def _empty_column(at: ArrowType) raises -> Column[]:
    """A zero-row column of the declared type (INT32, FLOAT32 and FLOAT64
    as declared; INT64 otherwise)."""
    if at == ArrowType.INT32:
        return Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].allocate(0)
        )
    if at == ArrowType.FLOAT64:
        return Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].allocate(0)
        )
    if at == ArrowType.FLOAT32:
        return Column.from_primitive[DType.float32](
            PrimitiveArray[DType.float32].allocate(0)
        )
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].allocate(0)
    )
