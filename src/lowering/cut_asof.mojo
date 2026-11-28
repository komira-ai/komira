# =============================================================================
# cut_asof -- the cutter's PLAN_ASOF_JOIN arm: a right segment and an ASOF sink
# =============================================================================
#
# An as-of join is two segments. The right child's pipeline ends in a
# SINK_COLLECT segment of its own (as a hash join's build side does, so a
# shared segment's output is never taken from its other readers). The left
# child's pipeline ends in a SINK_ASOF_JOIN segment (key NONE, COLUMNAR) whose
# AsofJoinSinkData is the next row of the ParamTable's `asof`, names the right
# segment as `right_seg_id`, and depends on it over an E3 edge. A pipeline
# then opens that reads the ASOF segment's output, the node's columns: the
# left child's, then the right child's made nullable, a right column whose
# name the left side uses suffixed `_right`.
#
# The ASOF segment estimates its left scan's rows: one output row per left
# row.
#
# The sink takes every left row and the right segment's rows whole, sorts both
# on (keys..., ASOF column) unless the plan marks a side sorted, and walks
# them (`op_asof`). The left rows come out in that sorted order; nothing above
# the node may count on the left side's order.
#
# The children are walked as a join's are: the left before the right, and in
# a plan that holds a shared-subplan reference the right first with the scan
# count set for each child, so the scans keep their pre-order indices
# (`cut_walk`, `cut_shared`).
#
# Refused (LOWERING_ASOF_UNSERVED) before either child is walked: a strategy
# the plan IR does not define; key lists of different lengths; a key or ASOF
# column that is not a column of its side; a key pair the walker does not
# compare (INT32, INT64 and FLOAT64 with the same type, STRING with STRING);
# an ASOF column pair of different types, or of a type the walker and the sort
# do not both take (INT32, INT64, FLOAT64 and the TIMESTAMP units); a
# tolerance of the other family than the ASOF column (an INT64 tolerance for
# an integer or TIMESTAMP column, a FLOAT64 one for a FLOAT64 column); and an
# output that names one column twice.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from lowering.cut_state import _Cutter, _Pipe
from lowering.lowered_plan import LoweringInputs, LOWERING_ASOF_UNSERVED
from plan_ir.logical_plan import (
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    LogicalPlan,
    plan_tag_name,
)
from physical_plan.physical_plan import (
    AsofJoinSinkData,
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_NONE,
    SINK_ASOF_JOIN,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
)


def _unserved(node: LogicalPlan, what: String) -> Error:
    return Error(
        String(LOWERING_ASOF_UNSERVED)
        + ": "
        + plan_tag_name(node.tag)
        + " ("
        + what
        + ") is not served by the as-of join"
    )


def _column_type(
    node: LogicalPlan, schema: Schema, side: String, name: String
) raises -> ArrowType:
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return schema.field_at(i).arrow_type
    raise _unserved(
        node, side + " column '" + name + "' is not a column of its side"
    )


def _is_string(t: ArrowType) -> Bool:
    return t == ArrowType.STRING or t == ArrowType.DICTIONARY


def _check_key_pair(
    node: LogicalPlan, l: ArrowType, r: ArrowType, k: Int
) raises:
    if _is_string(l) and _is_string(r):
        return
    var served = (
        l == ArrowType.INT32 or l == ArrowType.INT64 or l == ArrowType.FLOAT64
    )
    if not served or l != r:
        raise _unserved(
            node,
            "key "
            + String(k)
            + " compares "
            + String(l)
            + " with "
            + String(r)
            + "; INT32, INT64 and FLOAT64 with the same type and STRING with"
            " STRING are compared",
        )


def _asof_dtype_of(t: ArrowType) -> Optional[DType]:
    """The storage the walker reads an ASOF column of type `t` at, or None
    for a type it does not take."""
    if t == ArrowType.INT32:
        return DType.int32
    if t == ArrowType.INT64 or t.is_timestamp():
        return DType.int64
    if t == ArrowType.FLOAT64:
        return DType.float64
    return None


def _check_names_unique(node: LogicalPlan) raises:
    ref s = node.output_schema
    for i in range(s.num_columns()):
        for j in range(i):
            if s.field_name(i) == s.field_name(j):
                raise _unserved(
                    node,
                    "its output names the column '"
                    + s.field_name(i)
                    + "' twice",
                )


def check_asof(node: LogicalPlan) raises -> DType:
    """Every refusal of the node itself, before its children are walked;
    returns the storage of its ASOF column."""
    ref ad = node.asof_join_data_ref()
    if (
        ad.strategy != ASOF_BACKWARD
        and ad.strategy != ASOF_FORWARD
        and ad.strategy != ASOF_NEAREST
    ):
        raise _unserved(node, "strategy " + String(Int(ad.strategy)))
    if len(ad.left_keys) != len(ad.right_keys):
        raise _unserved(
            node,
            String(len(ad.left_keys))
            + " left keys and "
            + String(len(ad.right_keys))
            + " right keys",
        )
    ref ls = ad.left[].output_schema
    ref rs = ad.right[].output_schema
    for k in range(len(ad.left_keys)):
        var lt = _column_type(node, ls, "left key", ad.left_keys[k])
        var rt = _column_type(node, rs, "right key", ad.right_keys[k])
        _check_key_pair(node, lt, rt, k)
    var la = _column_type(node, ls, "left ASOF", ad.left_asof)
    var ra = _column_type(node, rs, "right ASOF", ad.right_asof)
    var dtype = _asof_dtype_of(la)
    if not dtype or la != ra:
        raise _unserved(
            node,
            "the ASOF columns are "
            + String(la)
            + " and "
            + String(ra)
            + "; two columns of one of INT32, INT64, FLOAT64 or a TIMESTAMP"
            " unit are walked",
        )
    var float_col = dtype.value() == DType.float64
    if (ad.tolerance.is_int64() and float_col) or (
        ad.tolerance.is_float64() and not float_col
    ):
        raise _unserved(
            node,
            "a tolerance of the other family than its "
            + String(la)
            + " ASOF column",
        )
    _check_names_unique(node)
    return dtype.value()


def _close_asof(
    mut cutter: _Cutter,
    node: LogicalPlan,
    asof_dtype: DType,
    var left: _Pipe,
    var right: _Pipe,
    inputs: LoweringInputs,
) -> _Pipe:
    """End the right child in its segment and the left child in the ASOF
    sink, and open the pipeline that reads the join's rows."""
    var rseg = cutter._close(
        right^, SINK_COLLECT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, inputs
    )
    ref ad = node.asof_join_data_ref()
    var pid = len(cutter.params.asof)
    cutter.params.asof.append(
        AsofJoinSinkData(
            ad.left_keys.copy(),
            ad.right_keys.copy(),
            ad.left_asof,
            ad.right_asof,
            ad.strategy,
            ad.tolerance,
            ad.left_sort_keys.copy(),
            ad.left_sort_desc.copy(),
            ad.right_sort_keys.copy(),
            ad.right_sort_desc.copy(),
            node.output_schema.copy(),
            asof_dtype=asof_dtype,
            right_seg_id=rseg,
        )
    )
    left.deps.append(rseg)
    left.edge_tags.append(EDGE_E3_PUBLISH_WAIT)
    var seg = cutter._close(
        left^, SINK_ASOF_JOIN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, pid, inputs
    )
    return cutter._reopen(seg, node.output_schema)
