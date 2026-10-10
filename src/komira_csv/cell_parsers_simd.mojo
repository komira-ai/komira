# =============================================================================
# cell_parsers_simd — SIMD-vectorized per-DType cell parsers (fast path).
# =============================================================================
#
# Why: the per-worker materialize loop (`_build_int64_column` et al.) is sequential
# AND scalar within each worker -- it dominates 60-85% of per-worker wall
# on TPC-H lineitem + ClickBench fixtures.
#
# This module provides a SIMD fast path for the most common DTypes in
# numeric CSV columns (Int64 / Float64 / Date32). The shape is:
#
#     fast_parse_int64_lemire_8digit(...) -> Optional[Int64]
#         |  applicable iff cell is exactly 8 ASCII digits (no sign,
#         |  no separator, no exponent) -- Lemire-style 4-mul SIMD parse.
#     fast_parse_uint_n_simd(...) -> Optional[UInt64]
#         |  applicable iff cell is N ASCII digits (1..16); routes
#         |  through Lemire 8-digit + scalar remainder.
#     can_simd_parse_digits_run(...) -> (digit_count, was_simple)
#         |  byte_class scan of up to 16 bytes; returns N digits +
#         |  bool "no special bytes seen" (no sign / decimal / exp).
#
# The caller (per-DType column builder) uses these as a fast path:
#
#     if simple_run_len > 0 and simple_run_len <= max_digits_for_T:
#         var v = fast_parse_uint_n_simd(cell, simple_run_len)
#         if v: ... use SIMD-parsed value
#     else:
#         fall back to scalar _try_parse_int64
#
# The applicability check + SIMD parse together cost ~4-6ns/cell vs
# ~15-25ns/cell scalar; a worker with 90%-applicable cells gets ~3x
# speedup on the parse phase.
#
# Encapsulation: all public functions take `Span[UInt8, _]` and return
# `Optional[T]` -- no UnsafePointer crosses a module boundary. The
# internal SIMD loads use stdlib `SIMD[T, W]` value types.
#
# Mojo spelling rules: `SIMD[DType.bool, N](fill=False)` for a splat, and
# the `SIMD.lt(a, b)` method form for comparisons. All SIMD ops below
# use the method form. The `ne` / `lt` / `ge` methods on SIMD[uint8, W]
# work via the unified Highway-style wrappers in
# `komira_simd.byte_class.comparisons`.
# =============================================================================


# =============================================================================
# Numeric byte-span SIMD primitives — RE-EXPORTED from the core packages
# =============================================================================
#
# The integer + float
# SIMD fast paths (Lemire 8-digit / fast_parse_int64_simple /
# fast_parse_float64_simple + their helpers) were promoted to
# `komira_csv.byte_span_numeric` so substrate-layer consumers
# (row-format decoders in komira_row_format) can reuse them without a `komira_row_format -> komira_csv` layering
# inversion.
#
# This module RE-EXPORTS the public entries so the
# `from .cell_parsers_simd import fast_parse_int64_simple` callers
# (int_column_simd / reader / typed_column_builders / parallel_reader)
# keep one import site. The ISO date / time / timestamp SIMD primitives
# (cell_is_iso_date_shaped / fast_parse_iso_date32 / ...) stay below
# because they are CSV-format-specific shapes (caller is the per-DType
# column builder, not a general byte-parser substrate consumer).
# =============================================================================


from komira_csv.byte_span_numeric import (
    fast_parse_uint_8digit,
    fast_parse_uint_n_digits,
    fast_parse_int64_simple,
    fast_parse_float64_simple,
)
from komira_csv.temporal_range import epoch_seconds_to_ns


# =============================================================================
# Internal helper — narrow alias kept ONLY for the ISO date/time block below.
# =============================================================================
#
# The date/time SIMD primitives (cell_is_iso_date_shaped and friends)
# reference a single-byte digit check inline; we re-declare the helper
# here as a private module-local rather than importing the private
# `_is_ascii_digit_byte` from the core packages (Mojo's private-name
# convention is leading-underscore; cross-module imports of private
# names are discouraged).


