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
#     writer appended meanwhile is carried, then a bootstrap delta (`rewrite`)
#     holding the exact-name index and embedding projection of the surviving
#     entities only. The head then holds no row, no embedding, no name-index
#     entry and no closure of the erased partition.
#
# A WRITER THAT RACES. A delta appended between the read and the commit is
# carried onto the new head, and a writer that still held the partition (it read
# the graph before the erasure) may have put the partition's rows, edges to its
# nodes, tombstones of such edges, name-index entries or projection rows in it.
# After every commit the carried deltas are examined for exactly those; if they
# hold any, the head is folded again, the carried deltas included, with the
# partition left out (`SnapshotWorkingSet.load_merged_without_partition`, which
# does not trip over a tombstone for an edge the new base no longer holds). That
# repeats for at most `MAX_ERASE_ROUNDS` commits; a writer that is still adding
# the partition after the last one makes the call raise, naming the partition and
# the count of rows that are still on the head. A carried delta of another
# partition is examined and kept as it is. Between a commit and the fold that
# removes a carried tombstone of an erased edge, a reader that merges the head
# fails ("matches no edge"); the next commit repairs the head.
#
# WHAT STAYS. Earlier chunks and the objects they name are not deleted: the
# lineage is append-only, `KgSnapshotStore` has no delete verb, and a reader
# pinned to an earlier head must keep reading it. So the erased rows stay in the
# objects of the old base and deltas until the host reaps them. The deltas of the
# old chain are retired (stamped with the caller's time, see `compaction`) so the
# host's retention policy can find them; the old base and its objects are for the
# host to remove. The change gate's fingerprints (`fingerprint_*`) are not
# touched. The node-id high-water mark is derived from the entities a load
# finds, so when the erased partition held the highest node ids, a reload
# mints them again for new entities.
#
# A CRASH after the head commit and before the bootstrap leaves a head with no
# index. Repeating the call finds nothing to erase and appends the bootstrap; the
# deltas the crashed call folded stay unretired (see `rewrite`).
#
# A set that erased something cannot be written with `delta_tables` (it refuses
# a set that lost a loaded entity or shrank below its loaded edges); write it
# with `to_tables`.
# =============================================================================

from komira_kg_format import (
    ChainView,
    KgSnapshotStore,
    SCHEMA_VERSION_ENTITIES_EMBEDDING,
    SnapshotId,
)
from komira_objectstore.store import CloneableConditionalWriteStore

from .bitemporal import WorkingEdge
from .rewrite import CommittedRewrite, base_tables_of, finish_rewrite
from .working_codec import (
    TABLE_ENTITIES_EMBEDDING,
    decode_embedding_projection,
    read_delta_table,
)
from .working_rows import WorkingEntity, WorkingEpisode
from .working_set import PartitionDrop, SnapshotWorkingSet


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


# The commits `erase_kg_partition` makes at most: the first, then one more for
# each time the deltas a writer slipped in held rows of the partition.
comptime MAX_ERASE_ROUNDS: Int = 4


def _index_rows_of_gone[
    Store: CloneableConditionalWriteStore
](chain: ChainView[Store], gone: Dict[Int64, Bool], dim: Int) raises -> Int:
    """The name-index entries and projection rows of the chain's deltas that
    name a node id in `gone`."""
    var count = 0
    for d in range(chain.num_deltas()):
        ref dbody = chain.deltas[d]
        ref entries = dbody.name_index.entries
        for i in range(len(entries)):
            if entries[i].nid in gone:
                count += 1
        if dbody.has_table(TABLE_ENTITIES_EMBEDDING):
            var rows = decode_embedding_projection(
                read_delta_table(
                    chain,
                    d,
                    TABLE_ENTITIES_EMBEDDING,
                    SCHEMA_VERSION_ENTITIES_EMBEDDING,
                ),
                dim,
            )
            for i in range(len(rows.nids)):
                if rows.nids[i] in gone:
                    count += 1
    return count


def _add(mut report: ErasureReport, drop: PartitionDrop):
    report.entities += drop.entities
    report.edges += drop.edges
    report.episodes += drop.episodes


