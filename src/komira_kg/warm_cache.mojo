# =============================================================================
# warm_cache -- keep the merged graph in memory between reads.
# =============================================================================
#
# Reading the live graph merges the head chain (`SnapshotWorkingSet.load_latest`),
# a read of every table object on each call. A process that reads often holds the
# merge and reuses it until the head moves.
#
# THE KEY is the head chunk's sequence number, read fresh from the store on
# every call (`latest_snapshot_id`, one head read and no object fetch). The
# lineage is append-only and every chunk and object is content-addressed and
# immutable, so a given head resolves the same base and deltas for ever: a set
# merged at head `h` is the set a fresh load at `h` would give. An append, a
# fold or an erasure appends a new head chunk, so the next call sees the key
# move and merges again. A head moved by another process is seen the same way,
# through a handle that reads the listing (see below).
#
# THE HEAD IS READ THROUGH THE HANDLE YOU PASS. A `KgSnapshotStore` handle sees
# its own commits at once; one that already holds a tail may not see another
# handle's, and re-reads the listing only when it holds none. So a cache that
# must follow writers in other processes is given a fresh handle on each call
# (one listing, no object fetch); a cache that serves one process's own writes
# can keep passing its handle. `take_current` and `commit` assume that single
# writer; a head moved by another writer is only noticed through a fresh handle.
#
# TWO WAYS TO USE IT.
#   * `refresh` and `get`: a read-only borrow of the merged set. `refresh` makes
#     the resident set current (a hit costs one head read) and `get` lends it as
#     an immutable `ref`, so a reader cannot change what the next reader sees.
#   * `take_current` and `commit`: the single writer's loop. `take_current` moves
#     the resident set out (merging again if the head moved), the writer mutates
#     it and appends its own delta, and `commit` puts it back keyed at the new
#     head, so the next ingest starts from memory with no read of the delta it
#     just wrote. Between the two the cache is empty: a writer that fails before
#     `commit` just drops the set and the next call merges the true state.
#
# The cache holds no pointer: the merged set is an owned value, lent out as a
# `ref` into the cache.
# =============================================================================

from komira_kg_format import KgSnapshotStore, SnapshotId
from komira_objectstore.store import CloneableConditionalWriteStore

from .working_set import SnapshotWorkingSet


struct WarmMergedCache[Store: CloneableConditionalWriteStore](Movable):
    """A resident merged `SnapshotWorkingSet`, keyed by the head it was merged
    at.

    Parameters:
        Store: The store type of the `KgSnapshotStore` it reads.
    """

    var _merged: Optional[SnapshotWorkingSet]
    var _head: SnapshotId

    def __init__(out self):
        """A cold cache: nothing is resident."""
        self._merged = Optional[SnapshotWorkingSet]()
        self._head = SnapshotId(-1)

    def is_warm(self) -> Bool:
        """True iff a merged set is resident."""
        return Bool(self._merged)

    def cached_head_seq(self) -> SnapshotId:
        """The head the resident set is keyed at; -1 if cold."""
        return self._head

    def refresh(mut self, store: KgSnapshotStore[Self.Store]) raises:
        """Make the resident set current: keep it if the head has not moved,
        else merge the head afresh, which then becomes resident. `get` lends it.

        Raises:
            If the lineage is empty, or a table is unreadable.
        """
        var head = store.latest_snapshot_id()
        if head < SnapshotId(0):
            raise Error(
                "WarmMergedCache.refresh: empty lineage (write a base snapshot"
                " before reading the merged view)"
            )
        if not self._merged or self._head != head:
            self.invalidate()
            self._merged = Optional[SnapshotWorkingSet](
                SnapshotWorkingSet.load_latest(store)
            )
            self._head = head

    def get(self) raises -> ref [self._merged._value] SnapshotWorkingSet:
        """The resident merged set, read-only: the borrow is immutable because
        `self` is, so a caller cannot edit what the next call lends. It ends at
        the next call on the cache.

        Raises:
            If the cache is cold (call `refresh` first).
        """
        # The return origin names the Optional's storage, which is what
        # `Optional.value()` borrows from; `ref [self._merged]` is refused.
        if not self._merged:
            raise Error("WarmMergedCache.get: the cache is cold (refresh it)")
        return self._merged.value()

    def invalidate(mut self):
        """Drop the resident set: the next call merges again."""
        self._merged = Optional[SnapshotWorkingSet]()
        self._head = SnapshotId(-1)

    def take_current(
        mut self, store: KgSnapshotStore[Self.Store], embedding_dim: Int
    ) raises -> SnapshotWorkingSet:
        """Move the current merged set out for a single writer. The resident
        set is used if the head has not moved since it was keyed; otherwise (cold,
        or another writer advanced the head) it is dropped and the true head is
        merged, so a delta another writer appended is never lost. On an empty
        lineage the result is an empty set of `embedding_dim`.

        The cache is empty until `commit`.

        Raises:
            If a table is unreadable, or `embedding_dim` is not positive (on an
            empty lineage).
        """
        var head = store.latest_snapshot_id()
        var resident = Optional[SnapshotWorkingSet]()
        swap(resident, self._merged)
        var keyed = self._head
        self._head = SnapshotId(-1)
        if head < SnapshotId(0):
            return SnapshotWorkingSet(embedding_dim)
        if resident and keyed == head:
            return resident.take()
        return SnapshotWorkingSet.load_latest(store)

    def commit(mut self, var ws: SnapshotWorkingSet, new_head: SnapshotId) raises:
        """Put back a set that was taken, after the writer's own append moved the
        head to `new_head`. The set is marked committed
        (`SnapshotWorkingSet.mark_committed`) and keyed at `new_head`.

        Raises:
            If an embedding of the set is not `embedding_dim` finite components.
        """
        ws.mark_committed()
        self._merged = Optional[SnapshotWorkingSet](ws^)
        self._head = new_head
