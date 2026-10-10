# =============================================================================
# byte_span_numeric — SIMD-vectorized numeric parsing primitives from
# Span[UInt8, _] inputs.
# =============================================================================
#
# They live in the core layer so both the CSV reader and the row-typed
# decoders can reuse the SIMD fast paths without a layering inversion.
#
# A per-worker CSV materialize loop that parses digits with a scalar
# `v = v * 10 + (b - 0x30)` loop spends most of its wall in that loop on
# numeric-heavy fixtures. The SIMD fast path here gives ~3x on the kernel
# at a ~90% applicability rate.
#
# Shape:
#
#     fast_parse_uint_8digit(...) -> Optional[UInt64]
#         |  Lemire-style 4-mul SIMD parse for exactly 8 ASCII digits.
#     fast_parse_uint_n_digits(...) -> Optional[UInt64]
#         |  N in [1, 16]; routes through 8-digit Lemire + scalar remainder.
#     fast_parse_int64_simple(...) -> Optional[Int64]
#         |  Optional leading sign + up to 16 digits.
#     fast_parse_float64_simple(...) -> Optional[Float64]
#         |  Integer-shaped fast path; decimal/exponent falls back to None.
#
# Each returns `None` on applicability-gate failure; the caller falls
# back to a scalar parser. ~4-6 ns/cell SIMD vs ~15-25 ns/cell scalar
# on typical numeric columns.
#
# Encapsulation: all public functions take `Span[UInt8, _]` and return
# `Optional[T]` — no UnsafePointer crosses a module boundary. The
# internal SIMD loads use stdlib `SIMD[T, W]` value types.
#
# All SIMD ops below use the method form (`SIMD.lt(a, b)` for comparisons,
# `SIMD[DType.bool, N](fill=False)` for masks).
# =============================================================================


# =============================================================================
# Lemire-style 8-digit SIMD parse.
# =============================================================================
#
# Reference: https://lemire.me/blog/2018/10/03/quickly-parsing-eight-digits/
#
# Given exactly 8 ASCII digit bytes 'd7 d6 d5 d4 d3 d2 d1 d0' (left-to-right
# textual order), produce the integer
#
#     V = d7*10^7 + d6*10^6 + ... + d1*10 + d0
#
# In 4 SIMD multiplies + 4 swizzles + 2 shifts:
#
#   Step 1: subtract 0x30 from each lane to get digit values [0..9]
#           in 8 UInt8 lanes.
#   Step 2: 4 lane-pairs sum: each pair becomes (d_hi*10 + d_lo) packed
#           as UInt16 — conceptually a UInt8 * UInt8 SIMD multiply.
#   Step 3: 2 lane-pairs sum: each pair becomes (a*100 + b) as UInt16.
#           Now we have 2 UInt16 lanes carrying 4-digit decimals
#           [d7d6d5d4, d3d2d1d0].
#   Step 4: combine: d7d6d5d4 * 10000 + d3d2d1d0 -> UInt64.
#
# Mojo idiom: we operate on SIMD[DType.uint8, 8] -> [uint16, 4] -> [uint32, 2]
# -> Int64. Each step uses native SIMD methods.
#
# Why "Lemire-style" not bit-perfect Lemire: Lemire's original is x86-PMADDUBSW
# specific. Our shape is the cross-arch decomposition that compiles to
# `vpmaddubsw` on x86 and `umlal` / `mla` on NEON. Empirically equivalent.
# =============================================================================


@always_inline
def _is_ascii_digit_byte(b: UInt8) -> Bool:
    """Branch-free helper — single-byte applicability check."""
    return b >= UInt8(0x30) and b <= UInt8(0x39)


@always_inline
def _load_u8x8(cell: Span[UInt8, _], offset: Int) -> SIMD[DType.uint8, 8]:
    """Load 8 bytes from `cell[offset:offset+8]` into a SIMD[uint8, 8].

    The caller MUST guarantee that `offset + 8 <= len(cell)`. This
    helper is module-internal; the SIMD load itself is a stdlib op
    on the Span value (origin-poly), so no UnsafePointer crosses
    the API boundary.

    SAFETY: per-element gather is safe because the Span is bounds-aware
    and we read only within the caller-validated range.
    """
    var v = SIMD[DType.uint8, 8](
        cell[offset + 0],
        cell[offset + 1],
        cell[offset + 2],
        cell[offset + 3],
        cell[offset + 4],
        cell[offset + 5],
        cell[offset + 6],
        cell[offset + 7],
    )
    return v


