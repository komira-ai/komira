# =============================================================================
# test_delete_retained_logs_each_retained_deletion -- the retention override of `deploy_destroy`, over a
#   fake cloud.
#
#   (1) Without `force_delete_data` a teardown KEEPS the RETAIN_KEEP datastore,
#       deletes the RETAIN_DELETE service in front of it, and logs no
#       "deleted retained" line.
#   (2) With it, every retained resource is deleted and named twice: the intent
#       before the delete and the confirmation after.
#   (3) The intent line is logged even when the retained delete then fails.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from kci_deploy import (
    EnvBinding,
    CLOUD_GCP,
    DIRECT_APPLY_ALLOWED,
    CaptureReporter,
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
    RETAIN_KEEP,
    RETAIN_UNDELETABLE,
    CONVERGE_IN_PLACE,
    VERB_NOOP,
)


struct _Cell(Movable):
    var logical_id: String
    var deps: List[String]
    var retention: Int
    var phase: Int
    var fail_delete: Bool

    def __init__(
        out self,
        logical_id: String,
        var deps: List[String],
        retention: Int,
        fail_delete: Bool,
    ):
        self.logical_id = logical_id.copy()
        self.deps = deps^
        self.retention = retention
        self.phase = RES_PRESENT_MATCHED
        self.fail_delete = fail_delete


