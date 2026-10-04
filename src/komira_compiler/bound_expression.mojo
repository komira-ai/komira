# =============================================================================
# komira_compiler.bound_expression — BoundExpression skeleton
# =============================================================================
#
# Status: Phase 0 SKELETON. This file defines the index-resolved typed AST
# surface that mirrors `komira_eval.expr_ast` ExprXX traits + LitXX structs,
# with one critical difference: column access is by RESOLVED INDEX
# (`BoundCol[col_idx: Int, dtype: DType]`) rather than by name. This is the
# planner output type — the optimizer produces a `BoundExpression`-shaped
# tree once schemas have been resolved.
#
# Phase 1 will land:
#   - the full `from_expr_ast(...)` walker that consumes an `ExprXX`-conforming
#     comptime AST + the schema and produces the bound form with `col_idx`
#     resolved;
#   - the per-DType bound binop family (`BoundGtI64`, `BoundLtF64`, ...) that
#     mirrors A's M2;
#   - `BoundAnd` / `BoundOr` homogeneous over `BoundExprBool` (mirrors A's M3);
#   - the eventual `evaluate[S: Schema, W: Int](batch: BatchOf[S], i: Int) ->
#     SIMD[T, W]` body signature shared with the comptime AST surface.
#
# For Phase 0 skeleton we ship:
#   - 5 per-DType bound-Expr traits (`BoundExprI64`, `BoundExprI32`,
#     `BoundExprF32`, `BoundExprF64`, `BoundExprBool`);
#   - 5 BoundLit structs (`BoundLitI64[v]`, ...) — these are the comptime-
#     value literal forms, identical in shape to `LitI64` etc. on the comptime
#     AST side. They are NOT redundant: they're the BOUND-side leaf form a
#     factory walker will eventually construct when the source AST node is
#     a `LitI64` (no schema resolution needed for literals);
#   - 5 BoundCol structs (`BoundColI64[col_idx]`, ...) — the KEY distinguishing
#     feature of the bound surface: resolved-index column access. `col_idx`
#     is the OFFSET into the resolved schema's column array; per-DType so the
#     trait conformance pins the output type at the type level;
#   - `from_expr_ast(...) -> BoundExpression???` factory STUB that `raise`s
#     "not implemented in Phase 0". Phase 1 will replace this with a per-trait
#     walker. The stub exists so callers can refer to the symbol without
#     making it un-importable; the production gate at Phase 1 is the body
#     swap, not a new symbol.
#
# =============================================================================
# Package-ownership invariant — DO NOT CROSS
# =============================================================================
#
# BoundExpression lives
# in `komira_compiler` (NOT `komira_eval`). The comptime AST surface
# (ExprXX traits + LitXX) lives in `komira_eval.expr_ast`.
#
# These are **parallel hierarchies** by design:
#   - komira_eval owns the COMPTIME / RUNTIME source AST (what the user
#     wrote via the SDK surface).
#   - komira_compiler owns the INDEX-RESOLVED bound AST (what the planner
#     emits after resolving names → column indices + dtypes against the
#     schema).
#
# This file MUST NOT import from `komira_eval`. The two hierarchies share
# NAMES only (`BoundExprI64` mirrors `ExprI64`'s shape), never traits — a
# `BoundExprI64` conformer is NOT a valid `ExprI64`, and the per-DType
# decomposition is repeated rather than re-exported.
#
# =============================================================================
# Mojo 1.0.0b1 idioms required to read / extend this file
# =============================================================================
#
# Mirrors `komira_eval.expr_ast` — read the long idiom block in that file
# for the rationale. Two-line recap:
#
# 1. **`Self.v` qualifier for comptime VALUE params.** Inside an
#    `@staticmethod` body of `struct BoundLitI64[v: Int64]`, the comptime
#    parameter `v` must be referenced as `Self.v`, NOT bare `v`.
# 2. **`@fieldwise_init` is MANDATORY** on every zero-field BoundLit / BoundCol
#    struct. The trait declarations conform to
#    `Copyable, Movable, ImplicitlyCopyable`, which require a constructible
#    instance. `@fieldwise_init` synthesizes the no-arg default constructor.
# 3. **`(Copyable, Movable, ImplicitlyCopyable)` super-traits compose verbatim.**
#
# Why per-DType decomposition (mirroring expr_ast): parametric trait
# declarations and `[*]` wildcard-arg form do NOT compile in Mojo 1.0.0b1.
# Same fallback applies here.
#
# =============================================================================


