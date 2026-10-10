# komira_sdk

The plan-building half of the Mojo SDK: the pieces a DataFrame-style verb uses
to author a `LogicalPlan` (from `komira_plan_ir`) out of expressions (from
`komira_plan_expr`). Nothing here executes a plan.

This package lands in parts. This part holds the modules below; the carrier
that strings them into verbs, the sinks, and the package facade come later, so
`__init__.mojo` exports nothing yet and you import each module by name.

## Modules

| module | what it holds |
|---|---|
| `agg_output_naming` | the output name of an unaliased aggregate, by polars' rule: the leftmost column of its argument, `len` for `count(*)` (`author_polars_agg_names`, `polars_root_name`, `polars_agg_out_name`) |
| `auto_schema` | `derive_schema[T]()`: a `SchemaDescriptor` derived from a row struct's fields by reflection, and `DerivedSchemaRow`, the trait that gives a row struct that `schema()` |
| `cte_binding` | `CteScope`: statement-scoped CTE name to `LogicalPlan` bindings |
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
from komira_sdk.auto_schema import derive_schema
from komira_plan_expr.typed_schema import TYPE_INT64, TYPE_FLOAT64


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
from komira_sdk.auto_schema import DerivedSchemaRow
from komira_plan_expr.typed_schema import TYPE_STRING


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
from komira_sdk.agg_output_naming import polars_agg_out_name
from komira_plan_expr.agg_expr import AGG_COUNT, AGG_SUM

assert_equal(polars_agg_out_name(AGG_SUM, True, String("v")), String("v"))
assert_equal(polars_agg_out_name(AGG_COUNT, False, String()), String("len"))
```

## Dependencies

`deps` in `BUCK` is the full transitive closure, so it includes the deps of
`komira_udf`, whose row UDF types `row_udf_chain` names.
`komira_op_agg_state` is there for one welded test, which also covers its
statistical accumulators.
