# =============================================================================
# tests/test_group_clock.mojo
#   The clocks a GroupCoordinator reads and waits on.
#
#   ManualGroupClock moves only through set, advance and sleep_ms; its sleep_ms
#   moves the reading by the requested wait, so a coordinator polling for a
#   deadline reaches it. A wait of zero or less moves nothing. SystemGroupClock
#   reads the Unix wall clock in milliseconds (the test checks the epoch scale,
#   not an interval) and a wait of zero returns at once.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_kafka_broker.group_clock import (
    GroupClock,
    ManualGroupClock,
    SystemGroupClock,
)


def _read_twice[C: GroupClock](mut c: C) -> Int64:
    var first = c.now_ms()
    var second = c.now_ms()
    return second - first


def test_manual_clock_starts_where_told_and_holds_still() raises:
    var c = ManualGroupClock(Int64(42))
    assert_equal(c.now_ms(), Int64(42))
    assert_equal(_read_twice(c), Int64(0))
    var d = ManualGroupClock()
    assert_equal(d.now_ms(), Int64(0))


def test_manual_clock_set_and_advance() raises:
    var c = ManualGroupClock(Int64(10))
    c.advance(Int64(5))
    assert_equal(c.now_ms(), Int64(15))
    c.set(Int64(1000))
    assert_equal(c.now_ms(), Int64(1000))
    c.advance(Int64(-1))
    assert_equal(c.now_ms(), Int64(999))


def test_manual_clock_sleep_moves_the_reading_and_counts() raises:
    var c = ManualGroupClock(Int64(100))
    c.sleep_ms(Int64(20))
    c.sleep_ms(Int64(30))
    assert_equal(c.now_ms(), Int64(150))
    assert_equal(c.sleep_calls, 2)
    assert_equal(c.slept_ms, Int64(50))


def test_manual_clock_sleep_of_nothing_moves_nothing() raises:
    var c = ManualGroupClock(Int64(100))
    c.sleep_ms(Int64(0))
    c.sleep_ms(Int64(-5))
    assert_equal(c.now_ms(), Int64(100))
    assert_equal(c.slept_ms, Int64(0))
    assert_equal(c.sleep_calls, 2)


def test_system_clock_reads_unix_epoch_milliseconds() raises:
    var c = SystemGroupClock()
    # 2023-11-14 in epoch milliseconds: any real wall clock is past it, and a
    # clock in seconds or microseconds is not in this range.
    var now = c.now_ms()
    assert_true(now > Int64(1_700_000_000_000))
    assert_true(now < Int64(100_000_000_000_000))
    c.sleep_ms(Int64(0))
    c.sleep_ms(Int64(-1))


def main() raises:
    test_manual_clock_starts_where_told_and_holds_still()
    test_manual_clock_set_and_advance()
    test_manual_clock_sleep_moves_the_reading_and_counts()
    test_manual_clock_sleep_of_nothing_moves_nothing()
    test_system_clock_reads_unix_epoch_milliseconds()
    print("test_group_clock: ALL PASS")
