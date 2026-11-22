"""The plan encoder: komira._ops trees as `komira.plan.v1` messages, the plan
wire the engine reads (src/plan_proto/plan.proto, src/plan_wire).

`encode_plan` gives the `WirePlanEnvelope` of a whole plan, the bytes the plan
door takes (`komira_plan_stream`), each node with the output schema the engine
derives for it. Its scans read sources libkomira describes: `parquet_source`
over the schema bytes of `komira_parquet_schema`, `binding_source` over the
binding bytes of `komira_csv_binding` and `komira_json_binding`, keyed by the
scan's path.

`encode_expr` gives the `WireExpr` of an expression node over an input schema,
and `expr_field` the output field the engine derives for it. An input schema
is a sequence of `WireField`.

Nothing here writes or reads SQL text: a plan is built as nodes and sent as
nodes.

It imports the generated modules `komira.plan.v1`, which the package does not
ship yet, so nothing imports it when `komira` is imported.
"""

from __future__ import annotations

from ._expr import encode_expr
from ._field import expr_field
from ._rel import encode_plan
from ._source import binding_source, parquet_source

__all__ = ["binding_source", "encode_expr", "encode_plan", "expr_field", "parquet_source"]
