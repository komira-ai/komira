"""The polars door's plans, built in Mojo.

Each function here builds the `LogicalPlan` that one committed fixture
(`fixtures/polars_<stem>.txtpb`) describes, in the shapes a polars-shaped
frontend emits for polars 1.44.2. The plan nodes come from `komira_plan_ir`'s
factories, the ones the decoder uses. The expressions that this repository's
polars surface already lowers (`is_in`, `sum_horizontal`) come from that
surface (`komira_plan_expr.col_expr`, bound over the input schema by
`col_expr_bind` as a verb binds them), so a fixture that disagrees with the
in-tree lowering fails the comparison.

The shapes:

- `scan_parquet(...).filter(col("qty") > 2).with_columns((col("price") *
  col("qty")).alias("revenue")).group_by("region").agg(col("revenue").sum())
  .sort("revenue", descending=True).limit(3)`: LIMIT(SORT(AGGREGATE(PROJECT(
  FILTER(SCAN))))). `with_columns` is a PROJECT of every input column, in
  order, with the new column appended. An unaliased `sum` is named after its
  column. `group_by` adds no SORT (polars documents no group order). The sort
  places nulls FIRST, polars' default `nulls_last=False`, on a descending key.
  `limit(3)` is LIMIT 3 at offset 0.
- `filter(col("region").is_in(["north", "west"]))`: `col_expr.is_in`, the OR
  of one `=` per value.
- `with_columns(col("price").sum().over("region").alias("region_total"))`: a
  group broadcast, one PARTITION_BY node: key `region`, no order keys, one
  SUM of `price` over the whole partition (ROWS UNBOUNDED PRECEDING to
  UNBOUNDED FOLLOWING), appended as `region_total`. The engine runs a window
  as this node; `Expr.over` on `col("price").sum()` names the same function,
  column and frame, which the test checks.
- `with_columns(sum_horizontal("price", "discount").alias("gross"))`:
  `col_expr.sum_horizontal`, `coalesce(price, 0.0) + coalesce(discount,
  0.0)`, so a null is skipped and an all-null row is 0 (polars' default
  `ignore_nulls=True`).
- `sort(["region", "price"], descending=[False, True])` and the same with
  `nulls_last=True`: the four null-order cells, nulls first and last on an
  ascending and on a descending key.
- `select(col("price").sum())`: a whole-frame AGGREGATE (no keys) whose one
  output is `price`. `dropped_sum_plan` is the defect this shape guards
  against: the aggregate dropped and the raw column projected.
- `orders.group_by("cust_id").agg(col("amount").sum())`: the polars half of
  the cross-door check (`door_plans.groupby_sum_plan` is the pandas half).
"""

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.col_expr import col, sum_horizontal
from komira_plan_expr.col_expr_bind import bind_unbound_expr
from komira_plan_expr.expr import Expr
from komira_plan_expr.partition_expr import PartitionExpr, PF_SUM
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_KIND_COLUMNAR,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant

from .door_plans import DOOR_MTIME_NS, orders_scan


def sales_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("sale_id", ArrowType.INT64, False))
    sb.add_field(Field("region", ArrowType.STRING, True))
    sb.add_field(Field("qty", ArrowType.INT64, True))
    sb.add_field(Field("price", ArrowType.FLOAT64, True))
    sb.add_field(Field("discount", ArrowType.FLOAT64, True))
    return sb.build()


def sales_scan() raises -> LogicalPlan:
    """`scan_parquet("/data/sales.parquet")`: the footer's schema, mtime and
    row count, on the local file system."""
    var schema = sales_schema()
    var src = ParquetSource(
        String("/data/sales.parquet"), schema.copy(), None,
        mtime_ns=DOOR_MTIME_NS,
    )
    return LogicalPlan.scan_from_source(
        SourceVariant(src^),
        schema^,
        None,
        None,
        Optional(6),
        None,
        SOURCE_KIND_COLUMNAR,
    )


def _passthrough(schema: Schema) raises -> ExprArray:
    """`with_columns`' first half: every input column, in order."""
    var out = ExprArray()
    for i in range(schema.num_columns()):
        out.append(Expr.col_ref(schema.field_name(i)))
    return out^


