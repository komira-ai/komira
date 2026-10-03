# =============================================================================
# kci_reconciler/graph.mojo — the ResourceGraph (the DAG of erased resource nodes)
#   + Kahn topo-sort of the resource-graph deploy engine.
# =============================================================================
#
# THE GRAPH. A `ResourceGraph` holds N `ErasedResource` nodes (each a concrete
# `Resource` conformer, type-erased). The edges are IMPLICIT in each node's
# `depends_on()` (its IN-edges). `topo_sort` (Kahn's algorithm) returns the node
# INDICES in a dependency-correct order: a node appears AFTER every node it
# depends on. A CYCLE (or a dependency naming a logical_id not in the graph) is a
# fail-loud error — the engine cannot reconcile a graph it cannot order.
#
# WHY erased nodes (the homogeneous container). The graph holds N DISTINCT
# concrete conformer types (a CloudRunService node, a bucket node, a role node)
# in ONE container. A `Slab[ErasedResource]` (the in-tree Movable-only erased-
# handle collection shape — the SAME `Slab[ErasedHandle]` the async runtime uses)
# stores them uniformly; the engine drives each node BLIND through the erased
# `Resource` surface. The graph OWNS its nodes (single-owner); it hands out `mut`
# refs by index for the engine to drive.
#
# ── ENCAPSULATION ─────────────────────────────────────────────────────────
# The public surface is value-typed: `add(var ErasedResource)` moves a node in;
# `topo_sort()` returns `List[Int]` (node indices); `index_of(logical_id)` returns
# `Int` (-1 if absent); `node(idx)` returns a `mut` ref for the engine to drive.
# ZERO UnsafePointer crosses the boundary; the Slab's byte arithmetic is confined
# INSIDE the Slab primitive (concrete origin, no wildcard cast at the storage
# boundary — the blessed `Slab[ErasedHandle]` shape). No stale-pointer hazard
# across destroy and recreate: the node is the concrete `ErasedResource` whose
# only pointer field is a concrete-origin OwnedPointer home. Mojo 1.0.0b2 (def-only).
# =============================================================================

from komira_core.collections.slab import Slab

from kci_reconciler.erased_resource import ErasedResource


# =============================================================================
# §1 — ResourceGraph — the owned DAG of erased resource nodes.
# =============================================================================
struct ResourceGraph(Movable, Deinitable):
    """The deploy graph: N `ErasedResource` nodes stored in a `Slab[ErasedResource]`
    (single-owner). The edges are implicit in each node's `depends_on()`. Build the
    graph with `add(node^)`; the engine reads the topo order via `topo_sort()`,
    looks up a node by key via `index_of(logical_id)`, and drives a node via
    `node(idx)` (a `mut` ref into the slab).

    The graph owns its nodes; it hands out `mut` refs by index (the engine borrows
    them to drive the reconcile verbs). No stale-pointer hazard across destroy and
    recreate: the Slab element is the
    concrete `ErasedResource` (no wildcard cast at the storage boundary — the
    blessed `Slab[ErasedHandle]` shape)."""

    var _nodes: Slab[ErasedResource]

    def __init__(out self):
        self._nodes = Slab[ErasedResource]()

    def add(mut self, var node: ErasedResource) raises:
        """Add an erased resource node to the graph (moved in — single-owner). The
        node's `logical_id` becomes its graph-stable key. A duplicate logical_id is
        a fail-loud error (two nodes cannot share a key — the topo-sort + intent-
        adopt key must be unique)."""
        var lid = node.logical_id()
        if self._index_of(lid) >= 0:
            raise Error(
                String("ResourceGraph.add: duplicate logical_id '")
                + lid
                + String("' — every graph node must have a unique key")
            )
        self._nodes.append(node^)

    def num_nodes(self) -> Int:
        """The number of nodes in the graph. (A plain method, NOT `__len__` — a
        `def __len__` carries implicit `raises`, so `len(graph)` would need the
        SizedRaising trait; a named accessor keeps the callers non-raising and
        explicit)."""
        return len(self._nodes)

    def node(
        ref self, idx: Int
    ) -> ref [origin_of(self._nodes[idx])] ErasedResource:
        """A `mut` ref to node `idx` (the engine borrows it to drive the reconcile
        verbs). The ref borrows through the owning Slab (tight origin — the
        `origin_of(self._nodes[idx])` chain elaborates to `self._nodes._bytes`, the
        origin `Slab.__getitem__` returns; the `worker_at` precedent in
        komira_async.runtime.runtime). No pointer crosses the boundary. PANICS on
        an out-of-bounds idx."""
        return self._nodes[idx]

    def _index_of(mut self, logical_id: String) raises -> Int:
        """The slab index of the node whose `logical_id` == `logical_id`, or -1 if
        no such node. Internal (mut self — reading a node's logical_id borrows the
        slab mutably per the Slab __getitem__ shape)."""
        for i in range(len(self._nodes)):
            if self._nodes[i].logical_id() == logical_id:
                return i
        return -1

    def index_of(mut self, logical_id: String) raises -> Int:
        """The slab index of the node keyed by `logical_id`, or -1 if absent. The
        engine uses this to resolve a `depends_on` edge to a node index."""
        return self._index_of(logical_id)


