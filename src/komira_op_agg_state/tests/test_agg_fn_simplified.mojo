# =============================================================================
# test_agg_fn_simplified.mojo — WAVE-11-UDF-E M6 — lock-in tests for the
#                                simplified AggFn surface.
# =============================================================================
#
# WAVE-11-UDF-E M6 (maintainer directive). Mirrors UDF-A's
# `test_filter_fn_simplified.mojo` pattern for the AggFn trait surface.
# AggFn's trait default `comptime InputSchema = _derive_schema[Self.InRow]()`
# landed pre-UDF-E (commit `` via UDF-D); UDF-E M5 added the
# AutoKomiraSchema conformance to the 12 Row* + RowStr structs in
# builtin_agg_fns_*. This file locks in the simplified AggFn surface:
#
#   1. _derive_schema on N-field InRow structs — 1/2/3 fields.
#   2. Trait-default firing — an AggFn conformer that omits `InputSchema`
#      gets the auto-derived schema per UDF-A's F-28 finding.
#   3. Explicit override path — `InputSchema = schema_of[...]()` wins
#      over the trait default.
#   4. init / update / merge / finalize lifecycle — over a single group
#      and a 2-group fold.
#   5. update_scalar / update parity — both forms produce identical
#      State for the same input.
#   6. End-to-end engine dispatch — build an AggFnAcc from a
#      AutoKomiraSchema-marked AggFn (auto-derived schema) and run it
#      over a synthetic RecordBatch; verify the finalize output.
#
# Same SchemaDescriptor not-ImplicitlyCopyable gotcha as UDF-A's test —
# pull name/dtype off the comptime schema via parametric helper fns.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_almost_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, SchemaBuilder, RecordBatch, RecordBatchBuilder,
)
from komira_udf.agg_fn import AggFn, PodState
from komira_udf.schema_descriptor import (
    SchemaDescriptor,
    schema_of,
    _derive_schema,
    DT_F64,
    DT_I64,
)
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_op_agg_state.agg_fn_acc import AggFnAcc
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Parametric comptime-schema accessors (same shape as UDF-A's test;
# SchemaDescriptor is not ImplicitlyCopyable).
# =============================================================================


def _col_name[S: SchemaDescriptor, i: Int]() -> String:
    return comptime(S.cols[i].name)


def _col_dtag[S: SchemaDescriptor, i: Int]() -> Int:
    return comptime(S.cols[i].dtype)


def _num_cols[S: SchemaDescriptor]() -> Int:
    return comptime(len(S.cols))


# =============================================================================
# Test fixture row structs — single-field, 2-field, 3-field with AutoKomiraSchema.
# =============================================================================


@fieldwise_init
struct ValueRow(Copyable, Movable, AutoKomiraSchema):
    """Single-Float64 row — the simplest aggregate input shape."""
    var value: Float64


@fieldwise_init
struct ValueWeightRow(Copyable, Movable, AutoKomiraSchema):
    """2-field row — Float64 value + Float64 weight for weighted-avg."""
    var value: Float64
    var weight: Float64


@fieldwise_init
struct PriceQtyDiscRow(Copyable, Movable, AutoKomiraSchema):
    """3-field row — Float64 price + Int64 qty + Float64 disc."""
    var price: Float64
    var qty: Int64
    var disc: Float64


# =============================================================================
# PodState fixtures.
# =============================================================================


@fieldwise_init
struct SumState(PodState):
    """Single-Float64 running sum state."""
    var sum: Float64


@fieldwise_init
struct WAvgState(PodState):
    """Weighted-avg state — sum(value*weight), sum(weight)."""
    var sum_vw: Float64
    var sum_w: Float64


# =============================================================================
# Fixture 1 — minimal AggFn (1-input sum) using trait-default InputSchema.
# =============================================================================


@fieldwise_init
struct SumF64Auto(AggFn):
    """sum(value). Declares only InRow + Output + State + UDF_ID + the
    five methods — InputSchema falls through to the trait default
    `_derive_schema[ValueRow]()`."""
    comptime InRow = ValueRow
    comptime OutputSchema = schema_of["sum_value", DT_F64]()
    comptime OutType = DType.float64
    comptime State = SumState
    comptime UDF_ID = UInt32(9701)

    def init(self) -> SumState:
        return SumState(0.0)

    def update(self, mut s: SumState, row: ValueRow):
        self.update_scalar(s, row.value)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumState, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])

    def merge(self, a: SumState, b: SumState) -> SumState:
        return SumState(a.sum + b.sum)

    def finalize(self, s: SumState) -> Scalar[DType.float64]:
        return s.sum


