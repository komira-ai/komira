# =============================================================================
# komira_plan_harness/float_text.mojo -- float cells: text, bits, tolerance.
# =============================================================================
#
# A float cell is `<decimal>|0x<IEEE bits>`: the decimal is for a reader, the
# bits are what is compared. Bit patterns are carried as UInt64 for every
# width (float16, float32, float64), the hex has width/4 upper-case digits.
#
#   NaN    `NaN|0x7FF8000000000000`; a hand file may write bare `NaN`, which
#          matches any NaN. With bits, only that NaN matches.
#   zero   `0.0|0x0...` and `-0.0|0x8...` are different cells.
#   inf    `inf|0x...` and `-inf|0x...`; bare `inf` / `-inf` are accepted.
#
# A hand file may give the decimal only. It is accepted only when the decimal
# is EXACTLY a float of the column's width (`0.5`, `-0.0`, `1e300` is not,
# `0.1` is not): the bits are then derived from it, never rounded. A decimal
# given WITH bits must round to those bits (it lies between the midpoints to
# the two neighbouring floats), or the cell is refused: a file whose decimal a
# reviewer reads must not disagree with the bits the compare uses (ties go
# to the even mantissa, as IEEE round-to-nearest does). Both
# decisions are made in exact integer arithmetic (_bignat.mojo), not by a
# float parser.
#
# Comparison (float_cells_match): NaN against NaN by bits when the expected
# side gives bits; two zeros by bits (so -0.0 is not 0.0); infinities by bits;
# anything else within the column's tolerance, `ulps=<n>` (distance in units
# in the last place, -0.0 and 0.0 adjacent) or `rel=<x>`
# (|a - e| <= x * max(|a|, |e|)).
# =============================================================================

from std.memory import bitcast

from ._bignat import BigNat, cmp_dec_dyadic


# ---------------------------------------------------------------------------
# IEEE layout per width
# ---------------------------------------------------------------------------


def _mbits(width: Int) -> Int:
    if width == 16:
        return 10
    if width == 32:
        return 23
    return 52


def _ebits(width: Int) -> Int:
    if width == 16:
        return 5
    if width == 32:
        return 8
    return 11


def _bias(width: Int) -> Int:
    return (1 << (_ebits(width) - 1)) - 1


def _sign_bit(width: Int) -> UInt64:
    return UInt64(1) << UInt64(width - 1)


def _frac_mask(width: Int) -> UInt64:
    return (UInt64(1) << UInt64(_mbits(width))) - 1


def _exp_field(bits: UInt64, width: Int) -> Int:
    var emask = (UInt64(1) << UInt64(_ebits(width))) - 1
    return Int((bits >> UInt64(_mbits(width))) & emask)


def _exp_all_ones(width: Int) -> Int:
    return (1 << _ebits(width)) - 1


def float_is_nan(bits: UInt64, width: Int) -> Bool:
    return _exp_field(bits, width) == _exp_all_ones(width) and (
        bits & _frac_mask(width)
    ) != 0


def float_is_inf(bits: UInt64, width: Int) -> Bool:
    return _exp_field(bits, width) == _exp_all_ones(width) and (
        bits & _frac_mask(width)
    ) == 0


def float_is_zero(bits: UInt64, width: Int) -> Bool:
    return (bits & ~_sign_bit(width)) == 0


def _is_negative(bits: UInt64, width: Int) -> Bool:
    return (bits & _sign_bit(width)) != 0


def _inf_bits(negative: Bool, width: Int) -> UInt64:
    var b = UInt64(_exp_all_ones(width)) << UInt64(_mbits(width))
    if negative:
        b |= _sign_bit(width)
    return b


def float_value(bits: UInt64, width: Int) -> Float64:
    """The value of a bit pattern, widened exactly to Float64."""
    if width == 64:
        return bitcast[DType.float64](bits)
    if width == 32:
        return Float64(bitcast[DType.float32](UInt32(bits)))
    return Float64(bitcast[DType.float16](UInt16(bits)).cast[DType.float32]())


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def _hex_upper(nibble: UInt64) -> String:
    var digits = String("0123456789ABCDEF")
    var i = Int(nibble & 0xF)
    return String(digits[byte = i : i + 1])


