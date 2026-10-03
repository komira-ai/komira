# =============================================================================
# kci_cloud/deploy.mojo: configure, validate, lower to data, realize, then
#   hand the graph to the engine, in a cell.
# =============================================================================
#
# The three verbs every command runs through. Each one runs in a CELL
# (`CellContext`: machine, cell, provenance, adopt, settings) and FIRST
# configures the adapter with the cell's settings and validates: any finding
# (a setting, the graph, coverage, a limit, the platform, the public
# mechanism) refuses the whole graph before lowering, so a refused graph
# never reaches an adapter's `lower` and never reaches the engine: nothing is
# created, and the adapter is never asked to.
#
# LOWERING IS DATA. `lower_data` asks the adapter for `LoweredNode`s and holds
# them to the lowering contract on every run (not only in tests): each
# resource lowers to at least one node, every node id is `<resource
# id>/<role>`, every node's owner is the resource it came from, and no id
# repeats. `lowering_json` renders a lowering for golden tests. Only then
# does `realize_graph` turn the data into engine nodes, and it checks that
# each realized node kept its id, owner and wanted.
#
# THE CLOSED WORLD. A type's lowering emits its whole fixed set of roles, the
# ones the file turned off with `wanted` False. A role that is not fixed (one
# `uses/<target>` per line) is found through the cloud: `list_owned` names
# every object of this machine and cell; one owned by a resource still in the
# file but no longer lowered is added as a turned-off node, so it is removed;
# one owned by a resource the file no longer names is LEFTOVER, reported and
# never deleted here.
#
# Every verb runs the engine's OWNED forms (the cell scope): the store keyed
# by (machine, cell, resource), the stamp born with each object, and a
# foreign or conflicting object refused before any change.
# =============================================================================

from kci_reconciler import (
    AppliedNode,
    ChangeAction,
    Creds,
    InputRef,
    REFUSED_TOKEN,
    ResourceGraph,
    StateStore,
    UndeletableSkip,
    apply_graph_owned,
    destroy_graph_owned,
    plan_graph_owned,
)
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import CellContext, CloudAdapter, LoweredNode, Setting
from kci_cloud.clouds import Clouds
from kci_cloud.validate import refusal_text, validate_for


def refuse_unless_valid[
    S: CloudAdapter
](clouds: Clouds, mut cloud: S, ctx: CellContext, resources: List[Resource]) raises:
    """Configure `cloud` with the cell, then validate; any finding raises the
    one refusal text. An unowned scope (no machine or cell) is refused:
    kci deploys only into a cell."""
    if not ctx.scope.owned():
        raise Error(
            String("kci deploys only into a cell: the context names no")
            + String(" machine and cell")
        )
    var findings = cloud.configure(ctx)
    var more = validate_for(clouds, cloud, resources)
    for i in range(len(more)):
        findings.append(more[i].copy())
    if len(findings) > 0:
        raise Error(refusal_text(cloud.cloud_id(), findings))


def lower_data[
    S: CloudAdapter
](cloud: S, resources: List[Resource]) raises -> List[LoweredNode]:
    """Lower every resource to data and check the lowering contract."""
    var out = List[LoweredNode]()
    for i in range(len(resources)):
        ref r = resources[i]
        var nodes = cloud.lower(r)
        if len(nodes) == 0:
            raise Error(
                String("cloud \"")
                + cloud.cloud_id().text()
                + String("\" lowered resource \"")
                + r.id
                + String("\" to no nodes")
            )
        var prefix = r.id + String("/")
        for n in range(len(nodes)):
            ref node = nodes[n]
            if node.owner != r.id or not node.id.startswith(prefix):
                raise Error(
                    String("cloud \"")
                    + cloud.cloud_id().text()
                    + String("\" broke the lowering contract on \"")
                    + r.id
                    + String("\": node \"")
                    + node.id
                    + String("\" has owner \"")
                    + node.owner
                    + String("\"; every node must be \"")
                    + prefix
                    + String("<role>\" and owned by its resource")
                )
            for k in range(len(out)):
                if out[k].id == node.id:
                    raise Error(
                        String("cloud \"")
                        + cloud.cloud_id().text()
                        + String("\" lowered node \"")
                        + node.id
                        + String("\" twice")
                    )
            out.append(node.copy())
    return out^


