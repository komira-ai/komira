# =============================================================================
# test_timer_entry_and_math.mojo
# =============================================================================
# TimerEntry POD struct + private level/slot math
# helpers. Validates the foundational arithmetic layer used by schedule()
# and advance(). NO public API yet (TimerWheel.schedule still raises in
# this commit).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.timer.timer_wheel import (
    TimerCallback,
    TimerEntry,
    _level_for_delta,
    _slot_for_deadline,
    _slot_range_ns,
    BASE_RESOLUTION_MS,
    NUM_LEVELS,
    LEVEL_MULT,
)


def _placeholder_cb(arg: UInt64) -> None:
    pass


def test_constants() raises:
    """The wheel is parameterized by Tokio's NUM_LEVELS=6, LEVEL_MULT=64,
    BASE_RESOLUTION_MS=1."""
    assert_equal(Int(BASE_RESOLUTION_MS), 1)
    assert_equal(Int(NUM_LEVELS), 6)
    assert_equal(Int(LEVEL_MULT), 64)


def test_timer_entry_construct() raises:
    """TimerEntry is a POD bag: handle_id + deadline + cancelled flag + cb.
    All fields Copyable, struct itself Copyable+Movable+Deinitable."""
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(42))
    var e = TimerEntry(
        _handle_id=UInt64(7),
        _deadline_ns=Int64(5_000_000),  # 5ms in ns
        _cancelled=False,
        _cb=cb,
    )
    assert_equal(Int(e._handle_id), 7)
    assert_equal(Int(e._deadline_ns), 5_000_000)
    assert_false(e._cancelled)
    assert_equal(Int(e._cb._arg), 42)


def test_slot_range_ns() raises:
    """Level N's slot range = (LEVEL_MULT^N) * BASE_RESOLUTION_MS in ms,
    converted to ns. Validates the shift-multiply math used in schedule()
    and advance()."""
    # Level 0: 1ms = 1_000_000 ns per slot.
    assert_equal(Int(_slot_range_ns(UInt8(0))), 1_000_000)
    # Level 1: 64ms = 64_000_000 ns per slot.
    assert_equal(Int(_slot_range_ns(UInt8(1))), 64_000_000)
    # Level 2: 64*64 = 4096ms ≈ 4_096_000_000 ns per slot.
    assert_equal(Int(_slot_range_ns(UInt8(2))), 4_096_000_000)
    # Level 5: 64^5 ms ≈ 1.07e9 ms ≈ 1.07e18 ns per slot.
    var l5 = _slot_range_ns(UInt8(5))
    # 64^5 = 1073741824
    assert_equal(Int(l5), 1_073_741_824 * 1_000_000)


def test_level_for_delta_zero() raises:
    """Past or now deadlines (delta <= 0) → level 0 (fire next tick)."""
    assert_equal(Int(_level_for_delta(Int64(0))), 0)
    assert_equal(Int(_level_for_delta(Int64(-100))), 0)


def test_level_for_delta_level0() raises:
    """delta in [0, 64ms) → level 0."""
    assert_equal(Int(_level_for_delta(Int64(1_000_000))), 0)        # 1ms
    assert_equal(Int(_level_for_delta(Int64(50_000_000))), 0)       # 50ms
    assert_equal(Int(_level_for_delta(Int64(63_999_999))), 0)       # just under 64ms


def test_level_for_delta_level1() raises:
    """delta in [64ms, 64^2 ms) → level 1."""
    assert_equal(Int(_level_for_delta(Int64(64_000_000))), 1)       # exactly 64ms
    assert_equal(Int(_level_for_delta(Int64(100_000_000))), 1)      # 100ms
    assert_equal(Int(_level_for_delta(Int64(4_095_999_999))), 1)    # just under 4096ms


def test_level_for_delta_level2() raises:
    """delta in [4.096s, 64^3 ms = ~262s) → level 2."""
    assert_equal(Int(_level_for_delta(Int64(4_096_000_000))), 2)
    assert_equal(Int(_level_for_delta(Int64(100_000_000_000))), 2)  # 100s


