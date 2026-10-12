# =============================================================================
# test_explain_analyze_collect -- the EXPLAIN ANALYZE slot table and its fold
# =============================================================================
#
# `explain_analyze_collect` keeps one process-global table of per-kind slots
# (calls, rows, wall ns) that the engine's recording seams write through
# `ea_record` and that `build_execution_report` folds into an
# `ExecutionReport`. Before this file no welded test compiled `ea_record`,
# `ea_slot`, `ea_reset`, `build_execution_report` or `ea_kind_name`: only the
# README's example reached some of them, and the engine tests that drive the
# seams are another package's.
#
# - test_record_accumulates_per_kind: two records of one kind sum calls, rows
#   and ns into that kind only; rows 0 and ns <= 0 leave their field alone.
#   Catches a record that writes a neighbouring kind (wrong stride), adds a
#   negative wall, or drops the per-field guards.
# - test_out_of_range_reads_and_writes_are_refused: `ea_slot` answers 0 for a
#   field at or past the stride (which would otherwise read the NEXT kind's
#   calls slot, set non-zero here) and for kinds outside the table; an
#   `ea_record` of a kind outside the table leaves every in-range slot 0.
#   Not caught: dropping `ea_record`'s kind bound. That write lands outside
#   the table, where no reader through this API can see it.
# - test_reset_zeroes_every_kind: after recording every kind, `ea_reset`
#   leaves every field of every kind 0. Catches a reset loop over fewer slots
#   than EA_N_KINDS * EA_SLOT_STRIDE.
# - test_report_folds_fired_kinds_in_reading_order: only fired kinds get a
#   block, in the render order (the join sides under Join, not by id), each
#   label carrying its call count; a zero row count or zero wall is omitted,
#   not rendered as 0; the streaming sink's label says its rows are not
#   measurable.
# - test_every_kind_is_named_and_reported: all EA_N_KINDS kinds fired give
#   EA_N_KINDS blocks whose labels are the kind names in render order, and an
#   id outside the table is named `kind#<n>`.
#
# The table is process-global: every test starts with `ea_reset()` and none
# arms the collector (recording does not need the flag; the seams check it).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false

from komira_metrics.explain_analyze_collect import (
    EA_AGGREGATE,
    EA_ASOF_JOIN,
    EA_CROSS_JOIN,
    EA_DISTINCT,
    EA_F_CALLS,
    EA_F_NS,
    EA_F_ROWS,
    EA_JOIN,
    EA_JOIN_BUILD,
    EA_JOIN_PROBE,
    EA_N_KINDS,
    EA_OTHER_BREAKER,
    EA_PARTITION_TOPN,
    EA_SCAN_LEAF,
    EA_SLOT_STRIDE,
    EA_SORT,
    EA_STREAM_SINK,
    EA_UNION,
    EA_WINDOW,
    build_execution_report,
    ea_armed,
    ea_kind_name,
    ea_record,
    ea_reset,
    ea_slot,
)
from komira_metrics.metrics_set import METRIC_KIND_COUNTER, METRIC_KIND_TIME
from komira_name_registry import name_id as _literal_name_id


comptime _ROWS_EMITTED: UInt32 = _literal_name_id["rows_emitted"]()
comptime _ELAPSED_COMPUTE: UInt32 = _literal_name_id["elapsed_compute"]()


def _assert_all_zero(context: String) raises:
    for kind in range(EA_N_KINDS):
        for field in range(EA_SLOT_STRIDE):
            assert_equal(
                ea_slot(kind, field),
                Int64(0),
                context + ": kind " + String(kind) + " field " + String(field),
            )


