# =============================================================================
# AggKernel — kernel-math umbrella trait (Phase 7 Mojo)
# =============================================================================
#
# Phase 7 collapses the prior `Aggregator` + `AggregatorWithStruct`
# sibling traits into ONE umbrella trait, `AggKernel`. The variant tag (scalar
# State vs typed StateStruct) is now expressed via `comptime if conforms_to(Agg,
# AggregatorWithStruct)` at the storage layer, NOT via `IS_NOOP` / `IS_STRUCT`
# sentinels on each impl. Variadic `*Aggs: AggKernel` dispatch at the sink
# template replaces the 8-positional `A0..A7 = NoOpAggregator` template; the
# variadic length IS the active count, so `NoOpAggregator` is gone.
#
# Backwards-compat: `Aggregator` is exposed as a TYPE ALIAS for `AggKernel`,
# allowing the 8 builtin impls + the AggregatorWithStruct sibling trait to
# refine through it without source churn at every conformer site.
#
# Trait shape:
#   - `alias StateDType: DType`         — kernel state element type
#   - `alias InputDType: DType`         — column-input element type
#   - `alias OutputDType: DType`        — finalize-output element type
#   - `init() -> Scalar[StateDType]`    — fresh per-group state
#   - `update(mut s, x)`                — scalar update
#   - `update_batch[N](mut ss, xs)`     — SIMD update; default loops scalar
#   - `combine(mut a, b)`               — parallel-merge formula
#   - `finalize(s) -> Scalar[OutputDType]` — final value
#
# References:
# - Phase 7 dispatch plan (maintainer directive).
#   - an internal doc (Repro 25
#     verifies trait-default-impl + comptime fan-out + override composition).
#   - an internal doc §3.0b / §6.8a.
# =============================================================================


trait AggKernel(Movable, Deinitable):
    """Owns kernel math, NOT storage layout.

    The trait surface is comptime-resolved: each aggregator impl monomorphizes
    its own kernel body, and the storage path (AoS thunk wrapper or Slab
    `commit_batch[KeyT, AggSpec]`) invokes those static methods directly.

    Trait shape (Phase 7 freeze, Mojo):
      - `alias StateDType: DType`         — kernel state element type
      - `alias InputDType: DType`         — column-input element type
      - `alias OutputDType: DType`        — finalize-output element type
      - `init() -> Scalar[StateDType]`    — fresh per-group state
      - `update(mut s, x)`                — scalar update
      - `update_batch[N](mut ss, xs)`     — SIMD update; default loops scalar
      - `combine(mut a, b)`               — parallel-merge formula
      - `finalize(s) -> Scalar[OutputDType]` — final value

    DType-bounded State accommodates the 8 SIMD-vectorizable scalar kernels
    (SumF64, SumI64, CountStar, MinF64, MaxF64, MinI64, MaxI64, AvgF64).
    Multi-field-state kernels (Welford-shape stddev/var, largest_k heap, etc.)
    additionally conform to `AggregatorWithStruct` (which refines `AggKernel`
    with `StateStruct: ...`); the storage layer branches via
    `comptime if conforms_to(Agg, AggregatorWithStruct)`.

    Movable + Deinitable matches the v4.1 trait quartet. Storage
    path flows aggs through worker-pool state during sink local/global
    lifecycle.

    NOTE on `IS_NOOP`: removed in Phase 7. The variadic `*Aggs: AggKernel`
    pack length IS the active count; there is no inactive sentinel slot to
    elide. The `NoOpAggregator` placeholder is gone.

    Caveat from Repro 25 (load-bearing):
      The default `update_batch[N]` body must use `var s = states[i];
      Self.update(s, inputs[i]); states[i] = s` (not `Self.update(states[i],
      inputs[i])` directly). SIMD lane access via `[i]` returns by value;
      passing the lane to `update` does NOT propagate the mutation back
      into the SIMD register. The var-roundtrip is mandatory.
    """

    # -------------------------------------------------------------------
    # Associated types — DType-bounded for SIMD-vectorizable kernels.
    # -------------------------------------------------------------------

    comptime StateDType: DType
    """Kernel state element type. Float64 for SUM/MIN/MAX/AVG;
    UInt64 for COUNT; Int64 for SUM[Int64] / MIN[Int64] / MAX[Int64].
    """

    comptime InputDType: DType
    """Column input element type. Float64 for SUM(Float64);
    Int64 for SUM(Int64); Bool placeholder for CountStar.
    """

    comptime OutputDType: DType
    """Finalize output element type. Usually equals StateDType for
    SUM/MIN/MAX/COUNT; differs for AVG (sum/count -> divided Float64).
    """

    # -------------------------------------------------------------------
    # Lifecycle methods — static; called by storage path comptime.
    # -------------------------------------------------------------------

    @staticmethod
    def init() -> Scalar[Self.StateDType]:
        """Fresh per-group state at hash-table insert time.

        SUM: 0.0 (Float64) or 0 (Int64). MIN: Float64.MAX (saturating).
        MAX: Float64.MIN. COUNT: 0 (UInt64).
        """
        ...

    @staticmethod
    def update(
        mut state: Scalar[Self.StateDType],
        input: Scalar[Self.InputDType],
    ):
        """Scalar update: mutate state in place using one input row.

        Examples:
          SUM:    s += x
          COUNT:  s += 1  (input ignored)
          MIN:    if x < s: s = x
          MAX:    if x > s: s = x
        """
        ...

    @staticmethod
    def update_batch[
        N: Int
    ](
        mut states: SIMD[Self.StateDType, N],
        inputs: SIMD[Self.InputDType, N],
    ):
        """SIMD batch update over N lanes.

        Default impl loops scalar `update` over the SIMD lanes. Phase H's
        per-(agg_fn, T) hand-staged specialization OVERRIDES this body
        with `addpd ymm` (x86 AVX-2) / `fadd v.2d` (ARM64 NEON) per
        Repro 28 evidence (autovectorizer does NOT fire on unit-stride
        += loops in Mojo).

        Repro 25 caveat: SIMD lane access via `[i]` returns the lane by
        VALUE. Passing `states[i]` to `update` mutates a temporary and
        the change does NOT propagate to the SIMD register. The
        `var s = states[i]; Self.update(s, ...); states[i] = s`
        roundtrip is mandatory for the default impl to produce correct
        results.
        """
        comptime for i in range(N):
            var s = states[i]
            Self.update(s, inputs[i])
            states[i] = s

    @staticmethod
    def combine(
        mut a: Scalar[Self.StateDType],
        b: Scalar[Self.StateDType],
    ):
        """Parallel-merge formula. Used during finalize-segment combine.

        SUM/COUNT: a += b. MIN: a = min(a, b). MAX: a = max(a, b).
        AVG: combine sum + combine count separately (per AvgF64 impl).
        """
        ...

    @staticmethod
    def finalize(
        state: Scalar[Self.StateDType],
    ) -> Scalar[Self.OutputDType]:
        """Convert final state to output value.

        SUM/COUNT/MIN/MAX: passthrough (state IS the output).
        AVG: divide sum by count (post-merge).
        """
        ...


