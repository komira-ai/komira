# =============================================================================
# scalar_math — element-wise floating-point math kernels for EXPR_MATH_FN(2)
# =============================================================================
#
# These kernels back the
# `EXPR_MATH_FN` (unary: sin / cos / sqrt / asin / radians) and
# `EXPR_MATH_FN2` (binary: atan2) Expr variants that the `haversine`
# example needs (great-circle distance over lat/lon).
#
# Contract:
#   * Input is always FLOAT64 (the eval arm in compiler_eval_column.mojo
#     casts the child column to FLOAT64 before calling these).
#   * Output is always FLOAT64.
#   * Validity is carried verbatim (null in -> null out) via
#     `clone_array_validity` — same discipline as int64_to_float64.
#
# Implementation note: per-element scalar loop using `std.math`.  Derived
# math columns (haversine, deg/rad conversions) are projected once per
# record batch, not in a hot aggregation inner loop, so the scalar form is
# correct + clear and SIMD widening is deliberately deferred.
# =============================================================================

from std.math import sqrt, sin, cos, asin, atan2, pi, ceil, floor
from std.ffi import external_call

from komira_arrow.bitmap import Bitmap
from komira_arrow.primitive_array import PrimitiveArray
from komira_column_kernels.compiler_helpers import clone_array_validity

# Unary math-fn op codes — kept in lockstep with the MATH_* constants in
# komira_plan_expr/expr.mojo (the IR side).  Duplicated here as local
# kernel tags so this leaf module has no dependency on the plan layer.
comptime KMATH_SIN: UInt8 = 0
comptime KMATH_COS: UInt8 = 1
comptime KMATH_SQRT: UInt8 = 2
comptime KMATH_ASIN: UInt8 = 3
comptime KMATH_RADIANS: UInt8 = 4
# The DOUBLE-returning SQL functions.
comptime KMATH_CEIL: UInt8 = 5
comptime KMATH_FLOOR: UInt8 = 6
comptime KMATH_LN: UInt8 = 7
comptime KMATH_EXP: UInt8 = 8
comptime KMATH_LOG10: UInt8 = 9
comptime KMATH_LOG2: UInt8 = 10
comptime KMATH_TAN: UInt8 = 11
comptime KMATH_ATAN: UInt8 = 12
comptime KMATH_ACOS: UInt8 = 13
comptime KMATH_COT: UInt8 = 14
comptime KMATH_DEGREES: UInt8 = 15
comptime KMATH_CBRT: UInt8 = 16
comptime KMATH_SINH: UInt8 = 17
comptime KMATH_COSH: UInt8 = 18
comptime KMATH_TANH: UInt8 = 19
# Inverse hyperbolics + gamma.
comptime KMATH_ACOSH: UInt8 = 20
comptime KMATH_ASINH: UInt8 = 21
comptime KMATH_ATANH: UInt8 = 22
comptime KMATH_GAMMA: UInt8 = 23

# Binary math-fn op codes.
comptime KMATH2_ATAN2: UInt8 = 0
comptime KMATH2_POW: UInt8 = 1  # pow(base, exponent) — mirrors MATH2_POW

comptime _DEG_TO_RAD: Float64 = pi / 180.0
comptime _RAD_TO_DEG: Float64 = 180.0 / pi


