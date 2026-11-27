# =============================================================================
# Tests for `temporal_epoch`: `epoch` (DOUBLE seconds), `epoch_ms` and
# `epoch_us` (BIGINT) over DATE32 and every TIMESTAMP_* unit.
#
# Every expected value is DuckDB v1.5.5's answer for the same instant
# (`SELECT epoch(TIMESTAMP '...')`, `epoch_ms(TIMESTAMP_NS '...')`, ...), quoted
# beside the row as the literal it was measured on.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.testing import assert_raises

from arrow.primitive_array import PrimitiveArray
from arrow.arrow_types import ArrowType
from kernels.temporal_epoch import (
    div_trunc,
    epoch_ms_date32,
    epoch_ms_ts,
    epoch_seconds_date32,
    epoch_seconds_ts,
    epoch_us_date32,
    epoch_us_ts,
    ts_to_micros,
)


def _i64(values: List[Int64]) -> PrimitiveArray[DType.int64]:
    var vals = List[Scalar[DType.int64]]()
    for v in values:
        vals.append(Scalar[DType.int64](v))
    return PrimitiveArray[DType.int64].from_list(vals)


def _i32(values: List[Int32]) -> PrimitiveArray[DType.int32]:
    var vals = List[Scalar[DType.int32]]()
    for v in values:
        vals.append(Scalar[DType.int32](v))
    return PrimitiveArray[DType.int32].from_list(vals)


def _with_null[dt: DType](values: List[Scalar[dt]], null_row: Int) raises -> PrimitiveArray[dt]:
    var n = len(values)
    var arr = PrimitiveArray[dt].allocate_nullable(n)
    for i in range(n):
        arr.set(i, values[i])
    arr._set_null(null_row)
    arr.null_count = 1
    return arr^


# ---- TIMESTAMP_US: the unit DuckDB's TIMESTAMP is in --------------------------


def test_a_fractional_timestamp_has_fractional_epoch_seconds() raises:
    """TIMESTAMP '2026-09-01 00:00:00.123456': epoch 1788220800.123456, epoch_ms
    1788220800123 (the microseconds dropped), epoch_us the tick count."""
    var a = _i64([Int64(1788220800123456)])
    assert_equal(epoch_seconds_ts(a, ArrowType.TIMESTAMP_US).get(0), Float64(1788220800.123456))
    assert_equal(epoch_ms_ts(a, ArrowType.TIMESTAMP_US).get(0), Int64(1788220800123))
    assert_equal(epoch_us_ts(a, ArrowType.TIMESTAMP_US).get(0), Int64(1788220800123456))


def test_a_pre_1970_timestamp_is_negative_and_ms_truncates_toward_zero() raises:
    """TIMESTAMP '1969-12-31 23:59:59.9995' is -500 us: epoch -0.0005, epoch_us
    -500, and epoch_ms 0 (toward zero; a floor would answer -1).
    TIMESTAMP '1969-12-31 23:59:59.001' is -999000 us: epoch_ms -999."""
    var a = _i64([Int64(-500), Int64(-999000)])
    var s = epoch_seconds_ts(a, ArrowType.TIMESTAMP_US)
    var ms = epoch_ms_ts(a, ArrowType.TIMESTAMP_US)
    var us = epoch_us_ts(a, ArrowType.TIMESTAMP_US)
    assert_equal(s.get(0), Float64(-0.0005))
    assert_equal(ms.get(0), Int64(0))
    assert_equal(us.get(0), Int64(-500))
    assert_equal(ms.get(1), Int64(-999))
    assert_equal(s.get(1), Float64(-0.999))


def test_instants_past_2038_and_far_before_1970_are_exact() raises:
    """TIMESTAMP '2100-01-01' (past the 32-bit second limit of 2038):
    4102444800.0 and 4102444800000 ms. TIMESTAMP '-290000-01-01':
    -9213683299200.0, near the bottom of the microsecond range."""
    var a = _i64([Int64(4102444800000000), Int64(-9213683299200000000)])
    var s = epoch_seconds_ts(a, ArrowType.TIMESTAMP)
    var ms = epoch_ms_ts(a, ArrowType.TIMESTAMP)
    assert_equal(s.get(0), Float64(4102444800.0))
    assert_equal(ms.get(0), Int64(4102444800000))
    assert_equal(s.get(1), Float64(-9213683299200.0))
    assert_equal(ms.get(1), Int64(-9213683299200000))
    assert_equal(epoch_us_ts(a, ArrowType.TIMESTAMP).get(1), Int64(-9213683299200000000))


