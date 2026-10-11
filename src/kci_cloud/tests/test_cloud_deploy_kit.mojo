# =============================================================================
# test_cloud_deploy_kit.mojo
# =============================================================================
#
# plan / apply / destroy (deploy.mojo) over the `kit` cloud of
# test_cloud_conformance_kit.mojo, on the paths a cloud reaches only through
# its own objects and labels (sections 4 to 6: test_cloud_deploy_kit_names.mojo
# and test_cloud_deploy_kit_adopt.mojo):
#
# 1. THE LOWERING CONTRACT, on every run: a resource lowered to no nodes, a
#    node lowered twice, a desired field that is kci's metadata, a named
#    resource with no primary node to carry the name, a dependency on a
#    resource the list does not hold, a realized node that changed its id.
# 2. VALIDATE FIRST: a validation run id outside the rule, and a composite
#    instance of a definition not given, refuse the plan.
# 3. WHAT LIST_OWNED SAYS IS COUNTED ONCE: a cloud that reports each object
#    twice leaves one retained object behind, removes one turned-off role
#    and releases one adopted object, each once; the plan names the release.
#
# THE KIT CLOUD (the sections headed "the kit cloud") is the same text in
# test_cloud_conformance_kit{,_late,_member}.mojo and
# test_cloud_deploy_kit{,_adopt,_names}.mojo: a welded test is one file, and
# the runs are split so each file's coverage run stays short. Change all six.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.memory import ArcPointer

from komira_proto_codec import decode_json
from kci_reconciler import (
    CONVERGE_IN_PLACE, CellScope, ChangeAction, Creds, ErasedResource, InMemoryStateStore, InputRef, LABEL_CELL,
    LABEL_MACHINE, LABEL_RESOURCE, LABEL_ROLE, Label, ModelledDigest, Outputs, OwnerStamp, Provenance, RES_ABSENT,
    RES_FAILED, RETAIN_DELETE, RETAIN_KEEP, ResolvedInputs, Resource as EngineResource, ResourceStatus, VERB_CREATE,
    VERB_NOOP, VERB_REPLACE, VERB_UPDATE, unbound_error,
)
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    Absence, ApplyOutcome, ArtifactNeed, BootstrapItem, Catalog, CellContext, CloudId, Clouds, ConformanceTarget,
    ExistingObject, FIELD_SERVICE, FINDING_LIMIT, Feed, Finding, Firing, GrantEdge, LoweredNode, OwnedRecord, Principal,
    RUN_UNKNOWN, Setting, adopted_by, adoption_labels, apply_resources, body_field, create_labels, decode_label_value,
    describe, destroy_resources, is_kci_label_key, lower_data, lowered_budget_findings, plan_report, plan_resources,
    render_plan, retain_labels, retained_by, retention_label_key, run_conformance, shared_name_findings,
    standard_identity_of, standard_label_rule, validation_run_label_key, validation_run_labels, validation_run_of,
    MEMBER_FOREIGN, ROLE_UNMAPPED, Refusal, RegistryLogin,
)


# ---- the kit cloud: its memory ------------------------------------------------


@fieldwise_init
struct _Obj(Copyable, Movable):
    """One object, at its node id."""

    var id: String
    var kind: String
    var digest: String
    var url: String
    var labels: List[Label]
    var note: String
    var name: String
    var failed: Bool
    var extra: String
    var hidden: Bool
    var policy: String
    var member: String
    var role: String


@fieldwise_init
struct _Member(Copyable, Movable):
    """Planted out of band on `resource:<id>`'s or `cell:<name>`'s policy."""

    var policy: String
    var member: String
    var role: String


