# =============================================================================
# Tests for the per-row and per-frame accessors the partition and window UDF
# traits read through (`PartitionRowView`, `FrameView`), the default methods
# of `WindowFn`, a `PartitionLocalMapFn` driven over two partitions, and the
# default `Predicate.eval[W]` body with a raising predicate.
#
# Fixture: a 20-row batch of four columns (int64, float64, int32, float32)
# with a NULL every fifth row (base rows 2, 7, 12, 17), each column then
# SLICED to base rows [3, 16): logical row j is base row j + 3, so every read
# goes through a column `_offset` of 3. Valid values are hand-chosen so each
# column and each row is distinct: i64 = 100 + r, f64 = r + 0.25,
# i32 = 1000 - r, f32 = r * 0.5 (r = base row). Logical rows 4 and 9 are
# NULL; the views do not consult validity (null handling is the engine's, per
# `NullHandling`), so no assertion reads a NULL slot's value.
#
# What each test proves (and the defect it catches):
#   - test_partition_row_view: every dtype arm reads the right cell through a
#     PERMUTED input map (local 0 -> batch column 2, ...) on the sliced batch:
#     an arm reading the wrong typed accessor, ignoring the map, or dropping
#     the slice offset reads a value 3 rows off and goes red.
#   - test_frame_view: `len` is hi - lo for a full frame, a one-row frame and
#     an empty one; comptime `get[frame_idx]` and runtime `get_at(frame_idx)`
#     read row lo + frame_idx for all four dtypes (an off-by-one in the
#     lo + frame_idx arithmetic or a swapped lo/hi is caught).
#   - test_window_fn_defaults: prepare_partition is init_partition's state
#     (init returns a non-zero marker); enter_row / leave_row leave the state
#     unchanged; emit is compute_frame over the frame (value and call count);
#     the comptime defaults invertible = False and ORDER_KEY_DT = int64.
#   - test_partition_local_map_fn: state is reset per partition by the test's
#     own driver (it calls init_partition at each boundary), and the state
#     threading is the test struct's own run_partition_row; the product code
#     it proves is PartitionRowView.get reading the right row.
#   - test_predicate_default_eval_raises: an error raised by eval_scalar for
#     one lane reaches the caller of the default eval[W] body.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder

from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.frame_view import FrameView
from komira_udf.partition_local_map_fn import PartitionLocalMapFn
from komira_udf.partition_row_view import (
    MAX_PARTITION_UDF_ARITY,
    PartitionRowView,
)
from komira_udf.predicate import Predicate
from komira_udf.schema_descriptor import DT_I64, schema_of
from komira_udf.stateful_contract import KeyEntry, KeyList
from komira_udf.window_fn import WindowFn
from komira_udf.window_frame_spec import WindowFrameSpec


# -----------------------------------------------------------------------------
# Fixture
# -----------------------------------------------------------------------------

comptime BASE_ROWS = 20
comptime SLICE_START = 3
comptime SLICE_LEN = 13


def _is_null_base(r: Int) -> Bool:
    return r % 5 == 2


def _valid(j: Int) -> Bool:
    """Logical row j of the sliced batch is valid."""
    return not _is_null_base(j + SLICE_START)


def _i64_at(j: Int) -> Int64:
    return Int64(100 + j + SLICE_START)


def _f64_at(j: Int) -> Float64:
    return Float64(j + SLICE_START) + 0.25


def _i32_at(j: Int) -> Int32:
    return Int32(1000 - (j + SLICE_START))


def _f32_at(j: Int) -> Float32:
    return Float32(j + SLICE_START) * 0.5


def _sliced_batch() raises -> RecordBatch:
    var b0 = ColumnBuilder[DType.int64].with_capacity(BASE_ROWS)
    var b1 = ColumnBuilder[DType.float64].with_capacity(BASE_ROWS)
    var b2 = ColumnBuilder[DType.int32].with_capacity(BASE_ROWS)
    var b3 = ColumnBuilder[DType.float32].with_capacity(BASE_ROWS)
    for r in range(BASE_ROWS):
        if _is_null_base(r):
            b0.append_null()
            b1.append_null()
            b2.append_null()
            b3.append_null()
        else:
            b0.append(Int64(100 + r))
            b1.append(Float64(r) + 0.25)
            b2.append(Int32(1000 - r))
            b3.append(Float32(r) * 0.5)
    var c0 = b0^.materialize().slice(SLICE_START, SLICE_LEN)
    var c1 = b1^.materialize().slice(SLICE_START, SLICE_LEN)
    var c2 = b2^.materialize().slice(SLICE_START, SLICE_LEN)
    var c3 = b3^.materialize().slice(SLICE_START, SLICE_LEN)
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", DType.int64, True))
    sb.add_field(Field("f64", DType.float64, True))
    sb.add_field(Field("i32", DType.int32, True))
    sb.add_field(Field("f32", DType.float32, True))
    return RecordBatch.from_typed_columns_4(sb.build(), c0^, c1^, c2^, c3^)


