# =============================================================================
# expr_x_conformers.mojo — ExprX conformer subset for fused filter/project stages
# =============================================================================
#
# Per-batch Expr conformers used by the fused FilterProject stage
# conformers (CompiledStage_FilterProject1 / _FilterOnly / _Project1 etc.).
#
# Conformer catalog:
#
# Column accessors (3):
#   - ColXI64[col_idx: Int] — INT64 column accessor.
#   - ColXF64[col_idx: Int] — FLOAT64 column accessor.
#   - ColXBool[col_idx: Int] — BOOL column accessor (bit-packed).
#
# Literals (3):
#   - LitXI64[v: Int64] — INT64 literal.
#   - LitXF64[v: Float64] — FLOAT64 literal.
#   - LitXBool[v: Bool] — BOOL literal.
#
# INT64 comparison binops (6):
#   - GeXI64[L, R] / GtXI64[L, R] / LtXI64[L, R] / LeXI64[L, R] / EqXI64[L, R] / NeXI64[L, R]
#
# FLOAT64 ordered comparison binops (4):
#   - GeXF64[L, R] / GtXF64[L, R] / LtXF64[L, R] / LeXF64[L, R]
#
# Logical binops:
#   - AndX[L, R] — Boolean conjunction.
#
# Arithmetic:
#   - MulXF64[L, R] — FLOAT64 multiplication (e.g. TPC-H Q6's
#     `l_extendedprice * l_discount`).
#
# The later sections add float equality, float add/sub/div, Float32 and Int32
# conformers, and the String conformers.
#
# Pattern: each conformer is `@fieldwise_init` + trait conformance + zero
# or one comptime parameter. Trait methods `eval[W, bo]` / `eval_scalar[bo]`
# / `depth` are `@staticmethod @always_inline`. Mojo monomorphizer inlines
# the trait method body at every CompiledStage_FilterProject*.process_batch
# call site.
#
# Encapsulation invariants:
#   - NO UnsafePointer in any public method signature.
#   - NO wildcard origins.
#   - All BatchView access via the typed col_i64 / col_f64 / col_bool
#     accessors which return ColView[dtype, origin] / BoolColView[origin]
#     with concrete origin parameter.
#
# Cross-references:
#   - komira_expr.expr_x (trait declarations consumed here).
#   - komira_arrow.batch_view (BatchView + ColView /
#     BoolColView typed accessors).
# =============================================================================
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_column_kernels.string_comparison import like_match_string
from komira_udf.column_resolver import ColumnResolver
from komira_expr.expr_x import ExprXBool, ExprXF32, ExprXF64, ExprXI32, ExprXI64, ExprXString
from komira_row_format.row_block import RowBlock


# =============================================================================
# §0 — Lowering-default stubs
# =============================================================================
#
# The source typed expression AST traits declare a `comptime X[S:
# SchemaDescriptor]` member that lowers the source conformer to its
# executable ExprX twin. Every concrete source conformer with a clean twin
# (Lit*, Col*, comparison binops, And/Or) overrides the member; conformers
# WITHOUT a clean twin (ApplyScalarFn* UDF nodes, future
# nullable variants, etc.) inherit a STUB default that names the
# `_UnsupportedX*` types here.
#
# Each stub conforms to its trait surface but raises at use-site via
# `constrained[False, ...]`. The constrained body fires BEFORE instantiation
# of the eval method, so the source conformer's lowering remains TYPE-VALID
# (`E.X[S]` resolves to a concrete type); only an attempt to ACTUALLY drive
# the stub through the engine fails at compile time. The recursive
# `Self.eval_*` call satisfies Mojo's flow analyzer (the recursion is
# unreachable because constrained[False] fires first); Mojo emits a
# "self recursive call will cause an infinite loop" warning that we accept
# (the same idiom as the MapFn adapter).
# =============================================================================


struct _UnsupportedXI64(ExprXI64):
    """Stub ExprXI64 conformer for source ExprI64 nodes without a typed-
    lowering twin (e.g. ApplyScalarFn* UDF nodes)."""

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int64, W]:
        comptime assert False, ("_UnsupportedXI64: source ExprI64 conformer has no typed-lowering"
            " twin yet (e.g. ApplyScalarFn* UDFs). Drop to"
            " .untyped() for runtime-Expr execution.")

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int64:
        comptime assert False, ("_UnsupportedXI64.eval_scalar_s: no typed-lowering twin.")

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() — raises at compile time (stub) ---
    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(
            String(
                "_UnsupportedXI64.to_expr: no typed-lowering twin yet (e.g."
                " ApplyScalarFn* UDFs). Drop to .untyped() for"
                " runtime-Expr lowering."
            )
        )


struct _UnsupportedXI32(ExprXI32):
    """Stub ExprXI32 conformer — see _UnsupportedXI64."""

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        comptime assert False, ("_UnsupportedXI32: no typed-lowering twin.")

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        comptime assert False, ("_UnsupportedXI32: no typed-lowering twin.")

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() — raises at runtime (stub) ---
    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("_UnsupportedXI32.to_expr: no typed-lowering twin."))


struct _UnsupportedXF32(ExprXF32):
    """Stub ExprXF32 conformer — see _UnsupportedXI64."""

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        comptime assert False, ("_UnsupportedXF32: no typed-lowering twin.")

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        comptime assert False, ("_UnsupportedXF32: no typed-lowering twin.")

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() — raises at runtime (stub) ---
    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("_UnsupportedXF32.to_expr: no typed-lowering twin."))


struct _UnsupportedXF64(ExprXF64):
    """Stub ExprXF64 conformer — see _UnsupportedXI64."""

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        comptime assert False, ("_UnsupportedXF64: no typed-lowering twin.")

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        comptime assert False, ("_UnsupportedXF64: no typed-lowering twin.")

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() — raises at runtime (stub) ---
    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("_UnsupportedXF64.to_expr: no typed-lowering twin."))


struct _UnsupportedXBool(ExprXBool):
    """Stub ExprXBool conformer for source ExprBool nodes without a typed-
    lowering twin (e.g. ApplyScalarFnBool UDF nodes)."""

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        comptime assert False, ("_UnsupportedXBool: source ExprBool conformer has no typed-lowering"
            " twin yet (e.g. ApplyScalarFnBool UDFs). Drop to"
            " .untyped() for runtime-Expr execution.")

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        comptime assert False, ("_UnsupportedXBool.eval_scalar_s: no typed-lowering twin.")

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() — raises at runtime (stub) ---
    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(
            String(
                "_UnsupportedXBool.to_expr: no typed-lowering twin yet."
                " Drop to .untyped() for runtime-Expr lowering."
            )
        )