struct _Store(Movable):
    """Every object (a grant's is a member binding), every mutating call,
    the planted members, the creates that landed and failed, the defect."""

    var objs: List[_Obj]
    var calls: List[String]
    var defect: String
    var raced_id: String
    var race_next: Bool
    var phantom: String
    var aside: ExistingObject
    var aside_id: String
    var released: List[OwnedRecord]
    var foreign_seen: Bool
    var forget: String
    var members: List[_Member]
    var fail_after: String
    var failed_after: String
    var born: List[String]

    def __init__(out self, defect: String):
        self.objs = List[_Obj]()
        self.calls = List[String]()
        self.defect = defect
        self.raced_id = String("")
        self.race_next = False
        self.phantom = String("")
        self.aside = ExistingObject()
        self.aside_id = String("")
        self.released = List[OwnedRecord]()
        self.foreign_seen = False
        self.forget = String("")
        self.members = List[_Member]()
        self.fail_after = String("")
        self.failed_after = String("")
        self.born = List[String]()

    def find(self, id: String) -> Int:
        """The true state, hidden objects included."""
        for i in range(len(self.objs)):
            if self.objs[i].id == id:
                return i
        return -1

    def visible(self, id: String) -> Int:
        """What a read sees: a hidden object reads as absent."""
        var i = self.find(id)
        if i >= 0 and self.objs[i].hidden:
            return -1
        return i

    def insert(
        mut self, id: String, kind: String, digest: String, url: String, labels: List[Label], note: String, name: String,
        binding: List[String] = List[String](),
    ):
        var b = binding.copy() if binding else [String(""), String(""), String("")]
        self.objs.append(_Obj(id, kind, digest, url, labels.copy(), note, name, False, String(""), False, b[0], b[1], b[2]))

    def forgets(self, id: String) -> Bool:
        """`forget`; under member_forgets, web's cell grant once two members stand."""
        var i = self.find(id) if self.defect == "member_forgets" and len(self.members) > 1 else -1
        return id == self.forget or (i >= 0 and id.startswith("web/") and self.objs[i].policy.startswith("cell:"))

    def stamp_of(self, i: Int) -> String:
        if self.defect == "born_unread" and self.objs[i].id in self.born:
            return String("")
        return standard_identity_of(self.objs[i].labels)

    def member_of(self, i: Int, member: String, role: String) -> _Member:
        ref o = self.objs[i]
        var m = String("kit:outsider") if member == MEMBER_FOREIGN else o.member.copy()
        return _Member(o.policy, m^, String("kit.role/custom") if role == ROLE_UNMAPPED else o.role.copy())

    def members_report(self, i: Int) -> String:
        """The planted members on grant object `i`'s policy but its own."""
        var out = String("")
        for m in self.members:
            ref o = self.objs[i]
            if o.policy.byte_length() > 0 and m.policy == o.policy and (m.member != o.member or m.role != o.role):
                out += String("member ") + m.member + String(" holding ") + m.role + String(" (not this cell's); ")
        return String("a member (not this cell's); ") if out and self.defect == "member_report_fixed" else out^

    def strip_members(mut self, policy: String):
        var kept = List[_Member]()
        for m in self.members:
            if m.policy != policy:
                kept.append(m.copy())
        self.members = kept^

    def plant(mut self, id: String, kind: String, digest: String, name: String):
        """An object made outside kci: no stamp, not a served call."""
        self.insert(id, kind, digest, String(""), List[Label](), String(""), name)

    def create(
        mut self, id: String, kind: String, digest: String, url: String, labels: List[Label], note: String, name: String,
        binding: List[String] = List[String](),
    ) raises:
        if self.race_next:
            # A second apply of the same cell created it a moment earlier.
            self.race_next = False
            self.raced_id = id
            self.insert(id, kind, String("stale") if self.defect == "race_stale" else digest, url, labels, note, name, binding)
            self.calls.append(String("create ") + id)
            if self.defect == "race_double":
                self.calls.append(String("create ") + id)
        var at = self.find(id)
        if at >= 0 and self.defect == "born_recreated" and id in self.born:
            _ = self.objs.pop(at)  # this cloud's create overwrites
        elif at >= 0:
            raise Error(String("kit: ALREADY_EXISTS: ") + id)
        var two_step = self.defect == "stamp_after_create"  # labels in a second step
        self.insert(id, kind, digest, url, List[Label]() if two_step else labels.copy(), note, name, binding)
        self.calls.append(String("create ") + id)
        if self.fail_after.byte_length() > 0 and self.fail_after == id and self.defect != "fail_after_noop":
            # It landed as the request carried it; the caller hears an error.
            self.fail_after = String("")
            self.failed_after = id
            self.born.append(id)
            raise Error(String("kit: DEADLINE_EXCEEDED waiting for the create of ") + id + String(", which landed"))
        if two_step:
            self.objs[len(self.objs) - 1].labels = labels.copy()

    def at(mut self, verb: String, id: String) raises -> Int:
        """The visible object `id`, for a served call `verb`."""
        var i = self.visible(id)
        if i < 0:
            raise Error(String("kit: NOT_FOUND: ") + id)
        self.calls.append(verb + String(" ") + id)
        return i

    def update(mut self, id: String, digest: String, url: String, mark: Label) raises:
        var i = self.at(String("update"), id)
        self.objs[i].digest = digest
        self.objs[i].url = url
        self.objs[i].failed = False
        var kept = List[Label]()
        for l in self.objs[i].labels:
            if l.key != mark.key:
                kept.append(l.copy())
        kept.append(mark.copy())
        self.objs[i].labels = kept^

    def relabel(mut self, id: String, labels: List[Label], note: String, name: String) raises:
        var i = self.at(String("relabel"), id)
        self.objs[i].labels = labels.copy()
        self.objs[i].note = note
        self.objs[i].name = name

    def release(mut self, record: OwnedRecord) raises:
        if self.defect == "release_fails":
            raise Error(String("kit: release refused for ") + record.id)
        var i = self.at(String("release"), record.id)
        if self.defect == "release_deletes":
            _ = self.objs.pop(i)
            return
        if self.defect == "owned_remembers" or self.defect == "release_read_stamped":
            self.released.append(record.copy())
        var kept = List[Label]()
        var mark = retention_label_key()
        for l in self.objs[i].labels:
            if not is_kci_label_key(l.key) or (self.defect == "release_keeps_mark" and l.key == mark):
                kept.append(l.copy())
        self.objs[i].labels = kept^

    def _hides(self, i: Int, consumer: Bool) raises -> Bool:
        """Whether a delete of object `i` only hides it: a delete that reads
        as done and leaves the object standing."""
        ref d = self.defect
        if d == "delete_hides":
            return True
        if d == "consumer_hides":
            return consumer
        if d == "adopted_hides":
            return self.objs[i].note.startswith("adopt@")
        if d == "raced_hides":
            return self.objs[i].id == self.raced_id
        if d == "run_hides":
            return Bool(validation_run_of(self.objs[i].labels))
        if d == "born_leaves":
            return self.objs[i].id in self.born
        return False

    def remove(mut self, id: String, consumer: Bool) raises:
        self.calls.append(String("delete ") + id)
        var i = self.visible(id)
        if i < 0:
            return
        if self._hides(i, consumer):
            self.objs[i].hidden = True
            return
        _ = self.objs.pop(i)
        var res = String(id[byte = 0 : max(id.rfind("/"), 0)])  # its policy goes with its last object
        for o in self.objs:
            if o.id.startswith(res + String("/")):
                return
        self.strip_members(String("resource:") + res)

    def creates_of(self, id: String) -> Int:
        var n = 0
        for c in self.calls:
            if c == String("create ") + id:
                n += 1
        return n


