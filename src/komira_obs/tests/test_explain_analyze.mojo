# =============================================================================
# test_explain_analyze.mojo — EXPLAIN ANALYZE unit tests (renderer)
# =============================================================================
#
# EXPLAIN ANALYZE on a multi-operator plan prints per-operator metrics in
# operator order with non-zero values for at least rows_consumed /
# elapsed_compute per operator.
#
# This file exercises the RENDERER in isolation: an ExecutionReport built by
# hand with realistic per-operator MetricsSnapshots is rendered via
# `format_execution_report` and the output is asserted multi-line +
# per-operator non-zero. The END-TO-END capture path through the engine is an
# engine test; keeping the renderer's test here lets it regress fast without
# paying the full pipeline cost.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_obs.metrics_set import (
    MetricsSet,
    MetricsSnapshot,
    METRIC_KIND_COUNTER,
    METRIC_KIND_TIME,
    METRIC_KIND_GAUGE,
)
from komira_obs.name_registry import _fnv1a_compute
from komira_obs.explain_analyze import (
    OperatorMetricsBlock,
    ExecutionReport,
    record_operator_metrics,
    format_metric_value,
    format_operator_block,
    format_execution_report,
)


# -----------------------------------------------------------------------------
# format_metric_value — well-known names + kind formatting
# -----------------------------------------------------------------------------


def test_format_counter_value() raises:
    """Counter renders as `<name>: <int>` with no unit."""
    var name_id = _fnv1a_compute("rows_processed")
    var s = format_metric_value(name_id, METRIC_KIND_COUNTER, Int64(15000))
    assert_equal(s, "rows_processed: 15000")


def test_format_time_value_microseconds() raises:
    """Time < 1ms renders in microseconds."""
    var name_id = _fnv1a_compute("elapsed_compute")
    # 543000 ns = 543 us
    var s = format_metric_value(name_id, METRIC_KIND_TIME, Int64(543000))
    assert_equal(s, "elapsed_compute: 543 us")


def test_format_time_value_milliseconds() raises:
    """Time >= 1ms renders in milliseconds with 3-digit micro fraction."""
    var name_id = _fnv1a_compute("elapsed_compute")
    # 21043000 ns = 21043 us = 21.043 ms
    var s = format_metric_value(name_id, METRIC_KIND_TIME, Int64(21043000))
    assert_equal(s, "elapsed_compute: 21.043 ms")


def test_format_time_value_zero() raises:
    """Zero time renders as '0 us'."""
    var name_id = _fnv1a_compute("elapsed_compute")
    var s = format_metric_value(name_id, METRIC_KIND_TIME, Int64(0))
    assert_equal(s, "elapsed_compute: 0 us")


def test_format_time_value_sub_microsecond() raises:
    """Time below 1us renders as '<1 us'."""
    var name_id = _fnv1a_compute("elapsed_compute")
    var s = format_metric_value(name_id, METRIC_KIND_TIME, Int64(500))
    assert_equal(s, "elapsed_compute: <1 us")


def test_format_unknown_name_id_falls_back_to_hex() raises:
    """Unknown name_id renders with the digest as a diagnostic — never silently
    drops the metric."""
    var fake_id = UInt32(0xDEADBEEF)
    var s = format_metric_value(fake_id, METRIC_KIND_COUNTER, Int64(42))
    # The exact suffix is the int representation of the digest; just assert
    # the format prefix (`name#<digest>: <value>`) is present.
    assert_true(s.startswith("name#"))
    assert_true(s.endswith(": 42"))


# -----------------------------------------------------------------------------
# format_operator_block — single operator's multi-line block
# -----------------------------------------------------------------------------


def test_format_operator_block_with_metrics() raises:
    """Block renders label, 'metrics:' header, and one indented line per
    entry."""
    var snap = MetricsSnapshot()
    _ = snap.append(
        _fnv1a_compute("rows_processed"),
        METRIC_KIND_COUNTER,
        Int64(1500),
    )
    _ = snap.append(
        _fnv1a_compute("elapsed_compute"),
        METRIC_KIND_TIME,
        Int64(2_500_000),
    )
    var block = OperatorMetricsBlock(String("MapOp(2 exprs)"), snap^)
    var rendered = format_operator_block(block)
    # Multi-line: at minimum 4 lines (label, "  metrics:", 2 entries).
    var nl = rendered.count("\n")
    assert_true(nl >= 4)
    assert_true("MapOp(2 exprs)" in rendered)
    assert_true("  metrics:" in rendered)
    assert_true("rows_processed: 1500" in rendered)
    assert_true("elapsed_compute: 2.500 ms" in rendered)


