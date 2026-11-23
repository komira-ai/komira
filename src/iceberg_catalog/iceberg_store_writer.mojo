# =============================================================================
# iceberg_catalog/iceberg_store_writer.mojo — the committer's manifest writer
#   for one statement: its manifest once, its manifest list per attempt.
# =============================================================================
#
# `StoreSnapshotWriter` is the `AppendSnapshotWriter` of the write sink. It
# holds one statement's data files (already written, as `DataFileInfo` with
# their URIs) and writes, through a `TableFiles`, under the table's metadata
# path:
#
#   * the statement's MANIFEST, on the first attempt that needs one and never
#     again: `<metadata path>/<statement uuid>-m0.avro`, listing the data
#     files as ADDED under the snapshot id `S` with inherited (null) sequence
#     numbers, so the one manifest is valid in whichever attempt lands. A
#     statement with no files has none.
#   * a MANIFEST LIST per attempt:
#     `<metadata path>/snap-<S>-<attempt>-<statement uuid>.avro`. An append
#     lists the manifests of `main`'s snapshot in the base the attempt was
#     built on, then the statement's manifest (sequence number inherited,
#     added under `S`). An overwrite lists the statement's manifest alone, and
#     nothing when the statement has no files.
#
# The base's manifest list is read from the store, so a 409 that moves `main`
# is followed by a list that carries the new base's manifests and the same
# manifest. A base list that this package did not write cannot be read
# positionally (`is_komira_manifest_list`), so an append on top of it is
# refused as `ICEBERG_MANIFEST_LIST_UNSUPPORTED` until a general reader
# exists; an overwrite never reads the base's list. A base whose `main` names a
# snapshot the metadata does not list is `ICEBERG_CATALOG_RESPONSE_INVALID`.
#
# `manifest_uri` ("" until written) and `written` (the manifest and every list,
# in write order) are what the caller deletes after a definite failure.
# =============================================================================

from iceberg import (
    DataFileInfo,
    ICE_MANIFEST_CONTENT_DATA,
    ICE_SEQ_INHERIT,
    ManifestFileEntry,
    build_data_manifest,
    build_manifest_list,
    is_komira_manifest_list,
    read_manifest_list,
)
from objectstore.store import CloneableConditionalWriteStore

from .iceberg_commit import AppendSnapshotWriter
from .iceberg_rest_errors import (
    ICEBERG_CATALOG_RESPONSE_INVALID,
    ICEBERG_MANIFEST_LIST_UNSUPPORTED,
)
from .iceberg_table_files import TableFiles
from .iceberg_table_metadata import TableMetadata


struct StoreSnapshotWriter[S: CloneableConditionalWriteStore](
    AppendSnapshotWriter, Movable
):
    """Writes one statement's manifest and manifest lists (module header).

    `schema_json` and `schema_id` are the table's current schema, as the
    manifest header records it; `metadata_path` is the URI of the directory
    the files go to, without a trailing `/`."""

    var _files: TableFiles[Self.S]
    var _statement_uuid: String
    var _overwrite: Bool
    var _data_files: List[DataFileInfo]
    var _schema_json: String
    var _schema_id: Int
    var _metadata_path: String
    var _manifest: Optional[ManifestFileEntry]
    var manifest_uri: String
    var written: List[String]

    def __init__(
        out self,
        var files: TableFiles[Self.S],
        var statement_uuid: String,
        overwrite: Bool,
        var data_files: List[DataFileInfo],
        var schema_json: String,
        schema_id: Int,
        var metadata_path: String,
    ):
        self._files = files^
        self._statement_uuid = statement_uuid^
        self._overwrite = overwrite
        self._data_files = data_files^
        self._schema_json = schema_json^
        self._schema_id = schema_id
        self._metadata_path = metadata_path^
        self._manifest = None
        self.manifest_uri = String("")
        self.written = List[String]()

    def write_manifest_list(
        mut self,
        snapshot_id: Int64,
        attempt: Int,
        base: TableMetadata,
        sequence_number: Int64,
    ) raises -> String:
        var entries = List[ManifestFileEntry]()
        if not self._overwrite and Bool(base.main_snapshot_id):
            entries = self._base_manifests(base)
        if len(self._data_files) > 0 and not Bool(self._manifest):
            self._write_manifest(snapshot_id)
        if Bool(self._manifest):
            entries.append(self._manifest.value().copy())
        var bytes = build_manifest_list(snapshot_id, sequence_number, entries)
        var uri = (
            self._metadata_path
            + String("/snap-")
            + String(snapshot_id)
            + String("-")
            + String(attempt)
            + String("-")
            + self._statement_uuid
            + String(".avro")
        )
        self.written.append(uri)
        self._files.put(uri, bytes)
        return uri

    def _write_manifest(mut self, snapshot_id: Int64) raises:
        var bytes = build_data_manifest(
            self._schema_json, self._schema_id, snapshot_id, self._data_files
        )
        var uri = (
            self._metadata_path
            + String("/")
            + self._statement_uuid
            + String("-m0.avro")
        )
        self.manifest_uri = String(uri)
        self.written.append(String(uri))
        self._files.put(uri, bytes)
        var rows = Int64(0)
        for i in range(len(self._data_files)):
            rows += Int64(self._data_files[i].record_count)
        self._manifest = Optional[ManifestFileEntry](
            ManifestFileEntry(
                String(uri),
                len(bytes),
                len(self._data_files),
                rows,
                ICE_MANIFEST_CONTENT_DATA,
                ICE_SEQ_INHERIT,
                snapshot_id,
                0,
            )
        )

    def _base_manifests(
        self, base: TableMetadata
    ) raises -> List[ManifestFileEntry]:
        """The manifests of the list `main`'s snapshot names in `base`."""
        var main_id = base.main_snapshot_id.value()
        var i = base.snapshot_index(main_id)
        if i < 0:
            raise Error(
                String(ICEBERG_CATALOG_RESPONSE_INVALID)
                + String(": table metadata names main snapshot ")
                + String(main_id)
                + String(" but does not list it")
            )
        var uri = String(base.snapshots[i].manifest_list)
        var bytes = self._files.get(uri)
        if not is_komira_manifest_list(bytes):
            raise Error(
                String(ICEBERG_MANIFEST_LIST_UNSUPPORTED)
                + String(": manifest list ")
                + uri
                + String(" of snapshot ")
                + String(main_id)
                + String(
                    " was not written by komira; this write appends only to"
                    " manifest lists it wrote"
                )
            )
        return read_manifest_list(bytes)
