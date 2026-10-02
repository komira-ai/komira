# =============================================================================
# test_tracer_basic.mojo — Tracer single-threaded correctness + determinism
# =============================================================================
#
# Uses the determinism harness (MockClock + deterministic seeded counters
# via install_mock_ids + CapturingExporter).
#
# This file contributes a focused subset; related coverage is in
# `komira_name_registry`'s and `komira_spsc_ring`'s tests and
# `test_span_record_pod.mojo`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_trace.tracer import Tracer
from komira_trace.testing import MockClock, MockIdGenerator
from komira_trace.exporter import CapturingExporter
from komira_name_registry import name_id as _literal_name_id
from komira_trace.span_record import SPAN_FLAG_ROOT, SPAN_STATUS_CLOSED, SPAN_STATUS_OPEN


def test_construct() raises:
    """Constructing a Tracer with one worker leaves rings empty."""
    var t = Tracer(num_workers=1)
    assert_equal(t.depth_of(0), Int(0), "stack depth 0 initially")
    assert_equal(t.current_span(0), UInt64(0), "current_span = 0 initially")
    assert_equal(t.ring_size(0), Int64(0), "ring empty initially")
    print("  test_construct PASS")


def test_start_span_emits_open_record() raises:
    """start_span pushes onto the worker stack and into the ring."""
    var t = Tracer(num_workers=1)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(100))

    var sid = t.start_span["engine.segment.execute"](worker_id=0)
    assert_equal(sid, UInt64(100), "span_id from seeded counter")
    assert_equal(t.depth_of(0), Int(1), "stack depth 1 after start")
    assert_equal(t.current_span(0), UInt64(100), "current_span = sid")
    assert_equal(t.ring_size(0), Int64(1), "one record on ring")
    print("  test_start_span_emits_open_record PASS")


def test_start_end_balanced() raises:
    """start_span + end_span returns the stack to depth 0 and emits two records."""
    var t = Tracer(num_workers=1)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var sid = t.start_span["seg"](worker_id=0)
    t.end_span(span_id=sid, worker_id=0)
    assert_equal(t.depth_of(0), Int(0), "stack back to 0 after end")
    assert_equal(t.ring_size(0), Int64(2), "two records: open + close")
    print("  test_start_end_balanced PASS")


def test_nested_spans() raises:
    """Nested start/end_span maintains LIFO depth invariants."""
    var t = Tracer(num_workers=1)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(10))
    var s1 = t.start_span["outer"](worker_id=0)
    assert_equal(t.depth_of(0), Int(1), "depth 1 after outer")
    var s2 = t.start_span["inner"](worker_id=0, parent_id=s1)
    assert_equal(t.depth_of(0), Int(2), "depth 2 after inner")
    t.end_span(span_id=s2, worker_id=0)
    assert_equal(t.depth_of(0), Int(1), "depth 1 after inner end")
    t.end_span(span_id=s1, worker_id=0)
    assert_equal(t.depth_of(0), Int(0), "depth 0 after outer end")
    print("  test_nested_spans PASS")


def test_mock_clock_drives_start_ns() raises:
    """MockClock injection: start_ns reflects the mock time."""
    var t = Tracer(num_workers=1)
    var clock = MockClock(start_ns=UInt64(5_000_000))
    t.install_mock_clock(clock)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    var sid = t.start_span["test"](worker_id=0)
    var exp = CapturingExporter()
    t.drain_into_capture(exp)
    ref first = exp.captured_spans[0]
    assert_equal(first.start_ns, UInt64(5_000_000), "start_ns from MockClock")
    assert_equal(first.span_id, UInt64(1), "span_id from seeded counter")
    _ = sid
    print("  test_mock_clock_drives_start_ns PASS")


def test_name_registry_populated_on_first_emit() raises:
    """First emit of a name registers it in the per-process registry."""
    var t = Tracer(num_workers=1)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    assert_equal(t.name_registry_count(), Int(0), "registry empty initially")
    var _sid = t.start_span["operator.flat_hash_agg"](worker_id=0)
    assert_equal(t.name_registry_count(), Int(1), "one name registered")
    # Second emit of same name does NOT increment.
    var _sid2 = t.start_span["operator.flat_hash_agg"](worker_id=0)
    assert_equal(t.name_registry_count(), Int(1), "still one name")
    print("  test_name_registry_populated_on_first_emit PASS")


def test_root_flag_set_on_zero_parent() raises:
    """Span with parent_id=0 carries SPAN_FLAG_ROOT."""
    var t = Tracer(num_workers=1)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var _sid = t.start_span["root"](worker_id=0)
    var exp = CapturingExporter()
    t.drain_into_capture(exp)
    ref rec = exp.captured_spans[0]
    assert_true(rec.is_root(), "root flag set when parent_id == 0")
    print("  test_root_flag_set_on_zero_parent PASS")


def test_explicit_parent_id_clears_root_flag() raises:
    """Span with non-zero parent_id does NOT carry ROOT flag."""
    var t = Tracer(num_workers=1)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var _sid = t.start_span["child"](worker_id=0, parent_id=UInt64(99))
    var exp = CapturingExporter()
    t.drain_into_capture(exp)
    ref rec = exp.captured_spans[0]
    assert_false(rec.is_root(), "root flag cleared for parented span")
    assert_equal(rec.parent_id, UInt64(99), "parent_id propagated")
    print("  test_explicit_parent_id_clears_root_flag PASS")


def test_drain_collects_all_records() raises:
    """drain_into_capture pulls every record across every worker ring.

    Packet split: two distinct spans → 2 SpanRecords (the
    drain joins each OPEN+CLOSE packet pair into one record).
    """
    var t = Tracer(num_workers=2)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var s0 = t.start_span["w0"](worker_id=0)
    t.end_span(s0, worker_id=0)
    var s1 = t.start_span["w1"](worker_id=1)
    t.end_span(s1, worker_id=1)

    var exp = CapturingExporter()
    t.drain_into_capture(exp)
    assert_equal(exp.count(), Int(2),
                 "drain collects 2 records (one per span_id, OPEN+CLOSE joined)")
    print("  test_drain_collects_all_records PASS")


def test_capturing_exporter_clear() raises:
    """CapturingExporter.clear resets the capture list."""
    var exp = CapturingExporter()
    var t = Tracer(num_workers=1)
    var _s = t.start_span["x"](worker_id=0)
    t.drain_into_capture(exp)
    assert_true(exp.count() >= 1, "captured at least one")
    exp.clear()
    assert_equal(exp.count(), Int(0), "after clear count = 0")
    print("  test_capturing_exporter_clear PASS")


def main() raises:
    print("test_tracer_basic")
    print("=================")
    test_construct()
    test_start_span_emits_open_record()
    test_start_end_balanced()
    test_nested_spans()
    test_mock_clock_drives_start_ns()
    test_name_registry_populated_on_first_emit()
    test_root_flag_set_on_zero_parent()
    test_explicit_parent_id_clears_root_flag()
    test_drain_collects_all_records()
    test_capturing_exporter_clear()
    print()
    print("ALL TESTS PASS")
