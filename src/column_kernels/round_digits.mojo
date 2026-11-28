# =============================================================================
# round_digits — `EXPR_ROUND_DIGITS` kernels: round / trunc / half-even to a
# digit count
# =============================================================================
#
# One kernel family per element type, each taking the rule (`RDG_*`) and the
# digit count and returning the input's own type (DECIMAL128 with the scale the
# type rule in `plan_expr.round_digits_type` names):
#
#   * `eval_round_digits_float[dt]`   FLOAT64 / FLOAT32
#   * `eval_round_digits_int[dt]`     INT8 / INT16 / INT32 / INT64
#   * `eval_round_digits_decimal`     DECIMAL128 (i128 values)
#
# The rules are the ones the `RDG_*` docstrings in `plan_expr/expr.mojo` state.
# `RDG_ROUND` and `RDG_TRUNC` follow DuckDB (libm `round` / `trunc` / `pow`
# through `external_call`, as `numeric_unary` does); `RDG_ROUND_HALF_EVEN`
# follows numpy's `np.round` (libm `rint` / `rintf`). NULL rows stay NULL; a
# NULL row's data is never read. The one exception is a DECIMAL whose digit
# count rounds every value away: every row, NULL included, is 0.

from std.ffi import external_call

from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from byte_buffer.heap_region import HeapRegion
from column_kernels.compiler_helpers import clone_array_validity
from plan_expr.expr import RDG_ROUND, RDG_TRUNC, RDG_ROUND_HALF_EVEN
from plan_expr.round_digits_type import (
    round_digits_decimal_all_zero,
    round_digits_decimal_scale,
)
from scalar_arithmetic.decimal_arith import I128, pow10_i128

# numpy's exact powers of ten, 10^0 .. 10^8.
comptime _NP_POW10_TABLE_LEN = 9


@always_inline
def _pow10_f64(n: Int) -> Float64:
    """libm `pow(10, n)`, the multiplier DuckDB's float rounding uses."""
    return external_call["pow", Float64](Float64(10.0), Float64(n))


def numpy_power_of_ten(n: Int) -> Float64:
    """numpy's `power_of_ten(n)`: the exact table below 9, else 1e9 times 10.0
    repeated `n - 9` times. The product saturates at infinity, so the loop
    stops there."""
    if n < _NP_POW10_TABLE_LEN:
        var r = Float64(1.0)
        for _ in range(n):
            r = r * Float64(10.0)
        return r
    var f = Float64(1e9)
    for _ in range(n - 9):
        f = f * Float64(10.0)
        if f - f != f - f:
            break
    return f


@always_inline
def _is_inf_or_nan(x: Float64) -> Bool:
    return x != x or x - x != x - x


def _sql_round_digits_f64(op: UInt8, x: Float64, digits: Int) -> Float64:
    """`round(x, digits)` / `trunc(x, digits)` over one DOUBLE, DuckDB's rule."""
    if digits >= 0:
        var m = _pow10_f64(digits)
        var r: Float64
        if op == RDG_TRUNC:
            r = external_call["trunc", Float64](x * m) / m
        else:
            r = external_call["round", Float64](x * m) / m
        if _is_inf_or_nan(r):
            return x
        return r
    var md = _pow10_f64(-digits)
    var rd: Float64
    if op == RDG_TRUNC:
        rd = external_call["trunc", Float64](x / md) * md
    else:
        rd = external_call["round", Float64](x / md) * md
    if _is_inf_or_nan(rd):
        # `trunc` returns the operand where `round` returns zero.
        if op == RDG_TRUNC:
            return x
        return Float64(0.0)
    return rd


def _half_even_f64(x: Float64, digits: Int) -> Float64:
    """numpy's `np.round(x, digits)` over one float64; no inf / nan fallback."""
    if digits == 0:
        return external_call["rint", Float64](x)
    if digits > 0:
        var f = numpy_power_of_ten(digits)
        return external_call["rint", Float64](x * f) / f
    var fd = numpy_power_of_ten(-digits)
    return external_call["rint", Float64](x / fd) * fd


def _half_even_f32(x: Float32, digits: Int) -> Float32:
    """numpy's `np.round(x, digits)` over one float32, computed in float32."""
    if digits == 0:
        return external_call["rintf", Float32](x)
    if digits > 0:
        var f = Float32(numpy_power_of_ten(digits))
        return external_call["rintf", Float32](x * f) / f
    var fd = Float32(numpy_power_of_ten(-digits))
    return external_call["rintf", Float32](x / fd) * fd


def round_digits_f64(op: UInt8, x: Float64, digits: Int) -> Float64:
    """One FLOAT64 value through rule `op` (`RDG_*`) at `digits` places."""
    if op == RDG_ROUND_HALF_EVEN:
        return _half_even_f64(x, digits)
    return _sql_round_digits_f64(op, x, digits)


def round_digits_i64(op: UInt8, v: Int64, digits: Int) -> Int64:
    """One INT64 value through rule `op` (`RDG_*`) at `digits` places, with the
    INT64 rules of `eval_round_digits_int`."""
    if digits >= 0:
        return v
    if op != RDG_ROUND_HALF_EVEN and digits <= -19:
        return 0
    var factor = Float64(1.0)
    if op == RDG_ROUND_HALF_EVEN:
        factor = numpy_power_of_ten(-digits)
    return _int_round_digits(op, v, digits, factor)


