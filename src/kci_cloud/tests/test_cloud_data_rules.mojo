# =============================================================================
# test_cloud_data_rules.mojo
# =============================================================================
#
# The bucket, retention and the KEEP gap, over a stub cloud defined here (the
# fake clouds live in kci_cloud_fake; this package must be testable without
# them):
#
# 1. THE DATA REFUSALS, every one collected in one pass: an explicit
#    `object_expiry_days: 0`; `retention` on a service and on a container job;
#    a retention value that is neither DELETE nor KEEP; READ asked of a
#    service; a NAME reference to a service; `uses` on a bucket.
# 2. A GOOD DATA GRAPH IS CLEAN: buckets with and without retention, a
#    service that uses them READ and READ_WRITE and reads their NAME and
#    ADDRESS.
# 3. LOWERING RESOLVES AND SETS RETENTION: a dependency or input an adapter
#    wrote as a bare resource id lands on that resource's primary node
#    (`<id>/bucket`, `<id>/run`); each node takes its resource's retention
#    (the written one, else the type's default: KEEP for a bucket); the
#    golden JSON shows it.
# 4. REALIZE MUST KEEP THE RETENTION: an adapter whose engine node drops it
#    is refused before anything is created.
# 5. THE KEEP GAP, at `removals`: an object `list_owned` reports as RETAINED,
#    owned by a resource still in the file that no longer lowers it, is LEFT
#    BEHIND (reported, never a node to remove); the same object unretained is
#    a role to remove; an object of a resource gone from the file is
#    leftover. An apply reports what it left behind.
# 6. THE TABLE REFUSALS, in one pass: no key; an access path with no
#    partition; an untyped field; an order with no field; an index with no
#    name; two access paths with one name; an empty `ttl_field`; `uses` on a
#    table. A good table graph (a key with an order, two indexes, a TTL, a
#    service that reads its NAME and uses it READ_WRITE, another that
#    DESCRIBEs it) is clean, and a table lowers KEEP by default.
# 7. A TABLE'S KEY IS IMMUTABLE: with `list_owned` reporting the stored key,
#    a plan and an apply asking for another key are refused before anything
#    is created, and the refusal names the old and the new key; the same
#    key is planned; a destroy is not refused.
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
    ResourceStatus,
    RES_ABSENT,
    RETAIN_DELETE,
    RETAIN_KEEP,
    VERB_CREATE,
    VERB_NOOP,
)
from kci_resource_proto.refs import Retention
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
    CloudId,
    Clouds,
    Finding,
    LoweredNode,
    OwnedRecord,
    ExistingObject,
    Principal,
    RUN_UNKNOWN,
    Setting,
    FIELD_BUCKET,
    FIELD_TABLE,
    FIELD_SERVICE_ACCOUNT,
    FIELD_GRANT,
    FIELD_CONTAINER_JOB,
    FIELD_WORKER,
    FIELD_QUEUE,
    FIELD_TOPIC,
    FIELD_SUBSCRIPTION,
    FIELD_SECRET,
    FIELD_DNS_ZONE,
    FIELD_DNS_RECORD,
    FIELD_CERTIFICATE,
    FIELD_SCHEDULE,
    FIELD_EVENT_TRIGGER,
    FIELD_NETWORK,
    FIELD_SUBNET,
    FIELD_IP_ADDRESS,
    FIELD_REGISTRY,
    Feed,
    Firing,
    FIELD_SERVICE,
    FINDING_GRAPH,
    KEY_FIELD,
    apply_resources,
    describe,
    destroy_resources,
    graph_findings,
    lower_data,
    lowering_json,
    plan_resources,
    removals,
    standard_identity_of,
    standard_label_rule,
    table_key_text,
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


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


comptime IMG = '"image":{"digest":"sha256:0011"}'


# ---- the stub cloud ----------------------------------------------------------


struct _Log(Movable):
    var created: List[String]

    def __init__(out self):
        self.created = List[String]()