def bits_hex(bits: UInt64, width: Int) -> String:
    """`0x` and width/4 upper-case hex digits."""
    var res = String("0x")
    var n = width // 4
    for k in range(n):
        var shift = UInt64((n - 1 - k) * 4)
        res += _hex_upper(bits >> shift)
    return res


def float_decimal_text(bits: UInt64, width: Int) -> String:
    """The readable half of a float cell. Specials are spelled by canon
    itself; a finite non-zero value uses the standard library's shortest
    round-trip formatting of the column's own width (float16 through float32,
    which holds it exactly)."""
    if float_is_nan(bits, width):
        return String("NaN")
    if float_is_inf(bits, width):
        return String("-inf") if _is_negative(bits, width) else String("inf")
    if float_is_zero(bits, width):
        return String("-0.0") if _is_negative(bits, width) else String("0.0")
    if width == 64:
        return String(bitcast[DType.float64](bits))
    if width == 32:
        return String(bitcast[DType.float32](UInt32(bits)))
    return String(bitcast[DType.float16](UInt16(bits)).cast[DType.float32]())


def float_cell_text(bits: UInt64, width: Int) -> String:
    """The canonical cell: `<decimal>|0x<bits>`."""
    return float_decimal_text(bits, width) + "|" + bits_hex(bits, width)


# ---------------------------------------------------------------------------
# Decimal parsing (exact)
# ---------------------------------------------------------------------------

# Bounds that keep the exact arithmetic small. No float of any width needs
# more: float64's smallest subnormal has 751 significant digits and exponent
# -1074 (scientific form), its largest finite is below 1e309.
comptime _MAX_DIGITS: Int = 800
comptime _MAX_ABS_EXP10: Int = 1200


struct ParsedDecimal(Movable):
    """`[-]digits[.digits][(e|E)[+|-]digits]` as sign, D and E with value
    D * 10^E."""

    var negative: Bool
    var digits: BigNat
    var exp10: Int

    def __init__(out self, negative: Bool, var digits: BigNat, exp10: Int):
        self.negative = negative
        self.digits = digits^
        self.exp10 = exp10


def _is_digit(b: UInt8) -> Bool:
    return b >= 48 and b <= 57


def parse_decimal(text: String) raises -> ParsedDecimal:
    """Parse a decimal literal exactly; raise naming the text if malformed."""
    var bs = text.as_bytes()
    var n = len(bs)
    var i = 0
    var negative = False
    if i < n and bs[i] == 45:  # '-'
        negative = True
        i += 1
    var digits = BigNat()
    var ndigits = 0
    var sig = 0
    var frac_digits = 0
    var chunk: UInt32 = 0
    var chunk_len = 0

    var seen_point = False
    while i < n:
        var b = bs[i]
        if _is_digit(b):
            ndigits += 1
            if sig > 0 or b != 48:
                sig += 1
            if ndigits > _MAX_DIGITS + 400:
                raise Error("canon: '" + text + "' is too long")
            if seen_point:
                frac_digits += 1
            chunk = chunk * 10 + UInt32(b - 48)
            chunk_len += 1
            if chunk_len == 9:
                digits.mul_small(1000000000)
                digits.add_small(chunk)
                chunk = 0
                chunk_len = 0
            i += 1
        elif b == 46 and not seen_point:  # '.'
            seen_point = True
            i += 1
        else:
            break
    if ndigits == 0:
        raise Error("canon: '" + text + "' is not a decimal number")
    if sig > _MAX_DIGITS:
        raise Error(
            "canon: '" + text + "' has more than "
            + String(_MAX_DIGITS) + " significant digits"
        )
    if chunk_len > 0:
        var scale: UInt32 = 1
        for _ in range(chunk_len):
            scale *= 10
        digits.mul_small(scale)
        digits.add_small(chunk)
    var exp = 0
    if i < n and (bs[i] == 101 or bs[i] == 69):  # 'e' / 'E'
        i += 1
        var eneg = False
        if i < n and (bs[i] == 43 or bs[i] == 45):
            eneg = bs[i] == 45
            i += 1
        var edigits = 0
        while i < n and _is_digit(bs[i]):
            if exp < 100000:
                exp = exp * 10 + Int(bs[i] - 48)
            edigits += 1
            i += 1
        if edigits == 0:
            raise Error("canon: '" + text + "' has an empty exponent")
        if eneg:
            exp = -exp
    if i != n:
        raise Error("canon: '" + text + "' is not a decimal number")
    return ParsedDecimal(negative, digits^, exp - frac_digits)


