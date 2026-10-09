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
#    And each of kci_cloud's own refusal sites, one test each: a scope with
#    no cell, a changed cloud name, a marked object without `adopt`, a
#    delete of an adopted object, and a replace of one under the plan and
#    under the apply's plan-first step. A returned outcome's refusal equals
#    the argument's, finding for finding.
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
#    printed from its smallest id, a cycle closed by a resource's second
#    reference is found (naming that reference), two references to the same
#    peer report the cycle once, the field is the first edge from the
#    smallest id to the next member, and two services that only `uses`
#    each other are no cycle. The finding kinds are pairwise distinct.
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
    FINDING_CELL,
    FINDING_COVERAGE,
    FINDING_LIMIT,
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


def _same_refusal(a: Optional[Refusal], b: Optional[Refusal]) -> String:
    """Empty when `a` and `b` are the same refusal (both None, or equal
    `by_engine`, `text` and findings: count, and each finding's kind,
    resource and field), else what differs."""
    if Bool(a) != Bool(b):
        return String("one is set and the other is not")
    if not a:
        return String("")
    ref x = a.value()
    ref y = b.value()
    if x.by_engine != y.by_engine:
        return String("by_engine differs")
    if x.text != y.text:
        return String("text differs: ") + x.text + String(" | ") + y.text
    if len(x.findings) != len(y.findings):
        return String("finding count differs: ") + String(len(x.findings)) + String(" vs ") + String(len(y.findings))
    for i in range(len(x.findings)):
        ref f = x.findings[i]
        ref g = y.findings[i]
        if f.kind != g.kind or f.resource_id != g.resource_id or f.field_path != g.field_path:
            return String("finding ") + String(i) + String(" differs")
    return String("")


def _apply[S: CloudAdapter](mut cloud: S, json: String, mut st: InMemoryStateStore, machine: String = String("shop")) raises -> _Seen:
    """An apply's refusal, raised or returned; a returned outcome's own
    `refusal` must be the one the argument got, finding for finding. The
    checks run outside the `try`, so a failed one is not taken for the
    verb's raise."""
    var seen = _Seen()
    var returned = False
    var differs = String("")
    var refused_agrees = True
    var landed = 0
    try:
        var out = apply_resources(_reg(), cloud, _ctx(machine), _list(json), Creds.none(), st, _no_defs(), seen.refusal)
        returned = True
        differs = _same_refusal(out.refusal, seen.refusal)
        refused_agrees = out.refused() == Bool(out.refusal)
        if out.error:
            seen.text = out.error.value()
        if out.refusal:
            landed = len(out.landed)
    except e:
        seen.raised = True
        seen.text = String(e)
    if returned:
        assert_equal(differs, "", "the outcome's refusal is the argument's")
        assert_true(refused_agrees, "refused() is the typed refusal")
        assert_equal(landed, 0, "a refusal lands nothing")
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


# ---- 1b. each of kci_cloud's own refusal sites, one test each ---------------------------------
#
# Each test reaches exactly one `_refuse` call (or the cell check) under the
# plan and under the apply, so that site raising its text without setting
# the refusal goes red here alone.


def test_a_scope_with_no_cell_is_typed() raises:
    """Catches: the cell check in `_valid_expansion` raising its text
    without setting `refusal`."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var json = String('{"id":"logs","bucket":{}}')
    var p = _plan(cloud, json, st, String(""))
    assert_true(p.raised, "the plan raises")
    var pf = _typed(p, False, FINDING_CELL, String("(cell)"), String("plan"))
    assert_equal(len(pf), 1)
    assert_equal(pf[0].field_path, "scope")
    var a = _apply(cloud, json, st, String(""))
    assert_true(a.raised, "the apply raises before any effect")
    _ = _typed(a, False, FINDING_CELL, String("(cell)"), String("apply"))
    assert_equal(cloud.mutations(), 0)
    print("  test_a_scope_with_no_cell_is_typed: PASS")


def test_a_name_change_is_typed() raises:
    """`logs` was created as `acme-logs` and the file now names it
    `acme-logs-2`. Catches: the name-change site in `_prepare` raising its
    text without setting `refusal`."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    _done(apply_resources(_reg(), cloud, _ctx(), _list(String('{"id":"logs","physicalName":"acme-logs","bucket":{}}')), Creds.none(), st))
    var before = cloud.mutations()
    var json = String('{"id":"logs","physicalName":"acme-logs-2","bucket":{}}')
    var p = _plan(cloud, json, st)
    assert_true(p.raised, "the plan raises")
    var pf = _typed(p, False, FINDING_GRAPH, String("logs"), String("plan"))
    assert_equal(pf[0].field_path, "physical_name")
    var a = _apply(cloud, json, st)
    assert_true(a.raised, "the apply raises before any effect")
    _ = _typed(a, False, FINDING_GRAPH, String("logs"), String("apply"))
    assert_equal(cloud.mutations(), before, "nothing changed")
    print("  test_a_name_change_is_typed: PASS")


