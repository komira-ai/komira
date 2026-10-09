# komira_jsonl

JSON Lines (one JSON object per line) to and from Arrow record batches
(`komira_arrow`), for the engine's JSON scan and its JSON writers.

- **Schema inference.** `infer_jsonl_schema(bytes)` reads every line once and
  returns one nullable field per key, in first-seen order, typed by a lattice
  (int64 and float64 promote to float64; a key seen only as `null` is
  `NULL`). A nested object or array is refused by inference: to read list,
  struct or map columns, pass an explicit schema. `infer_jsonl_schema_parallel`
  does the same over partitions.
- **Reading.** `komira_jsonl.columnar_materializer.materialize_jsonl_to_batch(bytes,
  schema)` builds a `RecordBatch` for the schema. The input is validated whole
  before any row is built: every line must be blank (skipped) or one JSON object
  (RFC 8259), and an error names the line (`komira_jsonl: line N: ...`). A key
  the schema reads may appear once per object; keys the schema does not read
  are skipped. A JSON `null` reads NULL inside a nested value too: a list
  element, a struct member (and a member missing from its object), a map
  value. A list, struct or map column refuses a number or literal other than
  `null`. A DECIMAL128 column reads a JSON number or a string, an exponent
  included (`1e2`), truncating digits past its scale. The parallel and streaming readers (`read_jsonl_streamed_to_batches`)
  treat a newline inside a JSON string as part of the string, not a line end.
- **Writing.** `komira_jsonl.json_writer` writes a batch as JSON Lines
  (`write_batch_jsonl_direct`, `write_batch_jsonl_fused`) or as a pretty JSON
  array (`write_batch_json_pretty`), with the cell writers (`write_i64_dec`,
  `write_f64_dtoa`, `write_string_escaped`, `write_date32`, ...) on their own.
  `write_f64_dtoa` writes a non-finite float as `null`, and so do the batch
  and row writers in a nullable column; NaN or +-Inf in a non-nullable column
  is refused with an error that names the column, the row and the value.
- **Records.** `JsonCompatible` is the trait a struct implements to be one JSON
  object (`to_json`, `from_json`); `write_record` appends one as a line and
  `parse_record` reads one back.

The SIMD structural index and the `json_extract` kernel are in
`komira_json_index`, not here.

## Examples

Infer a schema, then read the lines into columns:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_jsonl import infer_jsonl_schema
from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch

var text = String(
    '{"id":1,"price":9,"name":"pen","ok":true}\n'
    '{"id":2,"price":2.5,"name":"ink","ok":false}\n'
    '\n'
    '{"id":3,"price":4,"name":null,"ok":true}\n'
)
var schema = infer_jsonl_schema(text.as_bytes())
assert_equal(schema.num_columns(), 4)
assert_equal(String(schema.field_name(1)), "price")
assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
assert_true(schema.field_arrow_type(1) == ArrowType.FLOAT64)  # 9 and 2.5 promote
assert_true(schema.field_arrow_type(2) == ArrowType.STRING)
assert_true(schema.field_arrow_type(3) == ArrowType.BOOL)

var batch = materialize_jsonl_to_batch(text.as_bytes(), schema^)
assert_equal(batch.num_rows(), 3)  # the blank line is skipped
ref prices = batch.column_at(1)
assert_equal(prices.as_primitive[DType.float64]().get(1), 2.5)
ref names = batch.column_at(2)
assert_equal(names.as_string().get(0), "pen")
assert_true(names.as_string().is_null(2))
```

A line that is not one JSON object is refused, naming the line, before any row
is built:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_jsonl import infer_jsonl_schema
from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch

var good = String('{"a":1}\n')
var bad = String('{"a":1}\n{"a":2}\n[3]\n')
var message = String()
try:
    _ = materialize_jsonl_to_batch(bad.as_bytes(), infer_jsonl_schema(good.as_bytes()))
except e:
    message = String(e)
assert_true("line 3:" in message, message)
assert_true("not a JSON object" in message, message)
```

Write a batch back out as JSON Lines, and escape a string cell on its own:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_jsonl import infer_jsonl_schema
from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.json_writer import write_batch_jsonl_direct, write_string_escaped

var text = String('{"id":1,"tag":"a"}\n{"id":2,"tag":null}\n')
var batch = materialize_jsonl_to_batch(text.as_bytes(), infer_jsonl_schema(text.as_bytes()))
var out = List[UInt8]()
write_batch_jsonl_direct(out, batch)
assert_equal(String(unsafe_from_utf8=out), text)

var cell = List[UInt8]()
write_string_escaped(cell, "say \"hi\"\n")
assert_equal(String(unsafe_from_utf8=cell), "\"say \\\"hi\\\"\\n\"")
```
