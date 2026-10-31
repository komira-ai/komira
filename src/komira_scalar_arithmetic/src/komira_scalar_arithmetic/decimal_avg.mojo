"""AVG of an exact 128-bit total, as DuckDB computes it.

DuckDB's avg() (v1.5.6, `extension/core_functions/aggregate/algebraic/avg.cpp`)
keeps an exact total and finishes it one of two ways, by the physical type of
its input:

  * SMALLINT (and TINYINT, which binds to it) and DECIMAL(p <= 4), whose
    values are 16 bits wide: `IntegerAverageOperation::Finalize` (lines
    102-112): `double(total) / (double(count) * scale)`, all in double.
  * INTEGER, BIGINT, HUGEINT and DECIMAL(p > 4): `IntegerAverageOperationHugeint`
    and `HugeintAverageOperation` (lines 114-124 and 140-149):
    `Hugeint::Cast<long double>(total) / divident`, where `divident` is
    `GetAverageDivident<long double>` (lines 92-100): `long double(count)`,
    times `scale` for a DECIMAL. `scale` is the double
    `Hugeint::Cast<double>(10^s)` (`BindDecimalAvg`, lines 269-278), a
    `double`, widened to long double for the product. The quotient is stored
    to a `double`.

`long double` is the x87 extended format on x86-64: a 64-bit mantissa, every
operation rounded to nearest even. So the result of the second form is four
roundings: the total to 64 bits (`CastBigintToFloating`, `src/common/types/
hugeint.cpp` lines 649-661: the low word plus the high word times 2^64, one
rounding, and for a high word of -1 an exact negation), the product
`count * scale` to 64 bits, the quotient to 64 bits, and the quotient to 53
bits. A double division and a single conversion of the total differ from it in
the last bits once the total passes 2^53, and (through the second rounding)
now and then for a small total over a count past 2^11.

Mojo has no 80-bit float, so the roundings are done in integers. A rounded
value is `mant * 2^exp` with a 64-bit mantissa whose top bit is set. The
quotient of two such values is a 128-bit by 64-bit integer division with the
remainder kept for the round and sticky bits, which makes the rounding exact.

The result is the same on every platform. DuckDB on a platform whose long
double is only a double (arm64 macOS) answers the double division and does not
match this function there; the pinned DuckDB the tests compare with runs on
x86-64.
"""

from std.bit import count_leading_zeros
from std.memory import bitcast

from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import hugeint_to_float64

comptime U128 = SIMD[DType.uint128, 1]


@fieldwise_init
struct _Ld(Copyable, Movable):
    """`mant * 2^exp` with `mant` a 64-bit mantissa whose top bit is set: a
    nonzero x87 extended value."""

    var mant: UInt64
    var exp: Int


@always_inline
def _bit_length(a: U128) -> Int:
    """The bits of `a` (0 for 0)."""
    var hi = (a >> U128(64)).cast[DType.uint64]()
    if hi != 0:
        return 128 - Int(count_leading_zeros(hi))
    return 64 - Int(count_leading_zeros(a.cast[DType.uint64]()))


def _round64(a: U128, exp: Int) -> _Ld:
    """`a * 2^exp` (`a` nonzero) rounded to nearest even at a 64-bit mantissa."""
    var bl = _bit_length(a)
    if bl <= 64:
        # Exact: only normalize.
        var m = a.cast[DType.uint64]()
        var lz = Int(count_leading_zeros(m))
        return _Ld(m << UInt64(lz), exp - lz)
    var sh = bl - 64
    var m = a >> U128(sh)
    var rem = a - (m << U128(sh))
    var half = U128(1) << U128(sh - 1)
    if rem > half or (rem == half and (m & U128(1)) == U128(1)):
        m = m + U128(1)
    var e = exp + sh
    if (m >> U128(64)) != 0:
        # The mantissa carried out to 2^64: 2^63 at the next exponent.
        m = m >> U128(1)
        e += 1
    return _Ld(m.cast[DType.uint64](), e)


def _div64(n: _Ld, d: _Ld) -> _Ld:
    """`n / d` rounded to nearest even at a 64-bit mantissa.

    Both mantissas are in [2^63, 2^64), so the quotient of `n.mant * 2^64` by
    `d.mant` is in (2^63, 2^65): 64 bits (then the round bit is the first bit of
    the doubled remainder's quotient) or 65 (then it is the low bit).

    Two facts make the rounding a plain "up when the round bit is set":
      * There is no exact tie. A tie needs `n.mant * 2^65 = d.mant * (2q + 1)`
        (below 2^64) or `n.mant * 2^64 = d.mant * q` with `q` odd (above); with
        `d.mant = 2^a * m` for odd `m` and `a <= 63`, the power of two of the
        left side is at least 64 and that of the right side is `a`.
      * The rounding cannot carry out of 64 bits: a quotient within half a unit
        of 2^64 would need `n.mant >= 2 * d.mant - 1` (above 1) or
        `n.mant >= d.mant` (below 1), which two 64-bit mantissas of this range
        do not satisfy."""
    var num = U128(n.mant) << U128(64)
    var den = U128(d.mant)
    var q = num // den
    var r = num - q * den
    var e = n.exp - d.exp - 64
    var round_bit: Bool
    if (q >> U128(64)) != 0:
        round_bit = (q & U128(1)) == U128(1)
        q = q >> U128(1)
        e += 1
    else:
        round_bit = Bool((r << U128(1)) >= den)
    if round_bit:
        q = q + U128(1)
    return _Ld(q.cast[DType.uint64](), e)