# =============================================================================
# §1 — Column accessors
# =============================================================================
#
# Read one column from the BatchView per row. The column index is a comptime
# parameter (load-bearing for Mojo's monomorphization to inline the column
# slot dereference; runtime column-index dispatch would defeat the inline
# benefit). Plan-compile-time logical-plan column-name resolution maps the
# Expr's column NAME to a comptime column INDEX, which is then baked into
# the ColX* conformer's `col_idx` parameter.
# =============================================================================


struct ColXI64[name: StringLiteral](ExprXI64):
    """Read INT64 column `name` per row.

    Trait conformance: ExprXI64. `eval_simd[W, bo]` returns a SIMD chunk of
    W INT64 values; `eval_scalar_s[bo]` returns one INT64.

    The leaf is name-keyed at the type level. The
    runtime `_idx: Int = -1` field is populated by `bind(resolver)` at Stage
    init; the per-row hot loop reads `self._idx` directly with zero hashmap
    probes. ArrowType.INT64 defensive validation in `bind` raises if the
    file's actual schema has a different DType for this column name.
    """

    var _idx: Int

    def __init__(out self):
        self._idx = -1

    def bind(mut self, resolver: ColumnResolver) raises:
        """Resolve column name to physical index + validate ArrowType."""
        self._idx = resolver.index_for(String(Self.name))
        var at = resolver.arrow_type_for(String(Self.name))
        if at != ArrowType.INT64:
            raise Error(
                String("ColXI64[\""),
                String(Self.name),
                String("\"].bind: file's ArrowType is "),
                String(at),
                String(", expected INT64"),
            )

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int64, W]:
        return batch.col_i64(self._idx).load[W](i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int64:
        return batch.col_i64(self._idx).load[1](i)[0]

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        """Lower this engine leaf to a runtime `Expr.col_ref` keyed by the
        comptime `name`, for the runtime LogicalPlan walker."""
        return Expr.col_ref(String(Self.name))

    # --- operator overloads ---
    def __gt__[R: ExprXI64](self, rhs: R) -> GtXI64[Self, R]:
        return GtXI64[Self, R]()

    def __lt__[R: ExprXI64](self, rhs: R) -> LtXI64[Self, R]:
        return LtXI64[Self, R]()

    def __ge__[R: ExprXI64](self, rhs: R) -> GeXI64[Self, R]:
        return GeXI64[Self, R]()

    def __le__[R: ExprXI64](self, rhs: R) -> LeXI64[Self, R]:
        return LeXI64[Self, R]()

    def __eq__[R: ExprXI64](self, rhs: R) -> EqXI64[Self, R]:
        return EqXI64[Self, R]()

    def __ne__[R: ExprXI64](self, rhs: R) -> NeXI64[Self, R]:
        return NeXI64[Self, R]()


struct ColAtXF64[idx: Int](ExprXF64):
    """Read FLOAT64 column at COMPTIME index `idx` per row.

    The comptime-index sibling of
    `ColXF64[name]`. Where `ColXF64` resolves its column index at runtime via
    `bind(resolver)`, `ColAtXF64` bakes the index as a comptime param — so an
    expression tree built ENTIRELY from `ColAtXF64` + `LitXF64` + the F64
    arith binops is fully resolved at construction (no runtime bind pass).

    This is the leaf the generic column-path computed aggregand aggregator
    (`SumOfExprF64Agg[E]`) uses: it mirrors how `SumProductF64Agg[col_a,
    col_b]` bakes its two column indices as comptime params (resolved via a
    marker's `BOUND[S] = ...[S.index_of(name)]` site), generalized from the
    fixed 2-column `a*b` shape to an arbitrary `ExprXF64` tree. The `bind`
    default-no-op (inherited from RowTransform) is correct: there is nothing
    to resolve at runtime.

    `to_expr()` RAISES — a comptime-index leaf has no column NAME to emit as
    a `col_ref`, and this leaf is for the comptime-resolved agg-evaluator
    path, NOT the runtime-Expr lowering surface (filter / projection plan
    nodes lower through the name-keyed `ColXF64` instead).
    """

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        return batch.col_f64(Self.idx).load[W](i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        return batch.col_f64(Self.idx).load[1](i)[0]

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(
            "ColAtXF64[",
            String(Self.idx),
            "].to_expr: comptime-index leaf has no column name to lower to a"
            " runtime col_ref Expr (this leaf is for the comptime-resolved"
            " computed-aggregand evaluator path, not runtime-Expr lowering).",
        )

    # --- operator overloads (mirror ColXF64) ---
    def __gt__[R: ExprXF64](self, rhs: R) -> GtXF64[Self, R]:
        return GtXF64[Self, R]()

    def __lt__[R: ExprXF64](self, rhs: R) -> LtXF64[Self, R]:
        return LtXF64[Self, R]()

    def __ge__[R: ExprXF64](self, rhs: R) -> GeXF64[Self, R]:
        return GeXF64[Self, R]()

    def __le__[R: ExprXF64](self, rhs: R) -> LeXF64[Self, R]:
        return LeXF64[Self, R]()

    def __eq__[R: ExprXF64](self, rhs: R) -> EqXF64[Self, R]:
        return EqXF64[Self, R]()

    def __ne__[R: ExprXF64](self, rhs: R) -> NeXF64[Self, R]:
        return NeXF64[Self, R]()


struct ColXF64[name: StringLiteral](ExprXF64):
    """Read FLOAT64 column `name` per row.

    Name-keyed leaf; runtime `_idx` populated by bind.
    Mirror of ColXI64 with DType.float64 + ArrowType.FLOAT64 defensive
    validation.
    """

    var _idx: Int

    def __init__(out self):
        self._idx = -1

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))
        var at = resolver.arrow_type_for(String(Self.name))
        if at != ArrowType.FLOAT64:
            raise Error(
                String("ColXF64[\""),
                String(Self.name),
                String("\"].bind: file's ArrowType is "),
                String(at),
                String(", expected FLOAT64"),
            )

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        return batch.col_f64(self._idx).load[W](i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        return batch.col_f64(self._idx).load[1](i)[0]

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.col_ref(String(Self.name))

    # --- operator overloads ---
    def __gt__[R: ExprXF64](self, rhs: R) -> GtXF64[Self, R]:
        return GtXF64[Self, R]()

    def __lt__[R: ExprXF64](self, rhs: R) -> LtXF64[Self, R]:
        return LtXF64[Self, R]()

    def __ge__[R: ExprXF64](self, rhs: R) -> GeXF64[Self, R]:
        return GeXF64[Self, R]()

    def __le__[R: ExprXF64](self, rhs: R) -> LeXF64[Self, R]:
        return LeXF64[Self, R]()

    def __eq__[R: ExprXF64](self, rhs: R) -> EqXF64[Self, R]:
        return EqXF64[Self, R]()

    def __ne__[R: ExprXF64](self, rhs: R) -> NeXF64[Self, R]:
        return NeXF64[Self, R]()


struct ColXBool[name: StringLiteral](ExprXBool):
    """Read BOOL column `name` per row.

    Name-keyed leaf; runtime `_idx` populated by bind.
    Uses BoolColView for bit-packed access; out-of-bounds lanes default
    to False.
    """

    var _idx: Int

    def __init__(out self):
        self._idx = -1

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))
        var at = resolver.arrow_type_for(String(Self.name))
        if at != ArrowType.BOOL:
            raise Error(
                String("ColXBool[\""),
                String(Self.name),
                String("\"].bind: file's ArrowType is "),
                String(at),
                String(", expected BOOL"),
            )

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        # BoolColView.load raises on bounds; the fused-stage caller
        # guarantees `i + W <= n` so we suppress the raise via a try wrap.
        try:
            return batch.col_bool(self._idx).load[W](i)
        except:
            return SIMD[DType.bool, W](fill=False)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        try:
            return batch.col_bool(self._idx).load_bit(i)
        except:
            return False

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.col_ref(String(Self.name))

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


