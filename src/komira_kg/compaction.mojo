# =============================================================================
# compaction -- fold a delta chain into a fresh base.
# =============================================================================
#
# `compact_chain` merges the head chain (base and deltas) into the rows a full
# rewrite would hold, writes them as a new base, and makes that base the head.
# It lives here, not in `komira_kg_format`, because the fold is a read-merge that
# rebuilds tables: it needs the working set, and the format package knows
# nothing of one.
#
# THE FOLD, in order:
#   1. Pin a head `H` and resolve that exact chain: the folded deltas and the
#      merged rows come from the same immutable chunk, so a delta appended
#      afterwards cannot land in the new base without being listed as folded.
#   2. Merge `H` (`SnapshotWorkingSet.load_merged`) and rebuild its tables.
#   3. Write them as a PENDING base (`write_base_tables`). It is not the head and
#      no reader sees it as one.
#   4. `commit_compacted_head` appends the chain head `{new base, deltas on the
#      head now that H did not fold}`. A writer that appended while the fold ran
#      has its delta carried onto the new head, never lost.
#   5. Append the bootstrap index delta (see `rewrite`).
#   6. Retire the folded deltas: stamp each chunk with the caller's `now_ms`.
#
# NOTHING IS DELETED. Step 6 only writes a retention marker, and the new base is
# new objects. A reader that pinned a head from before the fold (a `ChainView`,
# or a `SnapshotView` of the old base) still finds every chunk and object it
# names; when to delete them is the host's retention decision, taken against
# `KgSnapshotStore.retired_age_ms`.
#
# THE ORDER IS THE RULE. The head moves (step 4) before any delta is retired
# (step 6), and `retire_folded_delta` refuses a delta the head chain still names
# (it reads the head authoritatively, not from this handle's tail). A fold that
# stops after step 4 leaves a readable lineage whose folded deltas are merely
# not yet marked.
#
# IDEMPOTENT. A base alone, and a chain whose only deltas are bootstrap deltas
# (no graph table), are already compact: nothing is written.
#
# The store reads no clock: `now_ms` is the host's.
# =============================================================================

from komira_kg_format import (
    CompactionPolicy,
    KgDeltaBody,
    KgSnapshotStore,
    SnapshotId,
)
from komira_objectstore.store import CloneableConditionalWriteStore

from .rewrite import append_index_bootstrap, base_tables_of
from .working_codec import (
    TABLE_EDGES,
    TABLE_EDGES_TOMBSTONE,
    TABLE_ENTITIES,
    TABLE_EPISODES,
)
from .working_set import SnapshotWorkingSet


@fieldwise_init
struct CompactionResult(Copyable, Movable):
    """What a `compact_chain` call did.

    Fields:
        compacted: Whether a fold ran (False when there was nothing to fold).
        new_head_seq: The head after the call; the head that was found if no
            fold ran.
        new_base_seq: The new base's chunk; -1 if no fold ran.
        num_folded: The deltas folded into the new base.
        num_carried: The deltas the new head carried over from writers that
            appended while the fold ran (the bootstrap delta is not counted).
    """

    var compacted: Bool
    var new_head_seq: SnapshotId
    var new_base_seq: SnapshotId
    var num_folded: Int
    var num_carried: Int


def _nothing_to_fold(head: SnapshotId) -> CompactionResult:
    return CompactionResult(False, head, SnapshotId(-1), 0, 0)


def _has_graph_data(dbody: KgDeltaBody) -> Bool:
    """Whether a delta changes a graph table, as opposed to only adding dedup
    index entries (a name index, an embedding projection)."""
    return (
        dbody.has_table(TABLE_ENTITIES)
        or dbody.has_table(TABLE_EDGES)
        or dbody.has_table(TABLE_EPISODES)
        or dbody.has_table(TABLE_EDGES_TOMBSTONE)
    )


def compact_chain[
    Store: CloneableConditionalWriteStore
](mut store: KgSnapshotStore[Store], now_ms: Int64) raises -> CompactionResult:
    """Fold the store's current head chain into a fresh base (see the file
    header). Same as `compact_chain_at` on the head found now.

    Args:
        store: The snapshot store.
        now_ms: The time, in milliseconds from the caller's clock, stamped on
            each retired delta.

    Raises:
        If the lineage is empty, or as `compact_chain_at`.
    """
    var head = store.head_seq()
    if head < SnapshotId(0):
        raise Error("compact_chain: empty lineage (write a base first)")
    return compact_chain_at(store, head, now_ms)


def compact_chain_at[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store], head: SnapshotId, now_ms: Int64
) raises -> CompactionResult:
    """Fold the chain headed at chunk `head` into a fresh base and make it the
    head, carrying forward every delta the head has gained since `head`.

    `head` is normally the head just read. Naming it is what lets a caller (or
    a test) hold a fold open while another writer appends.

    Args:
        store: The snapshot store.
        head: A base or chain-head chunk to fold.
        now_ms: The time, in milliseconds from the caller's clock, stamped on
            each retired delta.

    Raises:
        If `head` is not a base or chain head, another compaction committed a
        base first (fold the new chain instead), the chain head keeps losing
        the race for its slot (an error ending "(retryable)"), or a table is
        unreadable. After the head has moved, an error from retiring a delta
        leaves the fold done and the delta unmarked.
    """
    var chain = store.read_chain(head)
    if chain.num_deltas() == 0:
        return _nothing_to_fold(head)
    var has_data = False
    for i in range(chain.num_deltas()):
        if _has_graph_data(chain.deltas[i]):
            has_data = True
    if not has_data:
        return _nothing_to_fold(head)
    var folded_base = chain.base_id()
    var folded = chain.delta_seqs.copy()

    var ws = SnapshotWorkingSet.load_merged(chain)
    var new_base = store.write_base_tables(base_tables_of(ws), ws.embedding_dim)
    var committed = store.commit_compacted_head(
        new_base, folded_base, folded.copy()
    )
    var carried = store.read_chain_body(committed).num_deltas()
    var new_head = append_index_bootstrap(store, ws, committed)
    for i in range(len(folded)):
        store.retire_folded_delta(folded[i], now_ms)
    return CompactionResult(True, new_head, new_base, len(folded), carried)


def maybe_compact_chain[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store],
    policy: CompactionPolicy,
    now_ms: Int64,
) raises -> CompactionResult:
    """Fold the head chain if `policy` says it is worth it: the host calls it
    after an append. No fold runs on an empty lineage, a base alone, a chain the
    policy does not trip on, or a chain that is already compact.

    Args:
        store: The snapshot store.
        policy: The count-or-size trigger.
        now_ms: As `compact_chain`.
    """
    var head = store.head_seq()
    if head < SnapshotId(0):
        return _nothing_to_fold(head)
    var body = store.read_chain_body(head)
    if body.num_deltas() == 0:
        return _nothing_to_fold(head)
    var sizes = store.chain_total_bytes(body)
    if not policy.should_compact(body.num_deltas(), sizes[1], sizes[0]):
        return _nothing_to_fold(head)
    return compact_chain_at(store, head, now_ms)
