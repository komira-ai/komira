# =============================================================================
# Tests -- SlabHashAggSinkStructCorr end to end
# =============================================================================
#
# The sink is driven directly (init_global, init_local, consume per worker,
# combine, combine_partition for every partition, finalize) and every
# group's CORR(x, y) is compared with the closed-form Pearson coefficient of
# that group's rows.
#
#   1. test_corr_three_workers_one_key -- three workers; group 1 is only in
#      workers 0 and 1 (not in worker 2, the survivor), so its partition
#      merge takes the MISS branch for worker 0 and the HIT branch for
#      worker 1; group 2 is in all three. The rows of each group have a
#      moderate correlation (|r| well below 1), where a merge that combines
#      a state twice (doubling n and the co-moments of the copy) shifts r
#      past the 1e-9 tolerance once another worker merges in. Catches that,
#      and a merge that keeps one side.
#   2. test_corr_two_keys_int64_inputs -- one worker, (k0, k1) keys and Int64
#      x and y columns (converted to Float64): (0, 1) and (1, 0) are two
#      groups, each with its own r. Catches the two-key probe collapsing
#      them, and x or y read from a key column (r is symmetric in x and y,
#      so a swap of the two is not observable).
# =============================================================================

from std.collections.optional import Optional
from std.math import sqrt
from std.memory import OwnedPointer, Pointer
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
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_collections.slab import Slab
from komira_op_agg_slab.slab_hash_agg_sink_struct_corr import (
    SlabHashAggSinkStructCorr,
)
from komira_op_agg_slab.slab_hash_agg_sink_struct_state import (
    N_PARTITIONS_SHAPE_B,
    SlabHashAggLocal,
)
from komira_operator_api.memory_reservation import MemoryReservation
from komira_operator_api.morsel_sink import MorselSink
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    ParquetSourceData,
)
from komira_plan_expr.agg_expr import AGG_CORR, AggExpr
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray, ExprArray


# =============================================================================
# Reference math
# =============================================================================


def _abs(x: Float64) -> Float64:
    if x < Float64(0.0):
        return -x
    return x


def _approx_equal(a: Float64, b: Float64, tol: Float64) -> Bool:
    var diff = _abs(a - b)
    if diff <= tol:
        return True
    return diff <= tol * (_abs(a) + _abs(b))


def _pearson(xs: List[Float64], ys: List[Float64]) -> Float64:
    """Two-pass Pearson correlation coefficient."""
    var n = len(xs)
    var mx = Float64(0.0)
    var my = Float64(0.0)
    for i in range(n):
        mx += xs[i]
        my += ys[i]
    mx /= Float64(n)
    my /= Float64(n)
    var c = Float64(0.0)
    var sx = Float64(0.0)
    var sy = Float64(0.0)
    for i in range(n):
        var dx = xs[i] - mx
        var dy = ys[i] - my
        c += dx * dy
        sx += dx * dx
        sy += dy * dy
    return c / sqrt(sx * sy)


# =============================================================================
# Fixtures
# =============================================================================


def _agg_sink_data_corr(num_keys: Int) raises -> AggSinkData:
    """CORR(x, y) GROUP BY the first `num_keys` columns."""
    var group_by = ExprArray()
    var osb = SchemaBuilder()
    for k in range(num_keys):
        var name = "k" + String(k)
        group_by.append(col(name).copy_expr())
        osb.add_field(Field(name, ArrowType.INT64, False))
    var aggs = AggExprArray()
    var none_alias: Optional[String] = None
    aggs.append(
        AggExpr(
            AGG_CORR,
            Optional[Expr](col("x").copy_expr()),
            Optional[Expr](col("y").copy_expr()),
            none_alias^,
        )
    )
    osb.add_field(Field("corr_xy", ArrowType.FLOAT64, False))
    return AggSinkData(group_by^, aggs^, osb.build(), False, 0)


def _empty_pq_data() raises -> ParquetSourceData:
    return ParquetSourceData(
        String(""),
        Optional[List[String]](None),
        Optional[Expr](None),
    )