struct _DNode(EngineResource, Movable, Deinitable):
    var _log: ArcPointer[_Log]
    var _id: String
    var _owner: String
    var _deps: List[String]
    var _retention: Int

    def __init__(
        out self, log: ArcPointer[_Log], id: String, owner: String, var deps: List[String], retention: Int
    ):
        self._log = log.copy()
        self._id = id
        self._owner = owner
        self._deps = deps^
        self._retention = retention

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return self._deps.copy()

    def retention(mut self) -> Int:
        return self._retention

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.absent()

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var verb = VERB_NOOP
        if live.phase == RES_ABSENT:
            verb = VERB_CREATE
        return ChangeAction(self._id.copy(), verb, String(""), self._retention)

    def create(mut self, creds: Creds) raises -> String:
        raise Error(String("stub: an unstamped create"))

    def stamps_ownership(mut self) -> Bool:
        return True

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
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


struct _Data(CloudAdapter, Movable):
    """Hosts every v1 type. A bucket lowers to `<id>/bucket`; a workload to
    `<id>/run`, depending on each `uses` target and reading each env
    reference BY THE BARE RESOURCE ID (kci resolves it). `drop_retention`
    realizes every node with RETAIN_DELETE whatever kci set. `owned` is what
    `list_owned` reports."""

    var _drop_retention: Bool
    var owned: List[OwnedRecord]
    var log: ArcPointer[_Log]

    def __init__(out self, drop_retention: Bool = False):
        self._drop_retention = drop_retention
        self.owned = List[OwnedRecord]()
        self.log = ArcPointer[_Log](_Log())

    def cloud_id(self) -> CloudId:
        return CloudId(String("data"))

    def complete(self) -> Bool:
        return True

    def implemented(self) -> List[Int]:
        var l = List[Int]()
        l.append(FIELD_SERVICE)
        l.append(FIELD_CONTAINER_JOB)
        l.append(FIELD_WORKER)
        l.append(FIELD_TABLE)
        l.append(FIELD_BUCKET)
        l.append(FIELD_SERVICE_ACCOUNT)
        l.append(FIELD_GRANT)
        l.append(FIELD_QUEUE)
        l.append(FIELD_TOPIC)
        l.append(FIELD_SUBSCRIPTION)
        l.append(FIELD_SECRET)
        l.append(FIELD_DNS_ZONE)
        l.append(FIELD_DNS_RECORD)
        l.append(FIELD_CERTIFICATE)
        l.append(FIELD_SCHEDULE)
        l.append(FIELD_EVENT_TRIGGER)
        l.append(FIELD_NETWORK)
        l.append(FIELD_SUBNET)
        l.append(FIELD_IP_ADDRESS)
        l.append(FIELD_REGISTRY)
        return l^

    def absences(self) -> List[Absence]:
        return List[Absence]()

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        return List[Finding]()

    def public_mechanism(self) -> String:
        return String("edge")

    def check(self, r: Resource, feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
        return List[Finding]()

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return ArtifactNeed(String("oci-image"), String("linux/amd64"))

    def lower(self, r: Resource, edges: List[GrantEdge], feeds: List[Feed], firings: List[Firing]) raises -> List[LoweredNode]:
        var out = List[LoweredNode]()
        if Bool(r.bucket):
            out.append(LoweredNode(r.id + String("/bucket"), r.id, String("bucket")))
            return out^
        if Bool(r.table):
            var key = List[Setting]()
            key.append(Setting(String(KEY_FIELD), table_key_text(r.table.value())))
            out.append(
                LoweredNode(
                    r.id + String("/table"), r.id, String("table"), List[String](), List[InputRef](), key^
                )
            )
            return out^
        var deps = List[String]()
        for u in range(len(r.uses)):
            deps.append(r.uses[u].target.value().resource.copy())
        var refs = List[InputRef]()
        if r._oneof0_case == 1:
            for entry in r.service.value().env.items():
                if entry.value._oneof0_case == 3:
                    ref rf = entry.value.ref_.value()
                    refs.append(
                        InputRef(
                            rf.resource.copy(),
                            rf.standard.value().json_name(),
                            String("service.env.") + entry.key,
                        )
                    )
        out.append(LoweredNode(r.id + String("/run"), r.id, String("run"), deps^, refs^))
        return out^

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        var retention = RETAIN_DELETE if self._drop_retention else node.retention
        return ErasedResource.erase(
            _DNode(self.log, node.id, node.owner, node.depends_on.copy(), retention)
        )

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        return List[BootstrapItem]()

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return standard_label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        return standard_identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        return self.owned.copy()

    def read_existing(mut self, creds: Creds, node: LoweredNode) raises -> ExistingObject:
        return ExistingObject()  # nothing stands anywhere: these tests adopt nothing

    def release(mut self, creds: Creds, record: OwnedRecord) raises:
        raise Error("stub: these tests release nothing")

    def whoami(mut self, creds: Creds) raises -> Principal:
        return Principal(String("deployer"), String("data-account"))

    def trust_render(self, scope: CellScope) -> String:
        return String("data: any caller")

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        return List[Finding]()

    def image_registry(self, ctx: CellContext) -> String:
        return String("")

    def registry_login(mut self, creds: Creds) raises -> RegistryLogin:
        return RegistryLogin(String(""), String(""))


def _owned(node: String, retained: Bool) -> OwnedRecord:
    return OwnedRecord(
        String("bucket"),
        node.copy(),
        String("data"),
        String("none"),
        String(""),
        String(RUN_UNKNOWN),
        True,
        node.copy(),
        retained,
        String(""),
        None,
    )


# ---- 1. the data refusals ------------------------------------------------------------


def test_the_data_refusals_in_one_pass() raises:
    var json = (
        String('{"resource":[')
        + String('{"id":"zero","bucket":{"objectExpiryDays":0}},')
        + String('{"id":"svc-keep","retention":"KEEP","service":{') + String(IMG) + String("}},")
        + String('{"id":"job-del","retention":"DELETE","containerJob":{') + String(IMG) + String('}},')
        + String('{"id":"reader","service":{') + String(IMG)
        + String(',"env":{"N":{"ref":{"resource":"svc-keep","standard":"NAME"}}}},')
        + String('"uses":[{"target":{"resource":"svc-keep"},"access":"READ"}]},')
        + String('{"id":"grantor","bucket":{},')
        + String('"uses":[{"target":{"resource":"zero"},"access":"READ"}]},')
        + String('{"id":"odd","bucket":{}}')
        + String("]}")
    )
    var resources = _list(json)
    # A value outside the enum cannot be spelled in JSON; it can arrive on
    # the wire, where proto3 keeps it.
    resources[5].retention = Retention(7)
    var f = graph_findings(Catalog.v1(), resources)
    var t = _all_text(f)
    for want in [
        "zero|bucket.object_expiry_days|0 would expire every object at once",
        "svc-keep|retention|a service takes no retention: it is deleted with its resource",
        "job-del|retention|a container_job takes no retention",
        "odd|retention|retention value 7 is not DELETE or KEEP",
        'reader|uses[0]|service "svc-keep" does not accept access READ',
        'reader|service.env.N|"svc-keep" (service) does not expose NAME',
        "grantor|uses|a bucket runs as no identity, so it cannot use another resource",
    ]:
        assert_true(_has(t, String(want)), String("missing: ") + String(want) + "\n" + t)
    assert_equal(len(f), 7, "exactly the findings above, each once:\n" + t)
    for i in range(len(f)):
        assert_equal(f[i].kind, FINDING_GRAPH)
    print("  test_the_data_refusals_in_one_pass: PASS")


# ---- 2. a good data graph -------------------------------------------------------------


def _data_graph() -> String:
    return (
        String('{"resource":[')
        + String('{"id":"api","service":{') + String(IMG)
        + String(',"env":{"STORE":{"ref":{"resource":"store","standard":"NAME"}},')
        + String('"SCRATCH":{"ref":{"resource":"scratch","standard":"ADDRESS"}}}},')
        + String('"uses":[{"target":{"resource":"store"},"access":"READ_WRITE"},')
        + String('{"target":{"resource":"scratch"},"access":"READ"}]},')
        + String('{"id":"store","bucket":{"versioning":true}},')
        + String('{"id":"scratch","retention":"DELETE","bucket":{"objectExpiryDays":7,"tier":"ARCHIVE"}}')
        + String("]}")
    )


def test_a_good_data_graph_is_clean() raises:
    var f = graph_findings(Catalog.v1(), _list(_data_graph()))
    assert_equal(len(f), 0, _all_text(f))
    var kept = _list(String('{"resource":[{"id":"k","retention":"KEEP","bucket":{}}]}'))
    assert_equal(len(graph_findings(Catalog.v1(), kept)), 0, "KEEP written out is legal")
    print("  test_a_good_data_graph_is_clean: PASS")


# ---- 3. lowering resolves references and sets retention -----------------------------------


def test_lowering_resolves_references_and_sets_retention() raises:
    var cloud = _Data()
    var nodes = lower_data(cloud, _list(_data_graph()))
    assert_equal(len(nodes), 3)
    ref api = nodes[0]
    assert_equal(api.id, "api/run")
    assert_equal(len(api.depends_on), 2)
    assert_equal(api.depends_on[0], "store/bucket", "a bare id lands on the primary node")
    assert_equal(api.depends_on[1], "scratch/bucket")
    var producers = String("")
    for i in range(len(api.inputs)):
        producers += api.inputs[i].producer + String(".") + api.inputs[i].output + String(" ")
    assert_true(_has(producers, "store/bucket.NAME"), producers)
    assert_true(_has(producers, "scratch/bucket.ADDRESS"), producers)
    assert_equal(api.retention, RETAIN_DELETE, "a service takes no retention")
    assert_equal(nodes[1].id, "store/bucket")
    assert_equal(nodes[1].retention, RETAIN_KEEP, "a bucket is KEEP by default")
    assert_equal(nodes[2].id, "scratch/bucket")
    assert_equal(nodes[2].retention, RETAIN_DELETE, "a written DELETE is DELETE")

    var golden = lowering_json(lower_data(cloud, _list(String('{"resource":[{"id":"b","bucket":{}}]}'))))
    assert_equal(
        golden,
        String('[\n  {"id":"b/bucket","owner":"b","kind":"bucket","wanted":true,"retention":"keep",')
        + String('"depends_on":[],"inputs":[],"desired":{}}\n]'),
    )
    print("  test_lowering_resolves_references_and_sets_retention: PASS")


# ---- 4. realize must keep the retention -----------------------------------------------


def test_realize_must_keep_the_retention() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Data()))
    var cheat = _Data(drop_retention=True)
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cheat, _ctx(), _list(_data_graph()), Creds.none(), st)
    except e:
        raised = True
        assert_true(_has(String(e), "realize must keep the retention kci set"), String(e))
        assert_true(_has(String(e), 'node "store/bucket" with retention'), String(e))
    assert_true(raised, "a realized node that dropped KEEP is refused")
    assert_equal(len(cheat.log[].created), 0, "nothing was created")
    print("  test_realize_must_keep_the_retention: PASS")


