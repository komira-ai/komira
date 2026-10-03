# =============================================================================
# hash_agg_op_dt.mojo — DType-templated constructible agg-op family
# =============================================================================
#
# THE CONSTRUCTION WALL THIS CLOSES
# ---------------------------------
# The typed engine path (`materialize[S, ID, *M]`) needs an `Aggregator`
# conformer it can VALUE-CONSTRUCT generically from a typed marker — for ANY
# op + ANY DType. The two pre-existing families both fail this generically:
#   * `AggFnAgg[F, col]` — `init()` is `constrained[False]` (UNIMPLEMENTABLE;
#     `@staticmethod init` has no `_udf` access). HARD COMPILE FAIL on
#     value-construction. (The marker `BOUND[S]` is documented dead-at-
#     construction for exactly this reason.)
#   * `HashAggOpF64Agg[Op, col]` / `...I64Agg` / `...I32Agg` / `...F32Agg`
#     (`hash_agg_op_aggregator.mojo`) — CONSTRUCTIBLE, but FOUR sibling structs
#     parametric on four DType-SPECIFIC op traits (`HashAggOpF64`/`I64`/`I32`/
#     `F32`). The typed factory could only stamp ONE (the F64 single-SUM path).
#
# THIS FILE: ONE DType-PARAMETRIC op trait (`HashAggOpDt`, carrying its own
# `comptime DT: DType`) + DType-parametric op conformers (`SumOp[dt]`,
# `CountOp[dt]`, `MinOp[dt]`, `MaxOp[dt]`, `AvgOp[dt]`) with a GENERIC IDENTITY
# constructor (`init()` — SUM/COUNT->0, MIN->+sentinel, MAX->-sentinel,
# AVG->(0,0)), + ONE DType-templated `Aggregator` adapter `HashAggOpAgg[Op,
# col]` that reads the bound column off the `BatchView` via a comptime
# `Op.DT ==` ladder (the proven `AggFnAgg` pattern — folds to a direct typed
# load, no runtime dispatch).
#
# `HashAggOpAgg` is the CONSTRUCTIBLE generic family the typed factory stamps:
# field-less, real default `__init__`, working static `init()`. It conforms to
# the unified `Aggregator` trait so it drops into `AggSlot[A: Aggregator]`
# (`stage_primitives/hash_agg.mojo`) unchanged.
#
# WHY THE 4 OLD ADAPTERS REMAIN (not a parallel API)
# ----------------------------------------------------------------
# `HashAggOpF64Agg` + the 3 DType siblings are consumed widely (runtime
# substrate, untyped path). Those are DType siblings, which
# are allowed (only ARITY siblings are banned).
# `HashAggOpAgg` is not a parallel API to them: it is the SINGLE generic family
# the TYPED-construction path requires (the old siblings cannot be value-
# constructed generically from `*M` without enumerating four call sites). The
# old siblings are kept as separate structs; collapsing them onto this
# template would touch every one of their call sites.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any signature.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads the per-batch
#     lifetime witness.
#   - POD-only field-less conformers + adapter (slab-safe: `StateTy` is a POD
#     scalar / SIMD pair, no heap-owning inner field).
#
# Cross-references:
#   - aggregator.mojo — the unified `Aggregator` trait (target).
#   - hash_agg_op_aggregator.mojo — the 4 DType-sibling adapters.
#   - agg_op_traits.mojo — the 4 DType-specific op traits.
# =============================================================================

from std.builtin.swap import swap
from std.collections import List

from komira_core.collections.batch_view import BatchView
from komira_core.collections.band_view import BandView
from komira_core.collections.morsel_view import MorselView

from komira_agg.aggregator import Aggregator
from komira_udf.float_quotient_order import (
    float_max_fold_f64,
    float_max_identity_f64,
    float_min_fold_f64,
    float_min_identity_f64,
)


# =============================================================================
# §0 — native output-DType helper (matches the untyped path's result family)
# =============================================================================
#
# The untyped
# col-untyped agg path (`_untyped_agg_output_arrow`) emits SUM/MIN/MAX over ANY
# integer-family input (i8/i16/i32/i64/u8..u64) as INT64, and over any
# float-family input (f32/f64) as FLOAT64. To be byte-identical the typed
# `HashAggOpAgg` drain must emit the same RESULT family, so SUM/MIN/MAX publish
# `OUT_DT = _sum_minmax_out_dt[dt]()` (int-family -> int64, float-family ->
# float64) rather than the native input width.
# =============================================================================


@always_inline
def _sum_minmax_out_dt[dt: DType]() -> DType:
    """Native output DType for SUM / MIN / MAX over input DType `dt` — the
    RESULT-family map the untyped path uses. Integer-family inputs
    (i8/i16/i32/i64/u8..u64) -> int64; float-family inputs (f32/f64) ->
    float64. Folds at comptime (the ops are monomorphized per `dt`)."""
    comptime if (
        dt == DType.float64
        or dt == DType.float32
    ):
        return DType.float64
    else:
        # Integer family — i8/i16/i32/i64/u8..u64 all widen to int64, matching
        # `_untyped_agg_output_arrow`'s INT64 result for integer-family inputs.
        return DType.int64


@always_inline
def _cd_dt_is_int_family[dt: DType]() -> Bool:
    """True iff `dt` is an integer family DType — the family the radix-parallel
    COUNT_DISTINCT dedup admits (values widen to Int64 EXACTLY; a value-hash
    partition is a faithful equality partition). Float DTypes are excluded
    (bitwise `-0.0 != 0.0` / NaN would diverge from the sort-dedup semantics)."""
    return (
        dt == DType.int64
        or dt == DType.int32
        or dt == DType.int16
        or dt == DType.int8
        or dt == DType.uint64
        or dt == DType.uint32
        or dt == DType.uint16
        or dt == DType.uint8
    )


@always_inline
def _sum_minmax_state_dt[dt: DType]() -> DType:
    """Per-bucket RUNNING-STATE DType for MIN / MAX (and FIRST / LAST) over
    input DType `dt` — the TYPE-COMPLETENESS map. ⚠ SUM and
    AVG use `_exact_sum_state_dt` (INT128) instead: an INT64
    running SUM wraps past 2^63. Integer-family inputs
    (i8/i16/i32/i64/u8..u64) accumulate in INT64 (EXACT to 2^63, no Float64
    rounding past 2^53); float-family inputs (f32/f64) accumulate in FLOAT64.

    This is the load-bearing change vs the prior `StateTy = Float64`-for-all:
    an integer SUM/MIN/MAX no longer round-trips through Float64, so large-
    magnitude integer results (e.g. `SUM(bigint) > 2^53`) are EXACT — matching
    the EXACT ROW path (`RowSumAggI64`) and DuckDB (exact to 2^63), instead of
    being silently wrong by plan orientation.

    The state DType matches `_sum_minmax_out_dt[dt]()` exactly: int-family ->
    int64 (== OUT_DT), float-family -> float64 (== OUT_DT). So `finalize` is an
    in-type identity (no cross-family cast). Folds at comptime."""
    comptime if (
        dt == DType.float64
        or dt == DType.float32
    ):
        return DType.float64
    else:
        return DType.int64


@always_inline
def _exact_sum_state_dt[dt: DType]() -> DType:
    """Per-bucket RUNNING-STATE DType for SUM and AVG over input DType `dt`
. Float-family inputs -> FLOAT64, as
    before. Integer-family inputs -> INT128, EXACT BY CONSTRUCTION: a sum of
    fewer than 2^63 values each inside [-2^64, 2^64) cannot leave
    [-2^127, 2^127), so no partial and no MERGE of partials can overflow, and
    the total is independent of the order workers' partials combine in.

    ⛔ WHY NOT INT64 (`_sum_minmax_state_dt`, what SUM used until this date):
    `SumOp[int64]` added into an INT64 cell with a bare `+` and WRAPPED --
    `sum([MAX, 1])` answered MIN at this door, grouped and 0-key alike, where
    DuckDB 1.5.3 answers 9223372036854775808. A per-step overflow CHECK would
    be the wrong fix: `[MAX, 1, -7]` has a PARTIAL outside INT64 and a TOTAL
    (MAX - 6) inside it, and DuckDB answers it. Only the exact total can tell
    the two apart; it is narrowed ONCE, at emission (`SumOp.total_fits_i64`).

    ⛔ WHY AVG TOO: summing integers in FLOAT64 would make `avg([2^53, 1,
    -2^53])` answer 0.0 (2^53 + 1 rounds back to 2^53) where DuckDB answers
    0.3333333333333333 -- the same class as the 0-key STREAMING sink
    (`int_sum_overflow.ExactIntAgg`), on the typed door's own
    kernel. Folds at comptime."""
    comptime if (
        dt == DType.float64
        or dt == DType.float32
    ):
        return DType.float64
    else:
        return DType.int128


# =============================================================================
# §1 — HashAggOpDt — the DType-PARAMETRIC per-bucket aggregate op trait
# =============================================================================
#
# Generalizes the 4 DType-specific op traits (`HashAggOpF64`/`I64`/`I32`/`F32`)
# into ONE trait carrying `comptime DT: DType`. `update_scalar` takes a
# `Scalar[Self.DT]` (the bound column's native scalar). The identity element is
# the conformer's `init()`. All-static, field-less marker conformers.
# =============================================================================