def test_record_accumulates_per_kind() raises:
    ea_reset()
    ea_record(EA_SORT, rows=10, elapsed_ns=1_000)
    ea_record(EA_SORT, rows=5, elapsed_ns=250)
    assert_equal(ea_slot(EA_SORT, EA_F_CALLS), Int64(2))
    assert_equal(ea_slot(EA_SORT, EA_F_ROWS), Int64(15))
    assert_equal(ea_slot(EA_SORT, EA_F_NS), Int64(1_250))
    # A row count of 0 and a wall of 0 or below add a call and nothing else.
    ea_record(EA_SORT, rows=0, elapsed_ns=0)
    ea_record(EA_SORT, rows=0, elapsed_ns=-7)
    assert_equal(ea_slot(EA_SORT, EA_F_CALLS), Int64(4))
    assert_equal(ea_slot(EA_SORT, EA_F_ROWS), Int64(15))
    assert_equal(ea_slot(EA_SORT, EA_F_NS), Int64(1_250))
    # No other kind moved: its neighbours by id included.
    for kind in range(EA_N_KINDS):
        if kind == EA_SORT:
            continue
        for field in range(EA_SLOT_STRIDE):
            assert_equal(ea_slot(kind, field), Int64(0), "kind " + String(kind))
    ea_reset()


def test_out_of_range_reads_and_writes_are_refused() raises:
    ea_reset()
    # Kinds outside the table write nothing.
    ea_record(-1, rows=3, elapsed_ns=3)
    ea_record(EA_N_KINDS, rows=3, elapsed_ns=3)
    ea_record(EA_N_KINDS + 5, rows=3, elapsed_ns=3)
    _assert_all_zero("after out-of-range records")
    # The kind after EA_SORT has calls; a field index at the stride would
    # land on exactly that slot if the field bound were not checked.
    ea_record(EA_SORT + 1, rows=9, elapsed_ns=9)
    assert_equal(ea_slot(EA_SORT + 1, EA_F_CALLS), Int64(1))
    assert_equal(ea_slot(EA_SORT, EA_SLOT_STRIDE), Int64(0))
    assert_equal(ea_slot(EA_SORT, EA_SLOT_STRIDE + EA_F_ROWS), Int64(0))
    assert_equal(ea_slot(EA_SORT, -1), Int64(0))
    assert_equal(ea_slot(-1, EA_F_CALLS), Int64(0))
    assert_equal(ea_slot(EA_N_KINDS, EA_F_CALLS), Int64(0))
    ea_reset()


def test_reset_zeroes_every_kind() raises:
    ea_reset()
    for kind in range(EA_N_KINDS):
        ea_record(kind, rows=kind + 1, elapsed_ns=100 * (kind + 1))
    for kind in range(EA_N_KINDS):
        assert_equal(ea_slot(kind, EA_F_CALLS), Int64(1))
        assert_equal(ea_slot(kind, EA_F_ROWS), Int64(kind + 1))
        assert_equal(ea_slot(kind, EA_F_NS), Int64(100 * (kind + 1)))
    ea_reset()
    _assert_all_zero("after ea_reset")
    assert_equal(build_execution_report().count(), 0)


