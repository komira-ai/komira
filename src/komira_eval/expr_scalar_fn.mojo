# =============================================================================
# expr_scalar_fn.mojo — User-facing trait for SIMD UDFs in the Eigen tree
# =============================================================================
#
# `ExprScalarFn` — the user-facing trait for SIMD UDFs that participate in the typed Path A Eigen
# tree alongside built-in operators (Gt/Lt/And/Or/etc.). Composes fully into
# one fused kernel — no runtime registry lookup on the typed path.
#
# Audience for this trait:
#   - **Perf-critical SIMD UDF author** — z-score filter, custom vectorized
#     math, fraud detection rule. Per-lane logic that benefits from SIMD-chunk
#     fusion with built-in predicates. Examples: `IsPositiveF64`,
#     `AboveThreshold[t]`, `InRange[lo, hi]`, `EvenF64`.
#
# Anti-audience (use a different trait):
#   - **Per-row UDF** (regex, FFI to external lib, branch-heavy logic) — use
#     `FilterFn` from `komira_eval.filter_fn`. ExprScalarFn's
#     `@staticmethod fn eval_chunk[W]` is for lane-wise SIMD-friendly logic;
#     per-row branchy logic doesn't benefit from chunk dispatch.
#   - **Aggregation function** (sum, min, max, custom reducer) — use `AggFn`.
#   - **Casual user filter** (`col["a"] > 5`) — use built-in operators via
#     plain `df.filter[col["a"] > lit(5)]()`. No UDF struct needed.
#
# Design summary:
#   - Conformer is a comptime-parametric struct (zero fields, @fieldwise_init).
#   - `comptime UDF_ID: UInt32` — user-supplied unique ID in registered
#     range [7000, 9999]. Mojo 1.0.0b1 has no `_type_hash[T]()`; future watch.
#   - `comptime T_IN: DType` — the input SIMD DType.
#   - `comptime T_OUT: DType` — the output SIMD DType.
#   - `@staticmethod fn eval_chunk[W](input: SIMD[T_IN, W]) -> SIMD[T_OUT, W]`
#     — the lane-wise SIMD kernel. Engine drives the chunk loop; the UDF
#     produces W output lanes from W input lanes.
#
# Column flow is **explicit at the call site** via the Apply node:
# `ApplyScalarFnBool[ColF64["price", 0], MyUDF]`. The Apply node's `InExpr`
# type-param names the column; the UDF struct names the function. This
# separation matches the team-lead's "explicit column at call site" principle
# while keeping the UDF struct reusable across columns.
#
# Example conformer:
# ```mojo
# @fieldwise_init
# struct IsPositiveF64(ExprScalarFn):
#     comptime UDF_ID: UInt32 = 7100
#     comptime T_IN: DType = DType.float64
#     comptime T_OUT: DType = DType.bool
#
#     @staticmethod
#     fn eval_chunk[W: Int](input: SIMD[DType.float64, W]) -> SIMD[DType.bool, W]:
#         return input > SIMD[DType.float64, W](0.0)
# ```
#
# Composes with built-in operators inside `df.filter[E]`:
# ```mojo
# df.filter[
#     And[
#         ApplyScalarFnBool[ColF64["price", 0], IsPositiveF64],
#         Lt[ColF64["score", 1], LitF64[100.0]],
#     ]()
# ]()
# ```
#
# Why no `InRow: AutoKomiraSchema` on this trait (unlike FilterFn):
#   FilterFn is per-row — its `InRow` is the row struct (multi-field).
#   ExprScalarFn is per-CHUNK on ONE column's lanes — the input is
#   `SIMD[T_IN, W]` (one DType, W lanes), not a multi-field row. The
#   column reference lives on the Apply node's `InExpr` parameter, not
#   on the UDF trait. Cleaner separation; AutoKomiraSchema is irrelevant here.
#
# Positional-constructor limitation: NOT a blocker for ExprScalarFn.
#   Mojo cannot reach `@fieldwise_init`-synthesized positional CONSTRUCTOR access
#   through generic trait dispatch. ExprScalarFn never constructs an instance
#   of itself through a generic — it's @staticmethod only. The Apply node's
#   `Self.UDF.eval_chunk[W](...)` is a method dispatch, not a constructor
#   call; the same shape as the typed-expression `Self.L.depth()` /
#   `Self.L.to_expr()`, which work end-to-end.
#
# Future Mojo capability watch:
#   - User-definable macros would allow a `@scalar_expr_op` decorator that auto-generates the bracket-heavy
#     struct from a plain function. Pure UX layer; no architectural change.
#   - `_type_hash[T]()` for stable comptime type identity → auto-derive
#     `UDF_ID` from type hash; user no longer specifies it.
# =============================================================================