trait HashAggOpDt(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """DType-parametric per-bucket aggregate op. Carries its own input DType
    `DT` (comptime) so ONE `Aggregator` adapter (`HashAggOpAgg[Op, col]`) can
    DType-template across the whole family.

    Members:
      - `comptime DT: DType` — the input column's native DType (the BatchView
        accessor the adapter calls is selected by this).
      - `comptime OUT_DT: DType` — the op's NATIVE output DType, matching the
        untyped path's column ArrowType:
        SUM/MIN/MAX over an integer-family `DT` -> `DT` widened to int64 / the
        native int; SUM/MIN/MAX over a float-family `DT` -> float64; COUNT ->
        int64 (always); AVG -> float64 (a mean). The drain emits the agg column
        in THIS DType, not uniform Float64, so the typed output is
        byte-identical to the untyped output (which emits the op's native type).
      - `StateTy` — the per-bucket running-state type. TYPE-COMPLETE per the
        input DType: MIN/MAX over an integer-family input
        keep `Scalar[int64]` (an exact compare/store), over a float-family
        input `Scalar[float64]`; COUNT is always `Scalar[int64]`. SUM and AVG
        over an integer-family input accumulate an EXACT 128-bit total
        (`Scalar[int128]` / `SIMD[int128, 2]`:
        an INT64 total would WRAP past 2^63 and a FLOAT64 one
        round past 2^53); over a float-family input `Scalar[float64]` /
        `SIMD[float64, 2]`. The integer MIN/MAX state DType equals `OUT_DT`, so
        their `finalize` is an in-type identity; integer SUM's NARROWS
        INT128 -> INT64 and is guarded by `EXACT_INT_SUM` / `total_fits_i64`.
      - `init()` — the GENERIC IDENTITY element (SUM/COUNT->0, MIN->+sentinel,
        MAX->-sentinel, AVG->(0,0)). This is what makes the family CONSTRUCTIBLE
        (vs `AggFnAgg.init()` = `constrained[False]`).
      - `finalize(state) -> Scalar[Self.OUT_DT]` — produce the group output in
        the op's native output DType. For integer MIN/MAX the state IS the
        `OUT_DT` (int64), so finalize is an in-type return — EXACT, never via
        Float64; integer SUM narrows its exact INT128 total, which the engine's
        drain has already checked fits (`total_fits_i64`). For float SUM/MIN/MAX
        the Float64 state IS the OUT_DT. AVG divides sum/count and returns
        Float64.
    """

    comptime DT: DType
    comptime OUT_DT: DType
    comptime StateTy: Copyable & Movable & Deinitable

    comptime NEEDS_VALUE: Bool = True
    """Band fold: does this op READ its bound input column's value per row? Default True (SUM / AVG /
    MIN / MAX / STDDEV / FIRST / LAST / COUNT_DISTINCT / MEDIAN all fold the read
    value). COUNT overrides it to False (it only increments) — so the band fold
    (`HashAggOpAgg.update_band`) can SKIP the value read for COUNT, whose bound
    `col` is a structural placeholder (index 0 — a group-key column) that has no
    valid fixed-width span in the band. The batch path reads + discards that
    placeholder harmlessly; the band path (tightly-sized reused scratch) must not
    reinterpret a dict-code / string key column as an i64 value, so it skips."""

    @staticmethod
    def init() -> Self.StateTy:
        ...

    @staticmethod
    def update_scalar(mut state: Self.StateTy, value: Scalar[Self.DT]):
        ...

    @staticmethod
    def finalize(state: Self.StateTy) -> Scalar[Self.OUT_DT]:
        ...

    @staticmethod
    def combine(mut state: Self.StateTy, partial: Self.StateTy):
        ...

    # -- The EXACT INTEGER SUM hooks,
    # forwarded by `HashAggOpAgg` to `Aggregator.EXACT_INT_SUM` /
    # `total_fits_i64` (see that trait for the contract).
    comptime EXACT_INT_SUM: Bool = False
    """True ONLY for an integer-family `SumOp`, whose INT128 state is narrowed to
    its INT64 `OUT_DT` by `finalize`."""

    @staticmethod
    def total_fits_i64(state: Self.StateTy) -> Bool:
        """DEFAULT True (never consulted unless `EXACT_INT_SUM`)."""
        _ = state
        return True

    # -- radix-parallel COUNT_DISTINCT hooks.
    comptime IS_DISTINCT_BUFFER: Bool = False
    """True iff this op's per-group state is an INTEGER value BUFFER whose
    finalize is a DEDUP-COUNT that is order-independent AND radix-per-value-
    partition parallelizable. Default False. Set True ONLY by the integer-input
    `CountDistinctOp` — MEDIAN's buffer is NOT set (its finalize is a global-order
    percentile select, which a per-value-partition union would corrupt)."""

    @staticmethod
    def distinct_values_i64(state: Self.StateTy) -> List[Int64]:
        """The group's fed values widened to Int64, for the engine-layer radix-
        parallel COUNT_DISTINCT dedup (consulted ONLY when IS_DISTINCT_BUFFER).
        DEFAULT returns an EMPTY list (never called for a non-distinct op)."""
        _ = state
        return List[Int64]()

    # -- move-combine (no concat) hooks.
    @staticmethod
    def take_distinct_buffer_into(mut dst: Self.StateTy, mut src: Self.StateTy):
        """MOVE `src`'s per-group distinct value buffer(s) into `dst`'s per-group
        run accumulator — the concat-FREE cross-worker merge (consulted ONLY when
        IS_DISTINCT_BUFFER). O(1) per buffer (a `List` move / swap), NOT O(values)
        like the serial `combine` concat. DEFAULT = no-op (never called for a
        non-distinct op — the `AggSlot.combine_at_move` branch is comptime-severed
        for every non-CD agg). The integer `CountDistinctOp` overrides it."""
        _ = dst
        _ = src

    @staticmethod
    def distinct_runs_i64(state: Self.StateTy) -> List[List[Int64]]:
        """The group's distinct value buffer(s) widened to Int64 as a LIST of runs
        (the per-row buffer plus every move-combined worker buffer), for the
        engine-layer radix-parallel multi-buffer dedup (consulted ONLY when
        IS_DISTINCT_BUFFER). DEFAULT returns an EMPTY list (never called for a
        non-distinct op). The integer `CountDistinctOp` overrides it."""
        _ = state
        return List[List[Int64]]()

    # -- parallel per-group finalize.
    comptime SORT_FINALIZE: Bool = False
    """True iff this op's per-group `finalize` is an EXPENSIVE independent per-group
    computation (a full sort + interpolated percentile select — MEDIAN) that the
    engine layer parallelizes by partitioning GROUPS across workers at drain time.
    Default False (cheap-finalize ops keep the serial per-group emit). Set True ONLY
    by `MedianOp`. The engine-layer `run_with_state` fan-out lives in
    `AggSlot.emit_column_parallel`; the eval layer stays dispatcher-free — the exact
    `finalize` (variable-size buffer sort + interpolation) is untouched, only its
    per-group INVOCATION is parallelized (byte-identical, groups are independent)."""


# =============================================================================
# §2 — DType-parametric op conformers (Sum / Count / Min / Max / Avg)
# =============================================================================
#
# Each is parametric on `dt: DType`. State is TYPE-COMPLETE per the input DType
#: MIN/MAX over an integer-family input accumulate in
# `Scalar[int64]` (EXACT — NO Float64 rounding past 2^53), over a float-family
# input in `Scalar[float64]`, and their `finalize` is an in-type return. SUM and
# AVG over an integer-family input accumulate an EXACT INT128 total
#; SUM's `finalize`
# narrows it to INT64 after the drain's `total_fits_i64` check. MIN/MAX
# identities: integer family `Scalar[int64].MAX` / `.MIN`; float family the
# quotient order's TOP (canonical NaN) / BOTTOM (-inf), folded with
# `float_min_fold_f64` / `float_max_fold_f64`. Finite
# identities such as `+1e300` / `-1e300` under bare `<` / `>` would
# DRAIN as answers (MIN over [1e308] = 1e300).
# =============================================================================


struct SumOp[dt: DType](HashAggOpDt):
    """SUM over `dt`. Identity = 0. Integer-family input -> an EXACT `Scalar
    [int128]` running total (`_exact_sum_state_dt`), narrowed to the INT64
    `OUT_DT` once, at emission; float-family input -> `Scalar[float64]`.

    ⛔ `finalize` over an integer total outside INT64 TRUNCATES -- it cannot
    raise (trait surface). `EXACT_INT_SUM` makes every `HashAggTable` drain ask
    `total_fits_i64` first and REFUSE by name (`int_sum_overflow_message`), so a
    `sum()` drained through a `HashAggTable` answers exactly or refuses."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = _sum_minmax_out_dt[Self.dt]()
    comptime SDT: DType = _exact_sum_state_dt[Self.dt]()
    comptime StateTy = Scalar[Self.SDT]
    comptime EXACT_INT_SUM: Bool = Self.SDT == DType.int128

    @staticmethod
    @always_inline
    def init() -> Scalar[Self.SDT]:
        return Scalar[Self.SDT](0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Scalar[Self.SDT], value: Scalar[Self.dt]):
        # Integer input -> an exact 128-bit add; float input -> an f64 add.
        state = state + value.cast[Self.SDT]()

    @staticmethod
    @always_inline
    def total_fits_i64(state: Scalar[Self.SDT]) -> Bool:
        comptime if Self.SDT == DType.int128:
            return state >= Int64.MIN.cast[Self.SDT]() and state <= Int64.MAX.cast[
                Self.SDT
            ]()
        else:
            return True

    @staticmethod
    @always_inline
    def finalize(state: Scalar[Self.SDT]) -> Scalar[Self.OUT_DT]:
        # Float family: an in-type identity. Integer family: the INT128 -> INT64
        # narrowing -- exact whenever `total_fits_i64`, which the drain checks
        # before it calls this (see the struct docstring).
        return state.cast[Self.OUT_DT]()

    @staticmethod
    @always_inline
    def combine(mut state: Scalar[Self.SDT], partial: Scalar[Self.SDT]):
        state = state + partial


struct CountOp[dt: DType](HashAggOpDt):
    """COUNT over `dt` (counts every row fed — no-null model, mirrors
    `CountF64` semantics). Identity = 0. State = `Scalar[int64]` (an
    exact integer counter, not Float64). Output is
    ALWAYS int64 (COUNT is integer-valued — matches the untyped path's INT64
    COUNT column)."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = DType.int64
    comptime NEEDS_VALUE: Bool = False
    comptime StateTy = Scalar[DType.int64]

    @staticmethod
    @always_inline
    def init() -> Scalar[DType.int64]:
        return Scalar[DType.int64](0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Scalar[DType.int64], value: Scalar[Self.dt]):
        state = state + 1

    @staticmethod
    @always_inline
    def finalize(state: Scalar[DType.int64]) -> Scalar[Self.OUT_DT]:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Scalar[DType.int64], partial: Scalar[DType.int64]):
        state = state + partial


