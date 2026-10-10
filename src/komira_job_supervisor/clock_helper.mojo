# =============================================================================
# komira_job_supervisor/clock_helper.mojo: the UTC timestamp a crash report
# carries.
# =============================================================================
#
# `utc_stamp_now()` renders the system wall clock (`komira_clock.now_unix_ms`,
# CLOCK_REALTIME) as a compact ISO 8601 UTC stamp, "YYYYMMDDTHHMMSSZ". The
# civil-date conversion is Howard Hinnant's branch-free `civil_from_days`:
# closed-form integer arithmetic, no heap, no FFI.
#
# Pure value arithmetic; no pointer type.
# =============================================================================

from komira_clock import now_unix_ms


# =============================================================================
# §2: civil_from_days, days since the epoch -> (year, month, day).
# =============================================================================
def _civil_from_days(z_in: Int) -> Tuple[Int, Int, Int]:
    """Howard Hinnant `civil_from_days`: days since the Unix epoch -> (year, month,
    day) in the proleptic Gregorian calendar, for every input including days before
    the epoch and before year 0. Branch-free, O(1).

    Reference: H. Hinnant, "chrono-Compatible Low-Level Date Algorithms". Hinnant's
    C++ subtracts 146096 from a negative `z` because C++ `/` truncates; Mojo's `//`
    already floors, so the era is `z // 146097` for every `z`."""
    var z = z_in + 719468
    var era = z // 146097
    var doe = z - era * 146097  # [0, 146096]
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365  # [0, 399]
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)  # [0, 365]
    var mp = (5 * doy + 2) // 153  # [0, 11]
    var d = doy - (153 * mp + 2) // 5 + 1  # [1, 31]
    var m = mp + 3 if mp < 10 else mp - 9  # [1, 12]
    var year = y + 1 if m <= 2 else y
    return Tuple[Int, Int, Int](year, m, d)


# =============================================================================
# §3: zero-padded decimal formatters.
# =============================================================================
def _pad2(v: Int) -> String:
    """Two-digit zero-padded decimal (00..99)."""
    if v < 10:
        return String("0") + String(v)
    return String(v)


def _pad4(v: Int) -> String:
    """Four-digit zero-padded decimal (0000..9999)."""
    if v < 10:
        return String("000") + String(v)
    if v < 100:
        return String("00") + String(v)
    if v < 1000:
        return String("0") + String(v)
    return String(v)


# =============================================================================
# §4: the stamp.
# =============================================================================
def utc_stamp_from_unix_ms(unix_ms: Int64) -> String:
    """Milliseconds since the Unix epoch as "YYYYMMDDTHHMMSSZ" (UTC)."""
    var total_secs = Int(unix_ms // 1000)
    # Floor-divide into days + seconds-of-day, correct for negative epochs.
    var days = total_secs // 86400
    var secs_of_day = total_secs - days * 86400
    if secs_of_day < 0:
        secs_of_day += 86400
        days -= 1
    var ymd = _civil_from_days(days)
    var hh = secs_of_day // 3600
    var mm = (secs_of_day % 3600) // 60
    var ss = secs_of_day % 60
    return (
        _pad4(ymd[0])
        + _pad2(ymd[1])
        + _pad2(ymd[2])
        + String("T")
        + _pad2(hh)
        + _pad2(mm)
        + _pad2(ss)
        + String("Z")
    )


def utc_stamp_now() -> String:
    """The system wall clock as "YYYYMMDDTHHMMSSZ" (UTC)."""
    return utc_stamp_from_unix_ms(now_unix_ms())
