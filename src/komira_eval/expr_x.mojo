# =============================================================================
# expr_x.mojo — Per-batch Expr trait family
# =============================================================================
#
# The "X" suffix stands for "eXecution-time per-batch": per-DType trait
# families evaluated inside a fused per-batch stage loop.
#
# Differentiation from the typed expression AST `Expr{Bool,I64,F64}`:
#
#   - Expr{Bool,I64,F64} are comptime-folding AST nodes used for plan
#     lowering. Their trait shape:
#         @staticmethod fn evaluate() -> T
#         @staticmethod fn depth() -> Int
#         @staticmethod fn to_expr() raises -> Expr
#     No batch parameter; the AST folds at compile time.
#
#   - ExprX{Bool,I64,F64,String} are PER-BATCH execution-time evaluators.
#     Their trait shape:
#         @staticmethod fn eval[W, bo](batch: BatchView[bo], i: Int) -> SIMD[T, W]
#         @staticmethod fn eval_scalar[bo](batch: BatchView[bo], i: Int) -> T
#         @staticmethod fn depth() -> Int
#     SIMD-aware; consumes a typed BatchView; conformers are the per-row
#     accessors (ColXI64 / LitXI64 / GeXI64 etc.) that fused stage primitives
#     monomorphize into ONE fused per-batch function.
#
# CRITICAL ARCHITECTURAL PROPERTIES:
#
#   1. NO trait method is `@always_inline` at the trait declaration — Mojo
#      monomorphization handles inlining at conformer-call sites. Trait
#      declarations only specify the signature contract.
#   2. Conformers' `eval` methods carry `@always_inline` (mandatory; this
#      is what enables Mojo's monomorphizer to inline the per-DType trait
#      method into the fused-stage loop body): a stage's `process_batch`
#      inlines Pred + GroupKey + AggVal + AggOp.update_chunk into ONE
#      function body.
#   3. NO @always_inline on the recursive walker fallback; only on
#      per-chunk hot paths.
#   4. The `bo: Origin[mut=False]` parameter is the per-batch lifetime
#      witness; it threads through every conformer call so the compiler
#      tracks the BatchView's parent RecordBatch lifetime end-to-end.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins (`MutAnyOrigin` / `MutExternalOrigin` /
#     `ImmutAnyOrigin`).
#   - All BatchView references threaded via `BatchView[bo: Origin[mut=False]]`.
#
# Cross-references:
#   - komira_core.collections.batch_view — BatchView + ColView surfaces.
# =============================================================================

from komira_core.collections.batch_view import BatchView
from komira_core.collections.multi_column_builder import (
    MultiColumnSink,
    SinkKind,
)
from komira_core.plan.expr import Expr

from komira_eval.column_resolver import ColumnResolver
from komira_eval.predicate import Predicate
from komira_eval.row_transform import RowTransform


# =============================================================================
# §2.6 refinement edges
# =============================================================================
#
# The per-batch ExprX trait family (`ExprXBool` / `ExprXI64`
# / ...) is wired into the three unified UDF trait
# surfaces (`Predicate` / `RowTransform` / `Aggregator`) via trait inheritance
# so the variadic Stage substrate sees a `Predicate` /
# `RowTransform` view of every ExprX conformer with NO adapter struct:
#
#   - `trait ExprXBool(Predicate, ...)` — the boolean Expr is a row->Bool
#     predicate.
#   - `trait ExprX{I64,F64,I32,F32,String}(RowTransform, ...)` — a numeric /
#     string Expr is a single-output row->row transform.
#
# THE NAME-COLLISION RENAME (Option A — rename-not-reshape). The ExprX
# conformers KEEP their `@staticmethod` SIMD internals — the engine hot path
# dispatches STATICALLY through the comptime type parameter
# (`Self.Pred.eval_simd[W, bo]`), never through a trait method, which is what
# preserves the zero-`bl` property. But the ExprX
# trait family's OWN static methods `eval` / `eval_scalar` COLLIDE with the
# unified-trait instance methods `Predicate.eval` / `Predicate.eval_scalar` /
# (and would shadow a `RowTransform` method). Mojo 1.0.0b1: a same-named
# `@staticmethod` does NOT satisfy an inherited instance-method requirement.
# Resolution: the ExprX family's own static methods are renamed off the
# collision — `eval` -> `eval_simd`, `eval_scalar` -> `eval_scalar_s` — and a
# DELEGATING DEFAULT BODY on each refining trait satisfies the parent's
# abstract instance method by forwarding to the renamed static.
#
# FINDING #1 (Mojo 1.0.0b1): a refining trait CANNOT override a parent trait's
# already-DEFAULTED method with its own default body ("conflicting default
# implementations ... you must implement it manually"). So `ExprXBool` does
# NOT override `Predicate.eval[W]` (which carries the Pattern B default) — it
# inherits the per-lane fan-out default unchanged. This does NOT regress the
# engine's zero-`bl` property: the engine hot path calls the conformer's
# `eval_simd` STATICALLY through the type parameter; the `Predicate.eval[W]`
# trait method is the SLOW unified-view path, and its default body
# monomorphizes to zero-`bl` + LLVM auto-fuses the
# per-lane compares into vector compares.
# =============================================================================


