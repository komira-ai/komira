# =============================================================================
# test_ring_lazy_slots.mojo — the LAZY-SLOTS guard for the two per-worker SPSC
# ring families that `EngineContext` construction allocates.
# =============================================================================
#
# WHAT THIS PINS. `EngineContext.__init__` builds one `SpanPacketRingBuffer`
# per worker pthread (obs tracer) and N+1 `LogRecordRing`s (log engine), all
# unconditionally, and both families are documented as carrying ZERO traffic
# unless explicitly enabled. Eagerly `create_prefilled`-ing each ring's full
# backing store at construction would make a many-worker context zero-fill and
# first-touch tens of MiB of slots that never receive a packet, paying
# milliseconds of startup and thousands of first-touch faults.
#
# The backing store is deferred to the first `try_push`. `_capacity` remains
# the LOGICAL capacity from construction, so every index/mask/backpressure
# computation is byte-identical; only the allocation moves.
#
# FALSIFICATION. `test_*_slots_are_lazy` asserts `slots_allocated() == False`
# on a freshly constructed ring. A constructor that ran `create_prefilled(cap)`
# would make `slots_allocated()` True at that point and the assert FAIL —
# re-introducing the eager `create_prefilled` in either constructor turns its
# test RED.
#
# The remaining tests pin that laziness did not change ring BEHAVIOUR: capacity
# reporting, empty-pop, round-trip, wrap-around past the capacity boundary, and
# DROP-policy overflow accounting all hold with the deferred store.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_obs.ring_buffer import OVERFLOW_BLOCK, OVERFLOW_DROP
from komira_obs.packet_ring import SpanPacketRingBuffer
from komira_obs.span_packet import SpanPacket

from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.log_event_record import LogEventRecord


# -----------------------------------------------------------------------------
# The falsifiers: no backing store until the first push.
# -----------------------------------------------------------------------------
def test_span_packet_ring_slots_are_lazy() raises:
    """FAILS IF the ctor calls `create_prefilled(cap)`, so a
    fresh ring already had its 64 slots and `slots_allocated()` was True."""
    var ring = SpanPacketRingBuffer(64, OVERFLOW_BLOCK)
    assert_equal(ring.capacity(), Int(64), "logical capacity is live at ctor")
    assert_false(
        ring.slots_allocated(), "fresh span ring must NOT own a backing store"
    )

    # First push materializes it.
    assert_true(ring.try_push(SpanPacket()), "first push succeeds")
    assert_true(
        ring.slots_allocated(), "first push materializes the backing store"
    )
    print("  test_span_packet_ring_slots_are_lazy PASS")


def test_log_record_ring_slots_are_lazy() raises:
    """FAILS IF the ctor calls `create_prefilled(cap)`, so a
    fresh ring already had its 64 slots and `slots_allocated()` was True."""
    var ring = LogRecordRing(64, OVERFLOW_BLOCK)
    assert_equal(ring.capacity(), Int(64), "logical capacity is live at ctor")
    assert_false(
        ring.slots_allocated(), "fresh log ring must NOT own a backing store"
    )

    assert_true(ring.try_push(LogEventRecord()), "first push succeeds")
    assert_true(
        ring.slots_allocated(), "first push materializes the backing store"
    )
    print("  test_log_record_ring_slots_are_lazy PASS")


# -----------------------------------------------------------------------------
# Behaviour is unchanged by the deferral.
# -----------------------------------------------------------------------------
def test_span_ring_pop_empty_before_any_push() raises:
    """A never-pushed ring has no backing store; popping it must still be a
    clean empty, not a dereference of the absent store."""
    var ring = SpanPacketRingBuffer(16, OVERFLOW_BLOCK)
    assert_false(ring.slots_allocated(), "no store yet")
    assert_true(ring.is_empty(), "fresh ring is empty")
    var maybe = ring.try_pop()
    assert_false(Bool(maybe), "empty pop returns None")
    assert_false(ring.slots_allocated(), "an empty pop allocates nothing")
    print("  test_span_ring_pop_empty_before_any_push PASS")


def test_log_ring_pop_empty_before_any_push() raises:
    var ring = LogRecordRing(16, OVERFLOW_BLOCK)
    assert_false(ring.slots_allocated(), "no store yet")
    assert_true(ring.is_empty(), "fresh ring is empty")
    var maybe = ring.try_pop()
    assert_false(Bool(maybe), "empty pop returns None")
    assert_false(ring.slots_allocated(), "an empty pop allocates nothing")
    print("  test_log_ring_pop_empty_before_any_push PASS")


def test_span_ring_round_trip_and_wrap() raises:
    """Push/pop round-trips a distinguishing field, and the index mask still
    wraps correctly past the capacity boundary with the deferred store."""
    var ring = SpanPacketRingBuffer(4, OVERFLOW_BLOCK)
    # 3 full laps around a 4-slot ring: exercises `tail & (cap-1)` wrap.
    for i in range(12):
        var p = SpanPacket()
        p.span_id = UInt64(i + 1)
        assert_true(ring.try_push(p), "push in-flight")
        var got = ring.try_pop()
        assert_true(Bool(got), "pop returns the pushed packet")
        assert_equal(
            Int(got.value().span_id), Int(i + 1), "round-trip preserves span_id"
        )
    assert_true(ring.is_empty(), "drained")
    print("  test_span_ring_round_trip_and_wrap PASS")


def test_log_ring_round_trip_and_wrap() raises:
    var ring = LogRecordRing(4, OVERFLOW_BLOCK)
    for i in range(12):
        var r = LogEventRecord()
        r.site_id = UInt32(i + 1)
        assert_true(ring.try_push(r), "push in-flight")
        var got = ring.try_pop()
        assert_true(Bool(got), "pop returns the pushed record")
        assert_equal(
            Int(got.value().site_id), Int(i + 1), "round-trip preserves site_id"
        )
    assert_true(ring.is_empty(), "drained")
    print("  test_log_ring_round_trip_and_wrap PASS")


def test_span_ring_drop_policy_still_accounts() raises:
    """DROP-policy overflow accounting is driven by `_capacity`, which is live
    from construction — the deferred store must not change the full point."""
    var ring = SpanPacketRingBuffer(4, OVERFLOW_DROP)
    for _ in range(4):
        assert_true(ring.try_push(SpanPacket()), "fills to capacity")
    assert_false(ring.try_push(SpanPacket()), "5th push on a 4-ring drops")
    assert_equal(
        Int(ring.overflow_dropped_count()), Int(1), "one drop accounted"
    )
    print("  test_span_ring_drop_policy_still_accounts PASS")


def test_log_ring_drop_policy_still_accounts() raises:
    var ring = LogRecordRing(4, OVERFLOW_DROP)
    for _ in range(4):
        assert_true(ring.try_push(LogEventRecord()), "fills to capacity")
    assert_false(ring.try_push(LogEventRecord()), "5th push on a 4-ring drops")
    assert_equal(
        Int(ring.overflow_dropped_count()), Int(1), "one drop accounted"
    )
    print("  test_log_ring_drop_policy_still_accounts PASS")


def main() raises:
    print("test_ring_lazy_slots")
    test_span_packet_ring_slots_are_lazy()
    test_log_record_ring_slots_are_lazy()
    test_span_ring_pop_empty_before_any_push()
    test_log_ring_pop_empty_before_any_push()
    test_span_ring_round_trip_and_wrap()
    test_log_ring_round_trip_and_wrap()
    test_span_ring_drop_policy_still_accounts()
    test_log_ring_drop_policy_still_accounts()
    print("ALL PASS")
