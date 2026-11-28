# arrow_ipc

Arrow IPC framing, encoders and decoders, the C data and stream interfaces, tensor columns, file chunk reads.

The encoders write the Arrow IPC wire format: a message is a continuation
marker, a length, a flatbuffer `Message` and an 8-byte-aligned body. A
`RecordBatch` message carries the buffers of each column but not their
types; those travel in the preceding `Schema` message
(`encode_schema_message`), so a decoder is given the column types.
`arrow_ipc.ipc_encoder_dispatch` holds the encoders,
`arrow_ipc.ipc_decoder_dispatch` the decoders, and
`arrow_ipc.record_batch_compare` a strict (bit-exact) batch
comparison.

Every example below runs as a test when the package is built, so it cannot
go stale.

## A record batch message round trip

Encode a nullable `INT32` column and a `STRING` column as one RecordBatch
message, then decode the frame back into columns. Values and nulls survive
the round trip.

```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.string_array import StringArray
from arrow_ipc.ipc_decoder_dispatch import decode_record_batch_message
from arrow_ipc.ipc_encoder_dispatch import encode_record_batch_message
from byte_buffer.heap_region import HeapRegion
from containers.slab import Slab
from std.testing import assert_equal, assert_false, assert_true

var counts = ColumnBuilder[DType.int32].with_capacity(3)
counts.append(Int32(7))
counts.append_null()
counts.append(Int32(-3))

var words: List[String] = ["alpha", "beta", "gamma"]

var columns = Slab[Column[HeapRegion]]()
columns.append(counts^.materialize())
columns.append(Column.from_string(StringArray.from_strings(words)))
var frame = encode_record_batch_message(columns^)

# The frame starts with the IPC continuation marker 0xFFFFFFFF.
var view = frame.view_ro()
for i in range(4):
    assert_equal(view.get_typed[UInt8](i), UInt8(0xFF))

var types: List[ArrowType] = [ArrowType.INT32, ArrowType.STRING]
var decoded = decode_record_batch_message(frame^, types^)
assert_equal(len(decoded), 2)

assert_equal(decoded[0].arrow_type, ArrowType.INT32)
assert_equal(decoded[0].length(), 3)
assert_equal(decoded[0].null_count(), 1)
assert_false(decoded[0].is_null_at(0))
assert_true(decoded[0].is_null_at(1))
var ints = decoded[0].as_primitive[DType.int32]()
assert_equal(ints.get(0), Int32(7))
assert_equal(ints.get(2), Int32(-3))

assert_equal(decoded[1].arrow_type, ArrowType.STRING)
var strings = decoded[1].as_string()
assert_equal(strings.get(0), "alpha")
assert_equal(strings.get(2), "gamma")
```

## Record batches as an Arrow C stream

`arrow_ipc.c_data_stream.build_record_batch_stream(batches, schema, out)`
fills a caller-allocated `struct ArrowArrayStream` (the Arrow C Stream
Interface) with owned batches. The consumer owns the stream and calls its
`release` once; each chunk `get_next` hands out shares its column buffers
(no copy) and stays readable after the stream is released. Every `release`
sets the struct's `release` to NULL, and a second call on a released struct
does nothing.

The column types that cross: every integer and float width, bool, date32 and
date64, timestamps of every unit, decimal128 and decimal256, time, duration
and interval, utf8, binary, large utf8 and large binary, a dictionary of utf8
values at the top level, list, struct, map, and sparse and dense unions. A
view type (`UTF8_VIEW`, `BINARY_VIEW`, the list views) does not, nor does a
variable-length (utf8, binary and their large forms), nested or union column
with a non-zero offset. A stream with no
batch can hold no nested column, whose child types only a batch carries.

`arrow_ipc.c_data_column` (`FFI-BOUNDARY`) is the same layout one batch or
column at a time, for a host that calls a UDF runtime (`udf_host`):
`export_struct_array` and `export_struct_schema` give a batch as a struct
array and its schema, `export_field_schema` one field's schema, and
`import_c_column` reads the array a runtime returns at the type its schema
declares, copying every buffer so nothing points into the producer's memory
afterwards. The producer's array is released by its owner, not by the import.

`build_record_batch_stream` checks only the column types; anything else that
cannot cross surfaces later, as EIO from the consumer's `get_schema` or
`get_next`. A caller that must refuse before the stream exists (a C entry
point that leaves `*out` untouched on failure) first calls
`arrow_ipc.c_data_stream_check.check_record_batch_stream(schema, batches)`. It
builds, and releases at once, everything the stream's callbacks would build,
so when it returns they do not fail. It raises naming the column and its type
(and the batch, for a refusal of a batch's data). It also refuses a batch that
still carries a selection mask, whose dropped rows the export would carry,
and a batch whose column count is not the schema's.

```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow_ipc.c_data_stream_check import check_record_batch_stream
from containers.slab import Slab
from std.testing import assert_true

var fields = SchemaBuilder()
fields.add_field(Field("n", ArrowType.INT64, nullable=False))
var schema = fields.build()

var builder = RecordBatchBuilder.with_capacity(1)
builder.add_column(
    Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list([Int64(1), Int64(2)])
    )
)
var batches = Slab[RecordBatch].with_capacity(1)
batches.append(builder.build(schema.copy()))

# One INT64 column crosses whole: no raise.
check_record_batch_stream(schema, batches)

# A UTF8_VIEW column does not, and the refusal names it.
var views = SchemaBuilder()
views.add_field(Field("v", ArrowType.UTF8_VIEW, nullable=True))
var refusal = String()
try:
    check_record_batch_stream(views.build(), Slab[RecordBatch]())
except e:
    refusal = String(e)
assert_true(refusal.startswith("ArrowCStreamExport: column 'v' ("))
```
