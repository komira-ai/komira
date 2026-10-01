# =============================================================================
# json_number — direct-byte JSON number formatters
# =============================================================================
#
# The two number encoders the proto3-JSON encoder appends with, writing
# straight into a `List[UInt8]` (no intermediate `String` per value):
#
#   - `write_i64_dec(mut buf, v: Int64)` — integer decimal-string encoder.
#   - `write_f64_dtoa(mut buf, v: Float64)` — IEEE 754 double-to-string;
#       NaN / +Inf / -Inf -> `null` per RFC 8259 §6.
#
# They live here, beside their only consumer in this package, so that
# `komira_serde` depends on nothing but `komira_protobuf`: the generated
# cloud clients all import `komira_serde`, and a dependency on a full JSON
# library would make every one of them pay for it.
#
# # dtoa correctness
#
# Mojo's stdlib `String(Float64)` produces shortest-round-trip bytes
# (Grisu3/Ryu-equivalent). `write_f64_dtoa` has a two-tier strategy:
#   1. Fast path (`_try_fast_decimal_dtoa`) emits a fixed-point decimal
#      directly into `buf` for `|v| ∈ [1e-4, 1e9)` values that lie exactly
#      on the 10^-4 grid (monetary scale-2 decimals and their scale-4
#      products). Byte-identity to stdlib is proven by an exact round-trip
#      check.
#   2. Slow path delegates to `String(v)` + byte-copy for everything else
#      (pi, denormals, large values, scientific-notation cases).
# Any value the fast path rejects falls back to stdlib, so the fast path
# can change speed but never bytes.
#
# # Encapsulation
#
# No `UnsafePointer` in any signature. `List[UInt8]` is the encapsulated
# byte buffer.
# =============================================================================

from std.memory import bitcast


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
def _append_bytes(mut buf: List[UInt8], s: String):
    """Append all bytes of `s` to `buf`. Bytes are read in place via
    `s[byte=i]` (typed-byte projection); `s` itself is not copied."""
    var n = s.byte_length()
    for i in range(n):
        buf.append(UInt8(ord(s[byte=i])))


@always_inline
def _append_null_lit(mut buf: List[UInt8]):
    """Append the 4 bytes `null` directly (no String alloc)."""
    buf.append(UInt8(0x6E))  # n
    buf.append(UInt8(0x75))  # u
    buf.append(UInt8(0x6C))  # l
    buf.append(UInt8(0x6C))  # l


# =============================================================================
# Integer decimal-string encoder (write_i64_dec)
# =============================================================================
#
# Algorithm: divide-by-10 loop into a stack-local digit buffer, then
# reverse. Negatives get a leading '-' + abs.


def write_i64_dec(mut buf: List[UInt8], v: Int64):
    """Write `v` as a decimal-encoded JSON number to `buf`.

    Negative values: leading `-` + abs. Zero: single `0`. INT64_MIN
    safe (abs(INT64_MIN) overflow is handled by the explicit branch).
    """
    if v == Int64(0):
        buf.append(UInt8(0x30))  # '0'
        return
    # INT64_MIN special case (abs() would overflow).
    if v == Int64(-9223372036854775808):
        _append_bytes(buf, String("-9223372036854775808"))
        return
    var abs_v: Int64
    if v < Int64(0):
        buf.append(UInt8(0x2D))  # '-'
        abs_v = -v
    else:
        abs_v = v
    # Build digits in reverse into a stack-local fixed buffer (no heap
    # allocation per integer). An Int64 decimal has at most 20 digits; the
    # leading '-' is already emitted above and abs_v >= 0.
    var digits = Array[UInt8, 20](uninitialized=True)
    var n = 0
    while abs_v > Int64(0):
        var d = Int(abs_v % Int64(10))
        digits[n] = UInt8(0x30 + d)
        n += 1
        abs_v = abs_v // Int64(10)
    # Emit reversed.
    for i in range(n):
        buf.append(digits[n - 1 - i])


# =============================================================================
# Float64 shortest-round-trip (write_f64_dtoa)
# =============================================================================
#
# The stdlib `String(Float64)` path allocates a heap `String` per value,
# formats it, and copies it out. The two-tier dtoa below avoids that for
# the common fixed-point case.
#
# **Fast path** (`_try_fast_decimal_dtoa`): for values in the fixed-point
# domain |v| ∈ [1e-4, 1e9) where `v` is exactly representable as
# `int / 10^4` (verified by a round-trip equality check), emit bytes
# directly into `buf` as a fixed-point decimal (e.g. `21168.23`, `0.04`,
# `20321.5008`, `13309.6`, `17.0`). No heap String alloc.
#
# **Slow path** (stdlib fallback): everything outside the fast-path
# domain — pi, denormals, large values, `-0.0`, scientific-notation
# cases — falls back to `String(v)` + bulk extend. Preserves
# byte-identity with stdlib.
#
# **Byte-identity invariant**: when the fast path emits, its output MUST
# equal `String(v)`. Proven by the round-trip equality check
# `Float64(rounded) / 10000.0 == v`. This is an exact dyadic-rational
# constraint: only values for which the rounded 10^-4 grid representation
# is bit-exact with `v` are accepted.
#
# NaN / +/-Inf -> JSON `null` per RFC 8259 §6 (the DuckDB / pyarrow /
# yyjson convention).


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
        _append_null_lit(buf)
        return
    if _try_fast_decimal_dtoa(buf, v):
        return
    # Slow-path fallback: format once into a String, then bulk-copy its
    # bytes.
    var s = String(v)
    buf.extend(Span(s.as_bytes()))