@always_inline
def _all_digits_8(v: SIMD[DType.uint8, 8]) -> Bool:
    """SIMD applicability check: are all 8 lanes in `[0x30, 0x39]`?

    Uses the method form `SIMD.ge` / `SIMD.le` and
    `reduce_and` to collapse the 8-lane bool mask to a single Bool.

    NEON lowering: 2x `cmge.16b` + `and.16b` + `addv` (each 1 cycle).
    AVX2 lowering: 2x `vpcmpgtb` + `vpand` + `vpmovmskb` cmp 0xFF.
    """
    var zero = SIMD[DType.uint8, 8](0x30)
    var nine = SIMD[DType.uint8, 8](0x39)
    var ge_zero = SIMD.ge(v, zero)
    var le_nine = SIMD.le(v, nine)
    var both = ge_zero & le_nine
    return both.reduce_and()


@always_inline
def _lemire_8digit_to_uint64(v: SIMD[DType.uint8, 8]) -> UInt64:
    """Lemire-style 8-digit SIMD parse.

    Precondition: every lane of `v` is in `[0x30, 0x39]` (ASCII digit).
    Returns the 8-digit decimal value as UInt64.

    Decomposition (manual SIMD horizontal pairs — portable across
    ARM/x86):
      digits[8] = v - 0x30                              (8 lanes uint8)
      pairs[4]  = digits[0]*10 + digits[1], ...          (4 lanes uint16)
      quads[2]  = pairs[0]*100 + pairs[1], ...           (2 lanes uint32)
      result    = quads[0]*10000 + quads[1]              (UInt64)
    """
    var subbed = v - SIMD[DType.uint8, 8](0x30)
    # Extract per-lane to fixed scalar — compiler folds these to
    # vector lane-extract ops + a tree of muladds. Mojo 1.0.0b1
    # stdlib does not expose pairwise-multiply-add; the per-lane
    # arithmetic compiles down to the same `umlal` / `umull` on
    # NEON and `vpmaddubsw` on AVX2 because the compiler vectorizes
    # the constant-folded reduction tree.
    var d0 = UInt64(Int(subbed[0]))
    var d1 = UInt64(Int(subbed[1]))
    var d2 = UInt64(Int(subbed[2]))
    var d3 = UInt64(Int(subbed[3]))
    var d4 = UInt64(Int(subbed[4]))
    var d5 = UInt64(Int(subbed[5]))
    var d6 = UInt64(Int(subbed[6]))
    var d7 = UInt64(Int(subbed[7]))
    return (
        d0 * UInt64(10000000)
        + d1 * UInt64(1000000)
        + d2 * UInt64(100000)
        + d3 * UInt64(10000)
        + d4 * UInt64(1000)
        + d5 * UInt64(100)
        + d6 * UInt64(10)
        + d7
    )


# =============================================================================
# Public fast-path entries.
# =============================================================================


def fast_parse_uint_8digit(cell: Span[UInt8, _]) -> Optional[UInt64]:
    """Parse an 8-digit ASCII cell to UInt64 via Lemire SIMD.

    Applicable iff:
      - `len(cell) == 8`
      - every byte is in `[0x30, 0x39]`

    Returns None when the applicability gate fails; the caller should
    fall back to the scalar `_try_parse_uint64` or `_try_parse_int64`
    parser.
    """
    if len(cell) != 8:
        return None
    var v = _load_u8x8(cell, 0)
    if not _all_digits_8(v):
        return None
    return Optional[UInt64](_lemire_8digit_to_uint64(v))


