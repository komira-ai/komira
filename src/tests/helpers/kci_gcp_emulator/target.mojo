# =============================================================================
# kci_gcp_emulator/target.mojo: the GCP adapter over the emulator, as a
# conformance kit target.
# =============================================================================
#
# `EmulatedGcpCloud` is kci_cloud_gcp's `GcpCloud` built over five
# `EmulatorConnector`s to one shared emulator, with every service pointed at
# the emulator's IP-literal hosts and the emulator's token: every adapter
# method is the adapter's own, forwarded unchanged, so the kit drives the
# real wire code. The kit's OBSERVATION HOOKS read and change the emulator's
# state directly, never through the adapter, so a hook cannot agree with an
# adapter bug:
#   * a node's object is found by the name the node's lowering gives it
#     (its physical name, else kci_cloud_gcp's derived name); a binding's by
#     its member (its principal's account), its target (the account it is
#     on, or the project for a cell edge) and the role G4's table gives;
#   * `live_labels` of an account is its description read line by line as
#     labels (whatever else it holds, so a kci line a release left behind is
#     seen), of a job its labels, and of a binding what kci_cloud's
#     attribution derives from the emulator's accounts (steps 3, 12, 13 and
#     15);
#   * `tamper` changes a modelled field (an account's display name, a job's
#     timeout), `tamper_unmodelled` adds a label a console would, `fail` puts
#     a job in the failed state;
#   * `plant_foreign`, `plant_like` and `plant_foreign_member` put objects
#     and members in place out of band (never a served call, never counted
#     as a mutation): a planted FOREIGN member is an account stamped by
#     another cell of the same machine (`outside`, never a node of this one),
#     and an UNMAPPED role is one G4's table does not hold;
#   * the race and fail-after hooks arm the emulator's create paths
#     (emu_state.mojo), keyed by the node's object.
# The adapter must be configured before a hook names a node: the hooks read
# the machine and cell the last `configure` was given.
# =============================================================================

from std.memory import ArcPointer

from kci_cloud import (
    Absence,
    ArtifactNeed,
    BindingEnd,
    BootstrapItem,
    CellContext,
    CloudId,
    ConformanceTarget,
    ExistingObject,
    Feed,
    Finding,
    Firing,
    GrantEdge,
    LoweredNode,
    OwnedRecord,
    Principal,
    RegistryLogin,
    attribute,
    description_labels,
    description_lines,
    encode_label_value,
    role_for,
)
from kci_cloud_gcp import (
    GcpCloud,
    GcpConnectors,
    GcpEndpoint,
    GcpEndpoints,
    KIND_ACCOUNT,
    KIND_BINDING,
    KIND_JOB,
    ModelField,
    account_email,
    account_member,
    account_resource,
    desired_model,
    display_name_of,
    gcp_role_table,
    job_json,
    job_resource,
    object_name,
    project_resource,
)
from kci_reconciler import CellScope, Creds, ErasedResource, LABEL_CELL, Label, OwnerStamp, RETAIN_DELETE
from kci_resource_proto.resource import Resource
from komira_gcp_core import StaticTokenSource
from komira_json import JsonValue

from kci_gcp_emulator.emu_http import parse_object, str_member, with_member
from kci_gcp_emulator.emu_state import (
    CRM_HOST,
    EMU_TOKEN,
    IAM_HOST,
    RUN_HOST,
    TOKENINFO_HOST,
    EmuAccount,
    EmuJob,
    GcpEmulator,
)
from kci_gcp_emulator.emu_stream import EmulatorConnector


comptime UNMAPPED_ROLE = "roles/editor"
"""The role step 14 plants for ROLE_UNMAPPED: in no row of G4's table."""
comptime OUTSIDE_SUFFIX = "-elsewhere"
"""What a planted foreign member's cell is: the node's cell and this."""
comptime UNMODELLED_LABEL = "console-edit"


