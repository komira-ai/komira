# =============================================================================
# DynamicFilter / BandSink behaviour
# =============================================================================
#
# What each test proves, and the defect it would catch:
#   * `DynamicFilter.copy` hands back a filter with the same key column name
#     that SHARES the bloom (the Arc count rises to 2, no deep copy), and every
#     inserted key is still reported as possibly present through the copy: a
#     deep copy, a dropped name, or a copy with an empty bloom is red;
#   * a `BandSink` conformer drives the full lifecycle through the trait:
#     per-worker state, folding borrowed bands into it, the serial combine of
#     all workers' partials, and the drain to an output batch carrying the
#     caller's schema: a combine that skips a worker or a drain that drops the
#     combined value is red.
# =============================================================================

from std.memory import ArcPointer
from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.band_view import BandView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, RecordBatchBuilder, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_engine_runtime.band_sink import BandSink
from komira_engine_runtime.dynamic_filter import DynamicFilter


def test_dynamic_filter_copy_shares_the_bloom() raises:
    var bloom = BloomFilter.create(4096)
    for v in range(1, 101):
        bloom.insert_int64(Int64(v))
    var f = DynamicFilter("k", ArcPointer[BloomFilter](bloom^))
    assert_equal(f.bloom.count(), 1)
    var g = f.copy()
    assert_equal(g.key_col_name, "k")
    assert_equal(f.bloom.count(), 2)
    for v in range(1, 101):
        assert_true(g.bloom[].might_contain_int64(Int64(v)), String(v))
        assert_true(f.bloom[].might_contain_int64(Int64(v)), String(v))


struct _Total(Movable):
    var sum: Int64

    def __init__(out self, sum: Int64):
        self.sum = sum


def _one_row(value: Int64, var schema: Schema) raises -> RecordBatch:
    var buf = OwnedAlignedBuffer(8)
    var p = buf.view_typed_mut[DType.int64]()
    p.unsafe_write(Scalar[DType.int64](value))
    buf.set_length(Int64(8))
    var arr = PrimitiveArray[DType.int64](
        buf^, 1, Optional[Bitmap[HeapRegion]](None), 0, 0
    )
    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](arr))
    return builder.build(schema^)


struct _SumSink(BandSink):
    comptime WorkerLocal = _Total

    def __init__(out self):
        pass

    def init_worker_state(self) raises -> Self.WorkerLocal:
        return _Total(0)

    def consume_band[
        o: Origin[mut=False]
    ](self, mut local: Self.WorkerLocal, band: BandView[o]) raises:
        var span = band.col_i64_span(0)
        for i in range(band.n_rows()):
            local.sum += span[i]

    def combine_workers(
        self,
        var locals: Slab[Optional[Self.WorkerLocal]],
        num_workers: Int,
    ) raises -> Self.WorkerLocal:
        var total = Int64(0)
        var taken = 0
        while True:
            var slot = locals.pop()
            if not slot:
                break
            var part = slot.take()
            if part:
                total += part.take().sum
                taken += 1
        if taken != num_workers:
            raise Error("combine_workers: expected " + String(num_workers))
        return _Total(total)

    def drain(
        self, var combined: Self.WorkerLocal, var output_schema: Schema
    ) raises -> Slab[RecordBatch]:
        var out = Slab[RecordBatch]()
        out.append(_one_row(combined.sum, output_schema^))
        return out^


def _fold[
    o: Origin[mut=False]
](sink: _SumSink, mut local: _Total, ref [o] buf: OwnedAlignedBuffer, n: Int) raises:
    var band = BandView[o](n, 1)
    band.push_flat_col(buf.view_range_ro(0, n * 8))
    sink.consume_band(local, band)


def _values(first: Int, n: Int) -> OwnedAlignedBuffer:
    var buf = OwnedAlignedBuffer(n * 8)
    var p = buf.view_typed_mut[DType.int64]()
    for i in range(n):
        (p + i).unsafe_write(Scalar[DType.int64](first + i))
    buf.set_length(Int64(n * 8))
    return buf^


def test_band_sink_lifecycle_combines_every_worker() raises:
    var sink = _SumSink()
    var w0 = sink.init_worker_state()
    var w1 = sink.init_worker_state()
    var b0 = _values(1, 4)  # 1+2+3+4 = 10
    var b1 = _values(10, 2)  # 10+11 = 21
    var b2 = _values(100, 3)  # 100+101+102 = 303
    _fold(sink, w0, b0, 4)
    _fold(sink, w1, b1, 2)
    _fold(sink, w0, b2, 3)
    assert_equal(Int(w0.sum), 313)
    assert_equal(Int(w1.sum), 21)

    var locals = Slab[Optional[_Total]]()
    locals.append(Optional[_Total](w0^))
    locals.append(Optional[_Total](w1^))
    var combined = sink.combine_workers(locals^, 2)
    assert_equal(Int(combined.sum), 334)

    var sb = SchemaBuilder()
    sb.add_field(Field("total", ArrowType.INT64, False))
    var out = sink.drain(combined^, sb.build())
    assert_equal(len(out), 1)
    assert_equal(out[0].num_rows(), 1)
    assert_equal(out[0].schema.field_name(0), "total")
    assert_equal(
        Int(out[0].column_at(0).as_primitive[DType.int64]().get(0)), 334
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
