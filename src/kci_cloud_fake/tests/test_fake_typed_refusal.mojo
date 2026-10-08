# =============================================================================
# test_fake_typed_refusal.mojo: a refused run is a value, not a message.
# =============================================================================
#
# `plan_report` and `apply_resources` given a `refusal` argument set it to a
# `Refusal` exactly when the run is refused before any change, so a caller
# tells REFUSED (exit 3) from FAILED or PARTIAL without reading text.
#
# 1. EVERY REFUSAL PATH IS TYPED, under the plan and the apply both, with its
#    findings: a validate finding, an expansion finding, a changed table key,
#    an adoption finding (FINDING_ADOPTION), a foreign object and a
#    conflicting one (the engine's, FINDING_OWNERSHIP, one finding per node).
# 2. NOTHING ELSE IS: an engine fault (a create that failed, a presence read
#    that raised), a `realize` that raises and a broken lowering contract
#    leave the refusal None.
# 3. A FAILED RELEASE is typed apart from an engine error
#    (`ApplyOutcome.failed_release`).
# 4. THE PLAN REPORTS what the apply leaves alone: the same `leftover` and
#    `left_behind`.
# 5. A REFERENCE CYCLE (two services each reading the other's URL) is a
#    validate finding: the typed refusal under both verbs, with no call on
#    the fake. A cycle among later resources is found too, a 3-cycle is
#    printed from its smallest id, and two services that only `uses` each
#    other are no cycle.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

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
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList
from kci_cloud import (
    Absence,
    ApplyOutcome,
    ArtifactNeed,
    BootstrapItem,
    Catalog,
    CellContext,
    CloudAdapter,
    CloudId,
    Clouds,
    ExistingObject,
    FINDING_ADOPTION,
    FINDING_GRAPH,
    FINDING_OWNERSHIP,
    Feed,
    Finding,
    Firing,
    GrantEdge,
    LoweredNode,
    OwnedRecord,
    PlanReport,
    Principal,
    Refusal,
    apply_resources,
    describe,
    lower_data,
    plan_report,
    validate_for,
)

from kci_cloud_fake import FakeCloud


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](String('{"resource":[') + json + String("]}")).resource.copy()


