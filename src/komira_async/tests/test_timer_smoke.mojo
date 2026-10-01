# =============================================================================
# test_timer_smoke.mojo
# =============================================================================
# smoke test for komira_async.timer.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.timer.timer_wheel import (
    TimerCallback,
    TimerHandle,
    TimerWheel,
)


def _placeholder_cb(arg: UInt64) -> None:
    pass


def test_timer_handle_construct() raises:
    """TimerHandle is a POD opaque handle."""
    var h = TimerHandle(_id=UInt64(0), _level=UInt8(0), _bucket=UInt8(0))
    assert_equal(Int(h._id), 0)


def test_timer_callback_construct() raises:
    """TimerCallback."""
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    assert_equal(Int(cb._arg), 0)


def test_timer_wheel_construct() raises:
    """TimerWheel constructs with _now_ns = 0; schedule() works."""
    var w = TimerWheel()
    assert_equal(Int(w._now_ns), 0)
    # schedule() now WORKS. Verify it returns a non-null
    # handle and the wheel state advances.
    var h = w.schedule(
        Int64(1_000_000),
        TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0)),
    )
    assert_true(h._id > UInt64(0))
    assert_equal(Int(w._next_handle_id), 2)


def main() raises:
    test_timer_handle_construct()
    test_timer_callback_construct()
    test_timer_wheel_construct()
    print("PASS komira_async.timer smoke")
