"""Window items of a `Project` as `WirePartitionByNode`s under it.

The engine computes window functions in a node of their own: a partition-by
node appends one column per window expression to its input. A `Project` that
holds window items is therefore encoded as the SQL binder binds a SELECT list
with windows (`_bind_window_projection`, src/sql/sql_bind_window_order.mojo):
one partition-by node per window item, in item order, the first over the
project's input; then the projection over the last of them, where a window item
is a reference to its column. That column is named after the item, or
`_w_shadow_<i>_<name>` when the input already has a column of that name (`i`
the item's index), and the projection renames it back.

Each window expression carries what the engine reads (`PartitionExpr`,
src/plan_expr/partition_expr.mojo): the function, its argument column, its
offset (lag and lead: the row distance; ntile: the bucket count; nth_value:
n), a NULL default (a `WindowExpr` has none), and a frame. Without a frame it
gets the binder's: the whole partition when unordered, `RANGE BETWEEN
UNBOUNDED PRECEDING AND CURRENT ROW` when ordered. A frame offset is a row or
value count, its direction the bound's.

The engine's placement of NULLs in an order key is last in both directions. The
node carries a placement per order key (`nulls_first`) and the encoder writes
the list only when some key asks for NULLs first, so a window that asks for
nothing encodes exactly as it did before the field existed. An aggregate window with an offset is refused too: the frame says which rows it
reads, and the engine reads no offset for it.

The appended field is the engine's (`partition_expr_output_field`):

    row_number rank dense_rank ntile count   int64, never null
    percent_rank cume_dist avg               float64, never null
    sum                                      int64 over a signed int, float64
                                             otherwise, never null
    min max                                  the input's type and nullability
    lag lead nth_value                       the input's field, nullable
    first_value last_value                   the input's field
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation
from komira._ops._expr import ColRef, Node
from komira._ops._rel import Frame, WindowExpr
from komira._ops._vocab import WINDOW_AGGREGATE

from ._field import columns_of
from ._wire import arrow_id, field, member, pb, vocab

__all__ = ["window_stack"]

_INT64 = arrow_id("int64")
_FLOAT64 = arrow_id("float64")
_SIGNED_INTS = frozenset(arrow_id(t) for t in ("int8", "int16", "int32", "int64"))

# The frames the binder gives a window with no frame clause.
_UNORDERED = Frame("rows", "unbounded_preceding", "unbounded_following")
_ORDERED = Frame("range", "unbounded_preceding", "current_row")


def _frame(win: WindowExpr) -> pb.WireFrame:
    frame = win.frame or (_ORDERED if win.order_by else _UNORDERED)
    return pb.WireFrame(
        units=member("FRAME_UNITS_", frame.units),
        start_tag=member("FRAME_BOUND_", frame.start),
        start_offset=frame.start_offset,
        end_tag=member("FRAME_BOUND_", frame.end),
        end_offset=frame.end_offset,
    )


def _null_default() -> pb.WireScalar:
    """The default a window expression without one carries: the engine's
    `ScalarValue()`, a NULL of no type."""
    return pb.WireScalar(kind=vocab.SCALAR_KIND_DTYPE, time_unit=vocab.SCALAR_TIME_UNIT_MICRO)


def window_field(name: str, win: WindowExpr, schema) -> pb.WireField:
    """The field the engine appends for the window expression `win`, whose
    column is `name`, over the input columns `schema`."""
    func = win.func
    if func in ("row_number", "rank", "dense_rank", "ntile", "count"):
        return field(name, _INT64, False)
    if func in ("percent_rank", "cume_dist", "avg"):
        return field(name, _FLOAT64, False)
    arg = columns_of(schema)[win.arg]
    if func == "sum":
        return field(name, _INT64 if arg.arrow_type_id in _SIGNED_INTS else _FLOAT64, False)
    if func in ("min", "max"):
        return field(name, arg.arrow_type_id, arg.nullable)
    out = pb.WireField()
    out.CopyFrom(arg)
    out.name = name
    if func in ("lag", "lead", "nth_value"):
        out.nullable = True
    return out


def _partition_by(win: WindowExpr, column: str, child: pb.WirePlan, item: str) -> pb.WirePlan:
    if win.func in WINDOW_AGGREGATE and win.offset != 0:
        raise UnsupportedOperation(
            f"the window {item!r} is a {win.func} with offset {win.offset}, and an aggregate "
            "window reads the rows of its frame: give the rows as a Frame"
        )
    schema = list(child.output_schema.fields)
    out = pb.WirePlan()
    node = out.partition_by
    node.partition_keys.extend(win.partition_by)
    node.order_keys.extend(key.column for key in win.order_by)
    node.descending.extend(key.descending for key in win.order_by)
    if any(key.nulls_first for key in win.order_by):
        node.nulls_first.extend(key.nulls_first for key in win.order_by)
    expr = node.partition_exprs.add(
        func=member("PF_", win.func),
        column=win.arg or "",
        offset=win.offset,
        has_default=False,
        alias_name=column,
    )
    expr.default_value.CopyFrom(_null_default())
    expr.frame.CopyFrom(_frame(win))
    node.child.CopyFrom(child)
    out.output_schema.fields.extend(schema)
    out.output_schema.fields.append(window_field(column, win, schema))
    return out


def window_stack(
    items: tuple[tuple[str, Node | WindowExpr], ...], child: pb.WirePlan
) -> tuple[pb.WirePlan, list[tuple[str, Node]]]:
    """The partition-by nodes of the window items of `items` over `child`,
    and the items with each window replaced by a reference to its column."""
    inputs = {f.name for f in child.output_schema.fields}
    plan = child
    out: list[tuple[str, Node]] = []
    for i, (name, item) in enumerate(items):
        if not isinstance(item, WindowExpr):
            out.append((name, item))
            continue
        column = f"_w_shadow_{i}_{name}" if name in inputs else name
        if column in {f.name for f in plan.output_schema.fields}:
            raise UnsupportedOperation(
                f"the window {name!r} would be computed as the column '{column}', "
                "which its input already has; rename that column first"
            )
        plan = _partition_by(item, column, plan, name)
        out.append((name, ColRef(column)))
    return plan, out
