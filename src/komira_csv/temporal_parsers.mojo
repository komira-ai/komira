# =============================================================================
# temporal_parsers — Date64, Timestamp, Time and Duration cell parsers.
# =============================================================================
#
# Each `_try_parse_<dtype>(cell)` returns an `Optional[T]`, `None` on parse
# failure (the caller writes a null bit + 0 sentinel), with the contract of
# cell_parsers.mojo, which holds Date32 and the numeric parsers. A value
# that does not fit its Int64 unit is refused, never wrapped
# (temporal_range.mojo).
# =============================================================================

from .cell_parsers import (
    _byte_is_ascii_digit,
    _days_in_month,
    _is_leap_year,
    _try_parse_float64,
)
from .temporal_range import epoch_seconds_to_ns, checked_mul_add, div_toward_zero


# =============================================================================
# Date64 parser (ISO-8601 datetime; milliseconds since 1970-01-01).
# =============================================================================
#
# Date64 is Arrow's milliseconds-since-epoch INT64. Per Arrow spec the value
# is constrained to whole-day multiples of 86400000, BUT in practice tools
# (pandas, pyarrow.csv) emit both:
#   - Date-only "YYYY-MM-DD" -> midnight UTC ms-since-epoch
#   - Datetime "YYYY-MM-DD HH:MM:SS[.fff]" -> full ms-since-epoch
# We accept both shapes here; the wider TIMESTAMP_MS parser below accepts the
# same datetime shape but rejects bare date-only.


@always_inline
def _days_since_epoch(year: Int, month: Int, day: Int) -> Int:
    """Days since 1970-01-01 for a validated (year, month, day) tuple."""
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
    return days_total


@always_inline
def _parse_ymd_at(cell: Span[UInt8, _], offset: Int) -> Optional[Int]:
    """Parse 'YYYY-MM-DD' at cell[offset:offset+10]; return days-since-epoch.

    Returns None on format mismatch or invalid date. Validates leap-year
    Feb 29.
    """
    if len(cell) < offset + 10:
        return None
    if cell[offset + 4] != UInt8(0x2D):
        return None
    if cell[offset + 7] != UInt8(0x2D):
        return None
    var i = offset
    while i < offset + 4:
        if not _byte_is_ascii_digit(cell[i]):
            return None
        i = i + 1
    if not _byte_is_ascii_digit(cell[offset + 5]) or not _byte_is_ascii_digit(cell[offset + 6]):
        return None
    if not _byte_is_ascii_digit(cell[offset + 8]) or not _byte_is_ascii_digit(cell[offset + 9]):
        return None
    var year = (Int(cell[offset + 0]) - 0x30) * 1000 + (Int(cell[offset + 1]) - 0x30) * 100 + (Int(cell[offset + 2]) - 0x30) * 10 + (Int(cell[offset + 3]) - 0x30)
    var month = (Int(cell[offset + 5]) - 0x30) * 10 + (Int(cell[offset + 6]) - 0x30)
    var day = (Int(cell[offset + 8]) - 0x30) * 10 + (Int(cell[offset + 9]) - 0x30)
    if month < 1 or month > 12:
        return None
    if day < 1 or day > _days_in_month(year, month):
        return None
    return Optional[Int](_days_since_epoch(year, month, day))


