# =============================================================================
# test_cloud_validate_and_deploy.mojo
# =============================================================================
#
# Over a stub cloud defined here (the reference clouds live in
# kci_cloud_mem; this package must be testable without them):
#
# 1. GRAPH FINDINGS, every one collected in one pass: duplicate and malformed
#    ids, a missing type, refs to missing resources, an output the producer
#    does not expose, a named output, a self reference, an unresolved release
#    parameter, an unresolved build output, an access verb not accepted.
# 2. COVERAGE: a type the chosen cloud does not host is refused with its
#    typed absence and the built-in clouds that host it.
# 3. REFUSE BEFORE LOWER: a refused graph never reaches the adapter's
#    `lower`, so nothing can be created; plan, apply and destroy alike.
# 4. THE LOWERING CONTRACT is enforced on every run: a node whose id or owner
#    does not name its resource is refused.
# 5. A plan groups under the authored resources.
# 6. A cloud that is not built in is a wiring defect, raised, not a finding.
# 7. THE V1.3 GRAPH RULES: the id grammar, the image platform (OS + CPU),
#    `env` of a job checked like a service's, `env` and `secret_env` never
#    setting one variable twice, a secret reference with a name.
# 8. A PARTIAL APPLY IS REPORTED, NOT RAISED: what landed and what is pending
#    come back with the error.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import decode_json
from kci_reconciler import (
    ChangeAction,
    Creds,
    ErasedResource,
    InMemoryStateStore,
    Resource as EngineResource,
    ResourceGraph,
    ResourceStatus,
    RES_ABSENT,
    RETAIN_DELETE,
    VERB_CREATE,
    VERB_NOOP,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    CloudAdapter,
    Absence,
    Catalog,
    Finding,
    CloudId,
    Clouds,
    NOT_YET,
    FINDING_GRAPH,
    FINDING_COVERAGE,
    FINDING_LIMIT,
    FIELD_SERVICE,
    FIELD_JOB,
    apply_resources,
    body_field,
    describe,
    destroy_resources,
    graph_findings,
    group_plan,
    plan_resources,
    refusal_text,
    validate_for,
)


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _all_text(findings: List[Finding]) -> String:
    var s = String("")
    for i in range(len(findings)):
        s += findings[i].resource_id + String("|") + findings[i].field_path
        s += String("|") + findings[i].reason + String("\n")
    return s^


# ---- the stub cloud ----------------------------------------------------------


struct _Log(Movable):
    var lowered: List[String]
    var created: List[String]

    def __init__(out self):
        self.lowered = List[String]()
        self.created = List[String]()


struct _Node(EngineResource, Movable, Deinitable):
    var _log: ArcPointer[_Log]
    var _id: String
    var _owner: String
    var _fail_create: Bool

    def __init__(
        out self,
        log: ArcPointer[_Log],
        id: String,
        owner: String,
        fail_create: Bool = False,
    ):
        self._log = log.copy()
        self._id = id
        self._owner = owner
        self._fail_create = fail_create

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        for i in range(len(self._log[].created)):
            if self._log[].created[i] == self._id:
                return ResourceStatus.matched(self._id, String("d"))
        return ResourceStatus.absent()

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var verb = VERB_NOOP
        if live.phase == RES_ABSENT:
            verb = VERB_CREATE
        return ChangeAction(self._id.copy(), verb, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        if self._fail_create:
            raise Error(String("stub: create refused for ") + self._id)
        self._log[].created.append(self._id)
        return self._id.copy()

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1

    def owner(mut self) -> String:
        return self._owner.copy()


struct _Stub(CloudAdapter, Movable):
    """Hosts `service` (and `job` when `full`); refuses port 1 as a limit;
    lowers each resource to `<id>/run` and, for a service, `<id>/edge`."""

    var _id: String
    var _full: Bool
    var _bad_owner: Bool
    var _fail_create: String
    var log: ArcPointer[_Log]

    def __init__(
        out self,
        id: String,
        full: Bool,
        bad_owner: Bool = False,
        fail_create: String = String(""),
    ):
        self._id = id
        self._full = full
        self._bad_owner = bad_owner
        self._fail_create = fail_create
        self.log = ArcPointer[_Log](_Log())

    def cloud_id(self) -> CloudId:
        return CloudId(self._id)

    def complete(self) -> Bool:
        return self._full

    def implemented(self) -> List[Int]:
        var l = List[Int]()
        l.append(FIELD_SERVICE)
        if self._full:
            l.append(FIELD_JOB)
        return l^

    def absences(self) -> List[Absence]:
        var l = List[Absence]()
        if not self._full:
            l.append(Absence(FIELD_JOB, NOT_YET, String("no runner for jobs")))
        return l^

    def check(self, r: Resource) -> List[Finding]:
        var l = List[Finding]()
        if r._oneof0_case == 1 and r.service.value().port == 1:
            l.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("service.port"),
                    String("port 1 is reserved here"),
                    String("stub limits"),
                    True,
                )
            )
        return l^

    def lower(mut self, r: Resource, mut graph: ResourceGraph) raises:
        self.log[].lowered.append(r.id)
        var owner = r.id.copy()
        if self._bad_owner:
            owner = String("someone-else")
        var run_id = r.id + String("/run")
        graph.add(
            ErasedResource.erase(
                _Node(self.log, run_id, owner, fail_create=run_id == self._fail_create)
            )
        )
        if r._oneof0_case == 1:
            graph.add(ErasedResource.erase(_Node(self.log, r.id + String("/edge"), r.id)))


