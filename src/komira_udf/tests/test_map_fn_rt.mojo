# =============================================================================
# test_map_fn_rt.mojo — MapFn -> RowTransform adapter acceptance
# =============================================================================
#
# Locks in the `MapFnRT[F: MapFn, col0: Int]` newtype adapter — the
# `RowTransform` conformance bridge for the user-facing `MapFn` family.
#
# Coverage:
#   1. `MapFnRT[F, col0]` conforms to `RowTransform` — `ARITY=1`,
#      `dtype_at[0]() == F.OutType`, usable through a parametric
#      `fn _drive_via_row_transform[R: RowTransform, ...]` helper.
#   2. `write_one` smoke — small Int64 input column, identity MapFn,
#      adapter builds the UDF's `InRow` -> forwards `run_row` ->
#      builder receives the expected value.
#   3. Cross-DType smoke — Float64 input column with a different
#      identity MapFn, exercises the `comptime if` ladder.
#   4. Stateful MapFn smoke — a `_RunningSumMapI64` conformer that
#      mutates its `_total` field across rows verifies that `write_one`
#      threads `mut self` correctly into `self._udf` (the in-instance
#      adapter pattern preserves captures across rows).
#
# Note on `project_one`: `MapFnRT` intentionally does NOT override the
# static `project_one` — see `map_fn_rt.mojo` module doc. The Stage
# NoBreaker emit path drives ExprX conformers ; MapFnRT is
# driven via the instance `write_one`.
#
# This acceptance harness mirrors
# `test_udf_trait_surface.mojo`'s patterns (BatchView fixture +
# minimal `_TestBuilder` stand-in + parametric trait-dispatch helpers).
# =============================================================================

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.batch_view import BatchView, batch_view_over
from komira_core.collections.multi_column_builder import MultiColumnSink

from komira_udf.map_fn import MapFn
from komira_udf.map_fn_rt import MapFnRT
from komira_udf.row_transform import RowTransform
from komira_udf.schema_descriptor import schema_of, DT_I64, DT_F64


# -----------------------------------------------------------------------------
# Fixture — a 1-column RecordBatch of values 0..n.
# -----------------------------------------------------------------------------
def _build_i64_batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("c0", DType.int64, True))
    var col0 = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


