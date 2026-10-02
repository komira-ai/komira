# =============================================================================
# xl_date_serial.mojo — ★ THE 1900 SERIAL ARITHMETIC, MOVED HERE SO A TEST CAN
#                         RUN IT.
# =============================================================================
#
#     serial 59 = 1900-02-28
#     serial 60 = 1900-02-29   ⛔ A DAY THAT NEVER EXISTED
#     serial 61 = 1900-03-01
#
# Excel reproduces it deliberately for Lotus compatibility, so every date at or
# after 1900-03-01 is shifted by +1 against the true proleptic Gregorian count.
# An implementation that "fixes" the bug is off by one for every modern date,
# and until this move there was no test in the tree that could have said so.
# `test_xl_date_serial.mojo` is what the move buys.
#
# ⚠ THE DAY ARITHMETIC ITSELF IS HOWARD HINNANT'S `days_from_civil` /
# `civil_from_days`, relative to 1970-01-01 — a published algorithm, not a
# local invention, and correct for the whole proleptic Gregorian range.
#
# Encapsulation rule : values only, no `UnsafePointer`.
# =============================================================================


@fieldwise_init
struct _Ymd(Copyable, Movable):
    var y: Int
    var m: Int
    var d: Int


# =============================================================================
# Proleptic Gregorian day arithmetic (Hinnant). Days are relative to 1970-01-01.
# =============================================================================
@always_inline
def _days_from_civil(y0: Int, m: Int, d: Int) -> Int:
    var y = y0 - 1 if m <= 2 else y0
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


@always_inline
def _civil_from_days(z0: Int) -> _Ymd:
    var z = z0 + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    return _Ymd(y + 1 if m <= 2 else y, m, d)


@always_inline
def _excel_base() -> Int:
    """Unix-days of 1899-12-31 — Excel serial 0."""
    return _days_from_civil(1899, 12, 31)


@always_inline
def _leap(y: Int) -> Bool:
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)


@always_inline
def _days_in_month(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if _leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _date_to_serial(y: Int, m: Int, d: Int) -> Int:
    """(y, m, d) -> Excel 1900 serial (Lotus-bug compatible). Month/day overflow
    rolls over (Excel DATE normalizes)."""
    var tm = y * 12 + (m - 1)   # normalize out-of-range months
    var y2 = tm // 12
    var m2 = tm % 12 + 1
    var base = _excel_base()
    var unix_date = _days_from_civil(y2, m2, 1) + (d - 1)  # linear day rollover
    var true_days = unix_date - base
    # Lotus phantom day: dates on/after 1900-03-01 are shifted +1.
    if unix_date >= _days_from_civil(1900, 3, 1):
        return true_days + 1
    return true_days


def _serial_to_ymd(serial: Int) -> _Ymd:
    """Excel 1900 serial -> (y, m, d), honoring the phantom serial 60."""
    if serial == 60:
        return _Ymd(1900, 2, 29)  # Lotus phantom 1900-02-29
    var true_days = serial - 1 if serial > 60 else serial
    return _civil_from_days(_excel_base() + true_days)
