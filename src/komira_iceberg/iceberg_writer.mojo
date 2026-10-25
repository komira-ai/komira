# =============================================================================
# iceberg_writer.mojo — the file-based Iceberg v2 table writer + atomic commit.
# =============================================================================
#
# Exposes a set of Parquet data files as a READABLE Apache Iceberg v2 table
# written ENTIRELY in the object store, with NO service. Any Iceberg engine
# reads the table by pointing at the bucket; commits are atomic and serverless
# through the object store's create-if-absent write.
#
# THE LAYOUT (the file-based "Hadoop table" convention that pyiceberg's
# StaticTable and DuckDB's iceberg_scan read without any catalog service):
#
#   <location>/
#     data/
#       <data files written by the caller>.parquet
#     metadata/
#       v<N>.metadata.json                 # the table metadata, version N
#       version-hint.text                  # ascii "<N>": the latest version
#       <uuid>-m0.avro                      # manifest file (lists data files)
#       <uuid>-mdel.avro                    # manifest file (lists delete files)
#       snap-<snapshot-id>-1-<uuid>.avro    # manifest list (lists manifests)
#
# THE COMMIT (atomic, serverless):
#   1. write the data Parquet file(s)            (caller does this; passes infos)
#   2. write the manifest file(s) (Avro)         create-if-absent, uuid-named
#   3. write the manifest list (Avro)            create-if-absent, uuid-named
#   4. CREATE v<N+1>.metadata.json               create-if-absent: THE COMMIT
#   5. move version-hint.text to N+1             compare-and-swap, best effort
#
# Step 4 is the linearization point. `v<N+1>.metadata.json` is created with
# create-if-absent, so exactly one writer ever owns version N+1; a loser gets a
# precondition error, which `commit` raises as a commit conflict (re-read and
# retry against N+1). Everything the file points at was written first, so the
# table is complete the moment it exists. The hint (step 5) is a convenience for
# readers: `current_version` reads it and then steps over every higher metadata
# file, so a writer that stopped between 4 and 5 has still committed, and the
# next writer or reader sees it.
#
# The hint is moved with compare-and-swap from the etag read BEFORE the version
# was read, and never moved backwards: if the swap loses, the hint is re-read and
# the commit stands when it already names this version or a later one.
#
# Generic over `[Store: ConditionalWriteStore]` so the IDENTICAL code runs on the
# in-memory / local-fs conformers (local verify + acceptance test) and on
# S3/GCS/Azure, unchanged.
#
# Encapsulation: the store is taken by value (the conformers are cheap handles);
# every byte buffer is an owned `List[UInt8]`; ZERO UnsafePointer in any
# signature; ZERO wildcard origins; the Parquet/Avro byte production is
# delegated to the already-encapsulated writers.
# =============================================================================

from komira_clock.clock import now_unix_ms

from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from .iceberg_types import (
    IcebergSchema,
    DataFileInfo,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    ICE_DATA_CONTENT_POSITION_DELETES,
)
from .iceberg_metadata_json import (
    SnapshotInfo,
    SummaryKV,
    schema_json,
    partition_spec_fields_json,
    delete_spec_of,
    build_table_metadata_json,
)
from .iceberg_json_scan import bare_int64_field, bytes_to_str
from .iceberg_partition import PartitionSpec
from .iceberg_avro_manifest import (
    ManifestFileEntry,
    ICE_MANIFEST_CONTENT_DATA,
    ICE_MANIFEST_CONTENT_DELETES,
    build_manifest_file,
    build_manifest_list,
)
from .iceberg_avro_manifest_read import read_manifest_list
from .iceberg_row_value import RowCell
from .iceberg_reader import read_live_rows_from, parse_partition_spec_from_metadata
from .iceberg_summary import read_current_snapshot_summary
from .iceberg_version import (
    current_version,
    metadata_dir,
    metadata_json_key,
    pointer_key,
    read_hint_version,
)
from .iceberg_writer_state import (
    PriorState,
    gen_snapshot_id,
    gen_table_uuid,
    parse_prior_state,
)