# =============================================================================
# ⚠ THE TRANSCENDENTALS GO STRAIGHT TO libm, DELIBERATELY.
# =============================================================================
#
# `tan` / `atan` / `acos` / `exp` / `log10` / `cbrt` / `sinh` / `cosh` / `tanh`
# are called through `external_call` rather than reconstructed from the
# identities the already-imported `std.math` names would allow
# (`tan = sin/cos`, `atan = atan2(x, 1)`, `log10 = log(x)/ln(10)`,
# `sinh = (e^x - e^-x)/2`, ...).
#
# ★ THE REASON IS THE ORACLE, NOT CONVENIENCE. These columns are compared
# VALUE-BY-VALUE against DuckDB v1.5.3, and DuckDB calls libm for every one of
# them. Going to the SAME libm makes the answer BIT-IDENTICAL; an identity
# reconstruction is correct to within an ulp or two and would put a
# last-bit disagreement into a parity cell — a red that is real (the values do
# differ) and that no amount of kernel work can close, because the difference
# is in the rounding of an intermediate that DuckDB never computes.
#
# `ceil` / `floor` / `sqrt` stay on `std.math`: those are EXACT IEEE-754
# operations with a single correctly-rounded answer, so there is no oracle to
# diverge from. `cot` and `degrees` are one exact arithmetic step on top of a
# libm result (`1/tan(x)`, `x * 180/pi`) and DuckDB computes them the same way.
#
# `Float64` is C `double` on every platform this builds for, so the ABI is the
# plain one-double-in-one-double-out libm signature. libm is linked into every
# binary here already (`std.math` itself needs it), so this adds no dependency.

#
# EACH CALL SPELLS ITS OWN SYMBOL NAME INLINE, rather than going through a
# one-line `libm1(name, x)` helper. `external_call`'s symbol is a COMPILE-TIME
# PARAMETER (`external_call["madvise", Int32](...)`), so a helper taking the
# name as a runtime argument
# does not compile at all -- and one taking it as a `[name: StaticString]`
# parameter buys nothing over the literal at eleven call sites.


# =============================================================================
# ★ `libm_pow` — THE ONE `pow` KERNEL. ⛔ NEVER `base ** exponent`.
# =============================================================================
#
# Mojo's `**` on a binary64 pair is NOT libm's `pow`. It is an approximate
# kernel (an exp2/log2 pair), and on Mojo 1.0.0 it is ~11 significant digits,
# not ~16. Against `external_call["pow"]` on the same values in the same
# process:
#
#     base  exp    `**`                  libm `pow`            rel err
#     2.0   0.5    1.4142135623734946    1.4142135623730951    2.8e-13
#     3.5   0.75   2.5588865598945456    2.5588865599815867    3.4e-11
#     7.25  0.9    5.9470858232220944    5.947085823295539     1.2e-11
#
# 3.4e-11 is ~196,000 ulps (1 ulp is 1.74e-16 there). DuckDB v1.5.3 calls libm
# and matches it to the last bit, so the operator form would put a REAL value
# divergence into every `pow`/`power` result — four orders of magnitude
# coarser than a 1e-12 relative tolerance.
#
# ⚠ THE OPERATOR IS NOT A FLOAT32 INTERMEDIATE AND NOT A PLATFORM DIFFERENCE.
# A float32 intermediate would be ~1.2e-7, four
# orders COARSER; and plain `exp(y * log(x))` in float64 reproduces libm to the
# last bit on two of these three rows, so the loss is in the kernel's own
# reduced-precision exp/log pair, not in the identity.
#
# This is the same rule as the transcendental block above, for the same reason:
# the oracle is DuckDB-on-libm, so go to the SAME libm. `pow` carries every
# edge case the callers rely on — a negative base with an INTEGER-valued
# exponent is exact (`pow(-0.5, 2) = 0.25`, which is what `pow(corr, 2)` needs
# for a negative correlation), a negative base with a fractional exponent is
# NaN, `pow(x, 0)` is 1.0 — all matching DuckDB.
#
# ⚠ IT IS A NAMED FUNCTION AND NOT AN INLINE `external_call` AT EACH SITE,
# unlike the eleven unary libm calls above, because `pow` has FOUR evaluators
# (this one, plus the column walker and two row walkers in
# `komira_eval/expression_executor.mojo`) and they must not be able to drift.
# `y ** x` reads exactly like a call to libm `pow`, so all four could be wrong
# in the same way; `libm_pow(y, x)` cannot.
# =============================================================================
@always_inline
def libm_pow(base: Float64, exponent: Float64) -> Float64:
    """`base ** exponent` through libm's correctly-rounded `pow`."""
    return external_call["pow", Float64](base, exponent)



