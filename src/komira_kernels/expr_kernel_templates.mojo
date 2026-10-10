# =============================================================================
# expr_kernel_templates.mojo — Tier 1 Expr → comptime kernel template registry
# =============================================================================
#
# This module hosts the registry of comptime-monomorphized kernel template
# structs that the SDK's `optimizer_expr.mojo` matcher binds to per-shape
# `BIN_*` / `UN_*` / `EXPR_CAST` / `EXPR_WHEN` Expr nodes.
#
# Templates cover arithmetic (ColCol over F64/I64/F32/I32, ColLit over
# F64/I64), comparison (ColLit over F64/I64), casts, when/otherwise,
# is_null / is_not_null, boolean composition, negate and mod. Anything else
# falls back to the generic Expr interpreter in `expr_interpreter.mojo`
# (`InterpretedExprKernel`).
#
# Templates are FREESTANDING structs (NOT MapFn conformers); they can opt in
# to MapFn conformance later.
#
# The matcher signature is
#   fn _match_expr_to_kernel_template(expr: Expr) -> Optional[Int]
# returning a stable template-id (>0 = match, 0 = INTERPRETED). The matcher
# lives in `optimizer_expr.mojo`. It matches ColLit shapes (the Lit-side
# dtype is determinable from `ScalarValue.dtype`; the ColRef dtype is
# implied); ColCol matching needs schema context plumbed through the
# optimizer pass.
#
# Encapsulation rule:
#   - Template structs declare ONLY @staticmethod / @fieldwise_init bodies;
#     zero state, zero heap, zero pointer fields. Pure POD.
#   - All SIMD lane access goes through `SimdOf` typed accessors — no
#     `UnsafePointer` in any signature or body of these templates.
#   - The literal value carried inside ColLit templates is a runtime parameter
#     to `eval[W]` (broadcast to a SIMD vec inside the body), NOT a struct
#     field on the template. This keeps the template stateless + purely
#     comptime-monomorphized.
#
# Mojo idioms:
#   - `Self.T_IN` / `Self.T_OUT` / `Self.W` for parameter refs in bodies.
#   - SIMD compare uses `.ge() / .gt() / .lt() / .le() / .eq()` for W>1; float
#     `<>` is `~eq` (see the comparison templates).
#   - A Bool splat at W>1 is `SIMD[DType.bool, W](fill=b)`.
#   - `mask.select(if_true, if_false)` is the lane-select.
#   - `var out = self` requires `.copy()` for SimdOf (Copyable but not
#     ImplicitlyCopyable).
# =============================================================================

from komira_kernels.simd_of import SimdOf
from komira_column_kernels.cast_null import round_half_to_even


# =============================================================================
# Template-id sentinels (stable Int IDs the matcher returns).
# 0 = INTERPRETED (fallback), 1+ = templated.
#
# IDs are STABLE — never renumber. New templates append at the end.
# Sub-slot 6 plan_compiler will switch on these IDs to emit MorselOp variants.
# =============================================================================

comptime EXPR_TEMPLATE_INTERPRETED: Int = 0  # InterpretedExprKernel sentinel

# Arithmetic ColCol — 4 ops × 4 dtypes = 16 templates (IDs 1..16)
comptime EXPR_TEMPLATE_ADD_F64_COLCOL: Int = 1
comptime EXPR_TEMPLATE_SUB_F64_COLCOL: Int = 2
comptime EXPR_TEMPLATE_MUL_F64_COLCOL: Int = 3
comptime EXPR_TEMPLATE_DIV_F64_COLCOL: Int = 4

comptime EXPR_TEMPLATE_ADD_I64_COLCOL: Int = 5
comptime EXPR_TEMPLATE_SUB_I64_COLCOL: Int = 6
comptime EXPR_TEMPLATE_MUL_I64_COLCOL: Int = 7
comptime EXPR_TEMPLATE_DIV_I64_COLCOL: Int = 8

comptime EXPR_TEMPLATE_ADD_F32_COLCOL: Int = 9
comptime EXPR_TEMPLATE_SUB_F32_COLCOL: Int = 10
comptime EXPR_TEMPLATE_MUL_F32_COLCOL: Int = 11
comptime EXPR_TEMPLATE_DIV_F32_COLCOL: Int = 12

comptime EXPR_TEMPLATE_ADD_I32_COLCOL: Int = 13
comptime EXPR_TEMPLATE_SUB_I32_COLCOL: Int = 14
comptime EXPR_TEMPLATE_MUL_I32_COLCOL: Int = 15
comptime EXPR_TEMPLATE_DIV_I32_COLCOL: Int = 16

# Arithmetic ColLit — 4 ops × 2 dtypes (F64+I64; bench-driven priority) = 8 (IDs 17..24)
comptime EXPR_TEMPLATE_ADD_F64_COLLIT: Int = 17
comptime EXPR_TEMPLATE_SUB_F64_COLLIT: Int = 18
comptime EXPR_TEMPLATE_MUL_F64_COLLIT: Int = 19
comptime EXPR_TEMPLATE_DIV_F64_COLLIT: Int = 20

comptime EXPR_TEMPLATE_ADD_I64_COLLIT: Int = 21
comptime EXPR_TEMPLATE_SUB_I64_COLLIT: Int = 22
comptime EXPR_TEMPLATE_MUL_I64_COLLIT: Int = 23
comptime EXPR_TEMPLATE_DIV_I64_COLLIT: Int = 24

# Comparison ColLit — 6 ops × 2 dtypes (F64+I64) = 12 (IDs 25..36)
comptime EXPR_TEMPLATE_GT_F64_COLLIT: Int = 25
comptime EXPR_TEMPLATE_GE_F64_COLLIT: Int = 26
comptime EXPR_TEMPLATE_LT_F64_COLLIT: Int = 27
comptime EXPR_TEMPLATE_LE_F64_COLLIT: Int = 28
comptime EXPR_TEMPLATE_EQ_F64_COLLIT: Int = 29
comptime EXPR_TEMPLATE_NE_F64_COLLIT: Int = 30