# ---- the kit cloud: its engine node -------------------------------------------


def _static_digest(node: LoweredNode) raises -> String:
    var d = ModelledDigest(node.kind)
    for s in node.desired:
        d.field(s.key, s.value)
    return d.text()


struct _Node(EngineResource, Movable, Deinitable):
    var _store: ArcPointer[_Store]
    var _low: LoweredNode
    var _static: String
    var _bound: List[String]
    var _is_bound: Bool
    var _owner_calls: Int

    def __init__(out self, store: ArcPointer[_Store], node: LoweredNode) raises:
        self._store = store.copy()
        self._low = node.copy()
        self._static = _static_digest(node)
        self._bound = List[String]()
        self._is_bound = len(node.inputs) == 0
        self._owner_calls = 0

    def _defect(self) -> String:
        return self._store[].defect.copy()

    def _desired(self) raises -> String:
        if not self._is_bound:
            raise unbound_error(self._low.id, self._low.inputs[0])
        var d = self._static.copy()
        for i in range(len(self._low.inputs)):
            d += String("|") + self._low.inputs[i].field + String("=") + self._bound[i]
        return d^

    def _name(self) -> String:
        return self._low.field(String("physical_name"))

    def _url(self) -> String:
        if self._low.kind != "svc":
            return String("")
        var base = self._name()
        if base.byte_length() == 0:
            base = String(self._low.id[byte = 0 : self._low.id.rfind("/")])
        return String("https://") + base + String(".test")

    def logical_id(mut self) -> String:
        if self._defect() == "realize_renames":
            return self._low.id + String("x")
        return self._low.id.copy()

    def depends_on(mut self) -> List[String]:
        return self._low.depends_on.copy()

    def retention(mut self) -> Int:
        return self._low.retention

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        ref s = self._store[]
        ref id = self._low.id
        if s.defect == "plan_mutates":
            s.calls.append(String("read ") + id)
        if s.defect == "read_fault" and id == "web/run":
            raise Error(String("kit: read fault on ") + id)
        var i = s.visible(id)
        if i < 0:
            if s.defect == "phantom_present" and id == "api/public":
                return ResourceStatus.matched(id, self._static, String(""), String(""), s.phantom)
            return ResourceStatus.absent()
        var stamp = s.stamp_of(i)
        if s.defect == "born_recreated" and id in s.born:
            return ResourceStatus.absent()
        var members = s.members_report(i) if s.defect != "member_unreported" else String("")
        if s.defect == "member_read_strips" and members.byte_length() > 0:
            s.strip_members(s.objs[i].policy.copy())
        ref o = s.objs[i]
        if s.defect == "reads_mutate_present" or (s.defect == "member_read_rewrites" and members.byte_length() > 0):
            s.calls.append(String("read ") + id)
        if s.defect == "race_ghost_create" and id == s.raced_id:
            s.calls.append(String("create ") + id)
        var extra = String("")
        if o.extra.byte_length() > 0 and s.defect != "hide_unmanaged":
            extra = String("label ") + o.extra + String(" (not modelled; left as it is)")
        if o.extra.byte_length() > 0 and s.defect == "unmodelled_read_mutates":
            s.calls.append(String("read ") + id)
        extra += members
        if o.failed:
            if s.defect == "fail_once":
                o.failed = False
            return ResourceStatus(RES_FAILED, id, o.digest, String("kit: not ready"), o.url, String(""), stamp, extra)
        var drift = s.defect == "member_drifts" and members.byte_length() > 0
        if self._is_bound and o.digest == self._desired() and not drift:
            return ResourceStatus.matched(id, o.digest, o.url, String(""), stamp, extra)
        return ResourceStatus.drifted(id, o.digest, o.url, String(""), stamp, extra)

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        ref s = self._store[]
        var i = s.visible(self._low.id)
        if i < 0:
            return ResourceStatus.absent()
        var stamp = s.stamp_of(i)
        if s.defect == "foreign_read_mutates" and stamp.byte_length() == 0:
            s.calls.append(String("read ") + self._low.id)
        if s.defect == "foreign_seen_once" and stamp.byte_length() == 0:
            if s.foreign_seen:
                return ResourceStatus.absent()
            s.foreign_seen = True
        return ResourceStatus.drifted(self._low.id, String(""), s.objs[i].url, String(""), stamp)

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var verb = VERB_UPDATE
        if live.phase == RES_ABSENT:
            verb = VERB_UPDATE if self._defect() == "plan_update" else VERB_CREATE
        elif live.is_matched():
            verb = VERB_NOOP
        elif self._defect() == "replace_drift":
            verb = VERB_REPLACE
        return ChangeAction(self._low.id, verb, String("kit"), self._low.retention)

    def create(mut self, creds: Creds) raises -> String:
        raise Error(String("kit: an unstamped create"))

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        var defect = self._defect()
        if defect == "create_fails" and self._low.id == "api/run":
            raise Error(String("kit: create refused for ") + self._low.id)
        var labels = create_labels(stamp, self._low.retention)
        if defect == "wrong_mark":
            labels = standard_label_rule(stamp)
            labels.extend(validation_run_labels(stamp))
            labels.extend(retain_labels(RETAIN_KEEP))
        elif defect == "run_label_missing":
            labels = standard_label_rule(stamp)
            labels.extend(retain_labels(self._low.retention))
        elif defect == "run_label_stale" and stamp.validation_run_id:
            labels = standard_label_rule(stamp)
            labels.append(Label(validation_run_label_key(), String("kit-run-000000")))
            labels.extend(retain_labels(self._low.retention))
        elif defect == "bad_label":
            labels.append(Label(String("Bad"), String("x")))
        var digest = self._desired()
        if defect == "provenance_digest":
            digest += String("|run=") + stamp.provenance.run_id
        self._store[].create(
            self._low.id, self._low.kind, digest, self._url(), labels, stamp.provenance.run_id, self._name(),
            self._binding(),
        )
        return self._low.id.copy()

    def _binding(self) -> List[String]:
        """A grant's `[policy, member, role]`: its principal holding its verb's role."""
        var out = List[String]()
        ref n = self._low
        if n.kind == "grant":
            var cell = n.field(String("cell"))
            out.append(String("cell:") + cell if cell else String("resource:") + n.field(String("target")))
            out.append(n.field(String("principal")))
            out.append(String("kit.role/") + n.field(String("access")))
        return out^

    def adopt_owned(mut self, stamp: OwnerStamp, physical_id: String, creds: Creds) raises:
        var defect = self._defect()
        var labels = standard_label_rule(stamp)
        if defect == "adopt_unstamped":
            labels = List[Label]()
        labels.extend(retain_labels(self._low.retention))
        if defect != "adopted_unmarked":
            labels.extend(adoption_labels(self._low.adopted))
        self._store[].relabel(physical_id, labels, String("adopt@") + stamp.provenance.run_id, self._name())

    def update(mut self, creds: Creds) raises:
        self._store[].update(self._low.id, self._desired(), self._url(), retain_labels(self._low.retention)[0])

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._store[].remove(physical_id, len(self._low.inputs) > 0)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE

    def input_refs(mut self) -> List[InputRef]:
        return self._low.inputs.copy()

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        var vals = List[String]()
        for r in self._low.inputs:
            vals.append(resolved.value_of(self._low.id, r.producer, r.output))
        self._bound = vals^
        self._is_bound = True

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        var o = Outputs()
        if self._low.kind == "svc":
            o.set(String("URL"), self._url())
        return o^

    def owner(mut self) -> String:
        self._owner_calls += 1
        if self._defect() == "owner_fades" and self._owner_calls > 1:
            return String("")
        return self._low.owner.copy()

    def stamps_ownership(mut self) -> Bool:
        return True

    def wanted(mut self) -> Bool:
        return self._low.wanted


