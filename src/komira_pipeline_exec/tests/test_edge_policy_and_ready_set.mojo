# =============================================================================
# Edge policy, order key policy, plan checks and the ready set
# =============================================================================
#
# What these tests prove:
#
#   * E1, E2 and E3 make a consumer wait for its producer; E5 does not; E4 and a
#     value that is no tag are refused by name.
#   * ORDER_NONE and ORDER_PARTITION_ID are served; ORDER_ROW_RANGE and an
#     unknown kind are refused by name.
#   * The ready set is the unfinished segments whose waited-for dependencies
#     finished, in id order: a chain opens one segment at a time, two
#     independent segments are ready together, a segment behind both waits for
#     both, and an E5 dependency is not waited for.
#   * `check_plan` refuses, with the offending segment named: another IR
#     version, a seg_id that is not the position, edge tags that do not match
#     the dependencies, a dependency outside the plan, a segment depending on
#     itself, an edge tag or order key without a policy, and a dependency cycle.
#     A cycle that runs only through E5 edges is not a cycle, and a diamond is
#     accepted.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_physical_plan.physical_plan import (
    EDGE_E1_MORSEL_STREAM,
    EDGE_E2_INGEST_STREAM,
    EDGE_E3_PUBLISH_WAIT,
    EDGE_E4_PARTITION_WISE,
    EDGE_E5_INDEPENDENT,
    ORDER_NONE,
    ORDER_PARTITION_ID,
    ORDER_ROW_RANGE,
    SegmentDescPod,
)
from komira_pipeline_exec.edge_policy import (
    POLICY_NONE,
    POLICY_WAIT,
    check_order_key,
    edge_policy,
)
from komira_pipeline_exec.fake_builder import fake_desc
from komira_pipeline_exec.plan_check import check_plan, ready_set


def _seg(id: Int, dep: Int = -1, tag: UInt8 = EDGE_E3_PUBLISH_WAIT) -> SegmentDescPod:
    var deps = List[Int]()
    var tags = List[UInt8]()
    if dep >= 0:
        deps.append(dep)
        tags.append(tag)
    return fake_desc(id, deps^, tags^)


def _seg_two(id: Int, a: Int, b: Int) -> SegmentDescPod:
    var deps = List[Int]()
    var tags = List[UInt8]()
    deps.append(a)
    deps.append(b)
    tags.append(EDGE_E3_PUBLISH_WAIT)
    tags.append(EDGE_E3_PUBLISH_WAIT)
    return fake_desc(id, deps^, tags^)


def _expect_refusal(ref descs: List[SegmentDescPod], needle: String) raises:
    try:
        check_plan(descs)
    except e:
        assert_true(needle in String(e), String(e))
        return
    assert_true(False, "check_plan accepted a plan it must refuse: " + needle)


def test_edge_policy_per_tag() raises:
    assert_equal(edge_policy(EDGE_E1_MORSEL_STREAM), POLICY_WAIT)
    assert_equal(edge_policy(EDGE_E2_INGEST_STREAM), POLICY_WAIT)
    assert_equal(edge_policy(EDGE_E3_PUBLISH_WAIT), POLICY_WAIT)
    assert_equal(edge_policy(EDGE_E5_INDEPENDENT), POLICY_NONE)
    try:
        _ = edge_policy(EDGE_E4_PARTITION_WISE)
        assert_true(False, "E4 must be refused")
    except e:
        assert_true("E4_PARTITION_WISE" in String(e), String(e))
    try:
        _ = edge_policy(UInt8(9))
        assert_true(False, "tag 9 must be refused")
    except e:
        assert_true("edge tag 9" in String(e), String(e))


def test_order_key_policy() raises:
    check_order_key(ORDER_NONE)
    check_order_key(ORDER_PARTITION_ID)
    try:
        check_order_key(ORDER_ROW_RANGE)
        assert_true(False, "ORDER_ROW_RANGE must be refused")
    except e:
        assert_true("ORDER_ROW_RANGE" in String(e), String(e))
    try:
        check_order_key(UInt8(7))
        assert_true(False, "kind 7 must be refused")
    except e:
        assert_true("order key kind 7" in String(e), String(e))


def test_ready_set_opens_a_chain_one_segment_at_a_time() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_seg(0))
    descs.append(_seg(1, 0))
    descs.append(_seg(2, 1))
    var fin = List[Bool](length=3, fill=False)
    var r = ready_set(descs, fin)
    assert_equal(len(r), 1)
    assert_equal(r[0], 0)
    fin[0] = True
    r = ready_set(descs, fin)
    assert_equal(len(r), 1)
    assert_equal(r[0], 1)
    fin[1] = True
    r = ready_set(descs, fin)
    assert_equal(len(r), 1)
    assert_equal(r[0], 2)
    fin[2] = True
    assert_equal(len(ready_set(descs, fin)), 0)


