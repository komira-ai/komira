# =============================================================================
# AggregatorWithStruct — multi-field-state Aggregator trait variant (Item 19a)
# =============================================================================
#
# Sibling refinement of `AggKernel` (the Phase 7 umbrella scalar trait). Where
# the scalar `AggKernel` binds state to a single SIMD scalar via
# `alias StateDType: DType`, this trait additionally binds state to a per-impl
# typed struct via `alias StateStruct: AnyType`.
#
# Design: an internal doc (Option B,
# maintainer/maintainer ratified).
#
# Trait shape (Phase 7 simplified — IS_NOOP / IS_STRUCT removed):
#   - `alias StateStruct: AnyType`              — per-impl typed state struct
#   - `alias InputDType: DType`                 — primary input column DType
#   - `alias OutputDType: DType`                — finalize-output element type
#   - `alias STATE_BYTES: Int`                  — sizeof(StateStruct)
#   - `init() -> Self.StateStruct`              — fresh per-group state
#   - `update(mut s, x)`                        — single-row update
#   - `combine(mut accum, donor)`               — parallel-merge formula
#   - `finalize(s) -> Scalar[OutputDType]`      — final value
#
# Storage path branches via `comptime if conforms_to(Agg, AggregatorWithStruct)`
# at the per-AggIdx method level (init_state / commit_aggregator /
# combine_aggregator / finalize_aggregator). The `IS_STRUCT` sentinel is gone.
#
# Note on `update_batch`: the design doc §3.1 lines 287-303 sketched a
# default `update_batch[N](mut states: InlineArray[StateStruct, N], ...)`
# body that loops scalar update. Mojo's `InlineArray` requires
# `ElementType: Copyable`, but constraining `StateStruct: Copyable` would
# preclude impls whose state holds non-Copyable subfields (e.g. side-Slab
# variant's offset/length pair is Copyable, but a future variant might
# carry a non-Copyable handle). Dropping `update_batch` from the base
# trait keeps the `StateStruct: AnyType` constraint open. Per-impl
# override at the conformer level remains available; the storage layer's
# commit hot path uses scalar `update` per row regardless. Future
# specialization (Phase H-shape SIMD per-impl) lives on the conformer,
# not on the trait surface.
#
# Why a sibling trait (not generic Aggregator[StateT]):
#   The 8 SIMD-vectorizable Phase G-pre builtins (SumF64, CountStar, etc.)
#   live on `AggKernel` with `Scalar[StateDType]` state — a single SIMD
#   register lane that vectorizes via `states += inputs`. Folding multi-field
#   state into the existing trait would require parametric storage layouts
#   and break the SIMD path. The sibling trait approach has zero ripple to
#   the 8 builtins.
#
# Why typed StateStruct (not bytes-typed Scalar[uint8]):
#   Bytes-typed transmute (Option C in the design doc) reintroduces the
#   AosRowThunk pattern that Phase G is replacing — every method body would
#   bitcast through a raw pointer. Typed StateStruct gives compile-checked
#   field access (`state.mean += delta`) with no transmutes in kernel bodies.
#
# Storage integration (post-Phase-7):
#   `SlabStorage` (`slab_storage.mojo`) admits AggregatorWithStruct impls
#   through the SAME methods as scalar AggKernel impls — `init_state`,
#   `commit_aggregator`, `combine_aggregator`, `finalize_aggregator` —
#   which branch internally via `comptime if conforms_to(Agg,
#   AggregatorWithStruct)` to bitcast `_agg_slab_<AggIdx>: Slab[UInt8]`
#   to `Agg.StateStruct` (struct branch) vs `Scalar[Agg.StateDType]`
#   (scalar branch). Encapsulation: the bitcast is inside SlabStorage;
#   the impl never sees a raw pointer.
#
# Sibling variants (NOT landed in 19a-impl; deferred to 19b kernel dispatches
# that need them):
#   - `AggregatorWithStruct2Input`            — for corr (2nd input column)
#   - `AggregatorWithStructAndSideStorage`    — for median (variable-size buffer)
#   - `AggregatorWithStructAndListOutput`     — for largest_k (List[T] output)
#
# 19a-impl lands ONLY the base trait + a single reference impl
# (StddevSampAggregator). The 3 sibling variants land alongside the
# kernel that needs them, in the corresponding 19b dispatch.
# =============================================================================


