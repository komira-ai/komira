# =============================================================================
# kci_cloud/derived.mojo: the DERIVED stamp of a member binding.
# =============================================================================
#
# On some clouds a grant is a MEMBER BINDING: a member (an identity, or
# everyone) holding a role on a target's access policy. A binding carries no
# labels and no description, so it cannot be stamped when it is created.
# Dropping such kinds from the owned scope would drop almost everything (every
# workload with its own identity lowers the implicit `cell LOGS WRITE` edge,
# and every service a public binding), so a shape whose grants are such
# bindings declares them DERIVED (`ProviderShape.grant_carrier`), and a
# binding's stamp is COMPUTED from what the cloud holds. `attribute` is that
# computation, a pure function of the binding and the two objects at its
# ends; a fake and a real adapter call the same function.
#
# ATTRIBUTION. A binding (target, member, role) is attributed to a node when:
#   * its ROLE maps back, through the adapter's table (`RoleRow`s), to exactly
#     one row: one access verb on the target's kind, or, for a binding on the
#     cell's own scope (on GCP the project), one cell resource and verb
#     (`cell/<NAME>`). The table must be injective (`role_table_problems`);
#   * its MEMBER is an identity stamped by this machine and cell (its object's
#     stamp names role `.../identity`), or everyone (`ALL_USERS`) on a row
#     whose access is `ACCESS_PUBLIC`;
#   * its TARGET is an object stamped by this machine and cell, of the kind
#     the row names, or the cell scope (`target_is_cell`) for a `cell/<NAME>`
#     row. THE MEMBER CHECK: on an owned target the member's machine and cell
#     must be the target's; an identity of another cell (or another machine)
#     holding a mapped role is never this cell's.
# The node id is a pure function of the cloud's objects:
#   * `<P>/u-<h>`, where `P` is the member identity's path (its stamp's
#     resource and role, without the last `/identity`) and `h` is
#     `grants.uses_role`'s hash of `P` and the target path (the target
#     object's resource path, its node id without its role, or `cell/<NAME>`);
#   * `<T>/public` for everyone on a public row, where `T` is the target's
#     resource path.
# The derived labels are what `create_labels` would have written for that
# node: the identity (owner = the member's resource, or the target's for a
# public binding), the validation run and the retention mark of the member
# identity (of the target, for a public binding). Every node of a resource
# takes the resource's retention, so these equal the binding node's own.
#
# NOT OURS. A binding with no attribution (a role not in the table, a member
# this cell does not stamp, a target it does not own) is an UNMANAGED
# DIFFERENCE: an adapter reports it and never removes it. A hand-made binding
# equal to a wanted one is attributed like any other: it is ours, whoever
# wrote it, and an apply of it is a no-op.
#
# THE RESTRICTION. The node id above is pure only when the owner of an edge
# is its principal. A `uses` line on a workload that has `run_as` (the node
# belongs to the workload, the member is the account) and a `grant` resource
# (the node belongs to the grant) break that; on a DERIVED shape `check`
# refuses both (shape/lower.mojo, `derived_grant_limits`).
# =============================================================================

from kci_reconciler import (
    LABEL_CELL,
    LABEL_MACHINE,
    LABEL_RESOURCE,
    LABEL_ROLE,
    LABEL_SCHEME,
    Label,
    OwnerStamp,
    RETAIN_DELETE,
    RETAIN_KEEP,
)

from kci_cloud.catalog import ROLE_IDENTITY
from kci_cloud.grants import CELL_PATH_PREFIX, uses_role
from kci_cloud.labels import (
    create_labels,
    decode_label_value,
    retained_by,
    standard_identity_of,
    validation_run_of,
)


comptime ALL_USERS = "allUsers"
"""The member that is everyone (a public binding's)."""
comptime ACCESS_PUBLIC = "PUBLIC"
"""A `RoleRow`'s access for the role that makes a target public."""
comptime ROLE_PUBLIC_NODE = "public"
"""The role of a public binding's node: `<T>/public`."""


@fieldwise_init
struct RoleRow(Copyable, Movable, Deinitable):
    """One row of an adapter's role table: on a target of provider kind
    `target` (or on the cell scope, `cell/<NAME>`), access `access` (a
    catalog verb, or `ACCESS_PUBLIC`) is the cloud's role `role`."""

    var target: String
    var access: String
    var role: String


def role_table_problems(rows: List[RoleRow]) -> List[String]:
    """Why `rows` is not injective: a role on two rows (attribution could
    not read it back), or one (target, access) on two rows. Empty when it
    is."""
    var out = List[String]()
    for i in range(len(rows)):
        for k in range(i + 1, len(rows)):
            if rows[i].role == rows[k].role:
                out.append(
                    String("role \"") + rows[i].role + String("\" maps both ") + rows[i].target
                    + String(" ") + rows[i].access + String(" and ") + rows[k].target + String(" ")
                    + rows[k].access
                )
            if rows[i].target == rows[k].target and rows[i].access == rows[k].access:
                out.append(
                    String("") + rows[i].target + String(" ") + rows[i].access + String(" has two roles, \"")
                    + rows[i].role + String("\" and \"") + rows[k].role + String("\"")
                )
    return out^


def role_for(rows: List[RoleRow], target: String, access: String) -> Optional[String]:
    """The role of `access` on `target` (a kind, or `cell/<NAME>`), or None
    when the table has no row for it."""
    for i in range(len(rows)):
        if rows[i].target == target and rows[i].access == access:
            return rows[i].role.copy()
    return None


def _row_of(rows: List[RoleRow], role: String) -> Optional[RoleRow]:
    """The one row of `role`, or None for none or several."""
    var found: Optional[RoleRow] = None
    for i in range(len(rows)):
        if rows[i].role == role:
            if found:
                return None
            found = rows[i].copy()
    return found^