# =============================================================================
# §1 — ExprXBool — per-batch Boolean Expr trait (refines Predicate)
# =============================================================================
#
# Conformers: column accessor (ColXBool), literal (LitXBool), comparison
# binops (GeXI64 / LtXI64 / LeXI64 / GtXI64 / EqXI64 / NeXI64 over Int64,
# similar for F64; SubstrEqXString etc. for String), logical binops
# (AndX / OrX / NotX), Kleene-aware variants for nullable columns.
# The conformers live in expr_x_conformers.mojo; this file ships the TRAIT
# DECLARATION only.
# =============================================================================


trait ExprXBool(Predicate, Copyable, Movable, ImplicitlyCopyable):
    """Per-batch Boolean Expr — execution-time evaluator. Refines `Predicate`.

    The hot-path SIMD shape: `eval_simd[W, bo](self, batch, i)` returns a
    `SIMD[DType.bool, W]` lane vector for W contiguous rows starting at
    logical index `i`. Conformers carry `@always_inline` so Mojo's
    monomorphizer inlines them into the fused-stage inner loop.

    The scalar tail shape: `eval_scalar_s[bo](self, batch, i)` returns a `Bool`
    for one row; conformers also carry `@always_inline`. The fused-stage
    loops over SIMD chunks then a scalar tail.

    The `depth()` accessor is used by the planner for cost-model
    estimates (deeper Expr trees suggest higher per-row cost); not
    used by hot-path code.

    Predicate conformance: `ExprXBool` refines
    `Predicate`. The conformer's own `eval_simd` / `eval_scalar_s` are
    renamed off the collision with `Predicate.eval` / `eval_scalar`; the
    instance `Predicate.eval_scalar` is satisfied by the delegating default
    body below. `Predicate.eval[W]` (the Pattern B per-lane default) is
    inherited UNCHANGED — a refining trait cannot override a parent's
    defaulted method (finding #1).

    `eval_simd` / `eval_scalar_s` flipped
    from `@staticmethod` to INSTANCE methods. Binop conformers now store sub-Expr
    instances as `var left: Self.L` / `var right: Self.R` FIELDS and dispatch via
    field access (`self.left.eval_simd[W, bo](batch, i)`). The `fn __init__(out
    self)` requirement supports zero-arg construction (`F()`) in generic contexts.
    This shape is verified across a 32-conformer cross-instantiation matrix.
    """

    def __init__(out self):
        ...

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        ...

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        ...

    @staticmethod
    def depth() -> Int:
        ...

    # --- to_expr() — runtime Expr lowering surface -----------------
    # Each conformer publishes a `@staticmethod fn to_expr() raises -> Expr`
    # that produces the runtime LogicalPlan walker `Expr` tree (col_ref /
    # literal / binary) matching its comptime shape. A typed filter lowers
    # via `E.to_expr()` to attach the predicate to the underlying runtime
    # LogicalPlan as a `Filter` node.
    @staticmethod
    def to_expr() raises -> Expr:
        ...

    # --- bind: runtime name->idx resolution + optional ArrowType validation -----
    def bind(mut self, resolver: ColumnResolver) raises:
        """Walk the Expr tree at Stage init, populating each leaf's `_idx`
        from `resolver.index_for(name)` + (per-leaf) defensive ArrowType
        validation against `resolver.arrow_type_for(name)`. Composite binops
        recurse into `self.left.bind(resolver); self.right.bind(resolver)`.
        Literals + stubs no-op.

        Default body: NO-OP — most conformers don't carry runtime-bound
        state (literals, stubs). Conformers that DO carry state override
        with the populate-self pattern (leaves) or recursive walk
        (composites). The default-no-op shape lets every existing
        conformer satisfy the trait surface without per-struct edits."""
        pass

    # --- Predicate refinement: delegating default body ---------------------
    def eval_scalar[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) raises -> Bool:
        """`Predicate.eval_scalar` — delegating default body. Forwards to the
        conformer's renamed instance `eval_scalar_s`. Every `ExprXBool`
        conformer transitively conforms to `Predicate` for free; the engine
        hot path still calls `eval_simd` statically through the type
        parameter + field access (B-revised pattern)."""
        return self.eval_scalar_s[bo](batch, i)


