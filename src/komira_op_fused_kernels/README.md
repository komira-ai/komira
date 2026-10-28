# komira_op_fused_kernels

INNER join kernels that fuse a probe with its output. The
package root re-exports nothing; import from the modules.

- `komira_op_fused_kernels.parallel_inner_probe`:
  `parallel_inner_join_probe_into` and `parallel_perfect_inner_probe_into`,
  the single-INT64-key INNER probes of a `HashJoinBuilder` and of a
  `PerfectHashJoin` (both from `komira_op_join_build`) forked over the
  engine's dispatcher. The probe rows are split into morsels sized from the
  pool's worker count; each worker appends (build row, probe row) pairs to its
  own lists, which are then appended to the caller's. The pairs are the serial
  probe's, in a different order; a NULL probe key matches nothing. They read the first `num_probe_rows` keys (more than the array holds
  raises); with one morsel they call the serial probe on those keys.
- `komira_op_fused_kernels.parallel_gate`: `should_parallelize`, true from
  `PARALLEL_THRESHOLD_ROWS` (100,000) rows when the pool it would fork over has
  more than one worker.
- `komira_op_fused_kernels.join_fused_gather`: `assemble_inner_join_fused`
  (every column of both sides) and `assemble_inner_join_fused_projected` (the
  named columns, either side as the build side), which walk the chains and
  write each output row as it is found, with no index lists and no second
  pass. A kernel raises when an output type's byte width differs from its
  source column's,. With no names the projected kernel returns the match count alone
  (`RecordBatch.count_only`).
- `komira_op_fused_kernels.join_chunked_gather`:
  `assemble_inner_join_chunked`, the same output as
  `assemble_inner_join_fused`, made by flattening the chains, probing into
  chunks of 65,536 index pairs and gathering each output column per chunk;
  for joins whose output is many times their input.
- `komira_op_fused_kernels.join_fused_route`: which inputs those three
  kernels carry. They copy fixed-width cells and emit no validity bitmap, so
  an offsets or dictionary column, a BOOL column, or a column holding a NULL
  goes to the per-column gather of `komira_join_assembly` instead:
  `fused_join_cannot_carry_output` (for a projection) and
  `fused_join_cannot_carry_batches` (for every column) say so, and each kernel
  raises on a NULL it is handed (`require_null_free_column`).

## Examples

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_probe_null_mask import ProbeNullMask
from komira_op_fused_kernels.join_fused_gather import assemble_inner_join_fused_projected
from komira_op_fused_kernels.join_fused_route import fused_join_cannot_carry_output
from komira_op_fused_kernels.parallel_gate import should_parallelize

# orders(id, qty) joined to items(id, price) on id, selecting (qty, price).
var oid: List[Int64] = [1, 2, 2, 3]
var qty: List[Int64] = [10, 20, 30, 40]
var iid: List[Int64] = [2, 3]
var price: List[Int64] = [500, 700]
var ob = RecordBatchBuilder()
ob.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(oid)))
ob.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(qty)))
var os = SchemaBuilder()
os.add_field(Field("id", ArrowType.INT64, False))
os.add_field(Field("qty", ArrowType.INT64, False))
var orders = ob.build(os.build())
var ib = RecordBatchBuilder()
ib.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(iid)))
ib.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(price)))
var isb = SchemaBuilder()
isb.add_field(Field("id", ArrowType.INT64, False))
isb.add_field(Field("price", ArrowType.INT64, False))
var items = ib.build(isb.build())

var names: List[String] = ["qty", "price"]
# Fixed-width and NULL-free: the fused kernel can carry these columns.
assert_false(fused_join_cannot_carry_output(orders, items, names))
var probe = PrimitiveArray[DType.int64].from_list(oid)
var table = HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list(iid))
var joined = assemble_inner_join_fused_projected(
    orders, items, table, probe, names, orders, items, True,
    ProbeNullMask(probe, probe.length),
)
assert_equal(joined.num_rows(), 3)  # order 1 has no item
assert_equal(Int(joined.column_value(0, 0)), 20)
assert_equal(Int(joined.column_value(1, 0)), 500)
assert_equal(Int(joined.column_value(1, 2)), 700)
assert_false(should_parallelize(joined.num_rows(), 4))
```