def test_ready_set_holds_independent_segments_together() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_seg(0))
    descs.append(_seg(1))
    descs.append(_seg_two(2, 0, 1))
    var fin = List[Bool](length=3, fill=False)
    var r = ready_set(descs, fin)
    assert_equal(len(r), 2)
    assert_equal(r[0], 0)
    assert_equal(r[1], 1)
    fin[1] = True
    r = ready_set(descs, fin)
    assert_equal(len(r), 1)
    assert_equal(r[0], 0)
    fin[0] = True
    r = ready_set(descs, fin)
    assert_equal(len(r), 1)
    assert_equal(r[0], 2)


def test_ready_set_does_not_wait_for_an_independent_edge() raises:
    var descs = List[SegmentDescPod]()
    descs.append(_seg(0, 1, EDGE_E5_INDEPENDENT))
    descs.append(_seg(1))
    var fin = List[Bool](length=2, fill=False)
    var r = ready_set(descs, fin)
    assert_equal(len(r), 2)
    var waiting = List[SegmentDescPod]()
    waiting.append(_seg(0, 1, EDGE_E3_PUBLISH_WAIT))
    waiting.append(_seg(1))
    r = ready_set(waiting, fin)
    assert_equal(len(r), 1)
    assert_equal(r[0], 1)


def test_check_plan_accepts_a_diamond_and_an_independent_cycle() raises:
    var diamond = List[SegmentDescPod]()
    diamond.append(_seg(0))
    diamond.append(_seg(1, 0))
    diamond.append(_seg(2, 0))
    diamond.append(_seg_two(3, 1, 2))
    check_plan(diamond)
    var loop = List[SegmentDescPod]()
    loop.append(_seg(0, 1, EDGE_E5_INDEPENDENT))
    loop.append(_seg(1, 0, EDGE_E5_INDEPENDENT))
    check_plan(loop)
    check_plan(List[SegmentDescPod]())


def test_check_plan_refuses_a_plan_it_cannot_run() raises:
    var wrong_version = List[SegmentDescPod]()
    wrong_version.append(_seg(0))
    wrong_version[0].ir_version = 13
    _expect_refusal(wrong_version, "segment 0 is IR version 13")

    var wrong_id = List[SegmentDescPod]()
    wrong_id.append(_seg(0))
    wrong_id.append(_seg(5))
    _expect_refusal(wrong_id, "segment 1 has seg_id 5")

    var tag_count = List[SegmentDescPod]()
    tag_count.append(_seg(0))
    tag_count.append(_seg(1, 0))
    _ = tag_count[1].edge_tags.pop()
    _expect_refusal(tag_count, "segment 1 has 1 dependencies and 0 edge tags")

    var outside = List[SegmentDescPod]()
    outside.append(_seg(0, 4))
    _expect_refusal(outside, "segment 0 depends on segment 4")

    var one_past = List[SegmentDescPod]()
    one_past.append(_seg(0, 1))
    _expect_refusal(one_past, "segment 0 depends on segment 1, which is not")

    var itself = List[SegmentDescPod]()
    itself.append(_seg(0, 0))
    _expect_refusal(itself, "segment 0 depends on itself")

    var e4 = List[SegmentDescPod]()
    e4.append(_seg(0))
    e4.append(_seg(1, 0, EDGE_E4_PARTITION_WISE))
    _expect_refusal(e4, "E4_PARTITION_WISE")
    _expect_refusal(e4, "segment 1")

    var row_range = List[SegmentDescPod]()
    row_range.append(_seg(0))
    row_range[0].order_key_kind = ORDER_ROW_RANGE
    _expect_refusal(row_range, "ORDER_ROW_RANGE")

    var cycle = List[SegmentDescPod]()
    cycle.append(_seg(0, 1))
    cycle.append(_seg(1, 0))
    cycle.append(_seg(2))
    _expect_refusal(cycle, "dependency cycle; 2 segments can never start")


def main() raises:
    var suite = TestSuite()
    suite.test[test_edge_policy_per_tag]()
    suite.test[test_order_key_policy]()
    suite.test[test_ready_set_opens_a_chain_one_segment_at_a_time]()
    suite.test[test_ready_set_holds_independent_segments_together]()
    suite.test[test_ready_set_does_not_wait_for_an_independent_edge]()
    suite.test[test_check_plan_accepts_a_diamond_and_an_independent_cycle]()
    suite.test[test_check_plan_refuses_a_plan_it_cannot_run]()
    suite^.run()
