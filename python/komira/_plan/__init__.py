"""The plan encoder: komira._ops trees as `komira.plan.v1` messages, the plan
wire the engine reads (src/plan_proto/plan.proto, src/plan_wire).

This part encodes expressions: `encode_expr` gives the `WireExpr` of an
expression node over an input schema, and `expr_field` the output field the
engine derives for it, which a node that computes columns declares in its
output schema. An input schema is a sequence of `WireField`.

It imports the generated modules `komira.plan.v1`, which the package does not
ship yet, so nothing imports it when `komira` is imported.
"""

from __future__ import annotations

from ._expr import encode_expr
from ._field import expr_field

__all__ = ["encode_expr", "expr_field"]
