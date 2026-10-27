# =============================================================================
# query_build -- answer a query from a merged working set.
# =============================================================================
#
# `build_query_result` reads the subgraph around what a query matches. It is a
# pure function of the working set, the embedder and the request, so the server
# gives the same answer from the warm merged set and from a set freshly loaded
# at the same head.
#
# SEEDS. An entity is a seed when it is in scope and either
#   * SEMANTIC: the embedded query and its name embedding have a cosine of at
#     least `similarity_floor`; or
#   * SURFACE: its name contains the query text, ASCII case folded.
# An entity is in scope when its partition is one the request names and, if the
# request names a facet, its facet (`facet_from_attrs`) equals it byte for byte.
# Semantic seeds come first, strongest first, equal scores by ascending node id;
# surface-only seeds follow in working-set order. Every semantic seed's score is
# in the result's `scores` as "semantic", whatever `k` cuts.
#
# A FEDERATED query keeps at most `per_partition_cap` semantic seeds and
# `per_partition_cap` surface seeds of each partition, then ranks the union
# together; the order of the partitions in the request changes nothing.
#
# NODES. The seeds, then their one-hop neighbours (in seed order, then edge
# order), up to `k`. A seed has score 1.0 and a neighbour 0.5. A neighbour must
# pass the facet filter; it must also be in a named partition for a single
# query, while a federated query admits a neighbour of any partition (the graph
# connects them). A federated node carries a provenance entry
# {source_id: "<node id>", source: "partition:<id>"}.
#
# EDGES. Every edge between two emitted nodes, its `fact` as the result edge's
# `predicate` (the stored edge keeps no separate predicate column, so the fact is
# the one relation text a warm set and a loaded one share; an edge with no fact
# has an empty one). With `as_of`, only edges whose [valid_at, invalid_at) holds
# it, and an edge not live then brings in no neighbour.
#
# A failed or ill-sized embedding drops the semantic half: the text match still
# answers.
# =============================================================================

from std.math import isfinite

from komira_kg import Embedder, SnapshotWorkingSet, WorkingEdge, facet_from_attrs
from komira_kg_format import (
    KgQueryResult,
    ProvenanceEntry,
    ResultEdge,
    ResultNode,
    ScoreEntry,
    cosine,
)

from .query_config import QueryConfig
from .query_spec import QuerySpec

comptime _NODE_TYPE: String = "entity"


def _lower(c: UInt8) -> UInt8:
    if c >= 0x41 and c <= 0x5A:
        return c + 32
    return c


def _contains_ci(hay: Span[UInt8, _], needle: List[UInt8]) -> Bool:
    if len(needle) == 0 or len(needle) > len(hay):
        return False
    for i in range(len(hay) - len(needle) + 1):
        var same = True
        for j in range(len(needle)):
            if _lower(hay[i + j]) != needle[j]:
                same = False
                break
        if same:
            return True
    return False


def _before(scores: List[Float64], nids: List[Int64], a: Int, b: Int) -> Bool:
    """Whether item `a` ranks ahead of item `b`: higher score, then lower id."""
    if scores[a] != scores[b]:
        return scores[a] > scores[b]
    return nids[a] < nids[b]


def _ranked(scores: List[Float64], nids: List[Int64]) -> List[Int]:
    """The positions `0..len(scores)` ordered best first (a stable bottom-up
    merge sort, O(n log n))."""
    var n = len(scores)
    var cur = List[Int](capacity=n)
    for i in range(n):
        cur.append(i)
    var width = 1
    while width < n:
        var nxt = List[Int](capacity=n)
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var a = lo
            var b = mid
            while a < mid and b < hi:
                if _before(scores, nids, cur[b], cur[a]):
                    nxt.append(cur[b])
                    b += 1
                else:
                    nxt.append(cur[a])
                    a += 1
            while a < mid:
                nxt.append(cur[a])
                a += 1
            while b < hi:
                nxt.append(cur[b])
                b += 1
            lo = hi
        cur = nxt^
        width *= 2
    return cur^


def _position_of(names: List[String], name: String) -> Int:
    for i in range(len(names)):
        if names[i] == name:
            return i
    return -1


def _edge_live(edge: WorkingEdge, as_of: Optional[Int64]) -> Bool:
    if not as_of:
        return True
    var t = as_of.value()
    return edge.valid_at <= t and t < edge.invalid_at


def _slot_for(
    mut slot_of: Dict[Int64, Int], mut lists: List[List[Int]], nid: Int64
) -> Int:
    var slot = slot_of.get(nid, -1)
    if slot < 0:
        slot = len(lists)
        lists.append(List[Int]())
        slot_of[nid] = slot
    return slot


def _finite(v: List[Float64]) -> Bool:
    for i in range(len(v)):
        if not isfinite(v[i]):
            return False
    return True