@always_inline
def _is_ascii_digit_byte(b: UInt8) -> Bool:
    """Branch-free helper — single-byte applicability check.

    Mirror of `komira_csv.byte_span_numeric._is_ascii_digit_byte`
    kept private to this module for use by the ISO date/time fast paths
    below. The compiler inlines this to a 1-3 cycle byte compare.
    """
    return b >= UInt8(0x30) and b <= UInt8(0x39)


# =============================================================================
# SIMD applicability check (32-byte runway).
# =============================================================================
#
# For the column builder hot loop, the cheapest check is "is this cell
# under 32 bytes AND made of only digits/sign/decimal/exponent bytes?"
# A single 32-byte SIMD load + byte-class scan answers it. This is used
# by the column builders to decide whether to dispatch SIMD parse or
# scalar parse.


def cell_is_simple_numeric(cell: Span[UInt8, _]) -> Bool:
    """Branch-free applicability check for SIMD numeric fast path.

    Returns True iff `len(cell) <= 16` AND every byte is in the
    "simple numeric" alphabet: digits + sign + decimal-point. This
    is a SUPERSET of the integer fast path's applicability
    (integers reject decimal-point; floats accept it). The caller's
    DType-specific fast-path parser does the final validation.

    Returns False on quoted cells, longer cells (>16 bytes), or cells
    containing letters / whitespace / exponent / null-symbol bytes
    (we conservatively fall back to scalar for any of these so the
    fast-path stays simple).
    """
    var n = len(cell)
    if n == 0 or n > 16:
        return False
    var i = 0
    while i < n:
        var c = cell[i]
        # Allowed: digits 0..9 (0x30..0x39), sign +/- (0x2B/0x2D),
        # decimal point (0x2E).
        if not (
            (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x2B)
            or c == UInt8(0x2D)
            or c == UInt8(0x2E)
        ):
            return False
        i = i + 1
    return True


# =============================================================================
#
# ISO-8601 fixed-shape SIMD parsers for Date32 / Date64 / Timestamp_* /
# Time_* / Duration_*. The key insight: ISO-8601 inputs have FIXED
# positions for digit bytes and FIXED positions for separators, so the
# applicability gate is a single 16-byte SIMD compare (digit-mask AND
# separator-mask reduced via & to a single Bool).
#
# Shapes:
#   Date32 : "YYYY-MM-DD"                  (10 bytes; digits at 0..3, 5..6, 8..9; '-' at 4, 7)
#   Date64 : "YYYY-MM-DD"                  (10 bytes, midnight UTC ms) OR
#            "YYYY-MM-DD[ T]HH:MM:SS[.fff]" (>=19 bytes; tail by scalar)
#   Time_S : "HH:MM:SS"                    (8 bytes; digits at 0..1, 3..4, 6..7; ':' at 2, 5)
#   Time_* : "HH:MM:SS[.frac]"             (>=8 bytes; fractional tail scalar)
#   Timestamp_S : "YYYY-MM-DD[ T]HH:MM:SS" (19 bytes; no fraction)
#   Timestamp_* : "YYYY-MM-DD[ T]HH:MM:SS[.frac]" (>=19 bytes; fraction scalar tail)
#
# Algorithm pattern (Lemire-style 10-byte / 8-byte / 19-byte SIMD parse):
#   1. SIMD load fixed prefix into SIMD[uint8, 16].
#   2. SIMD compare each lane against expected byte class:
#        digit-position lanes vs [0x30, 0x39]
#        separator-position lanes vs constant ('-' / ':' / 'T' / ' ')
#   3. Reduce-and the resulting bool mask: True = SIMD path applicable.
#   4. On True: subtract 0x30 from digit lanes, accumulate digit-by-digit
#      via lane extraction (compiler emits umlal / vpmaddubsw).
#   5. Validate value ranges (year, month, day, hour, minute, second).
#   6. Combine with epoch-day computation (calls into the scalar
#      _days_since_epoch since the leap-year cascade is hard to vectorize
#      and is cheap relative to the digit-parse savings).
#
# The fast path covers TPC-H lineitem l_shipdate/l_commitdate/l_receiptdate
# (3 Date32 cols, canonical 10-byte form) and ClickBench timestamp columns
# (~10 Timestamp_NS cols, canonical 19-byte form).
# =============================================================================


