# =============================================================================
# kci_cloud/deploy.mojo: validate, lower, then hand the graph to the engine.
# =============================================================================
#
# The three verbs every command runs through. Each one validates FIRST and
# refuses the whole graph on any finding, before lowering, so a refused
# graph never reaches an adapter's `lower` and never reaches the engine:
# nothing is created, and the adapter is never asked to.
#
# `lower_resources` also holds every adapter to the lowering contract, on
# every run and not only in tests: each resource lowers to at least one node,
# every node's id is `<resource id>/<role>`, and every node's `owner()` is the
# resource it came from. A plan grouped by owner is only honest if that holds.
# =============================================================================

from kci_reconciler import (
    AppliedNode,
    ChangeAction,
    Creds,
    ResourceGraph,
    StateStore,
    UndeletableSkip,
    apply_graph_tracked,
    destroy_graph,
    plan_graph,
)
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import CloudAdapter
from kci_cloud.clouds import Clouds
from kci_cloud.validate import refusal_text, validate_for


def refuse_unless_valid[
    S: CloudAdapter
](clouds: Clouds, cloud: S, resources: List[Resource]) raises:
    var findings = validate_for(clouds, cloud, resources)
    if len(findings) > 0:
        raise Error(refusal_text(cloud.cloud_id(), findings))


def lower_resources[
    S: CloudAdapter
](mut cloud: S, resources: List[Resource]) raises -> ResourceGraph:
    """Lower every resource and check the lowering contract."""
    var graph = ResourceGraph()
    for i in range(len(resources)):
        ref r = resources[i]
        var before = graph.num_nodes()
        cloud.lower(r, graph)
        if graph.num_nodes() == before:
            raise Error(
                String("cloud \"")
                + cloud.cloud_id().text()
                + String("\" lowered resource \"")
                + r.id
                + String("\" to no nodes")
            )
        var prefix = r.id + String("/")
        for n in range(before, graph.num_nodes()):
            var lid = graph.node(n).logical_id()
            var own = graph.node(n).owner()
            if own != r.id or not lid.startswith(prefix):
                raise Error(
                    String("cloud \"")
                    + cloud.cloud_id().text()
                    + String("\" broke the lowering contract on \"")
                    + r.id
                    + String("\": node \"")
                    + lid
                    + String("\" has owner \"")
                    + own
                    + String("\"; every node must be \"")
                    + prefix
                    + String("<role>\" and owned by its resource")
                )
    return graph^


def plan_resources[
    S: CloudAdapter
](
    clouds: Clouds, mut cloud: S, resources: List[Resource], creds: Creds
) raises -> List[ChangeAction]:
    """The dry run: validate, lower, `plan_graph`. Creates nothing."""
    refuse_unless_valid(clouds, cloud, resources)
    var graph = lower_resources(cloud, resources)
    return plan_graph(graph, creds)


struct ApplyOutcome(Movable, Deinitable):
    """What an apply did, whether or not it finished.

      * `error`   — None when every node converged; else the engine's error
                    (it names the node, the verb and the fault domain).
      * `applied` — every node, in apply order, when `error` is None; empty
                    otherwise (use `landed`).
      * `landed`  — the nodes this apply acted on before it stopped, in apply
                    order, each with the verb it issued. On success it equals
                    `applied`. These mutations are LIVE in the cell.
      * `pending` — the nodes it never reached, in the order they would have
                    run; the failing node is the first. Empty on success.

    A caller that only got a bool (or only the error) could not tell "nothing
    happened" from "half the graph is live": that is the PARTIAL outcome a
    driver must not retry blindly, and these lists are how it is reported.
    """

    var applied: List[AppliedNode]
    var landed: List[AppliedNode]
    var pending: List[String]
    var error: Optional[String]

    def __init__(
        out self,
        var applied: List[AppliedNode],
        var landed: List[AppliedNode],
        var pending: List[String],
        var error: Optional[String],
    ):
        self.applied = applied^
        self.landed = landed^
        self.pending = pending^
        self.error = error^

    def ok(self) -> Bool:
        return not self.error

    def partial(self) -> Bool:
        """True iff the apply failed AFTER at least one node landed."""
        return Bool(self.error) and len(self.landed) > 0


def apply_resources[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
) raises -> ApplyOutcome:
    """Validate, lower, then `apply_graph_tracked`.

    RAISES only before any effect: a refused graph (the validate phase) or a
    broken lowering contract. A failure inside the engine is NOT raised: it
    is returned in the outcome with what landed and what is pending, so the
    caller can report a partial apply instead of a bare failure."""
    refuse_unless_valid(clouds, cloud, resources)
    var graph = lower_resources(cloud, resources)
    var landed = List[AppliedNode]()
    var pending = List[String]()
    var applied = List[AppliedNode]()
    var error: Optional[String] = None
    try:
        applied = apply_graph_tracked(graph, creds, store, landed, pending)
    except e:
        error = String(e)
    if error:
        return ApplyOutcome(List[AppliedNode](), landed^, pending^, error^)
    return ApplyOutcome(applied^, landed^, pending^, None)


def destroy_resources[
    S: CloudAdapter, St: StateStore
](
    clouds: Clouds,
    mut cloud: S,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
) raises -> List[UndeletableSkip]:
    """Validate, lower, `destroy_graph` (reverse order, retention honoured).
    A graph this cloud cannot host cannot have been applied by it, so it
    is refused here too rather than half-lowered."""
    refuse_unless_valid(clouds, cloud, resources)
    var graph = lower_resources(cloud, resources)
    return destroy_graph(graph, creds, store)


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