def build_query_result[
    Emb: Embedder
](
    emb: Emb,
    ws: SnapshotWorkingSet,
    spec: QuerySpec,
    config: QueryConfig,
) -> KgQueryResult:
    """The subgraph a query matches in `ws` (see the file header).

    Parameters:
        Emb: The embedder.

    Args:
        emb: The embedder; it embeds the query text once.
        ws: The merged working set.
        spec: The request.
        config: The query limits.

    Returns:
        The result, with no `answer`. Never raises: an embedder failure is
        answered from the text match alone.
    """
    var n_ent = ws.num_entities()
    var out: KgQueryResult
    if spec.federated:
        out = KgQueryResult(
            String("federated_query"),
            String("federated query (")
            + String(len(spec.partitions))
            + " partitions): "
            + spec.text,
        )
    else:
        out = KgQueryResult(String("query"), String("query: ") + spec.text)

    # Scope: which entities a request may seed from.
    var part_of = List[Int](capacity=n_ent)  # position in spec.partitions, or -1
    for i in range(n_ent):
        part_of.append(_position_of(spec.partitions, ws.entities[i].partition_id))
    var facet_ok = List[Bool](capacity=n_ent)
    var has_facet = len(spec.facet.as_bytes()) > 0
    for i in range(n_ent):
        if has_facet:
            facet_ok.append(facet_from_attrs(ws.entities[i].attrs) == spec.facet)
        else:
            facet_ok.append(True)

    var cap = n_ent + 1
    if spec.federated:
        cap = config.per_partition_cap

    # Semantic seeds.
    var sem_idx = List[Int]()
    var sem_score = List[Float64]()
    var sem_nid = List[Int64]()
    var query_vec = List[Float64]()
    try:
        query_vec = emb.embed(spec.text)
    except:
        query_vec = List[Float64]()
    if len(query_vec) == ws.embedding_dim and _finite(query_vec):
        for i in range(n_ent):
            if part_of[i] < 0 or not facet_ok[i]:
                continue
            if len(ws.entities[i].name_embedding) != len(query_vec):
                continue
            var s = cosine(query_vec, ws.entities[i].name_embedding)
            if s >= config.similarity_floor:
                sem_idx.append(i)
                sem_score.append(s)
                sem_nid.append(ws.entities[i].nid)
    var order = _ranked(sem_score, sem_nid)
    var taken = List[Int](length=len(spec.partitions), fill=0)
    var matched = List[Int]()  # entity indices, seeds in order
    var is_seed = List[Bool](length=n_ent, fill=False)
    for r in range(len(order)):
        var at = order[r]
        var ent = sem_idx[at]
        if taken[part_of[ent]] >= cap:
            continue
        taken[part_of[ent]] += 1
        matched.append(ent)
        is_seed[ent] = True
        out.add_score(
            ScoreEntry(String("semantic"), ws.entities[ent].nid, sem_score[at])
        )

    # Surface seeds.
    var needle = List[UInt8]()
    var text_bytes = spec.text.as_bytes()
    for b in range(len(text_bytes)):
        needle.append(_lower(text_bytes[b]))
    var surface_taken = List[Int](length=len(spec.partitions), fill=0)
    for i in range(n_ent):
        if part_of[i] < 0 or not facet_ok[i] or is_seed[i]:
            continue
        if surface_taken[part_of[i]] >= cap:
            continue
        if _contains_ci(ws.entities[i].name.as_bytes(), needle):
            surface_taken[part_of[i]] += 1
            matched.append(i)
            is_seed[i] = True

    # Nodes: the seeds, then neighbours.
    var emitted = List[Int]()
    var emitted_nid = Dict[Int64, Int]()
    for m in range(len(matched)):
        if len(emitted) >= spec.k:
            break
        emitted_nid[ws.entities[matched[m]].nid] = matched[m]
        emitted.append(matched[m])

    if len(emitted) < spec.k and len(matched) > 0:
        var at_nid = Dict[Int64, Int]()
        for i in range(n_ent):
            at_nid[ws.entities[i].nid] = i
        # For each node id that a live edge touches, the entity indices of its
        # neighbours in edge order. `slot_of` maps a node id to its list.
        var slot_of = Dict[Int64, Int]()
        var near_of = List[List[Int]]()
        for e in range(ws.num_edges()):
            ref edge = ws.edges[e]
            if not _edge_live(edge, spec.as_of):
                continue
            var a = at_nid.get(edge.src_nid, -1)
            var b = at_nid.get(edge.dst_nid, -1)
            if a < 0 or b < 0:
                continue
            var sa = _slot_for(slot_of, near_of, edge.src_nid)
            near_of[sa].append(b)
            var sb = _slot_for(slot_of, near_of, edge.dst_nid)
            near_of[sb].append(a)
        for m in range(len(matched)):
            var slot = slot_of.get(ws.entities[matched[m]].nid, -1)
            if slot < 0:
                continue
            for j in range(len(near_of[slot])):
                if len(emitted) >= spec.k:
                    break
                var cand = near_of[slot][j]
                var cand_nid = ws.entities[cand].nid
                if cand_nid in emitted_nid:
                    continue
                if not facet_ok[cand]:
                    continue
                if part_of[cand] < 0:
                    continue
                emitted_nid[cand_nid] = cand
                emitted.append(cand)
            if len(emitted) >= spec.k:
                break

    for j in range(len(emitted)):
        var i = emitted[j]
        var score = 1.0 if is_seed[i] else 0.5
        out.add_node(
            ResultNode(ws.entities[i].nid, ws.entities[i].name.copy(), String(_NODE_TYPE), score)
        )
        out.add_score(ScoreEntry(String("name_match"), ws.entities[i].nid, score))
        if spec.federated:
            out.add_provenance(
                ProvenanceEntry(
                    String(ws.entities[i].nid),
                    String("partition:") + ws.entities[i].partition_id,
                )
            )

    # Edges between emitted nodes.
    for e in range(ws.num_edges()):
        ref edge = ws.edges[e]
        if edge.src_nid in emitted_nid and edge.dst_nid in emitted_nid:
            if not _edge_live(edge, spec.as_of):
                continue
            out.add_edge(
                ResultEdge(
                    edge.src_nid, edge.dst_nid, edge.fact.copy(), edge.valid_at, String("")
                )
            )
    return out^
