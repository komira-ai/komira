# =============================================================================
# test_mpsc.mojo — MPSC channel tests
# =============================================================================
# multi-producer single-consumer.
# Vyukov-style MPMC queue with fetch_add CAS-loop on enqueue_pos.
#
# Tests:
#   1. capacity validation — power-of-2 enforcement
#   2. single-producer roundtrip — basic FIFO (single producer is the
#      degenerate MPSC case)
#   3. clone-then-send — multiple senders share the queue
#   4. full ring → TRY_SEND_FULL
#   5. close + drain — receiver drains pending then sees CLOSED
#   6. unbounded() factory — large default capacity
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.channel.mpsc import (
    MpscReceiver,
    MpscSender,
    channel,
    unbounded,
)
from komira_async.channel.spsc import (
    TRY_SEND_OK,
    TRY_SEND_FULL,
    TRY_SEND_CLOSED,
    TRY_RECV_OK,
    TRY_RECV_EMPTY,
    TRY_RECV_CLOSED,
)


def test_capacity_must_be_power_of_two() raises:
    """Vyukov ring capacity power-of-2 enforced."""
    var raised = False
    try:
        var pair = channel[Int](capacity=UInt(3))
        _ = pair^
    except Error:
        raised = True
    assert_true(raised, "channel(capacity=3) must raise")


def test_single_producer_roundtrip() raises:
    """1 producer × 1 consumer — degenerate MPSC; FIFO."""
    var pair = channel[Int](capacity=UInt(8))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    for i in range(5):
        var rc = tx.try_send(i * 11)
        assert_equal(Int(rc), Int(TRY_SEND_OK))
    for i in range(5):
        var r = rx.try_recv()
        assert_equal(Int(r.status), Int(TRY_RECV_OK))
        assert_equal(r.value(), i * 11)


def test_clone_then_send() raises:
    """MpscSender.clone() shares the queue. Both clones can
    send independently."""
    var pair = channel[Int](capacity=UInt(8))
    var tx1 = pair.take_sender()
    var tx2 = tx1.clone()
    var rx = pair.take_receiver()
    var rc1 = tx1.try_send(100)
    var rc2 = tx2.try_send(200)
    var rc3 = tx1.try_send(300)
    assert_equal(Int(rc1), Int(TRY_SEND_OK))
    assert_equal(Int(rc2), Int(TRY_SEND_OK))
    assert_equal(Int(rc3), Int(TRY_SEND_OK))
    # Drain — order is FIFO across producers (single-thread interleave).
    var r1 = rx.try_recv()
    var r2 = rx.try_recv()
    var r3 = rx.try_recv()
    assert_equal(Int(r1.status), Int(TRY_RECV_OK))
    assert_equal(r1.value(), 100)
    assert_equal(Int(r2.status), Int(TRY_RECV_OK))
    assert_equal(r2.value(), 200)
    assert_equal(Int(r3.status), Int(TRY_RECV_OK))
    assert_equal(r3.value(), 300)


def test_full_ring_returns_try_send_full() raises:
    """Vyukov ring full → TRY_SEND_FULL."""
    var pair = channel[Int](capacity=UInt(2))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc1 = tx.try_send(1)
    var rc2 = tx.try_send(2)
    assert_equal(Int(rc1), Int(TRY_SEND_OK))
    assert_equal(Int(rc2), Int(TRY_SEND_OK))
    var rc3 = tx.try_send(3)
    assert_equal(Int(rc3), Int(TRY_SEND_FULL))
    # Drain to make space.
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_OK))
    var rc4 = tx.try_send(3)
    assert_equal(Int(rc4), Int(TRY_SEND_OK))


def test_close_drains_then_closed() raises:
    """close() drain semantics."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    _ = tx.try_send(7)
    _ = tx.try_send(8)
    tx.close()
    var r1 = rx.try_recv()
    assert_equal(Int(r1.status), Int(TRY_RECV_OK))
    assert_equal(r1.value(), 7)
    var r2 = rx.try_recv()
    assert_equal(Int(r2.status), Int(TRY_RECV_OK))
    assert_equal(r2.value(), 8)
    var r3 = rx.try_recv()
    assert_equal(Int(r3.status), Int(TRY_RECV_CLOSED))


def test_receiver_close_blocks_sender() raises:
    """receiver close → sender try_send returns CLOSED."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    rx.close()
    var rc = tx.try_send(1)
    assert_equal(Int(rc), Int(TRY_SEND_CLOSED))


def test_unbounded_factory_works() raises:
    """unbounded() returns a large-capacity
    MPSC for low-rate signal channels."""
    var pair = unbounded[Int]()
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    # Send a bunch (well under the 4096 default).
    for i in range(100):
        var rc = tx.try_send(i)
        assert_equal(Int(rc), Int(TRY_SEND_OK))
    # Drain.
    for i in range(100):
        var r = rx.try_recv()
        assert_equal(Int(r.status), Int(TRY_RECV_OK))
        assert_equal(r.value(), i)


def main() raises:
    test_capacity_must_be_power_of_two()
    test_single_producer_roundtrip()
    test_clone_then_send()
    test_full_ring_returns_try_send_full()
    test_close_drains_then_closed()
    test_receiver_close_blocks_sender()
    test_unbounded_factory_works()
    print("PASS komira_async.channel.test_mpsc")
