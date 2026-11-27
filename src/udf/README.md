# `udf`

The trait surface a library user writes user-defined functions against, built
on `arrow` and `plan_expr`.

- Schema descriptors: `schema_descriptor`, `schema_auto`, `auto_komira_schema`,
  `udf_descriptor`.
- Function traits: `agg_fn`, `map_fn`, `map_fn_rt`, `filter_fn`, `window_fn`,
  `row_udf`, `scalar_udf`, `expr_scalar_fn`, with `window_frame_spec`,
  `frame_view`, `partition_row_view` and `partition_local_map_fn`.
- Shared leaves: `purity`, `predicate`, `row_transform`, `column_resolver`,
  `row_builder`, `stateful_contract`.
- `float_quotient_order`: the float equality and ordering model; it is
  to move to `column_kernels`.

There are no root re-exports; import each name from its module.

## Examples

A `ColumnResolver` turns a column name into its physical index and types once,
when a pipeline is bound. A name that is not in the file's schema raises and
lists what is there:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from udf.column_resolver import ColumnResolver

var sb = SchemaBuilder()
sb.add_field(Field(String("id"), ArrowType.INT64, False))
sb.add_field(Field(String("price"), ArrowType.FLOAT64, False))
sb.add_field(Field(String("label"), ArrowType.STRING, False))
var schema = sb.build()

var resolver = ColumnResolver.from_arrow_schema(schema)
assert_equal(resolver.len(), 3)
assert_equal(resolver.index_for(String("price")), 1)
assert_true(resolver.dtype_for(String("price")) == DType.float64)
assert_true(resolver.arrow_type_for(String("label")) == ArrowType.STRING)
assert_true(resolver.has(String("id")))
assert_false(resolver.has(String("missing")))

var raised = False
var message = String("")
try:
    _ = resolver.index_for(String("missing"))
except e:
    raised = True
    message = String(e)
assert_true(raised)
assert_true(String("missing") in message)
assert_true(String("label") in message)
```

`Purity` tells the optimizer how far a UDF may be pushed down or folded, and a
`UdfDescriptor` carries the metadata kept beside a scalar UDF:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from udf.purity import Purity
from udf.udf_descriptor import UdfDescriptor

assert_true(Purity.PURE.is_pure())
assert_true(Purity.PURE.is_pushable())
assert_true(Purity.STATELESS.is_pushable())
assert_false(Purity.STATELESS.is_pure())
assert_false(Purity.STATEFUL.is_pushable())
assert_true(Purity.PURE != Purity.STATEFUL)
assert_equal(Int(Purity.STATELESS.tag()), 1)

var descriptor = UdfDescriptor(String("my_udf"))
assert_equal(descriptor.name, String("my_udf"))
assert_false(descriptor.preserves_ordering)
var restricted = False
if descriptor.input_columns:
    restricted = True
assert_false(restricted)

var columns = List[Int]()
columns.append(2)
descriptor.input_columns = columns^
if descriptor.input_columns:
    restricted = True
assert_true(restricted)
assert_equal(descriptor.input_columns.value()[0], 2)
```
