# =============================================================================
# write.mojo: direct-byte JSON writers.
# =============================================================================
#
# Every writer appends to a caller-owned `List[UInt8]` (no intermediate
# `String` per value), so an encoder can build a whole document in one buffer:
#
#   - `write_json_string(buf, s)`: `s` as a quoted, escaped JSON string.
#   - `write_json_null(buf)` / `write_json_bool(buf, b)`: the literals.
#   - `write_i64_dec(buf, v)` / `write_u64_dec(buf, v)`: decimal integers,
#       correct at Int64.MIN, Int64.MAX and UInt64.MAX.
#   - `write_f64_dtoa(buf, v)`: shortest-round-trip IEEE 754 double;
#       NaN / +Inf / -Inf have no JSON form and are written as `null`
#       (RFC 8259 §6); `-0.0` keeps its sign.
#
# # String escaping (RFC 8259 §7)
#
# `"` and `\` get a backslash; backspace, form feed, LF, CR and tab get their
# two-character escapes; every other byte below 0x20 becomes `\u00XX`
# (lowercase hex). Every other byte, including every byte of a multibyte UTF-8
# sequence, is copied verbatim: the output is UTF-8, never `\u`-escaped
# non-ASCII. The writer iterates raw bytes (`String.as_bytes()`); appending a
# byte >= 0x80 as a code point (`chr(b)`) would double-encode every multibyte
# sequence (an em dash `e2 80 94` would become `c3 a2 c2 80 c2 94`).
#
# # dtoa correctness
#
# Mojo's `String(Float64)` produces shortest-round-trip digits. `write_f64_dtoa`
# has two tiers:
#   1. Fast path (`_try_fast_decimal_dtoa`): emits a fixed-point decimal
#      directly into `buf` for `|v|` in [1e-4, 1e9) that lies exactly on the
#      10^-4 grid (monetary scale-2 decimals and their scale-4 products). Its
#      output equals `String(v)` byte for byte; an exact round-trip check is
#      the proof.
#   2. Slow path: `String(v)` + byte copy for everything else (pi, denormals,
#      large values, scientific notation, -0.0).
# A value the fast path rejects falls back to the stdlib, so the fast path can
# change speed but never bytes. Every output of either tier is a valid JSON
# number (the tests reparse them with the strict parser).
#
# # Encapsulation
#
# No pointer in any signature. `List[UInt8]` is the byte buffer.
# =============================================================================

from std.memory import bitcast

# =============================================================================
# Literals and strings.
# =============================================================================

@always_inline
def _append_ascii(mut buf: List[UInt8], s: String):
    """Append the bytes of `s` verbatim."""
    buf.extend(Span(s.as_bytes()))

def write_json_null(mut buf: List[UInt8]):
    """Append the literal `null`."""
    buf.append(UInt8(0x6E))  # n
    buf.append(UInt8(0x75))  # u
    buf.append(UInt8(0x6C))  # l
    buf.append(UInt8(0x6C))  # l

def write_json_bool(mut buf: List[UInt8], b: Bool):
    """Append the literal `true` or `false`."""
    if b:
        _append_ascii(buf, String("true"))
    else:
        _append_ascii(buf, String("false"))

@always_inline
def _hex_digit(nibble: UInt8) -> UInt8:
    """A 0..15 nibble as its lowercase-hex ASCII byte."""
    if nibble < 10:
        return 0x30 + nibble  # '0'..'9'
    return 0x61 + (nibble - 10)  # 'a'..'f'

def write_json_string(mut buf: List[UInt8], s: String):
    """Append `s` as a JSON string literal, quotes included, escaped per
    RFC 8259 §7 (see the module header). Bytes >= 0x20 other than `"` and `\\`
    are copied verbatim, so UTF-8 passes through unchanged."""
    buf.append(0x22)  # opening '"'
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 0x22:  # '"'
            buf.append(0x5C)
            buf.append(0x22)
        elif b == 0x5C:  # backslash
            buf.append(0x5C)
            buf.append(0x5C)
        elif b == 0x0A:  # '\n'
            buf.append(0x5C)
            buf.append(0x6E)
        elif b == 0x0D:  # '\r'
            buf.append(0x5C)
            buf.append(0x72)
        elif b == 0x09:  # '\t'
            buf.append(0x5C)
            buf.append(0x74)
        elif b == 0x08:  # '\b'
            buf.append(0x5C)
            buf.append(0x62)
        elif b == 0x0C:  # '\f'
            buf.append(0x5C)
            buf.append(0x66)
        elif b < 0x20:  # any other control byte -> \u00XX
            buf.append(0x5C)  # '\'
            buf.append(0x75)  # 'u'
            buf.append(0x30)  # '0'
            buf.append(0x30)  # '0'
            buf.append(_hex_digit((b >> 4) & 0xF))
            buf.append(_hex_digit(b & 0xF))
        else:
            # >= 0x20 and not " or \: every UTF-8 byte, verbatim.
            buf.append(b)
    buf.append(0x22)  # closing '"'

