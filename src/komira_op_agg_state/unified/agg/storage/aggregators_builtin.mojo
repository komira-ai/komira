# =============================================================================
# aggregators_builtin — 8 standard Aggregator impls (Wave 9 v4.1.3 Phase G-pre)
# =============================================================================
#
# Phase G-pre retrofit per plan §3.0b / §6.8a. Replaces the per-AccTag
# kernel math at `accumulator_set.mojo:462-567` (the 4 monomorphic
# AosRowThunk bodies) with comptime-monomorphizable static methods on
# 8 trait conformer structs. Both AoS (via thunk wrappers) and Slab
# (via comptime fan-out per plan §3.3) storage paths invoke the same
# trait method calls.
#
# Impls landed:
#   1. SumF64       — SUM over Float64 (s += x)
#   2. SumI64       — SUM over Int64
#   3. CountStar    — COUNT(*) (s += 1, input ignored)
#   4. MinF64       — MIN over Float64 (saturating init at +inf)
#   5. MaxF64       — MAX over Float64 (saturating init at -inf)
#   6. MinI64       — MIN over Int64
#   7. MaxI64       — MAX over Int64
#   8. AvgF64       — AVG over Float64 (sum-only state; count tracked
#                     in sibling slot; finalize divides — composite
#                     handled at AccTag level via paired sum+count
#                     slots in AggLayout)
#
# Composite Aggregators (sum+count combos for narrow layout) are
# explicitly NOT in this file's scope — those are AggLayout-level
# packings that compose two atomic Aggregators into one slot. The
# narrow-layout shape (`ACC_SUM_COUNT_F64`, `ACC_SUM_COUNT_MIN_MAX_F64`)
# remains the AccTag-level concern; Phase G-pre's role is to provide
# atomic Aggregator math units that the layout layer can compose. The
# existing AosRowThunk thunks at `accumulator_set.mojo:462-499`
# continue to handle the composite layouts — they delegate the inner
# arithmetic ops (one each per sub-field) into the corresponding
# atomic Aggregator's `update`. See §6.8a worked retrofit.
#
# References:
#   - an internal doc §3.0b worked
#     retrofit + §6.8a Phase G-pre
#   - an internal doc (item 19; new Aggregator
#     impls land alongside via the same trait abstraction)
#   - an internal doc (Repro 28:
#     hand-staged SIMD required; Phase G-pre uses the default-impl loop
#     until Phase H specializes per-(agg_fn, T))
# =============================================================================

from komira_eval.float_quotient_order import (
    float_max_fold_f64,
    float_max_identity_f64,
    float_min_fold_f64,
    float_min_identity_f64,
)
from komira_engine_operators.unified.agg.storage.aggregator_trait import (
    Aggregator,
)


# =============================================================================
# SumF64 — SUM over Float64
# =============================================================================
#
# Replaces `row_sum_f64` (`accumulator_set.mojo:499-506`) for the
# atomic ACC_SUM_F64 case. Composite ACC_SUM_COUNT_*_F64 thunks
# decompose into a SumF64.update + CountStar.update pair (and
# Min/Max in the quartet case) at the thunk wrapper site.
# =============================================================================


struct SumF64(Aggregator, Movable, Deinitable):
    """SUM(Float64) — kernel math `s += x`.

    State / Input / Output are all Float64. The default `update_batch[N]`
    body loops scalar update; Phase H's per-(agg_fn, T) hand-staged SIMD
    overrides with `ss += xs` (single SIMD add per N-wide vector).
    """

    var _phantom: UInt8

    comptime StateDType = DType.float64
    comptime InputDType = DType.float64
    comptime OutputDType = DType.float64

    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def init() -> Scalar[DType.float64]:
        return 0.0

    @always_inline
    @staticmethod
    def update(
        mut state: Scalar[DType.float64], input: Scalar[DType.float64]
    ):
        state += input

    @always_inline
    @staticmethod
    def update_batch[
        N: Int
    ](
        mut states: SIMD[DType.float64, N],
        inputs: SIMD[DType.float64, N],
    ):
        # Vectorized override: single SIMD add per N-wide vector. This
        # is the only Aggregator in Phase G-pre that overrides
        # update_batch with an explicit SIMD body — Phase H extends to
        # all 8 impls per (agg_fn, T) hand-staged specialization.
        # The vectorized form here is correct AND identical to the
        # default-impl loop (verified by `update_batch_simd_matches_scalar`
        # case in test_aggregator_trait.mojo).
        states += inputs

    @always_inline
    @staticmethod
    def combine(
        mut a: Scalar[DType.float64], b: Scalar[DType.float64]
    ):
        a += b

    @always_inline
    @staticmethod
    def finalize(state: Scalar[DType.float64]) -> Scalar[DType.float64]:
        return state