def _map(a: Int, b: Int, c: Int, d: Int) -> Array[Int, MAX_PARTITION_UDF_ARITY]:
    var cols = Array[Int, MAX_PARTITION_UDF_ARITY](fill=-1)
    cols[0] = a
    cols[1] = b
    cols[2] = c
    cols[3] = d
    return cols^


# -----------------------------------------------------------------------------
# PartitionRowView
# -----------------------------------------------------------------------------


def test_fixture_shape() raises:
    var batch = _sliced_batch()
    assert_equal(batch.num_rows(), SLICE_LEN)
    assert_equal(MAX_PARTITION_UDF_ARITY, 16)
    # The two NULL rows the slice holds are logical rows 4 and 9.
    var nulls = List[Int]()
    for j in range(SLICE_LEN):
        if not _valid(j):
            nulls.append(j)
    assert_equal(len(nulls), 2)
    assert_equal(nulls[0], 4)
    assert_equal(nulls[1], 9)


def test_partition_row_view() raises:
    var batch = _sliced_batch()
    var ptr = Pointer(to=batch)
    # Local input k reads batch column cols[k]: a permutation.
    var cols = _map(2, 0, 3, 1)
    for j in range(SLICE_LEN):
        if not _valid(j):
            continue
        var v = PartitionRowView(ptr, j, cols)
        var where = String(" row ") + String(j)
        assert_equal(v.get[0, DType.int32](), _i32_at(j), "i32" + where)
        assert_equal(v.get[1, DType.int64](), _i64_at(j), "i64" + where)
        assert_equal(v.get[2, DType.float32](), _f32_at(j), "f32" + where)
        assert_equal(v.get[3, DType.float64](), _f64_at(j), "f64" + where)


# -----------------------------------------------------------------------------
# FrameView
# -----------------------------------------------------------------------------


def test_frame_view() raises:
    var batch = _sliced_batch()
    var ptr = Pointer(to=batch)
    var cols = _map(0, 1, 2, 3)
    # Frame [5, 9): logical rows 5, 6, 7, 8 (all valid).
    var view = FrameView(ptr, cols, 5, 9)
    assert_equal(view.__len__(), 4)
    assert_equal(view.get[0, 0, DType.int64](), _i64_at(5))
    assert_equal(view.get[3, 0, DType.int64](), _i64_at(8))
    assert_equal(view.get[1, 1, DType.float64](), _f64_at(6))
    assert_equal(view.get[2, 2, DType.int32](), _i32_at(7))
    assert_equal(view.get[0, 3, DType.float32](), _f32_at(5))
    for i in range(view.__len__()):
        var j = 5 + i
        assert_equal(view.get_at[0, DType.int64](i), _i64_at(j))
        assert_equal(view.get_at[1, DType.float64](i), _f64_at(j))
        assert_equal(view.get_at[2, DType.int32](i), _i32_at(j))
        assert_equal(view.get_at[3, DType.float32](i), _f32_at(j))
    # A one-row frame at the last row, and an empty frame.
    var last = FrameView(ptr, cols, SLICE_LEN - 1, SLICE_LEN)
    assert_equal(last.__len__(), 1)
    assert_equal(last.get_at[0, DType.int64](0), _i64_at(SLICE_LEN - 1))
    assert_equal(FrameView(ptr, cols, 3, 3).__len__(), 0)


# -----------------------------------------------------------------------------
# WindowFn defaults
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Calls(Copyable, Movable):
    var n: Int


@fieldwise_init
struct _VRow(AutoKomiraSchema, Copyable, Movable):
    var v: Int64


@fieldwise_init
struct _FrameSum(WindowFn):
    """SUM(v) over the frame; counts compute_frame calls in its state."""

    comptime InRow = _VRow
    comptime OutputSchema = schema_of["s", DT_I64]()
    comptime OutType = DType.int64
    comptime UDF_ID = UInt32(7_200)
    comptime State = _Calls
    comptime PART_KEYS = KeyList()
    comptime ORDER_KEYS = KeyList()
    comptime frame = WindowFrameSpec.rows_running()

    def init_partition(self) -> _Calls:
        return _Calls(7)

    def compute_frame[
        origin: Origin[mut=False]
    ](self, mut s: _Calls, view: FrameView[origin]) raises -> Int64:
        s.n += 1
        var acc = Int64(0)
        for i in range(view.__len__()):
            acc += view.get_at[0, DType.int64](i)
        return acc