struct MinOp[dt: DType](HashAggOpDt):
    """MIN over `dt`. Identity: integer family `Scalar[int64].MAX`; float family
    the quotient order's TOP, the canonical NaN (`float_min_identity_f64`), and
    each step is `float_min_fold_f64`.
    ⛔ It was `+1e300` with a bare `<`: MIN over [1e308] answered 1e300 and an
    all-NaN group 1e300 (inf at FLOAT) -- a value not in the column. State is TYPE-COMPLETE
    (SW-A): integer-family input -> `Scalar[int64]` (EXACT compare/store — no
    Float64 rounding past 2^53 picking the wrong extreme near 2^62);
    float-family input -> `Scalar[float64]`. The state DType == `OUT_DT`."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = _sum_minmax_out_dt[Self.dt]()
    comptime SDT: DType = _sum_minmax_state_dt[Self.dt]()
    comptime StateTy = Scalar[Self.SDT]

    @staticmethod
    @always_inline
    def init() -> Scalar[Self.SDT]:
        # MIN identity = the TOP of the order. Integer family:
        # `Scalar[int64].MAX` (exact, == 2^63-1). Float family: the canonical
        # NaN -- the identity AND the all-NaN group's answer.
        comptime if Self.SDT == DType.float64:
            return rebind[Scalar[Self.SDT]](float_min_identity_f64())
        else:
            return Scalar[Self.SDT].MAX

    @staticmethod
    @always_inline
    def update_scalar(mut state: Scalar[Self.SDT], value: Scalar[Self.dt]):
        var v = value.cast[Self.SDT]()
        comptime if Self.SDT == DType.float64:
            state = rebind[Scalar[Self.SDT]](
                float_min_fold_f64(rebind[Float64](state), rebind[Float64](v))
            )
        else:
            if v < state:
                state = v

    @staticmethod
    @always_inline
    def finalize(state: Scalar[Self.SDT]) -> Scalar[Self.OUT_DT]:
        return state.cast[Self.OUT_DT]()

    @staticmethod
    @always_inline
    def combine(mut state: Scalar[Self.SDT], partial: Scalar[Self.SDT]):
        comptime if Self.SDT == DType.float64:
            state = rebind[Scalar[Self.SDT]](
                float_min_fold_f64(
                    rebind[Float64](state), rebind[Float64](partial)
                )
            )
        else:
            if partial < state:
                state = partial


struct MaxOp[dt: DType](HashAggOpDt):
    """MAX over `dt`. Identity: integer family `Scalar[int64].MIN`; float family
    `-inf`, the quotient order's BOTTOM (`float_max_identity_f64`), each step
    `float_max_fold_f64` -- NaN is the MAX once one arrives (DuckDB 1.5.3).
    ⛔ It was `-1e300` with a bare `>`: MAX over [-inf] answered -1e300 and
    MAX over [NaN, 1] 1.0. State is TYPE-COMPLETE
    (SW-A): integer-family input -> `Scalar[int64]` (EXACT compare/store — no
    Float64 rounding past 2^53 picking the wrong extreme near 2^62);
    float-family input -> `Scalar[float64]`. The state DType == `OUT_DT`."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = _sum_minmax_out_dt[Self.dt]()
    comptime SDT: DType = _sum_minmax_state_dt[Self.dt]()
    comptime StateTy = Scalar[Self.SDT]

    @staticmethod
    @always_inline
    def init() -> Scalar[Self.SDT]:
        # MAX identity = the BOTTOM of the order. Integer family:
        # `Scalar[int64].MIN` (exact, == -2^63). Float family: `-inf`.
        comptime if Self.SDT == DType.float64:
            return rebind[Scalar[Self.SDT]](float_max_identity_f64())
        else:
            return Scalar[Self.SDT].MIN

    @staticmethod
    @always_inline
    def update_scalar(mut state: Scalar[Self.SDT], value: Scalar[Self.dt]):
        var v = value.cast[Self.SDT]()
        comptime if Self.SDT == DType.float64:
            state = rebind[Scalar[Self.SDT]](
                float_max_fold_f64(rebind[Float64](state), rebind[Float64](v))
            )
        else:
            if v > state:
                state = v

    @staticmethod
    @always_inline
    def finalize(state: Scalar[Self.SDT]) -> Scalar[Self.OUT_DT]:
        return state.cast[Self.OUT_DT]()

    @staticmethod
    @always_inline
    def combine(mut state: Scalar[Self.SDT], partial: Scalar[Self.SDT]):
        comptime if Self.SDT == DType.float64:
            state = rebind[Scalar[Self.SDT]](
                float_max_fold_f64(
                    rebind[Float64](state), rebind[Float64](partial)
                )
            )
        else:
            if partial > state:
                state = partial


struct AvgOp[dt: DType](HashAggOpDt):
    """AVG over `dt`. Identity = (sum=0, count=0). State = `SIMD[SDT, 2]`
    (lane 0 = sum, lane 1 = count) with `SDT = _exact_sum_state_dt[dt]`:
    FLOAT64 for a float-family input, an EXACT INT128 pair for an integer one.
    `finalize` emits sum/count as Float64 (a mean -- always float, matching the
    untyped AVG output). The integer total is NOT narrowed to INT64, so an
    AVG never refuses where its SUM would; it is rounded TWICE -- the INT128
    total to FLOAT64 (`Scalar[int128].cast[float64]()`), then the divide.
    That equals DuckDB 1.5.3 where `long double` is `double` (darwin arm64,
    measured: avg([2^53+1, 0, 0]) = 3002399751580330.5 at both); DuckDB on
    x86-64 divides in 80-bit and can differ in the last ulp past 2^53
    (inferred from its source, not executed)."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = DType.float64
    comptime SDT: DType = _exact_sum_state_dt[Self.dt]()
    comptime StateTy = SIMD[Self.SDT, 2]

    @staticmethod
    @always_inline
    def init() -> SIMD[Self.SDT, 2]:
        return SIMD[Self.SDT, 2](0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: SIMD[Self.SDT, 2], value: Scalar[Self.dt]):
        state[0] = state[0] + value.cast[Self.SDT]()
        state[1] = state[1] + 1

    @staticmethod
    @always_inline
    def finalize(state: SIMD[Self.SDT, 2]) -> Scalar[Self.OUT_DT]:
        if state[1] == 0:
            return Float64(0.0)
        return state[0].cast[DType.float64]() / state[1].cast[DType.float64]()

    @staticmethod
    @always_inline
    def combine(mut state: SIMD[Self.SDT, 2], partial: SIMD[Self.SDT, 2]):
        state = state + partial


# =============================================================================
# §2b — STDDEV_SAMP op conformer — running-moment (Welford/M2) accumulator
# =============================================================================
#
# Sample standard deviation, the genuinely-hard agg: a 2-MOMENT running
# accumulator (Welford `[count | mean | M2]`), NOT a single fold. `StateTy` is
# the local POD `WelfordRunningState` (24 bytes, all scalar — slab-safe, no
# heap). `update_scalar` is the Welford one-pass; `combine` is the Chan et al.
# parallel-merge (load-bearing for the multi-worker partial-agg path); finalize
# emits sqrt(M2/(count-1)) (NaN for count <= 1).
#
# This is the EXACT convention the SDK `stddev_samp()` expression computes today
# via the live untyped path (`StddevSampF64` in
# `komira_engine_operators.agg.agg_state_slab`) — sample stddev (ddof=1),
# NaN-as-NULL for count <= 1. The column-native typed output is therefore
# bit-for-bit identical to the untyped path. The separate
# `hash_agg_untyped.mojo` `AGG_STDDEV_POP_F64` kernel (population, m2/count) is
# NOT reachable from the SDK surface and is NOT the oracle.
#
# A SINGLE Welford conformer serves every numeric input DType (`dt` widens to
# Float64 in `update_scalar` via `value.cast[float64]()`) — NO per-DType sibling
# is needed (the state + arithmetic are DType-independent once widened).
# =============================================================================


@fieldwise_init
struct WelfordRunningState(
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Per-bucket running-moment state for the Welford/M2 stddev kernel.

    24 bytes, all primitive scalars (slab-safe — no `List` / `String` /
    `OwnedPointer` field). Identity = (count=0, mean=0.0, m2=0.0); merging any
    state with the identity yields the original (the `combine` zero-count
    early-out preserves this)."""

    var count: Int64
    var mean: Float64
    var m2: Float64


