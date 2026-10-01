# =============================================================================
# test_stream_smoke.mojo
# =============================================================================
# minimal import + construct smoke for komira_async.stream.
# (The full test suite is at test_stream.mojo; this smoke is the
# Cargo-equivalent compile-pass canary.)
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.channel.mpsc import channel
from komira_async.stream.stream import (
    ChannelStream,
    FilterStream,
    MapStream,
    Stream,
    TakeStream,
    collect,
    iter_channel,
)


def test_channel_stream_construct() raises:
    """ChannelStream wraps a fresh receiver; no items → close() → next()
    yields None."""
    var pair = channel[Int](capacity=UInt(4))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    sender.close()
    var s = iter_channel[Int](receiver^)
    var item = s.next()
    assert_false(item.__bool__())


def test_channel_stream_one_item() raises:
    """Single-item smoke: send 7, close, next yields Some(7), then None."""
    var pair = channel[Int](capacity=UInt(4))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    _ = sender.try_send(7)
    sender.close()
    var s = iter_channel[Int](receiver^)
    var item = s.next()
    assert_true(item.__bool__())
    assert_equal(item.value(), 7)
    var item2 = s.next()
    assert_false(item2.__bool__())


def main() raises:
    test_channel_stream_construct()
    test_channel_stream_one_item()
    print("PASS komira_async.stream smoke")
