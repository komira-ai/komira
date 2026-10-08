"""The parts of `widen_payload_table_parallel` the round trips do not reach: a
result with no chunks, a narrow column that carries a validity bitmap, a tile
that fails, on the serial arm and on the forked one, and each operand of the
serial-or-fork decision taken on its own.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.table import Table
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_dispatch_join_kernels.join_payload_narrow_exec import (
    PayloadWidenPlan,
    _PN_MIN_PARALLEL_ROWS,
)
from komira_dispatch_join_kernels.join_payload_widen import (
    widen_payload_table_parallel,
)


comptime I64 = DType.int64


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _wide_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    return sb.build()


def _narrow_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.UINT16, True))
    return sb.build()


def _plan(src_bytes: UInt8, base: Int64) -> PayloadWidenPlan:
    """Output column 1 was narrowed to `src_bytes` with frame `base`."""
    var plan = PayloadWidenPlan()
    plan.out_col.append(1)
    plan.src_bytes.append(src_bytes)
    plan.base.append(base)
    return plan^


def _narrow_chunk(rows: Int, null_row: Int) raises -> RecordBatch:
    """`key` INT64 and `v` UINT16 holding `i % 50000`; `null_row >= 0` gives
    `v` a validity bitmap with that row NULL."""
    var keys = PrimitiveArray[I64].allocate(rows)
    for i in range(rows):
        keys.set(i, Int64(i))
    var buf = OwnedAlignedBuffer(max(rows * 2, 1))
    buf.set_length(Int64(rows * 2))
    for i in range(rows):
        buf.set_typed[Scalar[DType.uint16]](i, UInt16(i % 50000))
    var validity = Optional[Bitmap[HeapRegion]](None)
    var nulls = 0
    if null_row >= 0:
        var bm = Bitmap.create_all_valid(rows)
        bm.clear(null_row)
        validity = Optional[Bitmap[HeapRegion]](bm^)
        nulls = 1
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(Column.from_primitive[I64](keys^))
    b.add_column(
        Column[HeapRegion](
            arrow_type=ArrowType.UINT16,
            data=buf^,
            offsets=Optional[OwnedAlignedBuffer](None),
            validity=validity^,
            length=rows,
            null_count=nulls,
            offset=0,
        )
    )
    return b.build(_narrow_schema())


def test_no_chunks_still_carries_the_wide_schema() raises:
    """A table with no chunks and a non-empty plan comes back as one empty
    chunk under the WIDE schema.
    MUTANT: the `n_chunks == 0` arm returning the table it was given: the
    result has no chunk and the narrow schema."""
    var rt = _make_started_runtime(2)
    ref disp = rt.dispatcher()
    var t = Table.from_chunks(List[RecordBatch](), _narrow_schema())
    var out = widen_payload_table_parallel(
        t^, _plan(UInt8(2), Int64(0)), _wide_schema(), Pointer(to=disp),
        CancellationToken.never(), 2,
    )
    rt.shutdown()
    assert_equal(out.num_chunks(), 1)
    assert_equal(out.num_rows(), 0)
    assert_true(out.schema().field_arrow_type(1) == ArrowType.INT64)
    assert_true(out.chunks()[0].column_at(1).arrow_type == ArrowType.INT64)


def test_a_validity_bitmap_survives_the_widen() raises:
    """A narrow column with a NULL at row 3: the widened column keeps the
    bitmap (row 3 NULL, null count 1) and adds the base to every other row.
    MUTANT: the `if old._validity:` arm dropped: the bitmap is lost and row 3
    reads as a value."""
    var rt = _make_started_runtime(2)
    ref disp = rt.dispatcher()
    var t = Table.from_batch(_narrow_chunk(10, 3))
    var out = widen_payload_table_parallel(
        t^, _plan(UInt8(2), Int64(1000)), _wide_schema(), Pointer(to=disp),
        CancellationToken.never(), 1,
    )
    rt.shutdown()
    ref col = out.chunks()[0].column_at(1)
    assert_true(col.arrow_type == ArrowType.INT64)
    assert_equal(col._null_count, 1)
    var arr = col.as_primitive[I64]()
    assert_true(arr.is_null(3))
    for i in range(10):
        if i != 3:
            assert_false(arr.is_null(i))
            assert_equal(arr.get(i), Int64(1000 + i))


def test_a_failing_tile_raises_on_the_serial_arm() raises:
    """A plan naming a source width the kernel does not read raises the
    kernel's own message.
    MUTANT: `_pn_widen_range`'s raise replaced by `return`: no raise."""
    var rt = _make_started_runtime(2)
    ref disp = rt.dispatcher()
    var t = Table.from_batch(_narrow_chunk(10, -1))
    with assert_raises(contains="widen asked for source width 3"):
        var out = widen_payload_table_parallel(
            t^, _plan(UInt8(3), Int64(0)), _wide_schema(), Pointer(to=disp),
            CancellationToken.never(), 1,
        )
        _ = out^
    rt.shutdown()


