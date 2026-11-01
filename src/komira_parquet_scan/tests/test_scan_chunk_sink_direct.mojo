# scan_chunk_sink, the collect side of the sub-row-group scan:
#   - chunks staged out of order drain in (rg_idx, chunk_idx) order, ties in
#     arrival order, across a flush and across merged workers;
#   - discard_rg drops every chunk of one row group, staged or flushed, and
#     returns its rows;
#   - a dictionary string chunk drains as a dictionary column over its row
#     group's dictionary, the other columns kept; a codes column of the wrong
#     length is refused;
#   - the sink's combine and drain over per-worker builders.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_parquet_scan.scan_chunk_sink import (
    ScanCollectChunkSink,
    StagedStringDictCol,
    StreamingScanOutputBuilder,
)


def _batch(first: Int, n: Int) raises -> RecordBatch:
    """Column x = first, first + 1, ..."""
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](first + i))
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals^))
    )


def _first(b: RecordBatch) raises -> Int:
    return Int(b.column_at(0).as_primitive[DType.int64]().get(0))


def test_drain_sorts_by_stamp_across_a_flush() raises:
    # A budget of 1 byte flushes after every append.
    var b = StreamingScanOutputBuilder(1)
    b.append(_batch(300, 2), 3, 0)
    b.append(_batch(110, 2), 1, 1)
    b.append(_batch(100, 2), 1, 0)
    b.append(_batch(301, 1), 3, 0)  # a tie: keeps arrival order
    assert_equal(b.num_chunks(), 4)
    var out = b.drain()
    assert_equal(len(out), 4)
    var want: List[Int] = [100, 110, 300, 301]
    for i in range(4):
        assert_equal(_first(out[i]), want[i])
    assert_equal(b.num_chunks(), 0)


def test_discard_rg_drops_staged_and_flushed_chunks() raises:
    var b = StreamingScanOutputBuilder(16 * 3)  # flushes after the second chunk
    b.append(_batch(0, 2), 5, 0)
    b.append(_batch(10, 1), 6, 0)
    b.append(_batch(20, 3), 5, 1)
    assert_equal(b.discard_rg(5), 5)
    assert_equal(b.discard_rg(5), 0)
    var out = b.drain()
    assert_equal(len(out), 1)
    assert_equal(_first(out[0]), 10)


def test_merge_then_drain() raises:
    var a = StreamingScanOutputBuilder(1 << 20)
    a.append(_batch(20, 1), 2, 0)
    var c = StreamingScanOutputBuilder(1)
    c.append(_batch(10, 1), 1, 0)
    c.append(_batch(30, 1), 3, 0)
    a.merge_from(c^)
    var out = a.drain()
    assert_equal(len(out), 3)
    assert_equal(_first(out[0]), 10)
    assert_equal(_first(out[2]), 30)


def _codes_batch(codes: List[Int], x0: Int) raises -> RecordBatch:
    """Columns s (INT32 codes placeholder) and x."""
    var arr = PrimitiveArray[DType.int32].allocate(len(codes))
    for i in range(len(codes)):
        arr.set_typed[Scalar[DType.int32]](i, Int32(codes[i]))
    var xs = List[Scalar[DType.int64]]()
    for i in range(len(codes)):
        xs.append(Scalar[DType.int64](x0 + i))
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.INT32, False))
    sb.add_field(Field("x", ArrowType.INT64, False))
    return RecordBatch.from_typed_columns_2(
        sb.build(),
        Column.from_primitive[DType.int32](arr^),
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(xs^)),
    )


def _dict(words: List[String]) -> StagedStringDictCol:
    var off = List[Int32]()
    var by = List[UInt8]()
    off.append(0)
    for i in range(len(words)):
        for b in words[i].as_bytes():
            by.append(b)
        off.append(Int32(len(by)))
    return StagedStringDictCol(0, "s", off^, by^)


def test_string_dictionary_chunks_drain_as_dictionary_columns() raises:
    var b = StreamingScanOutputBuilder(1 << 20)
    var d0 = List[StagedStringDictCol]()
    d0.append(_dict(["red", "blue"]))
    b.append(_codes_batch([1, 0, 1], 0), 0, 0, d0^)
    var d1 = List[StagedStringDictCol]()
    d1.append(_dict(["green"]))
    b.append(_codes_batch([0, 0], 3), 1, 0, d1^)
    var out = b.drain()
    assert_equal(len(out), 2)
    ref first = out[0]
    assert_true(first.schema.field_arrow_type(0) == ArrowType.DICTIONARY)
    var sda = first.column_at(0).as_dictionary()
    assert_equal(sda.get(0), "blue")
    assert_equal(sda.get(1), "red")
    assert_equal(Int(first.column_at(1).as_primitive[DType.int64]().get(2)), 2)
    assert_equal(out[1].column_at(0).as_dictionary().get(1), "green")


def test_a_codes_column_of_the_wrong_length_is_refused() raises:
    var b = StreamingScanOutputBuilder(1 << 20)
    var d = List[StagedStringDictCol]()
    var sdc = _dict(["a"])
    sdc.col_pos = 1  # points at x, an INT64 column read as INT32 codes
    d.append(sdc^)
    b.append(_codes_batch([0, 0], 0), 0, 0, d^)
    with assert_raises():
        _ = b.drain()


def _noop() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_the_sink_combines_and_drains_workers() raises:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _noop, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var sink = ScanCollectChunkSink(0)
    var locals = Slab[Optional[StreamingScanOutputBuilder]].create(3)
    var w0 = sink.init_worker_state()
    sink.consume_chunk(w0, 4, 0, _batch(40, 1))
    locals.append(Optional(w0^))
    locals.append(Optional[StreamingScanOutputBuilder](None))
    var w2 = sink.init_worker_state()
    sink.consume_chunk(w2, 2, 0, _batch(20, 1))
    locals.append(Optional(w2^))
    var combined = sink.combine_workers(locals^, 3, Pointer(to=disp), CancellationToken.never())
    var out = sink.drain(combined^, _batch(0, 1).schema.copy(), Pointer(to=disp), CancellationToken.never())
    assert_equal(len(out), 2)
    assert_equal(_first(out[0]), 20)
    assert_equal(_first(out[1]), 40)
    rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
