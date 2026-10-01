# =============================================================================
# agg_fn.mojo — the typed user-defined aggregate trait (AggFn)
#               + the PodScalar / PodState marker traits (the slab-safety gate)
# =============================================================================
#
# An `AggFn` is a typed user-defined aggregate: N rows -> 1 value (per
# group) — `init`/`update`/`merge`/`finalize`, with the running state in a
# `comptime State` associated type. The adapter `AggFnAcc[F: AggFn]`
# (agg_fn_acc.mojo) *implements* the engine's `Accumulator` trait by wrapping
# `F` — same pattern as `UdfOp[T: ScalarUdf]` wrapping `ScalarUdf`. The adapter
# does the `Column` -> typed-`InRow` extraction (it knows `F.InputSchema` at
# comptime) + the gid-keyed `Slab[F.State]` bookkeeping; the user's `F` only
# ever sees typed `InRow` values.
#
# `mut s: Self.State` across `update` calls; the adapter holds
# `List[F.State]` (`ref slot = container[gid]`); `init() -> Self.State`
# (associated type as a return type), `merge(a: Self.State, b: Self.State)
# -> Self.State` (associated type as non-`self` value params) — all compile
# and give the right answer. No wildcard origin.
# `merge` is fine in this trait (it takes `Self.State`, not `Self` — the
# `Self`-typed-trait-param ban that keeps `merge_aligned` out of `Accumulator`
# doesn't apply to associated types).
#
# `update` ALWAYS takes `Self.InRow` — a one-input agg uses a
# single-field `InRow` (uniform with `MapFn`/`FilterFn`; there is NO `InCol`).
# The OPTIONAL SIMD fast path is the engine-internal `_AggFnFusedKernel`
# sub-trait (in `komira_engine_operators._internal.agg_fn_fused_kernel`)
# with `@staticmethod update_chunk[W]` over SimdOf-typed input rows.
#
# **The slab-safety gate**: `F.State` MUST conform to `PodState` — a fixed-size
# POD `@fieldwise_init` struct whose fields are all `PodScalar` (the
# int/float/bool families) or `InlineArray[T: PodScalar, N]`. No heap-owning
# field — `flush_partial_to_column` Arrow-columnar-dumps the raw `State` slab,
# so a `State` with a `List`/`String`/`Set` field corrupts memory at
# parallel-merge time. The `PodState` bound + the explicit allowlist is the
# compile-time gate (a `WeightedAvg(AggFn)` with `var bad: List[Int]` in its
# `State` must FAIL TO COMPILE). A UDF agg whose state genuinely needs heap
# (a HyperLogLog with a dynamic register array) ships its state as an
# `InlineArray[T, MAX]` — same workaround the engine's own statistical
# accumulators use (the AggLayout -> InlineArray migration).
#
# The user trait ships the scalar `update` path; `update_chunk` is the
# engine-internal fast path.
# =============================================================================

from komira_eval.schema_descriptor import SchemaDescriptor, _derive_schema


trait PodScalar(Copyable, Movable):
    """Marker — the scalar dtypes legal in an `AggFn.State`: the
    integer/float/bool families only. No heap-owning conformer (a closed
    marker — the engine blesses the allowlist; a conformer can't add itself).
    `Int8..Int64`, `UInt8..UInt64`, `Float32`, `Float64`, `Bool` conform."""
    ...


trait PodState(Copyable, Movable, Deinitable):
    """Marker — an `AggFn.State` MUST conform: a fixed-size POD
    `@fieldwise_init` struct whose fields are all `PodScalar` or
    `InlineArray[T: PodScalar, N]`. No heap-owning field —
    `flush_partial_to_column` Arrow-columnar-dumps the raw slab. A conformer
    with a `List`/`String`/`Set` field FAILS TO COMPILE (the trait-conformance
    check rejects it — the slab-safety compile-time gate)."""
    ...


