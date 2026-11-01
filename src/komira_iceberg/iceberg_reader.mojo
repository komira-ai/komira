# =============================================================================
# iceberg_reader.mojo — file-based Iceberg v2 reader with merge-on-read.
# =============================================================================
#
# A delete file that no reader honors is a SILENT correctness hole — the write
# side would "succeed" while every reader still saw the deleted rows. This
# module is the reader that actually HONORS the delete files: it walks the
# standard Iceberg read path
#
#   version-hint.text -> v<N>.metadata.json -> current snapshot
#     -> manifest LIST -> each manifest FILE -> data/delete file entries
#
# and applies merge-on-read to the data files:
#
#   * POSITION deletes (content=1): a data row at (file_path, position) is
#     masked iff some position-delete entry names exactly that (path, pos) and
#     its delete file's sequence number is >= the data file's.
#
#   * EQUALITY deletes (content=2): a data row is masked iff some equality-delete
#     file with a sequence number STRICTLY GREATER than the data file's sequence
#     number contains a delete row whose equality columns EQUAL this data row's
#     equality columns. The strict-greater rule is load-bearing: it lets a LATER
#     re-insert of a deleted key (a new data file with a HIGHER seq) survive the
#     earlier delete — the update / re-insert semantics a change stream needs.
#
# The reader is generic over `[Store: ConditionalWriteStore]` so it runs on the
# in-memory and local-filesystem conformers and any object store, unchanged.
#
# Encapsulation: the store is taken by `ref`; every buffer is an owned
# List[UInt8]; rows are owned List[RowCell]. ZERO UnsafePointer in any
# signature; ZERO wildcard origins.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from .iceberg_types import (
    IcebergSchema,
    ICE_DATA_CONTENT_DATA,
    ICE_DATA_CONTENT_POSITION_DELETES,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
)
from .iceberg_avro_manifest import (
    ICE_MANIFEST_CONTENT_DATA,
    ICE_MANIFEST_CONTENT_DELETES,
)
from .iceberg_avro_manifest_read import (
    ManifestEntry,
    read_manifest_list,
    read_manifest_entries,
)
from .iceberg_json_scan import (
    bare_int64_field,
    bytes_to_str,
    json_str_field,
    matching_object_end,
    snapshot_objects,
    substr,
)
from .iceberg_version import current_version, metadata_json_key
from .iceberg_partition import (
    PartitionSpec,
    partition_value_type_tags,
    ICE_TRANSFORM_IDENTITY,
    ICE_TRANSFORM_BUCKET,
)
from .iceberg_row_value import (
    RowCell,
    col_types_of,
    rows_equal,
    decode_partition_cell,
)
from .iceberg_parquet_data import read_parquet_data_file
from .iceberg_delete_writer import (
    read_equality_delete_file,
    read_position_delete_file,
)


# =============================================================================
# Current snapshot lookup (OUR own well-formed metadata.json only).
# =============================================================================


def _current_snapshot_manifest_list(json: String) raises -> String:
    """Find the current snapshot's `manifest-list` object key in metadata.json.

    Reads `current-snapshot-id`, then scans the `snapshots` array for the
    snapshot object whose `snapshot-id` matches and returns its `manifest-list`
    string. (The writer always emits the current snapshot LAST, but we match by
    id to be robust.)"""
    var cur_id = bare_int64_field(json, "current-snapshot-id")

    # THE EMPTY TABLE. A NEGATIVE `current-snapshot-id` is the Iceberg spelling
    # of "no current snapshot", and it is the shape this package's own writer
    # produces for a table created and never committed to
    # (`build_table_metadata_json`: -1 means "no current snapshot").
    #
    # THE CHECK IS ON THE SIGN OF THE ID, NOT ON `len(snapshots) == 0`. A
    # pointer that NAMES a snapshot the table does not contain is CORRUPT and
    # must keep raising below: "the table is empty" and "the table is broken" are
    # different answers, and a reader that returns the first for the second
    # converts a corruption into a clean empty result.
    if cur_id < Int64(0):
        return String("")

    # Walk the snapshots array; return the manifest-list of the matching id.
    var snaps = snapshot_objects(json)
    for i in range(len(snaps)):
        if bare_int64_field(snaps[i], "snapshot-id") == cur_id:
            return json_str_field(snaps[i], "manifest-list")
    raise Error(
        "_current_snapshot_manifest_list: current snapshot object not found"
    )


