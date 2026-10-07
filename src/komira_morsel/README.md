# komira_morsel

The morsel layer of the query engine. A `Morsel` is a chunk of rows (a
`komira_arrow` `RecordBatch` with a morsel id and a partition id) that one
worker processes at a time; `split_record_batch` cuts a batch into a
`MorselArray` of morsels of at most a given number of rows, sharing the
column buffers instead of copying them where it can, and `split_into_views`
does the same as row ranges over one batch.

The package also holds what the scheduler side and the operator side of the
engine both need:

- the traits a source, an operator and a sink implement (`morsel_source`,
  `morsel_operator`, `morsel_sink`), the execution context a sink's combine
  step receives (`pipeline_execution`), a type-erased source
  (`vtable_source`) and the streaming source and sink contracts;
- resolution of a plan's scan bindings to sources (`scan_binding_resolve_pass`,
  `scan_morsel_resolver`, `scan_resolver_c_box`);
- filter kernels that run on morsels: fused filters (`fused_filter`), the
  dynamic join filter a hash join's build side publishes to its probe side
  (`dynamic_join_filter`), its range, in-list and bloom masks over `INT64`
  keys (`bloom_mask`), and the shared top-N cut-off that lets a scan skip row
  groups that cannot reach the result (`topn_boundary`).

The package root re-exports nothing; import from the modules. It does not
schedule work or run a query itself.

## Examples

Split a 10-row batch into morsels of at most 4 rows:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_morsel.morsel import split_record_batch

var values = List[Scalar[DType.int64]]()
for i in range(10):
    values.append(Scalar[DType.int64](i * 10))
var sb = SchemaBuilder()
sb.add_field(Field("x", ArrowType.INT64, False))
var batch = RecordBatch.from_typed_columns_1(
    sb.build(), Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(values^))
)

var morsels = split_record_batch(batch^, 4)
assert_equal(len(morsels), 3)
assert_equal(morsels.num_rows_at(0), 4)
assert_equal(morsels.num_rows_at(1), 4)
assert_equal(morsels.num_rows_at(2), 2)
assert_equal(morsels.total_rows(), 10)
assert_equal(morsels[2].num_columns(), 1)
```

Masks a hash join's probe side computes from its build side's keys, and the
top-N cut-off:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_dynamic_filter.in_list_filter import InListFilter
from komira_dynamic_filter.range_filter import RangeFilter
from komira_morsel.bloom_mask import in_list_mask_int64, range_mask_int64
from komira_morsel.topn_boundary import TopNBoundary

var probe = List[Scalar[DType.int64]]()
for v in [5, 20, 35, 50, 65]:
    probe.append(Scalar[DType.int64](v))
var keys = PrimitiveArray[DType.int64].from_list(probe^)

# The build side's keys all lie in [10, 50].
var in_range = range_mask_int64(keys, RangeFilter.new_int64(10, 50))
assert_equal(in_range.true_count(), 3)
assert_true(not in_range.get(0))
assert_true(in_range.get(3))  # 50: the bounds are inclusive

# The build side had exactly the keys {20, 65}.
var build_keys: List[Int64] = [20, 65]
var listed = InListFilter.try_from_int64(build_keys)
var in_list = in_list_mask_int64(keys, listed.take())
assert_equal(in_list.true_count(), 2)
assert_true(in_list.get(1))
assert_true(in_list.get(4))

# ORDER BY key ASC LIMIT n: once a worker holds n rows with keys <= 40, a row
# group whose keys are all above 40 cannot reach the result.
var boundary = TopNBoundary.new(descending=False)
assert_true(not boundary.prunes_range(100, 200))  # nothing published yet
var shared = boundary.clone()
shared.publish(40)
assert_equal(boundary.load(), 40)  # every clone sees it
assert_true(boundary.prunes_range(41, 90))
assert_true(not boundary.prunes_range(40, 90))  # a key equal to the cut-off survives
shared.publish(70)  # looser: ignored
assert_equal(boundary.load(), 40)
```
