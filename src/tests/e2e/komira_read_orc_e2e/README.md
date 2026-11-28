# komira_read_orc_e2e

Test-only. `read_orc('path')` through `run_sql` over local ORC files, read by
value. Nothing depends on this package.

## Reading an ORC file in SQL

`read_orc('path')` reads one local ORC file, of any ORC codec, as a table:
the binder reads the file's columns from its footer, and the query decodes
only the columns it uses. It takes no option, as in DuckDB's `orc` extension.
This program writes a small file and queries it:

<!-- include examples/read_orc_sql.mojo -->
```mojo
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
```

The columns it reads are BOOLEAN, TINYINT, SMALLINT, INTEGER, BIGINT, FLOAT,
DOUBLE, VARCHAR (ORC `string`, `varchar` and `char`) and DATE. Refused by
name, at bind: a column of any other type (struct, list, map, union,
timestamp, decimal, binary), a glob pattern (`read_orc('*.orc')`), any option,
and a file that is missing or is not ORC.

## The tests

`tests/test_read_orc_sql.mojo` reads the six files pyarrow's ORC C++ writer
wrote (kept in `komira_formats_e2e` beside the script that generated them)
through `run_sql` and checks every value and NULL against the generator's
rules: each codec, three stripes, a projection in query order, filters,
`count(*)`, a grouped aggregate, the other column types (a file it writes),
and each refusal. The BUCK file lists what each test proves.