# =============================================================================
# §2 — ExprXI64 — per-batch Int64 Expr trait
# =============================================================================
#
# Conformers: column accessor (ColXI64), literal (LitXI64[v]), arithmetic
# binops (AddXI64 / SubXI64 / MulXI64 / DivXI64), cast nodes (CastXI64FromF64,
# CastXI64FromString), composite-key packing helpers (GroupKey2I64Packed
# lifted to production as CompositeKey* in composite_key.mojo).
# =============================================================================


trait ExprXI64(RowTransform, Copyable, Movable, ImplicitlyCopyable):
    """Per-batch Int64 Expr — execution-time evaluator. Refines `RowTransform`.

    See ExprXBool for the architectural shape rationale; this trait
    mirrors the same surface but returns `SIMD[DType.int64, W]` /
    `Int64`.

    RowTransform conformance: `ExprXI64` refines
    `RowTransform` as a single-output (`ARITY = 1`) row->row transform. The
    conformer's own `eval_simd` / `eval_scalar_s` are renamed off the
    collision; `RowTransform.dtype_at[k]` + `write_one` are satisfied by the
    delegating default bodies below.

    `eval_simd` / `eval_scalar_s` are
    INSTANCE methods. See ExprXBool docstring for the FIELD-based binop pattern.
    """

    def __init__(out self):
        ...

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int64, W]:
        ...

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int64:
        ...

    @staticmethod
    def depth() -> Int:
        ...

    # --- to_expr() — runtime Expr lowering surface -----------------
    # See ExprXBool.to_expr docstring for the contract. ExprXI64 conformers
    # produce `Expr.col_ref(name)` (ColXI64), `Expr.literal(from_int64(v))`
    # (LitXI64), and `Expr.binary(BIN_*, ...)` (arithmetic + composite).
    @staticmethod
    def to_expr() raises -> Expr:
        ...

    # --- bind: runtime name->idx resolution -----------------------
    # NOTE: there is no no-op `bind` default here because `bind` lives on
    # the parent `RowTransform` trait. Mojo 1.0.0b1 rejects conflicting
    # default impls on parent + refining trait ("trait method requirement
    # 'bind' has conflicting default implementations" — same finding #1 the
    # `eval[W]` Pattern-B default sits behind). Conformers inherit the no-op
    # default from RowTransform; leaves + composites override as before. See
    # ExprXBool.bind for the override pattern.

    # --- RowTransform refinement: delegating default bodies ----------------
    @staticmethod
    def out_kind_at[k: Int]() -> SinkKind:
        """`RowTransform.out_kind_at` — a numeric Expr writes through the
        NUMERIC value channel (`append_at[k, DT]`)."""
        return SinkKind.NUMERIC

    @staticmethod
    def dtype_at[k: Int]() -> DType:
        """`RowTransform.dtype_at` — single Int64 output column."""
        return DType.int64

    def write_one[
        bo: Origin[mut=False], MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.write_one` — delegating default body. Lands the
        single Int64 output value (via the renamed instance `eval_scalar_s`)
        into output slot 0."""
        builders.append_at[0, DType.int64](self.eval_scalar_s[bo](batch, i))

    def project_one[
        bo: Origin[mut=False], dst_k: Int, MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.project_one` — instance delegating default body.

        `RowTransform.project_one`
        flipped from `@staticmethod` to `mut self` so `ProjectList.emit_projected`
        can dispatch through the stored Out instance (whose runtime `_idx`
        was populated by `bind`). The trait default body now reads `self`
        directly — no more `var inst = Self()` zero-arg construction.

        Lands the single Int64 output value into builder slot `dst_k`."""
        builders.append_at[dst_k, DType.int64](self.eval_scalar_s[bo](batch, i))


# =============================================================================
# §3 — ExprXF64 — per-batch Float64 Expr trait
# =============================================================================


trait ExprXF64(RowTransform, Copyable, Movable, ImplicitlyCopyable):
    """Per-batch Float64 Expr — execution-time evaluator. Refines
    `RowTransform`.

    Mirrors ExprXI64 with `SIMD[DType.float64, W]` / `Float64`.

    INSTANCE-method dispatch shape.
    """

    def __init__(out self):
        ...

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        ...

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        ...

    @staticmethod
    def depth() -> Int:
        ...

    # --- to_expr() — runtime Expr lowering surface -----------------
    # See ExprXBool.to_expr docstring for the contract.
    @staticmethod
    def to_expr() raises -> Expr:
        ...

    # --- bind: runtime name->idx resolution -----------------------
    # NOTE: there is no no-op `bind` default here because `bind` lives on
    # the parent `RowTransform` trait. Mojo 1.0.0b1 rejects conflicting
    # default impls on parent + refining trait ("trait method requirement
    # 'bind' has conflicting default implementations" — same finding #1 the
    # `eval[W]` Pattern-B default sits behind). Conformers inherit the no-op
    # default from RowTransform; leaves + composites override as before. See
    # ExprXBool.bind for the override pattern.

    # --- RowTransform refinement: delegating default bodies ----------------
    @staticmethod
    def out_kind_at[k: Int]() -> SinkKind:
        """`RowTransform.out_kind_at` — a numeric Expr writes through the
        NUMERIC value channel (`append_at[k, DT]`)."""
        return SinkKind.NUMERIC

    @staticmethod
    def dtype_at[k: Int]() -> DType:
        """`RowTransform.dtype_at` — single Float64 output column."""
        return DType.float64

    def write_one[
        bo: Origin[mut=False], MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.write_one` — delegating default body. Lands the
        single Float64 output value into output slot 0."""
        builders.append_at[0, DType.float64](self.eval_scalar_s[bo](batch, i))

    def project_one[
        bo: Origin[mut=False], dst_k: Int, MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.project_one` — instance delegating default body.
        Flipped from @staticmethod to mut
        self. See ExprXI64.project_one docstring for the cascade rationale.
        Lands the single Float64 output value into builder slot `dst_k`."""
        builders.append_at[dst_k, DType.float64](
            self.eval_scalar_s[bo](batch, i)
        )


# =============================================================================
# §3b — ExprXF32 — per-batch Float32 Expr trait
#
# =============================================================================
#
# Mirror of ExprXF64 with Float32 / SIMD[DType.float32, W] return types. Use
# cases: F32 column accessor + F32 literal + F32 arithmetic + F32 comparison
# walker.
#
# Note: F32 EQ/NE are not provided here (NaN-semantics discipline matching
# the F64 side).
# =============================================================================


trait ExprXF32(RowTransform, Copyable, Movable, ImplicitlyCopyable):
    """Per-batch Float32 Expr — execution-time evaluator. Refines
    `RowTransform`.

    Mirrors ExprXF64 / ExprXI64 with `SIMD[DType.float32, W]` / `Float32`.

    INSTANCE-method dispatch shape.
    """

    def __init__(out self):
        ...

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        ...

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        ...

    @staticmethod
    def depth() -> Int:
        ...

    # --- to_expr() — runtime Expr lowering surface -----------------
    # See ExprXBool.to_expr docstring for the contract.
    @staticmethod
    def to_expr() raises -> Expr:
        ...

    # --- bind: runtime name->idx resolution -----------------------
    # NOTE: there is no no-op `bind` default here because `bind` lives on
    # the parent `RowTransform` trait. Mojo 1.0.0b1 rejects conflicting
    # default impls on parent + refining trait ("trait method requirement
    # 'bind' has conflicting default implementations" — same finding #1 the
    # `eval[W]` Pattern-B default sits behind). Conformers inherit the no-op
    # default from RowTransform; leaves + composites override as before. See
    # ExprXBool.bind for the override pattern.

    # --- RowTransform refinement: delegating default bodies ----------------
    @staticmethod
    def out_kind_at[k: Int]() -> SinkKind:
        """`RowTransform.out_kind_at` — a numeric Expr writes through the
        NUMERIC value channel (`append_at[k, DT]`)."""
        return SinkKind.NUMERIC

    @staticmethod
    def dtype_at[k: Int]() -> DType:
        """`RowTransform.dtype_at` — single Float32 output column."""
        return DType.float32

    def write_one[
        bo: Origin[mut=False], MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.write_one` — delegating default body. Lands the
        single Float32 output value into output slot 0."""
        builders.append_at[0, DType.float32](self.eval_scalar_s[bo](batch, i))

    def project_one[
        bo: Origin[mut=False], dst_k: Int, MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.project_one` — instance delegating default body.
        Flipped from @staticmethod to mut
        self. See ExprXI64.project_one docstring for the cascade rationale.
        Lands the single Float32 output value into builder slot `dst_k`."""
        builders.append_at[dst_k, DType.float32](
            self.eval_scalar_s[bo](batch, i)
        )


# =============================================================================
# §3c — ExprXI32 — per-batch Int32 Expr trait
#
# =============================================================================
#
# Mirror of ExprXI64 with Int32 / SIMD[DType.int32, W] return types. Use
# cases: I32 column accessor + I32 literal + I32 arithmetic + I32 comparison.
# Mirrors the runtime walker side's I32 arithmetic.
#
# Also covers Date32 (Arrow Date32 is Int32 days-since-epoch — same storage,
# different semantics; callers wanting date semantics use col_date32 + the
# same ExprXI32 trait operating on Int32 day counts).
# =============================================================================


trait ExprXI32(RowTransform, Copyable, Movable, ImplicitlyCopyable):
    """Per-batch Int32 Expr — execution-time evaluator. Refines
    `RowTransform`.

    Mirrors ExprXI64 with `SIMD[DType.int32, W]` / `Int32`.

    Also serves Date32 (Int32-aliased) column reads.

    INSTANCE-method dispatch shape.
    """

    def __init__(out self):
        ...

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        ...

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        ...

    @staticmethod
    def depth() -> Int:
        ...

    # --- to_expr() — runtime Expr lowering surface -----------------
    # See ExprXBool.to_expr docstring for the contract.
    @staticmethod
    def to_expr() raises -> Expr:
        ...

    # --- bind: runtime name->idx resolution -----------------------
    # NOTE: there is no no-op `bind` default here because `bind` lives on
    # the parent `RowTransform` trait. Mojo 1.0.0b1 rejects conflicting
    # default impls on parent + refining trait ("trait method requirement
    # 'bind' has conflicting default implementations" — same finding #1 the
    # `eval[W]` Pattern-B default sits behind). Conformers inherit the no-op
    # default from RowTransform; leaves + composites override as before. See
    # ExprXBool.bind for the override pattern.

    # --- RowTransform refinement: delegating default bodies ----------------
    @staticmethod
    def out_kind_at[k: Int]() -> SinkKind:
        """`RowTransform.out_kind_at` — a numeric Expr writes through the
        NUMERIC value channel (`append_at[k, DT]`)."""
        return SinkKind.NUMERIC

    @staticmethod
    def dtype_at[k: Int]() -> DType:
        """`RowTransform.dtype_at` — single Int32 output column."""
        return DType.int32

    def write_one[
        bo: Origin[mut=False], MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.write_one` — delegating default body. Lands the
        single Int32 output value into output slot 0."""
        builders.append_at[0, DType.int32](self.eval_scalar_s[bo](batch, i))

    def project_one[
        bo: Origin[mut=False], dst_k: Int, MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.project_one` — instance delegating default body.
        Flipped from @staticmethod to mut
        self. See ExprXI64.project_one docstring for the cascade rationale.
        Lands the single Int32 output value into builder slot `dst_k`."""
        builders.append_at[dst_k, DType.int32](self.eval_scalar_s[bo](batch, i))


# =============================================================================
# §4 — ExprXString — per-batch String Expr trait
# =============================================================================
#
# CRITICAL DIFFERENCE from numeric ExprX variants: NO SIMD method (no
# `eval[W]`). Strings are not SIMD-able in a uniform-width sense — Arrow
# StringArray stores variable-width payloads with offsets, so per-row
# extraction is fundamentally scalar.
#
# Conformers can still be optimized internally (e.g. SIMD memcmp for
# fixed-width prefix predicates) but the trait surface exposes a scalar
# extractor only.
# =============================================================================


trait ExprXString(RowTransform, Copyable, Movable, ImplicitlyCopyable):
    """Per-batch String Expr — scalar-only execution-time evaluator.

    No SIMD method by design. Conformers (ColXString / LitXString /
    SubstrXString / etc.) return one String per row. The fused-stage
    loop unrolls W rows scalar-wise when consuming a String Expr.

    Note: the `eval_scalar_s` return type is `String` (the stdlib heap-
    owning value). Accessors could return `StringView` / `Span[UInt8]`
    if string-allocation overhead dominates.

    `ExprXString` REFINES `RowTransform`.

    The `RowTransform` -> `MultiColumnSink` -> `MultiColumnBuilder` ->
    `ColumnSlot[dt]` -> `ColumnBuilder[dt]` chain is `Scalar[DType]`-only
    and no `DType` holds a String, so a String `RowTransform` conformer
    appends through `StringColumnSlot` (the second `ColumnSink` conformer) reached through
    `MultiColumnSink.append_string_at[k]`.

    Two members carry the difference:
      * `out_kind_at[k]()` returns `SinkKind.STRING` — the fact a caller
        reads BEFORE `dtype_at[k]()` to pick the sink type and the append
        method.
      * `dtype_at[k]()` returns a documented PLACEHOLDER. There is no DType
        that means String and Mojo 1.0.0 removed `DType.invalid`; the
        placeholder is unreachable for anyone who consults `out_kind_at`
        first, which every in-tree dispatcher does.

    NO SIMD, still. `write_one` / `project_one` go one row at a time
    through `eval_scalar_s`, which is the same scalar shape the rest of
    this trait already had — Arrow StringArray is variable-width, so there
    is no lane-parallel form to lose.

    NOT NULLABLE, and this is a real limit rather than an oversight.
    `eval_scalar_s` returns a `String` and has no way to say NULL, so a
    String projection through this trait always produces a VALID row. The
    sink itself distinguishes null from `""` (`append_null_value` vs
    `append_string_value("")`); it is this trait's return type that cannot
    reach the null. Widening it belongs with the Kleene-aware ExprX edge,
    not here.

    INSTANCE-method dispatch shape.
    """

    def __init__(out self):
        ...

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> String:
        ...

    @staticmethod
    def depth() -> Int:
        ...

    # --- to_expr() — runtime Expr lowering surface -----------------
    # ExprXString conformers produce `Expr.col_ref(name)` (ColXString) or
    # `Expr.literal(from_string(s))` (LitXString). LikeXString defers (no
    # BIN_LIKE in Expr; see conformer body for details).
    @staticmethod
    def to_expr() raises -> Expr:
        ...

    # --- bind: runtime name->idx resolution -----------------------
    # NOTE UDF-STRING: the no-op `bind` default that used to
    # live here is REMOVED because `ExprXString` now refines `RowTransform`,
    # which already carries one. Mojo 1.0.0b1 rejects conflicting default
    # impls on parent + refining trait ("trait method requirement 'bind' has
    # conflicting default implementations"). Conformers
    # inherit the no-op default from RowTransform; leaves + composites
    # override (see `ColXString.bind`). ExprXI64 et al. follow the same
    # rule.

    # --- RowTransform refinement: delegating default bodies ----------------
    @staticmethod
    def out_kind_at[k: Int]() -> SinkKind:
        """`RowTransform.out_kind_at` — this transform writes STRINGS.

        The override that makes the whole edge work: it is what tells
        `ProjectList.emit_projected` to build a `StringColumnSlot` for this
        output column and to drive `append_string_at` rather than
        `append_at`.
        """
        return SinkKind.STRING

    @staticmethod
    def dtype_at[k: Int]() -> DType:
        """`RowTransform.dtype_at` — PLACEHOLDER; see the trait docstring.

        A STRING output has no value-channel DType. `uint8` is returned
        because it is the element type of the byte buffer a
        `StringColumnSlot` actually writes, matching the same placeholder
        `StringColumnSlot.DT` names — so the two agree rather than offering
        a reader two different fictions. Callers that consult
        `out_kind_at[k]()` first (all of them) never observe it.
        """
        return DType.uint8

    def write_one[
        bo: Origin[mut=False], MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.write_one` — delegating default body. Lands the
        single String output value (via the instance `eval_scalar_s`) into
        output slot 0 through the builder's STRING channel."""
        builders.append_string_at[0](self.eval_scalar_s[bo](batch, i))

    def project_one[
        bo: Origin[mut=False], dst_k: Int, MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.project_one` — instance delegating default body.

        The String twin of the numeric ExprX bodies: lands this transform's
        one String value into builder slot `dst_k`. INSTANCE dispatch, so
        the leaf's runtime `_idx` (populated by `bind`) is consulted —
        see the numeric twins for why a static `Self()` path SIGSEGVs."""
        builders.append_string_at[dst_k](self.eval_scalar_s[bo](batch, i))
