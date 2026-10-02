# =============================================================================
# xl_scalar_engineering.mojo — ★ THE ENGINEERING CATEGORY, WHICH WAS THE LAST
#                                WHOLE EXCEL CATEGORY AT ZERO.
# =============================================================================
#
# ============ ⛔⛔ THE SELECTION RULE, AND IT IS THE `WIDTH` ==================
#
#   HEX2DEC      ★ THE DISCRIMINATOR OF THE WHOLE BASE FAMILY. Excel's hex
#                door is **40-BIT** two's complement, not 32-bit:
#                `HEX2DEC("FFFFFFFFFF")` is -1 and `HEX2DEC("FFFFFFFF")` is
#                +4294967295. A 32-bit-minded kernel answers -1 for BOTH, and
#                every input a reader is likely to try by hand — 8 hex digits
#                or fewer, positive — agrees with it.
#   OCT2DEC      the same rule at **30** bits, BIN2DEC at **10**. Three
#                different widths for one family, which is why the width is a
#                parameter and never a literal in a kernel.
#   DEC2BIN      `places` is IGNORED when the number is negative — a negative
#                always renders full width. A kernel that honours `places`
#                there returns a SHORTER string, never an error.
#   BITLSHIFT    the domain is 2^48, not 2^32 and not 2^53, and the RESULT is
#                range-checked as well as the input: `BITLSHIFT(1,48)` is
#                `#NUM!` where `BITLSHIFT(1,47)` is 140737488355328.
#   GESTEP       `GESTEP(-4,-5)` is 1. A kernel comparing magnitudes answers 0
#                and agrees everywhere both arguments are non-negative.
#   ERF          the TWO-ARGUMENT form: `ERF(1,2)` is erf(2)-erf(1), and a
#                one-argument kernel that ignores the second answers erf(1),
#                which is a perfectly plausible number in [0,1].
#   IMARGUMENT   `atan2`, never `atan(b/a)`: `IMARGUMENT("-1")` is pi and the
#                quotient form answers 0 — the branch cut, exactly as the
#                brief warns.
#   COMPLEX      the coefficient 1 is OMITTED: `COMPLEX(3,1)` is `"3+i"`, not
#                `"3+1i"`, and `COMPLEX(0,-1)` is `"-i"`.
#   IM* parsing  a malformed complex number is **`#NUM!`**, not `#VALUE!` —
#                the error code most readers would guess wrong.
#
# ============ ⚠ WHERE THE SPECIAL FUNCTIONS COME FROM =======================
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins, no `unsafe_from_address`.
# =============================================================================

from std.ffi import external_call
from std.math import atan2, sqrt as _sqrt

from komira_core.plan.excel_error_code import (
    XL_ERR_DIV0,
    XL_ERR_NUM,
    XL_ERR_VALUE,
)

from .formula_value import FormulaValue
from .xl_special_fn import xs_erf, xs_erfc


# =============================================================================
# Shared argument handling — the DOMINANT error algebra, once.
# =============================================================================
def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` coerced to a NUMBER, or the error that stops the call.

    ⚠ ERRORS ARE DATA, NOT EXCEPTIONS — an error argument returns ITSELF (the
    leftmost-error dominance of `ERRH_PROPAGATE_DOMINANT`) and a non-numeric
    text returns `#VALUE!`."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _text(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` coerced to TEXT, or the error that stops the call."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_text()


comptime _INT_EXACT: Float64 = 9007199254740992.0
"""2^53 — above this every finite Float64 IS an integer, and `Int()` starts
running out of Int64."""


def _trunc(v: Float64) -> Float64:
    """Truncate TOWARD ZERO — what Excel's Engineering family does to a
    non-integral argument (`DEC2BIN(9.9)` is `1001`, `DEC2BIN(-9.9)` is the
    two's complement of -9).

    ⛔ NOT `floor`. `floor(-9.9)` is -10, which is a different number in the
    half of the domain a positive-only fixture never reaches.
    as `#NUM!` — which is the answer Excel gives."""
    if v >= _INT_EXACT or v <= -_INT_EXACT:
        return v
    if v < 0.0:
        return -Float64(Int(-v))
    return Float64(Int(v))


def _places_int(v: Float64) -> Int:
    """`places` as an `Int`, CLAMPED to a range the conversion can represent.

    ⛔ NOT A BARE `Int(v)`, for the reason `_trunc` states. Every value outside
    `[-1, _MAX_PLACES + 1]` is refused by `_render_base` anyway, so clamping to
    those two sentinels cannot change any answer this function can produce —
    it only removes the undefined conversion on the way to the refusal."""
    if v > Float64(_MAX_PLACES):
        return _MAX_PLACES + 1
    if v < 0.0:
        return -1
    return Int(_trunc(v))