def emulator_endpoints() -> GcpEndpoints:
    """Every service at the emulator's IP-literal host, over plain http."""
    return GcpEndpoints(
        GcpEndpoint(String(IAM_HOST), UInt16(0), True),
        GcpEndpoint(String(CRM_HOST), UInt16(0), True),
        GcpEndpoint(String(RUN_HOST), UInt16(0), True),
        GcpEndpoint(String(TOKENINFO_HOST), UInt16(0), True),
    )


def emulated_adapter(emu: ArcPointer[GcpEmulator]) raises -> GcpCloud[EmulatorConnector, StaticTokenSource]:
    """kci_cloud_gcp's adapter over the emulator (the file header)."""
    return GcpCloud[EmulatorConnector, StaticTokenSource](
        GcpConnectors[EmulatorConnector](
            EmulatorConnector(emu),
            EmulatorConnector(emu),
            EmulatorConnector(emu),
            EmulatorConnector(emu),
            EmulatorConnector(emu),
        ),
        StaticTokenSource(String(EMU_TOKEN)),
        emulator_endpoints(),
    )


struct EmulatedGcpCloud(ConformanceTarget, Movable):
    """The adapter, over the emulator, with the kit's hooks (the file
    header)."""

    var cloud: GcpCloud[EmulatorConnector, StaticTokenSource]
    var emu: ArcPointer[GcpEmulator]
    var nodes: List[LoweredNode]
    var machine: String
    var cell: String
    var armed: String

    def __init__(out self, emu: ArcPointer[GcpEmulator]) raises:
        self.cloud = emulated_adapter(emu)
        self.emu = emu.copy()
        self.nodes = List[LoweredNode]()
        self.machine = String("")
        self.cell = String("")
        self.armed = String("")

    # --- what a node's object is called -----------------------------------

    def _node(self, id: String) -> Optional[LoweredNode]:
        for i in range(len(self.nodes)):
            if self.nodes[i].id == id:
                return self.nodes[i].copy()
        return None

    def _name(self, id: String) -> String:
        var physical = String("")
        var n = self._node(id)
        if n:
            physical = n.value().field(String("physical_name"))
        return object_name(self.machine, self.cell, id, physical)

    def _email(self, id: String) -> String:
        return account_email(self._name(id), self.emu[].project)

    def _kind(self, id: String) -> String:
        var n = self._node(id)
        if not n:
            return String("")
        return n.value().kind.copy()

    def _spot(self, id: String) raises -> Tuple[String, String, String]:
        """A binding node's (resource, member, role)."""
        var n = self._node(id)
        if not n:
            raise Error(String("target: no binding node ") + id)
        ref node = n.value()
        var member = account_member(self._email(node.depends_on[0]))
        var access = node.field(String("access"))
        var cell = node.field(String("cell"))
        var rows = gcp_role_table()
        if cell.byte_length() > 0:
            var role = role_for(rows, String("cell/") + cell, access)
            return (project_resource(self.emu[].project), member^, role.value().copy())
        var role = role_for(rows, String(KIND_ACCOUNT), access)
        return (account_resource(self.emu[].project, self._email(node.depends_on[1])), member^, role.value().copy())

    def _key(self, id: String) raises -> String:
        """The emulator's key of a node's object."""
        var kind = self._kind(id)
        if kind == KIND_ACCOUNT:
            return self._email(id)
        if kind == KIND_JOB:
            return job_resource(self.emu[].project, self.emu[].region, self._name(id))
        if kind == KIND_BINDING:
            var s = self._spot(id)
            return self.emu[].binding_key(s[0], s[1], s[2])
        raise Error(String("target: node ") + id + String(" is of no kind the emulator holds"))

    def _job_index(self, id: String) -> Int:
        return self.emu[].job_index(job_resource(self.emu[].project, self.emu[].region, self._name(id)))

    def _labels_of(self, email: String) -> List[Label]:
        """An account's description read as kci reads it (kci's whole, or
        nothing)."""
        var i = self.emu[].account_index(email)
        if i < 0:
            return List[Label]()
        return description_labels(self.emu[].accounts[i].description)

    def _lines_as_labels(self, email: String) -> List[Label]:
        """An account's description read line by line, whatever else it
        holds: an identity line as its six labels, every `key=value` line as
        a label. What a console shows of it, so a release that leaves one of
        kci's lines behind is seen (step 13)."""
        var out = List[Label]()
        var i = self.emu[].account_index(email)
        if i < 0:
            return out^
        var lines = self.emu[].accounts[i].description.split("\n")
        for k in range(len(lines)):
            var line = String(lines[k])
            var identity = description_labels(line)
            if len(identity) > 0:
                out.extend(identity^)
                continue
            var eq = line.find("=")
            if eq > 0:
                out.append(Label(String(line[byte=0:eq]), String(line[byte = eq + 1 : line.byte_length()])))
        return out^

    # --- the adapter, forwarded --------------------------------------------

    def cloud_id(self) -> CloudId:
        return self.cloud.cloud_id()

    def complete(self) -> Bool:
        return self.cloud.complete()

    def implemented(self) -> List[Int]:
        return self.cloud.implemented()

    def absences(self) -> List[Absence]:
        return self.cloud.absences()

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        self.machine = ctx.scope.machine.copy()
        self.cell = ctx.scope.cell.copy()
        return self.cloud.configure(ctx)

    def public_mechanism(self) -> String:
        return self.cloud.public_mechanism()

    def check(self, r: Resource, feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
        return self.cloud.check(r, feeds, firings)

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return self.cloud.required_artifact(r)

    def lower(self, r: Resource, edges: List[GrantEdge], feeds: List[Feed], firings: List[Firing]) raises -> List[LoweredNode]:
        return self.cloud.lower(r, edges, feeds, firings)

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        var kept = List[LoweredNode]()
        for i in range(len(self.nodes)):
            if self.nodes[i].id != node.id:
                kept.append(self.nodes[i].copy())
        # A node realized only to be removed carries no fields: keep the
        # lowering's record of it, which names its object.
        var removal = len(node.desired) == 0 and Bool(self._node(node.id))
        if removal:
            kept.append(self._node(node.id).value().copy())
        else:
            kept.append(node.copy())
        self.nodes = kept^
        return self.cloud.realize(node)

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        return self.cloud.bootstrap_resources(machine, cell)

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return self.cloud.label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        return self.cloud.identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        return self.cloud.list_owned(creds, scope)

    def read_existing(mut self, creds: Creds, node: LoweredNode) raises -> ExistingObject:
        return self.cloud.read_existing(creds, node)

    def release(mut self, creds: Creds, record: OwnedRecord) raises:
        self.cloud.release(creds, record)

    def whoami(mut self, creds: Creds) raises -> Principal:
        return self.cloud.whoami(creds)

    def trust_render(self, scope: CellScope) -> String:
        return self.cloud.trust_render(scope)

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        return self.cloud.trust_check(creds, scope)

    def image_registry(self, ctx: CellContext) -> String:
        return self.cloud.image_registry(ctx)

    def registry_login(mut self, creds: Creds) raises -> RegistryLogin:
        return self.cloud.registry_login(creds)

    # --- the kit's hooks -----------------------------------------------------

    def live_count(self) -> Int:
        return self.emu[].live_count()

    def mutations(self) -> Int:
        return self.emu[].mutations

    def tamper(mut self, logical_id: String) raises:
        var kind = self._kind(logical_id)
        if kind == KIND_ACCOUNT:
            var i = self.emu[].account_index(self._email(logical_id))
            if i < 0:
                raise Error(String("target: no account to tamper for ") + logical_id)
            self.emu[].accounts[i].display_name = String("changed in a console")
            return
        var j = self._job_index(logical_id)
        if j < 0:
            raise Error(String("target: no object to tamper for ") + logical_id)
        var body = self.emu[].jobs[j].body.copy()
        var t = body.get("template")
        var task = with_member(t.get("template"), String("timeout"), JsonValue.from_string(String("1s")))
        self.emu[].jobs[j].body = with_member(body, String("template"), with_member(t, String("template"), task^))

    def tamper_unmodelled(mut self, logical_id: String) raises:
        var j = self._job_index(logical_id)
        if j < 0:
            raise Error(String("target: an unmodelled change is a job's label; no job for ") + logical_id)
        var body = self.emu[].jobs[j].body.copy()
        var labels = JsonValue.empty_object()
        if body.has("labels"):
            labels = body.get("labels")
        labels = with_member(labels, String(UNMODELLED_LABEL), JsonValue.from_string(String("yes")))
        self.emu[].jobs[j].body = with_member(body, String("labels"), labels^)

    def unmodelled(self, logical_id: String) -> String:
        var j = self._job_index(logical_id)
        if j < 0:
            return String("")
        try:
            ref body = self.emu[].jobs[j].body
            if body.has("labels"):
                return str_member(body.get("labels"), String(UNMODELLED_LABEL))
        except:
            pass
        return String("")

    def fail(mut self, logical_id: String) raises:
        var j = self._job_index(logical_id)
        if j < 0:
            raise Error(String("target: only a job has a failed state; no job for ") + logical_id)
        self.emu[].jobs[j].failed = True

    def live_labels(self, logical_id: String) -> List[Label]:
        var kind = self._kind(logical_id)
        if kind == KIND_ACCOUNT:
            return self._lines_as_labels(self._email(logical_id))
        if kind == KIND_JOB:
            var j = self._job_index(logical_id)
            var out = List[Label]()
            if j < 0:
                return out^
            try:
                ref body = self.emu[].jobs[j].body
                if body.has("labels"):
                    var labels = body.get("labels")
                    for i in range(labels.num_members()):
                        out.append(Label(labels.key_at(i), labels.value_at(i).as_string()))
            except:
                pass
            return out^
        if kind == KIND_BINDING:
            try:
                var s = self._spot(logical_id)
                var p = self.emu[].policy_index(s[0])
                if p < 0 or not self.emu[].policies[p].has(s[1], s[2]):
                    return List[Label]()
                var on_project = s[0] == project_resource(self.emu[].project)
                var target = List[Label]()
                if not on_project:
                    target = self._labels_of(String(s[0][byte = account_resource(self.emu[].project, String("")).byte_length() :]))
                var member = self._labels_of(String(s[1][byte = 15:]))
                var d = attribute(
                    on_project, BindingEnd(String(KIND_ACCOUNT), target^), False, BindingEnd(String(KIND_ACCOUNT), member^), s[2], gcp_role_table()
                )
                if d:
                    return d.value().labels.copy()
            except:
                pass
        return List[Label]()

    def plant_foreign(mut self, logical_id: String) raises:
        var kind = self._kind(logical_id)
        if kind == KIND_ACCOUNT:
            var email = self._email(logical_id)
            self.emu[].accounts.append(EmuAccount(self._name(logical_id), email, String(""), String(""), self.emu[].fresh_id()))
            return
        if kind == KIND_JOB:
            var name = job_resource(self.emu[].project, self.emu[].region, self._name(logical_id))
            self.emu[].jobs.append(EmuJob(name, parse_object(String("{\"name\":\"") + name + String("\"}"))))
            return
        raise Error(String("target: cannot plant a foreign ") + kind)

    def plant_like(mut self, node: LoweredNode) raises:
        var kept = List[LoweredNode]()
        for i in range(len(self.nodes)):
            if self.nodes[i].id != node.id:
                kept.append(self.nodes[i].copy())
        kept.append(node.copy())
        self.nodes = kept^
        if node.kind == KIND_ACCOUNT:
            var email = self._email(node.id)
            self.emu[].accounts.append(
                EmuAccount(self._name(node.id), email, display_name_of(node.id), String(""), self.emu[].fresh_id())
            )
            return
        if node.kind == KIND_JOB:
            var sa = self._email(node.depends_on[0]) if len(node.depends_on) > 0 else String("")
            var model = desired_model(node, List[String](), sa, node.retention)
            var name = job_resource(self.emu[].project, self.emu[].region, self._name(node.id))
            var body = with_member(parse_object(job_json(model, List[Label]())), String("name"), JsonValue.from_string(name.copy()))
            self.emu[].jobs.append(EmuJob(name, body^))
            return
        raise Error(String("target: cannot plant a ") + node.kind)

    def race_next_create(mut self):
        self.emu[].race_next = True

    def raced(self) -> String:
        var key = self.emu[].raced_key.copy()
        if key.byte_length() == 0:
            return String("")
        for i in range(len(self.nodes)):
            try:
                if self._key(self.nodes[i].id) == key:
                    return self.nodes[i].id.copy()
            except:
                pass
        return String("(an object no node names: ") + key + String(")")

    def creates_of(self, logical_id: String) -> Int:
        try:
            return self.emu[].creates_of(self._key(logical_id))
        except:
            return 0

    def plant_foreign_member(mut self, node: String, member: String, role: String) raises:
        var s = self._spot(node)
        var who = s[1].copy()
        if member == "FOREIGN":
            # An account of another cell of the same machine, stamped as the
            # node's principal is there: THE MEMBER CHECK must not take it.
            var principal = self._labels_of(String(s[1][byte = 15:]))
            var labels = List[Label]()
            for i in range(len(principal)):
                if principal[i].key == LABEL_CELL:
                    labels.append(Label(principal[i].key.copy(), encode_label_value(self.cell + String(OUTSIDE_SUFFIX))))
                else:
                    labels.append(principal[i].copy())
            var id = String("outsider-") + String(self.emu[].next_id + 1)
            var email = account_email(id, self.emu[].project)
            self.emu[].accounts.append(EmuAccount(id, email, String(""), description_lines(labels), self.emu[].fresh_id(), True))
            who = account_member(email)
        var held = s[2].copy() if role == "MAPPED" else String(UNMAPPED_ROLE)
        var p = self.emu[].policy_of(s[0])
        self.emu[].policies[p].add(who, held)
        self.emu[].planted_keys.append(self.emu[].binding_key(s[0], who, held))

    def member_present(self, node: String, member: String, role: String) -> Bool:
        try:
            var s = self._spot(node)
            var held = s[2].copy() if role == "MAPPED" else String(UNMAPPED_ROLE)
            var p = self.emu[].policy_index(s[0])
            if p < 0:
                return False
            ref pol = self.emu[].policies[p]
            if member != "FOREIGN":
                return pol.has(s[1], held)
            for b in range(len(pol.bindings)):
                if pol.bindings[b].role != held:
                    continue
                for m in range(len(pol.bindings[b].members)):
                    var email = String(pol.bindings[b].members[m][byte = 15:])
                    var i = self.emu[].account_index(email)
                    if i >= 0 and self.emu[].accounts[i].outside:
                        return True
        except:
            pass
        return False

    def fail_after_create_of(mut self, node: String):
        try:
            self.emu[].fail_after_key = self._key(node)
            self.armed = node.copy()
        except:
            self.armed = String("")

    def failed_after_create(self) -> String:
        if self.armed.byte_length() == 0 or self.emu[].failed_after_key.byte_length() == 0:
            return String("")
        try:
            if self.emu[].failed_after_key == self._key(self.armed):
                return self.armed.copy()
        except:
            pass
        return String("(another object: ") + self.emu[].failed_after_key + String(")")