comptime EXPR_TEMPLATE_GT_I64_COLLIT: Int = 31
comptime EXPR_TEMPLATE_GE_I64_COLLIT: Int = 32
comptime EXPR_TEMPLATE_LT_I64_COLLIT: Int = 33
comptime EXPR_TEMPLATE_LE_I64_COLLIT: Int = 34
comptime EXPR_TEMPLATE_EQ_I64_COLLIT: Int = 35
comptime EXPR_TEMPLATE_NE_I64_COLLIT: Int = 36

# Highest template-id active in 3.a. Used by the coverage trip-wire test
# to assert no out-of-band IDs leak. Bumps in 3.b as new templates land.
comptime EXPR_TEMPLATE_MAX_ID_PHASE_3A: Int = 36

# =============================================================================
# Template IDs 37..65 — 29 templates used with the
# generic Expr interpreter at expr_interpreter.mojo.
#
# Composition: 8 cast (37-44) + 4 when/otherwise (45-48) + 8 is_null /
# is_not_null (49-56) + 3 boolean composition (57-59) + 4 negate (60-63) +
# 2 mod (64-65) = 29 → MAX_ID = 65.
#
# String comparison templates are NOT included: SimdOf has no String
# accessor, so string compare routes to the engine evaluator via the
# InterpretedExprKernel pass-through.
# =============================================================================

# Cast templates — 8 (IDs 37..44). Common dtype conversions.
comptime EXPR_TEMPLATE_CAST_F64_TO_F32: Int = 37
comptime EXPR_TEMPLATE_CAST_F32_TO_F64: Int = 38
comptime EXPR_TEMPLATE_CAST_I64_TO_I32: Int = 39
comptime EXPR_TEMPLATE_CAST_I32_TO_I64: Int = 40
comptime EXPR_TEMPLATE_CAST_F64_TO_I64: Int = 41
comptime EXPR_TEMPLATE_CAST_I64_TO_F64: Int = 42
comptime EXPR_TEMPLATE_CAST_I32_TO_F64: Int = 43
comptime EXPR_TEMPLATE_CAST_F32_TO_I64: Int = 44

# When/otherwise templates — 4 (IDs 45..48). One per dtype on the result side.
comptime EXPR_TEMPLATE_WHEN_F64: Int = 45
comptime EXPR_TEMPLATE_WHEN_F32: Int = 46
comptime EXPR_TEMPLATE_WHEN_I64: Int = 47
comptime EXPR_TEMPLATE_WHEN_I32: Int = 48

# is_null / is_not_null — 8 (IDs 49..56). One pair per dtype.
# These read the validity mask of the input column and return a Bool result.
# SimdOf does not carry a validity slot, so the kernel
# templates here have a body that is correct in shape but consumes the mask
# from the ENGINE side. The templates' eval[W] body is a
# placeholder that returns all-False (is_null) / all-True (is_not_null) for
# the SimdOf surface as it stands today; the engine path bypasses this body
# and consumes the validity mask directly. Documented in eval[W] body comment.
comptime EXPR_TEMPLATE_IS_NULL_F64: Int = 49
comptime EXPR_TEMPLATE_IS_NOT_NULL_F64: Int = 50
comptime EXPR_TEMPLATE_IS_NULL_F32: Int = 51
comptime EXPR_TEMPLATE_IS_NOT_NULL_F32: Int = 52
comptime EXPR_TEMPLATE_IS_NULL_I64: Int = 53
comptime EXPR_TEMPLATE_IS_NOT_NULL_I64: Int = 54
comptime EXPR_TEMPLATE_IS_NULL_I32: Int = 55
comptime EXPR_TEMPLATE_IS_NOT_NULL_I32: Int = 56

# Boolean composition — 3 (IDs 57..59). Shape: take two BoolRow inputs,
# return one BoolRow. AND/OR are 2-arg; NOT is 1-arg.
comptime EXPR_TEMPLATE_AND_BOOL: Int = 57
comptime EXPR_TEMPLATE_OR_BOOL: Int = 58
comptime EXPR_TEMPLATE_NOT_BOOL: Int = 59

# Unary negate — 4 (IDs 60..63). One per arithmetic dtype.
comptime EXPR_TEMPLATE_NEGATE_F64: Int = 60
comptime EXPR_TEMPLATE_NEGATE_F32: Int = 61
comptime EXPR_TEMPLATE_NEGATE_I64: Int = 62
comptime EXPR_TEMPLATE_NEGATE_I32: Int = 63

# Modulo — 2 (IDs 64..65). Integer-only (Float MOD has nuanced semantics
# better routed through the interpreter when it appears).
comptime EXPR_TEMPLATE_MOD_I64_COLCOL: Int = 64
comptime EXPR_TEMPLATE_MOD_I32_COLCOL: Int = 65

# Highest template-id active in 3.b. Total: 65 templates.
comptime EXPR_TEMPLATE_MAX_ID_PHASE_3B: Int = 65


# =============================================================================
# POD struct definitions for SimdOf instantiation.
#
# Each template's `T_IN` is a `@fieldwise_init struct {Dtype}PairRow` (for
# ColCol) or `{Dtype}Row` (for ColLit — the lit is a runtime arg, not a field);
# each `T_OUT` is the result row.
#
# These are reused across all templates of the same dtype to keep the SimdOf
# blob layout consistent. SoA byte layout: F64=8B/lane, I64=8B/lane, F32=4B/lane,
# I32=4B/lane, Bool=1B/lane.
# =============================================================================

# --- F64 ---
@fieldwise_init
struct F64PairRow(Copyable, Movable):
    """Two F64 inputs (ColCol shape)."""
    var a: Float64
    var b: Float64

@fieldwise_init
struct F64Row(Copyable, Movable):
    """One F64 input (ColLit shape) or one F64 output."""
    var a: Float64

@fieldwise_init
struct BoolRow(Copyable, Movable):
    """One Bool output (comparison templates produce this)."""
    var a: Bool

# --- I64 ---
@fieldwise_init
struct I64PairRow(Copyable, Movable):
    var a: Int64
    var b: Int64

@fieldwise_init
struct I64Row(Copyable, Movable):
    var a: Int64

# --- F32 ---
@fieldwise_init
struct F32PairRow(Copyable, Movable):
    var a: Float32
    var b: Float32