# ---- 5. the KEEP gap -----------------------------------------------------------------------


def test_a_retained_object_is_left_behind() raises:
    # `store` was a bucket and is now a service: the file no longer lowers
    # `store/bucket`. Retained, it is left behind; unretained, it is a role
    # to remove. `gone` is not in the file at all: leftover.
    var resources = _list(
        String('{"resource":[{"id":"store","service":{') + String(IMG) + String("}}]}")
    )
    var cloud = _Data()
    cloud.owned.append(_owned(String("store/bucket"), True))
    cloud.owned.append(_owned(String("store/old"), False))
    cloud.owned.append(_owned(String("gone/bucket"), True))
    var nodes = lower_data(cloud, resources)
    var rem = removals(cloud, _ctx(), nodes, resources, Creds.none())
    assert_equal(len(rem.left_behind), 1, "the retained object is left behind")
    assert_equal(rem.left_behind[0], "store/bucket")
    assert_equal(len(rem.roles), 1, "only the unretained object is a role to remove")
    assert_equal(rem.roles[0].id, "store/old")
    assert_false(rem.roles[0].wanted)
    assert_equal(len(rem.leftover), 1)
    assert_equal(rem.leftover[0], "gone/bucket", "a resource gone from the file is leftover")

    # Through an apply: reported, and no node is made for it.
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Data()))
    var only = _Data()
    only.owned.append(_owned(String("store/bucket"), True))
    var st = InMemoryStateStore()
    var outcome = apply_resources(reg, only, _ctx(), resources, Creds.none(), st)
    assert_true(outcome.ok(), outcome.error.value() if outcome.error else String(""))
    assert_equal(len(outcome.left_behind), 1)
    assert_equal(outcome.left_behind[0], "store/bucket")
    for i in range(len(outcome.applied)):
        assert_true(outcome.applied[i].logical_id != "store/bucket", "no node for a kept object")
    print("  test_a_retained_object_is_left_behind: PASS")


