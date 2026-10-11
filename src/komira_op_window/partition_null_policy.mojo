# =============================================================================
# partition_null_policy -- the NULL policy of a window aggregate
# =============================================================================
#
# One definition, read by the three window aggregate kernel families:
# `partition_scan_kernels._eval_running_*` (the running frame),
# `partition_sliding_frame.eval_sliding_*` (bounded frames) and
# `partition_sliding_frame.eval_full_partition_agg` (the whole partition).
# They share no other code, so the policy lives here.
#
# The policy is SQL's (and DuckDB's):
#
#   1. Every aggregate except `COUNT(*)` skips NULL inputs. A NULL cell
#      contributes nothing: not a zero, not an identity.
#   2. An aggregate over zero surviving values is NULL, except COUNT, which
#      is 0. `AggI64` / `AggF64` carry the surviving `count` so the caller can
#      tell "no input" from a value.
#   3. `COUNT(<col>)` counts non-NULL values; `COUNT(*)` counts rows. Both
#      arrive as `PF_COUNT`; `COUNT(*)` has an empty argument column
#      (`count_is_star`).
#   4. The output is nullable iff the input carries NULLs OR the frame can be
#      empty. A bounded frame that excludes the current row (`2 PRECEDING ..
#      1 PRECEDING`) selects no rows at a partition edge even over a column
#      with no NULLs, and writing a NULL into an output allocated without a
#      validity bitmap aborts the process. So a framed kernel allocates
#      through `alloc_frame_out_*`, which takes the resolved frame; the
#      running and whole-partition kernels, whose frame always holds the
#      current row, allocate through `alloc_out_*`. COUNT never takes the NULL
#      arm (an empty frame counts 0), so its output stays non-nullable.
#
# The NULL test is hoisted: `Column.has_validity_buffer()` is loop-invariant,
# and every caller binds it once and guards with `if nulls and is_null(...)`,
# so a column without a bitmap pays one predictable branch per row.
# =============================================================================

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion


@always_inline
def cell_is_null(col: Column[HeapRegion], row: Int) -> Bool:
    """True iff `col[row]` is SQL NULL.

    A sliced column shares its parent's validity bitmap and carries a
    non-zero `_offset`, so the bit of logical row `r` is at `_offset + r`.
    """
    if col._validity:
        # Validity: 1 = valid, 0 = null.
        return not col._validity.value().test(col._offset + row)
    return False


@always_inline
def count_is_star(col_name: String) -> Bool:
    """True iff this `PF_COUNT` is `COUNT(*)` rather than `COUNT(<col>)`.

    The plan gives both the same `PF_COUNT` tag; the empty argument column
    is the only thing that tells them apart.
    """
    return col_name.byte_length() == 0


@fieldwise_init
struct AggI64(Copyable, Movable):
    """An INT64 aggregate result and the number of non-NULL values it saw.

    `count == 0` means the SQL answer is NULL; for `PF_COUNT` over a named
    column `count` is the answer.
    """

    var value: Int64
    var count: Int


@fieldwise_init
struct AggF64(Copyable, Movable):
    """A FLOAT64 aggregate result and its non-NULL count. See `AggI64`."""

    var value: Float64
    var count: Int


def alloc_out_i64(n: Int, nullable: Bool) raises -> PrimitiveArray[DType.int64]:
    """Allocate a window output column, with a validity bitmap only if needed.

    For the running frame and the whole partition only: their frame always
    holds the current row, so `nullable` is the input column's nullability.
    A framed kernel calls `alloc_frame_out_i64` instead.
    """
    if nullable:
        return PrimitiveArray[DType.int64].allocate_nullable(n)
    return PrimitiveArray[DType.int64].allocate(n)


def alloc_out_f64(n: Int, nullable: Bool) raises -> PrimitiveArray[DType.float64]:
    """FLOAT64 sibling of `alloc_out_i64`. Same contract."""
    if nullable:
        return PrimitiveArray[DType.float64].allocate_nullable(n)
    return PrimitiveArray[DType.float64].allocate(n)


def frame_can_be_empty(lo_idx: List[Int], hi_idx: List[Int]) -> Bool:
    """True iff any row's frame `[lo, hi)` selects no rows.

    Read off the resolved indices rather than derived from the frame spec:
    under RANGE any offset pair can select nothing (a row may have no peer
    inside the key window), and the indices are already computed. `hi <= lo`
    is empty, as every reducer reads `[lo, hi)` as a range.
    """
    for r in range(len(lo_idx)):
        if hi_idx[r] <= lo_idx[r]:
            return True
    return False


def alloc_frame_out_i64(
    n: Int, input_nullable: Bool, lo_idx: List[Int], hi_idx: List[Int]
) raises -> PrimitiveArray[DType.int64]:
    """Allocate a framed window output: nullable iff the input carries NULLs
    or some row's frame is empty (policy point 4).

    Guarding the NULL store instead would write a wrong value (whatever the
    accumulator held) where SQL answers NULL. Over a non-nullable input and a
    frame that always holds a row (`1 PRECEDING .. CURRENT ROW`) no bitmap is
    allocated.
    """
    var out_nullable = input_nullable
    if not out_nullable:
        out_nullable = frame_can_be_empty(lo_idx, hi_idx)
    return alloc_out_i64(n, out_nullable)


def alloc_frame_out_f64(
    n: Int, input_nullable: Bool, lo_idx: List[Int], hi_idx: List[Int]
) raises -> PrimitiveArray[DType.float64]:
    """FLOAT64 sibling of `alloc_frame_out_i64`. Same two-term predicate."""
    var out_nullable = input_nullable
    if not out_nullable:
        out_nullable = frame_can_be_empty(lo_idx, hi_idx)
    return alloc_out_f64(n, out_nullable)


@always_inline
def store_i64_or_null(
    mut arr: PrimitiveArray[DType.int64], row: Int, value: Int64, count: Int
) raises:
    """Write `value` at `row`, or a NULL there when `count == 0`.

    The NULL arm needs an output allocated with a bitmap (`alloc_frame_out_*`
    for a framed kernel): `_set_null` on an array without one aborts.
    """
    if count == 0:
        arr._set_null(row)
    else:
        arr.store[1](row, value)


@always_inline
def store_f64_or_null(
    mut arr: PrimitiveArray[DType.float64], row: Int, value: Float64, count: Int
) raises:
    """FLOAT64 sibling of `store_i64_or_null`. Same contract."""
    if count == 0:
        arr._set_null(row)
    else:
        arr.store[1](row, value)