# =============================================================================
# Field-id -> column index map (for extracting equality columns from a row).
# =============================================================================


def _col_index_of_field_id(schema: IcebergSchema, field_id: Int) raises -> Int:
    for i in range(len(schema.fields)):
        if schema.fields[i].field_id == field_id:
            return i
    raise Error(
        "_col_index_of_field_id: field-id "
        + String(field_id)
        + " not in schema"
    )


# =============================================================================
# One resolved data file (its rows + its sequence number + its path).
# =============================================================================


struct _DataFileRows(Copyable, Movable, Deinitable):
    var file_path: String
    var sequence_number: Int64
    var rows: List[List[RowCell]]

    def __init__(
        out self,
        var file_path: String,
        sequence_number: Int64,
        var rows: List[List[RowCell]],
    ):
        self.file_path = file_path^
        self.sequence_number = sequence_number
        self.rows = rows^

    def copy(self) -> Self:
        var rr = List[List[RowCell]]()
        for i in range(len(self.rows)):
            var row = List[RowCell]()
            for j in range(len(self.rows[i])):
                row.append(self.rows[i][j].copy())
            rr.append(row^)
        return Self(String(self.file_path), self.sequence_number, rr^)


# One equality-delete file: its match field-ids + its sequence number + rows.
struct _EqDeleteFile(Copyable, Movable, Deinitable):
    var equality_ids: List[Int]
    var sequence_number: Int64
    var rows: List[List[RowCell]]

    def __init__(
        out self,
        var equality_ids: List[Int],
        sequence_number: Int64,
        var rows: List[List[RowCell]],
    ):
        self.equality_ids = equality_ids^
        self.sequence_number = sequence_number
        self.rows = rows^

    def copy(self) -> Self:
        var eids = List[Int]()
        for i in range(len(self.equality_ids)):
            eids.append(self.equality_ids[i])
        var rr = List[List[RowCell]]()
        for i in range(len(self.rows)):
            var row = List[RowCell]()
            for j in range(len(self.rows[i])):
                row.append(self.rows[i][j].copy())
            rr.append(row^)
        return Self(eids^, self.sequence_number, rr^)


# One position-delete: (data-file-path, position) + the delete file's sequence
# number. A position delete masks a data row ONLY when the delete file's
# sequence number is >= the data file's sequence number (`data_seq <=
# del_seq`) — the position-delete analogue of the equality-delete strict-order
# rule. Without the seq, a stale position delete from generation g could mask an
# identically-positioned row in a LATER data file at the same (path, pos), which
# becomes reachable once a compaction re-emits a file at the same key with fresh
# rows at the same offsets. Carrying and gating on the seq closes that hole.
@fieldwise_init
struct _PosDelete(Copyable, Movable, Deinitable):
    var file_path: String
    var pos: Int64
    var sequence_number: Int64

    def copy(self) -> Self:
        return Self(String(self.file_path), self.pos, self.sequence_number)


# =============================================================================
# The merge-on-read core (a free function over a borrowed store).
# =============================================================================
#
# The reader logic is a FREE FUNCTION taking the store by `ref` so BOTH the
# standalone `IcebergTableReader` wrapper AND the writer's `read_live_rows`
# convenience (which reads through its OWN store handle) share one
# implementation — no store clone needed, no duplicated merge code to drift.