# ---- the other TIMESTAMP units ------------------------------------------------


def test_timestamp_ns_is_truncated_toward_zero_to_microseconds_first() raises:
    """TIMESTAMP_NS '1969-12-31 23:59:59.999999999' (-1 ns): 0 in all three.
    '...59.998999999' (-1000001 ns): epoch_ms -1. '...59.999998999' (-1001 ns):
    epoch_us -1. '2026-09-01 00:00:00.123456789': the nanoseconds dropped."""
    var a = _i64([Int64(-1), Int64(-1000001), Int64(-1001), Int64(1788220800123456789)])
    var s = epoch_seconds_ts(a, ArrowType.TIMESTAMP_NS)
    var ms = epoch_ms_ts(a, ArrowType.TIMESTAMP_NS)
    var us = epoch_us_ts(a, ArrowType.TIMESTAMP_NS)
    assert_equal(s.get(0), Float64(0.0))
    assert_equal(ms.get(0), Int64(0))
    assert_equal(us.get(0), Int64(0))
    assert_equal(ms.get(1), Int64(-1))
    assert_equal(us.get(2), Int64(-1))
    assert_equal(us.get(3), Int64(1788220800123456))
    assert_equal(s.get(3), Float64(1788220800.123456))


def test_timestamp_ms_and_s_are_scaled_up() raises:
    """TIMESTAMP_MS '2026-09-01 00:00:00.123': epoch_us 1788220800123000.
    TIMESTAMP_S '1960-01-01': epoch -315619200.0, epoch_ms -315619200000."""
    var m = _i64([Int64(1788220800123)])
    assert_equal(epoch_us_ts(m, ArrowType.TIMESTAMP_MS).get(0), Int64(1788220800123000))
    assert_equal(epoch_ms_ts(m, ArrowType.TIMESTAMP_MS).get(0), Int64(1788220800123))
    var s = _i64([Int64(-315619200)])
    assert_equal(epoch_seconds_ts(s, ArrowType.TIMESTAMP_S).get(0), Float64(-315619200.0))
    assert_equal(epoch_ms_ts(s, ArrowType.TIMESTAMP_S).get(0), Int64(-315619200000))


def test_a_second_count_too_large_for_microseconds_raises() raises:
    """DuckDB refuses a TIMESTAMP_S or _MS whose microsecond count leaves
    BIGINT ('Could not convert Timestamp(S) to Timestamp(US)'); the kernel
    raises too instead of wrapping. The largest second count that fits does
    not raise, in either direction."""
    var top = Int64(9223372036854)
    assert_equal(ts_to_micros(top, ArrowType.TIMESTAMP_S), top * 1_000_000)
    assert_equal(ts_to_micros(-top, ArrowType.TIMESTAMP_S), -top * 1_000_000)
    with assert_raises(contains="Could not convert Timestamp(S) 9223372036855"):
        _ = epoch_us_ts(_i64([top + 1]), ArrowType.TIMESTAMP_S)
    with assert_raises(contains="Could not convert Timestamp(S) -9223372036855"):
        _ = epoch_seconds_ts(_i64([-top - 1]), ArrowType.TIMESTAMP_S)
    with assert_raises(contains="Could not convert Timestamp(MS) 9223372036854776"):
        _ = epoch_ms_ts(_i64([Int64(9223372036854776)]), ArrowType.TIMESTAMP_MS)


def test_a_non_timestamp_unit_is_refused() raises:
    """A DATE32 or INT64 passed as the timestamp unit raises, naming it."""
    with assert_raises(contains="unsupported timestamp unit type_id="):
        _ = epoch_us_ts(_i64([Int64(0)]), ArrowType.INT64)


# ---- DATE32 -------------------------------------------------------------------


