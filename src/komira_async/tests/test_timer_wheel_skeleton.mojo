# =============================================================================
# test_timer_wheel_skeleton.mojo
# =============================================================================
# TimerWheel struct full field set.
#
# Validates that the wheel constructs with all 6 levels × 64 buckets present,
# all empty, _occupied bitmask cleared, _now_ns/_epoch_ns/_next_handle_id at
# expected starting values. schedule/cancel/advance still raise (Commits 3-5).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.timer.timer_wheel import (
    TimerCallback,
    TimerHandle,
    TimerWheel,
    NUM_LEVELS,
    LEVEL_MULT,
)


def _placeholder_cb(arg: UInt64) -> None:
    pass


def test_wheel_construct_default() raises:
    """Empty wheel: _now_ns=0, _epoch_ns=0, _next_handle_id=1 (id 0 reserved)."""
    var w = TimerWheel()
    assert_equal(Int(w._now_ns), 0)
    assert_equal(Int(w._epoch_ns), 0)
    assert_equal(Int(w._next_handle_id), 1)


def test_wheel_buckets_all_empty() raises:
    """All 6 levels × 64 buckets empty on construct."""
    var w = TimerWheel()
    for slot in range(64):
        assert_equal(len(w._level_0[slot]), 0)
        assert_equal(len(w._level_1[slot]), 0)
        assert_equal(len(w._level_2[slot]), 0)
        assert_equal(len(w._level_3[slot]), 0)
        assert_equal(len(w._level_4[slot]), 0)
        assert_equal(len(w._level_5[slot]), 0)


def test_wheel_occupied_bitmask_cleared() raises:
    """_occupied[level] == 0 on construct (no bucket has any entry)."""
    var w = TimerWheel()
    for level in range(6):
        assert_equal(Int(w._occupied[level]), 0)


def test_wheel_with_epoch() raises:
    """Construct with explicit epoch: useful for tests + integration. The
    epoch is the wheel's anchor for absolute → slot conversion."""
    var w = TimerWheel(_epoch_ns=Int64(1_000_000_000))  # 1s anchor
    assert_equal(Int(w._epoch_ns), 1_000_000_000)
    # _now_ns starts at epoch (a fresh wheel has nothing to fire yet).
    assert_equal(Int(w._now_ns), 1_000_000_000)


def test_wheel_all_methods_work() raises:
    """schedule/cancel/advance all functional. Verify no
    raises under simple usage; full behavior tested in dedicated test
    files."""
    var w = TimerWheel()

    # cancel() silently no-ops on stale ids.
    w.cancel(TimerHandle(_id=UInt64(1), _level=UInt8(0), _bucket=UInt8(0)))

    # advance() on empty wheel returns empty list.
    var fired = w.advance(Int64(1_000_000))
    assert_equal(len(fired), 0)
    assert_equal(Int(w._now_ns), 1_000_000)


def test_wheel_constants_visible() raises:
    """NUM_LEVELS=6 and LEVEL_MULT=64 are accessible from the module."""
    assert_equal(Int(NUM_LEVELS), 6)
    assert_equal(Int(LEVEL_MULT), 64)


def main() raises:
    test_wheel_construct_default()
    test_wheel_buckets_all_empty()
    test_wheel_occupied_bitmask_cleared()
    test_wheel_with_epoch()
    test_wheel_all_methods_work()
    test_wheel_constants_visible()
    print("PASS komira_async.timer wheel skeleton")
