# =============================================================================
# test_poc_partition_row_view.mojo — POC for the arity-agnostic ROW-VIEW
# partition-UDF input reader (ZERO per-arity siblings in the engine path)
# =============================================================================
#
# Proves the ROW-VIEW inversion:
#
#   * `PartitionRowView[origin]` wraps `(Pointer[RecordBatch, origin], row)`
#     + a comptime-fixed mapping from the UDF's OWN 0-based input position to
#     the resolved batch column index. A comptime-typed getter
#     `get[local_input_idx, dt]() -> Scalar[dt]` re-derives the typed cell read
#     (the SAME `column_as_primitive_*().load[1]()` the current `_read_cell`
#     does). This is the canonical `BatchView` shape: a `Pointer[_, origin]`
#     field, re-derive per call — NO UnsafePointer crossing a boundary, NO
#     wildcard origin.
#
#   * The ENGINE constructs the view in ONE arity-agnostic loop (no
#     `comptime if n_in == N`). The UDF reads its N inputs from the view by
#     comptime column index, doing its OWN `@parameter for` — per-arity
#     unrolling moves to the UDF (which knows its arity at comptime), the engine
#     path is one loop.
#
# POC GATE: an arity-1 conformer AND an arity-3 conformer driven through the
# SAME engine loop (`_poc_run_scan`) yield correct per-partition values.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.schema import (
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
    Field,
)
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType


# =============================================================================
# The arity-agnostic ROW-VIEW (POC shape of the stage primitive).
# =============================================================================

comptime POC_MAX_ARITY: Int = 8


