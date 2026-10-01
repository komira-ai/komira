# =============================================================================
# test_deploy_status_maps_resource_status -- `deploy_status` maps a served node's live status.
#
#   RES_PRESENT_MATCHED                -> DEPLOY_STATUS_HEALTHY
#   RES_PRESENT_DRIFTED / _CONVERGING  -> DEPLOY_STATUS_CONVERGING
#   RES_FAILED                         -> DEPLOY_STATUS_FAILED
#   RES_ABSENT, or no such node        -> DEPLOY_STATUS_NOTFOUND
# carrying `endpoint` and `live_image` through.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from kci_deploy import (
    CaptureReporter,
    deploy_status,
    DeploymentStatus,
    DEPLOY_STATUS_CONVERGING,
    DEPLOY_STATUS_HEALTHY,
    DEPLOY_STATUS_FAILED,
    DEPLOY_STATUS_NOTFOUND,
)

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
    RES_CONVERGING,
    RES_FAILED,
    RETAIN_DELETE,
    CONVERGE_IN_PLACE,
    VERB_NOOP,
)


comptime _ENDPOINT: String = "https://svc-x-uc.a.run.app"
comptime _IMAGE: String = "repo/app@sha256:live"


struct _FakeState(Movable):
    var logical_id: String
    var phase: Int

    def __init__(out self, logical_id: String, phase: Int):
        self.logical_id = logical_id.copy()
        self.phase = phase


struct FakeResource(Resource, Movable, Deinitable):
    var _p: ArcPointer[_FakeState]

    def __init__(out self, logical_id: String, phase: Int):
        self._p = ArcPointer[_FakeState](_FakeState(logical_id.copy(), phase))

    def logical_id(mut self) -> String:
        return self._p[].logical_id

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var ph = self._p[].phase
        if ph == RES_ABSENT:
            return ResourceStatus.absent()
        return ResourceStatus(
            ph,
            String("phys-") + self._p[].logical_id,
            _IMAGE,
            String("scripted"),
            _ENDPOINT,
            _IMAGE,
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


def _graph_with(name: String, phase: Int) raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(ErasedResource.erase(FakeResource(name, phase)))
    return g^


def _status_for(name: String, phase: Int) raises -> DeploymentStatus:
    var g = _graph_with(name, phase)
    var reporter = CaptureReporter()
    return deploy_status(g, name, Creds.none(), reporter)


def test_deploy_status_matched_is_healthy() raises:
    var st = _status_for(String("app-svc"), RES_PRESENT_MATCHED)
    assert_equal(st.phase, DEPLOY_STATUS_HEALTHY, "matched -> HEALTHY")
    assert_equal(st.endpoint, _ENDPOINT, "healthy carries the served endpoint")
    assert_equal(st.live_image, _IMAGE, "healthy carries the live image")


def test_deploy_status_drifted_is_converging() raises:
    var st = _status_for(String("app-svc"), RES_PRESENT_DRIFTED)
    assert_equal(st.phase, DEPLOY_STATUS_CONVERGING, "drifted -> CONVERGING")
    assert_equal(
        st.live_image, _IMAGE, "converging carries the live image through"
    )


def test_deploy_status_converging_is_converging() raises:
    var st = _status_for(String("app-svc"), RES_CONVERGING)
    assert_equal(st.phase, DEPLOY_STATUS_CONVERGING, "converging -> CONVERGING")


def test_deploy_status_failed_is_failed() raises:
    var st = _status_for(String("app-svc"), RES_FAILED)
    assert_equal(st.phase, DEPLOY_STATUS_FAILED, "failed -> FAILED")


def test_deploy_status_absent_is_not_found() raises:
    var st = _status_for(String("app-svc"), RES_ABSENT)
    assert_equal(st.phase, DEPLOY_STATUS_NOTFOUND, "absent -> NOTFOUND")


def test_deploy_status_unknown_name_is_not_found() raises:
    var g = _graph_with(String("app-svc"), RES_PRESENT_MATCHED)
    var reporter = CaptureReporter()
    var st = deploy_status(g, String("no-such-node"), Creds.none(), reporter)
    assert_equal(
        st.phase, DEPLOY_STATUS_NOTFOUND, "an unknown served node -> NOTFOUND"
    )


def main() raises:
    test_deploy_status_matched_is_healthy()
    test_deploy_status_drifted_is_converging()
    test_deploy_status_converging_is_converging()
    test_deploy_status_failed_is_failed()
    test_deploy_status_absent_is_not_found()
    test_deploy_status_unknown_name_is_not_found()
    print(
        "test_deploy_status_maps_resource_status: all status-mapping cases PASSED"
        " (RES_* -> DEPLOY_STATUS_* with endpoint + live_image carried)"
    )