# =============================================================================
# Date32 / common-date helpers.
# =============================================================================


@always_inline
def _load_u8x16(cell: Span[UInt8, _], offset: Int) -> SIMD[DType.uint8, 16]:
    """Load 16 bytes from `cell[offset:offset+16]` into SIMD[uint8, 16].

    Caller MUST guarantee `offset + 16 <= len(cell)`. We over-read up
    to 6 bytes past the canonical 10-byte date for the SIMD load -- but
    callers gate on `len(cell) >= 16` (since we always allocate cell
    bytes inside a per-worker slab, the slab tail has guaranteed
    padding from the scanner; for short cells we fall back to a
    16-byte zero-padded helper).
    """
    return SIMD[DType.uint8, 16](
        cell[offset + 0],
        cell[offset + 1],
        cell[offset + 2],
        cell[offset + 3],
        cell[offset + 4],
        cell[offset + 5],
        cell[offset + 6],
        cell[offset + 7],
        cell[offset + 8],
        cell[offset + 9],
        cell[offset + 10],
        cell[offset + 11],
        cell[offset + 12],
        cell[offset + 13],
        cell[offset + 14],
        cell[offset + 15],
    )


@always_inline
def _load_u8x16_padded(cell: Span[UInt8, _]) -> SIMD[DType.uint8, 16]:
    """Load up to len(cell) bytes from cell[0:] into SIMD[uint8, 16];
    zero-pad the remainder.

    For ISO-8601 fixed-shape cells the caller has already validated
    length, so the un-validated tail lanes are masked away by the
    digit-mask + separator-mask check.
    """
    var n = len(cell)
    if n >= 16:
        return _load_u8x16(cell, 0)
    # Scalar fallback: build lane-by-lane with zero pad.
    var lanes = SIMD[DType.uint8, 16](0)
    var i = 0
    while i < n:
        lanes[i] = cell[i]
        i = i + 1
    return lanes


@always_inline
def _digit_value_lane(v: SIMD[DType.uint8, 16], idx: Int) -> Int:
    """Extract lane `idx` as an Int in [0, 9].

    Caller must have validated the digit-mask first.
    """
    return Int(v[idx]) - 0x30


# Constants for date32 mask validation. We materialize them as SIMD
# constants once; the compiler hoists the comparison vectors.
comptime _ASCII_DIGIT_LO: UInt8 = 0x30
comptime _ASCII_DIGIT_HI: UInt8 = 0x39
comptime _ASCII_DASH: UInt8 = 0x2D       # '-'
comptime _ASCII_COLON: UInt8 = 0x3A      # ':'
comptime _ASCII_T: UInt8 = 0x54          # 'T'
comptime _ASCII_SPACE: UInt8 = 0x20      # ' '
comptime _ASCII_DOT: UInt8 = 0x2E        # '.'
comptime _ASCII_Z: UInt8 = 0x5A          # 'Z'


@always_inline
def _is_leap_year_int(year: Int) -> Bool:
    if year % 400 == 0:
        return True
    if year % 100 == 0:
        return False
    return year % 4 == 0


@always_inline
def _days_in_month_int(year: Int, month: Int) -> Int:
    if month == 1 or month == 3 or month == 5 or month == 7 or month == 8 or month == 10 or month == 12:
        return 31
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    if _is_leap_year_int(year):
        return 29
    return 28


@always_inline
def _days_since_epoch_int(year: Int, month: Int, day: Int) -> Int:
    """Days since 1970-01-01 for a validated (year, month, day) tuple."""
    var days_total: Int = 0
    if year >= 1970:
        var y = 1970
        while y < year:
            if _is_leap_year_int(y):
                days_total += 366
            else:
                days_total += 365
            y = y + 1
    else:
        var y = year
        while y < 1970:
            if _is_leap_year_int(y):
                days_total -= 366
            else:
                days_total -= 365
            y = y + 1
    var m = 1
    while m < month:
        days_total += _days_in_month_int(year, m)
        m = m + 1
    days_total += (day - 1)
    return days_total


