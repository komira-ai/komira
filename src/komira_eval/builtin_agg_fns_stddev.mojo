# =============================================================================
# builtin_agg_fns_stddev.mojo — Built-in STDDEV_SAMP cells
# =============================================================================
#
# Sample standard deviation, the genuinely-hard agg: a 2-MOMENT running
# accumulator (Welford `[count | mean | m2]`), NOT a single fold. State is
# `WelfordStateF64`; output is always Float64 (a stddev).
#
# These `AggFn` conformers exist so the typed agg MARKER's legacy `BOUND[S]`
# member type-checks (`AggSlot[AggFnAgg[StddevSampF64, col]]`). `BOUND` is
# DEAD-at-value-construction (the `AggFnAgg.init()` `constrained[
# False]` wall — see `typed_agg_markers.mojo`); the production column-native
# path uses the marker's `OP_TY = StddevSampOp[dt]` (`hash_agg_op_dt.mojo`),
# and the typed-ROW path uses its own row-typed stddev cell.
# The bodies below ARE correct (sample stddev, NaN for count <= 1) so a future
# AggFn-path revival is honest, not just a structural placeholder.
#
# Convention: SAMPLE stddev (ddof=1) = sqrt(m2/(count-1)); count <= 1 -> NaN.
# Bit-for-bit the live untyped `StddevSampF64` oracle
# (`komira_engine_operators.agg.agg_state_slab`).
#
# Mojo discipline: no UnsafePointer in signatures, no wildcard origins,
# file < 1000 LOC.
# =============================================================================

from std.math import sqrt

from komira_eval.agg_fn import AggFn
from komira_eval.schema_descriptor import schema_of, DT_F64
from komira_eval.builtin_agg_fns_states import (
    RowI32, RowI64, RowF32, RowF64, WelfordStateF64,
)


# -----------------------------------------------------------------------------
# Shared Welford helpers (the recurrence is DType-independent once widened).
# -----------------------------------------------------------------------------


@always_inline
def _welford_fn_update(mut s: WelfordStateF64, x: Float64):
    s.count += Int64(1)
    var delta = x - s.mean
    s.mean += delta / s.count.cast[DType.float64]()
    s.m2 += delta * (x - s.mean)


@always_inline
def _welford_fn_merge(
    a: WelfordStateF64, b: WelfordStateF64
) -> WelfordStateF64:
    if b.count == 0:
        return WelfordStateF64(a.count, a.mean, a.m2)
    if a.count == 0:
        return WelfordStateF64(b.count, b.mean, b.m2)
    var na = a.count.cast[DType.float64]()
    var nb = b.count.cast[DType.float64]()
    var n = na + nb
    var delta = b.mean - a.mean
    # m2 BEFORE mean — the formula uses the OLD means.
    var m2 = a.m2 + b.m2 + delta * delta * na * nb / n
    var mean = (na * a.mean + nb * b.mean) / n
    return WelfordStateF64(a.count + b.count, mean, m2)


@always_inline
def _welford_fn_finalize_samp(s: WelfordStateF64) -> Scalar[DType.float64]:
    if s.count <= 1:
        return Float64(0.0) / Float64(0.0)  # NaN (DuckDB NULL convention)
    return sqrt(s.m2 / (s.count - 1).cast[DType.float64]())


@always_inline
def _welford_fn_finalize_var(s: WelfordStateF64) -> Scalar[DType.float64]:
    """SAMPLE variance drain: M2/(count-1) for count > 1; NaN
    otherwise. The un-sqrt'd sibling of `_welford_fn_finalize_samp`
    (`var_samp = stddev_samp ** 2`)."""
    if s.count <= 1:
        return Float64(0.0) / Float64(0.0)  # NaN (DuckDB NULL convention)
    return s.m2 / (s.count - 1).cast[DType.float64]()


