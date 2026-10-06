# =============================================================================
# agg_pick_output_conform -- a PICKING aggregate (min / max / first / last /
#                            any_value) answers in its INPUT COLUMN's type.
# =============================================================================
#
# ★ THE DEFECT (`XS-TYPE-WIDENED`,
#   `XS-TYPE-TIMEZONE-DROPPED`). The untyped aggregate routes fold every
#   integer MIN / MAX into a signed 8-byte cell and every float one into an
#   8-byte FLOAT64 cell, and their drains publish the CELL's type:
#
#     `SELECT g, min(v) FROM t GROUP BY g`   v int8     -> int64
#                                            v float32  -> double
#     `SELECT max(v) FROM t`                 v uint8    -> int64
#     `SELECT min(t) FROM t`                 t timestamp[us, tz=UTC]
#                                                       -> timestamp[us]
#
#   The plan layer declares the right answer and always has
#   (`logical_plan._infer_agg_field` -> `_pick_out_field`: "infer type from the
#   child expression (NO promotion)"), and every reference agrees -- MEASURED
#   2026-09-25: DuckDB 1.5.3 `typeof(min(x))`, polars 1.44.2 and
#   pandas 3.0.6 all keep int8 / int16 / int32 / uint8 / uint16 / uint32 /
#   float32, grouped and 0-key, and keep the zone of a TIMESTAMPTZ.
#
# ⭐ WHY ONE CONFORM AT THE NODE'S EXIT AND NOT A NARROWING IN EACH DRAIN.
#   The cell's type is re-decided by every route that can serve the node --
#   the flat + radix serial drains, the multi-writer parallel drain (which
#   builds every column at the drain schema's type over an 8-byte buffer, so a
#   narrow LABEL there would be a wrong stride, not a wrong name), the perfect-
#   hash drain, the extended fold, the 0-key streaming sink and the resident
#   0-key fold. A narrowing in each is N places to drift; this is the ONE place
#   every one of them passes through (`execute_agg_plan` and its decline-
#   returning twin), and it asks the plan, which already states the rule.
#   The kernels keep their wide cells: a pick's cell never needs more than its
#   input's width, but the combine/merge machinery is shared with SUM and is
#   not where the answer's type belongs.
#
# ⛔ A CLOSED SET, NOT "WHATEVER THE PLAN SAYS". A column is touched ONLY when
#   ALL of these hold, and is otherwise left exactly as the route produced it:
#     1. it is an aggregate column (never a key) whose function is a PICK
#        (`AGG_MIN` / `AGG_MAX` / `agg_picks_by_arrival_order`);
#     2. its input is a PLAIN COLUMN REFERENCE (alias-stripped). A computed
#        input's width is the expression evaluator's decision, and a value it
#        produced need not fit the width the plan infers for the expression;
#     3. (drained, declared) is one of:
#          INT64   -> INT8 / INT16 / INT32 / UINT8 / UINT16 / UINT32  (narrow)
#          FLOAT64 -> FLOAT32                                          (narrow)
#          TIMESTAMP_u (no zone) -> TIMESTAMP_u with the input's zone  (retag)
#   Every narrowing is CHECKED per value. A pick returns an element of its
#   input, so a value outside the input's type is not an answer to narrow --
#   it is a route that handed back something that was never in the column,
#   and it RAISES naming the column rather than wrapping.
#
#   A batch whose column count is not `keys + aggregates` is returned
#   UNCHANGED: positions are the only link between the plan's fields and the
#   drained columns, and a shape this function does not describe is not one it
#   may re-type.
#
# Encapsulation: no UnsafePointer, no wildcard origin.
# =============================================================================

from std.collections import List, Optional

from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_plan_expr.agg_expr import (
    AGG_MAX,
    AGG_MIN,
    agg_picks_by_arrival_order,
)
from komira_plan_expr.expr import Expr, EXPR_ALIAS, EXPR_COL_REF
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_AGGREGATE


# ---- what one output column's conform step is -------------------------------
comptime PICK_CONFORM_KEEP = 0
"""The route's column is the answer (or the column is outside the set)."""
comptime PICK_CONFORM_NARROW_INT = 1
"""An INT64 pick over a narrower integer column: checked cast to its width."""
comptime PICK_CONFORM_NARROW_F32 = 2
"""A FLOAT64 pick over a FLOAT32 column: cast (exact for every f32 value)."""
comptime PICK_CONFORM_RETAG_TZ = 3
"""A timestamp pick that lost its input's zone: re-stamp it, move no byte."""


def _is_pick(func: UInt8) -> Bool:
    return func == AGG_MIN or func == AGG_MAX or agg_picks_by_arrival_order(func)


def _is_plain_col_ref(e: Expr) -> Bool:
    if e.tag == EXPR_ALIAS:
        return _is_plain_col_ref(e.alias_child_ref())
    return e.tag == EXPR_COL_REF