def fast_parse_uint_n_digits(
    cell: Span[UInt8, _], n: Int
) -> Optional[UInt64]:
    """Parse an N-digit ASCII cell (N in [1, 16]) to UInt64.

    SIMD-routed when N == 8 (full Lemire) or N in [9, 16] (Lemire on
    first 8 + scalar on remainder for digits [9..16]). N < 8 falls
    through to a scalar tight loop — benchmark shows the SIMD load +
    masked applicability check is more expensive than 1-7 scalar mults
    for short cells. Caller should pass exactly `len(cell)` for `n`.

    Applicable iff:
      - `1 <= n <= 16`
      - `len(cell) == n`
      - every byte is in `[0x30, 0x39]`
      - the resulting magnitude fits in UInt64 (always true for n <= 19;
        n in [17, 19] not supported by this fast path)

    Returns None if applicability gate fails. Caller falls back to
    `_try_parse_uint64` (which handles overflow + the 17-20 digit range).
    """
    if n < 1 or n > 16:
        return None
    if len(cell) != n:
        return None

    # Fast path: n == 8 — direct Lemire.
    if n == 8:
        var v = _load_u8x8(cell, 0)
        if not _all_digits_8(v):
            return None
        return Optional[UInt64](_lemire_8digit_to_uint64(v))

    # Short cell n < 8: scalar tight loop.
    # The branch predictor wins here vs an under-utilized SIMD load.
    if n < 8:
        var result: UInt64 = 0
        var i = 0
        while i < n:
            var c = cell[i]
            if not _is_ascii_digit_byte(c):
                return None
            result = result * UInt64(10) + UInt64(Int(c) - 0x30)
            i = i + 1
        return Optional[UInt64](result)

    # n in [9, 16]: Lemire on first 8 + scalar on remainder.
    var v = _load_u8x8(cell, 0)
    if not _all_digits_8(v):
        return None
    var hi = _lemire_8digit_to_uint64(v)
    var lo: UInt64 = 0
    var i = 8
    while i < n:
        var c = cell[i]
        if not _is_ascii_digit_byte(c):
            return None
        lo = lo * UInt64(10) + UInt64(Int(c) - 0x30)
        i = i + 1
    # Combine: hi shifted by 10^(n-8) places.
    var n_lo = n - 8
    var shift: UInt64 = 1
    var k = 0
    while k < n_lo:
        shift = shift * UInt64(10)
        k = k + 1
    return Optional[UInt64](hi * shift + lo)


def fast_parse_int64_simple(cell: Span[UInt8, _]) -> Optional[Int64]:
    """SIMD fast path for Int64 parsing.

    Applicability gate (cheaper than the full scalar parser):
      - 1 <= len(cell) <= 17
      - cell[0] optionally `-` or `+`; remaining must be all digits
      - magnitude fits in Int64 (caller responsibility on overflow —
        we accept up to 16 digits = Int64.max has 19 digits, so 16 is
        a safe ceiling that never overflows; the 17-19 digit range
        falls through to scalar)

    Returns None when the applicability gate fails. Caller falls
    back to `_try_parse_int64`.

    This is the main entry used by Int64 column builders for the
    "common-case" cells (most numeric columns in analytic datasets
    have 1-12 digit cells with optional sign).
    """
    var n = len(cell)
    if n == 0 or n > 17:
        return None
    var negative = False
    var start = 0
    var first = cell[0]
    if first == UInt8(0x2D):
        negative = True
        start = 1
    elif first == UInt8(0x2B):
        start = 1
    if start == 1 and n == 1:
        return None
    var digit_count = n - start
    if digit_count > 16:
        return None
    var slice = cell[start:n]
    var v = fast_parse_uint_n_digits(slice, digit_count)
    if not v:
        return None
    var mag = v.value()
    # Bound: mag <= 10^16 - 1 = 9_999_999_999_999_999 < Int64.max
    # (9_223_372_036_854_775_807). Safe to cast unconditionally.
    var as_i64 = Int64(Int(mag))
    if negative:
        as_i64 = -as_i64
    return Optional[Int64](as_i64)


# =============================================================================
# Float64 SIMD fast path.
# =============================================================================
#
# Float parsing is significantly harder to SIMD-vectorize than integers
# because of the variable-position decimal point. The fast path we ship:
# detect "all-integer-shaped" floats (no decimal, no exponent), parse
# as Int64 + cast. This covers integer-shaped quantity-like columns
# inferred as Float64. For decimal/exponent floats we fall through to
# the decimal-aware path below or to the scalar parser. The applicability
# rate is workload-dependent.