struct StddevSampOp[dt: DType](HashAggOpDt):
    """STDDEV_SAMP over `dt`. Identity = (count=0, mean=0, m2=0). State =
    `WelfordRunningState` (24 bytes). Output is ALWAYS Float64 (a stddev).

    update = Welford one-pass (count++; delta=x-mean; mean+=delta/count;
    m2+=delta*(x-mean_new)). combine = Chan parallel-merge (m2 BEFORE mean).
    finalize = sqrt(m2/(count-1)) for count > 1; NaN otherwise. Bit-for-bit the
    live untyped `StddevSampF64` oracle."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = DType.float64
    comptime StateTy = WelfordRunningState

    @staticmethod
    @always_inline
    def init() -> WelfordRunningState:
        return WelfordRunningState(Int64(0), Float64(0.0), Float64(0.0))

    @staticmethod
    @always_inline
    def update_scalar(mut state: WelfordRunningState, value: Scalar[Self.dt]):
        var x = value.cast[DType.float64]()
        state.count = state.count + 1
        var delta = x - state.mean
        state.mean = state.mean + delta / state.count.cast[DType.float64]()
        state.m2 = state.m2 + delta * (x - state.mean)

    @staticmethod
    @always_inline
    def finalize(state: WelfordRunningState) -> Scalar[Self.OUT_DT]:
        from std.math import sqrt

        if state.count <= 1:
            return Float64(0.0) / Float64(0.0)  # NaN (DuckDB NULL convention)
        return sqrt(state.m2 / (state.count - 1).cast[DType.float64]())

    @staticmethod
    @always_inline
    def combine(mut state: WelfordRunningState, partial: WelfordRunningState):
        # Chan et al. parallel-merge. Identity-respecting (zero-count donor /
        # accum is a no-op). m2 BEFORE mean — the formula uses OLD means.
        if partial.count == 0:
            return
        if state.count == 0:
            state = partial
            return
        var na = state.count.cast[DType.float64]()
        var nb = partial.count.cast[DType.float64]()
        var n = na + nb
        var delta = partial.mean - state.mean
        state.m2 = state.m2 + partial.m2 + delta * delta * na * nb / n
        state.mean = (na * state.mean + nb * partial.mean) / n
        state.count = state.count + partial.count


# =============================================================================
# §2c — VAR_SAMP op conformer — the M2-finalize-WITHOUT-sqrt sibling of STDDEV
# =============================================================================
#
# Sample variance (ddof=1). Reuses STDDEV's `WelfordRunningState` (the
# `[count | mean | M2]` POD) + the SAME Welford update + Chan parallel-merge
# combine; ONLY `finalize` differs — `M2 / (count - 1)` for count > 1, NaN
# otherwise (no sqrt). `var_samp = stddev_samp ** 2`. Output is ALWAYS Float64.
# A SINGLE conformer serves every numeric input DType (`dt` widens to Float64 in
# `update_scalar`) — sibling-by-DTYPE is unnecessary (state + arithmetic are
# DType-independent once widened).
# =============================================================================


struct VarSampOp[dt: DType](HashAggOpDt):
    """VAR_SAMP over `dt`. Identity = (count=0, mean=0, m2=0). State =
    `WelfordRunningState` (24 bytes). Output is ALWAYS Float64 (a variance).

    update = Welford one-pass; combine = Chan parallel-merge (m2 BEFORE mean);
    finalize = M2/(count-1) for count > 1; NaN otherwise — the un-sqrt'd sibling
    of `StddevSampOp.finalize`."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = DType.float64
    comptime StateTy = WelfordRunningState

    @staticmethod
    @always_inline
    def init() -> WelfordRunningState:
        return WelfordRunningState(Int64(0), Float64(0.0), Float64(0.0))

    @staticmethod
    @always_inline
    def update_scalar(mut state: WelfordRunningState, value: Scalar[Self.dt]):
        var x = value.cast[DType.float64]()
        state.count = state.count + 1
        var delta = x - state.mean
        state.mean = state.mean + delta / state.count.cast[DType.float64]()
        state.m2 = state.m2 + delta * (x - state.mean)

    @staticmethod
    @always_inline
    def finalize(state: WelfordRunningState) -> Scalar[Self.OUT_DT]:
        if state.count <= 1:
            return Float64(0.0) / Float64(0.0)  # NaN (DuckDB NULL convention)
        return state.m2 / (state.count - 1).cast[DType.float64]()

    @staticmethod
    @always_inline
    def combine(mut state: WelfordRunningState, partial: WelfordRunningState):
        # Chan et al. parallel-merge. Identity-respecting (zero-count donor /
        # accum is a no-op). m2 BEFORE mean — the formula uses OLD means.
        if partial.count == 0:
            return
        if state.count == 0:
            state = partial
            return
        var na = state.count.cast[DType.float64]()
        var nb = partial.count.cast[DType.float64]()
        var n = na + nb
        var delta = partial.mean - state.mean
        state.m2 = state.m2 + partial.m2 + delta * delta * na * nb / n
        state.mean = (na * state.mean + nb * partial.mean) / n
        state.count = state.count + partial.count


# =============================================================================
# §2d — FIRST / LAST op conformers — order-dependent value-pick (seen-flag state)
# =============================================================================
#
# FIRST(col) /
# LAST(col) over a NUMERIC input DType. State is a 2-field POD
# `FirstLastRunningState[SDT]` (value + seen flag) — the `MinMaxState` shape, but
# DType-parametric in ONE struct (the `WelfordRunningState` single-struct
# convention, generalized to the state-DType). Identity = (value=0, seen=False).
#
# SEMANTICS (mirrors `builtin_agg_fns_firstlast.mojo` — DuckDB
# `first.cpp` / `last.cpp`):
#   FIRST: write the value only on the FIRST update; subsequent updates are
#          no-ops (the state sticks once seen). merge: keep `a` if a.seen, else
#          take `b`.
#   LAST:  every update OVERWRITES the value. merge: take `b` if b.seen, else
#          keep `a`.
#
# These are INHERENTLY ORDER-DEPENDENT (non-ordered aggregation): the result
# depends on row arrival order (DuckDB warns the same). The `combine` cross-
# worker merge preserves the per-partition fold but the cross-partition order is
# the partition-visit order (single-worker / single-partition is unambiguous).
#
# OUTPUT DType: FIRST/LAST pick an existing value, so the natural output is the
# input's native value. We follow the MIN/MAX native-drain convention
# (`_sum_minmax_out_dt`/`_sum_minmax_state_dt`: integer-family input -> int64
# state+out, float-family input -> float64 state+out) so the value rides through
# the same `BatchView` typed-accessor ladder + `Scalar[OUT_DT]` drain the rest of
# the `HashAggOpAgg` family uses; finalize is an in-type identity (SDT == OUT_DT).
#
# NO untyped-column oracle: the untyped column lowering RAISES on AGG_FIRST /
# AGG_LAST; there is no `ACC_FIRST`/`ACC_LAST`
# accumulator. So the typed `HashAggOpAgg[FirstOp/LastOp, col]` fast path is the
# SOLE executing FIRST/LAST column path; it does NOT route through the untyped
# fallback (which would raise).
# =============================================================================


