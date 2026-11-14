# Exact decimal numbers as text, for the value checks.
#
# A decimal here is written `[-]digits[.digits]`. Its canonical form has no
# leading zeros in the integer part (`0` for none), no trailing zeros in the
# fraction, no point when the fraction is empty and no sign on zero, so two
# texts of one value (`123.40`, `123.4`) have one canonical form and equal
# values are equal texts. At most 38 fractional digits are accepted (DuckDB's
# widest scale), any number of integer digits.
#
# `ExactSum` adds canonical decimals without rounding and without a width
# limit: the magnitude is held as base 10^9 limbs of the value times 10^38.
# Equal sums have equal texts, whatever order the terms were added in.

comptime MAX_FRACTION_DIGITS: Int = 38
comptime _BASE: Int = 1000000000
comptime _LIMB_DIGITS: Int = 9


struct DecimalParts(Copyable, Movable):
    """A decimal split into its sign and canonical digit runs."""

    var negative: Bool
    var int_digits: String
    var frac_digits: String

    def __init__(out self, negative: Bool, var int_digits: String, var frac_digits: String):
        self.negative = negative
        self.int_digits = int_digits^
        self.frac_digits = frac_digits^

    def is_zero(self) -> Bool:
        return self.int_digits == "0" and self.frac_digits.byte_length() == 0


