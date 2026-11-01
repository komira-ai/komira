# =============================================================================
# _FilterFnFusedKernel — engine-internal fast-path trait
# =============================================================================
#
# NOT user-facing. NOT exported from komira_eval/__init__.mojo or
# komira_sdk/__init__.mojo. End users should write FilterFn (per-row)
# or ExprScalarFn (Eigen-tree SIMD UDF) — both with explicit column
# flow at call site.
#
# This trait powers POC-ζ's 4.4× chain fusion for built-in agg/filter
# conformers (sum/min/max/etc.). Engineers writing engine-internal
# scaffolding use this; library users do not.
#
# Renamed from `FilterFnSimd` (WAVE-11-UDF-B) so that `FilterFnSimd` is not part of
# the user-facing surface — the trait functionality
# is preserved but no longer advertised as a user API.
# =============================================================================
#
# UDF-PHASE-B3-2 history (sub-slot 2 of UDF Execution Architecture v0.4 RFC v2.1).
# `_FilterFnFusedKernel` extends `FilterFn` with the typed-SimdOf chunk path:
#
#   @staticmethod
#   fn eval[W: Int](input: SimdOf[Self.T_IN, W]) -> SIMD[DType.bool, W]
#   @staticmethod
#   fn eval_row(input: Self.T_IN) -> Bool
#
# Stays a SUB-trait of `FilterFn`, so a `_FilterFnFusedKernel` conformer must
# also declare `comptime InRow` + `keep_row` + `keep_scalar` (the user-facing
# parent surface).
# =============================================================================

from komira_udf.filter_fn import FilterFn
from komira_kernels.simd_of import SimdOf


trait _FilterFnFusedKernel(FilterFn):
    """Engine-internal: a SimdOf-typed predicate. Chunk of `Self.T_IN`
    rows -> W keep-bits. Conformers MUST also conform to `FilterFn`
    (this trait extends it), which means they MUST declare the parent
    `InRow` member and provide `keep_row` / `keep_scalar` for the
    per-lane fallback path.

    The NEW comptime member on `_FilterFnFusedKernel`:
      - `T_IN`        : the typed input row struct (Movable + Copyable +
                         Deinitable). Same logical role as
                         `InRow` on `FilterFn`; both co-exist for
                         backward compat. The conformer typically declares
                         `comptime T_IN = MyRow` and `comptime InRow = MyRow`
                         pointing at the same struct.

    The NEW @staticmethod methods on `_FilterFnFusedKernel`:
      - `eval[W]`     : THE primary SIMD-chunk hot path. Takes a
                         `SimdOf[Self.T_IN, W]` and returns a
                         `SIMD[DType.bool, W]` keep-mask. Body uses SimdOf
                         typed accessors. The engine driver ANDs the result
                         into the selection mask.
      - `eval_row`    : THE scalar tail oracle. Takes one `Self.T_IN`
                         and returns one `Bool`. The engine driver calls
                         this for the ragged tail. MUST agree with
                         `eval[W=1]` lane-for-lane.

    Both are `@staticmethod` (no `self`) — same rationale as the parallel
    `_MapFnFusedKernel` and `_AggFnFusedKernel` (also internalized to
    `komira_operator_api` per UDF-B-FOLLOWUP): intended
    for stateless / capture-free templates. A user-facing UDF that
    needs captures continues to use `FilterFn` (with `mut self`).
    """

    comptime T_IN: Movable & Copyable & Deinitable

    @staticmethod
    def eval[W: Int](input: SimdOf[Self.T_IN, W]) -> SIMD[DType.bool, W]:
        """W lanes of typed input rows -> W keep-bits. The body uses
        `SimdOf` typed accessors; the engine driver ANDs the result into
        the selection mask. MUST match `eval_row` lane-for-lane.
        """
        ...

    @staticmethod
    def eval_row(input: Self.T_IN) -> Bool:
        """One typed input row -> one keep-bit. The scalar tail path.
        The correctness oracle for `eval[W]`.
        """
        ...
