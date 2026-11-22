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

Refused by name (`UnsupportedOperation`), because the engine has no node that
means them: a `Distinct` over a subset of the columns, a `Union` whose inputs
differ in a column's type or nullability, and a `Write`, whose target the
plan door does not take.

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
    Project,
    Scan,
    Sort,
    SortKey,
    TopN,
    Union,
    Write,
)
from komira._ops._vocab import LEFT_ONLY_HOWS, RIGHT_SUFFIX

from ._agg import encode_aggregate
from ._expr import encode_expr, encode_residual
from ._field import expr_field
from ._source import encode_scan
from ._wire import member, pb, vocab
from ._window import window_stack

__all__ = ["encode_plan"]

# The format version of a plan that carries no write target
# (`PLAN_WIRE_FORMAT_VERSION`, src/plan_wire/plan_wire_codec.mojo).
FORMAT_VERSION = 4

_LEFT_PADDED = frozenset({"right", "full"})
_RIGHT_PADDED = frozenset({"left", "full"})


def _same_fields(out: pb.WirePlan, child: pb.WirePlan) -> None:
    out.output_schema.fields.extend(child.output_schema.fields)


def _item_expr(name: str, expr: Node) -> Node:
    """A project item as the expression the engine names `name`."""
    if isinstance(expr, ColRef) and expr.name == name:
        return expr
    return Alias(expr, name)


def _project(node: Project, child: pb.WirePlan) -> pb.WirePlan:
    below, items = window_stack(node.items, child)
    schema = list(below.output_schema.fields)
    out = pb.WirePlan()
    for name, expr in items:
        item = _item_expr(name, expr)
        out.project.exprs.append(encode_expr(item, schema))
        out.output_schema.fields.append(expr_field(item, schema))
    out.project.child.CopyFrom(below)
    return out


def _sort_keys(msg, keys: tuple[SortKey, ...]) -> None:
    msg.keys.extend(key.column for key in keys)
    msg.descending.extend(key.descending for key in keys)
    msg.nulls_first.extend(key.nulls_first for key in keys)


def _join(node: Join, left: pb.WirePlan, right: pb.WirePlan) -> pb.WirePlan:
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
            encode_residual(node.residual, left.output_schema.fields, right.output_schema.fields)
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


def encode_node(plan, sources: Mapping[str, pb.WireScanSource]) -> pb.WirePlan:
    """The plan `plan` (a node of komira._ops) as a `WirePlan`, its scans
    reading `sources` (by path)."""
    if isinstance(plan, Scan):
        return encode_scan(plan, sources)
    if isinstance(plan, Write):
        raise UnsupportedOperation(
            "a Write cannot be encoded: the plan door returns rows and takes no write target"
        )
    if isinstance(plan, Join):
        return _join(plan, encode_node(plan.left, sources), encode_node(plan.right, sources))
    if isinstance(plan, Union):
        return _union([encode_node(c, sources) for c in plan.children])
    if isinstance(plan, Distinct) and plan.subset is not None:
        raise UnsupportedOperation(
            "a Distinct over the columns " + ", ".join(plan.subset) + " cannot be encoded: "
            "the engine's distinct compares every column; select those columns first"
        )
    child = encode_node(plan.child, sources)
    if isinstance(plan, Project):
        return _project(plan, child)
    if isinstance(plan, Aggregate):
        return encode_aggregate(plan, child)
    out = pb.WirePlan()
    _same_fields(out, child)
    if isinstance(plan, Filter):
        out.filter.predicate.CopyFrom(encode_expr(plan.predicate, child.output_schema.fields))
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
    """The plan `plan` as the `WirePlanEnvelope` the plan door takes. `sources`
    maps the path of each scan to what it reads (`parquet_source`,
    `binding_source`). Raises `UnsupportedOperation` for a node the engine
    cannot run as written, and the errors of `encode_expr` for an expression."""
    if not isinstance(plan, PLAN_NODES):
        raise TypeError(f"plan must be a plan node, not {type(plan).__name__}")
    if not isinstance(sources, Mapping):
        raise TypeError(f"sources must be a mapping of paths to sources, not {type(sources).__name__}")
    out = pb.WirePlanEnvelope(format_version=FORMAT_VERSION)
    out.plan.CopyFrom(encode_node(plan, sources))
    return out
