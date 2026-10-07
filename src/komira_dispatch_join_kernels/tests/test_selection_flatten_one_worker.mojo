"""`flatten_selection_table_parallel` on a runtime of ONE worker, where the
fork's tasks run one after another, and with a pool width of one, where the
fork is not taken at all.

With every chunk mislabelled, the first task fails and records its message,
and each later task must see the error flag and return without resolving its
chunk. The driver raises the first message. The welded test runs the same
failure on four workers, where the order of the tasks is not fixed; here it is,
so the early return is taken on every run.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_raises

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.selection_column import make_selection_column
from komira_arrow.table import Table
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import bridge_oab_to_sab

from komira_dispatch_join_kernels.selection_flatten_parallel import (
    SELECTION_FLATTEN_PARALLEL_MIN_ROWS,
    flatten_selection_table_parallel,
)


comptime I64 = DType.int64
comptime N_CHUNKS = 6
comptime CHUNK_ROWS = 2048
comptime BASE_ROWS = 64


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _dict_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field.dictionary("i_sel", ArrowType.INT32, False))
    return sb.build()


def _selection_table() raises -> Table:
    """`N_CHUNKS` chunks of one INT64 selection column over the chunk's own
    base."""
    var chunks = List[RecordBatch](capacity=N_CHUNKS)
    for k in range(N_CHUNKS):
        var base_arr = PrimitiveArray[I64].allocate(BASE_ROWS)
        for i in range(BASE_ROWS):
            base_arr.set(i, Int64(1000 * k + i))
        var base = Column.from_primitive[I64](base_arr^)
        var codes = OwnedAlignedBuffer(CHUNK_ROWS * 4)
        for r in range(CHUNK_ROWS):
            codes.set_typed[Scalar[DType.int32]](r, Int32((r * 5) % BASE_ROWS))
        codes.set_length(Int64(CHUNK_ROWS * 4))
        var sab = bridge_oab_to_sab[HeapRegion](codes^)
        var b = RecordBatchBuilder.with_capacity(1)
        b.add_column(make_selection_column(base, sab, 4, CHUNK_ROWS))
        chunks.append(b.build(_dict_schema()))
        _ = base^
        _ = sab^
    return Table.from_chunks(chunks^, _dict_schema())


def _flat_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i_sel", ArrowType.INT64, False))
    return sb.build()


def test_a_pool_width_of_one_flattens_serially() raises:
    """`num_workers` 1 over six chunks and 12,288 rows: the chunk and row
    tests alone would fork, so only `num_workers < 2` keeps it serial. The
    token is cancelled before the call, so a fork would raise; the serial
    flatten never dispatches and returns every value.
    MUTANT: `or num_workers < 2` dropped: the fork runs over the cancelled
    token and raises."""
    var tok = CancellationToken.new()
    tok.cancel(String("the serial arm must not fork"))
    var rt = _make_started_runtime(1)
    ref disp = rt.dispatcher()
    var out = flatten_selection_table_parallel(
        _selection_table(), _flat_schema(), Pointer(to=disp), tok^, 1,
    )
    rt.shutdown()
    assert_equal(out.num_chunks(), N_CHUNKS)
    assert_equal(out.num_rows(), N_CHUNKS * CHUNK_ROWS)
    for k in range(N_CHUNKS):
        ref ch = out.chunks()[k]
        var col = ch.column_at(0).as_primitive[I64]()
        for r in range(0, CHUNK_ROWS, 61):
            assert_equal(col.get(r), Int64(1000 * k + (r * 5) % BASE_ROWS))
    _ = out^


def test_later_tasks_return_once_one_has_failed() raises:
    """Every chunk fails; the first message comes out of the fork.
    MUTANT: the driver's `raise Error(raised_msg)` dropped: a table comes
    back. Dropping the task's early return instead changes no outcome (each
    later task fails the same way and loses the compare-exchange), so no
    assertion can see it: the early return only saves work."""
    assert_equal(
        N_CHUNKS * CHUNK_ROWS >= SELECTION_FLATTEN_PARALLEL_MIN_ROWS, True
    )
    var wrong = SchemaBuilder()
    wrong.add_field(Field("i_sel", ArrowType.INT32, False))
    var rt = _make_started_runtime(1)
    ref disp = rt.dispatcher()
    with assert_raises(contains="flatten_selection_batch"):
        var out = flatten_selection_table_parallel(
            _selection_table(), wrong.build(), Pointer(to=disp),
            CancellationToken.never(), 4,
        )
        _ = out^
    rt.shutdown()


def main() raises:
    test_later_tasks_return_once_one_has_failed()
    test_a_pool_width_of_one_flattens_serially()
    print("All 2 one-worker selection flatten tests passed.")