def exact_float_bits(dec: ParsedDecimal, width: Int) raises -> UInt64:
    """The bits of the float of `width` that EQUALS `dec`; raise when there is
    none (the decimal would have to be rounded, or is out of range)."""
    var sign = _sign_bit(width) if dec.negative else UInt64(0)
    if dec.digits.is_zero():
        return sign
    var e10 = dec.exp10
    if e10 > _MAX_ABS_EXP10 or e10 < -_MAX_ABS_EXP10:
        raise Error("out of range")
    var n = dec.digits.copy()
    if e10 >= 0:
        n.mul_pow5(e10)
    else:
        for _ in range(-e10):
            if n.divmod_small(5) != 0:
                raise Error("not exactly representable")
    var e2 = e10
    # n is not zero here (dec.digits is not, and only an exact division got
    # here); the check keeps the loop finite if that ever stops holding.
    while not n.is_zero() and n.is_even():
        n.shr1()
        e2 += 1
    if n.is_zero():
        raise Error("not exactly representable")
    var mbits = _mbits(width)
    var bl = n.bit_length()
    if bl > mbits + 1:
        raise Error("not exactly representable")
    var top = e2 + bl - 1
    var bias = _bias(width)
    if top > bias:
        raise Error("out of range")
    var m = n.low_u64()
    var emin = 1 - bias
    if top >= emin:
        var mant = (m << UInt64(mbits - (bl - 1))) & _frac_mask(width)
        return sign | (UInt64(top + bias) << UInt64(mbits)) | mant
    var shift = e2 - (emin - mbits)
    if shift < 0:
        raise Error("not exactly representable")
    return sign | (m << UInt64(shift))


def decimal_rounds_to(dec: ParsedDecimal, bits: UInt64, width: Int) -> Bool:
    """True iff `dec` rounds to the finite float `bits` (round half to even):
    it lies between the midpoints to the two neighbours, a midpoint itself
    only when `bits` has an even mantissa; with the same sign; a zero
    float requires a zero decimal of the same sign."""
    var neg = _is_negative(bits, width)
    if float_is_zero(bits, width):
        return dec.digits.is_zero() and dec.negative == neg
    if dec.digits.is_zero() or dec.negative != neg:
        return False
    if dec.exp10 > _MAX_ABS_EXP10 or dec.exp10 < -_MAX_ABS_EXP10:
        return False
    var mbits = _mbits(width)
    var exp = _exp_field(bits, width)
    var frac = bits & _frac_mask(width)
    var m: UInt64
    var f: Int
    if exp == 0:
        m = frac
        f = 1 - _bias(width) - mbits
    else:
        m = frac | (UInt64(1) << UInt64(mbits))
        f = exp - _bias(width) - mbits
    var hi = BigNat.from_u64(2 * m + 1)
    var lo: BigNat
    var glo: Int
    if exp > 1 and frac == 0:
        # The bottom of a binade: the float below is half as far away.
        lo = BigNat.from_u64(4 * m - 1)
        glo = f - 2
    else:
        lo = BigNat.from_u64(2 * m - 1)
        glo = f - 1
    # Round half to even: a decimal exactly on a midpoint rounds to the float
    # whose mantissa is even, so the ends are closed only for an even one.
    var even = (m & 1) == 0
    var c_lo = cmp_dec_dyadic(dec.digits, dec.exp10, lo, glo)
    if c_lo < 0 or (c_lo == 0 and not even):
        return False
    var c_hi = cmp_dec_dyadic(dec.digits, dec.exp10, hi, f - 1)
    return c_hi < 0 or (c_hi == 0 and even)


# ---------------------------------------------------------------------------
# Cells
# ---------------------------------------------------------------------------


