# =============================================================================
# column_arith: column {op} scalar arithmetic and SQL modulo
# =============================================================================
#
# `_eval_binary_col_scalar` (a column against a literal through the SIMD scalar
# kernels) and the truncating modulo and float `fmod` kernels it uses.
# =============================================================================

from std.ffi import external_call

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.arithmetic import (
    eval_add_scalar,
    eval_div,
    eval_div_scalar,
    eval_mul,
    eval_mul_scalar,
    eval_rsub_scalar,
    eval_sub,
    eval_sub_scalar,
)
from komira_column_kernels.compiler_helpers import broadcast_scalar, clone_array_validity
from komira_plan_expr.expr import (
    BIN_ADD,
    BIN_DIV,
    BIN_MOD,
    BIN_MUL,
    BIN_SUB,
)
from komira_plan_expr.literal_domain import int_literal_fits
from komira_plan_expr.scalar_value import ScalarValue

from .column_compare import _column_to_float64, _column_to_int64


# =============================================================================
# Column expression evaluation — Expr -> Column
# =============================================================================


# =============================================================================
# ★★ BIN_MOD AS AN OUTPUT COLUMN — THE LAST BINARY OP WITH NO
#    PROJECTION ARM.
# =============================================================================
#
# `BIN_MOD` (op 4) had an interpreter kernel (`komira_kernels/expr_interpreter`)
# and two generated kernel templates (IDs 64/65) and NO arm here, so `mod(a,b)`
# BOUND and could not RUN: `unsupported int64 scalar binary op: 4` on the
# col-vs-literal ladder and `unsupported int64 binary op: 4` on the col-vs-col
# one. It was held out as `F21-binop-not-executable-as-a-projection` and it was
# the only binary op in that state — every comparison was closed
# by delegating to the predicate ladder, which a remainder cannot do because a
# remainder is not a mask.
#
# ⛔ THERE IS NO `eval_mod` KERNEL AND THESE TWO FUNCTIONS DO NOT WRITE ONE.
# The remainder is composed out of `eval_div` / `eval_mul` / `eval_sub`, which
# is not a shortcut but the ONLY way to inherit three behaviours that are
# already written down once:
#
#   1. `eval_div` / `eval_div_scalar` are TOTAL over the integers. A ZERO
#      DIVISOR yields a NULL row with NOTHING handed to the
#      machine's divide instruction. A hand-written `%` kernel would have had
#      to re-derive that, and the failure mode it protects against is a SIGFPE
#      that takes the process down — measured, on this exact op family.
#   2. `clone_array_validity` MERGES rather than overwrites, so the
#      divide-by-zero mask survives into the remainder.
#   3. The INT64 / INT32 / FLOAT64 width rules and the literal-promotion rules
#      stay in ONE place (`_eval_binary_col_scalar`), which is what this file's
#      own header asks for.
#
# ⛔⛔ AND IT IS `a - trunc(a/b)*b`, NOT `a % b`. MEASURED, IN BOTH DIRECTIONS:
#   * DuckDB v1.5.3 `-17 % 5` = **-2** — TRUNCATED, remainder takes the sign of
#     the DIVIDEND (C's rule).
#   * Mojo's `%` is **FLOOR-mod** — and written down in
#     `komira_kernels/temporal_extract._dayofweek_from_days`, where the same fact
#     is load-bearing in the OPPOSITE direction. `-17 % 5` there is **3**.
# So the language's own operator is the WRONG answer here by 5, and the two
# conventions agree on every non-negative dividend — which is exactly why the
# regression corpus carries `m = -17` and `m = 17, n = -5`. This engine's
# integral `BIN_DIV` truncates toward zero (SIMD `/` lowers to the hardware
# divide), so the identity below IS the truncated remainder.
#
# ⚠ `fmod` IS A DIFFERENT FUNCTION AND MUST NOT BE ROUTED HERE. Measured
# v1.5.3 at (-17, 5): `mod` = -2, `fmod` = **3.0** — FLOORED. `fmod` already
# has its own binder desugar (`sql_binder`, `x - y*floor(x/y)`) and making the
# two agree would be wrong on one of them.
#
# ⚠ `mod(INT64_MIN, -1)` RAISES here because `eval_div`'s MIN/-1 overflow guard
# fires on the quotient — and that AGREES with the oracle. This paragraph used to
# call it a residual ("0 in DuckDB"); RE-DuckDB 1.5.3
# raises `Out of Range Error: Overflow in division of -9223372036854775808 / -1`
# for `mod`, `%` and `//` alike (`numeric_domain_oracle.tsv` i64_mod@k4 is an
# ERROR cell). polars / numpy answer 0 — the skins' business, not this kernel's.
#
# ⛔ THE FLOAT ARM IS NOT THIS IDENTITY. See `_fmod_cc`.


