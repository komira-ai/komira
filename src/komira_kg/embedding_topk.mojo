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
# by `cosine` against the query. This is an exact scan, O(rows * log k): the k
# best are kept in a bounded heap. An approximate index is a different component.
#
# NON-FINITE VALUES. A query with a NaN or infinite component is refused. A stored
# row with one (a table written past the working set, which refuses them) is
# skipped, never ranked: `cosine` scores such a row 0.0, which would put it among
# the genuine orthogonal matches.
#
# A chain whose deltas carry no projection (a base alone, or deltas written
# before a projection existed) yields no candidates; the caller then scans the
# base's entities.
# =============================================================================

from std.math import isfinite

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
    are returned if the chain's projection holds fewer entities. A stored row
    with a non-finite component is skipped, not ranked.

    Args:
        chain: The resolved chain; its deltas carry the projection.
        query: The query vector; its length must be the graph's embedding
            dimension (the base manifest's).
        k: How many candidates; more than zero.

    Raises:
        If `k` is not positive, `query` is not the graph's dimension, `query`
        has a component that is not finite, or a projection table is malformed (a cell of another length, a null cell, a
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
    for i in range(len(query)):
        if not isfinite(query[i]):
            raise Error(
                "resolve_embedding_topk: query component "
                + String(i)
                + " is not finite"
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
    # The k best rows so far, as indices into `nids`/`scores`, in a heap whose
    # root is the WORST of them: a new row replaces the root if it beats it.
    var scores = List[Float64](capacity=len(nids))
    var heap = List[Int]()
    for i in range(len(nids)):
        if not _all_finite(vectors[i]):
            scores.append(0.0)
            continue
        scores.append(cosine(query, vectors[i]))
        if len(heap) < k:
            heap.append(i)
            _sift_up(heap, len(heap) - 1, scores, nids)
        elif _worse(heap[0], i, scores, nids):
            heap[0] = i
            _sift_down(heap, 0, len(heap), scores, nids)
    # Heap sort: the worst goes to the end each time, leaving best first.
    var size = len(heap)
    while size > 1:
        size -= 1
        _swap_at(heap, 0, size)
        _sift_down(heap, 0, size, scores, nids)
    var out = List[EmbeddingCandidate]()
    for i in range(len(heap)):
        out.append(EmbeddingCandidate(nids[heap[i]], scores[heap[i]]))
    return out^


def _all_finite(v: List[Float64]) -> Bool:
    for i in range(len(v)):
        if not isfinite(v[i]):
            return False
    return True


def _swap_at(mut heap: List[Int], i: Int, j: Int):
    var held = heap[i]
    heap[i] = heap[j]
    heap[j] = held


def _worse(
    a: Int, b: Int, scores: List[Float64], nids: List[Int64]
) -> Bool:
    """Whether row `a` ranks below row `b`: a lower score, or the same score and
    a higher node id."""
    if scores[a] != scores[b]:
        return scores[a] < scores[b]
    return nids[a] > nids[b]


def _sift_up(
    mut heap: List[Int], start: Int, scores: List[Float64], nids: List[Int64]
):
    var i = start
    while i > 0:
        var parent = (i - 1) // 2
        if not _worse(heap[i], heap[parent], scores, nids):
            break
        _swap_at(heap, i, parent)
        i = parent


def _sift_down(
    mut heap: List[Int],
    start: Int,
    size: Int,
    scores: List[Float64],
    nids: List[Int64],
):
    var i = start
    while True:
        var left = 2 * i + 1
        if left >= size:
            break
        var child = left
        if left + 1 < size and _worse(heap[left + 1], heap[left], scores, nids):
            child = left + 1
        if not _worse(heap[child], heap[i], scores, nids):
            break
        _swap_at(heap, i, child)
        i = child
