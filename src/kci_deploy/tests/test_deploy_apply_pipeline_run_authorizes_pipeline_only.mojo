# =============================================================================
# test_deploy_apply_pipeline_run_authorizes_pipeline_only -- the pipeline-run authorization of the governance gate.
#
# `pipeline_run=True` authorizes a pipeline-driven apply or destroy against a
# PIPELINE_ONLY environment, while a direct apply or destroy of the same
# environment stays refused, and an ALLOWED environment is unaffected.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_raises

from kci_deploy import (
    EnvBinding,
    CLOUD_GCP,
    DIRECT_APPLY_ALLOWED,
    DIRECT_APPLY_PIPELINE_ONLY,
    CaptureReporter,
    deploy_apply,
    deploy_destroy,
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

    def __init__(out self, *, var _share: ArcPointer[_FakeState]):
        self._p = _share^

    def share(self) -> FakeResource:
        return FakeResource(_share=ArcPointer[_FakeState](copy=self._p))

    def logical_id(mut self) -> String:
        return self._p[].logical_id

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        if self._p[].phase == RES_ABSENT:
            return ResourceStatus.absent()
        return ResourceStatus.matched(
            String("phys-") + self._p[].logical_id, String("digest-live")
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        if live.is_absent():
            return ChangeAction(
                self._p[].logical_id,
                VERB_CREATE,
                String("absent -> create"),
                RETAIN_DELETE,
            )
        return ChangeAction(
            self._p[].logical_id,
            VERB_NOOP,
            String("matched -> noop"),
            RETAIN_DELETE,
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


def _pipeline_only_env() -> EnvBinding:
    return EnvBinding(
        String("staging"),
        CLOUD_GCP,
        String("customer-proj"),
        String("us-central1"),
        DIRECT_APPLY_PIPELINE_ONLY,
    )


def _one_node_graph(phase: Int) raises -> ResourceGraph:
    var g = ResourceGraph()
    g.add(ErasedResource.erase(FakeResource(String("app-svc"), phase)))
    return g^


def test_deploy_apply_pipeline_run_authorizes_pipeline_only() raises:
    var g = _one_node_graph(RES_ABSENT)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    var outcome = deploy_apply(
        g,
        _pipeline_only_env(),
        Creds.none(),
        store,
        reporter,
        pipeline_run=True,
    )
    assert_equal(outcome.node_count(), 1, "pipeline_run apply reconciled the node")
    assert_equal(
        outcome.created_count(), 1, "the absent node was CREATED (apply proceeded)"
    )


def test_deploy_apply_direct_still_refused_on_pipeline_only() raises:
    var g = _one_node_graph(RES_ABSENT)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    with assert_raises():
        _ = deploy_apply(
            g,
            _pipeline_only_env(),
            Creds.none(),
            store,
            reporter,
            pipeline_run=False,
        )


def test_deploy_destroy_pipeline_run_authorizes_pipeline_only() raises:
    var g = _one_node_graph(RES_PRESENT_MATCHED)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    var outcome = deploy_destroy(
        g,
        _pipeline_only_env(),
        Creds.none(),
        store,
        reporter,
        pipeline_run=True,
    )
    assert_equal(
        outcome.node_count, 1, "pipeline_run destroy reverse-walked the node"
    )


def test_deploy_destroy_direct_still_refused_on_pipeline_only() raises:
    var g = _one_node_graph(RES_PRESENT_MATCHED)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    with assert_raises():
        _ = deploy_destroy(
            g,
            _pipeline_only_env(),
            Creds.none(),
            store,
            reporter,
            pipeline_run=False,
        )


def test_deploy_apply_allowed_env_unaffected() raises:
    var g = _one_node_graph(RES_ABSENT)
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    var allowed = EnvBinding(
        String("dev-adi"),
        CLOUD_GCP,
        String("dev-proj"),
        String("us-central1"),
        DIRECT_APPLY_ALLOWED,
    )
    var outcome = deploy_apply(
        g, allowed, Creds.none(), store, reporter, pipeline_run=False
    )
    assert_equal(
        outcome.created_count(),
        1,
        "an ALLOWED env applies on the CLI default (pipeline_run=False)",
    )


def main() raises:
    test_deploy_apply_pipeline_run_authorizes_pipeline_only()
    test_deploy_apply_direct_still_refused_on_pipeline_only()
    test_deploy_destroy_pipeline_run_authorizes_pipeline_only()
    test_deploy_destroy_direct_still_refused_on_pipeline_only()
    test_deploy_apply_allowed_env_unaffected()
    print(
        "test_deploy_apply_pipeline_run_authorizes_pipeline_only: all"
        " governance cases PASSED (pipeline_run authorizes PIPELINE_ONLY;"
        " CLI gate preserved)"
    )
