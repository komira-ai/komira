# komira_arrow_ipc

Arrow IPC framing, encoders and decoders, the C data and stream interfaces, tensor columns, file chunk reads.

The encoders write the Arrow IPC wire format: a message is a continuation
marker, a length, a flatbuffer `Message` and an 8-byte-aligned body. A
`RecordBatch` message carries the buffers of each column but not their
types; those travel in the preceding `Schema` message
(`encode_schema_message`), so a decoder is given the column types.
`komira_arrow_ipc.ipc_encoder_dispatch` holds the encoders,
`komira_arrow_ipc.ipc_decoder_dispatch` the decoders, and
`komira_arrow_ipc.record_batch_compare` a strict (bit-exact) batch
comparison.

Every example below runs as a test when the package is built, so it cannot
go stale.

## A record batch message round trip

Encode a nullable `INT32` column and a `STRING` column as one RecordBatch
message, then decode the frame back into columns. Values and nulls survive
the round trip.

```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.ipc_decoder_dispatch import decode_record_batch_message
from komira_arrow_ipc.ipc_encoder_dispatch import encode_record_batch_message
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
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