struct FloatCell(Copyable, Movable):
    """A parsed float cell: NULL, any NaN (bare `NaN` in a hand file), or a
    bit pattern."""

    var is_null: Bool
    var any_nan: Bool
    var bits: UInt64

    def __init__(out self, is_null: Bool, any_nan: Bool, bits: UInt64):
        self.is_null = is_null
        self.any_nan = any_nan
        self.bits = bits

    def canonical(self, width: Int) -> String:
        if self.is_null:
            return String("\\N")
        if self.any_nan:
            return String("NaN")
        return float_cell_text(self.bits, width)


def _parse_hex_bits(text: String, width: Int) raises -> UInt64:
    var bs = text.as_bytes()
    var want = width // 4
    if len(bs) != want + 2 or bs[0] != 48 or (bs[1] != 120 and bs[1] != 88):
        raise Error(
            "canon: float bits '" + text + "' are not 0x and "
            + String(want) + " hex digits"
        )
    var v: UInt64 = 0
    for k in range(2, len(bs)):
        var b = bs[k]
        var d: UInt64
        if b >= 48 and b <= 57:
            d = UInt64(b - 48)
        elif b >= 65 and b <= 70:
            d = UInt64(b - 55)
        elif b >= 97 and b <= 102:
            d = UInt64(b - 87)
        else:
            raise Error("canon: float bits '" + text + "' hold a non-hex digit")
        v = (v << 4) | d
    return v


def parse_float_cell(text: String, width: Int) raises -> FloatCell:
    """Parse an expected float cell (see the module header for the forms)."""
    if text == "\\N":
        return FloatCell(True, False, 0)
    if text == "NaN":
        return FloatCell(False, True, 0)
    var w = String("float") + String(width)
    var bar = text.find("|")
    if bar < 0:
        if text == "inf":
            return FloatCell(False, False, _inf_bits(False, width))
        if text == "-inf":
            return FloatCell(False, False, _inf_bits(True, width))
        var dec = parse_decimal(text)
        try:
            return FloatCell(False, False, exact_float_bits(dec, width))
        except e:
            raise Error(
                "canon: '" + text + "' is " + String(e) + " as " + w
                + "; write the cell as <decimal>|0x<bits>"
            )
    var dpart = String(text[byte=0:bar])
    var hpart = String(text[byte = bar + 1 : text.byte_length()])
    var bits = _parse_hex_bits(hpart, width)
    if dpart == "NaN":
        if not float_is_nan(bits, width):
            raise Error("canon: '" + text + "' says NaN but the bits are not a NaN")
        return FloatCell(False, False, bits)
    if dpart == "inf" or dpart == "-inf":
        if bits != _inf_bits(dpart == "-inf", width):
            raise Error("canon: '" + text + "' says " + dpart + " but the bits differ")
        return FloatCell(False, False, bits)
    if float_is_nan(bits, width) or float_is_inf(bits, width):
        raise Error(
            "canon: '" + text + "' gives a number but the bits are NaN or inf"
        )
    var dec = parse_decimal(dpart)
    if not decimal_rounds_to(dec, bits, width):
        raise Error(
            "canon: '" + text + "': the decimal does not round to the bits as "
            + w
        )
    return FloatCell(False, False, bits)


# ---------------------------------------------------------------------------
# Tolerance and comparison
# ---------------------------------------------------------------------------