struct BindingEnd(Copyable, Movable, Deinitable):
    """What the cloud holds at one end of a binding: the object's provider
    kind and its labels (empty when it carries none, or does not exist)."""

    var kind: String
    var labels: List[Label]

    def __init__(out self, kind: String = String(""), var labels: List[Label] = List[Label]()):
        self.kind = kind
        self.labels = labels^

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind.copy()
        self.labels = copy.labels.copy()


struct DerivedStamp(Copyable, Movable, Deinitable):
    """A binding's attribution: the node it is (`node`), the machine and
    cell it is of, and the labels it reads as (`create_labels` of that
    node)."""

    var node: String
    var machine: String
    var cell: String
    var labels: List[Label]

    def __init__(out self, node: String, machine: String, cell: String, var labels: List[Label]):
        self.node = node
        self.machine = machine
        self.cell = cell
        self.labels = labels^

    def __init__(out self, *, copy: Self):
        self.node = copy.node.copy()
        self.machine = copy.machine.copy()
        self.cell = copy.cell.copy()
        self.labels = copy.labels.copy()


struct _Stamp(Copyable, Movable, Deinitable):
    """The decoded stamp of one object."""

    var machine: String
    var cell: String
    var resource: String
    var node: String
    var scheme: Int

    def __init__(out self, machine: String, cell: String, resource: String, node: String, scheme: Int):
        self.machine = machine
        self.cell = cell
        self.resource = resource
        self.node = node
        self.scheme = scheme

    def __init__(out self, *, copy: Self):
        self.machine = copy.machine.copy()
        self.cell = copy.cell.copy()
        self.resource = copy.resource.copy()
        self.node = copy.node.copy()
        self.scheme = copy.scheme


def _label(labels: List[Label], key: String) -> String:
    for i in range(len(labels)):
        if labels[i].key == key:
            return decode_label_value(labels[i].value)
    return String("")


def _stamp_of(labels: List[Label]) -> Optional[_Stamp]:
    """The stamp `labels` carry, or None when they carry no complete one."""
    if standard_identity_of(labels).byte_length() == 0:
        return None
    var scheme: Int
    try:
        scheme = atol(_label(labels, String(LABEL_SCHEME)))
    except:
        return None
    var resource = _label(labels, String(LABEL_RESOURCE))
    var role = _label(labels, String(LABEL_ROLE))
    var node = resource.copy() if role.byte_length() == 0 else resource + String("/") + role
    return _Stamp(_label(labels, String(LABEL_MACHINE)), _label(labels, String(LABEL_CELL)), resource^, node^, scheme)


def _path_of(node: String) -> String:
    """A node's resource path: its id without its last role segment."""
    var at = node.rfind("/")
    if at <= 0:
        return node.copy()
    return String(node[byte=0:at])


def _derived(
    node: String, machine: String, cell: String, owner: String, scheme: Int, source: List[Label]
) raises -> DerivedStamp:
    """The stamp of `node` of resource `owner`, with the validation run and
    the retention of the object whose labels are `source`."""
    var prefix = owner + String("/")
    var role = String(node[byte = prefix.byte_length() : node.byte_length()])
    var stamp = OwnerStamp(
        machine.copy(), cell.copy(), owner.copy(), role^, scheme, validation_run_id=validation_run_of(source)
    )
    var retention = RETAIN_KEEP if retained_by(source) else RETAIN_DELETE
    return DerivedStamp(node, machine, cell, create_labels(stamp, retention))


def attribute(
    target_is_cell: Bool,
    target: BindingEnd,
    all_users: Bool,
    member: BindingEnd,
    role: String,
    rows: List[RoleRow],
) raises -> Optional[DerivedStamp]:
    """The attribution of the binding (`target`, `member`, `role`) under the
    role table `rows` (the file header), or None when it is not kci's: an
    unmanaged difference. `target_is_cell` says the target is the cell's own
    scope (then `target` is not read); `all_users` says the member is
    everyone (then `member` is not read)."""
    var row = _row_of(rows, role)
    if not row:
        return None
    ref r = row.value()
    if all_users:
        if target_is_cell or r.access != ACCESS_PUBLIC or r.target != target.kind:
            return None
        var t = _stamp_of(target.labels)
        if not t:
            return None
        ref ts = t.value()
        var node = _path_of(ts.node) + String("/") + String(ROLE_PUBLIC_NODE)
        return _derived(node, ts.machine, ts.cell, ts.resource, ts.scheme, target.labels)
    if r.access == ACCESS_PUBLIC:
        return None
    var m = _stamp_of(member.labels)
    if not m:
        return None
    ref ms = m.value()
    var suffix = String("/") + String(ROLE_IDENTITY)
    if not ms.node.endswith(suffix):
        return None
    var principal = String(ms.node[byte = 0 : ms.node.byte_length() - suffix.byte_length()])
    var machine = ms.machine.copy()
    var cell = ms.cell.copy()
    var path: String
    if target_is_cell:
        if not r.target.startswith(CELL_PATH_PREFIX):
            return None
        path = r.target.copy()
    else:
        if r.target != target.kind:
            return None
        var t = _stamp_of(target.labels)
        if not t:
            return None
        ref ts = t.value()
        # THE MEMBER CHECK: an identity of another machine or cell is never
        # this cell's, whatever role it holds on an object this cell owns.
        if ms.machine != ts.machine or ms.cell != ts.cell:
            return None
        machine = ts.machine.copy()
        cell = ts.cell.copy()
        path = _path_of(ts.node)
    var node = principal + String("/") + uses_role(principal, path)
    return _derived(node, machine, cell, ms.resource, ms.scheme, member.labels)
