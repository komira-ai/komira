# =============================================================================
# kci_cloud/deploy.mojo: configure, validate, lower to data, realize, then
#   hand the graph to the engine, in a cell.
# =============================================================================
#
# The three verbs every command runs through. Each one runs in a CELL
# (`CellContext`: machine, cell, provenance, adopt, validation run id,
# settings) and FIRST configures the adapter with the cell's settings and
# validates: any finding (a validation run id outside komira_validation_run's
# rule, on plan and apply only; a setting, the graph, coverage, a limit, the
# platform, the public mechanism) refuses the whole graph before lowering,
# so a refused graph never reaches an adapter's `lower` and never reaches the
# engine: nothing is created, and the adapter is never asked to.
#
# LOWERING IS DATA. `lower_data` asks the adapter for `LoweredNode`s and holds
# them to the lowering contract on every run (not only in tests): each
# resource lowers to at least one node, every node id is `<resource
# id>/<role>`, every node's owner is the resource it came from, and no id
# repeats. It then RESOLVES what is kci's to decide, not the cloud's: a
# dependency or input the adapter wrote as another resource's bare id lands
# on that resource's primary node (`<id>/<primary role>`, catalog.mojo), and
# every node takes its resource's retention (`Resource.retention`, else the
# type's versioned default). `lowering_json` renders a lowering for golden
# tests. Only then does `realize_graph` turn the data into engine nodes, and
# it checks that each realized node kept its id, owner, wanted and
# retention.
#
# THE CLOSED WORLD. A type's lowering emits its whole fixed set of roles, the
# ones the file turned off with `wanted` False. A role that is not fixed (one
# grant edge `u-<h>` per `uses` line, grants.mojo) is found through the
# cloud: `list_owned` names
# every object of this machine and cell; one owned by a resource still in the
# file but no longer lowered is added as a turned-off node, so it is removed;
# one owned by a resource the file no longer names is LEFTOVER, reported and
# never deleted here.
#
# RETENTION ON THAT PATH. An object `list_owned` reports as RETAINED (its
# `kci-retention=retain` mark) is never turned into a node to remove: it is LEFT
# BEHIND, reported beside the leftover, and nothing deletes it. That is the
# only thing that can say "keep" once the file stops lowering the node (a
# KEEP bucket whose id is re-used by another type, say): the lowering no
# longer holds it, so the engine would otherwise see a plain turned-off node
# and delete it. A KEEP node still in the file is skipped by the engine's
# destroy (its realized retention).
#
# A TABLE'S KEY IS IMMUTABLE. The same `list_owned` read reports each table
# object's stored key (`OwnedRecord.key`); a plan or an apply whose
# `<id>/table` node asks for a different key is refused with the one refusal
# text (`data.key_change_findings`, naming the old and the new key) before
# anything is realized or created. A destroy is not refused: it removes what
# the cloud holds, whatever key the file now writes.
#
# THE METADATA (metadata.mojo). `lower_data` writes the author's labels on
# every node of a resource (`label.<key>` fields) and the written cloud name
# on its primary node (`physical_name`); an adapter that writes either field
# itself breaks the lowering contract. A plan, an apply or a destroy whose
# primary node asks for another cloud name than the one its object was
# created under is refused after `list_owned`, before anything is realized
# (`metadata.name_change_findings`). Unlike a table key, a changed name
# refuses a destroy too: where a cloud addresses an object by its name, a
# destroy realized from the file's new name would address another object
# and leave the first one behind. Plan and apply run with the primary
# node of every resource that writes `adopt` in the scope's adopt list
# (`with_adopted`); destroy does not need it (the engine ignores it there).
#
# THE ROLE LABEL BUDGET. After lowering and before anything else, every
# node's role must fit the 63-byte label value (`role_budget_findings`); one
# that does not refuses the graph with the one refusal text. The owner of a
# node is its first segment at any depth (`owner_of_node`).
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
    RETAIN_DELETE,
    RETAIN_KEEP,
    ResourceGraph,
    StateStore,
    UndeletableSkip,
    apply_graph_owned,
    destroy_graph_owned,
    plan_graph_owned,
)
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import (
    CellContext,
    CloudAdapter,
    FINDING_CELL,
    Finding,
    LoweredNode,
    Setting,
)
from kci_cloud.catalog import (
    Catalog,
    RETENTION_KEEP,
    effective_retention,
    primary_node,
)
from kci_cloud.clouds import Clouds
from kci_cloud.data import key_change_findings
from kci_cloud.feed import feeds_of
from kci_cloud.grants import edges_for
from kci_cloud.firing import firings_of
from kci_cloud.labels import validation_run_problem
from kci_cloud.metadata import (
    LABEL_FIELD_PREFIX,
    PHYSICAL_NAME_FIELD,
    adopted_nodes,
    label_fields,
    name_change_findings,
)
from kci_cloud.validate import refusal_text, role_budget_findings, validate_for