struct PartitionRowView[origin: Origin[mut=False]](Copyable, Movable):
    """A monomorphic accessor over `(batch, row)` that maps the UDF's OWN
    0-based input position to a resolved batch column index. The UDF reads
    `view.get[local_idx, dt]()`; the view re-derives the typed cell read per
    call (canonical `BatchView` shape).

    The engine constructs ONE of these per row in a single arity-agnostic loop.
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _row: Int
    # Resolved batch column index for each of the UDF's input positions.
    var _cols: Array[Int, POC_MAX_ARITY]

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        row: Int,
        cols: Array[Int, POC_MAX_ARITY],
    ):
        self._batch = ptr
        self._row = row
        self._cols = cols.copy()  # `cols` is a read param; caller keeps it

    @always_inline
    def get[local_input_idx: Int, dt: DType](self) raises -> Scalar[dt]:
        """Read this row's value for the UDF's `local_input_idx`-th input as
        `Scalar[dt]`. The UDF knows `local_input_idx` + `dt` at comptime (from
        its `InputSchema`); the view resolves the batch column index at runtime
        and re-derives the typed read."""
        var col = self._cols[local_input_idx]
        comptime if dt == DType.int64:
            return rebind[Scalar[dt]](
                self._batch[].column_as_primitive_int64(col).load[1](self._row)[0]
            )
        elif dt == DType.int32:
            return rebind[Scalar[dt]](
                self._batch[].column_as_primitive_int32(col).load[1](self._row)[0]
            )
        elif dt == DType.float64:
            return rebind[Scalar[dt]](
                self._batch[].column_as_primitive_float64(col).load[1](self._row)[0]
            )
        elif dt == DType.float32:
            return rebind[Scalar[dt]](
                self._batch[].column_as_primitive_float32(col).load[1](self._row)[0]
            )
        else:
            comptime assert False, "PartitionRowView.get: DType not supported (POC covers" " int64/int32/float64/float32)."
            return Scalar[dt]()


# =============================================================================
# The POC trait surface — a per-row reader that reads its OWN inputs from the
# view (the inversion). Generic over the view's origin.
# =============================================================================


trait PocPartitionUdf(Copyable, Movable):
    comptime State: Copyable & Movable & Deinitable
    comptime OutType: DType
    comptime ARITY: Int

    def init_partition(self) -> Self.State:
        ...

    def run_partition_row[
        origin: Origin[mut=False]
    ](self, mut s: Self.State, view: PartitionRowView[origin]) raises -> Scalar[
        Self.OutType
    ]:
        ...


# =============================================================================
# Conformer A — arity-1 (running sum of one Int64 column).
# =============================================================================


@fieldwise_init
struct PocSum1State(Copyable, Movable, Deinitable):
    var acc: Int64


@fieldwise_init
struct PocSum1(PocPartitionUdf, Copyable, Movable):
    var bias: Int64

    comptime State = PocSum1State
    comptime OutType = DType.int64
    comptime ARITY = 1

    def init_partition(self) -> Self.State:
        return PocSum1State(0)

    def run_partition_row[
        origin: Origin[mut=False]
    ](self, mut s: Self.State, view: PartitionRowView[origin]) raises -> Scalar[
        Self.OutType
    ]:
        # The UDF reads its OWN input by comptime index 0, dtype Int64.
        var v0 = view.get[0, DType.int64]()
        s.acc += v0
        return Scalar[Self.OutType](s.acc + self.bias)


# =============================================================================
# Conformer B — arity-3 (running sum of a*b + c, three Int64 columns).
# Proves extensibility with ZERO new engine code: the per-arity unrolling
# lives ENTIRELY in this conformer's `@parameter`-free explicit reads.
# =============================================================================


@fieldwise_init
struct PocSum3State(Copyable, Movable, Deinitable):
    var acc: Int64


@fieldwise_init
struct PocSum3(PocPartitionUdf, Copyable, Movable):
    var bias: Int64

    comptime State = PocSum3State
    comptime OutType = DType.int64
    comptime ARITY = 3

    def init_partition(self) -> Self.State:
        return PocSum3State(0)

    def run_partition_row[
        origin: Origin[mut=False]
    ](self, mut s: Self.State, view: PartitionRowView[origin]) raises -> Scalar[
        Self.OutType
    ]:
        # The UDF reads its OWN 3 inputs by comptime index, each Int64.
        var a = view.get[0, DType.int64]()
        var b = view.get[1, DType.int64]()
        var c = view.get[2, DType.int64]()
        s.acc += a * b + c
        return Scalar[Self.OutType](s.acc + self.bias)


# =============================================================================
# The ONE arity-agnostic engine loop. NO `comptime if n_in == N`, NO
# `_call_arityK`. Constructs the view per row + calls the UDF reader.
# =============================================================================


def _poc_run_scan[
    F: PocPartitionUdf
](
    udf: F,
    batch: RecordBatch,
    cols: Array[Int, POC_MAX_ARITY],
    bounds: List[Int],
) raises -> List[Int64]:
    """Single arity-agnostic loop: for each partition, init a fresh state and
    thread it forward; per row, build a `PartitionRowView` and call
    `run_partition_row`. The UDF reads its own inputs — the engine never
    branches on arity."""
    var out = List[Int64]()
    var nrows = batch.num_rows()
    var nb = len(bounds)
    var ptr = Pointer(to=batch)
    for b in range(nb):
        var start = bounds[b]
        var end = bounds[b + 1] if (b + 1) < nb else nrows
        var st = udf.init_partition()
        for r in range(start, end):
            var view = PartitionRowView(ptr, r, cols)
            var o = udf.run_partition_row(st, view)
            out.append(Int64(o))
        _ = st^
    return out^


# =============================================================================
# Fixtures
# =============================================================================


def _i64_col(vals: List[Int64]) raises -> PrimitiveArray[DType.int64]:
    var lst: List[Scalar[DType.int64]] = []
    for i in range(len(vals)):
        lst.append(vals[i])
    return PrimitiveArray[DType.int64].from_list(lst)


def _make_batch_abc(
    a: List[Int64], b: List[Int64], c: List[Int64]
) raises -> RecordBatch:
    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(Column.from_primitive(_i64_col(a)))
    builder.add_column(Column.from_primitive(_i64_col(b)))
    builder.add_column(Column.from_primitive(_i64_col(c)))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    return builder.build(sb.build())


# =============================================================================
# Tests — both conformers through the SAME engine loop.
# =============================================================================


def test_poc_arity1() raises:
    # Two partitions: rows [0,3) and [3,5). UDF reads col "a" (index 0).
    # a = [1, 2, 3,  10, 20]
    # part0 running sum + bias 100: 101, 103, 106
    # part1 running sum + bias 100: 110, 130
    var a: List[Int64] = [1, 2, 3, 10, 20]
    var b: List[Int64] = [0, 0, 0, 0, 0]
    var c: List[Int64] = [0, 0, 0, 0, 0]
    var batch = _make_batch_abc(a, b, c)

    var cols = Array[Int, POC_MAX_ARITY](fill=0)
    cols[0] = 0  # UDF input 0 -> batch col "a"

    var bounds = List[Int]()
    bounds.append(0)
    bounds.append(3)

    var udf = PocSum1(bias=100)
    var out = _poc_run_scan[PocSum1](udf, batch, cols, bounds)

    assert_equal(len(out), 5, "arity1: 5 rows")
    assert_equal(Int(out[0]), 101, "arity1 p0 r0")
    assert_equal(Int(out[1]), 103, "arity1 p0 r1")
    assert_equal(Int(out[2]), 106, "arity1 p0 r2")
    assert_equal(Int(out[3]), 110, "arity1 p1 r0 (no bleed)")
    assert_equal(Int(out[4]), 130, "arity1 p1 r1")


def test_poc_arity3() raises:
    # Same SAME engine loop, an arity-3 UDF: acc += a*b + c, + bias 0.
    # a = [2, 3, 4,  5, 6]
    # b = [10,10,10, 1, 1]
    # c = [1, 2, 3,  7, 8]
    # part0 [0,3): a*b+c = 21, 32, 43 ; running = 21, 53, 96
    # part1 [3,5): a*b+c =  12, 14    ; running = 12, 26
    var a: List[Int64] = [2, 3, 4, 5, 6]
    var b: List[Int64] = [10, 10, 10, 1, 1]
    var c: List[Int64] = [1, 2, 3, 7, 8]
    var batch = _make_batch_abc(a, b, c)

    var cols = Array[Int, POC_MAX_ARITY](fill=0)
    cols[0] = 0  # input 0 -> "a"
    cols[1] = 1  # input 1 -> "b"
    cols[2] = 2  # input 2 -> "c"

    var bounds = List[Int]()
    bounds.append(0)
    bounds.append(3)

    var udf = PocSum3(bias=0)
    var out = _poc_run_scan[PocSum3](udf, batch, cols, bounds)

    assert_equal(len(out), 5, "arity3: 5 rows")
    assert_equal(Int(out[0]), 21, "arity3 p0 r0")
    assert_equal(Int(out[1]), 53, "arity3 p0 r1")
    assert_equal(Int(out[2]), 96, "arity3 p0 r2")
    assert_equal(Int(out[3]), 12, "arity3 p1 r0 (no bleed)")
    assert_equal(Int(out[4]), 26, "arity3 p1 r1")


def main() raises:
    test_poc_arity1()
    test_poc_arity3()
    print("test_poc_partition_row_view: OK")