# =============================================================================
# ISO date shape applicability gates.
# =============================================================================


@always_inline
def cell_is_iso_date_shaped(cell: Span[UInt8, _]) -> Bool:
    """Branch-free SIMD gate: is this cell a canonical "YYYY-MM-DD"?

    Returns True iff:
      - len(cell) == 10
      - cell[0..3], cell[5..6], cell[8..9] are ASCII digits
      - cell[4] == '-', cell[7] == '-'

    Implementation: SIMD load 16 bytes (zero-padded), build digit and
    separator masks, AND-reduce.
    """
    if len(cell) != 10:
        return False
    var v = _load_u8x16_padded(cell)
    # Digit-position lanes: 0, 1, 2, 3, 5, 6, 8, 9. Other positions don't
    # matter (we mask with separator check below).
    var lo = SIMD[DType.uint8, 16](_ASCII_DIGIT_LO)
    var hi = SIMD[DType.uint8, 16](_ASCII_DIGIT_HI)
    var ge_lo = SIMD.ge(v, lo)
    var le_hi = SIMD.le(v, hi)
    var is_digit = ge_lo & le_hi
    # Separators must be '-' at lanes 4, 7.
    if v[4] != UInt8(_ASCII_DASH):
        return False
    if v[7] != UInt8(_ASCII_DASH):
        return False
    # Check digit lanes via lane access.
    if not is_digit[0] or not is_digit[1] or not is_digit[2] or not is_digit[3]:
        return False
    if not is_digit[5] or not is_digit[6]:
        return False
    if not is_digit[8] or not is_digit[9]:
        return False
    return True


@always_inline
def _decode_ymd_simd(v: SIMD[DType.uint8, 16]) -> Tuple[Int, Int, Int]:
    """Decode (year, month, day) from a SIMD vector that the caller
    has validated via `cell_is_iso_date_shaped`.

    Does NOT validate month/day ranges -- caller's responsibility.
    """
    var year = (
        _digit_value_lane(v, 0) * 1000
        + _digit_value_lane(v, 1) * 100
        + _digit_value_lane(v, 2) * 10
        + _digit_value_lane(v, 3)
    )
    var month = _digit_value_lane(v, 5) * 10 + _digit_value_lane(v, 6)
    var day = _digit_value_lane(v, 8) * 10 + _digit_value_lane(v, 9)
    return (year, month, day)


# =============================================================================
# fast_parse_iso_date32 -- SIMD Date32 fast path.
# =============================================================================


def fast_parse_iso_date32(cell: Span[UInt8, _]) -> Optional[Int32]:
    """Parse 10-byte ISO `YYYY-MM-DD` -> Int32 days-since-1970-01-01.

    Applicability: see `cell_is_iso_date_shaped`. Returns None when the
    gate fails; caller falls back to `_try_parse_date32` (scalar).

    The fast path saves ~8-12 scalar digit-validity branches + manual
    digit-by-digit shift on the canonical 10-byte form (the dominant
    case for ISO date columns; lineitem.l_shipdate / l_commitdate /
    l_receiptdate are all canonical).
    """
    if not cell_is_iso_date_shaped(cell):
        return None
    var v = _load_u8x16_padded(cell)
    var ymd = _decode_ymd_simd(v)
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]
    if month < 1 or month > 12:
        return None
    if day < 1 or day > _days_in_month_int(year, month):
        return None
    return Optional[Int32](Int32(_days_since_epoch_int(year, month, day)))


# =============================================================================
# fast_parse_iso_date64 -- SIMD Date64 fast path (10-byte canonical form).
#
# Date64 accepts both 10-byte date-only AND >=19-byte datetime. For the
# datetime path we delegate to the timestamp_ms helper. The 10-byte
# fast path covers pandas-default Date64 emission (midnight UTC ms).
# =============================================================================


