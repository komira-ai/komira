# =============================================================================
# test_drain_join_scales.mojo -- the drain's OPEN/CLOSE join is linear
# =============================================================================
#
# WHAT THIS TEST GATES. The drain (`drain_into_capture`, and `drain_into_jsonl`
# in production) joins each CLOSE packet to its OPEN record by span id. One
# worker drains N1 = 4,096 spans and then N2 = 16 * N1 = 65,536 spans; the test
# asserts t(N2) / t(N1) < 64. A linear join gives about 16x; a join that scans
# the records once per CLOSE (O(n^2)) gives about 256x. 64 is the geometric
# mean of the two, so it tolerates a 4x timing distortion either way.
#
# Why a ratio and not an absolute rate: the ratio does not depend on how fast
# the builder is, how loaded it is or whether the build is instrumented for
# coverage; only the growth of the drain with n moves it. Only the drain is
# timed (the producer loop is outside the timed region), and each size takes
# the fastest of up to REPS drains, so one descheduled run cannot fail it.
#
# DEFECT IT CATCHES: a per-CLOSE linear scan over the records (the join this
# package shipped before the Dict index). Every drained record is also checked
# closed, with its own span id, so a join that patches the wrong record fails
# here too.
# =============================================================================

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_spsc_ring.spsc_ring import OVERFLOW_DROP
from komira_trace.tracer import Tracer
from komira_trace.exporter import CapturingExporter
from komira_trace.span_record import SPAN_STATUS_CLOSED


comptime N1 = 4_096
comptime N2 = 65_536
comptime GROWTH = N2 // N1  # 16
# Geometric mean of linear (16x) and quadratic (256x) growth.
comptime RATIO_CEILING = 64.0
comptime REPS = 3
# One OPEN + one CLOSE packet per span; the ring must hold every packet of the
# larger run (no drop, or the join would see fewer packets than emitted).
comptime RING_CAPACITY = 2 * N2


def _timed_drain(n: Int) raises -> Int:
    """Emits `n` closed spans on worker 0, then drains them; returns the
    drain's wall time in ns after checking every record."""
    var tracer = Tracer(
        num_workers=1, ring_capacity=RING_CAPACITY, overflow_policy=OVERFLOW_DROP
    )
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    for _i in range(n):
        var s = tracer.start_span["bench.join"](worker_id=0)
        tracer.end_span(s, worker_id=0)
    assert_equal(
        tracer.ring_size(0), Int64(2 * n), "every packet is in the ring"
    )

    var exp = CapturingExporter()
    var t0 = perf_counter_ns()
    tracer.drain_into_capture(exp)
    var t1 = perf_counter_ns()

    assert_equal(exp.count(), n, "one record per emitted span")
    for i in range(n):
        ref rec = exp.captured_spans[i]
        # Seeded ids: the i-th OPEN carries span id i + 1.
        assert_equal(rec.span_id, UInt64(i + 1), "records in OPEN order")
        assert_equal(rec.status, SPAN_STATUS_CLOSED, "every span is closed")
    return Int(t1 - t0)


def _best_of(n: Int, reps: Int) raises -> Int:
    var best = _timed_drain(n)
    for _r in range(reps - 1):
        var t = _timed_drain(n)
        if t < best:
            best = t
    return best


def test_drain_join_is_linear() raises:
    # Warm-up: the first drain pays one-time allocator growth.
    _ = _timed_drain(N1)
    var t1 = _best_of(N1, REPS)
    # The large size runs once and is re-measured only when the ratio looks
    # high, so a linear join costs one large drain and a slow one costs REPS.
    var t2 = _timed_drain(N2)
    for _r in range(REPS - 1):
        if Float64(t2) / Float64(t1) < RATIO_CEILING:
            break
        var t = _timed_drain(N2)
        if t < t2:
            t2 = t
    var ratio = Float64(t2) / Float64(t1)
    print("  t(N1 =", N1, ") =", t1, "ns")
    print("  t(N2 =", N2, ") =", t2, "ns")
    print("  ratio =", ratio, "(linear ~", GROWTH, ", quadratic ~", GROWTH * GROWTH, ")")
    assert_true(
        ratio < RATIO_CEILING,
        "drain join grows faster than linear: t(N2)/t(N1) = " + String(ratio),
    )
    print("  test_drain_join_is_linear PASS")


def main() raises:
    print("test_drain_join_scales")
    print("======================")
    test_drain_join_is_linear()
    print()
    print("ALL TESTS PASS")
