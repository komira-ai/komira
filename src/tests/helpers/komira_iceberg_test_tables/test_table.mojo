# =============================================================================
# test_table.mojo -- TestTable: a version-2 Iceberg table written to a local
# directory the way Iceberg Java lays one out.
# =============================================================================
#
#   <root>/metadata/v<N>.metadata.json     one per commit (and per `create`)
#   <root>/metadata/version-hint.text      N, no newline
#   <root>/metadata/snap-<id>-1-<uuid>.avro        the manifest list of a snapshot
#   <root>/metadata/<uuid>-m0.avro                 the manifests
#   <root>/data/<col>=<value>/<name>.parquet       data and delete files
#
# Every path the manifests record is `<location>/<path under root>`: an
# absolute `file:` URI under the table's recorded location, which need not be
# where the files are (a test moves the table; `allow_moved_paths` finds it).
#
# Each commit adds a snapshot (id `SNAPSHOT_ID_BASE + n`, sequence number n)
# whose manifest list names the new manifests first and then the manifests of
# the snapshot before, as Java does:
#
#   append               a manifest of the new data files, status ADDED
#   add_position_deletes a manifest of one position-delete file
#   add_equality_deletes a manifest of one equality-delete file
#   overwrite            the manifests holding a removed file are rewritten
#                        (the file DELETED, its neighbours EXISTING), then a
#                        manifest of the added files
#
# Partitioning is identity, by columns named at construction. Names are the
# caller's: a file called `a1` lives at `data/<partition>/a1.parquet`, and a
# position delete names a data file by that `name`.
# =============================================================================

from .avro_manifests import manifest_file_bytes, manifest_list_bytes
from .data_files import (
    avro_file_bytes,
    parquet_file_bytes,
    write_file_bytes,
    write_file_text,
)
from .metrics import bytes_less, file_metrics
from .table_metadata import table_metadata_json, timestamp_ms
from .table_model import (
    CONTENT_DATA,
    CONTENT_EQUALITY_DELETES,
    CONTENT_POSITION_DELETES,
    FORMAT_AVRO,
    FORMAT_PARQUET,
    SNAPSHOT_ID_BASE,
    STATUS_ADDED,
    STATUS_DELETED,
    STATUS_EXISTING,
    TT_LONG,
    TT_STRING,
    ColumnMetrics,
    ManifestEntryRecord,
    ManifestRecord,
    SnapshotRecord,
    TableCell,
    TableColumn,
    TableFileRecord,
    TableRow,
)


@fieldwise_init
struct TestDataFile(Copyable, Movable):
    """A data file to write: its `name`, its partition tuple (one cell per
    partition column, in the order the table was given them; empty for an
    unpartitioned table) and its rows (a cell per table column)."""

    var name: String
    var partition: List[TableCell]
    var rows: List[TableRow]


@fieldwise_init
struct PositionDelete(Copyable, Movable):
    """The row at `position` (from 0) of the data file called `data_file`."""

    var data_file: String
    var position: Int


def _uuid(n: Int) -> String:
    """A fixed, well-formed UUID text for file number `n`."""
    var digits = String(n)
    var padded = String()
    for _ in range(12 - digits.byte_length()):
        padded += "0"
    return String("a1b2c3d4-0000-4000-8000-") + padded + digits