def _clouds(var lite: _Stub, var full: _Stub) raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(lite))
    reg.add(describe(full))
    return reg^


def _img() -> String:
    return String('"image":{"digest":"sha256:0011"}')


def _good() -> String:
    var IMG = _img()
    return (
        String('{"resource":[')
        + String('{"id":"api","service":{')
        + IMG
        + String(',"port":8080,"public":{}},')
        + String('"uses":[{"target":{"resource":"batch"},"access":"CALL"}]},')
        + String('{"id":"batch","job":{')
        + IMG
        + String(',"onDemand":{}}}')
        + String("]}")
    )


# ---- 1. graph findings --------------------------------------------------------------


def test_every_graph_finding_in_one_pass() raises:
    var IMG = _img()
    var json = (
        String('{"resource":[')
        # a service with a missing ref, a non-exposed output, a named output,
        # a self ref, an unresolved parameter, an empty value
        + String('{"id":"api","service":{')
        + IMG
        + String(',"port":8080,"env":{')
        + String('"A":{"ref":{"resource":"nope","standard":"URL"}},')
        + String('"B":{"ref":{"resource":"batch","standard":"URL"}},')
        + String('"C":{"ref":{"resource":"web","named":"x"}},')
        + String('"D":{"ref":{"resource":"api","standard":"URL"}},')
        + String('"E":{"param":"region"},')
        + String('"F":{}')
        + String("}},")
        + String('"uses":[{"target":{"resource":"ghost"},"access":"CALL"},')
        + String('{"target":{"resource":"web"}},')
        + String('{"target":{"resource":"web","standard":"URL"},"access":"CALL"}]},')
        # a job whose image is an unresolved build output
        + String('{"id":"batch","job":{"image":{"output":{"step":"b","name":"img"}},"onDemand":{}}},')
        + String('{"id":"web","service":{') + IMG + String("}},")
        # a duplicate id, a slash id, and no type
        + String('{"id":"web","service":{') + IMG + String("}},")
        + String('{"id":"a/b","service":{') + IMG + String("}},")
        + String('{"id":"empty"}')
        + String("]}")
    )
    var f = graph_findings(Catalog.v1(), _list(json))
    var t = _all_text(f)
    for want in [
        'api|service.env.A|ref to missing resource "nope"',
        'api|service.env.B|"batch" (job) does not expose URL',
        "api|service.env.C|a named output is only for the escape hatch",
        "api|service.env.D|refers to its own resource",
        'api|service.env.E|release parameter "region" is unresolved',
        "api|service.env.F|has no value",
        'api|uses[0]|ref to missing resource "ghost"',
        'api|uses[1]|service "web" does not accept access ACCESS_UNSET',
        "api|uses[2]|access is granted to a resource, not to one of its outputs",
        "batch|job.image|the image is a build output that was not resolved",
        "web|id|duplicate id",
        "a/b|id|an id is lowercase letters, digits and '-' only",
        "empty|body|resource 'empty' has no type",
    ]:
        assert_true(_has(t, String(want)), String("missing: ") + String(want) + "\n" + t)
    assert_equal(len(f), 13, "exactly the findings above, each once:\n" + t)
    for i in range(len(f)):
        assert_equal(f[i].kind, FINDING_GRAPH)
    assert_equal(len(graph_findings(Catalog.v1(), _list(_good()))), 0, "a good graph is clean")
    print("  test_every_graph_finding_in_one_pass: PASS")


# ---- 2 + 3. coverage, limits, and refusing before lowering -------------------------