# ---- 6. the table refusals --------------------------------------------------------------

comptime _KEY = '"key":{"partition":{"name":"customer","type":"STRING"}}'


def test_the_table_refusals_in_one_pass() raises:
    var json = (
        String('{"resource":[')
        + String('{"id":"nokey","table":{}},')
        + String('{"id":"nopart","table":{"key":{"name":"k"}}},')
        + String('{"id":"untyped","table":{"key":{"partition":{"name":"customer"}}}},')
        + String('{"id":"noorder","table":{"key":{"partition":{"name":"c","type":"STRING"},"order":{"type":"NUMBER"}}}},')
        + String('{"id":"noname","table":{') + String(_KEY)
        + String(',"indexes":[{"partition":{"name":"s","type":"STRING"}}]}},')
        + String('{"id":"dup","table":{') + String(_KEY)
        + String(',"indexes":[{"name":"by-s","partition":{"name":"s","type":"STRING"}},')
        + String('{"name":"by-s","partition":{"name":"t","type":"BYTES"}}]}},')
        + String('{"id":"ttl","table":{') + String(_KEY) + String(',"ttlField":""}},')
        + String('{"id":"granting","table":{') + String(_KEY)
        + String('},"uses":[{"target":{"resource":"ttl"},"access":"READ"}]}')
        + String("]}")
    )
    var f = graph_findings(Catalog.v1(), _list(json))
    var t = _all_text(f)
    for want in [
        "nokey|table.key|no key: a table finds its items by a key",
        "nopart|table.key.partition|no partition field",
        'untyped|table.key.partition.type|an untyped field ("customer"): its type is STRING, NUMBER or BYTES',
        "noorder|table.key.order|an order with no field",
        "noname|table.indexes[0].name|an index has no name",
        'dup|table.indexes[1].name|duplicate access path name "by-s"',
        "ttl|table.ttl_field|an empty ttl_field",
        "granting|uses|a table runs as no identity, so it cannot use another resource",
    ]:
        assert_true(_has(t, String(want)), String("missing: ") + String(want) + "\n" + t)
    assert_equal(len(f), 8, "exactly the findings above, each once:\n" + t)
    for i in range(len(f)):
        assert_equal(f[i].kind, FINDING_GRAPH)
    print("  test_the_table_refusals_in_one_pass: PASS")


