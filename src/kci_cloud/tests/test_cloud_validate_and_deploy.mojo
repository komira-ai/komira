# =============================================================================
# test_cloud_validate_and_deploy.mojo
# =============================================================================
#
# Over a stub cloud defined here (the fake clouds live in
# kci_cloud_fake; this package must be testable without them):
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
# 7. THE V1.3 GRAPH RULES: the id grammar, the image platform (OS + CPU,
#    `<os>/<cpu>` in the graph; deployable or not by the cloud's
#    `required_artifact`),
#    `env` of a container job checked like a service's, `env` and `secret_env` never
#    setting one variable twice, a secret reference with a name.
# 8. A PARTIAL APPLY IS REPORTED, NOT RAISED: what landed and what is pending
#    come back with the error.
# 9. LOWERING IS DATA: a golden JSON of a lowering, made before any engine
#    node exists.
# 10. THE CELL IS CONFIGURED FIRST: an unknown setting or value refuses the
#    whole graph; a public service in a cell whose settings choose no public
#    mechanism is refused at validate time; an unowned context is refused.
# 11. THE REST OF THE ADAPTER INTERFACE: bootstrap resources, whoami, the
#    trust pair, the artifact a resource needs, list_owned, and the standard
#    label rule (encoded exactly, refused rather than rewritten).
# 12. and 13. (the label rule's `/` and depth-N ids) are in
#    test_cloud_label_role_encoding.mojo.
# 14. THE ROLE LABEL BUDGET IS CHECKED BEFORE APPLY: a lowered node whose
#    encoded role is over 63 bytes refuses the whole graph with a GRAPH
#    finding naming the node, its byte count and its segment lengths, before
#    any node is realized or created; a 63-byte role is applied.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import decode_json
from kci_reconciler import (
    CellScope,
    ChangeAction,
    Creds,
    ErasedResource,
    InMemoryStateStore,
    InputRef,
    Label,
    OwnerStamp,
    Provenance,
    Resource as EngineResource,
    ResourceGraph,
    ResourceStatus,
    RES_ABSENT,
    RETAIN_DELETE,
    VERB_CREATE,
    VERB_DELETE,
    VERB_NOOP,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    RegistryLogin,
    GrantEdge,
    CloudAdapter,
    Absence,
    ArtifactNeed,
    BootstrapItem,
    Catalog,
    CellContext,
    Finding,
    LoweredNode,
    OwnedRecord,
    ExistingObject,
    Principal,
    RUN_UNKNOWN,
    Setting,
    FINDING_CELL,
    decode_label_value,
    encode_label_value,
    label_problems,
    lower_data,
    lowering_json,
    role_budget_findings,
    standard_identity_of,
    standard_label_rule,
    CloudId,
    Clouds,
    NOT_YET,
    FINDING_GRAPH,
    FINDING_COVERAGE,
    FINDING_LIMIT,
    FIELD_SERVICE,
    FIELD_CONTAINER_JOB,
    FIELD_WORKER,
    FIELD_TABLE,
    FIELD_BUCKET,
    FIELD_SERVICE_ACCOUNT, FIELD_NETWORK, FIELD_SUBNET, FIELD_IP_ADDRESS, FIELD_REGISTRY,
    FIELD_GRANT, FIELD_QUEUE, FIELD_TOPIC, FIELD_SUBSCRIPTION, FIELD_SECRET, Feed, Firing,
    FIELD_DNS_ZONE, FIELD_DNS_RECORD, FIELD_CERTIFICATE, FIELD_SCHEDULE, FIELD_EVENT_TRIGGER,
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
    var realized: List[String]
    var created: List[String]
    var stamps: List[String]

    def __init__(out self):
        self.realized = List[String]()
        self.created = List[String]()
        self.stamps = List[String]()

    def find(self, id: String) -> Int:
        for i in range(len(self.created)):
            if self.created[i] == id:
                return i
        return -1


struct _Node(EngineResource, Movable, Deinitable):
    var _log: ArcPointer[_Log]
    var _id: String
    var _owner: String
    var _fail_create: Bool
    var _retention: Int

    def __init__(
        out self,
        log: ArcPointer[_Log],
        id: String,
        owner: String,
        fail_create: Bool = False,
        retention: Int = RETAIN_DELETE,
    ):
        self._log = log.copy()
        self._id = id
        self._owner = owner
        self._fail_create = fail_create
        self._retention = retention

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return self._retention

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var i = self._log[].find(self._id)
        if i >= 0:
            return ResourceStatus.matched(
                self._id, String("d"), String(""), String(""), self._log[].stamps[i]
            )
        return ResourceStatus.absent()

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var verb = VERB_NOOP
        if live.phase == RES_ABSENT:
            verb = VERB_CREATE
        return ChangeAction(self._id.copy(), verb, String(""), RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        raise Error(String("stub: an unstamped create"))

    def stamps_ownership(mut self) -> Bool:
        return True

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        # A real adapter writes the labels in the create call; so does this.
        _ = standard_label_rule(stamp)
        if self._fail_create:
            raise Error(String("stub: create refused for ") + self._id)
        self._log[].created.append(self._id)
        self._log[].stamps.append(stamp.identity())
        return self._id.copy()

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        var i = self._log[].find(self._id)
        if i >= 0:
            _ = self._log[].created.pop(i)
            _ = self._log[].stamps.pop(i)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1

    def owner(mut self) -> String:
        return self._owner.copy()


struct _Stub(CloudAdapter, Movable):
    """Hosts `service` (and every other type when `full`); refuses port 1
    as a limit; lowers each resource to `<id>/run` (a bucket to
    `<id>/bucket`) and, for a service, `<id>/edge`;
    with `extra_role` set, also `<id>/<extra_role>` for every resource.
    Takes one setting, `public_mechanism` (`edge` or `none`, default
    `edge`), and trusts the principal `deployer` only."""

    var _id: String
    var _full: Bool
    var _bad_owner: Bool
    var _fail_create: String
    var _extra_role: String
    var _mechanism: String
    var log: ArcPointer[_Log]

    def __init__(
        out self,
        id: String,
        full: Bool,
        bad_owner: Bool = False,
        fail_create: String = String(""),
        extra_role: String = String(""),
    ):
        self._id = id
        self._full = full
        self._bad_owner = bad_owner
        self._fail_create = fail_create
        self._extra_role = extra_role
        self._mechanism = String("edge")
        self.log = ArcPointer[_Log](_Log())

    def cloud_id(self) -> CloudId:
        return CloudId(self._id)

    def complete(self) -> Bool:
        return self._full

    def implemented(self) -> List[Int]:
        var l = List[Int]()
        l.append(FIELD_SERVICE)
        if self._full:
            for f in [FIELD_CONTAINER_JOB, FIELD_WORKER, FIELD_TABLE, FIELD_BUCKET, FIELD_QUEUE, FIELD_SERVICE_ACCOUNT]:
                l.append(f)
            l.append(FIELD_TOPIC)
            l.append(FIELD_GRANT)
            l.append(FIELD_SUBSCRIPTION)
            l.append(FIELD_SECRET)
            for f in [FIELD_DNS_ZONE, FIELD_DNS_RECORD, FIELD_CERTIFICATE, FIELD_SCHEDULE, FIELD_EVENT_TRIGGER, FIELD_NETWORK, FIELD_SUBNET, FIELD_IP_ADDRESS, FIELD_REGISTRY]:
                l.append(f)
        return l^

    def absences(self) -> List[Absence]:
        var l = List[Absence]()
        if not self._full:
            l.append(Absence(FIELD_CONTAINER_JOB, NOT_YET, String("no runner for jobs")))
            l.append(Absence(FIELD_WORKER, NOT_YET, String("no always-on runner")))
            l.append(Absence(FIELD_TABLE, NOT_YET, String("no tables")))
            l.append(Absence(FIELD_BUCKET, NOT_YET, String("no object store")))
            l.append(Absence(FIELD_SERVICE_ACCOUNT, NOT_YET, String("no identities")))
            l.append(Absence(FIELD_GRANT, NOT_YET, String("no grants")))
            for f in [FIELD_QUEUE, FIELD_TOPIC, FIELD_SUBSCRIPTION, FIELD_SCHEDULE, FIELD_EVENT_TRIGGER]:
                l.append(Absence(f, NOT_YET, String("no messaging or triggers")))
            l.append(Absence(FIELD_SECRET, NOT_YET, String("no secret store")))
            for f in [FIELD_DNS_ZONE, FIELD_DNS_RECORD, FIELD_CERTIFICATE, FIELD_NETWORK, FIELD_SUBNET, FIELD_IP_ADDRESS, FIELD_REGISTRY]:
                l.append(Absence(f, NOT_YET, String("no names, networks or registries")))
        return l^

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        var out = List[Finding]()
        self._mechanism = String("edge")
        for i in range(len(ctx.settings)):
            ref st = ctx.settings[i]
            if st.key == "public_mechanism":
                if st.value == "edge":
                    self._mechanism = String("edge")
                elif st.value == "none":
                    self._mechanism = String("")
                else:
                    out.append(
                        Finding(
                            FINDING_CELL,
                            String("(cell)"),
                            String("settings.public_mechanism"),
                            String("\"") + st.value + String("\" is not edge or none"),
                        )
                    )
            else:
                out.append(
                    Finding(
                        FINDING_CELL,
                        String("(cell)"),
                        String("settings.") + st.key,
                        String("not a setting of this cloud"),
                    )
                )
        return out^

    def public_mechanism(self) -> String:
        return self._mechanism.copy()

    def check(self, r: Resource, feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
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

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return ArtifactNeed(String("OCI"), String("linux/amd64"))

    def lower(self, r: Resource, edges: List[GrantEdge], feeds: List[Feed], firings: List[Firing]) raises -> List[LoweredNode]:
        var owner = r.id.copy()
        if self._bad_owner:
            owner = String("someone-else")
        var out = List[LoweredNode]()
        var run = List[Setting]()
        run.append(Setting(String("type"), String(r._oneof0_case)))
        var role = String("bucket") if Bool(r.bucket) else String("run")
        out.append(
            LoweredNode(r.id + String("/") + role, owner, role, List[String](), List[InputRef](), run^)
        )
        if r._oneof0_case == 1:
            var edge = List[Setting]()
            edge.append(Setting(String("mechanism"), self._mechanism.copy()))
            out.append(
                LoweredNode(r.id + String("/edge"), r.id, String("edge"), List[String](), List[InputRef](), edge^)
            )
        if self._extra_role.byte_length() > 0:
            out.append(LoweredNode(r.id + String("/") + self._extra_role, r.id, String("extra")))
        return out^

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        self.log[].realized.append(node.id)
        return ErasedResource.erase(
            _Node(
                self.log,
                node.id,
                node.owner,
                fail_create=node.id == self._fail_create,
                retention=node.retention,
            )
        )

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        var l = List[BootstrapItem]()
        l.append(
            BootstrapItem(String("ledger"), machine + String("-") + cell + String("-ledger"), String("the state store"))
        )
        return l^

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return standard_label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        return standard_identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        var l = List[OwnedRecord]()
        for i in range(len(self.log[].created)):
            var id = self.log[].created[i].copy()
            l.append(
                OwnedRecord(
                    String("stub"), id.copy(), String("stub"), String("none"),
                    String(""), String(RUN_UNKNOWN), True, id.copy(), False,
                    String(""), None,
                )
            )
        return l^

    def read_existing(mut self, creds: Creds, node: LoweredNode) raises -> ExistingObject:
        return ExistingObject()  # nothing stands anywhere: these tests adopt nothing

    def release(mut self, creds: Creds, record: OwnedRecord) raises:
        raise Error("stub: these tests release nothing")

    def whoami(mut self, creds: Creds) raises -> Principal:
        return Principal(creds.token.copy(), String("stub-account"))

    def trust_render(self, scope: CellScope) -> String:
        return String("stub: cell ") + scope.cell + String(" trusts deployer")

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        var l = List[Finding]()
        if creds.token != "deployer":
            l.append(
                Finding(FINDING_CELL, String("(cell)"), String("trust"), creds.token + String(" is not deployer"))
            )
        return l^

    def image_registry(self, ctx: CellContext) -> String:
        return String("")

    def registry_login(mut self, creds: Creds) raises -> RegistryLogin:
        return RegistryLogin(String(""), String(""))


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


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
        + String('{"id":"batch","containerJob":{')
        + IMG
        + String('}}')
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
        # a container job whose image is an unresolved build output
        + String('{"id":"batch","containerJob":{"image":{"output":{"step":"b","name":"img"}}}},')
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
        'api|service.env.B|"batch" (container_job) does not expose URL',
        "api|service.env.C|a named output is only for the escape hatch",
        "api|service.env.D|refers to its own resource",
        'api|service.env.E|release parameter "region" is unresolved',
        "api|service.env.F|has no value",
        'api|uses[0]|ref to missing resource "ghost"',
        'api|uses[1]|service "web" does not accept access ACCESS_UNSET',
        "api|uses[2]|access is granted to a resource, not to one of its outputs",
        'api|uses[2]|a second edge from the identity of "api" to web; the first is uses[1] of "api"',
        "batch|container_job.image|the image is a build output that was not resolved",
        "web|id|duplicate id",
        "a/b|id|an id is lowercase letters, digits and '-' only",
        "empty|body|resource 'empty' has no type",
    ]:
        assert_true(_has(t, String(want)), String("missing: ") + String(want) + "\n" + t)
    assert_equal(len(f), 14, "exactly the findings above, each once:\n" + t)
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
            'resource "batch": container_job (PORTABLE): no adapter in cloud "lite"'
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
                _ = plan_resources(reg, cloud, _ctx(), resources, creds, store)
            elif verb == 1:
                _ = apply_resources(reg, cloud, _ctx(), resources, creds, store)
            else:
                _ = destroy_resources(reg, cloud, _ctx(), resources, creds, store)
        except e:
            raised = True
            assert_true(_has(String(e), "Nothing was created."), String(e))
        assert_true(raised, String("verb ") + String(verb) + " refused")
    assert_equal(len(cloud.log[].realized), 0, "a refused graph never reaches the adapter")
    assert_equal(len(cloud.log[].created), 0, "and nothing is created")

    # The same file on the full cloud applies.
    var full = _Stub(String("full"), True)
    var outcome = apply_resources(reg, full, _ctx(), _list(_good()), creds, store)
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
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cheat, _ctx(), _list(_good()), Creds.none(), st)
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
    var pst = InMemoryStateStore()
    var plan = plan_resources(reg, full, _ctx(), _list(_good()), Creds.none(), pst)
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
        # a platform that is not <os>/<cpu>, and one that is (whether a
        # cloud runs it is the cloud's question, checked below)
        + String('{"id":"bad-plat","service":{"image":{"digest":"sha256:01","platform":"amd64"}}},')
        + String('{"id":"mac","service":{"image":{"digest":"sha256:01","platform":"darwin/arm64"}}},')
        + String('{"id":"ok-plat","containerJob":{"image":{"digest":"sha256:02","platform":"linux/amd64"}}},')
        # a service and a container job that set one variable by env AND by secret_env,
        # a secret with no name, and a container job env that is unresolved or dangling
        + String('{"id":"svc","service":{') + IMG
        + String(',"env":{"DB":{"literal":"x"}},')
        + String('"secretEnv":{"DB":{"name":"db"},"EMPTY":{}}}},')
        + String('{"id":"cron","containerJob":{') + IMG
        + String(',"env":{"REGION":{"param":"region"},"API":{"ref":{"resource":"ghost","standard":"URL"}},')
        + String('"TOKEN":{"literal":"t"}},')
        + String('"secretEnv":{"TOKEN":{"name":"tok"}}}}')
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
        'bad-plat|service.image.platform|platform "amd64" is not <os>/<cpu> (for example linux/amd64)',
        "svc|service.secret_env.DB|the variable is set by env and by secret_env; set it in one",
        "svc|service.secret_env.EMPTY|a secret reference with no name and no secret",
        'cron|container_job.env.REGION|release parameter "region" is unresolved',
        'cron|container_job.env.API|ref to missing resource "ghost"',
        "cron|container_job.secret_env.TOKEN|the variable is set by env and by secret_env; set it in one",
    ]:
        assert_true(_has(t, String(want)), String("missing: ") + String(want) + "\n" + t)
    assert_equal(len(f), 12, "exactly the findings above, each once:\n" + t)
    assert_false(_has(t, "a-1-b-2-c-3-d-4-e-5-f-6|"), "a 24-byte id is legal:\n" + t)
    assert_false(_has(t, "ok-plat|"), "linux/amd64 written out is legal:\n" + t)
    assert_false(_has(t, "mac|"), "a well-formed platform is not a graph finding:\n" + t)

    # Deployability is the cloud's: the stub runs linux/amd64 images only.
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Stub(String("full"), True)))
    var full = _Stub(String("full"), True)
    var pj = (
        String('{"resource":[')
        + String('{"id":"mac","service":{"image":{"digest":"sha256:01","platform":"darwin/arm64"}}},')
        + String('{"id":"ok-plat","containerJob":{"image":{"digest":"sha256:02","platform":"linux/amd64"}}},')
        + String('{"id":"dflt","containerJob":{"image":{"digest":"sha256:03"}}}')
        + String("]}")
    )
    var pf = validate_for(reg, full, _list(pj))
    var pt = _all_text(pf)
    assert_true(
        _has(
            pt,
            'mac|service.image.platform|platform "darwin/arm64" is not deployable on cloud'
            ' "full": it runs OCI for linux/amd64',
        ),
        pt,
    )
    assert_equal(len(pf), 1, "only mac; empty means linux/amd64:\n" + pt)
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
        + String('{"id":"batch","containerJob":{') + IMG + String('}}')
        + String("]}")
    )
    var cloud = _Stub(String("full"), True, fail_create=String("batch/run"))
    var store = InMemoryStateStore()
    var outcome = apply_resources(reg, cloud, _ctx(), _list(json), Creds.none(), store)
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