@always_inline
def _fmod_f64(a: Float64, b: Float64) -> Float64:
    """C `fmod` — exact, sign of the dividend, NaN for a zero divisor / an
    infinite dividend, the dividend itself for an infinite divisor."""
    return external_call["fmod", Float64](a, b)


def _fmod_cc[
    dt: DType
](la: PrimitiveArray[dt], ra: PrimitiveArray[dt]) -> PrimitiveArray[dt]:
    """Row-wise `fmod(la, ra)` over a FLOATING dtype. A float32 operand widens
    to float64 exactly, and `fmod`'s exact result narrows back exactly. The
    result carries no validity; the caller merges the operands'."""
    var n = la.length
    var out = PrimitiveArray[dt].allocate(n)
    # SAFETY: origin-tied views held in function scope keep all three buffers
    # alive across the loop; the typed pointers never leave this function.
    var lv = la.view_ro()
    var rv = ra.view_ro()
    var ov = out.view_mut()
    var lp = lv._unsafe_ptr().bitcast[Scalar[dt]]()
    var rp = rv._unsafe_ptr().bitcast[Scalar[dt]]()
    var op_ = ov._unsafe_ptr().bitcast[Scalar[dt]]()
    for i in range(n):
        var r = _fmod_f64(
            lp.load[width=1](i).cast[DType.float64](),
            rp.load[width=1](i).cast[DType.float64](),
        )
        op_.store[width=1](i, r.cast[dt]())
    return out^


def _fmod_cs[
    dt: DType
](arr: PrimitiveArray[dt], scalar: Scalar[dt]) -> PrimitiveArray[dt]:
    """`fmod(arr, scalar)` — the col-vs-LITERAL twin of `_fmod_cc`."""
    var n = arr.length
    var out = PrimitiveArray[dt].allocate(n)
    # SAFETY: as `_fmod_cc`.
    var av = arr.view_ro()
    var ov = out.view_mut()
    var ap = av._unsafe_ptr().bitcast[Scalar[dt]]()
    var op_ = ov._unsafe_ptr().bitcast[Scalar[dt]]()
    var b = scalar.cast[DType.float64]()
    for i in range(n):
        var r = _fmod_f64(ap.load[width=1](i).cast[DType.float64](), b)
        op_.store[width=1](i, r.cast[dt]())
    return out^


def _mod_trunc_cc[
    dt: DType
](la: PrimitiveArray[dt], ra: PrimitiveArray[dt]) raises -> PrimitiveArray[dt]:
    """`la - trunc(la / ra) * ra` — the TRUNCATED remainder, column vs column.

    The integral arm needs no `trunc`: this engine's integral divide already
    truncates toward zero. The floating arm is NOT this identity — it is libm
    `fmod` (`_fmod_cc`), because the identity rounds.
    """

    comptime if dt.is_floating_point():
        # ⛔ NOT `la - trunc(la / ra) * ra` OVER FLOATS. That
        # identity ROUNDS three times: `mod(1.7976931348623157e308, 10.0)`
        # answered 0.0 (DuckDB 8.0 — the quotient has no bits left for the
        # remainder at that magnitude) and `mod(-0.0, 1.0)` answered +0.0
        # (DuckDB -0.0 — `-0.0 - (-0.0 * 1.0)` is +0.0). DuckDB 1.5.3's float
        # `%` IS C `fmod` — MEASURED bit for bit over a 156-pair edge grid
        # (signed zeros, +-inf, NaN, subnormals, DBL_MAX, zero divisors) — and
        # `fmod` is EXACT, so this is libm's.
        return _fmod_cc[dt](la, ra)
    else:
        var q = eval_div[dt](la, ra)
        var pr = eval_mul[dt](q, ra)
        var rem = eval_sub[dt](la, pr)
        # ⛔ LOAD-BEARING: `q`'s NULL rows are the ZERO-DIVISOR rows, and their
        # data slot is an allocated 0 — so `rem` holds `la` there and would
        # come back VALID and WRONG without this. `clone_array_validity`
        # merges, so the caller's own operand merge cannot undo it either.
        clone_array_validity[dt, dt](q, rem)
        return rem^


