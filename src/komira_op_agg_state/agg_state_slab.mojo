# =============================================================================
# agg_state_slab.mojo — AggStateSlab + KeyHashFn + KeyEqFn traits + conformers
# =============================================================================
#
# WSC PHASE-B deliverable per RFC v1.1 §2.4 lines 559-579 + preflight §3.5.
#
# Three trait families + their v0.4 GA conformers:
#
#   1. HashAggOp{F64,I64} conformers — per-bucket aggregate primitives
#      (Sum / Count / Min / Max / Avg). Trait DECLARATIONS live at
#      eval-pkg level (`komira_eval/agg_op_traits.mojo`); CONFORMERS
#      live here in the operators pkg.
#
#   2. AggStateSlab[AggOp] — decouples per-bucket agg from container
#      shape (scalar-1-bucket vs hash-table-N-buckets). The H2O spike's
#      load-bearing trait surface (h2o_expr_nodes.mojo §6).
#
#   3. KeyHashFn / KeyEqFn — pluggable hash + equality conformers for
#      composite keys. Mirrors H2O spike's KeyHashFnv / KeyEqStringInt64
#      shape; consumed by CompositeHashTable stage primitive.
#
# Encapsulation invariants (the internal development notes hard ban #1, #3):
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - All conformers are field-less marker structs (Q6/H2O spike pattern)
#     — state is held externally in the hash-table slot, not on the AggOp.
#
# Cross-references:
#   - WSC RFC v1.1 §2.4 lines 559-579 (AggStateSlab + KeyHashFn + KeyEqFn).
#   - komira_eval/agg_op_traits.mojo (trait declarations).
#   - WSC-SPIKE-H2O h2o_expr_nodes.mojo §4 (SumF64 / CountF64 conformers
#     reused verbatim).
#   - WSC-SPIKE-Q1 fused_expr_nodes_q1.mojo §8 (HashAggSum4F64I64 — the
#     fused multi-agg conformer; v0.4 PHASE-B splits into per-agg-fn
#     conformers).
# =============================================================================

from komira_udf.float_quotient_order import (
    float_max_fold_f64,
    float_max_identity_f64,
    float_min_fold_f64,
    float_min_identity_f64,
)
from komira_agg.agg_op_traits import (
    HashAggOpF32,
    HashAggOpF64,
    HashAggOpI32,
    HashAggOpI64,
)
from komira_expr.composite_key import (
    KeyValue1, KeyValue2, KeyValue3, KeyValue4,
    hash_key_value1, hash_key_value2, hash_key_value3, hash_key_value4,
    eq_key_value1, eq_key_value2, eq_key_value3, eq_key_value4,
)
# LOWER-UNTYPED-AGG-MEDIAN-ARM — reuse the
# existing MedianState POD (Int32 count + Int32 pad + InlineArray[Float64, 64])
# from aggregators_struct_builtin.mojo. The state struct is already POD,
# gap6-safe (no heap-owning inner fields), and conforms to the
# Copyable+Movable+Deinitable bound on HashAggOpF64.StateTy.
#
# ERR-CAT-A-LARGEST-K-WIREUP — reuse the
# existing LargestKState POD (Int32 count + Int32 pad +
# InlineArray[Float64, 2]) for the LARGEST_K AGG wireup. Same POD shape;
# K=2 hardcoded (matches H2O h8 `largest2(v3)` semantics).
#
# ERR-CAT-A-STDDEV-WIREUP — reuse the existing
# WelfordState POD (UInt64 count + Float64 mean + Float64 m2 = 24 bytes)
# for the AGG_STDDEV_SAMP wireup. Same POD shape; numerically-stable
# Welford one-pass + Chan combine semantics inherited from
# StddevSampAggregator.
from komira_op_agg_state.aggregators_struct_builtin import (
    median_of_reservoir_nan_last,
    LargestKState,
    MedianState,
    MAX_MEDIAN_VALUES,
    WelfordState,
)
from std.math import sqrt

# ERR-CAT-A-COUNT-DISTINCT-WIREUP — the
# CountDistinctI64ToF64 conformer is declared in runtime_breaker_state.mojo
# (alongside the HashSetI64 primitive it wraps) to avoid a circular import.
# The HashAggTableF64[CountDistinctI64ToF64] field in RuntimeBreakerState
# is the consumer; same monomorphization pattern as MedianF64 here.


# =============================================================================
# §1 — HashAggOpF64 conformers — Sum / Count / Min / Max / Avg over Float64
# =============================================================================
#
# Each conformer is a zero-field marker struct. State is held externally
# (in HashAggTable / CompositeHashTable slots). The trait methods
# (init / update_scalar / finalize) carry @always_inline for monomorphizer
# inlining into the fused-stage loop body.
#
# Mirrors WSC-SPIKE-H2O's SumF64 + CountF64 conformer pattern verbatim
# (h2o_expr_nodes.mojo §4 lines 204-239); extends with Min, Max, Avg.
# =============================================================================


