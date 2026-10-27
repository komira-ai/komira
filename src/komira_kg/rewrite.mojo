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
# the later position of the bootstrap on the chain cannot override it. Those
# sets are read from the chain as it is when the bootstrap is appended (a fresh
# read of the head), not from the chain the commit returned, so a delta that
# landed between the commit and the append is spoken for too.
#
# WHEN THAT HOLDS. `KgSnapshotStore` has no verb that appends a delta only if the
# head is still a given chunk, so one window stays: a delta whose chain head lands
# after the bootstrap's fresh read and before the bootstrap's own chain head sits
# EARLIER on the chain, and for a name or node id both speak for, the bootstrap
# (the later delta) wins. The window is one head read to one head append; a
# writer that appends after the bootstrap always wins. If another fold replaced
# the base meanwhile, nothing is appended: that fold wrote its own bootstrap.
#
# A CRASH between the head commit and the bootstrap leaves a head whose base has
# no index. `finish_rewrite` with nothing written, and so a repeated compaction
# or erasure, repairs it (`repair_missing_bootstrap`): a head whose deltas carry
# no name-index entry and no projection gets the bootstrap of its base. The
# deltas the crashed run folded were not retired, and a retry cannot tell them
# from a delta whose writer has not yet landed its chain head (the store lists
# no chunks and `retire_folded_delta` is for a caller that knows the folded
# set), so they stay unmarked; the host's retention policy can retire them.
# =============================================================================

from komira_collections.slab import Slab
from komira_kg_format import (
    KgDeltaBody,
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


struct CommittedRewrite(Movable):
    """A rewritten base that is the head, before its bootstrap and before the
    folded deltas are retired. Made by `compact_commit_at` and
    `erase_commit_at`, finished by `finish_rewrite`.

    Fields:
        ws: The state the committed base was built from; none if nothing was
            written.
        head: The head after the commit (the head found if nothing was written).
        base_seq: The committed base's chunk; -1 if nothing was written.
        folded: Every delta folded into the base.
        carried: The deltas the head carried over from writers that appended
            while the rewrite ran.
    """

    var ws: Optional[SnapshotWorkingSet]
    var head: SnapshotId
    var base_seq: SnapshotId
    var folded: List[Int64]
    var carried: Int

    def __init__(out self, head: SnapshotId):
        """Nothing was written; `head` is the head that was found."""
        self.ws = Optional[SnapshotWorkingSet]()
        self.head = head
        self.base_seq = SnapshotId(-1)
        self.folded = List[Int64]()
        self.carried = 0

    def __init__(
        out self,
        var ws: SnapshotWorkingSet,
        head: SnapshotId,
        base_seq: SnapshotId,
        var folded: List[Int64],
        carried: Int,
    ):
        """A base built from `ws` was committed as `head`."""
        self.ws = Optional[SnapshotWorkingSet](ws^)
        self.head = head
        self.base_seq = base_seq
        self.folded = folded^
        self.carried = carried

    def wrote(self) -> Bool:
        """True iff a base was committed."""
        return Bool(self.ws)


def finish_rewrite[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store], var committed: CommittedRewrite, now_ms: Int64
) raises -> SnapshotId:
    """Finish a rewrite and return the head: append the bootstrap, then retire
    the folded deltas (in that order, after the head moved). If nothing was
    written, repair a base that lacks its bootstrap (see
    `repair_missing_bootstrap`).

    Raises:
        As `append_index_bootstrap` and `KgSnapshotStore.retire_folded_delta`.
        After the head has moved, an error leaves the rewrite done.
    """
    if not committed.wrote():
        return repair_missing_bootstrap(store, committed.head)
    var ws = committed.ws.take()
    var head = append_index_bootstrap(store, ws, committed.head)
    for i in range(len(committed.folded)):
        store.retire_folded_delta(committed.folded[i], now_ms)
    return head


def _speaks_for_an_index(dbody: KgDeltaBody) -> Bool:
    return (
        dbody.name_index.num_entries() > 0
        or dbody.has_table(TABLE_ENTITIES_EMBEDDING)
    )


def repair_missing_bootstrap[
    Store: CloneableConditionalWriteStore
](mut store: KgSnapshotStore[Store], head: SnapshotId) raises -> SnapshotId:
    """Append the bootstrap of the base at `head` if no delta of the head chain
    carries a name-index entry or an embedding projection, and return the head.

    That is the head a rewrite leaves if it stops after the commit. Nothing is
    done if `head` is not the head now (the caller holds an older chain), if a
    delta already carries an index, or if the base holds no entity.

    Raises:
        If a table is unreadable or the append fails.
    """
    if store.head_seq() != head:
        return head
    var chain = store.read_chain(head)
    for d in range(chain.num_deltas()):
        if _speaks_for_an_index(chain.deltas[d]):
            return head
    var ws = SnapshotWorkingSet.load_from(chain.base)
    return append_index_bootstrap(store, ws, head)


def append_index_bootstrap[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store],
    ws: SnapshotWorkingSet,
    head: SnapshotId,
) raises -> SnapshotId:
    """Append the bootstrap delta of `ws` to the head chain and return the new
    head (the head now if `ws` has no entity or nothing is left to index).

    `ws` is the state the base at `head` was built from. The deltas on the
    chain now were appended after that state was read, so they win over it: the
    names their name index lists and the node ids their projections list are
    left out of the bootstrap. The chain is read when this is called, not taken
    from `head`; the header says what window that leaves. If the head's base is
    no longer the base at `head`, another fold replaced it and nothing is
    appended.

    Raises:
        If a delta on the chain is unreadable, or the append fails.
    """
    var base_seq = store.read_chain_body(head).base_seq
    var now = store.head_seq()
    if len(ws.entities) == 0:
        return now
    var chain = store.read_chain(now)
    if chain.base_id() != base_seq:
        return now
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
        return now
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
