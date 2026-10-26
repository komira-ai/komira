# =============================================================================
# embedding_topk -- the nearest entities to a vector, from the deltas' narrow
#   embedding projection.
# =============================================================================
#
# Every delta that adds or edits entities carries an `entities_embedding` table:
# the node id and the packed name embedding, and nothing else. Candidate
# generation for near-duplicate resolution reads only those objects, never the
# wide base `entities` table (a bootstrap delta puts the whole projection on a
# compacted or erased base, see `rewrite`).
#
# The projections are folded in apply order, a later row for a node id replacing
# the earlier one (an entity renamed and re-embedded), and every entity is scored
# by `cosine` against the query. This is an exact scan, O(rows * k); an
# approximate index is a different component.
#
# A chain whose deltas carry no projection (a base alone, or deltas written
# before a projection existed) yields no candidates; the caller then scans the
# base's entities.
# =============================================================================

from komira_kg_format import ChainView, SCHEMA_VERSION_ENTITIES_EMBEDDING, cosine
from komira_objectstore.store import CloneableConditionalWriteStore

from .working_codec import (
    TABLE_ENTITIES_EMBEDDING,
    decode_embedding_projection,
    read_delta_table,
)


@fieldwise_init
struct EmbeddingCandidate(Copyable, Movable):
    """One near-duplicate candidate: an entity and its cosine score against the
    query.

    Fields:
        nid: The entity's node id.
        score: The cosine similarity, in [-1.0, 1.0].
    """

    var nid: Int64
    var score: Float64


def resolve_embedding_topk[
    Store: CloneableConditionalWriteStore
](
    chain: ChainView[Store], query: List[Float64], k: Int
) raises -> List[EmbeddingCandidate]:
    """The `k` entities of the chain nearest to `query` by cosine.

    Order: score descending; equal scores by ascending node id. Fewer than `k`
    are returned if the chain's projection holds fewer entities.

    Args:
        chain: The resolved chain; its deltas carry the projection.
        query: The query vector; its length must be the graph's embedding
            dimension (the base manifest's).
        k: How many candidates; more than zero.

    Raises:
        If `k` is not positive, `query` is not the graph's dimension, or a
        projection table is malformed (a cell of another length, a null cell, a
        node id out of range).
    """
    if k <= 0:
        raise Error(
            "resolve_embedding_topk: k must be positive, got " + String(k)
        )
    var dim = chain.base.embedding_dim()
    if len(query) != dim:
        raise Error(
            "resolve_embedding_topk: the query has "
            + String(len(query))
            + " components but the graph's dimension is "
            + String(dim)
        )
    var nids = List[Int64]()
    var vectors = List[List[Float64]]()
    var at = Dict[Int64, Int]()
    for d in range(chain.num_deltas()):
        if not chain.deltas[d].has_table(TABLE_ENTITIES_EMBEDDING):
            continue
        var rows = decode_embedding_projection(
            read_delta_table(
                chain,
                d,
                TABLE_ENTITIES_EMBEDDING,
                SCHEMA_VERSION_ENTITIES_EMBEDDING,
            ),
            dim,
        )
        for r in range(len(rows.nids)):
            var nid = rows.nids[r]
            if nid in at:
                vectors[at[nid]] = rows.vectors[r].copy()
            else:
                at[nid] = len(nids)
                nids.append(nid)
                vectors.append(rows.vectors[r].copy())
    var n = len(nids)
    var scores = List[Float64](capacity=n)
    for i in range(n):
        scores.append(cosine(query, vectors[i]))
    var taken = List[Bool]()
    for _ in range(n):
        taken.append(False)
    var out = List[EmbeddingCandidate]()
    for _ in range(min(k, n)):
        var best = -1
        for i in range(n):
            if taken[i]:
                continue
            if (
                best < 0
                or scores[i] > scores[best]
                or (scores[i] == scores[best] and nids[i] < nids[best])
            ):
                best = i
        taken[best] = True
        out.append(EmbeddingCandidate(nids[best], scores[best]))
    return out^
