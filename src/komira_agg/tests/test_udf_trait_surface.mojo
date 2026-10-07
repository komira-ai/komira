# =============================================================================
# test_udf_trait_surface.mojo — unified UDF trait-surface acceptance tests
# =============================================================================
#
# Locks in the 3 unified trait surfaces (Predicate / RowTransform /
# Aggregator) + the Purity enum.
#
# Coverage:
#   1. Purity enum — PURE / STATELESS / STATEFUL constants, tag(),
#      is_pure(), is_pushable(), equality.
#   2. Predicate — a conformer overriding ONLY eval_scalar picks up the
#      Pattern B default-body eval[W]; a conformer overriding BOTH
#      gets the override; the PURITY default is STATELESS.
#   3. RowTransform — ARITY + dtype_at; a conformer is usable through the
#      trait surface. (A parametric-return eval[W,k]
#      is NOT implementable in Mojo — see row_transform.mojo
#      module doc — so the trait's unifying method is write_one.)
#   4. Aggregator — init / update_scalar / update_chunk default body /
#      combine / finalize / STATE_SIZE; PURITY default PURE.
#   5. Parametric trait-dispatch helpers — a `fn f[P: Predicate]` confirms
#      each conformer is usable through the trait surface (the variadic
#      Stage substrate slot-type position).
# =============================================================================

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.batch_view import BatchView, batch_view_over

from komira_arrow.multi_column_builder import (
    MultiColumnSink,
    SinkKind,
)

from komira_udf.purity import Purity
from komira_udf.predicate import Predicate
from komira_udf.row_transform import RowTransform
from komira_agg.aggregator import Aggregator


# -----------------------------------------------------------------------------
# Fixture — a 1-column Int64 RecordBatch, c0 = [0, 1, ..., n).
# -----------------------------------------------------------------------------
def _build_i64_batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    var vals1 = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
        vals1.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var arr1 = PrimitiveArray[DType.int64].from_list(vals1^)
    var schema = Schema.from_fields_2(
        Field("c0", DType.int64, True),
        Field("c1", DType.int64, True),
    )
    var col0 = Column.from_primitive[DType.int64](arr^)
    var col1 = Column.from_primitive[DType.int64](arr1^)
    return RecordBatch.from_typed_columns_2(schema^, col0^, col1^)


# -----------------------------------------------------------------------------
# Predicate conformers.
# -----------------------------------------------------------------------------
# Overrides ONLY eval_scalar — picks up the Pattern B default eval[W].
@fieldwise_init
struct GtFiveP(Predicate):
    def eval_scalar[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) -> Bool:
        return Int(batch.col_i64(0).load[1](i)[0]) > 5


# Overrides BOTH — the override eval[W] forces lane 0 True as a marker.
@fieldwise_init
struct MarkedGtP(Predicate):
    comptime PURITY: Purity = Purity.PURE

    def eval_scalar[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) -> Bool:
        return Int(batch.col_i64(0).load[1](i)[0]) > 5

    def eval[
        W: Int, bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) raises -> SIMD[DType.bool, W]:
        var mask = SIMD[DType.bool, W](fill=False)
        var n = batch.n_rows()

        comptime for lane in range(W):
            if i + lane < n:
                mask[lane] = self.eval_scalar[bo](batch, i + lane)
        if W >= 1:
            mask[0] = True  # marker — distinguishes override from default
        return mask


# Parametric helper — confirms a conformer is usable through the trait
# surface (the Stage slot-type position).
def _count_via_predicate[
    P: Predicate, bo: Origin[mut=False]
](mut p: P, batch: BatchView[bo]) raises -> Int:
    var kept = 0
    var n = batch.n_rows()
    for i in range(n):
        if p.eval_scalar[bo](batch, i):
            kept += 1
    return kept


