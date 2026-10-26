# =============================================================================
# rewrite -- what a rewrite of a whole graph writes: the base tables, and the
#   index delta that rides on the new base.
# =============================================================================
#
# Compaction (`compaction`) and erasure (`erase`) both replace the head with a
# base built from a working set. A base carries no dedup index, so each follows
# its base with one bootstrap delta that holds the exact-name index and the
# `entities_embedding` projection of every entity, and no graph table. A reader
# resolving an exact name or a near-duplicate then needs no read of the wide
# base; and because the delta holds no graph table it adds no row on a merge and
# does not make the chain look worth folding again.
#
# A delta that was appended after the pending base was read (a writer that raced
# the fold) is carried on the new head, and it is newer than the base: the
# bootstrap leaves out the names and node ids that delta already speaks for, so
# the later position of the bootstrap on the chain cannot override it.
# =============================================================================

from komira_collections.slab import Slab
from komira_kg_format import (
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    SCHEMA_VERSION_ENTITIES,
    SCHEMA_VERSION_ENTITIES_EMBEDDING,
    SnapshotId,
)
from komira_objectstore.store import CloneableConditionalWriteStore

from .name_similarity import normalize_name
from .working_codec import (
    TABLE_ENTITIES,
    TABLE_ENTITIES_EMBEDDING,
    build_embedding_projection_batch,
    build_entities_batch,
    decode_embedding_projection,
    read_delta_table,
)
from .working_set import SnapshotWorkingSet


def base_tables_of(ws: SnapshotWorkingSet) raises -> Slab[KgTable]:
    """The tables of a base snapshot of `ws`. A set with no rows at all (every
    partition erased) still writes a base: a zero-row `entities` table, because
    a snapshot with no table is refused.

    Raises:
        As `SnapshotWorkingSet.to_tables`.
    """
    var tables = ws.to_tables()
    if len(tables) == 0:
        tables.append(
            KgTable(
                String(TABLE_ENTITIES),
                build_entities_batch(ws.entities, List[Int](), ws.embedding_dim),
                SCHEMA_VERSION_ENTITIES,
            )
        )
    return tables^


def append_index_bootstrap[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store],
    ws: SnapshotWorkingSet,
    head: SnapshotId,
) raises -> SnapshotId:
    """Append the bootstrap delta of `ws` to the chain headed at `head` and
    return the new head; `head` itself if `ws` has no entity.

    `ws` is the state the base at `head` was built from. The deltas already on
    `head` were appended after that state was read, so they win over it: the
    names their name index lists and the node ids their projections list are
    left out of the bootstrap.

    Raises:
        If a delta on `head` is unreadable, or the append fails.
    """
    if len(ws.entities) == 0:
        return head
    var chain = store.read_chain(head)
    var newer_names = Dict[String, Bool]()
    var newer_nids = Dict[Int64, Bool]()
    for d in range(chain.num_deltas()):
        ref dbody = chain.deltas[d]
        ref entries = dbody.name_index.entries
        for i in range(len(entries)):
            newer_names[entries[i].normalized_name] = True
        if dbody.has_table(TABLE_ENTITIES_EMBEDDING):
            var rows = decode_embedding_projection(
                read_delta_table(
                    chain,
                    d,
                    TABLE_ENTITIES_EMBEDDING,
                    SCHEMA_VERSION_ENTITIES_EMBEDDING,
                ),
                ws.embedding_dim,
            )
            for i in range(len(rows.nids)):
                newer_nids[rows.nids[i]] = True
    var index = KgNameIndexBody()
    var keep = List[Int]()
    for i in range(len(ws.entities)):
        ref e = ws.entities[i]
        var name = normalize_name(e.name)
        if name not in newer_names:
            index.add(name, e.nid)
        if e.nid not in newer_nids:
            keep.append(i)
    if index.num_entries() == 0 and len(keep) == 0:
        return head
    var tables = Slab[KgTable]()
    if len(keep) > 0:
        tables.append(
            KgTable(
                String(TABLE_ENTITIES_EMBEDDING),
                build_embedding_projection_batch(
                    ws.entities, keep, ws.embedding_dim
                ),
                SCHEMA_VERSION_ENTITIES_EMBEDDING,
            )
        )
    return store.append_delta(tables^, index^)
