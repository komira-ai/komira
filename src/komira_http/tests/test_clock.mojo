# =============================================================================
# src/komira_http/tests/test_clock.mojo — Clock trait + SystemClock + MockClock
# =============================================================================
# 

from std.testing import assert_equal, assert_true

from komira_http.client.clock import MockClock, SystemClock


def test_system_clock_monotonic_two_reads() raises:
    """Two consecutive SystemClock reads are non-decreasing."""
    var c = SystemClock.new()
    var t0 = c.now_us()
    var t1 = c.now_us()
    assert_true(t1 >= t0)


def test_system_clock_nonzero() raises:
    """SystemClock returns a sane positive value (system uptime is
    measured in years on most boxes -> > 1us trivially)."""
    var c = SystemClock.new()
    var t = c.now_us()
    assert_true(t > 0)


def test_system_clock_two_instances_same_timeline() raises:
    """Two SystemClock instances observe the same monotonic timeline
    (the OS-level clock is process-global)."""
    var a = SystemClock.new()
    var b = SystemClock.new()
    var ta = a.now_us()
    var tb = b.now_us()
    # Two reads in rapid succession differ by at most a small number of us.
    var diff = tb - ta
    if diff < 0:
        diff = -diff
    assert_true(diff < 1_000_000)  # within 1 second is plenty of slack


def test_mock_clock_starts_at_zero() raises:
    var c = MockClock.new()
    assert_equal(c.now_us(), 0)


def test_mock_clock_starting_at() raises:
    var c = MockClock.starting_at(1_000_000)
    assert_equal(c.now_us(), 1_000_000)


def test_mock_clock_advance() raises:
    """advance_us moves time forward by exactly the requested delta."""
    var c = MockClock.starting_at(100)
    c.advance_us(50)
    assert_equal(c.now_us(), 150)
    c.advance_us(0)
    assert_equal(c.now_us(), 150)
    c.advance_us(1_000_000)
    assert_equal(c.now_us(), 1_000_150)


def test_mock_clock_two_reads_no_advance_same_value() raises:
    """The invariant: time does NOT advance unless
    advance_us is called. Two consecutive now_us calls return the
    same value.
    """
    var c = MockClock.starting_at(42)
    var a = c.now_us()
    var b = c.now_us()
    assert_equal(a, b)
    assert_equal(a, 42)


def test_mock_clock_idle_eviction_window() raises:
    """The eviction-window arithmetic pattern used by the pool:

      last_used = clock.now_us()      # at checkin
      ... time passes ...
      now = clock.now_us()
      if now - last_used > idle_threshold_us: evict

    Verified at the trait level so pool tests don't need to
    re-derive the protocol.
    """
    var clk = MockClock.starting_at(1_000_000)
    var last_used = clk.now_us()
    # Advance past 60s idle threshold.
    clk.advance_us(61_000_000)
    var now = clk.now_us()
    assert_true(now - last_used > 60_000_000)


def main() raises:
    test_system_clock_monotonic_two_reads()
    test_system_clock_nonzero()
    test_system_clock_two_instances_same_timeline()
    test_mock_clock_starts_at_zero()
    test_mock_clock_starting_at()
    test_mock_clock_advance()
    test_mock_clock_two_reads_no_advance_same_value()
    test_mock_clock_idle_eviction_window()
    print("OK: test_clock")