# =============================================================================
# Fixture 2 — explicit override path. Column name 'l_extendedprice'
# differs from the InRow field name 'value'.
# =============================================================================


@fieldwise_init
struct SumF64Aliased(AggFn):
    """Conformer with an explicit InputSchema override — declares column
    name 'l_extendedprice' even though InRow.value is the underlying field."""
    comptime InRow = ValueRow
    comptime InputSchema = schema_of["l_extendedprice", DT_F64]()
    comptime OutputSchema = schema_of["sum_value", DT_F64]()
    comptime OutType = DType.float64
    comptime State = SumState
    comptime UDF_ID = UInt32(9702)

    def init(self) -> SumState:
        return SumState(0.0)

    def update(self, mut s: SumState, row: ValueRow):
        self.update_scalar(s, row.value)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumState, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])

    def merge(self, a: SumState, b: SumState) -> SumState:
        return SumState(a.sum + b.sum)

    def finalize(self, s: SumState) -> Scalar[DType.float64]:
        return s.sum


# =============================================================================
# Fixture 3 — 2-field AggFn (weighted average) with trait-default schema.
# =============================================================================


@fieldwise_init
struct WeightedAvgAuto(AggFn):
    """weighted_avg(value, weight). Uses the trait-default InputSchema
    (auto-derived from ValueWeightRow)."""
    comptime InRow = ValueWeightRow
    comptime OutputSchema = schema_of["wavg", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WAvgState
    comptime UDF_ID = UInt32(9703)

    def init(self) -> WAvgState:
        return WAvgState(0.0, 0.0)

    def update(self, mut s: WAvgState, row: ValueWeightRow):
        self.update_scalar(s, row.value, row.weight)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WAvgState, *vals: *Ts):
        s.sum_vw += rebind[Float64](vals[0]) * rebind[Float64](vals[1])
        s.sum_w += rebind[Float64](vals[1])

    def merge(self, a: WAvgState, b: WAvgState) -> WAvgState:
        return WAvgState(a.sum_vw + b.sum_vw, a.sum_w + b.sum_w)

    def finalize(self, s: WAvgState) -> Scalar[DType.float64]:
        return s.sum_vw / s.sum_w if s.sum_w != 0.0 else 0.0


# =============================================================================
# Tests.
# =============================================================================


def test_derive_schema_single_field() raises:
    """_derive_schema[ValueRow]() produces a 1-col schema with field
    name 'value' and dtype DT_F64."""
    comptime s = _derive_schema[ValueRow]()
    assert_equal(_num_cols[s](), 1)
    assert_equal(_col_name[s, 0](), String("value"))
    assert_equal(_col_dtag[s, 0](), DT_F64)


def test_derive_schema_two_fields() raises:
    """_derive_schema[ValueWeightRow]() produces a 2-col schema:
    ['value' Float64, 'weight' Float64]."""
    comptime s = _derive_schema[ValueWeightRow]()
    assert_equal(_num_cols[s](), 2)
    assert_equal(_col_name[s, 0](), String("value"))
    assert_equal(_col_dtag[s, 0](), DT_F64)
    assert_equal(_col_name[s, 1](), String("weight"))
    assert_equal(_col_dtag[s, 1](), DT_F64)


