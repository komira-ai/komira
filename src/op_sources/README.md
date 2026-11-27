# op_sources

The sources of the engine's pipelines: the Arrow IPC stream and file readers (in-memory, codec-reporting and memory-mapped) with their dictionary cache, the source that streams one or several in-memory record batches as morsels (shared claim cursor, optional work stealing), and the source that serves a registered intermediate result to a later stage. The per-batch IPC decoding is `arrow_ipc`'s; source statistics are `plan_stats.source_statistics.SourceStatistics`. Its switches are constructor arguments; it reads no environment.

## Examples

`BatchMorselSource` splits one record batch into morsels of at most `morsel_rows` rows. Each `next_morsel` call hands out the next morsel once; after the last one every call answers `None`:

```mojo module
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder

from op_sources.batch_morsel_source import BatchMorselSource


def _range_batch(n: Int) raises -> RecordBatch:
    var vals = List[Int64]()
    for i in range(n):
        vals.append(Int64(i))
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](arr^))
    return b.build(sb.build())


def main() raises:
    var src = BatchMorselSource(_range_batch(1000), morsel_rows=300)
    assert_equal(src.partition_hint(), 4)
    assert_equal(src.row_count_hint(), 1000)

    var pulls = 0
    var total_rows = 0
    while True:
        var opt = src.next_morsel(0)
        if not opt:
            break
        total_rows += opt.value().num_rows()
        pulls += 1
    assert_equal(pulls, 4)
    assert_equal(total_rows, 1000)

    var again = src.next_morsel(0)
    assert_true(not again)
```

The readers take the bytes of an Arrow IPC stream (the schema message, record-batch messages, the end-of-stream marker) and return one `RecordBatch`; `decode_arrow_ipc_auto` picks the stream or the file walk by the leading magic. Here a stream is assembled from `arrow_ipc`'s encoders and read back equal to the batch it came from:

```mojo module
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from byte_buffer.shared_aligned_buffer import SharedAlignedBuffer
from containers.slab import Slab
from arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_eos_bytes,
    encode_record_batch_message,
    encode_schema_message,
)
from arrow_ipc.record_batch_compare import record_batch_diff

from op_sources.arrow_file_reader import decode_arrow_ipc_auto
from op_sources.arrow_stream_reader import decode_arrow_ipc_stream


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    return sb.build()


def _columns(n: Int) raises -> Slab[Column[HeapRegion]]:
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        ids.set(i, Int64(i * 7))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](ids^))
    return cols^


def _expected(n: Int) raises -> RecordBatch:
    var cols = _columns(n)
    var bb = RecordBatchBuilder()
    bb.add_column(cols.take_at(0))
    return bb.build(_schema())


def _append(mut out: List[UInt8], b: SharedAlignedBuffer[HeapRegion]):
    for i in range(b.len()):
        out.append(b.read_u8_at(i))


def _stream_bytes(n: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    _append(out, encode_schema_message(_schema()))
    _append(out, encode_record_batch_message(_columns(n)))
    _append(out, arrow_ipc_eos_bytes())
    return out^


def main() raises:
    var got = decode_arrow_ipc_stream(_stream_bytes(5))
    assert_equal(got.num_rows(), 5)
    var d = record_batch_diff(_expected(5), got)
    assert_true(d.equal, d.reason)

    var via_auto = decode_arrow_ipc_auto(_stream_bytes(5))
    var d2 = record_batch_diff(_expected(5), via_auto)
    assert_true(d2.equal, d2.reason)
```