@always_inline
def _parse_hms_at(
    cell: Span[UInt8, _], offset: Int
) -> Optional[Tuple[Int, Int, Int]]:
    """Parse 'HH:MM:SS' at cell[offset:offset+8]; return (h, m, s).

    Returns None on format mismatch or out-of-range value.
    """
    if len(cell) < offset + 8:
        return None
    if cell[offset + 2] != UInt8(0x3A):
        return None
    if cell[offset + 5] != UInt8(0x3A):
        return None
    if not _byte_is_ascii_digit(cell[offset + 0]) or not _byte_is_ascii_digit(cell[offset + 1]):
        return None
    if not _byte_is_ascii_digit(cell[offset + 3]) or not _byte_is_ascii_digit(cell[offset + 4]):
        return None
    if not _byte_is_ascii_digit(cell[offset + 6]) or not _byte_is_ascii_digit(cell[offset + 7]):
        return None
    var h = (Int(cell[offset + 0]) - 0x30) * 10 + (Int(cell[offset + 1]) - 0x30)
    var m = (Int(cell[offset + 3]) - 0x30) * 10 + (Int(cell[offset + 4]) - 0x30)
    var s = (Int(cell[offset + 6]) - 0x30) * 10 + (Int(cell[offset + 7]) - 0x30)
    if h > 23 or m > 59 or s > 59:
        return None
    return Optional[Tuple[Int, Int, Int]]((h, m, s))


@always_inline
def _parse_fractional_seconds(
    cell: Span[UInt8, _], start: Int, max_digits: Int
) -> Optional[Tuple[Int, Int]]:
    """Parse leading `.<digits>` (max `max_digits` digits) starting at offset.

    Returns (value_in_units_of_10**max_digits, num_chars_consumed).
    e.g. ".5" with max_digits=3 -> (500, 2).

    Returns None if:
      - cell[start] is '.' but no digits follow.
      - more than max_digits fractional digits are present (preserves
        round-trip fidelity — the caller's unit can't represent the
        precision the input carries).

    If cell[start] is not '.', returns (0, 0) — meaning "no fraction present".
    """
    var n = len(cell)
    if start >= n or cell[start] != UInt8(0x2E):  # '.'
        return Optional[Tuple[Int, Int]]((0, 0))
    var i = start + 1
    var value: Int = 0
    var consumed_digits = 0
    while i < n and _byte_is_ascii_digit(cell[i]):
        value = value * 10 + (Int(cell[i]) - 0x30)
        consumed_digits = consumed_digits + 1
        i = i + 1
    if consumed_digits == 0:
        return None
    # Reject precision overshoot — caller's unit can't represent this.
    # This is critical for the inference lattice: if a column carries
    # "0.000001" (6 frac digits), Date64 should REJECT and Timestamp_US
    # should accept; otherwise the lattice would silently truncate.
    if consumed_digits > max_digits:
        return None
    # Pad to max_digits: if user wrote ".5" with max=3, we want value=500.
    while consumed_digits < max_digits:
        value = value * 10
        consumed_digits = consumed_digits + 1
    return Optional[Tuple[Int, Int]]((value, i - start))


