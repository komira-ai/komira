# =============================================================================
# aggregators_struct_builtin — AggregatorWithStruct reference impls (Item 19a)
# =============================================================================
#
# Sibling of `aggregators_builtin.mojo`. Item 19a-impl lands ONE reference
# impl (`StddevSampAggregator` with 24-byte `WelfordState`) to prove the
# `AggregatorWithStruct` trait shape composes end-to-end through the
# storage layer.
#
# Item 19b dispatches add the H2O kernel impls (stddev_pop, var_samp,
# var_pop, corr, median, largest_k) — each in their own file or this file
# extended in-place, depending on kernel-specific helper LOC.
#
# References:
#   - an internal doc §3.1, §6.1
#   - komira-mojo/src/komira_engine_operators/unified/agg/storage/aggregator_with_struct_trait.mojo
# =============================================================================

from std.math import sqrt

from komira_engine_operators.unified.agg.storage.aggregator_with_struct_trait import (
    AggregatorWithStruct,
)


# -----------------------------------------------------------------------------
# WelfordState — 24-byte per-group state for stddev / variance kernels
# -----------------------------------------------------------------------------
#
# Per design doc §6.1: 3 fields packed into 24 bytes (8 + 8 + 8). gap6-safe
# by construction: Movable + Deinitable quartet, all primitive
# scalar fields, no heap-owning subfields. The `StateStruct` constraints in
# `AggregatorWithStruct` are satisfied: no List, String, OwnedPointer,
# ArcPointer, or wildcard-origin pointers.
#
# Field order (count, mean, m2) matches the canonical Welford/Chan parallel-
# merge formulation; STATE_BYTES = 24 is `sizeof[UInt64]() + 2 *
# sizeof[Float64]()` and equals what Mojo lays out for the struct (the
# stride math at the storage layer asserts this matches at runtime).
#
# Welford recurrences (single-pass):
#     count += 1
#     delta = x - mean
#     mean += delta / count
#     m2   += delta * (x - new_mean)
#
# Chan/Welford parallel merge (combine):
#     n   = a.count + b.count
#     dx  = b.mean - a.mean
#     a.mean = (a.count*a.mean + b.count*b.mean) / n
#     a.m2  += b.m2 + dx*dx * a.count * b.count / n
#     a.count = n
#
# stddev_samp finalize: sqrt(m2 / (count - 1)) for count > 1; NaN otherwise.
# -----------------------------------------------------------------------------