comptime _ADOPTED_LOGS = '{"id":"logs","physicalName":"acme-logs","adopt":"ADOPT","bucket":{}}'
comptime _READER = '{"id":"reader","serviceAccount":{}}'


def _adopt_logs(mut cloud: FakeCloud, mut st: InMemoryStateStore, json: String) raises:
    """Plant what `json`'s adopted nodes declare, then apply `json`."""
    var nodes = lower_data(cloud, _list(json))
    for i in range(len(nodes)):
        if nodes[i].adopted:
            cloud.plant_like(nodes[i])
    _done(apply_resources(_reg(), cloud, _ctx(), _list(json), Creds.none(), st))


def test_a_marked_object_without_adopt_is_typed() raises:
    """A failed release leaves `logs/bucket` stamped and marked; the file
    names `logs` again without `adopt`. Catches: the marked-unadopted site
    in `_prepare` raising its text without setting `refusal`."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    _adopt_logs(cloud, st, String(_ADOPTED_LOGS) + String(",") + String(_READER))
    cloud.store[].fail_at_call = cloud.store[]._attempts + 1
    var out = apply_resources(_reg(), cloud, _ctx(), _list(String(_READER)), Creds.none(), st)
    assert_true(out.release_failed(), "the release failed, the mark stays")
    var before = cloud.mutations()
    var json = String('{"id":"logs","physicalName":"acme-logs","bucket":{}},') + String(_READER)
    var p = _plan(cloud, json, st)
    assert_true(p.raised, "the plan raises")
    var pf = _typed(p, False, FINDING_ADOPTION, String("logs"), String("plan"))
    assert_true(pf[0].reason.find("the object carries kci's adoption mark") >= 0, pf[0].reason)
    var a = _apply(cloud, json, st)
    assert_true(a.raised, "the apply raises before any effect")
    _ = _typed(a, False, FINDING_ADOPTION, String("logs"), String("apply"))
    assert_equal(cloud.mutations(), before, "nothing changed")
    print("  test_a_marked_object_without_adopt_is_typed: PASS")


def test_a_delete_of_an_adopted_object_is_typed() raises:
    """`logs` (adopted, retention DELETE, not ADOPT_DELETABLE) becomes a
    secret: the run would delete its bucket. Catches: the `delete_findings`
    site in `_prepare` raising its text without setting `refusal`."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    _adopt_logs(
        cloud,
        st,
        String('{"id":"logs","physicalName":"acme-logs","retention":"DELETE","adopt":"ADOPT","bucket":{}},')
        + String(_READER),
    )
    var before = cloud.mutations()
    var json = String('{"id":"logs","secret":{}},') + String(_READER)
    var p = _plan(cloud, json, st)
    assert_true(p.raised, "the plan raises")
    var pf = _typed(p, False, FINDING_ADOPTION, String("logs"), String("plan"))
    assert_true(pf[0].reason.find("the resource no longer lowers it") >= 0, pf[0].reason)
    var a = _apply(cloud, json, st)
    assert_true(a.raised, "the apply raises before any effect")
    _ = _typed(a, False, FINDING_ADOPTION, String("logs"), String("apply"))
    assert_equal(cloud.mutations(), before, "nothing changed")
    print("  test_a_delete_of_an_adopted_object_is_typed: PASS")