# -----------------------------------------------------------------------------
# Per-DType BoundExpr traits
# -----------------------------------------------------------------------------
# Each trait pins ONE concrete result DType. Mirrors the ExprXX trait family
# in `komira_eval.expr_ast`. The Phase 0 `evaluate` signature is
# parameter-free; Phase 1 rewrites bodies to `evaluate[S, W](batch, i)` once
# `BatchOf` + `Column.load_via_sel` exist. Struct shapes (trait
# names, conformer names, parameter shapes) do NOT change between P0 and P1.
#
# Plan-time depth check: each conformer also exposes a `depth` static
# method. Phase 0 leaf nodes return 1; Phase 1 binops will return
# `Self.L.depth + Self.R.depth` (parallel to the comptime side once
# the binop family lands).

trait BoundExprI64(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    @staticmethod
    def evaluate() -> Int64:
        ...

    @staticmethod
    def depth() -> Int:
        ...


trait BoundExprI32(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    @staticmethod
    def evaluate() -> Int32:
        ...

    @staticmethod
    def depth() -> Int:
        ...


trait BoundExprF32(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    @staticmethod
    def evaluate() -> Float32:
        ...

    @staticmethod
    def depth() -> Int:
        ...


trait BoundExprF64(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    @staticmethod
    def evaluate() -> Float64:
        ...

    @staticmethod
    def depth() -> Int:
        ...


trait BoundExprBool(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    @staticmethod
    def evaluate() -> Bool:
        ...

    @staticmethod
    def depth() -> Int:
        ...


# -----------------------------------------------------------------------------
# BoundLit family — comptime-value leaves
# -----------------------------------------------------------------------------
# Bound-side mirror of LitI64/LitI32/LitF32/LitF64/LitBool. Identical shape:
# value is a comptime parameter; `evaluate` returns `Self.v`. These exist
# on the bound side (rather than being re-imported from komira_eval) to
# preserve the package-ownership invariant — the two hierarchies share NAMES
# only, never traits.
#
# Body invariant: `return Self.v`, NEVER bare `v`.
# `depth` returns 1 for leaves; Phase 1 binops will recurse.

@fieldwise_init
struct BoundLitI64[v: Int64](BoundExprI64):
    @staticmethod
    def evaluate() -> Int64:
        return Self.v

    @staticmethod
    def depth() -> Int:
        return 1


@fieldwise_init
struct BoundLitI32[v: Int32](BoundExprI32):
    @staticmethod
    def evaluate() -> Int32:
        return Self.v

    @staticmethod
    def depth() -> Int:
        return 1


@fieldwise_init
struct BoundLitF32[v: Float32](BoundExprF32):
    @staticmethod
    def evaluate() -> Float32:
        return Self.v

    @staticmethod
    def depth() -> Int:
        return 1


@fieldwise_init
struct BoundLitF64[v: Float64](BoundExprF64):
    @staticmethod
    def evaluate() -> Float64:
        return Self.v

    @staticmethod
    def depth() -> Int:
        return 1


@fieldwise_init
struct BoundLitBool[v: Bool](BoundExprBool):
    @staticmethod
    def evaluate() -> Bool:
        return Self.v

    @staticmethod
    def depth() -> Int:
        return 1


# -----------------------------------------------------------------------------
# BoundCol family — resolved-index column accessors
# -----------------------------------------------------------------------------
# The KEY distinguishing feature of the bound AST surface vs. the source AST:
# column access is by RESOLVED INDEX (comptime `col_idx: Int`), not by name.
# Per-DType so the trait conformance pins the output type at the type level
# (mirrors the per-DType ColXX family in komira_sdk).
#
# Phase 0 skeleton: `col_idx` is held as a comptime parameter; the `evaluate`
# body is a placeholder that returns the zero value of the dtype. Phase 1 will
# rewrite the body to `batch.column[col_idx].load_via_sel(sel, k)` once the
# BatchOfS / Column.load_via_sel surface exists.
#
# `depth` returns 1 for leaves (col accesses don't recurse).
#
# Index semantics: `col_idx` is the OFFSET into the resolved schema's column
# array; the factory walker (`from_expr_ast`) will be responsible for
# resolving names → indices against the schema. A negative `col_idx` is a
# placeholder for "unresolved" (Phase 0 only — Phase 1 will raise on a
# walker-produced negative index).

@fieldwise_init
struct BoundColI64[col_idx: Int](BoundExprI64):
    @staticmethod
    def evaluate() -> Int64:
        # Phase 0 skeleton: placeholder body. Phase 1 will replace with
        # `batch.column[col_idx].load_via_sel(sel, k)`.
        return Int64(0)

    @staticmethod
    def depth() -> Int:
        return 1


@fieldwise_init
struct BoundColI32[col_idx: Int](BoundExprI32):
    @staticmethod
    def evaluate() -> Int32:
        return Int32(0)

    @staticmethod
    def depth() -> Int:
        return 1


@fieldwise_init
struct BoundColF32[col_idx: Int](BoundExprF32):
    @staticmethod
    def evaluate() -> Float32:
        return Float32(0.0)

    @staticmethod
    def depth() -> Int:
        return 1


@fieldwise_init
struct BoundColF64[col_idx: Int](BoundExprF64):
    @staticmethod
    def evaluate() -> Float64:
        return Float64(0.0)

    @staticmethod
    def depth() -> Int:
        return 1


@fieldwise_init
struct BoundColBool[col_idx: Int](BoundExprBool):
    @staticmethod
    def evaluate() -> Bool:
        return False

    @staticmethod
    def depth() -> Int:
        return 1


# -----------------------------------------------------------------------------
# from_expr_ast — factory stub (Phase 0)
# -----------------------------------------------------------------------------
# Stub for the AST-walking factory that Phase 1 will replace with a per-trait
# walker. The walker will consume a comptime-parametric `ExprXX`-conforming
# AST + a schema and produce a BoundExpression with names resolved to
# indices.
#
# Phase 0 ships this as a per-DType set of `raise`-only stubs. The reason
# we don't simply omit the symbol is so that callers can:
#   1) refer to the function (e.g. in early compile-paths or stubbed tests)
#      without an import error, and
#   2) the production gate at Phase 1 is the body swap, not the introduction
#      of a new symbol — which avoids a churn diff at landing time.
#
# These are comptime-parametric over the input AST type `E`, mirroring how
# Phase 1's walker will dispatch on the trait it sees. For Phase 0 they all
# raise; the per-DType decomposition is repeated so the return type pins
# correctly under the trait conformance.

def from_expr_ast_i64[E: BoundExprI64](var ast: E) raises -> BoundLitI64[0]:
    raise Error("BoundExpression lowering lands in Phase 1 (Slot WAVE-11-P1-*)")


def from_expr_ast_i32[E: BoundExprI32](var ast: E) raises -> BoundLitI32[0]:
    raise Error("BoundExpression lowering lands in Phase 1 (Slot WAVE-11-P1-*)")


def from_expr_ast_f32[E: BoundExprF32](var ast: E) raises -> BoundLitF32[0.0]:
    raise Error("BoundExpression lowering lands in Phase 1 (Slot WAVE-11-P1-*)")


def from_expr_ast_f64[E: BoundExprF64](var ast: E) raises -> BoundLitF64[0.0]:
    raise Error("BoundExpression lowering lands in Phase 1 (Slot WAVE-11-P1-*)")


def from_expr_ast_bool[E: BoundExprBool](var ast: E) raises -> BoundLitBool[False]:
    raise Error("BoundExpression lowering lands in Phase 1 (Slot WAVE-11-P1-*)")