def test_report_folds_fired_kinds_in_reading_order() raises:
    ea_reset()
    # Recorded out of render order on purpose.
    ea_record(EA_JOIN_PROBE, rows=40, elapsed_ns=0)
    ea_record(EA_JOIN, rows=30, elapsed_ns=3_000)
    ea_record(EA_JOIN, rows=12, elapsed_ns=1_000)
    ea_record(EA_SCAN_LEAF, rows=100, elapsed_ns=500)
    ea_record(EA_STREAM_SINK, rows=0, elapsed_ns=700)
    ea_record(EA_JOIN_BUILD, rows=7, elapsed_ns=0)
    var report = build_execution_report()
    assert_equal(report.count(), 5)

    assert_equal(report.blocks[0].label, "ScanLeaf(parquet collect) x1")
    assert_equal(report.blocks[0].snapshot.count(), 2)
    assert_equal(report.blocks[0].snapshot.lookup(_ROWS_EMITTED).value(), 100)
    assert_equal(report.blocks[0].snapshot.lookup(_ELAPSED_COMPUTE).value(), 500)
    assert_equal(report.blocks[0].snapshot.entries[0].kind, METRIC_KIND_COUNTER)
    assert_equal(report.blocks[0].snapshot.entries[1].kind, METRIC_KIND_TIME)

    assert_equal(
        report.blocks[1].label,
        "StreamingSink(morsel driver) x1  (rows not measurable at this driver)",
    )
    assert_equal(report.blocks[1].snapshot.count(), 1)
    assert_false(Bool(report.blocks[1].snapshot.lookup(_ROWS_EMITTED)))
    assert_equal(report.blocks[1].snapshot.lookup(_ELAPSED_COMPUTE).value(), 700)

    assert_equal(report.blocks[2].label, "Join x2")
    assert_equal(report.blocks[2].snapshot.lookup(_ROWS_EMITTED).value(), 42)
    assert_equal(
        report.blocks[2].snapshot.lookup(_ELAPSED_COMPUTE).value(), 4_000
    )

    assert_equal(report.blocks[3].label, "  JoinBuildSide x1")
    assert_equal(report.blocks[3].snapshot.count(), 1)
    assert_equal(report.blocks[3].snapshot.lookup(_ROWS_EMITTED).value(), 7)
    assert_false(Bool(report.blocks[3].snapshot.lookup(_ELAPSED_COMPUTE)))

    assert_equal(report.blocks[4].label, "  JoinProbeSide x1")
    assert_equal(report.blocks[4].snapshot.lookup(_ROWS_EMITTED).value(), 40)
    ea_reset()


def test_every_kind_is_named_and_reported() raises:
    ea_reset()
    for kind in range(EA_N_KINDS):
        ea_record(kind, rows=1, elapsed_ns=1)
    var report = build_execution_report()
    var want = List[String]()
    want.append("ScanLeaf(parquet collect) x1")
    want.append(
        "StreamingSink(morsel driver) x1  (rows not measurable at this driver)"
    )
    want.append("Aggregate x1")
    want.append("Sort x1")
    want.append("Distinct x1")
    want.append("Join x1")
    want.append("  JoinBuildSide x1")
    want.append("  JoinProbeSide x1")
    want.append("CrossJoin x1")
    want.append("Window x1")
    want.append("PartitionTopN x1")
    want.append("AsofJoin x1")
    want.append("Union x1")
    want.append("OtherBreaker x1")
    assert_equal(len(want), EA_N_KINDS)
    assert_equal(report.count(), EA_N_KINDS)
    for i in range(EA_N_KINDS):
        assert_equal(report.blocks[i].label, want[i], "block " + String(i))
    # Each name by id, and the ids the table does not hold.
    assert_equal(ea_kind_name(EA_AGGREGATE), "Aggregate")
    assert_equal(ea_kind_name(EA_DISTINCT), "Distinct")
    assert_equal(ea_kind_name(EA_CROSS_JOIN), "CrossJoin")
    assert_equal(ea_kind_name(EA_WINDOW), "Window")
    assert_equal(ea_kind_name(EA_PARTITION_TOPN), "PartitionTopN")
    assert_equal(ea_kind_name(EA_ASOF_JOIN), "AsofJoin")
    assert_equal(ea_kind_name(EA_UNION), "Union")
    assert_equal(ea_kind_name(EA_OTHER_BREAKER), "OtherBreaker")
    assert_equal(ea_kind_name(EA_N_KINDS), "kind#" + String(EA_N_KINDS))
    assert_equal(ea_kind_name(-1), "kind#-1")
    ea_reset()


def test_collector_left_disarmed() raises:
    """Nothing here arms the collector; the flag is process-global."""
    assert_false(ea_armed())


def main() raises:
    var suite = TestSuite()
    suite.test[test_record_accumulates_per_kind]()
    suite.test[test_out_of_range_reads_and_writes_are_refused]()
    suite.test[test_reset_zeroes_every_kind]()
    suite.test[test_report_folds_fired_kinds_in_reading_order]()
    suite.test[test_every_kind_is_named_and_reported]()
    suite.test[test_collector_left_disarmed]()
    suite^.run()
