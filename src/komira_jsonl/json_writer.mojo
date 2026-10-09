# =============================================================================
# json_writer — direct-byte JSON value formatters + pretty-print
# =============================================================================
#
# The per-type byte-buffer formatters for the JSONL sink hot path.
# `encode.mojo` has String-form helpers (`_emit_int`, `_emit_float64`,
# ...) that allocate an intermediate `String` per cell; this module has
# the direct-byte twins that append straight to `List[UInt8]`,
# eliminating the per-cell `String` allocation.
#
# Public surface:
#
#   - `fn write_i64_dec(mut buf, v: Int64)` — integer decimal-string encoder
#   - `fn write_f64_dtoa(mut buf, v: Float64)` — IEEE 754 double-to-string;
#       NaN / +Inf / -Inf -> `null` per RFC 8259 §6. The batch and row
#       writers refuse NaN / +-Inf in a NOT NULL column instead (the error
#       names the column, the row and the value; `encode.
#       not_null_nonfinite_error`).
#   - `fn write_string_escaped(mut buf, s)` — JSON-spec string escape
#       (matches `_emit_string_escaped` byte-for-byte, no String alloc).
#   - `fn write_date32(mut buf, days)` — ISO-8601 `YYYY-MM-DD` encoder
#       (Howard Hinnant proleptic-Gregorian inverse, ~30 LOC).
#   - `fn write_decimal128(mut buf, low: Int64, high: Int64, scale: Int)`
#       — emits Decimal128 as a JSON STRING (precision-preserving;
#       quoted; the string-vs-numeric choice favours precision).
#   - `fn write_batch_json_pretty(mut buf, batch, indent: Int = 2)` —
#       JSON array of records with Python `json.dumps(..., indent=2)`-
#       byte-identical formatting.
#
# # dtoa correctness
#
# The stdlib `String(Float64)` produces shortest-round-trip
# bytes (Grisu3/Ryu-equivalent). `write_f64_dtoa` has a two-tier strategy:
#   1. Fast path (`_try_fast_decimal_dtoa`) emits fixed-point decimal
#      directly into `buf` for `|v| ∈ [1e-4, 1e9)` dyadic rationals on
#      the 10^-4 grid (e.g. monetary scale-2 decimals and scale-4
#      products).
#      Byte-identity to stdlib is proven by an exact round-trip check.
#   2. Slow path delegates to `String(v)` + byte-copy for everything
#      else (pi, denormals, large values, scientific-notation cases).
# Zero correctness risk: any rejected value falls back to stdlib.
# Empirical: 1M random Float64 + monetary-domain edge cases → 0 mismatches
# (tests/test_dtoa_parity.mojo).
#
# # Encapsulation
#
# No `UnsafePointer` in any signature. `List[UInt8]` is the encapsulated
# byte buffer; `Span[UInt8, _]` borrowed reads are the typed-view path.
# =============================================================================

from std.bit import count_trailing_zeros
from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.string_array import StringArray
from komira_simd.byte_class.byte_find_any_of import byte_find_eq_2_u8x16
from komira_simd.byte_class.byte_mask_ops import bytemask_or
from komira_simd.byte_class.comparisons import byte_lt
from komira_simd.byte_class.movemask import (
    bool_vec_to_uint_u8x16,
    movemask_to_uint_u8x16,
)

from komira_jsonl.encode import (
    _is_nan_f64,
    _is_inf_f64,
    _nibble_hex_lower,
    _emit_float64,
    _emit_string_escaped,
    check_float_column_writable,
    not_null_nonfinite_error,
)

# JSONL row-native write: the row-native JSONL emitter reads cells
# DIRECTLY off `RowOutput`'s `RowBlock`s. Importing `komira_row_format`
# from `komira_jsonl` is acyclic — `komira_row_format` does NOT import
# `komira_jsonl` (the row_output/row_block carriers never reach back into
# the JSON package).
from komira_row_format.row_output import RowOutput
from komira_row_format.row_block import (
    DT_I64,
    DT_F64,
    DT_I32,
    DT_F32,
    DT_STRING,
)


# =============================================================================
# Append-byte helpers
# =============================================================================



@always_inline
def _append_bytes(mut buf: List[UInt8], s: String):
    """Append all bytes of `s` to `buf`. No copy of `s` itself; bytes
    are read in-place via `s[byte=i]` (typed-byte projection)."""
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


@always_inline
def _append_true_lit(mut buf: List[UInt8]):
    """Append the 4 bytes `true` directly (no String alloc)."""
    buf.append(UInt8(0x74))  # t
    buf.append(UInt8(0x72))  # r
    buf.append(UInt8(0x75))  # u
    buf.append(UInt8(0x65))  # e


@always_inline
def _append_false_lit(mut buf: List[UInt8]):
    """Append the 5 bytes `false` directly (no String alloc)."""
    buf.append(UInt8(0x66))  # f
    buf.append(UInt8(0x61))  # a
    buf.append(UInt8(0x6C))  # l
    buf.append(UInt8(0x73))  # s
    buf.append(UInt8(0x65))  # e


@always_inline
def _append_byte(mut buf: List[UInt8], b: UInt8):
    buf.append(b)


@always_inline
def _append_str_literal(mut buf: List[UInt8], s: StringLiteral):
    """Append a static string literal byte-by-byte."""
    _append_bytes(buf, String(s))