@fieldwise_init
struct F32Row(Copyable, Movable):
    var a: Float32

# --- I32 ---
@fieldwise_init
struct I32PairRow(Copyable, Movable):
    var a: Int32
    var b: Int32

@fieldwise_init
struct I32Row(Copyable, Movable):
    var a: Int32


# =============================================================================
# ARITHMETIC TEMPLATES — ColCol shape (16 templates)
#
# Each template:
#   - alias T_IN  = {Dtype}PairRow
#   - alias T_OUT = {Dtype}Row
#   - @staticmethod fn eval_row(row: T_IN) -> T_OUT          (scalar oracle)
#   - @staticmethod fn eval[W: Int](input: SimdOf[T_IN, W]) -> SimdOf[T_OUT, W]
#
# Mojo idiom: `Self.T_IN` / `Self.T_OUT` / `Self.W` REQUIRED for
# parameter refs in bodies.
# =============================================================================


# ---- F64 × F64 → F64 (ColCol) ----

@fieldwise_init
struct GenBinaryArithAdd_F64_ColCol(Copyable, Movable):
    """Template ID 1 — `BIN_ADD(ColRef:F64, ColRef:F64) → F64`."""
    comptime T_IN = F64PairRow
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64PairRow) -> F64Row:
        return F64Row(a=row.a + row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64PairRow, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f64[0]() + input.get_f64[1]())
        return out^


@fieldwise_init
struct GenBinaryArithSub_F64_ColCol(Copyable, Movable):
    """Template ID 2 — `BIN_SUB(ColRef:F64, ColRef:F64) → F64`."""
    comptime T_IN = F64PairRow
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64PairRow) -> F64Row:
        return F64Row(a=row.a - row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64PairRow, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f64[0]() - input.get_f64[1]())
        return out^


@fieldwise_init
struct GenBinaryArithMul_F64_ColCol(Copyable, Movable):
    """Template ID 3 — `BIN_MUL(ColRef:F64, ColRef:F64) → F64`.
    Q6's `l_extendedprice * l_discount` lowers to this."""
    comptime T_IN = F64PairRow
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64PairRow) -> F64Row:
        return F64Row(a=row.a * row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64PairRow, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f64[0]() * input.get_f64[1]())
        return out^


@fieldwise_init
struct GenBinaryArithDiv_F64_ColCol(Copyable, Movable):
    """Template ID 4 — `BIN_DIV(ColRef:F64, ColRef:F64) → F64`.

    NOTE: division by zero produces ±inf or NaN per IEEE 754 — no explicit
    NULL semantics here; null handling is the caller's concern.
    """
    comptime T_IN = F64PairRow
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64PairRow) -> F64Row:
        return F64Row(a=row.a / row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64PairRow, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f64[0]() / input.get_f64[1]())
        return out^


# ---- I64 × I64 → I64 (ColCol) ----

@fieldwise_init
struct GenBinaryArithAdd_I64_ColCol(Copyable, Movable):
    """Template ID 5 — `BIN_ADD(ColRef:I64, ColRef:I64) → I64`."""
    comptime T_IN = I64PairRow
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64PairRow) -> I64Row:
        return I64Row(a=row.a + row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64PairRow, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() + input.get_i64[1]())
        return out^


@fieldwise_init
struct GenBinaryArithSub_I64_ColCol(Copyable, Movable):
    """Template ID 6 — `BIN_SUB(ColRef:I64, ColRef:I64) → I64`."""
    comptime T_IN = I64PairRow
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64PairRow) -> I64Row:
        return I64Row(a=row.a - row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64PairRow, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() - input.get_i64[1]())
        return out^


@fieldwise_init
struct GenBinaryArithMul_I64_ColCol(Copyable, Movable):
    """Template ID 7 — `BIN_MUL(ColRef:I64, ColRef:I64) → I64`."""
    comptime T_IN = I64PairRow
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64PairRow) -> I64Row:
        return I64Row(a=row.a * row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64PairRow, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() * input.get_i64[1]())
        return out^


@fieldwise_init
struct GenBinaryArithDiv_I64_ColCol(Copyable, Movable):
    """Template ID 8 — `BIN_DIV(ColRef:I64, ColRef:I64) → I64`.

    NOTE: integer divide-by-zero is UB in Mojo (matches Rust's release
    semantics). MANUAL null mode is handled by the caller.
    """
    comptime T_IN = I64PairRow
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64PairRow) -> I64Row:
        return I64Row(a=row.a // row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64PairRow, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() // input.get_i64[1]())
        return out^


# ---- F32 × F32 → F32 (ColCol) ----

@fieldwise_init
struct GenBinaryArithAdd_F32_ColCol(Copyable, Movable):
    """Template ID 9 — `BIN_ADD(ColRef:F32, ColRef:F32) → F32`."""
    comptime T_IN = F32PairRow
    comptime T_OUT = F32Row

    @staticmethod
    @always_inline
    def eval_row(row: F32PairRow) -> F32Row:
        return F32Row(a=row.a + row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32PairRow, W]) -> SimdOf[F32Row, W]:
        var out = SimdOf[F32Row, W].zero()
        out.set_f32[0](input.get_f32[0]() + input.get_f32[1]())
        return out^


@fieldwise_init
struct GenBinaryArithSub_F32_ColCol(Copyable, Movable):
    """Template ID 10 — `BIN_SUB(ColRef:F32, ColRef:F32) → F32`."""
    comptime T_IN = F32PairRow
    comptime T_OUT = F32Row

    @staticmethod
    @always_inline
    def eval_row(row: F32PairRow) -> F32Row:
        return F32Row(a=row.a - row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32PairRow, W]) -> SimdOf[F32Row, W]:
        var out = SimdOf[F32Row, W].zero()
        out.set_f32[0](input.get_f32[0]() - input.get_f32[1]())
        return out^


