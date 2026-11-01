# =============================================================================
# test_udf_traits.mojo — conformance + comptime-mechanics for the typed UDF traits
# =============================================================================
#
# UDF-DESIGN Deliverable 3, Phase 1 (design doc rev 6 =,
# §1, §2, §7). Exercises the trait FILES in komira_eval/ (map_fn.mojo /
# filter_fn.mojo / agg_fn.mojo / stateful_contract.mojo / schema_descriptor.mojo)
# directly — no engine plumbing yet (the operators + the comptime-F cascade
# are P1.c-P1.e). Covers:
#   - a 2-col MapFn conformer (DiscPrice): run_row gives the right
#     value; a stateless conformer may declare `self` (not `mut self`) and
#     still conform (spike Probe 5 bonus).
#   - a plain MapFn conformer (DiscPriceVec — post-WAVE-11-UDF-F migration
#     from the deleted user-facing vectorized sub-trait): exercises the
#     dispatch distinction against `_MapFnFusedKernel` (the engine-internal
#     SIMD fast-path signal that succeeded the user-facing opt-in; the
#     opt-in marker is now the internal kernel surface).
#   - a 1-col FilterFn conformer (QtyAbove) with a captured `threshold` field
#     ("the closure capture"): keep_row.
#   - a 2-col AggFn conformer (WeightedAvg) with a PodState `State`:
#     init/update over 3 groups + merge two partials + finalize → the expected
#     numbers ([20, 150, 1000] then merged-with-[16.25, 116.667, 750]).
#   - the comptime schema machinery: `schema_of[...]()` builds a SchemaDescriptor
#     read at comptime; reading `F.OutputSchema.cols[0].name`/`.dtype` works.
#   - the StatefulContract tags + a partition_local KeyList.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_almost_equal

from komira_arrow.batch_view import BatchView

from komira_udf.map_fn import MapFn
from komira_udf.filter_fn import FilterFn
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.agg_fn import AggFn, PodState
from komira_kernels.simd_of import SimdOf
from komira_udf.schema_descriptor import (
    SchemaDescriptor, ColDescriptor, schema_of, DT_F64, DT_I64, DT_F32,
    dtag_to_dtype, dtag_to_arrow_type_id, dtag_of_arrow_type_id, dtag_is_simd,
)
from komira_udf.stateful_contract import (
    StatefulContract, KeyList, KeyEntry,
    CONTRACT_STATELESS, CONTRACT_SERIAL_ORDERED, CONTRACT_PARTITION_LOCAL,
)
from komira_udf.udf_descriptor import NullHandling
from komira_operator_api.map_fn_fused_kernel import _MapFnFusedKernel


# =============================================================================
# MapFn conformer — disc_price = l_extendedprice * (1 - l_discount)
# =============================================================================

@fieldwise_init
struct LineitemPriceRow(Copyable, Movable, AutoKomiraSchema):
    var l_extendedprice: Float64
    var l_discount: Float64


# UDF-PHASE-B3-7-SDK-A-CONFORMERS: single-field output row struct for the
# *Simd sub-trait migration. The legacy MapFn surface uses `OutType: DType` (a
# scalar dtype); the new _MapFnFusedKernel surface uses `T_OUT: <struct>` (one or more
# typed fields). Single-field wrap is the canonical shape.
@fieldwise_init
struct DiscPriceOutRow(Copyable, Movable):
    var l_disc_price: Float64


@fieldwise_init
struct DiscPrice(_MapFnFusedKernel):
    # No captured fields (a stateless UDF). `parallelism`/`null_mode` omitted -> defaults.
    # Legacy MapFn surface (required by MapFn parent trait).
    comptime InRow = LineitemPriceRow
    comptime InputSchema = schema_of["l_extendedprice", DT_F64, "l_discount", DT_F64]()
    comptime OutputSchema = schema_of["l_disc_price", DT_F64]()
    comptime OutType = DType.float64
    comptime UDF_ID = UInt32(7001)

    # NEW _MapFnFusedKernel surface (comptime T_IN / T_OUT).
    comptime T_IN = LineitemPriceRow
    comptime T_OUT = DiscPriceOutRow

    # `self` (immutable) against the `mut self` trait requirement — still conforms (Probe 5).
    def run_row(mut self, row: LineitemPriceRow) -> Float64:
        return row.l_extendedprice * (1.0 - row.l_discount)

    # NEW @staticmethod SimdOf-typed oracles (required by _MapFnFusedKernel).
    @staticmethod
    def eval[W: Int](input: SimdOf[LineitemPriceRow, W]) -> SimdOf[DiscPriceOutRow, W]:
        var out = SimdOf[DiscPriceOutRow, W].zero()
        var price = input.get_f64[0]()
        var discount = input.get_f64[1]()
        out.set_f64[0](price * (SIMD[DType.float64, W](1.0) - discount))
        return out^

    @staticmethod
    def eval_row(input: LineitemPriceRow) -> DiscPriceOutRow:
        return DiscPriceOutRow(l_disc_price=input.l_extendedprice * (1.0 - input.l_discount))