def _is_narrow_int(t: ArrowType) -> Bool:
    return (
        t == ArrowType.INT8
        or t == ArrowType.INT16
        or t == ArrowType.INT32
        or t == ArrowType.UINT8
        or t == ArrowType.UINT16
        or t == ArrowType.UINT32
    )


def pick_conform_step(imm drained: Field, imm declared: Field) -> Int:
    """The conform step for ONE pick column, from the (drained, declared)
    Field pair. KEEP for everything outside the closed set in the header."""
    var d = drained.arrow_type
    var w = declared.arrow_type
    if d == ArrowType.INT64 and _is_narrow_int(w):
        return PICK_CONFORM_NARROW_INT
    if d == ArrowType.FLOAT64 and w == ArrowType.FLOAT32:
        return PICK_CONFORM_NARROW_F32
    if (
        d.is_timestamp()
        and d == w
        and drained.timezone().byte_length() == 0
        and declared.timezone().byte_length() > 0
    ):
        return PICK_CONFORM_RETAG_TZ
    return PICK_CONFORM_KEEP


struct AggPickConform(Movable):
    """What `conform_agg_picks` needs from the plan, captured BEFORE the plan
    is moved into the route: the output arity, and for each output column the
    declared Field if it is a pick over a plain column (else None)."""

    var n_cols: Int
    var declared: List[Optional[Field]]

    def __init__(out self):
        self.n_cols = -1
        self.declared = List[Optional[Field]]()

    @staticmethod
    def of(imm plan: LogicalPlan) -> AggPickConform:
        """Read the aggregate node's picks. A non-aggregate plan (or one with
        no pick) yields a conform that changes nothing."""
        var out = AggPickConform()
        if plan.tag != PLAN_AGGREGATE or not plan._aggregate:
            return out^
        ref ad = plan._aggregate.value()[]
        var n_keys = len(ad.group_by)
        var n_aggs = len(ad.agg_exprs)
        if plan.output_schema.num_columns() != n_keys + n_aggs:
            # A UDF aggregate appends its own columns; not this function's.
            return out^
        out.n_cols = n_keys + n_aggs
        for _ in range(n_keys):
            out.declared.append(Optional[Field](None))
        var any_pick = False
        for a in range(n_aggs):
            ref ae = ad.agg_exprs[a]
            if (
                _is_pick(ae.func)
                and ae.child
                and _is_plain_col_ref(ae.child.value())
            ):
                out.declared.append(
                    Optional[Field](
                        plan.output_schema.field_at_unchecked(n_keys + a).copy()
                    )
                )
                any_pick = True
            else:
                out.declared.append(Optional[Field](None))
        if not any_pick:
            out.n_cols = -1
            out.declared.clear()
        return out^


def _narrow_int_to[
    dst: DType
](imm rb: RecordBatch, c: Int, target: ArrowType, name: String) raises -> Column[
    HeapRegion
]:
    """Column `c` (INT64 storage) as `dst`, NULLs preserved, every value
    CHECKED to be representable -- see the header for why a miss raises."""
    var a = rb.column_as_primitive[DType.int64](c)
    var n = a.length
    var has_nulls = Bool(a.validity)
    var out = (
        PrimitiveArray[dst].allocate_nullable(n) if has_nulls else
        PrimitiveArray[dst].allocate(n)
    )
    for r in range(n):
        if has_nulls and a.is_null(r):
            out._set_null(r)
            continue
        var v = a.get(r)
        var back = v.cast[dst]().cast[DType.int64]()
        if back != v:
            _raise_pick_out_of_range(name, String(v), target)
        out.set(r, v.cast[dst]())
    return Column.from_primitive_with_arrow_type[dst](out, target)


def _narrow_f64_to_f32(
    imm rb: RecordBatch, c: Int, name: String
) raises -> Column[HeapRegion]:
    """Column `c` (FLOAT64) as FLOAT32, NULLs preserved. Every value a FLOAT32
    column holds is exactly representable in FLOAT64, so a pick over one
    round-trips (NaN and the signed zeros included).

    ⛔ CHECKED, like the integer arm (review, 2026-09-25). A
    value that does NOT round-trip was never in the column: MEASURED, the
    grouped fold answers its init SENTINEL (-DBL_MAX for max, +DBL_MAX for min)
    for a group whose only non-NULL values are NaN, and an unchecked cast
    turned that into -inf / +inf -- a second wrong value, silently. It now
    REFUSES naming the column (DuckDB 1.5.3 answers NaN for that group)."""
    var a = rb.column_as_primitive[DType.float64](c)
    var n = a.length
    var has_nulls = Bool(a.validity)
    var out = (
        PrimitiveArray[DType.float32].allocate_nullable(n) if has_nulls else
        PrimitiveArray[DType.float32].allocate(n)
    )
    for r in range(n):
        if has_nulls and a.is_null(r):
            out._set_null(r)
        else:
            var v = a.get(r)
            var f = v.cast[DType.float32]()
            # `v != v` is the NaN test (a NaN never compares equal).
            if v == v and f.cast[DType.float64]() != v:
                _raise_pick_out_of_range(name, String(v), ArrowType.FLOAT32)
            out.set(r, f)
    return Column.from_primitive_with_arrow_type[DType.float32](
        out, ArrowType.FLOAT32
    )