# =============================================================================
# Integers.
# =============================================================================

def write_u64_dec(mut buf: List[UInt8], v: UInt64):
    """Append `v` as an unsigned decimal JSON number (correct up to
    UInt64.MAX, where a signed writer would wrap)."""
    if v == UInt64(0):
        buf.append(UInt8(0x30))  # '0'
        return
    # A UInt64 has at most 20 decimal digits.
    var digits = Array[UInt8, 20](uninitialized=True)
    var n = 0
    var x = v
    while x > UInt64(0):
        digits[n] = UInt8(0x30) + UInt8(Int(x % UInt64(10)))
        n += 1
        x = x // UInt64(10)
    for i in range(n):
        buf.append(digits[n - 1 - i])

def write_i64_dec(mut buf: List[UInt8], v: Int64):
    """Append `v` as a decimal JSON number: a leading `-` for a negative
    value, a single `0` for zero. Int64.MIN is exact (its magnitude is taken
    as a UInt64, where it does not overflow)."""
    if v < Int64(0):
        buf.append(UInt8(0x2D))  # '-'
        # Two's complement: the magnitude of any negative Int64, including
        # MIN, is (~v + 1) as a UInt64.
        var mag = (~v).cast[DType.uint64]() + UInt64(1)
        write_u64_dec(buf, mag)
    else:
        write_u64_dec(buf, v.cast[DType.uint64]())

# =============================================================================
# Float64 shortest-round-trip (write_f64_dtoa).
# =============================================================================

@always_inline
def _is_nan_f64(v: Float64) -> Bool:
    """IEEE 754: NaN iff exponent = all-1 and mantissa != 0."""
    var bits = UInt64(bitcast[DType.uint64, 1](v))
    var exp = (bits >> UInt64(52)) & UInt64(0x7FF)
    var mant = bits & UInt64(0xFFFFFFFFFFFFF)
    return exp == UInt64(0x7FF) and mant != UInt64(0)

@always_inline
def _is_inf_f64(v: Float64) -> Bool:
    """IEEE 754: +/-Inf iff exponent = all-1 and mantissa == 0."""
    var bits = UInt64(bitcast[DType.uint64, 1](v))
    var exp = (bits >> UInt64(52)) & UInt64(0x7FF)
    var mant = bits & UInt64(0xFFFFFFFFFFFFF)
    return exp == UInt64(0x7FF) and mant == UInt64(0)