# WAVE-11-UDF-F: was the user-facing vectorized sub-trait
# (deleted); migrated to plain MapFn. The engine's vectorized comptime
# branch was a vestige (both arms called the same scalar dispatch — see
# map_fn_op.mojo:_compute_output header doc); no perf regression. The
# SIMD fast-path surface is now the engine-internal `_MapFnFusedKernel`
# opt-in.
#
# InputSchema dropped — trait-default `_derive_schema[LineitemPriceRow]()`
# (UDF-A's F-28 finding) produces the byte-identical 2-col schema from
# the InRow struct's `@fieldwise_init` fields. LineitemPriceRow conforms
# to `AutoKomiraSchema` (the trait-default gating marker).
@fieldwise_init
struct DiscPriceVec(MapFn):
    comptime InRow = LineitemPriceRow
    comptime OutputSchema = schema_of["l_disc_price", DT_F64]()
    comptime OutType = DType.float64
    comptime UDF_ID = UInt32(7002)

    def run_row(mut self, row: LineitemPriceRow) -> Float64:
        return row.l_extendedprice * (1.0 - row.l_discount)


# =============================================================================
# FilterFn conformer — l_quantity > self.threshold (the captured threshold)
# =============================================================================

@fieldwise_init
struct LineitemQtyRow(Copyable, Movable, AutoKomiraSchema):
    var l_quantity: Float64


# WAVE-11-UDF-A: was FilterFnVectorized (deleted); migrated to plain FilterFn.
# The engine's vectorized comptime branch was a vestige (both arms called
# the same scalar dispatch); no perf regression.
@fieldwise_init
struct QtyAbove(FilterFn):
    comptime InRow = LineitemQtyRow
    comptime InputSchema = schema_of["l_quantity", DT_F64]()
    comptime UDF_ID = UInt32(7101)
    var threshold: Float64        # <-- the "capture"

    def keep_row(mut self, row: LineitemQtyRow) -> Bool:
        return row.l_quantity > self.threshold

    # UDF-EXPRX-MIGRATION: FilterFn refines the unified `Predicate`
    # surface. A FilterFn conformer satisfies `Predicate.eval_scalar` with a
    # one-line delegate that reads its input column off the `BatchView`, builds
    # the row and forwards to `keep_row`. Input column 0 is `l_quantity` (F64).
    def eval_scalar[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) raises -> Bool:
        return self.keep_row(LineitemQtyRow(batch.col_f64(0).load[1](i)[0]))


# =============================================================================
# AggFn conformer — weighted_avg(value, weight) = sum(value*weight)/sum(weight)
# =============================================================================

@fieldwise_init
struct WAvgInRow(Copyable, Movable, AutoKomiraSchema):
    var value: Float64
    var weight: Float64


@fieldwise_init
struct WAvgState(PodState):    # all fields PodScalar — conforms to PodState (S3 gate)
    var sum_vw: Float64
    var sum_w: Float64


# WAVE-11-UDF-F: was the user-facing vectorized agg sub-trait
# (deleted); migrated to plain AggFn. The engine's vectorized comptime
# branch was a vestige (the trait contract required `update_chunk[W=1]`
# to match `update_scalar` lane-for-lane); no perf regression. The SIMD
# fast-path surface is now the engine-internal `_AggFnFusedKernel` opt-in.
# InputSchema dropped — trait-default `_derive_schema[WAvgInRow]()`
# auto-derives the byte-identical 2-col schema. WAvgInRow conforms to
# `AutoKomiraSchema` (the trait-default gating marker).
@fieldwise_init
struct WeightedAvg(AggFn):
    comptime InRow = WAvgInRow
    comptime OutType = DType.float64
    comptime State = WAvgState
    comptime OutputSchema = schema_of["wavg", DT_F64]()
    comptime UDF_ID = UInt32(7201)

    def init(self) -> WAvgState:
        return WAvgState(0.0, 0.0)

    def update(self, mut s: WAvgState, row: WAvgInRow):
        self.update_scalar(s, row.value, row.weight)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WAvgState, *vals: *Ts):
        s.sum_vw += rebind[Float64](vals[0]) * rebind[Float64](vals[1])
        s.sum_w += rebind[Float64](vals[1])

    def merge(self, a: WAvgState, b: WAvgState) -> WAvgState:
        return WAvgState(a.sum_vw + b.sum_vw, a.sum_w + b.sum_w)

    def finalize(self, s: WAvgState) -> Scalar[DType.float64]:
        return s.sum_vw / s.sum_w if s.sum_w != 0.0 else 0.0


