# =============================================================================
# Tests for the Int64 range of the temporal cell parsers (komira#899).
# =============================================================================
#
# A Timestamp[ns] or Duration whose value does not fit in Int64 nanoseconds
# must be refused (None, so the cell becomes null), never wrapped; a
# Duration in a coarser unit rounds toward zero, as its docstring says.
#
#   T1 timestamp_ns upper bound: 2262-04-11T23:47:16.854775807 is Int64.MAX;
#      one nanosecond later, and the rest of that day, are refused. Scalar
#      parser and SIMD fast path agree on every cell.
#   T2 timestamp_ns lower bound: 1677-09-21T00:12:43.145224192 is Int64.MIN;
#      one nanosecond earlier is refused.
#   T3 ISO duration per component: the largest whole D / H / M / S count
#      that fits is accepted, one more is refused.
#   T4 ISO duration sums and digit runs: a sum of in-range components that
#      passes Int64.MAX is refused, as is a digit run longer than Int64.
#   T5 Duration_{s,ms,us} round toward zero for negative values.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv.temporal_parsers import (
    _try_parse_timestamp_ns,
    _try_parse_duration_ns,
    _try_parse_duration_us,
    _try_parse_duration_ms,
    _try_parse_duration_s,
)
from komira_csv.cell_parsers_simd import fast_parse_iso_timestamp_ns


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _int64_max() -> Int64:
    return Int64(9223372036854775807)


def _int64_min() -> Int64:
    return Int64(-9223372036854775807) - Int64(1)


def _assert_ts_ns(text: String, expected: Int64) raises:
    """Both timestamp_ns parsers accept `text` as `expected`."""
    var b = _bytes(text)
    var scalar = _try_parse_timestamp_ns(Span(b))
    var fast = fast_parse_iso_timestamp_ns(Span(b))
    assert_true(scalar, "scalar timestamp_ns accepts " + text)
    assert_true(fast, "SIMD timestamp_ns accepts " + text)
    assert_equal(Int(scalar.value()), Int(expected), "scalar timestamp_ns of " + text)
    assert_equal(Int(fast.value()), Int(expected), "SIMD timestamp_ns of " + text)


def _assert_ts_ns_refused(text: String) raises:
    """Both timestamp_ns parsers refuse `text`."""
    var b = _bytes(text)
    assert_false(
        _try_parse_timestamp_ns(Span(b)), "scalar timestamp_ns refuses " + text
    )
    assert_false(
        fast_parse_iso_timestamp_ns(Span(b)), "SIMD timestamp_ns refuses " + text
    )


def _assert_dur_ns(text: String, expected: Int64) raises:
    var b = _bytes(text)
    var p = _try_parse_duration_ns(Span(b))
    assert_true(p, "duration_ns accepts " + text)
    assert_equal(Int(p.value()), Int(expected), "duration_ns of " + text)


def _assert_dur_ns_refused(text: String) raises:
    var b = _bytes(text)
    assert_false(_try_parse_duration_ns(Span(b)), "duration_ns refuses " + text)


def test_t1_timestamp_ns_upper_bound() raises:
    _assert_ts_ns(String("2262-04-11T23:47:16.854775807"), _int64_max())
    _assert_ts_ns(String("2262-04-11T23:47:16.854775807Z"), _int64_max())
    _assert_ts_ns(
        String("2262-04-11T23:47:15"), Int64(9223372035000000000)
    )
    # The cell from komira#899: inside the old day window, past Int64.MAX.
    _assert_ts_ns_refused(String("2262-04-11T23:59:59"))
    _assert_ts_ns_refused(String("2262-04-11T23:47:16.854775808"))
    _assert_ts_ns_refused(String("2262-04-11T23:47:17"))
    _assert_ts_ns_refused(String("2262-04-12T00:00:00"))
    _assert_ts_ns_refused(String("9999-12-31T23:59:59.999999999"))


def test_t2_timestamp_ns_lower_bound() raises:
    _assert_ts_ns(String("1677-09-21T00:12:43.145224192"), _int64_min())
    _assert_ts_ns(
        String("1677-09-21 00:12:44"), Int64(-9223372036000000000)
    )
    _assert_ts_ns(
        String("1677-09-22T00:00:00"), Int64(-106751) * Int64(86400000000000)
    )
    _assert_ts_ns_refused(String("1677-09-21T00:12:43.145224191"))
    _assert_ts_ns_refused(String("1677-09-21T00:00:00"))
    _assert_ts_ns_refused(String("0001-01-01T00:00:00"))