# =============================================================================
# ★★ BASE CONVERSION — ONE PAIR OF PRIMITIVES, TWELVE NAMES.
#
# ⛔ THE WIDTH IS A PARAMETER AND NEVER A LITERAL IN A KERNEL. Excel's three
# bases carry THREE DIFFERENT two's-complement widths, all rendered in at most
# TEN characters:
#
#       base    chars   bits    range
#       bin       10      10    [-512, 511]
#       oct       10      30    [-536870912, 536870911]
#       hex       10      40    [-549755813888, 549755813887]
#
# A kernel that hard-codes one of them is right for that base and silently
# wrong for the other two, which is the defect this parameterisation exists to
# make unspellable.
# =============================================================================
comptime _BIN_BITS: Int = 10
comptime _OCT_BITS: Int = 30
comptime _HEX_BITS: Int = 40
comptime _MAX_PLACES: Int = 10
"""The widest rendering Excel's base family produces, and the cap on `places`.

⚠ THIS CAP IS THIS ENGINE'S CONTRACT AND IS **NOT** GRADED AGAINST EXCEL. Every
other rule in this section is quoted from Microsoft's published page; the
behaviour of `places` ABOVE ten characters is not stated there, so it is
refused here (`#NUM!`) rather than silently extending the format, and its cell
lives in the Mojo test rather than in the Excel-agreeing oracle."""


def _pow2(n: Int) -> Float64:
    """`2 ** n` by repeated multiplication — exact for every `n` this file
    uses (n <= 40), where a `pow` call is a libm round trip for a constant."""
    var f = Float64(1.0)
    for _ in range(n):
        f = f * 2.0
    return f


def _digit_char(d: Int) -> String:
    """One UPPER-CASE base-16 digit. Excel's `DEC2HEX` emits upper case."""
    var b = List[UInt8]()
    if d < 10:
        b.append(UInt8(48 + d))
    else:
        b.append(UInt8(55 + d))
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def _digit_val(c: UInt8) -> Int:
    """A digit's value, or -1. ⚠ LOWER CASE IS ACCEPTED ON INPUT — Excel's
    `HEX2DEC("ff")` is 255 — while output is always upper case."""
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 65 and c <= 70:
        return Int(c) - 55
    if c >= 97 and c <= 102:
        return Int(c) - 87
    return -1


@fieldwise_init
struct _Parsed(Copyable, Movable):
    """A parsed base-N literal: `ok` plus the SIGNED value it denotes."""

    var ok: Bool
    var value: Float64

    def copy(self) -> Self:
        return Self(self.ok, self.value)


def _parse_base(s: String, base: Int, bits: Int) -> _Parsed:
    """Read `s` as a base-`base` literal of at most ten digits, TWO'S
    COMPLEMENT at `bits`.

    ★ THE SIGN IS DECIDED BY THE VALUE, NOT BY THE DIGIT COUNT. A literal whose
    unsigned value has the top bit of `bits` set is negative — so
    `HEX2DEC("FFFFFFFFFF")` is -1 (40 bits, top bit set) and
    `HEX2DEC("FFFFFFFF")` is +4294967295 (the 40-bit top bit is CLEAR). ⛔ A
    "10 characters means signed" rule gets the first right and the second
    wrong, and 8-digit hex is what a reader tries by hand.

    An empty literal is 0 — Excel reads a blank cell that way."""
    var bs = s.as_bytes()
    if len(bs) == 0:
        return _Parsed(True, 0.0)
    if len(bs) > _MAX_PLACES:
        return _Parsed(False, 0.0)
    var acc = Float64(0.0)
    var b = Float64(base)
    for k in range(len(bs)):
        var d = _digit_val(bs[k])
        if d < 0 or d >= base:
            return _Parsed(False, 0.0)
        acc = acc * b + Float64(d)
    var span = _pow2(bits)
    if acc >= span * 0.5:
        return _Parsed(True, acc - span)
    return _Parsed(True, acc)


def _render_base(v: Float64, base: Int, bits: Int, places: Int,
                 has_places: Bool) -> FormulaValue:
    """Render the SIGNED integer `v` in base `base`, two's complement at
    `bits`, honouring `places`.

    ⛔⛔ `places` IS IGNORED WHEN `v` IS NEGATIVE, and that is Excel's rule
    rather than an oversight: a negative always renders at FULL width, so
    `DEC2BIN(-9,4)` is `1111110111` and not a four-character string. A kernel
    that honours `places` there returns a well-formed SHORTER string, never an
    error, which is the shape of wrong answer this family specialises in."""
    var u = v
    if u < 0.0:
        u = u + _pow2(bits)
    # Digits, least significant first.
    var digs = List[Int]()
    var b = Float64(base)
    if u == 0.0:
        digs.append(0)
    while u >= 1.0:
        var q = Float64(Int(u / b))
        var r = u - q * b
        digs.append(Int(r))
        u = q
    var out = String("")
    var n = len(digs)
    if v < 0.0:
        # Full width: the negative encoding fills every character.
        var want = _width_chars(base, bits)
        while n < want:
            digs.append(0)
            n += 1
    elif has_places:
        if places < 0 or places > _MAX_PLACES:
            return FormulaValue.error(XL_ERR_NUM)
        if places < n:
            return FormulaValue.error(XL_ERR_NUM)
        while n < places:
            digs.append(0)
            n += 1
    for k in range(n):
        out += _digit_char(digs[n - 1 - k])
    return FormulaValue.text_val(out)


def _width_chars(base: Int, bits: Int) -> Int:
    """How many characters the FULL-WIDTH (negative) encoding occupies. All
    three of Excel's bases render their negative range in exactly ten."""
    if base == 2:
        return bits
    if base == 8:
        return bits // 3
    return bits // 4


def _places_arg(imm args: List[FormulaValue]) -> FormulaValue:
    """The optional `places` argument. Absent -> BLANK (the "no places"
    marker); present -> a NUMBER or the error that stops the call.

    ⚠ NON-NUMERIC `places` IS `#VALUE!` AND NEGATIVE `places` IS `#NUM!` —
    Microsoft states the two codes separately and they are not the same
    complaint."""
    if len(args) < 2:
        return FormulaValue.blank()
    return _num(args, 1)


