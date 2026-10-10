# =============================================================================
# Tests for SIMD temporal cell parsers.
# =============================================================================
#
#
# Goal: verify the SIMD ISO-8601 temporal parsers
# (cell_parsers_simd.mojo:fast_parse_iso_*) produce byte-identical
# results to the scalar baseline parsers (temporal_parsers.mojo and, for
# Date32, cell_parsers.mojo: _try_parse_*)
# on every applicable canonical-form input AND correctly reject
# inapplicable inputs (returns None -> caller falls back to scalar).
#
# Test families:
#   T_DATE32: fast_parse_iso_date32 parity + applicability gate
#   T_TIMESTAMP: fast_parse_iso_timestamp_{s,ms,us,ns} parity + gates
#   T_TIME: fast_parse_iso_time_{s,ms,us,ns} parity + gates
#   T_DATE64: fast_parse_iso_date64_date_only parity + gates
#   T_MIXED: mixed scenarios (leap years, edge dates, out-of-range)
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv.cell_parsers import (
    _try_parse_date32,
)
from komira_csv.temporal_parsers import (
    _try_parse_date64,
    _try_parse_timestamp_s,
    _try_parse_timestamp_ms,
    _try_parse_timestamp_us,
    _try_parse_timestamp_ns,
    _try_parse_time_s,
    _try_parse_time_ms,
    _try_parse_time_us,
    _try_parse_time_ns,
)
from komira_csv.cell_parsers_simd import (
    fast_parse_iso_date32,
    fast_parse_iso_date64_date_only,
    fast_parse_iso_timestamp_s,
    fast_parse_iso_timestamp_ms,
    fast_parse_iso_timestamp_us,
    fast_parse_iso_timestamp_ns,
    fast_parse_iso_time_s,
    fast_parse_iso_time_ms,
    fast_parse_iso_time_us,
    fast_parse_iso_time_ns,
    cell_is_iso_date_shaped,
    cell_is_iso_timestamp_prefix,
)


# =============================================================================
# Helpers.
# =============================================================================


def _bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] fixture."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


# =============================================================================
# T_DATE32: fast_parse_iso_date32 parity + applicability gate.
# =============================================================================


def test_date32_parity_canonical() raises:
    """SIMD vs scalar parity on canonical 10-byte ISO dates."""
    var inputs = List[String]()
    inputs.append(String("1970-01-01"))  # epoch
    inputs.append(String("2024-02-29"))  # leap-year Feb 29
    inputs.append(String("2023-02-28"))  # non-leap Feb 28
    inputs.append(String("1999-12-31"))  # end of millennium
    inputs.append(String("2000-01-01"))  # century leap year
    inputs.append(String("1900-03-01"))  # 1900 is NOT a leap year
    inputs.append(String("2024-12-31"))  # year-end
    inputs.append(String("1969-12-31"))  # pre-epoch
    inputs.append(String("1677-09-22"))  # near Int32 lower bound (negative days)
    inputs.append(String("2100-02-28"))  # 2100 NOT a leap year
    inputs.append(String("2400-02-29"))  # 2400 IS a leap year

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_date32(Span(b))
        var scalar = _try_parse_date32(Span(b))
        assert_true(fast, "DATE32 SIMD accepts " + inputs[i])
        assert_true(scalar, "DATE32 scalar accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "DATE32 parity for " + inputs[i],
        )
        i = i + 1


