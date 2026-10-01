# =============================================================================
# test_timer_advance.mojo
# =============================================================================
# advance() implementation tests.
#
# advance(now_ns) -> List[TimerCallback]:
#   - Advance _now_ns to max(now_ns, _now_ns) — never go backwards.
#   - Process every level whose buckets are due (their deadline <= now_ns).
#   - Level 0 due slots: fire entries (return their callbacks).
#   - Level >= 1 due slots: cascade — re-schedule each entry to its
#     correct lower level given the new "now". (entries' _deadline_ns
#     is still in the future since their level slot hadn't expired yet;
#     re-scheduling just moves them to a finer-resolution level.)
#   - Cancelled entries are silently dropped (not in result; not
#     re-scheduled).
#   - Result list is in firing order (FIFO within a slot, slot order
#     ascending).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.timer.timer_wheel import (
    TimerCallback,
    TimerHandle,
    TimerWheel,
)


def _placeholder_cb(arg: UInt64) -> None:
    pass


def test_advance_empty_wheel() raises:
    """advance() on empty wheel returns empty list; _now_ns advances."""
    var w = TimerWheel()
    var fired = w.advance(Int64(10_000_000))  # advance to 10ms
    assert_equal(len(fired), 0)
    assert_equal(Int(w._now_ns), 10_000_000)


def test_advance_no_backwards() raises:
    """advance() never moves _now_ns backwards."""
    var w = TimerWheel()
    var _f1 = w.advance(Int64(10_000_000))
    var _f2 = w.advance(Int64(5_000_000))  # try to go backwards
    assert_equal(Int(w._now_ns), 10_000_000)


def test_advance_fires_due_level0_entry() raises:
    """Schedule at +5ms, advance to +5ms, callback fires."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(42))
    var _h = w.schedule(Int64(5_000_000), cb)
    var fired = w.advance(Int64(5_000_000))
    assert_equal(len(fired), 1)
    assert_equal(Int(fired[0]._arg), 42)
    # Bucket emptied + _occupied bit cleared.
    assert_equal(len(w._level_0[5]), 0)
    assert_equal(Int(w._occupied[0]) & (1 << 5), 0)


def test_advance_does_not_fire_future_entry() raises:
    """Schedule at +10ms, advance to +5ms, callback does NOT fire."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(42))
    var _h = w.schedule(Int64(10_000_000), cb)
    var fired = w.advance(Int64(5_000_000))
    assert_equal(len(fired), 0)
    assert_equal(len(w._level_0[10]), 1)


def test_advance_fires_then_skips() raises:
    """Schedule two entries at +5ms and +10ms; advance to +5ms fires
    only the +5ms; advance to +10ms fires the +10ms."""
    var w = TimerWheel()
    var cb_a = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(100))
    var cb_b = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(200))
    var _ha = w.schedule(Int64(5_000_000), cb_a)
    var _hb = w.schedule(Int64(10_000_000), cb_b)
    var fired1 = w.advance(Int64(5_000_000))
    assert_equal(len(fired1), 1)
    assert_equal(Int(fired1[0]._arg), 100)
    var fired2 = w.advance(Int64(10_000_000))
    assert_equal(len(fired2), 1)
    assert_equal(Int(fired2[0]._arg), 200)


def test_advance_fires_multiple_in_same_bucket_fifo() raises:
    """3 entries at the same +5ms deadline → all 3 fire in insertion order."""
    var w = TimerWheel()
    var cb_a = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(100))
    var cb_b = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(200))
    var cb_c = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(300))
    var _ha = w.schedule(Int64(5_000_000), cb_a)
    var _hb = w.schedule(Int64(5_000_000), cb_b)
    var _hc = w.schedule(Int64(5_000_000), cb_c)
    var fired = w.advance(Int64(5_000_000))
    assert_equal(len(fired), 3)
    assert_equal(Int(fired[0]._arg), 100)
    assert_equal(Int(fired[1]._arg), 200)
    assert_equal(Int(fired[2]._arg), 300)


def test_advance_skips_cancelled_entries() raises:
    """Cancelled entries do not appear in fired list."""
    var w = TimerWheel()
    var cb_a = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(100))
    var cb_b = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(200))
    var _ha = w.schedule(Int64(5_000_000), cb_a)
    var hb = w.schedule(Int64(5_000_000), cb_b)
    w.cancel(hb)
    var fired = w.advance(Int64(5_000_000))
    # Only cb_a fires; cb_b was tombstoned.
    assert_equal(len(fired), 1)
    assert_equal(Int(fired[0]._arg), 100)


def test_advance_cascades_level1_to_level0() raises:
    """Schedule at +200ms → level 1 slot 3. Advance to +200ms; entry
    cascades through levels and ultimately fires."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(99))
    var h = w.schedule(Int64(200_000_000), cb)  # 200ms
    assert_equal(Int(h._level), 1)
    # Advance to exactly the deadline.
    var fired = w.advance(Int64(200_000_000))
    # Entry should have cascaded through level 0 and fired.
    assert_equal(len(fired), 1)
    assert_equal(Int(fired[0]._arg), 99)
    assert_equal(Int(w._now_ns), 200_000_000)


def test_advance_cascades_level2() raises:
    """Schedule at +5s → level 2 slot 1. Advance to +5s. Entry cascades
    through level 2 → 1 → 0 and fires."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(7))
    var _h = w.schedule(Int64(5_000_000_000), cb)  # 5s
    var fired = w.advance(Int64(5_000_000_000))
    assert_equal(len(fired), 1)
    assert_equal(Int(fired[0]._arg), 7)


def test_advance_partial_cascade() raises:
    """Schedule at +200ms, advance only to +100ms. Entry should NOT fire.
    Whether it cascaded is internal — but it must not be in result."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(99))
    var _h = w.schedule(Int64(200_000_000), cb)
    var fired = w.advance(Int64(100_000_000))
    assert_equal(len(fired), 0)
    # Now advance the rest of the way; should fire.
    var fired2 = w.advance(Int64(200_000_000))
    assert_equal(len(fired2), 1)
    assert_equal(Int(fired2[0]._arg), 99)


def test_advance_idle_advance_no_fires() raises:
    """advance() with no scheduled entries on a non-empty wheel that has
    only future-dated entries: no fires."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var _h = w.schedule(Int64(1_000_000_000), cb)  # 1s — level 1
    var fired = w.advance(Int64(10_000_000))      # advance only 10ms
    assert_equal(len(fired), 0)


def main() raises:
    test_advance_empty_wheel()
    test_advance_no_backwards()
    test_advance_fires_due_level0_entry()
    test_advance_does_not_fire_future_entry()
    test_advance_fires_then_skips()
    test_advance_fires_multiple_in_same_bucket_fifo()
    test_advance_skips_cancelled_entries()
    test_advance_cascades_level1_to_level0()
    test_advance_cascades_level2()
    test_advance_partial_cascade()
    test_advance_idle_advance_no_fires()
    print("PASS komira_async.timer advance")
