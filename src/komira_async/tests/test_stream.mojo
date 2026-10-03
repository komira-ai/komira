# =============================================================================
# test_stream.mojo
# =============================================================================
# Stream[T] trait + adapters real-impl tests.
#
# 10 tests covering:
#   * iter_channel — wraps an MpscReceiver as a Stream
#   * map / filter / take — combinators on a base Stream
#   * collect — drains a stream into a List
#   * chained pipeline (map → filter → take → collect)
#
# This form ships the synchronous-Optional[T] form. A later step
# lifts to IoOp[Optional[T], NoopSink, never_origin] once reactor.run_once
# is wired (matches AsyncMutex.lock pattern: synchronous-park in 1.17,
# IoOp form in a later step).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.channel.mpsc import (
    MpscChannelPair,
    MpscSender,
    MpscReceiver,
    channel,
)
from komira_async.stream.stream import (
    ChannelStream,
    FilterStream,
    MapStream,
    TakeStream,
    collect,
    iter_channel,
)


# -----------------------------------------------------------------------------
# Closure conformers (Mojo 0.26.3 has no first-class capture closures; the
# canonical idiom is a struct conformer with a __call__ shape, OR free fns
# referenced by name. We use free fns since map/filter take fn pointers).
# -----------------------------------------------------------------------------


def _double_int(v: Int) -> Int:
    return v * 2


def _is_even(v: Int) -> Bool:
    return (v % 2) == 0


def _gt_5(v: Int) -> Bool:
    return v > 5


# -----------------------------------------------------------------------------
# Test 1: iter_channel — drains a 5-element MpscChannel
# -----------------------------------------------------------------------------


def test_iter_channel_drains() raises:
    """ChannelStream wraps an MpscReceiver. Send 5 ints, close sender,
    iterate via ChannelStream.next() — first 5 yield Some(i), 6th yields
    None."""
    var pair = channel[Int](capacity=UInt(8))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    for i in range(5):
        var status = sender.try_send(i)
        assert_equal(Int(status), 0)  # TRY_SEND_OK
    sender.close()
    var stream = iter_channel[Int](receiver^)
    for i in range(5):
        var item = stream.next()
        assert_true(item.__bool__())
        assert_equal(item.value(), i)
    var item6 = stream.next()
    assert_false(item6.__bool__())


# -----------------------------------------------------------------------------
# Test 2: iter_channel — close-sender propagates as None
# -----------------------------------------------------------------------------


def test_iter_channel_close_propagates() raises:
    """Send 3, close sender, ChannelStream drains all 3 then yields None
    (TRY_RECV_CLOSED is observed as Optional.None at the Stream surface)."""
    var pair = channel[Int](capacity=UInt(8))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    var status1 = sender.try_send(10)
    var status2 = sender.try_send(20)
    var status3 = sender.try_send(30)
    assert_equal(Int(status1), 0)
    assert_equal(Int(status2), 0)
    assert_equal(Int(status3), 0)
    sender.close()
    var stream = iter_channel[Int](receiver^)
    var got1 = stream.next()
    var got2 = stream.next()
    var got3 = stream.next()
    var got4 = stream.next()
    assert_true(got1.__bool__())
    assert_equal(got1.value(), 10)
    assert_true(got2.__bool__())
    assert_equal(got2.value(), 20)
    assert_true(got3.__bool__())
    assert_equal(got3.value(), 30)
    assert_false(got4.__bool__())


# -----------------------------------------------------------------------------
# Test 3: map — int → int via _double_int
# -----------------------------------------------------------------------------


def test_map_int_to_int() raises:
    """ChannelStream[Int] → MapStream[..., Int, Int] with _double_int.
    Submit 1..5; collect should be [2, 4, 6, 8, 10]."""
    var pair = channel[Int](capacity=UInt(8))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    for i in range(1, 6):
        _ = sender.try_send(i)
    sender.close()
    var inner = iter_channel[Int](receiver^)
    var mapped = MapStream[ChannelStream[Int], Int](
        _inner=inner^, _f=_double_int
    )
    var collected = collect[MapStream[ChannelStream[Int], Int]](
        mapped^
    )
    assert_equal(len(collected), 5)
    assert_equal(collected[0], 2)
    assert_equal(collected[1], 4)
    assert_equal(collected[2], 6)
    assert_equal(collected[3], 8)
    assert_equal(collected[4], 10)


# -----------------------------------------------------------------------------
# Test 4: filter — keep evens
# -----------------------------------------------------------------------------


def test_filter_evens() raises:
    """Submit 1..10; FilterStream pred=_is_even; collect == [2, 4, 6, 8, 10]."""
    var pair = channel[Int](capacity=UInt(16))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    for i in range(1, 11):
        _ = sender.try_send(i)
    sender.close()
    var inner = iter_channel[Int](receiver^)
    var filtered = FilterStream[ChannelStream[Int]](
        _inner=inner^, _pred=_is_even
    )
    var collected = collect[FilterStream[ChannelStream[Int]]](
        filtered^
    )
    assert_equal(len(collected), 5)
    assert_equal(collected[0], 2)
    assert_equal(collected[1], 4)
    assert_equal(collected[2], 6)
    assert_equal(collected[3], 8)
    assert_equal(collected[4], 10)


