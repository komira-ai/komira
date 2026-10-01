# =============================================================================
# builtin_agg_fns_corr.mojo — bivariate CORR(x, y) Aggregator (Welford co-moment)
# =============================================================================
#
# The `CorrF64Agg` conformer
# lets the typed-column scalar + grouped agg paths self-serve CORR.
#
# THE 2-INPUT WRINKLE
# -------------------
# CORR reads TWO columns per row (x and y). The single-column `HashAggOpAgg[Op,
# col]` adapter (`hash_agg_op_dt.mojo`) cannot serve it. The canonical 2-column
# path is to conform DIRECTLY to the unified `Aggregator` trait — the precedent
# is `SumProductF64Agg[col_a, col_b]` (`builtin_agg_fns_sum_product.mojo`), the
# productized 2-column SUM(A*B). `CorrF64Agg` follows that exact shape (two
# comptime column indices read in `update_scalar` via the BatchView typed-accessor
# ladder), extended to a 6-moment co-variance accumulator + a stable Pearson
# finalize.
#
# ALGORITHM = WELFORD CO-MOMENT (numerically stable; matches DuckDB to last ULP).
# The naive moment-sum form `n*Sxx - Sx^2` loses precision via catastrophic
# cancellation for large means; instead we carry a bivariate Welford state
# `[n | mean_x | mean_y | M2_x | M2_y | C2]` (the StddevSampOp `WelfordRunningState`
# convention extended to two variables + a co-moment), with:
#   update  : online co-moment update (dx=x-mean_x BEFORE the mean update;
#             C2 += dx * (y - mean_y_NEW)).
#   combine : Chan et al. parallel-merge for both M2 terms AND the co-moment
#             (M2/C2 use the OLD means; delta scaled by na*nb/n). Associative —
#             the multi-worker fold is byte-identical to single-worker.
#   finalize: Pearson r = C2 / sqrt(M2_x * M2_y). Returns NaN for n < 2 OR when
#             either M2 is 0 (a constant column => zero variance => DuckDB NaN).
#             This matches DuckDB `corr(x, y)`: NaN for n=1 and for a constant
#             input (the documented "DuckDB NULL/NaN convention").
#
# DType-GENERIC: parametric on `(dt_x, dt_y, col_x, col_y)`; each column is read
# in its NATIVE DType off the BatchView, then `.cast[float64]()` BEFORE the
# co-moment recurrence — so CORR over int columns is correct. The arity is FIXED
# at 2 (CORR is intrinsically bivariate), so this is NOT an arity-sibling clone
# (the ban on arity-sibling clones targets arity-as-the-axis families; CORR
# has a single arity).
# Output is ALWAYS Float64 (a correlation coefficient).
#
# Encapsulation invariants:
#   - NO UnsafePointer in any signature.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads the per-batch witness.
#   - NO partial-move-via-take_pointee.
#   - POD `CoMomentRunningState` state (48 bytes, all primitive scalars; no heap —
#     slab-safe in the `AggSlot[A].states: List[A.StateTy]` per-group vector).
#
# Cross-references:
#   - `aggregator.mojo` — the unified `Aggregator` trait surface.
#   - `builtin_agg_fns_sum_product.mojo` — the 2-column precedent this mirrors.
#   - `hash_agg_op_dt.mojo` §2b — the single-variable Welford/Chan analogue.
# =============================================================================

from std.math import sqrt

from komira_core.collections.batch_view import BatchView
from komira_eval.aggregator import Aggregator


# =============================================================================
# §1 — CoMomentRunningState — bivariate Welford state (POD, slab-safe)
# =============================================================================