trait AggregatorWithStruct(Movable, Deinitable):
    """Multi-field-state Aggregator. Sibling refinement of `AggKernel`.

    Conformers carry a per-impl typed `StateStruct` that holds richer state
    than a single SIMD-scalar `AggKernel` can express. The trait surface
    is comptime-resolved: each conformer monomorphizes its own kernel body
    and the storage path invokes those static methods directly.

    Constraints on `StateStruct`:
      - Must be Movable + Deinitable (matches trait quartet).
      - Must NOT contain heap-owning fields (no List, String, OwnedPointer,
        ArcPointer, or wildcard-origin pointers) — gap6 hazard.
        Inline structs with primitive + InlineArray fields only. See
        an internal doc §7.11 +
        an internal doc.

    Reference impl: `StddevSampAggregator` with
    `WelfordState { count: UInt64, mean: Float64, m2: Float64 }` (24 bytes).
    """

    # -------------------------------------------------------------------
    # Associated types
    # -------------------------------------------------------------------

    comptime StateStruct: Copyable & Movable & Deinitable
    """Per-impl typed state struct. Held inline in `_agg_slab_<AggIdx>`
    byte-Slab at `entry_id * STATE_BYTES` offset.

    The triple (Copyable + Movable + Deinitable) is required by the
    storage layer's per-row round-trip pattern:

        var s = (inner_base + eid)[].copy()   # copy out of the slab slot
        Self.update(s, input)                 # mutate by reference
        (inner_base + eid)[] = s^             # move back into the slab

    Mojo 1.0.0 MIGRATION: the bound used to also demand
    `ImplicitlyCopyable`, and the round-trip above used to be spelled
    with a bare `=` on both lines. 1.0.0 removed `ImplicitlyCopyable`
    from `InlineArray[T, N]` and will not synthesize an implicit copy
    constructor for any struct holding one -- and there is no
    hand-written escape hatch (`__copyinit__` is not a hook the
    compiler consults, `fn` is gone, `@register_passable("trivial")`
    is gone). `MedianState` (520 B) and `LargestKState` both hold an
    InlineArray, so keeping the bound would have made them
    unconformable. The copy still happens at exactly the same two
    places and costs exactly what it cost under b2; it is now spelled
    out rather than synthesized.

    Forbidden field types (gap6 hazard): List, String, OwnedPointer,
    ArcPointer, wildcard-origin pointers. Inline structs with primitive
    + InlineArray fields only. Reference impls (WelfordState etc.)
    satisfy this constraint with primitive scalar fields, which Mojo
    auto-derives the triple for.
    """

    comptime InputDType: DType
    """Primary input column DType. For stddev/var: Float64. For largest_k_i64:
    Int64. (2-input variant `AggregatorWithStruct2Input` adds Input2DType.)"""

    comptime OutputDType: DType
    """Finalize output element type. For stddev/var/median/corr: Float64.
    For list-output kernels (largest_k), see
    `AggregatorWithStructAndListOutput.finalize_to_list`."""

    comptime STATE_BYTES: Int
    """sizeof(StateStruct). MUST match the actual byte size of StateStruct;
    the storage layer uses this as the per-AggIdx stride for slab packing.
    Mismatch produces silent wrong-sized loads/stores (the bitcast-through-
    byte-Slab is comptime-typed but stride math is runtime)."""

    # -------------------------------------------------------------------
    # Lifecycle methods — static; called by storage path comptime
    # -------------------------------------------------------------------

    @staticmethod
    def init() -> Self.StateStruct:
        """Fresh per-group state at hash-table insert time.

        For Welford-shaped kernels: zero state (count=0, mean=0.0, m2=0.0).
        For min/max-shaped kernels: saturating identity per field.

        Return-by-value (not out-param) matches the existing `AggKernel.init`
        shape; the storage layer assigns the result into the slot via
        typed pointer write `(inner_base + eid)[] = Agg.init()`. Avoids
        partial-move on slot bytes.
        """
        ...

    @staticmethod
    def update(
        mut state: Self.StateStruct,
        input: Scalar[Self.InputDType],
    ):
        """Single-row update. State is mutated in place by reference.

        Examples:
          stddev: count += 1; delta = x - mean; mean += delta/count;
                  m2 += delta * (x - mean)
          largest_k: if heap_count < k: push + sift-up; else if x > root:
                  replace root + sift-down
        """
        ...

    @staticmethod
    def combine(
        mut accum: Self.StateStruct,
        donor: Self.StateStruct,
    ):
        """Parallel-merge: fold donor state into accum.

        Used during finalize-segment combine in the storage layer. The
        formula must be mathematically equivalent to `init` followed by
        in-order `update` over the union of accum's + donor's input rows.

        For Welford: Chan/Welford parallel formula (see
        `StddevSampAggregator.combine`).
        For largest_k: heap-merge donor's K elements into accum, capped
        at k.
        """
        ...

    @staticmethod
    def finalize(state: Self.StateStruct) -> Scalar[Self.OutputDType]:
        """Convert final state to output scalar.

        For stddev_samp: sqrt(m2 / (count - 1)) for count > 1; NaN otherwise.
        For stddev_pop:  sqrt(m2 / count) for count > 0; NaN otherwise.
        For var_samp:    m2 / (count - 1) for count > 1; NaN otherwise.
        For var_pop:     m2 / count for count > 0; NaN otherwise.

        For list-output kernels (largest_k), see
        `AggregatorWithStructAndListOutput.finalize_to_list` instead.
        """
        ...