# =============================================================================
# ⛔ THE DOMAIN GUARD — SIXTEEN POINTS DuckDB v1.5.3 REFUSES AND libm ANSWERS
# =============================================================================
#
# Eleven points on the positive side, five more on the NEGATIVE side of the
# same three intervals, and the `sqrt(NEGATIVE)` family. Every expectation
# below is DuckDB v1.5.3's answer, checked against the engine by oracle
# tests.
#
# ⛔ WHY A WRONG ANSWER HERE IS WORSE THAN A ULP. `-inf` and `nan` PROPAGATE. A
# `SUM` over a column holding one is `nan` for every row and a `MIN` is `-inf`,
# so the failure arrives at the far end of the query with nothing left to
# attribute it to. A refusal is a published NO the caller reads at the call
# site. libm answers every one of these; this guard is what asks whether SQL
# should.
#
# ⚠ THE MESSAGES ARE DuckDB v1.5.3's OWN SENTENCES AND THE TWO LOGARITHM ONES
# DIFFER ON PURPOSE. v1.5.3 says "cannot take logarithm of zero" AT zero and
# "...of a negative number" BELOW it; ONE message for both points is a
# DIFFERENT defect from no guard, and the oracle tests carry both rows
# exactly so they can be told apart.
#
# ⚠ THE INTERVAL TESTS ARE TWO-SIDED. `asin` / `acos` / `atanh` are undefined
# BOTH above +1 and below -1, and the one-sided `x > 1` shape a reader writes
# first closes the five positive-side points and leaves the five negative-side
# ones open.
#
# ⚠ NaN IN, NaN OUT — NOT A REFUSAL, AND NOT AN ACCIDENT. Every comparison
# below is FALSE for a NaN argument, so `asin(nan)` falls through to libm and
# returns NaN, which is what DuckDB does and what the oracle pins. Do not
# "tighten" it into an `isnan` refusal.
#
# ⚠ `-0.0` IS NOT NEGATIVE. `x < 0.0` is FALSE for `-0.0`, so
# `sqrt(-0.0) = -0.0` still answers — which the oracle pins as a VALUE. A
# `signbit` test would refuse it and be wrong.
#
# ⚠ THE BOUNDARY IS `|x| > 1`, NOT `>= 1`. `asin(1)` is pi/2 and `atanh(1)` is
# `+inf` in v1.5.3 — both ANSWER. Only strictly outside the closed interval
# refuses.
#
# ⛔⛔ WHERE IT IS CALLED FROM IS THE OTHER HALF OF THE DESIGN, AND IT IS NOT
# `_apply_unary`. Two reasons, both load-bearing:
#
#   1. **NULLS.** `eval_math_unary` walks EVERY slot including null ones, whose
#      payload bytes are arbitrary (typically 0.0 off parquet). Guarding inside
#      `_apply_unary` would turn `ln(NULL)` into "cannot take logarithm of
#      zero" — on whichever rows a writer happened to leave zeroed. The guard
#      belongs on the loop that can see the validity bitmap, which is this
#      file's `eval_math_unary`.
#   2. **LAYER.** `_apply_unary` is also reached from
#      `ExpressionExecutor`'s generic `EXPR_MATH_UNARY_F64` arm, whose sibling
#      arms (EXPR_SQRT_F64 and the other four legacy tags) have a DOCUMENTED
#      IEEE-754 contract — "sqrt(-x) -> NaN (NOT a raise)", pinned by
#      `komira_eval`'s tests. A guard inside
#      `_apply_unary` would give one of those six arms SQL semantics and leave
#      five with IEEE semantics, which is a worse inconsistency than the one
#      it closes.
#
# ⚠⚠ ⇒ THE RESIDUAL IS REAL, IT IS DATA-DEPENDENT, AND IT IS STATED HERE
# RATHER THAN HIDDEN. `compute_project` routes a strict-null-propagating expr
# TWO ways, and only one of them reaches this file:
#
#   input batch HOLDS a null   -> `_eval_column_expr` -> `eval_math_unary`
#                                 -> GUARDED (the `nz_saw_null` overlay arm)
#   input batch holds none     -> the per-DType `ExpressionExecutor` walker
#                                 -> UNGUARDED: `ln(0.0)` answers `-inf` there
#
# So on the untyped project path the same query refuses or answers depending on
# whether some OTHER row of the batch happened to be NULL. Closing that needs
# the guard at the executor layer, and it cannot simply be moved into
# `_apply_unary`: `eval_to_list_f64_from_view` does not carry a null mask (which
# is precisely why the `nz_saw_null` overlay exists), and the five legacy
# EXPR_*_F64 tags beside the generic one have a DOCUMENTED IEEE-754 contract
# pinned by `komira_eval`'s tests. The SQL frontend reaches the
# `eval_math_unary` side.
# =============================================================================