def _source_text(imm args: List[FormulaValue]) -> FormulaValue:
    """The base-literal argument as TEXT.

    ⚠ A NUMBER COERCES: `BIN2DEC(1100100)` is 100, because the general format
    of 1100100 is the string `1100100`. A NEGATIVE number coerces to a string
    with a `-`, which is not a base digit, so it is `#NUM!` — which is what
    Excel answers."""
    return _text(args, 0)


def _convert(imm args: List[FormulaValue], src_base: Int, src_bits: Int,
             dst_base: Int, dst_bits: Int) -> FormulaValue:
    """The whole base family, once: parse in the source width, range-check
    against the DESTINATION width, render."""
    var s = _source_text(args)
    if s.is_error():
        return s.copy()
    var p = _parse_base(s.text, src_base, src_bits)
    if not p.ok:
        return FormulaValue.error(XL_ERR_NUM)
    var pl = _places_arg(args)
    if pl.is_error():
        return pl.copy()
    var half = _pow2(dst_bits) * 0.5
    if p.value < -half or p.value > half - 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    if pl.is_blank():
        return _render_base(p.value, dst_base, dst_bits, 0, False)
    return _render_base(p.value, dst_base, dst_bits, _places_int(pl.num), True)


def _from_dec(imm args: List[FormulaValue], dst_base: Int,
              dst_bits: Int) -> FormulaValue:
    """`DEC2*` — the source is a NUMBER, truncated toward zero, and the range
    check is against the DESTINATION width."""
    var n = _num(args, 0)
    if n.is_error():
        return n.copy()
    var v = _trunc(n.num)
    var pl = _places_arg(args)
    if pl.is_error():
        return pl.copy()
    var half = _pow2(dst_bits) * 0.5
    if v < -half or v > half - 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    if pl.is_blank():
        return _render_base(v, dst_base, dst_bits, 0, False)
    return _render_base(v, dst_base, dst_bits, _places_int(pl.num), True)


def _to_dec(imm args: List[FormulaValue], src_base: Int,
            src_bits: Int) -> FormulaValue:
    """`*2DEC` — arity 1, no `places`, and the answer is a NUMBER."""
    var s = _source_text(args)
    if s.is_error():
        return s.copy()
    var p = _parse_base(s.text, src_base, src_bits)
    if not p.ok:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(p.value)