def lowering_json(nodes: List[LoweredNode]) -> String:
    """A lowering as one JSON array, one node per line (golden tests)."""
    var s = String("[")
    for i in range(len(nodes)):
        s += String("\n  ") if i == 0 else String(",\n  ")
        s += nodes[i].to_json()
    s += String("\n]")
    return s^


def realize_graph[
    S: CloudAdapter
](mut cloud: S, nodes: List[LoweredNode]) raises -> ResourceGraph:
    """The engine graph for `nodes`; each realized node must keep its id,
    owner and wanted."""
    var graph = ResourceGraph()
    for i in range(len(nodes)):
        ref want = nodes[i]
        var node = cloud.realize(want)
        var lid = node.logical_id()
        var own = node.owner()
        if lid != want.id or own != want.owner or node.wanted() != want.wanted:
            raise Error(
                String("cloud \"")
                + cloud.cloud_id().text()
                + String("\" realized node \"")
                + want.id
                + String("\" as \"")
                + lid
                + String("\" owned by \"")
                + own
                + String("\"; realize must keep the id, owner and wanted")
            )
        graph.add(node^)
    return graph^


struct Removals(Movable):
    """What `list_owned` says beyond the lowering: roles of resources still in
    the file that the file turned off (`roles`, to remove), and nodes of
    resources the file no longer names (`leftover`, reported only)."""

    var roles: List[LoweredNode]
    var leftover: List[String]

    def __init__(out self):
        self.roles = List[LoweredNode]()
        self.leftover = List[String]()


def _resource_of(node_id: String) -> String:
    var i = node_id.find("/")
    if i < 0:
        return node_id.copy()
    return String(node_id[byte=0:i])


def removals[
    S: CloudAdapter
](
    mut cloud: S,
    ctx: CellContext,
    nodes: List[LoweredNode],
    resources: List[Resource],
    creds: Creds,
) raises -> Removals:
    """Compare what the cloud says this cell owns with the lowering."""
    var out = Removals()
    var owned = cloud.list_owned(creds, ctx.scope)
    for i in range(len(owned)):
        var nid = owned[i].owner_node.copy()
        var lowered = False
        for k in range(len(nodes)):
            if nodes[k].id == nid:
                lowered = True
                break
        if lowered:
            continue
        var res = _resource_of(nid)
        var in_file = False
        for k in range(len(resources)):
            if resources[k].id == res:
                in_file = True
                break
        if in_file:
            var dup = False
            for k in range(len(out.roles)):
                if out.roles[k].id == nid:
                    dup = True
                    break
            if not dup:
                out.roles.append(
                    LoweredNode(
                        nid,
                        res,
                        owned[i].kind.copy(),
                        List[String](),
                        List[InputRef](),
                        List[Setting](),
                        False,
                    )
                )
        else:
            out.leftover.append(nid^)
    return out^


def _graph_for[
    S: CloudAdapter
](
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut leftover: List[String],
) raises -> ResourceGraph:
    """Lowering + the roles `list_owned` says to remove, realized."""
    var nodes = lower_data(cloud, resources)
    var rem = removals(cloud, ctx, nodes, resources, creds)
    for i in range(len(rem.roles)):
        nodes.append(rem.roles[i].copy())
    leftover = rem.leftover.copy()
    return realize_graph(cloud, nodes)


def lower_resources[
    S: CloudAdapter
](mut cloud: S, resources: List[Resource]) raises -> ResourceGraph:
    """Lower (data, contract checked) and realize, with no cell: the
    lowering alone, as the conformance kit counts it."""
    return realize_graph(cloud, lower_data(cloud, resources))


def plan_resources[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
) raises -> List[ChangeAction]:
    """The dry run: configure, validate, lower, `plan_graph_owned`. Creates
    nothing and writes nothing to the store."""
    refuse_unless_valid(clouds, cloud, ctx, resources)
    var leftover = List[String]()
    var graph = _graph_for(cloud, ctx, resources, creds, leftover)
    return plan_graph_owned(graph, creds, ctx.scope, store)


