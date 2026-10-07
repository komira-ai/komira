# =============================================================================
# _AggFnFusedKernel — engine-internal fast-path trait
# =============================================================================
#
# NOT user-facing. NOT exported from komira_eval/__init__.mojo or
# komira_sdk/__init__.mojo. End users should write AggFn (per-row)
# or ExprAggFn (Eigen-tree SIMD UDF) — both with explicit column flow
# at call site.
#
# This trait powers POC-ζ's 4.4× chain fusion alongside
# `_FilterFnFusedKernel` and `_MapFnFusedKernel`. Engineers writing
# engine-internal scaffolding use this; library users do not.
#
# Renamed from `AggFnSimd` (WAVE-11-UDF-B-FOLLOWUP) per maintainer
# directive "drop *Simd from user-facing surface" — the trait
# functionality is preserved but no longer advertised as a user API.
# =============================================================================
#
# UDF-PHASE-B3-2 history (sub-slot 2 of UDF Execution Architecture v0.4 RFC v2.1).
# `_AggFnFusedKernel` extends `AggFn` with the typed-SimdOf chunk path:
#
#   @staticmethod
#   fn init() -> Self.STATE
#   @staticmethod
#   fn update_chunk[W: Int](mut state: Self.STATE,
#                           input: SimdOf[Self.T_IN, W])
#   @staticmethod
#   fn update(mut state: Self.STATE, input: Self.T_IN)
#   @staticmethod
#   fn merge(mut a: Self.STATE, b: Self.STATE)
#   @staticmethod
#   fn finalize(state: Self.STATE) -> Self.T_OUT
#
# Stays a SUB-trait of `AggFn`, so a `_AggFnFusedKernel` conformer must
# also declare `comptime InRow` + `update_scalar` + `init` + `merge` +
# `finalize` (the user-facing parent surface).
# =============================================================================

from komira_udf.agg_fn import AggFn, PodState
from komira_kernels.simd_of import SimdOf


trait _AggFnFusedKernel(AggFn):
    """Engine-internal: a SimdOf-typed aggregate. Chunks of `Self.T_IN`
    rows fold into `Self.STATE`; finalize produces `Self.T_OUT`.
    Conformers MUST also conform to `AggFn` (this trait extends it),
    which means they MUST declare the legacy `InRow` / `OutType` /
    `State` members AND provide the `init` / `update` / `update_scalar`
    / `merge` / `finalize` `self`-method form for the existing engine path.

    The NEW comptime members on `_AggFnFusedKernel`:
      - `T_IN`  : the typed input row struct (Movable + Copyable +
                   Deinitable). Same logical role as
                   `InRow` on `AggFn`; both co-exist for backward compat.
      - `T_OUT` : the typed output row struct. The legacy `AggFn.OutType`
                   is a `DType` (single scalar), `T_OUT` is a struct
                   (one or more output fields, future-proof).
      - `STATE` : the running state struct, conforming to `PodState`
                   (Copyable + Movable + Deinitable — the gap6
                   gate). Same logical role as `State` on `AggFn`.

    The NEW @staticmethod methods on `_AggFnFusedKernel`:
      - `init()`               : factory for the identity state.
      - `update_chunk[W]`      : THE primary SIMD-chunk hot path. Folds W
                                  typed input lanes into the group's state.
                                  Body uses SimdOf typed accessors.
      - `update`               : THE scalar tail / per-row oracle. Used for
                                  the ragged tail (n % W rows) and for
                                  parallel-merge boundary cases.
      - `merge`                : in-place combine of two partial states
                                  for the same group (`a` += `b`).
      - `finalize`             : produce the output row from a final state.

    All are `@staticmethod` (no `self`) — `_AggFnFusedKernel` is intended
    for stateless aggregates (the 6 `*Vec` builtin cells in
    `builtin_agg_fns_vec.mojo`, the 80 builtin AggFn cells, and the future
    template-based aggregates). A user-facing UDF agg that needs captures
    continues to use plain `AggFn`. (The former user-facing vectorized
    sub-trait was deleted by WAVE-11-UDF-F.)

    NOTE: the typed-bridge engine wiring in `agg_fn_acc.mojo` (the
    comptime `if conforms_to(F, _AggFnFusedKernel)` branch) is what
    actually drives the SIMD hot path; v0.4 P1 still routes every
    AggFn through the per-lane scalar update path. The bridge fns
    `_invoke_update_chunk[G: _AggFnFusedKernel, W]` and
    `_invoke_finalize_simd[G: _AggFnFusedKernel]` operate generically
    on this trait.
    """

    comptime T_IN:  Movable & Copyable & Deinitable
    comptime T_OUT: Movable & Copyable & Deinitable
    comptime STATE: PodState

    @staticmethod
    def init() -> Self.STATE:
        """Construct the identity / zero state for a new group."""
        ...

    @staticmethod
    def update_chunk[W: Int](
        mut state: Self.STATE, input: SimdOf[Self.T_IN, W]
    ):
        """Fold W typed input lanes into `state` at once. Body uses
        `SimdOf` typed accessors. MUST agree with a per-lane loop over
        `update` lane-for-lane (the correctness contract; `update` is
        the oracle).
        """
        ...

    @staticmethod
    def update(mut state: Self.STATE, input: Self.T_IN):
        """Fold one typed input row into `state`. The scalar tail path
        the engine driver calls for `n % W` ragged rows after the W-lane
        chunk loop. The correctness oracle for `update_chunk[W]`.
        """
        ...

    @staticmethod
    def merge(mut a: Self.STATE, b: Self.STATE):
        """In-place combine of two partial states for the same group:
        `a` += `b`. Called by the cold-path merge thunk during the
        parallel-worker partial-merge phase.
        """
        ...

    @staticmethod
    def finalize(state: Self.STATE) -> Self.T_OUT:
        """Produce the typed output row from a final state."""
        ...