@always_inline
def check_unary_domain(op: UInt8, x: Float64) raises:
    """Raise DuckDB v1.5.3's own sentence for an argument outside `op`'s domain.

    A no-op for every op with no domain restriction and for every in-domain
    value. See the block comment above for why each bound has the shape it has
    and for why this is NOT called from `_apply_unary`.
    """
    if op == KMATH_LN or op == KMATH_LOG10 or op == KMATH_LOG2:
        if x == 0.0:
            raise Error("Out of Range Error: cannot take logarithm of zero")
        if x < 0.0:
            raise Error(
                "Out of Range Error: cannot take logarithm of a negative number"
            )
        return
    if op == KMATH_SQRT:
        if x < 0.0:
            raise Error(
                "Out of Range Error: cannot take square root of a negative"
                " number"
            )
        return
    if op == KMATH_ASIN:
        if x < -1.0 or x > 1.0:
            raise Error("Invalid Input Error: ASIN is undefined outside [-1,1]")
        return
    if op == KMATH_ACOS:
        if x < -1.0 or x > 1.0:
            raise Error("Invalid Input Error: ACOS is undefined outside [-1,1]")
        return
    if op == KMATH_ATANH:
        if x < -1.0 or x > 1.0:
            raise Error(
                "Invalid Input Error: ATANH is undefined outside [-1,1]"
            )
        return
    if op == KMATH_COT:
        if x == 0.0:
            raise Error(
                "Out of Range Error: input value 0.000000 is out of range for"
                " numeric function cotangent"
            )
        return
    if op == KMATH_GAMMA:
        if x == 0.0:
            raise Error("Out of Range Error: cannot take gamma of zero")
        return


