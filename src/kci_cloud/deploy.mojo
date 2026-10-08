# =============================================================================
# kci_cloud/deploy.mojo: configure, validate, lower to data, realize, then
#   hand the graph to the engine, in a cell.
# =============================================================================
#
# The three verbs every command runs through. Each one runs in a CELL
# (`CellContext`: machine, cell, provenance, adopt, validation run id,
# settings) and FIRST configures the adapter with the cell's settings,
# EXPANDS the list's composite instances with the definitions it was given
# (compose.mojo) and validates the expanded list: any finding (a validation
# run id outside komira_validation_run's rule, on plan and apply only; a
# setting, an expansion finding, the graph, coverage, a limit, the
# platform, the public mechanism) refuses the whole graph before lowering,
# so a refused graph never reaches an adapter's `lower` and never reaches the
# engine: nothing is created, and the adapter is never asked to.
#
# LOWERING IS DATA. `lower_data` asks the adapter for `LoweredNode`s and holds
# them to the lowering contract on every run (not only in tests): each
# resource lowers to at least one node, every node id is `<resource
# id>/<role>`, every node's owner is the resource it came from, and no id
# repeats. It then sets each node's OWNER to the first segment of its
# resource's id: a primitive written at the top owns its nodes, and every
# node of an expanded `top/c1/.../ck` is owned by `top`, however deep, so the
# stamp, the store key and the closed world below keep one owner per object.
# It then RESOLVES what is kci's to decide, not the cloud's: a
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
# never deleted here. "Still in the file" is by OWNER: a top-level instance
# is in the file while any of its primitives is, so a component its
# definition dropped (at any depth) is a role of `top` no longer lowered, and
# is removed.
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
# SAFE ADOPTION (adoption.mojo). `lower_data` marks the primary node of a
# resource that writes `adopt` (`LoweredNode.adopted`). Plan and apply then
# read each marked node's object and refuse a missing one or an unstamped
# one that is not what the file declares (`adoption_check`), and an object
# carrying the adoption mark whose resource does not write `adopt`
# (`unadopted_findings`), after `list_owned` and before anything is
# realized. An object carrying the
# adoption mark whose resource left the list is RELEASED by the apply, never
# deleted (`Removals.releases`; its state record is retired, then
# `CloudAdapter.release`), and is not leftover. A delete of an adopted
# object is refused before any change unless its resource writes `adopt`
# ADOPT_DELETABLE (`delete_findings` on plan, apply and destroy). A replace
# of an adopted node is refused whatever `adopt` says (`replace_findings`
# on the engine's plan, which apply runs first when the run has adopted
# nodes; a replace the plan cannot see, of a node it reports as known after
# apply, is not refused: the engine stops the apply there instead of
# replacing). `plan_report` returns the plan with its adopted
# nodes and releases, and `render_plan` prints them.
#
# THE ROLE LABEL BUDGET. Every node's role must fit the 63-byte label value;
# validate reports a role that does not (`lowered_budget_findings`, item 4
# of validate.mojo), so plan, apply and destroy, which validate first,
# refuse it with the one refusal text before anything is listed, realized
# or created. The owner of a node is its first segment at any depth
# (`owner_of_node`).
#
# Every verb runs the engine's OWNED forms (the cell scope): the store keyed
# by (machine, cell, resource), the stamp born with each object, and a
# foreign or conflicting object refused before any change.
#
# THE TYPED REFUSAL (refusal.mojo). `plan_report` and `apply_resources`,
# given a `refusal` argument, set it to a `Refusal` exactly when the run is
# refused before any change: any finding above (kci_cloud's own, raised with
# the one refusal text) or the engine's ownership refusal (by_engine). A plan
# raises either; an apply raises kci_cloud's and returns the engine's in
# `ApplyOutcome.refusal`. Anything else the verbs raise (a read that failed,
# a broken lowering contract, a `realize` that raised, an engine error) leaves
# it None, so a caller tells REFUSED from FAILED without reading text. An
# apply whose engine run finished and whose release then failed is typed
# apart too (`ApplyOutcome.failed_release`). A plan's report also carries the
# `leftover` and `left_behind` the apply would report.
# =============================================================================