# -----------------------------------------------------------------------------
# Backwards-compat alias: `Aggregator = AggKernel`
# -----------------------------------------------------------------------------
#
# The pre-Phase-7 name `Aggregator` is preserved as a type alias for
# `AggKernel` so the 8 builtin impls in `aggregators_builtin.mojo` continue
# to declare `(Aggregator, ...)` conformance without source churn. New code
# should prefer `AggKernel`.
# -----------------------------------------------------------------------------

comptime Aggregator = AggKernel


# -----------------------------------------------------------------------------
# _TestProbeAggregator — minimal AggKernel impl for trait-conformance tests
# -----------------------------------------------------------------------------
#
# Phase 7 replaces the prior `NoOpAggregator` placeholder. The cascade-probe
# tests (`test_no_op_aggregator_conforms`) used `NoOpAggregator` as a stand-in
# to verify the trait surface compiles + dispatches; with `IS_NOOP` removed
# and the variadic dispatch model, the placeholder still serves the
# trait-conformance smoke test. Production hot path uses the real impls in
# `aggregators_builtin.mojo`.
# -----------------------------------------------------------------------------


struct _TestProbeAggregator(AggKernel, Movable, Deinitable):
    """Minimal AggKernel impl for trait-conformance smoke tests only.

    State / Input / Output are all UInt8. All methods are no-ops (state stays
    at 0; updates do nothing; finalize returns input). Used by the
    cascade-probe tests; never on a production hot path.
    """

    var _phantom: UInt8
    """Mojo requires structs to have at least one field for non-default
    layout-respecting moves. Single byte; zero practical cost.
    """

    comptime StateDType = DType.uint8
    comptime InputDType = DType.uint8
    comptime OutputDType = DType.uint8

    def __init__(out self):
        self._phantom = UInt8(0)

    @staticmethod
    def init() -> Scalar[DType.uint8]:
        return 0

    @staticmethod
    def update(mut state: Scalar[DType.uint8], input: Scalar[DType.uint8]):
        # No-op.
        pass

    @staticmethod
    def combine(mut a: Scalar[DType.uint8], b: Scalar[DType.uint8]):
        # No-op.
        pass

    @staticmethod
    def finalize(state: Scalar[DType.uint8]) -> Scalar[DType.uint8]:
        return state
