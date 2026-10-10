# =============================================================================
# test_udf_e2e_window_fn.mojo: custom WindowFns over a ROWS frame, read
# through `FrameView`, with frames clipped at partition edges.
# =============================================================================
#
# Two UDFs over a 9-row batch already in (partition, order) order, three
# partitions: rows [0, 4), the single row [4, 5), and [5, 9). Each declares
# `ROWS BETWEEN 1 PRECEDING AND 2 FOLLOWING`.
#   * `WeightedFrameSum` (int64 `v`, float64 `w`): sum of `v * w` over the
#     frame, every frame row read with `FrameView.get_at` (runtime index).
#   * `FirstALastB` (int32 `a`, float32 `b`): `1000 * a` of the frame's first
#     row (`FrameView.get[0, ...]`, comptime index) plus `b` of its last row.
# The four input dtypes are the four `FrameView` reads.
#
# What komira does not have, so this test does not claim it:
#   * A FRAME SCAN. Nothing in komira turns a `WindowFrameSpec` into a row's
#     `[lo, hi)`, clips it to the partition, finds partition boundaries, or
#     emits NULL for an empty frame (the `BREAKER_WINDOW_UDF` breaker that
#     `stage_program` describes is not in komira). So the frames below are
#     LITERALS, written by hand from the declared frame, and the test checks
#     the UDF and `FrameView` over them, not the clipping.
#   * NULLS. `FrameView` exposes no validity, so a `WindowFn` cannot tell a
#     NULL input from the 0 in its slot. The inputs here are therefore all
#     valid; a window UDF over a nullable column has no way to honour SQL
#     null semantics through this trait today.
#
# Planted mutant (reverted): `FrameView.__len__`, `self._hi - self._lo` ->
# `self._hi - self._lo - 1`. `test_weighted_frame_sum` and
# `test_first_a_last_b` went red ("frame width row 0": 2 instead of 3), and
# `test_state_is_per_partition_and_defaults_delegate` too (the default `emit`
# summed three of the four frame rows: 14.5 instead of 30.5); no other welded
# test in the rebuilt closure did.
#
# Planted mutant (reverted; in this file's stand-in driver, since komira has
# no window driver to plant it in): `_run` calls `prepare_partition` once,
# before the partition loop, so one state crosses all three partitions.
# `test_weighted_frame_sum` and `test_first_a_last_b` went red ("frames
# counted by partition 1's state": 5 instead of 1).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.partition_expr import (
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_RANGE,
    FRAME_UNITS_ROWS,
)

from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.frame_view import FrameView
from komira_udf.partition_row_view import MAX_PARTITION_UDF_ARITY
from komira_udf.schema_descriptor import DT_F64, DT_I32, DT_I64, schema_of
from komira_udf.stateful_contract import KeyList
from komira_udf.window_fn import WindowFn
from komira_udf.window_frame_spec import WindowFrameSpec

from komira_udf_e2e.columns import (
    all_valid,
    f32_column,
    f64_column,
    i32_column,
    i64_column,
)


# --- the UDFs ---------------------------------------------------------------------


@fieldwise_init
struct FramesSeen(Copyable, Movable):
    """Per-partition state: how many frames this partition has computed."""

    var n: Int


@fieldwise_init
struct VW(AutoKomiraSchema, Copyable, Movable):
    var v: Int64
    var w: Float64


@fieldwise_init
struct AB(AutoKomiraSchema, Copyable, Movable):
    var a: Int32
    var b: Float32


comptime ROWS_1P_2F = WindowFrameSpec.rows(
    FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_FOLLOWING, 2
)