# =============================================================================
# SumI64 — SUM over Int64
# =============================================================================


struct SumI64(Aggregator, Movable, Deinitable):
    """SUM(Int64) — kernel math `s += x`."""

    var _phantom: UInt8

    comptime StateDType = DType.int64
    comptime InputDType = DType.int64
    comptime OutputDType = DType.int64

    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def init() -> Scalar[DType.int64]:
        return 0

    @always_inline
    @staticmethod
    def update(
        mut state: Scalar[DType.int64], input: Scalar[DType.int64]
    ):
        state += input

    @always_inline
    @staticmethod
    def update_batch[
        N: Int
    ](
        mut states: SIMD[DType.int64, N],
        inputs: SIMD[DType.int64, N],
    ):
        states += inputs

    @always_inline
    @staticmethod
    def combine(
        mut a: Scalar[DType.int64], b: Scalar[DType.int64]
    ):
        a += b

    @always_inline
    @staticmethod
    def finalize(state: Scalar[DType.int64]) -> Scalar[DType.int64]:
        return state


# =============================================================================
# CountStar — COUNT(*)
# =============================================================================
#
# Replaces `row_count_star` (`accumulator_set.mojo:511-523`). Input is
# Bool placeholder (per §3.0b worked retrofit); update increments by 1
# regardless of input value. Default impl loops scalar; SIMD body
# adds 1 per lane.
# =============================================================================


struct CountStar(Aggregator, Movable, Deinitable):
    """COUNT(*) — kernel math `s += 1` (input ignored).

    Input DType is Bool (placeholder per §3.0b). State DType is UInt64
    (matches the existing Int64 count slot in AggLayout; Mojo SIMD
    casts at the lane boundary).
    """

    var _phantom: UInt8

    comptime StateDType = DType.uint64
    comptime InputDType = DType.bool
    comptime OutputDType = DType.uint64

    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def init() -> Scalar[DType.uint64]:
        return 0

    @always_inline
    @staticmethod
    def update(
        mut state: Scalar[DType.uint64], input: Scalar[DType.bool]
    ):
        state += 1

    @always_inline
    @staticmethod
    def update_batch[
        N: Int
    ](
        mut states: SIMD[DType.uint64, N],
        inputs: SIMD[DType.bool, N],
    ):
        # Every lane increments; input is ignored (COUNT(*) doesn't
        # filter by input).
        states += 1

    @always_inline
    @staticmethod
    def combine(
        mut a: Scalar[DType.uint64], b: Scalar[DType.uint64]
    ):
        a += b

    @always_inline
    @staticmethod
    def finalize(state: Scalar[DType.uint64]) -> Scalar[DType.uint64]:
        return state


# =============================================================================
# MinF64 — MIN over Float64
# =============================================================================
#
# Init state is +inf (saturating); update keeps the smaller of the
# state vs input. Combine takes min of two states.
# =============================================================================


struct MinF64(Aggregator, Movable, Deinitable):
    """MIN(Float64) — saturating-init at +inf; `s = min(s, x)`."""

    var _phantom: UInt8

    comptime StateDType = DType.float64
    comptime InputDType = DType.float64
    comptime OutputDType = DType.float64

    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def init() -> Scalar[DType.float64]:
        # +inf as the saturating min identity (Float64.MAX would also
        # work; +inf is more conventional and matches DuckDB's MIN
        # neutral element).
        return float_min_identity_f64()

    @always_inline
    @staticmethod
    def update(
        mut state: Scalar[DType.float64], input: Scalar[DType.float64]
    ):
        state = float_min_fold_f64(state, input)

    @always_inline
    @staticmethod
    def combine(
        mut a: Scalar[DType.float64], b: Scalar[DType.float64]
    ):
        a = float_min_fold_f64(a, b)

    @always_inline
    @staticmethod
    def finalize(state: Scalar[DType.float64]) -> Scalar[DType.float64]:
        return state


# =============================================================================
# MaxF64 — MAX over Float64
# =============================================================================


struct MaxF64(Aggregator, Movable, Deinitable):
    """MAX(Float64) — saturating-init at -inf; `s = max(s, x)`."""

    var _phantom: UInt8

    comptime StateDType = DType.float64
    comptime InputDType = DType.float64
    comptime OutputDType = DType.float64

    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def init() -> Scalar[DType.float64]:
        return float_max_identity_f64()

    @always_inline
    @staticmethod
    def update(
        mut state: Scalar[DType.float64], input: Scalar[DType.float64]
    ):
        state = float_max_fold_f64(state, input)

    @always_inline
    @staticmethod
    def combine(
        mut a: Scalar[DType.float64], b: Scalar[DType.float64]
    ):
        a = float_max_fold_f64(a, b)

    @always_inline
    @staticmethod
    def finalize(state: Scalar[DType.float64]) -> Scalar[DType.float64]:
        return state


