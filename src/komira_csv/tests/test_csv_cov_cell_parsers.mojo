# =============================================================================
# Refusal edges of the scalar and SIMD cell parsers.
# =============================================================================
#
# The happy paths of these parsers are pinned by test_csv_cell_parsers,
# test_byte_span_numeric_parsers and test_csv_simd_temporal_parsers. What this
# file adds is every early `return None` a cell can reach, one cell per
# check, each paired with a near-miss that the same check must ACCEPT, so a
# mutant that drops the check (accepts the bad cell) or tightens it (refuses
# the good one) goes red. The mutant planted for each group is named in the
# group's docstring.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv.byte_span_numeric import (
    fast_parse_uint_n_digits,
    fast_parse_float64_simple,
    fast_parse_float64_decimal,
    _pow10_f64,
)
from komira_csv.cell_parsers import (
    _try_parse_int64,
    _try_parse_float64,
    _try_parse_date32,
    _try_parse_uint64,
    _try_parse_uint16,
    _try_parse_int32,
    _try_parse_int16,
    _try_parse_int8,
    _try_parse_decimal128_to_int64,
    unescape_cell_posix,
    cell_to_string,
)
from komira_csv.cell_parsers_simd import (
    cell_is_iso_date_shaped,
    fast_parse_iso_date64_date_only,
    cell_starts_iso_time,
    _parse_fractional_seconds_inline,
    fast_parse_iso_time_ms,
    fast_parse_iso_time_us,
    fast_parse_iso_time_ns,
    cell_is_iso_timestamp_prefix,
    fast_parse_iso_timestamp_s,
    fast_parse_iso_timestamp_ms,
    fast_parse_iso_timestamp_us,
    fast_parse_iso_timestamp_ns,
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


# -----------------------------------------------------------------------------
# byte_span_numeric
# -----------------------------------------------------------------------------


def _undigits(s: String, n: Int) -> Optional[UInt64]:
    var b = _b(s)
    return fast_parse_uint_n_digits(Span(b), n)


def _f64_simple(s: String) -> Optional[Float64]:
    var b = _b(s)
    return fast_parse_float64_simple(Span(b))


def _f64_dec(s: String) -> Optional[Float64]:
    var b = _b(s)
    return fast_parse_float64_decimal(Span(b))


def test_uint_n_digits_non_digit_in_simd_lanes() raises:
    """A non-digit inside the 8-byte Lemire load is refused for n == 8 and
    for n in [9, 16]. Mutant: drop `if not _all_digits_8(v): return None` in
    either arm -> the cell parses to a garbage value (red)."""
    assert_equal(_undigits("12345678", 8).value(), UInt64(12345678))
    assert_false(Bool(_undigits("1234a678", 8)), "n == 8 with a letter")
    assert_equal(_undigits("1234567890", 10).value(), UInt64(1234567890))
    assert_false(Bool(_undigits("12x4567890", 10)), "n == 10, letter in lane 2")
    assert_false(Bool(_undigits("123456789x", 10)), "n == 10, letter at 9")


def test_float64_simple_sign_only_and_letter() raises:
    """`-` alone, a letter after the digits, and 17 unsigned digits are
    refused. The sign and digit pre-scan is a fast reject only (the int
    path re-checks both, so dropping it is equivalent); 17 digits pass the
    pre-scan and are refused by the int path. Mutant: drop `if not v:
    return None` (red: 17 digits decode to a garbage value)."""
    assert_equal(_f64_simple("-12").value(), Float64(-12.0))
    assert_false(Bool(_f64_simple("-")), "sign only")
    assert_false(Bool(_f64_simple("+")), "plus only")
    assert_false(Bool(_f64_simple("-1x")), "letter after digits")
    assert_false(
        Bool(_f64_simple("12345678901234567")), "17 digits pass the scan only"
    )


def test_float64_decimal_every_fraction_length() raises:
    """`0.0..01` for fraction lengths 1..15 equals 10^-k: each length divides
    by a different `_pow10_f64` arm, so swapping any one constant (mutant:
    `if k == 7: return 1000000.0`) makes exactly that length wrong (red).
    `_pow10_f64(0)` is reachable only directly (a decimal has >= 1 fraction
    digit)."""
    var zero = Int(_i64("0").value())  # a run-time 0: not folded at compile time
    assert_equal(_pow10_f64(zero), Float64(1.0))
    var pow: Float64 = 1.0
    var k = 1
    while k <= 15:
        pow = pow * 10.0
        var s = String("0.")
        var z = 1
        while z < k:
            s += "0"
            z += 1
        s += "1"
        var got = _f64_dec(s)
        assert_true(Bool(got), "decimal with " + String(k) + " fraction digits")
        assert_equal(got.value(), Float64(1.0) / pow, s)
        assert_equal(_pow10_f64(k), pow, "_pow10_f64(" + String(k) + ")")
        k += 1


# -----------------------------------------------------------------------------
# cell_parsers (scalar)
# -----------------------------------------------------------------------------


def _i64(s: String) -> Optional[Int64]:
    var b = _b(s)
    return _try_parse_int64(Span(b))


def _f64(s: String) -> Optional[Float64]:
    var b = _b(s)
    return _try_parse_float64(Span(b), UInt8(ord(".")))


def _d32(s: String) -> Optional[Int32]:
    var b = _b(s)
    return _try_parse_date32(Span(b))


def test_int64_plus_sign_only() raises:
    """`+` alone is refused, `+7` is 7. Mutant: drop `if n == 1: return
    None` in the `+` arm -> `+` parses to 0 (red)."""
    assert_equal(_i64("+7").value(), Int64(7))
    assert_false(Bool(_i64("+")), "plus only")


def test_float64_sign_only_and_exponent_shapes() raises:
    """Sign-only cells, a dangling `e`, `e-`/`e+` with no digit and a letter in
    the exponent are refused; a negative exponent divides. Mutant: make the
    negative-exponent loop multiply (red: 25e-2 != 0.25)."""
    assert_false(Bool(_f64("-")), "minus only")
    assert_false(Bool(_f64("+")), "plus only")
    assert_equal(_f64("+2.5").value(), Float64(2.5))
    assert_false(Bool(_f64("1e")), "dangling e")
    assert_false(Bool(_f64("1e-")), "e- without digits")
    assert_false(Bool(_f64("1E+")), "E+ without digits")
    assert_false(Bool(_f64("1e2x")), "letter in exponent")
    assert_equal(_f64("25e-2").value(), Float64(0.25))
    assert_equal(_f64("5E-1").value(), Float64(0.5))
    assert_equal(_f64("3e+2").value(), Float64(300.0))


def test_date32_each_shape_check() raises:
    """One cell per refusal of `_try_parse_date32`: second dash, a year digit,
    a month digit, a day digit, month 13. Mutant: drop the second-dash check
    (red: `2024-01x01` decodes)."""
    assert_equal(_d32("1970-01-02").value(), Int32(1))
    assert_false(Bool(_d32("2024-01x01")), "second dash")
    assert_false(Bool(_d32("2a24-01-01")), "year digit")
    assert_false(Bool(_d32("2024-0a-01")), "month digit")
    assert_false(Bool(_d32("2024-01-0a")), "day digit")
    assert_false(Bool(_d32("2024-13-01")), "month 13")
    assert_false(Bool(_d32("2024-00-01")), "month 0")


def test_uint_and_narrow_int_refusals() raises:
    """UInt64: empty and a 20-digit value above the ceiling are refused, the
    exact maximum is accepted. The narrow parsers refuse a non-number before
    their range check. Mutant: drop `if result > ceiling` (red: 20 nines
    wrap)."""
    var e = _b("")
    assert_false(Bool(_try_parse_uint64(Span(e))), "empty")
    var big = _b("99999999999999999999")
    assert_false(Bool(_try_parse_uint64(Span(big))), "20 nines overflow")
    var mx = _b("18446744073709551615")
    assert_equal(_try_parse_uint64(Span(mx)).value(), UInt64.MAX)
    var x = _b("x1")
    assert_false(Bool(_try_parse_uint16(Span(x))), "uint16 non-number")
    assert_false(Bool(_try_parse_int32(Span(x))), "int32 non-number")
    assert_false(Bool(_try_parse_int16(Span(x))), "int16 non-number")
    assert_false(Bool(_try_parse_int8(Span(x))), "int8 non-number")
    var ok = _b("-12")
    assert_equal(_try_parse_int8(Span(ok)).value(), Int8(-12))
    assert_equal(_try_parse_int16(Span(ok)).value(), Int16(-12))
    assert_equal(_try_parse_int32(Span(ok)).value(), Int32(-12))


def _dec(s: String, p: Int, sc: Int) -> Optional[Int64]:
    var b = _b(s)
    return _try_parse_decimal128_to_int64(Span(b), p, sc)


def test_decimal_argument_and_shape_refusals() raises:
    """Precision outside [1, 18], scale outside [0, precision], an empty cell,
    a sign alone, a letter, and a lone dot are refused; `-1.5` at (5, 2) is
    -150. Mutant: `precision > 18` -> `> 19` (red: precision 19 accepted)."""
    assert_equal(_dec("-1.5", 5, 2).value(), Int64(-150))
    assert_equal(_dec(".5", 1, 1).value(), Int64(5))
    assert_false(Bool(_dec("1", 0, 0)), "precision 0")
    assert_false(Bool(_dec("1", 19, 0)), "precision 19")
    assert_true(Bool(_dec("1", 18, 0)), "precision 18 accepted")
    assert_false(Bool(_dec("1", 5, -1)), "negative scale")
    assert_false(Bool(_dec("1", 5, 6)), "scale above precision")
    assert_false(Bool(_dec("", 5, 2)), "empty")
    assert_false(Bool(_dec("-", 5, 2)), "sign only")
    assert_false(Bool(_dec("+", 5, 2)), "plus only")
    assert_false(Bool(_dec("1x", 5, 2)), "letter")
    assert_false(Bool(_dec(".", 5, 2)), "dot only")


def test_posix_escapes_and_cell_to_string_unescape() raises:
    """`\\t` and `\\r` translate to TAB and CR; `cell_to_string` routes a
    flagged cell to the doubled-quote collapse (RFC 4180 / Excel) or the
    backslash collapse (Posix). Mutant: invert `double_quote_escapes` in
    `cell_to_string` (red: `a""b` keeps both quotes under the Posix
    collapse)."""
    var p = _b("a\\tb\\rc\\qd")
    assert_equal(unescape_cell_posix(Span(p), UInt8(ord("\\"))), "a\tb\rcqd")
    var dq = _b('a""b')
    assert_equal(
        cell_to_string(Span(dq), True, True, UInt8(ord('"')), UInt8(0)),
        'a"b',
    )
    var px = _b("x\\ny")
    assert_equal(
        cell_to_string(
            Span(px), True, False, UInt8(ord('"')), UInt8(ord("\\"))
        ),
        "x\ny",
    )


# -----------------------------------------------------------------------------
# cell_parsers_simd
# -----------------------------------------------------------------------------


def _shaped(s: String) -> Bool:
    var b = _b(s)
    return cell_is_iso_date_shaped(Span(b))


def _d64(s: String) -> Optional[Int64]:
    var b = _b(s)
    return fast_parse_iso_date64_date_only(Span(b))


def _starts_time(s: String) -> Bool:
    var b = _b(s)
    return cell_starts_iso_time(Span(b), 0)


def test_date_shape_gate_and_date64_month() raises:
    """The SIMD date gate refuses a wrong second dash and a non-digit month;
    `fast_parse_iso_date64_date_only` refuses month 13. Mutant: `month > 12`
    -> `> 13` in the date-only Date64 path (red: month 13 decodes)."""
    assert_true(_shaped("2024-02-29"), "valid date")
    assert_false(_shaped("2024-02x29"), "lane 7 not a dash")
    assert_false(_shaped("2024-0x-29"), "lane 6 not a digit")
    assert_false(_shaped("2024-x2-29"), "lane 5 not a digit")
    assert_equal(_d64("1970-01-02").value(), Int64(86400000))
    assert_false(Bool(_d64("2024-13-01")), "month 13")


def test_time_gate_each_lane() raises:
    """`cell_starts_iso_time` checks the second colon and each digit lane. One
    cell per lane. Mutant: drop the lane-6 digit check (red: `12:34:x6`
    passes)."""
    assert_true(_starts_time("12:34:56"), "valid time")
    assert_false(_starts_time("12:34x56"), "second colon")
    assert_false(_starts_time("x2:34:56"), "lane 0")
    assert_false(_starts_time("1x:34:56"), "lane 1")
    assert_false(_starts_time("12:x4:56"), "lane 3")
    assert_false(_starts_time("12:3x:56"), "lane 4")
    assert_false(_starts_time("12:34:x6"), "lane 6")
    assert_false(_starts_time("12:34:5x"), "lane 7")


def test_fractional_seconds_inline_absent() raises:
    """Called where no `.` starts the fraction (or past the end), the helper
    reports `(0, 0)`: no value, nothing consumed. Mutant: return `(0, 1)`
    (red)."""
    var b = _b("12:00:00")
    var at_end = _parse_fractional_seconds_inline(Span(b), 8, 3)
    assert_equal(at_end.value()[0], 0)
    assert_equal(at_end.value()[1], 0)
    var no_dot = _parse_fractional_seconds_inline(Span(b), 2, 3)
    assert_equal(no_dot.value()[1], 0)


def _tms(s: String) -> Optional[Int32]:
    var b = _b(s)
    return fast_parse_iso_time_ms(Span(b))


def _tus(s: String) -> Optional[Int64]:
    var b = _b(s)
    return fast_parse_iso_time_us(Span(b))


def _tns(s: String) -> Optional[Int64]:
    var b = _b(s)
    return fast_parse_iso_time_ns(Span(b))


def test_time_ms_us_ns_refusals() raises:
    """For each of time_ms/us/ns: too short, a bad gate, an hour/minute out of
    range, a dot with no digit, too many fraction digits, and trailing
    garbage are refused; a valid fraction decodes. Mutant: drop time_us's
    `pos != n` check (red: `12:00:00 ` accepted)."""
    assert_equal(_tms("00:00:01.5").value(), Int32(1500))
    assert_false(Bool(_tms("12:00")), "ms short")
    assert_false(Bool(_tms("12x00:00")), "ms gate")
    assert_false(Bool(_tms("24:00:00")), "ms hour 24")
    assert_false(Bool(_tms("12:00:00Z")), "ms trailing")

    assert_equal(_tus("00:00:01.25").value(), Int64(1250000))
    assert_false(Bool(_tus("12x00:00")), "us gate")
    assert_false(Bool(_tus("12:60:00")), "us minute 60")
    assert_false(Bool(_tus("12:00:00.")), "us dot without digit")
    assert_false(Bool(_tus("12:00:00.1234567")), "us 7 fraction digits")
    assert_false(Bool(_tus("12:00:00 ")), "us trailing")

    assert_equal(_tns("00:00:01.000000001").value(), Int64(1000000001))
    assert_false(Bool(_tns("1:00:00")), "ns short")
    assert_false(Bool(_tns("12x00:00")), "ns gate")
    assert_false(Bool(_tns("12:00:00.1234567890")), "ns 10 fraction digits")
    assert_false(Bool(_tns("12:00:00x")), "ns trailing")


def _prefix(s: String) -> Bool:
    var b = _b(s)
    return cell_is_iso_timestamp_prefix(Span(b))


def test_timestamp_prefix_each_lane() raises:
    """The timestamp gate checks both dashes and each of the eight date digit
    lanes. One cell per check. Mutant: drop the lane-9 digit check (red:
    `2024-01-0x...` passes)."""
    assert_true(_prefix("2024-01-02T03:04:05"), "valid")
    assert_false(_prefix("2024x01-02T03:04:05"), "dash 4")
    assert_false(_prefix("2024-01x02T03:04:05"), "dash 7")
    assert_false(_prefix("x024-01-02T03:04:05"), "lane 0")
    assert_false(_prefix("2x24-01-02T03:04:05"), "lane 1")
    assert_false(_prefix("20x4-01-02T03:04:05"), "lane 2")
    assert_false(_prefix("202x-01-02T03:04:05"), "lane 3")
    assert_false(_prefix("2024-x1-02T03:04:05"), "lane 5")
    assert_false(_prefix("2024-0x-02T03:04:05"), "lane 6")
    assert_false(_prefix("2024-01-x2T03:04:05"), "lane 8")
    assert_false(_prefix("2024-01-0xT03:04:05"), "lane 9")


def _ts(s: String, unit: Int) -> Optional[Int64]:
    var b = _b(s)
    if unit == 0:
        return fast_parse_iso_timestamp_s(Span(b))
    if unit == 1:
        return fast_parse_iso_timestamp_ms(Span(b))
    if unit == 2:
        return fast_parse_iso_timestamp_us(Span(b))
    return fast_parse_iso_timestamp_ns(Span(b))


def test_timestamp_refusals_every_unit() raises:
    """For each unit (s, ms, us, ns): a failed gate, month 13, Feb 30 in a leap
    year, hour 24, and trailing garbage are refused; ns also refuses a
    10-digit fraction. The accepted control is 1970-01-02 00:00:01 in each
    unit. Mutant: `day > days_in_month` -> `> 1 + days_in_month` in the ms
    parser (red: Feb 30 decodes)."""
    var scale = List[Int64]()
    scale.append(1)
    scale.append(1000)
    scale.append(1000000)
    scale.append(1000000000)
    var u = 0
    while u < 4:
        var tag = String("unit ") + String(u)
        assert_equal(
            _ts("1970-01-02T00:00:01", u).value(),
            Int64(86401) * scale[u],
            tag,
        )
        assert_false(Bool(_ts("1970-01-02", u)), tag + ": gate (too short)")
        assert_false(Bool(_ts("2024-13-01T00:00:00", u)), tag + ": month 13")
        assert_false(Bool(_ts("2024-02-30T00:00:00", u)), tag + ": Feb 30")
        assert_false(Bool(_ts("2024-01-01T24:00:00", u)), tag + ": hour 24")
        assert_false(Bool(_ts("2024-01-01T00:00:00x", u)), tag + ": trailing")
        u += 1
    assert_false(
        Bool(_ts("2024-01-01T00:00:00.1234567890", 3)), "ns 10 digits"
    )


def main() raises:
    test_uint_n_digits_non_digit_in_simd_lanes()
    test_float64_simple_sign_only_and_letter()
    test_float64_decimal_every_fraction_length()
    test_int64_plus_sign_only()
    test_float64_sign_only_and_exponent_shapes()
    test_date32_each_shape_check()
    test_uint_and_narrow_int_refusals()
    test_decimal_argument_and_shape_refusals()
    test_posix_escapes_and_cell_to_string_unescape()
    test_date_shape_gate_and_date64_month()
    test_time_gate_each_lane()
    test_fractional_seconds_inline_absent()
    test_time_ms_us_ns_refusals()
    test_timestamp_prefix_each_lane()
    test_timestamp_refusals_every_unit()
    print("test_csv_cov_cell_parsers: 15 tests PASS")
