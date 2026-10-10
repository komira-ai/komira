# komira_csv

A CSV reader that materializes an Arrow `RecordBatch` (`komira_arrow`), and a
CSV writer for the engine's sinks.

- **Reading.** `read_csv_bytes_to_batch[Q](bytes, options)` parses a CSV held in
  memory; `read_csv_to_batch(path)` and `read_csv_to_batch_with_options` read a
  file; `read_csv_bytes_to_batch_parallel` splits a large body into row ranges
  only where it can prove the split is outside a quoted field. `Q` is the
  quoting dialect: `Rfc4180` (a doubled quote escapes a quote), `Excel`, or
  `Posix` (backslash escapes).
- **Types.** Each column's type is inferred from the first `infer_rows` rows
  over int64, float64, date32 (`YYYY-MM-DD`), bool and string; widening and
  declared types, per-column date formats, decimals and projection are
  options on `CsvReadOptions`.
- **Defaults** follow pandas: comma delimiter, a header row (without one the
  columns are `col_0`, `col_1`, ...), the cells `""`, `NULL`, `NA`, `NaN`,
  `null` read as null, and `true`, `TRUE`, `T`, `1`, `yes`, `Y` (and `false`,
  `FALSE`, `F`, `0`, `no`, `N`) as booleans. Blank lines are skipped
  (in a one-column file a blank line is a null record).
- **Lower levels.** The byte scanners (`scan_csv_phase1` and SIMD variants
  `..._phase2_movemask`, `..._phase3_pclmulqdq`) return cell ranges without
  building columns; `is_null_cell`, `is_true_cell`, `is_false_cell` classify
  one cell.
- **Writing.** `komira_csv.csv_sink.CsvSink(path, delimiter, header)` writes the
  batches it is given to a file, quoting a cell only when it must.

The reader does not stream: a body is parsed whole into one batch.

## Examples

A small file with a header: each column's type is inferred, a quoted cell may
hold the delimiter, and a doubled quote is one quote:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_csv import CsvReadOptions, Rfc4180, read_csv_bytes_to_batch

var text = String(
    "id,price,day,ok,note\n"
    "1,9.5,2026-09-01,true,\"red, large\"\n"
    "2,12.25,2026-09-02,false,\"say \"\"hi\"\"\"\n"
)
var batch = read_csv_bytes_to_batch[Rfc4180](text.as_bytes(), CsvReadOptions())
assert_equal(batch.num_rows(), 2)
assert_equal(batch.num_columns(), 5)
assert_equal(String(batch.schema.field_at(0).name), "id")
assert_true(batch.schema.field_at(0).arrow_type == ArrowType.INT64)
assert_true(batch.schema.field_at(1).arrow_type == ArrowType.FLOAT64)
assert_true(batch.schema.field_at(2).arrow_type == ArrowType.DATE32)
assert_true(batch.schema.field_at(3).arrow_type == ArrowType.BOOL)
assert_true(batch.schema.field_at(4).arrow_type == ArrowType.STRING)

ref ids = batch.column_at(0)
assert_equal(ids.as_primitive[DType.int64]().get(1), 2)
ref notes = batch.column_at(4)
assert_equal(notes.as_string().get(0), "red, large")
assert_equal(notes.as_string().get(1), "say \"hi\"")
```

Null tokens become Arrow nulls, and a file without a header gets generated
column names:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_csv import CsvReadOptions, Rfc4180, read_csv_bytes_to_batch

var nulls = String("id,name\n1,pen\n,NULL\n3,NA\n")
var batch = read_csv_bytes_to_batch[Rfc4180](nulls.as_bytes(), CsvReadOptions())
ref ids = batch.column_at(0)
ref names = batch.column_at(1)
assert_true(ids.as_primitive[DType.int64]().is_null(1))
assert_true(names.as_string().is_null(1))
assert_true(names.as_string().is_null(2))
assert_equal(names.as_string().get(0), "pen")

var options = CsvReadOptions()
options.has_header = False
var bare = read_csv_bytes_to_batch[Rfc4180](String("1,2,3\n4,5,6\n").as_bytes(), options)
assert_equal(bare.num_rows(), 2)
assert_equal(String(bare.schema.field_at(2).name), "col_2")
```

Projection keeps only the named columns, and the cell classifiers follow the
default token sets:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_csv import CsvReadOptions, Rfc4180, is_null_cell, is_true_cell, read_csv_bytes_to_batch

var options = CsvReadOptions()
assert_true(is_null_cell("NA".as_bytes(), options))
assert_true(not is_null_cell("n/a".as_bytes(), options))
assert_true(is_true_cell("yes".as_bytes(), options))
assert_true(not is_true_cell("on".as_bytes(), options))

options.with_projection("b")
var batch = read_csv_bytes_to_batch[Rfc4180](String("a,b\n1,2\n\n3,4\n").as_bytes(), options)
assert_equal(batch.num_columns(), 1)
assert_equal(batch.num_rows(), 2)  # the blank line is skipped
ref b = batch.column_at(0)
assert_equal(b.as_primitive[DType.int64]().get(1), 4)
```