@always_inline
def _try_fast_decimal_dtoa(mut buf: List[UInt8], v: Float64) -> Bool:
    """Try to emit `v` as fixed-point decimal via a 10^-4 grid round-trip.
    Returns True if `v` is in the fast-path domain and bytes were emitted;
    False otherwise (caller MUST fall back to stdlib).

    **Byte-identity contract**: when returning True, the bytes written
    are byte-equal to `String(v)`. The round-trip equality check is the
    proof: only values that exactly equal their rounded 10^-4 grid form
    are accepted, which guarantees the fixed-point emission has the same
    shortest-round-trip digits as `String(v)`.

    **Domain accepted**:
      - `|v| ∈ [1e-4, 1e9)` (intersection of stdlib decimal range and
        int64-safe scale).
      - `v` must equal `Float64(round(v * 10000)) / 10000` exactly.
      - `v == +0.0` (but NOT `-0.0` — preserved-sign zero takes slow path).

    Out-of-domain (FAST-PATH-REJECT, slow-path takes over): NaN, ±Inf,
    `|v| >= 1e9`, `0 < |v| < 1e-4` (stdlib uses scientific notation here),
    `-0.0`, and any value whose 10^-4 grid round-trip does not equal `v`.
    """
    # NaN: rejected (caller already short-circuited NaN/Inf above).
    if v != v:
        return False
    var abs_v = v if v >= Float64(0.0) else -v
    # Out-of-range: rejected.
    if abs_v >= Float64(1.0e9):
        return False
    # Sub-1e-4: stdlib emits scientific notation (`1e-05` etc.).
    if abs_v != Float64(0.0) and abs_v < Float64(1.0e-4):
        return False
    # `-0.0`: stdlib distinguishes from `+0.0`; fast path conflates via
    # the abs+round-trip math. Reject; let the slow path preserve sign.
    # SAFETY: bitcast Float64 -> UInt64 is a value-preserving reinterpret
    # of the IEEE 754 bit pattern; no aliasing or ownership concerns.
    var v_bits = bitcast[DType.uint64](v)
    if v_bits == UInt64(0x8000000000000000):
        return False
    # Round-trip via 10^-4 grid.
    var scaled = v * Float64(10000.0)
    var rounded: Int64
    if v >= Float64(0.0):
        rounded = Int64(scaled + Float64(0.5))
    else:
        rounded = -Int64(-scaled + Float64(0.5))
    # The byte-identity proof: this equality means the fixed-point form
    # IS the shortest-round-trip decimal of `v`.
    if Float64(rounded) / Float64(10000.0) != v:
        return False

    # Emit. Sign first, then unsigned magnitude.
    if v < Float64(0.0):
        buf.append(UInt8(0x2D))  # '-'
    var abs_rounded = rounded if rounded >= Int64(0) else -rounded
    var int_part = abs_rounded // Int64(10000)
    var frac = abs_rounded - int_part * Int64(10000)

    # Integer part — at most 9 digits (|v| < 1e9 ensures abs_rounded < 1e13,
    # int_part < 1e9).
    if int_part == Int64(0):
        buf.append(UInt8(0x30))  # '0'
    else:
        var digits = Array[UInt8, 12](uninitialized=True)
        var n = 0
        var x = int_part
        while x > Int64(0):
            digits[n] = UInt8(0x30 + Int(x % Int64(10)))
            n += 1
            x = x // Int64(10)
        for i in range(n):
            buf.append(digits[n - 1 - i])

    # Decimal point.
    buf.append(UInt8(0x2E))  # '.'
    # Fractional digits — trim trailing zeros while keeping at least one
    # digit (so `17.0` not `17.`, `21168.23` not `21168.2300`).
    if frac == Int64(0):
        buf.append(UInt8(0x30))  # `.0` for integer-valued floats
        return True
    # Extract 4 digits left-to-right (most significant first).
    var f0 = Int(frac // Int64(1000))
    var f1 = Int((frac // Int64(100)) % Int64(10))
    var f2 = Int((frac // Int64(10)) % Int64(10))
    var f3 = Int(frac % Int64(10))
    if f3 != 0:
        buf.append(UInt8(0x30 + f0))
        buf.append(UInt8(0x30 + f1))
        buf.append(UInt8(0x30 + f2))
        buf.append(UInt8(0x30 + f3))
    elif f2 != 0:
        buf.append(UInt8(0x30 + f0))
        buf.append(UInt8(0x30 + f1))
        buf.append(UInt8(0x30 + f2))
    elif f1 != 0:
        buf.append(UInt8(0x30 + f0))
        buf.append(UInt8(0x30 + f1))
    else:
        buf.append(UInt8(0x30 + f0))
    return True

def write_f64_dtoa(mut buf: List[UInt8], v: Float64):
    """Write `v` as a JSON number (shortest-round-trip), or `null` for
    NaN / +Inf / -Inf per RFC 8259 §6.

    Two-tier dtoa:
      1. Fast path (`_try_fast_decimal_dtoa`) — direct-buffer fixed-point
         emit for values in [1e-4, 1e9) that lie exactly on the 10^-4 grid.
      2. Slow path — `String(v)` + bulk extend, byte-identical to the
         stdlib formatter.
    """
    if _is_nan_f64(v) or _is_inf_f64(v):
        write_json_null(buf)
        return
    if _try_fast_decimal_dtoa(buf, v):
        return
    # Slow-path fallback: format once into a String, then bulk-copy its
    # bytes.
    var s = String(v)
    buf.extend(Span(s.as_bytes()))