from kci_reconciler import (
    AppliedNode,
    CellScope,
    ChangeAction,
    Creds,
    InputRef,
    RETAIN_DELETE,
    RETAIN_KEEP,
    ResourceGraph,
    StateStore,
    UndeletableSkip,
    apply_graph_owned,
    destroy_graph_owned,
    plan_graph_owned,
)
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import (
    CellContext,
    CloudAdapter,
    FINDING_CELL,
    Finding,
    LoweredNode,
    OwnedRecord,
    Setting,
)
from kci_cloud.adoption import (
    PlanReport,
    adopted_nodes_of,
    adoption_check,
    delete_findings,
    replace_findings,
    unadopted_findings,
    resource_of_node,
)
from kci_cloud.catalog import (
    Catalog,
    RETENTION_KEEP,
    effective_retention,
    primary_node,
)
from kci_cloud.cloud_id import CloudId
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
    adopts,
    label_fields,
    name_change_findings,
)
from kci_cloud.compose import expand
from kci_cloud.compose_refs import owner_of_node
from kci_cloud.outcome import ApplyOutcome
from kci_cloud.refusal import Refusal, engine_refusal, graph_refusal
from kci_cloud.validate import validate_expanded


def refuse_unless_valid[
    S: CloudAdapter
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    check_validation_run: Bool = True,
    definitions: List[CompositeDefinition] = List[CompositeDefinition](),
) raises:
    """`valid_expansion`, for a caller that needs only the refusal."""
    _ = valid_expansion(clouds, cloud, ctx, resources, check_validation_run, definitions)


def valid_expansion[
    S: CloudAdapter
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    check_validation_run: Bool = True,
    definitions: List[CompositeDefinition] = List[CompositeDefinition](),
) raises -> List[Resource]:
    """Configure `cloud` with the cell, expand `resources` with
    `definitions`, then validate the expanded list; any finding raises the
    one refusal text, else the expanded list is returned (the list itself
    when it holds no instance). An unowned scope (no machine or cell) is
    refused: kci deploys only into a cell. With `check_validation_run` (plan
    and apply), a validation run id outside komira_validation_run's rule is
    a FINDING_CELL finding (`validation_run_id`). Destroy passes False: it
    writes no run-id label, and a cleanup must not be blocked by a mark it
    never writes. An expansion finding is reported beside the cell's
    findings, and the expanded graph is not judged."""
    var refusal = Optional[Refusal](None)
    return _valid_expansion(clouds, cloud, ctx, resources, check_validation_run, definitions, refusal)


def _refuse(cloud: CloudId, findings: List[Finding], mut refusal: Optional[Refusal]) raises:
    """Set `refusal` to kci_cloud's refusal of `findings`, and raise its
    text."""
    var r = graph_refusal(cloud, findings)
    var text = r.text.copy()
    refusal = r^
    raise Error(text)


def _valid_expansion[
    S: CloudAdapter
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    check_validation_run: Bool,
    definitions: List[CompositeDefinition],
    mut refusal: Optional[Refusal],
) raises -> List[Resource]:
    """`valid_expansion`, setting `refusal` when it refuses."""
    if not ctx.scope.owned():
        var text = String("kci deploys only into a cell: the context names no") + String(" machine and cell")
        var why = List[Finding]()
        why.append(Finding(FINDING_CELL, String("(cell)"), String("scope"), text))
        refusal = Refusal(False, why^, text)
        raise Error(text)
    var findings = List[Finding]()
    var run_problem = String("")
    if check_validation_run:
        run_problem = validation_run_problem(ctx.scope.validation_run_id)
    if run_problem.byte_length() > 0:
        findings.append(
            Finding(FINDING_CELL, String("(cell)"), String("validation_run_id"), run_problem)
        )
    findings.extend(cloud.configure(ctx))
    var x = expand(clouds.catalog, definitions, resources)
    var more: List[Finding]
    if len(x.findings) > 0:
        more = x.findings.copy()
    else:
        more = validate_expanded(clouds, cloud, x.resources, x.produced)
    for i in range(len(more)):
        findings.append(more[i].copy())
    if len(findings) > 0:
        _refuse(cloud.cloud_id(), findings, refusal)
    return x.resources.copy()


def engine_retention(retention: Int) -> Int:
    """A catalog retention (`RETENTION_*`) as the engine's RETAIN_* code:
    KEEP is RETAIN_KEEP; DELETE and "takes none" are RETAIN_DELETE."""
    if retention == RETENTION_KEEP:
        return RETAIN_KEEP
    return RETAIN_DELETE


