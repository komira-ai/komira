# =============================================================================
# test_fake_label_budget.mojo: VALIDATE REPORTS THE ROLE LABEL BUDGET.
# =============================================================================
#
# Every node's role (its id after its owner) is written into a label value
# of at most 63 bytes. The fakes' own roles are short, so the cloud here is
# the generic fake with one more node on resource `a`, `a/<role>`, and
# optionally a lowering that raises on resource `b`. The graph is two
# buckets, `a` and `b`.
#
# 1. VALIDATE REPORTS IT: a 63-byte role passes; a 64-byte role (two
#    segments, 20 and 43 bytes) is one GRAPH finding on `a`, in the exact
#    text.
# 2. ONLY ON A GRAPH WITH NO OTHER FINDING, like the cloud names: with an id
#    finding beside it, the id finding is the only one.
# 3. A LOWERING THAT RAISES IS SKIPPED, not fatal: `b` raising leaves `a`'s
#    finding, and validate itself does not raise.
# 4. PLAN, APPLY AND DESTROY REFUSE IT FIRST: each raises the one refusal
#    text with the finding, and the cloud has served no call. The 63-byte
#    role applies (the control).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    CellScope,
    Creds,
    ErasedResource,
    InMemoryStateStore,
    Label,
    OwnerStamp,
    Provenance,
)
from kci_cloud import (
    Absence,
    ArtifactNeed,
    BootstrapItem,
    Catalog,
    CellContext,
    CloudAdapter,
    CloudId,
    Clouds,
    FINDING_GRAPH,
    Feed,
    Finding,
    Firing,
    GrantEdge,
    LoweredNode,
    OwnedRecord,
    ExistingObject,
    Principal,
    apply_resources,
    describe,
    destroy_resources,
    plan_resources,
    validate_for,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud


struct _Deep(CloudAdapter, Movable):
    """The generic fake, with one more node `a/<role>` on resource `a` when
    `role` is not empty, and a lowering that raises on resource `b` when
    `boom`."""

    var inner: FakeCloud
    var role: String
    var boom: Bool

    def __init__(out self, role: String, boom: Bool = False):
        self.inner = FakeCloud(String("deep"))
        self.role = role
        self.boom = boom

    def cloud_id(self) -> CloudId:
        return self.inner.cloud_id()

    def complete(self) -> Bool:
        return self.inner.complete()

    def implemented(self) -> List[Int]:
        return self.inner.implemented()

    def absences(self) -> List[Absence]:
        return self.inner.absences()

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        return self.inner.configure(ctx)

    def public_mechanism(self) -> String:
        return self.inner.public_mechanism()

    def check(self, r: Resource, feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
        return self.inner.check(r, feeds, firings)

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return self.inner.required_artifact(r)

    def lower(
        self, r: Resource, edges: List[GrantEdge], feeds: List[Feed], firings: List[Firing]
    ) raises -> List[LoweredNode]:
        if self.boom and r.id == "b":
            raise Error("this cloud cannot lower b")
        var out = self.inner.lower(r, edges, feeds, firings)
        if r.id == "a" and self.role.byte_length() > 0:
            out.append(LoweredNode(String("a/") + self.role, String("a"), String("deep")))
        return out^

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        return self.inner.realize(node)

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        return self.inner.bootstrap_resources(machine, cell)

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return self.inner.label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        return self.inner.identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        return self.inner.list_owned(creds, scope)

    def read_existing(mut self, creds: Creds, node: LoweredNode) raises -> ExistingObject:
        return self.inner.read_existing(creds, node)

    def release(mut self, creds: Creds, record: OwnedRecord) raises:
        self.inner.release(creds, record)

    def whoami(mut self, creds: Creds) raises -> Principal:
        return self.inner.whoami(creds)

    def trust_render(self, scope: CellScope) -> String:
        return self.inner.trust_render(scope)

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        return self.inner.trust_check(creds, scope)


comptime GRAPH = '{"resource":[{"id":"a","bucket":{}},{"id":"b","bucket":{}}]}'


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _rep(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def _fits() -> String:
    """63 bytes encoded: two segments, 20 and 42 bytes, and one `_`."""
    return _rep(String("p"), 20) + String("/") + _rep(String("q"), 42)


def _over() -> String:
    """64 bytes encoded: two segments, 20 and 43 bytes, and one `_`."""
    return _rep(String("p"), 20) + String("/") + _rep(String("q"), 43)


def _reason() -> String:
    return (
        String('node "a/')
        + _over()
        + String('": its role label is 64 bytes encoded; at most 63 (segment lengths 20, 43;')
        + String(" shorter ids or less nesting fit)")
    )


def _validated(cloud: _Deep, json: String) raises -> List[Finding]:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    return validate_for(reg, cloud, _list(json))


def _lines(findings: List[Finding]) -> String:
    var s = String("")
    for i in range(len(findings)):
        s += findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason + String("\n")
    return s^


# ---- 1. validate reports it ---------------------------------------------------------


def test_validate_reports_a_role_over_the_budget() raises:
    """Catches: validate not measuring the lowering at all (the role is
    found only once something is created), and a bound off by one either
    way (63 refused, or 64 taken)."""
    assert_equal(_lines(_validated(_Deep(_fits()), GRAPH)), "", "a 63-byte role passes")
    var f = _validated(_Deep(_over()), GRAPH)
    assert_equal(len(f), 1, _lines(f))
    assert_equal(f[0].kind, FINDING_GRAPH)
    assert_equal(f[0].resource_id, "a")
    assert_equal(f[0].field_path, "")
    assert_equal(f[0].reason, _reason())
    print("  test_validate_reports_a_role_over_the_budget: PASS")


# ---- 2. only on a graph with no other finding ------------------------------------


def test_only_on_a_graph_with_no_other_finding() raises:
    """Catches: the budget measured on a graph with another finding (a
    lowering of a graph validate refuses anyway, the same rule as the cloud
    names)."""
    var json = String('{"resource":[{"id":"a","bucket":{}},{"id":"B","bucket":{}}]}')
    var f = _validated(_Deep(_over()), json)
    assert_equal(len(f), 1, _lines(f))
    assert_equal(f[0].resource_id, "B", "the id finding, alone")
    assert_equal(len(_validated(_Deep(String("")), json)), 1, "the control: the id finding is there without the role")
    print("  test_only_on_a_graph_with_no_other_finding: PASS")


# ---- 3. a lowering that raises is skipped ------------------------------------------


def test_a_lowering_that_raises_is_skipped() raises:
    """Catches: validate raising out of a lowering (it reports findings; the
    lowering contract refuses at plan), and the measure stopping at the
    first resource whose lowering raises (`b`, which raises, is listed
    before `a` here)."""
    var json = String('{"resource":[{"id":"b","bucket":{}},{"id":"a","bucket":{}}]}')
    var f = _validated(_Deep(_over(), boom=True), json)
    assert_equal(len(f), 1, _lines(f))
    assert_equal(f[0].reason, _reason())
    assert_equal(_lines(_validated(_Deep(_fits(), boom=True), json)), "", "nothing over: no finding")
    print("  test_a_lowering_that_raises_is_skipped: PASS")


# ---- 4. plan, apply and destroy refuse it first ------------------------------------


def _refused(verb: String) raises:
    var cloud = _Deep(_over())
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    var st = InMemoryStateStore()
    var msg = String("")
    try:
        if verb == "plan":
            _ = plan_resources(reg, cloud, _ctx(), _list(GRAPH), Creds.none(), st)
        elif verb == "apply":
            _ = apply_resources(reg, cloud, _ctx(), _list(GRAPH), Creds.none(), st)
        else:
            _ = destroy_resources(reg, cloud, _ctx(), _list(GRAPH), Creds.none(), st)
        msg = verb + String(": NOT REFUSED")
    except e:
        msg = String(e)
    assert_true(msg.find('cannot apply this graph to cloud "deep". Nothing was created.') >= 0, msg)
    assert_true(msg.find(String('resource "a": ') + _reason()) >= 0, msg)
    assert_equal(len(cloud.inner.store[].calls), 0, verb + ": the cloud served no call")


def test_plan_apply_and_destroy_refuse_it_first() raises:
    """Catches: a verb that lowers, lists or creates before the budget is
    checked (deploy relies on validate for it), and a verb that skips
    validate."""
    _refused(String("plan"))
    _refused(String("apply"))
    _refused(String("destroy"))
    var cloud = _Deep(_fits())
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    var st = InMemoryStateStore()
    var out = apply_resources(reg, cloud, _ctx(), _list(GRAPH), Creds.none(), st)
    assert_true(out.ok(), "the 63-byte role applies")
    var made = False
    for i in range(len(out.applied)):
        if out.applied[i].logical_id == String("a/") + _fits():
            made = True
    assert_true(made, "the 63-byte role is created")
    print("  test_plan_apply_and_destroy_refuse_it_first: PASS")


def main() raises:
    print("test_fake_label_budget")
    test_validate_reports_a_role_over_the_budget()
    test_only_on_a_graph_with_no_other_finding()
    test_a_lowering_that_raises_is_skipped()
    test_plan_apply_and_destroy_refuse_it_first()
    print("ALL kci_cloud_fake LABEL BUDGET TESTS PASSED")
