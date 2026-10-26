# =============================================================================
# erase -- remove one partition from a graph.
# =============================================================================
#
# Many partitions share one snapshot lineage: `partition_id` is a column of every
# entity and episode, so the partition cannot be removed by deleting a key
# prefix. Erasure instead filters the rows and writes the rest as a new base.
#
#   * `erase_partition` drops, from a working set, the partition's entities and
#     episodes and every edge that has one of those entities as an endpoint
#     (edges carry no partition column; an edge to an erased node cannot
#     survive). Other partitions are untouched. The node-id high-water mark is
#     not lowered.
#   * `erase_kg_partition` does that to the live graph of a store and writes the
#     result as a full base (never a delta: a delta would leave the rows in the
#     base and only mask them), committed as a compaction commits so a delta a
#     writer appended meanwhile is carried, then a bootstrap delta (`rewrite`) holding the
#     exact-name index and embedding projection of the surviving entities only.
#     The head then holds no row, no embedding, no name-index entry and no
#     closure of the erased partition.
#
# WHAT STAYS. Earlier chunks and the objects they name are not deleted: the
# lineage is append-only, `KgSnapshotStore` has no delete verb, and a reader
# pinned to an earlier head must keep reading it. The deltas of the old chain
# are retired (stamped with the caller's time, see `compaction`) so the host's
# retention policy can find them; the old base and its objects are for the host
# to remove. The change gate's fingerprints (`fingerprint_*`) are not touched.
#
# A set that erased something cannot be written with `delta_tables` (it refuses
# a set that lost a loaded entity or shrank below its loaded edges); write it
# with `to_tables`.
# =============================================================================

from komira_kg_format import KgSnapshotStore
from komira_objectstore.store import CloneableConditionalWriteStore

from .bitemporal import WorkingEdge
from .rewrite import append_index_bootstrap, base_tables_of
from .working_rows import WorkingEntity, WorkingEpisode
from .working_set import SnapshotWorkingSet


@fieldwise_init
struct ErasureReport(Copyable, Movable):
    """The rows an erasure removed.

    Fields:
        entities: Entities of the partition.
        edges: Edges that had one of those entities as an endpoint.
        episodes: Episodes of the partition.
    """

    var entities: Int
    var edges: Int
    var episodes: Int

    def is_empty(self) -> Bool:
        """True iff nothing was removed."""
        return self.entities == 0 and self.edges == 0 and self.episodes == 0


def erase_partition(
    mut ws: SnapshotWorkingSet, partition_id: String
) -> ErasureReport:
    """Remove every row of `partition_id` from `ws` (see the file header).
    Erasing a partition the set does not hold removes nothing."""
    var gone = Dict[Int64, Bool]()
    var entities = List[WorkingEntity]()
    for i in range(len(ws.entities)):
        if ws.entities[i].partition_id == partition_id:
            gone[ws.entities[i].nid] = True
        else:
            entities.append(ws.entities[i].copy())
    var edges = List[WorkingEdge]()
    for i in range(len(ws.edges)):
        ref e = ws.edges[i]
        if e.src_nid not in gone and e.dst_nid not in gone:
            edges.append(e.copy())
    var episodes = List[WorkingEpisode]()
    for i in range(len(ws.episodes)):
        if ws.episodes[i].partition_id != partition_id:
            episodes.append(ws.episodes[i].copy())
    var report = ErasureReport(
        len(ws.entities) - len(entities),
        len(ws.edges) - len(edges),
        len(ws.episodes) - len(episodes),
    )
    ws.entities = entities^
    ws.edges = edges^
    ws.episodes = episodes^
    return report^


def erase_kg_partition[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store], partition_id: String, now_ms: Int64
) raises -> ErasureReport:
    """Erase `partition_id` from the live graph of `store` (see the file
    header). Idempotent: a partition with no rows writes nothing and returns an
    empty report, so a retry after a failure is safe.

    The new base is committed the way a compaction commits (it names the chain
    it was built from), so a delta another writer appended meanwhile stays on
    the head instead of being dropped; that delta is newer than the erasure and
    is the writer's to keep. The deltas that were folded are retired.

    Args:
        store: The snapshot store.
        partition_id: The partition to erase.
        now_ms: The time, in milliseconds from the caller's clock, stamped on
            each retired delta.

    Raises:
        If the lineage is empty, a table is unreadable, another compaction
        committed first (retry), or the writes fail (the old head stays the
        head until the new chain head is committed).
    """
    var chain = store.open_latest_chain()
    var ws = SnapshotWorkingSet.load_merged(chain)
    var report = erase_partition(ws, partition_id)
    if report.is_empty():
        return report^
    var folded = chain.delta_seqs.copy()
    var base = store.write_base_tables(base_tables_of(ws), ws.embedding_dim)
    var head = store.commit_compacted_head(base, chain.base_id(), folded.copy())
    _ = append_index_bootstrap(store, ws, head)
    for i in range(len(folded)):
        store.retire_folded_delta(folded[i], now_ms)
    return report^
