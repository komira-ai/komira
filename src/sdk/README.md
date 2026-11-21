# sdk

The plan-building half of the Mojo SDK: the pieces a DataFrame-style verb uses
to author a `LogicalPlan` (from `plan_ir`) out of expressions (from
`plan_expr`). Nothing here executes a plan.

This package lands in parts. This part holds the modules below; the carrier
that strings them into verbs, the sinks, and the package facade come later, so
`__init__.mojo` exports nothing yet and you import each module by name.

## Modules

| module | what it holds |
|---|---|
| `agg_output_naming` | the output name of an unaliased aggregate, by polars' rule: the leftmost column of its argument, `len` for `count(*)` (`author_polars_agg_names`, `polars_root_name`, `polars_agg_out_name`) |
| `auto_schema` | `derive_schema[T]()`: a `SchemaDescriptor` derived from a row struct's fields by reflection, and `DerivedSchemaRow`, the trait that gives a row struct that `schema()` |
| `cast_to_varchar_insert` | `insert_cast_if_text_output`: one `PLAN_CAST_TO_VARCHAR` node above the root of a plan whose sink writes text, none when the root already is one or the sink writes Arrow-typed batches |
| `cte_binding` | `CteScope`: statement-scoped CTE name to `LogicalPlan` bindings |
| `parquet_footer` | plan-time Parquet footer reads: `read_parquet_row_count`, and `read_parquet_footer` returning a `ParquetFooterSummary` (row count and Arrow schema) from one light parse of the footer (flat files only: a nested or repeated schema, no schema, or a negative row count is refused), plus cache-backed forms over a `ParquetMetadataCache` (`read_parquet_footer_with_cache`, and `read_parquet_footer_with_cache_via_fs` over any file system; a cache hit never re-checks the file, so a rewritten file is served stale until `invalidate(path)`). No data page is read |
| `parquet_read_options` | `ParquetReadOptions`: union by name, empty globs, Hive partitioning and a read-time partition filter |
| `plan_validator` | `validate_plan` and `validate_plan_report`: column references checked against each node's input schema, with a report of what could not be checked |
| `table_display` | `format_table`: a `RecordBatch` as an ASCII table |
| `select_aggregates` | `select` of aggregates as a one-row aggregate, a column beside an aggregate as a whole-frame window, and the named refusals |
| `filter_refusal` | the named refusal a `filter` carries in the plan when it cannot serve a predicate |
| `join_helpers` | join argument validation and the join plan builder |
| `row_udf_chain` | `RowMapChain`, `RowFilterChain`, `RowChain`: a scan plus row UDFs carried as comptime parameters |
| `dataframe_alias`, `dataframe_concat`, `dataframe_drop_nulls`, `dataframe_rename`, `dataframe_with_columns` | the plan builders of those verbs |

## Deriving a schema from a row struct

A row struct's fields, in declared order, become non-nullable columns:

```mojo module
from std.testing import assert_equal
from sdk.auto_schema import derive_schema
from plan_expr.typed_schema import TYPE_INT64, TYPE_FLOAT64


@fieldwise_init
struct Trade(Copyable, Movable):
    var id: Int64
    var price: Float64


def main() raises:
    var schema = derive_schema[Trade]()
    assert_equal(schema.num_cols(), 2)
    assert_equal(schema.cols[0].name, String("id"))
    assert_equal(schema.cols[0].dtype, TYPE_INT64)
    assert_equal(schema.cols[1].dtype, TYPE_FLOAT64)
```

A struct that conforms to `DerivedSchemaRow` gets the same descriptor from its
`schema()`, with no body of its own:

```mojo module
from std.testing import assert_equal
from sdk.auto_schema import DerivedSchemaRow
from plan_expr.typed_schema import TYPE_STRING


@fieldwise_init
struct Order(DerivedSchemaRow):
    var qty: Int32
    var note: String


def main() raises:
    var order_schema = Order.schema()
    assert_equal(order_schema.num_cols(), 2)
    assert_equal(order_schema.cols[1].name, String("note"))
    assert_equal(order_schema.cols[1].dtype, TYPE_STRING)
```

## Naming an unaliased aggregate

The name is authored into the plan before `LogicalPlan.aggregate` derives its
output schema, so every executor reads the same string. An aggregate of a
column takes the column's name; `count(*)` is `len`:

```mojo
from std.testing import assert_equal
from sdk.agg_output_naming import polars_agg_out_name
from plan_expr.agg_expr import AGG_COUNT, AGG_SUM

assert_equal(polars_agg_out_name(AGG_SUM, True, String("v")), String("v"))
assert_equal(polars_agg_out_name(AGG_COUNT, False, String()), String("len"))
```

## A plan whose sink writes text

A CSV or JSONL sink writes every column as text, so the plan it writes gets
one cast-to-string node at its root; the columns keep their names and
nullability. Applying the rule again, or for a sink that writes Arrow-typed
batches, adds nothing:

```mojo
from std.testing import assert_equal, assert_true
from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_ir.logical_plan import LogicalPlan, PLAN_CAST_TO_VARCHAR, SOURCE_PARQUET
from sdk.cast_to_varchar_insert import insert_cast_if_text_output

var sb = SchemaBuilder()
sb.add_field(Field(String("k"), ArrowType.INT64, False))
var scan = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())
var plan = insert_cast_if_text_output(scan^, True)
assert_true(plan.tag == PLAN_CAST_TO_VARCHAR)
assert_true(plan.output_schema.field_arrow_type(0) == ArrowType.STRING)
assert_equal(plan.output_schema.field_name(0), "k")
var again = insert_cast_if_text_output(plan^, True)
assert_true(again.cast_to_varchar_data_ref().child[].tag != PLAN_CAST_TO_VARCHAR)
```

## Dependencies

`deps` in `BUCK` is the full transitive closure, so it includes the deps of
`udf`, whose row UDF types `row_udf_chain` names.
`op_agg_state` is there for one welded test, which also covers its
statistical accumulators.

`parquet_footer` needs `parquet` (the file reader, the footer parsers
and the footer cache), and directly `fs` and `async_rt`; the
rest of its `deps` are `parquet`'s closure. Its test
builds its Parquet file byte by byte under the test's scratch directory
(`runtime_paths`).