# =============================================================================
# MinI64 — MIN over Int64
# =============================================================================


struct MinI64(Aggregator, Movable, Deinitable):
    """MIN(Int64) — saturating-init at Int64.MAX; `s = min(s, x)`."""

    var _phantom: UInt8

    comptime StateDType = DType.int64
    comptime InputDType = DType.int64
    comptime OutputDType = DType.int64

    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def init() -> Scalar[DType.int64]:
        return Scalar[DType.int64].MAX

    @always_inline
    @staticmethod
    def update(
        mut state: Scalar[DType.int64], input: Scalar[DType.int64]
    ):
        if input < state:
            state = input

    @always_inline
    @staticmethod
    def combine(
        mut a: Scalar[DType.int64], b: Scalar[DType.int64]
    ):
        if b < a:
            a = b

    @always_inline
    @staticmethod
    def finalize(state: Scalar[DType.int64]) -> Scalar[DType.int64]:
        return state


# =============================================================================
# MaxI64 — MAX over Int64
# =============================================================================


struct MaxI64(Aggregator, Movable, Deinitable):
    """MAX(Int64) — saturating-init at Int64.MIN; `s = max(s, x)`."""

    var _phantom: UInt8

    comptime StateDType = DType.int64
    comptime InputDType = DType.int64
    comptime OutputDType = DType.int64

    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def init() -> Scalar[DType.int64]:
        return Scalar[DType.int64].MIN

    @always_inline
    @staticmethod
    def update(
        mut state: Scalar[DType.int64], input: Scalar[DType.int64]
    ):
        if input > state:
            state = input

    @always_inline
    @staticmethod
    def combine(
        mut a: Scalar[DType.int64], b: Scalar[DType.int64]
    ):
        if b > a:
            a = b

    @always_inline
    @staticmethod
    def finalize(state: Scalar[DType.int64]) -> Scalar[DType.int64]:
        return state


# =============================================================================
# AvgF64 — AVG over Float64 (sum-only state form)
# =============================================================================
#
# Phase G-pre's AvgF64 exposes the SUM half of the SUM/COUNT pair via
# a Float64 State; the COUNT half is provided by a sibling CountStar
# instance composed at the AggLayout level (`ACC_SUM_COUNT_F64` shape).
# Finalize is a pure passthrough — the divide happens at the SDK
# materialization layer, where it composes naturally with the COUNT
# slot in the same AggLayout entry.
#
# This split mirrors how the existing AccumulatorSet handles AVG today:
# the narrow-layout AVG slot is `(sum: Float64, count: Int64)` packed
# into 16 bytes, and the AVG factory in `accumulator.mojo` posts both
# updates into the row in lockstep. The Aggregator-trait retrofit
# preserves this composition: AvgF64 just IS SumF64 with a different
# AccTag identity, and the COUNT half is independently provided.
#
# Item 19's stddev / corr take the alternative path: a dedicated
# `AggregatorWithStruct` trait variant (per §3.0b option 2) carries
# the multi-field state internally. v0.4 envelope; gated on Phase G-pre
# landing GREEN.
# =============================================================================


struct AvgF64(Aggregator, Movable, Deinitable):
    """AVG(Float64) — sum-only state; count tracked in sibling AccTag slot.

    Identical kernel math to SumF64; the AccTag split between SUM and
    AVG is a layout-level concern (same arithmetic, different finalize
    path at SDK materialization).
    """

    var _phantom: UInt8

    comptime StateDType = DType.float64
    comptime InputDType = DType.float64
    comptime OutputDType = DType.float64

    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def init() -> Scalar[DType.float64]:
        return 0.0

    @always_inline
    @staticmethod
    def update(
        mut state: Scalar[DType.float64], input: Scalar[DType.float64]
    ):
        state += input

    @always_inline
    @staticmethod
    def update_batch[
        N: Int
    ](
        mut states: SIMD[DType.float64, N],
        inputs: SIMD[DType.float64, N],
    ):
        states += inputs

    @always_inline
    @staticmethod
    def combine(
        mut a: Scalar[DType.float64], b: Scalar[DType.float64]
    ):
        a += b

    @always_inline
    @staticmethod
    def finalize(state: Scalar[DType.float64]) -> Scalar[DType.float64]:
        # Passthrough — SDK materialization layer divides by COUNT.
        return state
