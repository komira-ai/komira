# =============================================================================
# test_converge_names_every_drifted_served_node -- the multi-service converge report.
#
# A required-present served node reading DRIFTED is not settled. When a
# multi-service deploy times out that way, `poll_until_converged` must name
# EVERY service that is not serving the applied image, each with the image it
# IS serving, so the operator does not pay a full deploy per stale service to
# find the next one. A settled graph names no drift.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from kci_deploy import CaptureReporter, PollBudget, poll_until_converged

from kci_iac import (
    Creds,
    ResourceGraph,
    ErasedResource,
    ResourceStatus,
    ChangeAction,
    Resource,
    RES_ABSENT,
    RES_PRESENT_MATCHED,
    RES_PRESENT_DRIFTED,
    RETAIN_DELETE,
    CONVERGE_IN_PLACE,
    VERB_NOOP,
)


struct _FakeState(Movable):
    var logical_id: String
    var phase: Int
    var live_image: String

    def __init__(out self, logical_id: String, phase: Int, live_image: String):
        self.logical_id = logical_id.copy()
        self.phase = phase
        self.live_image = live_image.copy()


struct _FakeServed(Resource, Movable, Deinitable):

    var _p: ArcPointer[_FakeState]

    def __init__(out self, logical_id: String, phase: Int, live_image: String):
        self._p = ArcPointer[_FakeState](
            _FakeState(logical_id.copy(), phase, live_image.copy())
        )

    def logical_id(mut self) -> String:
        return self._p[].logical_id

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        if self._p[].phase == RES_ABSENT:
            return ResourceStatus.absent()
        return ResourceStatus(
            self._p[].phase,
            String("phys-") + self._p[].logical_id,
            self._p[].live_image,
            String("scripted"),
            String("https://") + self._p[].logical_id + String(".a.run.app"),
            self._p[].live_image,
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(
            self._p[].logical_id, VERB_NOOP, String("noop"), RETAIN_DELETE
        )

    def create(mut self, creds: Creds) raises -> String:
        return String("phys-") + self._p[].logical_id

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE


comptime _A_STALE: String = "repo/a@sha256:prior-a"
comptime _B_LIVE: String = "repo/b@sha256:applied-b"
comptime _C_STALE: String = "repo/c@sha256:prior-c"


def _three_served() raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(
        ErasedResource.erase(
            _FakeServed(String("a-svc"), RES_PRESENT_DRIFTED, String(_A_STALE))
        )
    )
    g.add(
        ErasedResource.erase(
            _FakeServed(String("b-svc"), RES_PRESENT_MATCHED, String(_B_LIVE))
        )
    )
    g.add(
        ErasedResource.erase(
            _FakeServed(String("c-svc"), RES_PRESENT_DRIFTED, String(_C_STALE))
        )
    )
    return g^


def _all_required() -> List[String]:
    var r = List[String]()
    r.append(String("a-svc"))
    r.append(String("b-svc"))
    r.append(String("c-svc"))
    return r^


def test_every_drifted_served_node_is_named_with_its_live_image() raises:
    var g = _three_served()
    var reporter = CaptureReporter()
    var out = poll_until_converged[CaptureReporter](
        g, Creds(String("t")), PollBudget(1, 0), reporter, _all_required()
    )
    assert_false(out.converged, "two served nodes serve a prior image")
    assert_false(out.failed, "DRIFTED is a converge timeout, not a resource fault")
    assert_equal(len(out.drifted_nodes), 2, "BOTH drifted served nodes are named")
    assert_equal(out.drifted_nodes[0], String("a-svc"))
    assert_equal(out.drifted_nodes[1], String("c-svc"))
    assert_equal(len(out.drifted_images), 2, "one live image per drifted node")
    assert_equal(out.drifted_images[0], String(_A_STALE))
    assert_equal(out.drifted_images[1], String(_C_STALE))
    assert_equal(out.drifted_node, String("a-svc"))
    var report = out.drift_report()
    assert_true(report.find(String("a-svc")) >= 0, "report names a-svc")
    assert_true(report.find(String("c-svc")) >= 0, "report names c-svc")
    assert_true(report.find(String(_A_STALE)) >= 0, "report states a's live image")
    assert_true(report.find(String(_C_STALE)) >= 0, "report states c's live image")
    assert_true(report.find(String("b-svc")) < 0, "the MATCHED node is not named")
    print("  test_every_drifted_served_node_is_named_with_its_live_image: PASS")


def test_a_settled_graph_names_no_drift() raises:
    var g = ResourceGraph()
    g.add(
        ErasedResource.erase(
            _FakeServed(String("b-svc"), RES_PRESENT_MATCHED, String(_B_LIVE))
        )
    )
    var req = List[String]()
    req.append(String("b-svc"))
    var reporter = CaptureReporter()
    var out = poll_until_converged[CaptureReporter](
        g, Creds(String("t")), PollBudget(1, 0), reporter, req
    )
    assert_true(out.converged, "a matched served node settles")
    assert_equal(len(out.drifted_nodes), 0, "nothing drifted")
    assert_equal(out.drift_report(), String(""), "an empty drift report")
    print("  test_a_settled_graph_names_no_drift: PASS")


def main() raises:
    test_every_drifted_served_node_is_named_with_its_live_image()
    test_a_settled_graph_names_no_drift()
    print("test_converge_names_every_drifted_served_node: 2 passed")