def _is_reserved_summary_key(key: String) -> Bool:
    """The summary keys a commit writes itself: a caller's `extra_summary` may
    not name one (a duplicate key in the summary object is ambiguous to a
    reader)."""
    return (
        key == String("operation")
        or key == String("added-data-files")
        or key == String("added-records")
        or key == String("total-data-files")
        or key == String("total-records")
        or key == String("added-files-size")
        or key == String("added-delete-files")
        or key == String("added-equality-delete-files")
        or key == String("added-position-delete-files")
        or key == String("added-equality-deletes")
        or key == String("added-position-deletes")
    )


# =============================================================================
# CommitResult — what a commit produced (object keys + the new version).
# =============================================================================


@fieldwise_init
struct IcebergCommitResult(Copyable, Movable, Deinitable):
    """The outcome of a `commit_append`.

    Fields:
      var version: Int                — the new metadata version number.
      var snapshot_id: Int64          — the snapshot this commit created.
      var sequence_number: Int64      — the v2 sequence number.
      var metadata_json_key: String   — object key of v<N>.metadata.json.
      var manifest_list_key: String   — object key of the manifest list.
      var manifest_key: String        — object key of the manifest file.
      var pointer_key: String         — object key of version-hint.text.
    """

    var version: Int
    var snapshot_id: Int64
    var sequence_number: Int64
    var metadata_json_key: String
    var manifest_list_key: String
    var manifest_key: String
    var pointer_key: String


