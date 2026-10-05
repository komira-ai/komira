# =============================================================================
# binary_fn.mojo — BinaryFn[TA, TB, TR, OP]: the comptime-templated binary
#                  arithmetic kernel trait
# =============================================================================
#
# Mirrors DuckDB's `BinaryFunction<TA, TB, TR, OP>` template (the per-column
# arithmetic kernel layer beneath each PhysicalOperator). The intent is to push
# the comptime-monomorphization win to the per-column kernel layer, where SIMD
# autovectorization actually lives, while keeping the operator graph
# runtime-tagged (`Slab[MorselOp]`) for EXPLAIN / plan-cache / serialization.
#
# Kernel-trait pattern:
#   - The hot-path method `eval_chunk(lhs, rhs, out, count)` is NON-RAISING.
#     Errors caught at the operator boundary (one check per chunk), not per
#     row. Mirrors DuckDB's `noexcept` convention. Required for autovectorization
#     inside the kernel's 2048-row tight loop.
#   - Validation / bind paths (`name`, schema inference at operator init) MAY
#     raise.
#   - All input / output buffers are typed `PrimitiveArray[T]` (or `ref [origin]
#     PrimitiveArray[T]`); NO `UnsafePointer` crosses any module boundary
#. The kernel's SIMD work
#     happens INSIDE PrimitiveArray's `_typed_ptr_ro` / `load[width=W]` /
#     `store[width=W]` (see `komira_column_kernels.arithmetic:eval_add`),
#     which is the existing hand-staged SIMD path.
#
# Mojo discipline:
#   - No `UnsafePointer` in any signature on this trait or its conformers.
#   - No wildcard origins (`MutAnyOrigin` / `ImmutAnyOrigin` / `MutExternalOrigin`)
#     anywhere — kernel state is pure-comptime + immutable inputs.
#   - File < 1000 LOC.
#   - `BinaryFn(Movable, Copyable, Deinitable)`: per-worker copies
#     by value (mirrors `MapFn`'s shape).
# =============================================================================
#
# Comptime parameters
# -------------------
# Each `BinaryFn` conformer carries four comptime parameters:
#
#   TA: DType    -- left input physical type  (e.g. DType.int64)
# TB: DType -- right input physical type (typically == TA in this version)
# TR: DType -- result physical type (typically == TA in this version)
#   OP: UInt8    -- arithmetic op tag (reuse `BIN_ADD` / `BIN_SUB` / `BIN_MUL`
#                   / `BIN_DIV` / `BIN_MOD` from `komira_plan_expr.expr`; the
#                   conformer asserts which tag it implements via the
#                   `OP_TAG` member so the dispatcher can verify the kernel
#                   matches the plan-level op tag).
#
# This ships the homogeneous-type cells (TA == TB == TR) for
# int64 + float64. Mixed-type / cast kernels would be one new
# conformer per cell (no trait change).
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray


trait BinaryFn(Movable, Copyable, Deinitable):
    """A typed user-defined-or-built-in binary arithmetic kernel: two input
    columns of typed primitives -> one output column.

    Conformers MUST provide:
      - `TA, TB, TR: DType` -- comptime physical types of the left, right,
        and result columns. this version is homogeneous (TA == TB == TR) for
        INT64 / FLOAT64. Mixed-type cells are followup (declare a new
        conformer per cell; no trait surface change).
      - `OP_TAG: UInt8` -- the arithmetic-op tag this kernel implements
        (`BIN_ADD` / `BIN_SUB` / `BIN_MUL` / `BIN_DIV` / `BIN_MOD` from
        `komira_plan_expr.expr`). The dispatcher / operator init verifies
        the kernel's OP_TAG matches the plan-level op tag.
      - `KERNEL_ID: UInt32` -- a stable identifier (akin to MapFn's
        `UDF_ID`). Used by EXPLAIN and any future kernel registry.
      - `name(self)` -- one-line human-readable kernel name for EXPLAIN.
      - `eval_chunk(self, lhs, rhs, mut out)` -- the hot path.
        NON-RAISING by design. Reads `count == lhs.length == rhs.length`
        lanes from `lhs[0..count)` and `rhs[0..count)`, writes `count`
        lanes to `out[0..count)`. The operator pre-allocates `out`
        with the same length, computes merged validity bitmap, and
        passes ownership-of-buffer into the kernel as a `mut` ref —
        the kernel writes only the data buffer. Null handling is the
        caller's responsibility (validity already on `out`). The
        kernel sees only raw lanes; null cells contain garbage but
        the validity bitmap masks them. This matches DuckDB's
        separation-of-concerns: the op manages validity, the kernel
        does pure arithmetic.

    Null-handling model (this version)
    -------------------------------
    PROPAGATE only: a row is null iff either input lane is null. The
    operator (`BinaryFnOp[F]`) computes the result validity bitmap from
    the inputs' bitmaps via bitmap-AND before calling `eval_chunk`. The
    kernel itself is oblivious to nulls.

    Hot-path autovectorization
    --------------------------
    Mojo 1.0.0b1's autovectorizer does NOT fire on unit-stride numeric
    loops. Each conformer's
    `eval_chunk` body MUST hand-stage SIMD via the
    `_typed_ptr_ro / load[width=W] / store[width=W]` pattern (see
    `komira_column_kernels.arithmetic:eval_add` for the canonical
    shape). The built-in conformers in `builtin_binary_fns.mojo`
    delegate to the existing `eval_add` / `eval_sub` / `eval_mul`
    primitives so they inherit the hand-staged kernel verbatim.

    Per-worker semantics
    --------------------
    `Copyable` — the operator builds N per-worker copies of the kernel
    struct (one per worker thread) into the worker-local op slab. The
    struct's fields (if any) are pure-data captures.
    """

    comptime TA: DType
    comptime TB: DType
    comptime TR: DType
    comptime OP_TAG: UInt8
    comptime KERNEL_ID: UInt32

    def name(self) -> String:
        ...

    # ---- HOT PATH — NON-RAISING ----
    #
    # `lhs` and `rhs` are typed input arrays with `lhs.length == rhs.length`.
    # `out` is a pre-allocated PrimitiveArray[Self.TR] of the same length
    # (allocated by the operator in raising context). The kernel writes
    # `out[0..count)` lane-by-lane (hand-staged SIMD). The kernel may NOT raise; correctness
    # errors must be caught at the operator's bind / construct time.
    # Validity is the operator's responsibility (the operator sets the
    # merged bitmap on `out` after / before this call).
    def eval_chunk(
        self,
        lhs: PrimitiveArray[Self.TA],
        rhs: PrimitiveArray[Self.TB],
        mut out: PrimitiveArray[Self.TR],
    ):
        ...
