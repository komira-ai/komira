# =============================================================================
# tests/test_cov_node_state_metrics_unit.mojo
#   The node's served-partition set with its lease generations, and the
#   sub-lineage rollout signals.
# =============================================================================
#
#   1. BrokerNodeState: a pre-seeded set is sorted and de-duplicated; a
#      reconcile reports exactly the started and stopped partitions, is
#      idempotent, freezes the writer epoch at acquire, raises the current
#      epoch on later heartbeats, never lowers either, and drops the lease of
#      a stopped partition (a re-acquire freezes the new generation).
#   2. SubLineageRolloutMetrics: the width gauge is the larger component, the
#      bound counter moves only past the bound, the fold interval is measured
#      between folds only, and the consume and audit counters add what they
#      are given.
#   3. audit_segment_contiguity: each gap, overlap, tear and column-length
#      mismatch counts.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_broker.broker_node_state import BrokerNodeState, ReconcileDelta
from komira_broker.sublineage_rollout_metrics import (
    BoundStatsView,
    SubLineageRolloutMetrics,
    audit_segment_contiguity,
)


def _u(*xs: Int) -> List[UInt32]:
    var out = List[UInt32]()
    for x in xs:
        out.append(UInt32(x))
    return out^


def _g(*xs: Int) -> List[Int64]:
    var out = List[Int64]()
    for x in xs:
        out.append(Int64(x))
    return out^


def _i(*xs: Int) -> List[Int64]:
    var out = List[Int64]()
    for x in xs:
        out.append(Int64(x))
    return out^