def test_date32_applicability_gate() raises:
    """Gate: True on canonical 10-byte form, False otherwise."""
    var b_ok = _bytes("2024-02-29")
    assert_true(cell_is_iso_date_shaped(Span(b_ok)), "10-byte canonical accepted")

    var b_short = _bytes("2024-02-2")
    assert_false(cell_is_iso_date_shaped(Span(b_short)), "9-byte rejected")

    var b_long = _bytes("2024-02-290")
    assert_false(cell_is_iso_date_shaped(Span(b_long)), "11-byte rejected")

    var b_slash = _bytes("2024/02/29")
    assert_false(cell_is_iso_date_shaped(Span(b_slash)), "YYYY/MM/DD rejected")

    var b_mdy = _bytes("02-29-2024")
    # Position 4 is '-' but positions 0-3 are not all digits (lane 0 '0',
    # lane 1 '2', lane 2 '-' fails digit check). So gate rejects.
    assert_false(cell_is_iso_date_shaped(Span(b_mdy)), "MM-DD-YYYY rejected")

    var b_letter = _bytes("20A4-02-29")
    assert_false(cell_is_iso_date_shaped(Span(b_letter)), "letter rejected")


def test_date32_invalid_dates_rejected() raises:
    """SIMD path rejects invalid dates (month/day out of range)."""
    var b_zero_m = _bytes("2024-00-15")
    assert_false(fast_parse_iso_date32(Span(b_zero_m)), "month=0 rejected")

    var b_big_m = _bytes("2024-13-15")
    assert_false(fast_parse_iso_date32(Span(b_big_m)), "month=13 rejected")

    var b_zero_d = _bytes("2024-02-00")
    assert_false(fast_parse_iso_date32(Span(b_zero_d)), "day=0 rejected")

    var b_feb_30 = _bytes("2024-02-30")
    assert_false(fast_parse_iso_date32(Span(b_feb_30)), "Feb 30 rejected")

    var b_non_leap = _bytes("2023-02-29")
    assert_false(
        fast_parse_iso_date32(Span(b_non_leap)),
        "Feb 29 in non-leap-year rejected",
    )

    # Sanity: SIMD must agree with scalar on rejection.
    var scalar_non_leap = _try_parse_date32(Span(b_non_leap))
    assert_false(scalar_non_leap, "scalar also rejects Feb 29 non-leap")


# =============================================================================
# T_TIMESTAMP: fast_parse_iso_timestamp_{s,ms,us,ns} parity + gates.
# =============================================================================


def test_timestamp_s_parity() raises:
    """Seconds-precision: parity on canonical 19-byte form."""
    var inputs = List[String]()
    inputs.append(String("1970-01-01T00:00:00"))     # epoch via 'T'
    inputs.append(String("1970-01-01 00:00:00"))     # epoch via ' '
    inputs.append(String("2024-02-29T12:34:56"))     # leap year
    inputs.append(String("2024-02-29T12:34:56Z"))    # Z suffix
    inputs.append(String("1999-12-31T23:59:59"))     # millennium eve
    inputs.append(String("2000-01-01T00:00:00"))     # millennium

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_timestamp_s(Span(b))
        var scalar = _try_parse_timestamp_s(Span(b))
        assert_true(fast, "TS_S SIMD accepts " + inputs[i])
        assert_true(scalar, "TS_S scalar accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "TS_S parity for " + inputs[i],
        )
        i = i + 1


def test_timestamp_ms_parity_with_fraction() raises:
    """Milliseconds: parity on canonical form including .fff fraction."""
    var inputs = List[String]()
    inputs.append(String("2024-02-29T12:34:56"))         # no fraction
    inputs.append(String("2024-02-29T12:34:56.123"))     # 3-digit fraction
    inputs.append(String("2024-02-29T12:34:56.001"))     # leading zero fraction
    inputs.append(String("2024-02-29T12:34:56.999"))     # max fraction
    inputs.append(String("2024-02-29T12:34:56.500Z"))    # fraction + Z

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_timestamp_ms(Span(b))
        var scalar = _try_parse_timestamp_ms(Span(b))
        assert_true(fast, "TS_MS SIMD accepts " + inputs[i])
        assert_true(scalar, "TS_MS scalar accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "TS_MS parity for " + inputs[i],
        )
        i = i + 1


