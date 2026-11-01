# komira_join_assembly

Join result assembly: gather-index planning, chunked parallel gather, join-key common-subexpression, the payload-inline chain-entry gate.

A hash join's probe produces matched row pairs as two index lists, one into
the left (probe) batch and one into the right (build) batch. This package
turns them into the output `RecordBatch`: `assemble_join_result` (in
`komira_join_assembly.compiler_join_assembly`) gathers every left column at
`left_indices`, then every right column at `right_indices`, naming and
typing them from the output schema. On an outer side an index of `-1`
stands for "no match" and gathers a null row. `assemble_join_result`
gathers serially; `assemble_join_result_dispatch` takes a `ParallelDispatch`
and gathers large outputs in parallel chunks.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Assembling an inner and a left join

```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_join_assembly.compiler_join_assembly import assemble_join_result
from std.testing import assert_equal, assert_false, assert_true

# Orders (the probe side): order id and product id.
var order_ids: List[Int64] = [100, 101, 102, 103]
var order_products: List[Int64] = [2, 1, 9, 2]
var orders = RecordBatch.from_typed_columns_2(
    Schema.from_fields_2(
        Field("order_id", DType.int64, False),
        Field("product_id", DType.int64, False),
    ),
    Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(order_ids)),
    Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(order_products)),
)

# Products (the build side): product id and name. Product 9 does not exist.
var product_ids: List[Int64] = [1, 2]
var product_names: List[String] = ["bolt", "nut"]
var products = RecordBatch.from_typed_columns_2(
    Schema.from_fields_2(
        Field("product_id", DType.int64, False),
        Field("name", ArrowType.STRING, False),
    ),
    Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(product_ids)),
    Column.from_string(StringArray.from_strings(product_names)),
)

# The output: the left columns, then the right ones (nullable, for the
# left join below).
var sb = SchemaBuilder()
sb.add_field(Field("order_id", DType.int64, False))
sb.add_field(Field("product_id", DType.int64, False))
sb.add_field(Field("product_id_right", DType.int64, True))
sb.add_field(Field("name", ArrowType.STRING, True))
var out_schema = sb.build()

# Inner join on product_id: order rows 0, 1 and 3 match product rows 1, 0
# and 1; order row 2 (product 9) matches nothing and is left out.
var left_rows: List[Int] = [0, 1, 3]
var right_rows: List[Int] = [1, 0, 1]
var inner = assemble_join_result(orders, products, left_rows, right_rows, out_schema)
assert_equal(inner.num_rows(), 3)
assert_equal(inner.num_columns(), 4)
assert_equal(inner.schema.field_name(2), "product_id_right")
var inner_orders = inner.column_at(0).as_primitive[DType.int64]()
var inner_keys = inner.column_at(2).as_primitive[DType.int64]()
var inner_names = inner.column_at(3).as_string()
assert_equal(inner_orders.get(0), Int64(100))
assert_equal(inner_keys.get(0), Int64(2))
assert_equal(inner_names.get(0), "nut")
assert_equal(inner_orders.get(1), Int64(101))
assert_equal(inner_names.get(1), "bolt")
assert_equal(inner_orders.get(2), Int64(103))
assert_equal(inner_names.get(2), "nut")

# Left join: every order is kept; order 102's right index is -1, so its
# right columns are null.
var all_orders: List[Int] = [0, 1, 2, 3]
var matches: List[Int] = [1, 0, -1, 1]
var left_join = assemble_join_result(
    orders, products, all_orders, matches, out_schema, right_nullable=True
)
assert_equal(left_join.num_rows(), 4)
assert_equal(left_join.column_at(0).as_primitive[DType.int64]().get(2), Int64(102))
assert_false(left_join.column_at(3).is_null_at(1))
assert_true(left_join.column_at(3).is_null_at(2))
assert_equal(left_join.column_at(3).null_count(), 1)
assert_equal(left_join.column_at(2).null_count(), 1)
```