@fieldwise_init
struct WeightedFrameSum(WindowFn):
    comptime InRow = VW
    comptime OutputSchema = schema_of["wsum", DT_F64]()
    comptime OutType = DType.float64
    comptime UDF_ID = UInt32(20_201)
    comptime State = FramesSeen
    comptime PART_KEYS = KeyList()
    comptime ORDER_KEYS = KeyList()
    comptime frame = ROWS_1P_2F

    def init_partition(self) -> FramesSeen:
        return FramesSeen(0)

    def compute_frame[
        origin: Origin[mut=False]
    ](self, mut s: FramesSeen, view: FrameView[origin]) raises -> Float64:
        s.n += 1
        var acc = Float64(0)
        for i in range(view.__len__()):
            acc += Float64(view.get_at[0, DType.int64](i)) * view.get_at[
                1, DType.float64
            ](i)
        return acc


@fieldwise_init
struct FirstALastB(WindowFn):
    comptime InRow = AB
    comptime OutputSchema = schema_of["first_a_last_b", DT_F64]()
    comptime OutType = DType.float64
    comptime UDF_ID = UInt32(20_202)
    comptime State = FramesSeen
    comptime PART_KEYS = KeyList()
    comptime ORDER_KEYS = KeyList()
    comptime frame = ROWS_1P_2F

    def init_partition(self) -> FramesSeen:
        return FramesSeen(0)

    def compute_frame[
        origin: Origin[mut=False]
    ](self, mut s: FramesSeen, view: FrameView[origin]) raises -> Float64:
        s.n += 1
        var first_a = view.get[0, 0, DType.int32]()
        var last_b = view.get_at[1, DType.float32](view.__len__() - 1)
        return Float64(first_a) * 1000.0 + Float64(last_b)


# --- the batch and its frames -----------------------------------------------------
#
#   row  part  v   w    v*w   a   b    frame [lo, hi) for 1 PRECEDING .. 2 FOLLOWING
#    0   0     1   1.0  1     11  0.5  [0, 3)   clipped at the partition start
#    1   0     2   0.5  1     12  1.5  [0, 4)
#    2   0     3   2.0  6     13  2.5  [1, 4)   clipped at the partition end
#    3   0     4   1.0  4     14  3.5  [2, 4)   clipped at the partition end
#    4   1    10   3.0  30    15  4.5  [4, 5)   a one-row partition
#    5   2     5   1.0  5     16  5.5  [5, 8)   clipped at the partition start
#    6   2     6   1.0  6     17  6.5  [5, 9)
#    7   2     7   0.5  3.5   18  7.5  [6, 9)   clipped at the partition end
#    8   2     8   2.0  16    19  8.5  [7, 9)   clipped at the partition end


def _batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("v", DType.int64, False))
    sb.add_field(Field("w", DType.float64, False))
    sb.add_field(Field("a", DType.int32, False))
    sb.add_field(Field("b", DType.float32, False))
    var v: List[Int64] = [1, 2, 3, 4, 10, 5, 6, 7, 8]
    var w: List[Float64] = [1.0, 0.5, 2.0, 1.0, 3.0, 1.0, 1.0, 0.5, 2.0]
    var a: List[Int32] = [11, 12, 13, 14, 15, 16, 17, 18, 19]
    var b: List[Float32] = [0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5]
    var ok = all_valid(9)
    return RecordBatch.from_typed_columns_4(
        sb.build(),
        i64_column(v, ok),
        f64_column(w, ok),
        i32_column(a, ok),
        f32_column(b, ok),
    )


def _part_starts() -> List[Int]:
    return [0, 4, 5]


def _lo() -> List[Int]:
    return [0, 0, 1, 2, 4, 5, 5, 6, 7]


def _hi() -> List[Int]:
    return [3, 4, 4, 4, 5, 8, 9, 9, 9]