def test_timestamp_us_parity() raises:
    """Microseconds: parity including 6-digit fraction."""
    var inputs = List[String]()
    inputs.append(String("2024-02-29T12:34:56.000001"))
    inputs.append(String("2024-02-29T12:34:56.999999"))
    inputs.append(String("2024-02-29T12:34:56.123456Z"))

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_timestamp_us(Span(b))
        var scalar = _try_parse_timestamp_us(Span(b))
        assert_true(fast, "TS_US SIMD accepts " + inputs[i])
        assert_true(scalar, "TS_US scalar accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "TS_US parity for " + inputs[i],
        )
        i = i + 1


def test_timestamp_ns_parity() raises:
    """Nanoseconds: parity including 9-digit fraction; overflow check."""
    var inputs = List[String]()
    inputs.append(String("2024-02-29T12:34:56.123456789"))
    inputs.append(String("2024-02-29T12:34:56"))           # no fraction
    inputs.append(String("2000-01-01T00:00:00.000000001")) # 1 ns past 2000

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_timestamp_ns(Span(b))
        var scalar = _try_parse_timestamp_ns(Span(b))
        assert_true(fast, "TS_NS SIMD accepts " + inputs[i])
        assert_true(scalar, "TS_NS scalar accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "TS_NS parity for " + inputs[i],
        )
        i = i + 1

    # Out-of-range date for ns precision must be rejected.
    var b_oor = _bytes("3000-01-01T00:00:00")
    assert_false(
        fast_parse_iso_timestamp_ns(Span(b_oor)),
        "ns: 3000-01-01 overflow rejected",
    )


def test_timestamp_s_rejects_subsecond() raises:
    """TS_S MUST reject sub-second fractions (precision loss)."""
    var b = _bytes("2024-02-29T12:34:56.123")
    assert_false(
        fast_parse_iso_timestamp_s(Span(b)),
        "TS_S rejects .fff",
    )


def test_timestamp_applicability_gate() raises:
    """Gate: validate 19-byte prefix + 'T'/' ' separator + time shape."""
    var b_ok_t = _bytes("2024-02-29T12:34:56")
    assert_true(cell_is_iso_timestamp_prefix(Span(b_ok_t)), "T-sep accepted")

    var b_ok_sp = _bytes("2024-02-29 12:34:56")
    assert_true(cell_is_iso_timestamp_prefix(Span(b_ok_sp)), "space-sep accepted")

    var b_bad_sep = _bytes("2024-02-29X12:34:56")
    assert_false(
        cell_is_iso_timestamp_prefix(Span(b_bad_sep)),
        "X separator rejected",
    )

    var b_short = _bytes("2024-02-29T12:34:5")  # 18 bytes
    assert_false(cell_is_iso_timestamp_prefix(Span(b_short)), "18-byte rejected")

    var b_bad_time = _bytes("2024-02-29T12-34-56")  # dashes in time
    assert_false(
        cell_is_iso_timestamp_prefix(Span(b_bad_time)),
        "non-colon time rejected",
    )


# =============================================================================
# T_TIME: fast_parse_iso_time_{s,ms,us,ns} parity + gates.
# =============================================================================


def test_time_s_parity() raises:
    """Time seconds: parity on 8-byte HH:MM:SS form."""
    var inputs = List[String]()
    inputs.append(String("00:00:00"))
    inputs.append(String("00:00:01"))
    inputs.append(String("12:34:56"))
    inputs.append(String("23:59:59"))
    inputs.append(String("01:23:45"))

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_time_s(Span(b))
        var scalar = _try_parse_time_s(Span(b))
        assert_true(fast, "TIME_S SIMD accepts " + inputs[i])
        assert_true(scalar, "TIME_S scalar accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "TIME_S parity for " + inputs[i],
        )
        i = i + 1


