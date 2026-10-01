# =============================================================================
# test_deploy_rollback_fail_loud_edges -- the fail-loud edges of `deploy_rollback`.
#
#   1. an empty `prior_digest` raises (a first deploy has nothing to restore);
#   2. `prior_digest == current_digest` raises (no rollback of a rollback);
#   3. otherwise the governed re-apply runs, threading `pipeline_run`.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_raises

from kci_deploy import (
    EnvBinding,
    CLOUD_GCP,
    DIRECT_APPLY_ALLOWED,
    DIRECT_APPLY_PIPELINE_ONLY,
    CaptureReporter,
    deploy_rollback,
)

from kci_iac import (
    Creds,
    ResourceGraph,
    ErasedResource,
    ResourceStatus,
    ChangeAction,
    InMemoryStateStore,
    Resource,
    RES_ABSENT,
    RES_PRESENT_MATCHED,
    RES_PRESENT_DRIFTED,
    RETAIN_DELETE,
    CONVERGE_IN_PLACE,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
)


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
        if self._p[].phase == RES_ABSENT:
            return ResourceStatus.absent()
        if self._p[].phase == RES_PRESENT_MATCHED:
            return ResourceStatus.matched(
                String("phys-") + self._p[].logical_id, String("digest-live")
            )
        return ResourceStatus.drifted(
            String("phys-") + self._p[].logical_id, String("digest-old")
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        if live.is_absent():
            return ChangeAction(
                self._p[].logical_id, VERB_CREATE, String("create"), RETAIN_DELETE
            )
        if live.is_matched():
            return ChangeAction(
                self._p[].logical_id, VERB_NOOP, String("noop"), RETAIN_DELETE
            )
        return ChangeAction(
            self._p[].logical_id, VERB_UPDATE, String("update"), RETAIN_DELETE
        )

    def create(mut self, creds: Creds) raises -> String:
        self._p[].phase = RES_PRESENT_MATCHED
        return String("phys-") + self._p[].logical_id

    def update(mut self, creds: Creds) raises:
        self._p[].phase = RES_PRESENT_MATCHED

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._p[].phase = RES_ABSENT

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE


def _allowed_env() -> EnvBinding:
    return EnvBinding(
        String("dev"),
        CLOUD_GCP,
        String("dev-proj"),
        String("us-central1"),
        DIRECT_APPLY_ALLOWED,
    )


def _graph(phase: Int) raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(ErasedResource.erase(FakeResource(String("app-svc"), phase)))
    return g^


def test_deploy_rollback_no_prior_raises() raises:
    var g = _graph(RES_PRESENT_DRIFTED)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    with assert_raises():
        _ = deploy_rollback(
            g,
            String(""),
            String("sha256:current"),
            _allowed_env(),
            Creds.none(),
            store,
            reporter,
        )


def test_deploy_rollback_prior_equals_current_raises() raises:
    var g = _graph(RES_PRESENT_DRIFTED)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    with assert_raises():
        _ = deploy_rollback(
            g,
            String("sha256:same"),
            String("sha256:same"),
            _allowed_env(),
            Creds.none(),
            store,
            reporter,
        )


def test_deploy_rollback_rewrites_and_reapplies() raises:
    var g = _graph(RES_PRESENT_DRIFTED)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    var outcome = deploy_rollback(
        g,
        String("sha256:prior"),
        String("sha256:current"),
        _allowed_env(),
        Creds.none(),
        store,
        reporter,
    )
    assert_equal(outcome.node_count(), 1, "rollback re-applied the single node")
    assert_equal(
        outcome.updated_count(), 1, "the drifted node converged via an UPDATE"
    )


def test_deploy_rollback_threads_pipeline_run() raises:
    var g = _graph(RES_PRESENT_DRIFTED)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    var pipeline_only = EnvBinding(
        String("staging"),
        CLOUD_GCP,
        String("customer-proj"),
        String("us-central1"),
        DIRECT_APPLY_PIPELINE_ONLY,
    )
    var outcome = deploy_rollback(
        g,
        String("sha256:prior"),
        String("sha256:current"),
        pipeline_only,
        Creds.none(),
        store,
        reporter,
        pipeline_run=True,
    )
    assert_equal(
        outcome.updated_count(),
        1,
        "pipeline_run=True authorizes the rollback re-apply against PIPELINE_ONLY",
    )


def test_deploy_rollback_pipeline_only_refused_without_pipeline_run() raises:
    var g = _graph(RES_PRESENT_DRIFTED)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    var pipeline_only = EnvBinding(
        String("staging"),
        CLOUD_GCP,
        String("customer-proj"),
        String("us-central1"),
        DIRECT_APPLY_PIPELINE_ONLY,
    )
    with assert_raises():
        _ = deploy_rollback(
            g,
            String("sha256:prior"),
            String("sha256:current"),
            pipeline_only,
            Creds.none(),
            store,
            reporter,
        )


def main() raises:
    test_deploy_rollback_no_prior_raises()
    test_deploy_rollback_prior_equals_current_raises()
    test_deploy_rollback_rewrites_and_reapplies()
    test_deploy_rollback_threads_pipeline_run()
    test_deploy_rollback_pipeline_only_refused_without_pipeline_run()
    print(
        "test_deploy_rollback_fail_loud_edges: all rollback edge cases PASSED (empty"
        " prior / prior==current raise; distinct prior re-applies; pipeline_run"
        " threaded)"
    )
