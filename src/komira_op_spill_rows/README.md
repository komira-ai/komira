# komira_op_spill_rows

The spill of the query engine's two row-format breakers, so that a `GROUP BY`
or an `ORDER BY` over more data than its memory budget finishes instead of
running out of memory, with the same answer it gives without a spill.

- `agg_spill.RowHashAggSpillState` spills a `RowHashAggTable` (from
  `komira_row_format`). After each batch, `maybe_spill_run` writes the table's
  partial groups to disk and empties it when its estimate passes the budget.
  `finalize_with_spill` reads the runs back and folds them into the in-memory
  table by key (`COUNT` and `SUM` add, `MIN` and `MAX` keep the extreme). If the
  folded groups themselves pass the budget, it splits every source by key hash
  into 8 parts and folds each part alone, splitting a part again while it is
  over the budget. `finalize_with_spill_yield` returns the result as up to 8
  batches instead of one. Group order is unspecified, as in SQL.
- `sort_spill.RowSortSpillState` spills a `RowSortBuffer` (INT64 keys and
  payloads). After each batch, `maybe_spill_run` sorts the buffer and writes it
  to disk as one run when its estimate passes the budget.
  `finalize_with_spill` merges the runs and the in-memory remainder by key with
  `komira_op_sort`'s k-way merge. Equal keys keep their input order, so the
  result is row for row the sort without a spill.
- `agg_spill_codec` is the THSPILL2 write and read of a table's packed group
  rows (string keys carry their string heap) and the shell tables a restore
  rebuilds.

Both take the budget in bytes (0 never spills) and the spill directory as
constructor arguments: the caller reads them from its flags. On the first spill
an operator creates its own sub-directory of that directory, named
`thsplc_agg_<pid>_<counter>` or `thsplc_sortrows_<pid>_<counter>` and created
exclusively (a name that exists is skipped, up to 64 tries), so operators and
processes can share one directory. The files are deleted when the finalize
returns or raises and when the state is dropped. `spill_root` makes the name.
The package root re-exports nothing; import from the modules.

## Examples

A sort whose budget is passed by every batch: each batch spills as a run, and
the finalize merges the runs. `spill_dir` is a directory of the caller's.

<!-- mojo-hidden
from std.testing import assert_equal
from komira_libc.posix import _read_env
var spill_dir = _read_env("TEST_TMPDIR") + "/readme_sort_spill"
-->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_row_format.row_block import COL_FIXED, ColDescriptor, DT_I64, RowLayout
from komira_row_format.row_sort import RowSortBuffer, SORT_ASC
from komira_op_spill_rows.sort_spill import RowSortSpillState

def key_batch(a: Int64, b: Int64) raises -> RecordBatch:
    var values: List[Int64] = [a, b]
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)))
    return rbb.build(sb.build())

# One INT64 key and nothing else: 8 bytes per row.
var layout = RowLayout()
layout.add_key_col(ColDescriptor(kind=COL_FIXED, dtype_tag=DT_I64,
                                 fixed_width=UInt16(8), offset_in_row=UInt16(0)))
layout.set_fixed_row_stride(8)
var buffer = RowSortBuffer(8, 8)
buffer.add_key_direction(SORT_ASC)
var key_cols: List[Int] = [0]
var no_cols = List[Int]()
var key_names: List[String] = ["k"]
var no_names = List[String]()
var directions: List[UInt8] = [SORT_ASC]

var spill = RowSortSpillState(1, spill_dir)  # a 1-byte budget
var firsts: List[Int64] = [3, 5, 4]
var seconds: List[Int64] = [1, 0, 2]
for i in range(3):
    var batch = key_batch(firsts[i], seconds[i])
    buffer.feed_batch(BatchView(batch), key_cols, no_cols, layout)
    spill.maybe_spill_run(buffer, layout, key_names, no_names)
assert_equal(spill.num_spilled_runs(), 3)

var merged = spill^.finalize_with_spill(
    buffer, layout, key_names, no_names, directions)
var result = merged.take()
var keys = result.column_as_primitive_int64(0)
for r in range(6):
    assert_equal(keys.load[1](r)[0], Int64(r))
```
