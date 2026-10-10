# =============================================================================
# komira_plan_harness/_bignat.mojo -- a small unsigned big integer.
# =============================================================================
#
# Only what canon needs to decide float questions exactly, never by a
# rounding library: is a decimal exactly representable as float16/32/64, and
# does a decimal round to a given bit pattern. Both come down to comparing
# D * 10^E with A * 2^G, which is integer arithmetic once both sides are
# scaled by powers of 2 and 5. It also prints a decimal128/decimal256
# magnitude, so canon does not depend on Int128/Int256 formatting.
#
# Limbs are base 2^32, little-endian, with no zero limb at the top (zero is
# the empty list).
# =============================================================================

comptime _MASK32: UInt64 = 0xFFFFFFFF
# 5^13 is the largest power of five below 2^32.
comptime _POW5_13: UInt32 = 1220703125


struct BigNat(Copyable, Movable):
    """An unsigned integer of any size; see the module header."""

    var limbs: List[UInt32]

    def __init__(out self):
        """Zero."""
        self.limbs = List[UInt32]()

    @staticmethod
    def from_u64(v: UInt64) -> BigNat:
        var b = BigNat()
        if v != 0:
            b.limbs.append(UInt32(v & _MASK32))
            var hi = v >> 32
            if hi != 0:
                b.limbs.append(UInt32(hi))
        return b^

    @staticmethod
    def from_u32_limbs(var limbs: List[UInt32]) -> BigNat:
        """From little-endian base-2^32 limbs (zero limbs at the top are
        dropped)."""
        var b = BigNat()
        b.limbs = limbs^
        b._trim()
        return b^

    def _trim(mut self):
        while len(self.limbs) > 0 and self.limbs[len(self.limbs) - 1] == 0:
            _ = self.limbs.pop()

    def is_zero(self) -> Bool:
        return len(self.limbs) == 0

    def is_even(self) -> Bool:
        return len(self.limbs) == 0 or (self.limbs[0] & 1) == 0

    def bit_length(self) -> Int:
        var n = len(self.limbs)
        if n == 0:
            return 0
        var top = self.limbs[n - 1]
        var bits = 0
        while top != 0:
            bits += 1
            top >>= 1
        return (n - 1) * 32 + bits

    def low_u64(self) -> UInt64:
        """The low 64 bits (the whole value when bit_length() <= 64)."""
        var v: UInt64 = 0
        if len(self.limbs) > 0:
            v = UInt64(self.limbs[0])
        if len(self.limbs) > 1:
            v |= UInt64(self.limbs[1]) << 32
        return v

    def mul_small(mut self, m: UInt32):
        if m == 0:
            self.limbs = List[UInt32]()
            return
        var carry: UInt64 = 0
        for i in range(len(self.limbs)):
            var p = UInt64(self.limbs[i]) * UInt64(m) + carry
            self.limbs[i] = UInt32(p & _MASK32)
            carry = p >> 32
        if carry != 0:
            self.limbs.append(UInt32(carry))

    def add_small(mut self, a: UInt32):
        var carry = UInt64(a)
        var i = 0
        while carry != 0:
            if i == len(self.limbs):
                self.limbs.append(UInt32(carry))
                return
            var s = UInt64(self.limbs[i]) + carry
            self.limbs[i] = UInt32(s & _MASK32)
            carry = s >> 32
            i += 1

    def divmod_small(mut self, d: UInt32) -> UInt32:
        """Divide in place by `d` (> 0); return the remainder."""
        var rem: UInt64 = 0
        var i = len(self.limbs) - 1
        while i >= 0:
            var cur = (rem << 32) | UInt64(self.limbs[i])
            self.limbs[i] = UInt32(cur // UInt64(d))
            rem = cur % UInt64(d)
            i -= 1
        self._trim()
        return UInt32(rem)

    def mul_pow5(mut self, k: Int):
        var left = k
        while left >= 13:
            self.mul_small(_POW5_13)
            left -= 13
        var m: UInt32 = 1
        for _ in range(left):
            m *= 5
        if m != 1:
            self.mul_small(m)

    def shl(mut self, k: Int):
        """Multiply by 2^k."""
        if k <= 0 or self.is_zero():
            return
        var words = k // 32
        var bits = k % 32
        if bits != 0:
            var carry: UInt32 = 0
            for i in range(len(self.limbs)):
                var v = self.limbs[i]
                self.limbs[i] = (v << UInt32(bits)) | carry
                carry = v >> UInt32(32 - bits)
            if carry != 0:
                self.limbs.append(carry)
        if words > 0:
            var shifted = List[UInt32](capacity=len(self.limbs) + words)
            for _ in range(words):
                shifted.append(0)
            for i in range(len(self.limbs)):
                shifted.append(self.limbs[i])
            self.limbs = shifted^

    def shr1(mut self):
        """Divide by 2 (truncating)."""
        _ = self.divmod_small(2)

    def cmp(self, other: BigNat) -> Int:
        """-1, 0 or 1 as self <, ==, > other."""
        var a = len(self.limbs)
        var b = len(other.limbs)
        if a != b:
            return -1 if a < b else 1
        var i = a - 1
        while i >= 0:
            var x = self.limbs[i]
            var y = other.limbs[i]
            if x != y:
                return -1 if x < y else 1
            i -= 1
        return 0

    def to_decimal(self) -> String:
        """Base-10 digits, no sign, no leading zero ("0" for zero)."""
        if self.is_zero():
            return String("0")
        var work = self.copy()
        var chunks = List[UInt32]()
        while not work.is_zero():
            chunks.append(work.divmod_small(1000000000))
        var res = String(chunks[len(chunks) - 1])
        var i = len(chunks) - 2
        while i >= 0:
            var s = String(chunks[i])
            for _ in range(9 - s.byte_length()):
                res += "0"
            res += s
            i -= 1
        return res


def cmp_dec_dyadic(d: BigNat, e10: Int, a: BigNat, g2: Int) -> Int:
    """Compare D * 10^e10 with A * 2^g2 (both non-negative): -1, 0 or 1.

    Written as D * 5^e10 * 2^e10 against A * 2^g2: the power of five moves to
    whichever side keeps it a whole number, then the side with the smaller
    power of two is shifted up to the other's.
    """
    var lhs = d.copy()
    var rhs = a.copy()
    if e10 >= 0:
        lhs.mul_pow5(e10)
    else:
        rhs.mul_pow5(-e10)
    if e10 < g2:
        rhs.shl(g2 - e10)
    else:
        lhs.shl(e10 - g2)
    return lhs.cmp(rhs)