# -----------------------------------------------------------------------------
# RowTransform conformer — single-output identity (ARITY=1).
# `RowTransform.write_one`'s builder
# parameter is now bounded on `MultiColumnSink` (was `AnyType`). The minimal
# in-tree builder stand-in `_TestBuilder` conforms to `MultiColumnSink` and
# `write_one` drives it via the real `append_at[k, DT]` surface — NO `rebind`
# hack. (The production `MultiColumnBuilder[*Bs]` also conforms; this test
# keeps the minimal builder so the test stays a focused trait-surface check.)
# -----------------------------------------------------------------------------
@fieldwise_init
struct _TestBuilder(Movable, MultiColumnSink):
    var last_written: Int64

    def append_at[k: Int, DT: DType](mut self, value: Scalar[DT]):
        # Single-slot stand-in: record the value of slot 0 as Int64.
        self.last_written = Int64(rebind[Scalar[DType.int64]](value))


@fieldwise_init
struct IdentityI64(RowTransform):
    comptime ARITY: Int = 1

    @staticmethod
    def out_kind_at[k: Int]() -> SinkKind:
        # `RowTransform.out_kind_at` is REQUIRED, not defaulted
        # (a default on the parent would block `ExprXString` from declaring
        # STRING — Mojo rejects conflicting parent+refining defaults). A
        # struct conforming to `RowTransform` DIRECTLY must spell it out,
        # exactly as it must spell out `dtype_at`.
        return SinkKind.NUMERIC

    @staticmethod
    def dtype_at[k: Int]() -> DType:
        return DType.int64

    def write_one[
        bo: Origin[mut=False], MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        # write_one is the unified surface method. With the A1 tightening,
        # `MCB: MultiColumnSink` exposes `append_at[k, DT]` directly — the
        # body lands the single Int64 output value into output slot 0.
        builders.append_at[0, DType.int64](batch.col_i64(0).load[1](i)[0])

    def project_one[
        bo: Origin[mut=False], dst_k: Int, MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        # `RowTransform.project_one` — the `mut self` Stage project-emit
        # variant, so
        # ProjectList.emit_projected can dispatch through stored Out instances
        # (whose runtime `_idx` is populated by `bind`). `IdentityI64` is a
        # zero-field POD whose output depends only on the input column, so
        # the body mirrors `write_one`: copy input col 0's row `i` into
        # output slot `dst_k`. (The directly-conforming ExprX numeric traits
        # inherit a delegating default; a struct conforming to `RowTransform`
        # DIRECTLY must spell `project_one` out.)
        builders.append_at[dst_k, DType.int64](batch.col_i64(0).load[1](i)[0])


# Parametric helper — confirms a RowTransform conformer is usable through
# the trait surface (the Stage *Outs slot-type position).
def _write_via_row_transform[
    R: RowTransform, bo: Origin[mut=False]
](mut r: R, batch: BatchView[bo], i: Int, mut b: _TestBuilder) raises:
    r.write_one[bo, _TestBuilder](batch, i, b)


# -----------------------------------------------------------------------------
# Aggregator conformer — running Int64 sum.
# -----------------------------------------------------------------------------
@fieldwise_init
struct SumI64Agg(Aggregator):
    comptime StateTy = Int64
    comptime OUT_DT: DType = DType.int64

    @staticmethod
    def init() -> Int64:
        return Int64(0)

    @staticmethod
    def make() -> Self:
        # `Aggregator.make` — field-less default-construct. This conformer is genuinely field-less, so `make()` is
        # the trivial no-arg construct.
        return Self()

    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Int64, batch: BatchView[bo], i: Int):
        state += batch.col_i64(0).load[1](i)[0]

    def combine(mut self, mut into: Int64, var partial: Int64):
        into += partial

    @staticmethod
    def finalize(state: Int64) -> Int64:
        return state


def _expect(cond: Bool, label: String) raises:
    if not cond:
        raise Error("FAIL: " + label)
    print("  ok:", label)


def main() raises:
    print("=== test_udf_trait_surface ===")

    # ----- 1. Purity enum -----
    _expect(Purity.PURE.tag() == 0, "Purity.PURE tag == 0")
    _expect(Purity.STATELESS.tag() == 1, "Purity.STATELESS tag == 1")
    _expect(Purity.STATEFUL.tag() == 2, "Purity.STATEFUL tag == 2")
    _expect(Purity.PURE.is_pure(), "PURE.is_pure()")
    _expect(not Purity.STATELESS.is_pure(), "STATELESS not pure")
    _expect(Purity.PURE.is_pushable(), "PURE pushable")
    _expect(Purity.STATELESS.is_pushable(), "STATELESS pushable")
    _expect(not Purity.STATEFUL.is_pushable(), "STATEFUL not pushable")
    _expect(Purity.PURE == Purity.PURE, "Purity equality")
    _expect(Purity.PURE != Purity.STATEFUL, "Purity inequality")

    var batch = _build_i64_batch(64)
    var view = batch_view_over(batch)

    # ----- 2. Predicate — Pattern B default body -----
    # c0 = [0..64); rows with c0 > 5 -> 58 kept.
    var gt = GtFiveP()
    var mask4 = gt.eval[4](view, 0)  # rows 0..3, all <= 5 -> all False
    _expect(
        not Bool(mask4[0]) and not Bool(mask4[3]),
        "Predicate default eval[4] rows 0..3 all False",
    )
    var mask4b = gt.eval[4](view, 4)  # rows 4..7: 4,5 False; 6,7 True
    _expect(
        not Bool(mask4b[0])
        and not Bool(mask4b[1])
        and Bool(mask4b[2])
        and Bool(mask4b[3]),
        "Predicate default eval[4] rows 4..7 = [F,F,T,T]",
    )
    var kept = _count_via_predicate(gt, view)
    _expect(kept == 58, "Predicate eval_scalar via trait helper kept == 58")

    # ----- 2b. Predicate override eval[W] wins -----
    var marked = MarkedGtP()
    var mmask = marked.eval[4](view, 0)  # override forces lane 0 True
    _expect(Bool(mmask[0]), "Predicate override eval[4] lane-0 marker fired")

    # ----- 3. RowTransform -----
    _expect(IdentityI64.ARITY == 1, "RowTransform ARITY == 1")
    _expect(
        IdentityI64.dtype_at[0]() == DType.int64,
        "RowTransform dtype_at[0] == int64",
    )
    var idt = IdentityI64()
    var builder = _TestBuilder(Int64(-1))
    # write_one through the trait surface via a parametric helper.
    _write_via_row_transform(idt, view, 7, builder)
    _expect(
        Int(builder.last_written) == 7,
        "RowTransform write_one (via trait) row 7 -> builder == 7",
    )

    # ----- 4. Aggregator -----
    var agg = SumI64Agg()
    var st = SumI64Agg.init()
    _expect(Int(st) == 0, "Aggregator init == 0")
    # update_scalar over all 64 rows: sum(0..63) = 2016.
    for i in range(view.n_rows()):
        agg.update_scalar[origin_of(batch)](st, view, i)
    _expect(Int(st) == 2016, "Aggregator update_scalar sum == 2016")
    _expect(
        Int(SumI64Agg.finalize(st)) == 2016, "Aggregator finalize == 2016"
    )

    # update_chunk default body over a fresh state — same result.
    var st2 = SumI64Agg.init()
    var i2 = 0
    while i2 + 8 <= view.n_rows():
        agg.update_chunk[8, origin_of(batch)](
            st2, view, i2, SIMD[DType.bool, 8](fill=True)
        )
        i2 += 8
    _expect(Int(st2) == 2016, "Aggregator update_chunk default body == 2016")

    # combine — two partials of 2016 each merge to 4032.
    var into = st
    agg.combine(into, st2)
    _expect(Int(into) == 4032, "Aggregator combine 2016 + 2016 == 4032")
    _expect(SumI64Agg.STATE_SIZE == 8, "Aggregator STATE_SIZE (sizeof Int64)")

    print("=== test_udf_trait_surface: ALL PASS ===")