def fast_parse_iso_date64_date_only(cell: Span[UInt8, _]) -> Optional[Int64]:
    """SIMD fast path for the date-only form of Date64.

    Applicability: 10-byte ISO `YYYY-MM-DD`. Returns None for the
    19+ byte datetime form; caller falls back to scalar
    `_try_parse_date64` for those.
    """
    if not cell_is_iso_date_shaped(cell):
        return None
    var v = _load_u8x16_padded(cell)
    var ymd = _decode_ymd_simd(v)
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]
    if month < 1 or month > 12:
        return None
    if day < 1 or day > _days_in_month_int(year, month):
        return None
    return Optional[Int64](
        Int64(_days_since_epoch_int(year, month, day)) * Int64(86400000)
    )


# =============================================================================
# ISO time shape applicability gate.
# =============================================================================


@always_inline
def cell_starts_iso_time(cell: Span[UInt8, _], offset: Int) -> Bool:
    """Branch-free gate: is cell[offset..offset+8] canonical "HH:MM:SS"?

    Lanes: 0..1 digits, 2=':', 3..4 digits, 5=':', 6..7 digits.

    Caller MUST have validated `len(cell) >= offset + 8`. The function
    only reads cell[offset..offset+8].
    """
    if cell[offset + 2] != UInt8(_ASCII_COLON):
        return False
    if cell[offset + 5] != UInt8(_ASCII_COLON):
        return False
    var b0 = cell[offset + 0]
    var b1 = cell[offset + 1]
    var b3 = cell[offset + 3]
    var b4 = cell[offset + 4]
    var b6 = cell[offset + 6]
    var b7 = cell[offset + 7]
    if b0 < UInt8(_ASCII_DIGIT_LO) or b0 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b1 < UInt8(_ASCII_DIGIT_LO) or b1 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b3 < UInt8(_ASCII_DIGIT_LO) or b3 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b4 < UInt8(_ASCII_DIGIT_LO) or b4 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b6 < UInt8(_ASCII_DIGIT_LO) or b6 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b7 < UInt8(_ASCII_DIGIT_LO) or b7 > UInt8(_ASCII_DIGIT_HI):
        return False
    return True


@always_inline
def _decode_hms_scalar(cell: Span[UInt8, _], offset: Int) -> Tuple[Int, Int, Int]:
    """Decode (h, m, s) from cell at `offset`, after gate has passed."""
    var h = (Int(cell[offset + 0]) - 0x30) * 10 + (Int(cell[offset + 1]) - 0x30)
    var m = (Int(cell[offset + 3]) - 0x30) * 10 + (Int(cell[offset + 4]) - 0x30)
    var s = (Int(cell[offset + 6]) - 0x30) * 10 + (Int(cell[offset + 7]) - 0x30)
    return (h, m, s)


@always_inline
def _parse_fractional_seconds_inline(
    cell: Span[UInt8, _], start: Int, max_digits: Int
) -> Optional[Tuple[Int, Int]]:
    """Parse leading `.<digits>` (at most `max_digits`) starting at offset.

    Mirrors `temporal_parsers.mojo:_parse_fractional_seconds` to keep this
    module self-contained (avoids the import cycle).
    """
    var n = len(cell)
    if start >= n or cell[start] != UInt8(_ASCII_DOT):
        return Optional[Tuple[Int, Int]]((0, 0))
    var i = start + 1
    var value: Int = 0
    var consumed_digits = 0
    while i < n:
        var c = cell[i]
        if c < UInt8(_ASCII_DIGIT_LO) or c > UInt8(_ASCII_DIGIT_HI):
            break
        value = value * 10 + (Int(c) - 0x30)
        consumed_digits = consumed_digits + 1
        i = i + 1
    if consumed_digits == 0:
        return None
    if consumed_digits > max_digits:
        return None
    while consumed_digits < max_digits:
        value = value * 10
        consumed_digits = consumed_digits + 1
    return Optional[Tuple[Int, Int]]((value, i - start))