@fieldwise_init
struct GenBinaryArithMul_F32_ColCol(Copyable, Movable):
    """Template ID 11 — `BIN_MUL(ColRef:F32, ColRef:F32) → F32`."""
    comptime T_IN = F32PairRow
    comptime T_OUT = F32Row

    @staticmethod
    @always_inline
    def eval_row(row: F32PairRow) -> F32Row:
        return F32Row(a=row.a * row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32PairRow, W]) -> SimdOf[F32Row, W]:
        var out = SimdOf[F32Row, W].zero()
        out.set_f32[0](input.get_f32[0]() * input.get_f32[1]())
        return out^


@fieldwise_init
struct GenBinaryArithDiv_F32_ColCol(Copyable, Movable):
    """Template ID 12 — `BIN_DIV(ColRef:F32, ColRef:F32) → F32`."""
    comptime T_IN = F32PairRow
    comptime T_OUT = F32Row

    @staticmethod
    @always_inline
    def eval_row(row: F32PairRow) -> F32Row:
        return F32Row(a=row.a / row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32PairRow, W]) -> SimdOf[F32Row, W]:
        var out = SimdOf[F32Row, W].zero()
        out.set_f32[0](input.get_f32[0]() / input.get_f32[1]())
        return out^


# ---- I32 × I32 → I32 (ColCol) ----

@fieldwise_init
struct GenBinaryArithAdd_I32_ColCol(Copyable, Movable):
    """Template ID 13 — `BIN_ADD(ColRef:I32, ColRef:I32) → I32`."""
    comptime T_IN = I32PairRow
    comptime T_OUT = I32Row

    @staticmethod
    @always_inline
    def eval_row(row: I32PairRow) -> I32Row:
        return I32Row(a=row.a + row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32PairRow, W]) -> SimdOf[I32Row, W]:
        var out = SimdOf[I32Row, W].zero()
        out.set_i32[0](input.get_i32[0]() + input.get_i32[1]())
        return out^


@fieldwise_init
struct GenBinaryArithSub_I32_ColCol(Copyable, Movable):
    """Template ID 14 — `BIN_SUB(ColRef:I32, ColRef:I32) → I32`."""
    comptime T_IN = I32PairRow
    comptime T_OUT = I32Row

    @staticmethod
    @always_inline
    def eval_row(row: I32PairRow) -> I32Row:
        return I32Row(a=row.a - row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32PairRow, W]) -> SimdOf[I32Row, W]:
        var out = SimdOf[I32Row, W].zero()
        out.set_i32[0](input.get_i32[0]() - input.get_i32[1]())
        return out^


@fieldwise_init
struct GenBinaryArithMul_I32_ColCol(Copyable, Movable):
    """Template ID 15 — `BIN_MUL(ColRef:I32, ColRef:I32) → I32`."""
    comptime T_IN = I32PairRow
    comptime T_OUT = I32Row

    @staticmethod
    @always_inline
    def eval_row(row: I32PairRow) -> I32Row:
        return I32Row(a=row.a * row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32PairRow, W]) -> SimdOf[I32Row, W]:
        var out = SimdOf[I32Row, W].zero()
        out.set_i32[0](input.get_i32[0]() * input.get_i32[1]())
        return out^