# =============================================================================
# Generic-over-F drivers (these prove the engine can be generic over the trait)
# =============================================================================

# UDF-1: `_run_map[F](f, a, b)` — which drove `F.run_scalar` through a
# generic `F: MapFn` bound — is DELETED with the oracle it called. A call
# through a generic trait bound cannot outlive the trait member (unlike a
# conformer's own orphaned method, which merely stops being a trait
# member). `_run_map_row` below proves the same "the engine can be generic
# over F" property through the oracle that survives.
def _run_map_row[F: MapFn](var f: F, row: F.InRow) raises -> Float64:
    return rebind[Float64](f.run_row(row))


def _is_vectorized_map[F: MapFn]() -> Bool:
    """WAVE-11-UDF-F: probes `_MapFnFusedKernel` (the
    engine-internal SIMD fast-path signal that succeeded the deleted
    user-facing vectorized sub-trait). DiscPrice opts into the kernel
    surface; DiscPriceVec is plain MapFn."""
    comptime if conforms_to(F, _MapFnFusedKernel):
        return True
    else:
        return False


def _keep_filter_row[F: FilterFn](var f: F, row: F.InRow) raises -> Bool:
    """UDF-1: was `_run_filter[F](f, a)` over the deleted `F.keep_scalar`.
    Same generic-over-F proof, routed through the surviving row oracle."""
    return f.keep_row(row)


def _agg_two_groups[F: AggFn](var f: F) -> Tuple[Float64, Float64]:
    """Fold two tiny groups through F.update, return their finalized values."""
    var s0 = f.init()
    var s1 = f.init()
    # group 0: (10, 2), (5, 1)  -> sum_vw = 25, sum_w = 3 -> 8.333...
    f.update(s0, rebind[F.InRow](WAvgInRow(10.0, 2.0)))
    f.update(s0, rebind[F.InRow](WAvgInRow(5.0, 1.0)))
    # group 1: (20, 4)          -> sum_vw = 80, sum_w = 4 -> 20.0
    f.update(s1, rebind[F.InRow](WAvgInRow(20.0, 4.0)))
    return (Float64(rebind[Scalar[DType.float64]](f.finalize(s0))),
            Float64(rebind[Scalar[DType.float64]](f.finalize(s1))))


def _agg_merge[F: AggFn](var f: F) -> Float64:
    """Two partials of the same group, then merge + finalize."""
    var a = f.init()
    var b = f.init()
    f.update(a, rebind[F.InRow](WAvgInRow(10.0, 2.0)))   # sum_vw=20, sum_w=2
    f.update(b, rebind[F.InRow](WAvgInRow(5.0, 1.0)))    # sum_vw=5,  sum_w=1
    var m = f.merge(a, b)                                  # sum_vw=25, sum_w=3 -> 8.333...
    return Float64(rebind[Scalar[DType.float64]](f.finalize(m)))


# =============================================================================
# Tests
# =============================================================================

def test_mapfn_run_row() raises:
    var f = DiscPrice()
    # 100 * (1 - 0.1) = 90.0
    assert_almost_equal(f.run_row(LineitemPriceRow(100.0, 0.1)), 90.0)
    # via the generic-over-F driver (proves the engine can be generic):
    assert_almost_equal(_run_map_row(DiscPrice(), LineitemPriceRow(200.0, 0.25)), 150.0)


def test_mapfn_vectorized_conforms_and_dispatch() raises:
    # WAVE-11-UDF-F: the user-facing vectorized sub-trait
    # was deleted. Probe now reads `_MapFnFusedKernel` (the engine-internal
    # SIMD signal that succeeded it). DiscPrice opts in to
    # `_MapFnFusedKernel` (the @staticmethod eval[W] / eval_row surface);
    # DiscPriceVec is plain MapFn (does NOT opt in).
    assert_true(_is_vectorized_map[DiscPrice]())
    assert_true(not _is_vectorized_map[DiscPriceVec]())
    # the oracle still produces the right value (the byte-identity
    # contract — `eval[W=1]` MUST match `run_row` per the kernel trait).
    # UDF-5 deleted DiscPriceVec's orphaned `run_scalar` helper; `run_row`
    # is now the only oracle there is to check.
    var f = DiscPriceVec()
    assert_almost_equal(f.run_row(LineitemPriceRow(100.0, 0.1)), 90.0)


