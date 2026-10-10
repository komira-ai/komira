# =============================================================================
# Tests for INT96 timestamp decode (legacy Spark/Hive format)
# =============================================================================
#
# INT96 stores timestamps as 12 bytes per value:
#   bytes [0:8]  = nanos within the Julian day (Int64 LE)
#   bytes [8:12] = Julian day number (Int32 LE)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet.plain import decode_plain_int96_to_int64


def _write_int96(
    mut buf: List[UInt8],
    offset: Int,
    nanos_in_day: Int64,
    julian_day: Int32,
):
    """Write a single INT96 value to a buffer at the given offset.

    Layout: 8 bytes nanos_in_day (LE) + 4 bytes julian_day (LE).
    """
    var n = UInt64(nanos_in_day)
    for k in range(8):
        buf[offset + k] = UInt8((n >> UInt64(8 * k)) & 0xFF)
    var d = UInt32(julian_day)
    for k in range(4):
        buf[offset + 8 + k] = UInt8((d >> UInt32(8 * k)) & 0xFF)


def test_int96_unix_epoch() raises:
    """INT96 for the Unix epoch (midnight UTC).

    Julian day 2440588 = Unix epoch.
    nanos_in_day = 0.
    Expected result: 0 nanoseconds since epoch.
    """
    var buf = List[UInt8](length=12, fill=0)
    _write_int96(buf, 0, Int64(0), Int32(2440588))

    var arr = decode_plain_int96_to_int64(Span(buf), 1)
    assert_equal(arr.length, 1)
    assert_equal(Int(arr.get(0)), 0)



def test_int96_one_day_after_epoch() raises:
    """INT96 for midnight UTC one day after the epoch.

    Julian day 2440589 = one day after epoch.
    nanos_in_day = 0.
    Expected: 86400 * 1e9 = 86_400_000_000_000 ns.
    """
    var buf = List[UInt8](length=12, fill=0)
    _write_int96(buf, 0, Int64(0), Int32(2440589))

    var arr = decode_plain_int96_to_int64(Span(buf), 1)
    assert_equal(arr.length, 1)

    comptime NANOS_PER_DAY = 86400000000000
    assert_equal(Int(arr.get(0)), NANOS_PER_DAY)



def test_int96_with_nanos_in_day() raises:
    """INT96 for the epoch plus 0.123456789 seconds.

    Julian day 2440588 = epoch.
    nanos_in_day = 123456789.
    Expected: 123456789 ns.
    """
    var buf = List[UInt8](length=12, fill=0)
    _write_int96(buf, 0, Int64(123456789), Int32(2440588))

    var arr = decode_plain_int96_to_int64(Span(buf), 1)
    assert_equal(arr.length, 1)
    assert_equal(Int(arr.get(0)), 123456789)



def test_int96_before_epoch() raises:
    """INT96 for 23:59:59 UTC on the day before the epoch (one second before epoch).

    Julian day 2440587 = one day before epoch.
    nanos_in_day = (86400 - 1) * 1e9 = 86_399_000_000_000.
    Expected: -1_000_000_000 ns (one second before epoch).
    """
    var buf = List[UInt8](length=12, fill=0)
    # One day before epoch, at 23:59:59.
    comptime NANOS_PER_SECOND = 1000000000
    comptime NANOS_PER_DAY = 86400000000000
    var nanos_in_day = Int64(NANOS_PER_DAY - NANOS_PER_SECOND)
    _write_int96(buf, 0, nanos_in_day, Int32(2440587))

    var arr = decode_plain_int96_to_int64(Span(buf), 1)
    assert_equal(arr.length, 1)

    # Expected: -86400*1e9 + (86400-1)*1e9 = -1e9
    var expected = Int64(-NANOS_PER_SECOND)
    assert_equal(arr.get(0), expected)



def test_int96_known_spark_timestamp() raises:
    """INT96 for a realistic Spark timestamp at 10:30:00 UTC.

    Julian day 2460690.
    nanos_in_day = (10*3600 + 30*60) * 1e9 = 37_800_000_000_000.
    """
    var buf = List[UInt8](length=12, fill=0)
    comptime NANOS_PER_SECOND = 1000000000
    var nanos_in_day = Int64((10 * 3600 + 30 * 60) * NANOS_PER_SECOND)
    _write_int96(buf, 0, nanos_in_day, Int32(2460690))

    var arr = decode_plain_int96_to_int64(Span(buf), 1)
    assert_equal(arr.length, 1)

    # Compute expected manually:
    # unix_day = 2460690 - 2440588 = 20102
    # result = 20102 * 86400 * 1e9 + 37800 * 1e9
    comptime NANOS_PER_DAY = 86400000000000
    var expected = Int64(20102) * Int64(NANOS_PER_DAY) + nanos_in_day
    assert_equal(arr.get(0), expected)



def test_int96_multiple_values() raises:
    """Decode multiple INT96 values at once."""
    var num_values = 3
    var buf = List[UInt8](length=num_values * 12, fill=0)

    # Value 0: Unix epoch
    _write_int96(buf, 0, Int64(0), Int32(2440588))
    # Value 1: One day after epoch
    _write_int96(buf, 12, Int64(0), Int32(2440589))
    # Value 2: Epoch + 1 nanosecond
    _write_int96(buf, 24, Int64(1), Int32(2440588))

    var arr = decode_plain_int96_to_int64(Span(buf), num_values)
    assert_equal(arr.length, 3)

    assert_equal(Int(arr.get(0)), 0)  # epoch
    assert_equal(Int(arr.get(1)), 86400000000000)  # epoch + 1 day
    assert_equal(Int(arr.get(2)), 1)  # epoch + 1 ns



def test_int96_empty() raises:
    """Decode zero INT96 values returns empty array."""
    var buf = List[UInt8](length=1, fill=0)  # dummy, won't be read

    var arr = decode_plain_int96_to_int64(Span(buf)[0:0], 0)
    assert_equal(arr.length, 0)



def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