def test_t3_iso_duration_per_component() raises:
    _assert_dur_ns(String("P106751D"), Int64(9223286400000000000))
    # The cell from komira#899: wrapped negative before the check.
    _assert_dur_ns_refused(String("P106752D"))
    _assert_dur_ns(String("PT2562047H"), Int64(9223369200000000000))
    _assert_dur_ns_refused(String("PT2562048H"))
    _assert_dur_ns(String("PT153722867M"), Int64(9223372020000000000))
    _assert_dur_ns_refused(String("PT153722868M"))
    _assert_dur_ns(String("PT9223372036S"), Int64(9223372036000000000))
    _assert_dur_ns_refused(String("PT9223372037S"))
    _assert_dur_ns(String("PT9223372036.854775807S"), _int64_max())
    _assert_dur_ns_refused(String("PT9223372036.854775808S"))
    _assert_dur_ns_refused(String("PT9223372037.5S"))
    _assert_dur_ns(String("-P106751D"), Int64(-9223286400000000000))
    _assert_dur_ns_refused(String("-P106752D"))
    # The coarser units derive from nanoseconds, so they refuse it too.
    var b = _bytes(String("P106752D"))
    assert_false(_try_parse_duration_s(Span(b)), "duration_s refuses P106752D")


def test_t4_iso_duration_sums_and_digit_runs() raises:
    _assert_dur_ns(String("P106751DT23H47M16.854775807S"), _int64_max())
    _assert_dur_ns(String("-P106751DT23H47M16.854775807S"), -_int64_max())
    _assert_dur_ns_refused(String("P106751DT23H47M16.854775808S"))
    _assert_dur_ns_refused(String("P106751DT23H47M17S"))
    _assert_dur_ns_refused(String("P106751DT24H"))
    _assert_dur_ns_refused(String("PT2562047H788M"))
    # Digit runs longer than Int64 holds, in the day and time segments.
    _assert_dur_ns_refused(String("P99999999999999999999D"))
    _assert_dur_ns_refused(String("P18446744073709551616D"))
    _assert_dur_ns_refused(String("PT99999999999999999999H"))
    _assert_dur_ns_refused(String("PT18446744073709551616S"))


def test_t5_duration_rounds_toward_zero() raises:
    var neg_1_5 = _bytes(String("-1.5"))
    assert_equal(Int(_try_parse_duration_s(Span(neg_1_5)).value()), -1, "-1.5 s")
    var pos_1_5 = _bytes(String("1.5"))
    assert_equal(Int(_try_parse_duration_s(Span(pos_1_5)).value()), 1, "1.5 s")
    var neg_2 = _bytes(String("-2"))
    assert_equal(Int(_try_parse_duration_s(Span(neg_2)).value()), -2, "-2 s")
    var neg_half = _bytes(String("-PT0.5S"))
    assert_equal(Int(_try_parse_duration_s(Span(neg_half)).value()), 0, "-PT0.5S s")
    var neg_ms = _bytes(String("-PT1.0005S"))
    assert_equal(Int(_try_parse_duration_ms(Span(neg_ms)).value()), -1000, "-PT1.0005S ms")
    var neg_ms_exact = _bytes(String("-PT1.5S"))
    assert_equal(Int(_try_parse_duration_ms(Span(neg_ms_exact)).value()), -1500, "-PT1.5S ms")
    var neg_us = _bytes(String("-PT0.0000015S"))
    assert_equal(Int(_try_parse_duration_us(Span(neg_us)).value()), -1, "-PT0.0000015S us")


def main() raises:
    # Every test runs even after one fails, so a red run names each failure.
    var failed = 0
    try:
        test_t1_timestamp_ns_upper_bound()
    except e:
        print("FAIL test_t1_timestamp_ns_upper_bound:", e)
        failed = failed + 1
    try:
        test_t2_timestamp_ns_lower_bound()
    except e:
        print("FAIL test_t2_timestamp_ns_lower_bound:", e)
        failed = failed + 1
    try:
        test_t3_iso_duration_per_component()
    except e:
        print("FAIL test_t3_iso_duration_per_component:", e)
        failed = failed + 1
    try:
        test_t4_iso_duration_sums_and_digit_runs()
    except e:
        print("FAIL test_t4_iso_duration_sums_and_digit_runs:", e)
        failed = failed + 1
    try:
        test_t5_duration_rounds_toward_zero()
    except e:
        print("FAIL test_t5_duration_rounds_toward_zero:", e)
        failed = failed + 1
    if failed > 0:
        raise Error("test_csv_temporal_range: " + String(failed) + "/5 FAILED")
    print("test_csv_temporal_range: 5/5 PASS")
