# =============================================================================
# test_timer_schedule.mojo
# =============================================================================
# schedule() implementation tests.
#
# schedule(deadline_ns, cb) -> TimerHandle:
#   - O(1): pick level via _level_for_delta, compute slot via
#     _slot_for_deadline, append TimerEntry to that bucket, set
#     _occupied[level] bit, return handle.
#   - Past deadlines (delta <= 0) → level 0 at the current slot.
#   - Handle ids are monotonic from _next_handle_id; never reused.
#
# advance() / cancel() still raise (Commits 4/5).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.timer.timer_wheel import (
    TimerCallback,
    TimerEntry,
    TimerHandle,
    TimerWheel,
)


def _placeholder_cb(arg: UInt64) -> None:
    pass


def test_schedule_level0_basic() raises:
    """Schedule at +5ms: handle._level == 0, _bucket == 5, _id == 1."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(42))
    var h = w.schedule(Int64(5_000_000), cb)
    assert_equal(Int(h._id), 1)
    assert_equal(Int(h._level), 0)
    assert_equal(Int(h._bucket), 5)
    # Bucket 5 of level 0 has 1 entry.
    assert_equal(len(w._level_0[5]), 1)
    var entry = w._level_0[5][0]
    assert_equal(Int(entry._handle_id), 1)
    assert_equal(Int(entry._deadline_ns), 5_000_000)
    assert_false(entry._cancelled)
    assert_equal(Int(entry._cb._arg), 42)
    # Occupied bit 5 of level 0 is set.
    assert_equal(Int(w._occupied[0]), 1 << 5)


def test_schedule_handle_id_monotonic() raises:
    """Each schedule bumps _next_handle_id; ids are unique + monotonic."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var h1 = w.schedule(Int64(1_000_000), cb)
    var h2 = w.schedule(Int64(2_000_000), cb)
    var h3 = w.schedule(Int64(3_000_000), cb)
    assert_equal(Int(h1._id), 1)
    assert_equal(Int(h2._id), 2)
    assert_equal(Int(h3._id), 3)
    assert_equal(Int(w._next_handle_id), 4)


def test_schedule_level1() raises:
    """Schedule at +200ms (> 64ms span) → level 1."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var h = w.schedule(Int64(200_000_000), cb)  # 200ms in ns
    assert_equal(Int(h._level), 1)
    # Slot at level 1: 200ms / 64ms = 3 (floor), so slot 3.
    assert_equal(Int(h._bucket), 3)
    assert_equal(len(w._level_1[3]), 1)
    # Occupied bit 3 of level 1 set.
    assert_equal(Int(w._occupied[1]), 1 << 3)


def test_schedule_level2() raises:
    """Schedule at +5s → level 2 (slot range 4.096s)."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var h = w.schedule(Int64(5_000_000_000), cb)  # 5s in ns
    assert_equal(Int(h._level), 2)
    # Slot: 5s / 4.096s = 1 (floor).
    assert_equal(Int(h._bucket), 1)
    assert_equal(len(w._level_2[1]), 1)


def test_schedule_past_deadline_goes_level0() raises:
    """Past deadline (negative delta from epoch) → level 0."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    # Schedule with deadline=0 from epoch=0 → delta=0 → level 0 slot 0.
    var h = w.schedule(Int64(0), cb)
    assert_equal(Int(h._level), 0)
    assert_equal(Int(h._bucket), 0)
    assert_equal(len(w._level_0[0]), 1)


def test_schedule_multiple_same_bucket() raises:
    """Multiple timers at the same deadline → same bucket; FIFO append."""
    var w = TimerWheel()
    var cb_a = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(100))
    var cb_b = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(200))
    var cb_c = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(300))
    var ha = w.schedule(Int64(5_000_000), cb_a)
    var hb = w.schedule(Int64(5_000_000), cb_b)
    var hc = w.schedule(Int64(5_000_000), cb_c)
    # All three in level 0 bucket 5.
    assert_equal(Int(ha._level), 0); assert_equal(Int(ha._bucket), 5)
    assert_equal(Int(hb._level), 0); assert_equal(Int(hb._bucket), 5)
    assert_equal(Int(hc._level), 0); assert_equal(Int(hc._bucket), 5)
    assert_equal(len(w._level_0[5]), 3)
    # Insertion order preserved.
    assert_equal(Int(w._level_0[5][0]._cb._arg), 100)
    assert_equal(Int(w._level_0[5][1]._cb._arg), 200)
    assert_equal(Int(w._level_0[5][2]._cb._arg), 300)
    # Occupied bit set once (the bit is "any entry"; not a count).
    assert_equal(Int(w._occupied[0]), 1 << 5)


def test_schedule_far_future_clamps_level5() raises:
    """100 days out → level 5."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var hundred_days_ns = Int64(100) * Int64(86_400) * Int64(1_000_000_000)
    var h = w.schedule(hundred_days_ns, cb)
    assert_equal(Int(h._level), 5)
    # Bucket: hundred_days_ns / level5_slot_range = 100*86400e9 / (64^5 * 1e6) = 100*86400e9 / 1.073e15 ≈ 8.04 → slot 8.
    # We don't pin the exact slot because slot math depends on epoch=0.
    # Just assert level 5 has SOME entry.
    var any_set = False
    for i in range(64):
        if len(w._level_5[i]) > 0:
            any_set = True
            assert_equal(Int(h._bucket), i)
    assert_true(any_set)


def test_schedule_with_explicit_epoch() raises:
    """When _epoch_ns != 0, slot math is relative to epoch, not absolute time."""
    var w = TimerWheel(_epoch_ns=Int64(1_000_000_000))  # epoch at 1s
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    # Deadline = 1.005s = epoch + 5ms → level 0 slot 5.
    var h = w.schedule(Int64(1_005_000_000), cb)
    assert_equal(Int(h._level), 0)
    assert_equal(Int(h._bucket), 5)


def main() raises:
    test_schedule_level0_basic()
    test_schedule_handle_id_monotonic()
    test_schedule_level1()
    test_schedule_level2()
    test_schedule_past_deadline_goes_level0()
    test_schedule_multiple_same_bucket()
    test_schedule_far_future_clamps_level5()
    test_schedule_with_explicit_epoch()
    print("PASS komira_async.timer schedule")
