# =============================================================================
# cut_window -- the cutter's PLAN_PARTITION_BY arm: a breaker
# =============================================================================
#
# A window node ends the open pipeline in a SINK_PARTITION_BY segment (key
# NONE, COLUMNAR) whose PartitionBySinkData is the next row of the ParamTable's
# `window`, and opens a pipeline that reads that segment's output over an E3
# edge. The sink holds every row, orders them by the partition keys then the
# order keys (each order key's NULLs where the node places them: last in both
# directions unless the node says NULLS FIRST) and appends one column per window
# function. The keys stay column names. One node carries every function of
# one OVER clause, so a fused node is one segment.
#
# The rows come out in key order, so when the node has a partition or an order
# key the reopened pipeline is marked as a sorted stream: a LIMIT above it is
# refused as a LIMIT above a sort is (`cut_limit`). The segment still records
# no order of its own.
#
# Refused (LOWERING_WINDOW_UNSERVED) before the child is walked, the first
# failing check in this order:
#
#   1. a descending list whose length is not the order keys';
#   1b. a non-empty nulls_first list whose length is not the order keys';
#   2. a partition or order key that is not a column of the child, or whose
#      type is not INT64, INT32, FLOAT64, BOOL or STRING (the types the
#      window's sort orders);
#   3. per function, in the node's order:
#        ROW_NUMBER, RANK, DENSE_RANK, PERCENT_RANK, CUME_DIST: served, the
#          frame is ignored;
#        NTILE: a bucket count above 0;
#        LAG, LEAD: an INT64, FLOAT64 or STRING argument column, and a default
#          (when it is not NULL) the column holds without a change of value:
#          an integer for INT64, an integer or a float for FLOAT64, a string
#          for STRING;
#        FIRST_VALUE, LAST_VALUE, NTH_VALUE (n above 0): an INT64, FLOAT64 or
#          STRING argument column and a served frame;
#        SUM, MIN, MAX, AVG: an INT8, INT16, INT32, INT64 or FLOAT64 argument
#          column and a served frame;
#        COUNT: a column of any type, or "" for COUNT(*), and a served frame;
#        any other function: refused by name.
#      Served frames: every ROWS or RANGE frame SQL allows, with the bounds
#      UNBOUNDED PRECEDING, n PRECEDING, CURRENT ROW, n FOLLOWING and
#      UNBOUNDED FOLLOWING. Refused, in this order, with the frame spelled:
#        - frame units that are neither ROWS nor RANGE;
#        - a shape SQL refuses, with DuckDB's reason: a start of UNBOUNDED
#          FOLLOWING, an end of UNBOUNDED PRECEDING, a FOLLOWING start whose
#          end is CURRENT ROW or PRECEDING, a CURRENT ROW start whose end is
#          PRECEDING;
#        - an offset below 0 (SQL here cannot write one; DuckDB's frames for
#          a large negative offset wrap around, so none is served);
#        - a RANGE frame with an offset (n PRECEDING or n FOLLOWING) over a
#          window whose ORDER BY is not one key, or whose key is not INT64,
#          INT32 or FLOAT64 (the types `op_window` measures an offset on).
#
# The schema the sink declares is the node's, except that a SUM, AVG, MIN or
# MAX column is nullable when its argument column is, and a SUM, AVG, MIN,
# MAX, FIRST_VALUE or LAST_VALUE column is nullable when its frame can be
# empty: a frame that does not hold the current row (`1 FOLLOWING AND 2
# FOLLOWING`) is empty at a partition's edge, and its answer there is NULL.
# The reopened pipeline carries that schema.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema, SchemaBuilder
from lowering.cut_state import _Cutter, _Pipe
from lowering.lowered_plan import LoweringInputs, LOWERING_WINDOW_UNSERVED
from plan_expr.partition_expr import (
    FRAME_UNITS_ROWS,
    PartitionExpr,
    partition_fn_name,
    value_fn_has_default,
    PF_ROW_NUMBER,
    PF_RANK,
    PF_DENSE_RANK,
    PF_PERCENT_RANK,
    PF_CUME_DIST,
    PF_NTILE,
    PF_LAG,
    PF_LEAD,
    PF_FIRST_VALUE,
    PF_LAST_VALUE,
    PF_NTH_VALUE,
    PF_SUM,
    PF_AVG,
    PF_COUNT,
    PF_MIN,
    PF_MAX,
    PartitionFrame,
    FRAME_UNITS_RANGE,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
)
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import (
    PartitionBySinkData,
    SINK_PARTITION_BY,
    SINK_ORIENT_COLUMNAR,
    KEY_DTYPE_NONE,
)