def _to_double(x: _Ld) -> Float64:
    """`x` rounded to nearest even at a 53-bit mantissa. A quotient of an
    integer below 2^127 by one at most 2^64 * 10^38 is between 2^-190 and
    2^127, so the power of two below is a normal double."""
    var low = x.mant & UInt64(0x7FF)
    var m53 = x.mant >> UInt64(11)
    if low > UInt64(0x400) or (low == UInt64(0x400) and (m53 & UInt64(1)) == UInt64(1)):
        m53 = m53 + UInt64(1)
    var scale = bitcast[DType.float64](UInt64(x.exp + 11 + 1023) << UInt64(52))
    return m53.cast[DType.float64]() * scale


def _pow10(scale: Int) -> U128:
    """10^scale (`scale` in [0, 38])."""
    var r = U128(1)
    for _ in range(scale):
        r = r * U128(10)
    return r


def _avg_fast_path_applies(mag: U128, count: Int, scale: Int) -> Bool:
    """True when the plain double division is DuckDB's long double result.

    That holds when `mag < 2^53` and `count * 10^scale < 2^11` (so `scale <= 3`).
    Proof: the divisor `D = count * 10^scale` is an integer below 2^11 and the
    total `N = mag` an integer below 2^53, both exact in a double and in a
    64-bit mantissa, so the long double quotient is the correct rounding to 64
    bits of `x = N / D`, which is then rounded to 53 bits. That differs from one
    rounding of `x` to 53 bits only if the 64-bit rounding lands on a midpoint
    `M` of two doubles while `x != M` (a tie broken the other way). With `x` in
    [2^e, 2^(e+1)) (`e <= 52`), `M = (2j + 1) * 2^(e - 53)`, and
    `x - M = (N * 2^(53 - e) - (2j + 1) * D) / (D * 2^(53 - e))` has a nonzero
    integer numerator, so `|x - M| >= 2^(e - 53) / D`. The 64-bit rounding moves
    `x` by at most `2^(e - 64)`, and `2^(e - 53) / D > 2^(e - 64)` exactly when
    `D < 2^11`: it cannot reach `M`. At `D = 2^11 + 3` it can: 2473 / 2051 (the
    unit test of this module)."""
    if scale > 3 or count >= 2048 or Bool(mag >= U128(9007199254740992)):
        return False
    var d = count
    for _ in range(scale):
        d = d * 10
    return d < 2048


def _avg_core(total: I128, count: Int, scale: Int, allow_fast: Bool) -> Float64:
    """DuckDB's long double average of `total` over `count * 10^scale`. A zero
    total or a count below 1 (the caller answers NULL for no rows) is 0.0."""
    if total == 0 or count <= 0:
        return Float64(0.0)
    var neg = total < 0
    var mag = total.cast[DType.uint128]()
    if neg:
        mag = U128(0) - mag
    var r: Float64
    if allow_fast and _avg_fast_path_applies(mag, count, scale):
        var d = Float64(count)
        for _ in range(scale):
            d = d * 10.0
        r = mag.cast[DType.float64]() / d
    else:
        var n = _round64(mag, 0)
        # The scale as a double (`Hugeint::Cast<double>(10^scale)`) is the
        # integer ms * 2^es with a 53-bit ms.
        var sbits = bitcast[DType.uint64](hugeint_to_float64(_pow10(scale).cast[DType.int128]()))
        var ms = (sbits & UInt64(0xFFFFFFFFFFFFF)) | (UInt64(1) << UInt64(52))
        var es = Int((sbits >> UInt64(52)) & UInt64(0x7FF)) - 1075
        var d = _round64(U128(count) * U128(ms), es)
        r = _to_double(_div64(n, d))
    if neg:
        r = -r
    return r


def _avg_long_double(total: I128, count: Int, scale: Int) -> Float64:
    return _avg_core(total, count, scale, True)


def _avg_emulated(total: I128, count: Int, scale: Int) -> Float64:
    """The emulation alone, with no fast path (the tests compare the two)."""
    return _avg_core(total, count, scale, False)


def _avg_double(total: I128, count: Int, scale: Int) -> Float64:
    """DuckDB's average of a 16-bit-wide input: `double(total) / (double(count)
    * 10^scale)`, the total an INT64 (a sum of 16-bit values over fewer than
    2^47 rows)."""
    if count <= 0:
        return Float64(0.0)
    var d = Float64(count)
    for _ in range(scale):
        d = d * 10.0
    return total.cast[DType.int64]().cast[DType.float64]() / d


def avg_decimal_float64(total: I128, count: Int, precision: Int, scale: Int) -> Float64:
    """DuckDB's avg() of a DECIMAL(`precision`, `scale`) column whose values
    sum to the unscaled `total` over `count` (>= 1) rows: a DOUBLE.

    A DECIMAL of 4 digits or fewer is stored in 16 bits and averaged in double;
    a wider one in 80-bit long double (this module's header). `count < 1` is
    0.0: the caller answers NULL for no rows."""
    if precision <= 4:
        return _avg_double(total, count, scale)
    return _avg_long_double(total, count, scale)


def avg_integer_float64(total: I128, count: Int, bits: Int) -> Float64:
    """DuckDB's avg() of an integer column of `bits` bits (8, 16, 32 or 64)
    whose values sum to `total` over `count` (>= 1) rows: a DOUBLE.

    A 16-bit column or narrower is averaged in double, a wider one in 80-bit
    long double (this module's header). `count < 1` is 0.0: the caller answers
    NULL for no rows."""
    if bits <= 16:
        return _avg_double(total, count, 0)
    return _avg_long_double(total, count, 0)