def _mod_trunc_cs[
    dt: DType
](arr: PrimitiveArray[dt], scalar: Scalar[dt]) raises -> PrimitiveArray[dt]:
    """`arr - trunc(arr / scalar) * scalar` — the col-vs-LITERAL twin.

    Kept as a separate spelling rather than broadcasting the literal into a
    column because that is what every other op on this ladder does: the whole
    point of `_eval_binary_col_scalar` is to avoid materialising N copies of a
    constant, and a MOD that silently did would be the one op on the ladder
    with a different cost model.
    """

    comptime if dt.is_floating_point():
        # libm `fmod`, as `_mod_trunc_cc` (the float identity rounded).
        return _fmod_cs[dt](arr, scalar)
    else:
        # `eval_div_scalar` answers an ALL-NULL column for a zero literal
        # divisor without dividing anything; the merge below carries that.
        var q = eval_div_scalar[dt](arr, scalar)
        var pr = eval_mul_scalar[dt](q, scalar)
        var rem = eval_sub[dt](arr, pr)
        clone_array_validity[dt, dt](q, rem)
        return rem^


def _eval_binary_col_scalar(
    col: Column[HeapRegion], op: UInt8, sv: ScalarValue, scalar_left: Bool = False
) raises -> Column[HeapRegion]:
    """Evaluate column {op} scalar using SIMD scalar kernels.

    `scalar_left=True` evaluates `scalar - column` (BIN_SUB only) through
    `eval_rsub_scalar` — NOT as `-(column - scalar)`, which raised a false
    INT64 overflow at `-1 - MAX` and answered -0.0 for `1.0 - 1.0` (see
    `eval_rsub_scalar`).

    Avoids materializing the scalar into a full N-element array.
    Uses eval_mul_scalar, eval_add_scalar, etc. which broadcast
    the scalar in SIMD registers — zero allocation overhead.
    """
    # NOTE: the `eval_*_scalar` SIMD kernels
    # allocate a fresh result array with no validity; a literal scalar is
    # never NULL, so the result's validity == the column's validity. We copy
    # it onto `result` before wrapping so a `nullable_col + lit` keeps its
    # null mask (was silently coming back all-valid).
    if col.arrow_type == ArrowType.FLOAT64:
        var arr = col.as_primitive[DType.float64]()
        # symmetric to the INT-col vs FLOAT-lit fix
        # below — a FLOAT-col vs INT-literal carries its value in
        # `int_val`, NOT `float_val` (which is 0 for an int literal). Read
        # the scalar via its REAL dtype: float literal -> `float_val`,
        # int literal -> widen `int_val` to f64. Output stays f64.
        var sval: Float64
        if sv.is_int():
            sval = Float64(Int(sv.int_val))
        else:
            sval = sv.float_val
        var scalar = Scalar[DType.float64](sval)
        var result: PrimitiveArray[DType.float64]
        if op == BIN_ADD:
            result = eval_add_scalar[DType.float64](arr, scalar)
        elif op == BIN_SUB and scalar_left:
            result = eval_rsub_scalar[DType.float64](scalar, arr)
        elif op == BIN_SUB:
            result = eval_sub_scalar[DType.float64](arr, scalar)
        elif op == BIN_MUL:
            result = eval_mul_scalar[DType.float64](arr, scalar)
        elif op == BIN_DIV:
            result = eval_div_scalar[DType.float64](arr, scalar)
        elif op == BIN_MOD:
            result = _mod_trunc_cs[DType.float64](arr, scalar)
        else:
            raise Error("unsupported float64 scalar binary op: " + String(Int(op)))
        clone_array_validity[DType.float64, DType.float64](arr, result)
        return Column.from_primitive[DType.float64](result)

    elif col.arrow_type == ArrowType.INT64 or col.arrow_type == ArrowType.INT32:
        # SQL numeric promotion for INT-col {op}
        # FLOAT-literal. The scalar's value lives in `float_val`, NOT
        # `int_val` (ScalarValue.from_float sets int_val=0). Pre-fix the
        # INT arms read `sv.int_val` blindly -> `int_col + 0.5` added 0
        # (silent-wrong). Dispatch on the scalar's REAL dtype: when the
        # literal is FLOAT, promote the int column to f64 (matching the
        # per-node col-col promotion at line ~1307 and the row path) and
        # run the float kernel; output f64. ALL arms (+,-,*,/) affected.
        if sv.is_float():
            var f_arr = _column_to_float64(col)
            var f_scalar = Scalar[DType.float64](sv.float_val)
            var f_result: PrimitiveArray[DType.float64]
            if op == BIN_ADD:
                f_result = eval_add_scalar[DType.float64](f_arr, f_scalar)
            elif op == BIN_SUB and scalar_left:
                f_result = eval_rsub_scalar[DType.float64](f_scalar, f_arr)
            elif op == BIN_SUB:
                f_result = eval_sub_scalar[DType.float64](f_arr, f_scalar)
            elif op == BIN_MUL:
                f_result = eval_mul_scalar[DType.float64](f_arr, f_scalar)
            elif op == BIN_DIV:
                f_result = eval_div_scalar[DType.float64](f_arr, f_scalar)
            elif op == BIN_MOD:
                f_result = _mod_trunc_cs[DType.float64](f_arr, f_scalar)
            else:
                raise Error("unsupported int-col vs float-literal scalar binary op: " + String(Int(op)))
            # `_column_to_float64` is validity-preserving on the column
            # side; the scalar is never NULL, so the f64 result's null
            # mask already matches the source column.
            clone_array_validity[DType.float64, DType.float64](f_arr, f_result)
            return Column.from_primitive[DType.float64](f_result)

        # THE SIXTH SITE, and
        # the one a composition ran through. The INT32 arm below used to build
        # its operand as `Scalar[DType.int32](Int32(Int(sv.int_val)))`, keeping
        # the LOW 32 BITS of the literal. For `+ - *` that was a silent wrong
        # value; for `/` it was worse, because `4294967296` truncates to ZERO
        # and the (correct) divide-by-zero guard then answered NULL for every row:
        # `SELECT q32 / 4294967296` -> NULL, where DuckDB v1.5.3 `//` -> 0. Before the
        # guard the same query was a PROCESS KILL — so the composition is fixed
        # HERE, at the truncation, and NOT by relaxing the guard.
        #
        # SQL numeric promotion is the rule, not an int32-specific patch: an
        # INT32 column against a literal outside int32 range promotes to INT64,
        # the same INT64 ⊕ INT32 → INT64 row `_eval_col_vs_col_promoted`'s table
        # already states, and the same result type DuckDB gives
        # (`typeof(i32 + 4294967296)` = BIGINT, ).
        var int_lit_needs_widening = (
            col.arrow_type == ArrowType.INT32
            and not int_literal_fits[DType.int32](sv.int_val)
        )

        if col.arrow_type == ArrowType.INT64 or int_lit_needs_widening:
            # `_column_to_int64` is the VALIDITY-PRESERVING widen (INT64 passes
            # through zero-copy); never a hand-rolled loop — see this file's
            # col-vs-col header.
            var arr = _column_to_int64(col)
            var scalar = Scalar[DType.int64](sv.int_val)
            var result: PrimitiveArray[DType.int64]
            if op == BIN_ADD:
                result = eval_add_scalar[DType.int64](arr, scalar)
            elif op == BIN_SUB and scalar_left:
                result = eval_rsub_scalar[DType.int64](scalar, arr)
            elif op == BIN_SUB:
                result = eval_sub_scalar[DType.int64](arr, scalar)
            elif op == BIN_MUL:
                result = eval_mul_scalar[DType.int64](arr, scalar)
            elif op == BIN_DIV:
                result = eval_div_scalar[DType.int64](arr, scalar)
            elif op == BIN_MOD:
                result = _mod_trunc_cs[DType.int64](arr, scalar)
            else:
                raise Error("unsupported int64 scalar binary op: " + String(Int(op)))
            clone_array_validity[DType.int64, DType.int64](arr, result)
            return Column.from_primitive[DType.int64](result)

        else:  # ArrowType.INT32, with a literal that PROVABLY fits it
            var arr = col.as_primitive[DType.int32]()
            # Reached only when `int_literal_fits[DType.int32]` said yes, so
            # this cast is LOSSLESS by the branch above. Spelled `.cast[]`
            # rather than the old `Int32(Int(...))` so no future reader has to
            # re-derive whether the truncating form was intentional here.
            var scalar = Scalar[DType.int32](sv.int_val.cast[DType.int32]())
            var result: PrimitiveArray[DType.int32]
            if op == BIN_ADD:
                result = eval_add_scalar[DType.int32](arr, scalar)
            elif op == BIN_SUB and scalar_left:
                result = eval_rsub_scalar[DType.int32](scalar, arr)
            elif op == BIN_SUB:
                result = eval_sub_scalar[DType.int32](arr, scalar)
            elif op == BIN_MUL:
                result = eval_mul_scalar[DType.int32](arr, scalar)
            elif op == BIN_DIV:
                result = eval_div_scalar[DType.int32](arr, scalar)
            elif op == BIN_MOD:
                result = _mod_trunc_cs[DType.int32](arr, scalar)
            else:
                raise Error("unsupported int32 scalar binary op: " + String(Int(op)))
            clone_array_validity[DType.int32, DType.int32](arr, result)
            return Column.from_primitive[DType.int32](result)

    # Fallback: broadcast scalar to column and use column-column path
    from komira_column_kernels.compiler_helpers import broadcast_scalar
    var right_col = broadcast_scalar(sv, col.length())
    raise Error("_eval_binary_col_scalar: unsupported type " + String(Int(col.arrow_type.type_id)))