# =============================================================================
# §2 — Literals
# =============================================================================
#
# Comptime-baked literal value. SIMD splat at the trait method body.
# =============================================================================


@fieldwise_init
struct LitXI64[v: Int64](ExprXI64):
    """Comptime INT64 literal. `eval[W]` returns splat-W of `v`.
    """

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int64, W]:
        return SIMD[DType.int64, W](Self.v)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int64:
        return Self.v

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.literal(ScalarValue.from_int64(Self.v))

    # --- operator overloads ---
    def __gt__[R: ExprXI64](self, rhs: R) -> GtXI64[Self, R]:
        return GtXI64[Self, R]()

    def __lt__[R: ExprXI64](self, rhs: R) -> LtXI64[Self, R]:
        return LtXI64[Self, R]()

    def __ge__[R: ExprXI64](self, rhs: R) -> GeXI64[Self, R]:
        return GeXI64[Self, R]()

    def __le__[R: ExprXI64](self, rhs: R) -> LeXI64[Self, R]:
        return LeXI64[Self, R]()

    def __eq__[R: ExprXI64](self, rhs: R) -> EqXI64[Self, R]:
        return EqXI64[Self, R]()

    def __ne__[R: ExprXI64](self, rhs: R) -> NeXI64[Self, R]:
        return NeXI64[Self, R]()


@fieldwise_init
struct LitXF64[v: Float64](ExprXF64):
    """Comptime FLOAT64 literal. Splat-W at eval.
    """

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        return SIMD[DType.float64, W](Self.v)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        return Self.v

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.literal(ScalarValue.from_float(Self.v))

    # --- operator overloads ---
    def __gt__[R: ExprXF64](self, rhs: R) -> GtXF64[Self, R]:
        return GtXF64[Self, R]()

    def __lt__[R: ExprXF64](self, rhs: R) -> LtXF64[Self, R]:
        return LtXF64[Self, R]()

    def __ge__[R: ExprXF64](self, rhs: R) -> GeXF64[Self, R]:
        return GeXF64[Self, R]()

    def __le__[R: ExprXF64](self, rhs: R) -> LeXF64[Self, R]:
        return LeXF64[Self, R]()

    def __eq__[R: ExprXF64](self, rhs: R) -> EqXF64[Self, R]:
        return EqXF64[Self, R]()

    def __ne__[R: ExprXF64](self, rhs: R) -> NeXF64[Self, R]:
        return NeXF64[Self, R]()


@fieldwise_init
struct LitXBool[v: Bool](ExprXBool):
    """Comptime BOOL literal. Splat-W at eval.

    Useful for filter-degenerate cases (`lit(true)` or `lit(false)` shows
    up in optimizer-rewritten plans).
    """

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return SIMD[DType.bool, W](fill=Self.v)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return Self.v

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.literal(ScalarValue.from_bool(Self.v))

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


# =============================================================================
# §3 — INT64 comparison binops
# =============================================================================
#
# Two-operand boolean-output kernels. Both operands are ExprXI64; result
# is SIMD[DType.bool, W] (the lane-wise comparison). SIMD comparison ops
# (.ge / .gt / .lt / .le / .eq / .ne) are stdlib-provided and lower to
# native CMP+SETcc on x86_64 / cmgt/cmlt/cmeq on AArch64.
# =============================================================================


struct GeXI64[L: ExprXI64, R: ExprXI64](ExprXBool):
    """L >= R over INT64. Lane-wise SIMD compare.

    Note: SIMD method form (`.ge()`) instead
    of operator (`>=`). Mojo 1.0.0b1 restricts operator-form
    `SIMD[T, W] >= SIMD[T, W]` to W=1 (`Scalar` only); multi-lane
    requires `.ge()`. Same constraint applies to `.gt()` / `.lt()` /
    `.le()` / `.eq()` / `.ne()` below.
    """

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).ge(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) >= self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_GE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct GtXI64[L: ExprXI64, R: ExprXI64](ExprXBool):
    """L > R over INT64."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).gt(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) > self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_GT, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct LtXI64[L: ExprXI64, R: ExprXI64](ExprXBool):
    """L < R over INT64."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).lt(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) < self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_LT, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct LeXI64[L: ExprXI64, R: ExprXI64](ExprXBool):
    """L <= R over INT64."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).le(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) <= self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_LE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct EqXI64[L: ExprXI64, R: ExprXI64](ExprXBool):
    """L == R over INT64."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).eq(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) == self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_EQ, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct NeXI64[L: ExprXI64, R: ExprXI64](ExprXBool):
    """L != R over INT64."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).ne(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) != self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_NE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


# =============================================================================
# §4 — FLOAT64 ordered comparison binops
# =============================================================================
#
# IEEE 754 ordered comparisons (Mojo's native SIMD .ge/.gt/.lt/.le lower
# to LLVM fcmp ordered cmp — `oge` / `ogt` / `olt` / `ole` — which return
# False for NaN-involving operands).
#
# ⚠ Over NaN-FREE data every comparison model agrees, which is why a
# NaN-free corpus cannot see the difference. On NaN-bearing data this is a
# KNOWN DIVERGENCE: DuckDB v1.5.3, PostgreSQL and Spark SQL all order NaN
# ABOVE +inf, so `NaN > 1.0` is TRUE there and False here.
#
# EqXF64 and NeXF64 are in §5b below: unordered NaN-aware semantics would
# require the `~v.eq(t)` pattern.
# =============================================================================


struct GeXF64[L: ExprXF64, R: ExprXF64](ExprXBool):
    """L >= R over FLOAT64. Ordered IEEE 754 compare.

    Note: see GeXI64 docstring for SIMD
    operator-vs-method form rationale (`.ge()` not `>=` on multi-lane
    SIMD per Mojo 1.0.0b1 constraint).
    """

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).ge(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) >= self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_GE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct GtXF64[L: ExprXF64, R: ExprXF64](ExprXBool):
    """L > R over FLOAT64. Ordered IEEE 754 compare."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).gt(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) > self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_GT, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct LtXF64[L: ExprXF64, R: ExprXF64](ExprXBool):
    """L < R over FLOAT64. Ordered IEEE 754 compare."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).lt(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) < self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_LT, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct LeXF64[L: ExprXF64, R: ExprXF64](ExprXBool):
    """L <= R over FLOAT64. Ordered IEEE 754 compare."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).le(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) <= self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_LE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