def test_filterfn_keep_row_and_capture() raises:
    var f = QtyAbove(threshold=24.0)
    assert_true(f.keep_row(LineitemQtyRow(25.0)))
    assert_true(not f.keep_row(LineitemQtyRow(24.0)))
    assert_true(not f.keep_row(LineitemQtyRow(10.0)))
    assert_true(f.keep_row(LineitemQtyRow(30.0)))
    assert_true(
        not _keep_filter_row(QtyAbove(threshold=50.0), LineitemQtyRow(49.0))
    )
    assert_true(
        _keep_filter_row(QtyAbove(threshold=50.0), LineitemQtyRow(51.0))
    )
    # WAVE-11-UDF-A: keep_chunk path removed — QtyAbove no longer
    # conforms to FilterFnVectorized (trait deleted). UDF-1: `keep_row` is
    # now the ONLY engine path, and UDF-5 deleted the orphaned `keep_scalar`
    # helper it used to delegate to, so every assertion above is on it.


def test_aggfn_lifecycle() raises:
    var (g0, g1) = _agg_two_groups(WeightedAvg())
    assert_almost_equal(g0, 25.0 / 3.0)   # (10*2 + 5*1)/(2+1)
    assert_almost_equal(g1, 20.0)         # 20*4 / 4
    var merged = _agg_merge(WeightedAvg())
    assert_almost_equal(merged, 25.0 / 3.0)
    # WAVE-11-UDF-F: inline update_chunk[W=4] block removed —
    # WeightedAvg no longer conforms to the user-facing vectorized sub-trait
    # (deleted). The SIMD lifecycle parity is covered by
    # tests/eval/test_agg_fn_simplified.mojo:test_lifecycle_two_groups_merge.
    # Per-row dispatch via update / update_scalar remains the engine path
    # (the AggFnAcc adapter is byte-identical with or without the deleted
    # vectorized branch — the trait contract gave it lane-for-lane parity).


def _schema_name[S: SchemaDescriptor, i: Int]() -> String:
    return comptime(S.cols[i].name)


def _schema_dtype[S: SchemaDescriptor, i: Int]() -> Int:
    return comptime(S.cols[i].dtype)


def _schema_ncols[S: SchemaDescriptor]() -> Int:
    return comptime(S.num_cols())


def test_comptime_schema_machinery() raises:
    # Read the trait's comptime OutputSchema/InputSchema at comptime, surface to runtime.
    assert_equal(_schema_name[DiscPrice.OutputSchema, 0](), "l_disc_price")
    assert_equal(_schema_dtype[DiscPrice.OutputSchema, 0](), DT_F64)
    assert_equal(_schema_name[DiscPrice.InputSchema, 0](), "l_extendedprice")
    assert_equal(_schema_name[DiscPrice.InputSchema, 1](), "l_discount")
    assert_equal(_schema_ncols[DiscPrice.InputSchema](), 2)
    # OutType agrees with OutputSchema.cols[0].dtype:
    assert_true(DiscPrice.OutType == dtag_to_dtype(DT_F64))
    # the dtype-tag <-> ArrowType mapping round-trips for the SIMD-able tags:
    assert_equal(dtag_of_arrow_type_id(dtag_to_arrow_type_id(DT_F64)), DT_F64)
    assert_equal(dtag_of_arrow_type_id(dtag_to_arrow_type_id(DT_I64)), DT_I64)
    assert_true(dtag_is_simd(DT_F32))
    assert_true(not dtag_is_simd(11))   # DT_STRING is not SIMD-able


def test_udf_id_distinct() raises:
    # the operator-factory selectors are distinct per type (the plan_cse fold relies on this)
    assert_true(DiscPrice.UDF_ID != DiscPriceVec.UDF_ID)
    assert_true(DiscPrice.UDF_ID != QtyAbove.UDF_ID)
    assert_true(QtyAbove.UDF_ID != WeightedAvg.UDF_ID)
    # default null_mode is PROPAGATE; default parallelism is stateless:
    assert_equal(DiscPrice.null_mode._tag, NullHandling.PROPAGATE._tag)
    assert_true(DiscPrice.parallelism.is_stateless())


def test_stateful_contract() raises:
    assert_equal(StatefulContract.stateless.tag, CONTRACT_STATELESS)
    assert_equal(StatefulContract.serial_ordered.tag, CONTRACT_SERIAL_ORDERED)
    assert_equal(StatefulContract.mergeable.tag, 2)
    assert_true(StatefulContract.stateless.is_stateless())
    assert_true(not StatefulContract.serial_ordered.is_stateless())
    assert_equal(CONTRACT_PARTITION_LOCAL, 3)
    # KeyList — the partition/order-key carrier for partition_local (P4):
    var kl = KeyList([KeyEntry("user_id", True), KeyEntry("region", True)])
    assert_equal(kl.num_keys(), 2)
    assert_equal(kl.names_joined(), "user_id, region")
    assert_equal(KeyList().num_keys(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