def split_decimal(text: String) raises -> DecimalParts:
    """The parts of `text`. Raises when it is not `[-]digits[.digits]` or has
    more than 38 fractional digits after its trailing zeros are dropped."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var negative = False
    if i < n and b[i] == UInt8(45):
        negative = True
        i += 1
    var int_start = i
    while i < n and b[i] >= UInt8(48) and b[i] <= UInt8(57):
        i += 1
    var int_end = i
    if int_end == int_start:
        raise Error(String("not a decimal number: ") + text)
    var frac_start = i
    var frac_end = i
    if i < n and b[i] == UInt8(46):
        i += 1
        frac_start = i
        while i < n and b[i] >= UInt8(48) and b[i] <= UInt8(57):
            i += 1
        frac_end = i
        if frac_end == frac_start:
            raise Error(String("not a decimal number: ") + text)
    if i != n:
        raise Error(String("not a decimal number: ") + text)
    while int_start < int_end - 1 and b[int_start] == UInt8(48):
        int_start += 1
    while frac_end > frac_start and b[frac_end - 1] == UInt8(48):
        frac_end -= 1
    if frac_end - frac_start > MAX_FRACTION_DIGITS:
        raise Error(String("a decimal with more than 38 fractional digits: ") + text)
    var int_digits = String(text[byte=int_start:int_end])
    var frac_digits = String(text[byte=frac_start:frac_end])
    var zero = int_digits == "0" and frac_digits.byte_length() == 0
    return DecimalParts(negative and not zero, int_digits^, frac_digits^)


def canonical_decimal(text: String) raises -> String:
    """`text` in canonical form."""
    var p = split_decimal(text)
    var out = String("")
    if p.negative:
        out += String("-")
    out += p.int_digits
    if p.frac_digits.byte_length() > 0:
        out += String(".") + p.frac_digits
    return out^


def _digits_order(x: String, y: String) -> Int:
    """-1, 0 or 1 by the bytes of two digit runs (shorter first when one is a
    prefix of the other)."""
    var a = x.as_bytes()
    var b = y.as_bytes()
    var n = len(a)
    if len(b) < n:
        n = len(b)
    for i in range(n):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    if len(a) == len(b):
        return 0
    return -1 if len(a) < len(b) else 1


def compare_parts(a: DecimalParts, b: DecimalParts) -> Int:
    """-1, 0 or 1 for the order of two canonical decimals."""
    if a.negative != b.negative:
        return -1 if a.negative else 1
    var c = 0
    if a.int_digits.byte_length() != b.int_digits.byte_length():
        c = -1 if a.int_digits.byte_length() < b.int_digits.byte_length() else 1
    else:
        c = _digits_order(a.int_digits, b.int_digits)
        if c == 0:
            c = _digits_order(a.frac_digits, b.frac_digits)
    return -c if a.negative else c


def compare_decimals(a: String, b: String) raises -> Int:
    """-1, 0 or 1 for the order of the values of two decimal texts."""
    return compare_parts(split_decimal(a), split_decimal(b))


def _limbs_of(p: DecimalParts) -> List[Int]:
    """The magnitude times 10^38 as base 10^9 limbs, least significant first,
    without high zero limbs."""
    var digits = p.int_digits + p.frac_digits
    for _ in range(MAX_FRACTION_DIGITS - p.frac_digits.byte_length()):
        digits += String("0")
    var b = digits.as_bytes()
    var out = List[Int]()
    var end = len(b)
    while end > 0:
        var start = end - _LIMB_DIGITS
        if start < 0:
            start = 0
        var v = 0
        for k in range(start, end):
            v = v * 10 + (Int(b[k]) - 48)
        out.append(v)
        end = start
    while len(out) > 0 and out[len(out) - 1] == 0:
        _ = out.pop()
    return out^


def _limbs_order(a: List[Int], b: List[Int]) -> Int:
    if len(a) != len(b):
        return -1 if len(a) < len(b) else 1
    var i = len(a) - 1
    while i >= 0:
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
        i -= 1
    return 0


def _limbs_add(a: List[Int], b: List[Int]) -> List[Int]:
    var out = List[Int]()
    var carry = 0
    var n = len(a)
    if len(b) > n:
        n = len(b)
    for i in range(n):
        var v = carry
        if i < len(a):
            v += a[i]
        if i < len(b):
            v += b[i]
        if v >= _BASE:
            v -= _BASE
            carry = 1
        else:
            carry = 0
        out.append(v)
    if carry > 0:
        out.append(carry)
    return out^


def _limbs_sub(a: List[Int], b: List[Int]) -> List[Int]:
    """`a - b` for `a >= b`."""
    var out = List[Int]()
    var borrow = 0
    for i in range(len(a)):
        var v = a[i] - borrow
        if i < len(b):
            v -= b[i]
        if v < 0:
            v += _BASE
            borrow = 1
        else:
            borrow = 0
        out.append(v)
    while len(out) > 0 and out[len(out) - 1] == 0:
        _ = out.pop()
    return out^


struct ExactSum(Copyable, Movable):
    """A running sum of decimals that never rounds and never overflows."""

    var negative: Bool
    var limbs: List[Int]

    def __init__(out self):
        self.negative = False
        self.limbs = List[Int]()

    def add(mut self, text: String) raises:
        """Add the decimal `text` (any form `split_decimal` takes)."""
        var p = split_decimal(text)
        var term = _limbs_of(p)
        if len(term) == 0:
            return
        if len(self.limbs) == 0:
            self.negative = p.negative
            self.limbs = term^
            return
        if self.negative == p.negative:
            self.limbs = _limbs_add(self.limbs, term)
            return
        var c = _limbs_order(self.limbs, term)
        if c == 0:
            self.negative = False
            self.limbs = List[Int]()
        elif c > 0:
            self.limbs = _limbs_sub(self.limbs, term)
        else:
            self.limbs = _limbs_sub(term, self.limbs)
            self.negative = p.negative

    def text(self) -> String:
        """The sum in canonical form."""
        if len(self.limbs) == 0:
            return String("0")
        var digits = String("")
        var top = len(self.limbs) - 1
        digits += String(self.limbs[top])
        var i = top - 1
        while i >= 0:
            var part = String(self.limbs[i])
            for _ in range(_LIMB_DIGITS - part.byte_length()):
                digits += String("0")
            digits += part
            i -= 1
        while digits.byte_length() < MAX_FRACTION_DIGITS + 1:
            digits = String("0") + digits
        var cut = digits.byte_length() - MAX_FRACTION_DIGITS
        var int_part = String(digits[byte=0:cut])
        var frac_part = String(digits[byte=cut : digits.byte_length()])
        var ib = int_part.as_bytes()
        var lead = 0
        while lead < len(ib) - 1 and ib[lead] == UInt8(48):
            lead += 1
        var int_clean = String(int_part[byte=lead : int_part.byte_length()])
        var fb = frac_part.as_bytes()
        var fe = len(fb)
        while fe > 0 and fb[fe - 1] == UInt8(48):
            fe -= 1
        var out = String("")
        if self.negative:
            out += String("-")
        out += int_clean
        if fe > 0:
            out += String(".") + String(frac_part[byte=0:fe])
        return out^
