# orc

Apache ORC v1 files to and from Arrow record batches (`arrow`).

- **Reading.** `read_orc_bytes` and `read_orc_file` decode a whole file into
  one `RecordBatch`: primitive, decimal, date, timestamp, and nested struct,
  list, map and union columns, over every stripe. `read_orc_bytes_projected`
  decodes only the listed top-level columns. Hive ACID files show their `row`
  columns by default; `read_orc_bytes_opts(bytes, with_acid_columns=True)`
  keeps the ACID metadata columns too. `read_orc_bytes_schema` gives the
  schema `read_orc_bytes` would return, from the footer alone (no stripe is
  read), and `read_orc_tail` the PostScript and Footer of a file of any codec.
  SQL reads a file with `read_orc('path')` (the README of the repository's
  `src/tests/e2e/komira_read_orc_e2e` runs it).
- **Writing.** `write_orc_bytes(batch, OrcWriterOptions(compression,
  row_index_stride, writer_timezone))` and `write_orc_file` write a file with
  column statistics, optionally row indexes and bloom filters, and several
  stripes when `stripe_size_rows` asks for them.
- **Codecs.** `ORC_COMPRESSION_NONE`, `_ZLIB`, `_SNAPPY`, `_LZO` (read only),
  `_LZ4` and `_ZSTD`.
- **Metadata and encodings.** `OrcFileTail.parse` reads the PostScript and
  Footer (Protocol Buffers) of an uncompressed file, `read_orc_tail` those of
  a file of any codec; `OrcSchema` maps the type
  tree to Arrow types and to its Hive-notation form (`struct<a:bigint,...>`);
  the integer run-length encodings (RLE v1 and v2) and the byte and boolean
  RLEs decode and encode on their own (`decode_rlev2`, `encode_int_rle_v2`,
  ...); `OrcBloomFilter` is ORC's bloom filter.

## Examples

Write a batch as an uncompressed ORC file in memory, inspect its footer and
schema, and read it back, whole and projected:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from orc import ORC_COMPRESSION_NONE, ORC_COMPRESSION_ZSTD, OrcFileTail, OrcSchema, OrcWriterOptions
from orc import read_orc_bytes, read_orc_bytes_projected, read_orc_bytes_schema, read_orc_tail, write_orc_bytes

var sb = SchemaBuilder()
sb.add_field(Field("id", ArrowType.INT64, False))
sb.add_field(Field("name", ArrowType.STRING, False))
var ids: List[Int64] = [10, 20, 30, 40]
var names: List[String] = ["a", "bb", "ccc", "dddd"]
var builder = RecordBatchBuilder.with_capacity(2)
builder.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ids)))
builder.add_column(Column.from_string(StringArray.from_strings(names)))
var batch = builder.build(sb.build())

var orc = write_orc_bytes(batch, OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, "UTC"))
assert_equal(String(unsafe_from_utf8=orc[0:3]), "ORC")  # the leading magic

var tail = OrcFileTail.parse(Span(orc))
assert_equal(tail.footer.number_of_rows, 4)
assert_equal(OrcSchema.from_types(tail.footer.types).canonical_form(), "struct<id:bigint,name:string>")

var back = read_orc_bytes(Span(orc))
assert_equal(back.num_rows(), 4)
assert_equal(back.column_as_primitive_int64(0).get(3), 40)
assert_equal(back.column_as_string(1).get(2), "ccc")

var only_name: List[Int] = [1]
var projected = read_orc_bytes_projected(Span(orc), only_name)
assert_equal(projected.num_columns(), 1)
assert_equal(projected.column_as_string(0).get(1), "bb")

# The schema and the row count of a compressed file, from its footer alone.
var zstd = write_orc_bytes(batch, OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, "UTC"))
var schema = read_orc_bytes_schema(Span(zstd))
assert_equal(schema.field_name(1), "name")
assert_equal(read_orc_tail(Span(zstd)).footer.number_of_rows, 4)
```

The integer run-length encoding v2, against the examples in the ORC
specification (a short repeat and a delta run), and an encode/decode round
trip:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from orc import decode_rlev2, encode_int_rle_v2

var repeat: List[UInt8] = [0x0A, 0x27, 0x10]
assert_equal(decode_rlev2(Span(repeat), 5, signed=False), [10000, 10000, 10000, 10000, 10000])

var delta: List[UInt8] = [0xC6, 0x09, 0x02, 0x02, 0x22, 0x42, 0x42, 0x46]
assert_equal(decode_rlev2(Span(delta), 10, signed=False), [2, 3, 5, 7, 11, 13, 17, 19, 23, 29])

var values: List[Int64] = [-5, 7, 7, 7, 1000000, -1]
var encoded = encode_int_rle_v2(values, signed=True)
assert_equal(decode_rlev2(Span(encoded), len(values), signed=True), values)
```
