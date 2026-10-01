# =============================================================================
# test_broadcast.mojo — Broadcast tests
# =============================================================================
# Pub/sub fan-out.
#
# Ring buffer of capacity slots. Producer increments _pos: Atomic[uint64];
# each subscriber holds its own _cursor. Slow-receiver: lag-then-error.
#
#
# Tests:
#   1. capacity validation — power-of-2 enforcement
#   2. 1 sender × 2 subscribers — both see all values in FIFO order
#   3. new subscriber misses prior values — cursor starts at current pos
#   4. slow subscriber lags — pos > cursor + capacity → LAGGED status
#   5. subscriber drop reduces sub_count — send still succeeds
#   6. send to no subscribers — succeeds (returns 0); values are dropped
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.channel.broadcast import (
    BroadcastReceiver,
    BroadcastSender,
    BroadcastChannelPair,
    channel,
    BCAST_RECV_OK,
    BCAST_RECV_EMPTY,
    BCAST_RECV_CLOSED,
    BCAST_RECV_LAGGED,
    BroadcastRecvOutcome,
)


def test_capacity_must_be_power_of_two() raises:
    """ring capacity must be power-of-2."""
    var raised = False
    try:
        var pair = channel[Int](capacity=UInt(3))
        _ = pair^
    except Error:
        raised = True
    assert_true(raised, "channel(capacity=3) must raise")


def test_one_sender_two_subscribers() raises:
    """1 producer × 2 subscribers; both see all values FIFO."""
    var pair = channel[Int](capacity=UInt(8))
    var tx = pair.take_sender()
    var rx1 = pair.take_receiver()
    # Subscribe a second receiver from the sender.
    var rx2 = tx.subscribe()

    # Send 3 values.
    var c1 = tx.send(10)
    var c2 = tx.send(20)
    var c3 = tx.send(30)
    # Both subs are live; send returns 2 (count of subscribers).
    assert_equal(Int(c1), 2)
    assert_equal(Int(c2), 2)
    assert_equal(Int(c3), 2)

    # rx1 sees 10, 20, 30 in order.
    var r11 = rx1.try_recv()
    assert_equal(Int(r11.status), Int(BCAST_RECV_OK))
    assert_equal(r11.value(), 10)
    var r12 = rx1.try_recv()
    assert_equal(r12.value(), 20)
    var r13 = rx1.try_recv()
    assert_equal(r13.value(), 30)

    # rx2 also sees 10, 20, 30 in order.
    var r21 = rx2.try_recv()
    assert_equal(Int(r21.status), Int(BCAST_RECV_OK))
    assert_equal(r21.value(), 10)
    var r22 = rx2.try_recv()
    assert_equal(r22.value(), 20)
    var r23 = rx2.try_recv()
    assert_equal(r23.value(), 30)


def test_new_subscriber_misses_prior_values() raises:
    """new subscriber's cursor starts at current pos. Sends
    BEFORE subscribe are not seen."""
    var pair = channel[Int](capacity=UInt(8))
    var tx = pair.take_sender()
    var rx1 = pair.take_receiver()

    # Send 2 values BEFORE subscribing rx2.
    _ = tx.send(100)
    _ = tx.send(200)
    var rx2 = tx.subscribe()
    # Send 1 value AFTER rx2 subscribes.
    _ = tx.send(300)

    # rx2 only sees 300.
    var r21 = rx2.try_recv()
    assert_equal(Int(r21.status), Int(BCAST_RECV_OK))
    assert_equal(r21.value(), 300)
    # rx2's next try_recv is empty.
    var r22 = rx2.try_recv()
    assert_equal(Int(r22.status), Int(BCAST_RECV_EMPTY))


def test_slow_subscriber_lags() raises:
    """capacity=4; sender sends 8; slow consumer's first recv
    returns LAGGED."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()

    # Send 8 values (capacity=4 so positions 4..7 overwrite 0..3).
    for i in range(8):
        _ = tx.send(i * 10)

    # First recv from rx detects lag.
    var r1 = rx.try_recv()
    assert_equal(Int(r1.status), Int(BCAST_RECV_LAGGED))

    # After lag, cursor advances to current pos - capacity = 4. Subsequent
    # recvs return values 40, 50, 60, 70 in order.
    var r2 = rx.try_recv()
    assert_equal(Int(r2.status), Int(BCAST_RECV_OK))
    assert_equal(r2.value(), 40)
    var r3 = rx.try_recv()
    assert_equal(r3.value(), 50)
    var r4 = rx.try_recv()
    assert_equal(r4.value(), 60)
    var r5 = rx.try_recv()
    assert_equal(r5.value(), 70)
    # Drained.
    var r6 = rx.try_recv()
    assert_equal(Int(r6.status), Int(BCAST_RECV_EMPTY))


def test_send_to_no_subscribers() raises:
    """send when sub_count=0 still succeeds; returns 0."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    rx^.close()
    # After receiver close, sub_count drops to 0.
    var c = tx.send(42)
    assert_equal(Int(c), 0)


def test_sender_close_makes_receivers_see_closed() raises:
    """sender close → receivers' next try_recv (after drain)
    returns CLOSED."""
    var pair = channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    _ = tx.send(7)
    tx^.close()
    var r1 = rx.try_recv()
    assert_equal(Int(r1.status), Int(BCAST_RECV_OK))
    assert_equal(r1.value(), 7)
    var r2 = rx.try_recv()
    assert_equal(Int(r2.status), Int(BCAST_RECV_CLOSED))


def main() raises:
    test_capacity_must_be_power_of_two()
    test_one_sender_two_subscribers()
    test_new_subscriber_misses_prior_values()
    test_slow_subscriber_lags()
    test_send_to_no_subscribers()
    test_sender_close_makes_receivers_see_closed()
    print("PASS komira_async.channel.test_broadcast")