# ---- 9. lowering is data -----------------------------------------------------------


def test_lowering_is_data_and_golden() raises:
    var full = _Stub(String("full"), True)
    var got = lowering_json(lower_data(full, _list(_good())))
    var want = (
        String("[\n")
        + String('  {"id":"api/run","owner":"api","kind":"run","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{"type":"1"}},\n')
        + String('  {"id":"api/edge","owner":"api","kind":"edge","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{"mechanism":"edge"}},\n')
        + String('  {"id":"batch/run","owner":"batch","kind":"run","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{"type":"2"}}\n')
        + String("]")
    )
    assert_equal(got, want)
    assert_equal(len(full.log[].realized), 0, "lowering creates no engine node")
    print("  test_lowering_is_data_and_golden: PASS")


# ---- 10. the cell is configured, and validated, first ------------------------------


def test_the_cell_is_configured_and_validated_first() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Stub(String("full"), True)))
    var creds = Creds.none()
    var store = InMemoryStateStore()

    # an unknown setting and a bad value refuse the whole graph
    var settings = List[Setting]()
    settings.append(Setting(String("public_mechanism"), String("teleport")))
    settings.append(Setting(String("regoin"), String("x")))
    var bad = CellContext(CellScope(String("shop"), String("blue")), settings^)
    var full = _Stub(String("full"), True)
    var msg = String("")
    try:
        _ = apply_resources(reg, full, bad, _list(_good()), creds, store)
    except e:
        msg = String(e)
    assert_true(_has(msg, "Nothing was created."), msg)
    assert_true(_has(msg, 'field settings.public_mechanism: "teleport" is not edge or none'), msg)
    assert_true(_has(msg, "field settings.regoin: not a setting of this cloud"), msg)
    assert_equal(len(full.log[].created), 0)

    # the public mechanism is chosen at validate time: none chosen, refused
    var none = List[Setting]()
    none.append(Setting(String("public_mechanism"), String("none")))
    var ctx = CellContext(CellScope(String("shop"), String("blue")), none^)
    var msg2 = String("")
    try:
        _ = plan_resources(reg, full, ctx, _list(_good()), creds, store)
    except e:
        msg2 = String(e)
    assert_true(
        _has(msg2, 'resource "api" field service.public: this cell\'s settings choose no public mechanism'),
        msg2,
    )

    # the chosen mechanism is in the lowering, not decided at apply time
    var edge = List[Setting]()
    edge.append(Setting(String("public_mechanism"), String("edge")))
    var ok = CellContext(CellScope(String("shop"), String("blue")), edge^)
    var plan = plan_resources(reg, full, ok, _list(_good()), creds, store)
    assert_equal(len(plan), 3)

    # kci deploys only into a cell
    var unowned = CellContext(CellScope.unowned())
    var msg3 = String("")
    try:
        _ = plan_resources(reg, full, unowned, _list(_good()), creds, store)
    except e:
        msg3 = String(e)
    assert_true(_has(msg3, "kci deploys only into a cell"), msg3)
    print("  test_the_cell_is_configured_and_validated_first: PASS")