def test_a_failing_tile_raises_out_of_the_fork() raises:
    """The same plan over a table big enough to fork, on a runtime of ONE
    worker (`num_workers` 8 still tiles and forks): the tasks run one after
    another, so the first fails and records its message, and every later task
    sees the flag and returns at once. The driver raises with the message.
    MUTANT: the driver's `if raised:` raise dropped: a table comes back with
    unwritten buffers and no error."""
    var rows = 2 * _PN_MIN_PARALLEL_ROWS
    var rt = _make_started_runtime(1)
    ref disp = rt.dispatcher()
    var chunks = List[RecordBatch]()
    chunks.append(_narrow_chunk(rows, -1))
    chunks.append(_narrow_chunk(rows, -1))
    var t = Table.from_chunks(chunks^, _narrow_schema())
    with assert_raises(
        contains=(
            "widen_payload_table_parallel: join_payload_narrow_exec: widen"
            " asked for source width 3"
        )
    ):
        var out = widen_payload_table_parallel(
            t^, _plan(UInt8(3), Int64(0)), _wide_schema(), Pointer(to=disp),
            CancellationToken.never(), 8,
        )
        _ = out^
    rt.shutdown()


def _widen_two_chunks_serially(rows: Int, num_workers: Int) raises:
    """Two chunks of `rows` over a token cancelled before the call. Only the
    serial arm can succeed (a fork raises on the cancelled token before it
    enqueues), so widened values prove the fork was not taken."""
    var tok = CancellationToken.new()
    tok.cancel(String("the serial arm must not fork"))
    var rt = _make_started_runtime(num_workers)
    ref disp = rt.dispatcher()
    var chunks = List[RecordBatch]()
    chunks.append(_narrow_chunk(rows, -1))
    chunks.append(_narrow_chunk(rows, -1))
    var t = Table.from_chunks(chunks^, _narrow_schema())
    var out = widen_payload_table_parallel(
        t^, _plan(UInt8(2), Int64(7)), _wide_schema(), Pointer(to=disp),
        tok^, num_workers,
    )
    rt.shutdown()
    assert_equal(out.num_chunks(), 2)
    for k in range(2):
        ref ch = out.chunks()[k]
        assert_true(ch.column_at(1).arrow_type == ArrowType.INT64)
        var vc = ch.column_at(1).as_primitive[I64]()
        assert_equal(vc.get(rows - 1), Int64((rows - 1) % 50000 + 7))
    _ = out^


def test_one_worker_widens_serially_above_the_fork_threshold() raises:
    """`num_workers` 1 over 2 x 65,536 rows: the row test alone would fork
    (one tile per chunk, two tasks), so only `num_workers < 2` keeps it
    serial.
    MUTANT: `num_workers < 2 or` dropped: the fork runs over the cancelled
    token and raises."""
    _widen_two_chunks_serially(_PN_MIN_PARALLEL_ROWS, 1)


def test_few_rows_widen_serially_on_a_pool() raises:
    """2 x 1,000 rows on four workers: one tile per chunk, two tasks, so only
    `total_rows < _PN_MIN_PARALLEL_ROWS` keeps it serial.
    MUTANT: `total_rows < _PN_MIN_PARALLEL_ROWS` dropped: the fork runs over
    the cancelled token and raises."""
    _widen_two_chunks_serially(1000, 4)


def main() raises:
    test_no_chunks_still_carries_the_wide_schema()
    test_a_validity_bitmap_survives_the_widen()
    test_a_failing_tile_raises_on_the_serial_arm()
    test_a_failing_tile_raises_out_of_the_fork()
    test_one_worker_widens_serially_above_the_fork_threshold()
    test_few_rows_widen_serially_on_a_pool()
    print("All 6 widen edge tests passed.")