struct TestTable(Movable):
    var root: String
    var location: String
    var columns: List[TableColumn]
    var partition_columns: List[TableColumn]
    var files: List[TableFileRecord]
    var manifests: List[ManifestRecord]
    var snapshots: List[SnapshotRecord]
    var version: Int
    var manifest_count: Int

    def __init__(
        out self,
        var root: String,
        var location: String,
        var columns: List[TableColumn],
        partition_by: List[String] = List[String](),
    ) raises:
        """A table whose files go under the local directory `root` and whose
        manifests record paths under `location` (no trailing `/`),
        partitioned by the identity of the columns named in `partition_by`
        (long, int, date or string columns)."""
        var partition_columns = List[TableColumn]()
        for p in range(len(partition_by)):
            var found = False
            for c in range(len(columns)):
                if columns[c].name == partition_by[p]:
                    partition_columns.append(columns[c].copy())
                    found = True
            if not found:
                raise Error(
                    "TestTable: the partition column " + partition_by[p]
                    + " is not a column of the table"
                )
        self.partition_columns = partition_columns^
        self.root = root^
        self.location = location^
        self.columns = columns^
        self.files = List[TableFileRecord]()
        self.manifests = List[ManifestRecord]()
        self.snapshots = List[SnapshotRecord]()
        self.version = 0
        self.manifest_count = 0

    def snapshot_id(self, commit: Int) -> Int64:
        """The id of the snapshot of commit number `commit` (from 1)."""
        return Int64(SNAPSHOT_ID_BASE + commit)

    def create(mut self) raises:
        """Writes the metadata of a table with no snapshot (version 1 when
        called first)."""
        self._write_metadata()

    def append(mut self, data_files: List[TestDataFile]) raises -> Int64:
        """Commits `data_files` as an append; returns the snapshot id."""
        if len(data_files) == 0:
            raise Error("TestTable.append: no data file")
        var seq = Int64(len(self.snapshots) + 1)
        var snap = self.snapshot_id(len(self.snapshots) + 1)
        var records = Int64(0)
        var entries = List[ManifestEntryRecord]()
        for i in range(len(data_files)):
            entries.append(self._add_data_file(data_files[i], snap, seq))
            records += Int64(len(data_files[i].rows))
        var added = self._write_manifest(CONTENT_DATA, seq, seq, snap, entries^)
        var listed = List[ManifestRecord]()
        listed.append(added^)
        for k in range(len(self.manifests)):
            listed.append(self.manifests[k].copy())
        self._commit(listed^, seq, snap, "append", len(data_files), 0, records)
        return snap

    def add_position_deletes(
        mut self,
        name: String,
        partition: List[TableCell],
        deletes: List[PositionDelete],
        file_format: String = FORMAT_PARQUET,
        referenced: Bool = False,
    ) raises -> Int64:
        """Commits one position-delete file `name` holding `deletes` (sorted
        by data file path, then position, as the spec asks). With `referenced`
        the entry records the one data file the deletes name, which must be
        only one."""
        if len(deletes) == 0:
            raise Error("TestTable.add_position_deletes: no delete")
        var paths = List[String]()
        for d in range(len(deletes)):
            paths.append(self._data_file_uri(deletes[d].data_file))
        var order = List[Int]()
        for d in range(len(deletes)):
            var at = len(order)
            while at > 0 and self._delete_before(paths, deletes, d, order[at - 1]):
                at -= 1
            order.insert(at, d)
        var rows = List[TableRow]()
        for o in range(len(order)):
            var cells = List[TableCell]()
            cells.append(TableCell(False, Int64(0), Float64(0.0), paths[order[o]].copy()))
            cells.append(TableCell(False, Int64(deletes[order[o]].position), Float64(0.0), String("")))
            rows.append(TableRow(cells^))
        var delete_columns = List[TableColumn]()
        delete_columns.append(TableColumn(2147483546, "file_path", TT_STRING, True))
        delete_columns.append(TableColumn(2147483545, "pos", TT_LONG, True))
        var only = String()
        if referenced:
            only = paths[0].copy()
            for d in range(len(paths)):
                if paths[d] != only:
                    raise Error(
                        "TestTable.add_position_deletes: referenced needs "
                        "deletes of one data file"
                    )
        return self._commit_delete_file(
            name, partition, delete_columns, rows, CONTENT_POSITION_DELETES,
            file_format, List[Int](), only,
        )

    def add_equality_deletes(
        mut self,
        name: String,
        partition: List[TableCell],
        equality_columns: List[String],
        rows: List[TableRow],
        file_format: String = FORMAT_PARQUET,
    ) raises -> Int64:
        """Commits one equality-delete file `name` of the table columns
        `equality_columns`, holding `rows` (a cell per equality column)."""
        if len(equality_columns) == 0 or len(rows) == 0:
            raise Error("TestTable.add_equality_deletes: no column or no row")
        var delete_columns = List[TableColumn]()
        var ids = List[Int]()
        for e in range(len(equality_columns)):
            var found = False
            for c in range(len(self.columns)):
                if self.columns[c].name == equality_columns[e]:
                    delete_columns.append(self.columns[c].copy())
                    ids.append(self.columns[c].id)
                    found = True
            if not found:
                raise Error(
                    "TestTable.add_equality_deletes: " + equality_columns[e]
                    + " is not a column of the table"
                )
        return self._commit_delete_file(
            name, partition, delete_columns, rows, CONTENT_EQUALITY_DELETES,
            file_format, ids, String(""),
        )

    def overwrite(
        mut self, removed: List[String], added: List[TestDataFile]
    ) raises -> Int64:
        """Commits the removal of the live data files called `removed` and the
        addition of `added`: each manifest holding a removed file is
        rewritten, the file DELETED and every other live entry EXISTING."""
        for r in range(len(removed)):
            if not self._is_live_data_file(removed[r]):
                raise Error(
                    "TestTable.overwrite: " + removed[r]
                    + " is not a live data file of the table"
                )
        var seq = Int64(len(self.snapshots) + 1)
        var snap = self.snapshot_id(len(self.snapshots) + 1)
        var kept = List[ManifestRecord]()
        for k in range(len(self.manifests)):
            var old = self.manifests[k].copy()
            if not self._holds_removed(old, removed):
                kept.append(old^)
                continue
            var entries = List[ManifestEntryRecord]()
            var lowest = Int64(-1)
            for e in range(len(old.entries)):
                ref entry = old.entries[e]
                if entry.status == STATUS_DELETED:
                    continue
                if self._is_removed(entry, removed):
                    entries.append(
                        ManifestEntryRecord(STATUS_DELETED, entry.file_index, snap, entry.data_seq)
                    )
                else:
                    entries.append(
                        ManifestEntryRecord(STATUS_EXISTING, entry.file_index, entry.snapshot_id, entry.data_seq)
                    )
                    if lowest < 0 or entry.data_seq < lowest:
                        lowest = entry.data_seq
            if lowest < 0:
                lowest = seq
            kept.append(self._write_manifest(CONTENT_DATA, seq, lowest, snap, entries^))
        var listed = List[ManifestRecord]()
        var records = Int64(0)
        if len(added) > 0:
            var entries = List[ManifestEntryRecord]()
            for i in range(len(added)):
                entries.append(self._add_data_file(added[i], snap, seq))
                records += Int64(len(added[i].rows))
            listed.append(self._write_manifest(CONTENT_DATA, seq, seq, snap, entries^))
        for k in range(len(kept)):
            listed.append(kept[k].copy())
        self._commit(listed^, seq, snap, "overwrite", len(added), 0, records)
        return snap

    # ---- internals ---------------------------------------------------------

    def _data_file_uri(self, name: String) raises -> String:
        for f in range(len(self.files)):
            if self.files[f].content == CONTENT_DATA and self.files[f].name == name:
                return self.files[f].uri.copy()
        raise Error("TestTable: no data file called " + name)

    def _delete_before(
        self, paths: List[String], deletes: List[PositionDelete], a: Int, b: Int
    ) -> Bool:
        """Whether delete `a` sorts before delete `b`."""
        if paths[a] != paths[b]:
            return bytes_less(paths[a], paths[b])
        return deletes[a].position < deletes[b].position

    def _is_live_data_file(self, name: String) -> Bool:
        for k in range(len(self.manifests)):
            for e in range(len(self.manifests[k].entries)):
                ref entry = self.manifests[k].entries[e]
                if entry.status != STATUS_DELETED and self.files[entry.file_index].content == CONTENT_DATA and self.files[entry.file_index].name == name:
                    return True
        return False

    def _is_removed(self, entry: ManifestEntryRecord, removed: List[String]) -> Bool:
        # `removed` names live data files (checked up front), and file names
        # are unique, so a name match is a data file.
        for r in range(len(removed)):
            if self.files[entry.file_index].name == removed[r]:
                return True
        return False

    def _holds_removed(self, manifest: ManifestRecord, removed: List[String]) -> Bool:
        for e in range(len(manifest.entries)):
            if manifest.entries[e].status != STATUS_DELETED and self._is_removed(manifest.entries[e], removed):
                return True
        return False

    def _partition_dir(self, partition: List[TableCell]) raises -> String:
        if len(partition) != len(self.partition_columns):
            raise Error(
                "TestTable: a partition tuple of " + String(len(partition))
                + " cells for " + String(len(self.partition_columns))
                + " partition columns"
            )
        var out = String("data")
        for p in range(len(partition)):
            out += "/" + self.partition_columns[p].name + "="
            if partition[p].is_null:
                out += "null"
            elif self.partition_columns[p].type_tag == TT_STRING:
                out += partition[p].s
            else:
                out += String(Int(partition[p].i))
        return out^

    def _record_file(
        mut self,
        name: String,
        partition: List[TableCell],
        extension: String,
        content: Int,
        file_format: String,
        bytes: List[UInt8],
        rows: List[TableRow],
        columns: List[TableColumn],
        equality_ids: List[Int],
        referenced: String,
    ) raises -> Int:
        """Writes `bytes` as the file `name` and records it; returns its index."""
        for f in range(len(self.files)):
            if self.files[f].name == name:
                raise Error("TestTable: the file name " + name + " is used twice")
        var rel = self._partition_dir(partition) + "/" + name + "." + extension
        write_file_bytes(self.root + "/" + rel, bytes)
        var metrics = List[ColumnMetrics]()
        if content == CONTENT_DATA:
            metrics = file_metrics(columns, rows)
        self.files.append(
            TableFileRecord(
                name.copy(), rel.copy(), self.location + "/" + rel, content,
                file_format.copy(), partition.copy(), Int64(len(rows)),
                Int64(len(bytes)), metrics^, equality_ids.copy(),
                referenced.copy(),
            )
        )
        return len(self.files) - 1

    def _add_data_file(
        mut self, file: TestDataFile, snap: Int64, seq: Int64
    ) raises -> ManifestEntryRecord:
        var columns = self.columns.copy()
        var bytes = parquet_file_bytes(columns, file.rows)
        var index = self._record_file(
            file.name, file.partition, "parquet", CONTENT_DATA, FORMAT_PARQUET,
            bytes, file.rows, columns, List[Int](), String(""),
        )
        return ManifestEntryRecord(STATUS_ADDED, index, snap, seq)

    def _commit_delete_file(
        mut self,
        name: String,
        partition: List[TableCell],
        delete_columns: List[TableColumn],
        rows: List[TableRow],
        content: Int,
        file_format: String,
        equality_ids: List[Int],
        referenced: String,
    ) raises -> Int64:
        var seq = Int64(len(self.snapshots) + 1)
        var snap = self.snapshot_id(len(self.snapshots) + 1)
        var bytes = List[UInt8]()
        var extension = String("parquet")
        if file_format == FORMAT_AVRO:
            bytes = avro_file_bytes(delete_columns, rows)
            extension = "avro"
        else:
            bytes = parquet_file_bytes(delete_columns, rows)
        var index = self._record_file(
            name, partition, extension, content, file_format, bytes, rows,
            delete_columns, equality_ids, referenced,
        )
        var entries = List[ManifestEntryRecord]()
        entries.append(ManifestEntryRecord(STATUS_ADDED, index, snap, seq))
        var listed = List[ManifestRecord]()
        listed.append(self._write_manifest(1, seq, seq, snap, entries^))
        for k in range(len(self.manifests)):
            listed.append(self.manifests[k].copy())
        self._commit(listed^, seq, snap, "overwrite", 0, 1, Int64(0))
        return snap

    def _write_manifest(
        mut self,
        content: Int,
        seq: Int64,
        min_seq: Int64,
        snap: Int64,
        var entries: List[ManifestEntryRecord],
    ) raises -> ManifestRecord:
        self.manifest_count += 1
        var rel = String("metadata/") + _uuid(self.manifest_count) + "-m0.avro"
        var manifest = ManifestRecord(
            rel.copy(), self.location + "/" + rel, content, seq, min_seq, snap,
            Int64(0), entries^,
        )
        var bytes = manifest_file_bytes(
            manifest, self.files, self.columns, self.partition_columns
        )
        write_file_bytes(self.root + "/" + rel, bytes)
        manifest.length = Int64(len(bytes))
        return manifest^

    def _commit(
        mut self,
        var listed: List[ManifestRecord],
        seq: Int64,
        snap: Int64,
        operation: String,
        added_data_files: Int,
        added_delete_files: Int,
        added_records: Int64,
    ) raises:
        var n = len(self.snapshots) + 1
        var parent = Int64(-1)
        if len(self.snapshots) > 0:
            parent = self.snapshots[len(self.snapshots) - 1].snapshot_id
        var rel = (
            String("metadata/snap-") + String(snap) + "-1-" + _uuid(100 + n)
            + ".avro"
        )
        write_file_bytes(
            self.root + "/" + rel,
            manifest_list_bytes(
                listed, self.files, self.partition_columns, snap, parent, seq
            ),
        )
        self.snapshots.append(
            SnapshotRecord(
                snap, parent, seq, timestamp_ms(n), self.location + "/" + rel,
                operation.copy(), added_data_files, added_delete_files,
                added_records,
            )
        )
        self.manifests = listed^
        self._write_metadata()

    def _write_metadata(mut self) raises:
        self.version += 1
        write_file_text(
            self.root + "/metadata/v" + String(self.version) + ".metadata.json",
            table_metadata_json(
                self.location, self.columns, self.partition_columns,
                self.snapshots, self.version,
            ),
        )
        write_file_text(self.root + "/metadata/version-hint.text", String(self.version))