# =============================================================================
# §5 — Logical binops
# =============================================================================


struct AndX[L: ExprXBool, R: ExprXBool](ExprXBool):
    """Boolean conjunction. Lane-wise SIMD bitwise AND on bool vectors.

    Q6 uses a 4-AND chain: And[And[And[And[GeI64[...], LtI64[...]],
    GeF64[...]], LeF64[...]], LtF64[...]]. AndX is the LOAD-BEARING
    conformer for filter predicate composition.
    """

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) & self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) and self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_AND, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct OrX[L: ExprXBool, R: ExprXBool](ExprXBool):
    """Boolean disjunction. Lane-wise SIMD bitwise OR on bool vectors.

    Mirror of AndX for the Or-side of
    the typed ExprBool->ExprXBool lowering. Source-side `Or[L, R]` from
    the typed expression AST lowers to `OrX[L.X[S], R.X[S]]`.
    """

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) | self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) or self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_OR, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


# =============================================================================
# §5b — Float Eq/Ne (deferred-NaN semantics; standard IEEE compare)
# =============================================================================
#
# EqXF64/NeXF64/EqXF32/NeXF32 serve the typed lowering: the source ExprAST
# `EqF64[L,R]` / `NeF64[L,R]` use the standard `==`/`!=` Scalar operators,
# which is IEEE 754 default. These twins MATCH that exact semantic; NaN-aware
# EqF*/NeF* variants would have to update the source and X-twin sides in
# lockstep.
#
# ⛔ AND THERE IS A THIRD SIDE, WHICH IS THE TRAP.
# `NeXF64`/`NeXF32` use `.ne`, i.e. LLVM `fcmp one` — ORDERED not-equal, so
# `NaN != x` is FALSE here for EVERY x. The SHIPPING `!=` kernels
# (`komira_column_kernels.comparison.eval_col_ne`, `komira_kernels.sel_kernels._cmp_ne`)
# deliberately do NOT use `.ne`: they use `~eq`, the UNORDERED form, where
# `NaN != x` is TRUE for every x. Those two answer `NaN <> 1.0` OPPOSITELY, and
# neither matches DuckDB, which answers TRUE for `NaN <> 1.0` and FALSE for
# `NaN <> NaN`.
#
# This is LATENT, not live: only the `test_exprx_to_expr` test references
# `NeXF64`, so no query reaches it. Wiring the typed-lowering path WITHOUT
# resolving this would silently fork `<>` by execution path. Resolve it with
# one shared NaN / signed-zero comparison semantics rather than by copying
# either existing spelling.
struct EqXF64[L: ExprXF64, R: ExprXF64](ExprXBool):
    """L == R over FLOAT64. Ordered IEEE 754 compare (NaN != NaN)."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).eq(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) == self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_EQ, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct NeXF64[L: ExprXF64, R: ExprXF64](ExprXBool):
    """L != R over FLOAT64. Ordered IEEE 754 compare."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).ne(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) != self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_NE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct EqXF32[L: ExprXF32, R: ExprXF32](ExprXBool):
    """L == R over FLOAT32. Ordered IEEE 754 compare."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).eq(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) == self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_EQ, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct NeXF32[L: ExprXF32, R: ExprXF32](ExprXBool):
    """L != R over FLOAT32. Ordered IEEE 754 compare."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i).ne(self.right.eval_simd[W, bo](batch, i))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) != self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_NE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


# =============================================================================
# §6 — Arithmetic — FLOAT64 multiplication
# =============================================================================


struct MulXF64[L: ExprXF64, R: ExprXF64](ExprXF64):
    """L * R over FLOAT64. Lane-wise SIMD multiply.

    Q6 projection: MulXF64[ColXF64[COL_EXTENDEDPRICE], ColXF64[COL_DISCOUNT]].
    Maps to LLVM fmul. NEON .2d / x86_64 mulpd one instruction per W=2.
    """

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        return self.left.eval_simd[W, bo](batch, i) * self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        return self.left.eval_scalar_s[bo](batch, i) * self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_MUL, Self.L.to_expr(), Self.R.to_expr())


# =============================================================================
# §6b — Arithmetic — FLOAT64 add / sub / div
# =============================================================================
#
# Mirror of MulXF64 for the remaining three F64 binary-arith ops. These
# complete the F64 arithmetic op-matrix (+, -, *, /) so a computed aggregand
# expression tree like `a * (1 - b)` (= MulXF64[ColXF64[a], SubXF64[LitXF64[1],
# ColXF64[b]]]) is fully expressible over the ExprXF64 surface. The F32 family
# already carries the full Add/Sub/Mul/Div quartet; this brings F64 to
# parity. Same FIELD-based instance dispatch shape as MulXF64:
# `var left/right` sub-Expr instances, recursive `bind`,
# lane-wise SIMD op, scalar fallback. Maps to LLVM fadd/fsub/fdiv.
# =============================================================================


struct AddXF64[L: ExprXF64, R: ExprXF64](ExprXF64):
    """L + R over FLOAT64. Lane-wise SIMD add. Maps to LLVM fadd."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        return self.left.eval_simd[W, bo](batch, i) + self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        return self.left.eval_scalar_s[bo](batch, i) + self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_ADD, Self.L.to_expr(), Self.R.to_expr())


struct SubXF64[L: ExprXF64, R: ExprXF64](ExprXF64):
    """L - R over FLOAT64. Lane-wise SIMD subtract. Maps to LLVM fsub.

    The immediate TPC-H disc-price gap: `1 - l_discount` =
    `SubXF64[LitXF64[1.0], ColXF64["l_discount"]]`."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        return self.left.eval_simd[W, bo](batch, i) - self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        return self.left.eval_scalar_s[bo](batch, i) - self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_SUB, Self.L.to_expr(), Self.R.to_expr())


