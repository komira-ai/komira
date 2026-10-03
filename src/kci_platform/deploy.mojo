# =============================================================================
# kci_platform/deploy.mojo: validate, lower, then hand the graph to the engine.
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

from kci_iac import (
    AppliedNode,
    ChangeAction,
    Creds,
    ResourceGraph,
    StateStore,
    UndeletableSkip,
    apply_graph,
    destroy_graph,
    plan_graph,
)
from kci_resource_proto.resource import Resource

from kci_platform.adapter import AdapterSet
from kci_platform.registry import Registry
from kci_platform.validate import refusal_text, validate_for


def refuse_unless_valid[
    S: AdapterSet
](registry: Registry, platform: S, resources: List[Resource]) raises:
    var findings = validate_for(registry, platform, resources)
    if len(findings) > 0:
        raise Error(refusal_text(platform.platform_id(), findings))


def lower_resources[
    S: AdapterSet
](mut platform: S, resources: List[Resource]) raises -> ResourceGraph:
    """Lower every resource and check the lowering contract."""
    var graph = ResourceGraph()
    for i in range(len(resources)):
        ref r = resources[i]
        var before = graph.num_nodes()
        platform.lower(r, graph)
        if graph.num_nodes() == before:
            raise Error(
                String("platform \"")
                + platform.platform_id().text()
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
                    String("platform \"")
                    + platform.platform_id().text()
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
    S: AdapterSet
](
    registry: Registry, mut platform: S, resources: List[Resource], creds: Creds
) raises -> List[ChangeAction]:
    """The dry run: validate, lower, `plan_graph`. Creates nothing."""
    refuse_unless_valid(registry, platform, resources)
    var graph = lower_resources(platform, resources)
    return plan_graph(graph, creds)


def apply_resources[
    S: AdapterSet, St: StateStore
](
    registry: Registry,
    mut platform: S,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
) raises -> List[AppliedNode]:
    """Validate, lower, `apply_graph`."""
    refuse_unless_valid(registry, platform, resources)
    var graph = lower_resources(platform, resources)
    return apply_graph(graph, creds, store)


def destroy_resources[
    S: AdapterSet, St: StateStore
](
    registry: Registry,
    mut platform: S,
    resources: List[Resource],
    creds: Creds,
    mut store: St,
) raises -> List[UndeletableSkip]:
    """Validate, lower, `destroy_graph` (reverse order, retention honoured).
    A graph this platform cannot host cannot have been applied by it, so it
    is refused here too rather than half-lowered."""
    refuse_unless_valid(registry, platform, resources)
    var graph = lower_resources(platform, resources)
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