@fieldwise_init
struct SumF64(HashAggOpF64):
    """Sum over Float64. StateTy = Float64."""

    comptime StateTy = Float64

    @staticmethod
    @always_inline
    def init() -> Float64:
        return Float64(0.0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Float64, value: Float64):
        state = state + value

    @staticmethod
    @always_inline
    def finalize(state: Float64) -> Float64:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Float64, partial: Float64):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running sum: combine adds the partials."""
        state = state + partial


@fieldwise_init
struct CountF64(HashAggOpF64):
    """Count-non-null over Float64. StateTy = Float64 (count stored as Float64
    for output-type uniformity).

    Note: for the PHASE-B trait surface we keep `update_scalar(mut state,
    value)` — the value is unused but the trait shape is uniform across
    AggOps. PHASE-D may add a `update_scalar_nullable(mut state, value,
    is_null)` overload for true Count-non-null semantics; PHASE-B counts
    every row passed in (no-null model).
    """

    comptime StateTy = Float64

    @staticmethod
    @always_inline
    def init() -> Float64:
        return Float64(0.0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Float64, value: Float64):
        state = state + 1.0

    @staticmethod
    @always_inline
    def finalize(state: Float64) -> Float64:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Float64, partial: Float64):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running count: combine adds the partial counts."""
        state = state + partial


@fieldwise_init
struct MinF64(HashAggOpF64):
    """Min over Float64. StateTy = Float64 (init = +Inf-equivalent
    sentinel; PHASE-B uses 1e300 to avoid NaN complexity per Q1
    spike pattern)."""

    comptime StateTy = Float64

    @staticmethod
    @always_inline
    def init() -> Float64:
        return float_min_identity_f64()

    @staticmethod
    @always_inline
    def update_scalar(mut state: Float64, value: Float64):
        state = float_min_fold_f64(state, value)

    @staticmethod
    @always_inline
    def finalize(state: Float64) -> Float64:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Float64, partial: Float64):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running min: combine keeps the smaller."""
        state = float_min_fold_f64(state, partial)


@fieldwise_init
struct MaxF64(HashAggOpF64):
    """Max over Float64. StateTy = Float64 (init = -Inf-equivalent
    sentinel: -1e300)."""

    comptime StateTy = Float64

    @staticmethod
    @always_inline
    def init() -> Float64:
        return float_max_identity_f64()

    @staticmethod
    @always_inline
    def update_scalar(mut state: Float64, value: Float64):
        state = float_max_fold_f64(state, value)

    @staticmethod
    @always_inline
    def finalize(state: Float64) -> Float64:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Float64, partial: Float64):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running max: combine keeps the larger."""
        state = float_max_fold_f64(state, partial)


# -----------------------------------------------------------------------------
# FIRST / LAST over Float64 — order-dependent value-pick (seen-flag state)
# -----------------------------------------------------------------------------
# AGG-FIRST-LAST — the untyped-COLUMN FIRST / LAST accumulators,
# mirroring the typed-COLUMN `FirstOp` / `LastOp` semantics oracle
# (`komira_eval/hash_agg_op_dt.mojo` §2d) so the universal-fallback (Path2)
# executes FIRST/LAST instead of raising "v0.5 out-of-scope".
#
# State is a 2-field POD `FirstLastF64State` (value + seen flag) — the
# MIN/MAX-shape (scalar running state) PLUS a `seen` flag, which is REQUIRED
# (vs MIN/MAX's pure sentinel) because ANY input value — including a sentinel —
# is a valid FIRST/LAST result, so we cannot distinguish "no value yet" from
# "the value happens to equal the sentinel". Identity = (value=0, seen=False).
#
# SEMANTICS (verbatim from the typed-column FirstOp / LastOp; DuckDB
# `first.cpp` / `last.cpp`):
#   FIRST: write the value only on the FIRST update; subsequent updates are
#          no-ops (the state sticks once seen). combine: keep `a` if a.seen,
#          else take `b` (the earlier partition wins).
#   LAST:  every update OVERWRITES the value. combine: take `b` if b.seen, else
#          keep `a` (the later partition wins).
# These are INHERENTLY ORDER-DEPENDENT (non-ordered aggregation): the result
# depends on row arrival order. Single-worker / single-partition is
# unambiguous; cross-partition merge order is the partition-visit order.
#
# OUTPUT DType: FIRST/LAST pick an existing value, so the natural output is the
# input's native value — we follow the MIN/MAX native-drain convention
# (float-family input -> Float64 state+out). gap6-safe: 2 POD fields, no
# heap-owning inner field.
# -----------------------------------------------------------------------------


