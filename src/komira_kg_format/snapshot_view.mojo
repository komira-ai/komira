# =============================================================================
# snapshot_view -- a resolved snapshot: its manifest body and a handle to fetch
#   its table objects.
# =============================================================================
#
# A `SnapshotView` is what `KgSnapshotStore.read_snapshot` returns for a base
# chunk. It holds the decoded `KgManifestBody` and its own handle on the object
# store, so it stays readable after the store that made it is gone, and after the
# lineage has moved on: the objects it names are content-addressed and never
# overwritten with different bytes.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from .manifest_body import KgManifestBody, KgTableEntry


# A snapshot is named by the sequence number of its manifest chunk: monotone and
# gapless within one lineage.
comptime SnapshotId = Int64


struct SnapshotView[Store: CloneableConditionalWriteStore](Movable):
    """A resolved base snapshot: the manifest body and a store handle.

    `snapshot_id` is the chunk sequence number this view resolves. `body` maps
    each table present to `{object_key, schema_version, row_count}`, and carries
    the graph's embedding dimension. `get_table_bytes` fetches a table's Parquet
    object.

    Parameters:
        Store: The object store the table objects live on.
    """

    var snapshot_id: SnapshotId
    var body: KgManifestBody
    var _store: Self.Store

    def __init__(
        out self,
        snapshot_id: SnapshotId,
        var body: KgManifestBody,
        var store: Self.Store,
    ):
        """A view of `body` read from chunk `snapshot_id`, fetching objects
        through `store`."""
        self.snapshot_id = snapshot_id
        self.body = body^
        self._store = store^

    @always_inline
    def id(self) -> SnapshotId:
        """The chunk sequence number of this snapshot."""
        return self.snapshot_id

    @always_inline
    def embedding_dim(self) -> Int:
        """The number of components of every embedding in this graph."""
        return self.body.embedding_dim

    @always_inline
    def num_tables(self) -> Int:
        """The number of tables the snapshot references."""
        return self.body.num_tables()

    def has_table(self, name: String) -> Bool:
        """True iff the snapshot references a table called `name`."""
        return self.body.has_table(name)

    def resolve(self, name: String) raises -> KgTableEntry:
        """The entry `{name, object_key, schema_version, row_count}` for `name`.

        Raises:
            If the snapshot omits that table.
        """
        return self.body.resolve(name)

    def object_key(self, name: String) raises -> String:
        """The content-addressed Parquet object key of table `name`."""
        return self.resolve(name).object_key

    def row_count(self, name: String) raises -> Int64:
        """The rows in table `name`, as the manifest records them."""
        return self.resolve(name).row_count

    def schema_version(self, name: String) raises -> Int64:
        """The schema version the snapshot stamped on table `name`."""
        return self.resolve(name).schema_version

    def assert_table_readable(
        self, name: String, reader_supported_version: Int64
    ) raises:
        """Refuse a table stamped with a schema version newer than the reader
        understands.

        A snapshot written under a later schema would be misread as the current
        layout, so the reader says what it understands and this raises rather
        than let it misread. An equal or older stamp is readable: an older
        table's columns are a prefix of the newer layout.

        This is the per-table gate; the manifest's format version is checked
        when the body is decoded.

        Args:
            name: The table to check.
            reader_supported_version: The highest schema version this build can
                read for that table (for example `SCHEMA_VERSION_ENTITIES`).

        Raises:
            If the snapshot omits `name`, or its stamp is above
            `reader_supported_version`.
        """
        var stamped = self.resolve(name).schema_version
        if stamped > reader_supported_version:
            raise Error(
                "SnapshotView.assert_table_readable: table "
                + name
                + " snapshot schema_version "
                + String(stamped)
                + " > reader-supported "
                + String(reader_supported_version)
                + " (this build cannot read a later schema; use a reader that"
                " understands it)"
            )

    def get_table_bytes(self, name: String) raises -> List[UInt8]:
        """The Parquet object of table `name`, byte for byte as it was written.

        Raises:
            If the snapshot omits the table, or the object cannot be read.
        """
        return self._store.get(Path.parse(self.object_key(name)))
