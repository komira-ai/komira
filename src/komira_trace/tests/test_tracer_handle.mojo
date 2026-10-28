# =============================================================================
# test_tracer_handle.mojo — TracerHandle, the engine-side gate
# =============================================================================
#
# A disabled handle forwards nothing to the tracer (no ring traffic, span id 0);
# an enabled one forwards `start_span`, `end_span` and `current_span`.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_trace.tracer import Tracer
from komira_trace.tracer_handle import TracerHandle


def test_disabled_handle_is_a_no_op() raises:
    """A disabled handle returns span id 0 and puts nothing on the ring."""
    var t = Tracer(num_workers=1)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(100))
    var h = TracerHandle[origin_of(t)].disabled(t)
    assert_false(h.enabled(), "disabled handle reports disabled")
    var sid = h.start_span["seg"](worker_id=0)
    assert_equal(sid, UInt64(0), "no span id from a disabled handle")
    assert_equal(h.current_span(0), UInt64(0), "no current span")
    h.end_span(sid, worker_id=0)
    assert_equal(t.ring_size(0), Int64(0), "ring untouched")
    assert_equal(t.depth_of(0), 0, "stack untouched")
    print("  test_disabled_handle_is_a_no_op PASS")


def test_enabled_handle_forwards_to_the_tracer() raises:
    """An enabled handle opens and closes spans on the tracer it borrows."""
    var t = Tracer(num_workers=1)
    t.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(100))
    var h = TracerHandle[origin_of(t)].borrow(t)
    assert_true(h.enabled(), "borrowed handle reports enabled")
    var outer = h.start_span["outer"](worker_id=0)
    assert_equal(outer, UInt64(100), "span id from the seeded counter")
    assert_equal(h.current_span(0), outer, "current span is the open one")
    var inner = h.start_span["inner"](worker_id=0, parent_id=outer)
    assert_equal(inner, UInt64(101), "next span id")
    h.end_span(inner, worker_id=0)
    h.end_span(outer, worker_id=0)
    assert_equal(h.current_span(0), UInt64(0), "no span open after both end")
    assert_equal(t.ring_size(0), Int64(4), "two OPEN and two CLOSE packets")
    print("  test_enabled_handle_forwards_to_the_tracer PASS")


def main() raises:
    print("test_tracer_handle")
    print("==================")
    test_disabled_handle_is_a_no_op()
    test_enabled_handle_forwards_to_the_tracer()
    print()
    print("ALL TESTS PASS")