# =============================================================================
# fast_parse_iso_time_* -- SIMD time fast paths.
# =============================================================================


def fast_parse_iso_time_s(cell: Span[UInt8, _]) -> Optional[Int32]:
    """Parse 8-byte ISO `HH:MM:SS` -> Int32 seconds-since-midnight.

    Sub-second precision is REJECTED (matches scalar _try_parse_time_s).
    """
    if len(cell) != 8:
        return None
    if not cell_starts_iso_time(cell, 0):
        return None
    var hms = _decode_hms_scalar(cell, 0)
    var h = hms[0]
    var m = hms[1]
    var s = hms[2]
    if h > 23 or m > 59 or s > 59:
        return None
    return Optional[Int32](Int32(h * 3600 + m * 60 + s))


def fast_parse_iso_time_ms(cell: Span[UInt8, _]) -> Optional[Int32]:
    """Parse `HH:MM:SS[.fff]` -> Int32 ms-since-midnight.

    SIMD on the 8-byte prefix; scalar tail for fractional part.
    """
    var n = len(cell)
    if n < 8:
        return None
    if not cell_starts_iso_time(cell, 0):
        return None
    var hms = _decode_hms_scalar(cell, 0)
    var h = hms[0]
    var m = hms[1]
    var s = hms[2]
    if h > 23 or m > 59 or s > 59:
        return None
    var frac_value: Int = 0
    var pos = 8
    if pos < n and cell[pos] == UInt8(_ASCII_DOT):
        var frac = _parse_fractional_seconds_inline(cell, pos, 3)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    if pos != n:
        return None
    return Optional[Int32](Int32((h * 3600 + m * 60 + s) * 1000 + frac_value))