# =============================================================================
# §2 — topo_sort — Kahn's algorithm over the graph's depends_on edges.
# =============================================================================
def topo_sort(mut graph: ResourceGraph) raises -> List[Int]:
    """Return the node INDICES of `graph` in a dependency-correct order (a node
    appears AFTER every node it depends on), via Kahn's algorithm:

      1. Build the adjacency (dep_idx -> dependent_idx) from each node's
         `depends_on()` AND the producers of its `input_refs()`, resolving each
         logical_id to its node index. A dependency or a reference naming a
         logical_id NOT in the graph is a fail-loud error.
      2. Compute in-degrees (how many deps each node has).
      3. Seed a queue with the in-degree-0 nodes (the roots), in INDEX order (so
         the order is deterministic — a stable topo order for a given graph).
      4. Pop a node, emit it, decrement its dependents' in-degrees; enqueue any
         that hit 0 (again pushed in index order via a re-scan for determinism).
      5. If fewer than N nodes were emitted, the remaining nodes form a CYCLE — a
         fail-loud error (the engine cannot order a cyclic graph).

    Returns the emitted index order (length == graph.num_nodes() on success).
    RAISES on a dangling dependency OR a cycle."""
    var n = graph.num_nodes()
    if n == 0:
        return List[Int]()

    # ---- step 1+2: build in-degrees + the dependents adjacency ----
    # `in_degree[i]` = number of deps node i has (that resolve to a graph node).
    # `dependents[i]` = the indices that depend ON node i (i is their dep) —
    # stored as a flat parallel structure (a List[List[Int]]).
    var in_degree = List[Int]()
    var dependents = List[List[Int]]()
    for _i in range(n):
        in_degree.append(0)
        dependents.append(List[Int]())

    for i in range(n):
        var deps = graph.node(i).depends_on()
        for j in range(len(deps)):
            var dep_idx = graph.index_of(deps[j])
            if dep_idx < 0:
                raise Error(
                    String("topo_sort: node '")
                    + graph.node(i).logical_id()
                    + String("' depends on '")
                    + deps[j]
                    + String("' which is not a node in the graph (dangling")
                    + String(" dependency)")
                )
            if dep_idx == i:
                raise Error(
                    String("topo_sort: node '")
                    + graph.node(i).logical_id()
                    + String("' depends on itself (a self-cycle)")
                )
            # node i depends on dep_idx: i's in-degree +1; i is a dependent of dep_idx.
            in_degree[i] += 1
            dependents[dep_idx].append(i)
        # A REFERENCE IS AN EDGE TOO. Each `input_refs` producer is ordered
        # before the consumer, so an author never keeps a dependency list and a
        # reference list in step. A ref to a producer already named in
        # `depends_on` adds nothing; a ref to a node that is not in the graph is
        # refused naming the field, because the value it would carry does not
        # exist anywhere.
        var refs = graph.node(i).input_refs()
        for r in range(len(refs)):
            ref ir = refs[r]
            var prod_idx = graph.index_of(ir.producer)
            if prod_idx < 0:
                raise Error(
                    String("topo_sort: node '")
                    + graph.node(i).logical_id()
                    + String("' field ")
                    + ir.field
                    + String(" reads output '")
                    + ir.output
                    + String("' of '")
                    + ir.producer
                    + String("', which is not a node in the graph (ref to a")
                    + String(" missing resource)")
                )
            if prod_idx == i:
                raise Error(
                    String("topo_sort: node '")
                    + graph.node(i).logical_id()
                    + String("' field ")
                    + ir.field
                    + String(" reads its own output '")
                    + ir.output
                    + String("' (a self-cycle through a reference)")
                )
            var already = False
            for k in range(len(dependents[prod_idx])):
                if dependents[prod_idx][k] == i:
                    already = True
                    break
            if already:
                continue
            in_degree[i] += 1
            dependents[prod_idx].append(i)

    # ---- step 3+4: Kahn's queue (index-ordered for determinism) ----
    # `emitted[i]` marks a node already emitted; we re-scan for the lowest-index
    # in-degree-0 not-yet-emitted node each round (a deterministic stable order,
    # O(n^2) — fine for a deploy graph of tens of nodes).
    var order = List[Int]()
    var emitted = List[Bool]()
    for _i in range(n):
        emitted.append(False)

    while len(order) < n:
        # find the lowest-index node with in-degree 0 not yet emitted.
        var pick = -1
        for i in range(n):
            if (not emitted[i]) and in_degree[i] == 0:
                pick = i
                break
        if pick < 0:
            # no in-degree-0 node remains but nodes are unemitted -> a CYCLE.
            var cycle_ids = String("")
            var first = True
            for i in range(n):
                if not emitted[i]:
                    if not first:
                        cycle_ids += String(", ")
                    cycle_ids += String("'") + graph.node(i).logical_id() + (
                        String("'")
                    )
                    first = False
            raise Error(
                String("topo_sort: the graph has a CYCLE among nodes [")
                + cycle_ids
                + String("] — the engine cannot order a cyclic graph")
            )
        # emit `pick`; decrement its dependents' in-degrees.
        emitted[pick] = True
        order.append(pick)
        ref deps_of_pick = dependents[pick]
        for k in range(len(deps_of_pick)):
            var d = deps_of_pick[k]
            in_degree[d] -= 1

    return order^