def _eq(got: List[UInt32], want: List[UInt32]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def test_seeded_set_is_canonical() raises:
    var n = BrokerNodeState("n1", _u(5, 1, 3, 1, 5, 2))
    assert_equal(n.node_id(), "n1")
    _eq(n.owned_partitions(), _u(1, 2, 3, 5))
    assert_equal(n.partition_count(), 4)
    assert_true(n.owns(UInt32(3)))
    assert_false(n.owns(UInt32(4)))
    # No generations delivered yet: every epoch reads 0.
    assert_equal(n.writer_lease_epoch_of(UInt32(1)), Int64(0))
    assert_equal(n.current_lease_epoch_of(UInt32(1)), Int64(0))
    # Re-applying the seeded set (unsorted, with a duplicate) changes nothing.
    var d = n.apply_assignment(_u(3, 2, 1, 5, 3))
    assert_true(d.is_empty())
    assert_equal(d.change_count(), 0)


def test_reconcile_delta_and_epochs() raises:
    var n = BrokerNodeState("n2")
    assert_equal(n.partition_count(), 0)
    var d1 = n.apply_assignment(_u(4, 2), _g(7, 3))
    _eq(d1.started, _u(2, 4))
    assert_equal(len(d1.stopped), 0)
    assert_equal(d1.change_count(), 2)
    assert_false(d1.is_empty())
    # The writer epoch freezes at acquire; current == writer.
    assert_equal(n.writer_lease_epoch_of(UInt32(4)), Int64(7))
    assert_equal(n.current_lease_epoch_of(UInt32(4)), Int64(7))
    assert_equal(n.lease_generation_of(UInt32(2)), Int64(3))
    # A bump while still owned raises current only.
    var d2 = n.apply_assignment(_u(2, 4), _g(3, 9))
    assert_true(d2.is_empty())
    assert_equal(n.writer_lease_epoch_of(UInt32(4)), Int64(7))
    assert_equal(n.current_lease_epoch_of(UInt32(4)), Int64(9))
    # A stale heartbeat never lowers current; a missing generation reads 0
    # and lowers nothing either.
    _ = n.apply_assignment(_u(2, 4), _g(1))
    assert_equal(n.current_lease_epoch_of(UInt32(4)), Int64(9))
    assert_equal(n.current_lease_epoch_of(UInt32(2)), Int64(3))
    assert_equal(n.writer_lease_epoch_of(UInt32(2)), Int64(3))
    # A duplicate pid in the assignment keeps the FIRST generation.
    _ = n.apply_assignment(_u(2, 2, 4), _g(5, 99, 9))
    assert_equal(n.current_lease_epoch_of(UInt32(2)), Int64(5))
    # Stop 2, start 6: the stopped lease is dropped.
    var d3 = n.apply_assignment(_u(6, 4), _g(1, 9))
    _eq(d3.started, _u(6))
    _eq(d3.stopped, _u(2))
    assert_equal(d3.change_count(), 2)
    assert_equal(n.writer_lease_epoch_of(UInt32(2)), Int64(0))
    assert_equal(n.current_lease_epoch_of(UInt32(2)), Int64(0))
    assert_false(n.owns(UInt32(2)))
    # Re-acquire 2 at a new generation: the writer epoch is the new one.
    _ = n.apply_assignment(_u(2, 4, 6), _g(11, 9, 1))
    assert_equal(n.writer_lease_epoch_of(UInt32(2)), Int64(11))
    assert_equal(n.current_lease_epoch_of(UInt32(2)), Int64(11))
    # Everything stops.
    var d4 = n.apply_assignment(_u())
    _eq(d4.stopped, _u(2, 4, 6))
    assert_equal(n.partition_count(), 0)
    assert_equal(n.current_lease_epoch_of(UInt32(4)), Int64(0))


def test_rollout_metrics_signals(mut m: SubLineageRolloutMetrics) raises:
    assert_equal(m.fold_count(), Int64(0))
    var calm = BoundStatsView(2, 3, 4)
    assert_equal(calm.width(), 3)
    assert_false(calm.exceeds_bound())
    var tail_wide = BoundStatsView(6, 1, 4)
    assert_equal(tail_wide.width(), 6)
    assert_true(tail_wide.exceeds_bound())
    var shard_wide = BoundStatsView(1, 5, 4)
    assert_true(shard_wide.exceeds_bound())
    # First fold: no interval yet.
    m.record_fold(calm, Int64(1_000_000_000))
    assert_equal(m.live_lineage_width(), Int64(3))
    assert_equal(m.l_exceeds_bound_count(), Int64(0))
    assert_equal(m.last_fold_interval_ms(), Int64(0))
    assert_equal(m.fold_count(), Int64(1))
    # Second fold 2.5 s later, past the bound.
    m.record_fold(tail_wide, Int64(3_500_000_000))
    assert_equal(m.last_fold_interval_ms(), Int64(2500))
    assert_equal(m.l_exceeds_bound_count(), Int64(1))
    assert_equal(m.live_lineage_width(), Int64(6))
    # A clock that went backwards leaves the interval as it was.
    m.record_fold(calm, Int64(3_000_000_000))
    assert_equal(m.last_fold_interval_ms(), Int64(2500))
    assert_equal(m.fold_count(), Int64(3))
    # Consume width: gauge and bound counter, never the fold count.
    m.record_consume_width(shard_wide)
    assert_equal(m.live_lineage_width(), Int64(5))
    assert_equal(m.l_exceeds_bound_count(), Int64(2))
    m.record_consume_width(calm)
    assert_equal(m.live_lineage_width(), Int64(3))
    assert_equal(m.l_exceeds_bound_count(), Int64(2))
    assert_equal(m.fold_count(), Int64(3))
    # Audit: a clean walk counts once, violations add their count.
    m.record_contiguity_audit(0)
    m.record_contiguity_audit(3)
    m.record_contiguity_audit(0)
    assert_equal(m.contiguity_clean_runs(), Int64(2))
    assert_equal(m.contiguity_violations(), Int64(3))
    # Consume: records add, EOS counts only when reached.
    m.record_consume(10, False)
    m.record_consume(0, True)
    m.record_consume(4, True)
    assert_equal(m.consume_records_count(), Int64(14))
    assert_equal(m.consume_eos_count(), Int64(2))
    _ = m.snapshot()


def test_audit_segment_contiguity() raises:
    assert_equal(audit_segment_contiguity(_i(), _i()), 0)
    assert_equal(audit_segment_contiguity(_i(0), _i()), 1)
    # A survivor range starting above 0 is still contiguous.
    assert_equal(audit_segment_contiguity(_i(10, 13, 15), _i(3, 2, 1)), 0)
    # A gap (13 -> 14), then contiguous from the new base.
    assert_equal(audit_segment_contiguity(_i(10, 14, 16), _i(3, 2, 1)), 1)
    # An overlap (12 < 13).
    assert_equal(audit_segment_contiguity(_i(10, 12, 14), _i(3, 2, 1)), 1)
    # A tear (0 records) at the end counts once.
    assert_equal(audit_segment_contiguity(_i(10, 13), _i(3, 0)), 1)
    # A negative count is a tear too.
    assert_equal(audit_segment_contiguity(_i(10), _i(-1)), 1)


def main() raises:
    # The metrics set is built before anything else allocates: building one
    # in a reused heap block hangs (komira-ai/komira#1072).
    var m = SubLineageRolloutMetrics()
    test_seeded_set_is_canonical()
    test_reconcile_delta_and_epochs()
    test_rollout_metrics_signals(m)
    test_audit_segment_contiguity()
    print("[OK] test_cov_node_state_metrics_unit")