struct DivXF64[L: ExprXF64, R: ExprXF64](ExprXF64):
    """L / R over FLOAT64. Lane-wise SIMD divide. F64 division never raises;
    IEEE-754 NaN/Inf semantics (matches DivXF32)."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        return self.left.eval_simd[W, bo](batch, i) / self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        return self.left.eval_scalar_s[bo](batch, i) / self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_DIV, Self.L.to_expr(), Self.R.to_expr())


# =============================================================================
# §7 — Float32 conformers
# =============================================================================
#
# F32 column accessor + literal + 4 comparison binops (Ge/Gt/Lt/Le) + 4
# arithmetic binops (Add/Sub/Mul/Div). EqXF32 / NeXF32 deferred per NaN-
# semantics discipline.
# =============================================================================


struct ColXF32[name: StringLiteral](ExprXF32):
    """Read FLOAT32 column `name` per row.

    Name-keyed leaf; runtime `_idx` populated by bind.
    Mirror of ColXF64 with DType.float32 + ArrowType.FLOAT32 defensive
    validation.
    """

    var _idx: Int

    def __init__(out self):
        self._idx = -1

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))
        var at = resolver.arrow_type_for(String(Self.name))
        if at != ArrowType.FLOAT32:
            raise Error(
                String("ColXF32[\""),
                String(Self.name),
                String("\"].bind: file's ArrowType is "),
                String(at),
                String(", expected FLOAT32"),
            )

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        return batch.col_f32(self._idx).load[W](i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        return batch.col_f32(self._idx).load[1](i)[0]

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.col_ref(String(Self.name))

    # --- operator overloads ---
    def __gt__[R: ExprXF32](self, rhs: R) -> GtXF32[Self, R]:
        return GtXF32[Self, R]()

    def __lt__[R: ExprXF32](self, rhs: R) -> LtXF32[Self, R]:
        return LtXF32[Self, R]()

    def __ge__[R: ExprXF32](self, rhs: R) -> GeXF32[Self, R]:
        return GeXF32[Self, R]()

    def __le__[R: ExprXF32](self, rhs: R) -> LeXF32[Self, R]:
        return LeXF32[Self, R]()

    def __eq__[R: ExprXF32](self, rhs: R) -> EqXF32[Self, R]:
        return EqXF32[Self, R]()

    def __ne__[R: ExprXF32](self, rhs: R) -> NeXF32[Self, R]:
        return NeXF32[Self, R]()


@fieldwise_init
struct LitXF32[v: Float32](ExprXF32):
    """Comptime FLOAT32 literal. Splat-W at eval."""

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        return SIMD[DType.float32, W](Self.v)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        return Self.v

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.literal(ScalarValue.from_float32(Self.v))

    # --- operator overloads ---
    def __gt__[R: ExprXF32](self, rhs: R) -> GtXF32[Self, R]:
        return GtXF32[Self, R]()

    def __lt__[R: ExprXF32](self, rhs: R) -> LtXF32[Self, R]:
        return LtXF32[Self, R]()

    def __ge__[R: ExprXF32](self, rhs: R) -> GeXF32[Self, R]:
        return GeXF32[Self, R]()

    def __le__[R: ExprXF32](self, rhs: R) -> LeXF32[Self, R]:
        return LeXF32[Self, R]()

    def __eq__[R: ExprXF32](self, rhs: R) -> EqXF32[Self, R]:
        return EqXF32[Self, R]()

    def __ne__[R: ExprXF32](self, rhs: R) -> NeXF32[Self, R]:
        return NeXF32[Self, R]()


struct GeXF32[L: ExprXF32, R: ExprXF32](ExprXBool):
    """L >= R over FLOAT32. Lane-wise SIMD compare."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) >= self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) >= self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_GE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct GtXF32[L: ExprXF32, R: ExprXF32](ExprXBool):
    """L > R over FLOAT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) > self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) > self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_GT, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct LtXF32[L: ExprXF32, R: ExprXF32](ExprXBool):
    """L < R over FLOAT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) < self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) < self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_LT, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct LeXF32[L: ExprXF32, R: ExprXF32](ExprXBool):
    """L <= R over FLOAT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) <= self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) <= self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_LE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct AddXF32[L: ExprXF32, R: ExprXF32](ExprXF32):
    """L + R over FLOAT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        return self.left.eval_simd[W, bo](batch, i) + self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        return self.left.eval_scalar_s[bo](batch, i) + self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_ADD, Self.L.to_expr(), Self.R.to_expr())


struct SubXF32[L: ExprXF32, R: ExprXF32](ExprXF32):
    """L - R over FLOAT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        return self.left.eval_simd[W, bo](batch, i) - self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        return self.left.eval_scalar_s[bo](batch, i) - self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_SUB, Self.L.to_expr(), Self.R.to_expr())


struct MulXF32[L: ExprXF32, R: ExprXF32](ExprXF32):
    """L * R over FLOAT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        return self.left.eval_simd[W, bo](batch, i) * self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        return self.left.eval_scalar_s[bo](batch, i) * self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_MUL, Self.L.to_expr(), Self.R.to_expr())