# -----------------------------------------------------------------------------
# Test 5: take — caps to first N
# -----------------------------------------------------------------------------


def test_take_n_caps() raises:
    """Submit 100; TakeStream n=5; collect.len() == 5; subsequent next()
    returns None (cap absorbed)."""
    var pair = channel[Int](capacity=UInt(128))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    for i in range(100):
        _ = sender.try_send(i)
    sender.close()
    var inner = iter_channel[Int](receiver^)
    var taken = TakeStream[ChannelStream[Int]](
        _inner=inner^, _remaining=UInt(5)
    )
    var collected = collect[TakeStream[ChannelStream[Int]]](
        taken^
    )
    assert_equal(len(collected), 5)
    assert_equal(collected[0], 0)
    assert_equal(collected[4], 4)


# -----------------------------------------------------------------------------
# Test 6: take — bigger n than the channel yields all elements
# -----------------------------------------------------------------------------


def test_take_n_larger_than_channel() raises:
    """Submit 3; TakeStream n=100; collect should yield 3 elements + None."""
    var pair = channel[Int](capacity=UInt(8))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    _ = sender.try_send(11)
    _ = sender.try_send(22)
    _ = sender.try_send(33)
    sender.close()
    var inner = iter_channel[Int](receiver^)
    var taken = TakeStream[ChannelStream[Int]](
        _inner=inner^, _remaining=UInt(100)
    )
    var collected = collect[TakeStream[ChannelStream[Int]]](
        taken^
    )
    assert_equal(len(collected), 3)
    assert_equal(collected[0], 11)
    assert_equal(collected[2], 33)


# -----------------------------------------------------------------------------
# Test 7: collect on closed empty channel
# -----------------------------------------------------------------------------


def test_collect_empty_stream() raises:
    """Closed empty channel → collect → empty List."""
    var pair = channel[Int](capacity=UInt(4))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    sender.close()
    var stream = iter_channel[Int](receiver^)
    var collected = collect[ChannelStream[Int]](stream^)
    assert_equal(len(collected), 0)


# -----------------------------------------------------------------------------
# Test 8: collect with single element
# -----------------------------------------------------------------------------


def test_collect_single_element() raises:
    """One element + close → collect yields a one-element list."""
    var pair = channel[Int](capacity=UInt(4))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    _ = sender.try_send(42)
    sender.close()
    var stream = iter_channel[Int](receiver^)
    var collected = collect[ChannelStream[Int]](stream^)
    assert_equal(len(collected), 1)
    assert_equal(collected[0], 42)


# -----------------------------------------------------------------------------
# Test 9: chained pipeline — map → filter → take → collect
# -----------------------------------------------------------------------------


def test_chain_map_filter_take() raises:
    """Pipeline: ChannelStream[Int 1..10] → MapStream(_double_int) →
    FilterStream(_gt_5) → TakeStream(2) → collect.

    Map produces [2,4,6,8,10,12,14,16,18,20]; filter keeps [6,8,10,...,20];
    take 2 yields [6, 8]."""
    var pair = channel[Int](capacity=UInt(16))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    for i in range(1, 11):
        _ = sender.try_send(i)
    sender.close()

    # Stage 1: ChannelStream
    var s1 = iter_channel[Int](receiver^)
    # Stage 2: MapStream(_double_int)
    var s2 = MapStream[ChannelStream[Int], Int](
        _inner=s1^, _f=_double_int
    )
    # Stage 3: FilterStream(_gt_5)
    var s3 = FilterStream[MapStream[ChannelStream[Int], Int]](
        _inner=s2^, _pred=_gt_5
    )
    # Stage 4: TakeStream(2)
    var s4 = TakeStream[
        FilterStream[MapStream[ChannelStream[Int], Int]]
    ](_inner=s3^, _remaining=UInt(2))

    var collected = collect[
        TakeStream[FilterStream[MapStream[ChannelStream[Int], Int]]]
    ](s4^)
    assert_equal(len(collected), 2)
    assert_equal(collected[0], 6)
    assert_equal(collected[1], 8)


# -----------------------------------------------------------------------------
# Test 10: filter all-rejected returns empty
# -----------------------------------------------------------------------------


def test_filter_all_rejected() raises:
    """Submit 10 odd ints; filter pred=_is_even rejects everything; collect
    yields empty list."""
    var pair = channel[Int](capacity=UInt(16))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()
    for i in range(10):
        _ = sender.try_send(2 * i + 1)  # odd: 1, 3, 5, ..., 19
    sender.close()
    var inner = iter_channel[Int](receiver^)
    var filtered = FilterStream[ChannelStream[Int]](
        _inner=inner^, _pred=_is_even
    )
    var collected = collect[FilterStream[ChannelStream[Int]]](
        filtered^
    )
    assert_equal(len(collected), 0)


def main() raises:
    test_iter_channel_drains()
    test_iter_channel_close_propagates()
    test_map_int_to_int()
    test_filter_evens()
    test_take_n_caps()
    test_take_n_larger_than_channel()
    test_collect_empty_stream()
    test_collect_single_element()
    test_chain_map_filter_take()
    test_filter_all_rejected()
    print("PASS komira_async.stream (10/10 tests)")