@always_inline
def _apply_unary(op: UInt8, x: Float64) -> Float64:
    """Apply a single unary math op to one Float64 value.

    ⚠ THE `else` IS `KMATH_RADIANS`, NOT A DEFAULT. An op this ladder does not
    name would be silently computed as `x * pi/180`. The ladder is exhaustive
    over the `KMATH_*` space by construction, and that space mirrors the
    `MATH_*` space in `plan/expr.mojo` op for op, so a new op must not reach
    here without a line of its own.
    """
    if op == KMATH_SIN:
        return sin(x)
    elif op == KMATH_COS:
        return cos(x)
    elif op == KMATH_SQRT:
        return sqrt(x)
    elif op == KMATH_ASIN:
        return asin(x)
    elif op == KMATH_CEIL:
        return ceil(x)
    elif op == KMATH_FLOOR:
        return floor(x)
    elif op == KMATH_LN:
        return external_call["log", Float64](x)
    elif op == KMATH_EXP:
        return external_call["exp", Float64](x)
    elif op == KMATH_LOG10:
        return external_call["log10", Float64](x)
    elif op == KMATH_LOG2:
        return external_call["log2", Float64](x)
    elif op == KMATH_TAN:
        return external_call["tan", Float64](x)
    elif op == KMATH_ATAN:
        return external_call["atan", Float64](x)
    elif op == KMATH_ACOS:
        return external_call["acos", Float64](x)
    elif op == KMATH_COT:
        # `cot(x) = 1/tan(x)`. DuckDB v1.5.3 computes it the same way, so the
        # single division is the whole difference from `tan` and is exact.
        return 1.0 / external_call["tan", Float64](x)
    elif op == KMATH_DEGREES:
        return x * _RAD_TO_DEG
    elif op == KMATH_CBRT:
        # ⚠ NOT `x ** (1/3)`: the power form is NaN for every negative `x`,
        # while `cbrt(-8) = -2` in both libm and DuckDB.
        return external_call["cbrt", Float64](x)
    elif op == KMATH_SINH:
        return external_call["sinh", Float64](x)
    elif op == KMATH_COSH:
        return external_call["cosh", Float64](x)
    elif op == KMATH_TANH:
        return external_call["tanh", Float64](x)
    elif op == KMATH_ACOSH:
        return external_call["acosh", Float64](x)
    elif op == KMATH_ASINH:
        return external_call["asinh", Float64](x)
    elif op == KMATH_ATANH:
        return external_call["atanh", Float64](x)
    elif op == KMATH_GAMMA:
        # ⚠ THE libm NAME IS `tgamma`, NOT `gamma`, AND THE WRONG SPELLING
        # FAILS DIFFERENTLY ON THE TWO PLATFORMS THIS BUILDS FOR. `gamma` is a
        # HISTORICAL 4.3BSD ALIAS FOR `lgamma` — the LOG of the gamma function
        # — and glibc still exports it, so on LINUX
        # `external_call["gamma"]` would link, run, and answer 3.178 where
        # DuckDB answers 24.0: a plausible positive Float64 for every positive
        # input, with no error anywhere. On macOS arm64 the symbol is not
        # exported at all (checked via dlsym), so the same typo is
        # a LINK failure here and a SILENT WRONG ANSWER there. `tgamma` is the
        # true gamma function and is the only correct spelling on both.
        return external_call["tgamma", Float64](x)
    else:  # KMATH_RADIANS
        return x * _DEG_TO_RAD


def eval_math_unary(
    op: UInt8, arr: PrimitiveArray[DType.float64]
) raises -> PrimitiveArray[DType.float64]:
    """Element-wise unary math over the whole KMATH_* space, validity-preserving
    and DOMAIN-CHECKED.

    `op` is one of KMATH_* (mirrors MATH_* on the IR side).  Input/output
    are FLOAT64.  The input null mask is carried onto the output.

    ⛔ RAISES on an argument SQL has no answer for — `ln(0)`, `asin(2)`,
    `sqrt(-1)` and the rest — with DuckDB v1.5.3's own sentence. This is the
    ONE call site of `check_unary_domain`; see the block comment on that
    function for the sixteen graded points, for why NULL rows are exempt, and
    for why the check is not inside `_apply_unary`.
    """
    var result = PrimitiveArray[DType.float64].allocate(arr.length)
    # Origin-tied view chain — locals pin both arrays alive
    # across the loop; mirrors int64_to_float64 in compiler_helpers.
    var src_view = arr.view_ro()
    var src_ptr = src_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    var dst_view = result.view_mut()
    var dst_ptr = dst_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    for i in range(arr.length):
        # ⛔ A NULL SLOT MAY NOT REACH THE DOMAIN GUARD. Its payload bytes are
        # arbitrary — typically 0.0 off parquet — so guarding them would turn
        # `ln(NULL)` into "cannot take logarithm of zero" on whichever rows a
        # writer happened to leave zeroed. `clone_array_validity` below carries
        # the null mask; this branch keeps the GUARD off those rows. The kernel
        # itself is harmless on garbage, so the stored value is still computed
        # — only the SQL question "should this refuse?" is skipped, because for
        # a NULL row SQL's answer is NULL and not an error.
        var x = Float64(src_ptr.load[width=1](i))
        if not arr.is_null(i):
            check_unary_domain(op, x)
        dst_ptr.store[width=1](i, Scalar[DType.float64](_apply_unary(op, x)))
    clone_array_validity[DType.float64, DType.float64](arr, result)
    return result^