def read_live_rows_from[
    Store: ConditionalWriteStore, o: Origin[mut=True]
](
    ref [o] store: Store,
    location: String,
    schema: IcebergSchema,
) raises -> List[List[RowCell]]:
    """Read the LIVE rows of the table's CURRENT snapshot (all delete files
    honored) through the borrowed `store`.

    Walks the current metadata version (`current_version`: the hint, then any
    committed version past it) -> v<N>.metadata.json -> current snapshot ->
    manifest list -> manifest FILES, collects the data + equality-delete +
    position-delete files, then applies merge-on-read. Raises when the location
    holds no table (no metadata version)."""
    var version = current_version(store, location)
    if version == 0:
        raise Error(
            "iceberg read: no table at '" + location + "' (no metadata version)"
        )
    var meta = bytes_to_str(
        store.get(Path.parse(metadata_json_key(location, version)))
    )
    var mlist_key = _current_snapshot_manifest_list(meta)
    # AN EMPTY KEY MEANS "no current snapshot" (see above): a table that has
    # never been committed to. Return ZERO ROWS rather than `get`-ing the object
    # at the key "", which would surface as a not-found and be indistinguishable
    # from a missing manifest list on a REAL snapshot.
    if mlist_key.byte_length() == 0:
        return List[List[RowCell]]()

    # Decode the manifest list -> the manifest FILE entries (data + delete).
    var mlist_bytes = store.get(Path.parse(mlist_key))
    var manifests = read_manifest_list(mlist_bytes)

    var col_types = col_types_of(schema)

    # Recover the table's partition spec from metadata.json so a DATA manifest's
    # `r102` partition record is decoded byte-aligned (merge-on-read itself does
    # NOT need the partition VALUES — equality deletes are global by key,
    # position deletes are per-file-path — but the reader MUST consume the
    # partition struct's bytes to stay aligned with the rest of the entry).
    var table_spec = parse_partition_spec_from_metadata(meta)
    var data_partition_types = partition_value_type_tags(table_spec, schema)

    var data_files = List[_DataFileRows]()
    var eq_deletes = List[_EqDeleteFile]()
    var pos_deletes = List[_PosDelete]()

    for mi in range(len(manifests)):
        ref m = manifests[mi]
        var manifest_bytes = store.get(Path.parse(m.manifest_path))
        # A manifest written under the table's spec carries a partition tuple
        # in each entry's `r102`: the data manifests, and the position-delete
        # manifest of a partitioned table (each position delete names its data
        # file's partition). A manifest written under another spec (the
        # unpartitioned spec of the global equality deletes) has none.
        var this_partition_types = List[Int]()
        if m.partition_spec_id == table_spec.spec_id:
            for i in range(len(data_partition_types)):
                this_partition_types.append(data_partition_types[i])
        var entries = read_manifest_entries(
            manifest_bytes, this_partition_types
        )
        for ei in range(len(entries)):
            ref e = entries[ei]
            if e.content == ICE_DATA_CONTENT_DATA:
                var df_bytes = store.get(Path.parse(e.file_path))
                # DATA files are Parquet. The merge algebra below is
                # format-agnostic — it only consumes List[List[RowCell]] in
                # file-absolute row order, which `read_parquet_data_file`
                # upholds (see its DECODE INVARIANT).
                var rows = read_parquet_data_file(df_bytes, col_types)
                data_files.append(
                    _DataFileRows(
                        String(e.file_path), e.sequence_number, rows^
                    )
                )
            elif e.content == ICE_DATA_CONTENT_EQUALITY_DELETES:
                if len(e.equality_ids) == 0:
                    raise Error(
                        "iceberg read: equality-delete file '"
                        + e.file_path
                        + "' lists no equality ids (it would match every row)"
                    )
                # the equality columns' types (in equality-id order).
                var eq_types = List[Int]()
                for k in range(len(e.equality_ids)):
                    var ci = _col_index_of_field_id(schema, e.equality_ids[k])
                    eq_types.append(schema.fields[ci].type_tag)
                var del_bytes = store.get(Path.parse(e.file_path))
                var del_rows = read_equality_delete_file(del_bytes, eq_types)
                var eids = List[Int]()
                for k in range(len(e.equality_ids)):
                    eids.append(e.equality_ids[k])
                eq_deletes.append(
                    _EqDeleteFile(eids^, e.sequence_number, del_rows^)
                )
            elif e.content == ICE_DATA_CONTENT_POSITION_DELETES:
                var pos_bytes = store.get(Path.parse(e.file_path))
                var pos_rows = read_position_delete_file(pos_bytes)
                for pj in range(len(pos_rows)):
                    # Carry the delete FILE's sequence number onto each
                    # position-delete entry so `_is_position_deleted` can gate
                    # `data_seq <= del_seq`.
                    pos_deletes.append(
                        _PosDelete(
                            String(pos_rows[pj].file_path),
                            pos_rows[pj].pos,
                            e.sequence_number,
                        )
                    )

    return _apply_merge(schema, data_files, eq_deletes, pos_deletes)