trait AggFn(Movable, Copyable, Deinitable):
    """A typed user-defined aggregate: N rows -> 1 value (per group).

    State lives in `Self.State` (conforming to `PodState`). The adapter
    (`AggFnAcc[F: AggFn]`, implementing the engine's `Accumulator` trait)
    keeps one `State` per dense group id in a `Slab` and routes typed `InRow`
    values into `update`. Lifecycle mirrors the engine's accumulators:
      - `init()`:            fresh per-group state (the identity element).
      - `update(s, row)`:    fold one input row into a group's state.
                             (vectorized variant on the engine-internal
                             `_AggFnFusedKernel` — see below)
      - `merge(a, b)`:       combine two partial states (worker-A + worker-B
                             for the same group). The `merge_aligned` analogue;
                             the cold-path thunk monomorphizes it per `F`.
      - `finalize(s)`:       produce the output value from a group's state.

    Conformers MUST provide `InRow` / `InputSchema` / `OutputSchema` / `OutType`
    / `UDF_ID` (same shape as `MapFn`) plus `State` (a `PodState` conformer)
    plus the four lifecycle methods. (`AggFn` has no `parallelism` member — an
    `AggFn` is intrinsically `mergeable` via `merge()`; it slots into the
    accumulator framework's per-worker-partial-then-merge path. A stateful
    per-row emit is a stateful `MapFn` — a different node.)
    """

    comptime InRow: Copyable & Movable          # a @fieldwise_init struct of typed input fields (single field
                                                #   for a one-input agg — uniform with MapFn). NO InCol.
    # Trait default — auto-derive from InRow via
    # comptime reflection. The
    # default fires per-conformer at the call site. Conformers may override by
    # declaring `comptime InputSchema = ...` directly (the explicit value wins).
    comptime InputSchema: SchemaDescriptor = _derive_schema[Self.InRow]()
                                                # name+dtype of InRow's fields, in order (= the het-pack arity+dtype source)
    comptime OutputSchema: SchemaDescriptor     # name+dtype of the (one) output column
    comptime OutType: DType                     # = OutputSchema.cols[0].dtype (the engine asserts)
    comptime State: PodState                    # the running state — must be a fixed-size POD (slab-safety gate)
    comptime UDF_ID: UInt32                     # the operator-factory selector — same as MapFn.UDF_ID

    def init(self) -> Self.State:
        """The identity / zero state for a new group. (GREEN — `Self.State`
        as a return type, Probe 3b)."""
        ...

    def update(self, mut s: Self.State, row: Self.InRow):
        """REQUIRED — the ergonomic named-struct fold. `mut s` gives exclusive
        access to this group's slot — same mutability model as the engine's
        accumulators. GREEN per Probe 3b. A one-input agg's `InRow` is a
        single-field struct; the body reads `row.<field>`. Normally a one-line
        delegate to `update_scalar` — the actual logic lives there (uniform
        with `MapFn.run_row` delegating to `MapFn.run_scalar`)."""
        ...

    def update_scalar[*Ts: Copyable & Movable](self, mut s: Self.State, *vals: *Ts):
        """REQUIRED — the positional het-pack form of `update`. The
        `AggFnAcc[F]` adapter calls THIS at each row (it knows the concrete
        arity at the call site so it forwards the right number of scalars, but
        it can't construct the opaque `Self.InRow` generically — `F.InRow` is
        only `Copyable & Movable`-bound, which exposes no fieldwise
        constructor, so the positional oracle is required). The conformer
        recovers each arg's concrete type with `rebind[Float64](vals[0])` etc.
        (it knows its arity + dtypes from `InputSchema`). The actual logic
        lives here; `update` delegates to it. (Uniform with `MapFn.run_scalar`
        / `FilterFn.keep_scalar` — the per-lane positional oracle the engine's
        generic-over-`F` code needs because it can't deconstruct `InRow`.)
        Declared `self` (not `mut self`): an `AggFn` scalar oracle never
        mutates `self` — an `AggFn` has no `parallelism` member; it's
        intrinsically `mergeable` via `merge()`."""
        ...

    def merge(self, a: Self.State, b: Self.State) -> Self.State:
        """Combine two partial states for the same group. Called by the
        cold-path merge thunk (parallel-worker partial-agg merge)."""
        ...

    def finalize(self, s: Self.State) -> Scalar[Self.OutType]:
        """Produce the group's output value from its final state."""
        ...


# =============================================================================
# No user-facing SIMD opt-in sub-trait
# =============================================================================
#
# There is no user-facing SIMD opt-in sub-trait (one carrying
# `update_chunk[W, *Ts]` against a het-pack `*cols`): the builtins in
# `builtin_agg_fns_vec.mojo` are plain `AggFn`s, and a vectorized
# conformance path would have to match `update_scalar` lane-for-lane anyway,
# so the scalar path is the byte-identical reference.
#
# The OPTIONAL SIMD fast-path is exclusively the engine-internal
# `_AggFnFusedKernel` (in `komira_engine_operators._internal.agg_fn_fused_kernel`)
# with `@staticmethod init` / `update_chunk[W]` / `update` / `merge` /
# `finalize` SimdOf-typed signatures. The engine-internal typed-bridge fns
# in `agg_fn_acc.mojo` (`_invoke_update_chunk[G: _AggFnFusedKernel, W]` +
# `_invoke_finalize_simd[G: _AggFnFusedKernel]`) operate on the relocated
# trait.
#
# End users should write `AggFn` (per-row) or `ExprAggFn` (Eigen-tree
# SIMD UDF) — both with explicit column flow at call site.
# `_AggFnFusedKernel` is engine-internal scaffolding for chain-fusion
# templates only.
#
# See `komira_engine_operators._internal.agg_fn_fused_kernel` for the
# kernel trait body.
# =============================================================================