# ---- 11. the rest of the adapter interface ----------------------------------------


def test_the_adapter_interface_and_the_label_rule() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Stub(String("full"), True)))
    var full = _Stub(String("full"), True)
    var scope = _ctx().scope.copy()

    var boot = full.bootstrap_resources(String("shop"), String("blue"))
    assert_equal(len(boot), 1)
    assert_equal(boot[0].name, "shop-blue-ledger")
    var me = full.whoami(Creds(String("deployer")))
    assert_equal(me.principal, "deployer")
    assert_equal(me.account, "stub-account")
    assert_true(_has(full.trust_render(scope), "cell blue trusts deployer"))
    assert_equal(len(full.trust_check(Creds(String("deployer")), scope)), 0)
    var tf = full.trust_check(Creds(String("intruder")), scope)
    assert_equal(len(tf), 1)
    assert_equal(tf[0].kind, FINDING_CELL)
    assert_equal(full.required_artifact(_list(_good())[0]).kind, "OCI")

    # the standard label rule: born with the object, decoded exactly
    var store = InMemoryStateStore()
    var out = apply_resources(reg, full, _ctx(), _list(_good()), Creds.none(), store)
    assert_true(out.ok())
    var stamp = scope.stamp(String("api"), String("api/edge"))
    var labels = full.label_rule(stamp)
    assert_equal(len(label_problems(labels)), 0)
    assert_equal(full.identity_of(labels), stamp.identity())
    assert_equal(encode_label_value(String("uses/jobs")), "uses_jobs")
    assert_equal(decode_label_value(String("uses_jobs")), "uses/jobs")
    var refused = False
    try:
        _ = encode_label_value(String("Upper"))
    except:
        refused = True
    assert_true(refused, "a value outside the rule is refused, never rewritten")
    var bad = List[Label]()
    bad.append(Label(String("kci_role"), String("a/b")))
    assert_equal(len(label_problems(bad)), 1)

    # list_owned names every object of the cell, by the node that owns it
    var owned = full.list_owned(Creds.none(), scope)
    assert_equal(len(owned), 3)
    assert_equal(owned[0].owner_node, "api/run")
    assert_equal(owned[0].run_id, RUN_UNKNOWN)
    print("  test_the_adapter_interface_and_the_label_rule: PASS")