def refuse_unless_valid[
    S: CloudAdapter
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    check_validation_run: Bool = True,
) raises:
    """Configure `cloud` with the cell, then validate; any finding raises the
    one refusal text. An unowned scope (no machine or cell) is refused:
    kci deploys only into a cell. With `check_validation_run` (plan and
    apply), a validation run id outside komira_validation_run's rule is a
    FINDING_CELL finding (`validation_run_id`). Destroy passes False: it
    writes no run-id label, and a cleanup must not be blocked by a mark it
    never writes."""
    if not ctx.scope.owned():
        raise Error(
            String("kci deploys only into a cell: the context names no")
            + String(" machine and cell")
        )
    var findings = List[Finding]()
    var run_problem = String("")
    if check_validation_run:
        run_problem = validation_run_problem(ctx.scope.validation_run_id)
    if run_problem.byte_length() > 0:
        findings.append(
            Finding(FINDING_CELL, String("(cell)"), String("validation_run_id"), run_problem)
        )
    findings.extend(cloud.configure(ctx))
    var more = validate_for(clouds, cloud, resources)
    for i in range(len(more)):
        findings.append(more[i].copy())
    if len(findings) > 0:
        raise Error(refusal_text(cloud.cloud_id(), findings))


def engine_retention(retention: Int) -> Int:
    """A catalog retention (`RETENTION_*`) as the engine's RETAIN_* code:
    KEEP is RETAIN_KEEP; DELETE and "takes none" are RETAIN_DELETE."""
    if retention == RETENTION_KEEP:
        return RETAIN_KEEP
    return RETAIN_DELETE


def _resolve(catalog: Catalog, resources: List[Resource], producer: String) raises -> String:
    """A bare resource id -> that resource's primary node; a node id is kept."""
    if producer.find("/") >= 0:
        return producer.copy()
    return primary_node(catalog, resources, producer)