def _sum_of(column: String) -> AggExpr:
    """`col(column).sum()`, named after its column."""
    return AggExpr(
        AGG_SUM, Optional(Expr.col_ref(column)), Optional(String(column))
    )


def polars_pipeline_plan() raises -> LogicalPlan:
    """scan -> filter -> with_columns -> group_by.agg -> sort -> limit."""
    var filtered = LogicalPlan.filter(col("qty") > 2, sales_scan())
    var exprs = _passthrough(filtered.output_schema)
    exprs.append((col("price") * col("qty")).alias("revenue"))
    var with_revenue = LogicalPlan.project(exprs^, filtered^)
    var keys = ExprArray()
    keys.append(Expr.col_ref("region"))
    var sums = AggExprArray()
    sums.append(_sum_of(String("revenue")))
    var grouped = LogicalPlan.aggregate(keys^, sums^, with_revenue^)
    var sort_keys: List[String] = [String("revenue")]
    var desc: List[Bool] = [True]
    var nf: List[Bool] = [True]
    var ordered = LogicalPlan.sort(
        sort_keys^, desc^, grouped^, Optional(nf^)
    )
    return LogicalPlan.limit(3, ordered^)


def polars_is_in_plan() raises -> LogicalPlan:
    """`filter(col("region").is_in(["north", "west"]))`."""
    var values: List[String] = [String("north"), String("west")]
    return LogicalPlan.filter(col("region").is_in(values), sales_scan())


def polars_agg_over_plan() raises -> LogicalPlan:
    """`with_columns(col("price").sum().over("region").alias(...))`."""
    var keys: List[String] = [String("region")]
    var fns = List[PartitionExpr]()
    fns.append(
        PartitionExpr.agg_with_frame(
            PF_SUM, String("price"), PartitionFrame.default_unordered()
        ).with_alias(String("region_total"))
    )
    return LogicalPlan.partition_by(
        keys^, List[String](), List[Bool](), fns^, sales_scan()
    )


def polars_sum_horizontal_plan() raises -> LogicalPlan:
    """`with_columns(sum_horizontal("price", "discount").alias("gross"))`,
    bound over the scan's schema as the verb binds it (the zero becomes 0.0
    beside a float64 column)."""
    var scan = sales_scan()
    var exprs = _passthrough(scan.output_schema)
    var gross = sum_horizontal(col("price"), col("discount")).alias("gross")
    exprs.append(bind_unbound_expr(gross, scan.output_schema, True))
    return LogicalPlan.project(exprs^, scan^)


def polars_sort_plan(nulls_last: Bool) raises -> LogicalPlan:
    """`sort(["region", "price"], descending=[False, True],
    nulls_last=nulls_last)`: `nulls_first` is `not nulls_last` on each key,
    whatever its direction."""
    var keys: List[String] = [String("region"), String("price")]
    var desc: List[Bool] = [False, True]
    var nf: List[Bool] = [not nulls_last, not nulls_last]
    return LogicalPlan.sort(keys^, desc^, sales_scan(), Optional(nf^))


def polars_select_sum_plan() raises -> LogicalPlan:
    """`select(col("price").sum())`: one row, one column `price`."""
    var sums = AggExprArray()
    sums.append(_sum_of(String("price")))
    return LogicalPlan.aggregate(ExprArray(), sums^, sales_scan())


def dropped_sum_plan() raises -> LogicalPlan:
    """The defect `polars_select_sum_plan` guards against: `select` that
    kept the column and dropped its aggregate (one row per input row)."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("price"))
    return LogicalPlan.project(exprs^, sales_scan())


def polars_group_by_sum_plan() raises -> LogicalPlan:
    """`orders.group_by("cust_id").agg(col("amount").sum())`."""
    var sums = AggExprArray()
    sums.append(_sum_of(String("amount")))
    var keys = ExprArray()
    keys.append(Expr.col_ref("cust_id"))
    return LogicalPlan.aggregate(keys^, sums^, orders_scan())