@fieldwise_init
struct GenBinaryArithDiv_I32_ColCol(Copyable, Movable):
    """Template ID 16 — `BIN_DIV(ColRef:I32, ColRef:I32) → I32`."""
    comptime T_IN = I32PairRow
    comptime T_OUT = I32Row

    @staticmethod
    @always_inline
    def eval_row(row: I32PairRow) -> I32Row:
        return I32Row(a=row.a // row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32PairRow, W]) -> SimdOf[I32Row, W]:
        var out = SimdOf[I32Row, W].zero()
        out.set_i32[0](input.get_i32[0]() // input.get_i32[1]())
        return out^


# =============================================================================
# ARITHMETIC TEMPLATES — ColLit shape (8 templates, F64+I64)
#
# The literal is passed as a runtime broadcast scalar to `eval[W]` — keeping
# the template stateless. The matcher already extracted the literal's value
# at plan-bind time; the engine threads it through to the dispatch arm.
# =============================================================================

@fieldwise_init
struct GenBinaryArithAdd_F64_ColLit(Copyable, Movable):
    """Template ID 17 — `BIN_ADD(ColRef:F64, Literal:F64) → F64`."""
    comptime T_IN = F64Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> F64Row:
        return F64Row(a=row.a + lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f64[0]() + SIMD[DType.float64, W](lit))
        return out^


@fieldwise_init
struct GenBinaryArithSub_F64_ColLit(Copyable, Movable):
    """Template ID 18 — `BIN_SUB(ColRef:F64, Literal:F64) → F64`."""
    comptime T_IN = F64Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> F64Row:
        return F64Row(a=row.a - lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f64[0]() - SIMD[DType.float64, W](lit))
        return out^


@fieldwise_init
struct GenBinaryArithMul_F64_ColLit(Copyable, Movable):
    """Template ID 19 — `BIN_MUL(ColRef:F64, Literal:F64) → F64`."""
    comptime T_IN = F64Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> F64Row:
        return F64Row(a=row.a * lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f64[0]() * SIMD[DType.float64, W](lit))
        return out^


@fieldwise_init
struct GenBinaryArithDiv_F64_ColLit(Copyable, Movable):
    """Template ID 20 — `BIN_DIV(ColRef:F64, Literal:F64) → F64`."""
    comptime T_IN = F64Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> F64Row:
        return F64Row(a=row.a / lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f64[0]() / SIMD[DType.float64, W](lit))
        return out^


@fieldwise_init
struct GenBinaryArithAdd_I64_ColLit(Copyable, Movable):
    """Template ID 21 — `BIN_ADD(ColRef:I64, Literal:I64) → I64`."""
    comptime T_IN = I64Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> I64Row:
        return I64Row(a=row.a + lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() + SIMD[DType.int64, W](lit))
        return out^


@fieldwise_init
struct GenBinaryArithSub_I64_ColLit(Copyable, Movable):
    """Template ID 22 — `BIN_SUB(ColRef:I64, Literal:I64) → I64`."""
    comptime T_IN = I64Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> I64Row:
        return I64Row(a=row.a - lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() - SIMD[DType.int64, W](lit))
        return out^


@fieldwise_init
struct GenBinaryArithMul_I64_ColLit(Copyable, Movable):
    """Template ID 23 — `BIN_MUL(ColRef:I64, Literal:I64) → I64`."""
    comptime T_IN = I64Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> I64Row:
        return I64Row(a=row.a * lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() * SIMD[DType.int64, W](lit))
        return out^


@fieldwise_init
struct GenBinaryArithDiv_I64_ColLit(Copyable, Movable):
    """Template ID 24 — `BIN_DIV(ColRef:I64, Literal:I64) → I64`."""
    comptime T_IN = I64Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> I64Row:
        return I64Row(a=row.a // lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() // SIMD[DType.int64, W](lit))
        return out^


# =============================================================================
# COMPARISON TEMPLATES — ColLit shape (12 templates: 6 ops × F64+I64)
#
# Output is a single Bool per row (filter-path use). Matches Q6's 5
# `col(...) >=/<=/<` Lit filter expressions (F64 + I32-as-Date32).
#
# Mojo 1.0.0b1 idiom: SIMD compare uses `.ge() / .gt() / .lt() / .le() /
# .eq()` method form for W>1; `>=`/`>`/`<`/`<=`/`==`/`!=` are
# Scalar-only (W=1). Float `<>` is `~eq`: `.ne()` is ordered (NaN -> FALSE)
# and would disagree with the scalar `!=` (NaN -> TRUE).
# =============================================================================

@fieldwise_init
struct GenBinaryCmpGt_F64_ColLit(Copyable, Movable):
    """Template ID 25 — `BIN_GT(ColRef:F64, Literal:F64) → Bool`."""
    comptime T_IN = F64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> BoolRow:
        return BoolRow(a=row.a > lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_f64[0]().gt(SIMD[DType.float64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpGe_F64_ColLit(Copyable, Movable):
    """Template ID 26 — `BIN_GE(ColRef:F64, Literal:F64) → Bool`.
    Q6's `col("l_discount") >= 0.05` lowers to this."""
    comptime T_IN = F64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> BoolRow:
        return BoolRow(a=row.a >= lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_f64[0]().ge(SIMD[DType.float64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpLt_F64_ColLit(Copyable, Movable):
    """Template ID 27 — `BIN_LT(ColRef:F64, Literal:F64) → Bool`.
    Q6's `col("l_quantity") < 24.0` lowers to this."""
    comptime T_IN = F64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> BoolRow:
        return BoolRow(a=row.a < lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_f64[0]().lt(SIMD[DType.float64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpLe_F64_ColLit(Copyable, Movable):
    """Template ID 28 — `BIN_LE(ColRef:F64, Literal:F64) → Bool`.
    Q6's `col("l_discount") <= 0.07` lowers to this."""
    comptime T_IN = F64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> BoolRow:
        return BoolRow(a=row.a <= lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_f64[0]().le(SIMD[DType.float64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpEq_F64_ColLit(Copyable, Movable):
    """Template ID 29 — `BIN_EQ(ColRef:F64, Literal:F64) → Bool`."""
    comptime T_IN = F64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> BoolRow:
        return BoolRow(a=row.a == lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_f64[0]().eq(SIMD[DType.float64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpNe_F64_ColLit(Copyable, Movable):
    """Template ID 30 — `BIN_NE(ColRef:F64, Literal:F64) → Bool`."""
    comptime T_IN = F64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F64Row, lit: Float64) -> BoolRow:
        return BoolRow(a=row.a != lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W], lit: Float64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        # `~eq`, not `.ne()`: SIMD `.ne()` is an ORDERED compare and answers
        # a NaN row FALSE, where `eval_row`'s `!=` (IEEE unordered) answers
        # TRUE. The two paths must agree on every row.
        out.set_bool[0](~input.get_f64[0]().eq(SIMD[DType.float64, W](lit)))
        return out^


# ---- I64 ColLit comparison ----

@fieldwise_init
struct GenBinaryCmpGt_I64_ColLit(Copyable, Movable):
    """Template ID 31 — `BIN_GT(ColRef:I64, Literal:I64) → Bool`.
    Q18's `sum(l_quantity) > 300` post-agg HAVING lowers to this."""
    comptime T_IN = I64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> BoolRow:
        return BoolRow(a=row.a > lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_i64[0]().gt(SIMD[DType.int64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpGe_I64_ColLit(Copyable, Movable):
    """Template ID 32 — `BIN_GE(ColRef:I64, Literal:I64) → Bool`.
    Q6's `col("l_shipdate") >= date_1994` (Date32-as-I32-via-cast or
    direct I64) lowers to this."""
    comptime T_IN = I64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> BoolRow:
        return BoolRow(a=row.a >= lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_i64[0]().ge(SIMD[DType.int64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpLt_I64_ColLit(Copyable, Movable):
    """Template ID 33 — `BIN_LT(ColRef:I64, Literal:I64) → Bool`.
    Q6's `col("l_shipdate") < date_1995` lowers to this."""
    comptime T_IN = I64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> BoolRow:
        return BoolRow(a=row.a < lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_i64[0]().lt(SIMD[DType.int64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpLe_I64_ColLit(Copyable, Movable):
    """Template ID 34 — `BIN_LE(ColRef:I64, Literal:I64) → Bool`."""
    comptime T_IN = I64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> BoolRow:
        return BoolRow(a=row.a <= lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_i64[0]().le(SIMD[DType.int64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpEq_I64_ColLit(Copyable, Movable):
    """Template ID 35 — `BIN_EQ(ColRef:I64, Literal:I64) → Bool`."""
    comptime T_IN = I64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> BoolRow:
        return BoolRow(a=row.a == lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_i64[0]().eq(SIMD[DType.int64, W](lit)))
        return out^


@fieldwise_init
struct GenBinaryCmpNe_I64_ColLit(Copyable, Movable):
    """Template ID 36 — `BIN_NE(ColRef:I64, Literal:I64) → Bool`."""
    comptime T_IN = I64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I64Row, lit: Int64) -> BoolRow:
        return BoolRow(a=row.a != lit)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W], lit: Int64) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_i64[0]().ne(SIMD[DType.int64, W](lit)))
        return out^


# =============================================================================
# InterpretedExprKernel — sentinel
#
# The interpreter itself is `komira_kernels.expr_interpreter`. This stub exists
# so the matcher's "no template match" branch has a stable sentinel to return
# (EXPR_TEMPLATE_INTERPRETED = 0); the engine dispatch arm routes interpreted
# exprs.
# =============================================================================

@fieldwise_init
struct InterpretedExprKernel(Copyable, Movable):
    """Sentinel struct for the generic Expr-tree interpreter fallback.

    Template ID 0 (`EXPR_TEMPLATE_INTERPRETED`). The full interpreter body
    lives in `expr_interpreter.mojo` and dispatches by walking the
    Expr tree node-by-node. The interpreter is ~5-10 ns/lane
    vs the templates' ~0.5 ns/lane.

    The matcher (in `optimizer_expr.mojo`) returns `Optional.none()` for
    any Expr shape outside the templated set; callers then know to take
    the interpreter path (or the legacy engine evaluator).
    """
    pass


# =============================================================================
# PHASE 3.b — CAST templates (8 templates: IDs 37..44)
#
# Each cast template takes a 1-field input row and emits a 1-field output
# row of the converted dtype. Used by `EXPR_CAST` Expr nodes when the source
# and target dtype both have SimdOf accessors.
# =============================================================================

@fieldwise_init
struct GenCast_F64_To_F32(Copyable, Movable):
    """Template ID 37 — `cast(F64 → F32)`."""
    comptime T_IN = F64Row
    comptime T_OUT = F32Row

    @staticmethod
    @always_inline
    def eval_row(row: F64Row) -> F32Row:
        return F32Row(a=Float32(row.a))

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W]) -> SimdOf[F32Row, W]:
        var out = SimdOf[F32Row, W].zero()
        out.set_f32[0](input.get_f64[0]().cast[DType.float32]())
        return out^


@fieldwise_init
struct GenCast_F32_To_F64(Copyable, Movable):
    """Template ID 38 — `cast(F32 → F64)`."""
    comptime T_IN = F32Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F32Row) -> F64Row:
        return F64Row(a=Float64(row.a))

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32Row, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_f32[0]().cast[DType.float64]())
        return out^


@fieldwise_init
struct GenCast_I64_To_I32(Copyable, Movable):
    """Template ID 39 — `cast(I64 → I32)` (truncating)."""
    comptime T_IN = I64Row
    comptime T_OUT = I32Row

    @staticmethod
    @always_inline
    def eval_row(row: I64Row) -> I32Row:
        return I32Row(a=Int32(row.a))

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W]) -> SimdOf[I32Row, W]:
        var out = SimdOf[I32Row, W].zero()
        out.set_i32[0](input.get_i64[0]().cast[DType.int32]())
        return out^


@fieldwise_init
struct GenCast_I32_To_I64(Copyable, Movable):
    """Template ID 40 — `cast(I32 → I64)`."""
    comptime T_IN = I32Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I32Row) -> I64Row:
        return I64Row(a=Int64(row.a))

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32Row, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i32[0]().cast[DType.int64]())
        return out^


@fieldwise_init
struct GenCast_F64_To_I64(Copyable, Movable):
    """Template ID 41 — `cast(F64 → I64)`, rounding HALF TO EVEN.

    ⚠ NOT TRUNCATING. DuckDB v1.5.3 rounds half to even on a float -> integer
    cast.

    ⛔⛔ AND THIS TEMPLATE IS **UNREACHABLE** from SQL: the only reader of the
    `EXPR_TEMPLATE_CAST_*` ids is `optimizer_expr._match_expr_to_kernel_template`,
    a SHAPE matcher, and its only assertions are in a coverage test. The live SQL
    cast runs in `compiler_eval_column`'s `EXPR_CAST` arm. The rounding is
    correct here anyway so that wiring the registry up later cannot introduce a
    truncating cast.
    """
    comptime T_IN = F64Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64Row) -> I64Row:
        return I64Row(a=round_half_to_even[DType.float64, 1](SIMD[DType.float64, 1](row.a)).cast[DType.int64]()[0])

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](round_half_to_even[DType.float64, W](input.get_f64[0]()).cast[DType.int64]())
        return out^


@fieldwise_init
struct GenCast_I64_To_F64(Copyable, Movable):
    """Template ID 42 — `cast(I64 → F64)`."""
    comptime T_IN = I64Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64Row) -> F64Row:
        return F64Row(a=Float64(row.a))

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_i64[0]().cast[DType.float64]())
        return out^


@fieldwise_init
struct GenCast_I32_To_F64(Copyable, Movable):
    """Template ID 43 — `cast(I32 → F64)`."""
    comptime T_IN = I32Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: I32Row) -> F64Row:
        return F64Row(a=Float64(row.a))

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32Row, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](input.get_i32[0]().cast[DType.float64]())
        return out^


@fieldwise_init
struct GenCast_F32_To_I64(Copyable, Movable):
    """Template ID 44 — `cast(F32 → I64)`, rounding HALF TO EVEN.

    ⚠ NOT TRUNCATING. DuckDB v1.5.3 rounds half to even on a float -> integer
    cast.

    ⛔⛔ AND THIS TEMPLATE IS **UNREACHABLE** from SQL: the only reader of the
    `EXPR_TEMPLATE_CAST_*` ids is `optimizer_expr._match_expr_to_kernel_template`,
    a SHAPE matcher, and its only assertions are in a coverage test. The live SQL
    cast runs in `compiler_eval_column`'s `EXPR_CAST` arm. The rounding is
    correct here anyway so that wiring the registry up later cannot introduce a
    truncating cast.
    """
    comptime T_IN = F32Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: F32Row) -> I64Row:
        return I64Row(a=round_half_to_even[DType.float32, 1](SIMD[DType.float32, 1](row.a)).cast[DType.int64]()[0])

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32Row, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](round_half_to_even[DType.float32, W](input.get_f32[0]()).cast[DType.int64]())
        return out^


# =============================================================================
# PHASE 3.b — WHEN/OTHERWISE templates (4 templates: IDs 45..48)
#
# Shape: pred (Bool) ? then : else → result. Lane-wise mask.select pattern.
#
# T_IN is a 3-field struct {pred: Bool, then_v: Dtype, else_v: Dtype} and
# T_OUT is the result dtype. The optimizer feeds the predicate's result and
# the two branch values into a single SimdOf chunk.
# =============================================================================

@fieldwise_init
struct WhenF64Row(Copyable, Movable):
    var pred: Bool
    var then_v: Float64
    var else_v: Float64


@fieldwise_init
struct WhenF32Row(Copyable, Movable):
    var pred: Bool
    var then_v: Float32
    var else_v: Float32


@fieldwise_init
struct WhenI64Row(Copyable, Movable):
    var pred: Bool
    var then_v: Int64
    var else_v: Int64


@fieldwise_init
struct WhenI32Row(Copyable, Movable):
    var pred: Bool
    var then_v: Int32
    var else_v: Int32


@fieldwise_init
struct GenWhen_F64(Copyable, Movable):
    """Template ID 45 — `when(pred, then_v, else_v) → F64`."""
    comptime T_IN = WhenF64Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: WhenF64Row) -> F64Row:
        if row.pred:
            return F64Row(a=row.then_v)
        return F64Row(a=row.else_v)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[WhenF64Row, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        var m = input.get_bool[0]()
        var t = input.get_f64[1]()
        var e = input.get_f64[2]()
        out.set_f64[0](m.select(t, e))
        return out^


@fieldwise_init
struct GenWhen_F32(Copyable, Movable):
    """Template ID 46 — `when(pred, then_v, else_v) → F32`."""
    comptime T_IN = WhenF32Row
    comptime T_OUT = F32Row

    @staticmethod
    @always_inline
    def eval_row(row: WhenF32Row) -> F32Row:
        if row.pred:
            return F32Row(a=row.then_v)
        return F32Row(a=row.else_v)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[WhenF32Row, W]) -> SimdOf[F32Row, W]:
        var out = SimdOf[F32Row, W].zero()
        var m = input.get_bool[0]()
        var t = input.get_f32[1]()
        var e = input.get_f32[2]()
        out.set_f32[0](m.select(t, e))
        return out^


@fieldwise_init
struct GenWhen_I64(Copyable, Movable):
    """Template ID 47 — `when(pred, then_v, else_v) → I64`."""
    comptime T_IN = WhenI64Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: WhenI64Row) -> I64Row:
        if row.pred:
            return I64Row(a=row.then_v)
        return I64Row(a=row.else_v)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[WhenI64Row, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        var m = input.get_bool[0]()
        var t = input.get_i64[1]()
        var e = input.get_i64[2]()
        out.set_i64[0](m.select(t, e))
        return out^


@fieldwise_init
struct GenWhen_I32(Copyable, Movable):
    """Template ID 48 — `when(pred, then_v, else_v) → I32`."""
    comptime T_IN = WhenI32Row
    comptime T_OUT = I32Row

    @staticmethod
    @always_inline
    def eval_row(row: WhenI32Row) -> I32Row:
        if row.pred:
            return I32Row(a=row.then_v)
        return I32Row(a=row.else_v)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[WhenI32Row, W]) -> SimdOf[I32Row, W]:
        var out = SimdOf[I32Row, W].zero()
        var m = input.get_bool[0]()
        var t = input.get_i32[1]()
        var e = input.get_i32[2]()
        out.set_i32[0](m.select(t, e))
        return out^


# =============================================================================
# PHASE 3.b — IS_NULL / IS_NOT_NULL templates (8 templates: IDs 49..56)
#
# These templates produce the SHAPE of the kernel — the actual validity-mask
# read happens at the engine boundary where the morsel
# executor has access to the column's validity bitmap.
#
# In SimdOf the blob does NOT carry a validity slot;
# the validity mask is plumbed alongside SimdOf at the engine boundary.
# The eval[W] body here returns a placeholder:
# is_null returns all-False (assuming non-null), is_not_null returns
# all-True. The engine's dispatch arm BYPASSES this body
# and produces the correct result from the validity bitmap directly.
#
# The eval_row body receives a value-only row (no validity); for the scalar
# tail path the engine dispatch arm checks validity separately. For the
# unit/coverage trip-wire test, the templates exist with the correct shape
# (T_IN/T_OUT) and template-id, and the matcher correctly maps the Expr
# UN_IS_NULL / UN_IS_NOT_NULL nodes to them. End-to-end correctness comes
# from the engine dispatch arm.
# =============================================================================


@fieldwise_init
struct GenIsNull_F64(Copyable, Movable):
    """Template ID 49 — `is_null(F64)` → Bool. See module note above."""
    comptime T_IN = F64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F64Row) -> BoolRow:
        return BoolRow(a=False)  # validity check at engine boundary

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](SIMD[DType.bool, W](fill=False))
        return out^


@fieldwise_init
struct GenIsNotNull_F64(Copyable, Movable):
    """Template ID 50 — `is_not_null(F64)` → Bool."""
    comptime T_IN = F64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F64Row) -> BoolRow:
        return BoolRow(a=True)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](SIMD[DType.bool, W](fill=True))
        return out^


@fieldwise_init
struct GenIsNull_F32(Copyable, Movable):
    """Template ID 51 — `is_null(F32)` → Bool."""
    comptime T_IN = F32Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F32Row) -> BoolRow:
        return BoolRow(a=False)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32Row, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](SIMD[DType.bool, W](fill=False))
        return out^


@fieldwise_init
struct GenIsNotNull_F32(Copyable, Movable):
    """Template ID 52 — `is_not_null(F32)` → Bool."""
    comptime T_IN = F32Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: F32Row) -> BoolRow:
        return BoolRow(a=True)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32Row, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](SIMD[DType.bool, W](fill=True))
        return out^


