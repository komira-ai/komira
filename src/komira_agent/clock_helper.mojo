# =============================================================================
# komira_agent/clock_helper.mojo — system-clock -> AWS SigV4 date stamps.
# =============================================================================
#
# The two SigV4 date stamps, from the LIVE system clock:
#
#   amz_date   — "YYYYMMDDTHHMMSSZ"  (the X-Amz-Date header value)
#   short_date — "YYYYMMDD"          (the credential-scope date)
#
# Source: `komira_clock.now_unix_ms()` (CLOCK_REALTIME wall clock). A MinIO
# test overrides via `MINIO_E2E_AMZ_DATE` / `MINIO_E2E_SHORT_DATE` for a
# deterministic signature; `amz_stamps_now()` consults those env vars first and
# only falls back to the system clock when unset, and `amz_override_unix_seconds`
# hands the same override to the S3 client's signing clock (s3_client.mojo).
#
# The unix-ms <-> civil-date conversions use Howard Hinnant's branch-free
# `civil_from_days` / `days_from_civil`: closed-form O(1) integer arithmetic,
# no heap, no FFI, no loop.
#
# ENCAPSULATION + gap6: pure value arithmetic over Int64 + owned String output.
# No UnsafePointer, no wildcard origin, no byte-slab. Mojo 1.0.0b1.
# =============================================================================

from komira_core_ffi.posix import _read_env
from komira_clock import now_unix_ms


# =============================================================================
# §1 — AmzStamps — the two SigV4 date strings.
# =============================================================================
struct AmzStamps(Copyable, Movable, ImplicitlyCopyable):
    """The pair of SigV4 date stamps the signer needs.

      amz_date   — "YYYYMMDDTHHMMSSZ" (X-Amz-Date header).
      short_date — "YYYYMMDD"         (credential-scope date)."""

    var amz_date: String
    var short_date: String

    def __init__(out self, var amz_date: String, var short_date: String):
        self.amz_date = amz_date^
        self.short_date = short_date^


# =============================================================================
# §2 — civil_from_days — Hinnant inverse (days-since-epoch -> y/m/d).
# =============================================================================
def _civil_from_days(z_in: Int) -> Tuple[Int, Int, Int]:
    """Howard Hinnant `civil_from_days`: days since the Unix epoch -> (year, month,
    day) in the proleptic Gregorian calendar. Branch-free, O(1) — the exact
    inverse of `date_to_days` / `days_from_civil`. Handles negative inputs
    (pre-epoch) correctly.

    Reference: H. Hinnant, "chrono-Compatible Low-Level Date Algorithms"."""
    var z = z_in + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
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
# §3 — zero-padded decimal formatters.
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
# §4 — amz_stamps_from_unix_ms — convert a wall-clock ms value to the stamps.
# =============================================================================
def amz_stamps_from_unix_ms(unix_ms: Int64) -> AmzStamps:
    """Convert milliseconds-since-Unix-epoch to the SigV4 (amz_date,
    short_date) pair, in UTC.

    amz_date   = "{YYYY}{MM}{DD}T{hh}{mm}{ss}Z"
    short_date = "{YYYY}{MM}{DD}"."""
    var total_secs = Int(unix_ms // 1000)
    # Floor-divide into days + seconds-of-day, correct for negative epochs.
    var days = total_secs // 86400
    var secs_of_day = total_secs - days * 86400
    if secs_of_day < 0:
        secs_of_day += 86400
        days -= 1

    var ymd = _civil_from_days(days)
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]

    var hh = secs_of_day // 3600
    var mm = (secs_of_day % 3600) // 60
    var ss = secs_of_day % 60

    var short_date = _pad4(year) + _pad2(month) + _pad2(day)
    var amz_date = (
        short_date
        + String("T")
        + _pad2(hh)
        + _pad2(mm)
        + _pad2(ss)
        + String("Z")
    )
    return AmzStamps(amz_date^, short_date^)