@fieldwise_init
struct CoMomentRunningState(
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Per-bucket bivariate Welford running-moment state for CORR.

    48 bytes, all primitive scalars (slab-safe — no `List` / `String` /
    `OwnedPointer` field). Identity = (n=0, all means/moments 0.0); merging any
    state with the identity yields the original (the `combine` zero-count
    early-out preserves this).

    Fields:
      - `n`      : observation count.
      - `mean_x` : running mean of x.
      - `mean_y` : running mean of y.
      - `m2_x`   : sum of squared deviations of x (variance accumulator).
      - `m2_y`   : sum of squared deviations of y.
      - `c2`     : co-moment (sum of cross deviations) — the covariance
                   accumulator.
    """

    var n: Int64
    var mean_x: Float64
    var mean_y: Float64
    var m2_x: Float64
    var m2_y: Float64
    var c2: Float64


# =============================================================================
# §2 — native-DType-to-F64 column read helper (the typed-accessor ladder)
# =============================================================================
#
# Reads column `col` (DType `dt`, comptime-known) off the BatchView at logical
# index `i` and returns it widened to Float64. Folds to a direct typed load + a
# cast (no runtime DType dispatch) per the monomorphized `dt`. Same ladder shape
# as `HashAggOpAgg.update_scalar` (this covers I64/I32/F64/F32).
# =============================================================================


@always_inline
def _read_col_f64[
    dt: DType, col: Int, bo: Origin[mut=False]
](batch: BatchView[bo], i: Int) -> Float64:
    comptime if dt == DType.float64:
        return batch.col_f64(col).load[1](i)[0].cast[DType.float64]()
    elif dt == DType.int64:
        return batch.col_i64(col).load[1](i)[0].cast[DType.float64]()
    elif dt == DType.int32:
        return batch.col_i32(col).load[1](i)[0].cast[DType.float64]()
    elif dt == DType.float32:
        return batch.col_f32(col).load[1](i)[0].cast[DType.float64]()
    else:
        comptime assert False, ("CorrF64Agg: input column DType is not yet supported ("
            "supported: int64 / int32 / float64 / float32; extend the ladder when "
            "adding new input DType coverage).")


# =============================================================================
# §3 — CorrF64Agg[dt_x, dt_y, col_x, col_y] — the bivariate CORR Aggregator
# =============================================================================


@fieldwise_init
struct CorrF64Agg[dt_x: DType, dt_y: DType, col_x: Int, col_y: Int](Aggregator):
    """`Aggregator` conformer computing the Pearson correlation of two columns.

    Per-group state: `CoMomentRunningState` (bivariate Welford, 48-byte POD).
    Output DType: `DType.float64`. Reads column `col_x` (DType `dt_x`) and
    `col_y` (DType `dt_y`) in their NATIVE types off the BatchView, casting each
    to Float64 before the co-moment recurrence (so CORR over int columns is
    correct).

    NO `update_chunk` override — the default per-lane `@parameter for` fan-out
    preserves the Welford accumulation order (a masked-SIMD reduce would
    reassociate; CORR's combine is associative so the multi-worker fold is
    correct, but the single-worker order must stay the per-row Welford recurrence
    for stability + value-match)."""

    comptime StateTy = CoMomentRunningState
    comptime OUT_DT: DType = DType.float64

    @staticmethod
    @always_inline
    def make() -> Self:
        """`Aggregator.make` — field-less default-construct (VARIADIC-FACTORY).
        `@fieldwise_init` synthesizes the no-arg ctor for this field-less struct
        (the 4 type params are comptime), so `Self()` is the trivial default."""
        return Self()

    @staticmethod
    @always_inline
    def init() -> CoMomentRunningState:
        return CoMomentRunningState(
            Int64(0), Float64(0.0), Float64(0.0),
            Float64(0.0), Float64(0.0), Float64(0.0),
        )

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: CoMomentRunningState, batch: BatchView[bo], i: Int):
        var x = _read_col_f64[Self.dt_x, Self.col_x, bo](batch, i)
        var y = _read_col_f64[Self.dt_y, Self.col_y, bo](batch, i)
        # Online bivariate Welford co-moment update. dx/dy use the OLD means;
        # the moment terms use the NEW means (m2/c2 += old_delta * new_delta).
        state.n = state.n + 1
        var nf = state.n.cast[DType.float64]()
        var dx = x - state.mean_x
        var dy = y - state.mean_y
        state.mean_x = state.mean_x + dx / nf
        state.mean_y = state.mean_y + dy / nf
        state.m2_x = state.m2_x + dx * (x - state.mean_x)
        state.m2_y = state.m2_y + dy * (y - state.mean_y)
        state.c2 = state.c2 + dx * (y - state.mean_y)

    @always_inline
    def combine(
        mut self, mut into: CoMomentRunningState, var partial: CoMomentRunningState
    ):
        # Chan et al. parallel-merge for both variances AND the co-moment.
        # Identity-respecting (a zero-count donor / accum is a no-op). The
        # m2/c2 updates use the OLD means; scaled by na*nb/n.
        if partial.n == 0:
            return
        if into.n == 0:
            into = partial
            return
        var na = into.n.cast[DType.float64]()
        var nb = partial.n.cast[DType.float64]()
        var n = na + nb
        var f = na * nb / n
        var dx = partial.mean_x - into.mean_x
        var dy = partial.mean_y - into.mean_y
        into.m2_x = into.m2_x + partial.m2_x + dx * dx * f
        into.m2_y = into.m2_y + partial.m2_y + dy * dy * f
        into.c2 = into.c2 + partial.c2 + dx * dy * f
        into.mean_x = (na * into.mean_x + nb * partial.mean_x) / n
        into.mean_y = (na * into.mean_y + nb * partial.mean_y) / n
        into.n = into.n + partial.n

    @staticmethod
    @always_inline
    def finalize(state: CoMomentRunningState) -> Scalar[DType.float64]:
        # Pearson r = C2 / sqrt(M2_x * M2_y). NaN for n < 2 (no covariance) OR
        # when either variance is 0 (a constant column => zero-variance => the
        # denominator is 0 => DuckDB NaN). The 0/0 NaN is the documented "DuckDB
        # NULL/NaN convention".
        if state.n < 2:
            return Float64(0.0) / Float64(0.0)  # NaN
        var den = sqrt(state.m2_x * state.m2_y)
        if den == 0.0:
            return Float64(0.0) / Float64(0.0)  # NaN (constant column)
        return state.c2 / den
