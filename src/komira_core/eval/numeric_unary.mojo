# =============================================================================
# numeric_unary — TYPE-PRESERVING element-wise numeric kernels
# =============================================================================
#
# These back the `UN_ABS` / `UN_SIGN` / `UN_TRUNC` /
# `UN_ROUND` members of `EXPR_UNARY_OP`.
#
# ⭐ WHY THIS IS A SEPARATE MODULE FROM `scalar_math.mojo` AND MUST STAY ONE.
# `scalar_math`'s header states its contract in its first ten lines: "Input is
# always FLOAT64 ... Output is always FLOAT64", and `eval_math_unary` takes and
# returns a `PrimitiveArray[DType.float64]` unconditionally. Every one of the
# functions here returns the INPUT's width instead. Putting a width-preserving
# kernel behind that module's name would make its stated contract false for
# some ops and true for others — the per-op/per-tag confusion that makes
# `EXPR_MATH_FN` the wrong home for these.
#
# CONTRACT HERE
#   * `eval_numeric_unary[dt]` — abs / trunc / round, `dt` in, `dt` out.
#   * `eval_sign[dt]`          — `dt` in, **INT8** out (DuckDB TINYINT).
#   * Validity is carried verbatim (null in -> null out).
#   * A NULL lane's DATA IS NEVER INSPECTED. That is not an optimisation: the
#     overflow guard below raises, and a garbage byte pattern under a null bit
#     must not be able to fail a query that DuckDB answers.
#
# ⚠ THE DuckDB SEMANTICS EACH KERNEL IS PINNED TO, ALL MEASURED ON v1.5.3 —
# never read off the docs page:
#   abs(-0.0)      -> +0.0   (proved with `1/abs(-0.0)` = `inf`, since
#                             `-0.0 == 0.0` makes it invisible to `=`)
#   abs(-inf)      -> inf ;  abs(nan) -> nan
#   abs(INT64_MIN) -> RAISES `Out of Range Error: Overflow on
#                     abs(-9223372036854775808)`
#   sign(-0.0)     -> 0  ;   sign(nan) -> 0   (so NOT `copysign`, and NOT
#                                              `x < 0 ? -1 : 1`)
#   round(0.5)=1  round(1.5)=2  round(2.5)=3  round(-2.5)=-3
#                  -> HALF AWAY FROM ZERO. NOT banker's rounding, NOT
#                     `nearbyint` (which is half-to-EVEN under the default
#                     rounding mode and would answer 2 for `round(2.5)`).
#   trunc(-0.5)    -> `-0`   (NEGATIVE ZERO IS PRESERVED, which is why this is
#                             libm `trunc` and not `Float64(Int(x))`)
#
# `round` and `trunc` go to libm by name for the same reason the
# transcendentals in `scalar_math` do — DuckDB calls the same functions. Unlike
# those, these two are EXACT operations with one correctly-rounded answer, so
# the mac-vs-glibc one-ulp hazard documented for `atanh` cannot arise here.
# =============================================================================

from std.ffi import external_call
from std.sys import size_of

from ..arrow.primitive_array import PrimitiveArray
from ..helpers.compiler_helpers import clone_array_validity

# Kernel-local op tags, mirroring the `UN_*` constants in
# `komira_core/plan/expr.mojo` so this leaf module has no dependency on the
# plan layer — the same arrangement `scalar_math`'s `KMATH_*` uses.
comptime KNUM_ABS: UInt8 = 0
comptime KNUM_SIGN: UInt8 = 1
comptime KNUM_TRUNC: UInt8 = 2
comptime KNUM_ROUND: UInt8 = 3
comptime KNUM_BIT_COUNT: UInt8 = 4


