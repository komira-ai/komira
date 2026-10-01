# =============================================================================
# test_spsc.mojo — SPSC channel tests
# =============================================================================
# single-producer, single-consumer ring.
# Cache-line-isolated layout (head/tail ≥ 64 bytes).
#
# Tests:
#   1. capacity validation — power-of-2 enforcement
#   2. single-thread fast path — push/pop FIFO at small capacity
#   3. capacity boundary — fill ring; try_send returns Full
#   4. close() + drain — receiver drains pending then sees Closed
#   5. try_recv batched — drain N items in one call
#   6. wrap-around at capacity boundary
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.channel.spsc import (
    SpscReceiver,
    SpscSender,
    channel,
    TRY_SEND_OK,
    TRY_SEND_FULL,
    TRY_SEND_CLOSED,
    TRY_RECV_OK,
    TRY_RECV_EMPTY,
    TRY_RECV_CLOSED,
)


def test_capacity_must_be_power_of_two() raises:
    """Capacity ENFORCED power-of-2."""
    var raised = False
    try:
        var pair = channel[Int](capacity=UInt(3))
        _ = pair^
    except Error:
        raised = True
    assert_true(raised, "channel(capacity=3) must raise (not power-of-2)")


def test_capacity_zero_rejected() raises:
    """capacity=0 is degenerate; reject."""
    var raised = False
    try:
        var pair = channel[Int](capacity=UInt(0))
        _ = pair^
    except Error:
        raised = True
    assert_true(raised, "channel(capacity=0) must raise")


def test_single_pair_fifo_roundtrip() raises:
    """send then recv; FIFO order preserved."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc1 = tx.try_send(10)
    var rc2 = tx.try_send(20)
    var rc3 = tx.try_send(30)
    assert_equal(Int(rc1), Int(TRY_SEND_OK))
    assert_equal(Int(rc2), Int(TRY_SEND_OK))
    assert_equal(Int(rc3), Int(TRY_SEND_OK))
    var r1 = rx.try_recv()
    var r2 = rx.try_recv()
    var r3 = rx.try_recv()
    assert_equal(Int(r1.status), Int(TRY_RECV_OK))
    assert_equal(r1.value(), 10)
    assert_equal(Int(r2.status), Int(TRY_RECV_OK))
    assert_equal(r2.value(), 20)
    assert_equal(Int(r3.status), Int(TRY_RECV_OK))
    assert_equal(r3.value(), 30)


def test_full_returns_try_send_full() raises:
    """ring full → try_send returns FULL."""
    var pair = channel[Int](capacity=UInt(2))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc1 = tx.try_send(1)
    var rc2 = tx.try_send(2)
    assert_equal(Int(rc1), Int(TRY_SEND_OK))
    assert_equal(Int(rc2), Int(TRY_SEND_OK))
    var rc3 = tx.try_send(3)
    assert_equal(Int(rc3), Int(TRY_SEND_FULL))
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_OK))
    assert_equal(r.value(), 1)
    var rc4 = tx.try_send(3)
    assert_equal(Int(rc4), Int(TRY_SEND_OK))


def test_empty_returns_try_recv_empty() raises:
    """empty ring → try_recv returns EMPTY."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_EMPTY))
    _ = tx
    _ = rx


def test_close_sender_drains_then_closed() raises:
    """sender closes; receiver drains pending; then sees CLOSED."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    _ = tx.try_send(1)
    _ = tx.try_send(2)
    tx.close()
    var r1 = rx.try_recv()
    assert_equal(Int(r1.status), Int(TRY_RECV_OK))
    assert_equal(r1.value(), 1)
    var r2 = rx.try_recv()
    assert_equal(Int(r2.status), Int(TRY_RECV_OK))
    assert_equal(r2.value(), 2)
    var r3 = rx.try_recv()
    assert_equal(Int(r3.status), Int(TRY_RECV_CLOSED))


def test_close_receiver_blocks_sender() raises:
    """receiver closes; subsequent try_send returns CLOSED."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    rx.close()
    var rc = tx.try_send(1)
    assert_equal(Int(rc), Int(TRY_SEND_CLOSED))


def test_try_recv_batch_drains_n_items() raises:
    """13 +: try_recv_batch drains N in one call.
    The batched API is the primary recv per audit recommendation 14."""
    var pair = channel[Int](capacity=UInt(16))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    for i in range(8):
        _ = tx.try_send(i * 10)
    var batch = rx.try_recv_batch(max_items=UInt(6))
    assert_equal(len(batch), 6)
    for i in range(6):
        assert_equal(batch[i], i * 10)
    var batch2 = rx.try_recv_batch(max_items=UInt(8))
    assert_equal(len(batch2), 2)
    assert_equal(batch2[0], 60)
    assert_equal(batch2[1], 70)
    var batch3 = rx.try_recv_batch(max_items=UInt(8))
    assert_equal(len(batch3), 0)


def test_wrap_around_at_capacity_boundary() raises:
    """ring index wraps via mask = capacity - 1."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    for i in range(10):
        var rc = tx.try_send(i)
        assert_equal(Int(rc), Int(TRY_SEND_OK))
        var r = rx.try_recv()
        assert_equal(Int(r.status), Int(TRY_RECV_OK))
        assert_equal(r.value(), i)


def main() raises:
    test_capacity_must_be_power_of_two()
    test_capacity_zero_rejected()
    test_single_pair_fifo_roundtrip()
    test_full_returns_try_send_full()
    test_empty_returns_try_recv_empty()
    test_close_sender_drains_then_closed()
    test_close_receiver_blocks_sender()
    test_try_recv_batch_drains_n_items()
    test_wrap_around_at_capacity_boundary()
    print("PASS komira_async.channel.test_spsc")