def _resolve(catalog: Catalog, resources: List[Resource], producer: String) raises -> String:
    """A resource id -> that resource's primary node; a node id is kept. A
    resource id may hold `/` (an expanded path), so the test is membership,
    never the separator: no resource id is also a node id (a node id is a
    resource id plus a role, and a primitive has no components)."""
    for i in range(len(resources)):
        if resources[i].id == producer:
            return primary_node(catalog, resources, producer)
    if producer.find("/") < 0:
        return primary_node(catalog, resources, producer)  # raises: no such resource
    return producer.copy()


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
            low.owner = owner_of_node(r.id)
            low.adopted = node.id == primary and adopts(r)
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
    apply and destroy). And `releases`: objects carrying the adoption mark
    whose resource left the list (released by an apply, never deleted, and
    not leftover). And `owned`: what `list_owned` said."""

    var roles: List[LoweredNode]
    var left_behind: List[String]
    var leftover: List[String]
    var key_changes: List[Finding]
    var name_changes: List[Finding]
    var releases: List[OwnedRecord]
    var owned: List[OwnedRecord]

    def __init__(out self):
        self.roles = List[LoweredNode]()
        self.left_behind = List[String]()
        self.leftover = List[String]()
        self.key_changes = List[Finding]()
        self.name_changes = List[Finding]()
        self.releases = List[OwnedRecord]()
        self.owned = List[OwnedRecord]()


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
        if owned[i].adopted and resource_of_node(resources, nid) < 0:
            # Adopted, and its resource left the list: released, never
            # deleted (adoption.mojo, rule 4).
            var again = False
            for k in range(len(out.releases)):
                if out.releases[k].owner_node == nid:
                    again = True
                    break
            if not again:
                out.releases.append(owned[i].copy())
            continue
        var res = owner_of_node(nid)
        var in_file = False
        for k in range(len(resources)):
            if owner_of_node(resources[k].id) == res:
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
    out.owned = owned^
    return out^


struct _Prepared(Movable):
    """What a verb acts on: the lowering plus the roles to remove (`nodes`,
    not yet realized), what is reported beside it, the adoption mark's
    releases and the run's adopted nodes (adoption.mojo)."""

    var nodes: List[LoweredNode]
    var leftover: List[String]
    var left_behind: List[String]
    var releases: List[OwnedRecord]
    var adopted: List[String]

    def __init__(out self):
        self.nodes = List[LoweredNode]()
        self.leftover = List[String]()
        self.left_behind = List[String]()
        self.releases = List[OwnedRecord]()
        self.adopted = List[String]()


def _prepare[
    S: CloudAdapter
](
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut refusal: Optional[Refusal],
    destroy: Bool = False,
) raises -> _Prepared:
    """Lowering + the roles `list_owned` says to remove. Called after
    validate, which has refused a role over the label budget. Refused after
    `list_owned` and before realize: a changed cloud name; a changed table
    key (not on a destroy); on plan and apply, an object carrying the
    adoption mark whose resource does not write `adopt`, and an adopted
    object missing or not the one declared; and a delete of an object carrying the adoption
    mark that its resource does not allow. Each refusal sets `refusal`; a
    read that raises (`list_owned`, `read_existing`) and a broken lowering
    contract do not."""
    var out = _Prepared()
    out.nodes = lower_data(cloud, resources)
    var rem = removals(cloud, ctx, out.nodes, resources, creds)
    if len(rem.name_changes) > 0:
        _refuse(cloud.cloud_id(), rem.name_changes, refusal)
    if not destroy and len(rem.key_changes) > 0:
        _refuse(cloud.cloud_id(), rem.key_changes, refusal)
    var taking = List[String]()
    if not destroy:
        var marked = unadopted_findings(out.nodes, rem.owned, resources)
        if len(marked) > 0:
            _refuse(cloud.cloud_id(), marked, refusal)
        var check = adoption_check(cloud, creds, out.nodes)
        if len(check.findings) > 0:
            _refuse(cloud.cloud_id(), check.findings, refusal)
        taking = check.taking.copy()
    for i in range(len(rem.roles)):
        out.nodes.append(rem.roles[i].copy())
    var deletes = delete_findings(out.nodes, rem.owned, resources, destroy)
    if len(deletes) > 0:
        _refuse(cloud.cloud_id(), deletes, refusal)
    out.adopted = adopted_nodes_of(rem.owned, taking)
    out.leftover = rem.leftover.copy()
    out.left_behind = rem.left_behind.copy()
    out.releases = rem.releases.copy()
    return out^


