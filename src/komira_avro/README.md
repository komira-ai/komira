# komira_avro

Apache Avro 1.11.1 Object Container Files (OCF) to and from Arrow record
batches (`komira_arrow`).

- **Schemas.** `AvroSchema.parse(json)` parses a schema; `parsing_canonical_form`
  and `fingerprint` are the spec's Parsing Canonical Form and its CRC-64-AVRO
  ("Rabin") fingerprint; `avro_node_to_arrow` maps an Avro type to an Arrow
  type. A recursive schema is refused.
- **Reading.** `read_avro_bytes` and `read_avro_file` read a whole container
  into one `RecordBatch` with the writer's schema;
  `read_avro_bytes_resolved(bytes, reader_schema_json)` applies the spec's
  schema resolution (field skip and reorder, defaults for missing fields,
  aliases, int/long/float/double promotion, string/bytes, union and enum
  resolution); `read_avro_bytes_parallel` decodes blocks in parallel.
- **Writing.** `write_avro_bytes(batch, AvroWriterOptions(codec))` and
  `write_avro_file` write a container; Arrow types Avro cannot express are
  annotated (`arrow.*`) so they read back as the same Arrow type, unless
  `emit_arrow_logicals` is off.
- **Codecs.** `null`, `deflate`, `snappy`, `bzip2`, `xz` and `zstandard`
  (`AVRO_CODEC_*`), selected by the header's `avro.codec`.
- **Lower levels.** `decode_ocf_header`, `scan_ocf_blocks`, the zigzag varint
  encoders (`encode_long`, `encode_string`, ...) and `decode_zigzag_long`.

## Examples

Parsing Canonical Form drops attributes that do not affect parsing, and the
fingerprint matches the spec's published value for `"int"`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_avro import AvroSchema

var schema = AvroSchema.parse(
    '{"type":"record","name":"Test","doc":"ignored",'
    '"fields":[{"name":"f","type":"long","doc":"d"},{"name":"g","type":"int"}]}'
)
assert_equal(
    schema.parsing_canonical_form(),
    '{"name":"Test","type":"record","fields":[{"name":"f","type":"long"},{"name":"g","type":"int"}]}',
)
assert_equal(AvroSchema.parse('"int"').fingerprint(), 0x7275D51A3F395C8F)
assert_equal(AvroSchema.parse('{"type":"int"}').parsing_canonical_form(), '"int"')
```

Avro's zigzag varint keeps small magnitudes short: -3 is the single byte `0x05`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_avro import decode_zigzag_long, encode_long, encode_string

var out = List[UInt8]()
encode_long(-3, out)
encode_string("hi", out)
assert_equal(out, [0x05, 0x04, 0x68, 0x69])  # -3, then length 2 and "hi"
var first = decode_zigzag_long(Span(out), 0)
assert_equal(first.value, -3)
assert_equal(first.new_pos, 1)
```

Write a batch to an in-memory container and read it back, once with the
writer's schema and once through a reader schema that drops a field and adds
one with a default:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_avro import AVRO_CODEC_NULL, AvroWriterOptions, decode_ocf_header
from komira_avro import read_avro_bytes, read_avro_bytes_resolved, write_avro_bytes

var sb = SchemaBuilder()
sb.add_field(Field("id", ArrowType.INT64, False))
sb.add_field(Field("name", ArrowType.STRING, False))
var ids: List[Int64] = [1, 2, 3]
var names: List[String] = ["pen", "ink", "eraser"]
var builder = RecordBatchBuilder.with_capacity(2)
builder.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ids)))
builder.add_column(Column.from_string(StringArray.from_strings(names)))
var batch = builder.build(sb.build())

var ocf = write_avro_bytes(batch, AvroWriterOptions(AVRO_CODEC_NULL))
assert_equal(String(unsafe_from_utf8=ocf[0:3]), "Obj")  # the magic "Obj" 0x01
assert_equal(ocf[3], 1)
assert_equal(decode_ocf_header(Span(ocf)).codec_name(), "null")

var back = read_avro_bytes(Span(ocf))
assert_equal(back.num_rows(), 3)
assert_equal(back.column_as_primitive_int64(0).get(2), 3)
assert_equal(back.column_as_string(1).get(1), "ink")

var reader_schema = String(
    '{"type":"record","name":"topLevelRecord","fields":['
    '{"name":"id","type":"long"},'
    '{"name":"score","type":"double","default":7.5}]}'
)
var resolved = read_avro_bytes_resolved(Span(ocf), reader_schema)
assert_equal(resolved.num_columns(), 2)
assert_equal(resolved.column_as_primitive_int64(0).get(0), 1)
assert_equal(resolved.column_as_primitive_float64(1).get(2), 7.5)
```
