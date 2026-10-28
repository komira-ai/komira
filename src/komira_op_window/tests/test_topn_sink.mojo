# =============================================================================
# test_topn_sink -- TopNSink through consume / combine / finalize
# =============================================================================
#
# The sink's rows are `_execute_topn_sink`'s over the workers' batches folded
# in worker order: checked against that kernel run directly, for a heap-sized
# and a full-sort-sized N, with a worker that sends nothing, with zero-row
# batches, and with no rows at all (an empty result). A small fixture with
# NULL keys, an ASC key, an N past the input and both NULL placements is
# checked against rows worked out by hand.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_collections.slab import Slab
from komira_column_kernels.batch_slice import _slice_batch_range
from komira_column_kernels.compiler_helpers import copy_batch
from komira_op_sort.sort_topn_sink import _execute_topn_sink
from komira_operator_api.memory_reservation import MemoryReservation
from komira_physical_plan.physical_plan import TopNSinkData

from komira_op_window.topn_sink import TopNSink, TopNSinkLocal


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _batch(n: Int) raises -> RecordBatch:
    """k = (r * 7919) % 1000 (ties), v = r."""
    var k = List[Scalar[DType.int64]](capacity=n)
    var v = List[Scalar[DType.int64]](capacity=n)
    for r in range(n):
        k.append(Int64((r * 7919) % 1000))
        v.append(Int64(r))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(k)))
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(v)))
    return bb.build(sb.build())


def _spec(n: Int) -> TopNSinkData:
    var keys: List[String] = ["k"]
    var desc: List[Bool] = [True]
    return TopNSinkData(keys^, desc^, n)


def _drive(full: RecordBatch, cuts: List[Int], n: Int) raises -> RecordBatch:
    return _drive_spec(full, cuts, _spec(n))


def _drive_spec(full: RecordBatch, cuts: List[Int], var spec: TopNSinkData) raises -> RecordBatch:
    """Worker w consumes rows [cuts[w], cuts[w+1]) as two batches (the
    second may have zero rows)."""
    var sink = TopNSink(spec^)
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var g = sink.init_global()
    var nw = len(cuts) - 1
    var states = Slab[OwnedPointer[TopNSinkLocal]].create(nw)
    for w in range(nw):
        var local = sink.init_local()
        var lo = cuts[w]
        var hi = cuts[w + 1]
        var mid = (lo + hi) // 2
        if hi > lo:
            sink.consume(w, local, g, _slice_batch_range(full, lo, mid - lo))
            sink.consume(w, local, g, _slice_batch_range(full, mid, hi - mid))
        states.append(OwnedPointer[TopNSinkLocal](local^))
    var reservation = MemoryReservation()
    sink.combine(g, states^, reservation)
    var fo = sink.finalize(g^, Pointer(to=disp), ct.clone())
    var out = fo.output.take_slot_unchecked(0)
    fo.output.set_len_unchecked(0)
    _ = fo^
    _ = runtime^
    return out^


def _assert_same(a: RecordBatch, b: RecordBatch) raises:
    assert_equal(a.num_rows(), b.num_rows())
    for c in range(a.num_columns()):
        ref ca = a.column_at(c)
        ref cb = b.column_at(c)
        for r in range(a.num_rows()):
            if ca._data.get_typed[Scalar[DType.int64]](ca._offset + r) != cb._data.get_typed[Scalar[DType.int64]](cb._offset + r):
                raise Error("col " + String(c) + " row " + String(r))


def test_topn_sink_equals_the_kernel() raises:
    var full = _batch(20_000)
    var cuts: List[Int] = [0, 7_000, 7_000, 20_000]
    for n in [10, 15_000]:
        var out = _drive(full, cuts, n)
        var want = _execute_topn_sink(copy_batch(full), _spec(n))
        _assert_same(out, want)
        assert_equal(out.num_rows(), n)


