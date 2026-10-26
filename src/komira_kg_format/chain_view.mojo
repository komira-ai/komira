# =============================================================================
# chain_view -- a resolved delta chain: a base snapshot and the ordered deltas
#   over it.
# =============================================================================
#
# A `ChainView` is what `KgSnapshotStore.read_chain` returns. Merging the base
# with the deltas into a working set is the reader's job; this holds what the
# merge needs: the base view, the decoded delta bodies in apply order, the
# chunk sequence number of each delta, and the handle to fetch delta objects.
#
# A chain of one (a base-only head, or the head just after a fold) has no
# deltas, and merging it is just loading the base.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from .delta_body import KgDeltaBody
from .snapshot_view import SnapshotId, SnapshotView


struct ChainView[Store: CloneableConditionalWriteStore](Movable):
    """A resolved chain: a base `SnapshotView`, the `KgDeltaBody` of each delta
    in apply order, and a store handle for the delta objects.

    `head_seq` is the chunk sequence number of the head this view resolves (the
    chain chunk, or for a base-only head the base chunk itself). `delta_seqs[i]`
    is the chunk of `deltas[i]`; a compactor passes them back to
    `commit_compacted_head` as the deltas it folded.

    Parameters:
        Store: The object store the delta objects live on.
    """

    var head_seq: SnapshotId
    var base: SnapshotView[Self.Store]
    var delta_seqs: List[Int64]
    var deltas: List[KgDeltaBody]
    var _store: Self.Store

    def __init__(
        out self,
        head_seq: SnapshotId,
        var base: SnapshotView[Self.Store],
        var delta_seqs: List[Int64],
        var deltas: List[KgDeltaBody],
        var store: Self.Store,
    ) raises:
        """A chain view over `base` and `deltas`, fetching delta objects through
        `store`.

        Raises:
            If `delta_seqs` and `deltas` differ in length.
        """
        if len(delta_seqs) != len(deltas):
            raise Error(
                "ChainView: "
                + String(len(delta_seqs))
                + " delta sequence numbers for "
                + String(len(deltas))
                + " delta bodies"
            )
        self.head_seq = head_seq
        self.base = base^
        self.delta_seqs = delta_seqs^
        self.deltas = deltas^
        self._store = store^

    @always_inline
    def id(self) -> SnapshotId:
        """The chunk sequence number of the head this view resolves."""
        return self.head_seq

    @always_inline
    def num_deltas(self) -> Int:
        """The number of deltas over the base."""
        return len(self.deltas)

    def base_id(self) -> SnapshotId:
        """The chunk sequence number of the base."""
        return self.base.id()

    def delta_object_bytes(
        self, delta_idx: Int, name: String
    ) raises -> List[UInt8]:
        """The delta object of table `name` in delta number `delta_idx`, as
        written (a framed blob or a Parquet file; see `delta_codec`).

        Raises:
            If `delta_idx` is out of range, the delta does not change `name`, or
            the object cannot be read.
        """
        if delta_idx < 0 or delta_idx >= len(self.deltas):
            raise Error(
                "ChainView.delta_object_bytes: delta index "
                + String(delta_idx)
                + " out of range for a chain of "
                + String(len(self.deltas))
                + " deltas"
            )
        var key = self.deltas[delta_idx].resolve(name).object_key
        return self._store.get(Path.parse(key))

    def resolve_name_index(self, normalized_name: String) -> Int64:
        """The id `normalized_name` resolves to in the chain's folded name
        index, or -1 if it is absent.

        The index is the deltas' entries folded in apply order, later entries
        winning. It touches only the decoded delta bodies, never a table object,
        so an exact-name match resolves without loading the base. A base has no
        index of its own: names written before the first delta are not in it.
        """
        var found = Int64(-1)
        for d in range(len(self.deltas)):
            ref entries = self.deltas[d].name_index.entries
            for i in range(len(entries)):
                if entries[i].normalized_name == normalized_name:
                    found = entries[i].nid
        return found