def lower_data[
    S: CloudAdapter
](cloud: S, resources: List[Resource]) raises -> List[LoweredNode]:
    """Lower every resource to data (each with its grant edges and the
    list's feeds and firings), check the lowering contract, then resolve
    references to resources and set each node's retention."""
    var catalog = Catalog.v1()
    var out = List[LoweredNode]()
    var feeds = feeds_of(resources)
    var firings = firings_of(resources)
    for i in range(len(resources)):
        ref r = resources[i]
        var retention = engine_retention(effective_retention(catalog, r))
        var nodes = cloud.lower(r, edges_for(resources, r), feeds, firings)
        if len(nodes) == 0:
            raise Error(
                String("cloud \"")
                + cloud.cloud_id().text()
                + String("\" lowered resource \"")
                + r.id
                + String("\" to no nodes")
            )
        var prefix = r.id + String("/")
        var primary = primary_node(catalog, resources, r.id)
        var named = False
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
            for k in range(len(node.desired)):
                ref key = node.desired[k].key
                if key == PHYSICAL_NAME_FIELD or key.startswith(LABEL_FIELD_PREFIX):
                    raise Error(
                        String("cloud \"")
                        + cloud.cloud_id().text()
                        + String("\" broke the lowering contract on \"")
                        + node.id
                        + String("\": it wrote the desired field \"")
                        + key
                        + String("\", which is kci's (the metadata)")
                    )
            var low = node.copy()
            low.desired.extend(label_fields(r))
            if node.id == primary and r.physical_name:
                low.desired.append(Setting(String(PHYSICAL_NAME_FIELD), r.physical_name.value()))
                named = True
            for k in range(len(low.depends_on)):
                low.depends_on[k] = _resolve(catalog, resources, low.depends_on[k])
            for k in range(len(low.inputs)):
                low.inputs[k].producer = _resolve(catalog, resources, low.inputs[k].producer)
            low.retention = retention
            out.append(low^)
        if r.physical_name and not named:
            raise Error(
                String("cloud \"")
                + cloud.cloud_id().text()
                + String("\" lowered no primary node \"")
                + primary
                + String("\" to hold the cloud name of \"")
                + r.id
                + String("\"")
            )
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
    owner, wanted and retention."""
    var graph = ResourceGraph()
    for i in range(len(nodes)):
        ref want = nodes[i]
        var node = cloud.realize(want)
        var lid = node.logical_id()
        var own = node.owner()
        if node.retention() != want.retention:
            raise Error(
                String("cloud \"")
                + cloud.cloud_id().text()
                + String("\" realized node \"")
                + want.id
                + String("\" with retention ")
                + String(node.retention())
                + String(", not ")
                + String(want.retention)
                + String("; realize must keep the retention kci set")
            )
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
    the file that the file turned off (`roles`, to remove), RETAINED objects
    of resources still in the file that the file no longer lowers
    (`left_behind`, reported only), and nodes of resources the file no
    longer names (`leftover`, reported only). And `key_changes`: a table
    whose stored key differs from the one the file asks for (refused by plan
    and apply). And `name_changes`: a node whose object was created under
    another cloud name than the one the file asks for (refused by plan,
    apply and destroy)."""

    var roles: List[LoweredNode]
    var left_behind: List[String]
    var leftover: List[String]
    var key_changes: List[Finding]
    var name_changes: List[Finding]

    def __init__(out self):
        self.roles = List[LoweredNode]()
        self.left_behind = List[String]()
        self.leftover = List[String]()
        self.key_changes = List[Finding]()
        self.name_changes = List[Finding]()


def owner_of_node(node_id: String) -> String:
    """The authored resource that owns node `node_id`: its FIRST segment, at
    any depth (`top/a/b/c/run` -> `top`). Ids cannot hold `/`, so this is
    exact however deep a node is."""
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
    out.key_changes = key_change_findings(nodes, owned)
    out.name_changes = name_change_findings(nodes, owned)
    for i in range(len(owned)):
        var nid = owned[i].owner_node.copy()
        var lowered = False
        for k in range(len(nodes)):
            if nodes[k].id == nid:
                lowered = True
                break
        if lowered:
            continue
        var res = owner_of_node(nid)
        var in_file = False
        for k in range(len(resources)):
            if resources[k].id == res:
                in_file = True
                break
        if in_file and owned[i].retained:
            # Kept by retention: reported, never a node to remove.
            var seen = False
            for k in range(len(out.left_behind)):
                if out.left_behind[k] == nid:
                    seen = True
                    break
            if not seen:
                out.left_behind.append(nid^)
        elif in_file:
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
    mut left_behind: List[String],
    refuse_key_change: Bool = True,
) raises -> ResourceGraph:
    """Lowering + the roles `list_owned` says to remove, realized. A role
    over the label budget refuses the graph here: after lowering (data),
    before `list_owned`, realize or any create. A changed table key refuses
    it after `list_owned` and before realize (unless `refuse_key_change` is
    False: a destroy)."""
    var nodes = lower_data(cloud, resources)
    var over = role_budget_findings(nodes)
    if len(over) > 0:
        raise Error(refusal_text(cloud.cloud_id(), over))
    var rem = removals(cloud, ctx, nodes, resources, creds)
    if len(rem.name_changes) > 0:
        raise Error(refusal_text(cloud.cloud_id(), rem.name_changes))
    if refuse_key_change and len(rem.key_changes) > 0:
        raise Error(refusal_text(cloud.cloud_id(), rem.key_changes))
    for i in range(len(rem.roles)):
        nodes.append(rem.roles[i].copy())
    leftover = rem.leftover.copy()
    left_behind = rem.left_behind.copy()
    return realize_graph(cloud, nodes)