def _unserved(reason: String) -> Error:
    return Error(String(LOWERING_WINDOW_UNSERVED) + ": " + reason)


def _column_index(schema: Schema, name: String) -> Int:
    """The index of the first column of `schema` called `name`, or -1."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return i
    return -1


def _is_sortable_key(t: ArrowType) -> Bool:
    return (
        t == ArrowType.INT64
        or t == ArrowType.INT32
        or t == ArrowType.FLOAT64
        or t == ArrowType.BOOL
        or t == ArrowType.STRING
    )


def _check_keys(schema: Schema, keys: List[String], clause: String) raises:
    for i in range(len(keys)):
        var at = _column_index(schema, keys[i])
        if at < 0:
            raise _unserved(
                "the " + clause + " key '" + keys[i] + "' is not a column of the input"
            )
        var t = schema.field_arrow_type(at)
        if not _is_sortable_key(t):
            raise _unserved(
                "the "
                + clause
                + " key '"
                + keys[i]
                + "' has type "
                + String(t)
                + ", which the window's sort does not order"
            )


def _fn_text(expr: PartitionExpr) -> String:
    return partition_fn_name(expr.func) + "(" + expr.column + ")"


def _bound_sql(tag: UInt8, offset: Int64) -> String:
    """One frame bound as SQL spells it (the five FRAME_BOUND_* tags; the
    binder emits no other)."""
    if tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
        return "UNBOUNDED PRECEDING"
    if tag == FRAME_BOUND_PRECEDING:
        return String(offset) + " PRECEDING"
    if tag == FRAME_BOUND_CURRENT_ROW:
        return "CURRENT ROW"
    if tag == FRAME_BOUND_FOLLOWING:
        return String(offset) + " FOLLOWING"
    return "UNBOUNDED FOLLOWING"


def _frame_sql(f: PartitionFrame) -> String:
    """The frame as SQL spells it: `ROWS BETWEEN 1 PRECEDING AND CURRENT ROW`."""
    var units = String("RANGE") if f.units == FRAME_UNITS_RANGE else String("ROWS")
    return (
        units
        + " BETWEEN "
        + _bound_sql(f.start_tag, f.start_offset)
        + " AND "
        + _bound_sql(f.end_tag, f.end_offset)
    )


def _is_offset_bound(tag: UInt8) -> Bool:
    return tag == FRAME_BOUND_PRECEDING or tag == FRAME_BOUND_FOLLOWING


def _shape_refusal(f: PartitionFrame) -> String:
    """DuckDB's reason for a frame shape SQL refuses, or "" for a shape it
    allows (its parser's sentences, measured on v1.5.6)."""
    if f.start_tag == FRAME_BOUND_UNBOUNDED_FOLLOWING:
        return "frame start cannot be UNBOUNDED FOLLOWING"
    if f.end_tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
        return "frame end cannot be UNBOUNDED PRECEDING"
    # DuckDB says "cannot have preceding rows" for an explicit `n FOLLOWING
    # AND CURRENT ROW` too; its "cannot end with current row" is the
    # shorthand `ROWS n FOLLOWING`'s, which a plan cannot tell apart.
    if f.start_tag == FRAME_BOUND_FOLLOWING and (
        f.end_tag == FRAME_BOUND_PRECEDING or f.end_tag == FRAME_BOUND_CURRENT_ROW
    ):
        return "frame starting from following row cannot have preceding rows"
    if f.start_tag == FRAME_BOUND_CURRENT_ROW and f.end_tag == FRAME_BOUND_PRECEDING:
        return "frame starting from current row cannot have preceding rows"
    return ""


def _is_range_offset_key(t: ArrowType) -> Bool:
    return t == ArrowType.INT64 or t == ArrowType.INT32 or t == ArrowType.FLOAT64


def _check_frame(
    expr: PartitionExpr, order_keys: List[String], schema: Schema
) raises:
    ref f = expr.frame
    if f.units != FRAME_UNITS_ROWS and f.units != FRAME_UNITS_RANGE:
        raise _unserved(
            _fn_text(expr)
            + " has the frame units "
            + String(Int(f.units))
            + ", which are neither ROWS nor RANGE"
        )
    var head = _fn_text(expr) + " has the frame " + _frame_sql(f)
    var shape = _shape_refusal(f)
    if shape != "":
        raise _unserved(head + ", which SQL does not allow: " + shape)
    if (_is_offset_bound(f.start_tag) and f.start_offset < 0) or (
        _is_offset_bound(f.end_tag) and f.end_offset < 0
    ):
        raise _unserved(head + "; an offset below 0 is not served")
    if f.units == FRAME_UNITS_ROWS:
        return
    if not (_is_offset_bound(f.start_tag) or _is_offset_bound(f.end_tag)):
        return
    if len(order_keys) != 1:
        raise _unserved(
            head
            + "; a RANGE frame with an offset needs exactly one ORDER BY key,"
            " and the window has "
            + String(len(order_keys))
        )
    # The key is a column of the child: `_check_keys` ran first.
    var t = schema.field_arrow_type(_column_index(schema, order_keys[0]))
    if not _is_range_offset_key(t):
        raise _unserved(
            head
            + "; a RANGE frame with an offset needs an INT64, INT32 or FLOAT64"
            " ORDER BY key, and '"
            + order_keys[0]
            + "' has type "
            + String(t)
        )


def _holds_current_row(f: PartitionFrame) -> Bool:
    """True iff every row's frame holds the row itself, so it is never empty.
    Offsets are not negative here (`_check_frame` refused them), so only a
    start of `n FOLLOWING` or an end of `n PRECEDING` with n above 0 can
    leave the row out, in ROWS and in RANGE units alike (a RANGE bound
    `0 FOLLOWING` is the current key, NaN and infinities included)."""
    var start_ok = f.start_tag != FRAME_BOUND_FOLLOWING or f.start_offset == 0
    var end_ok = f.end_tag != FRAME_BOUND_PRECEDING or f.end_offset == 0
    return start_ok and end_ok


def _argument_type(expr: PartitionExpr, schema: Schema) raises -> ArrowType:
    """The type of the function's argument column, or the refusal when the
    column is not one of the child's."""
    var at = _column_index(schema, expr.column)
    if at < 0:
        raise _unserved(
            _fn_text(expr)
            + " names the column '"
            + expr.column
            + "', which is not a column of the input"
        )
    return schema.field_arrow_type(at)


def _require_type(
    expr: PartitionExpr, t: ArrowType, int64_float64_string: Bool
) raises:
    """Refuse an argument type that is not INT64, FLOAT64 or STRING (or, when
    `int64_float64_string` is False, not INT64 or FLOAT64)."""
    if t == ArrowType.INT64 or t == ArrowType.FLOAT64:
        return
    if int64_float64_string and t == ArrowType.STRING:
        return
    raise _unserved(
        _fn_text(expr)
        + " has an argument of type "
        + String(t)
        + ", which the window sink does not compute over"
    )


def _require_aggregate_type(expr: PartitionExpr, t: ArrowType) raises:
    """Refuse a SUM, AVG, MIN or MAX argument type that is not INT8, INT16,
    INT32, INT64 or FLOAT64 (the window sink widens a narrow integer)."""
    if t == ArrowType.INT8 or t == ArrowType.INT16 or t == ArrowType.INT32:
        return
    _require_type(expr, t, False)


def _check_default(expr: PartitionExpr, t: ArrowType) raises:
    if not value_fn_has_default(expr):
        return
    ref d = expr.default_value
    var fits: Bool
    if t == ArrowType.INT64:
        fits = d.is_any_integer()
    elif t == ArrowType.FLOAT64:
        fits = d.is_any_integer() or d.is_float()
    else:
        fits = d.is_string()
    if not fits:
        raise _unserved(
            _fn_text(expr)
            + " has a default that the "
            + String(t)
            + " column cannot hold unchanged"
        )


def _check_expr(
    expr: PartitionExpr, order_keys: List[String], schema: Schema
) raises:
    var f = expr.func
    if (
        f == PF_ROW_NUMBER
        or f == PF_RANK
        or f == PF_DENSE_RANK
        or f == PF_PERCENT_RANK
        or f == PF_CUME_DIST
    ):
        return
    if f == PF_NTILE:
        if expr.offset <= 0:
            raise _unserved(
                "NTILE has the bucket count "
                + String(expr.offset)
                + "; a count above 0 is required"
            )
        return
    if f == PF_LAG or f == PF_LEAD:
        var t = _argument_type(expr, schema)
        _require_type(expr, t, True)
        _check_default(expr, t)
        return
    if f == PF_FIRST_VALUE or f == PF_LAST_VALUE or f == PF_NTH_VALUE:
        if f == PF_NTH_VALUE and expr.offset <= 0:
            raise _unserved(
                "NTH_VALUE has n = "
                + String(expr.offset)
                + "; an n above 0 is required"
            )
        _require_type(expr, _argument_type(expr, schema), True)
        _check_frame(expr, order_keys, schema)
        return
    if f == PF_SUM or f == PF_AVG or f == PF_MIN or f == PF_MAX:
        _require_aggregate_type(expr, _argument_type(expr, schema))
        _check_frame(expr, order_keys, schema)
        return
    if f == PF_COUNT:
        if expr.column != "":
            _ = _argument_type(expr, schema)
        _check_frame(expr, order_keys, schema)
        return
    raise _unserved(partition_fn_name(f) + " is not a window function the sink computes")


def _declared_schema(
    node: LogicalPlan, exprs: List[PartitionExpr], child: Schema
) -> Schema:
    """The node's output schema, with a SUM, AVG, MIN or MAX column nullable
    when its argument column is, and a SUM, AVG, MIN, MAX, FIRST_VALUE or
    LAST_VALUE column nullable when its frame can be empty."""
    ref declared = node.output_schema
    var first = declared.num_columns() - len(exprs)
    var changed = List[Bool]()
    var any_changed = False
    for j in range(len(exprs)):
        var f = exprs[j].func
        var nullable = False
        if f == PF_SUM or f == PF_AVG or f == PF_MIN or f == PF_MAX:
            var at = _column_index(child, exprs[j].column)
            nullable = (at >= 0 and child.field_nullable(at)) or not (
                _holds_current_row(exprs[j].frame)
            )
        elif f == PF_FIRST_VALUE or f == PF_LAST_VALUE:
            nullable = not _holds_current_row(exprs[j].frame)
        var flip = nullable and not declared.field_nullable(first + j)
        changed.append(flip)
        any_changed = any_changed or flip
    if not any_changed:
        return declared.copy()
    var sb = SchemaBuilder()
    for i in range(declared.num_columns()):
        var field = declared.field_at_unchecked(i)
        if i >= first and changed[i - first]:
            field.nullable = True
        sb.add_field(field)
    return sb.build()


def _window_data(node: LogicalPlan) raises -> PartitionBySinkData:
    """The sink row a PLAN_PARTITION_BY node needs, or its refusal. Called
    before the child is walked."""
    ref pd = node.partition_by_data_ref()
    ref child = pd.child[].output_schema
    if len(pd.descending) != len(pd.order_keys):
        raise _unserved(
            "the node has "
            + String(len(pd.order_keys))
            + " order keys and "
            + String(len(pd.descending))
            + " descending flags"
        )
    if len(pd.nulls_first) != 0 and len(pd.nulls_first) != len(pd.order_keys):
        raise _unserved(
            "the node has "
            + String(len(pd.order_keys))
            + " order keys and "
            + String(len(pd.nulls_first))
            + " nulls_first flags"
        )
    _check_keys(child, pd.partition_keys, "PARTITION BY")
    _check_keys(child, pd.order_keys, "ORDER BY")
    for i in range(len(pd.partition_exprs)):
        _check_expr(pd.partition_exprs[i], pd.order_keys, child)
    return PartitionBySinkData(
        pd.partition_keys.copy(),
        pd.order_keys.copy(),
        pd.descending.copy(),
        pd.partition_exprs.copy(),
        _declared_schema(node, pd.partition_exprs, child),
        pd.nulls_first.copy(),
    )


def _close_window(
    mut cutter: _Cutter,
    node: LogicalPlan,
    var pipe: _Pipe,
    var data: PartitionBySinkData,
    inputs: LoweringInputs,
) -> _Pipe:
    """End the window's child pipeline in its sink and open the pipeline that
    reads the sink's output."""
    var pid = len(cutter.params.window)
    var keyed = len(data.partition_keys) + len(data.order_keys) > 0
    var schema = data.output_schema.copy()
    cutter.params.window.append(data^)
    var seg = cutter._close(
        pipe^,
        SINK_PARTITION_BY,
        KEY_DTYPE_NONE,
        SINK_ORIENT_COLUMNAR,
        pid,
        inputs,
    )
    var reopened = cutter._reopen(seg, schema)
    reopened.sorted_input = keyed
    return reopened^
