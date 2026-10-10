# =============================================================================
# float32_bignum.mojo — fixed-width unsigned big integers for the float32
# JSON writer and reader (`proto3_json_float.mojo`, `float32_parse.mojo`)
# and the float64 reader (`float64_parse.mojo`).
# =============================================================================
#
# A value is `InlineArray[UInt32, N]`, little-endian 32-bit limbs. Every
# operation is exact as long as the result fits in N limbs; the callers size
# N from the largest value their algorithm can produce (each says its bound)
# and nothing here checks for overflow. No heap allocation.
# =============================================================================


def big_from[N: Int](x: UInt64) -> InlineArray[UInt32, N]:
    var b = InlineArray[UInt32, N](fill=UInt32(0))
    b[0] = UInt32(x & UInt64(0xFFFFFFFF))
    b[1] = UInt32(x >> UInt64(32))
    return b^


def big_is_zero[N: Int](a: InlineArray[UInt32, N]) -> Bool:
    for i in range(N):
        if a[i] != UInt32(0):
            return False
    return True


def big_shl[N: Int](mut a: InlineArray[UInt32, N], n: Int):
    """a *= 2^n (n >= 0)."""
    var limbs = n // 32
    var sh = n % 32
    for i in reversed(range(N)):
        var src = i - limbs
        var w = UInt64(0)
        if src >= 0:
            w = UInt64(a[src]) << UInt64(sh)
            if sh > 0 and src >= 1:
                w |= UInt64(a[src - 1]) >> UInt64(32 - sh)
        a[i] = UInt32(w & UInt64(0xFFFFFFFF))


def big_shr1[N: Int](mut a: InlineArray[UInt32, N]):
    """a //= 2."""
    for i in range(N):
        var hi = UInt32(0)
        if i + 1 < N:
            hi = a[i + 1] << UInt32(31)
        a[i] = (a[i] >> UInt32(1)) | hi


def big_mul_small[N: Int](mut a: InlineArray[UInt32, N], m: UInt32):
    var carry = UInt64(0)
    for i in range(N):
        var t = UInt64(a[i]) * UInt64(m) + carry
        a[i] = UInt32(t & UInt64(0xFFFFFFFF))
        carry = t >> UInt64(32)


def big_add_small[N: Int](mut a: InlineArray[UInt32, N], x: UInt32):
    var carry = UInt64(x)
    for i in range(N):
        if carry == UInt64(0):
            return
        var t = UInt64(a[i]) + carry
        a[i] = UInt32(t & UInt64(0xFFFFFFFF))
        carry = t >> UInt64(32)


def big_mul_pow10[N: Int](mut a: InlineArray[UInt32, N], p: Int):
    """a *= 10^p (p >= 0)."""
    var left = p
    while left >= 9:
        big_mul_small(a, UInt32(1000000000))
        left -= 9
    while left > 0:
        big_mul_small(a, UInt32(10))
        left -= 1


def big_add[
    N: Int
](a: InlineArray[UInt32, N], b: InlineArray[UInt32, N]) -> InlineArray[
    UInt32, N
]:
    var out = InlineArray[UInt32, N](fill=UInt32(0))
    var carry = UInt64(0)
    for i in range(N):
        var t = UInt64(a[i]) + UInt64(b[i]) + carry
        out[i] = UInt32(t & UInt64(0xFFFFFFFF))
        carry = t >> UInt64(32)
    return out^


def big_sub[N: Int](mut a: InlineArray[UInt32, N], b: InlineArray[UInt32, N]):
    """a -= b; requires a >= b."""
    var borrow = UInt64(0)
    for i in range(N):
        var t = UInt64(a[i]) - UInt64(b[i]) - borrow
        a[i] = UInt32(t & UInt64(0xFFFFFFFF))
        borrow = (t >> UInt64(63)) & UInt64(1)


def big_cmp[N: Int](a: InlineArray[UInt32, N], b: InlineArray[UInt32, N]) -> Int:
    for i in reversed(range(N)):
        if a[i] != b[i]:
            return 1 if a[i] > b[i] else -1
    return 0