def _build_f64_batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.float64]]()
    for i in range(n):
        vals.append(Scalar[DType.float64](Float64(i) + 0.5))
    var arr = PrimitiveArray[DType.float64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("c0", DType.float64, True))
    var col0 = Column.from_primitive[DType.float64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


# -----------------------------------------------------------------------------
# Minimal builder stand-in — conforms to MultiColumnSink. Records the
# last value written per slot (only slot 0 here since ARITY=1).
# -----------------------------------------------------------------------------
@fieldwise_init
struct _TestBuilder(Movable, MultiColumnSink):
    var last_i64: Int64
    var last_f64: Float64

    def append_at[k: Int, DT: DType](mut self, value: Scalar[DT]):
        # Identity routing — record into the slot matching DT for an
        # easy test of "did the adapter call append_at with the right
        # DType?". Single-column ARITY=1 adapter so `k` is always 0.
        comptime if DT == DType.int64:
            self.last_i64 = Int64(rebind[Scalar[DType.int64]](value))
        elif DT == DType.float64:
            self.last_f64 = Float64(rebind[Scalar[DType.float64]](value))


# -----------------------------------------------------------------------------
# MapFn conformers — field-less identity over a single input column.
# -----------------------------------------------------------------------------
# Row structs (1-field POD).
@fieldwise_init
struct _RowI64(Copyable, Movable):
    var v: Int64


@fieldwise_init
struct _RowF64(Copyable, Movable):
    var v: Float64


# Identity MapFn for Int64 -> Int64. Field-less; UDF_ID is arbitrary.
@fieldwise_init
struct _IdentityMapI64(MapFn):
    comptime InRow = _RowI64
    comptime InputSchema = schema_of["c0", DT_I64]()
    comptime OutputSchema = schema_of["out_v", DT_I64]()
    comptime OutType = DType.int64
    comptime UDF_ID = UInt32(0xABCD_0001)

    def run_row(mut self, row: _RowI64) -> Scalar[DType.int64]:
        return row.v


# Identity MapFn for Float64 -> Float64.
@fieldwise_init
struct _IdentityMapF64(MapFn):
    comptime InRow = _RowF64
    comptime InputSchema = schema_of["c0", DT_F64]()
    comptime OutputSchema = schema_of["out_v", DT_F64]()
    comptime OutType = DType.float64
    comptime UDF_ID = UInt32(0xABCD_0002)

    def run_row(mut self, row: _RowF64) -> Scalar[DType.float64]:
        return row.v


# Stateful MapFn — tracks a running sum across rows. Verifies that the
# adapter's `_udf: F` storage + `mut self.write_one` thread captures
# correctly across rows (the stateful-MapFn raison d'être for the
# instance-bound adapter shape — vs HashAggOpF64Agg's field-less form).
@fieldwise_init
struct _RunningSumMapI64(MapFn):
    var _total: Int64
    comptime InRow = _RowI64
    comptime InputSchema = schema_of["c0", DT_I64]()
    comptime OutputSchema = schema_of["out_v", DT_I64]()
    comptime OutType = DType.int64
    comptime UDF_ID = UInt32(0xABCD_0003)

    def run_row(mut self, row: _RowI64) -> Scalar[DType.int64]:
        self._total += row.v
        return self._total


# -----------------------------------------------------------------------------
# Parametric helper — confirms a `MapFnRT[...]` is usable through the
# RowTransform trait surface (the Stage *Outs slot-type position).
# -----------------------------------------------------------------------------
def _drive_via_row_transform[
    R: RowTransform, bo: Origin[mut=False]
](mut r: R, batch: BatchView[bo], i: Int, mut b: _TestBuilder) raises:
    r.write_one[bo, _TestBuilder](batch, i, b)


def _expect(cond: Bool, label: String) raises:
    if not cond:
        raise Error("FAIL: " + label)
    print("  ok:", label)


def main() raises:
    print("=== test_map_fn_rt ===")

    # ----- 1. Trait conformance — Int64 input -----
    # `MapFnRT[_IdentityMapI64, 0]` conforms to RowTransform: ARITY=1,
    # dtype_at[0]() == int64.
    _expect(
        MapFnRT[_IdentityMapI64, 0].ARITY == 1,
        "MapFnRT[IdMapI64, 0] ARITY == 1",
    )
    _expect(
        MapFnRT[_IdentityMapI64, 0].dtype_at[0]() == DType.int64,
        "MapFnRT[IdMapI64, 0] dtype_at[0] == int64",
    )

    # ----- 2. write_one smoke — Int64 -----
    var batch = _build_i64_batch(16)
    var view = batch_view_over(batch)
    var adapter_i64 = MapFnRT[_IdentityMapI64, 0](_IdentityMapI64())
    var builder = _TestBuilder(Int64(-1), Float64(-1.0))
    # Direct call.
    adapter_i64.write_one[origin_of(batch), _TestBuilder](view, 7, builder)
    _expect(
        Int(builder.last_i64) == 7,
        "MapFnRT[IdMapI64, 0] write_one row 7 -> builder.last_i64 == 7",
    )
    # Via parametric trait-dispatch helper (Stage *Outs slot position).
    var builder2 = _TestBuilder(Int64(-1), Float64(-1.0))
    _drive_via_row_transform(adapter_i64, view, 13, builder2)
    _expect(
        Int(builder2.last_i64) == 13,
        "MapFnRT[IdMapI64, 0] write_one via RowTransform trait row 13 -> 13",
    )

    # ----- 3. Cross-DType smoke — Float64 -----
    _expect(
        MapFnRT[_IdentityMapF64, 0].dtype_at[0]() == DType.float64,
        "MapFnRT[IdMapF64, 0] dtype_at[0] == float64",
    )
    var batch_f = _build_f64_batch(16)
    var view_f = batch_view_over(batch_f)
    var adapter_f64 = MapFnRT[_IdentityMapF64, 0](_IdentityMapF64())
    var builder_f = _TestBuilder(Int64(-1), Float64(-1.0))
    adapter_f64.write_one[origin_of(batch_f), _TestBuilder](
        view_f, 9, builder_f
    )
    # _build_f64_batch generates vals[i] = i + 0.5
    _expect(
        builder_f.last_f64 == Float64(9.5),
        "MapFnRT[IdMapF64, 0] write_one row 9 -> builder.last_f64 == 9.5",
    )

    # ----- 4. Stateful MapFn — running sum across rows -----
    # _build_i64_batch generates vals[i] = i; running sum after writing
    # rows [0, 1, 2, 3, 4] should be 0+1+2+3+4 = 10. The adapter's
    # `_udf: F` field preserves `_total` across rows (the instance-bound
    # adapter raison d'être).
    var stateful_adapter = MapFnRT[_RunningSumMapI64, 0](
        _RunningSumMapI64(Int64(0))
    )
    var stateful_builder = _TestBuilder(Int64(-1), Float64(-1.0))
    for i in range(5):
        stateful_adapter.write_one[origin_of(batch), _TestBuilder](
            view, i, stateful_builder
        )
    _expect(
        Int(stateful_builder.last_i64) == 10,
        "MapFnRT[RunningSumI64, 0] write_one rows [0..5) — running sum"
        " preserved across rows; final == 10",
    )

    print("=== test_map_fn_rt: ALL PASS ===")