@fieldwise_init
struct FirstLastF64State(
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Per-bucket running-state for FIRST / LAST over Float64. Two POD fields;
    `seen` distinguishes the identity (no value yet) from a written value.
    Identity = (value=0.0, seen=False)."""

    var value: Float64
    var seen: Bool


@fieldwise_init
struct FirstF64(HashAggOpF64):
    """FIRST over Float64. StateTy = `FirstLastF64State`. update writes the
    value only on the first-seen update (state sticks); combine keeps `a` if
    a.seen else takes `b`. ORDER-DEPENDENT (first value in arrival order)."""

    comptime StateTy = FirstLastF64State

    @staticmethod
    @always_inline
    def init() -> FirstLastF64State:
        return FirstLastF64State(Float64(0.0), False)

    @staticmethod
    @always_inline
    def update_scalar(mut state: FirstLastF64State, value: Float64):
        # FIRST: write only on the first update; subsequent updates no-ops.
        if not state.seen:
            state.value = value
            state.seen = True

    @staticmethod
    @always_inline
    def finalize(state: FirstLastF64State) -> Float64:
        return state.value

    @staticmethod
    @always_inline
    def combine(mut state: FirstLastF64State, partial: FirstLastF64State):
        # Keep the accumulator if it has already seen a value (it is the
        # earlier partition); otherwise adopt the partial. Identity-respecting.
        if not state.seen:
            state = partial


@fieldwise_init
struct LastF64(HashAggOpF64):
    """LAST over Float64. StateTy = `FirstLastF64State`. update always
    overwrites; combine takes `b` if b.seen else keeps `a`. ORDER-DEPENDENT
    (last value in arrival order)."""

    comptime StateTy = FirstLastF64State

    @staticmethod
    @always_inline
    def init() -> FirstLastF64State:
        return FirstLastF64State(Float64(0.0), False)

    @staticmethod
    @always_inline
    def update_scalar(mut state: FirstLastF64State, value: Float64):
        # LAST: every update overwrites — the running value is the most-recent.
        state.value = value
        state.seen = True

    @staticmethod
    @always_inline
    def finalize(state: FirstLastF64State) -> Float64:
        return state.value

    @staticmethod
    @always_inline
    def combine(mut state: FirstLastF64State, partial: FirstLastF64State):
        # Adopt the partial if it has seen a value (it is the later
        # partition); otherwise keep the accumulator. Identity-respecting.
        if partial.seen:
            state = partial


# AvgF64 needs paired state (sum, count). PHASE-B uses SIMD[float64, 2]
# as a fixed-size paired carrier (no nested struct — matches the spike's
# "InlineArray[Float64, 2] per bucket" gap6-safe pattern from H2O §6
# lines 332-380).
@fieldwise_init
struct AvgF64(HashAggOpF64):
    """Average over Float64. StateTy = SIMD[float64, 2] (lane 0 = sum,
    lane 1 = count). finalize emits sum/count."""

    comptime StateTy = SIMD[DType.float64, 2]

    @staticmethod
    @always_inline
    def init() -> SIMD[DType.float64, 2]:
        return SIMD[DType.float64, 2](0.0, 0.0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: SIMD[DType.float64, 2], value: Float64):
        state[0] = state[0] + value
        state[1] = state[1] + 1.0

    @staticmethod
    @always_inline
    def finalize(state: SIMD[DType.float64, 2]) -> Float64:
        if state[1] == 0.0:
            return Float64(0.0)
        return state[0] / state[1]

    @staticmethod
    @always_inline
    def combine(mut state: SIMD[DType.float64, 2], partial: SIMD[DType.float64, 2]):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Paired (sum, count): combine adds both lanes."""
        state = state + partial


# -----------------------------------------------------------------------------
# MedianF64 — HashAggOpF64 conformer for AGG_MEDIAN over Float64 input
# -----------------------------------------------------------------------------
# ⛔⛔ NO PLAN ROUTE REACHES THIS CONFORMER (measured 2026-09-23 at five doors,
# W0 — see `MedianState`'s banner in
# `unified/agg/storage/aggregators_struct_builtin.mojo`). The h6 "truncates
# ~36% of each group's rows" trade-off below describes this dead kernel, not
# what any query runs: every live median keeps every value.
#
# LOWER-UNTYPED-AGG-MEDIAN-ARM — provides the
# `HashAggOpF64`-shaped wrapper around the existing `MedianState` /
# `MedianAggregator` semantics (per-group fixed-capacity inline reservoir
# of Float64 values; insertion-sort + middle-element pick on finalize).
#
# StateTy = `MedianState` (520 bytes; Int32 count + 4-byte pad +
# `InlineArray[Float64, 64]` = MAX_MEDIAN_VALUES values).  POD-only, no
# heap-owning inner field — gap6-safe by construction.  Trait method
# bodies are identical to `MedianAggregator.update` / `.finalize`; the
# `combine` method is not exposed at the HashAggOpF64 trait surface
# (combine is only needed for inter-partition merge, which v0.4 GA's
# single-table HashAgg substrate does NOT use — the per-group state
# accumulates linearly via update_scalar).
#
# Trade-off vs DuckDB's exact median: groups exceeding MAX_MEDIAN_VALUES
# (64) keep the FIRST-64 retention policy.  H2O h6 bench (~10K groups *
# ~100 rows/group on SF=1) truncates ~36% of each group's rows — the
# bench measures throughput, not byte-identical agreement with DuckDB.
# -----------------------------------------------------------------------------


@fieldwise_init
struct MedianF64(HashAggOpF64):
    """Median over Float64 — fixed-capacity inline reservoir (cap=64).

    StateTy = MedianState (520-byte POD: Int32 count + Int32 pad +
    InlineArray[Float64, 64]).  Update appends value if count < 64;
    otherwise drops (FIRST-64 retention).  Finalize insertion-sorts a
    local copy of the buffer and returns the middle element (odd n) or
    the average of the two middle elements (even n).  Returns NaN for
    empty state (count == 0).
    """

    comptime StateTy = MedianState

    @staticmethod
    @always_inline
    def init() -> MedianState:
        return MedianState()

    @staticmethod
    @always_inline
    def update_scalar(mut state: MedianState, value: Float64):
        # FIRST-64 retention — drop additional values once the buffer is
        # full.  Mirrors `MedianAggregator.update`.
        var c = Int(state.count)
        if c < MAX_MEDIAN_VALUES:
            state.values[c] = value
            state.count = Int32(c + 1)

    @staticmethod
    @always_inline
    def finalize(state: MedianState) -> Float64:
        # ⛔ THIS USED TO BE A SECOND, HAND-WRITTEN COPY of
        # `MedianAggregator.finalize`, and the two copies shipped the SAME
        # defect: a raw `buf[j] > key` insertion sort, which is FALSE for
        # every NaN comparison and therefore returned an ARRIVAL-ORDER
        # ARTIFACT on any NaN-bearing group (six distinct answers over the 720
        # permutations of {1,2,3,4,NaN,NaN}, NaN the 60% plurality).
        #
        # ⚠ NOT A SHIPPED WRONG ANSWER: measured 2026-09-15, neither this body
        # nor `MedianAggregator` is reachable from any plan route — every
        # occurrence outside their defining files and their own tests is a
        # comment. The live AGG_MEDIAN arms are `_ext_median_inplace` and
        # `MedianOp[dt].finalize`, both already NaN-last. Fixed anyway, and
        # collapsed to ONE body, so that a later re-wiring cannot resurrect it
        # in only one arm.
        #
        # There is now ONE body — `median_of_reservoir_nan_last` in
        # `unified/agg/storage/aggregators_struct_builtin.mojo`, which orders
        # NaN LAST under DuckDB's total order — and both call it. Do not
        # re-inline this. Returns NaN on empty (count == 0). The input `state`
        # is by-value at the trait surface and the helper takes a `.copy()`,
        # so byte-slab state is not mutated.
        return median_of_reservoir_nan_last(
            state.values.copy(), Int(state.count)
        )

    @staticmethod
    @always_inline
    def combine(mut state: MedianState, partial: MedianState):
        """UDF-EXPRX-MIGRATION — merge a partial per-bucket
        state. Reservoir: combine appends partial values up to
        MAX_MEDIAN_VALUES (FIRST-N retention, mirroring update_scalar)."""
        var c = Int(state.count)
        for j in range(Int(partial.count)):
            if c < MAX_MEDIAN_VALUES:
                state.values[c] = partial.values[j]
                c = c + 1
        state.count = Int32(c)


# -----------------------------------------------------------------------------
# LargestKF64 — HashAggOpF64 conformer for AGG_LARGEST_K (K=2) over Float64
# -----------------------------------------------------------------------------
# ERR-CAT-A-LARGEST-K-WIREUP — provides the
# `HashAggOpF64`-shaped wrapper around the existing `LargestKState` /
# `LargestKAggregator` semantics (per-group min-heap of top-K=2 Float64
# values; finalize emits the LARGER of the top-2).
#
# StateTy = `LargestKState` (24 bytes; Int32 count + Int32 pad +
# `InlineArray[Float64, 2]` heap). POD-only, no heap-owning inner field —
# gap6-safe by construction. Trait method bodies are identical to
# `LargestKAggregator.update` / `.combine` / `.finalize`.
#
# K is hardcoded to 2 — matches H2O h8 `largest2(v3)` query. Generalizing
# K parameter is deferred until a second consumer needs it.
# -----------------------------------------------------------------------------


@fieldwise_init
struct LargestKF64(HashAggOpF64):
    """LARGEST-K (K=2) over Float64 — per-group min-heap of top-2.

    StateTy = LargestKState (24-byte POD: Int32 count + Int32 pad +
    InlineArray[Float64, 2]). Update is a K=2 min-heap push (replace-and-
    sift-down on the single parent/child relationship). Finalize returns
    the LARGER of the top-2 (heap[1] when count==2; heap[0] when count==1;
    NaN when count==0). Mirrors `LargestKAggregator` semantics from
    `aggregators_struct_builtin.mojo`.
    """

    comptime StateTy = LargestKState

    @staticmethod
    @always_inline
    def init() -> LargestKState:
        return LargestKState()

    @staticmethod
    @always_inline
    def update_scalar(mut state: LargestKState, value: Float64):
        # K=2 min-heap push. Mirrors `LargestKAggregator.update`.
        var x = value
        if state.count == Int32(0):
            state.heap[0] = x
            state.count = Int32(1)
            return
        if state.count == Int32(1):
            state.heap[1] = x
            if state.heap[0] > state.heap[1]:
                var tmp = state.heap[0]
                state.heap[0] = state.heap[1]
                state.heap[1] = tmp
            state.count = Int32(2)
            return
        # count == 2: replace min if x is larger than current min.
        if x > state.heap[0]:
            state.heap[0] = x
            if state.heap[0] > state.heap[1]:
                var tmp = state.heap[0]
                state.heap[0] = state.heap[1]
                state.heap[1] = tmp

    @staticmethod
    @always_inline
    def finalize(state: LargestKState) -> Float64:
        # Return the LARGEST of the top-K (heap max). Mirrors
        # `LargestKAggregator.finalize`. Empty group returns NaN.
        if state.count == Int32(0):
            return Float64(0.0) / Float64(0.0)  # NaN
        if state.count == Int32(1):
            return state.heap[0]
        # count == 2: heap[1] is the larger (min-heap invariant).
        return state.heap[1]

    @staticmethod
    @always_inline
    def combine(mut state: LargestKState, partial: LargestKState):
        """Push donor's filled heap slots into accum (at most K pushes).
        Mirrors `LargestKAggregator.combine`."""
        if partial.count == Int32(0):
            return
        Self.update_scalar(state, partial.heap[0])
        if partial.count >= Int32(2):
            Self.update_scalar(state, partial.heap[1])


# -----------------------------------------------------------------------------
# StddevSampF64 — HashAggOpF64 conformer for AGG_STDDEV_SAMP over Float64
# -----------------------------------------------------------------------------
# ERR-CAT-A-STDDEV-WIREUP — provides the
# `HashAggOpF64`-shaped wrapper around the existing `WelfordState` /
# `StddevSampAggregator` semantics (per-group Welford one-pass
# recurrence; numerically stable for unbounded n).
#
# StateTy = `WelfordState` (24 bytes; UInt64 count + Float64 mean +
# Float64 m2). POD-only, no heap-owning inner field — gap6-safe by
# construction. Trait method bodies are identical to
# `StddevSampAggregator.update` / `.combine` / `.finalize`.
#
# Welford recurrences (single-pass):
#     count += 1
#     delta = x - mean
#     mean += delta / count
#     m2   += delta * (x - new_mean)
#
# stddev_samp finalize: sqrt(m2 / (count - 1)) for count > 1; NaN otherwise.
# -----------------------------------------------------------------------------


@fieldwise_init
struct StddevSampF64(HashAggOpF64):
    """Sample standard deviation over Float64 — Welford one-pass + Chan combine.

    StateTy = WelfordState (24-byte POD: UInt64 count + Float64 mean +
    Float64 m2). Update is the textbook 4-line Welford recurrence;
    combine is the Chan/Welford parallel-merge formula. Both are
    numerically stable for unbounded n. Mirrors `StddevSampAggregator`
    semantics from `aggregators_struct_builtin.mojo`.
    """

    comptime StateTy = WelfordState

    @staticmethod
    @always_inline
    def init() -> WelfordState:
        return WelfordState()

    @staticmethod
    @always_inline
    def update_scalar(mut state: WelfordState, value: Float64):
        # Welford one-pass: 4 fp ops + 1 integer increment. Numerically
        # stable for unbounded n. Mirrors `StddevSampAggregator.update`.
        state.count += UInt64(1)
        var delta = value - state.mean
        state.mean += delta / Float64(state.count)
        state.m2 += delta * (value - state.mean)

    @staticmethod
    @always_inline
    def finalize(state: WelfordState) -> Float64:
        # sqrt(m2 / (count - 1)) for count > 1; NaN otherwise. Mirrors
        # `StddevSampAggregator.finalize`. Empty/single-row groups return
        # NaN (DuckDB's NULL convention via Komira's NaN-as-NULL idiom).
        if state.count <= UInt64(1):
            return Float64(0.0) / Float64(0.0)  # NaN
        var n_minus_1 = Float64(state.count - UInt64(1))
        return sqrt(state.m2 / n_minus_1)

    @staticmethod
    @always_inline
    def combine(mut state: WelfordState, partial: WelfordState):
        """Chan/Welford parallel-merge formula. Mirrors
        `StddevSampAggregator.combine`. Identity-respecting (zero-count
        donor / accum is a no-op)."""
        if partial.count == UInt64(0):
            return
        if state.count == UInt64(0):
            state = partial
            return
        var n_a = Float64(state.count)
        var n_b = Float64(partial.count)
        var n = n_a + n_b
        var delta = partial.mean - state.mean
        # Update m2 BEFORE mean — formula uses old means.
        state.m2 = state.m2 + partial.m2 + delta * delta * n_a * n_b / n
        state.mean = (n_a * state.mean + n_b * partial.mean) / n
        state.count = state.count + partial.count


# =============================================================================
# §2 — HashAggOpI64 conformers — Sum / Count / Min / Max over Int64
# =============================================================================


@fieldwise_init
struct SumI64(HashAggOpI64):
    """Sum over Int64. StateTy = Int64."""

    comptime StateTy = Int64

    @staticmethod
    @always_inline
    def init() -> Int64:
        return Int64(0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Int64, value: Int64):
        state = state + value

    @staticmethod
    @always_inline
    def finalize(state: Int64) -> Int64:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Int64, partial: Int64):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running sum: combine adds the partials."""
        state = state + partial


@fieldwise_init
struct CountI64(HashAggOpI64):
    """Count-non-null over Int64. StateTy = Int64."""

    comptime StateTy = Int64

    @staticmethod
    @always_inline
    def init() -> Int64:
        return Int64(0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Int64, value: Int64):
        state = state + 1

    @staticmethod
    @always_inline
    def finalize(state: Int64) -> Int64:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Int64, partial: Int64):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running count: combine adds the partial counts."""
        state = state + partial