@fieldwise_init
struct GenIsNull_I64(Copyable, Movable):
    """Template ID 53 — `is_null(I64)` → Bool."""
    comptime T_IN = I64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I64Row) -> BoolRow:
        return BoolRow(a=False)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](SIMD[DType.bool, W](fill=False))
        return out^


@fieldwise_init
struct GenIsNotNull_I64(Copyable, Movable):
    """Template ID 54 — `is_not_null(I64)` → Bool."""
    comptime T_IN = I64Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I64Row) -> BoolRow:
        return BoolRow(a=True)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](SIMD[DType.bool, W](fill=True))
        return out^


@fieldwise_init
struct GenIsNull_I32(Copyable, Movable):
    """Template ID 55 — `is_null(I32)` → Bool."""
    comptime T_IN = I32Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I32Row) -> BoolRow:
        return BoolRow(a=False)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32Row, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](SIMD[DType.bool, W](fill=False))
        return out^


@fieldwise_init
struct GenIsNotNull_I32(Copyable, Movable):
    """Template ID 56 — `is_not_null(I32)` → Bool."""
    comptime T_IN = I32Row
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: I32Row) -> BoolRow:
        return BoolRow(a=True)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32Row, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](SIMD[DType.bool, W](fill=True))
        return out^


# =============================================================================
# PHASE 3.b — BOOLEAN COMPOSITION (3 templates: IDs 57..59)
#
# AND/OR over two BoolRow inputs; NOT over one. Used by the optimizer when a
# Filter Expr has a multi-clause boolean composition (e.g. Q6's 5-way AND
# chain after fuse_filters_inplace).
# =============================================================================