struct DivXF32[L: ExprXF32, R: ExprXF32](ExprXF32):
    """L / R over FLOAT32. F32 division never raises; IEEE-754 NaN/Inf."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        return self.left.eval_simd[W, bo](batch, i) / self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        return self.left.eval_scalar_s[bo](batch, i) / self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_DIV, Self.L.to_expr(), Self.R.to_expr())


# =============================================================================
# §8 — Int32 conformers
# =============================================================================
#
# I32 column accessor + literal + 6 comparison binops (Ge/Gt/Lt/Le/Eq/Ne) +
# 4 arithmetic binops (Add/Sub/Mul/Div). Mirrors I64 conformer family.
#
# Also serves Date32 (Int32-aliased) column reads — same storage; date
# semantics handled by caller via day-arithmetic on the Int32 values.
# =============================================================================


struct ColXI32[name: StringLiteral](ExprXI32):
    """Read INT32 column `name` per row.

    Name-keyed leaf; runtime `_idx` populated by bind.
    Mirror of ColXI64 with DType.int32. ArrowType validation accepts both
    INT32 AND DATE32 (Arrow Date32 is Int32 days-since-epoch — same
    storage, different ArrowType tag; ColXI32 serves both).
    """

    var _idx: Int

    def __init__(out self):
        self._idx = -1

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))
        var at = resolver.arrow_type_for(String(Self.name))
        if at != ArrowType.INT32 and at != ArrowType.DATE32:
            raise Error(
                String("ColXI32[\""),
                String(Self.name),
                String("\"].bind: file's ArrowType is "),
                String(at),
                String(", expected INT32 or DATE32"),
            )

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        return batch.col_i32(self._idx).load[W](i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        return batch.col_i32(self._idx).load[1](i)[0]

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.col_ref(String(Self.name))

    # --- operator overloads ---
    def __gt__[R: ExprXI32](self, rhs: R) -> GtXI32[Self, R]:
        return GtXI32[Self, R]()

    def __lt__[R: ExprXI32](self, rhs: R) -> LtXI32[Self, R]:
        return LtXI32[Self, R]()

    def __ge__[R: ExprXI32](self, rhs: R) -> GeXI32[Self, R]:
        return GeXI32[Self, R]()

    def __le__[R: ExprXI32](self, rhs: R) -> LeXI32[Self, R]:
        return LeXI32[Self, R]()

    def __eq__[R: ExprXI32](self, rhs: R) -> EqXI32[Self, R]:
        return EqXI32[Self, R]()

    def __ne__[R: ExprXI32](self, rhs: R) -> NeXI32[Self, R]:
        return NeXI32[Self, R]()


@fieldwise_init
struct LitXI32[v: Int32](ExprXI32):
    """Comptime INT32 literal. Splat-W at eval."""

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        return SIMD[DType.int32, W](Self.v)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        return Self.v

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.literal(ScalarValue.from_int32(Self.v))

    # --- operator overloads ---
    def __gt__[R: ExprXI32](self, rhs: R) -> GtXI32[Self, R]:
        return GtXI32[Self, R]()

    def __lt__[R: ExprXI32](self, rhs: R) -> LtXI32[Self, R]:
        return LtXI32[Self, R]()

    def __ge__[R: ExprXI32](self, rhs: R) -> GeXI32[Self, R]:
        return GeXI32[Self, R]()

    def __le__[R: ExprXI32](self, rhs: R) -> LeXI32[Self, R]:
        return LeXI32[Self, R]()

    def __eq__[R: ExprXI32](self, rhs: R) -> EqXI32[Self, R]:
        return EqXI32[Self, R]()

    def __ne__[R: ExprXI32](self, rhs: R) -> NeXI32[Self, R]:
        return NeXI32[Self, R]()


struct GeXI32[L: ExprXI32, R: ExprXI32](ExprXBool):
    """L >= R over INT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) >= self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) >= self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_GE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct GtXI32[L: ExprXI32, R: ExprXI32](ExprXBool):
    """L > R over INT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) > self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) > self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_GT, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct LtXI32[L: ExprXI32, R: ExprXI32](ExprXBool):
    """L < R over INT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) < self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) < self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_LT, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct LeXI32[L: ExprXI32, R: ExprXI32](ExprXBool):
    """L <= R over INT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) <= self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) <= self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_LE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct EqXI32[L: ExprXI32, R: ExprXI32](ExprXBool):
    """L == R over INT32. Exact equality."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) == self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) == self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_EQ, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct NeXI32[L: ExprXI32, R: ExprXI32](ExprXBool):
    """L != R over INT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return self.left.eval_simd[W, bo](batch, i) != self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) != self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_NE, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


struct AddXI32[L: ExprXI32, R: ExprXI32](ExprXI32):
    """L + R over INT32. Two's-complement wrap on overflow."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        return self.left.eval_simd[W, bo](batch, i) + self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        return self.left.eval_scalar_s[bo](batch, i) + self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_ADD, Self.L.to_expr(), Self.R.to_expr())


struct SubXI32[L: ExprXI32, R: ExprXI32](ExprXI32):
    """L - R over INT32."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        return self.left.eval_simd[W, bo](batch, i) - self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        return self.left.eval_scalar_s[bo](batch, i) - self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_SUB, Self.L.to_expr(), Self.R.to_expr())


struct MulXI32[L: ExprXI32, R: ExprXI32](ExprXI32):
    """L * R over INT32. Two's-complement wrap."""

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        return self.left.eval_simd[W, bo](batch, i) * self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        return self.left.eval_scalar_s[bo](batch, i) * self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_MUL, Self.L.to_expr(), Self.R.to_expr())


struct DivXI32[L: ExprXI32, R: ExprXI32](ExprXI32):
    """L / R over INT32. Caller-responsible for div-by-zero; trunc-toward-zero.

    NOTE: this is a non-raising scalar; Mojo SIMD int division raises on
    div-by-zero. For predicate-guarded use only.
    """

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        return self.left.eval_simd[W, bo](batch, i) // self.right.eval_simd[W, bo](batch, i)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        return self.left.eval_scalar_s[bo](batch, i) // self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_DIV, Self.L.to_expr(), Self.R.to_expr())


# =============================================================================
# §9 — String conformers
# =============================================================================
#
# ExprXString is scalar-only (no eval[W] — String is non-SIMD-able by design;
# Arrow StringArray stores variable-width payloads with offsets).
#
# Scope: ColXString only (project-only). Filter-EQ is a separate conformer,
# since it needs either SIMD memcmp for fixed-prefix predicates or
# a substring comparison primitive.
#
# Access path: ExprXString conformer reaches through `batch._batch[]` to call
# RecordBatch.column_as_string(idx).get(i). The underscore prefix is a
# documented public pattern (e.g. gather_batch at compiled_filter_project_
# stage.mojo).
# =============================================================================


struct ColXString[name: StringLiteral](ExprXString):
    """Read STRING column `name` per row. Scalar-only (no SIMD chunk
    method per ExprXString trait shape).

    Name-keyed leaf; runtime `_idx` populated by bind.

    Access via `batch._batch[].column_as_string(self._idx).get(i)`. Bounds
    check is internal to StringArray.get (raises on OOB). ExprXString.
    eval_scalar doesn't raise — wrap in try/except matching ColXBool's
    pattern, defaulting to empty string on error.
    """

    var _idx: Int

    def __init__(out self):
        self._idx = -1

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))
        var at = resolver.arrow_type_for(String(Self.name))
        if at != ArrowType.STRING:
            raise Error(
                String("ColXString[\""),
                String(Self.name),
                String("\"].bind: file's ArrowType is "),
                String(at),
                String(", expected STRING"),
            )

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> String:
        try:
            return batch._batch[].column_as_string(self._idx).get(i)
        except:
            return String("")

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.col_ref(String(Self.name))

    # --- operator overloads (String eq only: there is no NeXString, so
    # there is no __ne__) ---
    def __eq__[R: ExprXString](self, rhs: R) -> EqXString[Self, R]:
        return EqXString[Self, R]()


