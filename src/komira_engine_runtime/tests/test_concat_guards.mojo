# =============================================================================
# CONCAT GUARDS: what the concat refuses, and what it must not fork under
# =============================================================================
#
# G1  SCHEMA AGREEMENT. Every batch must have the same columns as the first
#     batch with rows and columns: the same count, and (for a batch with rows)
#     the same type per column. A violation used to produce a result built
#     through the wrong layout, or an out-of-range column read, with no error.
#     Each case runs under the row floor (serial route) and above it (parallel
#     route), and the error must name the offending batch.
# G2  THE SCHEMA BATCH IS THE ONE THE DRIVER PICKED. A zero-row batch in front
#     may carry other column types; the serial route and the one-task-per-column
#     route took their column types from batch 0 and so read the wrong layout.
# G3  A LIVE POOL DISPATCH. A one-column concat reached from inside a pool task
#     must stay on the calling thread. The tests hold the dispatcher's own
#     on-pool guard (the process-global depth a pool task runs under) and
#     check that no fork is recorded; the control run without the guard forks.
# G4  THE INT32 OFFSET CEILING on the tiled STRING route, reached through
#     `ConcatOptions.offset_promote_at` with a trip point of 100 bytes instead
#     of 2 GiB of payload.
# G5  `string_tile_row_bounds` refuses a STRING column that has rows but no
#     offsets buffer.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import _OnPoolDispatchGuard
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import SITE_CONCAT

from komira_engine_runtime.concat_options import ConcatOptions
from komira_engine_runtime.concat_string_tile_bounds import _row_cost_at
from komira_engine_runtime.grain_geometry import (
    GRAIN_F_MORSELS,
    grain_geometry_calls,
    grain_geometry_field,
    grain_geometry_reset,
)
from komira_engine_runtime.streaming_concat_parallel import (
    concat_record_batches_column_parallel,
)


comptime _WORKERS: Int = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


# =============================================================================
# Fixtures
# =============================================================================


def _int64(base: Int, n: Int) -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate(n)
    var p = a._typed_ptr_mut()
    for j in range(n):
        (p + j)[] = Int64((base + j) * 3 + 1)
    return Column.from_primitive[DType.int64](a^)


def _int32(base: Int, n: Int) -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int32].allocate(n)
    var p = a._typed_ptr_mut()
    for j in range(n):
        (p + j)[] = Int32((base + j) * 5 - 1)
    return Column.from_primitive[DType.int32](a^)


def _text(base: Int, n: Int) raises -> Column[HeapRegion]:
    var strs = List[String](capacity=n)
    for j in range(n):
        strs.append(String("payload-") + String(base + j))
    return Column.from_string(StringArray.from_strings(strs))