def _table_graph(key: String) -> String:
    return (
        String('{"resource":[')
        + String('{"id":"api","service":{') + String(IMG)
        + String(',"env":{"ORDERS":{"ref":{"resource":"orders","standard":"NAME"}}}},')
        + String('"uses":[{"target":{"resource":"orders"},"access":"READ_WRITE"}]},')
        + String('{"id":"audit","service":{') + String(IMG) + String("},")
        + String('"uses":[{"target":{"resource":"orders"},"access":"DESCRIBE"}]},')
        + String('{"id":"orders","table":{"key":') + key
        + String(',"indexes":[{"name":"by-state","partition":{"name":"state","type":"STRING"},')
        + String('"order":{"name":"placed","type":"NUMBER"}},')
        + String('{"name":"by-sku","partition":{"name":"sku","type":"BYTES"}}],')
        + String('"ttlField":"expires"}}')
        + String("]}")
    )


comptime _KEY_ONE = '{"name":"pk","partition":{"name":"customer","type":"STRING"}}'
comptime _KEY_TWO = (
    '{"name":"pk","partition":{"name":"customer","type":"STRING"},'
    '"order":{"name":"placed","type":"NUMBER"}}'
)


def test_a_good_table_graph_is_clean() raises:
    var resources = _list(_table_graph(String(_KEY_TWO)))
    var f = graph_findings(Catalog.v1(), resources)
    assert_equal(len(f), 0, _all_text(f))
    assert_equal(table_key_text(resources[2].table.value()), "customer:STRING/placed:NUMBER")
    var nodes = lower_data(_Data(), resources)
    var at = -1
    for i in range(len(nodes)):
        if nodes[i].id == "orders/table":
            at = i
    assert_true(at >= 0, "the table lowers its primary node")
    assert_equal(nodes[at].retention, RETAIN_KEEP, "a table is KEEP by default")
    assert_equal(nodes[at].field(String(KEY_FIELD)), "customer:STRING/placed:NUMBER")
    assert_equal(nodes[0].depends_on[0], "orders/table", "a bare id lands on the table node")
    assert_equal(nodes[0].inputs[0].producer, "orders/table")
    print("  test_a_good_table_graph_is_clean: PASS")