@fieldwise_init
struct MinI64(HashAggOpI64):
    """Min over Int64. StateTy = Int64 (init = Int64.MAX-equivalent
    via Int64(9223372036854775807))."""

    comptime StateTy = Int64

    @staticmethod
    @always_inline
    def init() -> Int64:
        return Int64(9223372036854775807)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Int64, value: Int64):
        if value < state:
            state = value

    @staticmethod
    @always_inline
    def finalize(state: Int64) -> Int64:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Int64, partial: Int64):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running min: combine keeps the smaller."""
        if partial < state:
            state = partial


@fieldwise_init
struct MaxI64(HashAggOpI64):
    """Max over Int64. StateTy = Int64 (init = Int64.MIN-equivalent
    via -Int64(9223372036854775807))."""

    comptime StateTy = Int64

    @staticmethod
    @always_inline
    def init() -> Int64:
        return -Int64(9223372036854775807) - Int64(1)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Int64, value: Int64):
        if value > state:
            state = value

    @staticmethod
    @always_inline
    def finalize(state: Int64) -> Int64:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Int64, partial: Int64):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running max: combine keeps the larger."""
        if partial > state:
            state = partial


# -----------------------------------------------------------------------------
# FIRST / LAST over Int64 — order-dependent value-pick (seen-flag state)
# -----------------------------------------------------------------------------
# AGG-FIRST-LAST — Int64 mirror of FirstF64 / LastF64. Same
# seen-flag semantics; integer-family input -> Int64 state+out (MIN/MAX
# native-drain convention). State = `FirstLastI64State` (POD, gap6-safe).
# -----------------------------------------------------------------------------