@no_inline
def _raise_pick_out_of_range(name: String, v: String, target: ArrowType) raises:
    raise Error(
        "agg_pick_output_conform: aggregate column '"
        + name
        + "' is a min/max/first/last/any_value over a "
        + String(target)
        + " column, and the aggregate route answered "
        + v
        + ", which is not a "
        + String(target)
        + " value. A pick returns an element of its input, so this is a route"
        " defect, not an answer -- refusing rather than wrapping it."
    )


def _narrowed(
    imm rb: RecordBatch, c: Int, step: Int, imm declared: Field
) raises -> Column[HeapRegion]:
    var w = declared.arrow_type
    var name = String(declared.name)
    if step == PICK_CONFORM_NARROW_F32:
        return _narrow_f64_to_f32(rb, c, name)
    if w == ArrowType.INT8:
        return _narrow_int_to[DType.int8](rb, c, w, name)
    if w == ArrowType.INT16:
        return _narrow_int_to[DType.int16](rb, c, w, name)
    if w == ArrowType.INT32:
        return _narrow_int_to[DType.int32](rb, c, w, name)
    if w == ArrowType.UINT8:
        return _narrow_int_to[DType.uint8](rb, c, w, name)
    if w == ArrowType.UINT16:
        return _narrow_int_to[DType.uint16](rb, c, w, name)
    if w == ArrowType.UINT32:
        return _narrow_int_to[DType.uint32](rb, c, w, name)
    raise Error(
        "agg_pick_output_conform._narrowed: no narrowing for "
        + String(w)
        + " -- `pick_conform_step` and this ladder must name the SAME set."
    )


def conform_agg_picks(
    var rb: RecordBatch, imm plan: AggPickConform
) raises -> RecordBatch:
    """`rb` with every pick column in its input column's type (the closed set
    in the header); every other column, and every batch this plan does not
    describe, unchanged. CONSUMES `rb`."""
    if plan.n_cols < 0 or rb.num_columns() != plan.n_cols:
        return rb^
    var steps = List[Int](capacity=plan.n_cols)
    var any_change = False
    for c in range(plan.n_cols):
        var step = PICK_CONFORM_KEEP
        if plan.declared[c]:
            step = pick_conform_step(
                rb.schema.field_at(c), plan.declared[c].value()
            )
        if step != PICK_CONFORM_KEEP:
            any_change = True
        steps.append(step)
    if not any_change:
        return rb^

    # The schema and the NARROWED columns are built from `rb` before its
    # column slab is taken apart; every other column is MOVED, not copied.
    var sb = SchemaBuilder()
    var narrowed = List[Optional[Column[HeapRegion]]]()
    for c in range(plan.n_cols):
        var drained = rb.schema.field_at(c)
        var step = steps[c]
        if step == PICK_CONFORM_KEEP:
            sb.add_field(drained^)
            narrowed.append(Optional[Column[HeapRegion]](None))
            continue
        ref declared = plan.declared[c].value()
        if step == PICK_CONFORM_RETAG_TZ:
            # Same buffer, same unit: only the Field's zone was lost.
            sb.add_field(
                Field.timestamp(
                    drained.name,
                    drained.arrow_type,
                    declared.timezone(),
                    drained.nullable,
                )
            )
            narrowed.append(Optional[Column[HeapRegion]](None))
            continue
        sb.add_field(Field(drained.name, declared.arrow_type, drained.nullable))
        narrowed.append(
            Optional[Column[HeapRegion]](_narrowed(rb, c, step, declared))
        )

    var slab = rb.take_columns()
    # `Slab.pop` is last-first, so `moved` holds the columns REVERSED and
    # `moved.pop()` hands them back in schema order.
    var moved = List[Column[HeapRegion]]()
    while True:
        var col = slab.pop()
        if not col:
            break
        moved.append(col.take())
    if len(moved) != plan.n_cols:  # cov: unreachable the slab holds the batch's own columns, counted above
        raise Error(  # cov: unreachable see the line above
            "agg_pick_output_conform.conform_agg_picks: took "
            + String(len(moved))
            + " columns out of a batch whose schema declared "
            + String(plan.n_cols)
        )
    var out = RecordBatchBuilder.with_capacity(plan.n_cols)
    for c in range(plan.n_cols):
        var col = moved.pop()
        if narrowed[c]:
            out.add_column(narrowed[c].take())
        else:
            out.add_column(col^)
    return out.build(sb.build())