def _apply_merge(
    schema: IcebergSchema,
    data_files: List[_DataFileRows],
    eq_deletes: List[_EqDeleteFile],
    pos_deletes: List[_PosDelete],
) raises -> List[List[RowCell]]:
    """The merge-on-read core: emit each data row unless a position delete names
    its (file, pos) with a sequence number >= the data file's OR an equality
    delete with a STRICTLY HIGHER sequence number matches its equality columns.
    """
    var live = List[List[RowCell]]()
    for fi in range(len(data_files)):
        ref df = data_files[fi]
        for ri in range(len(df.rows)):
            ref row = df.rows[ri]
            if _is_position_deleted(
                df.file_path, Int64(ri), df.sequence_number, pos_deletes
            ):
                continue
            if _is_equality_deleted(
                schema, row, df.sequence_number, eq_deletes
            ):
                continue
            var out_row = List[RowCell]()
            for ci in range(len(row)):
                out_row.append(row[ci].copy())
            live.append(out_row^)
    return live^


def _is_position_deleted(
    file_path: String,
    pos: Int64,
    data_seq: Int64,
    pos_deletes: List[_PosDelete],
) -> Bool:
    """True iff some position-delete entry names exactly (file_path, pos) AND its
    delete file's sequence number is >= `data_seq` (a position delete masks its
    OWN and lower data generations, not a strictly-later one at the same
    path/offset). Mirrors the equality-delete ordering intent — the
    equality path uses STRICTLY-greater (a re-insert at a higher seq survives);
    the position path uses >= because a position delete of generation g is
    written against the rows present AT generation g (it CAN legitimately mask a
    same-generation row)."""
    for i in range(len(pos_deletes)):
        ref d = pos_deletes[i]
        if (
            d.pos == pos
            and data_seq <= d.sequence_number
            and _path_eq(d.file_path, file_path)
        ):
            return True
    return False


def _is_equality_deleted(
    schema: IcebergSchema,
    row: List[RowCell],
    data_seq: Int64,
    eq_deletes: List[_EqDeleteFile],
) raises -> Bool:
    """True iff some equality-delete file with a STRICTLY HIGHER sequence number
    than `data_seq` contains a delete row whose equality columns equal this data
    row's same columns."""
    for i in range(len(eq_deletes)):
        ref ed = eq_deletes[i]
        # ordering rule: a delete masks ONLY data with a LOWER seq.
        if ed.sequence_number <= data_seq:
            continue
        var projected = List[RowCell]()
        for k in range(len(ed.equality_ids)):
            var ci = _col_index_of_field_id(schema, ed.equality_ids[k])
            projected.append(row[ci].copy())
        for dj in range(len(ed.rows)):
            if rows_equal(projected, ed.rows[dj]):
                return True
    return False


