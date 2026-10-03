# =============================================================================
# test_channel_smoke.mojo
# =============================================================================
# smoke test for komira_async.channel (5 sub-modules).
# type-import smoke; per-channel deeper coverage in
# `test_message.mojo`, `test_spsc.mojo`, `test_mpsc.mojo`,
# `test_oneshot.mojo`, `test_broadcast.mojo`.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.channel.broadcast import (
    BroadcastReceiver,
    BroadcastSender,
    channel as broadcast_channel,
    BCAST_RECV_OK,
)
from komira_async.channel.message import Message
from komira_async.channel.mpsc import (
    MpscReceiver,
    MpscSender,
    channel as mpsc_channel,
)
from komira_async.channel.oneshot import (
    OneshotReceiver,
    OneshotSender,
    channel as oneshot_channel,
    SEND_OK,
)
from komira_async.channel.spsc import (
    SpscReceiver,
    SpscSender,
    channel as spsc_channel,
    TRY_SEND_OK,
    TRY_RECV_OK,
)


def test_message_construct() raises:
    """Message[T] is the cross-worker SPSC mesh envelope."""
    var m = Message[Int](payload=42, src_worker=UInt16(0), op_id=Int64(7))
    assert_equal(m.payload, 42)
    assert_equal(Int(m.src_worker), 0)


def test_spsc_factory_smoke() raises:
    """SPSC channel factory constructs both endpoints; basic
    send/recv roundtrip works."""
    var pair = spsc_channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc = tx.try_send(99)
    assert_equal(Int(rc), Int(TRY_SEND_OK))
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_OK))
    assert_equal(r.value(), 99)


def test_mpsc_factory_smoke() raises:
    """MPSC channel factory + send/recv roundtrip."""
    var pair = mpsc_channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc = tx.try_send(77)
    assert_equal(Int(rc), Int(TRY_SEND_OK))
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_OK))
    assert_equal(r.value(), 77)


def test_oneshot_factory_smoke() raises:
    """Oneshot channel factory + send/recv roundtrip."""
    var pair = oneshot_channel[Int]()
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var rc = tx^.send(55)
    assert_equal(Int(rc), Int(SEND_OK))
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(TRY_RECV_OK))
    assert_equal(r.value(), 55)


def test_broadcast_factory_smoke() raises:
    """Broadcast channel factory + send/recv roundtrip."""
    var pair = broadcast_channel[Int](capacity=UInt(4))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    var c = tx.send(33)
    assert_equal(Int(c), 1)
    var r = rx.try_recv()
    assert_equal(Int(r.status), Int(BCAST_RECV_OK))
    assert_equal(r.value(), 33)


def main() raises:
    test_message_construct()
    test_spsc_factory_smoke()
    test_mpsc_factory_smoke()
    test_oneshot_factory_smoke()
    test_broadcast_factory_smoke()
    print("PASS komira_async.channel smoke")
