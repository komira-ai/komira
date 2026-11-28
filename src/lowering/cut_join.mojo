# =============================================================================
# cut_join -- the cutter's PLAN_JOIN arm: a build segment and a fused probe
# =============================================================================
#
# A join is two edges. The build child's pipeline ends in a SINK_HASH_BUILD
# segment (key NONE, COLUMNAR; it indexes no ParamTable row, so its
# `sink_param_id` is -1): the sink collects the build rows. The probe child's
# pipeline stays open and gains an OP_JOIN_PROBE naming that segment, with the
# probe keys as `probe_left_keys` and the build keys as `probe_right_keys`,
# paired by position, and an E3 edge to the build segment. Several joins on
# one probe pipeline each add their own build segment and edge.
#
# Served: INNER, LEFT, RIGHT and FULL equi-joins, SEMI and ANTI equi-joins
# (the left rows with, or without, a partner on the right), and CROSS joins
# (no key). The OP_JOIN_PROBE's join type is the probe's view, the probe side
# as its left input: the plan's type when the right child builds; LEFT and
# RIGHT exchanged when the left child builds (a LEFT join that builds its left
# child keeps the build rows, which is the probe's RIGHT), and INNER, FULL and
# CROSS as they are.
#
# The build side is the one the plan records (`JoinData.build_side`); lowering
# never chooses or swaps it. RIGHT builds the right child, LEFT the left one,
# and UNSET builds the right child, the convention a join without a recorded
# side follows.
#
# The probe emits the probe side's columns, then the build side's, a build
# column whose name the probe side uses suffixed `_right`; a SEMI or ANTI
# probe emits the probe side's columns only. The join node's output is the
# left child's columns, then (except for SEMI and ANTI) the right child's,
# renamed by the same rule. When the right child builds, the two are the same
# columns under the same names. When the left child builds, a projection of
# column references is fused after the probe that puts the columns in the
# node's order under the node's names.
#
# Both children are walked, the left before the right, so the scans are met in
# pre-order whichever side builds. In a plan that holds a shared-subplan
# reference `cut_walk` walks the right child first, as the reference's
# producer visits a join, and sets the scan count for each child, so the scans
# keep their pre-order indices and the right child's segments take the lower
# ids (`cut_shared`).
#
# Refused (LOWERING_JOIN_UNSERVED) before either child is walked: a join type
# the plan IR does not define, a SEMI or ANTI join that builds its left child
# (the probe would emit the build rows, which it has no rule for), a CROSS
# join that names a key, an equi-join with no key or with key lists of
# different lengths, more keys than the probe takes, a residual predicate, the
# sort-merge algorithm hint, a build side the plan does not define, a key that
# is not a column of its side, a key pair whose types the probe does not
# compare, and a join whose output names one column twice. Key types: INT64
# and INT32, in any pairing; FLOAT64 with FLOAT64; STRING with STRING; DATE32
# and a TIMESTAMP in microseconds without a time zone, in any pairing (a DATE
# is its midnight, DuckDB's implicit cast); a TIMESTAMP in microseconds with a
# time zone with another such (one instant); DATE64 and the other TIMESTAMP
# units each only with its own type and time-zone presence.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema
from containers.slab import Slab
from lowering.cut_state import _Cutter, _Pipe
from lowering.lowered_plan import LoweringInputs, LOWERING_JOIN_UNSERVED
from plan_expr.expr import Expr
from plan_ir.logical_plan import (
    LogicalPlan,
    plan_tag_name,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_ALGO_SORT_MERGE,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
)
from physical_plan.physical_plan import (
    MorselOp,
    SINK_HASH_BUILD,
    SINK_ORIENT_COLUMNAR,
    KEY_DTYPE_NONE,
    EDGE_E3_PUBLISH_WAIT,
)


comptime JOIN_PROBE_MAX_KEYS = 8
"""The most key columns the probe takes (`op_join_probe`'s composite key)."""


def _join_type_name(join_type: UInt8) -> String:
    if join_type == JOIN_INNER:
        return "INNER"
    if join_type == JOIN_LEFT:
        return "LEFT"
    if join_type == JOIN_RIGHT:
        return "RIGHT"
    if join_type == JOIN_FULL:
        return "FULL"
    if join_type == JOIN_SEMI:
        return "SEMI"
    if join_type == JOIN_ANTI:
        return "ANTI"
    if join_type == JOIN_CROSS:
        return "CROSS"
    return "type " + String(Int(join_type))