struct FloatTolerance(Copyable, Movable, Writable):
    """`ulps=<n>` or `rel=<x>`; `text` is the spelling, kept for the header."""

    var is_rel: Bool
    var ulps: Int
    var rel: Float64
    var text: String

    def __init__(out self):
        """`ulps=0`: bit-exact."""
        self.is_rel = False
        self.ulps = 0
        self.rel = 0.0
        self.text = String("ulps=0")

    @staticmethod
    def of_ulps(n: Int) -> FloatTolerance:
        var t = FloatTolerance()
        t.ulps = n
        t.text = String("ulps=") + String(n)
        return t^

    @staticmethod
    def parse(text: String) raises -> FloatTolerance:
        """Parse `ulps=<n>` (n >= 0) or `rel=<x>` (x >= 0)."""
        if text.startswith("ulps="):
            var num = String(text[byte = 5 : text.byte_length()])
            var bs = num.as_bytes()
            if len(bs) == 0 or len(bs) > 18:
                raise Error("canon: bad tolerance '" + text + "'")
            var n = 0
            for b in bs:
                if not _is_digit(b):
                    raise Error("canon: bad tolerance '" + text + "'")
                n = n * 10 + Int(b - 48)
            var t = FloatTolerance.of_ulps(n)
            t.text = text
            return t^
        if text.startswith("rel="):
            var num = String(text[byte = 4 : text.byte_length()])
            var dec = parse_decimal(num)
            if dec.negative:
                raise Error("canon: negative tolerance '" + text + "'")
            var t = FloatTolerance()
            t.is_rel = True
            t.rel = _approx_value(dec)
            t.text = text
            return t^
        raise Error(
            "canon: tolerance '" + text + "' is neither ulps=<n> nor rel=<x>"
        )

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.text)


def _approx_value(dec: ParsedDecimal) -> Float64:
    """A tolerance's value; approximate is enough there."""
    var v: Float64 = 0.0
    var i = len(dec.digits.limbs) - 1
    while i >= 0:
        v = v * 4294967296.0 + Float64(dec.digits.limbs[i])
        i -= 1
    var e = dec.exp10
    while e > 0:
        v *= 10.0
        e -= 1
    while e < 0:
        v /= 10.0
        e += 1
    return v


def ulp_distance(a: UInt64, b: UInt64, width: Int) -> UInt64:
    """Units in the last place between two non-NaN patterns; -0.0 and 0.0
    are 0 apart, and the count runs through zero across a sign change."""
    var sign = _sign_bit(width)
    var ma = a & ~sign
    var mb = b & ~sign
    if (a & sign) != (b & sign):
        return ma + mb
    return ma - mb if ma >= mb else mb - ma


def float_cells_match(
    e: FloatCell, a: FloatCell, tol: FloatTolerance, width: Int
) -> Bool:
    """Does the actual cell `a` meet the expected cell `e`?"""
    if e.is_null or a.is_null:
        return e.is_null and a.is_null
    var a_nan = a.any_nan or float_is_nan(a.bits, width)
    if e.any_nan:
        return a_nan
    if float_is_nan(e.bits, width):
        # NaN by bits, never by value (NaN != NaN as a value).
        return (not a.any_nan) and a.bits == e.bits
    if a_nan:
        return False
    if float_is_inf(e.bits, width) or float_is_inf(a.bits, width):
        return e.bits == a.bits
    if float_is_zero(e.bits, width) and float_is_zero(a.bits, width):
        # -0.0 and 0.0 are different cells.
        return e.bits == a.bits
    if tol.is_rel:
        var ev = float_value(e.bits, width)
        var av = float_value(a.bits, width)
        var diff = abs(ev - av)
        var scale = max(abs(ev), abs(av))
        return diff <= tol.rel * scale
    return ulp_distance(e.bits, a.bits, width) <= UInt64(tol.ulps)


def _float_class(c: FloatCell, width: Int) -> Int:
    if c.is_null:
        return 0
    if c.any_nan:
        return 3
    if float_is_nan(c.bits, width):
        return 2
    return 1


def float_cells_order(a: FloatCell, b: FloatCell, width: Int) -> Int:
    """A total order for sorting rows before a multiset compare: NULL, then
    numbers by value (-0.0 before 0.0), then NaNs by bits, then bare NaN.
    Returns -1, 0 or 1."""
    var ca = _float_class(a, width)
    var cb = _float_class(b, width)
    if ca != cb:
        return -1 if ca < cb else 1
    if ca == 0 or ca == 3:
        return 0
    if ca == 2:
        if a.bits == b.bits:
            return 0
        return -1 if a.bits < b.bits else 1
    var sign = _sign_bit(width)
    var na = (a.bits & sign) != 0
    var nb = (b.bits & sign) != 0
    if na != nb:
        return -1 if na else 1
    var ma = a.bits & ~sign
    var mb = b.bits & ~sign
    if ma == mb:
        return 0
    var less = ma < mb
    if na:
        less = not less
    return -1 if less else 1