def _run[
    F: WindowFn
](f: F, batch: RecordBatch, col0: Int, col1: Int) raises -> List[
    Scalar[F.OutType]
]:
    """Per partition a fresh state (`prepare_partition`), per row one
    `FrameView` over the literal frame, `compute_frame` called on it. At the
    end of each partition the state must have counted exactly that
    partition's rows (4, 1, 4): a state shared or carried across partitions
    would read 5 at the one-row partition and 9 at the last."""
    var cols = Array[Int, MAX_PARTITION_UDF_ARITY](fill=-1)
    cols[0] = col0
    cols[1] = col1
    var ptr = Pointer(to=batch)
    var out = List[Scalar[F.OutType]]()
    var starts = _part_starts()
    var lo = _lo()
    var hi = _hi()
    for p in range(len(starts)):
        var start = starts[p]
        var end = starts[p + 1] if p + 1 < len(starts) else batch.num_rows()
        var s = f.prepare_partition()
        for r in range(start, end):
            var view = FrameView(ptr, cols, lo[r], hi[r])
            assert_equal(view.__len__(), hi[r] - lo[r], "frame width row " + String(r))
            out.append(f.compute_frame(s, view))
        assert_equal(
            rebind[FramesSeen](s).n,
            end - start,
            "frames counted by partition " + String(p) + "'s state",
        )
        _ = s^
    return out^


def test_weighted_frame_sum() raises:
    var batch = _batch()
    var got = _run(WeightedFrameSum(), batch, 0, 1)
    var want: List[Float64] = [8.0, 12.0, 11.0, 10.0, 30.0, 14.5, 30.5, 25.5, 19.5]
    assert_equal(len(got), len(want))
    for r in range(len(want)):
        assert_equal(got[r], want[r], "wsum row " + String(r))


def test_first_a_last_b() raises:
    var batch = _batch()
    var got = _run(FirstALastB(), batch, 2, 3)
    var want: List[Float64] = [
        11002.5, 11003.5, 12003.5, 13003.5, 15004.5,
        16007.5, 16008.5, 17008.5, 18008.5,
    ]
    assert_equal(len(got), len(want))
    for r in range(len(want)):
        assert_equal(got[r], want[r], "first_a_last_b row " + String(r))


def test_state_is_per_partition_and_defaults_delegate() raises:
    """`prepare_partition` defaults to `init_partition` (a fresh count per
    partition); the invertible-path defaults are a no-op `enter_row` /
    `leave_row` and an `emit` that is `compute_frame`."""
    var batch = _batch()
    var f = WeightedFrameSum()
    var cols = Array[Int, MAX_PARTITION_UDF_ARITY](fill=-1)
    cols[0] = 0
    cols[1] = 1
    var ptr = Pointer(to=batch)
    var s = f.prepare_partition()
    assert_equal(s.n, 0)
    var view = FrameView(ptr, cols, 5, 9)
    f.enter_row(s, view, 0)
    f.leave_row(s, view, 3)
    assert_equal(s.n, 0, "the default enter_row/leave_row touched the state")
    assert_equal(f.emit(s, view), 30.5, "the default emit is compute_frame")
    assert_equal(s.n, 1)
    assert_equal(f.compute_frame(s, view), 30.5)
    assert_equal(s.n, 2)
    var fresh = f.prepare_partition()
    assert_equal(fresh.n, 0, "a new partition starts from init_partition")
    assert_true(not WeightedFrameSum.invertible)


def test_declared_frame_and_schemas() raises:
    var fr = materialize[WeightedFrameSum.frame]()
    assert_equal(fr.units, FRAME_UNITS_ROWS)
    assert_equal(fr.start_tag, FRAME_BOUND_PRECEDING)
    assert_equal(fr.start_offset, 1)
    assert_equal(fr.end_tag, FRAME_BOUND_FOLLOWING)
    assert_equal(fr.end_offset, 2)
    var wi = materialize[WeightedFrameSum.InputSchema]()
    assert_equal(wi.num_cols(), 2)
    assert_equal(wi.cols[0].name, "v")
    assert_equal(wi.cols[0].dtype, DT_I64)
    assert_equal(materialize[FirstALastB.InputSchema]().cols[0].dtype, DT_I32)
    assert_true(WeightedFrameSum.ORDER_KEY_DT == DType.int64)
    assert_equal(materialize[WeightedFrameSum.PART_KEYS]().num_keys(), 0)


