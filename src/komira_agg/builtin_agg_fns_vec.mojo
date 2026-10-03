# =============================================================================
# builtin_agg_fns_vec.mojo — Built-in AggFn conformers with SIMD-reduce hot paths
# =============================================================================
#
# SIMD-accelerated fold paths for the hot
# aggregate cells. Each `*Vec` cell here is a DISTINCT conformer (not an
# extension of its non-Vec sibling).
#
# These cells conform to plain `AggFn`; there is no user-facing SIMD opt-in
# (`update_chunk[W, *Ts]`) sub-trait: a vectorized branch would have to
# produce lane-for-lane identical results to `update_scalar`, so the scalar
# path IS the byte-identical reference. The SIMD fast-path surface is the
# engine-internal `_AggFnFusedKernel` opt-in
# (see `komira_engine_operators._internal.agg_fn_fused_kernel`).
#
# These cells remain as distinct conformers (their `update_scalar` bodies
# differ from their non-Vec siblings only in carrying distinct `UDF_ID`s
# for the plan-CSE key — the scalar fold is identical). A future slot
# can migrate them to `_AggFnFusedKernel` to recover the SIMD reduce path
# via the @staticmethod-typed kernel surface.
#
# Cells shipped (all six are plain AggFn; SIMD reduce paths removed):
#   SumI64Vec, SumF64Vec  -- formerly SIMD reduce_add (removed)
#   MinI64Vec, MaxI64Vec  -- formerly SIMD reduce_min / reduce_max (removed)
#   CountI64Vec           -- formerly bool-mask popcount (removed)
#   AvgF64Vec             -- formerly SIMD reduce_add + count_add (removed)
#
# These mirror the scalar bodies in builtin_agg_fns_sum.mojo /
# builtin_agg_fns_minmax.mojo / builtin_agg_fns_count.mojo /
# builtin_agg_fns_avg.mojo for the typed scalar path.
#
# Mojo discipline: no UnsafePointer in signatures, no wildcard origins,
# file < 1000 LOC.
# =============================================================================

from komira_udf.agg_fn import AggFn
from komira_udf.schema_descriptor import schema_of, DT_I64, DT_F64
from komira_agg.builtin_agg_fns_states import (
    RowI64, RowF64,
    SumStateI64, SumStateF64,
    MinMaxStateI64,
    CountState, AvgStateF64,
)


# =============================================================================
# SumI64Vec — SUM(Int64) -> Int64. Scalar fold; SIMD reduce_add path
# was removed with the user-facing vectorized sub-trait.
# =============================================================================


@fieldwise_init
struct SumI64Vec(AggFn):
    """SUM(Int64) — same scalar body as `SumI64` in builtin_agg_fns_sum.mojo
    but with a distinct UDF_ID so plan-CSE keeps the two as distinct
    operator-factory cells."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["sum_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = SumStateI64
    comptime UDF_ID = UInt32(0x0004_0114)  # 0x14 = Vec variant of SumI64 (0x04)

    def init(self) -> SumStateI64:
        return SumStateI64(Int64(0))

    def update(self, mut s: SumStateI64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateI64, *vals: *Ts):
        s.sum += rebind[Int64](vals[0])

    def merge(self, a: SumStateI64, b: SumStateI64) -> SumStateI64:
        return SumStateI64(a.sum + b.sum)

    def finalize(self, s: SumStateI64) -> Scalar[DType.int64]:
        return s.sum


# =============================================================================
# SumF64Vec — SUM(Float64) -> Float64. Scalar fold.
# =============================================================================


@fieldwise_init
struct SumF64Vec(AggFn):
    """SUM(Float64) — non-compensated. SumF64KahanAcc
    (columnar_acc_typed.mojo) remains the precision path."""
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["sum_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = SumStateF64
    comptime UDF_ID = UInt32(0x0004_011A)  # Vec variant of SumF64

    def init(self) -> SumStateF64:
        return SumStateF64(Float64(0.0))

    def update(self, mut s: SumStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateF64, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])

    def merge(self, a: SumStateF64, b: SumStateF64) -> SumStateF64:
        return SumStateF64(a.sum + b.sum)

    def finalize(self, s: SumStateF64) -> Scalar[DType.float64]:
        return s.sum


# =============================================================================
# MinI64Vec — MIN(Int64). Scalar fold.
# =============================================================================


@fieldwise_init
struct MinI64Vec(AggFn):
    """MIN(Int64) — scalar fold."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["min_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = MinMaxStateI64
    comptime UDF_ID = UInt32(0x0004_0214)  # Vec variant of MinI64

    def init(self) -> MinMaxStateI64:
        return MinMaxStateI64(Int64(9223372036854775807), False)

    def update(self, mut s: MinMaxStateI64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI64, *vals: *Ts):
        var v = rebind[Int64](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI64, b: MinMaxStateI64) -> MinMaxStateI64:
        if not a.seen:
            return MinMaxStateI64(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI64(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateI64(b.value, True)
        return MinMaxStateI64(a.value, True)

    def finalize(self, s: MinMaxStateI64) -> Scalar[DType.int64]:
        return s.value


# =============================================================================
# MaxI64Vec — MAX(Int64). Scalar fold.
# =============================================================================


@fieldwise_init
struct MaxI64Vec(AggFn):
    """MAX(Int64) — scalar fold."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["max_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = MinMaxStateI64
    comptime UDF_ID = UInt32(0x0004_0314)  # Vec variant of MaxI64

    def init(self) -> MinMaxStateI64:
        return MinMaxStateI64(Int64(-9223372036854775808), False)

    def update(self, mut s: MinMaxStateI64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI64, *vals: *Ts):
        var v = rebind[Int64](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI64, b: MinMaxStateI64) -> MinMaxStateI64:
        if not a.seen:
            return MinMaxStateI64(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI64(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateI64(b.value, True)
        return MinMaxStateI64(a.value, True)

    def finalize(self, s: MinMaxStateI64) -> Scalar[DType.int64]:
        return s.value


# =============================================================================
# CountI64Vec — COUNT(Int64). Scalar fold (popcount path removed).
# =============================================================================


@fieldwise_init
struct CountI64Vec(AggFn):
    """COUNT(Int64) — unconditional +1 per non-null row (the PROPAGATE-null
    filter is on AggFnAcc, not the kernel)."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0414)  # Vec variant of CountI64

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


# =============================================================================
# AvgF64Vec — AVG(Float64). Scalar fold.
# =============================================================================


@fieldwise_init
struct AvgF64Vec(AggFn):
    """AVG(Float64) — scalar (sum, count) fold; finalize divides."""
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_051A)  # Vec variant of AvgF64

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)