def _served_type(join_type: UInt8) -> Bool:
    """True for the join types the probe has a rule for."""
    return (
        join_type == JOIN_INNER
        or join_type == JOIN_LEFT
        or join_type == JOIN_RIGHT
        or join_type == JOIN_FULL
        or join_type == JOIN_SEMI
        or join_type == JOIN_ANTI
        or join_type == JOIN_CROSS
    )


def _unserved(node: LogicalPlan, what: String) -> Error:
    return Error(
        String(LOWERING_JOIN_UNSERVED)
        + ": "
        + plan_tag_name(node.tag)
        + " ("
        + what
        + ") is not served by the hash join"
    )


def _key_family(field: Field) -> Int:
    """The family a key column compares in, or -1: 0 for the integers, 1 for
    FLOAT64, 2 for STRING, 3 for DATE32 and a microsecond TIMESTAMP without a
    time zone (the probe keys a DATE as its midnight in microseconds), 4 for a
    microsecond TIMESTAMP with a time zone, and one family apiece for DATE64
    and each other TIMESTAMP unit, with and without a time zone."""
    var t = field.arrow_type
    if t == ArrowType.INT64 or t == ArrowType.INT32:
        return 0
    if t == ArrowType.FLOAT64:
        return 1
    if t == ArrowType.STRING:
        return 2
    if t == ArrowType.DATE32:
        return 3
    var zoned = 1 if field.timezone() != "" else 0
    if t == ArrowType.TIMESTAMP or t == ArrowType.TIMESTAMP_US:
        return 3 + zoned
    if t == ArrowType.DATE64:
        return 5
    if t == ArrowType.TIMESTAMP_S:
        return 6 + zoned
    if t == ArrowType.TIMESTAMP_MS:
        return 8 + zoned
    if t == ArrowType.TIMESTAMP_NS:
        return 10 + zoned
    return -1


def _key_field(
    node: LogicalPlan, schema: Schema, name: String, side: String
) raises -> Field:
    """The field of the column `name` of `schema` (the first so named), or the
    refusal naming the side it is missing from."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return schema.field_at_unchecked(i)
    raise _unserved(
        node, "the key '" + name + "' is not a column of the " + side + " side"
    )


def _repeated_name(names: List[String]) -> Int:
    """The index of the first name that an earlier one repeats, or -1."""
    for i in range(len(names)):
        for j in range(i):
            if names[j] == names[i]:
                return i
    return -1


def _names_of(schema: Schema) -> List[String]:
    var out = List[String]()
    for i in range(schema.num_columns()):
        out.append(schema.field_name(i))
    return out^


def probe_output_names(
    probe_names: List[String], build_names: List[String]
) -> List[String]:
    """The column names the probe emits: the probe side's, then the build
    side's, a build name the probe side uses suffixed `_right`."""
    var out = probe_names.copy()
    for i in range(len(build_names)):
        var name = build_names[i]
        var used = False
        for j in range(len(probe_names)):
            if probe_names[j] == name:
                used = True
        if used:
            out.append(name + "_right")
        else:
            out.append(name)
    return out^


struct JoinShape(Movable):
    """What a PLAN_JOIN node lowers to, decided before its children are
    walked: which child builds, the probe's join type, the keys of each side
    in pair order, and the
    projection that restores the node's column order and names after the
    probe, when one is needed."""

    var build_left: Bool
    var probe_join_type: UInt8
    """The OP_JOIN_PROBE's join type: the probe side is its left input."""
    var probe_keys: List[String]
    var build_keys: List[String]
    var reorder: Optional[MorselOp]

    def __init__(
        out self,
        build_left: Bool,
        probe_join_type: UInt8,
        var probe_keys: List[String],
        var build_keys: List[String],
        var reorder: Optional[MorselOp],
    ):
        self.build_left = build_left
        self.probe_join_type = probe_join_type
        self.probe_keys = probe_keys^
        self.build_keys = build_keys^
        self.reorder = reorder^


