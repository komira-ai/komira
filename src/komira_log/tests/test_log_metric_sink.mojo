# =============================================================================
# test_log_metric_sink.mojo — `RingMetricSink`, `emit_metric_record`,
# `enable_ring_metric_capture` and `take_ring_metric_points`.
#
# The file's contract is the split between BACKPRESSURE (a full ring: return
# False, the sweep re-offers the point) and REFUSAL (no engine, an unencodable
# point, a histogram: return True and count it, because re-offering is a
# livelock). Every arm gets a case that goes red when that arm alone flips:
#
#   no engine        -> True, `refused_no_engine` 1     (a False would livelock)
#   pushed           -> True, `accepted` 1, the point drains back out
#   ring full        -> False, `backpressured` 1        (a True would lose it)
#   unencodable kind -> True, `refused_unencodable` 1, nothing on the ring
#   histogram        -> True, `refused_histogram` 1
#
# The engine is a test-owned one parked with `_test_install_borrow` and
# un-parked with `_test_reset` before it drops, so each case starts with no
# engine installed.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_spsc_ring.spsc_ring import OVERFLOW_DROP
from komira_metrics.histogram import HistogramPoint
from komira_metrics.metric_point import MetricPoint, counter_point

from komira_log import SharedEngine
from komira_log.env_filter import EnvFilter
from komira_log.engine.log_event_record import LogEventRecord
from komira_log.engine.log_manager import LogManager
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.metric_sink import (
    RingMetricSink,
    emit_metric_record,
    enable_ring_metric_capture,
    take_ring_metric_points,
    METRIC_EMIT_PUSHED,
    METRIC_EMIT_RING_FULL,
    METRIC_EMIT_UNENCODABLE,
)


comptime _VALUE: Int64 = Int64(-3)


def _point() raises -> MetricPoint:
    return counter_point(
        name_id=UInt32(0xA1),
        scope_id=UInt32(0xB2),
        attrset_id=UInt32(0xC3),
        value=_VALUE,
        start_time_unix_ns=UInt64(1_000),
        time_unix_ns=UInt64(2_000),
    )


def _fill(mut ring: LogRecordRing) -> Int:
    """Push blank records until a DROP ring refuses one; returns how many
    landed. Bounded so a ring that never refuses fails the caller's assert
    instead of hanging."""
    var n = 0
    while n < 1 << 20:
        if not ring.try_push(LogEventRecord()):
            return n
        n += 1
    return n


def test_no_engine_is_a_counted_refusal_not_backpressure() raises:
    LogManager._test_reset()
    var sink = RingMetricSink()
    assert_true(
        sink.try_accept(_point()),
        "no engine: True, so the sweep advances instead of re-offering forever",
    )
    assert_equal(sink.refused_no_engine(), 1)
    assert_equal(sink.refused(), 1)
    assert_equal(sink.accepted(), 0)
    assert_equal(sink.backpressured(), 0)
    assert_false(enable_ring_metric_capture(), "nothing to enable")
    assert_equal(len(take_ring_metric_points()), 0, "nothing to take")


def test_an_accepted_point_drains_back_out_through_the_global() raises:
    LogManager._test_reset()
    var eng = SharedEngine(num_workers=1, filter=EnvFilter())
    LogManager._test_install_borrow(eng)
    assert_true(enable_ring_metric_capture(), "capture is on")
    assert_true(eng.capture_metrics())
    var sink = RingMetricSink()
    assert_true(sink.try_accept(_point()))
    assert_equal(sink.accepted(), 1)
    assert_equal(sink.refused(), 0)
    assert_equal(eng.drain_worker(0, 64), 1, "one record on ring(0)")
    var pts = take_ring_metric_points(0)
    LogManager._test_reset()
    # Keeps `eng` alive past the last call that reaches it through the global
    # (Mojo ends a value's life at its last direct use).
    _ = eng.capture_metrics()
    assert_equal(len(pts), 1, "the point is returned")
    assert_equal(Int(pts[0].as_int()), Int(_VALUE))
    assert_equal(Int(pts[0].name_id), 0xA1)


def test_a_full_ring_is_backpressure_and_the_only_false() raises:
    LogManager._test_reset()
    var eng = SharedEngine(num_workers=1, filter=EnvFilter())
    LogManager._test_install_borrow(eng)
    var landed = _fill(eng.ring(0))
    assert_true(landed > 0 and landed < 1 << 20, "the worker ring is DROP")
    var sink = RingMetricSink()
    var took = sink.try_accept(_point())
    var backpressured = sink.backpressured()
    var refused = sink.refused()
    LogManager._test_reset()
    _ = eng.capture_metrics()  # alive until here; see above
    assert_false(took, "a full ring must not report the point delivered")
    assert_equal(backpressured, 1)
    assert_equal(refused, 0, "backpressure is not a loss")


def test_an_unencodable_point_is_refused_without_a_ring_slot() raises:
    LogManager._test_reset()
    var eng = SharedEngine(num_workers=1, filter=EnvFilter())
    LogManager._test_install_borrow(eng)
    var sink = RingMetricSink()
    var took = sink.try_accept(MetricPoint())  # METRIC_KIND_UNKNOWN
    LogManager._test_reset()
    var empty = eng.ring(0).is_empty()
    assert_true(took, "a refusal is True: never re-offer it")
    assert_equal(sink.refused_unencodable(), 1)
    assert_equal(sink.refused(), 1)
    assert_equal(sink.backpressured(), 0)
    assert_true(empty, "nothing was pushed")


def test_a_histogram_is_refused_and_counted() raises:
    var sink = RingMetricSink(worker_id=0)
    assert_true(sink.try_accept_histogram(HistogramPoint()))
    assert_true(sink.try_accept_histogram(HistogramPoint()))
    assert_equal(sink.refused_histogram(), 2)
    assert_equal(sink.refused(), 2)
    assert_equal(sink.accepted(), 0)


def test_emit_outcomes_encode_before_push() raises:
    """PUSHED, then RING_FULL on the full ring, and an unencodable point on
    that same full ring is UNENCODABLE, not RING_FULL: the encode is checked
    first, so a refusal is never reported as backpressure."""
    var ring = LogRecordRing(capacity=2, overflow_policy=OVERFLOW_DROP)
    assert_equal(emit_metric_record(ring, _point(), UInt64(1)), METRIC_EMIT_PUSHED)
    _ = _fill(ring)
    assert_equal(
        emit_metric_record(ring, _point(), UInt64(2)), METRIC_EMIT_RING_FULL
    )
    assert_equal(
        emit_metric_record(ring, MetricPoint(), UInt64(3)),
        METRIC_EMIT_UNENCODABLE,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