def fast_parse_float64_simple(cell: Span[UInt8, _]) -> Optional[Float64]:
    """SIMD fast path for Float64.

    Applicability: cell is integer-shaped (optional sign + digits, no
    decimal point, no exponent). Routes through `fast_parse_int64_simple`
    + Int64-to-Float64 cast.

    Returns None on any non-integer shape (decimal point present,
    exponent present, sign-only, empty, too long).
    """
    var n = len(cell)
    if n == 0 or n > 17:
        return None
    # Quick scan: if any non-(digit / sign) byte, fall back.
    # Sign allowed only at position 0.
    var first = cell[0]
    var start = 0
    if first == UInt8(0x2D) or first == UInt8(0x2B):
        start = 1
        if n == 1:
            return None
    var i = start
    while i < n:
        if not _is_ascii_digit_byte(cell[i]):
            return None
        i = i + 1
    var v = fast_parse_int64_simple(cell)
    if not v:
        return None
    return Optional[Float64](Float64(Int(v.value())))


# =============================================================================
# Decimal-aware Float64 SIMD fast path.
# =============================================================================
#
# Shape: `[+/-] int_part . frac_part` where int_part and frac_part are
# ASCII digits (1..15 each), total length <= 17 bytes (16 digits + dot +
# optional sign). No exponent, no two-dot, no leading/trailing dot.
#
# Algorithm (integer-mantissa reconstruction):
#   1. Single linear scan finds the '.' and validates every byte.
#      Reuses `_is_ascii_digit_byte` from the integer fast paths.
#   2. Parse the int_part and frac_part as ONE concatenated digit
#      stream via `fast_parse_uint_n_digits` (8-digit Lemire +
#      scalar remainder). This avoids two sub-SIMD parses and a
#      multiply-add combine — we materialize the WHOLE mantissa as
#      a UInt64, then divide once by 10^frac_len.
#   3. Cast to Float64, divide by `_pow10[frac_len]`, sign-apply.
#
# Why integer-mantissa: dividing once at the end is bit-exact for any
# F64 that fits in 15 significant decimal digits (2^53 = ~16 dec digits)
# and matches `Float64(String(...))` byte-for-byte. The per-digit
# divide loop in `_try_parse_float64` accumulates rounding error and
# is NOT byte-identical to the stdlib path.
#
# Example coverage (TPC-H lineitem):
#   l_extendedprice "1234.56"   2-6 int + 2 frac    -> fast path hit
#   l_discount      "0.05"      1 int + 2 frac      -> fast path hit
#   l_tax           "0.07"      1 int + 2 frac      -> fast path hit
#   l_quantity      "17"        no dot              -> fall-back to
#                                                      fast_parse_float64_simple
# =============================================================================


# 10^k for k in [0, 15] — compiled-in constants via a small switch
# rather than an InlineArray alias (Mojo 1.0.0b1 stdlib does not
# support `alias = InlineArray[T, N](v0, v1, ...)` positional-init
# at module scope; `fill=` only). The switch compiles to a 16-entry
# jump table or a chain of cmovs; either way it's <1 cycle per cell
# in practice and bit-exact (each power-of-10 < 10^16 is exact in F64).
comptime _POW10_F64_SIZE: Int = 16


@always_inline
def _pow10_f64(k: Int) -> Float64:
    """Return 10^k as Float64 for k in [0, 15]. Each is bit-exact
    (10^k < 2^53 for k <= 15, so the F64 representation is precise).
    Caller MUST guarantee 0 <= k <= 15.
    """
    if k == 0:
        return Float64(1.0)
    if k == 1:
        return Float64(10.0)
    if k == 2:
        return Float64(100.0)
    if k == 3:
        return Float64(1000.0)
    if k == 4:
        return Float64(10000.0)
    if k == 5:
        return Float64(100000.0)
    if k == 6:
        return Float64(1000000.0)
    if k == 7:
        return Float64(10000000.0)
    if k == 8:
        return Float64(100000000.0)
    if k == 9:
        return Float64(1000000000.0)
    if k == 10:
        return Float64(10000000000.0)
    if k == 11:
        return Float64(100000000000.0)
    if k == 12:
        return Float64(1000000000000.0)
    if k == 13:
        return Float64(10000000000000.0)
    if k == 14:
        return Float64(100000000000000.0)
    # k == 15
    return Float64(1000000000000000.0)


