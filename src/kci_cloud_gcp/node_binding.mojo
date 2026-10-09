# =============================================================================
# kci_cloud_gcp/node_binding.mojo: a grant edge's node, a member binding.
# =============================================================================
#
# A binding is a member holding an IAM role on a target's policy: here a
# service account's (IAM `Get/SetIamPolicy`) or the project's (Cloud
# Resource Manager `Get/SetIamPolicy`, the target of a `cell LOGS` edge). It
# carries no labels and no description, so its stamp is DERIVED
# (kci_cloud/derived.mojo): the stamp a read reports is what `attribute`
# computes from the member account's description, the target account's
# description (or the cell scope, for the project) and the role, through the
# role table (names.mojo).
#
# WHERE A NODE'S BINDING IS (`BindingSpot`): the member is the account of the
# node's principal (its first dependency), the target the account it
# depends on next, or the project for a cell edge, and the role the table's
# row for (target kind, access). A node realized only to be removed carries
# no fields: it finds its binding in what `list_owned` reported, the key
# `<resource>|<member>|<role>`, which is also every binding's physical id.
#
# THE VERBS, each one read-modify-write of the target's policy with the etag
# it read (session.mojo), adding or removing only this node's membership:
#   * create: add the member to the role. Nothing is stamped: the member and
#     the target already are.
#   * update: the member holds another role the table maps on this target
#     (the access changed): add the node's role, remove the other.
#   * delete: remove the member from the role; a policy whose account is gone
#     is a no-op.
#   * adopt: nothing to write (a binding's stamp is derived, not written).
# A READ reports, as an unmanaged difference, every membership of the
# target's policy that is not this cell's: a role the table does not map, a
# member this cell does not stamp, another cell's member, a conditional
# binding. Those are never removed: a write keeps every membership it was
# not handed.
# =============================================================================

from std.memory import ArcPointer

from kci_cloud import (
    BindingEnd,
    LoweredNode,
    RoleRow,
    attribute,
    description_labels,
    role_for,
    standard_identity_of,
)
from kci_reconciler import (
    CONVERGE_IN_PLACE,
    ChangeAction,
    Creds,
    Label,
    ModelledDigest,
    OwnerStamp,
    Resource as EngineResource,
    ResourceStatus,
)
from komira_gcp_core import GcpTokenSource
from komira_retry import Sleeper
from komira_http_core.transport.io_stream import Connector

from kci_cloud_gcp.names import (
    KIND_ACCOUNT,
    MEMBER_SA_PREFIX,
    SA_EMAIL_DOMAIN,
    account_email,
    account_member,
    account_resource,
    derived_name,
    email_of_member,
    gcp_role_table,
    project_resource,
)
from kci_cloud_gcp.node_account import plan_verb
from kci_cloud_gcp.session import GcpSession, PolicyEntry


comptime _KEY_SEP = "|"


struct BindingSpot(Copyable, Movable):
    """Where one binding is: on the project's policy, or on the account
    `target_email`'s; `member` holding `role`; `target_kind` the role
    table's target (the account kind, or `cell/<NAME>`)."""

    var on_project: Bool
    var target_email: String
    var member: String
    var role: String
    var target_kind: String

    def __init__(out self, on_project: Bool, target_email: String, member: String, role: String, target_kind: String):
        self.on_project = on_project
        self.target_email = target_email
        self.member = member
        self.role = role
        self.target_kind = target_kind

    def __init__(out self, *, copy: Self):
        self.on_project = copy.on_project
        self.target_email = copy.target_email.copy()
        self.member = copy.member.copy()
        self.role = copy.role.copy()
        self.target_kind = copy.target_kind.copy()

    def resource(self, project: String) -> String:
        if self.on_project:
            return project_resource(project)
        return account_resource(project, self.target_email)

    def key(self, project: String) -> String:
        return self.resource(project) + String(_KEY_SEP) + self.member + String(_KEY_SEP) + self.role


def binding_key(resource: String, member: String, role: String) -> String:
    return resource + String(_KEY_SEP) + member + String(_KEY_SEP) + role


def spot_of_key(key: String, project: String) raises -> BindingSpot:
    """The spot a binding's physical id names."""
    var parts = key.split(_KEY_SEP)
    if len(parts) != 3:
        raise Error(String("kci_cloud_gcp: a binding id that is not <resource>|<member>|<role>: ") + key)
    var resource = String(parts[0])
    var member = String(parts[1])
    var role = String(parts[2])
    if resource == project_resource(project):
        var rows = gcp_role_table()
        var kind = String("")
        for i in range(len(rows)):
            if rows[i].role == role:
                kind = rows[i].target.copy()
        return BindingSpot(True, String(""), member, role, kind)
    var prefix = account_resource(project, String(""))
    if not resource.startswith(prefix):
        raise Error(String("kci_cloud_gcp: a binding on a target G4 does not bind: ") + resource)
    return BindingSpot(False, String(resource[byte = prefix.byte_length() : resource.byte_length()]), member, role, String(KIND_ACCOUNT))


