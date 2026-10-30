# =============================================================================
# The scheduler over fake segments
# =============================================================================
#
# What these tests prove:
#
#   * Segments start in dependency order, lowest id first among the ready ones:
#     a diamond (0; 1 and 2 behind 0; 3 behind 1 and 2) starts 0, 1, 2, 3.
#   * A dependency on an independent edge is not waited for: a segment whose only
#     dependency is a later segment over E5 starts first, and over E3 starts
#     after it. The order is the same on every run.
#   * A segment's output reaches its dependent: a producer of twelve rows read
#     back in chunks of five by a counting consumer gives twelve. The producer's
#     output is taken by the consumer, so only the output no one took is
#     returned, by segment id.
#   * Two independent roots both return their outputs.
#   * A segment that fails ends the run: segments behind it and segments with a
#     later id that were ready do not start, and the error is the failing
#     segment's.
#   * A plan with an edge the driver has no policy for is refused before any
#     segment is built.
#   * A token cancelled before the run starts no segment.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async_api.token import CancellationToken
from komira_physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    EDGE_E4_PARTITION_WISE,
    EDGE_E5_INDEPENDENT,
    SegmentDescPod,
)
from komira_pipeline_exec.fake_builder import (
    FROM_CURSOR,
    FROM_DEP,
    TO_COUNT,
    FakeBuilder,
    FakeScript,
    fake_desc,
)
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.fake_support import (
    SLOT_COMBINES,
    SLOT_CONSUMED_MORSELS,
    SLOT_CONSUMED_ROWS,
    SLOT_CURSOR,
    batch_values,
)
from komira_pipeline_exec.run_plan import run_plan


def _desc(id: Int, dep: Int = -1, tag: UInt8 = EDGE_E3_PUBLISH_WAIT) -> SegmentDescPod:
    var deps = List[Int]()
    var tags = List[UInt8]()
    if dep >= 0:
        deps.append(dep)
        tags.append(tag)
    return fake_desc(id, deps^, tags^)


def _desc_two(id: Int, a: Int, b: Int) -> SegmentDescPod:
    var deps = List[Int]()
    var tags = List[UInt8]()
    deps.append(a)
    deps.append(b)
    tags.append(EDGE_E3_PUBLISH_WAIT)
    tags.append(EDGE_E3_PUBLISH_WAIT)
    return fake_desc(id, deps^, tags^)


def _order_is(b: FakeBuilder, want: List[Int]) raises:
    assert_equal(len(b.built_order), len(want))
    for i in range(len(want)):
        assert_equal(b.built_order[i], want[i])


def test_a_diamond_starts_in_dependency_order() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_desc(0))
    descs.append(_desc(1, 0))
    descs.append(_desc(2, 0))
    descs.append(_desc_two(3, 1, 2))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=4, rows=3))
    _ = b.add(FakeScript(FROM_DEP, rows=5, dep=0, to_kind=TO_COUNT))
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=2, rows=1))
    var d = InlineDispatch()
    var token = CancellationToken.new()
    _ = run_plan(descs, b, d, 2, token)
    _order_is(b, [0, 1, 2, 3])


def test_an_independent_edge_is_not_waited_for() raises:
    var free = List[SegmentDescPod]()
    free.append(_desc(0, 1, EDGE_E5_INDEPENDENT))
    free.append(_desc(1))
    var b1 = FakeBuilder()
    _ = b1.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    _ = b1.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    var d1 = InlineDispatch()
    _ = run_plan(free, b1, d1, 2, CancellationToken.new())
    _order_is(b1, [0, 1])

    var waits = List[SegmentDescPod]()
    waits.append(_desc(0, 1, EDGE_E3_PUBLISH_WAIT))
    waits.append(_desc(1))
    var b2 = FakeBuilder()
    _ = b2.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    _ = b2.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    var d2 = InlineDispatch()
    _ = run_plan(waits, b2, d2, 2, CancellationToken.new())
    _order_is(b2, [1, 0])


def test_a_segments_output_reaches_its_dependent() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_desc(0))
    descs.append(_desc(1, 0))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=4, rows=3))
    _ = b.add(FakeScript(FROM_DEP, rows=5, dep=0, to_kind=TO_COUNT))
    var d = InlineDispatch()
    var out = run_plan(descs, b, d, 3, CancellationToken.new())
    assert_false(out.has(0))
    assert_true(out.has(1))
    var counted = batch_values(out.take(1))
    assert_equal(len(counted), 1)
    assert_equal(counted[0], Int64(12))
    # The consumer read the producer's rows in chunks of five: 5, 5, 2.
    assert_equal(b.tally(1).get(SLOT_CONSUMED_MORSELS), 3)
    assert_equal(b.tally(1).get(SLOT_CONSUMED_ROWS), 12)
    assert_equal(b.tally(1).get(SLOT_COMBINES), 1)


def test_independent_roots_both_return_their_outputs() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_desc(0))
    descs.append(_desc(1))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=2, rows=2))
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=3, rows=1))
    var d = InlineDispatch()
    var out = run_plan(descs, b, d, 2, CancellationToken.new())
    assert_equal(len(batch_values(out.take(0))), 4)
    assert_equal(len(batch_values(out.take(1))), 3)
    assert_false(out.has(0))
    try:
        _ = out.take(0)
        assert_true(False, "an output taken twice must be refused")
    except e:
        assert_true("no output of segment 0" in String(e), String(e))


def test_a_failing_segment_ends_the_run() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_desc(0))
    descs.append(_desc(1, 0))
    descs.append(_desc(2))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=4, rows=2, fail_at_claim=1))
    _ = b.add(FakeScript(FROM_DEP, rows=5, dep=0, to_kind=TO_COUNT))
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    var d = InlineDispatch()
    try:
        _ = run_plan(descs, b, d, 2, CancellationToken.new())
        assert_true(False, "the plan must fail")
    except e:
        assert_true("fake source failed at claim 1" in String(e), String(e))
    _order_is(b, [0])
    assert_equal(b.tally(1).get(SLOT_CURSOR), 0)
    assert_equal(b.tally(2).get(SLOT_CURSOR), 0)


def test_a_plan_with_no_policy_for_an_edge_builds_nothing() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_desc(0))
    descs.append(_desc(1, 0, EDGE_E4_PARTITION_WISE))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    var d = InlineDispatch()
    try:
        _ = run_plan(descs, b, d, 2, CancellationToken.new())
        assert_true(False, "the plan must be refused")
    except e:
        assert_true("E4_PARTITION_WISE" in String(e), String(e))
    _order_is(b, List[Int]())


def test_a_token_cancelled_before_the_run_starts_no_segment() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_desc(0))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    var token = CancellationToken.new()
    token.cancel(String("stop"))
    var d = InlineDispatch()
    try:
        _ = run_plan(descs, b, d, 2, token)
        assert_true(False, "the plan must be cancelled")
    except e:
        assert_true("the query was cancelled: stop" in String(e), String(e))
    _order_is(b, List[Int]())


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_diamond_starts_in_dependency_order]()
    suite.test[test_an_independent_edge_is_not_waited_for]()
    suite.test[test_a_segments_output_reaches_its_dependent]()
    suite.test[test_independent_roots_both_return_their_outputs]()
    suite.test[test_a_failing_segment_ends_the_run]()
    suite.test[test_a_plan_with_no_policy_for_an_edge_builds_nothing]()
    suite.test[test_a_token_cancelled_before_the_run_starts_no_segment]()
    suite^.run()
