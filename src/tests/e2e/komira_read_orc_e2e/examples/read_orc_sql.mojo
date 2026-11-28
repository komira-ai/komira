from std.testing import assert_equal, assert_false

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from orc import ORC_COMPRESSION_ZSTD, OrcWriterOptions, write_orc_file
from runtime_paths import test_tmpdir
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql


def main() raises:
    # A small ORC file: columns a (BIGINT) and b (VARCHAR), zstd-compressed.
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.STRING, True))
    var a: List[Int64] = [1, 2, 3, 4, 5]
    var b: List[String] = ["one", "two", "three", "four", "five"]
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(a)))
    builder.add_column(Column.from_string(StringArray.from_strings(b)))
    var path = test_tmpdir() + "/data.orc"
    write_orc_file(builder.build(sb.build()), path, OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, "UTC"))

    # read_orc binds the file's columns from its footer; the query reads it.
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var outcome = run_sql(ctx, "SELECT a, b FROM read_orc('" + path + "') WHERE a > 3 ORDER BY a")
    assert_false(Bool(outcome.refusal))
    var rows = outcome.batches.pop()
    assert_equal(rows.num_rows(), 2)
    assert_equal(rows.column_as_primitive_int64(0).get(0), 4)
    assert_equal(rows.column_as_string(1).get(0), "four")
    assert_equal(rows.column_as_primitive_int64(0).get(1), 5)
    assert_equal(rows.column_as_string(1).get(1), "five")