def _bytes_of(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _col_index_of_field_id(schema: IcebergSchema, field_id: Int) raises -> Int:
    """Column index of `field_id` in `schema` (the nullable-key guard)."""
    for i in range(len(schema.fields)):
        if schema.fields[i].field_id == field_id:
            return i
    raise Error(
        "iceberg commit: equality-delete field-id "
        + String(field_id)
        + " not in the table schema"
    )


# =============================================================================
# IcebergTableWriter — orchestrates a v2 commit over a ConditionalWriteStore.
# =============================================================================


struct IcebergTableWriter[Store: ConditionalWriteStore](Movable):
    """File-based Iceberg v2 table writer over a conditional-write object store.

    Construct with a store + the table's `location` (the object-key PREFIX the
    table lives under, e.g. `"warehouse/db/tbl"`) + the schema + a stable
    table uuid (`gen_table_uuid()` makes one). Then call `commit_append(data_files)`
    once per batch of already-written Parquet data files; each call appends a
    snapshot as the next metadata version, atomically.

    The writer holds the `Store` BY VALUE (the conformers are cheap handles:
    InMemory / LocalFs / S3 all clone to a fresh handle on the same backing
    store).
    """

    var _store: Self.Store
    var _location: String
    var _schema: IcebergSchema
    var _table_uuid: String

    def __init__(
        out self,
        var store: Self.Store,
        var location: String,
        var schema: IcebergSchema,
        var table_uuid: String,
    ):
        self._store = store^
        self._location = location^
        self._schema = schema^
        self._table_uuid = table_uuid^

    @always_inline
    def data_dir(self) -> String:
        """The directory (object-key prefix) data files should be written to.

        The caller writes Parquet files under here and passes their full keys
        in `DataFileInfo.file_path`."""
        return self._location + "/data"

    @always_inline
    def location(self) -> String:
        return String(self._location)

    @always_inline
    def schema(self) -> IcebergSchema:
        return self._schema.copy()

    def set_schema(mut self, var schema: IcebergSchema):
        """Rebind the writer's schema (schema EVOLUTION — e.g. after
        `evolve_add_column`). The NEXT commit's metadata.json records the new
        schema as the current one and keeps every earlier schema in `schemas`,
        so a snapshot written under an older schema still names a schema the
        table holds. Data files committed after this carry the new column, and
        OLD data files (written under the prior, narrower schema) null-fill the
        added column at read. Add-column keeps existing field-ids STABLE, so the
        carried-forward manifests and files still bind correctly."""
        self._schema = schema^

    # -------------------------------------------------------------------------
    # Public object I/O passthroughs (so callers + tests stage data files and
    # enumerate the table WITHOUT reaching into the private store field).
    # -------------------------------------------------------------------------

    def put_object(mut self, key: String, var bytes: List[UInt8]) raises:
        """Unconditional PUT of `bytes` at object `key` (e.g. a data file the
        caller produced). The caller passes the same key in
        `DataFileInfo.file_path`."""
        _ = self._store.put(Path.parse(key), bytes^)

    def get_object(self, key: String) raises -> List[UInt8]:
        """Full-object fetch (recovery / verification / materialization)."""
        return self._store.get(Path.parse(key))

    def list_object_keys(self, prefix: String) raises -> List[String]:
        """List every object key under `prefix` (for table materialization /
        discovery)."""
        var listing = self._store.list_with_delimiter(Path.parse(prefix))
        var keys = List[String]()
        for i in range(len(listing.objects)):
            keys.append(String(listing.objects[i].location))
        return keys^

    # -------------------------------------------------------------------------
    # Merge-on-read convenience (reads through the writer's own store handle).
    # -------------------------------------------------------------------------

    def read_live_rows(mut self) raises -> List[List[RowCell]]:
        """Return the CURRENT snapshot's LIVE rows (all delete files honored),
        reading through this writer's OWN store handle.

        A convenience so callers/tests that just committed can read back without
        constructing a separate store handle. Delegates to the shared
        `read_live_rows_from` merge-on-read core."""
        return read_live_rows_from(self._store, self._location, self._schema)

    def read_current_summary(mut self) raises -> List[SummaryKV]:
        """Return the CURRENT snapshot's `summary` map (every KV: the count
        metrics AND any stamped position KVs), reading through this writer's OWN
        store handle. An empty list if the table has never been committed (cold
        start). Symmetric with `read_live_rows`: an ingest driver uses it to
        derive the per-shard resume point from the committed table."""
        return read_current_snapshot_summary(self._store, self._location)

    # -------------------------------------------------------------------------
    # The commit.
    # -------------------------------------------------------------------------

    def commit_append(
        mut self, var data_files: List[DataFileInfo]
    ) raises -> IcebergCommitResult:
        """Append a snapshot referencing `data_files`. Thin wrapper over
        `commit(data_files, deletes=[])`: the append path is the no-deletes case
        of the general commit, so there is ONE commit implementation."""
        return self.commit(data_files^, List[DataFileInfo]())

    def commit(
        mut self,
        var data_files: List[DataFileInfo],
        var delete_files: List[DataFileInfo],
    ) raises -> IcebergCommitResult:
        """Commit a snapshot over the table's DEFAULT (unpartitioned) spec.

        Thin wrapper over `commit_with_spec(..., PartitionSpec(0))`. See
        `commit_with_spec_and_summary` for the full contract."""
        return self.commit_with_spec(
            data_files^, delete_files^, PartitionSpec(0)
        )

    def commit_with_summary(
        mut self,
        var data_files: List[DataFileInfo],
        var delete_files: List[DataFileInfo],
        extra_summary: List[SummaryKV],
    ) raises -> IcebergCommitResult:
        """Commit a snapshot over the DEFAULT (unpartitioned) spec, STAMPING
        `extra_summary` KV entries into the new snapshot's `summary` map.

        An ingest process uses this to write the last-applied per-shard stream
        position INTO the summary so the resume point rides the SAME atomic
        commit as the data (no separate checkpoint store). The KVs are recovered
        on startup via `read_current_snapshot_summary`."""
        return self.commit_with_spec_and_summary(
            data_files^, delete_files^, PartitionSpec(0), extra_summary
        )

    def commit_with_spec(
        mut self,
        var data_files: List[DataFileInfo],
        var delete_files: List[DataFileInfo],
        var spec: PartitionSpec,
    ) raises -> IcebergCommitResult:
        """Commit under `spec` with NO extra summary entries. See
        `commit_with_spec_and_summary`."""
        return self.commit_with_spec_and_summary(
            data_files^, delete_files^, spec^, List[SummaryKV]()
        )

    def commit_with_spec_and_summary(
        mut self,
        var data_files: List[DataFileInfo],
        var delete_files: List[DataFileInfo],
        var spec: PartitionSpec,
        extra_summary: List[SummaryKV],
    ) raises -> IcebergCommitResult:
        """Commit a snapshot referencing `data_files` (content=0) AND
        `delete_files` (content=1 position / 2 equality) under partition `spec`,
        STAMPING `extra_summary` into the snapshot summary.

        Reads the current version and (if any) the prior snapshots from the
        current metadata.json, writes a DATA manifest (if any data files) + a
        DELETE manifest (if any delete files), carries forward EVERY parent
        manifest (both data and delete), builds the new manifest list and
        metadata.json, and creates `v<N+1>.metadata.json` with create-if-absent:
        the commit. Then it moves the version hint (see the module header).

        `spec` drives the DATA manifest's `r102` partition record and the
        metadata.json `partition-specs` / `default-spec-id`. A table keeps ONE
        spec: a commit under a different spec than the table's raises. Each data
        file's own `partition_avro` tuple (from `DataFileInfo.with_partition`) is
        recorded in its manifest entry. DELETE files carry no partition: they
        are global deletes, so their manifest is written under the unpartitioned
        spec `delete_spec_of(spec)`.

        Delete files' sequence numbers are STAMPED by THIS commit: every delete
        file's `sequence_number` is set to this commit's sequence number
        (== the new version) before the delete manifest is built; the caller
        does NOT supply a delete seq (a stale caller seq could silently mask the
        wrong data generation). A reader orders deletes against data-file
        generations by it (an equality delete masks ONLY data files with a
        STRICTLY LOWER sequence number; a position delete masks its OWN and
        lower).

        An equality delete whose equality key is on a NULLABLE column is
        REJECTED: null equality-key semantics (IS-NOT-DISTINCT-FROM) are not
        implemented in the merge predicate, so admitting one would silently
        mis-mask NULL-bearing rows.

        The snapshot's `operation` is `append` (data files only), `delete`
        (delete files only) or `overwrite` (both). Its summary also carries
        `added-files-size` and, when there are delete files, the
        `added-delete-files`, `added-equality-delete-files`,
        `added-position-delete-files`, `added-equality-deletes` and
        `added-position-deletes` counts. `extra_summary` may not use these or
        the count keys.

        Raises an `iceberg commit conflict` error when another writer created
        the next version first: re-read the table and retry."""
        for si in range(len(extra_summary)):
            if _is_reserved_summary_key(extra_summary[si].key):
                raise Error(
                    "iceberg commit: extra summary key '"
                    + extra_summary[si].key
                    + "' is written by the commit itself"
                )

        # The hint's etag is read BEFORE the version, so the swap at the end can
        # only succeed if nobody moved the hint since.
        var hint_etag = self._hint_etag()
        var cur_version = current_version(self._store, self._location)
        var new_version = cur_version + 1

        # Load prior snapshots from the current metadata (cumulative totals,
        # snapshot history, parent linkage, earlier schemas). Empty for the
        # first commit.
        var prior = PriorState()
        if cur_version > 0:
            var prior_json = bytes_to_str(
                self._store.get(
                    Path.parse(metadata_json_key(self._location, cur_version))
                )
            )
            prior = parse_prior_state(prior_json)
            self._check_spec_unchanged(prior_json, spec)

        var snapshot_id = gen_snapshot_id()
        var sequence_number = Int64(new_version)  # v2 seq monotone with version
        var now_ms = now_unix_ms()

        # ---- delete-file validation + sequence stamping ----
        var equality_delete_files = 0
        var position_delete_files = 0
        var equality_deletes = Int64(0)
        var position_deletes = Int64(0)
        for di in range(len(delete_files)):
            if delete_files[di].content == ICE_DATA_CONTENT_EQUALITY_DELETES:
                equality_delete_files += 1
                equality_deletes += Int64(delete_files[di].record_count)
                for ki in range(len(delete_files[di].equality_ids)):
                    var fid = delete_files[di].equality_ids[ki]
                    var ci = _col_index_of_field_id(self._schema, fid)
                    if not self._schema.fields[ci].required:
                        raise Error(
                            "iceberg commit: equality-delete key on NULLABLE"
                            " column '"
                            + self._schema.fields[ci].name
                            + "' (field-id "
                            + String(fid)
                            + ") is rejected: null equality-key semantics"
                            " (IS-NOT-DISTINCT-FROM) are not implemented;"
                            " declare the equality key column as required"
                        )
            elif delete_files[di].content == ICE_DATA_CONTENT_POSITION_DELETES:
                position_delete_files += 1
                position_deletes += Int64(delete_files[di].record_count)
            delete_files[di].sequence_number = sequence_number

        var sj = schema_json(self._schema)
        var meta_dir = metadata_dir(self._location)

        # ---- 1. manifest list carry-forward ----
        # An Iceberg snapshot's manifest list is the COMPLETE set of live
        # manifests, not just the delta, so carry forward EVERY manifest (data
        # AND delete) from the parent snapshot, each keeping the snapshot and
        # sequence number it was written under, then append this commit's new
        # manifest(s). Without this a reader at the new snapshot would see ONLY
        # the new files (silent loss of prior commits' rows AND prior deletes,
        # which would RESURRECT deleted rows).
        var mlist_entries = List[ManifestFileEntry]()
        if cur_version > 0 and len(prior.snapshots) > 0:
            ref parent = prior.snapshots[len(prior.snapshots) - 1]
            var parent_list_bytes = self._store.get(
                Path.parse(parent.manifest_list)
            )
            var carried = read_manifest_list(parent_list_bytes)
            for ci in range(len(carried)):
                mlist_entries.append(carried[ci].copy())

        # ---- 2. DATA manifest (Avro) for this commit's data files ----
        var data_manifest_key = String("")
        var added_data_files = len(data_files)
        var added_records = Int64(0)
        var added_files_size = Int64(0)
        for i in range(len(data_files)):
            added_records += Int64(data_files[i].record_count)
            added_files_size += Int64(data_files[i].file_size_in_bytes)
        if added_data_files > 0:
            var manifest_bytes = build_manifest_file(
                self._schema,
                sj,
                snapshot_id,
                sequence_number,
                data_files,
                ICE_MANIFEST_CONTENT_DATA,
                spec,  # DATA manifest carries the partition r102 record
            )
            var data_manifest_len = len(manifest_bytes)
            data_manifest_key = meta_dir + "/" + gen_table_uuid() + "-m0.avro"
            self._put_new(data_manifest_key, manifest_bytes^)
            mlist_entries.append(
                ManifestFileEntry(
                    String(data_manifest_key),
                    data_manifest_len,
                    added_data_files,
                    added_records,
                    ICE_MANIFEST_CONTENT_DATA,
                    sequence_number,
                    snapshot_id,
                    spec.spec_id,
                )
            )

        # ---- 3. DELETE manifest (Avro) for this commit's delete files ----
        var delete_manifest_key = String("")
        var added_delete_files = len(delete_files)
        var added_delete_records = Int64(0)
        for i in range(len(delete_files)):
            added_delete_records += Int64(delete_files[i].record_count)
        if added_delete_files > 0:
            var delete_spec = delete_spec_of(spec)
            var del_manifest_bytes = build_manifest_file(
                self._schema,
                sj,
                snapshot_id,
                sequence_number,
                delete_files,
                ICE_MANIFEST_CONTENT_DELETES,
                delete_spec,
            )
            var del_manifest_len = len(del_manifest_bytes)
            delete_manifest_key = (
                meta_dir + "/" + gen_table_uuid() + "-mdel.avro"
            )
            self._put_new(delete_manifest_key, del_manifest_bytes^)
            mlist_entries.append(
                ManifestFileEntry(
                    String(delete_manifest_key),
                    del_manifest_len,
                    added_delete_files,
                    added_delete_records,
                    ICE_MANIFEST_CONTENT_DELETES,
                    sequence_number,
                    snapshot_id,
                    delete_spec.spec_id,
                )
            )

        # ---- 4. manifest list (Avro) ----
        var mlist_bytes = build_manifest_list(
            snapshot_id, sequence_number, mlist_entries
        )
        var manifest_list_key = (
            meta_dir
            + "/snap-"
            + String(snapshot_id)
            + "-1-"
            + gen_table_uuid()
            + ".avro"
        )
        self._put_new(manifest_list_key, mlist_bytes^)

        # ---- 5. metadata.json (v<N+1>): THE COMMIT ----
        var snapshots = prior.snapshots.copy()
        var parent_id = Int64(-1)
        if len(snapshots) > 0:
            parent_id = snapshots[len(snapshots) - 1].snapshot_id
        var total_files = prior.total_files + added_data_files
        var total_records = prior.total_records + added_records

        var snap_extra = List[SummaryKV]()
        if added_files_size > Int64(0):
            snap_extra.append(
                SummaryKV(
                    String("added-files-size"), String(added_files_size)
                )
            )
        if added_delete_files > 0:
            snap_extra.append(
                SummaryKV(
                    String("added-delete-files"), String(added_delete_files)
                )
            )
            snap_extra.append(
                SummaryKV(
                    String("added-equality-delete-files"),
                    String(equality_delete_files),
                )
            )
            snap_extra.append(
                SummaryKV(
                    String("added-position-delete-files"),
                    String(position_delete_files),
                )
            )
            snap_extra.append(
                SummaryKV(
                    String("added-equality-deletes"), String(equality_deletes)
                )
            )
            snap_extra.append(
                SummaryKV(
                    String("added-position-deletes"), String(position_deletes)
                )
            )
        for si in range(len(extra_summary)):
            snap_extra.append(extra_summary[si].copy())
        var operation = String("append")
        if added_delete_files > 0:
            operation = String("overwrite") if added_data_files > 0 else String(
                "delete"
            )
        snapshots.append(
            SnapshotInfo(
                snapshot_id,
                sequence_number,
                now_ms,
                String(manifest_list_key),
                added_data_files,
                added_records,
                total_files,
                total_records,
                self._schema.schema_id,
                parent_id,
                snap_extra^,
                operation^,
            )
        )
        # Schemas an earlier snapshot was written with stay in `schemas`; the
        # current one is written last by the builder.
        var prior_schemas = List[String]()
        for i in range(len(prior.schemas)):
            if (
                Int(bare_int64_field(prior.schemas[i], "schema-id"))
                != self._schema.schema_id
            ):
                prior_schemas.append(String(prior.schemas[i]))
        var meta_json = build_table_metadata_json(
            self._table_uuid,
            self._location,
            self._schema,
            snapshots,
            snapshot_id,  # current-snapshot-id
            sequence_number,  # last-sequence-number
            now_ms,  # last-updated-ms
            spec,  # partition-specs + default-spec-id + last-partition-id
            prior_schemas^,
        )
        var meta_key = metadata_json_key(self._location, new_version)
        self._create_version(meta_key, new_version, _bytes_of(meta_json))

        # ---- 6. move the version hint (a convenience: the commit is done) ----
        self._advance_hint(hint_etag, new_version)

        # The `manifest_key` reported is the data manifest when present, else
        # the delete manifest (a delete-only commit).
        var reported_manifest = (
            data_manifest_key if added_data_files
            > 0 else delete_manifest_key
        )
        return IcebergCommitResult(
            new_version,
            snapshot_id,
            sequence_number,
            String(meta_key),
            String(manifest_list_key),
            reported_manifest,
            pointer_key(self._location),
        )

    # -------------------------------------------------------------------------
    # Store helpers.
    # -------------------------------------------------------------------------

    def _put_new(mut self, key: String, var bytes: List[UInt8]) raises:
        """Create-if-absent PUT of a uuid-named file. It raises when the object
        exists: a collision of two uuids is not a case to paper over."""
        _ = self._store.conditional_put(
            Path.parse(key), bytes^, WritePrecondition.if_none_match_star()
        )

    def _create_version(
        mut self, key: String, version: Int, var bytes: List[UInt8]
    ) raises:
        """Create `v<version>.metadata.json` with create-if-absent: the commit.

        A lost create means another writer owns this version. It is a commit
        conflict whatever bytes the other file holds (two writers never build
        the same snapshot), so it is raised, never tolerated."""
        try:
            _ = self._store.conditional_put(
                Path.parse(key), bytes^, WritePrecondition.if_none_match_star()
            )
        except e:
            if is_precondition(String(e)):
                raise Error(
                    "iceberg commit conflict: metadata version "
                    + String(version)
                    + " of '"
                    + self._location
                    + "' was created by another writer; re-read the table and"
                    " retry"
                )
            raise e^

    def _hint_etag(self) raises -> Optional[String]:
        """The etag of version-hint.text, or None when it does not exist (a
        proven absence only)."""
        try:
            var meta = self._store.head(Path.parse(pointer_key(self._location)))
            return Optional[String](String(meta.etag))
        except e:
            if is_not_found(String(e)):
                return None
            raise e^

    def _advance_hint(
        mut self, hint_etag: Optional[String], new_version: Int
    ) raises:
        """Move version-hint.text to `new_version`.

        The hint does not decide the commit (`v<new_version>.metadata.json`
        already exists) and is never moved backwards: when the swap loses, the
        hint is re-read, and a hint that already names this version or a later
        one ends it. An absent hint is created with create-if-absent; otherwise
        it is swapped from the etag read before the version was."""
        var ptr = Path.parse(pointer_key(self._location))
        var etag = hint_etag.copy()
        var attempts = 0
        while True:
            try:
                if etag:
                    _ = self._store.compare_and_swap(
                        ptr, _bytes_of(String(new_version)), etag.value()
                    )
                else:
                    _ = self._store.conditional_put(
                        ptr,
                        _bytes_of(String(new_version)),
                        WritePrecondition.if_none_match_star(),
                    )
                return
            except e:
                if not is_precondition(String(e)):
                    raise Error(
                        "iceberg commit: version "
                        + String(new_version)
                        + " is committed but the version hint was not updated: "
                        + String(e)
                    )
            attempts += 1
            if read_hint_version(self._store, self._location) >= new_version:
                return
            if attempts >= 3:
                raise Error(
                    "iceberg commit: version "
                    + String(new_version)
                    + " is committed but the version hint kept changing"
                )
            etag = self._hint_etag()

    def _check_spec_unchanged(
        self, prior_json: String, spec: PartitionSpec
    ) raises:
        """A table keeps one partition spec: older manifests were written under
        it and the reader decodes them with the table's current spec."""
        var prior_spec = parse_partition_spec_from_metadata(prior_json)
        if partition_spec_fields_json(prior_spec) != partition_spec_fields_json(
            spec
        ) or prior_spec.spec_id != spec.spec_id:
            raise Error(
                "iceberg commit: the partition spec of '"
                + self._location
                + "' cannot change ("
                + partition_spec_fields_json(prior_spec)
                + " -> "
                + partition_spec_fields_json(spec)
                + ")"
            )