def test_format_operator_block_empty_metrics() raises:
    """Operator with no registered metrics still renders the header — never
    silently empty."""
    var snap = MetricsSnapshot()
    var block = OperatorMetricsBlock(String("ScanParquet"), snap^)
    var rendered = format_operator_block(block)
    assert_true("ScanParquet" in rendered)
    assert_true("(no metrics registered)" in rendered)


# -----------------------------------------------------------------------------
# format_execution_report — multi-operator full report
# -----------------------------------------------------------------------------


def test_format_execution_report_multiple_operators() raises:
    """Multi-operator report renders header + each block in append order.

    The acceptance shape: a join+aggregate report (3 operators) must
    render as multi-line text where rows_processed / elapsed_compute land
    non-zero per operator.
    """
    var report = ExecutionReport()

    # Operator 1: scan-equivalent (rows_processed: 6M)
    var s1 = MetricsSnapshot()
    _ = s1.append(
        _fnv1a_compute("rows_processed"),
        METRIC_KIND_COUNTER,
        Int64(6_001_215),
    )
    _ = s1.append(
        _fnv1a_compute("elapsed_compute"),
        METRIC_KIND_TIME,
        Int64(15_400_000),
    )
    record_operator_metrics(report, String("MapOp(project lineitem cols)"), s1^)

    # Operator 2: join probe (rows_emitted: 1.5M)
    var s2 = MetricsSnapshot()
    _ = s2.append(
        _fnv1a_compute("rows_processed"),
        METRIC_KIND_COUNTER,
        Int64(6_001_215),
    )
    _ = s2.append(
        _fnv1a_compute("rows_emitted"),
        METRIC_KIND_COUNTER,
        Int64(1_500_000),
    )
    _ = s2.append(
        _fnv1a_compute("elapsed_compute"),
        METRIC_KIND_TIME,
        Int64(8_700_000),
    )
    record_operator_metrics(report, String("JoinProbeOp(INNER on l_orderkey)"), s2^)

    # Operator 3: aggregate-shape downstream (smaller volume)
    var s3 = MetricsSnapshot()
    _ = s3.append(
        _fnv1a_compute("rows_processed"),
        METRIC_KIND_COUNTER,
        Int64(1_500_000),
    )
    _ = s3.append(
        _fnv1a_compute("elapsed_compute"),
        METRIC_KIND_TIME,
        Int64(21_043_000),
    )
    record_operator_metrics(report, String("FlatHashAggOp(orderkey, sum(quantity))"), s3^)

    var rendered = format_execution_report(report)
    # Header.
    assert_true("EXPLAIN ANALYZE" in rendered)
    assert_true("===============" in rendered)
    # Each operator label appears.
    assert_true("MapOp(project lineitem cols)" in rendered)
    assert_true("JoinProbeOp(INNER on l_orderkey)" in rendered)
    assert_true("FlatHashAggOp(orderkey, sum(quantity))" in rendered)
    # Per-operator metrics with non-zero values for at least
    # rows_processed / elapsed_compute.
    assert_true("rows_processed: 6001215" in rendered)
    assert_true("rows_emitted: 1500000" in rendered)
    assert_true("rows_processed: 1500000" in rendered)
    # Each elapsed_compute renders >0.
    assert_true("elapsed_compute: 15.400 ms" in rendered)
    assert_true("elapsed_compute: 8.700 ms" in rendered)
    assert_true("elapsed_compute: 21.043 ms" in rendered)


def test_format_execution_report_empty() raises:
    """Empty report renders the diagnostic — never silently empty."""
    var report = ExecutionReport()
    var rendered = format_execution_report(report)
    assert_true("EXPLAIN ANALYZE" in rendered)
    assert_true("(no operator metrics captured)" in rendered)


def test_format_execution_report_preserves_append_order() raises:
    """Operator blocks render in the order they were appended."""
    var report = ExecutionReport()
    var s1 = MetricsSnapshot()
    _ = s1.append(
        _fnv1a_compute("rows_processed"),
        METRIC_KIND_COUNTER, Int64(100),
    )
    var s2 = MetricsSnapshot()
    _ = s2.append(
        _fnv1a_compute("rows_processed"),
        METRIC_KIND_COUNTER, Int64(200),
    )
    record_operator_metrics(report, String("First"), s1^)
    record_operator_metrics(report, String("Second"), s2^)

    var rendered = format_execution_report(report)
    var first_idx = rendered.find("First")
    var second_idx = rendered.find("Second")
    assert_true(first_idx >= 0)
    assert_true(second_idx > first_idx)


# -----------------------------------------------------------------------------
# MetricsSnapshot.merge_sum — used by the executor to combine per-worker
# snapshots before appending to the report. Test in this file because it's
# the renderer's contract.
# -----------------------------------------------------------------------------