@always_inline
def _path_eq(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    for i in range(len(ab)):
        if ab[i] != bb[i]:
            return False
    return True


# =============================================================================
# Partition-spec recovery from metadata.json + partition-value manifest decode.
# =============================================================================


def parse_partition_spec_from_metadata(meta: String) raises -> PartitionSpec:
    """Recover the DEFAULT partition spec from OUR metadata.json.

    Reads the FIRST object of the `partition-specs` array (the default spec —
    this writer emits exactly one, id 0). Each field object is `{name, transform,
    source-id, field-id}` (the shape `partition_spec_json` emits). The transform
    string "identity" / "bucket[N]" is parsed back into the transform tag +
    param. An absent / empty `partition-specs` array yields the unpartitioned
    spec."""
    var spec = PartitionSpec(0)
    var specs_at = meta.find('"partition-specs":[')
    if specs_at < 0:
        return spec^
    var bs = meta.as_bytes()
    var n = len(bs)
    var i = specs_at + String('"partition-specs":[').byte_length()
    # find the first spec object `{...}` (the default spec).
    while i < n and bs[i] != UInt8(ord("{")):
        if bs[i] == UInt8(ord("]")):
            return spec^  # empty array
        i += 1
    if i >= n:
        return spec^
    # the matching close brace of this first spec object.
    var obj_start = i
    i = matching_object_end(meta, i)
    var spec_obj = substr(meta, obj_start, i)
    # spec-id.
    var sid_at = spec_obj.find('"spec-id":')
    if sid_at >= 0:
        spec = PartitionSpec(Int(bare_int64_field(spec_obj, "spec-id")))
    # fields array.
    var fields_at = spec_obj.find('"fields":[')
    if fields_at < 0:
        return spec^
    var fb = spec_obj.as_bytes()
    var flen = len(fb)
    var p = fields_at + String('"fields":[').byte_length()
    while p < flen:
        var c = Int(fb[p])
        if c == ord("]"):
            break
        if c == ord("{"):
            var fstart = p
            p = matching_object_end(spec_obj, p)
            var field_obj = substr(spec_obj, fstart, p)
            var name = json_str_field(field_obj, "name")
            var transform = json_str_field(field_obj, "transform")
            var source_id = Int(bare_int64_field(field_obj, "source-id"))
            if transform == String("identity"):
                spec.add_identity(source_id, name^)
            elif transform.find("bucket[") == 0:
                var nbuckets = _parse_bucket_n(transform)
                spec.add_bucket(source_id, nbuckets, name^)
            else:
                raise Error(
                    "parse_partition_spec_from_metadata: unsupported"
                    " transform '"
                    + transform
                    + "'"
                )
        else:
            p += 1
    return spec^


def _parse_bucket_n(transform: String) raises -> Int:
    """Parse the N out of a `bucket[N]` transform string."""
    var bs = transform.as_bytes()
    var n = len(bs)
    var i = 0
    # skip to '['
    while i < n and bs[i] != UInt8(ord("[")):
        i += 1
    i += 1  # past '['
    var v = 0
    var any = False
    while i < n:
        var d = Int(bs[i])
        if d < ord("0") or d > ord("9"):
            break
        v = v * 10 + (d - ord("0"))
        any = True
        i += 1
    if not any:
        raise Error("_parse_bucket_n: no digits in '" + transform + "'")
    return v


def read_partition_values_from_manifest(
    manifest_bytes: List[UInt8],
    spec: PartitionSpec,
    schema: IcebergSchema,
) raises -> List[List[RowCell]]:
    """Decode the partition-VALUE tuple of every DATA-file entry in a manifest.

    Returns one `List[RowCell]` per data-file entry (in manifest order), the
    partition tuple recovered from that entry's `r102` partition record. Used by
    tests + tooling that want the partition-value STATS the manifest records
    (the merge reader itself does not need them). Delete-file entries (which
    carry no partition) yield an empty tuple and are skipped."""
    var pv_types = partition_value_type_tags(spec, schema)
    var entries = read_manifest_entries(manifest_bytes, pv_types)
    var out = List[List[RowCell]]()
    for ei in range(len(entries)):
        ref e = entries[ei]
        if e.content != ICE_DATA_CONTENT_DATA:
            continue
        var tuple = List[RowCell]()
        for pi in range(len(e.partition_avro)):
            tuple.append(
                decode_partition_cell(e.partition_avro[pi], pv_types[pi])
            )
        out.append(tuple^)
    return out^


# =============================================================================
# IcebergTableReader — a thin owning wrapper for standalone reads.
# =============================================================================


struct IcebergTableReader[Store: ConditionalWriteStore](Movable):
    """File-based Iceberg v2 reader with merge-on-read over Parquet data files
    and Avro delete files. Owns a store handle + the table `location` + schema;
    `read_live_rows` returns the CURRENT snapshot's LIVE rows (deletes honored).

    A thin wrapper over `read_live_rows_from` — the merge-on-read logic lives in
    that free function so the writer's `read_live_rows` convenience shares it.
    """

    var _store: Self.Store
    var _location: String
    var _schema: IcebergSchema

    def __init__(
        out self,
        var store: Self.Store,
        var location: String,
        var schema: IcebergSchema,
    ):
        self._store = store^
        self._location = location^
        self._schema = schema^

    def read_live_rows(mut self) raises -> List[List[RowCell]]:
        """Return the LIVE rows of the current snapshot (all delete files
        honored)."""
        return read_live_rows_from(
            self._store, self._location, self._schema
        )