@fieldwise_init
struct FirstLastI64State(
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Per-bucket running-state for FIRST / LAST over Int64. Two POD fields;
    `seen` distinguishes the identity from a written value. Identity =
    (value=0, seen=False)."""

    var value: Int64
    var seen: Bool


@fieldwise_init
struct FirstI64(HashAggOpI64):
    """FIRST over Int64. StateTy = `FirstLastI64State`. Write-only-on-first-
    seen; combine keeps `a` if a.seen else takes `b`. ORDER-DEPENDENT."""

    comptime StateTy = FirstLastI64State

    @staticmethod
    @always_inline
    def init() -> FirstLastI64State:
        return FirstLastI64State(Int64(0), False)

    @staticmethod
    @always_inline
    def update_scalar(mut state: FirstLastI64State, value: Int64):
        if not state.seen:
            state.value = value
            state.seen = True

    @staticmethod
    @always_inline
    def finalize(state: FirstLastI64State) -> Int64:
        return state.value

    @staticmethod
    @always_inline
    def combine(mut state: FirstLastI64State, partial: FirstLastI64State):
        if not state.seen:
            state = partial


@fieldwise_init
struct LastI64(HashAggOpI64):
    """LAST over Int64. StateTy = `FirstLastI64State`. Always-overwrite;
    combine takes `b` if b.seen else keeps `a`. ORDER-DEPENDENT."""

    comptime StateTy = FirstLastI64State

    @staticmethod
    @always_inline
    def init() -> FirstLastI64State:
        return FirstLastI64State(Int64(0), False)

    @staticmethod
    @always_inline
    def update_scalar(mut state: FirstLastI64State, value: Int64):
        state.value = value
        state.seen = True

    @staticmethod
    @always_inline
    def finalize(state: FirstLastI64State) -> Int64:
        return state.value

    @staticmethod
    @always_inline
    def combine(mut state: FirstLastI64State, partial: FirstLastI64State):
        if partial.seen:
            state = partial


# =============================================================================
# §3 — HashAggOpI32 conformers — Sum / Count / Min / Max over Int32
# (U5-FOLLOWUP-ROUND2-I32-AGG-SUBSTRATE)
# =============================================================================
#
# Mirror of §2 I64 conformers with Int32 value + state types. Two's-complement
# wrap on SumI32 overflow — explicit widening is the SDK's job (cast to I64
# then use SumI64).
# =============================================================================


@fieldwise_init
struct SumI32(HashAggOpI32):
    """Sum over Int32. StateTy = Int32 (two's-complement wrap on overflow)."""

    comptime StateTy = Int32

    @staticmethod
    @always_inline
    def init() -> Int32:
        return Int32(0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Int32, value: Int32):
        state = state + value

    @staticmethod
    @always_inline
    def finalize(state: Int32) -> Int32:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Int32, partial: Int32):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running sum: combine adds the partials."""
        state = state + partial


@fieldwise_init
struct CountI32(HashAggOpI32):
    """Count-non-null over Int32. StateTy = Int32."""

    comptime StateTy = Int32

    @staticmethod
    @always_inline
    def init() -> Int32:
        return Int32(0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Int32, value: Int32):
        state = state + 1

    @staticmethod
    @always_inline
    def finalize(state: Int32) -> Int32:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Int32, partial: Int32):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running count: combine adds the partial counts."""
        state = state + partial


@fieldwise_init
struct MinI32(HashAggOpI32):
    """Min over Int32. StateTy = Int32 (init = Int32.MAX = 2147483647)."""

    comptime StateTy = Int32

    @staticmethod
    @always_inline
    def init() -> Int32:
        return Int32(2147483647)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Int32, value: Int32):
        if value < state:
            state = value

    @staticmethod
    @always_inline
    def finalize(state: Int32) -> Int32:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Int32, partial: Int32):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running min: combine keeps the smaller."""
        if partial < state:
            state = partial


@fieldwise_init
struct MaxI32(HashAggOpI32):
    """Max over Int32. StateTy = Int32 (init = -Int32.MAX - 1 = Int32.MIN)."""

    comptime StateTy = Int32

    @staticmethod
    @always_inline
    def init() -> Int32:
        return -Int32(2147483647) - Int32(1)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Int32, value: Int32):
        if value > state:
            state = value

    @staticmethod
    @always_inline
    def finalize(state: Int32) -> Int32:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Int32, partial: Int32):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running max: combine keeps the larger."""
        if partial > state:
            state = partial


