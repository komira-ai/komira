"""Plan nodes as `WirePlan` messages, and a whole plan as a `WirePlanEnvelope`.

Each node is one arm of the `WirePlan` oneof (src/plan_proto/plan.proto) and
carries its output schema, which the reader derives again from the node's
inputs and compares, refusing the plan when they differ. Every schema here is
derived by the engine's own factory for the node (src/plan_ir/logical_plan.mojo):

    Scan       scan, its source from libkomira (komira/_plan/_source.py)
    Filter     filter: the child's fields
    Project    project: one field per item; an item that is not a column of
               its own name is aliased to it. Window items add partition-by
               nodes under it (komira/_plan/_window.py)
    Aggregate  aggregate: the keys, then the aggregates (komira/_plan/_agg.py)
    Sort       sort: each key's direction and NULL placement
    Limit      limit: the count and the offset
    TopN       topn: the sort keys and the count
    Distinct   distinct over every column
    Join       join: the left fields, then the right ones unless the join is a
               semi or anti join; a right column whose name the left has is
               renamed `<name>_right`; the side an outer join pads with NULLs
               is nullable. The engine picks the algorithm (`JOIN_ALGO_AUTO`)
    Union      union_all: the first input's fields, which every input must
               have, the same names, types and nullability
    Unnest     unnest: the child's fields, the list column replaced in place by
               a field of its element type, nullable when the element is or
               when the node keeps empty and NULL lists as a NULL row
    MapBatches map_batches: the `UdfRef` of its function (komira/_plan/_udf.py)
               by index; its fields are the children of the `UdfRef`'s return
               type

Refused by name (`UnsupportedOperation`): an `Unnest` of a column that is not a
list; and, because the engine has no node that means them, a `Distinct` over a subset of the columns, and a `Union` whose
inputs differ in a column's type or nullability.

A `Write` is the root of a plan only. It is not a node: `encode_plan` encodes its
child as the envelope's plan and its target as `WirePlanEnvelope.write_target`,
and gives the envelope the format version that carries a write target.

The `UdfRef`s of the plan's user functions are collected in a `UdfTable` while
the nodes are encoded, leaf to root, and become `WirePlanEnvelope.udfs`.

Nothing is optimized or reordered: the engine's optimizer gets the plan as the
node tree says it.
"""

from __future__ import annotations

from collections.abc import Mapping

from komira._errors import UnsupportedOperation
from komira._ops._expr import Alias, ColRef, Node
from komira._ops._rel import (
    PLAN_NODES,
    Aggregate,
    Distinct,
    Filter,
    Join,
    Limit,
    MapBatches,
    Project,
    Scan,
    Sort,
    SortKey,
    TopN,
    Union,
    Unnest,
    Write,
)
from komira._ops._vocab import LEFT_ONLY_HOWS, RIGHT_SUFFIX

from ._agg import encode_aggregate
from ._expr import encode_expr, encode_residual
from ._field import expr_field
from ._source import encode_scan
from ._udf import UdfTable, udf_ref
from ._wire import arrow_id, arrow_name, field, member, pb, vocab
from ._window import window_stack

__all__ = ["encode_plan"]

# The format version of a plan that carries no write target
# (`PLAN_WIRE_FORMAT_VERSION`, src/plan_wire/plan_wire_codec.mojo).
FORMAT_VERSION = 4

# The format version of a plan that carries one
# (`PLAN_WIRE_WRITE_TARGET_MIN_VERSION`, the same file).
WRITE_FORMAT_VERSION = 5

# Each write format's wire name and its default codec: the codec a target that
# names none gets (komira/_ops/_rel.py, `WriteTarget`).
_WRITE_FORMATS = {
    "parquet": ("WFMT_PARQUET", "snappy"),
    "csv": ("WFMT_CSV", "uncompressed"),
    "jsonl": ("WFMT_JSONL", "uncompressed"),
}

_LEFT_PADDED = frozenset({"right", "full"})
_RIGHT_PADDED = frozenset({"left", "full"})


