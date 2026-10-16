# =============================================================================
# test_drain_join_scales.mojo -- the drain's OPEN/CLOSE join is linear
# =============================================================================
#
# WHAT THIS TEST GATES. The drain (`drain_into_capture`, and `drain_into_jsonl`
# in production) joins each CLOSE packet to its OPEN record by span id. One
# worker drains N1 = 4,096 spans and, on a second Tracer, N2 = 16 * N1 = 65,536
# spans. The test reads `Tracer.join_probes()`, the number of span records the
# join examined to resolve CLOSE packets, and asserts:
#
#   - probes == n for each size: the indexed join costs one probe per CLOSE;
#   - probes(N2) == 16 * probes(N1) exactly.
#
# A join that scans the records once per CLOSE examines about n^2 / 2 records
# (8.4e6 at N1, 2.1e9 at N2), so every assert fails on it. Nothing here reads a
# clock: the counts do not depend on the builder's speed or load.
#
# DEFECT IT CATCHES: a per-CLOSE linear scan over the records (the join this
# package shipped before the Dict index). Every drained record is also checked
# closed, with its own span id, so a join that patches the wrong record fails
# here too.
# =============================================================================

from std.testing import assert_equal

from komira_spsc_ring.spsc_ring import OVERFLOW_DROP
from komira_trace.tracer import Tracer
from komira_trace.exporter import CapturingExporter
from komira_trace.span_record import SPAN_STATUS_CLOSED


comptime N1 = 4_096
comptime N2 = 65_536
comptime GROWTH = N2 // N1  # 16
# One OPEN + one CLOSE packet per span; the ring must hold every packet of the
# larger run (no drop, or the join would see fewer packets than emitted).
comptime RING_CAPACITY = 2 * N2


def _drain_probes(n: Int) raises -> Int:
    """Emits `n` closed spans on worker 0, drains them after checking every
    record, and returns the join's probe count."""
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
    assert_equal(tracer.ring_dropped_count(0), Int64(0), "no packet dropped")
    assert_equal(tracer.join_probes(), 0, "nothing joined before the drain")

    var exp = CapturingExporter()
    tracer.drain_into_capture(exp)

    assert_equal(exp.count(), n, "one record per emitted span")
    for i in range(n):
        ref rec = exp.captured_spans[i]
        # Seeded ids: the i-th OPEN carries span id i + 1.
        assert_equal(rec.span_id, UInt64(i + 1), "records in OPEN order")
        assert_equal(rec.status, SPAN_STATUS_CLOSED, "every span is closed")
    return tracer.join_probes()


def test_drain_join_is_linear() raises:
    var p1 = _drain_probes(N1)
    var p2 = _drain_probes(N2)
    print("  probes(N1 =", N1, ") =", p1)
    print("  probes(N2 =", N2, ") =", p2)
    print("  growth =", Float64(p2) / Float64(p1), "(linear ", GROWTH, ", quadratic ", GROWTH * GROWTH, ")")
    # One probe per CLOSE packet, one CLOSE per span.
    assert_equal(p1, N1, "the join probes once per CLOSE at N1")
    assert_equal(p2, N2, "the join probes once per CLOSE at N2")
    assert_equal(p2, GROWTH * p1, "the join's work grows linearly with spans")
    print("  test_drain_join_is_linear PASS")


def main() raises:
    print("test_drain_join_scales")
    print("======================")
    test_drain_join_is_linear()
    print()
    print("ALL TESTS PASS")