# ---- the kit cloud: the adapter -----------------------------------------------


def _lower(r: Resource, edges: List[GrantEdge]) raises -> List[LoweredNode]:
    """A service: `<id>/run` (image, port, literal env; a reference env is an
    input) and `<id>/public` (wanted iff public). Any other type: its primary
    role, empty. Every type: one `<id>/<role>` grant per edge."""
    var catalog = Catalog.v1()
    var out = List[LoweredNode]()
    if body_field(r) == FIELD_SERVICE:
        ref s = r.service.value()
        var d = List[Setting]()
        d.append(Setting(String("img"), s.image.value().digest.value()))
        d.append(Setting(String("port"), String(Int(s.port))))
        var refs = List[InputRef]()
        for e in s.env.items():  # the graphs here write one reference at most
            if e.value._oneof0_case == 3:
                ref rf = e.value.ref_.value()
                refs.append(InputRef(rf.resource, rf.standard.value().json_name(), String("env.") + e.key))
        out.append(LoweredNode(r.id + String("/run"), r.id, String("svc"), List[String](), refs^, d^))
        var deps = List[String]()
        deps.append(r.id + String("/run"))
        var p = List[Setting]()
        p.append(Setting(String("mechanism"), String("edge")))
        out.append(LoweredNode(r.id + String("/public"), r.id, String("ingress"), deps^, List[InputRef](), p^, s._oneof0_case == 1))
    else:
        ref t = catalog.types[catalog.index_of(body_field(r))]
        if t.primary_role != "grant":
            out.append(LoweredNode(r.id + String("/") + t.primary_role, r.id, t.name))
    for e in edges:
        var g = List[Setting]()
        var deps = List[String]()
        if e.on_cell():
            g.append(Setting(String("cell"), e.cell))
        else:
            g.append(Setting(String("target"), e.target))
            deps.append(e.target)
        g.append(Setting(String("access"), e.access))
        g.append(Setting(String("principal"), e.principal))
        out.append(LoweredNode(r.id + String("/") + e.role, r.id, String("grant"), deps^, List[InputRef](), g^))
    return out^