def _released_ids(releases: List[OwnedRecord]) -> List[String]:
    var out = List[String]()
    for i in range(len(releases)):
        out.append(releases[i].owner_node.copy())
    return out^


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
    definitions: List[CompositeDefinition] = List[CompositeDefinition](),
) raises -> List[ChangeAction]:
    """The dry run (`plan_report`), its engine actions alone."""
    return plan_report(clouds, cloud, ctx, resources, creds, store, definitions).actions.copy()


def plan_report[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
    definitions: List[CompositeDefinition] = List[CompositeDefinition](),
) raises -> PlanReport:
    """`plan_report` with no refusal argument (the next form)."""
    var refusal = Optional[Refusal](None)
    return plan_report(clouds, cloud, ctx, resources, creds, store, definitions, refusal)


def plan_report[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
    definitions: List[CompositeDefinition],
    mut refusal: Optional[Refusal],
) raises -> PlanReport:
    """The dry run: configure, expand, validate, lower, check the adoptions,
    `plan_graph_owned`, then refuse a replace of any adopted node. Creates
    nothing and writes nothing to the store. The report names the adopted
    nodes, the releases an apply would make, and the leftover and left
    behind it would report. A refusal (kci_cloud's or the engine's) raises
    with `refusal` set; any other raise leaves it None."""
    refusal = None
    var expanded = _valid_expansion(clouds, cloud, ctx, resources, True, definitions, refusal)
    var p = _prepare(cloud, ctx, expanded, creds, refusal)
    var graph = realize_graph(cloud, p.nodes)
    var scope = with_adopted(ctx, expanded).scope.copy()
    var actions = List[ChangeAction]()
    try:
        actions = plan_graph_owned(graph, creds, scope, store)
    except e:
        refusal = engine_refusal(scope, String("plan"), String(e))
        raise e^
    var bad = replace_findings(actions, p.adopted)
    if len(bad) > 0:
        _refuse(cloud.cloud_id(), bad, refusal)
    return PlanReport(
        actions^, p.adopted.copy(), _released_ids(p.releases), p.leftover.copy(), p.left_behind.copy()
    )


def apply_resources[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
    definitions: List[CompositeDefinition] = List[CompositeDefinition](),
) raises -> ApplyOutcome:
    """Configure, expand, validate, lower, then `apply_graph_owned` in the
    cell.

    RAISES only before any effect: a refused graph (settings or validate), a
    broken lowering contract, or a refused adoption (adoption.mojo: a
    missing or different adopted object, a delete of one its resource does
    not allow, a replace of any). A failure inside the engine, an ownership
    refusal included, is NOT raised: it is returned in the outcome with what
    landed and what is pending, so the caller can report a partial apply or
    a refusal instead of a bare failure. With adopted nodes, the engine's
    plan runs first (reads only) to refuse a planned replace before any
    change; an ownership refusal from that plan is left to the apply, which
    makes it the same way, and any other error of that plan is raised before
    any change. An adopted node the plan reports as known after apply (a
    producer of it changes in this run) is not read by the plan, so whether
    it needs a replace is not known before the apply; the engine never
    replaces an object (a drift it cannot converge in place stops the apply
    at that node, after the nodes before it landed). After the engine's
    apply succeeds, each release is made (its record retired, then
    `CloudAdapter.release`)."""
    var refusal = Optional[Refusal](None)
    return apply_resources(clouds, cloud, ctx, resources, creds, store, definitions, refusal)


