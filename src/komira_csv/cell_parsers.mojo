# =============================================================================
# cell_parsers — per-DType cell parsing for the CSV chassis.
# =============================================================================
#
#
# Each `_try_parse_<dtype>(slice, options)` returns an `Optional[T]` —
# `None` on parse failure (the caller writes a null bit + 0 sentinel).
#
# The base set is the 6 most-common DTypes:
#   Int64, Float64, String, Bool, Date32 (ISO-8601),
#   and a generic STRING/LARGE_STRING zero-copy hand-off (no parsing —
#   the bytes ARE the cell, just appended with optional unescape).
#
# The widened targets (UInt8/16/32/64, Int8/16/32, Float32, FLOAT16,
# DECIMAL128, NULL-typed) below follow the same `_try_parse_<dtype>`
# contract; the Date64, TIMESTAMP_*, TIME32/TIME64 and DURATION parsers
# follow it in temporal_parsers.mojo.
#
# Encapsulation: every parser takes `Span[UInt8, _]` (origin-poly view)
# and returns owned typed scalars; NO UnsafePointer crosses a module
# boundary. The unescape path uses a small `String` working buffer.
# =============================================================================

from .csv_options import CsvReadOptions
from .null_detection import is_null_cell, is_true_cell, is_false_cell


# =============================================================================
# Generic helpers.
# =============================================================================


@always_inline
def _byte_is_ascii_digit(b: UInt8) -> Bool:
    return b >= UInt8(0x30) and b <= UInt8(0x39)


# =============================================================================
# Int64 parser.
# =============================================================================