def _label(labels: List[Label], key: String) -> String:
    for l in labels:
        if l.key == key:
            return decode_label_value(l.value)
    return String("")


struct _Kit(ConformanceTarget, Movable):
    """A complete cloud, `kit`, that hosts every catalog type."""

    var store: ArcPointer[_Store]

    def __init__(out self, defect: String = String("")):
        self.store = ArcPointer[_Store](_Store(defect))

    def _defect(self) -> String:
        return self.store[].defect.copy()

    def cloud_id(self) -> CloudId:
        return CloudId(String("kit"))

    def complete(self) -> Bool:
        return True

    def implemented(self) -> List[Int]:
        var l = List[Int]()
        try:
            var catalog = Catalog.v1()
            for t in catalog.types:
                l.append(t.field)
        except:
            pass  # the catalog is a constant table: v1 does not raise
        return l^

    def absences(self) -> List[Absence]:
        return List[Absence]()

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        if self._defect() == "adopt_vanishes" and len(ctx.scope.adopt) > 0:
            # What stands unstamped is gone by the time the adoption runs.
            var keep = List[_Obj]()
            for o in self.store[].objs:
                if standard_identity_of(o.labels).byte_length() > 0:
                    keep.append(o.copy())
            self.store[].objs = keep^
        return List[Finding]()

    def public_mechanism(self) -> String:
        return String("edge")

    def check(self, r: Resource, feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
        var l = List[Finding]()
        if self._defect() == "refuse_named" and r.physical_name:
            l.append(Finding(FINDING_LIMIT, r.id, String("physical_name"), String("kit: no cloud names"), String("kit"), True))
        return l^

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return ArtifactNeed(String("oci-image"), String("linux/amd64"))

    def lower(self, r: Resource, edges: List[GrantEdge], feeds: List[Feed], firings: List[Firing]) raises -> List[LoweredNode]:
        var out = List[LoweredNode]()
        for n in _lower(r, edges):
            if not self.store[].forgets(n.id):
                out.append(n.copy())
        var d = self._defect()
        if d == "grantless_edge" and r.id == "g":  # a principal and a target, and no access
            var f: List[Setting] = [Setting(String("principal"), String("api")), Setting(String("target"), String("web"))]
            out.insert(0, LoweredNode(String("g/route"), r.id, String("route"), List[String](), List[InputRef](), f^))
        if d == "lower_raises" and r.id == "boom":
            raise Error(String("kit: cannot lower boom"))
        if not r.id.startswith("api"):
            return out^
        if d == "lower_none":
            return List[LoweredNode]()
        if d == "lower_twice":
            out.append(out[0].copy())
        elif d == "lower_metadata":
            out[0].desired.append(Setting(String("label.team"), String("x")))
        elif d == "lower_unnamed":
            out[0].id = r.id + String("/server")
        elif d == "lower_dep_ghost":
            out[0].depends_on.append(String("ghost"))
        return out^

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        return ErasedResource.erase(_Node(self.store, node))

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        return List[BootstrapItem]()

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return standard_label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        var defect = self._defect()
        if defect == "identity_wrong":
            return String("nobody")
        if defect == "identity_hides_adopted" and adopted_by(labels):
            return String("")
        return standard_identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        var out = List[OwnedRecord]()
        ref s = self.store[]
        for o in s.objs:
            if o.hidden or s.forgets(o.id) or standard_identity_of(o.labels).byte_length() == 0:
                continue
            if _label(o.labels, String(LABEL_MACHINE)) != scope.machine or _label(o.labels, String(LABEL_CELL)) != scope.cell:
                continue
            var node = _label(o.labels, String(LABEL_RESOURCE)) + String("/") + _label(o.labels, String(LABEL_ROLE))
            var marked = adopted_by(o.labels) and s.defect != "owned_hides_mark"
            out.append(
                OwnedRecord(
                    o.kind, o.id, String("kit"), String("none"), String("0"), String(RUN_UNKNOWN), True, node,
                    retained_by(o.labels), String(""), validation_run_of(o.labels), o.name, marked,
                )
            )
        if s.defect == "owned_twice":
            out.extend(out.copy())
        if s.defect == "owned_remembers":
            out.extend(s.released.copy())
        if s.defect == "phantom_owned":
            out.append(
                OwnedRecord(
                    String("svc"), String("api/ghost"), String("kit"), String("none"), String("0"),
                    String(RUN_UNKNOWN), True, String("api/ghost"), False, String(""), None,
                )
            )
        return out^

    def read_existing(mut self, creds: Creds, node: LoweredNode) raises -> ExistingObject:
        ref s = self.store[]
        if s.aside_id == node.id:
            return s.aside.copy()
        var i = s.visible(node.id)
        if i < 0:
            return ExistingObject()
        if s.defect == "release_read_stamped" and len(s.released) > 0:
            return ExistingObject(True, True, s.objs[i].kind, s.objs[i].name)
        var kind = String("other") if s.defect == "existing_wrong_kind" else s.objs[i].kind
        return ExistingObject(True, standard_identity_of(s.objs[i].labels).byte_length() > 0, kind, s.objs[i].name)

    def release(mut self, creds: Creds, record: OwnedRecord) raises:
        self.store[].release(record)

    def whoami(mut self, creds: Creds) raises -> Principal:
        return Principal(creds.token, String("kit"))

    def trust_render(self, scope: CellScope) -> String:
        return String("kit: any caller")

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        return List[Finding]()

    def live_count(self) -> Int:
        var n = len(self.store[].objs)
        if self._defect() == "live_inflated" and n > 0:
            n += 1
        return n

    def mutations(self) -> Int:
        return len(self.store[].calls)

    def _live(mut self, logical_id: String) raises -> Int:
        var i = self.store[].visible(logical_id)
        if i < 0:
            raise Error(String("kit: no live ") + logical_id)
        return i

    def tamper(mut self, logical_id: String) raises:
        var i = self.store[].visible(logical_id)
        if i < 0:
            return  # nothing stands there: nothing to change
        var defect = self._defect()
        if defect == "tamper_noop" or (defect == "tamper_skips_named" and self.store[].objs[i].name.byte_length() > 0):
            return
        self.store[].objs[i].digest = String("changed-out-of-band")

    def tamper_unmodelled(mut self, logical_id: String) raises:
        var i = self._live(logical_id)
        if self._defect() == "unmodelled_is_modelled":
            self.store[].objs[i].digest = String("changed-out-of-band")
            return
        if self._defect() == "forget_unmodelled":
            self.store[].forget = logical_id  # its lowering now leaves the node out
            return
        self.store[].objs[i].extra = String("team=payments")

    def unmodelled(self, logical_id: String) -> String:
        var i = self.store[].find(logical_id)
        if i < 0 or self._defect() == "unmodelled_hook_empty":
            return String("")
        return self.store[].objs[i].extra.copy()

    def fail(mut self, logical_id: String) raises:
        var i = self._live(logical_id)
        var defect = self._defect()
        if defect == "fail_noop":
            return
        self.store[].objs[i].failed = True
        if defect == "fail_spills":
            self.store[].objs[self._live(String("web/run"))].digest = String("changed-out-of-band")

    def live_labels(self, logical_id: String) -> List[Label]:
        var i = self.store[].find(logical_id)
        if i < 0:
            return List[Label]()
        return self.store[].objs[i].labels.copy()

    def plant_foreign(mut self, logical_id: String) raises:
        var defect = self._defect()
        if defect == "plant_foreign_noop":
            return
        self.store[].plant(logical_id, String("foreign"), String("made-outside-kci"), String(""))
        if defect == "plant_foreign_twice":
            self.store[].plant(String("zz/stray"), String("foreign"), String("made-outside-kci"), String(""))

    def plant_like(mut self, node: LoweredNode) raises:
        var defect = self._defect()
        if defect == "plant_like_noop":
            return
        var name = node.field(String("physical_name"))
        if defect == "plant_elsewhere":
            # Seen by the adoption read only, never by the engine's reads.
            self.store[].aside = ExistingObject(True, False, node.kind, name)
            self.store[].aside_id = node.id.copy()
            return
        self.store[].plant(node.id, node.kind, _static_digest(node), name)

    def race_next_create(mut self):
        if self._defect() != "race_noop":
            self.store[].race_next = True

    def raced(self) -> String:
        if self._defect() == "raced_hidden":
            return String("")
        return self.store[].raced_id.copy()

    def creates_of(self, logical_id: String) -> Int:
        return self.store[].creates_of(logical_id)

    def image_registry(self, ctx: CellContext) -> String:
        return String("registry.kit.test/") + ctx.scope.machine + String("/") + ctx.scope.cell

    def registry_login(mut self, creds: Creds) raises -> RegistryLogin:
        return RegistryLogin(String("kit"), creds.token)

    def plant_foreign_member(mut self, node: String, member: String, role: String) raises:
        ref s = self.store[]
        var i = s.visible(node)
        if i < 0 or s.objs[i].policy.byte_length() == 0:
            raise Error(String("kit: no binding at ") + node)
        if s.defect != "member_plant_noop":
            s.members.append(s.member_of(i, member, role))
        if s.defect == "member_plant_object" and s.find(String("zz/member")) < 0:
            s.plant(String("zz/member"), String("foreign"), String("made-outside-kci"), String(""))

    def member_present(self, node: String, member: String, role: String) -> Bool:
        ref s = self.store[]
        var i = s.visible(node)
        if i < 0:
            return False
        var w = s.member_of(i, member, role)
        if s.objs[i].member == w.member and s.objs[i].role == w.role:
            return True
        for p in s.members:
            if p.policy == w.policy and p.member == w.member and p.role == w.role:
                return True
        return False

    def fail_after_create_of(mut self, node: String):
        self.store[].fail_after = node
        self.store[].failed_after = String("")

    def failed_after_create(self) -> String:
        if self._defect() == "fail_after_misreport":
            return String("")
        return self.store[].failed_after.copy()


# ---- helpers ------------------------------------------------------------------


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _api(more: String = String("")) raises -> List[Resource]:
    """One internal service `api` (api/run, api/public turned off, its cell
    grant), with `more` written into the resource."""
    return _list(
        String('{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":8081,"internal":{}}')
        + more
        + String("}]}")
    )


def _named(name: String, adopt: String = String("")) raises -> List[Resource]:
    var more = String(',"physicalName":"') + name + String('"')
    if adopt.byte_length() > 0:
        more += String(',"adopt":"') + adopt + String('"')
    return _api(more)


def _reg(cloud: _Kit) raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    return reg^


def _plan_error(mut cloud: _Kit, resources: List[Resource], ctx: CellContext = _ctx()) -> String:
    try:
        var store = InMemoryStateStore()
        _ = plan_resources(_reg(cloud), cloud, ctx, resources, Creds.none(), store)
    except e:
        return String(e)
    return String("it planned")


def _apply(mut cloud: _Kit, resources: List[Resource], mut store: InMemoryStateStore) raises -> ApplyOutcome:
    return apply_resources(_reg(cloud), cloud, _ctx(), resources, Creds.none(), store)


def _apply_error(mut cloud: _Kit, resources: List[Resource], mut store: InMemoryStateStore) -> String:
    try:
        _ = _apply(cloud, resources, store)
    except e:
        return String(e)
    return String("it applied")


def _destroy_error(mut cloud: _Kit, resources: List[Resource], mut store: InMemoryStateStore) -> String:
    try:
        _ = destroy_resources(_reg(cloud), cloud, _ctx(), resources, Creds.none(), store)
    except e:
        return String(e)
    return String("it destroyed")


def _has(s: String, part: String) -> Bool:
    return s.find(part) >= 0


def _stamped(owner: String, node: String, adopted: Bool, retention: Int) raises -> List[Label]:
    """The labels kci writes on `node` of `owner` in the test cell."""
    var labels = standard_label_rule(_ctx().scope.stamp(owner, node))
    labels.extend(retain_labels(retention))
    labels.extend(adoption_labels(adopted))
    return labels^


# ---- 1. the lowering contract -------------------------------------------------


def _lowering_error(defect: String, resources: List[Resource]) -> String:
    var cloud = _Kit(defect)
    try:
        _ = lower_data(cloud, resources)
    except e:
        return String(e)
    return String("it lowered")


def test_the_lowering_contract_holds() raises:
    assert_equal(_lowering_error(String("lower_none"), _api()), "cloud \"kit\" lowered resource \"api\" to no nodes")
    assert_equal(_lowering_error(String("lower_twice"), _api()), "cloud \"kit\" lowered node \"api/run\" twice")
    assert_equal(
        _lowering_error(String("lower_metadata"), _api()),
        "cloud \"kit\" broke the lowering contract on \"api/run\": it wrote the desired field \"label.team\","
        + " which is kci's (the metadata)",
    )
    assert_equal(
        _lowering_error(String("lower_unnamed"), _named(String("alpha"))),
        "cloud \"kit\" lowered no primary node \"api/run\" to hold the cloud name of \"api\"",
    )
    assert_equal(_lowering_error(String("lower_unnamed"), _api()), "it lowered")  # no name to hold
    assert_equal(
        _lowering_error(String("lower_dep_ghost"), _api()),
        "a reference to \"ghost\" names no resource of the catalog in this list",
    )
    var renames = _Kit(String("realize_renames"))
    assert_equal(
        _plan_error(renames, _api()),
        "cloud \"kit\" realized node \"api/run\" as \"api/runx\" owned by \"api\"; realize must keep the id,"
        + " owner and wanted",
    )


# ---- 2. validate first --------------------------------------------------------


def test_a_bad_run_id_and_an_expansion_finding_refuse_the_plan() raises:
    var cloud = _Kit()
    var ctx = _ctx()
    ctx.scope.validation_run_id = String("Bad Id")
    var e = _plan_error(cloud, _api(), ctx)
    assert_true(e.startswith("kci: cannot apply this graph to cloud \"kit\". Nothing was created."), e)
    assert_true(
        _has(e, "resource \"(cell)\" field validation_run_id: validation run id \"Bad Id\" is not 1 to 63 bytes"), e
    )
    var inst = _list(String('{"resource":[{"id":"o","composite":{"definition":"acme.none","version":"1"}}]}'))
    e = _plan_error(cloud, inst)
    assert_true(_has(e, "\n  resource \"o\""), e)
    assert_equal(cloud.mutations(), 0)
    # The engine's refusal of a foreign object reaches the plan's caller typed.
    cloud.plant_foreign(String("api/run"))
    var refusal = Optional[Refusal](None)
    var store = InMemoryStateStore()
    try:
        _ = plan_report(_reg(cloud), cloud, _ctx(), _api(), Creds.none(), store, List[CompositeDefinition](), refusal)
    except:
        pass
    assert_true(Bool(refusal) and refusal.value().by_engine, "the engine's refusal")
    assert_equal(refusal.value().findings[0].field_path, "api/run")


# ---- 3. what list_owned says is counted once ----------------------------------


def test_each_owned_object_is_counted_once() raises:
    var cloud = _Kit(String("owned_twice"))
    var store = InMemoryStateStore()
    assert_false(Bool(_apply(cloud, _api(), store).error))
    var s = cloud.store
    s[].insert(String("api/old"), String("svc"), String("d"), String(""), _stamped(String("api"), String("api/old"), False, RETAIN_KEEP), String("x"), String(""))
    s[].insert(String("api/off"), String("svc"), String("d"), String(""), _stamped(String("api"), String("api/off"), False, RETAIN_DELETE), String("x"), String(""))
    s[].insert(String("gone/run"), String("svc"), String("d"), String(""), _stamped(String("gone"), String("gone/run"), True, RETAIN_DELETE), String("x"), String(""))
    var report = plan_report(_reg(cloud), cloud, _ctx(), _api(), Creds.none(), store)
    assert_equal(len(report.released), 1)
    assert_equal(report.released[0], "gone/run")
    var off = 0
    for a in report.actions:
        if a.logical_id == "api/off":
            off += 1
    assert_equal(off, 1)
    assert_true(_has(render_plan(report), "\ngone: release gone/run (adopted;"))
    var o = _apply(cloud, _api(), store)
    assert_false(Bool(o.error))
    assert_equal(len(o.left_behind), 1)
    assert_equal(o.left_behind[0], "api/old")
    assert_equal(len(o.released), 1)
    assert_equal(o.released[0], "gone/run")


def main() raises:
    test_the_lowering_contract_holds()
    test_a_bad_run_id_and_an_expansion_finding_refuse_the_plan()
    test_each_owned_object_is_counted_once()
