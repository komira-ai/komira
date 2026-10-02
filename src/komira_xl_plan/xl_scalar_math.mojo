# =============================================================================
# xl_scalar_math.mojo — ★ THE EXCEL NUMERIC SCALAR KERNELS, AND THEY ARE HERE
#                         SO THAT A TEST CAN RUN THEM.
# =============================================================================
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins, no `unsafe_from_address`.
# =============================================================================

from std.ffi import external_call
from std.math import floor, ceil, sqrt as _sqrt

from komira_core.plan.excel_error_code import XL_ERR_DIV0, XL_ERR_NUM

from .formula_value import FormulaValue


# =============================================================================
# Shared argument handling — the DOMINANT error algebra, once.
# =============================================================================
def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` coerced to a NUMBER, or the error that stops the call.

    ⚠ ERRORS ARE DATA HERE, NOT EXCEPTIONS. An error argument returns ITSELF —
    the leftmost-error dominance of `ERRH_PROPAGATE_DOMINANT` — and a
    non-numeric text returns `#VALUE!`. Every kernel below reads its arguments
    through this one function so the dominance order cannot differ between
    them."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _pow10(digits: Int) -> Float64:
    """`10 ** digits` for the ROUND family's digit argument.

    ⚠ A LOOP AND NOT `pow(10.0, d)`, because the rounding family multiplies by
    this value and then divides by it: an inexact power of ten introduces a
    scaling error into the very operation whose whole job is exactness at a
    decimal place. Repeated multiplication of 10.0 is exact for |d| <= 22 in
    binary64 (10^22 is the largest exactly representable power of ten), which
    covers every digit count Excel accepts (-15..15)."""
    var f = Float64(1.0)
    var n = digits if digits >= 0 else -digits
    for _ in range(n):
        f = f * 10.0
    if digits < 0:
        return 1.0 / f
    return f


def _digits_arg(imm args: List[FormulaValue]) -> FormulaValue:
    """The optional `num_digits` argument (default 0), as a NUMBER or an
    error."""
    if len(args) < 2:
        return FormulaValue.number(0.0)
    return _num(args, 1)


# =============================================================================
# ROUND / ROUNDUP / ROUNDDOWN
# =============================================================================
def _half_away_from_zero(scaled: Float64) -> Float64:
    """★ THE TIE RULE, ONE IMPLEMENTATION, SHARED BY `ROUND` AND `MROUND`.

    ⛔⛔ AND THE "OBVIOUS FIX" TO IT IS A **REGRESSION**, MEASURED 2026-09-14.
    `floor(x + 0.5)` is the textbook bug: it rounds `0.49999999999999994` — the
    largest double STRICTLY BELOW one half — up to 1, because the SUM carries to
    exactly 1.0 before `floor` ever runs. The textbook fix is to test the
    FRACTION (`x - floor(x) >= 0.5`), which answers 0.

    ⛔ EXCEL ANSWERS **1**. Excel does not round the binary double at all — it
    rounds the 15-SIGNIFICANT-DECIMAL-DIGIT representation it displays, and that
    representation of `0.49999999999999994` is exactly `0.5`. So the "correct"
    fraction test moves this kernel AWAY from Excel at the only inputs where the
    two spellings differ at all.

    ⚠ AND THEY DIFFER **NOWHERE ELSE**: over 400,000 random `(x, digits)` pairs
    with x in [-1000, 1000] and digits in [-3, 6], the two spellings returned
    IDENTICAL values on every single one. The disagreement is confined to the
    adversarial "largest double below a half" family, which is precisely the
    family where Excel's decimal reading says 0.5.
    """
    if scaled >= 0.0:
        return floor(scaled + 0.5)
    return ceil(scaled - 0.5)