# =============================================================================
# §4 — HashAggOpF32 conformers — Sum / Count / Min / Max over Float32
# (U5-FOLLOWUP-ROUND2-F32-AGG-SUBSTRATE)
# =============================================================================
#
# Mirror of §1 F64 conformers with Float32 value + state types. AvgF32
# deferred (filed `U5-FOLLOWUP-AVGF32` v0.5).
# =============================================================================


@fieldwise_init
struct SumF32(HashAggOpF32):
    """Sum over Float32. StateTy = Float32."""

    comptime StateTy = Float32

    @staticmethod
    @always_inline
    def init() -> Float32:
        return Float32(0.0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Float32, value: Float32):
        state = state + value

    @staticmethod
    @always_inline
    def finalize(state: Float32) -> Float32:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Float32, partial: Float32):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running sum: combine adds the partials."""
        state = state + partial


@fieldwise_init
struct CountF32(HashAggOpF32):
    """Count-non-null over Float32. StateTy = Float32 (count stored as
    Float32 for output-type uniformity, matching CountF64's pattern)."""

    comptime StateTy = Float32

    @staticmethod
    @always_inline
    def init() -> Float32:
        return Float32(0.0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Float32, value: Float32):
        state = state + 1.0

    @staticmethod
    @always_inline
    def finalize(state: Float32) -> Float32:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Float32, partial: Float32):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running count: combine adds the partial counts."""
        state = state + partial


@fieldwise_init
struct MinF32(HashAggOpF32):
    """Min over Float32. StateTy = Float32 (init = ~Float32.MAX-equivalent
    sentinel 3.4e38 to avoid NaN complexity; matches MinF64's 1e300 pattern)."""

    comptime StateTy = Float32

    @staticmethod
    @always_inline
    def init() -> Float32:
        return Float32(3.4e38)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Float32, value: Float32):
        if value < state:
            state = value

    @staticmethod
    @always_inline
    def finalize(state: Float32) -> Float32:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Float32, partial: Float32):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running min: combine keeps the smaller."""
        if partial < state:
            state = partial


@fieldwise_init
struct MaxF32(HashAggOpF32):
    """Max over Float32. StateTy = Float32 (init = -3.4e38 = ~Float32.MIN)."""

    comptime StateTy = Float32

    @staticmethod
    @always_inline
    def init() -> Float32:
        return Float32(-3.4e38)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Float32, value: Float32):
        if value > state:
            state = value

    @staticmethod
    @always_inline
    def finalize(state: Float32) -> Float32:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Float32, partial: Float32):
        """UDF-EXPRX-MIGRATION — merge a partial
        per-bucket state. Running max: combine keeps the larger."""
        if partial > state:
            state = partial


# =============================================================================
# §5 — KeyHashFn + KeyEqFn — generic FNV-1a hash + element-wise equality
# =============================================================================
#
# Pluggable hash + equality trait families consumed by CompositeHashTable
# (PHASE-B C7). Conformers ship one per CompositeKey arity (1..4); each
# delegates to the corresponding `hash_key_valueN` / `eq_key_valueN`
# helper from `komira_eval/composite_key.mojo`.
#
# Why per-arity conformers (vs a generic `KeyHashFn[N: Int]`):
#   Mojo trait conformers can't take an Int param to specialize
#   the trait method. Per-arity conformer structs are the canonical
#   workaround (matches the H2O spike's KeyHashFnv shape).
# =============================================================================


# Trait declarations
trait KeyHashFn1(Copyable, Movable, ImplicitlyCopyable):
    """Hash function over 1-component composite keys."""

    @staticmethod
    def hash(key: KeyValue1) -> UInt64: ...


trait KeyHashFn2(Copyable, Movable, ImplicitlyCopyable):
    """Hash function over 2-component composite keys (matches H2O spike
    KeyHashFnv shape)."""

    @staticmethod
    def hash(key: KeyValue2) -> UInt64: ...


trait KeyHashFn3(Copyable, Movable, ImplicitlyCopyable):
    """Hash function over 3-component composite keys."""

    @staticmethod
    def hash(key: KeyValue3) -> UInt64: ...


trait KeyHashFn4(Copyable, Movable, ImplicitlyCopyable):
    """Hash function over 4-component composite keys."""

    @staticmethod
    def hash(key: KeyValue4) -> UInt64: ...


trait KeyEqFn1(Copyable, Movable, ImplicitlyCopyable):
    """Equality function over 1-component composite keys."""

    @staticmethod
    def eq(a: KeyValue1, b: KeyValue1) -> Bool: ...


trait KeyEqFn2(Copyable, Movable, ImplicitlyCopyable):
    """Equality function over 2-component composite keys."""

    @staticmethod
    def eq(a: KeyValue2, b: KeyValue2) -> Bool: ...


trait KeyEqFn3(Copyable, Movable, ImplicitlyCopyable):
    """Equality function over 3-component composite keys."""

    @staticmethod
    def eq(a: KeyValue3, b: KeyValue3) -> Bool: ...


trait KeyEqFn4(Copyable, Movable, ImplicitlyCopyable):
    """Equality function over 4-component composite keys."""

    @staticmethod
    def eq(a: KeyValue4, b: KeyValue4) -> Bool: ...


# FNV-1a hash conformers (generic — work for any DType combination via
# the per-arity helper from composite_key.mojo)


@fieldwise_init
struct KeyHashFnv1(KeyHashFn1):
    """FNV-1a 64-bit hash over 1-component composite keys."""

    @staticmethod
    @always_inline
    def hash(key: KeyValue1) -> UInt64:
        return hash_key_value1(key)


@fieldwise_init
struct KeyHashFnv2(KeyHashFn2):
    """FNV-1a 64-bit hash over 2-component composite keys.
    Matches WSC-SPIKE-H2O KeyHashFnv shape."""

    @staticmethod
    @always_inline
    def hash(key: KeyValue2) -> UInt64:
        return hash_key_value2(key)


@fieldwise_init
struct KeyHashFnv3(KeyHashFn3):
    """FNV-1a 64-bit hash over 3-component composite keys."""

    @staticmethod
    @always_inline
    def hash(key: KeyValue3) -> UInt64:
        return hash_key_value3(key)


@fieldwise_init
struct KeyHashFnv4(KeyHashFn4):
    """FNV-1a 64-bit hash over 4-component composite keys."""

    @staticmethod
    @always_inline
    def hash(key: KeyValue4) -> UInt64:
        return hash_key_value4(key)


# Element-wise equality conformers
@fieldwise_init
struct KeyEqElementwise1(KeyEqFn1):
    """Element-wise equality over 1-component composite keys."""

    @staticmethod
    @always_inline
    def eq(a: KeyValue1, b: KeyValue1) -> Bool:
        return eq_key_value1(a, b)


@fieldwise_init
struct KeyEqElementwise2(KeyEqFn2):
    """Element-wise equality over 2-component composite keys.
    Generalization of WSC-SPIKE-H2O KeyEqStringInt64."""

    @staticmethod
    @always_inline
    def eq(a: KeyValue2, b: KeyValue2) -> Bool:
        return eq_key_value2(a, b)


@fieldwise_init
struct KeyEqElementwise3(KeyEqFn3):
    """Element-wise equality over 3-component composite keys."""

    @staticmethod
    @always_inline
    def eq(a: KeyValue3, b: KeyValue3) -> Bool:
        return eq_key_value3(a, b)


@fieldwise_init
struct KeyEqElementwise4(KeyEqFn4):
    """Element-wise equality over 4-component composite keys."""

    @staticmethod
    @always_inline
    def eq(a: KeyValue4, b: KeyValue4) -> Bool:
        return eq_key_value4(a, b)