def _same_fields(out: pb.WirePlan, child: pb.WirePlan) -> None:
    out.output_schema.fields.extend(child.output_schema.fields)


def _item_expr(name: str, expr: Node) -> Node:
    """A project item as the expression the engine names `name`."""
    if isinstance(expr, ColRef) and expr.name == name:
        return expr
    return Alias(expr, name)


def _project(node: Project, child: pb.WirePlan, udfs: UdfTable) -> pb.WirePlan:
    below, items = window_stack(node.items, child)
    schema = list(below.output_schema.fields)
    out = pb.WirePlan()
    for name, expr in items:
        item = _item_expr(name, expr)
        out.project.exprs.append(encode_expr(item, schema, udfs))
        out.output_schema.fields.append(expr_field(item, schema))
    out.project.child.CopyFrom(below)
    return out


def _sort_keys(msg, keys: tuple[SortKey, ...]) -> None:
    msg.keys.extend(key.column for key in keys)
    msg.descending.extend(key.descending for key in keys)
    msg.nulls_first.extend(key.nulls_first for key in keys)


def _join(node: Join, left: pb.WirePlan, right: pb.WirePlan, udfs: UdfTable) -> pb.WirePlan:
    out = pb.WirePlan()
    join = out.join
    join.left.CopyFrom(left)
    join.right.CopyFrom(right)
    join.left_on.extend(node.left_on)
    join.right_on.extend(node.right_on)
    join.join_type = member("JOIN_", node.how)
    join.algo_hint = vocab.JOIN_ALGO_AUTO
    if node.residual is not None:
        join.has_residual = True
        join.residual.CopyFrom(
            encode_residual(
                node.residual, left.output_schema.fields, right.output_schema.fields, udfs
            )
        )
    left_names = set()
    for f in left.output_schema.fields:
        left_names.add(f.name)
        g = out.output_schema.fields.add()
        g.CopyFrom(f)
        if node.how in _LEFT_PADDED:
            g.nullable = True
    if node.how not in LEFT_ONLY_HOWS:
        for f in right.output_schema.fields:
            g = out.output_schema.fields.add()
            g.CopyFrom(f)
            if f.name in left_names:
                g.name = f.name + RIGHT_SUFFIX
            if node.how in _RIGHT_PADDED:
                g.nullable = True
    return out


def _union(inputs: list[pb.WirePlan]) -> pb.WirePlan:
    first = inputs[0].output_schema.fields
    for i, branch in enumerate(inputs[1:], start=1):
        for a, b in zip(first, branch.output_schema.fields):
            if (a.arrow_type_id, a.nullable) != (b.arrow_type_id, b.nullable):
                raise UnsupportedOperation(
                    f"Union: the column '{a.name}' of input {i} has Arrow type id "
                    f"{b.arrow_type_id} and nullable {b.nullable}, and the first input's has "
                    f"{a.arrow_type_id} and {a.nullable}; the engine's union takes inputs of one "
                    "schema, so cast the columns to one type first"
                )
    out = pb.WirePlan()
    for branch in inputs:
        out.union_all.children.append(branch)
    out.output_schema.fields.extend(first)
    return out


def _map_batches(node: MapBatches, child: pb.WirePlan, udfs: UdfTable) -> pb.WirePlan:
    schema = child.output_schema.fields
    ref = udf_ref(node.udf, [expr_field(ColRef(name), schema) for name in node.udf.read_set])
    out = pb.WirePlan()
    out.map_batches.child.CopyFrom(child)
    out.map_batches.udf_index = udfs.add(ref)
    out.output_schema.fields.extend(ref.return_type.children)
    return out


