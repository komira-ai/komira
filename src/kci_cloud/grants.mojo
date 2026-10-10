# =============================================================================
# kci_cloud/grants.mojo: identities and grant edges, as kci decides them.
# =============================================================================
#
# WHO A RESOURCE RUNS AS. A `service_account` is an identity. A WORKLOAD (a
# `service`, a `container_job` or a `worker`; workload.mojo) runs as the
# account its `run_as` names; with no `run_as` it runs as its PRIVATE
# identity, the role `<id>/identity` of its own fixed set. A bucket and a
# grant run as nobody. A TRIGGER (a `schedule` or an `event_trigger`)
# reaches its target through an identity of its own, `<id>/identity`: a
# private helper only the cloud's scheduling or eventing service may use,
# never a grant's principal. So the IDENTITY OWNER of a resource is the id
# whose `<owner>/identity` node is the principal:
#   * a service account: itself;
#   * a workload: its `run_as` account, else itself;
#   * a trigger: itself;
#   * anything else: none.
# Every type that can hold an identity (the three workloads, a service
# account) lowers `<id>/identity` on every cloud. A compute resource with `run_as`
# lowers it turned off (`wanted` False): the closed world removes a private
# identity the file no longer uses.
#
# AN EDGE is one grant: a principal (an identity owner) may do `access` to a
# target (a resource of the list, or a resource the CELL provides). Edges
# come from four places, and all four are the same thing:
#   * each `uses` line of a resource that has an identity owner;
#   * a `grant` resource (its one edge, role `grant`);
#   * the IMPLICIT edge `cell LOGS WRITE`, which every resource that holds
#     its OWN identity (a service account, or a workload with no `run_as`)
#     gets unless it writes that edge itself. It is lowered and
#     printed like any other edge, never hidden;
#   * the IMPLICIT edge of a trigger, CALL on its target: a trigger's one
#     edge (it has no `uses` lines and no logs of its own), lowered and
#     printed like any other.
# One (principal, target) pair is ONE edge in the whole list: validate
# refuses a second, whether it comes from a `uses` line, a grant or the
# implicit edge.
#
# THE ROLE OF A `uses` EDGE is `u-<h>`, where `<h>` is 6 lowercase base32
# characters (RFC 4648 alphabet, `a-z2-7`) of sha256(principal path + "|" +
# target path): the first 30 bits of the digest. The target path is the
# target's resource id, or `cell/<NAME>` for a cell resource (`cell/LOGS`;
# an id cannot hold `/`, so the two never meet). The role is 8 bytes at any
# nesting depth, so a grant never strains the label budget. The verb is NOT
# hashed: READ -> WRITE is an update of the same node. Two edges of one
# resource whose roles collide are refused at validate; the author then
# writes one of them as a `grant` resource. A `grant` resource's edge has
# the role `grant`.
#
# kci decides all of this, never a cloud adapter. `edges_for` adds what the
# adapter cannot see from one resource, the TARGET'S TYPE (its catalog
# field, or `EDGE_TARGET_CELL` for a cell resource), and kci hands those
# edges to `CloudAdapter.lower`, which lowers each by its own table of grant
# kinds per target type.
# =============================================================================

from komira_crypto import sha256_string
from kci_resource_proto.resource import Resource

from kci_cloud.catalog import (
    ACCESS_CALL,
    ACCESS_READ,
    ACCESS_WRITE,
    FIELD_EVENT_TRIGGER,
    FIELD_GRANT,
    FIELD_SCHEDULE,
    FIELD_SERVICE_ACCOUNT,
    ROLE_GRANT,
    ROLE_IDENTITY,
    body_field,
)
from kci_cloud.workload import workload_of


comptime GRANT_ROLE_PREFIX = "u-"
"""The role of a `uses` edge is this prefix and 6 base32 characters."""
comptime GRANT_HASH_CHARS: Int = 6
comptime CELL_PATH_PREFIX = "cell/"
"""A cell resource's target path: `cell/<NAME>` (`cell/LOGS`)."""

comptime EDGE_TARGET_CELL: Int = 0
"""`GrantEdge.target_field` of an edge to a cell resource."""
comptime EDGE_TARGET_UNKNOWN: Int = -1
"""`GrantEdge.target_field` before `edges_for` resolved it."""

comptime CELL_LOGS: Int = 1
"""`kci.resource.v1.LOGS`."""
comptime CELL_METRICS: Int = 2
"""`kci.resource.v1.METRICS`."""
comptime CELL_ARTIFACTS: Int = 3
"""`kci.resource.v1.ARTIFACTS`."""

comptime _BASE32 = "abcdefghijklmnopqrstuvwxyz234567"