def join_shape(node: LogicalPlan) raises -> JoinShape:
    """The shape a PLAN_JOIN node lowers to, or its refusal. Called before the
    children are walked."""
    ref jd = node.join_data_ref()
    var jt = jd.join_type
    if not _served_type(jt):
        raise _unserved(node, "a " + _join_type_name(jt) + " join")
    var n = len(jd.left_on)
    if jt == JOIN_CROSS:
        if n != 0 or len(jd.right_on) != 0:
            raise _unserved(node, "a CROSS join that names a key")
    elif n == 0:
        raise _unserved(node, "a join with no equi key")
    if n != len(jd.right_on):
        raise _unserved(
            node,
            String(n)
            + " left keys against "
            + String(len(jd.right_on))
            + " right keys",
        )
    if n > JOIN_PROBE_MAX_KEYS:
        raise _unserved(
            node,
            String(n)
            + " keys; the probe takes at most "
            + String(JOIN_PROBE_MAX_KEYS),
        )
    if jd.has_residual():
        raise _unserved(node, "a residual predicate")
    if jd.algo_hint == JOIN_ALGO_SORT_MERGE:
        raise _unserved(node, "the sort-merge algorithm hint")
    var side = jd.build_side
    if (
        side != JOIN_BUILD_SIDE_LEFT
        and side != JOIN_BUILD_SIDE_RIGHT
        and side != JOIN_BUILD_SIDE_UNSET
    ):
        raise _unserved(node, "build side " + String(Int(side)))
    ref left_schema = jd.left[].output_schema
    ref right_schema = jd.right[].output_schema
    for k in range(n):
        var lt = _key_field(node, left_schema, jd.left_on[k], "left")
        var rt = _key_field(node, right_schema, jd.right_on[k], "right")
        var lf = _key_family(lt)
        if lf < 0 or lf != _key_family(rt):
            raise _unserved(
                node,
                "the key pair "
                + jd.left_on[k]
                + " ("
                + String(lt.arrow_type)
                + ") = "
                + jd.right_on[k]
                + " ("
                + String(rt.arrow_type)
                + ")",
            )
    var out_names = _names_of(node.output_schema)
    var dup = _repeated_name(out_names)
    if dup >= 0:
        raise _unserved(
            node, "an output that names '" + out_names[dup] + "' twice"
        )
    var build_left = side == JOIN_BUILD_SIDE_LEFT
    var keeps_left_only = jt == JOIN_SEMI or jt == JOIN_ANTI
    if build_left and keeps_left_only:
        raise _unserved(
            node, "a " + _join_type_name(jt) + " join that builds its left side"
        )
    var probe_type = jt
    if build_left and jt == JOIN_LEFT:
        probe_type = JOIN_RIGHT
    elif build_left and jt == JOIN_RIGHT:
        probe_type = JOIN_LEFT
    var left_names = _names_of(left_schema)
    var right_names = _names_of(right_schema)
    var emitted: List[String]
    if keeps_left_only:
        emitted = left_names.copy()
    elif build_left:
        emitted = probe_output_names(right_names, left_names)
    else:
        emitted = probe_output_names(left_names, right_names)
    # The probe's names are unique whenever the node's are: a left name the
    # probe renames to `x_right` collides only if the right side holds both
    # `x` and `x_right`, and the node then names `x_right` twice.
    # Node column i is left column i (i < L) or right column i - L. The probe
    # emits the probe side first, so a left build puts the left columns after
    # the right ones.
    var n_left = len(left_names)
    var n_right = len(right_names)
    var exprs = Slab[Expr]()
    var needed = False
    for i in range(len(out_names)):
        var at = i
        if build_left:
            at = n_right + i if i < n_left else i - n_left
        if at != i or emitted[at] != out_names[i]:
            needed = True
        exprs.append(Expr.col_ref(emitted[at]))
    var reorder: Optional[MorselOp] = None
    if needed:
        reorder = Optional(MorselOp.project(exprs^, out_names^))
    if build_left:
        return JoinShape(
            True, probe_type, jd.right_on.copy(), jd.left_on.copy(), reorder^
        )
    return JoinShape(
        False, probe_type, jd.left_on.copy(), jd.right_on.copy(), reorder^
    )


def _close_join(
    mut cutter: _Cutter,
    node: LogicalPlan,
    var shape: JoinShape,
    var left: _Pipe,
    var right: _Pipe,
    inputs: LoweringInputs,
) -> _Pipe:
    """End the build child's pipeline in its SINK_HASH_BUILD segment and fuse
    the probe onto the probe child's pipeline."""
    var probe: _Pipe
    var build: _Pipe
    if shape.build_left:
        build = left^
        probe = right^
    else:
        build = right^
        probe = left^
    var seg = cutter._close(
        build^, SINK_HASH_BUILD, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, inputs
    )
    probe.append_op(
        MorselOp.join_probe(
            seg,
            shape.probe_keys.copy(),
            shape.build_keys.copy(),
            shape.probe_join_type,
        )
    )
    probe.deps.append(seg)
    probe.edge_tags.append(EDGE_E3_PUBLISH_WAIT)
    probe.has_join = True
    if shape.reorder:
        probe.append_op(shape.reorder.take())
        probe.has_project = True
    probe.schema = node.output_schema.copy()
    return probe^