# ---- 7. a table's key is immutable ------------------------------------------------------


def _owned_table(node: String, key: String) -> OwnedRecord:
    return OwnedRecord(
        String("table"),
        node.copy(),
        String("data"),
        String("none"),
        String(""),
        String(RUN_UNKNOWN),
        True,
        node.copy(),
        True,
        key.copy(),
        None,
    )


def test_a_changed_key_is_refused_before_any_change() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(_Data()))
    var resources = _list(_table_graph(String(_KEY_TWO)))

    var cloud = _Data()
    cloud.owned.append(_owned_table(String("orders/table"), String("customer:STRING")))
    var refused = 0
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), resources, Creds.none(), st)
    except e:
        refused += 1
        var t = String(e)
        assert_true(_has(t, "orders"), t)
        assert_true(_has(t, "table.key"), t)
        assert_true(
            _has(t, "the key changed from customer:STRING to customer:STRING/placed:NUMBER"), t
        )
        assert_true(_has(t, "a new key is a new table"), t)
    try:
        var st = InMemoryStateStore()
        _ = apply_resources(reg, cloud, _ctx(), resources, Creds.none(), st)
    except e:
        refused += 1
        assert_true(_has(String(e), "the key changed from customer:STRING"), String(e))
    assert_equal(refused, 2, "the plan and the apply are both refused")
    assert_equal(len(cloud.log[].created), 0, "nothing was created")

    # The stored key, asked for again: planned.
    var same = _Data()
    same.owned.append(_owned_table(String("orders/table"), String("customer:STRING")))
    var st = InMemoryStateStore()
    var plan = plan_resources(
        reg, same, _ctx(), _list(_table_graph(String(_KEY_ONE))), Creds.none(), st
    )
    assert_true(len(plan) > 0, "an unchanged key plans")
    # A destroy removes what the cloud holds; it is not refused.
    var gone = _Data()
    gone.owned.append(_owned_table(String("orders/table"), String("customer:STRING")))
    var st2 = InMemoryStateStore()
    _ = destroy_resources(reg, gone, _ctx(), resources, Creds.none(), st2)
    print("  test_a_changed_key_is_refused_before_any_change: PASS")


def main() raises:
    print("test_cloud_data_rules")
    test_the_data_refusals_in_one_pass()
    test_a_good_data_graph_is_clean()
    test_lowering_resolves_references_and_sets_retention()
    test_realize_must_keep_the_retention()
    test_a_retained_object_is_left_behind()
    test_the_table_refusals_in_one_pass()
    test_a_good_table_graph_is_clean()
    test_a_changed_key_is_refused_before_any_change()
    print("ALL kci_cloud DATA RULE TESTS PASSED")