def xl_round(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ROUND(number, num_digits)` — HALF AWAY FROM ZERO.

    ⛔ NOT `round()`. Mojo's (and IEEE's) `round` is half-to-EVEN, so
    `ROUND(2.5, 0)` would answer 2 where Excel answers 3, and `ROUND(0.5,0)`
    would answer 0 where Excel answers 1. Half-away-from-zero is the whole
    reason this kernel is spelled out.

    ⚠ DIVERGENCE FROM EXCEL, AND THE INPUT IS **1.005**, NOT 2.675. This
    rounds the BINARY double; Excel rounds its 15-significant-decimal-digit
    representation. MEASURED 2026-09-14: `ROUND(2.675, 2)` is **2.68 here and
    2.68 in Excel** — they AGREE, because `2.675 * 100` rounds UP to exactly
    267.5 in binary64 — so the example this docstring cited for months was one
    where the engine is RIGHT, and the oracle cell carrying it was annotated
    "EXPECTED RED" while passing. `ROUND(1.005, 2)` is 1 here and 1.01 in
    Excel: `1.005 * 100` is 100.49999999999999, below the tie. No epsilon fixes
    that without breaking a value genuinely just under a half.

    ⚠ THE TIE ITSELF IS IN `_half_away_from_zero`, SHARED WITH `MROUND`, and
    its docstring records why the textbook `floor(x+0.5)` fix was MEASURED AND
    REJECTED rather than merely not attempted.
    """
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d = _digits_arg(args)
    if d.is_error():
        return d^
    var f = _pow10(Int(d.num))
    var scaled = x.num * f
    return FormulaValue.number(_half_away_from_zero(scaled) / f)


def xl_roundup(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ROUNDUP(number, num_digits)` — AWAY FROM ZERO. `ROUNDUP(-1.1, 0)` is
    -2, not -1: "up" in Excel means "in magnitude", which is the opposite of
    `ceil` on the negative side."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d = _digits_arg(args)
    if d.is_error():
        return d^
    var f = _pow10(Int(d.num))
    var scaled = x.num * f
    var r = ceil(scaled) if scaled >= 0.0 else floor(scaled)
    return FormulaValue.number(r / f)


def xl_rounddown(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ROUNDDOWN(number, num_digits)` — TOWARD ZERO. `ROUNDDOWN(-1.9, 0)` is
    -1, which is `ceil` on the negative side."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d = _digits_arg(args)
    if d.is_error():
        return d^
    var f = _pow10(Int(d.num))
    var scaled = x.num * f
    var r = floor(scaled) if scaled >= 0.0 else ceil(scaled)
    return FormulaValue.number(r / f)


# =============================================================================
# ABS / INT / SIGN
# =============================================================================
def xl_abs(imm args: List[FormulaValue]) raises -> FormulaValue:
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(-x.num if x.num < 0.0 else x.num)


def xl_int(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`INT(number)` — ⛔ **FLOOR, NOT TRUNCATION**. `INT(-3.5)` is -4 in Excel;
    a C-style cast to integer gives -3. This is the single most-confused Excel
    numeric function and the divergence is invisible until a negative value
    appears in the data. `ROUNDDOWN(x, 0)` is the truncating one."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(floor(x.num))


def xl_sign(imm args: List[FormulaValue]) raises -> FormulaValue:
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num > 0.0:
        return FormulaValue.number(1.0)
    if x.num < 0.0:
        return FormulaValue.number(-1.0)
    return FormulaValue.number(0.0)


# =============================================================================
# MOD / POWER / SQRT
# =============================================================================
def xl_mod(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`MOD(number, divisor)` — ⛔ **THE RESULT TAKES THE DIVISOR'S SIGN**, like
    Python's `%` and UNLIKE C's `fmod` (which takes the dividend's).
    `MOD(-3, 2)` is 1 in Excel and -1 in C. Excel documents it as
    `n - d*INT(n/d)`, which is what this computes — and `INT` there is FLOOR,
    which is the whole mechanism.

    A zero divisor is `#DIV/0!`."""
    var n = _num(args, 0)
    if n.is_error():
        return n^
    var d = _num(args, 1)
    if d.is_error():
        return d^
    if d.num == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number(n.num - d.num * floor(n.num / d.num))


def xl_power(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`POWER(number, power)` — the function form of `^`.

    The two Excel error cases, both real and both easy to miss:
      * `POWER(0, negative)` is `#DIV/0!` (a division by zero in disguise);
      * a NEGATIVE base with a NON-INTEGER exponent is `#NUM!` — the real
        answer is complex, and a binary64 power returns NaN, which would travel
        as a number and poison every arithmetic node above it.

    ⛔ THE CALL IS libm `pow`, NOT MOJO'S `**`. `**` on a binary64 pair is an
    approximate exp2/log2 kernel: measured 2026-09-09 on Mojo 1.0.0,
    `3.5 ** 0.75` is 2.5588865598945456 against libm's 2.5588865599815867 — a
    relative error of 3.4e-11, or ~196,000 ulps, so `POWER` was returning ~11
    correct significant digits instead of ~16. The canonical statement of this,
    with the full measurement, is `libm_pow` in
    `komira_core/eval/scalar_math.mojo`; it is spelled inline here rather than
    imported so the formula layer does not take a dependency on the Arrow
    column kernels. Both error cases above are decided BEFORE the call, so
    libm's own NaN/inf behaviour is never reached through them."""
    var b = _num(args, 0)
    if b.is_error():
        return b^
    var e = _num(args, 1)
    if e.is_error():
        return e^
    if b.num == 0.0 and e.num < 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    if b.num < 0.0 and e.num != floor(e.num):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(external_call["pow", Float64](b.num, e.num))


def xl_sqrt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SQRT(number)`. A negative argument is `#NUM!` — NOT NaN, which would
    travel as a number through every comparison silently."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(_sqrt(x.num))


# =============================================================================
# CEILING / FLOOR — the two-argument, significance forms
# =============================================================================
def _significance_guard(x: Float64, sig: Float64) -> Optional[FormulaValue]:
    """The shared refusal for `CEILING` / `FLOOR`: a zero significance is 0, and
    a POSITIVE number with a NEGATIVE significance is `#NUM!`.

    ⚠ THE SIX SIGN CASES ARE THE REASON THESE ARE NOT ONE-LINERS. Excel rounds
    AWAY from zero when number and significance share a sign and TOWARD zero
    when they do not, and refuses the one combination that has no answer. The
    arithmetic `f(number/significance) * significance` reproduces all five
    survivors exactly; this function removes the sixth."""
    if sig == 0.0:
        return Optional[FormulaValue](FormulaValue.number(0.0))
    if x > 0.0 and sig < 0.0:
        return Optional[FormulaValue](FormulaValue.error(XL_ERR_NUM))
    return Optional[FormulaValue]()


def xl_ceiling(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CEILING(number, significance)` — the nearest multiple of `significance`
    in the AWAY-FROM-ZERO direction when the signs agree.

    ⚠ SIGNIFICANCE IS REQUIRED, WHICH IS EXCEL'S ARITY AND NOT A CHOICE. The
    permissive one-argument form is `CEILING.MATH`; accepting it here would
    quietly build an answer for a formula Excel itself rejects with `#N/A`, and
    a surface that is MORE permissive than the thing it emulates cannot be
    checked against it."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var s = _num(args, 1)
    if s.is_error():
        return s^
    var guard = _significance_guard(x.num, s.num)
    if guard:
        return guard.value().copy()
    return FormulaValue.number(ceil(x.num / s.num) * s.num)


def xl_floor(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FLOOR(number, significance)` — the nearest multiple of `significance` in
    the TOWARD-ZERO direction when the signs agree. Same six-case table as
    `CEILING`; see `_significance_guard`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var s = _num(args, 1)
    if s.is_error():
        return s^
    var guard = _significance_guard(x.num, s.num)
    if guard:
        return guard.value().copy()
    return FormulaValue.number(floor(x.num / s.num) * s.num)


# =============================================================================
# PRODUCT
# =============================================================================
def xl_product(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PRODUCT(number1, ...)` — the variadic product.

    ⚠ BLANKS ARE SKIPPED, NOT TREATED AS ZERO. A blank coerces to 0 in
    arithmetic, so a `coerce_number` over every argument would make any product
    containing an empty cell 0 — which is the opposite of what Excel does and
    would be a confidently wrong number.

    ⚠ AND A PRODUCT OF NOTHING IS 0, NOT 1. That is Excel's answer
    (`PRODUCT(<all blank>)` is 0) rather than the mathematical identity, and it
    is stated here because 1 is what an accumulator initialised to the identity
    returns."""
    var acc = Float64(1.0)
    var seen = 0
    for i in range(len(args)):
        if args[i].is_error():
            return args[i].copy()
        if args[i].is_blank():
            continue
        var v = args[i].coerce_number()
        if v.is_error():
            return v^
        acc = acc * v.num
        seen += 1
    if seen == 0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(acc)