def erase_kg_partition[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store], partition_id: String, now_ms: Int64
) raises -> ErasureReport:
    """Erase `partition_id` from the live graph of `store` (see the file
    header). Idempotent: a partition with no rows writes no base and returns an
    empty report, so a retry after a failure is safe (it also appends a
    bootstrap that a crashed erasure or fold left missing).

    The new base is committed the way a compaction commits (it names the chain
    it was built from), so a delta another writer appended meanwhile stays on
    the head instead of being dropped, unless it holds rows of the partition
    (see the file header). The deltas that were folded are retired.

    Args:
        store: The snapshot store.
        partition_id: The partition to erase.
        now_ms: The time, in milliseconds from the caller's clock, stamped on
            each retired delta.

    Raises:
        If the lineage is empty, a table is unreadable, another compaction
        committed first (retry), the writes fail (the old head stays the head
        until the new chain head is committed), or a writer keeps adding the
        partition's rows.
    """
    var head = store.head_seq()
    if head < SnapshotId(0):
        raise Error("erase_kg_partition: empty lineage (write a base first)")
    return erase_kg_partition_at(store, head, partition_id, now_ms)


def erase_kg_partition_at[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store],
    head: SnapshotId,
    partition_id: String,
    now_ms: Int64,
) raises -> ErasureReport:
    """`erase_kg_partition` of the chain headed at chunk `head`, which is
    normally the head just read. Naming it lets a caller hold the erasure open
    while a writer appends.

    Raises:
        As `erase_kg_partition`.
    """
    var report = ErasureReport(0, 0, 0)
    var committed = erase_commit_at(
        store, head, partition_id, MAX_ERASE_ROUNDS, report
    )
    _ = finish_rewrite(store, committed^, now_ms)
    return report^


def erase_commit_at[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store],
    head: SnapshotId,
    partition_id: String,
    max_rounds: Int,
    mut report: ErasureReport,
) raises -> CommittedRewrite:
    """The erasure of `erase_kg_partition_at` up to the last head commit: the
    bootstrap and the retirements are `finish_rewrite`'s. Nothing is written,
    and `wrote()` of the result is False, if the partition holds no row.

    Args:
        store: The snapshot store.
        head: The base or chain-head chunk to erase from.
        partition_id: The partition to erase.
        max_rounds: The most commits to make (at least one is made).
        report: Set to the rows removed (also when this raises after a commit,
            up to the last one that was examined).

    Raises:
        As `erase_kg_partition`. A writer that still holds the partition's rows
        after `max_rounds` commits raises an error naming the partition and the
        rows left; the head is readable except for a carried tombstone of an
        erased edge, and a repeated call erases again.
    """
    var chain = store.read_chain(head)
    var gone = Dict[Int64, Bool]()
    var drop = PartitionDrop()
    var ws = SnapshotWorkingSet.load_merged_without_partition(
        chain, partition_id, gone, drop
    )
    report = ErasureReport(0, 0, 0)
    _add(report, drop)
    if report.is_empty():
        return CommittedRewrite(head)
    var folded = List[Int64]()
    var committed = head
    var base_seq = SnapshotId(-1)
    var carried = 0
    var rounds = 0
    while True:
        rounds += 1
        base_seq = store.write_base_tables(base_tables_of(ws), ws.embedding_dim)
        committed = store.commit_compacted_head(
            base_seq, chain.base_id(), chain.delta_seqs.copy()
        )
        for i in range(len(chain.delta_seqs)):
            folded.append(chain.delta_seqs[i])
        carried = store.read_chain_body(committed).num_deltas()
        if carried == 0:
            break
        # Deltas a writer appended since the chain was read are on the head
        # now: do they hold anything of the partition?
        chain = store.read_chain(committed)
        var again = PartitionDrop()
        var next_ws = SnapshotWorkingSet.load_merged_without_partition(
            chain, partition_id, gone, again
        )
        var left = again.total() + _index_rows_of_gone(
            chain, gone, ws.embedding_dim
        )
        if left == 0:
            break
        if rounds >= max_rounds:
            raise Error(
                "erase_kg_partition: partition '"
                + partition_id
                + "': "
                + String(left)
                + " row(s) of the partition were added by concurrent writers"
                + " and are still on the head after "
                + String(rounds)
                + " commit(s)"
            )
        _add(report, again)
        ws = next_ws^
    return CommittedRewrite(ws^, committed, base_seq, folded^, carried)