def test_time_ms_us_ns_parity() raises:
    """Time ms/us/ns: parity on canonical form with fraction."""
    var b_ms = _bytes("12:34:56.789")
    var f_ms = fast_parse_iso_time_ms(Span(b_ms))
    var s_ms = _try_parse_time_ms(Span(b_ms))
    assert_true(f_ms, "TIME_MS SIMD accepts")
    assert_true(s_ms, "TIME_MS scalar accepts")
    assert_equal(Int(f_ms.value()), Int(s_ms.value()), "TIME_MS parity")

    var b_us = _bytes("12:34:56.123456")
    var f_us = fast_parse_iso_time_us(Span(b_us))
    var s_us = _try_parse_time_us(Span(b_us))
    assert_true(f_us, "TIME_US SIMD accepts")
    assert_true(s_us, "TIME_US scalar accepts")
    assert_equal(Int(f_us.value()), Int(s_us.value()), "TIME_US parity")

    var b_ns = _bytes("12:34:56.123456789")
    var f_ns = fast_parse_iso_time_ns(Span(b_ns))
    var s_ns = _try_parse_time_ns(Span(b_ns))
    assert_true(f_ns, "TIME_NS SIMD accepts")
    assert_true(s_ns, "TIME_NS scalar accepts")
    assert_equal(Int(f_ns.value()), Int(s_ns.value()), "TIME_NS parity")


def test_time_s_rejects_subsecond() raises:
    """TIME_S rejects fractional seconds."""
    var b = _bytes("12:34:56.789")
    assert_false(fast_parse_iso_time_s(Span(b)), "TIME_S rejects fraction")


def test_time_rejects_out_of_range() raises:
    """h > 23, m > 59, s > 59 rejected by SIMD path."""
    var b_h = _bytes("25:00:00")
    assert_false(fast_parse_iso_time_s(Span(b_h)), "h=25 rejected")

    var b_m = _bytes("12:60:00")
    assert_false(fast_parse_iso_time_s(Span(b_m)), "m=60 rejected")

    var b_s = _bytes("12:00:60")
    assert_false(fast_parse_iso_time_s(Span(b_s)), "s=60 rejected")


def test_time_applicability_rejects_non_canonical() raises:
    """Non-canonical 8-byte forms rejected (e.g., dashes)."""
    var b_dash = _bytes("12-34-56")
    assert_false(fast_parse_iso_time_s(Span(b_dash)), "dash-sep rejected")

    var b_short = _bytes("12:34:5")
    assert_false(fast_parse_iso_time_s(Span(b_short)), "7-byte rejected")

    var b_long = _bytes("12:34:567")
    assert_false(fast_parse_iso_time_s(Span(b_long)), "9-byte without . rejected")


# =============================================================================
# T_DATE64: fast_parse_iso_date64_date_only parity + applicability.
# =============================================================================


def test_date64_date_only_parity() raises:
    """Date64 date-only parity (midnight UTC ms)."""
    var inputs = List[String]()
    inputs.append(String("1970-01-01"))
    inputs.append(String("2024-02-29"))
    inputs.append(String("2024-12-31"))
    inputs.append(String("1999-12-31"))
    inputs.append(String("2000-01-01"))

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_date64_date_only(Span(b))
        var scalar = _try_parse_date64(Span(b))
        assert_true(fast, "DATE64 SIMD accepts " + inputs[i])
        assert_true(scalar, "DATE64 scalar accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "DATE64 parity for " + inputs[i],
        )
        i = i + 1


def test_date64_rejects_datetime_form() raises:
    """Date64 SIMD date-only path returns None for 19+ byte datetime
    (caller falls back to scalar which handles both)."""
    var b_dt = _bytes("2024-02-29T12:34:56")
    var fast = fast_parse_iso_date64_date_only(Span(b_dt))
    assert_false(fast, "DATE64 date-only SIMD rejects datetime form")
    # The scalar parser handles datetime; verify it does.
    var scalar = _try_parse_date64(Span(b_dt))
    assert_true(scalar, "DATE64 scalar accepts datetime form")


# =============================================================================
# T_MIXED: leap years, boundary dates, mix of valid/invalid.
# =============================================================================


