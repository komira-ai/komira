# =============================================================================
# test_oneshot.mojo — Oneshot tests
# =============================================================================
# single-shot value transfer.
#
# State machine: 0=EMPTY, 1=SET, 2=CLOSED via Atomic[int32] (uint8 lacks
# compare_exchange in Mojo 0.26.3 ).
#
# Tests:
#   1. send → recv roundtrip (Int payload)
#   2. try_recv on empty returns EMPTY
#   3. send then try_recv returns OK with value
#   4. sender close (drop without send) → receiver sees CLOSED
#   5. double-send via clone is structurally impossible (send consumes self)
#   6. try_recv after send-and-recv returns CLOSED (slot drained)
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.channel.oneshot import (
    OneshotReceiver,
    OneshotSender,
    OneshotChannelPair,
    channel,
    SEND_OK,
    SEND_CLOSED,
)
from komira_async.channel.spsc import (
    TRY_RECV_OK,
    TRY_RECV_EMPTY,
    TRY_RECV_CLOSED,
    TryRecvOutcome,
)


def test_send_recv_roundtrip_int() raises:
    """simple Int payload send → try_recv."""
    var pair = channel[Int]()
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc = tx^.send(42)
    assert_equal(Int(rc), Int(SEND_OK))
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_OK))
    assert_equal(r.value(), 42)


def test_try_recv_on_empty() raises:
    """try_recv on empty oneshot returns EMPTY status."""
    var pair = channel[Int]()
    var _tx = pair.take_sender()
    var rx = pair.take_receiver()
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_EMPTY))


def test_sender_close_signals_receiver() raises:
    """sender close without send → receiver sees CLOSED."""
    var pair = channel[Int]()
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    tx^.close()
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_CLOSED))


def test_try_recv_after_drain_returns_closed() raises:
    """after a successful send + try_recv, the slot is drained
    and subsequent try_recv returns CLOSED."""
    var pair = channel[Int]()
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc = tx^.send(7)
    assert_equal(Int(rc), Int(SEND_OK))
    var r1 = rx.try_recv()
    assert_equal(Int(r1.status), Int(TRY_RECV_OK))
    assert_equal(r1.value(), 7)
    # Slot drained; subsequent try_recv returns CLOSED (sender consumed
    # itself in the send call so no more sends can happen).
    var r2 = rx.try_recv()
    assert_equal(Int(r2.status), Int(TRY_RECV_CLOSED))


def test_send_after_receiver_close_returns_closed() raises:
    """receiver close before send → sender sees CLOSED status."""
    var pair = channel[Int]()
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    rx^.close()
    var rc = tx^.send(99)
    assert_equal(Int(rc), Int(SEND_CLOSED))


def test_send_string_payload() raises:
    """Mojo 0.26.3 String payload through Oneshot."""
    var pair = channel[String]()
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc = tx^.send(String("hello-oneshot"))
    assert_equal(Int(rc), Int(SEND_OK))
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_OK))
    assert_equal(r.value(), String("hello-oneshot"))


def main() raises:
    test_send_recv_roundtrip_int()
    test_try_recv_on_empty()
    test_sender_close_signals_receiver()
    test_try_recv_after_drain_returns_closed()
    test_send_after_receiver_close_returns_closed()
    test_send_string_payload()
    print("PASS komira_async.channel.test_oneshot")