@fieldwise_init
struct StddevSampI32(AggFn):
    """STDDEV_SAMP(Int32) -> Float64. Sample stddev; integer widens to F64."""

    comptime InRow = RowI32
    comptime OutputSchema = schema_of["stddev_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WelfordStateF64
    comptime UDF_ID = UInt32(0x0004_0803)

    def init(self) -> WelfordStateF64:
        return WelfordStateF64(Int64(0), Float64(0.0), Float64(0.0))

    def update(self, mut s: WelfordStateF64, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WelfordStateF64, *vals: *Ts):
        _welford_fn_update(s, Float64(rebind[Int32](vals[0])))

    def merge(self, a: WelfordStateF64, b: WelfordStateF64) -> WelfordStateF64:
        return _welford_fn_merge(a, b)

    def finalize(self, s: WelfordStateF64) -> Scalar[DType.float64]:
        return _welford_fn_finalize_samp(s)


@fieldwise_init
struct StddevSampI64(AggFn):
    """STDDEV_SAMP(Int64) -> Float64. Sample stddev; integer widens to F64."""

    comptime InRow = RowI64
    comptime OutputSchema = schema_of["stddev_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WelfordStateF64
    comptime UDF_ID = UInt32(0x0004_0804)

    def init(self) -> WelfordStateF64:
        return WelfordStateF64(Int64(0), Float64(0.0), Float64(0.0))

    def update(self, mut s: WelfordStateF64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WelfordStateF64, *vals: *Ts):
        _welford_fn_update(s, Float64(rebind[Int64](vals[0])))

    def merge(self, a: WelfordStateF64, b: WelfordStateF64) -> WelfordStateF64:
        return _welford_fn_merge(a, b)

    def finalize(self, s: WelfordStateF64) -> Scalar[DType.float64]:
        return _welford_fn_finalize_samp(s)


@fieldwise_init
struct StddevSampF32(AggFn):
    """STDDEV_SAMP(Float32) -> Float64. Sample stddev; F32 widens to F64."""

    comptime InRow = RowF32
    comptime OutputSchema = schema_of["stddev_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WelfordStateF64
    comptime UDF_ID = UInt32(0x0004_0809)

    def init(self) -> WelfordStateF64:
        return WelfordStateF64(Int64(0), Float64(0.0), Float64(0.0))

    def update(self, mut s: WelfordStateF64, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WelfordStateF64, *vals: *Ts):
        _welford_fn_update(s, Float64(rebind[Float32](vals[0])))

    def merge(self, a: WelfordStateF64, b: WelfordStateF64) -> WelfordStateF64:
        return _welford_fn_merge(a, b)

    def finalize(self, s: WelfordStateF64) -> Scalar[DType.float64]:
        return _welford_fn_finalize_samp(s)


@fieldwise_init
struct StddevSampF64(AggFn):
    """STDDEV_SAMP(Float64) -> Float64. Canonical sample-stddev cell."""

    comptime InRow = RowF64
    comptime OutputSchema = schema_of["stddev_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WelfordStateF64
    comptime UDF_ID = UInt32(0x0004_080A)

    def init(self) -> WelfordStateF64:
        return WelfordStateF64(Int64(0), Float64(0.0), Float64(0.0))

    def update(self, mut s: WelfordStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WelfordStateF64, *vals: *Ts):
        _welford_fn_update(s, rebind[Float64](vals[0]))

    def merge(self, a: WelfordStateF64, b: WelfordStateF64) -> WelfordStateF64:
        return _welford_fn_merge(a, b)

    def finalize(self, s: WelfordStateF64) -> Scalar[DType.float64]:
        return _welford_fn_finalize_samp(s)


# =============================================================================
# VAR_SAMP cells — the M2-finalize-WITHOUT-sqrt sibling of STDDEV_SAMP.
# Identical Welford state + Chan combine; finalize = M2/(count-1) (no sqrt).
# Output is always Float64; `var_samp = stddev_samp ** 2`. count <= 1 -> NaN.
# =============================================================================


@fieldwise_init
struct VarSampI32(AggFn):
    """VAR_SAMP(Int32) -> Float64. Sample variance; integer widens to F64."""

    comptime InRow = RowI32
    comptime OutputSchema = schema_of["var_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WelfordStateF64
    comptime UDF_ID = UInt32(0x0004_0813)

    def init(self) -> WelfordStateF64:
        return WelfordStateF64(Int64(0), Float64(0.0), Float64(0.0))

    def update(self, mut s: WelfordStateF64, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WelfordStateF64, *vals: *Ts):
        _welford_fn_update(s, Float64(rebind[Int32](vals[0])))

    def merge(self, a: WelfordStateF64, b: WelfordStateF64) -> WelfordStateF64:
        return _welford_fn_merge(a, b)

    def finalize(self, s: WelfordStateF64) -> Scalar[DType.float64]:
        return _welford_fn_finalize_var(s)


@fieldwise_init
struct VarSampI64(AggFn):
    """VAR_SAMP(Int64) -> Float64. Sample variance; integer widens to F64."""

    comptime InRow = RowI64
    comptime OutputSchema = schema_of["var_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WelfordStateF64
    comptime UDF_ID = UInt32(0x0004_0814)

    def init(self) -> WelfordStateF64:
        return WelfordStateF64(Int64(0), Float64(0.0), Float64(0.0))

    def update(self, mut s: WelfordStateF64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WelfordStateF64, *vals: *Ts):
        _welford_fn_update(s, Float64(rebind[Int64](vals[0])))

    def merge(self, a: WelfordStateF64, b: WelfordStateF64) -> WelfordStateF64:
        return _welford_fn_merge(a, b)

    def finalize(self, s: WelfordStateF64) -> Scalar[DType.float64]:
        return _welford_fn_finalize_var(s)


@fieldwise_init
struct VarSampF32(AggFn):
    """VAR_SAMP(Float32) -> Float64. Sample variance; F32 widens to F64."""

    comptime InRow = RowF32
    comptime OutputSchema = schema_of["var_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WelfordStateF64
    comptime UDF_ID = UInt32(0x0004_0819)

    def init(self) -> WelfordStateF64:
        return WelfordStateF64(Int64(0), Float64(0.0), Float64(0.0))

    def update(self, mut s: WelfordStateF64, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WelfordStateF64, *vals: *Ts):
        _welford_fn_update(s, Float64(rebind[Float32](vals[0])))

    def merge(self, a: WelfordStateF64, b: WelfordStateF64) -> WelfordStateF64:
        return _welford_fn_merge(a, b)

    def finalize(self, s: WelfordStateF64) -> Scalar[DType.float64]:
        return _welford_fn_finalize_var(s)


@fieldwise_init
struct VarSampF64(AggFn):
    """VAR_SAMP(Float64) -> Float64. Canonical sample-variance cell."""

    comptime InRow = RowF64
    comptime OutputSchema = schema_of["var_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WelfordStateF64
    comptime UDF_ID = UInt32(0x0004_081A)

    def init(self) -> WelfordStateF64:
        return WelfordStateF64(Int64(0), Float64(0.0), Float64(0.0))

    def update(self, mut s: WelfordStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WelfordStateF64, *vals: *Ts):
        _welford_fn_update(s, rebind[Float64](vals[0]))

    def merge(self, a: WelfordStateF64, b: WelfordStateF64) -> WelfordStateF64:
        return _welford_fn_merge(a, b)

    def finalize(self, s: WelfordStateF64) -> Scalar[DType.float64]:
        return _welford_fn_finalize_var(s)