def eval_round_digits_float[
    dt: DType
](op: UInt8, digits: Int, arr: PrimitiveArray[dt]) raises -> PrimitiveArray[
    dt
]:
    """`round` / `trunc` / half-even to `digits` places over FLOAT64 or
    FLOAT32, same width out. `RDG_ROUND` and `RDG_TRUNC` compute a FLOAT32 in
    FLOAT64 and narrow, as DuckDB does; `RDG_ROUND_HALF_EVEN` computes a
    FLOAT32 in FLOAT32, as numpy does."""
    if op != RDG_ROUND and op != RDG_TRUNC and op != RDG_ROUND_HALF_EVEN:
        raise Error(
            "eval_round_digits_float: unknown rounding rule "
            + String(Int(op))
        )
    var result = PrimitiveArray[dt].allocate(arr.length)
    for i in range(arr.length):
        if arr.is_null(i):
            result.set(i, Scalar[dt](0))
            continue
        var x = arr.get(i)
        if op == RDG_ROUND_HALF_EVEN:
            comptime if dt == DType.float32:
                result.set(i, Scalar[dt](_half_even_f32(Float32(x), digits)))
            else:
                result.set(i, Scalar[dt](_half_even_f64(Float64(x), digits)))
        else:
            result.set(
                i,
                Scalar[dt](_sql_round_digits_f64(op, Float64(x), digits)),
            )
    clone_array_validity[dt, dt](arr, result)
    return result^


def _trunc_div_i64(a: Int64, b: Int64) -> Int64:
    """`a / b` truncating toward zero, for `b > 0`."""
    var q = a // b
    if a < 0 and a % b != 0:
        q += 1
    return q


def _int_round_digits(
    op: UInt8, v: Int64, digits: Int, half_even_factor: Float64
) -> Int64:
    """One integer lane, widened to INT64, through `digits < 0`."""
    if op == RDG_ROUND_HALF_EVEN:
        var y = external_call["rint", Float64](
            Float64(v) / half_even_factor
        ) * half_even_factor
        # Out of INT64's range (or nan) the hardware conversion answers
        # INT64_MIN; the explicit test gives that answer a name.
        if y != y or y >= 9.223372036854775807e18 or y < -9.223372036854775808e18:
            return Int64.MIN
        return Int64(y)
    var p = Int64(1)
    for _ in range(-digits):
        p = p * 10
    if op == RDG_TRUNC:
        return _trunc_div_i64(v, p) * p
    var half = p // 2
    var t = v - half if v < 0 else v + half
    return _trunc_div_i64(t, p) * p


def eval_round_digits_int[
    dt: DType
](op: UInt8, digits: Int, arr: PrimitiveArray[dt]) raises -> PrimitiveArray[
    dt
]:
    """`round` / `trunc` / half-even to `digits` places over a signed integer
    width, same width out.

    `digits >= 0` returns the value. Below zero, `digits <= -19` is 0 for
    `RDG_ROUND` and `RDG_TRUNC`; otherwise the arithmetic is INT64 with
    wrapping overflow and the result wraps to the column's width, which is
    DuckDB's measured behaviour (`round(INT32_MAX, -1)` is `-2147483646`).
    `RDG_ROUND_HALF_EVEN` goes through FLOAT64 and truncates back, as numpy
    does."""
    if op != RDG_ROUND and op != RDG_TRUNC and op != RDG_ROUND_HALF_EVEN:
        raise Error(
            "eval_round_digits_int: unknown rounding rule " + String(Int(op))
        )
    var result = PrimitiveArray[dt].allocate(arr.length)
    var factor = Float64(1.0)
    if op == RDG_ROUND_HALF_EVEN and digits < 0:
        factor = numpy_power_of_ten(-digits)
    for i in range(arr.length):
        if arr.is_null(i):
            result.set(i, Scalar[dt](0))
            continue
        var v = arr.get(i)
        if digits >= 0:
            result.set(i, v)
        elif op != RDG_ROUND_HALF_EVEN and digits <= -19:
            result.set(i, Scalar[dt](0))
        else:
            var r = _int_round_digits(op, Int64(v), digits, factor)
            result.set(i, r.cast[dt]())
    clone_array_validity[dt, dt](arr, result)
    return result^


def _trunc_div_i128(a: I128, b: I128) -> I128:
    """`a / b` truncating toward zero, for `b > 0` and `|a|` below 2^126."""
    if a < 0:
        return -((-a) // b)
    return a // b


def eval_round_digits_decimal(
    op: UInt8, digits: Int, arr: Decimal128Array[HeapRegion]
) raises -> Decimal128Array[HeapRegion]:
    """`round` / `trunc` to `digits` places over DECIMAL128(w, s).

    The output has the input's precision and the scale
    `round_digits_decimal_scale` names. `digits >= s` copies the values; a
    digit count that rounds every value away (`-digits >= w - s`) answers 0
    for every row, NULL rows included. `RDG_ROUND_HALF_EVEN` has no DECIMAL
    rule and is refused by name."""
    if op != RDG_ROUND and op != RDG_TRUNC:
        raise Error(
            "round: the pandas-shaped round has no DECIMAL rule; CAST the"
            " column to DOUBLE first"
        )
    var w = arr.precision
    var s = arr.scale
    var out_scale = round_digits_decimal_scale(op, s, digits)
    var out = Decimal128Array.allocate(arr.length, w, out_scale)
    if round_digits_decimal_all_zero(op, w, s, digits):
        return out^
    if digits >= s:
        for i in range(arr.length):
            if arr.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, arr.get_i128(i))
        return out^
    var p = pow10_i128(s - digits)
    var half = p // 2
    var post = I128(1)
    if digits < 0:
        post = pow10_i128(-digits)
    for i in range(arr.length):
        if arr.is_null(i):
            out.set_null(i)
            continue
        var v = arr.get_i128(i)
        var t = v
        if op == RDG_ROUND:
            t = v - half if v < 0 else v + half
        out.set_i128(i, _trunc_div_i128(t, p) * post)
    return out^