@always_inline
def _apply_binary(op: UInt8, y: Float64, x: Float64) -> Float64:
    """Apply a single binary math op to one (y, x) pair. `y` is the left
    child (atan2's numerator / pow's base); `x` is the right child (atan2's
    denominator / pow's exponent)."""
    if op == KMATH2_POW:
        # ⛔ NOT `y ** x` — see `libm_pow` above for the measured 196,000-ulp
        # reason. `y` is the base, `x` the exponent.
        return libm_pow(y, x)
    # KMATH2_ATAN2.
    return atan2(y, x)


def eval_math_binary(
    op: UInt8,
    left: PrimitiveArray[DType.float64],
    right: PrimitiveArray[DType.float64],
) raises -> PrimitiveArray[DType.float64]:
    """Element-wise binary math (atan2), validity-preserving.

    `op` is KMATH2_ATAN2.  Both inputs are FLOAT64; output is FLOAT64.  A
    row is null in the output if EITHER input row is null (Kleene-style
    null propagation — the standard arithmetic-binary semantics).
    `left` / `right` must have the same `length`.
    """
    var n = left.length
    var result = PrimitiveArray[DType.float64].allocate(n)
    var l_view = left.view_ro()
    var l_ptr = l_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    var r_view = right.view_ro()
    var r_ptr = r_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    var d_view = result.view_mut()
    var d_ptr = d_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    for i in range(n):
        var yv = Float64(l_ptr.load[width=1](i))
        var xv = Float64(r_ptr.load[width=1](i))
        d_ptr.store[width=1](i, Scalar[DType.float64](_apply_binary(op, yv, xv)))
    # Null propagation: a row is valid iff BOTH operands are valid. We
    # compute the AND of the two validity bitmaps by walking per-bit. If
    # neither input has a validity bitmap, the output is all-valid.
    _propagate_binary_validity(left, right, result)
    return result^


def _propagate_binary_validity(
    left: PrimitiveArray[DType.float64],
    right: PrimitiveArray[DType.float64],
    mut dst: PrimitiveArray[DType.float64],
) raises:
    """Set dst's validity = left.validity AND right.validity (Kleene null).

    If exactly one side has a validity bitmap, the output inherits it
    (the all-valid side contributes no nulls). If neither side has one,
    the output stays all-valid (no-op).
    """
    var has_l = Bool(left.validity)
    var has_r = Bool(right.validity)
    if not has_l and not has_r:
        return
    if has_l and not has_r:
        clone_array_validity[DType.float64, DType.float64](left, dst)
        return
    if has_r and not has_l:
        clone_array_validity[DType.float64, DType.float64](right, dst)
        return
    # Both sides nullable — AND the masks (a row is valid iff both inputs
    # are valid). `Bitmap.and_` returns a fresh Bitmap[HeapRegion].
    #
    # ★ OFFSET-AWARE. `Bitmap.and_` walks both inputs FROM BIT 0 over their
    # WHOLE length, so on a sliced operand it would merge the wrong bits and
    # return more of them than the result has rows — inventing nulls and losing
    # them (covered by `test_arith_cast_offset_validity`). Rebase each operand's
    # WINDOW first (`copy_slice_from` is the same primitive the one-sided arms
    # use via `clone_array_validity`), then AND.
    #
    # ⚠ `a.and_(b)` is the same offset hazard as `copy_slice_from(bm, 0,
    # bm.length)` in a different spelling; a search for one does not find the
    # other.
    var lw = Bitmap.copy_slice_from(left.validity.value(), left.offset, dst.length)
    var rw = Bitmap.copy_slice_from(right.validity.value(), right.offset, dst.length)
    var anded = lw.and_(rw)
    dst.null_count = anded.null_count()
    dst.validity = anded^
