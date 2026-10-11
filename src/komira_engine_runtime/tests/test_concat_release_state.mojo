# =============================================================================
# CONCAT TEARDOWN WAVE + STATE SLAB MOVE-OUT -- release-exactly-once falsifier
# =============================================================================
#
# `streaming_concat_parallel` hands its input batches to the pool to be
# destroyed (`release_concat_inputs_parallel`), and its three drivers move each
# slab out of their per-dispatch State after the drain barrier. Both are
# ownership transfers whose failure modes are silent until the allocator
# notices: a slot destroyed TWICE (a double free), or a slot never destroyed (a
# leak), or a slot read after it was moved out (a use-after-move).
#
# THE INSTRUMENT. Every fixture batch's value buffer is Arc-shared once more
# into a PROBE the test keeps. While the batch lives the buffer's strong count
# is 2; once the batch has been destroyed exactly once it is 1. So after a
# release:
#     count == 1   -> destroyed exactly once          (the contract)
#     count == 2   -> never destroyed (a leak / a slot nobody took)
#     a crash      -> destroyed twice (a double free), which this file's
#                     repeated, pool-backed runs are built to provoke
# The counts are read after the call returns, so they are deterministic: the
# call's own barrier has rejoined every worker.
#
# ARMS: success on the pool (release forked), the serial declines (under the
# row floor, one worker), the CANCELLED-token path (the dispatch raises, some
# slots may not have been taken; the length must still be zeroed or the slab
# destroys the taken ones a second time), and the full concat driver on both the
# column-parallel and the tiled routes, whose State slabs are moved out by
# `_take_slab`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_engine_runtime.streaming_concat_parallel import (
    concat_record_batches_column_parallel,
    release_concat_inputs_parallel,
)

