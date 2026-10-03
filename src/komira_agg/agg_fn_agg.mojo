# =============================================================================
# agg_fn_agg.mojo — AggFn -> Aggregator newtype adapter
# =============================================================================
#
# The
# `Aggregator` conformance bridge for the user-facing `AggFn` family.
#
# WHY AN ADAPTER, NOT A REFINEMENT EDGE
# -------------------------------------
# The HashAggOp* family conforms to `Aggregator` via the `hash_agg_op_aggregator`
# adapters (`HashAggOpF64Agg[Op, col]` and family). Those Ops are FIELD-LESS
# markers — `update_scalar` is a static method on the conformer; the adapter
# carries no instance state.
#
# `AggFn` CANNOT refine `Aggregator` the same way: the shapes genuinely differ.
#   - `AggFn.update_scalar[*Ts](self, mut s: Self.State, *vals: *Ts)` —
#     POSITIONAL het-pack of typed scalars, NO `BatchView`, NO `i: Int`. A
#     stateful AggFn carries captures (the `self` in `self.update_scalar`).
#     Per-group state is `Self.State` (no `StateTy` alias — `comptime State`
#     member), value-return `merge(self, a, b) -> Self.State`.
#   - `Aggregator.update_scalar[bo](mut self, mut state: Self.StateTy,
#     batch: BatchView[bo], i: Int)` — BatchView-keyed; reads bound input
#     column off `BatchView`. Per-group state is `Self.StateTy` (an
#     `alias`). In-place `combine(mut self, mut into, var partial)`.
# An `AggFn` conformer is a typed scalar-oracle with NO column binding —
# it has no way to know which `BatchView` column to read. So the bridge
# needs a real wrapper that CARRIES the column index AND an instance of
# the AggFn (because `AggFn.update_scalar` is `self`-bound — a stateful
# AggFn carries captures and must persist them across rows). This is
# the canonical Rust-style newtype adapter: it conforms a foreign-shaped
# type to a trait. It is NOT an additive parallel API — there is no sibling
# trait and no duplicated surface; the
# adapter IS the single `Aggregator` conformance for the `AggFn` family.
#
# The precedent is `HashAggOpF64Agg[Op, col]` (`hash_agg_op_aggregator.mojo`)
# for static-method conformers + `AggFnAcc[F]` (`komira_engine_operators.
# agg_fn_acc`) for instance-method conformers + `MapFnRT[F, col0]`
# (`map_fn_rt.mojo`) for the parallel MapFn -> RowTransform bridge. `AggFn`
# is instance-method-shape so the storage shape mirrors `AggFnAcc` /
# `MapFnRT`: hold `_udf: F` as a field, construct from `var udf: F`, call
# `self._udf.update_scalar(state, v0)` per row.
#
# SCOPE — ARITY=1 INPUT (single-column AggFn)
# ------------------------------------------------
# This adapter covers the ARITY=1 INPUT case (one input column), matching
# the `HashAggOpF64Agg[Op, col]` shape. Multi-input-column AggFn adapters
# (arity-2/3/4 input via per-arity branches, mirroring
# `agg_fn_acc._update_arity{2,3,4}`) are not provided.
#
# Per-DType `comptime if` ladder on the input column
# --------------------------------------------------
# `BatchView` exposes only typed `col_i64`/`col_i32`/`col_f64`/`col_f32`/
# `col_bool` accessors (no `col_any[dt]`). The adapter reads the input
# DType off `F.InputSchema.cols[0].dtype` at comptime and lands a
# `comptime if`-laddered call to the matching `BatchView` accessor —
# the SAME canonical pattern `sort_buffer._read_sort_key_scalar` and
# `hash_agg._read_key_scalar` use, which is why those compile to
# byte-identical direct loads (no runtime dispatch).
#
# State-alias bridge — Self.StateTy = Self.F.State
# ------------------------------------------------
# `Aggregator` requires an `alias StateTy: AnyType & Movable & Copyable &
# Deinitable`; `AggFn` declares `comptime State: PodState`.
# `PodState` refines `Copyable + Movable + Deinitable` (closed
# marker; the bound members ARE the Aggregator StateTy bound) so the
# bridge is a direct equality:
#
#     alias StateTy: ... = Self.F.State
#
# The bridge folds away — the adapter hot loop monomorphizes to 7-9
# instructions, at parity with a hand-written reference.
#
# init / finalize lifecycle
# -------------------------
# `Aggregator.init` and `Aggregator.finalize` are `@staticmethod`s.
# `AggFn.init` / `AggFn.finalize` are INSTANCE methods (`self`-bound) —
# a `@staticmethod Self.init()` has no access to `self._udf`. Two
# resolutions were considered:
#
#   (a) No-arg-construct `Self.F()` inside the static lifecycle hooks and
#       call the instance method. REJECTED — the `AggFn` trait bound
#       (`Movable, Copyable, Deinitable`) does NOT synthesize a
#       no-arg `__init__()` on the trait param. The Mojo 1.0.0b1 trait
#       elaboration error is the explicit "missing 1 required keyword-only
#       argument: 'copy'" diagnostic (the synthesized ctors are
#       `__copyinit__` / `__moveinit__`, NOT a no-arg ctor). Adding a
#       `Defaultable` parent to `AggFn` would force the ~30 builtin
#       conformer migration, which is out of scope here.
#
#   (b) Constrain `init` / `finalize` to unimplementable for any caller —
#       satisfies the trait surface (so `AggFnAgg` conforms to
#       `Aggregator`), HARD COMPILE FAIL on any callsite, diagnostic
#       directs callers to use the instance-bound path. The typed UDF
#       executor ALWAYS has an `AggFnAgg` instance in scope (one
#       per Stage `*Aggs` slot, constructed by the operator-build driver
#       from a `var udf: F`), so per-group `init` / `finalize` route
#       through `self._udf.init()` / `self._udf.finalize(state)` directly
#       — NOT through the static trait method.
#
# takes (b) — same pattern `MapFnRT.project_one` uses for its
# unimplementable-on-instance-bound-adapter constraint. The hot path
# (`update_scalar` per row, `combine` cross-worker partial-merge) is
# unaffected: the per-row hot loop monomorphizes to 7-9 insns, zero `bl` indirect.
# A future carve-out can lift `init` / `finalize` to a static path
# via a `Defaultable + AggFn` refining trait if the typed UDF executor
# surfaces a need to call them through the Aggregator trait surface.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any signature.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads the per-batch
#     lifetime witness end-to-end.
#
# Cross-references:
#   - aggregator.mojo — the unified `Aggregator` trait (target).
#   - agg_fn.mojo — the user-facing `AggFn` trait (source).
#   - hash_agg_op_aggregator.mojo — the precedent adapter family pattern
#     (static-method conformer variant).
#   - komira_engine_operators.agg_fn_acc — the precedent
#     instance-method-conformer adapter shape (`_udf: F` field).
#   - map_fn_rt.mojo — the parallel MapFn -> RowTransform bridge.
# =============================================================================