def test_derive_schema_three_fields_mixed_dtype() raises:
    """_derive_schema[PriceQtyDiscRow]() produces a 3-col schema with
    mixed DTypes (F64, I64, F64) in declaration order."""
    comptime s = _derive_schema[PriceQtyDiscRow]()
    assert_equal(_num_cols[s](), 3)
    assert_equal(_col_name[s, 0](), String("price"))
    assert_equal(_col_dtag[s, 0](), DT_F64)
    assert_equal(_col_name[s, 1](), String("qty"))
    assert_equal(_col_dtag[s, 1](), DT_I64)
    assert_equal(_col_name[s, 2](), String("disc"))
    assert_equal(_col_dtag[s, 2](), DT_F64)


def test_trait_default_input_schema_fires_one_field() raises:
    """An AggFn conformer that doesn't declare InputSchema gets the
    trait-default value from `_derive_schema[Self.InRow]()`."""
    assert_equal(_num_cols[SumF64Auto.InputSchema](), 1)
    assert_equal(_col_name[SumF64Auto.InputSchema, 0](), String("value"))
    assert_equal(_col_dtag[SumF64Auto.InputSchema, 0](), DT_F64)


def test_trait_default_input_schema_fires_two_field() raises:
    """A 2-field AggFn conformer (WeightedAvgAuto over ValueWeightRow)
    gets the auto-derived 2-col schema with the InRow's field names."""
    assert_equal(_num_cols[WeightedAvgAuto.InputSchema](), 2)
    assert_equal(_col_name[WeightedAvgAuto.InputSchema, 0](), String("value"))
    assert_equal(_col_dtag[WeightedAvgAuto.InputSchema, 0](), DT_F64)
    assert_equal(_col_name[WeightedAvgAuto.InputSchema, 1](), String("weight"))
    assert_equal(_col_dtag[WeightedAvgAuto.InputSchema, 1](), DT_F64)


def test_explicit_input_schema_override() raises:
    """An explicit `comptime InputSchema = schema_of[...]()` overrides
    the trait default. SumF64Aliased declares column name
    'l_extendedprice' even though InRow.value is the underlying field."""
    assert_equal(_num_cols[SumF64Aliased.InputSchema](), 1)
    assert_equal(_col_name[SumF64Aliased.InputSchema, 0](), String("l_extendedprice"))
    assert_equal(_col_dtag[SumF64Aliased.InputSchema, 0](), DT_F64)


def test_update_and_update_scalar_parity_one_field() raises:
    """SumF64Auto.update and .update_scalar produce identical State for
    the same input — the user-facing `update` delegates to the
    engine-facing variadic `update_scalar` per F-27 (UDF-A finding)."""
    var f = SumF64Auto()
    var s_via_row = f.init()
    f.update(s_via_row, ValueRow(10.0))
    f.update(s_via_row, ValueRow(20.0))
    f.update(s_via_row, ValueRow(30.0))
    var s_via_scalar = f.init()
    f.update_scalar(s_via_scalar, 10.0)
    f.update_scalar(s_via_scalar, 20.0)
    f.update_scalar(s_via_scalar, 30.0)
    assert_almost_equal(s_via_row.sum, 60.0)
    assert_almost_equal(s_via_scalar.sum, 60.0)
    assert_almost_equal(s_via_row.sum, s_via_scalar.sum)


def test_lifecycle_single_group() raises:
    """Sum over a single group: init -> 3 updates -> finalize."""
    var f = SumF64Auto()
    var s = f.init()
    assert_almost_equal(s.sum, 0.0)
    f.update(s, ValueRow(1.5))
    f.update(s, ValueRow(2.5))
    f.update(s, ValueRow(4.0))
    assert_almost_equal(Float64(f.finalize(s)), 8.0)