# =============================================================================
# §2b — dag_topo_order — the PURE, index-keyed Kahn primitive (the reusable core
#       of §2's topo_sort, over a resolved adjacency instead of a ResourceGraph).
#       A caller that already holds a DAG as "each node's DEPENDENCY indices"
#       (e.g. the validate-step scheduler, `run_validation_dag`) reuses THIS for
#       cycle detection + a deterministic dependency-correct order, without
#       wrapping its nodes as ErasedResources.
# =============================================================================
def dag_topo_order(deps_by_index: List[List[Int]]) raises -> List[Int]:
    """Kahn topo-sort over a DAG given as each node's DEPENDENCY indices
    (`deps_by_index[i]` = the indices node i depends on; every entry MUST be a
    valid `0 <= d < n` — the caller resolves names + detects DANGLING refs BEFORE
    calling this). Returns a dependency-correct index order (a node appears AFTER
    every node it depends on), deterministic (lowest-index-first). RAISES on a
    CYCLE (including a self-dependency, whose in-degree never reaches 0).

    This is the same Kahn algorithm `topo_sort` runs, factored to a pure
    index-adjacency signature so a name-keyed DAG (the validation step-DAG) reuses
    the primitive. O(n^2) — fine for a deploy graph / a wave's validate steps
    (tens of nodes)."""
    var n = len(deps_by_index)
    if n == 0:
        return List[Int]()

    # in_degree[i] = number of deps node i has; dependents[d] = the nodes that
    # depend ON d (so emitting d decrements their in-degree).
    var in_degree = List[Int]()
    var dependents = List[List[Int]]()
    for _i in range(n):
        in_degree.append(0)
        dependents.append(List[Int]())
    for i in range(n):
        ref di = deps_by_index[i]
        for k in range(len(di)):
            var d = di[k]
            in_degree[i] += 1
            dependents[d].append(i)

    var order = List[Int]()
    var emitted = List[Bool]()
    for _i in range(n):
        emitted.append(False)

    while len(order) < n:
        var pick = -1
        for i in range(n):
            if (not emitted[i]) and in_degree[i] == 0:
                pick = i
                break
        if pick < 0:
            # no in-degree-0 node remains but nodes are unemitted -> a CYCLE.
            var cyc = String("")
            var first = True
            for i in range(n):
                if not emitted[i]:
                    if not first:
                        cyc += String(", ")
                    cyc += String(i)
                    first = False
            raise Error(
                String("dag_topo_order: the DAG has a CYCLE among node indices [")
                + cyc
                + String("] — it cannot be topologically ordered")
            )
        emitted[pick] = True
        order.append(pick)
        ref deps_of_pick = dependents[pick]
        for k in range(len(deps_of_pick)):
            in_degree[deps_of_pick[k]] -= 1

    return order^


# =============================================================================
# §3 — reverse — the reverse of a topo order (destroy / rollback teardown order).
# =============================================================================
def reverse_order(order: List[Int]) -> List[Int]:
    """The reverse of a topo order (a dependent is torn down BEFORE the node it
    depends on — the destroy / rollback order). A small helper the engine's
    destroy_graph / rollback_create use."""
    var out = List[Int]()
    var i = len(order) - 1
    while i >= 0:
        out.append(order[i])
        i -= 1
    return out^