# =============================================================================
# §9b — String literal + equality
# =============================================================================
#
# LitXString[s: StringLiteral]: comptime String literal. StringLiteral is the
# canonical comptime-param String type in Mojo 1.0.0b1 (see typed_agg.mojo,
# schema_descriptor.mojo). eval_scalar materializes `String(s)` per call.
#
# EqXString[L, R](ExprXBool): scalar String equality. ExprXString is scalar-
# only, but EqXString outputs ExprXBool — which requires both `eval[W]` AND
# `eval_scalar`. The `eval[W]` does per-lane scalar fallback (no SIMD path
# for String, by ExprXString design).
# =============================================================================


@fieldwise_init
struct LitXString[s: StringLiteral](ExprXString):
    """Comptime String literal. Materializes `String(s)` per eval_scalar call.

    The materialization cost (heap alloc per row) is the price of the
    canonical String type. For perf-sensitive hot paths the SDK can hoist
    the literal materialization above the row loop; this scope is the
    correct-but-not-optimized form.
    """

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> String:
        return String(Self.s)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.literal(ScalarValue.from_string(String(Self.s)))

    # --- operator overloads (String eq only; see ColXString rationale) ---
    def __eq__[R: ExprXString](self, rhs: R) -> EqXString[Self, R]:
        return EqXString[Self, R]()


struct EqXString[L: ExprXString, R: ExprXString](ExprXBool):
    """L == R over STRING (byte equality via Mojo stdlib `String == String`).

    ExprXBool conformance: emits Bool per row. Since ExprXString has no
    SIMD path, the `eval[W]` method does per-lane scalar fallback (matches
    how non-SIMD-able subexpressions feed into Bool composition).
    """

    var left: Self.L
    var right: Self.R

    def __init__(out self):
        self.left = Self.L()
        self.right = Self.R()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.left.bind(resolver)
        self.right.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        var out = SIMD[DType.bool, W](fill=False)
        comptime for j in range(W):
            var lv = self.left.eval_scalar_s[bo](batch, i + j)
            var rv = self.right.eval_scalar_s[bo](batch, i + j)
            out[j] = lv == rv
        return out

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return self.left.eval_scalar_s[bo](batch, i) == self.right.eval_scalar_s[bo](batch, i)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.L.depth() + Self.R.depth()

    # --- to_expr() ---
    @staticmethod
    def to_expr() raises -> Expr:
        return Expr.binary(BIN_EQ, Self.L.to_expr(), Self.R.to_expr())

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


# =============================================================================
# §9c — SQL LIKE predicate
# =============================================================================
#
# `LikeXString[Value, Pattern](ExprXBool)` — SQL LIKE matcher with `%`
# (zero-or-more wildcard) + `_` (single-char wildcard).
#
# Runtime LIKE match. The pattern is
# materialized per-row via `Pattern.eval_scalar` (returns String), then
# matched against `Value.eval_scalar` via a state-machine. Per-row cost
# is O(len(value) × len(pattern)) worst-case for general patterns.
#
# Future optimization: comptime pattern compilation (parse `%` / `_`
# positions at struct construction). Currently the runtime cost is
# acceptable — production callers can hoist literal patterns
# above the row loop manually.
#
# Pattern semantics (PostgreSQL/MySQL/DuckDB compatible):
#   - `%`  matches zero or more characters.
#   - `_`  matches exactly one character.
#   - Any other byte matches itself.
#
# Edge cases:
#   - Empty pattern matches empty string only.
#   - Pattern of all `%` matches any string.
#   - No escape sequence support.
# =============================================================================


def _like_match(value: String, pattern: String) -> Bool:
    """SQL LIKE for the `LikeXString` conformer: `%` any run of characters, `_`
    ONE CHARACTER (a UTF-8 code point), everything else literal.

    ⭐ DELEGATES to `komira_column_kernels.string_comparison.like_match_string`
. This was its own byte-at-a-
    time copy of the matcher, so `_` matched one BYTE of a multi-byte
    character; the columnar kernel and the RuntimeExpr walker carried the same
    defect in their own copies. Falsifier:
    `komira_eval.tests.test_like_underscore_is_one_character`.
    """
    return like_match_string(value, pattern)


struct LikeXString[Value: ExprXString, Pattern: ExprXString](ExprXBool):
    """SQL LIKE predicate. Matches `Value` against `Pattern` per row.

    Pattern wildcards (PostgreSQL-compatible):
      - `%`  matches zero or more characters.
      - `_`  matches exactly one character.

    ExprXBool conformance: emits Bool per row. `eval[W]` does per-lane
    scalar fallback (String is not SIMD-able by design).

    Typical usage: `LikeXString[ColXString[0], LitXString["foo%"]]`.
    Both sides are ExprXString so the matcher works with column-vs-pattern,
    column-vs-column, or literal-vs-literal.
    """

    var value: Self.Value
    var pattern: Self.Pattern

    def __init__(out self):
        self.value = Self.Value()
        self.pattern = Self.Pattern()

    def bind(mut self, resolver: ColumnResolver) raises:
        """Recursive walk — propagate bind to both sub-Exprs."""
        self.value.bind(resolver)
        self.pattern.bind(resolver)

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        var out = SIMD[DType.bool, W](fill=False)
        comptime for j in range(W):
            var v = self.value.eval_scalar_s[bo](batch, i + j)
            var p = self.pattern.eval_scalar_s[bo](batch, i + j)
            out[j] = _like_match(v, p)
        return out

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        var v = self.value.eval_scalar_s[bo](batch, i)
        var p = self.pattern.eval_scalar_s[bo](batch, i)
        return _like_match(v, p)

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1 + Self.Value.depth() + Self.Pattern.depth()

    # --- to_expr() — raises at runtime; no BIN_LIKE in runtime Expr ---
    # SQL LIKE (`%` / `_` wildcards) has no direct Expr factory in
    # `komira_plan_expr.expr` (the closest cousin is `Expr.regexp_like`,
    # which uses RE2-style regex syntax — NOT SQL LIKE wildcards). Adding a
    # native LIKE walker arm requires extending `Expr` + the runtime walker
    # + the engine compiler/operators. Callers that need to lower a `LikeXString` to a
    # runtime `Expr` MUST drop to `.untyped()` and build the predicate via
    # the runtime regex factory (there is no typed LIKE factory).
    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(
            String(
                "LikeXString.to_expr: no native LIKE factory in runtime Expr"
                " yet (Expr.regexp_like uses regex syntax, not SQL LIKE"
                " wildcards). Drop to .untyped() to build the predicate via"
                " the runtime regex factory."
            )
        )

    # --- logical operator overloads ---
    def __and__[O: ExprXBool](self, other: O) -> AndX[Self, O]:
        return AndX[Self, O]()

    def __or__[O: ExprXBool](self, other: O) -> OrX[Self, O]:
        return OrX[Self, O]()