@fieldwise_init
struct BoolPairRow(Copyable, Movable):
    """Two Bool inputs (AND/OR composition)."""
    var a: Bool
    var b: Bool


@fieldwise_init
struct GenBool_And(Copyable, Movable):
    """Template ID 57 — `BIN_AND(Bool, Bool) → Bool`."""
    comptime T_IN = BoolPairRow
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: BoolPairRow) -> BoolRow:
        return BoolRow(a=row.a and row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[BoolPairRow, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_bool[0]() & input.get_bool[1]())
        return out^


@fieldwise_init
struct GenBool_Or(Copyable, Movable):
    """Template ID 58 — `BIN_OR(Bool, Bool) → Bool`."""
    comptime T_IN = BoolPairRow
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: BoolPairRow) -> BoolRow:
        return BoolRow(a=row.a or row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[BoolPairRow, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](input.get_bool[0]() | input.get_bool[1]())
        return out^


@fieldwise_init
struct GenBool_Not(Copyable, Movable):
    """Template ID 59 — `UN_NOT(Bool) → Bool`."""
    comptime T_IN = BoolRow
    comptime T_OUT = BoolRow

    @staticmethod
    @always_inline
    def eval_row(row: BoolRow) -> BoolRow:
        return BoolRow(a=not row.a)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[BoolRow, W]) -> SimdOf[BoolRow, W]:
        var out = SimdOf[BoolRow, W].zero()
        out.set_bool[0](~input.get_bool[0]())
        return out^


