# =============================================================================
# _MapFnFusedKernel — engine-internal fast-path trait
# =============================================================================
#
# NOT user-facing. NOT exported from komira_eval/__init__.mojo or
# komira_sdk/__init__.mojo. End users should write MapFn (per-row)
# or ExprScalarFn (Eigen-tree SIMD UDF) — both with explicit column
# flow at call site.
#
# This trait powers POC-ζ's 4.4× chain fusion alongside
# `_FilterFnFusedKernel` and `_AggFnFusedKernel`. Engineers writing
# engine-internal scaffolding use this; library users do not.
#
# Renamed from `MapFnSimd` (WAVE-11-UDF-B-FOLLOWUP) so that `*Simd` is not part
# of the user-facing surface — the trait
# functionality is preserved but no longer advertised as a user API.
# =============================================================================
#
# UDF-PHASE-B3-2 history (sub-slot 2 of UDF Execution Architecture v0.4 RFC v2.1).
# `_MapFnFusedKernel` extends `MapFn` with the typed-SimdOf chunk path:
#
#   @staticmethod
#   fn eval[W: Int](input: SimdOf[Self.T_IN, W]) -> SimdOf[Self.T_OUT, W]
#   @staticmethod
#   fn eval_row(input: Self.T_IN) -> Self.T_OUT
#
# Stays a SUB-trait of `MapFn`, so a `_MapFnFusedKernel` conformer must
# also declare `comptime InRow` + `run_row` + `run_scalar` (the
# user-facing parent surface).
# =============================================================================

from komira_udf.map_fn import MapFn
from komira_kernels.simd_of import SimdOf


trait _MapFnFusedKernel(MapFn):
    """Engine-internal: a SimdOf-typed map. Chunk of `Self.T_IN` rows
    -> chunk of `Self.T_OUT` rows. Conformers MUST also conform to
    `MapFn` (this trait extends it), which means they MUST declare the
    legacy `InRow` / `OutType` members and provide `run_row` / `run_scalar`
    for the per-lane fallback path.

    The NEW comptime members on `_MapFnFusedKernel`:
      - `T_IN`        : the typed input row struct (Movable + Copyable +
                         Deinitable). Same logical role as
                         `InRow` on `MapFn`; both co-exist for backward
                         compat. The conformer typically declares
                         `comptime T_IN = MyRow` and `comptime InRow = MyRow`
                         pointing at the same struct.
      - `T_OUT`       : the typed output row struct. Same role as `OutType`
                         on `MapFn`, but `OutType` is a `DType` (single
                         scalar) whereas `T_OUT` is a struct (one or more
                         output fields, future-proof for multi-output maps).
                         For a single-output map, `T_OUT` is a single-field
                         struct wrapping a scalar of `OutType`.

    The NEW @staticmethod methods on `_MapFnFusedKernel`:
      - `eval[W]`     : THE primary SIMD-chunk hot path. Takes a
                         `SimdOf[Self.T_IN, W]` (W lanes laid out as SoA in
                         a single inline byte blob with comptime-derived
                         per-field offsets) and returns a
                         `SimdOf[Self.T_OUT, W]`. Body uses SimdOf typed
                         accessors (`get_f64[i]()` / `set_f64[i](v)` etc.)
                         — no rebind, no het-pack — and is the canonical
                         shape that the future engine driver dispatches to.
      - `eval_row`    : THE scalar tail / correctness oracle. Takes one
                         `Self.T_IN` and returns one `Self.T_OUT`. The
                         engine driver calls this for the ragged tail
                         (n % W rows after the W-lane chunk loop). MUST
                         agree with `eval[W=1]` lane-for-lane.

    Both are `@staticmethod` (no `self`) — `_MapFnFusedKernel` is intended
    for stateless / capture-free templates (the B3-3 expr_kernel_templates
    family). A user-facing UDF that needs captures continues to use plain
    `MapFn` (which has `mut self`) and is dispatched through the legacy
    het-pack `run_scalar` path. (The former user-facing vectorized
    sub-trait was deleted by WAVE-11-UDF-F.)
    """

    comptime T_IN:  Movable & Copyable & Deinitable
    comptime T_OUT: Movable & Copyable & Deinitable

    @staticmethod
    def eval[W: Int](input: SimdOf[Self.T_IN, W]) -> SimdOf[Self.T_OUT, W]:
        """W lanes of typed input rows -> W lanes of typed output rows.
        The body uses `SimdOf` typed accessors directly — no rebind, no
        het-pack. MUST match `eval_row` lane-for-lane (the correctness
        contract; `eval_row` is the oracle).
        """
        ...

    @staticmethod
    def eval_row(input: Self.T_IN) -> Self.T_OUT:
        """One typed input row -> one typed output row. The scalar tail
        path the engine driver calls for `n % W` ragged rows after the
        W-lane chunk loop. The correctness oracle for `eval[W]`.
        """
        ...


# OPTIONAL manual-null path (RFC v2.1 N-2). A `_MapFnManualFusedKernel`
# declares an `eval_manual[W]` that takes both the input chunk AND the
# input validity mask, returning a tuple of (output chunk, output
# validity mask). This is the SIMD-typed analog of the M5 NORMATIVE
# rule on `MapFn` (a MANUAL-mode map opts in to the kernel surface so
# the engine has a vector path that can emit per-lane validity); for
# SimdOf-typed maps, MANUAL means conforming to
# `_MapFnManualFusedKernel` instead of `_MapFnFusedKernel`. The engine
# driver in sub-slot 6a comptime-branches `_MapFnManualFusedKernel`
# ahead of `_MapFnFusedKernel`.
#
# Relocated from the user-facing surface to this internal module
# (WAVE-11-UDF-B-FOLLOWUP); 0 conformers in tree at the
# time of move, so this is a dormant trait kept alive for the future
# MANUAL-mode SIMD UDF surface.
trait _MapFnManualFusedKernel(_MapFnFusedKernel):
    """A MANUAL-null SimdOf-typed map: takes the validity mask as input
    and returns it as part of the output. The engine driver in sub-slot
    6a routes MANUAL UDFs through this path (mask-aware) instead of the
    PROPAGATE path on `_MapFnFusedKernel` (mask is ANDed in by the
    driver after `eval`).
    """

    @staticmethod
    def eval_manual[W: Int](
        input: SimdOf[Self.T_IN, W],
        mask:  SIMD[DType.bool, W],
    ) -> Tuple[SimdOf[Self.T_OUT, W], SIMD[DType.bool, W]]:
        """W lanes of typed input rows + W-lane validity mask -> W lanes
        of typed output rows + W-lane validity mask. The body decides per
        lane whether the output is valid (e.g. division-by-zero produces
        a False mask bit even if the input lanes were valid).
        """
        ...
