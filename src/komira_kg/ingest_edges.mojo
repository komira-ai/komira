# =============================================================================
# ingest_edges -- apply extracted triples to the working set as bi-temporal
#   edges.
# =============================================================================
#
# For each triple the endpoints are resolved to node ids (an extracted mention
# first, then an existing entity of the same name, then a new entity, so an edge
# never dangles) and through the alias map. A new open edge is built; if the
# working set already holds a live edge with the same endpoints, fact and source,
# the triple is a repeat and adds nothing. (The predicate is not part of that
# identity: the `edges` table has no predicate column, so a stored edge reads back
# with "" and the relation rides in the fact.) Otherwise each existing
# edge between the pair whose interval overlaps (`overlapping_contradiction_
# candidates`) is put to the `LlmClient`'s `judge_contradiction`; a confirmed
# one is closed (`apply_invalidation`: stamped, never deleted) and the new edge is
# appended.
# =============================================================================

from komira_kg_format import EntityMention, Triple, TS_OPEN_SENTINEL

from .alias_map import AliasMap
from .bitemporal import (
    WorkingEdge,
    apply_invalidation,
    open_edge,
    overlapping_contradiction_candidates,
)
from .embedder import Embedder
from .ingest_config import IngestConfig
from .ingest_resolve import existing_nid_for_name, mint_entity
from .llm_client import LlmClient
from .working_set import SnapshotWorkingSet


def _resolve_endpoint[
    Emb: Embedder
](
    mut ws: SnapshotWorkingSet,
    name: String,
    mention_names: List[String],
    mention_nids: List[Int64],
    ref emb: Emb,
    partition_id: String,
    facet: String,
    facet_source: String,
) raises -> Int64:
    for i in range(len(mention_names)):
        if mention_names[i] == name:
            return mention_nids[i]
    var existing = existing_nid_for_name(ws, name, partition_id)
    if existing >= Int64(0):
        return existing
    var vec = emb.embed(name)
    var synthetic = EntityMention(String(name), String(""), String(""))
    return mint_entity(ws, synthetic, vec^, partition_id, facet, facet_source)


def _edge_indices_between(
    ws: SnapshotWorkingSet, src_nid: Int64, dst_nid: Int64
) -> List[Int]:
    var idxs = List[Int]()
    for i in range(len(ws.edges)):
        ref e = ws.edges[i]
        if e.src_nid == src_nid and e.dst_nid == dst_nid:
            idxs.append(i)
    return idxs^


def _is_live_repeat(ws: SnapshotWorkingSet, edge: WorkingEdge) -> Bool:
    for i in range(len(ws.edges)):
        ref e = ws.edges[i]
        if (
            e.src_nid == edge.src_nid
            and e.dst_nid == edge.dst_nid
            and e.invalid_at == TS_OPEN_SENTINEL
            and e.expired_at == TS_OPEN_SENTINEL
            and e.fact == edge.fact
            and e.source == edge.source
        ):
            return True
    return False


def apply_edges[
    Llm: LlmClient, Emb: Embedder
](
    mut ws: SnapshotWorkingSet,
    triples: List[Triple],
    mention_names: List[String],
    mention_nids: List[Int64],
    ref llm: Llm,
    ref emb: Emb,
    partition_id: String,
    now: Int64,
    episode_valid_at: Int64,
    mut aliases: AliasMap,
    cfg: IngestConfig,
    source: String = String(""),
    facet: String = String(""),
    facet_source: String = String(""),
) raises:
    """Apply each triple to `ws` as a new open edge, closing the edges it
    contradicts.

    A triple whose `valid_at` is `TS_OPEN_SENTINEL` is undated and takes
    `episode_valid_at`. The triple's `invalid_at` is not read: a new edge is
    always open. All edges of one call share `created_at == now`.

    Parameters:
        Llm: The model client (inferred); only `judge_contradiction` is called.
        Emb: The embedder (inferred); called only for an endpoint no mention or
            existing entity names.

    Args:
        ws: The working set; edges are appended and closed in place.
        triples: The extracted triples.
        mention_names: The extracted mention names, parallel to `mention_nids`.
        mention_nids: The resolved node id per mention name.
        llm: The model client.
        emb: The embedder.
        partition_id: The partition of any entity minted for an endpoint.
        now: The system time, stamped as `created_at` and as the expiry of an
            edge this call closes.
        episode_valid_at: The episode's event time, stamped as the reference
            time and as the `valid_at` of an undated triple.
        aliases: Each endpoint's id is resolved through it, so no edge points at
            an id that was merged away.
        cfg: Whether a contradiction candidate must share the predicate.
        source: The asserting source's id, "" for unattributed.
        facet: The facet stamped on any entity minted for an endpoint.
        facet_source: The source the facet is attributed to.

    Raises:
        If the embedder or the model raises, or an embedding is not the graph's
        dimension. Edges applied before the failure stay in `ws`; the caller
        discards the set.
    """
    for ti in range(len(triples)):
        ref t = triples[ti]
        var src_nid = _resolve_endpoint(
            ws, t.subject_name, mention_names, mention_nids, emb,
            partition_id, facet, facet_source,
        )
        var dst_nid = _resolve_endpoint(
            ws, t.object_name, mention_names, mention_nids, emb,
            partition_id, facet, facet_source,
        )
        src_nid = aliases.resolve(src_nid)
        dst_nid = aliases.resolve(dst_nid)

        var valid_at = t.valid_at
        if valid_at == TS_OPEN_SENTINEL:
            valid_at = episode_valid_at
        var new_edge = open_edge(
            src_nid,
            dst_nid,
            String(t.predicate),
            String(t.fact),
            valid_at,
            now,
            episode_valid_at,
            String(source),
        )
        if _is_live_repeat(ws, new_edge):
            continue

        var cand_idxs = _edge_indices_between(ws, src_nid, dst_nid)
        var cand_edges = List[WorkingEdge](capacity=len(cand_idxs))
        for k in range(len(cand_idxs)):
            cand_edges.append(ws.edges[cand_idxs[k]].copy())
        var candidates = overlapping_contradiction_candidates(
            new_edge, cand_edges, cfg.match_predicate
        )
        for ci in range(len(candidates)):
            var ws_idx = cand_idxs[candidates[ci]]
            if llm.judge_contradiction(
                String(new_edge.fact), String(ws.edges[ws_idx].fact)
            ):
                apply_invalidation(ws.edges[ws_idx], new_edge, now)
        ws.add_edge(new_edge^)