def role_hash(text: String, chars: Int) -> String:
    """`chars` (at most 6) lowercase base32 characters of sha256(text): the
    first 5 * `chars` bits of the digest, 5 bits per character, most
    significant first. The hashed part of every role kci derives from a
    name (`u-<h>` here, a table index's `ix-<h>` in data.mojo)."""
    var d = sha256_string(text)
    var bits: UInt64 = 0
    for i in range(4):
        bits = (bits << 8) | UInt64(Int(d[i]))
    var out = String("")
    var alphabet = String(_BASE32)
    for k in range(chars):
        var shift = 32 - 5 * (k + 1)
        var v = Int((bits >> UInt64(shift)) & 31)
        out += String(alphabet[byte = v : v + 1])
    return out^


def grant_hash(principal: String, target: String) -> String:
    """6 lowercase base32 characters of sha256(principal + "|" + target):
    the first 30 bits of the digest, 5 bits per character, most significant
    first."""
    return role_hash(principal + String("|") + target, GRANT_HASH_CHARS)


def uses_role(principal: String, target: String) -> String:
    """`u-<h>`: the role of the edge (principal, target path)."""
    return String(GRANT_ROLE_PREFIX) + grant_hash(principal, target)


def cell_name(cell: Int) -> String:
    """A declared cell resource by its name (`LOGS`), or empty."""
    if cell == CELL_LOGS:
        return String("LOGS")
    if cell == CELL_METRICS:
        return String("METRICS")
    if cell == CELL_ARTIFACTS:
        return String("ARTIFACTS")
    return String("")


def cell_accepts(cell: Int, access: String) -> Bool:
    """The verbs a cell resource accepts: LOGS and METRICS take READ and
    WRITE; ARTIFACTS takes READ."""
    if cell == CELL_LOGS or cell == CELL_METRICS:
        return access == ACCESS_READ or access == ACCESS_WRITE
    if cell == CELL_ARTIFACTS:
        return access == ACCESS_READ
    return False


def cell_accepted(cell: Int) -> String:
    """The verbs `cell` accepts, for a refusal text."""
    if cell == CELL_ARTIFACTS:
        return String(ACCESS_READ)
    return String(ACCESS_READ) + String(", ") + String(ACCESS_WRITE)


def _field(r: Resource) -> Int:
    """`r`'s body field, or -1 when it has none."""
    try:
        return body_field(r)
    except:
        return -1


def is_trigger(field: Int) -> Bool:
    """True for the body field of a schedule or an event trigger."""
    return field == FIELD_SCHEDULE or field == FIELD_EVENT_TRIGGER


def trigger_target(r: Resource) -> String:
    """The resource a trigger starts or calls (its `target`), or empty: for
    a trigger with no target, and for any other type."""
    if Bool(r.schedule) and Bool(r.schedule.value().target):
        return r.schedule.value().target.value().resource.copy()
    if Bool(r.event_trigger) and Bool(r.event_trigger.value().target):
        return r.event_trigger.value().target.value().resource.copy()
    return String("")


def holds_own_identity(r: Resource) -> Bool:
    """True iff `r` holds an identity of its own: a service account, or a
    workload with no `run_as`."""
    if _field(r) == FIELD_SERVICE_ACCOUNT:
        return True
    var w = workload_of(r)
    return Bool(w) and not Bool(w.value().run_as)


def run_as_of(r: Resource) -> String:
    """The account a workload names in `run_as`, or empty."""
    var w = workload_of(r)
    if not w:
        return String("")
    return w.value().account()


def identity_owner(r: Resource) -> String:
    """The id whose identity `r` runs as (see the file header), or empty
    for a type that runs as nobody."""
    if holds_own_identity(r) or is_trigger(_field(r)):
        return r.id.copy()
    return run_as_of(r)


def principal_node(owner: String) -> String:
    """The node a grant of identity owner `owner` hangs off."""
    return owner + String("/") + String(ROLE_IDENTITY)