# =============================================================================
# §5 — amz_stamps_now — env-override-first, else live system clock.
# =============================================================================
def amz_stamps_now() -> AmzStamps:
    """Resolve the SigV4 date stamps for "now".

    Order:
      1. If BOTH `MINIO_E2E_AMZ_DATE` and `MINIO_E2E_SHORT_DATE` are set
         (the deterministic-test override, mirrors os_read_s3_microbench),
         use them verbatim.
      2. Else derive from the live system clock
         (`komira_clock.now_unix_ms`, which itself honors the
         `THORIUM_MOCK_NOW_MS` test hook).

    This is the SAME helper for both the deterministic MinIO e2e and the
    live-clock production agent — the only difference is whether the env
    override is present."""
    var amz_env = _read_env("MINIO_E2E_AMZ_DATE")
    var short_env = _read_env("MINIO_E2E_SHORT_DATE")
    if amz_env.byte_length() > 0 and short_env.byte_length() > 0:
        return AmzStamps(amz_env^, short_env^)
    return amz_stamps_from_unix_ms(now_unix_ms())


def _days_from_civil(y_in: Int, m: Int, d: Int) -> Int:
    """Howard Hinnant `days_from_civil`: (year, month, day) in the proleptic
    Gregorian calendar -> days since the Unix epoch. The exact inverse of
    `_civil_from_days`."""
    var y = y_in - 1 if m <= 2 else y_in
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400  # [0, 399]
    var mp = m - 3 if m > 2 else m + 9  # [0, 11]
    var doy = (153 * mp + 2) // 5 + d - 1  # [0, 365]
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy  # [0, 146096]
    return era * 146097 + doe - 719468


def _digits(s: String, start: Int, n: Int) raises -> Int:
    """The decimal value of `n` ASCII digits of `s` at `start`."""
    var b = s.as_bytes()
    var v = 0
    for i in range(start, start + n):
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            raise Error("not a digit")
        v = v * 10 + (c - 0x30)
    return v


def unix_seconds_from_amz_date(amz_date: String) raises -> Int:
    """Parse a SigV4 `YYYYMMDDTHHMMSSZ` stamp (UTC) into Unix seconds. The
    inverse of `amz_stamps_from_unix_ms`'s `amz_date`. Raises on any other
    shape."""
    var b = amz_date.as_bytes()
    if len(b) != 16 or b[8] != UInt8(0x54) or b[15] != UInt8(0x5A):
        raise Error(
            "agent clock: an amz date is YYYYMMDDTHHMMSSZ, got " + amz_date
        )
    try:
        var year = _digits(amz_date, 0, 4)
        var month = _digits(amz_date, 4, 2)
        var day = _digits(amz_date, 6, 2)
        var hh = _digits(amz_date, 9, 2)
        var mm = _digits(amz_date, 11, 2)
        var ss = _digits(amz_date, 13, 2)
        if month < 1 or month > 12 or day < 1 or day > 31:
            raise Error("out of range")
        if hh > 23 or mm > 59 or ss > 59:
            raise Error("out of range")
        return _days_from_civil(year, month, day) * 86400 + hh * 3600 + mm * 60 + ss
    except:
        raise Error(
            "agent clock: an amz date is YYYYMMDDTHHMMSSZ, got " + amz_date
        )


def amz_override_unix_seconds() raises -> Optional[Int]:
    """The `MINIO_E2E_*` override as Unix seconds: the `MINIO_E2E_AMZ_DATE`
    instant when BOTH `MINIO_E2E_AMZ_DATE` and `MINIO_E2E_SHORT_DATE` are set
    (the same condition `amz_stamps_now` uses), else None. Raises when the
    override is set but `MINIO_E2E_AMZ_DATE` is not a SigV4 stamp."""
    var amz_env = _read_env("MINIO_E2E_AMZ_DATE")
    var short_env = _read_env("MINIO_E2E_SHORT_DATE")
    if amz_env.byte_length() > 0 and short_env.byte_length() > 0:
        return Optional[Int](unix_seconds_from_amz_date(amz_env))
    return None