def test_coverage_and_limits_refuse_before_lowering() raises:
    var lite = _Stub(String("lite"), False)
    var reg = _clouds(lite^, _Stub(String("full"), True))
    var cloud = _Stub(String("lite"), False)
    var bad = _good().replace('"port":8080', '"port":1')
    var resources = _list(bad)

    var f = validate_for(reg, cloud, resources)
    assert_equal(len(f), 2, _all_text(f))
    var text = refusal_text(cloud.cloud_id(), f)
    assert_true(
        _has(text, 'kci: cannot apply this graph to cloud "lite". Nothing was created.'),
        text,
    )
    assert_true(
        _has(
            text,
            'resource "batch": job (PORTABLE): no adapter in cloud "lite"'
            " (NOT_YET: no runner for jobs)",
        ),
        text,
    )
    assert_true(_has(text, "clouds built into this kci that implement it: full"), text)
    assert_true(
        _has(
            text,
            'resource "api" field service.port: port 1 is reserved here'
            " (citation: stub limits) [unverified]",
        ),
        text,
    )

    var creds = Creds.none()
    var store = InMemoryStateStore()
    for verb in range(3):
        var raised = False
        try:
            if verb == 0:
                _ = plan_resources(reg, cloud, resources, creds)
            elif verb == 1:
                _ = apply_resources(reg, cloud, resources, creds, store)
            else:
                _ = destroy_resources(reg, cloud, resources, creds, store)
        except e:
            raised = True
            assert_true(_has(String(e), "Nothing was created."), String(e))
        assert_true(raised, String("verb ") + String(verb) + " refused")
    assert_equal(len(cloud.log[].lowered), 0, "a refused graph is never lowered")
    assert_equal(len(cloud.log[].created), 0, "and nothing is created")

    # The same file on the full cloud applies.
    var full = _Stub(String("full"), True)
    var outcome = apply_resources(reg, full, _list(_good()), creds, store)
    assert_true(outcome.ok(), "the full cloud applies")
    assert_equal(len(outcome.applied), 3)
    assert_equal(len(outcome.landed), 3, "on success landed is every node")
    assert_equal(len(outcome.pending), 0)
    assert_equal(len(full.log[].created), 3)
    print("  test_coverage_and_limits_refuse_before_lowering: PASS")


# ---- 4. the lowering contract ----------------------------------------------------------


def test_the_lowering_contract_is_enforced() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Stub(String("full"), True)))
    var cheat = _Stub(String("full"), True, bad_owner=True)
    var raised = False
    try:
        _ = plan_resources(reg, cheat, _list(_good()), Creds.none())
    except e:
        raised = True
        assert_true(_has(String(e), "broke the lowering contract"), String(e))
        assert_true(_has(String(e), 'node "api/run" has owner "someone-else"'), String(e))
    assert_true(raised, "a node not owned by its resource is refused")
    print("  test_the_lowering_contract_is_enforced: PASS")


# ---- 5 + 6. plan grouping; an unregistered cloud ------------------------------------


def test_plan_groups_by_resource_and_unregistered_raises() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Stub(String("full"), True)))
    var full = _Stub(String("full"), True)
    var plan = plan_resources(reg, full, _list(_good()), Creds.none())
    var grouped = group_plan(plan)
    assert_equal(grouped, "api: create api/run, create api/edge\nbatch: create batch/run")

    var stray = _Stub(String("stray"), True)
    var raised = False
    try:
        _ = validate_for(reg, stray, _list(_good()))
    except e:
        raised = True
        assert_true(
            _has(String(e), 'kci: "stray" is not a cloud built into this kci (built in: full)'),
            String(e),
        )
    assert_true(raised)
    print("  test_plan_groups_by_resource_and_unregistered_raises: PASS")


# ---- 7. the v1.3 graph rules ---------------------------------------------------------