@fieldwise_init
struct FirstLastRunningState[dt: DType](
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Per-bucket running-state for the FIRST / LAST value-pick kernels —
    DType-parametric in ONE struct (the `WelfordRunningState` single-struct
    convention, generalized to the state-DType `dt`).

    Two primitive fields, all POD (slab-safe — no `List` / `String` /
    `OwnedPointer` field). `seen` distinguishes the identity (no value yet) from
    a written value; identity = (value=0, seen=False). Merging any state with the
    identity yields the original (the FIRST/LAST `combine` seen-flag check
    preserves this)."""

    var value: Scalar[Self.dt]
    var seen: Bool


struct FirstOp[dt: DType](HashAggOpDt):
    """FIRST over `dt`. Identity = (value=0, seen=False). State =
    `FirstLastRunningState[SDT]`. Output native (integer-family -> int64,
    float-family -> float64; SDT == OUT_DT so finalize is an in-type identity).

    update = write-only-on-first-seen (the state sticks after the first value);
    combine = keep `a` if a.seen else take `b` (DuckDB `FirstFunctionBase`).
    The result is the first value in arrival order."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = _sum_minmax_out_dt[Self.dt]()
    comptime SDT: DType = _sum_minmax_state_dt[Self.dt]()
    comptime StateTy = FirstLastRunningState[Self.SDT]

    @staticmethod
    @always_inline
    def init() -> FirstLastRunningState[Self.SDT]:
        return FirstLastRunningState[Self.SDT](Scalar[Self.SDT](0), False)

    @staticmethod
    @always_inline
    def update_scalar(
        mut state: FirstLastRunningState[Self.SDT], value: Scalar[Self.dt]
    ):
        # FIRST: write only on the first update; subsequent updates are no-ops.
        if not state.seen:
            state.value = value.cast[Self.SDT]()
            state.seen = True

    @staticmethod
    @always_inline
    def finalize(state: FirstLastRunningState[Self.SDT]) -> Scalar[Self.OUT_DT]:
        # SDT == OUT_DT — this cast is an in-type identity.
        return state.value.cast[Self.OUT_DT]()

    @staticmethod
    @always_inline
    def combine(
        mut state: FirstLastRunningState[Self.SDT],
        partial: FirstLastRunningState[Self.SDT],
    ):
        # Keep the accumulator's value if it has already seen one (it is the
        # earlier partition); otherwise adopt the partial. Identity-respecting
        # (an unseen accum adopts the partial; an unseen partial is a no-op).
        if not state.seen:
            state = partial


struct LastOp[dt: DType](HashAggOpDt):
    """LAST over `dt`. Identity = (value=0, seen=False). State =
    `FirstLastRunningState[SDT]`. Output native (integer-family -> int64,
    float-family -> float64; SDT == OUT_DT so finalize is an in-type identity).

    update = always-overwrite (every value replaces the state); combine = take
    `b` if b.seen else keep `a` (DuckDB `LastFunctionBase`). ORDER-DEPENDENT:
    the result is the last value in arrival order."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = _sum_minmax_out_dt[Self.dt]()
    comptime SDT: DType = _sum_minmax_state_dt[Self.dt]()
    comptime StateTy = FirstLastRunningState[Self.SDT]

    @staticmethod
    @always_inline
    def init() -> FirstLastRunningState[Self.SDT]:
        return FirstLastRunningState[Self.SDT](Scalar[Self.SDT](0), False)

    @staticmethod
    @always_inline
    def update_scalar(
        mut state: FirstLastRunningState[Self.SDT], value: Scalar[Self.dt]
    ):
        # LAST: every update overwrites — the running value is the most-recent.
        state.value = value.cast[Self.SDT]()
        state.seen = True

    @staticmethod
    @always_inline
    def finalize(state: FirstLastRunningState[Self.SDT]) -> Scalar[Self.OUT_DT]:
        # SDT == OUT_DT — this cast is an in-type identity.
        return state.value.cast[Self.OUT_DT]()

    @staticmethod
    @always_inline
    def combine(
        mut state: FirstLastRunningState[Self.SDT],
        partial: FirstLastRunningState[Self.SDT],
    ):
        # Adopt the partial's value if it has seen one (it is the later
        # partition); otherwise keep the accumulator. Identity-respecting.
        if partial.seen:
            state = partial


# =============================================================================
# §2e — COUNT_DISTINCT op conformer — variable-size per-group value buffer
# =============================================================================
#
# COUNT(DISTINCT). The
# FIRST genuinely-VARIABLE-SIZE per-group state in the catalog. State is a
# HEAP-OWNING `CountDistinctState[dt]` (a `List[Scalar[dt]]` value buffer), NOT
# a POD scalar/SIMD/fixed-moment.
#
# WHY THE TYPED-COLUMN CATALOG CAN HOST THIS (vs the ROW substrate, which
# CANNOT):
#   - The per-group state lives in `AggSlot[A].states: List[A.StateTy]`
#     (`stage_primitives/hash_agg.mojo`) — a GROWABLE Mojo-managed `List`, NOT a
#     raw byte-slab and NOT a fixed InlineArray. A heap-owning `StateTy` element
#     is stale-slab-SAFE there: `List` manages element move/copy/destroy through Mojo's
#     normal lifetime machinery; the stale-slab trap (byte-slab reinterpretation under
#     tcmalloc reuse) does not apply to a typed `List`.
#   - The `Aggregator`/`HashAggOpDt` `StateTy` bound is `Movable & Copyable &
#     Deinitable` — a `List`-fielded struct with a deep `__copyinit__`
#     satisfies it. `STATE_SIZE = size_of[StateTy]()` is defined but never
#     consumed to size a byte-slab (grep-confirmed), so the 8/24-byte List header
#     is not a problem.
#   - Cross-worker combine is `AggSlot.combine_*` -> `Op.combine(state,
#     donor.copy())` — so a UNION/CONCAT merge is expressible. COUNT_DISTINCT's
#     combine CONCATENATES the donor's value buffer into the accumulator's (the
#     dedup is deferred to finalize); concat is associative, so the multi-worker
#     fold is byte-identical to single-worker.
#
# ALGORITHM = SORT-DEDUP AT FINALIZE (mirrors the untyped-column oracle
# `agg_count_distinct.mojo` `_execute_count_distinct_agg`, which is the older
# `CountDistinctI64ColumnarAcc` strategy):
#   update  : append the row value to the buffer (O(1) amortized — cache-friendly
#             sequential push, NOT a per-row hash probe).
#   combine : append the donor's whole buffer (UNION via concat; dedup deferred).
#   finalize: `sort(buffer)` then count value-runs (a value differs from the
#             previous => +1 distinct). Empty buffer -> 0. Output is ALWAYS int64
#             (a count — matches DuckDB `COUNT(DISTINCT x)`'s int64 result and the
#             untyped path's INT64 CD column). DuckDB's COUNT(DISTINCT) of an
#             empty group is 0 (not NULL); we feed every row (no-null model), so
#             an empty buffer naturally yields 0.
#
# A SINGLE conformer serves every comparable input DType (`dt`): the buffer holds
# the value in its NATIVE `dt` (no widening — distinctness is exact per the input
# type), `sort` + `!=` are DType-generic. NO per-DType sibling needed.
# =============================================================================


struct CountDistinctState[dt: DType](
    Copyable, Movable, Deinitable
):
    """Per-bucket value buffer for the COUNT_DISTINCT kernel — a growable
    `List[Scalar[dt]]` holding every value fed to the group (dedup is deferred
    to `finalize` via sort-dedup, the cache-friendly strategy).

    HEAP-OWNING (`List` fields). Gap6-safe in the catalog because the owning
    container is `AggSlot[A].states: List[A.StateTy]` (a typed Mojo `List`, NOT a
    byte-slab) — see the COUNT_DISTINCT section header. `List`'s deep `__copyinit__` gives this
    struct a correct deep copy, which the `Aggregator.combine` donor-`.copy()`
    cross-worker merge relies on. Identity = an empty buffer (count 0).

    `values` is the per-row append buffer (the hot path). `runs` is the
    move accumulator: the concat-free
    cross-worker merge MOVES each worker's whole `values` buffer in here as a
    separate run (O(1), no per-value copy) instead of concatenating into `values`.
    The distinct count is over the UNION of `values` ++ flatten(`runs`); a value
    present in two runs is deduped ONCE at finalize (serial) / drain (radix).
    `runs` is EMPTY on a per-worker instance (only the merged/global instance
    accumulates runs) and EMPTY in the legacy serial-concat path (kill-switch)."""

    var values: List[Scalar[Self.dt]]
    var runs: List[List[Scalar[Self.dt]]]

    def __init__(out self):
        self.values = List[Scalar[Self.dt]]()
        self.runs = List[List[Scalar[Self.dt]]]()


struct CountDistinctOp[dt: DType](HashAggOpDt):
    """COUNT_DISTINCT over `dt`. Identity = empty buffer. State =
    `CountDistinctState[dt]` (variable-size value buffer). Output is ALWAYS
    int64 (a distinct count — DuckDB `COUNT(DISTINCT x)`).

    update = append the value (O(1) amortized); combine = concat the donor's
    buffer (UNION, dedup deferred — associative); finalize = sort + count
    value-runs. A SINGLE conformer serves every comparable input DType."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = DType.int64
    comptime StateTy = CountDistinctState[Self.dt]

    @staticmethod
    @always_inline
    def init() -> CountDistinctState[Self.dt]:
        return CountDistinctState[Self.dt]()

    @staticmethod
    @always_inline
    def update_scalar(
        mut state: CountDistinctState[Self.dt], value: Scalar[Self.dt]
    ):
        # Append the value in its NATIVE dt (distinctness is exact per the input
        # type — no widening). O(1) amortized push.
        state.values.append(value)

    @staticmethod
    @always_inline
    def _finalize_nan_one_value(
        buf: List[Scalar[Self.dt]], n: Int, nan_count: Int
    ) -> Scalar[Self.OUT_DT]:
        """The NaN-BEARING arm of `finalize` — DuckDB's rule that ALL NaNs in a
        group are ONE distinct value. Reached only from the float
        instantiations, and only for a group that actually contains a NaN (the
        prescan in `finalize` is what decides). Kept out of line so the shipping
        NaN-free path is the same straight-line code it has always been.

        `k = n - nan_count` non-NaN values are COMPACTED into a dense `[0, k)`
        buffer, which is what puts `sort` back inside its own contract: `<` IS a
        strict weak ordering once NaN is gone, so equal values are guaranteed
        adjacent and the adjacent-run count is exact again. The NaN group then
        contributes exactly ONE, unconditionally (`nan_count >= 1` here), which
        is the whole of DuckDB's NaN rule — including `-NaN`, which is the same
        distinct value as `NaN` and is likewise never compared with `!=`.

        (-0.0 and 0.0 compare EQUIVALENT under `<`, so they collapse into one
        run — DuckDB agrees, `count(distinct x)` over {0.0,-0.0} is 1. That
        behaviour is on the NaN-free path too and is unchanged by this arm.)

        Matches DuckDB v1.5.3:
          {NaN,1,1,2,NaN} n=5 k=3 -> 2 non-NaN runs + 1 = 3
          {NaN,1,1,2,2,3,3} n=7 k=6 -> 3 non-NaN runs + 1 = 4, EVERY rotation
          {NaN,NaN,NaN} n=3 k=0 -> 1        {1,2,NaN,NaN} n=4 k=2 -> 3
          {-inf,inf,NaN} n=3 k=2 -> 3   (NaN is its own value, not +inf's)
          {0.0,-0.0,NaN,-NaN} n=4 k=2 -> 2  {5,5,5,NaN,5,NaN,5} n=7 k=5 -> 2"""
        var k = n - nan_count
        if k == 0:
            # Every value in the group is a NaN -> exactly ONE distinct value.
            return Scalar[DType.int64](1)
        # Compact the non-NaN values into a dense [0, k) buffer — this is what
        # puts `sort` back inside its contract.
        var dense = List[Scalar[Self.dt]](capacity=k)
        for i in range(n):
            var v = buf[i]
            if v == v:  # IEEE: only NaN is unequal to itself
                dense.append(v)
        sort(dense)
        var distinct_count = Int64(1)
        for i in range(1, k):
            if dense[i] != dense[i - 1]:
                distinct_count = distinct_count + 1
        # + 1 for the NaN group, which is ONE distinct value however many NaNs
        # (or -NaNs) the group holds.
        return distinct_count + Int64(1)

    @staticmethod
    @always_inline
    def finalize(state: CountDistinctState[Self.dt]) -> Scalar[Self.OUT_DT]:
        """Sort-dedup count (CountDistinctI64ColumnarAcc strategy): sort the
        UNION of `values` ++ flatten(`runs`), then count value-runs. Empty -> 0
        (DuckDB COUNT(DISTINCT) of an empty group is 0, not NULL). `runs` is
        empty in the per-row / serial-concat paths (this reduces to the prior
        `values.copy()` sort exactly); it carries the move-combined per-worker
        buffers when the concat-free combine path built the state — a value in
        two runs is deduped once by the sort.

        ★ NaN BROKE THIS TWO WAYS, AND THEY ARE INDEPENDENT.

        (1) `buf[i] != buf[i - 1]` IS THE WRONG RUN TEST FOR NaN. IEEE says
        `NaN != NaN` is TRUE, so every NaN past the first element opened a NEW
        run: a group holding k NaNs counted as k distinct values where DuckDB
        counts ONE. This needed no help from the sort — it fired on a perfectly
        sorted buffer. Measured before the fix: {NaN,NaN,NaN} -> 3 (DuckDB 1);
        {NaN,1,1,2,NaN} -> 4 (DuckDB 3).

        (2) `sort` WITH `<` WAS OUTSIDE ITS OWN CONTRACT. Every comparison
        against NaN is false, so NaN is neither less than, greater than, nor
        equivalent to anything and `<` is not a strict weak ordering — the
        result is an arbitrary permutation decided by the INPUT order, which can
        leave EQUAL NON-NaN VALUES NON-ADJACENT, and an adjacent-run counter
        then counts one value twice. Because the input order here is row-arrival
        order per worker concatenated in worker-merge order by `combine`, the
        answer became a function of THREAD COUNT AND MORSEL PARTITIONING.
        Measured before the fix, the seven rotations of the ONE multiset
        {NaN,1,1,2,2,3,3} (DuckDB says 4 for all seven) returned
        `4 4 5 4 5 4 5` — and rot2 holds only a SINGLE NaN, so that over-count
        is purely the scattered duplicate, not defect (1).

        The fix is a NaN COUNT PRESCAN, deliberately shaped so the SHIPPING PATH
        IS UNTOUCHED: a group with no NaN runs the same `sort(buf)` +
        adjacent-run count as before, and an INTEGER instantiation does not even
        run the prescan (`comptime if` on `dt.is_floating_point()`, so the
        branch is not in the integer monomorphization at all). That matters
        here more than for MEDIAN: every COUNT(DISTINCT) cell in the corpus —
        clickbench cb04 / cb05 / cb10 / cb13 and tpch q16 — is over an INTEGER
        column, and the integer instantiations are also the only ones the
        radix-parallel dedup (`IS_DISTINCT_BUFFER`) admits. The float
        instantiations are stamped by `typed_agg_markers.mojo`
        (`CountDistinctOfF32` / `CountDistinctOfF64`) and are served by THIS
        `finalize` on every path, since a float can never take the radix route.

        ⚠ PERF: on a FLOAT instantiation this adds ONE O(n) self-compare pass
        per group over the value buffer, on top of the sort. That cost is real
        and UNMEASURED — it is not free and it is not a win. This is a
        correctness commit. (Integer groups pay nothing: the loop is comptime-
        gated out of their monomorphization.)

        Pin: `komira_agg.tests.test_typed_col_count_distinct_nan_total_order`.
        """
        var n = len(state.values)
        for r in range(len(state.runs)):
            n = n + len(state.runs[r])
        if n == 0:
            return Scalar[DType.int64](0)
        var buf = List[Scalar[Self.dt]](capacity=n)
        for i in range(len(state.values)):
            buf.append(state.values[i])
        for r in range(len(state.runs)):
            for i in range(len(state.runs[r])):
                buf.append(state.runs[r][i])

        # NaN PRESCAN — FLOAT INSTANTIATIONS ONLY. `comptime if` on the DType
        # means the integer monomorphizations (`CountDistinctOp[int64]` /
        # `[int32]`, both stamped by `typed_agg_markers.mojo` and the only ones
        # the corpus's COUNT(DISTINCT) cells use) do not contain this loop at
        # all: NaN is unreachable for an integer input, so they pay nothing.
        comptime if Self.dt.is_floating_point():
            var nan_count = 0
            for i in range(n):
                var v = buf[i]
                if v != v:  # IEEE: only NaN is unequal to itself
                    nan_count += 1
            if nan_count != 0:
                return Self._finalize_nan_one_value(buf, n, nan_count)

        # ---- HOT PATH: no NaN in this group. Structurally unchanged. ----
        sort(buf)
        var distinct_count = Int64(1)
        for i in range(1, n):
            if buf[i] != buf[i - 1]:
                distinct_count = distinct_count + 1
        return distinct_count

    @staticmethod
    @always_inline
    def combine(
        mut state: CountDistinctState[Self.dt],
        partial: CountDistinctState[Self.dt],
    ):
        # UNION via concat — append the donor's whole buffer. Dedup is deferred
        # to finalize, so concat is associative (cross-worker fold is
        # byte-identical to single-worker). Identity-respecting (an empty donor
        # is a no-op). This is the LEGACY serial-concat path (kill-switch off);
        # the concat-free path uses `take_distinct_buffer_into` instead. `partial`
        # never carries `runs` in this path, but fold them defensively (a value in
        # a donor run is unioned into `values` so finalize dedups it once).
        for i in range(len(partial.values)):
            state.values.append(partial.values[i])
        for r in range(len(partial.runs)):
            for i in range(len(partial.runs[r])):
                state.values.append(partial.runs[r][i])

    # -- radix-parallel dedup hooks. Only the
    # INTEGER-input distinct is parallelized — a float distinct keeps the serial
    # finalize (the `-0.0 == 0.0` / NaN equality the sort-dedup honors would break
    # under a bitwise value-hash partition). All cb04/cb05/cb10 are INT64.
    comptime IS_DISTINCT_BUFFER = _cd_dt_is_int_family[Self.dt]()

    @staticmethod
    @always_inline
    def distinct_values_i64(
        state: CountDistinctState[Self.dt]
    ) -> List[Int64]:
        # Widen the UNION (`values` ++ flatten(`runs`)) to Int64 as ONE buffer
        # (EXACT for the integer family — the ONLY family that reaches here, gated
        # by IS_DISTINCT_BUFFER). The concat-free path uses `distinct_runs_i64`
        # instead (no flatten); this single-buffer view stays correct for any
        # state shape.
        var total = len(state.values)
        for r in range(len(state.runs)):
            total = total + len(state.runs[r])
        var out = List[Int64](capacity=total)
        for i in range(len(state.values)):
            out.append(Int64(state.values[i]))
        for r in range(len(state.runs)):
            for i in range(len(state.runs[r])):
                out.append(Int64(state.runs[r][i]))
        return out^

    # -- concat-free move-combine overrides.
    @staticmethod
    @always_inline
    def take_distinct_buffer_into(
        mut dst: CountDistinctState[Self.dt],
        mut src: CountDistinctState[Self.dt],
    ):
        # MOVE `src`'s whole per-row buffer into `dst` as a NEW run — O(1) (a
        # `List` swap), NOT the O(values) copy+append the serial `combine` does.
        # `dst` accumulates one run per worker; the radix drain scatters them all
        # together (cross-buffer dedup). Identity-respecting (empty src = no-op).
        if len(src.values) > 0:
            var moved = List[Scalar[Self.dt]]()
            swap(src.values, moved)
            dst.runs.append(moved^)
        # Defensive: fold any runs `src` already holds (src is normally a fresh
        # per-worker buffer with no runs; this covers a chained merge).
        for i in range(len(src.runs)):
            var r = List[Scalar[Self.dt]]()
            swap(src.runs[i], r)
            dst.runs.append(r^)

    @staticmethod
    @always_inline
    def distinct_runs_i64(
        state: CountDistinctState[Self.dt]
    ) -> List[List[Int64]]:
        # Widen each buffer (the per-row `values` plus every move-combined worker
        # run) to Int64 as a LIST OF RUNS — NO flatten/concat. The engine layer
        # scatters ALL runs together into value-hash partitions, so a value present
        # in two runs lands in one partition and is deduped once.
        var out = List[List[Int64]]()
        if len(state.values) > 0:
            var v = List[Int64](capacity=len(state.values))
            for i in range(len(state.values)):
                v.append(Int64(state.values[i]))
            out.append(v^)
        for r in range(len(state.runs)):
            var rr = List[Int64](capacity=len(state.runs[r]))
            for i in range(len(state.runs[r])):
                rr.append(Int64(state.runs[r][i]))
            out.append(rr^)
        return out^


# =============================================================================
# §2f — MEDIAN op conformer — variable-size per-group value buffer + percentile
# =============================================================================
#
# MEDIAN. The SECOND
# variable-size per-group state in the catalog. State
# is a HEAP-OWNING `MedianState[dt]` (a `List[Scalar[dt]]` value buffer). The
# typed-COLUMN catalog hosts this exactly as it hosts COUNT_DISTINCT — the
# per-group state lives in `AggSlot[A].states: List[A.StateTy]` (a typed Mojo
# `List`, slab-safe), with a CONCAT cross-worker combine. (COUNT_DISTINCT already
# PROVED the variable-size-buffer pattern works here, so MEDIAN follows directly;
# the ROW-substrate limitation does
# NOT apply to the column path.)
#
# ALGORITHM = BUFFER + SORT + INTERPOLATED PERCENTILE SELECT AT FINALIZE:
#   update  : append the row value to the buffer (O(1) amortized).
#   combine : append the donor's whole buffer (CONCAT — associative; order does
#             not matter since finalize sorts).
#   finalize: `sort(buffer)`, then the 50th percentile with LINEAR INTERPOLATION
#             (DuckDB `median(x)` == `quantile_cont(x, 0.5)`): odd n -> the middle
#             element; even n -> the mean of the two middle elements. Empty buffer
#             -> NaN (no value; DuckDB returns NULL). Output is ALWAYS Float64 (a
#             continuous-interpolation median is inherently float — even an
#             integer-input even-count median can be a half-integer, e.g.
#             median([10,20,30,40]) = 25.0).
#
# A SINGLE conformer serves every numeric input DType (`dt`): the buffer holds the
# value in its NATIVE `dt`, `sort` is DType-generic, the percentile arithmetic
# casts the selected element(s) to Float64. NO per-DType sibling needed.
# =============================================================================


struct MedianState[dt: DType](Copyable, Movable, Deinitable):
    """Per-bucket value buffer for the MEDIAN kernel — a growable
    `List[Scalar[dt]]` holding every value fed to the group (the percentile
    select happens at `finalize` after a sort).

    HEAP-OWNING (one `List` field). Gap6-safe in the catalog because the owning
    container is `AggSlot[A].states: List[A.StateTy]` (a typed Mojo `List`, NOT a
    byte-slab) — same hosting argument as `CountDistinctState`. `List`'s
    deep `__copyinit__` gives this struct a correct deep copy for the
    cross-worker `combine` donor-`.copy()`. Identity = an empty buffer (NaN)."""

    var values: List[Scalar[Self.dt]]

    def __init__(out self):
        self.values = List[Scalar[Self.dt]]()


struct MedianOp[dt: DType](HashAggOpDt):
    """MEDIAN over `dt`. Identity = empty buffer. State = `MedianState[dt]`
    (variable-size value buffer). Output is ALWAYS Float64 (a continuous-
    interpolation median — DuckDB `median(x)` == `quantile_cont(x, 0.5)`).

    update = append the value (O(1) amortized); combine = concat the donor's
    buffer (associative — finalize sorts); finalize = sort + interpolated 50th
    percentile (even n -> mean of the two middle elements). A SINGLE conformer
    serves every numeric input DType.

    ★ MEDIAN MUST NOT SET `IS_DISTINCT_BUFFER`.
    It shares COUNT_DISTINCT's value-buffer shape, but its finalize is a
    GLOBAL-ORDER percentile select — the median depends on the sorted order of
    ALL values together. The radix-parallel dedup partitions values by hash into
    DISJOINT groups and sums per-partition results; that is correct for a distinct
    COUNT (order-independent, disjoint-summable) but would compute a per-partition
    'median' and sum them into garbage. So MedianOp INHERITS the trait default
    `IS_DISTINCT_BUFFER = False` and keeps the serial sort-finalize. Do NOT
    'complete the pattern' here."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = DType.float64
    comptime StateTy = MedianState[Self.dt]

    # The EXACT per-group median
    # finalize (variable-size buffer sort + interpolated 50th percentile) is the
    # ~84% post-collect wall of h6. It is an INDEPENDENT per-group computation
    # (no cross-group interaction), so the engine layer partitions GROUPS across
    # workers at drain time — byte-identical to the serial per-group emit, just
    # parallel. This is ORTHOGONAL to IS_DISTINCT_BUFFER (which MEDIAN must NOT
    # set — see the docstring below): SORT_FINALIZE parallelizes ACROSS groups
    # (each group's global-order percentile select stays whole + exact), whereas
    # IS_DISTINCT_BUFFER would partition WITHIN a group by value-hash (which would
    # corrupt the median). The two are independent axes; only SORT_FINALIZE=True.
    comptime SORT_FINALIZE: Bool = True

    @staticmethod
    @always_inline
    def init() -> MedianState[Self.dt]:
        return MedianState[Self.dt]()

    @staticmethod
    @always_inline
    def update_scalar(mut state: MedianState[Self.dt], value: Scalar[Self.dt]):
        state.values.append(value)

    @staticmethod
    @always_inline
    def _finalize_nan_last(
        state: MedianState[Self.dt], n: Int, nan_count: Int
    ) -> Scalar[Self.OUT_DT]:
        """The NaN-BEARING arm of `finalize` — the DuckDB total order in which
        NaN IS THE LARGEST VALUE. Reached only from the float instantiations,
        and only for a group that actually contains a NaN (the prescan in
        `finalize` is what decides). Kept out of line so the shipping NaN-free
        path is the same straight-line code it has always been.

        `k = n - nan_count` non-NaN values occupy positions `[0, k)` of the total
        order and the NaN tail occupies `[k, n)`. The median index is `mid =
        n // 2`, so:
          * `mid >= k` -> the middle order statistic IS a NaN -> return NaN.
            (Even n also needs `buf[mid - 1]`, but `mid - 1 < mid <= k - 1`
            whenever `mid < k`, so the single `mid >= k` test covers both
            parities. n >= 2 whenever n is even, so `mid - 1 >= 0`.)
          * otherwise -> compact the non-NaN values into a dense prefix and run
            the SAME sort + odd/even index arithmetic as the hot path. `<` IS a
            strict weak ordering once NaN is gone, so `sort` is back inside its
            own contract. (-0.0 and 0.0 compare equivalent under `<`, which is
            what an order statistic wants.)

        Matches DuckDB v1.5.3:
          {1,2,3,NaN} n=4 k=3 mid=2 -> (2+3)/2 = 2.5
          {1,2,NaN,NaN} n=4 k=2 mid=2 -> NaN          {NaN,NaN,NaN} -> NaN
          {1,2,NaN,NaN,NaN} n=5 k=2 mid=2 -> NaN
          {-inf,inf,NaN} n=3 k=2 mid=1 -> inf   (NaN sorts ABOVE +inf)
          {NaN,1..8} n=9 k=8 mid=4 -> 5.0, for EVERY input rotation."""
        var k = n - nan_count
        var mid = n // 2
        if mid >= k:
            return Float64(0.0) / Float64(0.0)  # NaN
        var buf = List[Scalar[Self.dt]](capacity=k)
        for i in range(n):
            var v = state.values[i]
            if v == v:  # not NaN
                buf.append(v)
        sort(buf)
        if n % 2 == 1:
            return buf[mid].cast[DType.float64]()
        var lo = buf[mid - 1].cast[DType.float64]()
        var hi = buf[mid].cast[DType.float64]()
        return lo * 0.5 + hi * 0.5

    @staticmethod
    @always_inline
    def finalize(state: MedianState[Self.dt]) -> Scalar[Self.OUT_DT]:
        """Sorted 50th-percentile select, DuckDB `quantile_cont(x, 0.5)` parity.

        ★ NaN IS A TOTAL-ORDER PROBLEM, NOT A ROUNDING PROBLEM.
        The plain `<` comparator does not work here. On IEEE floats
        `<` is NOT a strict weak ordering once a NaN is present (every
        comparison against NaN is false, so NaN is neither less than, greater
        than, nor equivalent to anything), which puts `sort` OUTSIDE ITS OWN
        CONTRACT — the output is not merely "NaN somewhere", it is an arbitrary
        permutation determined by the INPUT order. And the input order here is
        row-arrival order per worker, concatenated in worker-merge order by
        `combine`, so THREAD COUNT, MORSEL PARTITIONING AND MERGE ORDER CHANGED
        THE ANSWER FOR THE SAME TABLE. Measured before the fix: the nine
        rotations of {NaN,1..8} returned nine DISTINCT answers (4,5,6,7,8,NaN,
        1,2,3); DuckDB returns 5.0 for all nine. Through `combine`, one multiset
        split four ways gave 4.0 / 8.0 / NaN / 4.0.

        The fix is a NaN COUNT PRESCAN, and it is deliberately shaped so the
        SHIPPING PATH IS UNTOUCHED: a group with no NaN runs the same
        `sort(buf)` + index arithmetic as before, and an integer instantiation
        does not even run the prescan (`comptime if` on
        `dt.is_floating_point()`, so the branch is not in the integer
        monomorphization at all). Only a NaN-bearing float group takes
        `_finalize_nan_last`.

        ⚠ PERF: on a FLOAT instantiation this adds ONE O(n) self-compare pass
        per group over the value buffer, on top of the sort. That cost is real
        and UNMEASURED — it is not free and it is not a win. This is a
        correctness commit.

        ★ THE EVEN CASE ALSO CHANGED, and it is an INDEPENDENT defect: the old
        `(lo + hi) / 2.0` OVERFLOWS to +/-inf when the two middle order
        statistics are same-signed and large. Measured (ours-before / DuckDB):
        {1e308,1e308} inf / 1e+308; {-1e308,-1e308} -inf / -1e+308;
        {5e307,1.5e308} inf / 1e+308; {1e308,1.5e308} inf / 1.25e+308. The
        spelling that reproduced DuckDB on 300/300 randomized differential cases
        is `lo * 0.5 + hi * 0.5`, and it is discriminated from the other
        plausible spelling `lo + (hi - lo) * 0.5` by {-inf,-inf}, where the lerp
        form gives NaN and DuckDB gives -inf (both agree on {-inf,inf} -> NaN).
        KNOWN AND DELIBERATELY ADOPTED: {5e-324,5e-324} now returns 0.0 (each
        half underflows) where the naive mean returned 5e-324 — DuckDB also
        returns 0.0, and the contract here is DuckDB parity.

        ⚠ NOT DONE HERE, ON PURPOSE: this still SORTS the whole buffer where a
        partial selection (`nth_element`-style partition around `mid`) would be
        O(n) expected instead of O(n log n). That is a PERF transform with its
        own measurement and its own risk surface, and it does not belong in a
        correctness commit. The sibling exact-median path
        (`agg_extended_grouped._ext_median_inplace`) sorts too, and carries BOTH
        of the defects fixed here — see the audit note in the commit message.

        Pin: `komira_agg.tests.test_typed_col_median_nan_total_order`."""
        var n = len(state.values)
        if n == 0:
            return Float64(0.0) / Float64(0.0)  # NaN (DuckDB NULL convention)

        # NaN PRESCAN — FLOAT INSTANTIATIONS ONLY. `comptime if` on the DType
        # means the integer monomorphizations (`MedianOp[int64]` /
        # `MedianOp[int32]`, both stamped by `typed_agg_markers.mojo`) do not
        # contain this loop at all: NaN is unreachable for an integer input, so
        # they pay nothing.
        comptime if Self.dt.is_floating_point():
            var nan_count = 0
            for i in range(n):
                var v = state.values[i]
                if v != v:  # IEEE: only NaN is unequal to itself
                    nan_count += 1
            if nan_count != 0:
                return Self._finalize_nan_last(state, n, nan_count)

        # ---- HOT PATH: no NaN in this group. Structurally unchanged. ----
        var buf = state.values.copy()
        sort(buf)
        var mid = n // 2
        if n % 2 == 1:
            # Odd count: the single middle element.
            return buf[mid].cast[DType.float64]()
        # Even count: linear interpolation = mean of the two middle elements
        # (DuckDB quantile_cont(0.5)). HALF-SUM, not `(lo + hi) / 2` — see the
        # overflow paragraph in the docstring.
        var lo = buf[mid - 1].cast[DType.float64]()
        var hi = buf[mid].cast[DType.float64]()
        return lo * 0.5 + hi * 0.5

    @staticmethod
    @always_inline
    def combine(
        mut state: MedianState[Self.dt], partial: MedianState[Self.dt]
    ):
        # CONCAT — append the donor's whole buffer. Associative (finalize sorts,
        # so order does not matter). Identity-respecting (an empty donor is a
        # no-op).
        for i in range(len(partial.values)):
            state.values.append(partial.values[i])


# =============================================================================
# §3 — HashAggOpAgg[Op, col] — the DType-TEMPLATED constructible adapter
# =============================================================================
#
# ONE struct conforming to the unified `Aggregator` trait, parametric on a
# `HashAggOpDt` op conformer `Op` + the comptime input-column index `col`. The
# input DType is `Op.DT`; the adapter selects the matching `BatchView` typed
# accessor via a comptime `Op.DT ==` ladder (folds to a direct typed load).
#
# CONSTRUCTIBLE: field-less, real default `__init__`, working static `init()`.
# This is the constructible generic family the typed factory stamps from a
# typed marker for ANY op + ANY DType (the construction-wall close).
#
# `OUT_DT` is `Op.OUT_DT` — the op's NATIVE output DType .
# The drain emits each agg column
# in this native DType (int64 for COUNT + integer SUM/MIN/MAX; float64 for AVG
# + float SUM/MIN/MAX) so the typed output is byte-identical to the untyped
# path. `finalize` returns `Scalar[Op.OUT_DT]`; the `AggSlot` drain reads it
# via the per-agg `emit_column` / `out_arrow_type` surface (not the legacy
# uniform-F64 channel).
# =============================================================================


struct HashAggOpAgg[Op: HashAggOpDt, col: Int](Aggregator):
    """DType-templated `Aggregator` adapter — ONE struct over the whole
    `HashAggOpDt` family. `Op` carries its own input DType (`Op.DT`); the
    adapter reads input column `col` off the `BatchView` via a comptime DType
    ladder and forwards the native scalar to `Op.update_scalar`.

    Field-less — `Op` / `col` are comptime params. CONSTRUCTIBLE via the no-arg
    `__init__` + working static `init()` (vs `AggFnAgg.init()` =
    `constrained[False]`). Drops into `AggSlot[A: Aggregator]` unchanged.
    """

    comptime StateTy = Self.Op.StateTy
    comptime OUT_DT: DType = Self.Op.OUT_DT

    def __init__(out self):
        """Field-less default ctor (the construction-wall close — `Op`/`col`
        are comptime params; an adapter instance carries no state)."""
        pass

    @staticmethod
    @always_inline
    def make() -> Self:
        """`Aggregator.make` — field-less default-construct (VARIADIC-FACTORY).
        `Op` / `col` are comptime params, so the adapter carries no state."""
        return Self()

    @staticmethod
    @always_inline
    def init() -> Self.StateTy:
        return Self.Op.init()

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, batch: BatchView[bo], i: Int):
        """Fold the row at logical index `i` into `state`. Reads input column
        `col` per `Op.DT` (comptime-known) via the matching `BatchView`
        accessor; the ladder folds to a direct typed load + direct
        `Op.update_scalar` call (no runtime DType dispatch)."""
        comptime if Self.Op.DT == DType.float64:
            Self.Op.update_scalar(
                state, batch.col_f64(Self.col).load[1](i)[0].cast[Self.Op.DT]()
            )
        elif Self.Op.DT == DType.int64:
            Self.Op.update_scalar(
                state, batch.col_i64(Self.col).load[1](i)[0].cast[Self.Op.DT]()
            )
        elif Self.Op.DT == DType.int32:
            Self.Op.update_scalar(
                state, batch.col_i32(Self.col).load[1](i)[0].cast[Self.Op.DT]()
            )
        elif Self.Op.DT == DType.float32:
            Self.Op.update_scalar(
                state, batch.col_f32(Self.col).load[1](i)[0].cast[Self.Op.DT]()
            )
        else:
            # this covers I64/I32/F64/F32 — the four BatchView typed
            # accessors (matches AggFnAgg's ladder). Other input DTypes are not
            # supported.
            comptime assert False, ("HashAggOpAgg: input column DType is not yet supported ("
                "supported: int64 / int32 / float64 / float32; extend the "
                "ladder when adding new input DType coverage).")

    @always_inline
    def update_scalar_mv[
        V: MorselView
    ](mut self, mut state: Self.StateTy, view: V, i: Int):
        """ENGINE-V2 MorselView seam sibling of `update_scalar`. The `update_scalar`
        ladder reads the col at its NATIVE accessor DType then `.cast[Op.DT]()`
        (a no-op -- the accessor DType selected per `Op.DT` already IS `Op.DT`),
        so this collapses to a single `col_scalar_nonraising[Op.DT]` read that is
        byte-identical to the batch path (same value, same `Op.update_scalar`
        fold). COUNT (`Op.update_scalar` ignores its value) reads the placeholder
        col harmlessly, exactly like the batch path."""
        Self.Op.update_scalar(
            state, view.col_scalar_nonraising[Self.Op.DT](Self.col, i)
        )

    @always_inline
    def update_band[
        o: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, band: BandView[o], row: Int):
        """The BAND sibling of `update_scalar`. Reads input column `col` at `row`
        DIRECTLY from the band's reused per-column scratch span (per `Op.DT`,
        comptime-known) and forwards the native scalar to the SAME
        `Op.update_scalar` value-fold the batch path uses — hence byte-identical
        to `update_scalar` on identical data (same value, same fold).

        COUNT (`Op.NEEDS_VALUE == False`) SKIPS the read entirely: its bound `col`
        is a structural placeholder (a group-key column, no valid fixed-width band
        span), and `Op.update_scalar` ignores its value arg, so a zero placeholder
        yields the identical increment.

        FLOAT32 AGGREGANDS. This
        body used to be a three-arm DType ladder (`col_f64_span` / `col_i64_span`
        / `col_i32_span`) closed by `comptime assert False` for "float32 + other
        input DTypes". That assert was NOT a runtime guard — it is a COMPTIME
        constraint, and the comptime dispatch tree instantiates the band arm for
        every agg in the pack regardless of the runtime source. So ANY query with
        an F32 aggregand (`SumOfF32` / `MinOfF32` / `MaxOfF32` / `AvgOfF32`) could
        not COMPILE, even over an Avro row source that never reaches a parquet
        band at runtime: `integration_test_typed_row_f32_minmax_typed_e2e` and
        `integration_test_typed_row_avg_maxi64_f32sum_dispatch_e2e` both FAILED TO
        BUILD with `constraint failed: HashAggOpAgg.update_band: band fold covers
        int64 / int32 / float64 aggregands`.

        The ladder is now the single generic `BandView.col_scalar[dt]` read —
        `_typed_span[dt](idx)[row]`, which is EXACTLY what each of the three
        removed arms expanded to (`col_XX_span(idx)[row]`) with a no-op
        same-DType `.cast`. So f64/i64/i32 are byte-identical, and every other
        fixed-width aggregand DType (f32 included) is served by the same
        reinterpret-the-raw-band-bytes read instead of failing to compile."""
        comptime if not Self.Op.NEEDS_VALUE:
            # COUNT: increment only; no value read (see NEEDS_VALUE docstring).
            Self.Op.update_scalar(state, Scalar[Self.Op.DT](0))
        else:
            Self.Op.update_scalar(
                state, band.col_scalar[Self.Op.DT](Self.col, row)
            )

    @always_inline
    def combine(mut self, mut into: Self.StateTy, var partial: Self.StateTy):
        Self.Op.combine(into, partial)

    @staticmethod
    @always_inline
    def finalize(state: Self.StateTy) -> Scalar[Self.OUT_DT]:
        return Self.Op.finalize(state)

    # -- Forward the exact-integer-SUM
    # narrowing hooks to the underlying `Op` (True only for an int `SumOp`).
    comptime EXACT_INT_SUM: Bool = Self.Op.EXACT_INT_SUM

    @staticmethod
    @always_inline
    def total_fits_i64(state: Self.StateTy) -> Bool:
        return Self.Op.total_fits_i64(state)

    # -- forward the radix-parallel dedup
    # hooks to the underlying `Op` (static, matching every other forward above).
    comptime IS_DISTINCT: Bool = Self.Op.IS_DISTINCT_BUFFER

    @always_inline
    def distinct_values(self, state: Self.StateTy) -> List[Int64]:
        return Self.Op.distinct_values_i64(state)

    # -- forward the concat-free move-combine
    # + multi-run hooks to the underlying `Op`.
    @always_inline
    def take_distinct_into(
        self, mut dst: Self.StateTy, mut src: Self.StateTy
    ):
        Self.Op.take_distinct_buffer_into(dst, src)

    @always_inline
    def distinct_runs(self, state: Self.StateTy) -> List[List[Int64]]:
        return Self.Op.distinct_runs_i64(state)

    # -- forward the parallel per-group
    # finalize flag to the underlying `Op` (True only for MedianOp).
    comptime PARALLEL_SORT_FINALIZE: Bool = Self.Op.SORT_FINALIZE