def with_adopted(ctx: CellContext, resources: List[Resource]) raises -> CellContext:
    """`ctx` with the primary node of every resource that writes `adopt`
    added to its scope's adopt list (each once)."""
    var out = ctx.copy()
    var nodes = adopted_nodes(Catalog.v1(), resources)
    for i in range(len(nodes)):
        if not out.scope.adopts(nodes[i]):
            out.scope.adopt.append(nodes[i])
    return out^


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
    var left_behind = List[String]()
    var graph = _graph_for(cloud, ctx, resources, creds, leftover, left_behind)
    return plan_graph_owned(graph, creds, with_adopted(ctx, resources).scope, store)


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
      * `left_behind` — RETAINED objects (`kci-retention=retain`) of resources
                     still in the file that the file no longer lowers;
                     reported, never deleted.

    A caller that only got a bool (or only the error) could not tell "nothing
    happened" from "half the graph is live": that is the PARTIAL outcome a
    driver must not retry blindly, and these lists are how it is reported.
    """

    var applied: List[AppliedNode]
    var landed: List[AppliedNode]
    var pending: List[String]
    var error: Optional[String]
    var leftover: List[String]
    var left_behind: List[String]

    def __init__(
        out self,
        var applied: List[AppliedNode],
        var landed: List[AppliedNode],
        var pending: List[String],
        var error: Optional[String],
        var leftover: List[String] = List[String](),
        var left_behind: List[String] = List[String](),
    ):
        self.applied = applied^
        self.landed = landed^
        self.pending = pending^
        self.error = error^
        self.leftover = leftover^
        self.left_behind = left_behind^

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
    var left_behind = List[String]()
    var graph = _graph_for(cloud, ctx, resources, creds, leftover, left_behind)
    var scope = with_adopted(ctx, resources).scope.copy()
    var landed = List[AppliedNode]()
    var pending = List[String]()
    var applied = List[AppliedNode]()
    var error: Optional[String] = None
    try:
        applied = apply_graph_owned(graph, creds, scope, store, landed, pending)
    except e:
        error = String(e)
    if error:
        return ApplyOutcome(
            List[AppliedNode](), landed^, pending^, error^, leftover^, left_behind^
        )
    return ApplyOutcome(applied^, landed^, pending^, None, leftover^, left_behind^)


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
    retention honoured: a KEEP node is skipped, nothing foreign deleted). The
    roles a resource in the file turned off are torn down with it; a retained
    object the file no longer lowers is not. A graph this cloud cannot host
    cannot have been applied by it, so it is refused here too rather than
    half-lowered. The scope's validation run id is not checked: destroy
    writes no run-id label, so a malformed one does not block a cleanup."""
    refuse_unless_valid(clouds, cloud, ctx, resources, check_validation_run=False)
    var leftover = List[String]()
    var left_behind = List[String]()
    var graph = _graph_for(
        cloud, ctx, resources, creds, leftover, left_behind, refuse_key_change=False
    )
    return destroy_graph_owned(graph, creds, ctx.scope, store)


def group_plan(actions: List[ChangeAction]) -> String:
    """A plan grouped under the authored resources, in first-seen order:
    `api: create api/run, create api/u-mz4k2q`. A node with no owner is
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