def _unnest(node: Unnest, child: pb.WirePlan) -> pb.WirePlan:
    out = pb.WirePlan()
    for f in child.output_schema.fields:
        if f.name != node.column:
            out.output_schema.fields.append(f)
            continue
        if f.arrow_type_id != arrow_id("list") or len(f.child_type_ids) != 1 or len(f.child_nullables) != 1:
            raise UnsupportedOperation(
                f"explode: column '{node.column}' is {arrow_name(f.arrow_type_id)}, not a list"
            )
        out.output_schema.fields.append(
            field(f.name, f.child_type_ids[0], f.child_nullables[0] or node.keep_empty)
        )
    out.unnest.child.CopyFrom(child)
    out.unnest.column = node.column
    out.unnest.keep_empty = node.keep_empty
    return out


def encode_node(
    plan, sources: Mapping[str, pb.WireScanSource], udfs: UdfTable
) -> pb.WirePlan:
    """The plan `plan` (a node of komira._ops) as a `WirePlan`, its scans
    reading `sources` (by path) and its user functions added to `udfs`."""
    if isinstance(plan, Scan):
        return encode_scan(plan, sources)
    if isinstance(plan, Join):
        return _join(
            plan, encode_node(plan.left, sources, udfs), encode_node(plan.right, sources, udfs), udfs
        )
    if isinstance(plan, Union):
        return _union([encode_node(c, sources, udfs) for c in plan.children])
    if isinstance(plan, Distinct) and plan.subset is not None:
        raise UnsupportedOperation(
            "a Distinct over the columns " + ", ".join(plan.subset) + " cannot be encoded: "
            "the engine's distinct compares every column; select those columns first"
        )
    child = encode_node(plan.child, sources, udfs)
    if isinstance(plan, MapBatches):
        return _map_batches(plan, child, udfs)
    if isinstance(plan, Project):
        return _project(plan, child, udfs)
    if isinstance(plan, Aggregate):
        return encode_aggregate(plan, child, udfs)
    if isinstance(plan, Unnest):
        return _unnest(plan, child)
    out = pb.WirePlan()
    _same_fields(out, child)
    if isinstance(plan, Filter):
        out.filter.predicate.CopyFrom(encode_expr(plan.predicate, child.output_schema.fields, udfs))
        out.filter.child.CopyFrom(child)
    elif isinstance(plan, Sort):
        _sort_keys(out.sort, plan.keys)
        out.sort.child.CopyFrom(child)
    elif isinstance(plan, Limit):
        out.limit.n = plan.n
        out.limit.offset = plan.offset
        out.limit.child.CopyFrom(child)
    elif isinstance(plan, TopN):
        _sort_keys(out.topn, plan.keys)
        out.topn.n = plan.n
        out.topn.child.CopyFrom(child)
    else:
        out.distinct.child.CopyFrom(child)
    return out


def encode_plan(plan, sources: Mapping[str, pb.WireScanSource]) -> pb.WirePlanEnvelope:
    """The plan `plan` as the `WirePlanEnvelope` the plan door takes; a `Write`
    root adds its target to the envelope. `sources` maps the path of each scan
    to what it reads (`parquet_source`, `binding_source`). Raises `UnsupportedOperation` for a node the engine
    cannot run as written, and the errors of `encode_expr` for an expression."""
    if not isinstance(plan, PLAN_NODES):
        raise TypeError(f"plan must be a plan node, not {type(plan).__name__}")
    if not isinstance(sources, Mapping):
        raise TypeError(f"sources must be a mapping of paths to sources, not {type(sources).__name__}")
    target = None
    if isinstance(plan, Write):
        plan, target = plan.child, plan.target
    out = pb.WirePlanEnvelope(format_version=FORMAT_VERSION)
    udfs = UdfTable()
    out.plan.CopyFrom(encode_node(plan, sources, udfs))
    out.udfs.extend(udfs.refs)
    if target is not None:
        wire_format, default_codec = _WRITE_FORMATS[target.format]
        out.format_version = WRITE_FORMAT_VERSION
        out.write_target.path = target.path
        out.write_target.format = getattr(vocab, wire_format)
        out.write_target.codec = getattr(vocab, "WCOMP_" + (target.codec or default_codec).upper())
    return out