def numeric_unary_kernel_tag(unary_op: UInt8) raises -> UInt8:
    """Map a plan-layer `UN_*` value onto this module's `KNUM_*` tag.

    ⛔ DELIBERATELY RAISING ON ANYTHING ELSE, AND DELIBERATELY THE ONLY
    TRANSLATION POINT. The caller in `compiler_eval_column` has already
    dispatched on the op, so this can only be reached with one of the four;
    a fifth member arriving here is a member somebody wired without a kernel,
    and answering it with a default would be the bind-then-compute-something
    -else shape rather than the bind-then-RAISE one.

    ⚠ The `UN_*` values are NOT the `KNUM_*` values (UN_ABS is 4, KNUM_ABS is
    0) — this function is why that is safe. Do not "simplify" it to a
    subtraction: the day the plan space grows a non-contiguous member the
    subtraction is silently wrong and this ladder is loudly right.
    """
    # UN_ABS / UN_SIGN / UN_TRUNC / UN_ROUND — spelled as literals rather than
    # imported so the leaf-module property above holds. The pairing is pinned
    # by a test that imports BOTH spaces.
    if unary_op == 4:
        return KNUM_ABS
    if unary_op == 5:
        return KNUM_SIGN
    if unary_op == 6:
        return KNUM_TRUNC
    if unary_op == 7:
        return KNUM_ROUND
    if unary_op == 8:
        return KNUM_BIT_COUNT
    raise Error(
        "numeric_unary: UnaryOp " + String(Int(unary_op)) + " has no"
        " numeric kernel in this module. The five that do are UN_ABS(4),"
        " UN_SIGN(5), UN_TRUNC(6), UN_ROUND(7) and UN_BIT_COUNT(8)."
    )


@always_inline
def _apply_float(op: UInt8, x: Float64) -> Float64:
    """One FLOAT64 value through one type-preserving op.

    ⚠ THE `else` IS `KNUM_ROUND` AND THE CALLER GUARANTEES EXHAUSTIVENESS —
    `numeric_unary_kernel_tag` above is the only producer of a `KNUM_*` and it
    raises rather than defaulting. `KNUM_SIGN` never reaches here: its output
    is INT8, so it has its own kernel.
    """
    if op == KNUM_ABS:
        # ⚠ NOT `x < 0 ? -x : x`. `-0.0 < 0.0` is FALSE, so that form returns
        # `-0.0` where DuckDB returns `+0.0` — measured, and invisible to any
        # `=` comparison. libm `fabs` clears the sign bit unconditionally and
        # is also correct for `nan` (which no comparison-based form is).
        return external_call["fabs", Float64](x)
    elif op == KNUM_TRUNC:
        return external_call["trunc", Float64](x)
    else:  # KNUM_ROUND
        # C `round` is HALF AWAY FROM ZERO, which is what DuckDB answers.
        return external_call["round", Float64](x)


def eval_numeric_unary_float[
    dt: DType
](op: UInt8, arr: PrimitiveArray[dt]) raises -> PrimitiveArray[dt]:
    """abs / trunc / round over a FLOATING width, SAME width out.

    ⚠ THE ARITHMETIC IS DONE IN FLOAT64 AND NARROWED BACK, AND THAT IS EXACT
    FOR FLOAT32 — it is not a "close enough". `fabs` only clears a sign bit.
    `trunc`/`round` of a float32 below 2^23 give an integer under 2^23, which
    float32 represents exactly; at or above 2^23 a float32 is ALREADY an
    integer and both functions return it unchanged. So there is no float32
    input whose narrowed answer differs from a native `truncf`/`roundf`, and
    one code path is worth more than two that must agree.
    """
    var result = PrimitiveArray[dt].allocate(arr.length)
    for i in range(arr.length):
        if arr.is_null(i):
            result.set(i, Scalar[dt](0))
            continue
        var x = Float64(arr.get(i))
        result.set(i, Scalar[dt](_apply_float(op, x)))
    clone_array_validity[dt, dt](arr, result)
    return result^


def eval_numeric_unary_int[
    dt: DType
](op: UInt8, arr: PrimitiveArray[dt]) raises -> PrimitiveArray[dt]:
    """abs / trunc / round over a SIGNED INTEGER width, same width out.

    `trunc` and `round` of an integer are the IDENTITY — DuckDB declares
    `trunc(BIGINT) -> BIGINT` and `round(BIGINT) -> BIGINT` and both return the
    operand unchanged. They are still copied through this kernel rather than
    short-circuited at the eval arm, so that the output is a FRESH array with
    its own validity and the projection cannot alias its input.

    ⛔ THE OVERFLOW GUARD IS THE POINT OF THIS FUNCTION. `abs(INT64_MIN)` has
    no representable answer; two's complement negation WRAPS and returns
    INT64_MIN itself — a NEGATIVE absolute value, silently. DuckDB raises
    `Out of Range Error`, and so does this, with the offending value named.
    """
    var result = PrimitiveArray[dt].allocate(arr.length)
    var lo = Scalar[dt].MIN
    for i in range(arr.length):
        # A NULL lane's data is not an input to anything, including the guard.
        if arr.is_null(i):
            result.set(i, Scalar[dt](0))
            continue
        var v = arr.get(i)
        if op == KNUM_ABS:
            if v == lo:
                raise Error(
                    "Out of Range Error: Overflow on abs(" + String(v) + ")"
                )
            result.set(i, -v if v < 0 else v)
        else:
            # KNUM_TRUNC / KNUM_ROUND — the identity on an integer.
            result.set(i, v)
    clone_array_validity[dt, dt](arr, result)
    return result^