def test_id_grammar_platform_and_secret_rules() raises:
    var IMG = _img()
    var json = (
        String('{"resource":[')
        # ids: uppercase, a doubled dash, a trailing dash, a digit first,
        # an underscore, and one byte too long
        + String('{"id":"Api","service":{') + IMG + String("}},")
        + String('{"id":"a--b","service":{') + IMG + String("}},")
        + String('{"id":"tail-","service":{') + IMG + String("}},")
        + String('{"id":"9lives","service":{') + IMG + String("}},")
        + String('{"id":"snake_case","service":{') + IMG + String("}},")
        + String('{"id":"abcdefghijklmnopqrstuvwxy","service":{') + IMG + String("}},")
        # legal at the edges: 24 bytes, single dashes, digits
        + String('{"id":"a-1-b-2-c-3-d-4-e-5-f-6","service":{') + IMG + String("}},")
        # an image of a platform v1 does not deploy, and one that says so explicitly
        + String('{"id":"mac","service":{"image":{"digest":"sha256:01","platform":"darwin/arm64"}}},')
        + String('{"id":"ok-plat","job":{"image":{"digest":"sha256:02","platform":"linux/amd64"},"onDemand":{}}},')
        # a service and a job that set one variable by env AND by secret_env,
        # a secret with no name, and a job env that is unresolved or dangling
        + String('{"id":"svc","service":{') + IMG
        + String(',"env":{"DB":{"literal":"x"}},')
        + String('"secretEnv":{"DB":{"name":"db"},"EMPTY":{}}}},')
        + String('{"id":"cron","job":{') + IMG
        + String(',"env":{"REGION":{"param":"region"},"API":{"ref":{"resource":"ghost","standard":"URL"}},')
        + String('"TOKEN":{"literal":"t"}},')
        + String('"secretEnv":{"TOKEN":{"name":"tok"}},"onDemand":{}}}')
        + String("]}")
    )
    var f = graph_findings(Catalog.v1(), _list(json))
    var t = _all_text(f)
    for want in [
        "Api|id|an id starts with a lowercase letter (a-z)",
        "a--b|id|an id may not contain '--'",
        "tail-|id|an id may not end with '-'",
        "9lives|id|an id starts with a lowercase letter (a-z)",
        "snake_case|id|an id is lowercase letters, digits and '-' only",
        "abcdefghijklmnopqrstuvwxy|id|id is 25 bytes; at most 24",
        'mac|service.image.platform|platform "darwin/arm64" is not deployable: v1 deploys linux/amd64 only',
        "svc|service.secret_env.DB|the variable is set by env and by secret_env; set it in one",
        "svc|service.secret_env.EMPTY|a secret reference with no name",
        'cron|job.env.REGION|release parameter "region" is unresolved',
        'cron|job.env.API|ref to missing resource "ghost"',
        "cron|job.secret_env.TOKEN|the variable is set by env and by secret_env; set it in one",
    ]:
        assert_true(_has(t, String(want)), String("missing: ") + String(want) + "\n" + t)
    assert_equal(len(f), 12, "exactly the findings above, each once:\n" + t)
    assert_false(_has(t, "a-1-b-2-c-3-d-4-e-5-f-6|"), "a 24-byte id is legal:\n" + t)
    assert_false(_has(t, "ok-plat|"), "linux/amd64 written out is legal:\n" + t)
    print("  test_id_grammar_platform_and_secret_rules: PASS")


# ---- 8. a partial apply is reported ---------------------------------------------------


def test_a_partial_apply_reports_landed_and_pending() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Stub(String("full"), True)))
    # `batch/run` cannot be created. The stub's nodes have no dependencies,
    # so the engine applies them in lowering order: api/run, api/edge, then
    # batch/run, which fails after the first two landed.
    var IMG = _img()
    var json = (
        String('{"resource":[')
        + String('{"id":"api","service":{') + IMG + String(',"port":8080}},')
        + String('{"id":"batch","job":{') + IMG + String(',"onDemand":{}}}')
        + String("]}")
    )
    var cloud = _Stub(String("full"), True, fail_create=String("batch/run"))
    var store = InMemoryStateStore()
    var outcome = apply_resources(reg, cloud, _list(json), Creds.none(), store)
    assert_false(outcome.ok(), "the apply failed")
    assert_true(outcome.partial(), "and some of it landed")
    assert_true(_has(outcome.error.value(), "stub: create refused for batch/run"), outcome.error.value())
    assert_equal(len(outcome.applied), 0, "nothing is reported as applied")
    assert_equal(len(outcome.landed), 2, "api/run and api/edge landed")
    assert_equal(outcome.landed[0].logical_id, "api/run")
    assert_equal(outcome.landed[1].logical_id, "api/edge")
    assert_equal(len(outcome.pending), 1)
    assert_equal(outcome.pending[0], "batch/run", "the failing node is pending, first")
    assert_equal(len(cloud.log[].created), 2, "what landed is live")
    print("  test_a_partial_apply_reports_landed_and_pending: PASS")


def main() raises:
    print("test_cloud_validate_and_deploy")
    test_every_graph_finding_in_one_pass()
    test_coverage_and_limits_refuse_before_lowering()
    test_the_lowering_contract_is_enforced()
    test_plan_groups_by_resource_and_unregistered_raises()
    test_id_grammar_platform_and_secret_rules()
    test_a_partial_apply_reports_landed_and_pending()
    print("ALL kci_cloud VALIDATE AND DEPLOY TESTS PASSED")
