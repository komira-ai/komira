# =============================================================================
# kci_cloud/cycles.mojo: a reference cycle between resources is a graph
#   finding.
# =============================================================================
#
# Two services each reading the other's URL can be created in no order: each
# needs the other's output before it exists. The engine finds that only when
# it sorts the realized graph (`topo_sort`, inside plan and apply), after the
# cloud has been read, and its error is untyped. So validate refuses the
# cycle first, as a FINDING_GRAPH finding, before anything is listed, read or
# realized: plan and apply return the typed refusal (refusal.mojo).
#
# THE EDGES. Resource A has an edge to resource B for every reference
# position of A (compose_refs.ref_sites, the one walk over them) that names
# B, EXCEPT:
#   * `uses[i].target` and a grant's `principal` and `target`: an edge of
#     access lowers to a node of its own (grants.mojo, `u-<h>`), owned by the
#     principal, which depends on both ends; the principal's own nodes do not
#     wait for the target. Two services that call each other are legal.
#   * `queue.dead_letter`: a dead-letter cycle is refused by messaging.mojo
#     already, naming the queues.
# A reference to the resource itself is refused by values.mojo, and one to a
# resource that is not in the list by the graph rules; neither is an edge.
#
# What this cannot see: a cycle that only the lowering's helper nodes create
# (an adapter's node that depends on another resource's node, with no
# reference between the two resources) still reaches the engine, and stays
# its untyped error.
#
# Each cycle is reported once, on its smallest resource id, printed from that
# id (`a -> b -> a`), with the reference position of its first step as the
# field. A strongly connected set of resources holding several cycles is
# reported at least once; the graph is refused either way.
# =============================================================================

from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.compose_refs import RefSite, SITE_REF, ref_sites


comptime _WHITE: Int = 0
comptime _GREY: Int = 1
comptime _BLACK: Int = 2


def _is_edge(path: String) -> Bool:
    """True iff the reference position `path` makes its resource wait for
    the resource it names (the header)."""
    if path.startswith("uses[") or path.startswith("grant."):
        return False
    return path != "queue.dead_letter"


def _named(site: RefSite) -> String:
    """The resource a reference position names, or empty (a literal value,
    a parameter, an unset reference)."""
    if site.kind == SITE_REF:
        if Bool(site.ref_):
            return site.ref_.value().resource.copy()
        return String("")
    if Bool(site.value) and site.value.value()._oneof0_case == 3:
        return site.value.value().ref_.value().resource.copy()
    return String("")


def _first_index(resources: List[Resource], id: String) -> Int:
    for i in range(len(resources)):
        if resources[i].id == id:
            return i
    return -1


struct _Graph(Movable):
    """The reference graph: `to[i]` the resources `resources[i]` waits for,
    `path[i]` the reference position of each of those edges, in order; and
    the walk's state."""

    var to: List[List[Int]]
    var path: List[List[String]]
    var color: List[Int]
    var stack: List[Int]
    var keys: List[String]

    def __init__(out self, resources: List[Resource]):
        self.to = List[List[Int]]()
        self.path = List[List[String]]()
        self.color = List[Int]()
        self.stack = List[Int]()
        self.keys = List[String]()
        for i in range(len(resources)):
            var to = List[Int]()
            var paths = List[String]()
            ref r = resources[i]
            if r.id.byte_length() > 0 and _first_index(resources, r.id) == i:
                var sites: List[RefSite]
                try:
                    sites = ref_sites(r)
                except:
                    sites = List[RefSite]()  # a shape the walk refuses is a finding of its own
                for k in range(len(sites)):
                    var name = _named(sites[k])
                    if name.byte_length() == 0 or not _is_edge(sites[k].path):
                        continue
                    var j = _first_index(resources, name)
                    if j < 0 or j == i:
                        continue
                    to.append(j)
                    paths.append(sites[k].path.copy())
            self.to.append(to^)
            self.path.append(paths^)
            self.color.append(_WHITE)

    def path_of(self, i: Int, j: Int) -> String:
        """The reference position of the first edge `i -> j`."""
        for k in range(len(self.to[i])):
            if self.to[i][k] == j:
                return self.path[i][k].copy()
        return String("")


def _report(resources: List[Resource], mut g: _Graph, at: Int, mut out: List[Finding]):
    """The cycle closed by an edge back to `resources[at]`: the walk's stack
    from `at` to its top. Reported once, from its smallest id."""
    var cyc = List[Int]()
    var started = False
    for k in range(len(g.stack)):
        if g.stack[k] == at:
            started = True
        if started:
            cyc.append(g.stack[k])
    if len(cyc) < 2:
        return
    var lo = 0
    for k in range(1, len(cyc)):
        if resources[cyc[k]].id < resources[cyc[lo]].id:
            lo = k
    var text = String("")
    for k in range(len(cyc) + 1):
        if k > 0:
            text += String(" -> ")
        text += resources[cyc[(lo + k) % len(cyc)]].id
    for k in range(len(g.keys)):
        if g.keys[k] == text:
            return
    g.keys.append(text.copy())
    var first = cyc[lo]
    var second = cyc[(lo + 1) % len(cyc)]
    out.append(
        Finding(
            FINDING_GRAPH,
            resources[first].id,
            g.path_of(first, second),
            String("a reference cycle: ")
            + text
            + String("; each resource reads an output of the next, so no order can create them"),
        )
    )


def _visit(resources: List[Resource], mut g: _Graph, i: Int, mut out: List[Finding]):
    g.color[i] = _GREY
    g.stack.append(i)
    for k in range(len(g.to[i])):
        var j = g.to[i][k]
        if g.color[j] == _GREY:
            _report(resources, g, j, out)
        elif g.color[j] == _WHITE:
            _visit(resources, g, j, out)
    _ = g.stack.pop()
    g.color[i] = _BLACK


def reference_cycle_findings(resources: List[Resource]) -> List[Finding]:
    """A FINDING_GRAPH finding per reference cycle between resources of
    `resources` (the header), each once, in the order a walk from the first
    resource meets them."""
    var out = List[Finding]()
    var g = _Graph(resources)
    for i in range(len(resources)):
        if g.color[i] == _WHITE:
            _visit(resources, g, i, out)
    return out^