def _ctx(machine: String = String("shop")) -> CellContext:
    return CellContext(CellScope(machine, String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _reg() raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    return reg^


def _no_defs() -> List[CompositeDefinition]:
    return List[CompositeDefinition]()


def _done(outcome: ApplyOutcome) raises:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())


struct _Seen(Movable):
    """What one verb said: whether it raised, its text, and the refusal it
    set."""

    var raised: Bool
    var text: String
    var refusal: Optional[Refusal]

    def __init__(out self):
        self.raised = False
        self.text = String("")
        self.refusal = None


def _plan[S: CloudAdapter](mut cloud: S, json: String, mut st: InMemoryStateStore, machine: String = String("shop")) raises -> _Seen:
    var seen = _Seen()
    try:
        _ = plan_report(_reg(), cloud, _ctx(machine), _list(json), Creds.none(), st, _no_defs(), seen.refusal)
    except e:
        seen.raised = True
        seen.text = String(e)
    return seen^


def _apply[S: CloudAdapter](mut cloud: S, json: String, mut st: InMemoryStateStore, machine: String = String("shop")) raises -> _Seen:
    """An apply's refusal, raised or returned; a returned outcome's own
    `refusal` must be the one the argument got."""
    var seen = _Seen()
    try:
        var out = apply_resources(_reg(), cloud, _ctx(machine), _list(json), Creds.none(), st, _no_defs(), seen.refusal)
        assert_equal(Bool(out.refusal), Bool(seen.refusal), "the outcome and the argument agree")
        assert_equal(out.refused(), Bool(out.refusal))
        if out.error:
            seen.text = out.error.value()
        if out.refusal:
            assert_equal(len(out.landed), 0, "a refusal lands nothing")
    except e:
        seen.raised = True
        seen.text = String(e)
    return seen^


def _typed(seen: _Seen, by_engine: Bool, kind: Int, resource: String, what: String) raises -> List[Finding]:
    assert_true(Bool(seen.refusal), what + ": typed: " + seen.text)
    ref r = seen.refusal.value()
    assert_equal(r.by_engine, by_engine, what)
    assert_equal(r.text, seen.text, what + ": the refusal is the text the verb gave")
    assert_true(len(r.findings) > 0, what + ": it carries its findings")
    var hit = False
    for i in range(len(r.findings)):
        if r.findings[i].kind == kind and r.findings[i].resource_id == resource:
            hit = True
    assert_true(hit, what + ": a finding of that kind names " + resource + ": " + r.text)
    return r.findings.copy()


# ---- 1. every refusal path is typed -------------------------------------------------------


def test_a_validate_finding_is_typed() raises:
    """Catches: kci_cloud's refusal raised as text alone (mutant: `_refuse`
    no longer sets `refusal` in `_valid_expansion`)."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var json = String('{"id":"Bad","bucket":{}}')
    var p = _plan(cloud, json, st)
    assert_true(p.raised, "the plan raises")
    _ = _typed(p, False, FINDING_GRAPH, String("Bad"), String("plan"))
    var a = _apply(cloud, json, st)
    assert_true(a.raised, "the apply raises before any effect")
    _ = _typed(a, False, FINDING_GRAPH, String("Bad"), String("apply"))
    assert_equal(cloud.mutations(), 0)
    print("  test_a_validate_finding_is_typed: PASS")


def test_an_expansion_finding_is_typed() raises:
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var json = String('{"id":"store","composite":{"definition":"acme.none","version":"1"}}')
    var p = _plan(cloud, json, st)
    assert_true(p.raised and Bool(p.refusal), "plan: " + p.text)
    assert_false(p.refusal.value().by_engine)
    var a = _apply(cloud, json, st)
    assert_true(a.raised and Bool(a.refusal), "apply: " + a.text)
    assert_equal(a.text, p.text, "the same refusal")
    print("  test_an_expansion_finding_is_typed: PASS")


comptime _KEY_ONE = '{"id":"orders","table":{"key":{"name":"pk","partition":{"name":"customer","type":"STRING"}}}}'
comptime _KEY_TWO = (
    '{"id":"orders","table":{"key":{"name":"pk","partition":{"name":"customer","type":"STRING"},'
    '"order":{"name":"placed","type":"NUMBER"}}}}'
)


def test_a_key_change_is_typed() raises:
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    _done(apply_resources(_reg(), cloud, _ctx(), _list(String(_KEY_ONE)), Creds.none(), st))
    var before = cloud.mutations()
    var p = _plan(cloud, String(_KEY_TWO), st)
    _ = _key(p, "plan")
    var a = _apply(cloud, String(_KEY_TWO), st)
    _ = _key(a, "apply")
    assert_equal(cloud.mutations(), before, "nothing changed")
    print("  test_a_key_change_is_typed: PASS")


def _key(seen: _Seen, what: String) raises -> Bool:
    assert_true(seen.raised and Bool(seen.refusal), what + ": " + seen.text)
    ref r = seen.refusal.value()
    assert_false(r.by_engine)
    var hit = False
    for i in range(len(r.findings)):
        if r.findings[i].resource_id == "orders" and r.findings[i].field_path == "table.key":
            hit = True
    assert_true(hit, what + ": the finding names orders' table.key: " + r.text)
    return hit


def test_an_adoption_finding_is_typed() raises:
    """Nothing stands where an adopted bucket is declared."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var json = String('{"id":"logs","physicalName":"acme-logs","adopt":"ADOPT","bucket":{}}')
    var p = _plan(cloud, json, st)
    assert_true(p.raised)
    _ = _typed(p, False, FINDING_ADOPTION, String("logs"), String("plan"))
    var a = _apply(cloud, json, st)
    assert_true(a.raised)
    _ = _typed(a, False, FINDING_ADOPTION, String("logs"), String("apply"))
    assert_equal(cloud.mutations(), 0)
    print("  test_an_adoption_finding_is_typed: PASS")


comptime _TWO = '{"id":"logs","bucket":{}},{"id":"media","bucket":{}}'


def test_a_foreign_object_is_typed_one_finding_per_node() raises:
    """Catches: the engine's foreign refusal returned as an untyped error
    (the row's mutant), and only the first problem line made a finding
    (mutant: the findings loop stops after one)."""
    var foreign = List[String]()
    foreign.append(String("logs/bucket"))
    foreign.append(String("media/bucket"))
    var cloud = FakeCloud(foreign=foreign)
    var st = InMemoryStateStore()
    var p = _plan(cloud, String(_TWO), st)
    assert_true(p.raised, "the plan raises")
    var pf = _typed(p, True, FINDING_OWNERSHIP, String("media"), String("plan"))
    assert_equal(len(pf), 2, "one finding per refused node")
    assert_equal(pf[0].field_path, "logs/bucket")
    assert_equal(pf[1].field_path, "media/bucket")
    assert_true(pf[1].reason.startswith("foreign"), pf[1].reason)
    var a = _apply(cloud, String(_TWO), st)
    assert_false(a.raised, "the engine's refusal is returned, not raised")
    var af = _typed(a, True, FINDING_OWNERSHIP, String("logs"), String("apply"))
    assert_equal(len(af), 2)
    assert_equal(cloud.mutations(), 0)
    print("  test_a_foreign_object_is_typed_one_finding_per_node: PASS")


def test_a_conflict_is_typed() raises:
    """Objects stamped by machine `shop`, met by machine `other`."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    _done(apply_resources(_reg(), cloud, _ctx(), _list(String(_TWO)), Creds.none(), st))
    var before = cloud.mutations()
    var other = InMemoryStateStore()
    var p = _plan(cloud, String(_TWO), other, String("other"))
    var pf = _typed(p, True, FINDING_OWNERSHIP, String("logs"), String("plan"))
    assert_true(pf[0].reason.startswith("conflict"), pf[0].reason)
    var a = _apply(cloud, String(_TWO), other, String("other"))
    var af = _typed(a, True, FINDING_OWNERSHIP, String("media"), String("apply"))
    assert_true(af[1].reason.startswith("conflict"), af[1].reason)
    assert_equal(cloud.mutations(), before)
    print("  test_a_conflict_is_typed: PASS")


# ---- 2. nothing else is ----------------------------------------------------------------------


def test_an_engine_fault_is_not_typed() raises:
    """A create that fails (apply), and a presence read that raises (plan
    and apply)."""
    var cloud = FakeCloud(fail_at_call=1)
    var st = InMemoryStateStore()
    var a = _apply(cloud, String(_TWO), st)
    assert_false(a.raised)
    assert_true(a.text.byte_length() > 0, "it stopped")
    assert_false(Bool(a.refusal), "an engine fault is not a refusal: " + a.text)
    var reads = FakeCloud()
    reads.store[].fail_reads_of(String("media/bucket"))
    var rst = InMemoryStateStore()
    var p = _plan(reads, String(_TWO), rst)
    assert_true(p.raised, "the read raised")
    assert_false(Bool(p.refusal), "a failed read is not a refusal: " + p.text)
    var ra = _apply(reads, String(_TWO), rst)
    assert_false(Bool(ra.refusal), "a failed read is not a refusal: " + ra.text)
    print("  test_an_engine_fault_is_not_typed: PASS")


struct _Faulty(CloudAdapter, Movable):
    """The generic fake, except: `mode` "realize" raises in `realize`;
    "owner" lowers every node owned by another resource (the lowering
    contract refuses it)."""

    var inner: FakeCloud
    var mode: String

    def __init__(out self, mode: String):
        self.inner = FakeCloud()
        self.mode = mode

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
        var nodes = self.inner.lower(r, edges, feeds, firings)
        if self.mode == "owner":
            for i in range(len(nodes)):
                nodes[i].owner = String("someone-else")
        return nodes^

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        if self.mode == "realize":
            raise Error("faulty: realize raised")
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


def test_a_raising_realize_and_a_broken_contract_are_not_typed() raises:
    """Catches: a raising `realize` typed as a refusal (the row's mutant),
    and a broken lowering contract typed as one."""
    var modes = List[String]()
    modes.append(String("realize"))
    modes.append(String("owner"))
    for m in range(len(modes)):
        var cloud = _Faulty(modes[m])
        var st = InMemoryStateStore()
        var p = _plan(cloud, String(_TWO), st)
        assert_true(p.raised, modes[m] + ": the plan raises")
        assert_false(Bool(p.refusal), modes[m] + ": not a refusal: " + p.text)
        var a = _apply(cloud, String(_TWO), st)
        assert_true(a.raised, modes[m] + ": the apply raises before any effect")
        assert_false(Bool(a.refusal), modes[m] + ": not a refusal: " + a.text)
        assert_equal(cloud.inner.mutations(), 0)
    print("  test_a_raising_realize_and_a_broken_contract_are_not_typed: PASS")


# ---- 3. a failed release ----------------------------------------------------------------------


def test_a_failed_release_is_typed_apart() raises:
    """Catches: a failed release told from an engine error only by its
    text (mutant: `failed_release` never set)."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var adopted = String('{"id":"logs","physicalName":"acme-logs","adopt":"ADOPT","bucket":{}},{"id":"reader","serviceAccount":{}}')
    var nodes = lower_data(cloud, _list(adopted))
    for i in range(len(nodes)):
        if nodes[i].adopted:
            cloud.plant_like(nodes[i])
    _done(apply_resources(_reg(), cloud, _ctx(), _list(adopted), Creds.none(), st))
    cloud.store[].fail_at_call = cloud.store[]._attempts + 1
    var refusal = Optional[Refusal](None)
    var out = apply_resources(
        _reg(), cloud, _ctx(), _list(String('{"id":"reader","serviceAccount":{}}')), Creds.none(), st, _no_defs(), refusal
    )
    assert_true(Bool(out.error), "the release failed")
    assert_true(out.release_failed(), "typed as a failed release: " + out.error.value())
    assert_equal(out.failed_release, "logs/bucket")
    assert_false(out.refused())
    assert_false(Bool(refusal))
    var fault = FakeCloud(fail_at_call=1)
    var fst = InMemoryStateStore()
    var stopped = apply_resources(_reg(), fault, _ctx(), _list(String(_TWO)), Creds.none(), fst)
    assert_true(Bool(stopped.error))
    assert_false(stopped.release_failed(), "an engine error is not a failed release")
    print("  test_a_failed_release_is_typed_apart: PASS")


# ---- 4. the plan reports what the apply leaves alone -------------------------------------


def _same(a: List[String], b: List[String], what: String) raises:
    assert_equal(len(a), len(b), what)
    for i in range(len(a)):
        assert_equal(a[i], b[i], what)


def test_the_plan_reports_leftover_and_left_behind() raises:
    """`data` (a bucket, KEEP by default) becomes a secret: its bucket is
    left behind; `old` leaves the file: leftover. Catches: either list
    dropped from `PlanReport` (the row's mutant drops `leftover`)."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    _done(
        apply_resources(
            _reg(), cloud, _ctx(), _list(String('{"id":"data","bucket":{}},{"id":"old","serviceAccount":{}}')), Creds.none(), st
        )
    )
    var next = _list(String('{"id":"data","secret":{}}'))
    var plan = plan_report(_reg(), cloud, _ctx(), next, Creds.none(), st)
    var out = apply_resources(_reg(), cloud, _ctx(), next, Creds.none(), st)
    _done(out)
    assert_true(len(out.leftover) > 0, "the apply reports leftover")
    assert_equal(len(out.left_behind), 1, "the apply reports the kept bucket")
    assert_equal(out.left_behind[0], "data/bucket")
    _same(plan.leftover, out.leftover, "leftover")
    _same(plan.left_behind, out.left_behind, "left_behind")
    print("  test_the_plan_reports_leftover_and_left_behind: PASS")


# ---- 5. a reference cycle ----------------------------------------------------------------------


def _svc(id: String, reads: String) -> String:
    var env = String("")
    if reads.byte_length() > 0:
        env = String(',"env":{"PEER":{"ref":{"resource":"') + reads + String('","standard":"URL"}}}')
    return String('{"id":"') + id + String('","service":{"image":{"digest":"sha256:a1"},"internal":{}') + env + String("}}")


def test_a_reference_cycle_is_typed_with_no_call() raises:
    """Two services each reading the other's URL, after a bucket. Catches:
    the cycle finding removed (the row's mutant: the apply returns
    `topo_sort`'s untyped engine error), and a walk that starts only from
    the first resource (mutant: the bucket first hides the cycle)."""
    var json = String('{"id":"logs","bucket":{}},') + _svc(String("web"), String("api")) + String(",") + _svc(String("api"), String("web"))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var p = _plan(cloud, json, st)
    assert_true(p.raised)
    var pf = _typed(p, False, FINDING_GRAPH, String("api"), String("plan"))
    assert_true(p.text.find("a reference cycle: api -> web -> api") >= 0, p.text)
    assert_equal(pf[0].field_path, "service.env.PEER")
    var a = _apply(cloud, json, st)
    assert_true(a.raised, "refused before any effect: " + a.text)
    _ = _typed(a, False, FINDING_GRAPH, String("api"), String("apply"))
    assert_equal(len(cloud.store[].calls), 0, "no call reached the fake")
    assert_equal(cloud.live_count(), 0)
    print("  test_a_reference_cycle_is_typed_with_no_call: PASS")


def _cycle_findings(json: String) raises -> List[String]:
    var found = validate_for(_reg(), FakeCloud(), _list(json))
    var out = List[String]()
    for i in range(len(found)):
        if found[i].reason.find("a reference cycle") >= 0:
            out.append(found[i].resource_id + String("|") + found[i].reason)
    return out^


def test_a_three_cycle_is_printed_once_from_its_smallest_id() raises:
    var json = (
        String('{"id":"logs","bucket":{}},')
        + _svc(String("cc"), String("aa"))
        + String(",")
        + _svc(String("bb"), String("cc"))
        + String(",")
        + _svc(String("aa"), String("bb"))
    )
    var found = _cycle_findings(json)
    assert_equal(len(found), 1, "one cycle, once")
    assert_true(found[0].startswith("aa|a reference cycle: aa -> bb -> cc -> aa"), found[0])
    var chain = _svc(String("aa"), String("bb")) + String(",") + _svc(String("bb"), String("cc")) + String(",") + _svc(String("cc"), String(""))
    assert_equal(len(_cycle_findings(chain)), 0, "a chain is no cycle")
    print("  test_a_three_cycle_is_printed_once_from_its_smallest_id: PASS")


def test_services_that_only_use_each_other_are_no_cycle() raises:
    """An edge of access lowers to a node of its own: two services that call
    each other plan."""
    var json = String(
        '{"id":"web","service":{"image":{"digest":"sha256:a1"},"internal":{}},'
        '"uses":[{"target":{"resource":"api"},"access":"CALL"}]},'
        '{"id":"api","service":{"image":{"digest":"sha256:a2"},"internal":{}},'
        '"uses":[{"target":{"resource":"web"},"access":"CALL"}]}'
    )
    assert_equal(len(_cycle_findings(json)), 0)
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var plan = plan_report(_reg(), cloud, _ctx(), _list(json), Creds.none(), st)
    assert_true(len(plan.actions) > 0, "it plans")
    print("  test_services_that_only_use_each_other_are_no_cycle: PASS")


def main() raises:
    print("test_fake_typed_refusal")
    test_a_validate_finding_is_typed()
    test_an_expansion_finding_is_typed()
    test_a_key_change_is_typed()
    test_an_adoption_finding_is_typed()
    test_a_foreign_object_is_typed_one_finding_per_node()
    test_a_conflict_is_typed()
    test_an_engine_fault_is_not_typed()
    test_a_raising_realize_and_a_broken_contract_are_not_typed()
    test_a_failed_release_is_typed_apart()
    test_the_plan_reports_leftover_and_left_behind()
    test_a_reference_cycle_is_typed_with_no_call()
    test_a_three_cycle_is_printed_once_from_its_smallest_id()
    test_services_that_only_use_each_other_are_no_cycle()
    print("ALL FAKE TYPED REFUSAL TESTS PASSED")