struct GrantEdge(Copyable, Movable, Deinitable):
    """One edge, as kci decided it: its role (`u-<h>` or `grant`), the
    identity owner that may act, the target resource id (empty for a cell
    resource) or the cell resource's name, the verb, whether it is the
    implicit `cell LOGS WRITE` edge, and the target's type (its catalog
    field; `EDGE_TARGET_CELL` for a cell resource; set by `edges_for`)."""

    var role: String
    var principal: String
    var target: String
    var cell: String
    var access: String
    var implicit: Bool
    var target_field: Int

    def __init__(
        out self,
        role: String,
        principal: String,
        target: String,
        cell: String,
        access: String,
        implicit: Bool = False,
        target_field: Int = EDGE_TARGET_UNKNOWN,
    ):
        self.role = role
        self.principal = principal
        self.target = target
        self.cell = cell
        self.access = access
        self.implicit = implicit
        self.target_field = target_field

    def __init__(out self, *, copy: Self):
        self.role = copy.role.copy()
        self.principal = copy.principal.copy()
        self.target = copy.target.copy()
        self.cell = copy.cell.copy()
        self.access = copy.access.copy()
        self.implicit = copy.implicit
        self.target_field = copy.target_field

    def on_cell(self) -> Bool:
        return self.cell.byte_length() > 0

    def target_path(self) -> String:
        """The target id, or `cell/<NAME>`."""
        if self.on_cell():
            return String(CELL_PATH_PREFIX) + self.cell
        return self.target.copy()

    def key(self) -> String:
        """(principal, target path): one edge per key in a list."""
        return self.principal + String("|") + self.target_path()

    def principal_node(self) -> String:
        return principal_node(self.principal)


def edges_of(r: Resource) raises -> List[GrantEdge]:
    """Every edge `r` lowers, in order: its `uses` lines as written, then the
    implicit `cell LOGS WRITE` edge when `r` holds its own identity and does
    not write that edge; for a grant resource, its one edge; for a trigger,
    its one implicit edge, CALL on its target. Raises on a shape validate
    refuses (a `uses` line on a type that runs as nobody or on a trigger, a
    line or grant with neither or both of target and cell, a trigger with
    no target)."""
    var out = List[GrantEdge]()
    if _field(r) == FIELD_GRANT:
        ref g = r.grant.value()
        if not g.principal:
            raise Error(String("grant \"") + r.id + String("\" has no principal"))
        var tgt = String("")
        if g.target:
            tgt = g.target.value().resource.copy()
        var cell = cell_name(g.cell.value)
        if (tgt.byte_length() > 0) == (cell.byte_length() > 0):
            raise Error(String("grant \"") + r.id + String("\" needs exactly one of target and cell"))
        out.append(
            GrantEdge(
                String(ROLE_GRANT), g.principal.value().resource.copy(), tgt^, cell^, g.access.json_name()
            )
        )
        return out^
    if is_trigger(_field(r)):
        if len(r.uses) > 0:
            raise Error(String("trigger \"") + r.id + String("\" has uses lines; its one edge is CALL on its target"))
        var tgt = trigger_target(r)
        if tgt.byte_length() == 0:
            raise Error(String("trigger \"") + r.id + String("\" has no target"))
        out.append(GrantEdge(uses_role(r.id, tgt), r.id.copy(), tgt^, String(""), String(ACCESS_CALL), True))
        return out^
    var owner = identity_owner(r)
    if owner.byte_length() == 0:
        if len(r.uses) > 0:
            raise Error(String("resource \"") + r.id + String("\" runs as no identity; it has no uses lines"))
        return out^
    var logs_written = False
    for u in range(len(r.uses)):
        ref use = r.uses[u]
        var tgt = String("")
        if use.target:
            tgt = use.target.value().resource.copy()
        var cell = cell_name(use.cell.value)
        if (tgt.byte_length() > 0) == (cell.byte_length() > 0):
            raise Error(
                String("resource \"") + r.id + String("\" uses[") + String(u)
                + String("] needs exactly one of target and cell")
            )
        if use.cell.value == CELL_LOGS:
            logs_written = True
        var path = tgt.copy() if tgt.byte_length() > 0 else String(CELL_PATH_PREFIX) + cell
        out.append(GrantEdge(uses_role(owner, path), owner.copy(), tgt^, cell^, use.access.json_name()))
    if holds_own_identity(r) and not logs_written:
        var path = String(CELL_PATH_PREFIX) + String("LOGS")
        out.append(
            GrantEdge(
                uses_role(owner, path), owner.copy(), String(""), String("LOGS"), String(ACCESS_WRITE), True
            )
        )
    return out^


def edges_for(resources: List[Resource], r: Resource) raises -> List[GrantEdge]:
    """`edges_of(r)`, each with its target's type set: the catalog field of
    the target resource in `resources`, or `EDGE_TARGET_CELL`. Raises for a
    target that is not in `resources` (validate refuses it first)."""
    var out = edges_of(r)
    for i in range(len(out)):
        if out[i].on_cell():
            out[i].target_field = EDGE_TARGET_CELL
            continue
        var found = False
        for k in range(len(resources)):
            if resources[k].id == out[i].target:
                out[i].target_field = body_field(resources[k])
                found = True
                break
        if not found:
            raise Error(
                String("resource \"") + r.id + String("\": an edge to \"") + out[i].target
                + String("\" names no resource of this list")
            )
    return out^