def test_mixed_leap_year_century_rule() raises:
    """Gregorian leap year rule: %4==0 except %100==0 unless %400==0."""
    # 2000: %400==0 -> leap.
    var b_2000 = _bytes("2000-02-29")
    assert_true(fast_parse_iso_date32(Span(b_2000)), "2000 is leap")

    # 1900: %100==0 and %400!=0 -> NOT leap.
    var b_1900 = _bytes("1900-02-29")
    assert_false(fast_parse_iso_date32(Span(b_1900)), "1900 NOT leap")

    # 2100: %100==0 and %400!=0 -> NOT leap.
    var b_2100 = _bytes("2100-02-29")
    assert_false(fast_parse_iso_date32(Span(b_2100)), "2100 NOT leap")

    # 2400: %400==0 -> leap.
    var b_2400 = _bytes("2400-02-29")
    assert_true(fast_parse_iso_date32(Span(b_2400)), "2400 is leap")

    # 2024: %4==0 and %100!=0 -> leap.
    var b_2024 = _bytes("2024-02-29")
    assert_true(fast_parse_iso_date32(Span(b_2024)), "2024 is leap")


def test_mixed_lineitem_shipdate_shape() raises:
    """Spot-check a few TPC-H lineitem.l_shipdate-shaped inputs.

    Real fixture has dates spread across 1992-1998 in canonical
    YYYY-MM-DD form. Verify SIMD parity on representatives.
    """
    var inputs = List[String]()
    inputs.append(String("1992-01-02"))
    inputs.append(String("1992-12-01"))
    inputs.append(String("1995-06-15"))
    inputs.append(String("1998-12-25"))
    inputs.append(String("1996-02-29"))  # 1996 IS leap

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_date32(Span(b))
        var scalar = _try_parse_date32(Span(b))
        assert_true(fast, "lineitem shape SIMD accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "lineitem shape parity " + inputs[i],
        )
        i = i + 1


def test_mixed_non_canonical_fallback() raises:
    """Non-canonical shapes -> SIMD returns None (caller scalar fallback).

    Verifies the SIMD gate is conservative: shapes that the scalar parser
    accepts (e.g., a non-canonical date format) are SIMD-rejected so the
    caller still gets a parse via the scalar fallback. The scalar parser
    also accepts only the canonical 10-byte form, so both
    fast and scalar return None for non-canonical inputs.
    """
    # Multiple non-canonical shapes that scalar also rejects.
    var inputs = List[String]()
    inputs.append(String("2024/02/29"))      # slash
    inputs.append(String("29-02-2024"))      # DMY order
    inputs.append(String("Feb 29 2024"))     # English
    inputs.append(String(""))                # empty

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_iso_date32(Span(b))
        var scalar = _try_parse_date32(Span(b))
        # Both None: SIMD-reject AND scalar-reject (canonical-only).
        assert_false(fast, "SIMD rejects " + inputs[i])
        assert_false(scalar, "scalar also rejects " + inputs[i])
        i = i + 1


# =============================================================================
# Driver.
# =============================================================================


def main() raises:
    # T_DATE32
    test_date32_parity_canonical()
    test_date32_applicability_gate()
    test_date32_invalid_dates_rejected()
    # T_TIMESTAMP
    test_timestamp_s_parity()
    test_timestamp_ms_parity_with_fraction()
    test_timestamp_us_parity()
    test_timestamp_ns_parity()
    test_timestamp_s_rejects_subsecond()
    test_timestamp_applicability_gate()
    # T_TIME
    test_time_s_parity()
    test_time_ms_us_ns_parity()
    test_time_s_rejects_subsecond()
    test_time_rejects_out_of_range()
    test_time_applicability_rejects_non_canonical()
    # T_DATE64
    test_date64_date_only_parity()
    test_date64_rejects_datetime_form()
    # T_MIXED
    test_mixed_leap_year_century_rule()
    test_mixed_lineitem_shipdate_shape()
    test_mixed_non_canonical_fallback()
    print("OK")