comptime _WORKERS: Int = 4
comptime _ROWS_PER_BATCH: Int = 20_000
"""Six of these exceed both the teardown wave's row floor (65,536) and the
tiled route's (131,072)."""


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _int_batch(base: Int, n: Int, cols: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    for c in range(cols):
        var a = PrimitiveArray[DType.int64].allocate(n)
        var p = a._typed_ptr_mut()
        for j in range(n):
            p[j] = Int64((base + j) * (c + 2) + 1)
        sb.add_field(Field("v" + String(c), ArrowType.INT64, False))
        b.add_column(Column.from_primitive[DType.int64](a^))
    return b.build(sb.build())


def _make_inputs(
    n_batches: Int,
    rows: Int,
    cols: Int,
    mut probes: List[SharedAlignedBuffer[HeapRegion]],
) raises -> Slab[Optional[RecordBatch]]:
    """The input slab; `probes` receives one share of each batch's column-0
    value buffer, so its strong count reads 2 while the batch lives."""
    var slab = Slab[Optional[RecordBatch]].create(n_batches)
    for m in range(n_batches):
        var b = _int_batch(m * rows, rows, cols)
        probes.append(b.column_at(0)._data.share())
        slab.append(Optional[RecordBatch](b^))
    return slab^


def _count(imm probe: SharedAlignedBuffer[HeapRegion]) -> Int:
    return Int(probe._region.count())


def _assert_all_released(label: String, imm probes: List[SharedAlignedBuffer[HeapRegion]]) raises:
    for m in range(len(probes)):
        var c = _count(probes[m])
        if c != 1:
            raise Error(
                label + ": batch " + String(m) + " has strong count "
                + String(c) + " after the release; exactly-once destruction"
                " leaves 1 (2 means the slot was NEVER destroyed)."
            )


def _runtime(workers: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=workers,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def test_release_on_pool_destroys_each_batch_exactly_once() raises:
    for it in range(8):
        var n = 6 + it
        var probes = List[SharedAlignedBuffer[HeapRegion]]()
        var slab = _make_inputs(n, _ROWS_PER_BATCH, 1, probes)
        _assert_probes_live(String("pre-release ") + String(it), probes)
        var runtime = _runtime(_WORKERS)
        ref disp = runtime.dispatcher()
        release_concat_inputs_parallel(
            slab^, n * _ROWS_PER_BATCH, disp, CancellationToken.new()
        )
        _ = runtime^
        _assert_all_released(String("pool release ") + String(it), probes)


def _assert_probes_live(label: String, imm probes: List[SharedAlignedBuffer[HeapRegion]]) raises:
    for m in range(len(probes)):
        assert_equal(
            _count(probes[m]), 2,
            label + ": the probe must make the count 2 while the batch lives"
            " (otherwise a count of 1 afterwards proves nothing)",
        )


def test_release_serial_declines_destroy_each_batch_exactly_once() raises:
    # Under the teardown wave's row floor.
    var small_probes = List[SharedAlignedBuffer[HeapRegion]]()
    var small = _make_inputs(6, 1_000, 1, small_probes)
    var rt1 = _runtime(_WORKERS)
    ref d1 = rt1.dispatcher()
    release_concat_inputs_parallel(
        small^, 6_000, d1, CancellationToken.new()
    )
    _ = rt1^
    _assert_all_released(String("under-floor decline"), small_probes)

    # One worker: one task would be pure overhead.
    var big_probes = List[SharedAlignedBuffer[HeapRegion]]()
    var big = _make_inputs(6, _ROWS_PER_BATCH, 1, big_probes)
    var rt2 = _runtime(1)
    ref d2 = rt2.dispatcher()
    release_concat_inputs_parallel(
        big^, 6 * _ROWS_PER_BATCH, d2, CancellationToken.new()
    )
    _ = rt2^
    _assert_all_released(String("one-worker decline"), big_probes)


def test_release_with_cancelled_token_never_double_destroys() raises:
    # A cancelled token makes the dispatch raise with some (possibly all)
    # slots untaken. The contract is leak-not-double-free: every batch is
    # destroyed AT MOST once, and the call neither crashes nor swallows the
    # cancellation as success while leaving slots behind.
    for it in range(8):
        var n = 6 + it
        var probes = List[SharedAlignedBuffer[HeapRegion]]()
        var slab = _make_inputs(n, _ROWS_PER_BATCH, 1, probes)
        var ct = CancellationToken.new()
        ct.cancel(String("test: cancel before the teardown wave"))
        var runtime = _runtime(_WORKERS)
        ref disp = runtime.dispatcher()
        var raised = False
        try:
            release_concat_inputs_parallel(
                slab^, n * _ROWS_PER_BATCH, disp, ct^
            )
        except:
            raised = True
        _ = runtime^
        for m in range(len(probes)):
            var c = _count(probes[m])
            if c < 1 or c > 2:
                raise Error(
                    "cancelled release " + String(it) + ": batch " + String(m)
                    + " has strong count " + String(c) + " (expected 1 or 2)"
                )
            if not raised and c != 1:
                raise Error(
                    "cancelled release " + String(it) + ": the call returned"
                    " normally but batch " + String(m) + " was never destroyed"
                )


def _concat_and_check(n_batches: Int, rows: Int, cols: Int, label: String) raises:
    var probes = List[SharedAlignedBuffer[HeapRegion]]()
    var opt_slab = _make_inputs(n_batches, rows, cols, probes)
    var total = n_batches * rows
    var runtime = _runtime(_WORKERS)
    ref disp = runtime.dispatcher()
    var batches = Slab[RecordBatch].create(n_batches)
    for m in range(n_batches):
        var taken = opt_slab.take_slot_unchecked(m)
        batches.append(taken.take())
    opt_slab.set_len_unchecked(0)
    _ = opt_slab^
    var out = concat_record_batches_column_parallel(
        batches^, disp, CancellationToken.new()
    )
    _ = runtime^
    assert_equal(out.num_rows(), total, label + ": row count")
    assert_equal(out.num_columns(), cols, label + ": column count")
    # Values: column c, row r == r * (c + 2) + 1, regenerated independently.
    for c in range(cols):
        ref col = out.column_at(c)
        for r in range(0, total, 97):
            var got = col._data.get_typed[Int64](r)
            assert_equal(Int(got), r * (c + 2) + 1, label + ": value")
    # The inputs were all consumed by the concat and destroyed exactly once.
    _assert_all_released(label + " inputs", probes)


def test_column_parallel_driver_releases_inputs_exactly_once() raises:
    # Two columns, rows under the tiling floor: the one-task-per-column route.
    for it in range(4):
        _concat_and_check(6, 9_000, 3, String("column route ") + String(it))


def test_tiled_driver_releases_inputs_exactly_once() raises:
    # Rows over the tiling floor: the row-range tiled route.
    for it in range(4):
        _concat_and_check(8, _ROWS_PER_BATCH, 2, String("tiled route ") + String(it))


def _cancelled_concat_and_check(
    n_batches: Int, rows: Int, cols: Int, label: String
) raises:
    """The RAISING path of a driver: the token is cancelled before the call, so
    the dispatch fails and the driver takes its `raised` arm. That arm drops the
    moved-out input slab SERIALLY (a teardown dispatch on a cancelled token
    would raise a second error and mask the first), drops the half-built output
    and re-raises. The contract: the call raises, and every input batch is
    destroyed exactly once all the same, so the failure path neither leaks the
    inputs nor frees a slot twice."""
    var probes = List[SharedAlignedBuffer[HeapRegion]]()
    var opt_slab = _make_inputs(n_batches, rows, cols, probes)
    _assert_probes_live(label, probes)
    var runtime = _runtime(_WORKERS)
    ref disp = runtime.dispatcher()
    var batches = Slab[RecordBatch].create(n_batches)
    for m in range(n_batches):
        var taken = opt_slab.take_slot_unchecked(m)
        batches.append(taken.take())
    opt_slab.set_len_unchecked(0)
    _ = opt_slab^
    var ct = CancellationToken.new()
    ct.cancel(String("test: cancel before the concat dispatch"))
    var raised = False
    try:
        var out = concat_record_batches_column_parallel(
            batches^, disp, ct^
        )
        _ = out^
    except:
        raised = True
    _ = runtime^
    assert_true(raised, label + ": a cancelled token must make the concat raise, not succeed")
    _assert_all_released(label + " inputs after the raise", probes)


def test_column_parallel_driver_raising_path_releases_inputs_exactly_once() raises:
    for it in range(4):
        _cancelled_concat_and_check(
            6, 9_000, 3, String("cancelled column route ") + String(it)
        )


def test_tiled_driver_raising_path_releases_inputs_exactly_once() raises:
    for it in range(4):
        _cancelled_concat_and_check(
            8, _ROWS_PER_BATCH, 2, String("cancelled tiled route ") + String(it)
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