struct ApplyOutcome(Movable, Deinitable):
    """What an apply did, whether or not it finished.

      * `error`    — None when every node converged; else the engine's error
                     (it names the node, the verb and the fault domain). An
                     error starting `kci: REFUSED` is an ownership refusal
                     made before any change (`refused()`).
      * `applied`  — every node, in apply order, when `error` is None; empty
                     otherwise (use `landed`).
      * `landed`   — the nodes this apply acted on before it stopped, in
                     apply order, each with the verb it issued. On success it
                     equals `applied`. These mutations are LIVE in the cell.
      * `pending`  — the nodes it never reached, in the order they would have
                     run; the failing node is the first. Empty on success.
      * `leftover` — nodes of resources the file no longer names that the
                     cloud says this cell owns; reported, never deleted here.

    A caller that only got a bool (or only the error) could not tell "nothing
    happened" from "half the graph is live": that is the PARTIAL outcome a
    driver must not retry blindly, and these lists are how it is reported.
    """

    var applied: List[AppliedNode]
    var landed: List[AppliedNode]
    var pending: List[String]
    var error: Optional[String]
    var leftover: List[String]

    def __init__(
        out self,
        var applied: List[AppliedNode],
        var landed: List[AppliedNode],
        var pending: List[String],
        var error: Optional[String],
        var leftover: List[String] = List[String](),
    ):
        self.applied = applied^
        self.landed = landed^
        self.pending = pending^
        self.error = error^
        self.leftover = leftover^

    def ok(self) -> Bool:
        return not self.error

    def partial(self) -> Bool:
        """True iff the apply failed AFTER at least one node landed."""
        return Bool(self.error) and len(self.landed) > 0

    def refused(self) -> Bool:
        """True iff the engine refused the run before any change (a node it
        may not act on: foreign, conflict, or one that cannot stamp)."""
        return Bool(self.error) and self.error.value().startswith(REFUSED_TOKEN)


def apply_resources[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
) raises -> ApplyOutcome:
    """Configure, validate, lower, then `apply_graph_owned` in the cell.

    RAISES only before any effect: a refused graph (settings or validate) or
    a broken lowering contract. A failure inside the engine, an ownership
    refusal included, is NOT raised: it is returned in the outcome with what
    landed and what is pending, so the caller can report a partial apply or
    a refusal instead of a bare failure."""
    refuse_unless_valid(clouds, cloud, ctx, resources)
    var leftover = List[String]()
    var graph = _graph_for(cloud, ctx, resources, creds, leftover)
    var landed = List[AppliedNode]()
    var pending = List[String]()
    var applied = List[AppliedNode]()
    var error: Optional[String] = None
    try:
        applied = apply_graph_owned(graph, creds, ctx.scope, store, landed, pending)
    except e:
        error = String(e)
    if error:
        return ApplyOutcome(List[AppliedNode](), landed^, pending^, error^, leftover^)
    return ApplyOutcome(applied^, landed^, pending^, None, leftover^)


def destroy_resources[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
) raises -> List[UndeletableSkip]:
    """Configure, validate, lower, `destroy_graph_owned` (reverse order,
    retention honoured, nothing foreign deleted). The roles a resource in the
    file turned off are torn down with it. A graph this cloud cannot host
    cannot have been applied by it, so it is refused here too rather than
    half-lowered."""
    refuse_unless_valid(clouds, cloud, ctx, resources)
    var leftover = List[String]()
    var graph = _graph_for(cloud, ctx, resources, creds, leftover)
    return destroy_graph_owned(graph, creds, ctx.scope, store)


def group_plan(actions: List[ChangeAction]) -> String:
    """A plan grouped under the authored resources, in first-seen order:
    `api: create api/run, create api/uses/jobs`. A node with no owner is
    grouped under `(no owner)`."""
    var owners = List[String]()
    for i in range(len(actions)):
        var o = actions[i].owner.copy()
        if o.byte_length() == 0:
            o = String("(no owner)")
        var seen = False
        for k in range(len(owners)):
            if owners[k] == o:
                seen = True
                break
        if not seen:
            owners.append(o)
    var s = String("")
    for k in range(len(owners)):
        if k > 0:
            s += String("\n")
        s += owners[k] + String(":")
        var first = True
        for i in range(len(actions)):
            var o = actions[i].owner.copy()
            if o.byte_length() == 0:
                o = String("(no owner)")
            if o != owners[k]:
                continue
            s += String(" ") if first else String(", ")
            first = False
            s += String(actions[i].verb_name()) + String(" ") + actions[i].logical_id
    return s^
