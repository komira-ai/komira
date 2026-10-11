# =============================================================================
# test_jsonl_zero_column_rows.mojo -- the JSONL writers on rows with no
# columns
# =============================================================================
#
# Refs #1139. The JSONL reader reads each `{}` line as one row of a
# zero-column schema; the writers wrote nothing for a batch (or row output)
# with rows and no columns, so a write-then-read round trip lost the rows.
# Each writer must write one `{}` line per row, and the bytes must read
# back as the same number of rows.
#
#   * test_batch_writers_write_one_empty_object_per_row -- a 3-row,
#     0-column batch (read from `{}` lines) through `write_batch_jsonl`,
#     `write_batch_jsonl_direct`, `write_batch_jsonl_fused` and
#     `write_batch_jsonl_fused_range` (rows 1..3): `{}\n` per row, and the
#     output infers a zero-column schema and reads back as the same row
#     count. Before the fix each wrote 0 bytes.
#   * test_zero_rows_write_nothing -- a 0-row, 0-column batch still writes
#     nothing through each writer (the early return kept for no rows).
#   * test_row_output_writes_one_empty_object_per_row -- a row output with
#     an empty layout and two blocks of 3 and 2 rows writes five `{}` lines.
# =============================================================================

from std.testing import assert_equal

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_row_format.row_block import RowBlock
from komira_row_format.row_output import RowOutput, RowOutputLayout

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.encode import write_batch_jsonl
from komira_jsonl.json_writer import (
    write_batch_jsonl_direct,
    write_batch_jsonl_fused,
    write_batch_jsonl_fused_range,
    write_row_output_jsonl,
)
from komira_jsonl.schema_inference import infer_jsonl_schema


def _no_fields() -> Schema:
    var sb = SchemaBuilder()
    return sb.build()


def _text(buf: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(buf))


def _empties(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += "{}\n"
    return s^


def _batch(n: Int) raises -> RecordBatch:
    var text = _empties(n)
    var batch = materialize_jsonl_to_batch(text.as_bytes(), _no_fields())
    assert_equal(batch.num_columns(), 0)
    assert_equal(batch.num_rows(), n)
    return batch^


def _rows_read_back(buf: List[UInt8]) raises -> Int:
    var schema = infer_jsonl_schema(Span(buf))
    assert_equal(schema.num_columns(), 0)
    return materialize_jsonl_to_batch(Span(buf), schema^).num_rows()


def _check(buf: List[UInt8], n: Int, what: String) raises:
    assert_equal(_text(buf), _empties(n), what)
    assert_equal(_rows_read_back(buf), n, what + " read back")


def test_batch_writers_write_one_empty_object_per_row() raises:
    var batch = _batch(3)
    var a = List[UInt8]()
    write_batch_jsonl(a, batch)
    _check(a, 3, "write_batch_jsonl")
    var b = List[UInt8]()
    write_batch_jsonl_direct(b, batch)
    _check(b, 3, "write_batch_jsonl_direct")
    var c = List[UInt8]()
    write_batch_jsonl_fused(c, batch)
    _check(c, 3, "write_batch_jsonl_fused")
    var d = List[UInt8]()
    write_batch_jsonl_fused_range(d, batch, 1, 3)
    _check(d, 2, "write_batch_jsonl_fused_range")


def test_zero_rows_write_nothing() raises:
    var batch = _batch(0)
    var a = List[UInt8]()
    write_batch_jsonl(a, batch)
    write_batch_jsonl_direct(a, batch)
    write_batch_jsonl_fused(a, batch)
    write_batch_jsonl_fused_range(a, batch, 0, 0)
    assert_equal(len(a), 0)


def _block(n: Int) raises -> RowBlock:
    var blk = RowBlock.with_capacity(n, 0, 8)
    blk.set_n_rows(n)
    return blk^


def test_row_output_writes_one_empty_object_per_row() raises:
    var blocks = Slab[RowBlock]()
    blocks.append(_block(3))
    blocks.append(_block(2))
    var layout = RowOutputLayout(List[Int](), List[UInt8](), 0, False)
    var ro = RowOutput(blocks^, layout^, _no_fields())
    var buf = List[UInt8]()
    write_row_output_jsonl(buf, ro)
    _check(buf, 5, "write_row_output_jsonl")


def main() raises:
    test_batch_writers_write_one_empty_object_per_row()
    test_zero_rows_write_nothing()
    test_row_output_writes_one_empty_object_per_row()
    print("test_jsonl_zero_column_rows: all passed")