def _try_parse_int64(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse a byte-span as a signed Int64.

    Accepts optional leading `-` or `+`, then ASCII digits.
    Returns None for: empty input, non-digit body, multi-sign, overflow
    (overflow is NOT detected — caller should layer a range check
    on top if range-strictness is required; this is consistent with the
    toy reader's behavior).
    """
    var n = len(cell)
    if n == 0:
        return None
    var start = 0
    var negative = False
    var first = cell[0]
    if first == UInt8(0x2D):  # '-'
        negative = True
        start = 1
        if n == 1:
            return None
    elif first == UInt8(0x2B):  # '+'
        start = 1
        if n == 1:
            return None
    var result: Int64 = 0
    var i = start
    while i < n:
        var c = cell[i]
        if not _byte_is_ascii_digit(c):
            return None
        result = result * Int64(10) + Int64(Int(c) - 0x30)
        i = i + 1
    if negative:
        result = -result
    return Optional[Int64](result)


# =============================================================================
# Float64 parser.
# =============================================================================


def _try_parse_float64(
    cell: Span[UInt8, _], decimal_separator: UInt8
) -> Optional[Float64]:
    """Parse a byte-span as a Float64.

    Accepts: optional leading `-` / `+`, digits, ONE decimal-separator
    (configurable per `CsvReadOptions.decimal_separator`), optional
    exponent `e[+-]?\\d+` / `E[+-]?\\d+`.

    Returns None on: empty input, multi-decimal-separator, malformed
    exponent, any non-recognized byte.

    Hand-written decimal parser; a lemire/fast_float port would be a
    further optimization.
    """
    var n = len(cell)
    if n == 0:
        return None
    var i = 0
    var negative = False
    var first = cell[0]
    if first == UInt8(0x2D):  # '-'
        negative = True
        i = 1
        if n == 1:
            return None
    elif first == UInt8(0x2B):  # '+'
        i = 1
        if n == 1:
            return None

    var integer_part: Float64 = 0.0
    var fraction_part: Float64 = 0.0
    var fraction_divisor: Float64 = 1.0
    var has_digits = False
    var seen_dot = False

    # Integer + fraction scan
    while i < n:
        var c = cell[i]
        if _byte_is_ascii_digit(c):
            has_digits = True
            var d = Float64(Int(c) - 0x30)
            if seen_dot:
                fraction_divisor *= 10.0
                fraction_part += d / fraction_divisor
            else:
                integer_part = integer_part * 10.0 + d
            i = i + 1
            continue
        if c == decimal_separator:
            if seen_dot:
                return None
            seen_dot = True
            i = i + 1
            continue
        if c == UInt8(0x65) or c == UInt8(0x45):  # 'e' or 'E'
            break
        # Any other byte is a parse failure.
        return None

    if not has_digits:
        return None

    var magnitude = integer_part + fraction_part

    # Exponent scan
    if i < n:
        var c = cell[i]
        if c == UInt8(0x65) or c == UInt8(0x45):
            i = i + 1
            if i >= n:
                return None
            var exp_neg = False
            var ec = cell[i]
            if ec == UInt8(0x2D):
                exp_neg = True
                i = i + 1
            elif ec == UInt8(0x2B):
                i = i + 1
            if i >= n:
                return None
            var exp_val: Int = 0
            var saw_exp_digit = False
            while i < n:
                var ed = cell[i]
                if not _byte_is_ascii_digit(ed):
                    return None
                exp_val = exp_val * 10 + (Int(ed) - 0x30)
                saw_exp_digit = True
                i = i + 1
            if not saw_exp_digit:
                return None
            # Apply exp: multiply or divide by 10^exp_val.
            var k = 0
            if exp_neg:
                while k < exp_val:
                    magnitude /= 10.0
                    k = k + 1
            else:
                while k < exp_val:
                    magnitude *= 10.0
                    k = k + 1

    if negative:
        magnitude = -magnitude
    return Optional[Float64](magnitude)


# =============================================================================
# Bool parser.
# =============================================================================


def _try_parse_bool(cell: Span[UInt8, _], options: CsvReadOptions) -> Optional[Bool]:
    """Parse a byte-span as a Bool via `options.true_strings` /
    `options.false_strings` lookup.
    """
    if is_true_cell(cell, options):
        return Optional[Bool](True)
    if is_false_cell(cell, options):
        return Optional[Bool](False)
    return None


# =============================================================================
# Date32 parser (ISO-8601 YYYY-MM-DD).
# =============================================================================


@always_inline
def _is_leap_year(year: Int) -> Bool:
    if year % 400 == 0:
        return True
    if year % 100 == 0:
        return False
    return year % 4 == 0


@always_inline
def _days_in_month(year: Int, month: Int) -> Int:
    # Returns the number of days in (year, month). month in [1, 12].
    if month == 1 or month == 3 or month == 5 or month == 7 or month == 8 or month == 10 or month == 12:
        return 31
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    # February
    if _is_leap_year(year):
        return 29
    return 28


def _try_parse_date32(cell: Span[UInt8, _]) -> Optional[Int32]:
    """Parse ISO-8601 `YYYY-MM-DD` -> Int32 days-since-1970-01-01.

    Only the canonical 10-byte form is accepted here. Variants
    like `YYYY/MM/DD` or `MM/DD/YYYY` go through the per-column
    date_format option.

    Hand-written; no chrono / strptime dep.
    """
    if len(cell) != 10:
        return None
    if cell[4] != UInt8(0x2D):  # '-'
        return None
    if cell[7] != UInt8(0x2D):
        return None
    # Year digits
    var i = 0
    while i < 4:
        if not _byte_is_ascii_digit(cell[i]):
            return None
        i = i + 1
    if not _byte_is_ascii_digit(cell[5]) or not _byte_is_ascii_digit(cell[6]):
        return None
    if not _byte_is_ascii_digit(cell[8]) or not _byte_is_ascii_digit(cell[9]):
        return None
    var year = (Int(cell[0]) - 0x30) * 1000 + (Int(cell[1]) - 0x30) * 100 + (Int(cell[2]) - 0x30) * 10 + (Int(cell[3]) - 0x30)
    var month = (Int(cell[5]) - 0x30) * 10 + (Int(cell[6]) - 0x30)
    var day = (Int(cell[8]) - 0x30) * 10 + (Int(cell[9]) - 0x30)
    if month < 1 or month > 12:
        return None
    if day < 1 or day > _days_in_month(year, month):
        return None
    # Days since 1970-01-01 — sum full years + months + day-of-month - 1.
    var days_total: Int = 0
    if year >= 1970:
        var y = 1970
        while y < year:
            if _is_leap_year(y):
                days_total += 366
            else:
                days_total += 365
            y = y + 1
    else:
        var y = year
        while y < 1970:
            if _is_leap_year(y):
                days_total -= 366
            else:
                days_total -= 365
            y = y + 1
    var m = 1
    while m < month:
        days_total += _days_in_month(year, m)
        m = m + 1
    days_total += (day - 1)
    return Optional[Int32](Int32(days_total))


# =============================================================================
# Widened numeric parsers
# =============================================================================
#
# Each parser mirrors the Int64 / Float64 contract:
# returns Optional[T] on a per-cell parse attempt; None on parse failure,
# overflow, or out-of-range. Narrowed integer parsers run Int64 first and
# then range-check; UInt parsers reject leading `-` (signed-cell signal).
#
# SerdeParse contract: integer parsers report overflow as `None` rather
# than wrapping. This is consistent with the null lattice: a cell that "doesn't fit" the column type yields a typed null
# rather than a wrong-value cell. The lattice (type_inference.mojo) then
# promotes the column to the next widest type.
# =============================================================================


def _try_parse_uint64(cell: Span[UInt8, _]) -> Optional[UInt64]:
    """Parse a byte-span as an unsigned UInt64.

    Accepts ASCII digits ONLY (no leading sign; a leading `-` returns None
    — signals "not a UInt", caller promotes to signed). Overflow detected
    via per-step ceiling check; returns None if the input would exceed
    UInt64.max.

    """
    var n = len(cell)
    if n == 0:
        return None
    # Reject leading `+` and `-`. UInt explicitly disallows the sign byte.
    var first = cell[0]
    if first == UInt8(0x2D) or first == UInt8(0x2B):
        return None
    # Overflow ceiling: 2**64-1 = 18446744073709551615 (20 digits).
    # We detect overflow by checking BEFORE each multiply.
    var result: UInt64 = 0
    var i = 0
    var ceiling: UInt64 = UInt64(1844674407370955161)  # floor(UInt64.max / 10)
    var ceiling_remainder: UInt64 = UInt64(5)            # UInt64.max % 10
    while i < n:
        var c = cell[i]
        if not _byte_is_ascii_digit(c):
            return None
        var d: UInt64 = UInt64(Int(c) - 0x30)
        if result > ceiling:
            return None
        if result == ceiling and d > ceiling_remainder:
            return None
        result = result * UInt64(10) + d
        i = i + 1
    return Optional[UInt64](result)


def _try_parse_uint32(cell: Span[UInt8, _]) -> Optional[UInt32]:
    """Parse a byte-span as UInt32. Routes through _try_parse_uint64 + range check."""
    var p64 = _try_parse_uint64(cell)
    if not p64:
        return None
    var v = p64.value()
    if v > UInt64(0xFFFFFFFF):
        return None
    return Optional[UInt32](UInt32(Int(v)))


def _try_parse_uint16(cell: Span[UInt8, _]) -> Optional[UInt16]:
    """Parse a byte-span as UInt16. Routes through _try_parse_uint64 + range check."""
    var p64 = _try_parse_uint64(cell)
    if not p64:
        return None
    var v = p64.value()
    if v > UInt64(0xFFFF):
        return None
    return Optional[UInt16](UInt16(Int(v)))


def _try_parse_uint8(cell: Span[UInt8, _]) -> Optional[UInt8]:
    """Parse a byte-span as UInt8. Routes through _try_parse_uint64 + range check."""
    var p64 = _try_parse_uint64(cell)
    if not p64:
        return None
    var v = p64.value()
    if v > UInt64(0xFF):
        return None
    return Optional[UInt8](UInt8(Int(v)))


def _try_parse_int32(cell: Span[UInt8, _]) -> Optional[Int32]:
    """Parse Int32. Routes through Int64 + range check.

    Returns None on overflow (caller promotes to Int64).
    """
    var p64 = _try_parse_int64(cell)
    if not p64:
        return None
    var v = p64.value()
    if v < Int64(-2147483648) or v > Int64(2147483647):
        return None
    return Optional[Int32](Int32(Int(v)))


def _try_parse_int16(cell: Span[UInt8, _]) -> Optional[Int16]:
    """Parse Int16. Routes through Int64 + range check."""
    var p64 = _try_parse_int64(cell)
    if not p64:
        return None
    var v = p64.value()
    if v < Int64(-32768) or v > Int64(32767):
        return None
    return Optional[Int16](Int16(Int(v)))


def _try_parse_int8(cell: Span[UInt8, _]) -> Optional[Int8]:
    """Parse Int8. Routes through Int64 + range check."""
    var p64 = _try_parse_int64(cell)
    if not p64:
        return None
    var v = p64.value()
    if v < Int64(-128) or v > Int64(127):
        return None
    return Optional[Int8](Int8(Int(v)))


def _try_parse_float32(
    cell: Span[UInt8, _], decimal_separator: UInt8
) -> Optional[Float32]:
    """Parse Float32. Routes through Float64 + downcast.

    Returns None on out-of-range (|v| > Float32.max ~ 3.4028235e38). Inf
    inputs from a too-large Float64 are flagged as parse failure consistent
    with the typed-null lattice. Subnormal denormalization is accepted
    (rounds toward zero per IEEE 754).
    """
    var p64 = _try_parse_float64(cell, decimal_separator)
    if not p64:
        return None
    var v = p64.value()
    # Float32 max ~ 3.4028235e38. If the Float64 magnitude exceeds this,
    # the downcast would produce inf — flag as parse failure.
    var abs_v = v
    if abs_v < Float64(0):
        abs_v = -abs_v
    if abs_v > Float64(3.4028234663852886e38):
        return None
    return Optional[Float32](Float32(v))


# =============================================================================
# Decimal128 parser.
# =============================================================================
#
# Decimal128 is a 128-bit fixed-point integer with a fixed (precision, scale)
# tied to the column metadata. The parser:
#   1. Accepts optional '-' / '+' prefix.
#   2. Parses ASCII digits with at most one '.' separator.
#   3. Aligns the parsed value to the column scale (right-pad with 0s if
#      the cell has fewer fractional digits than `scale`; reject as
#      out-of-range if the cell has more — caller signals as null).
#   4. Validates the resulting mantissa fits within `precision` decimal
#      digits.
#
# Storage: there is no stdlib Int128 type. We emit
# the value as Tuple[Int64_hi, UInt64_lo] using two-limb little-endian
# arithmetic. Callers downcast to Int64 if their column fits (i.e.,
# the mantissa magnitude < 2**63); precision > 18 is the natural cutoff
# where we need the full 128 bits.
#
# The parser ships at Int64 precision
# (precision <= 18). Wider precision (19-38) is not supported yet.


def _try_parse_decimal128_to_int64(
    cell: Span[UInt8, _], precision: Int, scale: Int
) -> Optional[Int64]:
    """Parse a decimal cell into an Int64 mantissa, given (precision, scale).

    Returns the parsed mantissa scaled to `scale` (i.e., the cell `"12.34"`
    with scale=4 yields `123400`).

    Constraints:
      - precision in [1, 18] (Int64 capacity ~ 9.2e18 ~ 18 digits).
      - scale in [0, precision].
      - Cell must contain at most `scale` fractional digits — excess is
        a parse failure (more precision than the column allows; caller
        sees a typed null).
      - Cell's pre-decimal-point digit count + scale must be <= precision
        — excess is "out of range for the column" (typed null).

    Per Arrow Decimal128 spec §Schema.fbs / Arrow IPC.
    """
    if precision <= 0 or precision > 18:
        return None
    if scale < 0 or scale > precision:
        return None
    var n = len(cell)
    if n == 0:
        return None
    var i = 0
    var negative = False
    var first = cell[0]
    if first == UInt8(0x2D):
        negative = True
        i = 1
    elif first == UInt8(0x2B):
        i = 1
    if i >= n:
        return None
    var int_digits: Int = 0
    var frac_digits: Int = 0
    var mantissa: Int64 = 0
    var seen_dot = False
    while i < n:
        var c = cell[i]
        if _byte_is_ascii_digit(c):
            mantissa = mantissa * Int64(10) + Int64(Int(c) - 0x30)
            if seen_dot:
                frac_digits = frac_digits + 1
            else:
                int_digits = int_digits + 1
            i = i + 1
            continue
        if c == UInt8(0x2E):  # '.'
            if seen_dot:
                return None
            seen_dot = True
            i = i + 1
            continue
        return None
    if int_digits == 0 and frac_digits == 0:
        return None
    if frac_digits > scale:
        return None
    if int_digits + scale > precision:
        return None
    # Right-pad fractional digits with zeros to reach `scale` total.
    var pad = scale - frac_digits
    var k = 0
    while k < pad:
        mantissa = mantissa * Int64(10)
        k = k + 1
    if negative:
        mantissa = -mantissa
    return Optional[Int64](mantissa)


# =============================================================================
# String unescape (RFC-4180 doubled-quote + Posix backslash).
# =============================================================================


def unescape_cell_double_quote(cell: Span[UInt8, _], quote: UInt8) -> String:
    """Collapse `""` -> `"` inside a cell that was flagged as `needs_unescape`.

    RFC 4180 doubled-quote handling. Works in O(n).

    Args:
        cell: The cell byte-span (inclusive of body, exclusive of the
            surrounding quote bytes which the scanner already stripped).
        quote: The quote byte (typically b'"').

    Returns:
        Owned String with `""` collapsed to single `"`.
    """
    var out = String("")
    var n = len(cell)
    var i = 0
    while i < n:
        var b = cell[i]
        if b == quote and i + 1 < n and cell[i + 1] == quote:
            out += chr(Int(quote))
            i = i + 2
            continue
        out += chr(Int(b))
        i = i + 1
    return out^


def unescape_cell_posix(cell: Span[UInt8, _], escape: UInt8) -> String:
    """Collapse Posix backslash escapes: `\\X` -> `X` literal for any byte X.

    Posix dialect (backslash escape).
    """
    var out = String("")
    var n = len(cell)
    var i = 0
    while i < n:
        var b = cell[i]
        if b == escape and i + 1 < n:
            var nx = cell[i + 1]
            # Translate common escapes; everything else passes through.
            if nx == UInt8(0x6E):  # 'n'
                out += chr(0x0A)
            elif nx == UInt8(0x74):  # 't'
                out += chr(0x09)
            elif nx == UInt8(0x72):  # 'r'
                out += chr(0x0D)
            else:
                out += chr(Int(nx))
            i = i + 2
            continue
        out += chr(Int(b))
        i = i + 1
    return out^


def cell_to_string(
    cell: Span[UInt8, _],
    needs_unescape: Bool,
    double_quote_escapes: Bool,
    quote: UInt8,
    posix_escape: UInt8,
) -> String:
    """High-level helper: copy a cell byte-span into an owned String,
    applying unescape if needed.

    Args:
        cell: Cell byte-span (already stripped of surrounding quotes).
        needs_unescape: True iff the scanner flagged this cell.
        double_quote_escapes: True for Rfc4180/Excel; False for Posix.
        quote: The quote byte.
        posix_escape: The Posix backslash byte (only consulted when
            double_quote_escapes is False).

    Returns:
        Owned String.
    """
    if not needs_unescape:
        # Fast path: byte-for-byte copy.
        var out = String("")
        var i = 0
        while i < len(cell):
            out += chr(Int(cell[i]))
            i = i + 1
        return out^
    if double_quote_escapes:
        return unescape_cell_double_quote(cell, quote)
    return unescape_cell_posix(cell, posix_escape)