# =============================================================================
# PHASE 3.b — UNARY NEGATE (4 templates: IDs 60..63)
# =============================================================================


@fieldwise_init
struct GenNegate_F64(Copyable, Movable):
    """Template ID 60 — `UN_NEGATE(F64) → F64`."""
    comptime T_IN = F64Row
    comptime T_OUT = F64Row

    @staticmethod
    @always_inline
    def eval_row(row: F64Row) -> F64Row:
        return F64Row(a=-row.a)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F64Row, W]) -> SimdOf[F64Row, W]:
        var out = SimdOf[F64Row, W].zero()
        out.set_f64[0](-input.get_f64[0]())
        return out^


@fieldwise_init
struct GenNegate_F32(Copyable, Movable):
    """Template ID 61 — `UN_NEGATE(F32) → F32`."""
    comptime T_IN = F32Row
    comptime T_OUT = F32Row

    @staticmethod
    @always_inline
    def eval_row(row: F32Row) -> F32Row:
        return F32Row(a=-row.a)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[F32Row, W]) -> SimdOf[F32Row, W]:
        var out = SimdOf[F32Row, W].zero()
        out.set_f32[0](-input.get_f32[0]())
        return out^


@fieldwise_init
struct GenNegate_I64(Copyable, Movable):
    """Template ID 62 — `UN_NEGATE(I64) → I64`."""
    comptime T_IN = I64Row
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64Row) -> I64Row:
        return I64Row(a=-row.a)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64Row, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](-input.get_i64[0]())
        return out^


@fieldwise_init
struct GenNegate_I32(Copyable, Movable):
    """Template ID 63 — `UN_NEGATE(I32) → I32`."""
    comptime T_IN = I32Row
    comptime T_OUT = I32Row

    @staticmethod
    @always_inline
    def eval_row(row: I32Row) -> I32Row:
        return I32Row(a=-row.a)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32Row, W]) -> SimdOf[I32Row, W]:
        var out = SimdOf[I32Row, W].zero()
        out.set_i32[0](-input.get_i32[0]())
        return out^


# =============================================================================
# PHASE 3.b — INTEGER MOD (2 templates: IDs 64..65)
# =============================================================================


@fieldwise_init
struct GenBinaryMod_I64_ColCol(Copyable, Movable):
    """Template ID 64 — `BIN_MOD(I64, I64) → I64`."""
    comptime T_IN = I64PairRow
    comptime T_OUT = I64Row

    @staticmethod
    @always_inline
    def eval_row(row: I64PairRow) -> I64Row:
        return I64Row(a=row.a % row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I64PairRow, W]) -> SimdOf[I64Row, W]:
        var out = SimdOf[I64Row, W].zero()
        out.set_i64[0](input.get_i64[0]() % input.get_i64[1]())
        return out^


@fieldwise_init
struct GenBinaryMod_I32_ColCol(Copyable, Movable):
    """Template ID 65 — `BIN_MOD(I32, I32) → I32`."""
    comptime T_IN = I32PairRow
    comptime T_OUT = I32Row

    @staticmethod
    @always_inline
    def eval_row(row: I32PairRow) -> I32Row:
        return I32Row(a=row.a % row.b)

    @staticmethod
    @always_inline
    def eval[W: Int](input: SimdOf[I32PairRow, W]) -> SimdOf[I32Row, W]:
        var out = SimdOf[I32Row, W].zero()
        out.set_i32[0](input.get_i32[0]() % input.get_i32[1]())
        return out^