def test_date32_counts_whole_days() raises:
    """DATE '2026-09-01' (day 20697): 1788220800.0 s, 1788220800000 ms,
    1788220800000000 us. DATE '1969-12-31' (day -1): -86400000 ms.
    DATE '5000000-01-01' (day 1825492972): 157722592780800.0 s and
    157722592780800000 ms, past the microsecond range."""
    var d = _i32([Int32(20697), Int32(-1), Int32(1825492972)])
    var s = epoch_seconds_date32(d)
    var ms = epoch_ms_date32(d)
    assert_equal(s.get(0), Float64(1788220800.0))
    assert_equal(ms.get(0), Int64(1788220800000))
    assert_equal(ms.get(1), Int64(-86400000))
    assert_equal(s.get(1), Float64(-86400.0))
    assert_equal(s.get(2), Float64(157722592780800.0))
    assert_equal(ms.get(2), Int64(157722592780800000))
    assert_equal(epoch_us_date32(_i32([Int32(20697)])).get(0), Int64(1788220800000000))


def test_date32_microseconds_out_of_range_raise() raises:
    """DuckDB: epoch_us(DATE '5000000-01-01') is 'Could not convert DATE ... to
    microseconds'. The kernel raises rather than wrapping, both ways."""
    with assert_raises(contains="Could not convert DATE day 1825492972"):
        _ = epoch_us_date32(_i32([Int32(1825492972)]))
    with assert_raises(contains="Could not convert DATE day -1825492972"):
        _ = epoch_us_date32(_i32([Int32(-1825492972)]))


# ---- NULL ---------------------------------------------------------------------


def test_null_stays_null_and_is_never_computed_on() raises:
    """A NULL row is NULL in every output, and its data lane is not read:
    the value under the null here would overflow if it were."""
    var ts = List[Scalar[DType.int64]]()
    ts.append(Scalar[DType.int64](9223372036854775807))
    ts.append(Scalar[DType.int64](1))
    var a = _with_null[DType.int64](ts, 0)
    for unit in [ArrowType.TIMESTAMP_S, ArrowType.TIMESTAMP_US]:
        var s = epoch_seconds_ts(a, unit)
        var ms = epoch_ms_ts(a, unit)
        var us = epoch_us_ts(a, unit)
        assert_true(s.is_null(0))
        assert_true(ms.is_null(0))
        assert_true(us.is_null(0))
        assert_false(us.is_null(1))
        assert_equal(s.null_count, 1)
    var d = List[Scalar[DType.int32]]()
    d.append(Scalar[DType.int32](2147483647))
    d.append(Scalar[DType.int32](0))
    var b = _with_null[DType.int32](d, 0)
    assert_true(epoch_seconds_date32(b).is_null(0))
    assert_true(epoch_ms_date32(b).is_null(0))
    var bus = epoch_us_date32(b)
    assert_true(bus.is_null(0))
    assert_false(bus.is_null(1))
    assert_equal(bus.get(1), Int64(0))


def test_a_slice_keeps_its_own_validity_window() raises:
    """slice(1, 2) of [NULL, 1, NULL] is [1, NULL]: the null is logical row 1."""
    var v = List[Scalar[DType.int64]]()
    for _ in range(3):
        v.append(Scalar[DType.int64](1000000))
    var arr = PrimitiveArray[DType.int64].allocate_nullable(3)
    for i in range(3):
        arr.set(i, v[i])
    arr._set_null(0)
    arr._set_null(2)
    arr.null_count = 2
    var s = arr.slice(1, 2)
    var out = epoch_seconds_ts(s, ArrowType.TIMESTAMP_US)
    assert_false(out.is_null(0))
    assert_true(out.is_null(1))
    assert_equal(out.null_count, 1)
    assert_equal(out.get(0), Float64(1.0))


def test_div_trunc_rounds_toward_zero() raises:
    """C integer division: -7/2 = -3, 7/2 = 3, -6/2 = -3, 0/2 = 0."""
    assert_equal(div_trunc(Int64(-7), Int64(2)), Int64(-3))
    assert_equal(div_trunc(Int64(7), Int64(2)), Int64(3))
    assert_equal(div_trunc(Int64(-6), Int64(2)), Int64(-3))
    assert_equal(div_trunc(Int64(0), Int64(2)), Int64(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