from komira_core.collections.batch_view import BatchView

from komira_udf.agg_fn import AggFn
from komira_agg.aggregator import Aggregator
from komira_udf.schema_descriptor import dtag_to_dtype


# =============================================================================
# §1 — AggFnAgg — Aggregator adapter for single-input-column AggFn
# =============================================================================


struct AggFnAgg[F: AggFn, col: Int](Aggregator):
    """`Aggregator` adapter wrapping an `AggFn` conformer `F` bound to
    input column `col`. Output DType is `F.OutType`.

    Fields
    ------
    _udf: The user's `F` instance (per-worker copy — the typed UDF
        executor lifecycle; mirrors the `_udf` field on `AggFnAcc[F:
        AggFn]` and `MapFnRT[F: MapFn, col0]`). `mut self.update_scalar`
        borrows it mutably per row — and even though `AggFn.update_scalar`
        is declared `self` (not `mut self`), threading through `mut self`
        on the adapter is sound (the conformer just doesn't mutate).

    `update_scalar` reads column `col` off the `BatchView` per
    `F.InputSchema.cols[0].dtype` (via a comptime-folded `comptime if`
    ladder over the four `BatchView` typed accessors), forwards the raw
    scalar to `self._udf.update_scalar(state, value)` via the het-pack
    positional oracle. `combine` forwards to the conformer's value-return
    `F.merge`, assigning into `into` in place to satisfy `Aggregator.combine`'s
    in-place contract.

    This is the canonical Rust-style newtype adapter — see module doc.
    7-9 insns/row hot loop, zero `bl` indirect, parity with a
    hand-written reference.
    """

    comptime StateTy: AnyType & Movable & Copyable & Deinitable = (
        Self.F.State
    )
    comptime OUT_DT: DType = Self.F.OutType

    var _udf: Self.F

    def __init__(out self, var udf: Self.F):
        """Construct an `AggFnAgg` wrapping the given `F` instance.

        Args:
            udf: The user's `F` instance. Ownership is transferred
                 (the adapter owns its per-worker copy — mirrors
                 `AggFnAcc.__init__` / `MapFnRT.__init__`).
        """
        self._udf = udf^

    # __moveinit__ / __copyinit__ / __del__ auto-synthesized — F is
    # Movable & Copyable & Deinitable.

    @staticmethod
    def make() -> Self:
        """`Aggregator.make` — UNIMPLEMENTABLE for an instance-bound `AggFn`
        adapter. A stateful `AggFn` `F` carries
        a per-worker capture that cannot be default-constructed (the `AggFn`
        trait bound synthesizes only copy/take ctors, not a no-arg `F()`), so
        the field-less `VariadicAggFactory` does NOT carry UDF aggregates —
        they route through the untyped UDF segment path. `constrained[False]`
        makes any accidental field-less construction a HARD COMPILE FAIL
        (mirrors `AggFnAgg.init()`)."""
        comptime assert False, ("AggFnAgg.make is unimplementable for an instance-bound AggFn "
            "adapter — its UDF `F` carries a per-worker capture and the AggFn "
            "trait bound does not synthesize a no-arg `F()` ctor. UDF "
            "aggregates route through the untyped UDF segment path, NOT the "
            "field-less VariadicAggFactory.")

    @staticmethod
    def init() -> Self.StateTy:
        """`Aggregator.init` — UNIMPLEMENTABLE for an instance-bound `AggFn`
        adapter; satisfies the trait surface but compile-time-rejects
        any call.

        WHY UNIMPLEMENTABLE — `init` is `@staticmethod` and has no access
        to `self._udf`. `AggFn.init` is an instance method (`self`-bound);
        the adapter MUST hold an `_udf: F` field to call into the
        conformer. Without `self`, the static method cannot reach
        `_udf`, and `Self.F()` no-arg construction is not viable (the
        `AggFn` trait bound is `Movable, Copyable, Deinitable`
        which synthesizes only copy/take ctors, NOT a no-arg
        `__init__()`).

        The `constrained[False]` body is the trait-surface escape hatch
        — `AggFnAgg` conforms to `Aggregator` at trait-decl time, but
        any callsite that tries to invoke the static `init` through
        `AggFnAgg` is a HARD COMPILE FAIL with the diagnostic below.
        The typed UDF executor ALWAYS has an `AggFnAgg`
        instance in scope and routes per-group `init` through
        `agg_slot._udf.init()` directly — NOT through the static trait
        method. See module doc "init / finalize lifecycle" for the
        resolution rationale.

        The body recursively calls `Self.init()` to satisfy the
        return-type contract — recursion is type-correct (returns
        `Self.StateTy`) and the `constrained[False]` above ensures the
        recursion is never instantiated; if someone DOES try to use it,
        they hit the constrained diagnostic at compile time before any
        recursion analysis fires.
        """
        comptime assert False, ("AggFnAgg.init is unimplementable for an instance-bound "
            "AggFn adapter — `@staticmethod init` has no access to "
            "`self._udf`, and the AggFn trait bound does not synthesize "
            "a no-arg `F()` ctor. Drive per-group `init` via the "
            "adapter instance (`agg_slot._udf.init()`) from the typed "
            "UDF executor path, or add a `Defaultable + AggFn` "
            "refining-trait carve-out.")

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, batch: BatchView[bo], i: Int):
        """Fold the single row at logical index `i` into `state`.

        Reads input column `col` per `F.InputSchema.cols[0].dtype`
        (comptime-known), forwards the raw scalar to
        `self._udf.update_scalar(state, value)` via the het-pack
        positional oracle. The `comptime if` ladder folds away — the
        adapter compiles to a direct typed load + direct
        `self._udf.update_scalar` call (7-9
        insns/row, zero `bl` to indirect dispatch).
        """
        # Read the aggregand off the batch via
        # the single generic `BatchView.col_scalar_nonraising[dt0]` primitive —
        # bit-exact over the FULL fixed-width numeric matrix (i8/16/32/64,
        # u8/16/32/64, f32/f64), with NO silent `col_i64` else-fallthrough (an
        # unhandled DType is a COMPILE ERROR). The all-handled-today DTypes
        # (I64/I32/F64/F32) codegen byte-identical to the prior ladder.
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        var v = batch.col_scalar_nonraising[dt0](Self.col, i)
        self._udf.update_scalar(state, v)

    @always_inline
    def combine(
        mut self, mut into: Self.StateTy, var partial: Self.StateTy
    ):
        """Merge a partial state into `into`. Forwards to
        `self._udf.merge(into, partial^)` and assigns the value-return
        back into `into` to satisfy `Aggregator.combine`'s in-place
        contract.

        `AggFn.merge` is `merge(self, a, b) -> Self.State` (value-return);
        `Aggregator.combine` is `combine(mut self, mut into, var partial)`
        (in-place). The adapter bridges the two by reading `into` as `a`,
        consuming `partial` as `b`, calling the value-return form, and
        storing the result back into `into`. The `into = merged^` move
        is the canonical bridging idiom (mirrors `AggFnAcc.merge_aligned`'s
        `self._states[g] = merged^`).
        """
        var merged = self._udf.merge(into, partial^)
        into = merged^

    @staticmethod
    def finalize(state: Self.StateTy) -> Scalar[Self.OUT_DT]:
        """`Aggregator.finalize` — UNIMPLEMENTABLE for an instance-bound
        `AggFn` adapter; satisfies the trait surface but compile-time-
        rejects any call. Same rationale as `init` above —
        `@staticmethod finalize` has no access to `self._udf`, and
        no-arg `Self.F()` construction is not viable under the `AggFn`
        trait bound. The typed UDF executor routes per-group
        `finalize` through `agg_slot._udf.finalize(state)` directly.
        """
        comptime assert False, ("AggFnAgg.finalize is unimplementable for an instance-bound "
            "AggFn adapter — `@staticmethod finalize` has no access to "
            "`self._udf`. Drive per-group `finalize` via the adapter "
            "instance (`agg_slot._udf.finalize(state)`) from the typed "
            "UDF executor path, or add a `Defaultable + AggFn` "
            "refining-trait carve-out.")