# =============================================================================
# Integer decimal-string encoder (write_i64_dec)
# =============================================================================
#
# Algorithm: standard divide-by-10 loop into a per-digit byte buffer,
# then reverse. Handles negatives via leading '-' + abs. ~20 LOC.
# Performance: Mojo's stdlib `String(Int64)` is ~equivalent; we expose
# the explicit variant for the hot-loop direct-write path.


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
    # Build digits in reverse into a stack-local fixed buffer (not a heap
    # `List[UInt8]()` per integer, which costs an alloc/free per cell).
    # An Int64 decimal has at most 20 digits; no negative branch
    # here (the leading '-' is already emitted above and abs_v >= 0).
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
# The stdlib `String(Float64)` is Grisu3/Ryu-shortest. It costs ~258
# ns/value on linux-x86_64 due to heap-`String` allocation + Grisu format +
# memcpy out — at 6 Float64 columns × 6M rows that is 36M calls, ~9 s.
#
# Two-tier dtoa.
#
# **Fast path** (`_try_fast_decimal_dtoa`): for values in the fixed-point
# domain |v| ∈ [1e-4, 1e9) where `v` is exactly representable as `int / 10^4`
# (verified by a round-trip equality check), emit bytes directly into `buf`
# as a fixed-point decimal (e.g. `21168.23`, `0.04`, `20321.5008`,
# `13309.6`, `17.0`). NO heap String alloc. ~28 ns/value (~9× faster).
#
# **Slow path** (stdlib fallback): for everything outside the fast-path
# domain — including pi, denormals, large values, NaN/Inf already handled,
# `-0.0`, scientific-notation cases — fall back to `String(v)` + bulk extend
# Preserves byte-identity with stdlib.
#
# **Byte-identity invariant**: when the fast path emits, its output MUST
# equal `String(v)`. Proven by the round-trip equality check
# `Float64(rounded) / 10000.0 == v`. This is an exact dyadic-rational
# constraint: only values for which the rounded 10^-4 grid representation
# is bit-exact with `v` are accepted. Verified empirically by
# `tests/test_dtoa_parity.mojo` (1M random Float64 + monetary-domain edge
# cases — 0 mismatches).
#
# NaN / +/-Inf -> JSON `null` per RFC 8259 §6 (mirrors DuckDB / pyarrow /
# yyjson convention) — unchanged.


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

    Out-of-domain (fast path rejects, slow path takes over): NaN, ±Inf,
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
         emit for the |v| ∈ [1e-4, 1e9) dyadic-rational-on-10^-4-grid
         domain. ~28 ns/value. Monetary data (scale-2 decimals and
         computed scale-4 products, e.g. TPC-H prices, discounts, taxes)
         is entirely in this set by construction.
      2. Slow path — `String(v)` + bulk extend. ~258 ns/value. Byte-
         identical to `encode._emit_float64`, which
         `test_byte_identity_fused_vs_legacy` checks.
    """
    if _is_nan_f64(v) or _is_inf_f64(v):
        _append_null_lit(buf)
        return
    if _try_fast_decimal_dtoa(buf, v):
        return
    # Slow-path fallback: format once into a stack String,
    # then bulk-memcpy its bytes (one heap alloc + Grisu format).
    var s = String(v)
    buf.extend(Span(s.as_bytes()))


# =============================================================================
# String escape (write_string_escaped) — direct-byte twin of _emit_string_escaped
# =============================================================================
#
# Same escape lattice as `encode._emit_string_escaped`:
#   - `"` -> `\"`
#   - `\` -> `\\`
#   - `\n` `\r` `\t` `\b` `\f` -> two-char form
#   - Other control chars (< 0x20) -> `\u00XX`
#   - All other bytes pass through verbatim (UTF-8 preserved).
# Wraps in `"..."`.
#
# # SIMD fast-path 
#
# Inner loop scans the source 16 bytes at a time. Predicate:
# `b == 0x22 | b == 0x5C | b < 0x20`. Lowered to NEON as
# (`cmeq.16b` × 2 + `cmlt.16b` + 2× `orr.16b`) → movemask to UInt16.
# If movemask == 0: bulk-extend 16 bytes via `buf.extend(Span)` (one
# `memcpy`). If movemask != 0: `ctz` gives the first escape byte;
# bulk-extend the safe prefix, then single-step the escape byte
# through `_write_escaped_byte` (the per-byte scalar branch), then
# advance and re-scan. Tail (< 16 bytes left) falls through to the
# scalar loop. Every escape byte goes through the SAME scalar branch as
# `encode._emit_string_escaped`, so output is byte-for-byte identical.
#
# Hot path: the SIMD fast path is the common case for typical text
# columns (long ASCII runs with no escape characters). Bulk memcpy
# ~16 B/cycle vs scalar ~1 B/8 cycles is the win.


@always_inline
def _write_escaped_byte(mut buf: List[UInt8], b: UInt8):
    """Per-byte JSON-escape branch — emits the escape sequence for
    `b` to `buf`. ASSUMES `b` requires escaping (i.e. `b == 0x22 |
    b == 0x5C | b < 0x20`). For non-escape bytes the SIMD fast path
    bulk-memcpys them; this helper is the single source-of-truth for
    the escape transformation.
    """
    if b == UInt8(0x22):  # "
        buf.append(UInt8(0x5C))  # \\
        buf.append(UInt8(0x22))  # "
    elif b == UInt8(0x5C):  # backslash
        buf.append(UInt8(0x5C))
        buf.append(UInt8(0x5C))
    elif b == UInt8(0x0A):  # \n
        buf.append(UInt8(0x5C))
        buf.append(UInt8(0x6E))
    elif b == UInt8(0x0D):  # \r
        buf.append(UInt8(0x5C))
        buf.append(UInt8(0x72))
    elif b == UInt8(0x09):  # \t
        buf.append(UInt8(0x5C))
        buf.append(UInt8(0x74))
    elif b == UInt8(0x08):  # \b
        buf.append(UInt8(0x5C))
        buf.append(UInt8(0x62))
    elif b == UInt8(0x0C):  # \f
        buf.append(UInt8(0x5C))
        buf.append(UInt8(0x66))
    else:
        # All remaining < 0x20 control chars -> \u00XX.
        # (Callers MUST only invoke this helper for bytes the predicate
        # flagged; this branch is the residual control-char path.)
        buf.append(UInt8(0x5C))  # \\
        buf.append(UInt8(0x75))  # u
        buf.append(UInt8(0x30))  # 0
        buf.append(UInt8(0x30))  # 0
        var hi = (b >> UInt8(4)) & UInt8(0xF)
        var lo = b & UInt8(0xF)
        var hs = _nibble_hex_lower(hi)
        var ls = _nibble_hex_lower(lo)
        buf.append(UInt8(ord(hs[byte=0])))
        buf.append(UInt8(ord(ls[byte=0])))


@always_inline
def _escape_mask_u8x16(chunk: SIMD[DType.uint8, 16]) -> UInt32:
    """Predicate scan of a 16-byte chunk: bit k of the returned UInt16
    (lower 16 bits of UInt32) is 1 iff `chunk[k]` requires escaping,
    i.e. `chunk[k] == 0x22 | chunk[k] == 0x5C | chunk[k] < 0x20`.

    NEON lowering: ~6 SIMD insns (2 `cmeq.16b` + 1 `cmlt.16b` + 2
    `orr.16b` + 1 movemask path). All single-cycle on M-series.
    """
    # m_quote_or_backslash: lanes where chunk[k] in {0x22, 0x5C}.
    var m_qb = byte_find_eq_2_u8x16(chunk, UInt8(0x22), UInt8(0x5C))
    # m_control: lanes where chunk[k] < 0x20. Returns SIMD[bool, 16];
    # convert directly via bool_vec_to_uint_u8x16 once OR-merged.
    var thresh = SIMD[DType.uint8, 16](0x20)
    var ctl_bool = byte_lt[16](chunk, thresh)
    # Materialize the control-char predicate as a 0xFF/0x00 byte-mask
    # and OR-merge with the quote/backslash byte-mask, then pack to bits.
    var ones = SIMD[DType.uint8, 16](0xFF)
    var zeros = SIMD[DType.uint8, 16](0x00)
    var m_ctl = ctl_bool.select(ones, zeros)
    var merged = bytemask_or[16](m_qb, m_ctl)
    return movemask_to_uint_u8x16(merged)


def write_string_escaped(mut buf: List[UInt8], s: String):
    """Write `s` as a JSON-spec escaped string (wrapped in `"..."`).

    Escape lattice per RFC 8259 §7. Identical to `_emit_string_escaped`
    but appends bytes directly to `buf` without intermediate String
    allocation.

    Implementation: SIMD-scan 16 bytes at a time for the 3-byte escape
    predicate; bulk-memcpy safe runs; single-byte escape for hit
    positions; scalar tail. See module header above for the algorithm.
    """
    buf.append(UInt8(0x22))  # opening "
    var n = s.byte_length()
    if n == 0:
        buf.append(UInt8(0x22))  # closing " (empty-string fast path)
        return

    # Borrow the source string's bytes as a Span for bulk-extend calls.
    # `Span` is a borrowed view; the underlying String memory is held
    # alive by `s` for the duration of this function.
    var bytes = s.as_bytes()
    # SAFETY: `src_ptr` is the byte-pointer of `bytes` (a Span borrowed
    # from `s`). `bytes` holds `s` alive for this function's scope; we
    # only dereference at offsets in [0, n) checked by the loop bounds.
    # The pointer is never returned or stored — purely a function-local
    # arithmetic alias for the SIMD load + scalar tail loop. Confined
    # to this function body; does not cross the module boundary.
    var src_ptr = bytes.unsafe_ptr()
    var i: Int = 0

    # SIMD chunk loop. Scans 16 bytes per iteration; bulk-memcpys
    # safe (no-escape) prefixes; single-steps escape bytes through
    # `_write_escaped_byte`.
    while i + 16 <= n:
        var chunk = (src_ptr + i).load[width=16](0)
        var mask = _escape_mask_u8x16(chunk)
        if mask == UInt32(0):
            # Fast path: 16-byte safe run; bulk-extend via one memcpy.
            buf.extend(Span(bytes)[i : i + 16])
            i += 16
            continue
        # Escape byte found. Walk every set bit in this chunk in order;
        # bulk-extend safe spans between hits; single-byte-emit each
        # escape byte through the scalar branch.
        var chunk_base = i
        var chunk_end = i + 16
        var bits = mask & UInt32(0xFFFF)
        var cur = i  # cursor within the source bytes
        while bits != UInt32(0):
            var k = Int(count_trailing_zeros(bits))
            var hit = chunk_base + k
            if hit > cur:
                # Bulk-copy safe prefix [cur, hit).
                buf.extend(Span(bytes)[cur:hit])
            # Single-step the escape byte through the scalar branch.
            _write_escaped_byte(buf, UInt8(chunk[k]))
            cur = hit + 1
            bits &= bits - UInt32(1)
        # Tail of this chunk after the last escape byte.
        if cur < chunk_end:
            buf.extend(Span(bytes)[cur:chunk_end])
        i = chunk_end

    # Scalar tail: < 16 bytes remaining. Read via `src_ptr` (already
    # held in scope and lifetime-anchored by `bytes = s.as_bytes()`)
    # to avoid the per-byte bounds-check overhead of `s[byte=i]`.
    # Output is byte-identical: same predicate + same escape branch.
    while i < n:
        var b = (src_ptr + i)[0]
        if b == UInt8(0x22) or b == UInt8(0x5C) or b < UInt8(0x20):
            _write_escaped_byte(buf, b)
        else:
            buf.append(b)
        i += 1
    buf.append(UInt8(0x22))  # closing "


# =============================================================================
# Date32 ISO-8601 encoder (write_date32)
# =============================================================================
#
# Date32 = Int32 days since Unix epoch (1970-01-01). Inverse algorithm:
# Howard Hinnant's `civil_from_days` (proleptic Gregorian). Produces
# `YYYY-MM-DD`. Output is ALWAYS quoted (JSON string per RFC 8259 — no
# native date type in JSON).
#
# Reference: https://howardhinnant.github.io/date_algorithms.html#civil_from_days


def _civil_from_days(z_in: Int) -> Tuple[Int, Int, Int]:
    """Howard Hinnant proleptic Gregorian. `z` is days from epoch
    (1970-01-01); returns `(year, month, day)`.

    Algorithm uses zero-day adjusted to 0000-03-01. Tested by H. Hinnant
    over the entire representable range of Int32 days (>= -784353015833 to
    784351576776). Correct for proleptic Gregorian; valid for any year
    in the supported range.
    """
    var z = z_in
    z = z + 719468  # shift epoch from 1970-01-01 to 0000-03-01
    var era: Int
    if z >= 0:
        era = z // 146097
    else:
        era = (z - 146096) // 146097
    var doe = z - era * 146097  # day-of-era [0..146096]
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m: Int
    if mp < 10:
        m = mp + 3
    else:
        m = mp - 9
    var year: Int
    if m <= 2:
        year = y + 1
    else:
        year = y
    return (year, m, d)


@always_inline
def _write_zero_padded_int(mut buf: List[UInt8], v: Int, width: Int):
    """Write `v` as `width` decimal digits, zero-padded on the left.
    Assumes `v >= 0` and fits in `width` digits."""
    var digits = List[UInt8]()
    var x = v
    if x == 0:
        digits.append(UInt8(0x30))
    else:
        while x > 0:
            digits.append(UInt8(0x30 + (x % 10)))
            x = x // 10
    var have = len(digits)
    # Left-pad zeros.
    for _ in range(width - have):
        buf.append(UInt8(0x30))
    # Emit reversed.
    for i in range(have):
        buf.append(digits[have - 1 - i])


def write_date32(mut buf: List[UInt8], days: Int32):
    """Write a Date32 value as a JSON-string-quoted ISO-8601 date:
    `"YYYY-MM-DD"`.

    Negative years are emitted with a leading `-` (proleptic Gregorian
    ISO-8601 §4.1.2.4 extended-year form). Year width is 4 zero-padded
    for non-negative years.
    """
    var ymd = _civil_from_days(Int(days))
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]
    buf.append(UInt8(0x22))  # opening "
    if year < 0:
        buf.append(UInt8(0x2D))  # '-'
        _write_zero_padded_int(buf, -year, 4)
    else:
        _write_zero_padded_int(buf, year, 4)
    buf.append(UInt8(0x2D))  # -
    _write_zero_padded_int(buf, month, 2)
    buf.append(UInt8(0x2D))  # -
    _write_zero_padded_int(buf, day, 2)
    buf.append(UInt8(0x22))  # closing "


# =============================================================================
# Decimal128 string-precision-preserving encoder (write_decimal128)
# =============================================================================
#
# Decimal128 is stored as low/high 64-bit halves of a two's-complement
# i128, plus a runtime `scale` (number of fractional digits). JSON has no
# native Decimal type; the string-vs-numeric choice here is to emit a
# QUOTED JSON string (`"123.45"`) to preserve full
# precision losslessly — alternative was JSON number (lossy beyond ~15
# sig digits via Float64 round-trip).
#
# Algorithm for converting i128 -> decimal digit string:
#   1. Detect sign (high < 0); negate via two's-complement if so.
#   2. Repeatedly divide by 10 to extract decimal digits (32-step long
#      division on 64-bit halves — i128 / 10 is straightforward since
#      10 fits comfortably in 64 bits).
#   3. Reverse the digit buffer; insert '.' at position (len - scale)
#      counting from the right; pad leading zeros if scale > len.
#
# This does not rely on native i128 arithmetic — we synthesize
# from (low, high) UInt64 pairs.


def _i128_neg(low: UInt64, high: UInt64) -> Tuple[UInt64, UInt64]:
    """Two's-complement negation of an i128 = (low, high).
    `~x + 1`, with carry from low to high.
    """
    var nl = ~low
    var nh = ~high
    var rl = nl + UInt64(1)
    var carry: UInt64
    if rl == UInt64(0):
        carry = UInt64(1)
    else:
        carry = UInt64(0)
    var rh = nh + carry
    return (rl, rh)


def _u128_div10(low: UInt64, high: UInt64) -> Tuple[UInt64, UInt64, UInt64]:
    """Divide unsigned 128-bit `(low, high)` by 10. Returns
    `(quot_low, quot_high, remainder)`.

    Long division: process the high word first, then carry the
    remainder into a 65-bit dividend for the low word.

    For the high half: q_hi = high / 10; r_hi = high % 10.
    For the low half we need (r_hi * 2^64 + low) / 10. Since
    r_hi < 10 and 10 fits in 64 bits comfortably, this is a single
    64-bit division iff we synthesize the multi-precision dividend.

    Concretely: factor (r_hi * 2^64 + low) as
    r_hi * 2^64 + low = (r_hi * 1844674407370955161 * 10 + r_hi * 6 + low)
    where 2^64 / 10 = 1844674407370955161 remainder 6.
    Therefore q_lo = r_hi * 1844674407370955161 + (r_hi * 6 + low) / 10
    and r = (r_hi * 6 + low) % 10. The (r_hi * 6 + low) sum can be
    up to 9*6 + (2^64-1) = 54 + 2^64-1 which overflows UInt64;
    handle the overflow explicitly.
    """
    var q_hi = high // UInt64(10)
    var r_hi = high - q_hi * UInt64(10)
    # q_lo = r_hi * 1844674407370955161 + (r_hi * 6 + low) // 10
    var k = UInt64(1844674407370955161)
    var t1 = r_hi * k
    var rh6 = r_hi * UInt64(6)
    var sum = rh6 + low
    var overflow: UInt64
    if sum < low:
        overflow = UInt64(1)
    else:
        overflow = UInt64(0)
    # `(rh6 + low) / 10`. With overflow, dividend = sum + 2^64*overflow.
    # For overflow=0, just sum/10.
    # For overflow=1, dividend = sum + 2^64. Decompose:
    #   2^64 = 10 * 1844674407370955161 + 6
    # so (sum + 2^64) / 10 = (sum + 6) / 10 + 1844674407370955161
    # and rem = (sum + 6) % 10. The (sum + 6) addition can also
    # overflow when sum is close to UInt64 max; (sum + 6) overflow
    # iff sum > UInt64_MAX - 6.
    var q_lo_part: UInt64
    var rem: UInt64
    if overflow == UInt64(0):
        q_lo_part = sum // UInt64(10)
        rem = sum - q_lo_part * UInt64(10)
    else:
        var sum_plus_6 = sum + UInt64(6)
        if sum_plus_6 < sum:
            # sum + 6 overflowed; decompose again. After overflow,
            # sum_plus_6 = sum + 6 - 2^64. Real value = sum + 6 + 2^64.
            # Compute (sum_plus_6 + 2^64) / 10:
            #   = sum_plus_6/10 + (sum_plus_6%10 + 2^64) / 10
            # Use 2^64 = 10*k + 6.
            var sp10 = sum_plus_6 // UInt64(10)  # cov: unreachable after a carry, sum <= 9 * 6 - 1, so sum + 6 cannot wrap
            var sp_mod = sum_plus_6 - sp10 * UInt64(10)  # cov: unreachable see the line above
            var sp_mod_plus_6 = sp_mod + UInt64(6)  # cov: unreachable see the line above
            q_lo_part = sp10 + k + (sp_mod_plus_6 // UInt64(10))  # cov: unreachable see the line above
            rem = sp_mod_plus_6 - (sp_mod_plus_6 // UInt64(10)) * UInt64(10)  # cov: unreachable see the line above
        else:
            q_lo_part = sum_plus_6 // UInt64(10) + k
            rem = sum_plus_6 - (sum_plus_6 // UInt64(10)) * UInt64(10)
    var q_lo = t1 + q_lo_part
    return (q_lo, q_hi, rem)


def write_decimal128(
    mut buf: List[UInt8],
    low: Int64,
    high: Int64,
    scale: Int,
):
    """Write a Decimal128 value `(low, high)` with `scale` fractional
    digits as a JSON-string-quoted lossless decimal: `"123.45"`.

    The byte buffer receives the OPENING `"`, the formatted digit
    sequence (with sign + decimal point at the scale boundary), and the
    CLOSING `"`. Output preserves all 38 digits of Decimal128 precision.
    """
    buf.append(UInt8(0x22))  # opening "

    # Detect negative via the signed high half.
    var ul = UInt64(low)
    var uh = UInt64(high)
    var negative = high < Int64(0)
    if negative:
        var neg = _i128_neg(ul, uh)
        ul = neg[0]
        uh = neg[1]
        buf.append(UInt8(0x2D))  # '-'

    # Repeatedly divide by 10 to extract digits.
    var digits = List[UInt8]()
    if ul == UInt64(0) and uh == UInt64(0):
        digits.append(UInt8(0x30))
    else:
        while ul != UInt64(0) or uh != UInt64(0):
            var d = _u128_div10(ul, uh)
            ul = d[0]
            uh = d[1]
            digits.append(UInt8(0x30 + Int(d[2])))

    var n_digits = len(digits)

    # Insert decimal point at position (n_digits - scale) counting from the
    # right (i.e. before the last `scale` digits). If scale > n_digits,
    # pad leading zeros after the decimal point: e.g. n=2, scale=4 -> "0.0012".
    if scale == 0:
        # No fractional part. Emit reversed digits.
        for i in range(n_digits):
            buf.append(digits[n_digits - 1 - i])
    elif scale >= n_digits:
        # All digits are after the decimal point; pad leading zeros.
        buf.append(UInt8(0x30))  # '0'
        buf.append(UInt8(0x2E))  # '.'
        # Leading zeros: scale - n_digits of them.
        var pad = scale - n_digits
        for _ in range(pad):
            buf.append(UInt8(0x30))
        # Then the digits themselves, reversed.
        for i in range(n_digits):
            buf.append(digits[n_digits - 1 - i])
    else:
        # Mixed integer + fractional. Integer part has (n_digits - scale)
        # digits.
        var int_digits = n_digits - scale
        # Emit integer-part digits (reversed slice).
        for i in range(int_digits):
            buf.append(digits[n_digits - 1 - i])
        buf.append(UInt8(0x2E))  # '.'
        for i in range(scale):
            buf.append(digits[scale - 1 - i])

    buf.append(UInt8(0x22))  # closing "


# =============================================================================
# Pretty-print mode: write_batch_json_pretty
# =============================================================================
#
# Python's `json.dumps(list_of_dicts, indent=2)` produces:
#
#   [
#     {
#       "col0": 1,
#       "col1": "abc"
#     },
#     {
#       "col0": 2,
#       "col1": "def"
#     }
#   ]
#
# Key separator: `": "` (colon + single space).
# Item separator: `,\n<indent>` between items, `,` (no space) when on the
# same line — but with indent != None, the separator is `,\n`.
# Trailing newline AFTER the last `]` is omitted by Python's `json.dumps`.
#
# We mirror this exactly. The batch's column types determine the per-cell
# JSON value emission (same dispatch as `_format_column_cells_json` in
# encode.mojo, but with the upgraded DATE32 / DECIMAL128 paths from this
# module).


def _write_indent(mut buf: List[UInt8], indent: Int, depth: Int):
    """Emit `depth * indent` space bytes."""
    var n = depth * indent
    for _ in range(n):
        buf.append(UInt8(0x20))


def _write_cell_pretty(
    mut buf: List[UInt8],
    batch: RecordBatch,
    col_index: Int,
    row: Int,
) raises:
    """Emit one cell value (typed per the batch's column dtype) at the
    current `buf` position. NULL emits `null`.

    Dispatch lattice mirrors `_format_column_cells_json` but goes
    direct-byte and upgrades DATE32 (ISO-8601) + DECIMAL128 (string).
    """
    ref col_ref = batch.column_at(col_index)
    var at = batch.schema.field_arrow_type(col_index)

    if at == ArrowType.INT64:
        var arr = col_ref.as_primitive[DType.int64]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            write_i64_dec(buf, arr.get(row))
    elif at == ArrowType.INT32:
        var arr = col_ref.as_primitive[DType.int32]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            write_i64_dec(buf, Int64(arr.get(row)))
    elif at == ArrowType.DATE32:
        var arr = col_ref.as_primitive[DType.int32]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            write_date32(buf, arr.get(row))
    elif at == ArrowType.INT16:
        var arr = col_ref.as_primitive[DType.int16]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            write_i64_dec(buf, Int64(arr.get(row)))
    elif at == ArrowType.INT8:
        var arr = col_ref.as_primitive[DType.int8]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            write_i64_dec(buf, Int64(arr.get(row)))
    elif at == ArrowType.UINT64:
        var arr = col_ref.as_primitive[DType.uint64]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            _append_bytes(buf, String(arr.get(row)))
    elif at == ArrowType.UINT32:
        var arr = col_ref.as_primitive[DType.uint32]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            _append_bytes(buf, String(arr.get(row)))
    elif at == ArrowType.UINT16:
        var arr = col_ref.as_primitive[DType.uint16]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            _append_bytes(buf, String(arr.get(row)))
    elif at == ArrowType.UINT8:
        var arr = col_ref.as_primitive[DType.uint8]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            _append_bytes(buf, String(arr.get(row)))
    elif at == ArrowType.FLOAT64:
        var arr = col_ref.as_primitive[DType.float64]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            var v = arr.get(row)
            if (_is_nan_f64(v) or _is_inf_f64(v)) and not batch.schema.field_nullable(col_index):
                raise not_null_nonfinite_error(String(batch.schema.field_name(col_index)), row, v)
            write_f64_dtoa(buf, v)
    elif at == ArrowType.FLOAT32:
        var arr = col_ref.as_primitive[DType.float32]()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            var v = Float64(arr.get(row))
            if (_is_nan_f64(v) or _is_inf_f64(v)) and not batch.schema.field_nullable(col_index):
                raise not_null_nonfinite_error(String(batch.schema.field_name(col_index)), row, v)
            write_f64_dtoa(buf, v)
    elif at == ArrowType.BOOL:
        var arr = col_ref.as_boolean()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            if arr.get(row):
                _append_true_lit(buf)
            else:
                _append_false_lit(buf)
    elif at == ArrowType.STRING or at == ArrowType.LARGE_STRING:
        # `_write_cell_pretty` is called per CELL, so `column_as_string` here
        # would copy the entire column to emit one value — and it has no
        # int64-offset path at all, so a PROMOTED column would raise.
        # `utf8_value_at` reads the
        # row's bounding offsets at the column's own width and copies only
        # that row: one arm, both widths, O(cell).
        #
        # DICTIONARY under a STRING field keeps the ordinal-resolving decode
        # (its codes are not offsets — reading them as offsets is wrong),
        # so the discrimination is on the COLUMN's tag, not the Schema's.
        if col_ref.arrow_type == ArrowType.DICTIONARY:
            var darr = batch.column_as_string(col_index)
            if darr.is_null(row):
                _append_null_lit(buf)
            else:
                write_string_escaped(buf, darr.get(row))
        elif col_ref.utf8_is_null_at(row):
            _append_null_lit(buf)
        else:
            write_string_escaped(buf, col_ref.utf8_value_at(row))
    elif at == ArrowType.DICTIONARY:
        var arr = col_ref.as_dictionary()
        if arr.indices.is_null(row):
            _append_null_lit(buf)
        else:
            write_string_escaped(buf, arr.get(row))
    elif at == ArrowType.DECIMAL128:
        var arr = col_ref.as_decimal128()
        if arr.is_null(row):
            _append_null_lit(buf)
        else:
            var lo = arr.get_low(row)
            var hi = arr.get_high(row)
            write_decimal128(buf, lo, hi, arr.scale)
    elif at == ArrowType.NULL:
        _append_null_lit(buf)
    else:
        raise Error(
            "json_writer: unsupported ArrowType '"
            + String(at)
            + "' at column index "
            + String(col_index)
        )


# =============================================================================
# Compact JSONL fast path: write_batch_jsonl_direct
# =============================================================================
#
# `encode.write_batch_jsonl` pre-materializes per-row `List[String]`
# cells via `_format_column_cells_json` then row-transposes — this is
# N_ROWS × N_COLS String heap allocations + UTF-8 conversions before the
# row loop. The direct-byte variant below skips the String cell pool: each
# cell formats DIRECTLY into `buf` via `_write_cell_pretty` (same dispatch
# lattice — INT* / FLOAT* / BOOL / STRING / DATE32 / DECIMAL128 / NULL —
# but writes bytes-in-place without an intermediate String).


def write_batch_jsonl_direct(
    mut buf: List[UInt8], batch: RecordBatch
) raises:
    """Emit `batch` as JSONL bytes (one `{...}\\n` per row) directly into
    `buf`. Drop-in replacement for `encode.write_batch_jsonl` with the
    String-cell-pool overhead removed.

    Cell-emit dispatch lives in `_write_cell_pretty` (shared with
    write_batch_json_pretty). Row separator: `,` between columns,
    trailing `\\n` per row.

    Args:
      buf: target byte buffer; bytes appended in-place.
      batch: borrowed RecordBatch.
    """
    var num_rows = batch.num_rows()
    var num_cols = batch.num_columns()
    if num_cols == 0 or num_rows == 0:
        return

    # Pre-escape column names once.
    ref schema = batch.schema
    var keys = List[List[UInt8]]()
    keys.reserve(num_cols)
    for c in range(num_cols):
        var kb = List[UInt8]()
        write_string_escaped(kb, String(schema.field_name(c)))
        keys.append(kb^)

    for r in range(num_rows):
        buf.append(UInt8(0x7B))  # {
        for c in range(num_cols):
            if c > 0:
                buf.append(UInt8(0x2C))  # ,
            # Emit pre-escaped key bytes.
            for i in range(len(keys[c])):
                buf.append(keys[c][i])
            buf.append(UInt8(0x3A))  # :
            # Emit cell value.
            _write_cell_pretty(buf, batch, c, r)
        buf.append(UInt8(0x7D))  # }
        buf.append(UInt8(0x0A))  # \n


def write_batch_json_pretty(
    mut buf: List[UInt8], batch: RecordBatch, indent: Int = 2
) raises:
    """Emit `batch` as a pretty-printed JSON array of records.

    Output format matches Python `json.dumps(list_of_dicts, indent=N)`
    byte-for-byte:
      - Open `[` then newline.
      - Each record: indent-spaces × 1, `{`, newline; each field
        indented × 2, key + `: ` + value; comma + newline between
        fields; close `}` indented × 1 on its own line; comma + newline
        between records (no trailing comma after the last record).
      - Close `]` at depth 0.
      - NO trailing newline after `]`.

    Empty batch (0 rows): emits `[]` (a single line).
    """
    var num_rows = batch.num_rows()
    var num_cols = batch.num_columns()

    if num_rows == 0:
        _append_bytes(buf, String("[]"))
        return

    buf.append(UInt8(0x5B))  # [
    buf.append(UInt8(0x0A))  # \n
    ref schema = batch.schema
    for r in range(num_rows):
        # Indent record: 1 level.
        _write_indent(buf, indent, 1)
        buf.append(UInt8(0x7B))  # {
        buf.append(UInt8(0x0A))  # \n
        for c in range(num_cols):
            # Indent field: 2 levels.
            _write_indent(buf, indent, 2)
            # Key.
            write_string_escaped(buf, String(schema.field_name(c)))
            buf.append(UInt8(0x3A))  # :
            buf.append(UInt8(0x20))  # space
            # Value.
            _write_cell_pretty(buf, batch, c, r)
            # Comma + newline between fields (none after the last field).
            if c < num_cols - 1:
                buf.append(UInt8(0x2C))  # ,
            buf.append(UInt8(0x0A))  # \n
        # Close record at level-1 indent.
        _write_indent(buf, indent, 1)
        buf.append(UInt8(0x7D))  # }
        # Comma + newline between records (none after the last record).
        if r < num_rows - 1:
            buf.append(UInt8(0x2C))  # ,
        buf.append(UInt8(0x0A))  # \n
    buf.append(UInt8(0x5D))  # ]


# =============================================================================
# Fused-encode JSONL: write_batch_jsonl_fused
# =============================================================================
#
# `encode.write_batch_jsonl` is bottlenecked by per-cell `String` heap
# allocs (N_ROWS x N_COLS Strings at materialize, plus N_ROWS Strings at
# row-transpose). `write_batch_jsonl_direct` avoids those but loses the
# per-column dispatch, replacing it with per-cell dispatch (15-branch
# ArrowType match per cell). The fused form combines:
#
#   1. **Per-column ArrowType dispatch**: the type-match runs
#      ONCE per column (N_COLS), not N_ROWS x N_COLS.
#   2. **Direct-byte writes into per-column List[UInt8] cell pools**
#      no per-cell `String` allocation. Bytes go straight
#      into the column pool.
#   3. **Row-transpose via byte-slice copy from cell pools**: no String
#      concat, no String construction. Pure `buf.append(UInt8)` loop
#      indexed by per-column offset arrays.
#
# Cost model (10K rows x 10 cols):
#   - N_COLS = 10 ArrowType match dispatches.
#   - N_COLS = 10 `column_at(c).as_primitive[...]()` typed-view casts.
#   - N_ROWS x N_COLS = 100K `arr.get(r)` typed scalar reads (unavoidable).
#   - N_ROWS x N_COLS = 100K direct-byte writes per cell (replaces
#     String alloc + concat).
#   - N_ROWS = 10K row-emit loops (replaces String construction +
#     re-iteration of the per-row line).
#
# Output is byte-identical to `encode.write_batch_jsonl` (verified by
# `tests/test_write_json.mojo::test_byte_identity_fused_vs_legacy`
# across the full 10K x 10 fixture covering all 13 ArrowType arms).


def _encode_col_int64_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.int64],
    row_start: Int,
    row_end: Int,
) raises:
    """Encode INT64 column cells into the per-column byte pool. One
    offset per row in `[row_start, row_end)`; final sentinel offset at
    end-of-byte-pool.

    Callers that want the whole-batch behavior pass `(0, num_rows)`.
    The parallel writer
    passes the per-worker `[lo_row, hi_row)` partition.
    """
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_i64_dec(cell_bytes, arr.get(r))
    cell_offsets.append(len(cell_bytes))


def _encode_col_int32_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.int32],
    row_start: Int,
    row_end: Int,
) raises:
    """Encode INT32 column cells (also used by the `encode` DATE32
    arm, which emits int days as plain int). For ISO-8601 DATE32 the
    dedicated `_encode_col_date32_cells` is used; this fn mirrors the
    `encode._format_column_cells_json` INT32/DATE32 arm exactly.
    """
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_i64_dec(cell_bytes, Int64(arr.get(r)))
    cell_offsets.append(len(cell_bytes))


def _encode_col_int16_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.int16],
    row_start: Int,
    row_end: Int,
) raises:
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_i64_dec(cell_bytes, Int64(arr.get(r)))
    cell_offsets.append(len(cell_bytes))


def _encode_col_int8_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.int8],
    row_start: Int,
    row_end: Int,
) raises:
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_i64_dec(cell_bytes, Int64(arr.get(r)))
    cell_offsets.append(len(cell_bytes))


def _encode_col_uint64_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.uint64],
    row_start: Int,
    row_end: Int,
) raises:
    """Encode UINT64 column cells. `encode` uses `String(arr.get(r))`;
    we mirror that exactly but bulk-memcpy the formatted bytes (not a
    per-byte `_append_bytes` loop). UINT64 can exceed INT64_MAX so the
    stdlib `String(UInt64)` formatting is preserved (not routed through
    the signed `write_i64_dec`)."""
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            var s = String(arr.get(r))
            cell_bytes.extend(Span(s.as_bytes()))
    cell_offsets.append(len(cell_bytes))


def _encode_col_uint32_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.uint32],
    row_start: Int,
    row_end: Int,
) raises:
    # Unsigned values fit in Int64; route through the stack-buffer
    # decimal encoder (no heap String alloc, no per-byte loop).
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_i64_dec(cell_bytes, Int64(arr.get(r)))
    cell_offsets.append(len(cell_bytes))


def _encode_col_uint16_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.uint16],
    row_start: Int,
    row_end: Int,
) raises:
    # See _encode_col_uint32_cells.
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_i64_dec(cell_bytes, Int64(arr.get(r)))
    cell_offsets.append(len(cell_bytes))


def _encode_col_uint8_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.uint8],
    row_start: Int,
    row_end: Int,
) raises:
    # See _encode_col_uint32_cells.
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_i64_dec(cell_bytes, Int64(arr.get(r)))
    cell_offsets.append(len(cell_bytes))


def _encode_col_float64_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.float64],
    row_start: Int,
    row_end: Int,
) raises:
    """Encode FLOAT64 column cells. NaN/Inf -> `null` per RFC 8259 §6
    via `write_f64_dtoa`. Mirrors `encode._format_column_cells_json`
    FLOAT64 arm byte-for-byte."""
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_f64_dtoa(cell_bytes, arr.get(r))
    cell_offsets.append(len(cell_bytes))


def _encode_col_float32_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: PrimitiveArray[DType.float32],
    row_start: Int,
    row_end: Int,
) raises:
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_f64_dtoa(cell_bytes, Float64(arr.get(r)))
    cell_offsets.append(len(cell_bytes))


def _encode_col_bool_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: BooleanArray,
    row_start: Int,
    row_end: Int,
) raises:
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            if arr.get(r):
                _append_true_lit(cell_bytes)
            else:
                _append_false_lit(cell_bytes)
    cell_offsets.append(len(cell_bytes))


def _encode_col_string_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: StringArray,
    row_start: Int,
    row_end: Int,
) raises:
    """Encode STRING column cells with RFC 8259 §7 escape lattice. Mirrors
    `encode._format_column_cells_json` STRING arm.

    ⚠ STRING only, not LARGE_STRING: `StringArray` is int32-offset by
    definition. The wide twin is `_encode_col_large_string_cells` below."""
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_string_escaped(cell_bytes, arr.get(r))
    cell_offsets.append(len(cell_bytes))


def _encode_col_large_string_cells(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    arr: LargeStringArray,
    row_start: Int,
    row_end: Int,
) raises:
    """The int64-offset twin of `_encode_col_string_cells`.

    Byte-for-byte the same emission — the escape lattice and the null literal
    are properties of the VALUE, not of the offset width, so the only
    difference is which array type carries the rows. Kept as a separate
    function rather than a parameterised one because `StringArray` and
    `LargeStringArray` share no trait in this tree."""
    for r in range(row_start, row_end):
        cell_offsets.append(len(cell_bytes))
        if arr.is_null(r):
            _append_null_lit(cell_bytes)
        else:
            write_string_escaped(cell_bytes, arr.get(r))
    cell_offsets.append(len(cell_bytes))


# =============================================================================
# Per-column dispatch driver — encodes one column into its byte pool
# =============================================================================


def _encode_column_cells_fused(
    mut cell_bytes: List[UInt8],
    mut cell_offsets: List[Int],
    batch: RecordBatch,
    col_index: Int,
    row_start: Int,
    row_end: Int,
) raises:
    """Hoist ArrowType dispatch OUT of the row loop. One match per column
    drives a per-column-kind specialized inner loop that emits direct
    bytes for rows in `[row_start, row_end)` into `cell_bytes` with row
    offsets in `cell_offsets`.

    `cell_offsets[k]` (k = 0 .. row_end - row_start) = start of the
    `(row_start + k)`-th row's bytes in `cell_bytes`.
    `cell_offsets[row_end - row_start]` = sentinel = len(cell_bytes).

    Byte-for-byte identical to `encode._format_column_cells_json` when
    each row's bytes are concatenated. Verified by
    `test_byte_identity_fused_vs_legacy`.

    Takes `(row_start, row_end)` so parallel workers can encode their own
    row range. Serial callers pass `(0, num_rows)`.
    """
    ref col_ref = batch.column_at(col_index)
    var at = batch.schema.field_arrow_type(col_index)

    if at == ArrowType.INT64:
        var arr = col_ref.as_primitive[DType.int64]()
        _encode_col_int64_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.INT32 or at == ArrowType.DATE32:
        # `encode` emits INT32 + DATE32 cells as plain int days; we mirror
        # that for byte-identity with that path.
        var arr = col_ref.as_primitive[DType.int32]()
        _encode_col_int32_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.INT16:
        var arr = col_ref.as_primitive[DType.int16]()
        _encode_col_int16_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.INT8:
        var arr = col_ref.as_primitive[DType.int8]()
        _encode_col_int8_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.UINT64:
        var arr = col_ref.as_primitive[DType.uint64]()
        _encode_col_uint64_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.UINT32:
        var arr = col_ref.as_primitive[DType.uint32]()
        _encode_col_uint32_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.UINT16:
        var arr = col_ref.as_primitive[DType.uint16]()
        _encode_col_uint16_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.UINT8:
        var arr = col_ref.as_primitive[DType.uint8]()
        _encode_col_uint8_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.FLOAT64:
        var arr = col_ref.as_primitive[DType.float64]()
        check_float_column_writable(arr, row_start, row_end, batch.schema, col_index)
        _encode_col_float64_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.FLOAT32:
        var arr = col_ref.as_primitive[DType.float32]()
        check_float_column_writable(arr, row_start, row_end, batch.schema, col_index)
        _encode_col_float32_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.BOOL:
        var arr = col_ref.as_boolean()
        _encode_col_bool_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.LARGE_STRING:
        # A separate arm from STRING — see the note on
        # `_encode_col_large_string_cells`. `column_as_large_string` is the
        # accessor that cannot refuse on size; `column_as_string` narrows and
        # refuses above the int32 ceiling, i.e. refuses exactly the column
        # whose size caused the promotion.
        var arr = batch.column_as_large_string(col_index)
        _encode_col_large_string_cells(
            cell_bytes, cell_offsets, arr, row_start, row_end
        )
    elif at == ArrowType.STRING:
        var arr = batch.column_as_string(col_index)
        _encode_col_string_cells(cell_bytes, cell_offsets, arr, row_start, row_end)
    elif at == ArrowType.DICTIONARY:
        # Dictionary: the typed string view per row is what the `encode`
        # path emits via `_emit_string_escaped(arr.get(r))`. Mirror it
        # via a per-row dispatch (dictionary doesn't have a column-level
        # bulk string view).
        var arr = col_ref.as_dictionary()
        for r in range(row_start, row_end):
            cell_offsets.append(len(cell_bytes))
            if arr.indices.is_null(r):
                _append_null_lit(cell_bytes)
            else:
                write_string_escaped(cell_bytes, arr.get(r))
        cell_offsets.append(len(cell_bytes))
    elif at == ArrowType.DECIMAL128:
        # Decimal128: `encode` emits `_emit_float64(arr.get_as_float(r))`
        # (lossy). Mirror that EXACTLY for byte-identity with that path
        # (its DECIMAL128 arm is lossy by design; `write_decimal128` is
        # the lossless string form).
        var arr = col_ref.as_decimal128()
        for r in range(row_start, row_end):
            cell_offsets.append(len(cell_bytes))
            if arr.is_null(r):
                _append_null_lit(cell_bytes)
            else:
                write_f64_dtoa(cell_bytes, arr.get_as_float(r))
        cell_offsets.append(len(cell_bytes))
    elif at == ArrowType.NULL:
        for _ in range(row_start, row_end):
            cell_offsets.append(len(cell_bytes))
            _append_null_lit(cell_bytes)
        cell_offsets.append(len(cell_bytes))
    else:
        raise Error(
            "json_writer (fused): unsupported ArrowType '"
            + String(at)
            + "' at column index "
            + String(col_index)
            + ". Supported: INT8/16/32/64, UINT8/16/32/64, FLOAT32/64,"
            + " BOOL, STRING, LARGE_STRING, DICTIONARY, DATE32, DECIMAL128,"
            + " NULL."
        )


# =============================================================================
# Public surface: write_batch_jsonl_fused
# =============================================================================


def write_batch_jsonl_fused(
    mut buf: List[UInt8], batch: RecordBatch
) raises:
    """Fused-encode JSONL writer — hoists ArrowType dispatch out of the
    row loop and emits direct bytes (no per-cell String allocation).

    Drop-in replacement for `encode.write_batch_jsonl`. Output is
    byte-identical for all 13 supported ArrowType arms (verified by
    `tests/test_write_json.mojo::test_byte_identity_fused_vs_legacy`).

    Args:
      buf: Target byte buffer; bytes appended in-place.
      batch: Borrowed RecordBatch. Columns are encoded once each into
             per-column byte pools, then row-transposed into `buf`.

    Implementation: thin wrapper over `write_batch_jsonl_fused_range`
    that emits ALL rows `[0, num_rows)`.
    """
    write_batch_jsonl_fused_range(buf, batch, 0, batch.num_rows())


def write_batch_jsonl_fused_range(
    mut buf: List[UInt8],
    batch: RecordBatch,
    row_start: Int,
    row_end: Int,
) raises:
    """Row-range-bounded fused JSONL writer.

    Emits JSONL bytes for rows `[row_start, row_end)` of `batch` into
    `buf`. The per-column byte pools cover only the requested row range
    so per-worker memory is bounded by `(row_end - row_start) * ~16
    bytes/cell × num_cols` — for a balanced N-worker split of an M-row
    batch, each worker's pool is ~M/N × num_cols × 16 bytes.

    The primary entry consumed by the parallel JSONL sink workers.
    Output is row-for-row byte-identical to
    `write_batch_jsonl_fused(buf, batch)` when called with
    `(0, batch.num_rows())`; the parallel writer concatenates the
    per-worker `[lo_w, hi_w)` outputs in tid order to produce the same
    serial-output bytes.

    Args:
      buf:       Target byte buffer; bytes appended in-place.
      batch:     Borrowed RecordBatch. Columns are encoded into
                 per-column byte pools sized to the row range, then
                 row-transposed into `buf`.
      row_start: Inclusive lower bound on rows to emit.
      row_end:   Exclusive upper bound on rows to emit. Caller must
                 ensure `0 <= row_start <= row_end <= batch.num_rows()`.
    """
    var num_cols = batch.num_columns()
    var n_range = row_end - row_start
    if num_cols == 0 or n_range <= 0:
        return

    # Pre-render column-name JSON-key bytes (escaped) once.
    ref schema = batch.schema
    var keys = List[List[UInt8]]()
    keys.reserve(num_cols)
    for c in range(num_cols):
        var kb = List[UInt8]()
        write_string_escaped(kb, String(schema.field_name(c)))
        keys.append(kb^)

    # Pre-encode each column's row-range into its own
    # (cell_bytes, cell_offsets) pool. `cell_offsets[c]` has length
    # `n_range + 1`: index k is local-row k's (== global-row row_start + k)
    # starting byte offset; index n_range is the sentinel = total bytes.
    var cell_bytes_per_col = List[List[UInt8]]()
    var cell_offsets_per_col = List[List[Int]]()
    cell_bytes_per_col.reserve(num_cols)
    cell_offsets_per_col.reserve(num_cols)
    for c in range(num_cols):
        var cb = List[UInt8]()
        # Pre-reserve a conservative per-column cell-byte capacity to
        # absorb append-doubling reallocations. 16 bytes/cell is a
        # ballpark for mixed Int64/Float64/String/Bool/Date32 columns;
        # any cell that exceeds is handled by amortized-O(1) growth.
        cb.reserve(n_range * 16)
        var co = List[Int]()
        co.reserve(n_range + 1)
        _encode_column_cells_fused(cb, co, batch, c, row_start, row_end)
        cell_bytes_per_col.append(cb^)
        cell_offsets_per_col.append(co^)


    # Pre-reserve `buf` to total output size. This avoids amortized-O(1)
    # capacity-doubling reallocations during the row-emit byte-append
    # hot loop. Total bytes (per-range):
    #   n_range * ('{' + '}' + '\n')             -- framing
    #   + sum_c (n_range * (len(keys[c]) + 1))   -- key + ':'
    #   + (num_cols - 1) * n_range               -- ',' between cols
    #   + sum_c len(cell_bytes_per_col[c])       -- cell payloads
    var per_row_key_chars = 0
    var total_cell_bytes = 0
    for c in range(num_cols):
        per_row_key_chars += len(keys[c]) + 1  # +1 for ':'
        total_cell_bytes += len(cell_bytes_per_col[c])
    var per_row_framing = 3 + (num_cols - 1)  # '{' + '}' + '\n' + commas
    var total_bytes = (
        n_range * (per_row_framing + per_row_key_chars)
        + total_cell_bytes
    )
    buf.reserve(len(buf) + total_bytes)

    # Row-transpose: pure byte-copy from per-column pools.
    # Each row produces: '{' + (key_c0 ':' cell_c0 ',' key_c1 ':' cell_c1 ...) + '}\n'
    # Pre-fuse each `key + ':'` into `key_with_colon[c]` so the inner loop
    # is one `extend(Span)` (memcpy) per column rather than per-byte
    # `append`. The trailing-comma prefix is bundled in as `, key + ':'`
    # for non-first columns, hoisted via `key_or_comma_key[c]`.
    var key_or_comma_key = List[List[UInt8]]()
    key_or_comma_key.reserve(num_cols)
    for c in range(num_cols):
        var kb = List[UInt8]()
        kb.reserve(len(keys[c]) + 2)
        if c > 0:
            kb.append(UInt8(0x2C))  # ,
        # Append all key bytes via bulk extend.
        kb.extend(Span(keys[c]))
        kb.append(UInt8(0x3A))  # :
        key_or_comma_key.append(kb^)

    # Local-row index k = 0..n_range-1 maps to global row row_start + k.
    # The per-column pools were filled by the row-range encoders, so
    # `cell_offsets_per_col[c][k]` already addresses the local-row-k cell.
    for k in range(n_range):
        buf.append(UInt8(0x7B))  # {
        for c in range(num_cols):
            # Bulk extend with `[,]<key>:` prefix.
            buf.extend(Span(key_or_comma_key[c]))
            # Emit this row's cell bytes from the per-column pool.
            ref cb = cell_bytes_per_col[c]
            ref co = cell_offsets_per_col[c]
            var start = co[k]
            var end = co[k + 1]
            # Bulk memcpy this cell's pre-encoded bytes in one shot (not a
            # per-byte `buf.append(cb[k])` loop, which is billions of
            # appends on a large table). The cell bytes are contiguous in `cb`; the slice
            # `Span(cb)[start:end]` is a borrowed view, copied via memcpy.
            buf.extend(Span(cb)[start:end])
        buf.append(UInt8(0x7D))  # }
        buf.append(UInt8(0x0A))  # \n


# =============================================================================
# Row-native JSONL emit.
#
# `write_row_output_jsonl` serializes a `RowOutput`'s RowBlocks DIRECTLY to
# JSONL text — no row->columnar->row-text bridge. It produces BYTE-IDENTICAL
# output to the columnar `write_batch_jsonl_direct` path by
# reusing the EXACT same value formatters:
#   * INT64 / INT32  -> `write_i64_dec` (decimal-string encoder).
#   * FLOAT64 / FLOAT32 -> `write_f64_dtoa` (shortest-round-trip; NaN/Inf ->
#     `null`, refused in a NOT NULL column as the columnar writers refuse
#     it). FLOAT32 is widened to Float64 before the call, MATCHING the
#     column path's `_write_cell_pretty` FLOAT32 arm (`write_f64_dtoa(buf,
#     Float64(arr.get(row)))`).
#   * STRING -> `write_string_escaped` (the same JSON escape lattice + quoting).
#   * NULL cell -> `_append_null_lit` (the 4 bytes `null`), MATCHING the column
#     path (a null cell emits `null`, NOT an absent key — every key is always
#     present, like `write_batch_jsonl_direct`).
#   * column NAME keys -> `write_string_escaped` (pre-escaped ONCE per column,
#     IDENTICAL to `write_batch_jsonl_direct`).
# Per row: `{` + `"key":value` (`,`-separated) + `}` + `\n`. Same byte layout
# as `write_batch_jsonl_direct`.
#
# Encapsulation: reads cells via RowBlock's PUBLIC
# `read_fixed[DT]` / `read_var_string_at` / `is_cell_null`. No raw pointer
# crosses a boundary; no wildcard origin.
# =============================================================================


def write_row_output_jsonl(
    mut buf: List[UInt8], imm ro: RowOutput
) raises:
    """Emit every row of `ro` as JSONL bytes (one `{...}\\n` per row) directly
    into `buf`, byte-identical to the columnar `write_batch_jsonl_direct`
    path over the same logical rows.

    The supported output DType subset matches the row-streaming fast fixed
    subset (DT_I64 / DT_I32 / DT_F64 / DT_F32 / DT_STRING); any other tag
    raises (the row pipeline never produces one for a pure-streaming chain).
    """
    ref layout = ro.layout
    var n_cols = layout.n_cols()
    if n_cols == 0:
        return
    var has_validity = layout.has_validity
    var vo = layout.validity_offset

    # Pre-escape column-name keys ONCE (mirrors write_batch_jsonl_direct).
    ref schema = ro.schema
    var keys = List[List[UInt8]]()
    keys.reserve(n_cols)
    for c in range(n_cols):
        var kb = List[UInt8]()
        write_string_escaped(kb, String(schema.field_name(c)))
        keys.append(kb^)

    # Row number across blocks, for the NOT NULL NaN / +-Inf refusal.
    var row_index = 0
    for bi in range(len(ro.blocks)):
        ref blk = ro.blocks[bi]
        for r in range(blk.n_rows):
            buf.append(UInt8(0x7B))  # {
            var c = 0
            while c < n_cols:
                if c > 0:
                    buf.append(UInt8(0x2C))  # ,
                # Key bytes (pre-escaped) + ':'.
                buf.extend(Span(keys[c]))
                buf.append(UInt8(0x3A))  # :
                var off = layout.offsets[c]
                var dt = layout.dtype_tags[c]
                var is_null = has_validity and blk.is_cell_null(r, vo, c)
                if is_null:
                    _append_null_lit(buf)
                elif dt == DT_I64:
                    write_i64_dec(buf, blk.read_fixed[DType.int64](r, off))
                elif dt == DT_I32:
                    write_i64_dec(
                        buf, Int64(blk.read_fixed[DType.int32](r, off))
                    )
                elif dt == DT_F64 or dt == DT_F32:
                    var v: Float64
                    if dt == DT_F64:
                        v = blk.read_fixed[DType.float64](r, off)
                    else:
                        v = Float64(blk.read_fixed[DType.float32](r, off))
                    if (
                        (_is_nan_f64(v) or _is_inf_f64(v))
                        and not schema.field_nullable(c)
                    ):
                        raise not_null_nonfinite_error(
                            String(schema.field_name(c)), row_index, v
                        )
                    write_f64_dtoa(buf, v)
                elif dt == DT_STRING:
                    var raw = blk.read_var_string_at(r, off)
                    var s = String(StringSlice(unsafe_from_utf8=Span(raw)))
                    write_string_escaped(buf, s)
                else:
                    raise Error(
                        "write_row_output_jsonl: output DType tag "
                        + String(Int(dt))
                        + " outside the row-streaming supported subset."
                    )
                c = c + 1
            buf.append(UInt8(0x7D))  # }
            buf.append(UInt8(0x0A))  # \n
            row_index += 1