def _try_parse_date64(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse ISO-8601 date-only OR datetime as milliseconds-since-epoch.

    Accepted forms:
      - 'YYYY-MM-DD'                    -> midnight UTC ms
      - 'YYYY-MM-DD HH:MM:SS'           -> full ms (space separator)
      - 'YYYY-MM-DDTHH:MM:SS'           -> full ms (ISO T separator)
      - Either above + '.f' to '.fff' (at most 3 digits, ms precision;
        a longer fraction returns None)
      - Either above + 'Z' suffix (treated as UTC; equivalent to no suffix)

    Returns None on format mismatch or invalid date/time. Times before
    1970-01-01 emit a negative Int64.
    """
    var n = len(cell)
    if n != 10 and n < 19:
        return None
    var ymd = _parse_ymd_at(cell, 0)
    if not ymd:
        return None
    var days = ymd.value()
    if n == 10:
        # Date-only.
        return Optional[Int64](Int64(days) * Int64(86400000))
    # Datetime: separator at index 10 must be 'T' or ' '.
    var sep = cell[10]
    if sep != UInt8(0x54) and sep != UInt8(0x20):
        return None
    var hms = _parse_hms_at(cell, 11)
    if not hms:
        return None
    var h_m_s = hms.value()
    var ms_in_day = (h_m_s[0] * 3600 + h_m_s[1] * 60 + h_m_s[2]) * 1000
    # Optional ".fff" — at most ms precision.
    var pos = 19
    if pos < n and cell[pos] == UInt8(0x2E):  # '.'
        var frac = _parse_fractional_seconds(cell, pos, 3)
        if not frac:
            return None
        var f = frac.value()
        ms_in_day = ms_in_day + f[0]
        pos = pos + f[1]
    # Optional 'Z' suffix.
    if pos < n:
        if cell[pos] == UInt8(0x5A):  # 'Z'
            pos = pos + 1
    if pos != n:
        return None
    return Optional[Int64](Int64(days) * Int64(86400000) + Int64(ms_in_day))


# =============================================================================
# TIMESTAMP_{S,MS,US,NS} parsers (ISO-8601 datetime).
# =============================================================================
#
# Each parser accepts the same datetime grammar as Date64 datetime but
# narrows the precision of the trailing `.<digits>` part to the unit cap
# and emits the value rescaled into that unit.


@always_inline
def _parse_iso_datetime_to_components(
    cell: Span[UInt8, _]
) -> Optional[Tuple[Int, Int, Int, Int, Int]]:
    """Parse ISO-8601 datetime; return (days_since_epoch, h, m, s, frac_index).

    Expects:
      cell[0:10]   = 'YYYY-MM-DD'
      cell[10]     = 'T' or ' '
      cell[11:19]  = 'HH:MM:SS'
      cell[19:]    = optional '.<digits>' optional 'Z'

    `frac_index` is the byte index of the '.' (or n if no fraction).

    Returns None on format mismatch.
    """
    var n = len(cell)
    if n < 19:
        return None
    var ymd = _parse_ymd_at(cell, 0)
    if not ymd:
        return None
    var sep = cell[10]
    if sep != UInt8(0x54) and sep != UInt8(0x20):
        return None
    var hms = _parse_hms_at(cell, 11)
    if not hms:
        return None
    var h_m_s = hms.value()
    return Optional[Tuple[Int, Int, Int, Int, Int]](
        (ymd.value(), h_m_s[0], h_m_s[1], h_m_s[2], 19)
    )


@always_inline
def _consume_optional_z(cell: Span[UInt8, _], var pos: Int) -> Int:
    """Consume an optional trailing 'Z' UTC marker; return new pos.

    Caller checks pos == len(cell) afterward to detect trailing garbage.
    """
    if pos < len(cell) and cell[pos] == UInt8(0x5A):
        pos = pos + 1
    return pos


def _try_parse_timestamp_s(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse ISO-8601 datetime as seconds-since-epoch (Int64).

    Sub-second precision in the cell is REJECTED (would lose precision) —
    returns None if a `.fff` part is present. Per Arrow Timestamp[s] spec.
    """
    var comp = _parse_iso_datetime_to_components(cell)
    if not comp:
        return None
    var c = comp.value()
    var n = len(cell)
    var pos = c[4]
    # Reject sub-second precision for seconds resolution.
    if pos < n and cell[pos] == UInt8(0x2E):
        return None
    pos = _consume_optional_z(cell, pos)
    if pos != n:
        return None
    var s_in_day = c[1] * 3600 + c[2] * 60 + c[3]
    return Optional[Int64](Int64(c[0]) * Int64(86400) + Int64(s_in_day))


def _try_parse_timestamp_ms(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse ISO-8601 datetime as milliseconds-since-epoch.

    Sub-second fraction of at most 3 digits (ms precision); a longer
    fraction returns None.
    """
    var comp = _parse_iso_datetime_to_components(cell)
    if not comp:
        return None
    var c = comp.value()
    var n = len(cell)
    var pos = c[4]
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(0x2E):
        var frac = _parse_fractional_seconds(cell, pos, 3)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    pos = _consume_optional_z(cell, pos)
    if pos != n:
        return None
    var ms_in_day = (c[1] * 3600 + c[2] * 60 + c[3]) * 1000 + frac_value
    return Optional[Int64](Int64(c[0]) * Int64(86400000) + Int64(ms_in_day))


def _try_parse_timestamp_us(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse ISO-8601 datetime as microseconds-since-epoch.

    Sub-second fraction of at most 6 digits (us precision); a longer
    fraction returns None.
    """
    var comp = _parse_iso_datetime_to_components(cell)
    if not comp:
        return None
    var c = comp.value()
    var n = len(cell)
    var pos = c[4]
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(0x2E):
        var frac = _parse_fractional_seconds(cell, pos, 6)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    pos = _consume_optional_z(cell, pos)
    if pos != n:
        return None
    var us_in_day = (c[1] * 3600 + c[2] * 60 + c[3]) * 1000000 + frac_value
    return Optional[Int64](Int64(c[0]) * Int64(86400000000) + Int64(us_in_day))


def _try_parse_timestamp_ns(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse ISO-8601 datetime as nanoseconds-since-epoch.

    Sub-second fraction of at most 9 digits (ns precision); a longer
    fraction returns None. Returns None for an instant outside the Int64
    nanosecond range, 1677-09-21T00:12:43.145224192 to
    2262-04-11T23:47:16.854775807.
    """
    var comp = _parse_iso_datetime_to_components(cell)
    if not comp:
        return None
    var c = comp.value()
    var n = len(cell)
    var pos = c[4]
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(0x2E):
        var frac = _parse_fractional_seconds(cell, pos, 9)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    pos = _consume_optional_z(cell, pos)
    if pos != n:
        return None
    var secs = c[0] * 86400 + c[1] * 3600 + c[2] * 60 + c[3]
    return epoch_seconds_to_ns(secs, frac_value)


# =============================================================================
# TIME{32,64} parsers (HH:MM:SS[.fff[fff[fff]]]).
# =============================================================================
#
# TIME has NO date component. The buffer-unit depends on the Arrow slot:
#   - TIME32_S:  Int32 seconds-since-midnight (range [0, 86400))
#   - TIME32_MS: Int32 milliseconds-since-midnight
#   - TIME64_US: Int64 microseconds-since-midnight
#   - TIME64_NS: Int64 nanoseconds-since-midnight


def _try_parse_time_s(cell: Span[UInt8, _]) -> Optional[Int32]:
    """Parse 'HH:MM:SS' as Int32 seconds-since-midnight.

    Sub-second precision is REJECTED.
    """
    var n = len(cell)
    if n != 8:
        return None
    var hms = _parse_hms_at(cell, 0)
    if not hms:
        return None
    var c = hms.value()
    return Optional[Int32](Int32(c[0] * 3600 + c[1] * 60 + c[2]))


def _try_parse_time_ms(cell: Span[UInt8, _]) -> Optional[Int32]:
    """Parse 'HH:MM:SS[.fff]' as Int32 ms-since-midnight."""
    var n = len(cell)
    if n < 8:
        return None
    var hms = _parse_hms_at(cell, 0)
    if not hms:
        return None
    var c = hms.value()
    var pos = 8
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(0x2E):
        var frac = _parse_fractional_seconds(cell, pos, 3)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    if pos != n:
        return None
    return Optional[Int32](Int32((c[0] * 3600 + c[1] * 60 + c[2]) * 1000 + frac_value))


def _try_parse_time_us(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse 'HH:MM:SS[.ffffff]' as Int64 us-since-midnight."""
    var n = len(cell)
    if n < 8:
        return None
    var hms = _parse_hms_at(cell, 0)
    if not hms:
        return None
    var c = hms.value()
    var pos = 8
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(0x2E):
        var frac = _parse_fractional_seconds(cell, pos, 6)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    if pos != n:
        return None
    return Optional[Int64](Int64((c[0] * 3600 + c[1] * 60 + c[2]) * 1000000 + frac_value))


def _try_parse_time_ns(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse 'HH:MM:SS[.fffffffff]' as Int64 ns-since-midnight."""
    var n = len(cell)
    if n < 8:
        return None
    var hms = _parse_hms_at(cell, 0)
    if not hms:
        return None
    var c = hms.value()
    var pos = 8
    var frac_value: Int = 0
    if pos < n and cell[pos] == UInt8(0x2E):
        var frac = _parse_fractional_seconds(cell, pos, 9)
        if not frac:
            return None
        var f = frac.value()
        frac_value = f[0]
        pos = pos + f[1]
    if pos != n:
        return None
    return Optional[Int64](Int64((c[0] * 3600 + c[1] * 60 + c[2]) * 1000000000 + frac_value))


# =============================================================================
# Duration_{S,MS,US,NS} parsers.
# =============================================================================
#
# Two accepted shapes:
#   1. ISO 8601 'PnDTnHnMnS' (subset; days + time-of-day components).
#   2. Plain numeric: integer or float seconds-since-zero (pandas's default
#      timedelta CSV emission).
#
# Each parser converts the parsed duration into the target unit. Negative
# durations supported via leading '-' prefix on the ISO shape ('-PnDTnHnMnS')
# or numeric shape ('-1.5').


def _try_parse_duration_iso_to_ns(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse ISO 8601 'PnDTnHnMnS' to nanoseconds.

    Subset supported: P[<days>D][T[<hours>H][<minutes>M][<seconds>[.<frac>]S]].
    Empty components are allowed; at least one component must be present.

    Returns None on malformed input, and when a component or the total
    exceeds Int64 nanoseconds (about 292 years) in magnitude. Per ISO 8601
    section 3.3.3.
    """
    var n = len(cell)
    if n < 2:
        return None
    var i = 0
    var negative = False
    if cell[0] == UInt8(0x2D):  # '-'
        negative = True
        i = 1
    if i >= n or cell[i] != UInt8(0x50):  # 'P'
        return None
    i = i + 1
    var ns_total: Int64 = 0
    var saw_any = False

    # Days segment (before 'T').
    var current_value: Int64 = 0
    var current_has_digits = False
    var seen_t = False
    while i < n:
        var c = cell[i]
        if _byte_is_ascii_digit(c):
            var digits = checked_mul_add(current_value, Int64(10), Int64(Int(c) - 0x30))
            if not digits:
                return None
            current_value = digits.value()
            current_has_digits = True
            i = i + 1
            continue
        if c == UInt8(0x44):  # 'D'
            if not current_has_digits:
                return None
            var total = checked_mul_add(current_value, Int64(86400000000000), ns_total)
            if not total:
                return None
            ns_total = total.value()
            current_value = 0
            current_has_digits = False
            saw_any = True
            i = i + 1
            continue
        if c == UInt8(0x54):  # 'T'
            if current_has_digits:
                return None  # Stray digits before T (no unit suffix).
            seen_t = True
            i = i + 1
            break
        return None

    if seen_t:
        # Time segment: H, M, S [with optional fractional seconds for S].
        var seen_h = False
        var seen_m = False
        var seen_s = False
        current_value = 0
        current_has_digits = False
        while i < n:
            var c = cell[i]
            if _byte_is_ascii_digit(c):
                var digits = checked_mul_add(current_value, Int64(10), Int64(Int(c) - 0x30))
                if not digits:
                    return None
                current_value = digits.value()
                current_has_digits = True
                i = i + 1
                continue
            if c == UInt8(0x48):  # 'H'
                if not current_has_digits or seen_h:
                    return None
                var total = checked_mul_add(current_value, Int64(3600000000000), ns_total)
                if not total:
                    return None
                ns_total = total.value()
                seen_h = True
                current_value = 0
                current_has_digits = False
                saw_any = True
                i = i + 1
                continue
            if c == UInt8(0x4D):  # 'M'
                if not current_has_digits or seen_m:
                    return None
                var total = checked_mul_add(current_value, Int64(60000000000), ns_total)
                if not total:
                    return None
                ns_total = total.value()
                seen_m = True
                current_value = 0
                current_has_digits = False
                saw_any = True
                i = i + 1
                continue
            if c == UInt8(0x53):  # 'S' (whole seconds, no fraction since we'd have hit '.' branch first)
                if not current_has_digits or seen_s:
                    return None
                var total = checked_mul_add(current_value, Int64(1000000000), ns_total)
                if not total:
                    return None
                ns_total = total.value()
                seen_s = True
                current_value = 0
                current_has_digits = False
                saw_any = True
                i = i + 1
                continue
            if c == UInt8(0x2E):  # '.' — fractional seconds
                if not current_has_digits or seen_s:
                    return None
                # Add the integer seconds.
                var int_secs = current_value
                # Now parse the fractional digits up to 9.
                var frac = _parse_fractional_seconds(cell, i, 9)
                if not frac:
                    return None
                var f = frac.value()
                # After consuming fraction, next byte must be 'S'.
                var after_frac = i + f[1]
                if after_frac >= n or cell[after_frac] != UInt8(0x53):
                    return None
                var with_secs = checked_mul_add(int_secs, Int64(1000000000), ns_total)
                if not with_secs:
                    return None
                var total = checked_mul_add(with_secs.value(), Int64(1), Int64(f[0]))
                if not total:
                    return None
                ns_total = total.value()
                seen_s = True
                current_value = 0
                current_has_digits = False
                saw_any = True
                i = after_frac + 1
                continue
            return None

        # Stray trailing digits (e.g. "PT5") -> error.
        if current_has_digits:
            return None

    if not saw_any:
        return None
    if negative:
        ns_total = -ns_total
    return Optional[Int64](ns_total)


def _try_parse_duration_ns(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse duration as Int64 nanoseconds.

    Two shapes accepted: ISO 8601 'PnDTnHnMnS' OR numeric seconds (float).
    """
    if len(cell) >= 1 and cell[0] == UInt8(0x50):  # 'P'
        return _try_parse_duration_iso_to_ns(cell)
    if len(cell) >= 2 and cell[0] == UInt8(0x2D) and cell[1] == UInt8(0x50):  # '-P'
        return _try_parse_duration_iso_to_ns(cell)
    # Numeric seconds (float). Multiply by 1e9 to convert to ns.
    var f = _try_parse_float64(cell, UInt8(0x2E))
    if not f:
        return None
    var secs = f.value()
    var ns_f = secs * Float64(1000000000.0)
    # Int64 range check.
    if ns_f > Float64(9.223372036854775e18) or ns_f < Float64(-9.223372036854775e18):
        return None
    return Optional[Int64](Int64(ns_f))


def _try_parse_duration_us(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse duration as Int64 microseconds, rounding toward zero from ns.

    The value is parsed as nanoseconds first, so a duration outside the
    Int64 nanosecond range (about 292 years) returns None in this unit too.
    """
    var ns = _try_parse_duration_ns(cell)
    if not ns:
        return None
    return Optional[Int64](div_toward_zero(ns.value(), Int64(1000)))


def _try_parse_duration_ms(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse duration as Int64 milliseconds, rounding toward zero from ns.

    The value is parsed as nanoseconds first, so a duration outside the
    Int64 nanosecond range (about 292 years) returns None in this unit too.
    """
    var ns = _try_parse_duration_ns(cell)
    if not ns:
        return None
    return Optional[Int64](div_toward_zero(ns.value(), Int64(1000000)))


def _try_parse_duration_s(cell: Span[UInt8, _]) -> Optional[Int64]:
    """Parse duration as Int64 seconds, rounding toward zero from ns.

    The value is parsed as nanoseconds first, so a duration outside the
    Int64 nanosecond range (about 292 years) returns None in this unit too.
    """
    var ns = _try_parse_duration_ns(cell)
    if not ns:
        return None
    return Optional[Int64](div_toward_zero(ns.value(), Int64(1000000000)))