def test_level_for_delta_level3_and_4() raises:
    """delta in level 3 and level 4 ranges."""
    # Level 3: ~4.66hr = 16_777_216_000_000 ns max.
    # 30 minutes = 30*60*1e9 = 1.8e12 ns → level 3 (since 1.8e12 < 16.7e12).
    var thirty_min = Int64(30) * Int64(60) * Int64(1_000_000_000)
    assert_equal(Int(_level_for_delta(thirty_min)), 3)
    # Level 4: ~12 days max. 1 day = 86_400_000_000_000 ns < 1.07e15 ns → level 4.
    var one_day = Int64(86_400_000) * Int64(1_000_000)
    assert_equal(Int(_level_for_delta(one_day)), 4)


def test_level_for_delta_clamps_to_top() raises:
    """delta beyond level 4's max range falls into level 5 (~2 years total span).

    Level 4 span = ~12.4 days = 1_073_741_824_000_000 ns.
    Anything > level 4 span and beyond → level 5.
    """
    # 100 days = 100 * 86_400 * 1e9 = 8.64e15 ns, > level 4 span (1.07e15) → level 5.
    var hundred_days = Int64(100) * Int64(86_400) * Int64(1_000_000_000)
    assert_equal(Int(_level_for_delta(hundred_days)), 5)
    # Even huger values still clamp to level 5 (Tokio's "top level acts as
    # pseudo-ring buffer" rule).
    # 10 years ≈ 3650 days × 86400s/day × 1e9 ns/s.
    var ten_years = Int64(3650) * Int64(86_400) * Int64(1_000_000_000)
    assert_equal(Int(_level_for_delta(ten_years)), 5)


def test_slot_for_deadline_level0() raises:
    """Level 0 slot = (deadline_ns / 1_000_000) % 64. epoch=0 baseline."""
    # 5ms deadline at epoch 0 → slot 5.
    assert_equal(Int(_slot_for_deadline(Int64(5_000_000), UInt8(0), Int64(0))), 5)
    # 63ms deadline → slot 63.
    assert_equal(Int(_slot_for_deadline(Int64(63_000_000), UInt8(0), Int64(0))), 63)
    # 64ms wraps to slot 0 (first slot of next rotation).
    assert_equal(Int(_slot_for_deadline(Int64(64_000_000), UInt8(0), Int64(0))), 0)


def test_slot_for_deadline_level1() raises:
    """Level 1 slot = (deadline_ns / 64_000_000) % 64. epoch=0."""
    # 64ms = level 1 slot 1. (64ms/64ms = 1.)
    assert_equal(Int(_slot_for_deadline(Int64(64_000_000), UInt8(1), Int64(0))), 1)
    # 200ms = level 1 slot 3 (200/64 = 3.125 → floor 3).
    assert_equal(Int(_slot_for_deadline(Int64(200_000_000), UInt8(1), Int64(0))), 3)


def test_slot_for_deadline_with_epoch() raises:
    """Non-zero epoch: slot computed relative to epoch."""
    var epoch = Int64(1_000_000_000)  # epoch at 1s.
    # Deadline at 1.005s → 5ms past epoch → level 0 slot 5.
    assert_equal(
        Int(_slot_for_deadline(Int64(1_005_000_000), UInt8(0), epoch)), 5,
    )


def main() raises:
    test_constants()
    test_timer_entry_construct()
    test_slot_range_ns()
    test_level_for_delta_zero()
    test_level_for_delta_level0()
    test_level_for_delta_level1()
    test_level_for_delta_level2()
    test_level_for_delta_level3_and_4()
    test_level_for_delta_clamps_to_top()
    test_slot_for_deadline_level0()
    test_slot_for_deadline_level1()
    test_slot_for_deadline_with_epoch()
    print("PASS komira_async.timer entry + math")