struct _FakeNode(Resource, Movable, Deinitable):
    var _p: ArcPointer[_Cell]

    def __init__(out self, var share: ArcPointer[_Cell]):
        self._p = share^

    def logical_id(mut self) -> String:
        return self._p[].logical_id

    def depends_on(mut self) -> List[String]:
        return self._p[].deps.copy()

    def retention(mut self) -> Int:
        return self._p[].retention

    def undeletable_reason(mut self) -> String:
        if self._p[].retention == RETAIN_UNDELETABLE:
            return String("fake: this node has no delete capability")
        return String("")

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        if self._p[].phase == RES_ABSENT:
            return ResourceStatus.absent()
        return ResourceStatus.matched(
            String("phys-") + self._p[].logical_id, String("digest")
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(
            self._p[].logical_id, VERB_NOOP, String("noop"), self._p[].retention
        )

    def create(mut self, creds: Creds) raises -> String:
        self._p[].phase = RES_PRESENT_MATCHED
        return String("phys-") + self._p[].logical_id

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        if self._p[].retention == RETAIN_UNDELETABLE:
            raise Error("fake: the engine must never delete an UNDELETABLE node")
        if self._p[].fail_delete:
            raise Error(String("fake: delete of ") + physical_id + " failed")
        self._p[].phase = RES_ABSENT

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE


comptime _SVC: String = "cw-svc"
comptime _DS: String = "cw-datastore"
comptime _NET: String = "cw-network"


struct _World(Movable):

    var svc: ArcPointer[_Cell]
    var ds: ArcPointer[_Cell]
    var net: ArcPointer[_Cell]

    def __init__(out self, ds_fail_delete: Bool):
        self.net = ArcPointer[_Cell](
            _Cell(_NET, List[String](), RETAIN_UNDELETABLE, False)
        )
        var ds_deps = List[String]()
        ds_deps.append(_NET)
        self.ds = ArcPointer[_Cell](
            _Cell(_DS, ds_deps^, RETAIN_KEEP, ds_fail_delete)
        )
        var svc_deps = List[String]()
        svc_deps.append(_DS)
        self.svc = ArcPointer[_Cell](
            _Cell(_SVC, svc_deps^, RETAIN_DELETE, False)
        )

    def graph(self) raises -> ResourceGraph:
        var g = ResourceGraph()
        g.add(ErasedResource.erase(_FakeNode(ArcPointer[_Cell](copy=self.net))))
        g.add(ErasedResource.erase(_FakeNode(ArcPointer[_Cell](copy=self.ds))))
        g.add(ErasedResource.erase(_FakeNode(ArcPointer[_Cell](copy=self.svc))))
        return g^


def _dev_env() -> EnvBinding:
    return EnvBinding(
        String("dev-x"),
        CLOUD_GCP,
        String("dev-proj"),
        String("us-central1"),
        DIRECT_APPLY_ALLOWED,
    )


def _has(r: CaptureReporter, a: String, b: String) -> Bool:
    for i in range(r.line_count()):
        var l = r.line_at(i)
        if l.find(a) >= 0 and l.find(b) >= 0:
            return True
    return False


def test_teardown_without_the_flag_keeps_the_retained_datastore() raises:
    var w = _World(False)
    var g = w.graph()
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    _ = deploy_destroy(g, _dev_env(), Creds.none(), store, reporter)
    assert_equal(w.svc[].phase, RES_ABSENT, "the RETAIN_DELETE service is reaped")
    assert_equal(
        w.ds[].phase,
        RES_PRESENT_MATCHED,
        "the RETAIN_KEEP datastore is STILL STANDING without --delete-retained",
    )
    assert_equal(w.net[].phase, RES_PRESENT_MATCHED, "the network too")
    assert_false(
        reporter.contains(String("RETAINED")),
        "no retained-deletion line is logged when nothing retained is deleted",
    )
    print("  test_teardown_without_the_flag_keeps_the_retained_datastore: PASS")


def test_teardown_with_the_flag_deletes_and_logs_each_retained_resource() raises:
    var w = _World(False)
    var g = w.graph()
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    _ = deploy_destroy(
        g, _dev_env(), Creds.none(), store, reporter, force_delete_data=True
    )
    assert_equal(
        w.ds[].phase, RES_ABSENT, "the RETAIN_KEEP datastore is DELETED"
    )
    assert_equal(w.svc[].phase, RES_ABSENT, "the service is reaped as always")
    assert_equal(
        w.net[].phase,
        RES_PRESENT_MATCHED,
        "RETAIN_UNDELETABLE stays undeletable under --delete-retained",
    )
    assert_true(
        _has(reporter, String("WILL DELETE RETAINED"), String("'") + _DS + "'"),
        "the intent to delete the retained datastore is LOGGED, by name",
    )
    assert_true(
        _has(reporter, String("DELETED RETAINED"), String("'") + _DS + "'"),
        "and its deletion is LOGGED, by name, after the walk",
    )
    assert_false(
        _has(reporter, String("RETAINED"), String("'") + _SVC + "'"),
        "a RETAIN_DELETE node is not a retained resource and is not logged as one",
    )
    assert_false(
        _has(reporter, String("DELETED RETAINED"), String("'") + _NET + "'"),
        "the UNDELETABLE node is never logged as deleted",
    )
    print(
        "  test_teardown_with_the_flag_deletes_and_logs_each_retained_resource:"
        " PASS"
    )


def test_the_intent_is_logged_before_a_failing_retained_delete() raises:
    var w = _World(True)
    var g = w.graph()
    var store = InMemoryStateStore()
    var reporter = CaptureReporter()
    var raised = False
    try:
        _ = deploy_destroy(
            g, _dev_env(), Creds.none(), store, reporter, force_delete_data=True
        )
    except:
        raised = True
    assert_true(raised, "the failing retained delete stops the walk fail-loud")
    assert_true(
        _has(reporter, String("WILL DELETE RETAINED"), String("'") + _DS + "'"),
        "the retained resource this run set out to destroy is already logged",
    )
    assert_false(
        _has(reporter, String("DELETED RETAINED"), String("'") + _DS + "'"),
        "and it is NOT logged as deleted — it is still standing",
    )
    assert_equal(w.ds[].phase, RES_PRESENT_MATCHED, "still standing")
    print("  test_the_intent_is_logged_before_a_failing_retained_delete: PASS")


def main() raises:
    test_teardown_without_the_flag_keeps_the_retained_datastore()
    test_teardown_with_the_flag_deletes_and_logs_each_retained_resource()
    test_the_intent_is_logged_before_a_failing_retained_delete()
    print("test_delete_retained_logs_each_retained_deletion: ALL PASS")