def fast_parse_iso_time_us(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse `HH:MM:SS[.ffffff]` -> Int64 us-since-midnight."""
    var n = len(cell)
    if n < 8:
        return None
    if not cell_starts_iso_time(cell, 0):
        return None
    var hms = _decode_hms_scalar(cell, 0)
    var h = hms[0]
    var m = hms[1]
    var s = hms[2]
    if h > 23 or m > 59 or s > 59:
        return None
    var frac_value: Int = 0
    var pos = 8
    if pos < n and cell[pos] == UInt8(_ASCII_DOT):
        var frac = _parse_fractional_seconds_inline(cell, pos, 6)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    if pos != n:
        return None
    return Optional[Int64](Int64((h * 3600 + m * 60 + s) * 1000000 + frac_value))


def fast_parse_iso_time_ns(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse `HH:MM:SS[.fffffffff]` -> Int64 ns-since-midnight."""
    var n = len(cell)
    if n < 8:
        return None
    if not cell_starts_iso_time(cell, 0):
        return None
    var hms = _decode_hms_scalar(cell, 0)
    var h = hms[0]
    var m = hms[1]
    var s = hms[2]
    if h > 23 or m > 59 or s > 59:
        return None
    var frac_value: Int = 0
    var pos = 8
    if pos < n and cell[pos] == UInt8(_ASCII_DOT):
        var frac = _parse_fractional_seconds_inline(cell, pos, 9)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    if pos != n:
        return None
    return Optional[Int64](Int64((h * 3600 + m * 60 + s) * 1000000000 + frac_value))


# =============================================================================
# fast_parse_iso_timestamp_* -- SIMD timestamp fast paths.
#
# Shape: "YYYY-MM-DD" + ('T' or ' ') + "HH:MM:SS" + optional ".frac" +
# optional 'Z'. 19 bytes minimum (no fraction). The SIMD gate validates
# the date prefix (10 bytes), separator (1 byte), and time prefix (8
# bytes); the fractional tail uses scalar.
# =============================================================================


@always_inline
def cell_is_iso_timestamp_prefix(cell: Span[UInt8, _]) -> Bool:
    """Branch-free gate: is the first 19 bytes canonical ISO timestamp?

    Validates date prefix + 'T'/' ' separator + time component.
    """
    if len(cell) < 19:
        return False
    # Date32 shape on the 10-byte prefix is identical at lane positions.
    # Inline the digit + dash check for the date prefix.
    if cell[4] != UInt8(_ASCII_DASH):
        return False
    if cell[7] != UInt8(_ASCII_DASH):
        return False
    var b0 = cell[0]
    var b1 = cell[1]
    var b2 = cell[2]
    var b3 = cell[3]
    var b5 = cell[5]
    var b6 = cell[6]
    var b8 = cell[8]
    var b9 = cell[9]
    if b0 < UInt8(_ASCII_DIGIT_LO) or b0 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b1 < UInt8(_ASCII_DIGIT_LO) or b1 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b2 < UInt8(_ASCII_DIGIT_LO) or b2 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b3 < UInt8(_ASCII_DIGIT_LO) or b3 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b5 < UInt8(_ASCII_DIGIT_LO) or b5 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b6 < UInt8(_ASCII_DIGIT_LO) or b6 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b8 < UInt8(_ASCII_DIGIT_LO) or b8 > UInt8(_ASCII_DIGIT_HI):
        return False
    if b9 < UInt8(_ASCII_DIGIT_LO) or b9 > UInt8(_ASCII_DIGIT_HI):
        return False
    # Separator at offset 10 must be 'T' or ' '.
    var sep = cell[10]
    if sep != UInt8(_ASCII_T) and sep != UInt8(_ASCII_SPACE):
        return False
    # Time component at offset 11..18 must match "HH:MM:SS".
    return cell_starts_iso_time(cell, 11)


@always_inline
def _decode_iso_timestamp_components(
    cell: Span[UInt8, _]
) -> Tuple[Int, Int, Int, Int]:
    """Decode (days_since_epoch, h, m, s) from a validated cell.

    Caller MUST have validated via `cell_is_iso_timestamp_prefix` AND
    confirmed month/day are in valid range. Returns days_since_epoch=0
    on out-of-range, but callers check separately.
    """
    var v = _load_u8x16_padded(cell)
    var ymd = _decode_ymd_simd(v)
    var hms = _decode_hms_scalar(cell, 11)
    var days = _days_since_epoch_int(ymd[0], ymd[1], ymd[2])
    return (days, hms[0], hms[1], hms[2])


@always_inline
def _consume_z_inline(cell: Span[UInt8, _], var pos: Int) -> Int:
    """Consume an optional trailing 'Z'; return updated position."""
    if pos < len(cell) and cell[pos] == UInt8(_ASCII_Z):
        pos = pos + 1
    return pos


def fast_parse_iso_timestamp_s(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse `YYYY-MM-DD[ T]HH:MM:SS[Z]` -> Int64 seconds-since-epoch.

    Sub-second fraction REJECTED.
    """
    if not cell_is_iso_timestamp_prefix(cell):
        return None
    var v = _load_u8x16_padded(cell)
    var ymd = _decode_ymd_simd(v)
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]
    if month < 1 or month > 12:
        return None
    if day < 1 or day > _days_in_month_int(year, month):
        return None
    var hms = _decode_hms_scalar(cell, 11)
    var h = hms[0]
    var m = hms[1]
    var s = hms[2]
    if h > 23 or m > 59 or s > 59:
        return None
    var n = len(cell)
    var pos = 19
    if pos < n and cell[pos] == UInt8(_ASCII_DOT):
        return None  # Reject sub-second for seconds resolution.
    pos = _consume_z_inline(cell, pos)
    if pos != n:
        return None
    var s_in_day = h * 3600 + m * 60 + s
    return Optional[Int64](
        Int64(_days_since_epoch_int(year, month, day)) * Int64(86400)
        + Int64(s_in_day)
    )


def fast_parse_iso_timestamp_ms(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse `YYYY-MM-DD[ T]HH:MM:SS[.fff][Z]` -> ms-since-epoch."""
    if not cell_is_iso_timestamp_prefix(cell):
        return None
    var v = _load_u8x16_padded(cell)
    var ymd = _decode_ymd_simd(v)
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]
    if month < 1 or month > 12:
        return None
    if day < 1 or day > _days_in_month_int(year, month):
        return None
    var hms = _decode_hms_scalar(cell, 11)
    var h = hms[0]
    var m = hms[1]
    var s = hms[2]
    if h > 23 or m > 59 or s > 59:
        return None
    var n = len(cell)
    var pos = 19
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(_ASCII_DOT):
        var frac = _parse_fractional_seconds_inline(cell, pos, 3)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    pos = _consume_z_inline(cell, pos)
    if pos != n:
        return None
    var ms_in_day = (h * 3600 + m * 60 + s) * 1000 + frac_value
    return Optional[Int64](
        Int64(_days_since_epoch_int(year, month, day)) * Int64(86400000)
        + Int64(ms_in_day)
    )


def fast_parse_iso_timestamp_us(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse `YYYY-MM-DD[ T]HH:MM:SS[.ffffff][Z]` -> us-since-epoch."""
    if not cell_is_iso_timestamp_prefix(cell):
        return None
    var v = _load_u8x16_padded(cell)
    var ymd = _decode_ymd_simd(v)
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]
    if month < 1 or month > 12:
        return None
    if day < 1 or day > _days_in_month_int(year, month):
        return None
    var hms = _decode_hms_scalar(cell, 11)
    var h = hms[0]
    var m = hms[1]
    var s = hms[2]
    if h > 23 or m > 59 or s > 59:
        return None
    var n = len(cell)
    var pos = 19
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(_ASCII_DOT):
        var frac = _parse_fractional_seconds_inline(cell, pos, 6)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    pos = _consume_z_inline(cell, pos)
    if pos != n:
        return None
    var us_in_day = (h * 3600 + m * 60 + s) * 1000000 + frac_value
    return Optional[Int64](
        Int64(_days_since_epoch_int(year, month, day)) * Int64(86400000000)
        + Int64(us_in_day)
    )


def fast_parse_iso_timestamp_ns(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse `YYYY-MM-DD[ T]HH:MM:SS[.fffffffff][Z]` -> ns-since-epoch.

    Returns None for an instant outside the Int64 nanosecond range,
    1677-09-21T00:12:43.145224192 to 2262-04-11T23:47:16.854775807
    (`epoch_seconds_to_ns`, shared with the scalar parser).
    """
    if not cell_is_iso_timestamp_prefix(cell):
        return None
    var v = _load_u8x16_padded(cell)
    var ymd = _decode_ymd_simd(v)
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]
    if month < 1 or month > 12:
        return None
    if day < 1 or day > _days_in_month_int(year, month):
        return None
    var hms = _decode_hms_scalar(cell, 11)
    var h = hms[0]
    var m = hms[1]
    var s = hms[2]
    if h > 23 or m > 59 or s > 59:
        return None
    var n = len(cell)
    var pos = 19
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(_ASCII_DOT):
        var frac = _parse_fractional_seconds_inline(cell, pos, 9)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    pos = _consume_z_inline(cell, pos)
    if pos != n:
        return None
    var secs = (
        _days_since_epoch_int(year, month, day) * 86400
        + h * 3600 + m * 60 + s
    )
    return epoch_seconds_to_ns(secs, frac_value)


# =============================================================================
# Duration_*: no SIMD gate.
#
# ISO 8601 duration "PnDTnHnMnS" has variable-length per-component digit
# runs (1+ digits per unit, optional units, optional fractional seconds);
# the shape doesn't decompose into fixed SIMD lane positions. The
# scalar parser at temporal_parsers.mojo:_try_parse_duration_iso_to_ns is
# a single pass with an overflow check per digit and per component.
#
# Numeric-seconds durations (pandas default) parse through the scalar
# `_try_parse_float64` inside `_try_parse_duration_ns`.
#
# This module ships NO SIMD entry for Duration_*: the Duration builders in
# typed_column_builders.mojo call the scalar `_try_parse_duration_*` only.
# =============================================================================