# ---- 14. the role label budget, before apply ------------------------------------------


def _repeat(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def _one_service() -> String:
    return String('{"resource":[{"id":"api","service":{') + _img() + String(',"internal":{}}}]}')


def test_a_role_over_the_label_budget_is_refused_before_apply() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Stub(String("full"), True)))

    # 63 bytes encoded: within the budget, applied.
    var r63 = _repeat(String("p"), 20) + String("/") + _repeat(String("q"), 42)
    var fits = _Stub(String("full"), True, extra_role=r63)
    var st = InMemoryStateStore()
    var ok = apply_resources(reg, fits, _ctx(), _list(_one_service()), Creds.none(), st)
    assert_true(ok.ok(), "a 63-byte role is applied")
    assert_equal(len(fits.log[].created), 3, "api/run, api/edge and the 63-byte role")

    # 64 bytes encoded: refused before anything is realized or created.
    var r64 = r63 + String("q")
    var over = _Stub(String("full"), True, extra_role=r64)
    var st2 = InMemoryStateStore()
    var msg = String("")
    try:
        var out = apply_resources(reg, over, _ctx(), _list(_one_service()), Creds.none(), st2)
        msg = String("NOT REFUSED BEFORE APPLY; the apply ran and returned: ")
        msg += out.error.value() if out.error else String("success")
    except e:
        msg = String(e)
    assert_true(_has(msg, "Nothing was created."), msg)
    assert_true(_has(msg, String('node "api/') + r64 + String('"')), msg)
    assert_true(_has(msg, "64 bytes"), msg)
    assert_true(_has(msg, "at most 63"), msg)
    assert_true(_has(msg, "segment lengths 20, 43"), msg)
    assert_equal(len(over.log[].created), 0, "nothing was created")
    assert_equal(len(over.log[].realized), 0, "nothing was even realized")

    # The pure check, at the depths the budget is stated for: four 12-byte
    # component ids and an 8-byte role is 60 bytes (fits); a fifth is 73.
    var c12 = _repeat(String("c"), 12)
    var role8 = _repeat(String("r"), 8)
    var d4 = String("top/") + c12 + "/" + c12 + "/" + c12 + "/" + c12 + "/" + role8
    var d5 = String("top/") + c12 + "/" + c12 + "/" + c12 + "/" + c12 + "/" + c12 + "/" + role8
    var nodes = List[LoweredNode]()
    nodes.append(LoweredNode(d4, String("top"), String("run")))
    assert_equal(len(role_budget_findings(nodes)), 0, "depth 4 at maximum id lengths fits")
    nodes.append(LoweredNode(d5, String("top"), String("run")))
    var f = role_budget_findings(nodes)
    assert_equal(len(f), 1, "depth 5 at maximum id lengths does not")
    assert_equal(f[0].kind, FINDING_GRAPH)
    assert_equal(f[0].resource_id, "top")
    assert_true(_has(f[0].reason, "73 bytes encoded; at most 63"), f[0].reason)
    assert_true(_has(f[0].reason, "segment lengths 12, 12, 12, 12, 12, 8"), f[0].reason)
    print("  test_a_role_over_the_label_budget_is_refused_before_apply: PASS")


def main() raises:
    print("test_cloud_validate_and_deploy")
    test_every_graph_finding_in_one_pass()
    test_coverage_and_limits_refuse_before_lowering()
    test_the_lowering_contract_is_enforced()
    test_plan_groups_by_resource_and_unregistered_raises()
    test_id_grammar_platform_and_secret_rules()
    test_a_partial_apply_reports_landed_and_pending()
    test_lowering_is_data_and_golden()
    test_the_cell_is_configured_and_validated_first()
    test_the_adapter_interface_and_the_label_rule()
    test_a_role_over_the_label_budget_is_refused_before_apply()
    print("ALL kci_cloud VALIDATE AND DEPLOY TESTS PASSED")
