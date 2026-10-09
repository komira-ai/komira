"""The pandas door's plans, built in Mojo with `komira_plan_ir`.

Each function here builds the `LogicalPlan` that one committed fixture
(`fixtures/<stem>.txtpb`) describes, through the same factories the decoder
uses. A pandas-shaped frontend emits these shapes:

- `df.sort_values("amount", na_position=...)`: one SORT over the scan, one key
  ascending, `nulls_first` true for `"first"` and false for `"last"`.
- `orders.merge(customers, on="cust_id", how=...)`: one JOIN of the two scans,
  `left_on` and `right_on` both `cust_id`, algorithm AUTO, no residual; the
  right side's colliding `cust_id` arrives as `cust_id_right`.
- `df.groupby("cust_id").size()`: COUNT with no input column (`count(*)`),
  output `size`. `df.groupby("cust_id").agg(n=("amount", "count"))`: COUNT of
  the column `amount`, output `n`. Both are an AGGREGATE under a SORT on the
  group key (ascending, nulls first), since a pandas `groupby` sorts its keys by
  default.
- `df.groupby("cust_id", sort=...).agg({"amount": "sum"})`: SUM of
  `amount`, output `amount`, under the same SORT on the group key when
  `sort=True` (pandas' default) and with no SORT when `sort=False`. These two
  are the pandas half of the cross-door check (`polars_plans` is the other).
  The `sort=False` plan equals polars' `group_by` only because the key
  `cust_id` is non-nullable (`orders_schema`): pandas' default `dropna=True`
  drops a null group that polars keeps.
- `read_csv(path)`: one SCAN whose source is the `komira.csv` binding the
  engine stamps, with `source_kind` left UNSET: the decoded scan takes ROW
  from the kind's declared orientation.

The parquet leaves carry what a frontend reads from a file's footer: path,
schema, mtime and row count, on the local filesystem.
"""

from std.memory import OwnedPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    JOIN_ALGO_AUTO,
    LogicalPlan,
    SOURCE_KIND_COLUMNAR,
    SOURCE_KIND_UNSET,
)
from komira_scan_source.csv_source import CsvSource
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant

comptime DOOR_MTIME_NS: UInt64 = 1234567890
"""The mtime every fixture's leaf carries (the parquet `mtime_ns` and the CSV
snapshot token)."""

comptime DOOR_CSV_PATH: String = "/tmp/golden_csv_fp.csv"
"""The CSV fixture's path. With `DOOR_MTIME_NS` and the default dialect it is
the input `komira_plan_ir`'s CSV arm test pins `CsvSource.fingerprint()` for,
so the fixture's fingerprint is that independently derived literal, not this
package's output."""

comptime DOOR_CSV_FINGERPRINT: UInt64 = 15403575544779683767
"""`CsvSource.fingerprint()` for (`DOOR_CSV_PATH`, `DOOR_MTIME_NS`, quote style
0, `,`, header), as `test_scan_binding_csv_arm.mojo` pins it."""

comptime DOOR_CSV_KIND_ID: UInt32 = 2103513342
"""`scan_kind_id("komira.csv")`, as the same test pins it."""


def orders_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("order_id", ArrowType.INT64, False))
    sb.add_field(Field("cust_id", ArrowType.INT64, False))
    sb.add_field(Field("amount", ArrowType.FLOAT64, True))
    sb.add_field(Field("city", ArrowType.STRING, True))
    return sb.build()


def customers_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("cust_id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, True))
    return sb.build()


def csv_schema() -> Schema:
    """What the engine infers for the CSV file: every column nullable."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("label", ArrowType.STRING, True))
    sb.add_field(Field("score", ArrowType.FLOAT64, True))
    return sb.build()


def _parquet_scan(
    path: String, var schema: Schema, row_count: Int
) raises -> LogicalPlan:
    var src = ParquetSource(
        String(path), schema.copy(), None, mtime_ns=DOOR_MTIME_NS
    )
    return LogicalPlan.scan_from_source(
        SourceVariant(src^),
        schema^,
        None,
        None,
        Optional(row_count),
        None,
        SOURCE_KIND_COLUMNAR,
    )


def orders_scan() raises -> LogicalPlan:
    return _parquet_scan(String("/data/orders.parquet"), orders_schema(), 6)


def customers_scan() raises -> LogicalPlan:
    return _parquet_scan(
        String("/data/customers.parquet"), customers_schema(), 3
    )


def sort_values_plan(na_first: Bool) raises -> LogicalPlan:
    """`orders.sort_values("amount", na_position="first" | "last")`."""
    var keys: List[String] = [String("amount")]
    var desc: List[Bool] = [False]
    var nf: List[Bool] = [na_first]
    return LogicalPlan.sort(keys^, desc^, orders_scan(), Optional(nf^))


def merge_plan(join_type: UInt8) raises -> LogicalPlan:
    """`orders.merge(customers, on="cust_id", how=...)`."""
    var lo: List[String] = [String("cust_id")]
    var ro: List[String] = [String("cust_id")]
    return LogicalPlan.join(
        orders_scan(), customers_scan(), lo^, ro^, join_type, JOIN_ALGO_AUTO
    )


def _grouped_count(
    var column: Optional[Expr], output: String
) raises -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("cust_id"))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_COUNT, column^, Optional(String(output))))
    var agg = LogicalPlan.aggregate(gb^, ax^, orders_scan())
    var keys: List[String] = [String("cust_id")]
    var desc: List[Bool] = [False]
    var nf: List[Bool] = [True]
    return LogicalPlan.sort(keys^, desc^, agg^, Optional(nf^))


def groupby_size_plan() raises -> LogicalPlan:
    """`orders.groupby("cust_id").size()`: `count(*)`, output `size`."""
    return _grouped_count(None, String("size"))


def groupby_count_col_plan() raises -> LogicalPlan:
    """`orders.groupby("cust_id").agg(n=("amount", "count"))`: `count(amount)`,
    output `n`."""
    return _grouped_count(Optional(Expr.col_ref("amount")), String("n"))


def groupby_sum_plan(sort: Bool) raises -> LogicalPlan:
    """`orders.groupby("cust_id", sort=sort).agg({"amount": "sum"})`: the
    dict form keeps the input column's name as the output's."""
    var keys = ExprArray()
    keys.append(Expr.col_ref("cust_id"))
    var sums = AggExprArray()
    sums.append(
        AggExpr(
            AGG_SUM,
            Optional(Expr.col_ref("amount")),
            Optional(String("amount")),
        )
    )
    var agg = LogicalPlan.aggregate(keys^, sums^, orders_scan())
    if not sort:
        return agg^
    var sort_keys: List[String] = [String("cust_id")]
    var desc: List[Bool] = [False]
    var nf: List[Bool] = [True]
    return LogicalPlan.sort(sort_keys^, desc^, agg^, Optional(nf^))


def read_csv_plan() raises -> LogicalPlan:
    """`read_csv(path)`: the `komira.csv` binding, default dialect."""
    var csv = CsvSource(String(DOOR_CSV_PATH), csv_schema(), DOOR_MTIME_NS)
    return LogicalPlan.scan_from_source(
        SourceVariant(csv^), csv_schema(), source_kind=SOURCE_KIND_UNSET
    )