def test_lifecycle_two_groups_merge() raises:
    """Two partial states (e.g. two workers' worth) get merged and
    finalized. Exercises the parallel-merge thunk path."""
    var f = WeightedAvgAuto()
    var a = f.init()
    var b = f.init()
    # group's split:
    # a: (10, 2), (5, 1) -> sum_vw=25, sum_w=3
    # b: (20, 4)         -> sum_vw=80, sum_w=4
    f.update(a, ValueWeightRow(10.0, 2.0))
    f.update(a, ValueWeightRow(5.0, 1.0))
    f.update(b, ValueWeightRow(20.0, 4.0))
    var m = f.merge(a, b)
    # merged: sum_vw=105, sum_w=7 -> 15.0
    assert_almost_equal(m.sum_vw, 105.0)
    assert_almost_equal(m.sum_w, 7.0)
    assert_almost_equal(Float64(f.finalize(m)), 15.0)


def _f64_col_nullable(vals: List[Float64], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A nullable Float64 column. `nulls` lists the indices to mark null."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, vals[i])
    for k in range(len(nulls)):
        arr._set_null(nulls[k])  # _set_null bumps null_count (fix)
    return Column.from_primitive[DType.float64](arr^)


def _build_value_batch_nullable(vals: List[Float64], nulls: List[Int]) raises -> RecordBatch:
    """Build a single-column 'value' RecordBatch over the given values
    + optional null indices."""
    var sb = SchemaBuilder()
    sb.add_field(Field("value", ArrowType.FLOAT64, True))
    var b = RecordBatchBuilder()
    b.add_column(_f64_col_nullable(vals, nulls))
    return b.build(sb.build())


def test_engine_e2e_agg_fn_acc_two_groups() raises:
    """End-to-end: AggFnAcc[SumF64Auto] over a 4-row RecordBatch with
    2 groups. Exercises the engine adapter against the trait-default
    _derive_schema-produced InputSchema."""
    var values = List[Float64]()
    values.append(10.0)
    values.append(20.0)
    values.append(30.0)
    values.append(40.0)
    var batch = _build_value_batch_nullable(values, [])
    var acc = AggFnAcc[SumF64Auto](SumF64Auto())
    acc.ensure_capacity(2)
    # gids 0,1,0,1 -> group 0 sees rows 0,2 = 10+30 = 40
    #                 group 1 sees rows 1,3 = 20+40 = 60
    var gids: List[Int] = [0, 1, 0, 1]
    acc.update_record_batch(gids, batch^)
    assert_equal(acc.num_groups(), 2)
    var col = acc.finalize_to_column()
    var out = col.as_primitive[DType.float64]()
    assert_almost_equal(out.get(0), 40.0)
    assert_almost_equal(out.get(1), 60.0)


def test_engine_e2e_agg_fn_acc_propagates_null() raises:
    """End-to-end: AggFnAcc skips null inputs (PROPAGATE null mode).
    Row 2's value is NULL — sum sees only the 3 non-null values."""
    var values = List[Float64]()
    values.append(10.0)
    values.append(20.0)
    values.append(0.0)  # marked null below
    values.append(40.0)
    var batch = _build_value_batch_nullable(values, [2])
    var acc = AggFnAcc[SumF64Auto](SumF64Auto())
    acc.ensure_capacity(1)
    # gids all 0 -> single group, but row 2 is null -> 10+20+40 = 70
    acc.update_record_batch([0, 0, 0, 0], batch^)
    assert_equal(acc.num_groups(), 1)
    var out = acc.finalize_to_column().as_primitive[DType.float64]()
    assert_almost_equal(out.get(0), 70.0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_derive_schema_single_field]()
    suite.test[test_derive_schema_two_fields]()
    suite.test[test_derive_schema_three_fields_mixed_dtype]()
    suite.test[test_trait_default_input_schema_fires_one_field]()
    suite.test[test_trait_default_input_schema_fires_two_field]()
    suite.test[test_explicit_input_schema_override]()
    suite.test[test_update_and_update_scalar_parity_one_field]()
    suite.test[test_lifecycle_single_group]()
    suite.test[test_lifecycle_two_groups_merge]()
    suite.test[test_engine_e2e_agg_fn_acc_two_groups]()
    suite.test[test_engine_e2e_agg_fn_acc_propagates_null]()
    suite^.run()