def xl_dec2bin(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DEC2BIN(number, [places])` — 10-bit two's complement, [-512, 511]."""
    return _from_dec(args, 2, _BIN_BITS)


def xl_dec2oct(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DEC2OCT(number, [places])` — 30-bit two's complement."""
    return _from_dec(args, 8, _OCT_BITS)


def xl_dec2hex(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DEC2HEX(number, [places])` — 40-bit two's complement. `DEC2HEX(-1)` is
    ten `F`s, not eight."""
    return _from_dec(args, 16, _HEX_BITS)


def xl_bin2dec(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BIN2DEC(number)` — 10-bit two's complement."""
    return _to_dec(args, 2, _BIN_BITS)


def xl_oct2dec(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`OCT2DEC(number)` — 30-bit two's complement."""
    return _to_dec(args, 8, _OCT_BITS)


def xl_hex2dec(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`HEX2DEC(number)` — 40-bit two's complement."""
    return _to_dec(args, 16, _HEX_BITS)


def xl_bin2oct(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BIN2OCT(number, [places])`."""
    return _convert(args, 2, _BIN_BITS, 8, _OCT_BITS)


def xl_bin2hex(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BIN2HEX(number, [places])`."""
    return _convert(args, 2, _BIN_BITS, 16, _HEX_BITS)


def xl_oct2bin(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`OCT2BIN(number, [places])` — ⚠ NARROWING. The octal door admits
    [-2^29, 2^29-1] and the binary one only [-512, 511], so the range check is
    against the DESTINATION."""
    return _convert(args, 8, _OCT_BITS, 2, _BIN_BITS)


def xl_oct2hex(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`OCT2HEX(number, [places])`."""
    return _convert(args, 8, _OCT_BITS, 16, _HEX_BITS)


def xl_hex2bin(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`HEX2BIN(number, [places])` — ⚠ NARROWING, 40 bits down to 10."""
    return _convert(args, 16, _HEX_BITS, 2, _BIN_BITS)


def xl_hex2oct(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`HEX2OCT(number, [places])` — ⚠ NARROWING, 40 bits down to 30."""
    return _convert(args, 16, _HEX_BITS, 8, _OCT_BITS)


# =============================================================================
# ★ THE BITWISE FAMILY — THE DOMAIN IS 2^48.
#
# ⛔ NOT 2^32 AND NOT 2^53. Microsoft states the limit as "greater than or
# equal to 0 and less than 2^48" for every one of the five, and it is checked
# on the RESULT as well as on the inputs for the two shift functions. 2^48 is
# exactly representable in Float64 (and so is 2^53), so the check is arithmetic
# rather than a cast.
# =============================================================================
comptime _BIT_MAX: Float64 = 281474976710655.0
"""2^48 - 1, spelled as the literal Microsoft's page prints."""

comptime _SHIFT_MAX: Int = 53
"""The documented `shift_amount` limit, |shift| <= 53."""


def _bit_arg(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """One bitwise operand: a NON-NEGATIVE INTEGER below 2^48, or `#NUM!`.

    ⚠ THE THREE REFUSALS ARE ALL `#NUM!` AND THE COERCION FAILURE IS
    `#VALUE!`. `BITAND("x",1)` is `#VALUE!` (the text is not a number);
    `BITAND(-1,1)`, `BITAND(1.5,1)` and `BITAND(2^48,1)` are `#NUM!` (the
    number is not in the domain). Collapsing the two would make the error code
    a lie about where the complaint comes from."""
    var n = _num(args, i)
    if n.is_error():
        return n.copy()
    if n.num < 0.0 or n.num > _BIT_MAX:
        return FormulaValue.error(XL_ERR_NUM)
    if n.num != _trunc(n.num):
        return FormulaValue.error(XL_ERR_NUM)
    return n.copy()


def _bitop(imm args: List[FormulaValue], op: Int) -> FormulaValue:
    """AND / OR / XOR over two 48-bit operands. `op` is 0/1/2."""
    var a = _bit_arg(args, 0)
    if a.is_error():
        return a.copy()
    var b = _bit_arg(args, 1)
    if b.is_error():
        return b.copy()
    var x = Int(a.num)
    var y = Int(b.num)
    if op == 0:
        return FormulaValue.number(Float64(x & y))
    if op == 1:
        return FormulaValue.number(Float64(x | y))
    return FormulaValue.number(Float64(x ^ y))


def xl_bitand(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BITAND(number1, number2)`."""
    return _bitop(args, 0)


def xl_bitor(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BITOR(number1, number2)`."""
    return _bitop(args, 1)


def xl_bitxor(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BITXOR(number1, number2)`."""
    return _bitop(args, 2)


def _shift(imm args: List[FormulaValue], left: Bool) -> FormulaValue:
    """`BITLSHIFT` / `BITRSHIFT`, one implementation.

    ⛔ A NEGATIVE `shift_amount` SHIFTS THE OTHER WAY, which is why these are
    one function and not two: `BITRSHIFT(13,-2)` is 52, the same number
    `BITLSHIFT(13,2)` gives. A kernel that clamps a negative shift to zero
    answers 13 and is right for every non-negative shift anybody writes.

    ⛔ AND THE RESULT IS RANGE-CHECKED TOO. `BITLSHIFT(1,48)` is `#NUM!`
    because 2^48 leaves the domain, where `BITLSHIFT(1,47)` is
    140737488355328. The check is spelled against `_BIT_MAX >> shift` so the
    intermediate can never overflow the Int it is computed in."""
    var a = _bit_arg(args, 0)
    if a.is_error():
        return a.copy()
    var s = _num(args, 1)
    if s.is_error():
        return s.copy()
    # ⛔ THE RANGE CHECK IS ON THE **FLOAT** AND IT COMES FIRST. `Int()` of a
    # Float64 outside Int64's range is UNDEFINED (see `_trunc`), and
    # `BITLSHIFT(4, 1e300)` is an ordinary formula — so the bound has to be
    # applied before the conversion, not after it.
    if s.num < -Float64(_SHIFT_MAX) or s.num > Float64(_SHIFT_MAX):
        return FormulaValue.error(XL_ERR_NUM)
    if s.num != _trunc(s.num):
        return FormulaValue.error(XL_ERR_NUM)
    var sh = Int(s.num)
    if not left:
        sh = -sh
    var x = Int(a.num)
    if sh == 0:
        return FormulaValue.number(Float64(x))
    if sh > 0:
        if sh >= 48:
            if x != 0:
                return FormulaValue.error(XL_ERR_NUM)
            return FormulaValue.number(0.0)
        if x > (Int(_BIT_MAX) >> sh):
            return FormulaValue.error(XL_ERR_NUM)
        return FormulaValue.number(Float64(x << sh))
    var r = -sh
    if r >= 48:
        return FormulaValue.number(0.0)
    return FormulaValue.number(Float64(x >> r))


def xl_bitlshift(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BITLSHIFT(number, shift_amount)`."""
    return _shift(args, True)


def xl_bitrshift(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BITRSHIFT(number, shift_amount)`."""
    return _shift(args, False)


# =============================================================================
# ★ THE COMPARISON PAIR.
# =============================================================================
def xl_delta(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DELTA(number1, [number2])` — the Kronecker delta: 1 if equal, else 0.
    `number2` defaults to 0, so `DELTA(0)` is 1."""
    var a = _num(args, 0)
    if a.is_error():
        return a.copy()
    var b = FormulaValue.number(0.0)
    if len(args) > 1:
        b = _num(args, 1)
        if b.is_error():
            return b.copy()
    if a.num == b.num:
        return FormulaValue.number(1.0)
    return FormulaValue.number(0.0)


def xl_gestep(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GESTEP(number, [step])` — 1 if `number >= step`, else 0.

    ⛔ IT IS AN ORDERED COMPARISON AND NOT A MAGNITUDE ONE: `GESTEP(-4,-5)` is
    **1**. A kernel comparing absolute values answers 0 and agrees with this
    one everywhere both arguments are non-negative, which is the whole region a
    hand-written fixture covers."""
    var a = _num(args, 0)
    if a.is_error():
        return a.copy()
    var b = FormulaValue.number(0.0)
    if len(args) > 1:
        b = _num(args, 1)
        if b.is_error():
            return b.copy()
    if a.num >= b.num:
        return FormulaValue.number(1.0)
    return FormulaValue.number(0.0)


# =============================================================================
# ★ THE ERROR FUNCTION — FOUR NAMES, TWO SHAPES.
#
# `ERF` takes an OPTIONAL upper limit and the other three do not. That arity
# difference is the whole difference between `ERF` and `ERF.PRECISE`, and it is
# graded: a row wired to the wrong one of the pair answers correctly for every
# one-argument call.
# =============================================================================
def xl_erf(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ERF(lower_limit, [upper_limit])` — the integral of the error function
    BETWEEN the two limits, i.e. `erf(upper) - erf(lower)`.

    ⚠ ONE ARGUMENT MEANS `erf(lower) - erf(0)`, and erf(0) is 0, so the
    one-argument form is plain `erf(x)`. `ERF(1,2)` is 0.152621472, NOT
    0.842700793 — a kernel that ignores the second argument answers a
    plausible probability-shaped number in [0,1]."""
    var a = _num(args, 0)
    if a.is_error():
        return a.copy()
    if len(args) < 2:
        return FormulaValue.number(xs_erf(a.num))
    var b = _num(args, 1)
    if b.is_error():
        return b.copy()
    return FormulaValue.number(xs_erf(b.num) - xs_erf(a.num))


def xl_erf_precise(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ERF.PRECISE(x)` — one argument only. The 2010 spelling exists BECAUSE
    it has no second limit."""
    var a = _num(args, 0)
    if a.is_error():
        return a.copy()
    return FormulaValue.number(xs_erf(a.num))


def xl_erfc(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ERFC(x)` — the complementary error function, `1 - erf(x)`.

    ⚠ COMPUTED AS libm `erfc` AND NOT AS `1 - erf(x)`: in the RIGHT tail the
    subtraction cancels to zero while `erfc` returns the small number directly,
    which is the same argument `norm_s_cdf` makes next door for the left tail.

    ⚠ A NEGATIVE ARGUMENT IS ACCEPTED — `ERFC(-1)` is 1.842700793. Excel
    before 2010 refused one with `#NUM!`; the modern function does not."""
    var a = _num(args, 0)
    if a.is_error():
        return a.copy()
    return FormulaValue.number(xs_erfc(a.num))


def xl_erfc_precise(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ERFC.PRECISE(x)` — the same number as `ERFC`, under the 2010 name."""
    var a = _num(args, 0)
    if a.is_error():
        return a.copy()
    return FormulaValue.number(xs_erfc(a.num))


# =============================================================================
# ★★ COMPLEX NUMBERS — ONE TEXT PARSER, ONE FORMATTER, TWENTY-SIX NAMES.
#
# ⛔ THE PARSER'S ERROR CODE IS `#NUM!`, NOT `#VALUE!`, and Microsoft states it
# on every one of the twenty-five consumers: "If inumber is not in the form
# x+yi or x+yj, IMABS returns the #NUM! error value." `#VALUE!` is what a
# reader guesses and what a text-coercion failure gives, so the two are
# DIFFERENT complaints here and both are reachable.
# =============================================================================
comptime _SUF_I: UInt8 = 0
comptime _SUF_J: UInt8 = 1
comptime _SUF_NONE: UInt8 = 2
"""A PURELY REAL literal carries NO suffix, which is not the same as carrying
`i`: `IMSUM("3","4j")` is `"7j"`, because only one operand stated a spelling."""


@fieldwise_init
struct _Cx(Copyable, Movable):
    """A parsed complex number. `err` is `XL_ERR_NONE` (0) when `re`/`im` are
    meaningful."""

    var re: Float64
    var im: Float64
    var suf: UInt8
    var err: UInt8

    def copy(self) -> Self:
        return Self(self.re, self.im, self.suf, self.err)


def _f64(s: String) -> _Parsed:
    """Parse a decimal literal, or `ok = False`. An empty string is NOT a
    number here — the caller decides whether empty means 1 (a bare `i`) or is
    an error."""
    if len(s.as_bytes()) == 0:
        return _Parsed(False, 0.0)
    try:
        return _Parsed(True, Float64(s))
    except:
        return _Parsed(False, 0.0)


def _parse_cx(s: String) -> _Cx:
    """Read `x+yi` / `x+yj` / `x` / `yi` / `i` / `-i`.

    ★ THE SEPARATOR IS THE LAST `+`/`-` THAT IS NEITHER AT POSITION 0 NOR
    IMMEDIATELY AFTER AN `e`/`E`. Without the exponent clause `"1.5e-3"` splits
    into `1.5e` and `-3` and every literal in scientific notation becomes
    `#NUM!`; without the position clause `"-3-4i"` loses its leading sign."""
    var bs = s.as_bytes()
    var n = len(bs)
    if n == 0:
        return _Cx(0.0, 0.0, _SUF_NONE, 0)
    var suf = _SUF_NONE
    var body = n
    if bs[n - 1] == UInt8(105):  # 'i'
        suf = _SUF_I
        body = n - 1
    elif bs[n - 1] == UInt8(106):  # 'j'
        suf = _SUF_J
        body = n - 1
    # Locate the real/imaginary separator inside [0, body).
    var sep = -1
    for k in range(1, body):
        var c = bs[k]
        if c == UInt8(43) or c == UInt8(45):  # '+' '-'
            var p = bs[k - 1]
            if p == UInt8(101) or p == UInt8(69):  # 'e' 'E'
                continue
            sep = k
    var head = String("")
    var tail = String("")
    if sep < 0:
        tail = _slice_bytes(s, 0, body)
    else:
        head = _slice_bytes(s, 0, sep)
        tail = _slice_bytes(s, sep, body)
    if suf == _SUF_NONE:
        # No suffix: the WHOLE literal must be a real number. `"3+4"` is
        # not in the form x+yi, so it is `#NUM!` and not 7.
        if sep >= 0:
            return _Cx(0.0, 0.0, _SUF_NONE, XL_ERR_NUM)
        var r = _f64(tail)
        if not r.ok:
            return _Cx(0.0, 0.0, _SUF_NONE, XL_ERR_NUM)
        return _Cx(r.value, 0.0, _SUF_NONE, 0)
    # Suffixed: `tail` is the imaginary coefficient and may be "", "+" or "-".
    var im = Float64(1.0)
    var tb = tail.as_bytes()
    if len(tb) == 0:
        im = 1.0
    elif len(tb) == 1 and tb[0] == UInt8(43):
        im = 1.0
    elif len(tb) == 1 and tb[0] == UInt8(45):
        im = -1.0
    else:
        var iv = _f64(tail)
        if not iv.ok:
            return _Cx(0.0, 0.0, _SUF_NONE, XL_ERR_NUM)
        im = iv.value
    var re = Float64(0.0)
    if sep >= 0:
        var rv = _f64(head)
        if not rv.ok:
            return _Cx(0.0, 0.0, _SUF_NONE, XL_ERR_NUM)
        re = rv.value
    return _Cx(re, im, suf, 0)


def _slice_bytes(s: String, a: Int, b: Int) -> String:
    """Bytes `[a, b)` of `s` as a new `String`.

    ⚠ IT TAKES THE `String` AND NOT A `Span`, which is not a style choice: a
    bare `Span[UInt8]` parameter in Mojo 1.0.0 fails to infer its `origin`
    parameter, and the lifetime this function actually needs is the CALLER's
    string. Every literal this file slices is ASCII by construction — the
    separator scan only ever cuts at `+`/`-`/`i`/`j`, never inside a multi-byte
    character — so a byte slice here cannot split a character."""
    var bs = s.as_bytes()
    var buf = List[UInt8]()
    for k in range(a, b):
        buf.append(bs[k])
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _suffix_text(suf: UInt8) -> String:
    if suf == _SUF_J:
        return String("j")
    return String("i")


def _fmt_num(v: Float64) -> String:
    """One coefficient in Excel's general format. Routed through
    `FormulaValue` so a complex result and a numeric one cannot render a
    number two different ways."""
    return FormulaValue.number(v).coerce_text().text


def _fmt_cx(re: Float64, im: Float64, suf: UInt8) -> FormulaValue:
    """Render `re + im*suffix`.
    `re + "+" + im + "i"` gets wrong while being right for `COMPLEX(3,4)`."""
    if not _finite(re) or not _finite(im):
        return FormulaValue.error(XL_ERR_NUM)
    var sf = _suffix_text(suf)
    if im == 0.0:
        return FormulaValue.text_val(_fmt_num(re))
    var imtxt = String("")
    if im == 1.0:
        imtxt = String("")
    elif im == -1.0:
        imtxt = String("-")
    else:
        imtxt = _fmt_num(im)
    if re == 0.0:
        return FormulaValue.text_val(imtxt + sf)
    var sign = String("")
    if im > 0.0:
        sign = String("+")
    return FormulaValue.text_val(_fmt_num(re) + sign + imtxt + sf)


def _finite(v: Float64) -> Bool:
    """Excel's numeric lattice has no infinity and no NaN; a complex kernel
    that overflows answers `#NUM!` for the same reason `FormulaValue.number`
    does."""
    return v >= -1.7976931348623157e308 and v <= 1.7976931348623157e308


def _arg_cx(imm args: List[FormulaValue], i: Int) -> _Cx:
    """Argument `i` as a complex number. An ERROR argument rides out through
    `err` so the leftmost-error dominance is preserved."""
    var t = _text(args, i)
    if t.is_error():
        return _Cx(0.0, 0.0, _SUF_NONE, t.error_code)
    return _parse_cx(t.text)


def _err_of(c: _Cx) -> FormulaValue:
    return FormulaValue.error(c.err)


def _join_suffix(a: UInt8, b: UInt8) -> Int:
    """The suffix of a two-operand result, or -1 when the operands DISAGREE.

    ⚠ `_SUF_NONE` IS NOT A DISAGREEMENT — a purely real operand states no
    spelling, so `IMSUM("3","4j")` is `"7j"`."""
    if a == _SUF_NONE:
        return Int(b)
    if b == _SUF_NONE:
        return Int(a)
    if a != b:
        return -1
    return Int(a)


def xl_complex(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`COMPLEX(real_num, i_num, [suffix])`.
    Excel requires lower case."""
    var a = _num(args, 0)
    if a.is_error():
        return a.copy()
    var b = _num(args, 1)
    if b.is_error():
        return b.copy()
    var suf = _SUF_I
    if len(args) > 2:
        var s = _text(args, 2)
        if s.is_error():
            return s.copy()
        if s.text == String("i"):
            suf = _SUF_I
        elif s.text == String("j"):
            suf = _SUF_J
        else:
            return FormulaValue.error(XL_ERR_VALUE)
    return _fmt_cx(a.num, b.num, suf)


def xl_imreal(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMREAL(inumber)`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    return FormulaValue.number(c.re)


def xl_imaginary(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMAGINARY(inumber)`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    return FormulaValue.number(c.im)


def xl_imabs(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMABS(inumber)` — the modulus."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    return FormulaValue.number(_sqrt(c.re * c.re + c.im * c.im))


def xl_imargument(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMARGUMENT(inumber)` — theta, in radians, in (-pi, pi].

    ⛔⛔ `atan2(im, re)` AND NEVER `atan(im/re)`. `IMARGUMENT("-1")` is **pi**
    and the quotient form answers **0**, because the quotient throws the
    quadrant away; that is the branch cut the brief warns about and it is
    reached by the shortest literal in the family.

    ⚠ ZERO IS `#DIV/0!` AND NOT `#NUM!` — Microsoft states that code for this
    one function, and it is the only `#DIV/0!` in the Engineering category."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    if c.re == 0.0 and c.im == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number(atan2(c.im, c.re))


def xl_imconjugate(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMCONJUGATE(inumber)`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    return _fmt_cx(c.re, -c.im, c.suf)


def xl_imsum(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMSUM(inumber1, ...)` — variadic."""
    var re = Float64(0.0)
    var im = Float64(0.0)
    var suf = _SUF_NONE
    for i in range(len(args)):
        var c = _arg_cx(args, i)
        if c.err != 0:
            return _err_of(c)
        var j = _join_suffix(suf, c.suf)
        if j < 0:
            return FormulaValue.error(XL_ERR_VALUE)
        suf = UInt8(j)
        re += c.re
        im += c.im
    return _fmt_cx(re, im, suf)


def xl_imsub(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMSUB(inumber1, inumber2)`."""
    var a = _arg_cx(args, 0)
    if a.err != 0:
        return _err_of(a)
    var b = _arg_cx(args, 1)
    if b.err != 0:
        return _err_of(b)
    var j = _join_suffix(a.suf, b.suf)
    if j < 0:
        return FormulaValue.error(XL_ERR_VALUE)
    return _fmt_cx(a.re - b.re, a.im - b.im, UInt8(j))


def xl_improduct(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMPRODUCT(inumber1, ...)` — variadic.

    ⛔ `(ac - bd) + (ad + bc)i`. The MINUS in the real part is the whole
    function: a kernel that adds answers 13 for `IMPRODUCT("2+3i","2+3i")`
    where the answer is -5, and both are plausible."""
    var re = Float64(1.0)
    var im = Float64(0.0)
    var suf = _SUF_NONE
    for i in range(len(args)):
        var c = _arg_cx(args, i)
        if c.err != 0:
            return _err_of(c)
        var j = _join_suffix(suf, c.suf)
        if j < 0:
            return FormulaValue.error(XL_ERR_VALUE)
        suf = UInt8(j)
        var nr = re * c.re - im * c.im
        var ni = re * c.im + im * c.re
        re = nr
        im = ni
    return _fmt_cx(re, im, suf)


def xl_imdiv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMDIV(inumber1, inumber2)`.

    ⚠ DIVISION BY ZERO IS `#NUM!` HERE AND `#DIV/0!` IN `IMARGUMENT` — the two
    codes really are different in this category, which is why neither is
    guessed."""
    var a = _arg_cx(args, 0)
    if a.err != 0:
        return _err_of(a)
    var b = _arg_cx(args, 1)
    if b.err != 0:
        return _err_of(b)
    var j = _join_suffix(a.suf, b.suf)
    if j < 0:
        return FormulaValue.error(XL_ERR_VALUE)
    var d = b.re * b.re + b.im * b.im
    if d == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return _fmt_cx((a.re * b.re + a.im * b.im) / d,
                   (a.im * b.re - a.re * b.im) / d, UInt8(j))


def _xexp(x: Float64) -> Float64:
    return external_call["exp", Float64](x)


def _xlog(x: Float64) -> Float64:
    return external_call["log", Float64](x)


def _xsin(x: Float64) -> Float64:
    return external_call["sin", Float64](x)


def _xcos(x: Float64) -> Float64:
    return external_call["cos", Float64](x)


def _xsinh(x: Float64) -> Float64:
    return external_call["sinh", Float64](x)


def _xcosh(x: Float64) -> Float64:
    return external_call["cosh", Float64](x)


def _xpow(b: Float64, e: Float64) -> Float64:
    """libm `pow`. ⛔ NOT `b ** e` — Mojo 1.0.0's Float64 `**` is an
    approximate exp2/log2 kernel ~196,000 ulps off libm, measured
    and recorded in `xl_special_fn.mojo`."""
    return external_call["pow", Float64](b, e)


def xl_imexp(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMEXP(inumber)` — `e^a (cos b + i sin b)`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var m = _xexp(c.re)
    return _fmt_cx(m * _xcos(c.im), m * _xsin(c.im), c.suf)


def _imln(c: _Cx) -> _Cx:
    """`ln z = ln|z| + i*arg(z)`, the PRINCIPAL branch. Shared by the three
    logarithms so they cannot pick different branches."""
    var m = _sqrt(c.re * c.re + c.im * c.im)
    if m == 0.0:
        return _Cx(0.0, 0.0, c.suf, XL_ERR_NUM)
    return _Cx(_xlog(m), atan2(c.im, c.re), c.suf, 0)


def xl_imln(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMLN(inumber)`. `IMLN("0")` is `#NUM!`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var l = _imln(c)
    if l.err != 0:
        return _err_of(l)
    return _fmt_cx(l.re, l.im, c.suf)


def xl_imlog10(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMLOG10(inumber)` — `IMLN(z) / ln(10)`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var l = _imln(c)
    if l.err != 0:
        return _err_of(l)
    var k = _xlog(10.0)
    return _fmt_cx(l.re / k, l.im / k, c.suf)


def xl_imlog2(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMLOG2(inumber)` — `IMLN(z) / ln(2)`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var l = _imln(c)
    if l.err != 0:
        return _err_of(l)
    var k = _xlog(2.0)
    return _fmt_cx(l.re / k, l.im / k, c.suf)


def _impow(c: _Cx, n: Float64) -> _Cx:
    """`z^n` by modulus and argument, the principal branch."""
    var m = _sqrt(c.re * c.re + c.im * c.im)
    if m == 0.0:
        if n > 0.0:
            return _Cx(0.0, 0.0, c.suf, 0)
        return _Cx(0.0, 0.0, c.suf, XL_ERR_NUM)
    var th = atan2(c.im, c.re)
    var r = _xpow(m, n)
    return _Cx(r * _xcos(n * th), r * _xsin(n * th), c.suf, 0)


def xl_impower(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMPOWER(inumber, number)` — the exponent may be any real."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var n = _num(args, 1)
    if n.is_error():
        return n.copy()
    var p = _impow(c, n.num)
    if p.err != 0:
        return _err_of(p)
    return _fmt_cx(p.re, p.im, c.suf)


def xl_imsqrt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMSQRT(inumber)` — `IMPOWER(z, 0.5)`, principal branch."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var p = _impow(c, 0.5)
    if p.err != 0:
        return _err_of(p)
    return _fmt_cx(p.re, p.im, c.suf)


def _imsin(c: _Cx) -> _Cx:
    return _Cx(_xsin(c.re) * _xcosh(c.im), _xcos(c.re) * _xsinh(c.im),
               c.suf, 0)


def _imcos(c: _Cx) -> _Cx:
    return _Cx(_xcos(c.re) * _xcosh(c.im), -_xsin(c.re) * _xsinh(c.im),
               c.suf, 0)


def _imsinh(c: _Cx) -> _Cx:
    return _Cx(_xsinh(c.re) * _xcos(c.im), _xcosh(c.re) * _xsin(c.im),
               c.suf, 0)


def _imcosh(c: _Cx) -> _Cx:
    return _Cx(_xcosh(c.re) * _xcos(c.im), _xsinh(c.re) * _xsin(c.im),
               c.suf, 0)


def _cdiv(ar: Float64, ai: Float64, br: Float64, bi: Float64,
          suf: UInt8) -> _Cx:
    var d = br * br + bi * bi
    if d == 0.0:
        return _Cx(0.0, 0.0, suf, XL_ERR_NUM)
    return _Cx((ar * br + ai * bi) / d, (ai * br - ar * bi) / d, suf, 0)


def xl_imsin(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMSIN(inumber)` — `sin a cosh b + i cos a sinh b`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var r = _imsin(c)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imcos(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMCOS(inumber)` — `cos a cosh b - i sin a sinh b`. ⚠ THE MINUS is the
    only difference from `IMSIN`'s shape and it is not a sign convention: it
    is what makes `IMCOS` even."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var r = _imcos(c)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imtan(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMTAN(inumber)` — `IMSIN / IMCOS`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var s = _imsin(c)
    var k = _imcos(c)
    var r = _cdiv(s.re, s.im, k.re, k.im, c.suf)
    if r.err != 0:
        return _err_of(r)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imcot(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMCOT(inumber)` — `IMCOS / IMSIN`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var s = _imsin(c)
    var k = _imcos(c)
    var r = _cdiv(k.re, k.im, s.re, s.im, c.suf)
    if r.err != 0:
        return _err_of(r)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imsec(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMSEC(inumber)` — `1 / IMCOS`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var k = _imcos(c)
    var r = _cdiv(1.0, 0.0, k.re, k.im, c.suf)
    if r.err != 0:
        return _err_of(r)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imcsc(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMCSC(inumber)` — `1 / IMSIN`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var s = _imsin(c)
    var r = _cdiv(1.0, 0.0, s.re, s.im, c.suf)
    if r.err != 0:
        return _err_of(r)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imsinh(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMSINH(inumber)` — `sinh a cos b + i cosh a sin b`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var r = _imsinh(c)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imcosh(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMCOSH(inumber)` — `cosh a cos b + i sinh a sin b`. ⚠ PLUS, where the
    CIRCULAR cosine takes a minus."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var r = _imcosh(c)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imsech(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMSECH(inumber)` — `1 / IMCOSH`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var k = _imcosh(c)
    var r = _cdiv(1.0, 0.0, k.re, k.im, c.suf)
    if r.err != 0:
        return _err_of(r)
    return _fmt_cx(r.re, r.im, c.suf)


def xl_imcsch(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IMCSCH(inumber)` — `1 / IMSINH`."""
    var c = _arg_cx(args, 0)
    if c.err != 0:
        return _err_of(c)
    var s = _imsinh(c)
    var r = _cdiv(1.0, 0.0, s.re, s.im, c.suf)
    if r.err != 0:
        return _err_of(r)
    return _fmt_cx(r.re, r.im, c.suf)
