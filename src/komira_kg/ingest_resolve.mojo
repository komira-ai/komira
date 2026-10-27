# =============================================================================
# ingest_resolve -- resolve extracted mentions to entities of the working set.
# =============================================================================
#
# For each mention the resolver embeds its name, takes the `cosine_k` existing
# entities nearest by name embedding as candidates, and runs the dedup cascade
# (`dedup_resolve`) over them: an exact or fuzzy match resolves to the existing
# node id, a borderline one is put to the `LlmClient`'s `judge_same_entity`, and
# anything else mints a new entity that carries its name embedding, so the next
# ingest can match against it.
#
# PARTITIONS. When the episode's partition id is not empty, only entities of that
# partition are candidates, and a name lookup (`existing_nid_for_name`) sees only
# that partition's entities: two partitions that both hold an entity called "X"
# hold two entities. An empty partition id matches across partitions.
# =============================================================================

from komira_kg_format import EntityMention, cosine

from .dedup import DedupCandidate, dedup_resolve
from .embedder import Embedder
from .ingest_config import IngestConfig
from .llm_client import LlmClient
from .name_similarity import normalize_name
from .source_facet import facet_attrs_json
from .working_codec import check_embedding
from .working_rows import WorkingEntity
from .working_set import SnapshotWorkingSet


def _tier0_candidates(
    ws: SnapshotWorkingSet,
    query_vec: List[Float64],
    k: Int,
    partition_id: String,
) -> List[DedupCandidate]:
    """The `k` entities nearest `query_vec` by cosine, best first, ties to the
    lower position. Entities of another partition are never candidates when
    `partition_id` is not empty."""
    var n = len(ws.entities)
    var scoped = len(partition_id.as_bytes()) > 0
    var scores = List[Float64](capacity=n)
    for i in range(n):
        if scoped and ws.entities[i].partition_id != partition_id:
            scores.append(-2.0)  # below any cosine in [-1, 1]: never taken
        else:
            scores.append(cosine(query_vec, ws.entities[i].name_embedding))
    var taken = List[Bool](capacity=n)
    for _ in range(n):
        taken.append(False)
    var out = List[DedupCandidate]()
    for _ in range(min(k, n)):
        var best = -1
        var best_score = -2.0
        for i in range(n):
            if taken[i]:
                continue
            if scores[i] > best_score:
                best_score = scores[i]
                best = i
        if best < 0:
            break
        taken[best] = True
        ref e = ws.entities[best]
        out.append(DedupCandidate(e.nid, String(e.name), String(e.summary)))
    return out^


def existing_nid_for_name(
    ws: SnapshotWorkingSet, name: String, partition_id: String
) -> Int64:
    """The node id of the first entity whose normalized name equals `name`'s,
    without calling the embedder; -1 if there is none. Entities of another
    partition are skipped when `partition_id` is not empty.

    Args:
        ws: The working set.
        name: The surface name to look up.
        partition_id: The partition to look in, or "" for all.

    Returns:
        The node id, or -1.
    """
    var target = normalize_name(name)
    var scoped = len(partition_id.as_bytes()) > 0
    for i in range(len(ws.entities)):
        if scoped and ws.entities[i].partition_id != partition_id:
            continue
        if normalize_name(ws.entities[i].name) == target:
            return ws.entities[i].nid
    return Int64(-1)


def mint_entity(
    mut ws: SnapshotWorkingSet,
    mention: EntityMention,
    var name_embedding: List[Float64],
    partition_id: String,
    facet: String,
    facet_source: String,
) raises -> Int64:
    """Add a new entity for `mention` and return its fresh node id.

    The entity's uuid is `"<partition_id>:<nid>"`, its `attrs` carry the facet
    (`facet_attrs_json`), and its embedding is held to the graph's dimension.

    Raises:
        If the embedding is not the graph's dimension of finite components, or
        the node ids are exhausted.
    """
    var nid = ws.next_nid()
    var uuid = partition_id + ":" + String(nid)
    ws.add_entity(
        WorkingEntity(
            nid,
            uuid^,
            String(partition_id),
            String(mention.name),
            name_embedding^,
            String(mention.summary),
            facet_attrs_json(facet, facet_source),
        )
    )
    return nid


def resolve_entities[
    Llm: LlmClient, Emb: Embedder
](
    mut ws: SnapshotWorkingSet,
    mentions: List[EntityMention],
    ref llm: Llm,
    ref emb: Emb,
    partition_id: String,
    cfg: IngestConfig,
    facet: String = String(""),
    facet_source: String = String(""),
) raises -> List[Int64]:
    """Resolve each mention to a node id, minting entities for the new ones.

    A mention resolved to an existing entity adds no row. A mention judged to be
    the same entity resolves to the candidate's id. No alias is recorded: the
    mention has no node id of its own to alias, it simply resolves to the
    candidate's. (`apply_edges` takes an `AliasMap` for a host that has merged
    two ids itself.)

    Parameters:
        Llm: The model client (inferred); only `judge_same_entity` is called.
        Emb: The embedder (inferred).

    Args:
        ws: The working set; new entities are appended.
        mentions: The extracted mentions, in extraction order.
        llm: The model client.
        emb: The embedder; its vectors must be the graph's dimension.
        partition_id: The episode's partition, stamped on new entities and used
            to scope the candidates.
        cfg: The candidate count and the cascade's thresholds.
        facet: The facet stamped on new entities' `attrs`.
        facet_source: The source the facet is attributed to.

    Returns:
        The resolved node id per mention, in mention order.

    Raises:
        If the embedder or the model raises, or an embedding is not the graph's
        dimension of finite components. Entities minted before the failure stay
        in `ws`; the caller discards the set.
    """
    var resolved = List[Int64](capacity=len(mentions))
    for mi in range(len(mentions)):
        ref m = mentions[mi]
        var query_vec = emb.embed(m.name)
        check_embedding(query_vec, ws.embedding_dim, "resolve_entities")
        var candidates = _tier0_candidates(
            ws, query_vec, cfg.cosine_k, partition_id
        )
        var decision = dedup_resolve(
            m.name,
            candidates,
            cfg.jaccard_merge,
            cfg.jaccard_escalate,
            cfg.min_entropy,
        )
        if decision.is_matched():
            resolved.append(decision.nid)
            continue
        if decision.is_needs_judgment():
            ref cand = candidates[decision.candidate_index]
            if llm.judge_same_entity(
                m.name, String(m.summary), String(cand.name), String(cand.summary)
            ):
                resolved.append(cand.nid)
                continue
        resolved.append(
            mint_entity(
                ws, m, query_vec^, partition_id, facet, facet_source
            )
        )
    return resolved^