def test_merge_sum_combines_counters_and_times() raises:
    """Counter / Time entries with matching (name_id, kind) sum; new entries
    append."""
    var a = MetricsSnapshot()
    _ = a.append(
        _fnv1a_compute("rows_processed"),
        METRIC_KIND_COUNTER,
        Int64(1000),
    )
    _ = a.append(
        _fnv1a_compute("elapsed_compute"),
        METRIC_KIND_TIME,
        Int64(500_000),
    )

    var b = MetricsSnapshot()
    _ = b.append(
        _fnv1a_compute("rows_processed"),
        METRIC_KIND_COUNTER,
        Int64(2500),
    )
    _ = b.append(
        _fnv1a_compute("elapsed_compute"),
        METRIC_KIND_TIME,
        Int64(700_000),
    )
    _ = b.append(
        _fnv1a_compute("rows_emitted"),
        METRIC_KIND_COUNTER,
        Int64(800),
    )

    a.merge_sum(b)

    var rows_processed_id = _fnv1a_compute("rows_processed")
    var elapsed_id = _fnv1a_compute("elapsed_compute")
    var rows_emitted_id = _fnv1a_compute("rows_emitted")

    var rp = a.lookup(rows_processed_id)
    assert_true(rp.__bool__())
    assert_equal(rp.value(), Int64(3500))

    var ec = a.lookup(elapsed_id)
    assert_true(ec.__bool__())
    assert_equal(ec.value(), Int64(1_200_000))

    var re = a.lookup(rows_emitted_id)
    assert_true(re.__bool__())
    assert_equal(re.value(), Int64(800))


def test_merge_sum_gauges_take_max() raises:
    """Gauge entries take the maximum across snapshots (gauge-of-gauges)."""
    var a = MetricsSnapshot()
    _ = a.append(
        _fnv1a_compute("peak_groups_in_flight"),
        METRIC_KIND_GAUGE,
        Int64(100),
    )

    var b = MetricsSnapshot()
    _ = b.append(
        _fnv1a_compute("peak_groups_in_flight"),
        METRIC_KIND_GAUGE,
        Int64(250),
    )

    a.merge_sum(b)
    var v = a.lookup(_fnv1a_compute("peak_groups_in_flight"))
    assert_true(v.__bool__())
    # Gauge takes the MAX, not the sum.
    assert_equal(v.value(), Int64(250))


# -----------------------------------------------------------------------------
# End-to-end: real MetricsSet → reduce() → render
# -----------------------------------------------------------------------------


def test_real_metrics_set_into_report() raises:
    """A real MetricsSet (not a hand-crafted snapshot) reduces and renders.

    Models the in-pipeline access pattern an operator uses today: register
    metrics in __init__, increment per-worker slots in execute(), reduce
    once at EXPLAIN ANALYZE time.
    """
    var ms = MetricsSet()
    _ = ms.register_counter["rows_processed"]()
    _ = ms.register_time["elapsed_compute"]()

    # Simulate per-worker writes from 3 workers.
    ms.counter["rows_processed"]().inc_in_pipeline(Int64(500), worker_id=0)
    ms.counter["rows_processed"]().inc_in_pipeline(Int64(700), worker_id=1)
    ms.counter["rows_processed"]().inc_in_pipeline(Int64(300), worker_id=2)
    ms.time["elapsed_compute"]().record_ns_in_pipeline(
        Int64(1_500_000), worker_id=0
    )
    ms.time["elapsed_compute"]().record_ns_in_pipeline(
        Int64(2_000_000), worker_id=1
    )

    var snap = ms.reduce()
    var report = ExecutionReport()
    record_operator_metrics(report, String("MapOp(test)"), snap^)

    var rendered = format_execution_report(report)
    # Counter sum across 3 workers: 500 + 700 + 300 = 1500.
    assert_true("rows_processed: 1500" in rendered)
    # Time sum across 2 workers: 1.5ms + 2ms = 3.5ms.
    assert_true("elapsed_compute: 3.500 ms" in rendered)


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    test_format_counter_value()
    test_format_time_value_microseconds()
    test_format_time_value_milliseconds()
    test_format_time_value_zero()
    test_format_time_value_sub_microsecond()
    test_format_unknown_name_id_falls_back_to_hex()
    test_format_operator_block_with_metrics()
    test_format_operator_block_empty_metrics()
    test_format_execution_report_multiple_operators()
    test_format_execution_report_empty()
    test_format_execution_report_preserves_append_order()
    test_merge_sum_combines_counters_and_times()
    test_merge_sum_gauges_take_max()
    test_real_metrics_set_into_report()
    print("test_explain_analyze: PASS")