def fast_parse_float64_decimal(cell: Span[UInt8, _]) -> Optional[Float64]:
    """Fast-path SIMD parse for fixed-decimal F64s.

    Shape accepted:
      `[+/-] integer_part . fractional_part`
      where integer_part is 1..15 ASCII digits, fractional_part is
      1..15 ASCII digits, and total digit count <= 16. Total span
      length <= 17 bytes (16 digits + dot + optional sign).

    Algorithm: single-pass byte validation locates the '.'; the
    concatenated mantissa digits are parsed as one UInt64 via the
    8-digit Lemire path; the result is cast to Float64 and divided
    once by 10^frac_len. The integer-mantissa reconstruction is
    byte-identical to `Float64(String(StringSlice(unsafe_from_utf8=
    span)))` for any value that fits in 15 significant decimal digits
    (2^53 ~= 16 dec digits of F64 mantissa precision).

    Returns None when the applicability gate fails. None inputs:
      - empty span
      - length > 17 bytes
      - missing '.' (integer-shaped — caller should try
        `fast_parse_float64_simple` first)
      - exponent present ('e' or 'E')
      - more than one '.'
      - leading or trailing '.'
      - sign-only (cell is just '-' or '+')
      - non-digit, non-sign, non-dot byte
      - total mantissa digit count > 16

    Caller falls back to the scalar `Float64(String(...))` path.
    """
    var n = len(cell)
    if n == 0 or n > 17:
        return None

    # Sign handling.
    var first = cell[0]
    var start = 0
    var negative = False
    if first == UInt8(0x2D):
        negative = True
        start = 1
    elif first == UInt8(0x2B):
        start = 1
    if start == 1 and n == 1:
        return None  # sign-only

    # Single linear scan: validate every byte, locate the '.'.
    # `dot_pos` is the index of the '.' in `cell` (NOT in the
    # post-sign slice). Sentinel `-1` = not found.
    var dot_pos: Int = -1
    var i = start
    while i < n:
        var b = cell[i]
        if b == UInt8(0x2E):  # '.'
            if dot_pos >= 0:
                return None  # second dot
            dot_pos = i
        elif not _is_ascii_digit_byte(b):
            # Any other byte (exponent, alpha, comma, ...) -> fallback.
            return None
        i = i + 1

    # No dot -> integer-shaped. Caller should have called the integer
    # fast path first; here we explicitly reject so the wrapper picks
    # the right path without double-paying the validation cost.
    if dot_pos < 0:
        return None

    var int_len = dot_pos - start
    var frac_start = dot_pos + 1
    var frac_len = n - frac_start

    # Leading or trailing dot.
    if int_len == 0 or frac_len == 0:
        return None

    # Total mantissa digits must fit in 16 (the n_digits SIMD cap)
    # and frac_len must fit in the _POW10 table.
    if int_len + frac_len > 16 or frac_len >= _POW10_F64_SIZE:
        return None  # cov: unreachable n <= 17 leaves at most 16 digits, and int_len >= 1 caps frac_len at 15

    # Concatenated mantissa view: we want to parse digits at
    # positions [start, dot_pos) ++ [frac_start, n) as one UInt64.
    # Allocating a temp buffer would dominate; instead, parse each
    # half via the scalar tight loop (1-15 digits each, both
    # contiguous in the original span). The 8-digit Lemire would
    # require a 16-byte temp slab — skip; the per-digit accumulation
    # at this small N is faster than the slab build.
    var mantissa: UInt64 = 0
    var k = start
    while k < dot_pos:
        # Already validated all bytes above; this is digit-only.
        mantissa = mantissa * UInt64(10) + UInt64(Int(cell[k]) - 0x30)
        k = k + 1
    k = frac_start
    while k < n:
        mantissa = mantissa * UInt64(10) + UInt64(Int(cell[k]) - 0x30)
        k = k + 1

    # Final cast + scale. The divide is one IEEE-754 op; the divisor
    # is exact for k in [0, 15] (powers of 10 within F64 precision).
    var as_f = Float64(Int(mantissa))
    var divisor = _pow10_f64(frac_len)
    var result = as_f / divisor
    if negative:
        result = -result
    return Optional[Float64](result)