def test_topn_sink_ties_keep_the_first_rows() raises:
    # Descending top 10: key 999 occurs 20 times in 20000 rows, so the cut
    # falls inside a run of ties. The rows kept are the first ten rows with
    # key 999, in row order (what a stable full sort then a slice gives),
    # worker split notwithstanding.
    var full = _batch(20_000)
    var cuts: List[Int] = [0, 7_000, 7_000, 20_000]
    var out = _drive(full, cuts, 10)
    assert_equal(out.num_rows(), 10)
    ref cv = out.column_at(1)
    ref ck = out.column_at(0)
    var next_row = 0
    for i in range(10):
        while (next_row * 7919) % 1000 != 999:
            next_row += 1
        assert_equal(ck._data.get_typed[Scalar[DType.int64]](ck._offset + i), 999)
        assert_equal(cv._data.get_typed[Scalar[DType.int64]](cv._offset + i), Int64(next_row))
        next_row += 1


def test_topn_sink_no_rows() raises:
    var full = _batch(10)
    var cuts: List[Int] = [0, 0, 0]
    var out = _drive(full, cuts, 5)
    assert_equal(out.num_rows(), 0)


def test_topn_sink_n_past_the_input() raises:
    # N larger than the row count returns every row, as the kernel does.
    var full = _batch(20_000)
    var cuts: List[Int] = [0, 7_000, 7_000, 20_000]
    var out = _drive(full, cuts, 30_000)
    assert_equal(out.num_rows(), 20_000)
    _assert_same(out, _execute_topn_sink(copy_batch(full), _spec(30_000)))
    # Seven rows, N = 50: all seven, in sort order (see _nullable_fixture).
    var small = _nullable_fixture()
    var want: List[Int64] = [5, 2, 6, 0, 3, 1, 4]
    var small_cuts: List[Int] = [0, 3, 3, 7]
    _check_v(_drive_spec(small, small_cuts, _spec2(50, False, False)), want)


def _nullable_fixture() raises -> RecordBatch:
    """k = 5 NULL 3 5 NULL 1 3 (NULL at rows 1 and 4, stored value 9), v =
    row index."""
    var k: List[Int64] = [5, 9, 3, 5, 9, 1, 3]
    var arr = PrimitiveArray[DType.int64].allocate_nullable(7)
    var v = PrimitiveArray[DType.int64].allocate(7)
    for r in range(7):
        arr.store[1](r, k[r])
        v.store[1](r, Int64(r))
    arr._set_null(1)
    arr._set_null(4)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](arr^))
    bb.add_column(Column.from_primitive[DType.int64](v^))
    return bb.build(sb.build())


def _spec2(n: Int, desc: Bool, nulls_first: Bool) -> TopNSinkData:
    var keys: List[String] = ["k"]
    var d: List[Bool] = [desc]
    var nf: List[Bool] = [nulls_first]
    return TopNSinkData(keys^, d^, n, nf^)


def _check_v(got: RecordBatch, want: List[Int64]) raises:
    assert_equal(got.num_rows(), len(want))
    ref cv = got.column_at(1)
    for i in range(len(want)):
        assert_equal(cv._data.get_typed[Scalar[DType.int64]](cv._offset + i), want[i])


def test_topn_sink_null_slots_and_asc_by_hand() raises:
    # The kernel orders a numeric NULL slot by its stored value and does not
    # read `nulls_first` (komira_op_sort.sort_topn_sink). The NULL rows (1 and
    # 4) store 9, above every value, so ASC puts them last and DESC first.
    var full = _nullable_fixture()
    var cuts: List[Int] = [0, 3, 3, 7]
    # ASC, N = 5: keys 1 3 3 5 5 are rows 5 2 6 0 3.
    var asc5: List[Int64] = [5, 2, 6, 0, 3]
    _check_v(_drive_spec(full, cuts, _spec2(5, False, False)), asc5)
    # A NULLS FIRST request changes nothing.
    _check_v(_drive_spec(full, cuts, _spec2(5, False, True)), asc5)
    # N = 6 reaches the first stored-9 row.
    var asc6: List[Int64] = [5, 2, 6, 0, 3, 1]
    _check_v(_drive_spec(full, cuts, _spec2(6, False, False)), asc6)
    # DESC, N = 4: the two 9s (rows 1, 4) then the 5s (rows 0, 3).
    var desc4: List[Int64] = [1, 4, 0, 3]
    _check_v(_drive_spec(full, cuts, _spec2(4, True, False)), desc4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
