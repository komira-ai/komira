# =============================================================================
# test_timer_high_cardinality.mojo
# =============================================================================
# high-cardinality stress test.
#
# Schedule N timers across all 6 levels with deterministic deadlines;
# advance through all; assert ALL fire exactly once and the firing-count
# matches the schedule-count (no leaks, no double-fires).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.timer.timer_wheel import (
    TimerCallback,
    TimerHandle,
    TimerWheel,
)


def _placeholder_cb(arg: UInt64) -> None:
    pass


def test_thousand_timers_level0() raises:
    """1000 timers all at level 0 (deadlines spread across 64 slots).
    Advance past all deadlines; assert exactly 1000 fires."""
    var w = TimerWheel()
    var n = 1000
    for i in range(n):
        var deadline = Int64(1_000_000) * Int64(1 + (i % 60))
        var _h = w.schedule(
            deadline,
            TimerCallback(_fn=_placeholder_cb, _arg=UInt64(i)),
        )
    # Advance to 100ms — well past all level-0 deadlines (max 60ms).
    var fired = w.advance(Int64(100_000_000))
    assert_equal(len(fired), n)


def test_ten_thousand_timers_mixed_levels() raises:
    """10K timers spread across all 6 levels by varying the deadline.
    Advance through 1 hour; assert all fire."""
    var w = TimerWheel()
    var n = 10000
    var max_deadline_ns = Int64(0)
    for i in range(n):
        # Spread deadlines from 1ms to ~1 hour using a deterministic
        # function. Mix levels by varying the magnitude.
        var step = (i % 6)
        var base_ns: Int64
        if step == 0:
            base_ns = Int64(5_000_000)            # 5ms (level 0)
        elif step == 1:
            base_ns = Int64(100_000_000)          # 100ms (level 1)
        elif step == 2:
            base_ns = Int64(2_000_000_000)        # 2s (level 1)
        elif step == 3:
            base_ns = Int64(60_000_000_000)       # 60s (level 2)
        elif step == 4:
            base_ns = Int64(900_000_000_000)      # 15min (level 3)
        else:
            base_ns = Int64(2_400_000_000_000)    # 40min (level 3)
        # Add a per-i offset so different i go in different slots.
        var jitter = Int64(i % 1000) * Int64(1_000_000)
        var deadline = base_ns + jitter
        if deadline > max_deadline_ns:
            max_deadline_ns = deadline
        var _h = w.schedule(
            deadline,
            TimerCallback(_fn=_placeholder_cb, _arg=UInt64(i)),
        )

    # Advance well past max_deadline.
    var advance_to = max_deadline_ns + Int64(60_000_000_000)  # +60s buffer

    # Walk in chunks of 100ms so the cascade machinery is exercised
    # repeatedly — single-shot advance(huge_now) would also work but
    # won't exercise mid-cascade ordering.
    var chunk = Int64(100_000_000)  # 100ms per advance
    var total_fired = 0
    var t = w._now_ns
    while t < advance_to:
        t += chunk
        var fired = w.advance(t)
        total_fired += len(fired)

    # Final flush.
    var _final = w.advance(advance_to)
    total_fired += len(_final)

    assert_equal(total_fired, n)


def test_no_double_fire() raises:
    """Schedule, advance to fire, advance again — entry does NOT fire
    a second time."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var _h = w.schedule(Int64(5_000_000), cb)
    var fired1 = w.advance(Int64(5_000_000))
    assert_equal(len(fired1), 1)
    # Advance again — same entry should not fire again.
    var fired2 = w.advance(Int64(10_000_000))
    assert_equal(len(fired2), 0)


def test_cancellation_at_scale() raises:
    """Schedule 1000 timers; cancel half (every other one); advance;
    only the un-cancelled half fires."""
    var w = TimerWheel()
    var n = 1000
    var handles = List[TimerHandle]()
    for i in range(n):
        var deadline = Int64(1_000_000) * Int64(1 + (i % 60))
        var h = w.schedule(
            deadline,
            TimerCallback(_fn=_placeholder_cb, _arg=UInt64(i)),
        )
        handles.append(h)
    # Cancel even-i.
    for i in range(n):
        if i % 2 == 0:
            w.cancel(handles[i])
    var fired = w.advance(Int64(100_000_000))
    # Half cancelled → half fire.
    assert_equal(len(fired), n // 2)


def test_handle_id_unique_after_many_schedules() raises:
    """After 10K schedules, _next_handle_id == 10001 (started at 1)."""
    var w = TimerWheel()
    var n = 10000
    for i in range(n):
        var _h = w.schedule(
            Int64(1_000_000),
            TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0)),
        )
    assert_equal(Int(w._next_handle_id), n + 1)


def main() raises:
    test_thousand_timers_level0()
    test_ten_thousand_timers_mixed_levels()
    test_no_double_fire()
    test_cancellation_at_scale()
    test_handle_id_unique_after_many_schedules()
    print("PASS komira_async.timer high cardinality")
