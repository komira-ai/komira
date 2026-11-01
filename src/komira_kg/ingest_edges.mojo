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
#
# A structured caller states its facts, end times included. `apply_edges_recording`
# can honour a triple's `invalid_at` (an ended fact is stored ended, and is judged
# for contradiction over its own interval, not an open one) and reports the
# identity of every triple it was given, repeats included, so a source that
# replaces its facts can tell which of its earlier edges it no longer states
# (ingest_source_diff). `apply_edges`, the episode path, ignores `invalid_at`: an
# extractor's end time is a guess, and an edge from it is always open.
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


@fieldwise_init
struct AssertedEdge(Copyable, Movable):
    """The identity of one triple as applied: the resolved endpoints, the fact
    and its interval.

    Fields:
        src_nid: The resolved source node id.
        dst_nid: The resolved destination node id.
        fact: The fact as a sentence.
        valid_at: The event-time start, the episode's for an undated triple.
        invalid_at: The event-time end; `TS_OPEN_SENTINEL` while open.
    """

    var src_nid: Int64
    var dst_nid: Int64
    var fact: String
    var valid_at: Int64
    var invalid_at: Int64

    def matches(self, e: WorkingEdge) -> Bool:
        """True iff the stored edge `e` is this assertion and still believed:
        the same endpoints and fact, not expired, the same end, and, for an
        ended fact, the same start (an open fact is the same fact whenever it
        started)."""
        return (
            e.src_nid == self.src_nid
            and e.dst_nid == self.dst_nid
            and e.fact == self.fact
            and e.expired_at == TS_OPEN_SENTINEL
            and e.invalid_at == self.invalid_at
            and (
                self.invalid_at == TS_OPEN_SENTINEL
                or e.valid_at == self.valid_at
            )
        )


def _is_live_repeat(
    ws: SnapshotWorkingSet, asserted: AssertedEdge, source: String
) -> Bool:
    for i in range(len(ws.edges)):
        ref e = ws.edges[i]
        if e.source == source and asserted.matches(e):
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
    always open (`apply_edges_recording` can honour it). All edges of one call
    share `created_at == now`.

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
    var asserted = List[AssertedEdge]()
    apply_edges_recording(
        ws,
        triples,
        mention_names,
        mention_nids,
        llm,
        emb,
        partition_id,
        now,
        episode_valid_at,
        aliases,
        cfg,
        asserted,
        False,
        source,
        facet,
        facet_source,
    )


def apply_edges_recording[
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
    mut asserted: List[AssertedEdge],
    honour_invalid_at: Bool,
    source: String = String(""),
    facet: String = String(""),
    facet_source: String = String(""),
) raises:
    """`apply_edges`, reporting what each triple asserted and optionally
    honouring its end time.

    Every triple appends one `AssertedEdge` to `asserted`, in order, whether it
    added an edge or repeated a live one. With `honour_invalid_at` a triple whose
    `invalid_at` is not `TS_OPEN_SENTINEL` is stored ended at that time (its
    `expired_at` stays open: the graph believes it as history), is a repeat only
    of an edge with the same end and start, and is judged for contradiction over
    `[valid_at, invalid_at)` alone. Without it every edge is open.

    Parameters:
        Llm: The model client (inferred); only `judge_contradiction` is called.
        Emb: The embedder (inferred).

    Args:
        ws: The working set; edges are appended and closed in place.
        triples: The triples to apply.
        mention_names: The mention names, parallel to `mention_nids`.
        mention_nids: The resolved node id per mention name.
        llm: The model client.
        emb: The embedder.
        partition_id: The partition of any entity minted for an endpoint.
        now: The system time of this write.
        episode_valid_at: The episode's event time.
        aliases: Each endpoint's id is resolved through it.
        cfg: Whether a contradiction candidate must share the predicate.
        asserted: Appended to, one entry per triple.
        honour_invalid_at: Whether a triple's own end time is stored.
        source: The asserting source's id, "" for unattributed.
        facet: The facet stamped on any entity minted for an endpoint.
        facet_source: The source the facet is attributed to.

    Raises:
        If the embedder or the model raises, an embedding is not the graph's
        dimension, or, with `honour_invalid_at`, a triple ends at or before its
        start. Edges applied before the failure stay in `ws`; the caller
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
        var invalid_at = TS_OPEN_SENTINEL
        if honour_invalid_at:
            invalid_at = t.invalid_at
        if invalid_at != TS_OPEN_SENTINEL and invalid_at <= valid_at:
            raise Error(
                "apply_edges: the fact '"
                + t.fact
                + "' ends at "
                + String(invalid_at)
                + ", not after its start "
                + String(valid_at)
            )
        var identity = AssertedEdge(
            src_nid, dst_nid, String(t.fact), valid_at, invalid_at
        )
        asserted.append(identity.copy())
        if _is_live_repeat(ws, identity, source):
            continue

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
        new_edge.invalid_at = invalid_at

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