def _defaults[F: WindowFn](f: F, batch: RecordBatch) raises:
    var cols = _map(0, -1, -1, -1)
    var ptr = Pointer(to=batch)
    var s = f.prepare_partition()
    var view = FrameView(ptr, cols, 0, 3)
    f.enter_row(s, view, 0)
    f.leave_row(s, view, 2)
    var got = f.emit(s, view)
    assert_equal(rebind[Int64](got), _i64_at(0) + _i64_at(1) + _i64_at(2))
    assert_equal(rebind[_Calls](s).n, 8, "emit called compute_frame once")
    assert_false(F.invertible)
    assert_true(F.ORDER_KEY_DT == DType.int64)


def test_window_fn_defaults() raises:
    var batch = _sliced_batch()
    var f = _FrameSum()
    # prepare_partition defaults to init_partition (marker 7, not 0).
    assert_equal(f.prepare_partition().n, 7)
    var s = f.init_partition()
    var view = FrameView(Pointer(to=batch), _map(0, -1, -1, -1), 0, 3)
    f.enter_row(s, view, 1)
    f.leave_row(s, view, 1)
    assert_equal(s.n, 7, "enter_row / leave_row defaults are no-ops")
    _defaults(f, batch)


# -----------------------------------------------------------------------------
# PartitionLocalMapFn
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Total(Copyable, Movable):
    var t: Int64


@fieldwise_init
struct _RunningSum(PartitionLocalMapFn):
    comptime InRow = _VRow
    comptime OutputSchema = schema_of["rs", DT_I64]()
    comptime OutType = DType.int64
    comptime UDF_ID = UInt32(7_201)
    comptime State = _Total
    comptime PART_KEYS = KeyList([KeyEntry("k", True)])
    comptime ORDER_KEYS = KeyList([KeyEntry("ts", True)])

    def run_row(mut self, row: _VRow) -> Int64:
        return row.v

    def init_partition(self) -> _Total:
        return _Total(0)

    def run_partition_row[
        origin: Origin[mut=False]
    ](self, mut s: _Total, view: PartitionRowView[origin]) raises -> Int64:
        s.t += view.get[0, DType.int64]()
        return s.t


def _drive_partitions[F: PartitionLocalMapFn](
    f: F, batch: RecordBatch, starts: List[Int], end: Int
) raises -> List[Scalar[F.OutType]]:
    var cols = _map(0, -1, -1, -1)
    var ptr = Pointer(to=batch)
    var out = List[Scalar[F.OutType]]()
    for p in range(len(starts)):
        var stop = starts[p + 1] if p + 1 < len(starts) else end
        var s = f.init_partition()
        for r in range(starts[p], stop):
            out.append(f.run_partition_row(s, PartitionRowView(ptr, r, cols)))
    return out^


def test_partition_local_map_fn() raises:
    var batch = _sliced_batch()
    # Partitions [0, 3) and [3, 4) hold only valid rows.
    var got = _drive_partitions(_RunningSum(), batch, [0, 3], 4)
    assert_equal(len(got), 4)
    assert_equal(rebind[Int64](got[0]), _i64_at(0))
    assert_equal(rebind[Int64](got[1]), _i64_at(0) + _i64_at(1))
    assert_equal(rebind[Int64](got[2]), _i64_at(0) + _i64_at(1) + _i64_at(2))
    # A fresh state at the boundary: not the carried 3-row total.
    assert_equal(rebind[Int64](got[3]), _i64_at(3))
    assert_equal(materialize[_RunningSum.PART_KEYS]().names_joined(), "k")
    assert_equal(materialize[_RunningSum.ORDER_KEYS]().names_joined(), "ts")
    var m = _RunningSum()
    assert_equal(m.run_row(_VRow(5)), 5)


# -----------------------------------------------------------------------------
# Predicate default eval[W] with a raising eval_scalar
# -----------------------------------------------------------------------------


@fieldwise_init
struct _RefuseRow(Predicate):
    """Keeps every row but `bad`, for which it raises."""

    var bad: Int

    def eval_scalar[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) raises -> Bool:
        if i == self.bad:
            raise Error("refused row " + String(i))
        return True


def test_predicate_default_eval_raises() raises:
    var batch = _sliced_batch()
    var view = batch_view_over(batch)
    var p = _RefuseRow(6)
    var ok = p.eval[4](view, 0)
    for k in range(4):
        assert_true(ok[k])
    var raised = False
    try:
        _ = p.eval[4](view, 4)
    except e:
        raised = True
        assert_equal(String(e), "refused row 6")
    assert_true(raised, "an eval_scalar error reaches eval[W]'s caller")
    # Lanes past the end are never evaluated, so a bad row past n is silent.
    var past = _RefuseRow(SLICE_LEN)
    var tail = past.eval[4](view, SLICE_LEN - 1)
    assert_true(tail[0])
    assert_false(tail[1] or tail[2] or tail[3])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