trait ExprScalarFn(Copyable, Movable, ImplicitlyCopyable):
    """User-facing trait for SIMD UDFs that participate in the Eigen tree.

    A conformer declares one static `eval_chunk[W]` method that maps a W-lane
    SIMD chunk of `T_IN` to a W-lane SIMD chunk of `T_OUT`. The engine drives
    the chunk loop and the conformer's kernel is monomorphized into the fused
    pipeline at AOT.

    Required user-supplied members:
      - `comptime UDF_ID: UInt32` — operator-factory selector. Choose a value
        in [7000, 9999] (the registered UDF range). Mojo 1.0.0b1 has no
        `_type_hash[T]()` so this can't yet auto-derive from type identity;
        documented as future-watch in the file header.
      - `comptime T_IN: DType` — the input column's DType. The Apply node's
        `InExpr` type-parameter must produce a `SIMD[T_IN, W]` chunk.
      - `comptime T_OUT: DType` — the output DType. For boolean predicates
        (filter UDFs), set `T_OUT = DType.bool` and wrap in `ApplyScalarFnBool`.
        For math (z-score-normalized value), set the matching numeric DType.
      - `@staticmethod fn eval_chunk[W](input: SIMD[T_IN, W]) -> SIMD[T_OUT, W]`
        — REQUIRED. The lane-wise SIMD kernel. The engine drives chunks of
        W=stdlib-native-SIMD-width; the conformer body produces W output
        lanes from W input lanes. Pure (no I/O), lane-independent (no
        cross-lane state).

    Why this is different from FilterFn:
      - FilterFn is per-row (input is one row struct). ExprScalarFn is
        per-chunk on ONE column's lanes (input is SIMD[T_IN, W]).
      - FilterFn doesn't compose with built-in operators (it's opaque). ExprScalarFn
        composes with Gt/Lt/Eq/And/Or via Apply node Eigen-tree participation.
      - FilterFn can hold captures (mut self with state). ExprScalarFn is
        @staticmethod-only (no state) — that's what enables full AOT fusion.

    The bracket-heavy invocation syntax is the accepted tradeoff for
    explicit-column-at-call-site UX. Once Mojo lands user-definable macros,
    the `@scalar_expr_op` decorator will generate the bracket form from a
    plain function — no architectural rework, just UX cleanup.

    Examples:
        ```mojo
        from komira_sdk import ExprScalarFn
        # a lane-wise SIMD kernel that doubles a Float64 column
        struct DoubleF64(ExprScalarFn):
            comptime UDF_ID: UInt32 = 7001    # pick in [7000, 9999]
            comptime T_IN: DType = DType.float64
            comptime T_OUT: DType = DType.float64
            @staticmethod
            def eval_chunk[W: Int](input: SIMD[DType.float64, W]) -> SIMD[DType.float64, W]:
                return input * 2.0
        ```
    (example not yet doctest-verified)
    """

    comptime UDF_ID: UInt32
    comptime T_IN: DType
    comptime T_OUT: DType

    @staticmethod
    def eval_chunk[W: Int](input: SIMD[Self.T_IN, W]) -> SIMD[Self.T_OUT, W]:
        """REQUIRED — W lanes in, W lanes out. The lane-wise SIMD kernel."""
        ...