def _batch_one_key_f64(
    keys: List[Int64], xs: List[Float64], ys: List[Float64]
) raises -> RecordBatch:
    """Columns: k0 Int64, x Float64, y Float64."""
    var n = len(keys)
    var k_arr = PrimitiveArray[DType.int64].allocate(n)
    var x_arr = PrimitiveArray[DType.float64].allocate(n)
    var y_arr = PrimitiveArray[DType.float64].allocate(n)
    var k_ptr = k_arr._typed_ptr_mut()
    var x_ptr = x_arr._typed_ptr_mut()
    var y_ptr = y_arr._typed_ptr_mut()
    for i in range(n):
        (k_ptr + i)[] = keys[i]
        (x_ptr + i)[] = xs[i]
        (y_ptr + i)[] = ys[i]
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, False))
    sb.add_field(Field("x", ArrowType.FLOAT64, False))
    sb.add_field(Field("y", ArrowType.FLOAT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](k_arr^))
    b.add_column(Column.from_primitive[DType.float64](x_arr^))
    b.add_column(Column.from_primitive[DType.float64](y_arr^))
    return b.build(sb.build())


def _finalize_and_extract_batch[
    K: MorselSink, disp_o: Origin[mut=True]
](
    sink: K,
    var sink_global: K.Global,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> K.Output:
    """Drive `sink.finalize` and take its single output."""
    var fr = sink.finalize(sink_global^, dispatcher_ptr, cancel_token^)
    if len(fr.output) != 1:
        raise Error("the sink returned output of length != 1")
    var out = fr.output.take_slot_unchecked(0)
    fr.output.set_len_unchecked(0)
    _ = fr^
    return out^


comptime _OneKeySink = SlabHashAggSinkStructCorr[0, 1, 2, DType.float64]
comptime _TwoKeySink = SlabHashAggSinkStructCorr[0, 2, 3, DType.int64]


# Per-row values of group g at its row i: x is a ramp, y mixes the ramp with
# a deterministic wobble, so |r| sits well inside (0, 1).
def _x_of(g: Int, i: Int) -> Float64:
    return Float64(i) + Float64(g) * 0.25


def _y_of(g: Int, i: Int) -> Float64:
    return (
        Float64(g) * Float64(i)
        + Float64((i * 7919) % 13) * 9.0
        - Float64((i * 104729) % 7) * 11.0
    )


# =============================================================================
# Test 1 -- three workers, one key, Float64 inputs
# =============================================================================


def test_corr_three_workers_one_key() raises:
    var sink = _OneKeySink.new(
        _agg_sink_data_corr(1), _empty_pq_data(), Slab[MorselOp](),
        num_workers=3,
    )
    var sink_global = sink.init_global()

    # Rows per (worker, group): group 1 lives in workers 0 and 1 only;
    # group 2 in all three.
    var all_x1 = List[Float64]()
    var all_y1 = List[Float64]()
    var all_x2 = List[Float64]()
    var all_y2 = List[Float64]()
    var row = 0
    var locals = Slab[OwnedPointer[SlabHashAggLocal]]()
    for w in range(3):
        var keys = List[Int64]()
        var xs = List[Float64]()
        var ys = List[Float64]()
        for _ in range(40):
            if w < 2:
                keys.append(Int64(1))
                xs.append(_x_of(1, row))
                ys.append(_y_of(1, row))
                all_x1.append(_x_of(1, row))
                all_y1.append(_y_of(1, row))
            keys.append(Int64(2))
            xs.append(_x_of(2, row))
            ys.append(_y_of(2, row))
            all_x2.append(_x_of(2, row))
            all_y2.append(_y_of(2, row))
            row += 1
        var local = sink.init_local()
        sink.consume(w, local, sink_global, _batch_one_key_f64(keys, xs, ys))
        locals.append(OwnedPointer[SlabHashAggLocal](local^))
    var ref1 = _pearson(all_x1, all_y1)
    var ref2 = _pearson(all_x2, all_y2)
    assert_true(_abs(ref1) < 0.95 and _abs(ref2) < 0.95)

    var reservation = MemoryReservation()
    sink.combine(sink_global, locals^, reservation)
    for p in range(N_PARTITIONS_SHAPE_B):
        sink.combine_partition(sink_global, p)

    var disp = LocalDispatcher[NoopSink]()
    var batch = _finalize_and_extract_batch(
        sink, sink_global^, Pointer(to=disp), CancellationToken.never(),
    )
    assert_equal(batch.num_rows(), 2)
    var keys_out = batch.column_as_primitive_int64(0)
    var r_out = batch.column_as_primitive_float64(1)
    var saw1 = False
    var saw2 = False
    for i in range(2):
        var k = keys_out.get_typed[Int64](i)
        var r = r_out.get_typed[Float64](i)
        if k == 1:
            saw1 = True
            assert_true(_approx_equal(r, ref1, 1e-9), "group 1 r")
        else:
            assert_equal(k, Int64(2))
            saw2 = True
            assert_true(_approx_equal(r, ref2, 1e-9), "group 2 r")
    assert_true(saw1 and saw2)


# =============================================================================
# Test 2 -- one worker, two keys, Int64 inputs
# =============================================================================


def test_corr_two_keys_int64_inputs() raises:
    var sink = _TwoKeySink.new(
        _agg_sink_data_corr(2), _empty_pq_data(), Slab[MorselOp](),
        num_workers=1,
    )
    var sink_global = sink.init_global()

    # Group (0, 1): y = 2x + wobble; group (1, 0): y = -x + wobble.
    comptime N = 30
    var k0 = PrimitiveArray[DType.int64].allocate(2 * N)
    var k1 = PrimitiveArray[DType.int64].allocate(2 * N)
    var xa = PrimitiveArray[DType.int64].allocate(2 * N)
    var ya = PrimitiveArray[DType.int64].allocate(2 * N)
    var k0p = k0._typed_ptr_mut()
    var k1p = k1._typed_ptr_mut()
    var xp = xa._typed_ptr_mut()
    var yp = ya._typed_ptr_mut()
    var gx_a = List[Float64]()
    var gy_a = List[Float64]()
    var gx_b = List[Float64]()
    var gy_b = List[Float64]()
    for i in range(N):
        var x = Int64(i)
        var ya_v = Int64(2 * i + (i * 31) % 5)
        var yb_v = Int64(-i + (i * 17) % 11)
        (k0p + 2 * i)[] = 0
        (k1p + 2 * i)[] = 1
        (xp + 2 * i)[] = x
        (yp + 2 * i)[] = ya_v
        (k0p + 2 * i + 1)[] = 1
        (k1p + 2 * i + 1)[] = 0
        (xp + 2 * i + 1)[] = x
        (yp + 2 * i + 1)[] = yb_v
        gx_a.append(Float64(x))
        gy_a.append(Float64(ya_v))
        gx_b.append(Float64(x))
        gy_b.append(Float64(yb_v))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, False))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    sb.add_field(Field("x", ArrowType.INT64, False))
    sb.add_field(Field("y", ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](k0^))
    bb.add_column(Column.from_primitive[DType.int64](k1^))
    bb.add_column(Column.from_primitive[DType.int64](xa^))
    bb.add_column(Column.from_primitive[DType.int64](ya^))
    var local = sink.init_local()
    sink.consume(0, local, sink_global, bb.build(sb.build()))
    var locals = Slab[OwnedPointer[SlabHashAggLocal]]()
    locals.append(OwnedPointer[SlabHashAggLocal](local^))

    var reservation = MemoryReservation()
    sink.combine(sink_global, locals^, reservation)
    for p in range(N_PARTITIONS_SHAPE_B):
        sink.combine_partition(sink_global, p)
    var disp = LocalDispatcher[NoopSink]()
    var batch = _finalize_and_extract_batch(
        sink, sink_global^, Pointer(to=disp), CancellationToken.never(),
    )
    assert_equal(batch.num_rows(), 2)
    var o0 = batch.column_as_primitive_int64(0)
    var o1 = batch.column_as_primitive_int64(1)
    var r_out = batch.column_as_primitive_float64(2)
    var ref_a = _pearson(gx_a, gy_a)
    var ref_b = _pearson(gx_b, gy_b)
    for i in range(2):
        var a = o0.get_typed[Int64](i)
        var b = o1.get_typed[Int64](i)
        var r = r_out.get_typed[Float64](i)
        if a == 0:
            assert_equal(b, Int64(1))
            assert_true(_approx_equal(r, ref_a, 1e-9), "group (0, 1) r")
        else:
            assert_equal(a, Int64(1))
            assert_equal(b, Int64(0))
            assert_true(_approx_equal(r, ref_b, 1e-9), "group (1, 0) r")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