def apply_resources[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
    definitions: List[CompositeDefinition],
    mut refusal: Optional[Refusal],
) raises -> ApplyOutcome:
    """`apply_resources` (the form above), with `refusal` set exactly when
    the run is refused before any change: raised (kci_cloud's refusal) or
    returned (the engine's, also in `ApplyOutcome.refusal`)."""
    refusal = None
    var expanded = _valid_expansion(clouds, cloud, ctx, resources, True, definitions, refusal)
    var p = _prepare(cloud, ctx, expanded, creds, refusal)
    var scope = with_adopted(ctx, expanded).scope.copy()
    if len(p.adopted) > 0:
        var pre = realize_graph(cloud, p.nodes)
        var actions = List[ChangeAction]()
        try:
            actions = plan_graph_owned(pre, creds, scope, store)
        except e:
            # Only the engine's ownership refusal (typed) steps aside: the
            # apply below makes it the same way, before any change, and
            # returns it. Any other error (a cloud read included) is raised
            # here, before any change.
            if not engine_refusal(scope, String("plan"), String(e)):
                raise e^
        var bad = replace_findings(actions, p.adopted)
        if len(bad) > 0:
            _refuse(cloud.cloud_id(), bad, refusal)
    var graph = realize_graph(cloud, p.nodes)
    var landed = List[AppliedNode]()
    var pending = List[String]()
    var applied = List[AppliedNode]()
    var error: Optional[String] = None
    try:
        applied = apply_graph_owned(graph, creds, scope, store, landed, pending)
    except e:
        error = String(e)
    if error:
        refusal = engine_refusal(scope, String("apply"), error.value())
        return ApplyOutcome(
            List[AppliedNode](),
            landed^,
            pending^,
            error^,
            p.leftover.copy(),
            p.left_behind.copy(),
            refusal=refusal.copy(),
        )
    var failed = String("")
    var released = _release(cloud, creds, scope, store, p.releases, error, failed)
    if error:
        # A failed release: the engine finished, so every node landed and
        # none is pending.
        return ApplyOutcome(
            List[AppliedNode](),
            applied^,
            pending^,
            error^,
            p.leftover.copy(),
            p.left_behind.copy(),
            released^,
            failed_release=failed^,
        )
    return ApplyOutcome(applied^, landed^, pending^, None, p.leftover.copy(), p.left_behind.copy(), released^)


def _release[
    S: CloudAdapter, St: StateStore
](
    mut cloud: S,
    creds: Creds,
    scope: CellScope,
    mut store: St,
    releases: List[OwnedRecord],
    mut error: Optional[String],
    mut failed: String,
) -> List[String]:
    """Release each object of `releases` in order (adoption.mojo, rule 4):
    its state record is retired, then the cloud drops its kci labels. The
    first failure stops the run and is set in `error`, its node in
    `failed`; the ids released
    before it are returned. Either failure leaves the object carrying its
    stamp and the adoption mark, so the next apply's `list_owned` reports it
    and releases it again (retiring a retired record is a no-op in
    `InMemoryStateStore`). The other order would leave, on a failed retire,
    an unstamped object with a live record, which the engine refuses as a
    conflict when a file names it again."""
    var done = List[String]()
    for i in range(len(releases)):
        ref rec = releases[i]
        try:
            store.mark_reaped(scope.key(rec.owner_node))
            cloud.release(creds, rec)
        except e:
            error = String("release of ") + rec.owner_node + String(" failed: ") + String(e)
            failed = rec.owner_node.copy()
            return done^
        done.append(rec.owner_node.copy())
    return done^


def destroy_resources[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
    definitions: List[CompositeDefinition] = List[CompositeDefinition](),
) raises -> List[UndeletableSkip]:
    """Configure, expand, validate, lower, `destroy_graph_owned` (reverse order,
    retention honoured: a KEEP node is skipped, nothing foreign deleted). The
    roles a resource in the file turned off are torn down with it; a retained
    object the file no longer lowers is not. A graph this cloud cannot host
    cannot have been applied by it, so it is refused here too rather than
    half-lowered. The scope's validation run id is not checked: destroy
    writes no run-id label, so a malformed one does not block a cleanup."""
    var expanded = valid_expansion(clouds, cloud, ctx, resources, False, definitions)
    var refusal = Optional[Refusal](None)
    var p = _prepare(cloud, ctx, expanded, creds, refusal, destroy=True)
    var graph = realize_graph(cloud, p.nodes)
    return destroy_graph_owned(graph, creds, ctx.scope, store)


def render_plan(report: PlanReport) -> String:
    """`group_plan` of a `plan_report`: its actions, the adopted nodes
    marked, and its releases."""
    return group_plan(report.actions, report.adopted, report.released)


def group_plan(
    actions: List[ChangeAction],
    adopted: List[String] = List[String](),
    released: List[String] = List[String](),
) -> String:
    """A plan grouped under the authored resources, in first-seen order:
    `api: create api/run, create api/u-mz4k2q`. A node with no owner is
    grouped under `(no owner)`. A node of `adopted` reads `update
    logs/bucket (adopted)`; each node of `released` ends the plan on a line
    of its own, under its owner: `old: release old/bucket (adopted; kci
    drops its stamp and record and leaves it standing)`."""
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
            for a in range(len(adopted)):
                if adopted[a] == actions[i].logical_id:
                    s += String(" (adopted)")
                    break
    for i in range(len(released)):
        if s.byte_length() > 0:
            s += String("\n")
        s += owner_of_node(released[i]) + String(": release ") + released[i]
        s += String(" (adopted; kci drops its stamp and record and leaves it standing)")
    return s^
