# dispatch_sources

Source support for the engine dispatcher: the typed in-memory source and its scan plan builders, the bare multi-batch in-memory scan fold, the row gate of the resident-filter fan-out, the leaf-servability pre-gates, and the column-parallel concat re-exported.

## Example

The package exports nothing from its root, so the example imports the gate module directly. It builds a three-row batch with an integer column `k` and a string column `name`, then asks whether a predicate reads a variable-width column and whether the resident-filter fan-out would admit the batch.

```mojo module
from std.testing import assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import SchemaBuilder, Field
from arrow.string_array import StringArray
from plan_expr.expr import Expr, BIN_GT, STR_LIKE
from plan_expr.scalar_value import ScalarValue

from dispatch_sources.inmem_filter_varlen_gate import (
    inmem_filter_rows_admit_fanout,
    predicate_reads_varlen_column,
)


def make_batch(n: Int) raises -> RecordBatch:
    var names = List[String](capacity=n)
    var keys = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        names.append(String("x"))
        keys.store[1](i, SIMD[DType.int64, 1](Int64(i)))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("name"), ArrowType.STRING, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](keys))
    rbb.add_column(Column.from_string(StringArray.from_strings(names)))
    return rbb.build(sb.build())


def main() raises:
    var batch = make_batch(3)
    var like = Expr.string_op(
        STR_LIKE, Expr.col_ref(String("name")), String("%green%")
    )
    var gt = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("k")),
        Expr.literal(ScalarValue.from_int64(Int64(10))),
    )
    assert_true(predicate_reads_varlen_column(batch, like))
    assert_false(predicate_reads_varlen_column(batch, gt))
    # At or above the caller's floor a batch is admitted; far below the
    # varlen floor of 65,536 rows it is not.
    assert_true(inmem_filter_rows_admit_fanout(batch, gt, 3))
    assert_false(inmem_filter_rows_admit_fanout(batch, like, 1000))
```