def test_frame_spec_constructors() raises:
    """Each named constructor's (units, start, end) against the SQL it names."""
    var t = WindowFrameSpec.rows_between_preceding_and_current(3)
    assert_equal(t.units, FRAME_UNITS_ROWS)
    assert_equal(t.start_tag, FRAME_BOUND_PRECEDING)
    assert_equal(t.start_offset, 3)
    assert_equal(t.end_tag, FRAME_BOUND_CURRENT_ROW)
    var run = WindowFrameSpec.rows_running()
    assert_equal(run.start_tag, FRAME_BOUND_UNBOUNDED_PRECEDING)
    assert_equal(run.end_tag, FRAME_BOUND_CURRENT_ROW)
    var full = WindowFrameSpec.rows_full_partition()
    assert_equal(full.start_tag, FRAME_BOUND_UNBOUNDED_PRECEDING)
    assert_equal(full.end_tag, FRAME_BOUND_UNBOUNDED_FOLLOWING)
    var r = WindowFrameSpec.range(FRAME_BOUND_PRECEDING, 5, FRAME_BOUND_FOLLOWING, 7)
    assert_equal(r.units, FRAME_UNITS_RANGE)
    assert_equal(r.start_offset, 5)
    assert_equal(r.end_offset, 7)
    var rt = WindowFrameSpec.range_between_preceding_and_current(2)
    assert_equal(rt.units, FRAME_UNITS_RANGE)
    assert_equal(rt.start_tag, FRAME_BOUND_PRECEDING)
    assert_equal(rt.start_offset, 2)
    assert_equal(rt.end_tag, FRAME_BOUND_CURRENT_ROW)
    var rr = WindowFrameSpec.range_running()
    assert_equal(rr.units, FRAME_UNITS_RANGE)
    assert_equal(rr.start_tag, FRAME_BOUND_UNBOUNDED_PRECEDING)
    var rf = WindowFrameSpec.range_full_partition()
    assert_equal(rf.units, FRAME_UNITS_RANGE)
    assert_equal(rf.end_tag, FRAME_BOUND_UNBOUNDED_FOLLOWING)


def test_frame_view_reads_every_dtype() raises:
    """Both `FrameView` reads, comptime-indexed `get` and runtime-indexed
    `get_at`, for each of the four input dtypes, over the frame [5, 9):
    frame row k is batch row 5 + k."""
    var batch = _batch()
    var cols = Array[Int, MAX_PARTITION_UDF_ARITY](fill=-1)
    cols[0] = 0  # v  int64
    cols[1] = 1  # w  float64
    cols[2] = 2  # a  int32
    cols[3] = 3  # b  float32
    var view = FrameView(Pointer(to=batch), cols, 5, 9)
    assert_equal(view.get[1, 0, DType.int64](), 6)
    assert_equal(view.get[3, 1, DType.float64](), 2.0)
    assert_equal(view.get[2, 2, DType.int32](), 18)
    assert_equal(view.get[0, 3, DType.float32](), 5.5)
    assert_equal(view.get_at[0, DType.int64](3), 8)
    assert_equal(view.get_at[1, DType.float64](2), 0.5)
    assert_equal(view.get_at[2, DType.int32](1), 17)
    assert_equal(view.get_at[3, DType.float32](0), 5.5)


def main() raises:
    var suite = TestSuite()
    suite.test[test_weighted_frame_sum]()
    suite.test[test_first_a_last_b]()
    suite.test[test_state_is_per_partition_and_defaults_delegate]()
    suite.test[test_declared_frame_and_schemas]()
    suite.test[test_frame_spec_constructors]()
    suite.test[test_frame_view_reads_every_dtype]()
    suite^.run()