# =============================================================================
# RowExprF64 — the ROW-PATH (RowBlock) Float64 expression evaluator
# =============================================================================
#
# The ROW-PATH sibling
# of the `ExprXF64` BatchView evaluator. The COLUMN-path generic
# computed-aggregand kernel (`SumOfExprF64Agg[E: ExprXF64]`), whose leaves read a
# `BatchView`. But MOST grouped queries route the typed-ROW grouped-agg driver
# (`TypedRowGroupedAggSegment`), which reads a `RowBlock` row via `read_fixed`
# at comptime-resolved byte offsets — there is NO BatchView in that path. So a
# customer's `df.group_by(k).agg(sum(price*(1-discount)))` could not route typed
# on the row path.
#
# `RowExprF64` is the parallel evaluator over a RowBlock row. It mirrors the
# `ExprXF64` op-matrix (Mul / Sub / Add / Div + literal + column leaf) but its
# leaf — `RowColF64[slot]` — reads `src.read_fixed[float64](row_idx, off)` where
# the byte offset is selected by the comptime `slot` from the input offsets the
# typed-ROW segment resolves by NAME (the SAME offset-threading the 2-input
# SUM_PRODUCT path already uses).
#
# Why a SIBLING family (not reuse ExprXF64)
# -----------------------------------------------------------------------------
# `ExprXF64.eval_scalar_s` takes a `BatchView[bo]` (a borrow over a RecordBatch).
# The row path has a `RowBlock` (fixed-width row tuples), not a RecordBatch — and
# building a per-row transient BatchView is not viable (BatchView wraps a whole
# RecordBatch). The two substrates are kept structurally identical (same op tree
# shape; same comptime-resolved leaves) so a follow-on could unify them behind a
# leaf-source parameter, but a tiny dedicated `RowExprF64` family is the
# minimal, lowest-risk substrate.
#
# Input-offset model (minimal envelope: up to 2 input columns)
# -----------------------------------------------------------------------------
# `eval_row(src, row_idx, off0, off1)` carries the byte offsets of the (up to)
# two input columns the expression references; `RowColF64[slot]` selects `off0`
# for `slot == 0`, `off1` for `slot == 1`. The disc-price headline shape
# `a * (1 - b)` references exactly two columns, so the 2-offset envelope serves
# it. The N-input generalization (an offset LIST threaded into `eval_row`) is the
# named follow-on; it requires generalizing the typed-ROW segment's per-agg
# offset model beyond the current `(offset, offset2)` pair.
#
# Encapsulation invariants:
#   - NO UnsafePointer in any signature (RowBlock reads are encapsulated).
#   - NO wildcard origins.
#   - Each conformer is a zero-field comptime-parameterized POD (Movable +
#     Copyable), so an expr tree built from these leaves is a POD value.
# =============================================================================


trait RowExprF64(Copyable, Movable, Deinitable):
    """A Float64 expression evaluated over ONE row of a `RowBlock`.

    The row-path sibling of `ExprXF64`. `eval_row` reads the (up to two) input
    columns at the byte offsets `off0` / `off1` the typed-ROW segment resolves by
    NAME, and folds the arithmetic tree in Float64. Conformers are comptime-
    parameterized zero-field PODs (the tree is fully resolved at construction)."""

    def __init__(out self):
        ...

    @staticmethod
    def eval_row(src: RowBlock, row_idx: Int, off0: Int, off1: Int) -> Float64:
        """Evaluate the expression over row `row_idx` of `src`, reading column
        leaf `slot==0` at byte offset `off0` and `slot==1` at `off1`."""
        ...


struct RowColF64[slot: Int](RowExprF64):
    """Read FLOAT64 input column at COMPTIME `slot` (0 or 1) from the row.

    `slot` indexes the typed-ROW segment's resolved input offsets: `slot == 0`
    reads `off0` (the agg's primary input offset), `slot == 1` reads `off1` (the
    secondary). The row-path analogue of `ColAtXF64[idx]` (which reads a
    BatchView column at comptime index)."""

    def __init__(out self):
        pass

    @staticmethod
    @always_inline
    def eval_row(src: RowBlock, row_idx: Int, off0: Int, off1: Int) -> Float64:
        comptime if Self.slot == 0:
            return src.read_fixed[DType.float64](row_idx, off0)
        else:
            return src.read_fixed[DType.float64](row_idx, off1)


struct RowLitF64[v: Float64](RowExprF64):
    """FLOAT64 literal — the row-path analogue of `LitXF64[v]`."""

    def __init__(out self):
        pass

    @staticmethod
    @always_inline
    def eval_row(src: RowBlock, row_idx: Int, off0: Int, off1: Int) -> Float64:
        return Self.v


struct RowMulF64[L: RowExprF64, R: RowExprF64](RowExprF64):
    """`L * R` over Float64 — row-path analogue of `MulXF64[L, R]`."""

    def __init__(out self):
        pass

    @staticmethod
    @always_inline
    def eval_row(src: RowBlock, row_idx: Int, off0: Int, off1: Int) -> Float64:
        return Self.L.eval_row(src, row_idx, off0, off1) * Self.R.eval_row(
            src, row_idx, off0, off1
        )


struct RowSubF64[L: RowExprF64, R: RowExprF64](RowExprF64):
    """`L - R` over Float64 — row-path analogue of `SubXF64[L, R]`. The
    disc-price `1 - discount` term lowers to `RowSubF64[RowLitF64[1.0],
    RowColF64[1]]`."""

    def __init__(out self):
        pass

    @staticmethod
    @always_inline
    def eval_row(src: RowBlock, row_idx: Int, off0: Int, off1: Int) -> Float64:
        return Self.L.eval_row(src, row_idx, off0, off1) - Self.R.eval_row(
            src, row_idx, off0, off1
        )


struct RowAddF64[L: RowExprF64, R: RowExprF64](RowExprF64):
    """`L + R` over Float64 — row-path analogue of `AddXF64[L, R]`."""

    def __init__(out self):
        pass

    @staticmethod
    @always_inline
    def eval_row(src: RowBlock, row_idx: Int, off0: Int, off1: Int) -> Float64:
        return Self.L.eval_row(src, row_idx, off0, off1) + Self.R.eval_row(
            src, row_idx, off0, off1
        )


struct RowDivF64[L: RowExprF64, R: RowExprF64](RowExprF64):
    """`L / R` over Float64 — row-path analogue of `DivXF64[L, R]`."""

    def __init__(out self):
        pass

    @staticmethod
    @always_inline
    def eval_row(src: RowBlock, row_idx: Int, off0: Int, off1: Int) -> Float64:
        return Self.L.eval_row(src, row_idx, off0, off1) / Self.R.eval_row(
            src, row_idx, off0, off1
        )