def _replace_setup(mut cloud: FakeCloud, mut st: InMemoryStateStore) raises -> String:
    """`logs/bucket` adopted, and the fake can change it only by a replace;
    returns the file that turns versioning on (a replace)."""
    _adopt_logs(cloud, st, String(_ADOPTED_LOGS))
    cloud.store[].replace_only(String("logs/bucket"))
    return String('{"id":"logs","physicalName":"acme-logs","adopt":"ADOPT","bucket":{"versioning":true}}')


def test_a_replace_is_typed_under_the_plan() raises:
    """Catches: the plan's `replace_findings` site raising its text without
    setting `refusal`."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var json = _replace_setup(cloud, st)
    var before = cloud.mutations()
    var p = _plan(cloud, json, st)
    assert_true(p.raised, "the plan raises")
    var pf = _typed(p, False, FINDING_ADOPTION, String("logs"), String("plan"))
    assert_true(pf[0].reason.find("this change would replace it") >= 0, pf[0].reason)
    assert_equal(cloud.mutations(), before, "nothing changed")
    print("  test_a_replace_is_typed_under_the_plan: PASS")


def test_a_replace_is_typed_under_the_apply() raises:
    """Catches: the apply's plan-first `replace_findings` site raising its
    text without setting `refusal`."""
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var json = _replace_setup(cloud, st)
    var before = cloud.mutations()
    var a = _apply(cloud, json, st)
    assert_true(a.raised, "the apply raises before any effect")
    var af = _typed(a, False, FINDING_ADOPTION, String("logs"), String("apply"))
    assert_true(af[0].reason.find("this change would replace it") >= 0, af[0].reason)
    assert_equal(cloud.mutations(), before, "nothing changed")
    print("  test_a_replace_is_typed_under_the_apply: PASS")


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


def _cycles(json: String) raises -> List[Finding]:
    """The reference-cycle findings validate gives for `json`."""
    var found = validate_for(_reg(), FakeCloud(), _list(json))
    var out = List[Finding]()
    for i in range(len(found)):
        if found[i].reason.find("a reference cycle") >= 0:
            out.append(found[i].copy())
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
    var cycles = _cycles(json)
    assert_equal(cycles[0].field_path, "service.env.PEER", "the field of aa's step to bb, the next member")
    var chain = _svc(String("aa"), String("bb")) + String(",") + _svc(String("bb"), String("cc")) + String(",") + _svc(String("cc"), String(""))
    assert_equal(len(_cycle_findings(chain)), 0, "a chain is no cycle")
    print("  test_a_three_cycle_is_printed_once_from_its_smallest_id: PASS")


def _svc_env(id: String, env: String) -> String:
    """A service whose `env` map is `env` (the JSON members, in order)."""
    return String('{"id":"') + id + String('","service":{"image":{"digest":"sha256:a1"},"internal":{},"env":{') + env + String("}}}")


def _ref(name: String, resource: String, standard: String) -> String:
    return String('"') + name + String('":{"ref":{"resource":"') + resource + String('","standard":"') + standard + String('"}}')


def test_a_cycle_closed_by_a_later_reference_is_found() raises:
    """`api` reads the bucket first and `web` second; `web` reads `api`.
    Catches: only a resource's first reference walked (mutant: the sites
    loop in `_Graph` stops after one; `api`'s only edge would be the
    bucket), and the field naming the first edge of `api` instead of the
    edge that closes the cycle."""
    var json = (
        String('{"id":"logs","bucket":{}},')
        + _svc_env(String("api"), _ref(String("A_LOGS"), String("logs"), String("NAME")) + String(",") + _ref(String("B_PEER"), String("web"), String("URL")))
        + String(",")
        + _svc(String("web"), String("api"))
    )
    var found = validate_for(_reg(), FakeCloud(), _list(json))
    var cycles = List[Finding]()
    for i in range(len(found)):
        if found[i].reason.find("a reference cycle") >= 0:
            cycles.append(found[i].copy())
    assert_equal(len(cycles), 1, "the cycle is found")
    assert_equal(cycles[0].resource_id, "api")
    assert_equal(cycles[0].field_path, "service.env.B_PEER", "the edge to web, not the first reference")
    assert_true(cycles[0].reason.startswith("a reference cycle: api -> web -> api"), cycles[0].reason)
    print("  test_a_cycle_closed_by_a_later_reference_is_found: PASS")


def test_two_edges_to_the_same_peer_report_the_cycle_once() raises:
    """`api` (listed first) reads `web`; `web` reads `api` twice, so the walk
    meets the back edge `web -> api` twice while `api` is on its stack.
    Catches: the dedupe of reported cycles dropped (mutant: the `keys`
    loop in `_report` skipped; the same finding twice)."""
    var json = (
        _svc(String("api"), String("web"))
        + String(",")
        + _svc_env(String("web"), _ref(String("A_PEER"), String("api"), String("URL")) + String(",") + _ref(String("B_PEER"), String("api"), String("HOST")))
    )
    var found = _cycle_findings(json)
    assert_equal(len(found), 1, "one cycle, reported once")
    assert_true(found[0].startswith("api|a reference cycle: api -> web -> api"), found[0])
    print("  test_two_edges_to_the_same_peer_report_the_cycle_once: PASS")


def test_the_field_is_the_first_of_two_edges_to_the_next_member() raises:
    """`api`, the smallest id, reads `web` twice (A_PEER, then B_PEER);
    `web` reads `api`. The field is the reference position of the first
    edge `api -> web` (`path_of`). Catches: `path_of` returning the last
    such edge (mutant: its loop walks backwards)."""
    var json = (
        _svc_env(String("api"), _ref(String("A_PEER"), String("web"), String("URL")) + String(",") + _ref(String("B_PEER"), String("web"), String("HOST")))
        + String(",")
        + _svc(String("web"), String("api"))
    )
    var cycles = _cycles(json)
    assert_equal(len(cycles), 1, "one cycle, once")
    assert_equal(cycles[0].resource_id, "api")
    assert_equal(cycles[0].field_path, "service.env.A_PEER", "the first edge api -> web")
    print("  test_the_field_is_the_first_of_two_edges_to_the_next_member: PASS")


def test_finding_kinds_are_distinct() raises:
    """A caller branches on a finding's kind, so no two kinds share a value.
    Catches: FINDING_OWNERSHIP given an existing kind's value (mutant: 5,
    FINDING_ADOPTION's)."""
    var kinds = List[Int]()
    kinds.append(FINDING_GRAPH)
    kinds.append(FINDING_COVERAGE)
    kinds.append(FINDING_LIMIT)
    kinds.append(FINDING_CELL)
    kinds.append(FINDING_ADOPTION)
    kinds.append(FINDING_OWNERSHIP)
    for i in range(len(kinds)):
        for k in range(i + 1, len(kinds)):
            assert_true(kinds[i] != kinds[k], String("kinds ") + String(i) + String(" and ") + String(k) + String(" share a value"))
    print("  test_finding_kinds_are_distinct: PASS")


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
    test_a_scope_with_no_cell_is_typed()
    test_a_name_change_is_typed()
    test_a_marked_object_without_adopt_is_typed()
    test_a_delete_of_an_adopted_object_is_typed()
    test_a_replace_is_typed_under_the_plan()
    test_a_replace_is_typed_under_the_apply()
    test_an_engine_fault_is_not_typed()
    test_a_raising_realize_and_a_broken_contract_are_not_typed()
    test_a_failed_release_is_typed_apart()
    test_the_plan_reports_leftover_and_left_behind()
    test_a_reference_cycle_is_typed_with_no_call()
    test_a_three_cycle_is_printed_once_from_its_smallest_id()
    test_a_cycle_closed_by_a_later_reference_is_found()
    test_two_edges_to_the_same_peer_report_the_cycle_once()
    test_the_field_is_the_first_of_two_edges_to_the_next_member()
    test_services_that_only_use_each_other_are_no_cycle()
    test_finding_kinds_are_distinct()
    print("ALL FAKE TYPED REFUSAL TESTS PASSED")