def eval_sign_float[
    dt: DType
](arr: PrimitiveArray[dt]) raises -> PrimitiveArray[DType.int8]:
    """`sign(<floating>)` -> INT8, validity-preserving.

    ⚠ `sign(-0.0)` IS `0` AND `sign(nan)` IS `0`, both measured on DuckDB
    v1.5.3. The comparison form below gets both right for free — `-0.0 < 0.0`
    and `-0.0 > 0.0` are BOTH false, and every comparison against `nan` is
    false — where `copysign(1.0, x)` would answer `-1` for `-0.0` and `1` for
    `nan`.
    """
    var result = PrimitiveArray[DType.int8].allocate(arr.length)
    for i in range(arr.length):
        if arr.is_null(i):
            result.set(i, Scalar[DType.int8](0))
            continue
        var x = Float64(arr.get(i))
        var s: Int8 = 0
        if x > 0.0:
            s = 1
        elif x < 0.0:
            s = -1
        result.set(i, Scalar[DType.int8](s))
    clone_array_validity[dt, DType.int8](arr, result)
    return result^


def eval_sign_int[
    dt: DType
](arr: PrimitiveArray[dt]) raises -> PrimitiveArray[DType.int8]:
    """`sign(<signed integer>)` -> INT8, validity-preserving. Never overflows —
    the output is one of -1 / 0 / 1 whatever the input width, which is exactly
    why DuckDB can declare TINYINT for all twelve of its overloads."""
    var result = PrimitiveArray[DType.int8].allocate(arr.length)
    for i in range(arr.length):
        if arr.is_null(i):
            result.set(i, Scalar[DType.int8](0))
            continue
        var v = arr.get(i)
        var s: Int8 = 0
        if v > 0:
            s = 1
        elif v < 0:
            s = -1
        result.set(i, Scalar[DType.int8](s))
    clone_array_validity[dt, DType.int8](arr, result)
    return result^


def eval_bit_count_int[
    dt: DType
](arr: PrimitiveArray[dt]) raises -> PrimitiveArray[DType.int8]:
    """`bit_count(<signed integer>)` -> INT8, validity-preserving.

    ⛔ THE POPCOUNT IS TAKEN OVER `dt`'s OWN WIDTH AND NOT OVER A WIDENED
    COPY. `bit_count((-1)::INTEGER)` is 32 on DuckDB v1.5.3 and
    `bit_count((-1)::BIGINT)` is 64 — the same VALUE, two different answers,
    because the operand's declared width IS an input to this function.
    Widening the lane to Int64 before counting would answer 64 for both: a
    plausible wrong answer on every negative operand and invisible on every
    non-negative one.

    ⚠ INT8 OUT IS NEVER A NARROWING HAZARD HERE: the largest width this
    engine carries is INT64, so the answer is at most 64 and TINYINT holds
    it. (DuckDB's own HUGEINT overload DOES overflow -- measured:
    `bit_count((-1)::HUGEINT)` = -128, not 128. This engine has no HUGEINT
    column, so the case cannot arise, and it is recorded here so that
    nobody "fixes" the output type if one ever lands.)
    """
    var result = PrimitiveArray[DType.int8].allocate(arr.length)
    for i in range(arr.length):
        # A NULL lane's data is not an input to anything. Same rule as the
        # kernels above: a garbage byte pattern under a clear validity bit
        # must not be able to change an answer.
        if arr.is_null(i):
            result.set(i, Scalar[DType.int8](0))
            continue
        var v = Int(arr.get(i))
        var n: Int8 = 0
        # ⚠ THE LOOP BOUND IS `dt`'s WIDTH IN BITS, AND THAT BOUND IS THE WHOLE
        # SEMANTIC. `v` is a 64-bit signed value, so a negative INT32 lane
        # carries 32 extra sign bits above bit 31; stopping at the operand's
        # own width is what makes `bit_count((-1)::INTEGER)` answer 32 and not
        # 64. `(v >> b) & 1` reads bit `b` of the two's-complement pattern for
        # every `b` below the width, whatever the sign.
        for b in range(size_of[Scalar[dt]]() * 8):
            if (v >> b) & 1 != 0:
                n += 1
        result.set(i, Scalar[DType.int8](n))
    clone_array_validity[dt, DType.int8](arr, result)
    return result^
