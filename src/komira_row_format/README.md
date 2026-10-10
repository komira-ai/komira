# komira_row_format

The row-major storage and kernels behind an engine's grouping, join and sort
operators when the key columns are known only at run time. There is no facade:
import from the sub-modules.

- `row_block`: `RowBlock`, packed fixed-stride rows with a side blob for
  variable-width cells, described by a `RowLayout` of `ColDescriptor`s (kind,
  `DT_*` data type, width, offset in the row); and the hash-aggregation table
  built on it.
- `row_directory`: `RowDirectory`, the open-addressing slot directory (power of
  two, linear probing, regrow at load factor 0.5) the row tables share.
- `arrow_row`: an order-preserving key encoding after Arrow's row format. Each
  fixed-width value encodes to bytes whose byte-wise order is the value order
  (`encode_i64_to_bytes`, `encode_f64_to_bytes`, ... with `asc=False`
  inverting every byte for a descending key); `encode_row_keys_for_sort`
  encodes a row's keys, with a null sentinel per key, into one byte string;
  `arrow_row_compare` compares two such strings. Floats sort in the engine's
  order: every NaN is one value above `+inf`, and `-0.0` ties `+0.0`. String
  and binary keys are refused by the composite encoder.
- `row_sort`: `RowSortBuffer`, which buffers Arrow batches, sorts them on
  64-bit integer keys (ascending or descending per key) and emits the sorted
  rows as a new `RecordBatch`. Other key and payload types are refused.
- `xxh3`: the scalar reference XXH3-64 (seed 0) for keys of up to 240 bytes
  (`xxh3_64_scalar_span`, `xxh3_64_scalar_bytes`); longer input is refused.

## Examples

XXH3-64 against the published vector for the empty input, and the 240-byte
limit:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_row_format.xxh3 import XXH3_MAX_KEY_LEN, xxh3_64_scalar_bytes, xxh3_64_scalar_span

assert_equal(xxh3_64_scalar_span("".as_bytes()), 0x2D06800538D394C2)
var key: List[UInt8] = [1, 2, 3, 4]
assert_equal(xxh3_64_scalar_bytes(key), xxh3_64_scalar_span(Span(key)))

var too_long = List[UInt8](length=XXH3_MAX_KEY_LEN + 1, fill=7)
var refused = False
try:
    _ = xxh3_64_scalar_bytes(too_long)
except:
    refused = True
assert_true(refused)
```

The order-preserving encoding: a signed integer becomes big-endian with its
sign bit flipped, so -1 sorts before 1 byte by byte; a descending key inverts
every byte; `-0.0` and `+0.0` encode alike:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_row_format.arrow_row import arrow_row_compare, encode_f64_to_bytes, encode_i64_to_bytes

def as_list(a: Array[UInt8, 8]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(8):
        out.append(a[i])
    return out^

var one = as_list(encode_i64_to_bytes(1, asc=True))
var minus_one = as_list(encode_i64_to_bytes(-1, asc=True))
assert_equal(one, [0x80, 0, 0, 0, 0, 0, 0, 1])
assert_equal(minus_one, [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
assert_equal(arrow_row_compare(minus_one, one), -1)

var one_desc = as_list(encode_i64_to_bytes(1, asc=False))
var minus_one_desc = as_list(encode_i64_to_bytes(-1, asc=False))
assert_equal(arrow_row_compare(minus_one_desc, one_desc), 1)

assert_equal(as_list(encode_f64_to_bytes(-0.0, asc=True)), as_list(encode_f64_to_bytes(0.0, asc=True)))
var big = as_list(encode_f64_to_bytes(1e308, asc=True))
var nan = as_list(encode_f64_to_bytes(Float64(0) / Float64(0), asc=True))
assert_true(arrow_row_compare(big, nan) < 0)
```

Sorting an Arrow batch of `(key, payload)` rows by the key, descending, with
`RowSortBuffer`:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_row_format.row_block import COL_FIXED, DT_I64, ColDescriptor, RowLayout
from komira_row_format.row_sort import SORT_DESC, RowSortBuffer

var sb = SchemaBuilder()
sb.add_field(Field("k", ArrowType.INT64, False))
sb.add_field(Field("p", ArrowType.INT64, False))
var keys: List[Int64] = [30, 10, 50, 20, 40]
var pays: List[Int64] = [300, 100, 500, 200, 400]
var rbb = RecordBatchBuilder.with_capacity(2)
rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(keys)))
rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(pays)))
var batch = rbb.build(sb.build())

# One 8-byte key cell at offset 0, one 8-byte payload cell at offset 8.
var layout = RowLayout()
layout.add_key_col(ColDescriptor(kind=COL_FIXED, dtype_tag=DT_I64, fixed_width=UInt16(8), offset_in_row=UInt16(0)))
layout.add_payload_col(ColDescriptor(kind=COL_FIXED, dtype_tag=DT_I64, fixed_width=UInt16(8), offset_in_row=UInt16(8)))
layout.set_fixed_row_stride(16)

var buf = RowSortBuffer(8, layout.fixed_row_stride)
buf.add_key_direction(SORT_DESC)
var key_cols: List[Int] = [0]
var payload_cols: List[Int] = [1]
buf.feed_batch(BatchView(batch), key_cols, payload_cols, layout)
buf.finalize_sort(layout)

var key_names: List[String] = ["k"]
var payload_names: List[String] = ["p"]
var sorted = buf.emit_to_record_batch(layout, key_names, payload_names)
assert_true(sorted)
var out = sorted.take()
var k = out.column_as_primitive_int64(0)
var p = out.column_as_primitive_int64(1)
for i in range(5):
    assert_equal(k.get(i), Int64(50 - 10 * i))
    assert_equal(p.get(i), Int64(500 - 100 * i))
```