struct WelfordState(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Per-group state for Welford-recurrence kernels (stddev / variance).

    Shape: 24 bytes total (count: UInt64, mean: Float64, m2: Float64).

    Copyable + ImplicitlyCopyable + Movable + Deinitable — all
    fields are primitive scalars; the trait quartet is auto-derivable.
    ImplicitlyCopyable is required so `accum = donor` inside `combine`
    (the early-out for accum.count == 0) compiles without an explicit
    `^` move (donor must remain readable after the assignment for the
    typical caller pattern that re-uses donor on subsequent iterations).
    """

    var count: UInt64
    var mean: Float64
    var m2: Float64

    @always_inline
    def __init__(out self):
        """Zero-init: count=0, mean=0.0, m2=0.0.

        This is the identity for Welford merge: combining any state with a
        zero-init state yields the original state. (See `combine` below;
        the `donor.count == 0` early-out preserves this.)
        """
        self.count = UInt64(0)
        self.mean = Float64(0.0)
        self.m2 = Float64(0.0)

    @always_inline
    def __init__(out self, count: UInt64, mean: Float64, m2: Float64):
        """Explicit-field construction.

        Used by combine and tests; not on the per-row hot path.
        """
        self.count = count
        self.mean = mean
        self.m2 = m2


# -----------------------------------------------------------------------------
# StddevSampAggregator — sample standard deviation
# -----------------------------------------------------------------------------
#
# DuckDB `stddev_samp(x)`: sample standard deviation with Bessel's correction
# (n-1 in the denominator). Returns NaN when count <= 1 (DuckDB returns NULL;
# Komira has no NULL today, NaN surfaces the edge to the SDK layer for
# downstream NULL-mapping).
#
# Mathematically equivalent to `sqrt(var_samp(x))`. var_samp / stddev_pop /
# var_pop are clones with `finalize` differing — they share `WelfordState`,
# `init`, `update`, `combine`. Item 19b Phase 1 lands them alongside.
# -----------------------------------------------------------------------------


struct StddevSampAggregator(
    AggregatorWithStruct, Copyable, Movable, Deinitable
):
    """Sample standard deviation kernel — Welford one-pass + Chan combine.

    State: `WelfordState` (24 bytes; count, mean, m2).
    Input: Float64.
    Output: Float64.

    finalize: `sqrt(m2 / (count - 1))` for count > 1; NaN otherwise.

    Per-row update is the textbook 4-line Welford recurrence; combine is
    the Chan/Welford parallel-merge formula. Both are numerically stable
    for unbounded n (no naive `sum_xx - sum_x^2 / n` cancellation).
    """

    var _phantom: UInt8
    """Mojo requires structs with at least one non-static field for non-
    default layout-respecting moves. Single byte; zero practical cost."""

    comptime StateStruct = WelfordState
    comptime InputDType = DType.float64
    comptime OutputDType = DType.float64
    comptime STATE_BYTES = 24
    """Sizeof(WelfordState) = 8 (UInt64) + 8 (Float64) + 8 (Float64).

    Asserted at storage construction time against
    `sizeof[WelfordState]()`. If the struct ever grows (alignment-pad,
    field add), STATE_BYTES MUST be updated in lockstep — the bitcast
    through `_agg_slab_<AggIdx>` byte-Slab is comptime-typed but the
    stride math is runtime-driven by this constant.
    """

    def __init__(out self):
        self._phantom = UInt8(0)

    # -------------------------------------------------------------------
    # Lifecycle methods
    # -------------------------------------------------------------------

    @always_inline
    @staticmethod
    def init() -> WelfordState:
        return WelfordState()

    @always_inline
    @staticmethod
    def update(mut state: WelfordState, input: Scalar[DType.float64]):
        """Welford one-pass: 4 floating-point ops + 1 integer increment.

        Numerically stable for unbounded n. The recurrence is:
            count := count + 1
            delta := x - mean_old
            mean  := mean_old + delta / count
            m2    := m2_old   + delta * (x - mean_new)

        This is what every textbook (Knuth Vol. 2, §4.2.2) writes; the
        combination of `delta * (x - mean_new)` (vs. `delta * delta`) is
        the load-bearing trick — using the post-update mean keeps the
        sum-of-squares-of-deviations correct for the running mean shift.
        """
        state.count += UInt64(1)
        var delta = Float64(input) - state.mean
        state.mean += delta / Float64(state.count)
        state.m2 += delta * (Float64(input) - state.mean)

    @always_inline
    @staticmethod
    def combine(mut accum: WelfordState, donor: WelfordState):
        """Chan/Welford parallel-merge formula.

        Mathematically equivalent to `init` followed by in-order `update`
        over the union of accum's + donor's input rows. Numerically stable.

        The two early-outs (donor.count == 0, accum.count == 0) preserve
        the identity element semantics of zero-init state: combining with
        a zero-init state is a no-op.
        """
        if donor.count == UInt64(0):
            return
        if accum.count == UInt64(0):
            accum = donor
            return
        var n_a = Float64(accum.count)
        var n_b = Float64(donor.count)
        var n = n_a + n_b
        var delta = donor.mean - accum.mean
        # Update m2 BEFORE mean — the formula uses old means.
        accum.m2 = accum.m2 + donor.m2 + delta * delta * n_a * n_b / n
        accum.mean = (n_a * accum.mean + n_b * donor.mean) / n
        accum.count = accum.count + donor.count

    @always_inline
    @staticmethod
    def finalize(state: WelfordState) -> Scalar[DType.float64]:
        """Sqrt(m2 / (count - 1)) for count > 1; NaN otherwise.

        DuckDB `stddev_samp` returns NULL when count <= 1; Komira has no
        NULL today, so we return Float64.nan and let the SDK layer
        downstream-map to NULL if needed. The count == 0 case (no rows for
        the group) and count == 1 case (single row, sample stddev
        undefined) both produce NaN — same as DuckDB's NULL.

        For count == 0, the body would compute m2 / -1 = -0.0 followed by
        sqrt(-0.0) = -0.0 — incorrect (should be NaN, not zero). The
        guard is required; do NOT remove without re-checking the count==0
        branch.
        """
        if state.count <= UInt64(1):
            # NaN via 0.0 / 0.0; Mojo produces a quiet NaN here.
            # (Float64.__nan__() is not exposed; this is the canonical
            # constant-NaN idiom across komira-mojo.)
            return Float64(0.0) / Float64(0.0)
        var n_minus_1 = Float64(state.count - UInt64(1))
        return sqrt(state.m2 / n_minus_1)


# -----------------------------------------------------------------------------
# PopulationWelfordFinalize — the ddof=0 half of the SAME WelfordState
# -----------------------------------------------------------------------------
#
# ★★ SQL-AGG-SERVE-2,.
# THREE FINALIZES, NO NEW STATE AND NO NEW MERGE. `var_pop` / `stddev_pop` /
# `sem` read the SAME `[count | mean | m2]` that `StddevSampAggregator` folds
# and Chan-merges above; they differ from it ONLY in the divisor. They live
# HERE, beside the sample finalize, precisely so the divisor difference is
# visible in one screen instead of being re-derived at a call site.
#
# ⛔⛔ AND `sem` IS **POPULATION**-BASED ON DuckDB v1.5.3 — THE ONE THING IN
# THIS FAMILY THAT CANNOT BE REASONED OUT AND HAD TO BE RUN. The textbook
# standard error of the mean is `stddev_SAMP / sqrt(n)`, and the
# `sql_fn_table._R_AGGPOPFIN` refusal row that this wave deleted stated exactly
# that: `sqrt(M2 / (count - 1)) / sqrt(count)`. MEASURED v1.5.3 over
# `{1, 2, 3, 4, 10}`:
#
#     sem(v)                        1.4142135623730951
#     stddev_pop(v) / sqrt(5)       1.4142135623730951   <- MATCHES
#     stddev_samp(v) / sqrt(5)      1.5811388300841895   <- the reason's formula
#
# An implementation written from the refusal row's own sentence is WRONG on
# every group of size > 1..
# -----------------------------------------------------------------------------


struct PopulationWelfordFinalize(Copyable, Movable, Deinitable):
    """ddof=0 finalizes over `WelfordState`. Stateless; methods are static."""

    var _phantom: UInt8
    """Mojo requires at least one non-static field for a layout-respecting
    move. Single byte; zero practical cost — same shape as the aggregators."""

    @always_inline
    def __init__(out self):
        self._phantom = UInt8(0)

    @always_inline
    @staticmethod
    def var_pop(state: WelfordState) -> Scalar[DType.float64]:
        """`m2 / count`. NaN at count == 0 (the DuckDB-NULL idiom).

        ⚠ AT count == 1 THIS IS A NON-NULL 0.0, where `StddevSampAggregator`
        above is NaN. MEASURED v1.5.3 over a singleton group: `var_pop` = 0.0
        and `var_samp` IS NULL. One shared `count <= 1` guard converts one."""
        if state.count == UInt64(0):
            return Float64(0.0) / Float64(0.0)
        return state.m2 / Float64(state.count)

    @always_inline
    @staticmethod
    def stddev_pop(state: WelfordState) -> Scalar[DType.float64]:
        """`sqrt(m2 / count)`. NaN at count == 0; 0.0 at count == 1."""
        if state.count == UInt64(0):
            return Float64(0.0) / Float64(0.0)
        return sqrt(state.m2 / Float64(state.count))

    @always_inline
    @staticmethod
    def sem(state: WelfordState) -> Scalar[DType.float64]:
        """`stddev_pop / sqrt(count)` = `sqrt(m2) / count`. NaN at count == 0.

        ⛔ THE DIVISOR IS `count`, NOT `count - 1`. See the banner above: this
        is the ONE member of the family whose definition had to be MEASURED
        rather than derived, and the plausible textbook reading is wrong."""
        if state.count == UInt64(0):
            return Float64(0.0) / Float64(0.0)
        var n = Float64(state.count)
        return sqrt(state.m2 / n) / sqrt(n)


# -----------------------------------------------------------------------------
# CountAggregator — non-null row count (Phase G G.2 Day 2)
# -----------------------------------------------------------------------------
#
# A simple count-of-non-null aggregator that conforms to
# `AggregatorWithStruct`. Unlike the scalar `CountStar` (in
# `aggregators_builtin.mojo`), this lives on the struct-state sink so it
# can be folded into multi-aggregator dispatches that include other
# struct-state kernels (e.g. PS2: stddev_samp + count).
#
# `update` ignores the input value and unconditionally increments the
# counter; downstream NULL-handling lives at the SDK layer (Komira has
# no NULL today). Output is Int64 to match the planner's COUNT field
# inference (`_infer_agg_field`: COUNT -> ArrowType.INT64).
#
# The 8-byte state shape (single UInt64 counter) overlaps with the
# scalar AggKernel CountStar shape; the difference is only the trait
# binding. If a future SIMD specialization wants to vectorize counts,
# do that on the AggKernel sibling, not here.
# -----------------------------------------------------------------------------


struct CountState(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Per-group state for `CountAggregator` — a single UInt64 counter.

    8 bytes total. Movable + Deinitable (auto-derived; the
    field is a primitive scalar). Same gap6 audit as `WelfordState`.
    """

    var count: UInt64

    @always_inline
    def __init__(out self):
        """Zero-init. Identity element for combine."""
        self.count = UInt64(0)


struct CountAggregator(
    AggregatorWithStruct, Copyable, Movable, Deinitable
):
    """Non-null row count kernel (struct-state variant).

    State: `CountState` (8 bytes; UInt64 counter).
    Input: any DType (the `update` body ignores its argument). Bound to
    `Int64` here so the storage layer's `_commit_slot_partitioned_with_struct`
    routes through the Int64 column extraction path; a future widening
    can flip the bound or refactor commit to skip per-row reads on
    count-shaped kernels.
    Output: Int64 (matches `_infer_agg_field` for AGG_COUNT).

    finalize: `state.count` cast to Int64.
    """

    var _phantom: UInt8
    """Mojo requires structs with at least one non-static field for
    non-default layout-respecting moves. Single byte; zero practical
    cost."""

    comptime StateStruct = CountState
    comptime InputDType = DType.int64
    comptime OutputDType = DType.int64
    comptime STATE_BYTES = 8
    """Sizeof(CountState) = 8 (single UInt64 counter)."""

    def __init__(out self):
        self._phantom = UInt8(0)

    # -------------------------------------------------------------------
    # Lifecycle methods
    # -------------------------------------------------------------------

    @always_inline
    @staticmethod
    def init() -> CountState:
        return CountState()

    @always_inline
    @staticmethod
    def update(mut state: CountState, input: Scalar[DType.int64]):
        """Increment counter; ignore the input value.

        Komira has no NULL today, so every row counts. Future NULL-aware
        impl would consult a validity bitmap before incrementing.
        """
        _ = input
        state.count += UInt64(1)

    @always_inline
    @staticmethod
    def combine(mut accum: CountState, donor: CountState):
        """Sum counts. Identity-respecting (donor.count == 0 is a no-op
        but the unconditional add is cheaper than an early-out branch
        on the per-group hot path)."""
        accum.count += donor.count

    @always_inline
    @staticmethod
    def finalize(state: CountState) -> Scalar[DType.int64]:
        """Return state.count as Int64."""
        return state.count.cast[DType.int64]()


# -----------------------------------------------------------------------------
# CorrelationState — 48-byte per-group state for Pearson correlation
# -----------------------------------------------------------------------------
#
# Bivariate Welford / Chan online recurrence for Pearson r = C / sqrt(Sx * Sy).
# Per-group state is 48 bytes:
#   n: UInt64        # row count
#   mean_x: Float64  # running mean of x
#   mean_y: Float64  # running mean of y
#   C: Float64       # sum of (x - mean_x)(y - mean_y) -- co-moment
#   Sx: Float64      # sum of squared deviations of x
#   Sy: Float64      # sum of squared deviations of y
#
# Welford online update (single row, x = Float64(v1), y = Float64(v2)):
#     n += 1
#     dx = x - mean_x
#     dy = y - mean_y
#     mean_x += dx / n
#     mean_y += dy / n
#     C += dx * (y - mean_y)         # NOTE: NEW mean_y (after update)
#     Sx += dx * (x - mean_x)        # NOTE: NEW mean_x
#     Sy += dy * (y - mean_y)        # NOTE: NEW mean_y
#
# Chan parallel-merge (combine `b` into `self`, n_a + n_b > 0):
#     delta_x = b.mean_x - self.mean_x
#     delta_y = b.mean_y - self.mean_y
#     factor = n_a * n_b / (n_a + n_b)
#     self.C  += b.C  + delta_x * delta_y * factor
#     self.Sx += b.Sx + delta_x * delta_x * factor
#     self.Sy += b.Sy + delta_y * delta_y * factor
#     self.mean_x += delta_x * n_b / (n_a + n_b)
#     self.mean_y += delta_y * n_b / (n_a + n_b)
#     self.n += b.n
#
# finalize → r = C / sqrt(Sx * Sy); NaN if n == 0 or the denominator is 0
#   (AGG-0KEY: the degenerate arm was 0.0, which is an ANSWER and
#   not a sentinel. DuckDB v1.5.3 returns NaN for n==1 and for a constant
#   column, and NULL only for n==0 — measured).
# -----------------------------------------------------------------------------


struct CorrelationState(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Per-group state for `CorrelationAggregator` — bivariate Welford.

    Shape: 48 bytes total (count + 2*means + co-moment + 2*sum-of-sq-devs).
    All primitive scalar fields; the trait quartet is auto-derivable.
    Same gap6 audit as `WelfordState`.
    """

    var n: UInt64
    var mean_x: Float64
    var mean_y: Float64
    var C: Float64
    var Sx: Float64
    var Sy: Float64

    @always_inline
    def __init__(out self):
        """Zero-init: identity element for combine."""
        self.n = UInt64(0)
        self.mean_x = Float64(0.0)
        self.mean_y = Float64(0.0)
        self.C = Float64(0.0)
        self.Sx = Float64(0.0)
        self.Sy = Float64(0.0)


# -----------------------------------------------------------------------------
# CorrelationAggregator — Pearson correlation (Item 19b H2O Q9)
# -----------------------------------------------------------------------------
#
# Bivariate aggregator: takes TWO Float64 inputs per row (x, y). The
# `AggregatorWithStruct` trait surface is unary — `update(state, value)`.
# To reuse the existing trait machinery (init/combine/finalize) without
# inventing a parallel `AggregatorWithStruct2Input` trait, this kernel:
#   - Conforms to AggregatorWithStruct with InputDType = Float64 (x dim).
#   - Provides a NON-trait `update_bivariate(state, x, y)` static method
#     that the dedicated `SlabHashAggSinkStructCorr` calls directly.
#   - The trait `update(state, x)` is a no-op safeguard that raises if
#     ever invoked through the variadic struct sink (never wired).
#
# This is the design the maintainer dispatch authorized: "bypass the trait's
# generic dispatch for CORR — the kernel already knows the type."
# -----------------------------------------------------------------------------


struct CorrelationAggregator(
    AggregatorWithStruct, Copyable, Movable, Deinitable
):
    """Pearson correlation kernel — bivariate Welford + Chan combine.

    State: `CorrelationState` (48 bytes).
    Input: 2x Float64 (x and y dimensions).
    Output: Float64 (r = C / sqrt(Sx * Sy)).
    """

    var _phantom: UInt8
    """Placeholder field — Mojo requires non-static field for non-default
    layout-respecting moves."""

    comptime StateStruct = CorrelationState
    comptime InputDType = DType.float64
    """X dimension. Y dim is taken via `update_bivariate`'s second arg
    (NOT via the trait surface). The variadic struct sink's
    `_commit_slot_partitioned_with_struct` would route Float64 through
    this kernel's trait `update` if ever called — we guard with a no-op
    body since CORR is dispatched through the dedicated
    `SlabHashAggSinkStructCorr` sink."""
    comptime OutputDType = DType.float64
    comptime STATE_BYTES = 48
    """Sizeof(CorrelationState) = 8 (UInt64) + 5 * 8 (Float64) = 48."""

    def __init__(out self):
        self._phantom = UInt8(0)

    # -------------------------------------------------------------------
    # Lifecycle methods
    # -------------------------------------------------------------------

    @always_inline
    @staticmethod
    def init() -> CorrelationState:
        return CorrelationState()

    @always_inline
    @staticmethod
    def update(mut state: CorrelationState, input: Scalar[DType.float64]):
        """Trait-required UNARY update — UNUSED for CORR.

        The variadic `SlabHashAggSinkStruct` would call this with one
        Float64 if CORR were wired through it; we don't do that. The
        dedicated `SlabHashAggSinkStructCorr` calls
        `update_bivariate(state, x, y)` directly. Body is a no-op so
        accidental calls don't corrupt state — they just don't accumulate.
        """
        _ = state
        _ = input

    @always_inline
    @staticmethod
    def update_bivariate(
        mut state: CorrelationState,
        x: Float64,
        y: Float64,
    ):
        """Welford bivariate one-pass: 6 floating-point ops + 1 increment.

        Numerically stable for unbounded n. The recurrence is the
        textbook Welford bivariate form (see e.g. Chan, Golub, LeVeque
        1979; Pebay 2008):
            n     := n + 1
            dx    := x - mean_x_old
            dy    := y - mean_y_old
            mean_x := mean_x_old + dx / n
            mean_y := mean_y_old + dy / n
            C     := C  + dx * (y - mean_y_new)
            Sx    := Sx + dx * (x - mean_x_new)
            Sy    := Sy + dy * (y - mean_y_new)
        """
        state.n += UInt64(1)
        var inv_n = Float64(1.0) / Float64(state.n)
        var dx = x - state.mean_x
        var dy = y - state.mean_y
        state.mean_x += dx * inv_n
        state.mean_y += dy * inv_n
        # Use the NEW means for the cross/squared-dev updates.
        state.C += dx * (y - state.mean_y)
        state.Sx += dx * (x - state.mean_x)
        state.Sy += dy * (y - state.mean_y)

    @always_inline
    @staticmethod
    def combine(
        mut accum: CorrelationState, donor: CorrelationState
    ):
        """Chan parallel-merge for bivariate Welford.

        Combine donor into accum. Numerically stable; preserves the
        identity element semantics (zero-init donor or accum is a no-op).
        """
        if donor.n == UInt64(0):
            return
        if accum.n == UInt64(0):
            accum = donor
            return
        var n_a = Float64(accum.n)
        var n_b = Float64(donor.n)
        var n_ab = n_a + n_b
        var delta_x = donor.mean_x - accum.mean_x
        var delta_y = donor.mean_y - accum.mean_y
        var factor = n_a * n_b / n_ab
        # Update co-moment + sums-of-sq-devs BEFORE means (formulas use
        # the deltas which depend on the OLD means).
        accum.C = accum.C + donor.C + delta_x * delta_y * factor
        accum.Sx = accum.Sx + donor.Sx + delta_x * delta_x * factor
        accum.Sy = accum.Sy + donor.Sy + delta_y * delta_y * factor
        accum.mean_x = accum.mean_x + delta_x * n_b / n_ab
        accum.mean_y = accum.mean_y + delta_y * n_b / n_ab
        accum.n = accum.n + donor.n

    @always_inline
    @staticmethod
    def finalize(state: CorrelationState) -> Scalar[DType.float64]:
        """Pearson r = C / sqrt(Sx * Sy); NaN where r is undefined.

        ★ THE DEGENERATE ARM WAS 0.0 AND IT WAS WRONG — board AGG-0KEY
        (). The docstring here used to say "DuckDB
        returns NULL when there's no variance in either dimension or when
        n < 2 ... we return 0.0 ... to keep the bench output finite for the
        H2O Q9 spike". BOTH halves of that were false, and the second was
        the damaging one:

          * MEASURED, DuckDB v1.5.3 — `corr` returns a genuine NON-NULL
            **NaN** for n == 1 AND for a constant x, a constant y, and both
            constant (`corr(a,b) IS NULL` is `false` in every one). It
            returns NULL only for n == 0. So the engine's NULL-vs-value
            split was right and its VALUE was not.
          * ⛔ 0.0 IS NOT A SENTINEL, IT IS AN ANSWER. `r = 0` reads as "no
            linear relationship", which is a finite, plausible, publishable
            number — so a query over a constant column got a WRONG
            correlation rather than a visible one, and every downstream
            filter, sort and average consumed it silently. NaN is loud, is
            what DuckDB emits, and is what this returns now.

        n == 0 stays NaN HERE and becomes SQL NULL at the DRAIN
        (`agg_extended_grouped._ext_result_is_null`, whose CORR arm is
        `n == 0` and deliberately NOT the ddof pair's `count <= 1`).
        """
        if state.n == UInt64(0):
            return Float64(0.0) / Float64(0.0)  # NaN
        var denom = state.Sx * state.Sy
        if denom <= Float64(0.0):
            # n == 1, or one/both dimensions constant — r is UNDEFINED, not
            # zero. DuckDB v1.5.3 returns NaN for all three; measured.
            return Float64(0.0) / Float64(0.0)  # NaN
        return state.C / sqrt(denom)


# -----------------------------------------------------------------------------
# MedianState — fixed-capacity inline reservoir of Float64 values
# -----------------------------------------------------------------------------
#
# ⛔⛔ NO PLAN ROUTE REACHES THIS STATE, `MedianAggregator` OR `MedianF64`.
# Every `median(x)` a customer can spell runs `_ext_median_inplace`
# (`agg_extended_grouped.mojo`) or `MedianOp[dt]` (`komira_eval/
# hash_agg_op_dt.mojo`), both of which keep EVERY value. MEASURED
# at five doors (W0; `agg_expr.median`'s docstring has the
# evidence). The "H2O Q6 ... bench measures throughput, not exact median
# agreement" rationale below is HISTORY: q06 runs the exact route and is
# VALUE_IDENTICAL against DuckDB on the corpus scoreboard. The customer-surface
# census read this section as a live wrong answer; do not cite it as one.
#
# Item 19b / H2O Q6 real-query. Per-group state is a small
# fixed-capacity inline reservoir of Float64 values. State layout:
#   count: Int32                              # 4 bytes
#   _pad:  Int32                              # 4 bytes alignment pad
#   values: InlineArray[Float64, 64]          # 512 bytes
# Total: 520 bytes per group.
#
# Why fixed-capacity inline (not heap List[Float64]):
#   `AggregatorWithStruct` state lives inside a byte-Slab via
#   `_agg_slabs[ai]` indexing. Heap-owning fields (List, OwnedPointer,
#   String) inside a byte-Slab is the gap6 pattern (see
#   an internal doc):
#   wildcard-origin slab + heap-owning inner field defeats ASAP-destruction
#   tracking and corrupts memory under destroy-recreate cycles. POD
#   (InlineArray + scalars) is the only safe shape.
#
# Capacity choice — 64 values (Tier S Fix #3, v0.4 perf sweep):
#   * State size 520B; 100K groups → ~52MB worst-case (acceptable).
#   * For groups exceeding 64 values, we KEEP the FIRST 64 (don't
#     overwrite). This is a biased sample — the median will be approximate.
#   * H2O Q6 has ~10K groups × ~100 rows each on the standard 1e7-row
#     fixture; capacity-64 truncates ~36% of each group's rows but
#     preserves enough samples for representative throughput numbers.
#     Result: bench measures throughput, not exact median agreement
#     with DuckDB.
#   * Reduced from 128 → 64 (1032B → 520B per state) to cut struct-state
#     cache pressure in the SlabHashAggSinkStruct consume loop. h6 wall
#     time prior: 311ms (3.83× DuckDB); target ≤ 1.10× post-fix.
#
# Combine semantics: extend self.values with other.values[:remaining_cap].
# When self is full (count == 64), donor contributions are dropped.
#
# Finalize: sort in-place via insertion sort (small N), return median.
# -----------------------------------------------------------------------------


comptime MAX_MEDIAN_VALUES: Int = 64
"""Fixed inline capacity for `MedianState`. See module-level rationale.

Trade-off: bigger N → more memory per group (linear), more accurate
median for high-cardinality groups, slower insertion-sort finalize
(O(n^2) so quadratic). 64 is empirically tuned for the H2O Q6 group
shape (group_size ≈ 100): state size 520 bytes, finalize ~4K ops worst
case (fast on modern CPUs), half the cache footprint of the prior
128-value layout."""


struct MedianState(
    # Mojo 1.0.0: NOT ImplicitlyCopyable -- the InlineArray field makes the
    # implicit copy ctor unsynthesizable, and an O(N) copy should be visible.
    # Every copy of this state is now an explicit `.copy()`.
    Copyable, Movable, Deinitable
):
    """Per-group state for `MedianAggregator` — fixed-capacity inline reservoir.

    Layout: 520 bytes total (count: Int32 + 4-byte pad + 64 × Float64).
    All POD scalar fields; gap6-safe by construction (no heap-owning
    inner field). The `_pad` slot exists to keep the InlineArray
    naturally 8-byte aligned.

    Copyable + ImplicitlyCopyable + Movable + Deinitable —
    auto-derivable since every field is POD.
    """

    var count: Int32
    var _pad: Int32
    var values: Array[Float64, MAX_MEDIAN_VALUES]

    @always_inline
    def __init__(out self):
        """Zero-init: count=0, values=zero-filled (POD).

        This is the identity for combine: combining any state with a
        zero-init state yields the original state.
        """
        self.count = Int32(0)
        self._pad = Int32(0)
        self.values = Array[Float64, MAX_MEDIAN_VALUES](
            uninitialized=True
        )


# -----------------------------------------------------------------------------
# median_of_reservoir_nan_last — THE ONE FINALIZE BODY FOR THE CAPPED MEDIAN
# -----------------------------------------------------------------------------
#
# ⭐⭐ THIS FUNCTION EXISTS BECAUSE THERE WERE TWO COPIES OF IT AND THEY WERE
#    BOTH WRONG IN THE SAME WAY. `MedianAggregator.finalize` here and
#    `MedianF64.finalize` (`agg/agg_state_slab.mojo`) are two hand-written
#    bodies over ONE shared `MedianState`. Both insertion-sorted the reservoir
#    with the raw predicate `buf[j] > key`.
#
# ⚠⚠ AND BEFORE YOU READ THE MEASUREMENT BELOW AS A SHIPPED WRONG ANSWER:
#    NEITHER BODY IS REACHABLE FROM ANY PLAN ROUTE. Measured —
#    outside this file, `agg_state_slab.mojo` and their own unit tests, every
#    occurrence of `MedianAggregator` and `MedianF64` in `src/` is a COMMENT or
#    a docstring. The LIVE AGG_MEDIAN routes are `_ext_median_inplace`
#    (`agg_extended_grouped.mojo`) and `MedianOp[dt].finalize`
#    (`komira_eval/hash_agg_op_dt.mojo`), and both have been NaN-last since
#. This fix is therefore HYGIENE on a latent defect, not the
#    repair of a user-visible one — do not cite it as the latter. It is worth
#    having because `MedianState` is still the state shape `agg_expr.mojo:985`
#    documents as AGG_MEDIAN's semantics, so a re-wiring would have shipped
#    this silently.
#
# ⛔ THAT PREDICATE IS FALSE FOR EVERY COMPARISON INVOLVING NaN, so a NaN key
#    never shifts anything and a NaN at `buf[0]` stops EVERY later insertion at
#    `j == 0` — which makes the remaining sort a COMPLETE NO-OP. The returned
#    "median" was then an artifact of ARRIVAL ORDER. MEASURED over the 720
#    permutations of {1,2,3,4,NaN,NaN} against a faithful model of that loop:
#
#        NaN 432 (60%) · 2.5 88 · 3.5 80 · 1.5 80 · 3.0 20 · 2.0 20
#
#    SIX distinct answers for ONE multiset, NaN the plurality. A group's rows
#    arrive in whatever order the partition hands over, so this was
#    NON-REPRODUCIBLE across runs of the same binary over the same file.
#
# THE ORDER IMPLEMENTED HERE — DuckDB's, in which NaN is the LARGEST value.
# DuckDB makes NaN self-equal and greater than everything including +inf, so a
# group's values form a genuine TOTAL order with the NaNs last and `median` is
# the ordinary mean-interpolated order statistic under it. MEASURED
# `pixi run duckdb` v1.5.3 (Variegata), 2026-09-15:
#
#     median{1,2,3,4,NaN,NaN} -> 3.5     median{1,2,3,NaN,NaN} -> 3.0
#     median{1,2,NaN,NaN}     -> NaN     median{1,2,3,NaN}     -> 2.5
#
# The sorted array is therefore [<the k non-NaN values ascending>, <n-k NaNs>]:
# order statistic j is the j-th smallest non-NaN when j < k, and NaN when
# j >= k. That is exactly what this computes — compact the non-NaN values to a
# prefix, sort ONLY that prefix (which is NaN-free, so `>` IS a strict weak
# ordering there and the insertion sort is inside its contract), then index.
#
# This is the SAME order the two UNCAPPED medians in this tree already
# implement — `agg_extended_grouped._ext_median_inplace` and the typed
# `MedianOp.finalize`'s `_finalize_nan_last` (`komira_eval/hash_agg_op_dt.mojo`)
# — so all four bodies now agree on every group of at most 64 values.
#
# ⛔ WHAT THIS DOES **NOT** FIX, STATED SO NOBODY READS THE TREE AS SETTLED:
#    the FIRST-64 RETENTION CAP. Past 64 contributing values `update` drops the
#    rest, so the answer is the median of an arbitrary 64-row SAMPLE and no NaN
#    rule can repair it. The missing primitive is VARIABLE-CAPACITY PER-GROUP
#    STATE IN A POD BYTE-SLAB — the same gap6 constraint that hardwired
#    `AGG_LARGEST_K`'s K to 2. Closing it is `AGG_PERCENTILE` over the
#    unbounded `PercentileAcc`; the decision record, including why the two
#    doors may not share one NaN policy, is
#    an internal doc.
#
# Gated by `komira_engine_operators/tests/test_median_nan_total_order.mojo`
# (720-ordering exhaustive sweep on BOTH bodies, both sides of the cap).
# -----------------------------------------------------------------------------


def median_of_reservoir_nan_last(
    var buf: Array[Float64, MAX_MEDIAN_VALUES], n: Int
) -> Float64:
    """Median of the first `n` slots of `buf` under DuckDB's NaN-last total
    order. Takes the buffer BY VALUE — it permutes it. Returns NaN for n == 0
    (the same NaN-as-NULL convention `StddevSampAggregator.finalize` uses).
    """
    var nan = Float64(0.0) / Float64(0.0)
    if n <= 0:
        return nan

    # Compact the non-NaN values into buf[0:k]. `k <= i` at every step, so the
    # write never clobbers a slot this loop has not already read.
    var k = 0
    for i in range(n):
        var v = buf[i]
        if v == v:
            buf[k] = v
            k += 1

    # buf[0:k] holds no NaN, so `>` is a strict weak ordering on it.
    for i in range(1, k):
        var key = buf[i]
        var j = i - 1
        while j >= 0 and buf[j] > key:
            buf[j + 1] = buf[j]
            j = j - 1
        buf[j + 1] = key

    if (n & 1) == 1:
        var mid = n // 2
        if mid >= k:
            return nan
        return buf[mid]

    # Even n: the middle pair is (n//2 - 1, n//2). If the UPPER index is at or
    # past the non-NaN prefix then at least one of the pair is a NaN, and the
    # mean of anything with a NaN is a NaN — so return it directly rather than
    # computing it, which also covers the all-NaN group.
    var hi_i = n // 2
    if hi_i >= k:
        return nan
    return (buf[hi_i - 1] + buf[hi_i]) * Float64(0.5)


# -----------------------------------------------------------------------------
# MedianAggregator — exact median via fixed-capacity inline reservoir
# -----------------------------------------------------------------------------
#
# DuckDB `median(x)` is exact (sorts the full per-group sequence). We
# trade exactness for memory bound: cap the reservoir at 64 values
# (FIRST-64 retention). For groups with <= 64 rows, result is exact;
# beyond that, biased sample. The H2O Q6 bench measures throughput —
# the 64-cap shape is documented at the module level above.
# -----------------------------------------------------------------------------


struct MedianAggregator(
    AggregatorWithStruct, Copyable, Movable, Deinitable
):
    """Approximate median kernel — fixed-capacity inline reservoir.

    State: `MedianState` (520 bytes; Int32 count + 64 × Float64 buffer).
    Input: Float64.
    Output: Float64.

    update: append if count < 64; otherwise drop (FIRST-64 retention).
    combine: extend self.values with other.values up to capacity.
    finalize: insertion-sort in-place, return middle element (odd) or
              average of two middle elements (even). Returns NaN on
              empty state.
    """

    var _phantom: UInt8
    """Mojo requires structs with at least one non-static field for non-
    default layout-respecting moves. Single byte; zero practical cost."""

    comptime StateStruct = MedianState
    comptime InputDType = DType.float64
    comptime OutputDType = DType.float64
    comptime STATE_BYTES = 520
    """Sizeof(MedianState) = 4 (Int32 count) + 4 (Int32 pad) +
    64*8 (InlineArray[Float64, 64]) = 520.

    Asserted at storage construction time against
    `sizeof[MedianState]()`. If the struct layout ever changes (cap
    bump, field add), STATE_BYTES MUST be updated in lockstep — the
    bitcast through `_agg_slab_<AggIdx>` byte-Slab is comptime-typed
    but the stride math is runtime-driven by this constant.
    """

    def __init__(out self):
        self._phantom = UInt8(0)

    # -------------------------------------------------------------------
    # Lifecycle methods
    # -------------------------------------------------------------------

    @always_inline
    @staticmethod
    def init() -> MedianState:
        return MedianState()

    @always_inline
    @staticmethod
    def update(mut state: MedianState, input: Scalar[DType.float64]):
        """Append if buffer not full; otherwise drop (FIRST-64 retention).

        Single branch + indexed store on the hot path. We deliberately
        DO NOT shift / overwrite older values when full — FIRST-64 is
        the simplest deterministic policy and avoids per-row sorting
        for an LRU shape.
        """
        var c = Int(state.count)
        if c < MAX_MEDIAN_VALUES:
            state.values[c] = Float64(input)
            state.count = Int32(c + 1)

    @always_inline
    @staticmethod
    def combine(mut accum: MedianState, donor: MedianState):
        """Extend accum.values with donor.values up to capacity.

        Identity-respecting (zero donor / zero accum are no-ops by
        natural fall-through: donor.count == 0 enters the loop with
        zero iterations).
        """
        var a_count = Int(accum.count)
        var d_count = Int(donor.count)
        if a_count >= MAX_MEDIAN_VALUES:
            return
        var room = MAX_MEDIAN_VALUES - a_count
        var n_copy = d_count
        if n_copy > room:
            n_copy = room
        for i in range(n_copy):
            accum.values[a_count + i] = donor.values[i]
        accum.count = Int32(a_count + n_copy)

    @always_inline
    @staticmethod
    def finalize(state: MedianState) -> Scalar[DType.float64]:
        """Median of the reservoir under DuckDB's NaN-last TOTAL order.

        Returns NaN on empty state (n == 0); same NaN-as-NULL convention
        as `StddevSampAggregator.finalize` (Komira has no NULL today;
        SDK layer downstream-maps NaN if needed).

        ⛔ THE BODY IS NOT INLINE HERE ANY MORE, DELIBERATELY. It was, and
        `MedianF64.finalize` (`agg/agg_state_slab.mojo`) held a second copy of
        the same code; both sorted with a raw `buf[j] > key` that is FALSE for
        every NaN comparison, so both returned an ARRIVAL-ORDER ARTIFACT on any
        NaN-bearing group (720-permutation measurement in
        `median_of_reservoir_nan_last`'s header). Two copies of one algorithm
        that a planner chooses between is how a defect gets fixed in one arm
        and shipped in the other, so there is now ONE body and both call it.

        finalize takes `state` by value (the trait surface) and passes a
        `.copy()` of the buffer, so the byte-slab state is never mutated —
        the same shape as `StddevSampAggregator.finalize` (immutable input).
        """
        return median_of_reservoir_nan_last(
            state.values.copy(), Int(state.count)
        )


# -----------------------------------------------------------------------------
# LargestKState — 24-byte per-group state for largest-K (K=2) aggregator
# -----------------------------------------------------------------------------
#
# Item 19b (H2O Q8): top-K-largest-per-group kernel. K is
# hardcoded to 2 for the H2O Q8 `largest2(v3)` query — generalizing the
# K parameter is deferred until a second consumer needs it.
#
# State layout (24 bytes total; gap6-safe by construction — primitive
# scalar fields and a fixed-size InlineArray of primitive Float64):
#   count: Int32                      # filled-slot count (0, 1, or 2)
#   _pad:  Int32                      # alignment pad (Mojo packs to 8)
#   heap:  InlineArray[Float64, 2]    # min-heap of K largest values seen
#
# The 4-byte Int32 + 4-byte pad keeps the InlineArray Float64 8-byte
# aligned; total struct size = 8 + 16 = 24 bytes.
#
# Min-heap invariant: heap[0] is the SMALLEST of the K values currently
# stored. When a new value > heap[0] arrives, replace heap[0] and sift
# down. For K=2 the sift is trivially: if heap[0] > heap[1], swap them.
#
# finalize semantics: return the LARGEST of the heap (max). For K=2 the
# largest is heap[1] when count == 2 (min-heap invariant: heap[0] <=
# heap[1]). The bench output is a single Float64 per group — DuckDB's
# Q8 SQL also uses `max(v3)` as a stand-in (see
# bench/duckdb/h2o/q08_groupby_topn.sql line 11), so output parity
# holds. The kernel machinery exercises the min-heap path even though
# the surface answer matches MAX, which is the dispatch's stated goal.
# -----------------------------------------------------------------------------


struct LargestKState(
    # Mojo 1.0.0: NOT ImplicitlyCopyable -- the InlineArray field makes the
    # implicit copy ctor unsynthesizable, and an O(N) copy should be visible.
    # Every copy of this state is now an explicit `.copy()`.
    Copyable, Movable, Deinitable
):
    """Per-group state for `LargestKAggregator` (K=2): min-heap of top-2.

    Shape: 24 bytes total (Int32 + Int32 pad + 2 * Float64). Movable +
    Deinitable auto-derived; primitive scalar fields only.
    Same gap6 audit as `WelfordState`.
    """

    var count: Int32
    var _pad: Int32
    var heap: Array[Float64, 2]

    @always_inline
    def __init__(out self):
        """Zero-init: count=0, heap=[0.0, 0.0]. Identity for combine.

        Mojo `InlineArray[T, N]` ctor takes `uninitialized=True`
        or `fill=...`; positional-args ctor not supported. Use `fill=`
        to zero both slots in one pass (Mojo expands to 2 stores).
        """
        self.count = Int32(0)
        self._pad = Int32(0)
        self.heap = Array[Float64, 2](fill=Float64(0.0))


# -----------------------------------------------------------------------------
# LargestKAggregator — top-2-largest per-group (Item 19b H2O Q8)
# -----------------------------------------------------------------------------
#
# H2O Q8: `SELECT id6, largest2(v3) FROM x GROUP BY id6` — for each
# group, return the 2 largest v3 values. The bench output is a single
# Float64 per group (the largest of the top-2; both DuckDB's Q8 SQL and
# this kernel return that scalar to keep the bench shape uniform with
# `max(v3)`). The min-heap path is the load-bearing exercise.
#
# Per-row update (K=2 specialization):
#   - count == 0: heap[0] = x; count = 1
#   - count == 1: place x at slot 1; sort so heap[0] is min; count = 2
#   - count == 2: if x > heap[0]: heap[0] = x; restore heap[0] <= heap[1]
#     by swap if needed.
#
# Combine: push donor's filled slots into accum (at most K pushes). The
# update path's K=2 specialization handles the eviction logic.
# -----------------------------------------------------------------------------


struct LargestKAggregator(
    AggregatorWithStruct, Copyable, Movable, Deinitable
):
    """Top-K-largest per-group kernel (K=2) — min-heap of K elements.

    State: `LargestKState` (24 bytes; Int32 count + 2 Float64 heap slots).
    Input: Float64.
    Output: Float64 (the LARGEST of the top-K, i.e. the heap max).

    finalize: heap[1] for count == 2; heap[0] for count == 1; NaN for
    count == 0 (matches DuckDB's NULL-on-empty via the same NaN-for-NULL
    idiom as stddev_samp).
    """

    var _phantom: UInt8
    """Mojo requires structs with at least one non-static field for non-
    default layout-respecting moves. Single byte; zero practical cost."""

    comptime StateStruct = LargestKState
    comptime InputDType = DType.float64
    comptime OutputDType = DType.float64
    comptime STATE_BYTES = 24
    """Sizeof(LargestKState) = 4 (Int32 count) + 4 (Int32 _pad) +
    16 (InlineArray[Float64, 2]). The pad keeps the InlineArray 8-byte
    aligned; total = 24 bytes."""

    def __init__(out self):
        self._phantom = UInt8(0)

    # -------------------------------------------------------------------
    # Lifecycle methods
    # -------------------------------------------------------------------

    @always_inline
    @staticmethod
    def init() -> LargestKState:
        return LargestKState()

    @always_inline
    @staticmethod
    def update(mut state: LargestKState, input: Scalar[DType.float64]):
        """Min-heap push of `input` into the K=2 top-K state.

        Branch shape:
          count == 0: heap[0] = x; count = 1.
          count == 1: place x at slot 1, then ensure heap[0] is min.
          count == 2: if x > heap[0] (current min), replace heap[0] with
                      x, then restore heap[0] <= heap[1] by swap.

        The K=2 sift collapses to a single conditional swap because the
        heap has only one parent/child relationship.
        """
        var x = Float64(input)
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

    @always_inline
    @staticmethod
    def combine(mut accum: LargestKState, donor: LargestKState):
        """Push donor's filled heap slots into accum (at most K pushes).

        Identity-respecting: zero-count donor is a no-op; the same
        `update` path absorbs donor values regardless of accum's
        starting count.
        """
        if donor.count == Int32(0):
            return
        Self.update(accum, donor.heap[0])
        if donor.count >= Int32(2):
            Self.update(accum, donor.heap[1])

    @always_inline
    @staticmethod
    def finalize(state: LargestKState) -> Scalar[DType.float64]:
        """Return the LARGEST of the top-K (heap max).

        For K=2 with min-heap invariant heap[0] <= heap[1]: the larger
        is heap[1] when count == 2 and heap[0] when count == 1. Empty
        group (count == 0) returns NaN — same NaN-as-NULL convention as
        `StddevSampAggregator.finalize`.
        """
        if state.count == Int32(0):
            return Float64(0.0) / Float64(0.0)  # NaN
        if state.count == Int32(1):
            return state.heap[0]
        # count == 2: heap[1] is the larger (min-heap invariant).
        return state.heap[1]