def _batch(
    var c0: Column[HeapRegion],
    t0: ArrowType,
    var c1: Optional[Column[HeapRegion]],
    t1: ArrowType,
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", t0, False))
    var rb = RecordBatchBuilder()
    rb.add_column(c0^)
    if c1:
        sb.add_field(Field("c1", t1, False))
        rb.add_column(c1.take())
    return rb.build(sb.build())


def _int64_int32(base: Int, n: Int) raises -> RecordBatch:
    return _batch(
        _int64(base, n), ArrowType.INT64,
        Optional[Column[HeapRegion]](_int32(base, n)), ArrowType.INT32,
    )


def _int64_text(base: Int, n: Int) raises -> RecordBatch:
    return _batch(
        _int64(base, n), ArrowType.INT64,
        Optional[Column[HeapRegion]](_text(base, n)), ArrowType.STRING,
    )


def _int32_int32(base: Int, n: Int) raises -> RecordBatch:
    return _batch(
        _int32(base, n), ArrowType.INT32,
        Optional[Column[HeapRegion]](_int32(base, n)), ArrowType.INT32,
    )


def _int64_only(base: Int, n: Int) raises -> RecordBatch:
    return _batch(
        _int64(base, n), ArrowType.INT64,
        Optional[Column[HeapRegion]](None), ArrowType.INT32,
    )


def _empty_text_text() raises -> RecordBatch:
    """Zero rows, two STRING columns."""
    return _batch(
        _text(0, 0), ArrowType.STRING,
        Optional[Column[HeapRegion]](_text(0, 0)), ArrowType.STRING,
    )


def _drive(
    var batches: Slab[RecordBatch],
    options: ConcatOptions = ConcatOptions(),
) raises -> RecordBatch:
    var runtime = _runtime()
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var out = concat_record_batches_column_parallel(
        batches^, disp, ct^, options
    )
    _ = runtime^
    return out^


def _refused_with(
    var batches: Slab[RecordBatch], needle: String, label: String
) raises:
    """The concat raises, and the message contains `needle`."""
    var message = String("")
    var raised = False
    try:
        var out = _drive(batches^)
        _ = out^
    except e:
        raised = True
        message = String(e)
    if not raised:
        raise Error(label + ": the concat returned instead of refusing")
    if needle not in message:
        raise Error(
            label + ": refused for another reason; wanted '" + needle
            + "' in: " + message
        )


# =============================================================================
# G1 -- schema agreement
# =============================================================================


def _slab2(var a: RecordBatch, var b: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch].create(2)
    s.append(a^)
    s.append(b^)
    return s^


def test_g1_batches_that_disagree_are_refused() raises:
    # 50 rows per batch stays serial; 50,000 per batch is the parallel route.
    var sizes: List[Int] = [50, 50_000]
    for k in range(len(sizes)):
        var n = sizes[k]
        var at = String(" at ") + String(n) + " rows/batch"
        _refused_with(
            _slab2(_int64_int32(0, n), _int64_text(n, n)),
            String("column 1 of batch 1 is"), String("INT32 vs STRING") + at,
        )
        _refused_with(
            _slab2(_int64_int32(0, n), _int32_int32(n, n)),
            String("column 0 of batch 1 is"), String("INT64 vs INT32") + at,
        )
        _refused_with(
            _slab2(_int64_int32(0, n), _int64_only(n, n)),
            String("batch 1 has 1 column(s)"), String("2 columns vs 1") + at,
        )
        _refused_with(
            _slab2(_int64_only(0, n), _int64_int32(n, n)),
            String("batch 1 has 2 column(s)"), String("1 column vs 2") + at,
        )
        var with_blank = Slab[RecordBatch].create(3)
        with_blank.append(RecordBatch())
        with_blank.append(_int64_int32(0, n))
        with_blank.append(_int64_int32(n, n))
        _refused_with(
            with_blank^, String("batch 0 has 0 column(s)"),
            String("zero-column batch first") + at,
        )


def test_g1_agreeing_batches_are_not_refused() raises:
    """The control: the same shapes with matching columns concatenate."""
    var out = _drive(_slab2(_int64_int32(0, 50_000), _int64_int32(50_000, 50_000)))
    assert_equal(out.num_rows(), 100_000, "rows")
    assert_equal(out.num_columns(), 2, "columns")


# =============================================================================
# G2 -- the schema batch is the driver's pick, not batch 0
# =============================================================================


def _check_after_a_typed_empty_batch(n: Int, options: ConcatOptions) raises:
    var batches = Slab[RecordBatch].create(3)
    batches.append(_empty_text_text())
    batches.append(_int64_int32(0, n))
    batches.append(_int64_int32(n, n))
    var out = _drive(batches^, options)
    var label = String("typed-empty batch 0, ") + String(n) + " rows/batch"
    assert_equal(out.num_rows(), 2 * n, label + ": rows")
    assert_true(
        out.column_at(0).arrow_type == ArrowType.INT64, label + ": column 0 type"
    )
    assert_true(
        out.column_at(1).arrow_type == ArrowType.INT32, label + ": column 1 type"
    )
    assert_true(
        out.schema.field_at(0).arrow_type == ArrowType.INT64,
        label + ": field 0 comes from the schema batch",
    )
    assert_true(
        out.schema.field_at(1).arrow_type == ArrowType.INT32,
        label + ": field 1 comes from the schema batch",
    )
    for r in range(2 * n):
        assert_equal(
            Int(out.column_at(0)._data.get_typed[Int64](r)), r * 3 + 1,
            label + ": column 0 row " + String(r),
        )
        assert_equal(
            Int(out.column_at(1)._data.get_typed[Int32](r)), r * 5 - 1,
            label + ": column 1 row " + String(r),
        )


def test_g2_a_typed_empty_first_batch_does_not_pick_the_types() raises:
    _check_after_a_typed_empty_batch(50, ConcatOptions())  # serial
    _check_after_a_typed_empty_batch(2_500, ConcatOptions())  # per-column
    _check_after_a_typed_empty_batch(
        2_500, ConcatOptions(force_tiles=True)
    )  # tiled


# =============================================================================
# G3 -- a live pool dispatch
# =============================================================================


def _one_text_column_batches() raises -> Slab[RecordBatch]:
    """Six batches of 25,000 rows of one STRING column: above the tiled
    route's row floor, so a one-column concat forks on a 4-worker pool."""
    var out = Slab[RecordBatch].create(6)
    for m in range(6):
        var sb = SchemaBuilder()
        sb.add_field(Field("c0", ArrowType.STRING, False))
        var rb = RecordBatchBuilder()
        rb.add_column(_text(m * 25_000, 25_000))
        out.append(rb.build(sb.build()))
    return out^


def test_g3_a_one_column_concat_forks_outside_a_pool_dispatch() raises:
    """The control: without the guard the same input forks into tiles, so the
    next test's `calls == 0` can only mean the guard declined."""
    grain_geometry_reset()
    var out = _drive(_one_text_column_batches())
    assert_equal(out.num_rows(), 150_000, "rows")
    assert_equal(grain_geometry_calls(SITE_CONCAT), 1, "one fork")
    assert_true(
        grain_geometry_field(SITE_CONCAT, GRAIN_F_MORSELS) >= 2,
        "the rule cuts the column into tiles",
    )


def test_g3_a_one_column_concat_stays_serial_under_a_pool_dispatch() raises:
    var runtime = _runtime()
    var batches = _one_text_column_batches()
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    grain_geometry_reset()
    var guard = _OnPoolDispatchGuard()
    var out = concat_record_batches_column_parallel(batches^, disp, ct^)
    guard.keepalive()
    assert_equal(out.num_rows(), 150_000, "rows")
    assert_equal(
        grain_geometry_calls(SITE_CONCAT), 0,
        "no fork may be recorded while a pool dispatch is live",
    )
    _ = runtime^


# =============================================================================
# G4 -- the Int32 offset ceiling on the tiled STRING route
# =============================================================================


def test_g4_tiled_string_route_refuses_past_the_offset_ceiling() raises:
    # Control: the same input under forced tiles concatenates.
    var ok = _drive(
        _slab2(_int64_text(0, 1_500), _int64_text(1_500, 1_500)),
        ConcatOptions(force_tiles=True),
    )
    assert_equal(ok.num_rows(), 3_000, "control rows")

    var message = String("")
    var raised = False
    try:
        var out = _drive(
            _slab2(_int64_text(0, 1_500), _int64_text(1_500, 1_500)),
            ConcatOptions(force_tiles=True, offset_promote_at=100),
        )
        _ = out^
    except e:
        raised = True
        message = String(e)
    if not raised:
        raise Error("the tiled STRING route accepted 3,000 rows past a 100-byte ceiling")
    assert_true(
        "ArrowOffsetOverflow" in message,
        "refused for another reason: " + message,
    )


# =============================================================================
# G5 -- a STRING column with rows and no offsets
# =============================================================================


def test_g5_row_cost_refuses_a_string_column_without_offsets() raises:
    var data = OwnedAlignedBuffer(8)
    data.set_length(Int64(0))
    var col = Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=5,
        null_count=0,
        offset=0,
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(col^)
    var slab = Slab[Optional[RecordBatch]].create(1)
    slab.append(Optional[RecordBatch](rb.build(sb.build())))
    var message = String("")
    var raised = False
    try:
        _ = _row_cost_at(slab, 0, 0, 1, 0, 0)
    except e:
        raised = True
        message = String(e)
    if not raised:
        raise Error("_row_cost_at read the offsets of a column that has none")
    assert_true("no offsets buffer" in message, "wrong error: " + message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