def mapped_roles(rows: List[RoleRow], target_kind: String) -> List[String]:
    """Every role the table maps on targets of `target_kind`."""
    var out = List[String]()
    for i in range(len(rows)):
        if rows[i].target == target_kind:
            out.append(rows[i].role.copy())
    return out^


def _in(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


struct AccountLabels(Movable):
    """The labels every account of the project reads as (its description),
    by email: one list call serves a whole policy's members."""

    var emails: List[String]
    var labels: List[List[Label]]

    def __init__(out self):
        self.emails = List[String]()
        self.labels = List[List[Label]]()

    def of(self, email: String) -> List[Label]:
        for i in range(len(self.emails)):
            if self.emails[i] == email:
                return self.labels[i].copy()
        return List[Label]()


def attributed_here(
    labels: AccountLabels,
    on_project: Bool,
    target_labels: List[Label],
    member: String,
    role: String,
    machine: String,
    cell: String,
) -> Optional[String]:
    """The derived node a membership is attributed to in `machine`'s `cell`
    (kci_cloud's `attribute` over G4's role table), or None when it is not
    this cell's: an unmanaged difference."""
    var email = email_of_member(member)
    if email.byte_length() == 0:
        return None
    try:
        var d = attribute(
            on_project,
            BindingEnd(String(KIND_ACCOUNT), target_labels.copy()),
            False,
            BindingEnd(String(KIND_ACCOUNT), labels.of(email)),
            role,
            gcp_role_table(),
        )
        if not d:
            return None
        if d.value().machine != machine or d.value().cell != cell:
            return None
        return d.value().node.copy()
    except:
        return None


def derived_identity(
    labels: AccountLabels, on_project: Bool, target_labels: List[Label], member: String, role: String
) -> String:
    """The identity a membership reads as (its derived stamp), or empty."""
    var email = email_of_member(member)
    if email.byte_length() == 0:
        return String("")
    try:
        var d = attribute(
            on_project,
            BindingEnd(String(KIND_ACCOUNT), target_labels.copy()),
            False,
            BindingEnd(String(KIND_ACCOUNT), labels.of(email)),
            role,
            gcp_role_table(),
        )
        if not d:
            return String("")
        return standard_identity_of(d.value().labels)
    except:
        return String("")


struct GcpBindingNode[C: Connector, TS: GcpTokenSource, S: Sleeper](EngineResource, Movable, Deinitable):
    """A grant edge's node (the file header)."""

    var _s: ArcPointer[GcpSession[Self.C, Self.TS, Self.S]]
    var _node: LoweredNode

    def __init__(out self, s: ArcPointer[GcpSession[Self.C, Self.TS, Self.S]], node: LoweredNode):
        self._s = s.copy()
        self._node = node.copy()

    def _account_of(self, node: String) -> String:
        var id = self._s[].name_of_node(node)
        if id.byte_length() == 0:
            id = derived_name(self._s[].machine, self._s[].cell, node)
        return account_email(id, self._s[].project)

    def _spot(self) raises -> BindingSpot:
        """Where this node's binding is (the file header)."""
        var access = self._node.field(String("access"))
        if access.byte_length() == 0:
            var key = self._s[].owned_id_of(self._node.id)
            if key.byte_length() == 0:
                raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": a binding to remove that list_owned did not report"))
            return spot_of_key(key, self._s[].project)
        if len(self._node.depends_on) == 0:
            raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": a binding with no principal"))
        var member = account_member(self._account_of(self._node.depends_on[0]))
        var cell = self._node.field(String("cell"))
        var rows = gcp_role_table()
        if cell.byte_length() > 0:
            var target = String("cell/") + cell
            var role = role_for(rows, target, access)
            if not role:
                raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": no IAM role for ") + access + String(" on ") + target)
            return BindingSpot(True, String(""), member, role.value(), target)
        if len(self._node.depends_on) < 2:
            raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": a binding with no target"))
        var target_node = self._node.depends_on[1].copy()
        var kind = self._s[].kind_of_node(target_node)
        if kind != KIND_ACCOUNT:
            raise Error(
                String("kci_cloud_gcp: ") + self._node.id + String(": a binding on a ") + kind
                + String("; this adapter binds on a service account or the project")
            )
        var role = role_for(rows, String(KIND_ACCOUNT), access)
        if not role:
            raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": no IAM role for ") + access + String(" on a service account"))
        return BindingSpot(False, self._account_of(target_node), member, role.value(), String(KIND_ACCOUNT))

    def _entries(mut self, spot: BindingSpot) raises -> Optional[List[PolicyEntry]]:
        if spot.on_project:
            return self._s[].project_policy()
        return self._s[].account_policy(spot.target_email)

    def _labels(mut self) raises -> AccountLabels:
        var out = AccountLabels()
        var accounts = self._s[].list_accounts()
        for i in range(len(accounts)):
            out.emails.append(accounts[i].email.copy())
            out.labels.append(description_labels(accounts[i].description))
        return out^

    def _read(mut self, with_digest: Bool) raises -> ResourceStatus:
        var spot = self._spot()
        var entries = self._entries(spot)
        if not entries:
            return ResourceStatus.absent()
        var rows = gcp_role_table()
        var mapped = mapped_roles(rows, spot.target_kind)
        if self._node.field(String("access")).byte_length() == 0:
            mapped = List[String]()
            mapped.append(spot.role.copy())
        var held = List[String]()
        for i in range(len(entries.value())):
            ref e = entries.value()[i]
            if not e.conditional and e.member == spot.member and _in(mapped, e.role):
                held.append(e.role.copy())
        if len(held) == 0:
            return ResourceStatus.absent()
        var labels = self._labels()
        var target_labels = List[Label]()
        if not spot.on_project:
            target_labels = labels.of(spot.target_email)
        var role = spot.role.copy() if _in(held, spot.role) else held[0].copy()
        var stamp = derived_identity(labels, spot.on_project, target_labels, spot.member, role)
        var pid = spot.key(self._s[].project)
        if not with_digest:
            return ResourceStatus.drifted(pid, String(""), String(""), String(""), stamp, String(""))
        var extra = String("")
        for i in range(len(entries.value())):
            ref e = entries.value()[i]
            var ours = False
            if not e.conditional:
                var at = attributed_here(
                    labels, spot.on_project, target_labels, e.member, e.role, self._s[].machine, self._s[].cell
                )
                ours = Bool(at)
            if ours:
                continue
            if extra.byte_length() > 0:
                extra += String("; ")
            extra += String("member ") + e.member + String(" holding ") + e.role
            if e.conditional:
                extra += String(" under a condition")
            extra += String(" (not this cell's; left as it is)")
        var want = ModelledDigest(self._node.kind)
        want.field(String("role"), spot.role)
        var live = ModelledDigest(self._node.kind)
        var joined = String("")
        for i in range(len(held)):
            if i > 0:
                joined += String(",")
            joined += held[i]
        live.field(String("role"), joined)
        if live.text() == want.text():
            return ResourceStatus.matched(pid, live.text(), String(""), String(""), stamp, extra)
        return ResourceStatus.drifted(pid, live.text(), String(""), String(""), stamp, extra)

    def _edit(mut self, spot: BindingSpot, adds: List[PolicyEntry], removes: List[PolicyEntry]) raises:
        if spot.on_project:
            _ = self._s[].edit_project_policy(adds, removes)
            return
        if not self._s[].account_policy(spot.target_email):
            if len(adds) > 0:
                raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": the account to bind on is gone"))
            return
        _ = self._s[].edit_account_policy(spot.target_email, adds, removes)

    def logical_id(mut self) -> String:
        return self._node.id.copy()

    def depends_on(mut self) -> List[String]:
        return self._node.depends_on.copy()

    def retention(mut self) -> Int:
        return self._node.retention

    def owner(mut self) -> String:
        return self._node.owner.copy()

    def wanted(mut self) -> Bool:
        return self._node.wanted

    def stamps_ownership(mut self) -> Bool:
        return True

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        return self._read(True)

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        return self._read(False)

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return plan_verb(self._node.id, live, self._node.retention)

    def create(mut self, creds: Creds) raises -> String:
        raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": a binding is written only in an owned scope"))

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        # Nothing to stamp: the member and the target already are.
        var spot = self._spot()
        var adds = List[PolicyEntry]()
        adds.append(PolicyEntry(spot.role.copy(), spot.member.copy(), False))
        self._edit(spot, adds, List[PolicyEntry]())
        return spot.key(self._s[].project)

    def update(mut self, creds: Creds) raises:
        var spot = self._spot()
        var entries = self._entries(spot)
        var removes = List[PolicyEntry]()
        if entries:
            var mapped = mapped_roles(gcp_role_table(), spot.target_kind)
            for i in range(len(entries.value())):
                ref e = entries.value()[i]
                if not e.conditional and e.member == spot.member and e.role != spot.role and _in(mapped, e.role):
                    removes.append(PolicyEntry(e.role.copy(), e.member.copy(), False))
        var adds = List[PolicyEntry]()
        adds.append(PolicyEntry(spot.role.copy(), spot.member.copy(), False))
        self._edit(spot, adds, removes)

    def adopt_owned(mut self, stamp: OwnerStamp, physical_id: String, creds: Creds) raises:
        # A binding's stamp is derived: there is nothing to write.
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        var spot = spot_of_key(physical_id, self._s[].project)
        var removes = List[PolicyEntry]()
        removes.append(PolicyEntry(spot.role.copy(), spot.member.copy(), False))
        self._edit(spot, List[PolicyEntry](), removes)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE
