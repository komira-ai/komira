# =============================================================================
# test_ring_buffer.mojo — SpanRingBuffer SPSC correctness
# =============================================================================
#
# Verifies:
#   1. Construct + push + pop round-trips a SpanRecord.
#   2. Capacity is rounded up to next power of two.
#   3. is_empty() initial state.
#   4. try_pop on an empty ring returns None.
#   5. DROP policy increments overflow_dropped on a full ring.
#   6. approximate_size() reflects pending records.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_obs.ring_buffer import (
    SpanRingBuffer,
    DEFAULT_RING_CAPACITY,
    OVERFLOW_BLOCK,
    OVERFLOW_DROP,
)
from komira_obs.span_record import SpanRecord


def test_construct() raises:
    """Construct + initial state."""
    var ring = SpanRingBuffer(64, OVERFLOW_BLOCK)
    assert_equal(ring.capacity(), Int(64), "capacity rounded to 64")
    assert_true(ring.is_empty(), "ring is empty initially")
    print("  test_construct PASS")


def test_capacity_rounds_up_pow2() raises:
    """Capacity is rounded UP to the next power of two."""
    var ring = SpanRingBuffer(50, OVERFLOW_BLOCK)
    assert_equal(ring.capacity(), Int(64), "50 → 64")
    print("  test_capacity_rounds_up_pow2 PASS")


def test_pop_empty_returns_none() raises:
    """try_pop on a fresh ring returns None."""
    var ring = SpanRingBuffer(16, OVERFLOW_BLOCK)
    var maybe = ring.try_pop()
    assert_false(Bool(maybe), "empty pop returns None")
    print("  test_pop_empty_returns_none PASS")


def test_push_pop_round_trip() raises:
    """Single push → pop returns the same record."""
    var ring = SpanRingBuffer(16, OVERFLOW_BLOCK)
    var rec = SpanRecord()
    rec.span_id = UInt64(42)
    rec.start_ns = UInt64(1000)
    rec.worker_id = UInt32(2)
    var ok = ring.try_push(rec)
    assert_true(ok, "push succeeds")
    assert_equal(ring.approximate_size(), Int64(1), "size = 1 after push")
    var maybe = ring.try_pop()
    assert_true(Bool(maybe), "pop succeeds")
    ref got = maybe.value()
    assert_equal(got.span_id, UInt64(42), "span_id round-trip")
    assert_equal(got.start_ns, UInt64(1000), "start_ns round-trip")
    assert_equal(got.worker_id, UInt32(2), "worker_id round-trip")
    assert_true(ring.is_empty(), "ring empty after pop")
    print("  test_push_pop_round_trip PASS")


def test_fifo_order() raises:
    """Multiple records pop in push order."""
    var ring = SpanRingBuffer(16, OVERFLOW_BLOCK)
    for i in range(8):
        var r = SpanRecord()
        r.span_id = UInt64(i)
        var _ok = ring.try_push(r)
    for i in range(8):
        var maybe = ring.try_pop()
        assert_true(Bool(maybe), "pop succeeds at iter " + String(i))
        assert_equal(maybe.value().span_id, UInt64(i),
                     "FIFO order at iter " + String(i))
    print("  test_fifo_order PASS")


def test_drop_policy_on_full() raises:
    """DROP policy increments overflow_dropped when ring is full."""
    var ring = SpanRingBuffer(8, OVERFLOW_DROP)
    # Fill to capacity (8).
    for i in range(8):
        var r = SpanRecord()
        r.span_id = UInt64(i)
        var _ok = ring.try_push(r)
    # Overflow attempt:
    var rec = SpanRecord()
    var ok = ring.try_push(rec)
    assert_false(ok, "push fails at overflow")
    assert_equal(ring.overflow_dropped_count(), Int64(1),
                 "drop counter = 1")
    print("  test_drop_policy_on_full PASS")


def main() raises:
    print("test_ring_buffer")
    print("================")
    test_construct()
    test_capacity_rounds_up_pow2()
    test_pop_empty_returns_none()
    test_push_pop_round_trip()
    test_fifo_order()
    test_drop_policy_on_full()
    print()
    print("ALL TESTS PASS")
