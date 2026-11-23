# =============================================================================
# iceberg_catalog/iceberg_write_sink.mojo — Arrow batches written into an
#   Iceberg table through the REST catalog: append or overwrite.
# =============================================================================
#
# `write_table` is one statement's write to one existing table
# (docs/design/iceberg_tables.md, "What komira writes" and "Commit
# semantics"). It never raises: every failure is an outcome whose `message`
# starts with its token. In order, it
#
#   1. loads the table's metadata; a table that is not format version 2 is
#      `ICEBERG_WRITE_FORMAT_UNSUPPORTED`;
#   2. maps the batches to the table's current schema BY POSITION. Every batch
#      must have as many columns as the schema has fields
#      (`ICEBERG_SCHEMA_INCOMPATIBLE` names both counts), the Iceberg type of
#      each column (`iceberg_type_of_column`) must be the field's type
#      (`ICEBERG_SCHEMA_INCOMPATIBLE` names the column and both types), and a
#      field of a type outside boolean, int, long, float, double, string and
#      date is `ICEBERG_TYPE_UNSUPPORTED`;
#   3. takes the data path from `write.data.path`, else `<location>/data`, and
#      the metadata path from `write.metadata.path`, else
#      `<location>/metadata`; a path that is not under `<location>/` is
#      `ICEBERG_LOCATION_REFUSED`;
#   4. takes the Parquet codec from `write.parquet.compression-codec` (zstd,
#      snappy, gzip, uncompressed or lz4), else zstd; another value is
#      `ICEBERG_WRITE_FORMAT_UNSUPPORTED` naming the property and the value;
#   5. draws the statement's uuid from the ids, and writes one data file
#      `<data path>/<uuid>-<i>.parquet` for each batch `i` that has rows
#      (`encode_iceberg_data_file`: the table's field ids, the table's
#      required flags, a null in a required column is
#      `ICEBERG_NULL_IN_REQUIRED_COLUMN`);
#   6. commits with `commit_append` over a `StoreSnapshotWriter`, in the
#      mode asked: an append adds the files to `main`; an overwrite makes them
#      the whole of `main` (a statement with no rows empties the table);
#   7. cleans up from the committer's outcome: after a definite failure it
#      deletes the statement's data files and manifest; it always deletes the
#      manifest lists the outcome lists; after an unknown outcome it deletes
#      nothing else. A failure before the commit deletes the data files
#      already written. A delete that fails is reported in `delete_failures`
#      and never replaces the outcome.
#
# Every URI goes through `files`, which refuses one outside the store's
# prefix as `ICEBERG_LOCATION_REFUSED`.
# =============================================================================

from arrow.record_batch import RecordBatch
from containers.slab import Slab
from iceberg import (
    DataFileInfo,
    encode_iceberg_data_file,
    iceberg_type_of_column,
    json_escape_string,
)
from objectstore.store import CloneableConditionalWriteStore
from parquet_api.types import CompressionCodec

from .iceberg_commit import (
    AppendCommit,
    CommitClock,
    CommitIds,
    check_append_base,
    commit_append,
)
from .iceberg_rest_catalog_client import (
    CatalogCredentialProvider,
    IcebergRestCatalog,
)
from .iceberg_rest_errors import (
    ICEBERG_LOCATION_REFUSED,
    ICEBERG_SCHEMA_INCOMPATIBLE,
    ICEBERG_TYPE_UNSUPPORTED,
    ICEBERG_WRITE_FORMAT_UNSUPPORTED,
)
from .iceberg_rest_transport import IcebergRestTransport
from .iceberg_store_writer import StoreSnapshotWriter
from .iceberg_table_files import TableFiles
from .iceberg_table_metadata import SchemaField, TableMetadata, TableSchema


comptime DATA_PATH_PROPERTY: String = "write.data.path"
comptime METADATA_PATH_PROPERTY: String = "write.metadata.path"
comptime CODEC_PROPERTY: String = "write.parquet.compression-codec"


# =============================================================================
# §0 — what a write returns.
# =============================================================================


struct TableWriteOutcome(Copyable, Movable):
    """What `write_table` did.

      * `committed`: the statement is in the table (or had no rows to write
        into a table with nothing to replace).
      * `message`: "" on success, else the error, starting with its token.
      * `rows_written`, `files_written`: the rows and data files the
        committed statement added (0 unless committed).
      * `snapshot_id`, `commit_id`, `landed_snapshot_id`, `manifest_list`,
        `posts`: the committer's (`AppendCommitOutcome`); the snapshot ids
        and the commit id are 0 and "" when the statement failed before the
        commit or had nothing to commit.
      * `deleted`: the URIs deleted; `delete_failures`: the URIs a delete
        failed on, each followed by the store's error, as `<uri>: <error>`."""

    var committed: Bool
    var message: String
    var rows_written: Int64
    var files_written: Int
    var snapshot_id: Int64
    var commit_id: String
    var landed_snapshot_id: Optional[Int64]
    var manifest_list: String
    var posts: Int
    var deleted: List[String]
    var delete_failures: List[String]

    def __init__(out self):
        self.committed = False
        self.message = String("")
        self.rows_written = 0
        self.files_written = 0
        self.snapshot_id = 0
        self.commit_id = String("")
        self.landed_snapshot_id = None
        self.manifest_list = String("")
        self.posts = 0
        self.deleted = List[String]()
        self.delete_failures = List[String]()


# =============================================================================
# §1 — the table's schema, paths and codec.
# =============================================================================


def table_schema_json(schema: TableSchema) -> String:
    """The schema as the manifest header records it:
    `{"type":"struct","schema-id":N,"fields":[{"id":..,"name":..,
    "required":..,"type":..},...]}`."""
    var out = (
        String('{"type":"struct","schema-id":')
        + String(schema.schema_id)
        + String(',"fields":[')
    )
    for i in range(len(schema.fields)):
        ref f = schema.fields[i]
        if i > 0:
            out += String(",")
        out += (
            String('{"id":')
            + String(f.id)
            + String(',"name":')
            + json_escape_string(f.name)
            + String(',"required":')
        )
        if f.required:
            out += String("true")
        else:
            out += String("false")
        out += String(',"type":') + json_escape_string(f.type_name) + String("}")
    out += String("]}")
    return out^


def _strip_slashes(s: String) -> String:
    var p = String(s)
    while p.endswith(String("/")):
        var trimmed = String(p[byte=0 : p.byte_length() - 1])
        p = trimmed^
    return p^


def _table_path(
    md: TableMetadata,
    key: String,
    property_name: String,
    default_dir: String,
    what: String,
) raises -> String:
    var location = _strip_slashes(md.location)
    var path = location + String("/") + default_dir
    var custom = md.property(property_name)
    if custom:
        path = _strip_slashes(custom.value())
    if not path.startswith(location + String("/")):
        raise Error(
            String(ICEBERG_LOCATION_REFUSED)
            + String(": table '")
            + key
            + String("': ")
            + what
            + String(" path ")
            + path
            + String(" is not under the table location ")
            + location
        )
    return path^


def table_data_path(md: TableMetadata, key: String) raises -> String:
    """The URI of the directory data files go to: `write.data.path`, else
    `<location>/data`, without a trailing `/`. Raises
    `ICEBERG_LOCATION_REFUSED` when it is not under `<location>/`."""
    return _table_path(
        md, key, String(DATA_PATH_PROPERTY), String("data"), String("data")
    )


def table_metadata_path(md: TableMetadata, key: String) raises -> String:
    """The URI of the directory manifests and manifest lists go to:
    `write.metadata.path`, else `<location>/metadata`, without a trailing `/`.
    Raises `ICEBERG_LOCATION_REFUSED` when it is not under `<location>/`."""
    return _table_path(
        md,
        key,
        String(METADATA_PATH_PROPERTY),
        String("metadata"),
        String("metadata"),
    )


def table_parquet_codec(md: TableMetadata, key: String) raises -> CompressionCodec:
    """The Parquet codec of the table's data files: `write.parquet.compression-codec`
    (zstd, snappy, gzip, uncompressed or lz4), else zstd. Raises
    `ICEBERG_WRITE_FORMAT_UNSUPPORTED` for another value."""
    var v = md.property(String(CODEC_PROPERTY))
    if not v:
        return CompressionCodec.ZSTD
    var name = v.value()
    if name == String("zstd"):
        return CompressionCodec.ZSTD
    if name == String("snappy"):
        return CompressionCodec.SNAPPY
    if name == String("gzip"):
        return CompressionCodec.GZIP
    if name == String("uncompressed"):
        return CompressionCodec.UNCOMPRESSED
    if name == String("lz4"):
        return CompressionCodec.LZ4_RAW
    raise Error(
        String(ICEBERG_WRITE_FORMAT_UNSUPPORTED)
        + String(": table '")
        + key
        + String("' property ")
        + String(CODEC_PROPERTY)
        + String(" is '")
        + name
        + String("'; komira writes zstd, snappy, gzip, uncompressed or lz4")
    )


def _first_slice_type(type_name: String) -> Bool:
    return (
        type_name == String("boolean")
        or type_name == String("int")
        or type_name == String("long")
        or type_name == String("float")
        or type_name == String("double")
        or type_name == String("string")
        or type_name == String("date")
    )


def _check_batches(
    key: String, schema: TableSchema, batches: Slab[RecordBatch]
) raises:
    """Every batch has the schema's columns, by position, with its types."""
    var n = len(schema.fields)
    for b in range(len(batches)):
        ref batch = batches[b]
        if batch.num_columns() != n:
            raise Error(
                String(ICEBERG_SCHEMA_INCOMPATIBLE)
                + String(": table '")
                + key
                + String("' has ")
                + String(n)
                + String(" column(s), batch ")
                + String(b)
                + String(" has ")
                + String(batch.num_columns())
            )
        for c in range(n):
            ref field = schema.fields[c]
            if not _first_slice_type(field.type_name):
                raise Error(
                    String(ICEBERG_TYPE_UNSUPPORTED)
                    + String(": column ")
                    + field.name
                    + String(" has Iceberg type ")
                    + field.type_name
                    + String(", which the Iceberg writer does not write yet")
                )
            var batch_type = iceberg_type_of_column(batch, c)
            if batch_type != field.type_name:
                raise Error(
                    String(ICEBERG_SCHEMA_INCOMPATIBLE)
                    + String(": table '")
                    + key
                    + String("': column '")
                    + field.name
                    + String("' is ")
                    + field.type_name
                    + String(" in the table, the batch holds ")
                    + batch_type
                )


# =============================================================================
# §2 — one statement.
# =============================================================================


struct _Prepared[S: CloneableConditionalWriteStore](Movable):
    """The statement ready to commit: its commit and its manifest writer."""

    var commit: AppendCommit
    var writer: StoreSnapshotWriter[Self.S]
    var rows: Int64
    var files: Int

    def __init__(
        out self,
        var commit: AppendCommit,
        var writer: StoreSnapshotWriter[Self.S],
        rows: Int64,
        files: Int,
    ):
        self.commit = commit^
        self.writer = writer^
        self.rows = rows
        self.files = files


def _prepare[
    T: IcebergRestTransport,
    P: CatalogCredentialProvider,
    S: CloneableConditionalWriteStore,
    I: CommitIds,
](
    mut catalog: IcebergRestCatalog[T, P],
    files: TableFiles[S],
    mut ids: I,
    namespace: String,
    table: String,
    batches: Slab[RecordBatch],
    overwrite: Bool,
    pinned_snapshot_ids: List[Int64],
    mut written: List[String],
) raises -> _Prepared[S]:
    """Steps 1 to 5 of the module header. Every data file written is added to
    `written`, so the caller can delete them when a later step raises."""
    var key = namespace + String(".") + table
    var loaded = catalog.load_table_metadata(namespace, table)
    ref md = loaded.metadata
    var probe = AppendCommit(
        String(namespace),
        String(table),
        String(md.table_uuid),
        List[SchemaField](),
        List[Int64](),
        0,
        0,
        0,
    )
    var refused = check_append_base(probe, md)
    if refused.byte_length() > 0:
        raise Error(refused)
    ref schema = md.schemas[md.schema_index(md.current_schema_id)]
    if len(schema.fields) == 0:
        raise Error(
            String(ICEBERG_SCHEMA_INCOMPATIBLE)
            + String(": table '")
            + key
            + String("' has no columns")
        )
    _check_batches(key, schema, batches)
    var data_path = table_data_path(md, key)
    var metadata_path = table_metadata_path(md, key)
    var codec = table_parquet_codec(md, key)

    var uuid = ids.uuid()
    var field_ids = List[Int]()
    var required = List[Bool]()
    var columns = List[SchemaField]()
    for c in range(len(schema.fields)):
        ref f = schema.fields[c]
        field_ids.append(f.id)
        required.append(f.required)
        columns.append(SchemaField(f.id, String(f.name), f.required, String(f.type_name)))
    var infos = List[DataFileInfo]()
    var rows = Int64(0)
    var size = Int64(0)
    for b in range(len(batches)):
        ref batch = batches[b]
        if batch.num_rows() == 0:
            continue
        var uri = (
            data_path
            + String("/")
            + uuid
            + String("-")
            + String(b)
            + String(".parquet")
        )
        var encoded = encode_iceberg_data_file(
            batch, field_ids, required, String(uri), codec
        )
        # Refused before it is recorded when the store cannot hold it;
        # recorded before the put, which may land and still raise.
        _ = files.key_of(uri)
        written.append(uri)
        files.put(uri, encoded.bytes)
        rows += Int64(encoded.info.record_count)
        size += Int64(encoded.info.file_size_in_bytes)
        infos.append(encoded.info.copy())

    var pins = List[Int64]()
    for i in range(len(pinned_snapshot_ids)):
        pins.append(pinned_snapshot_ids[i])
    var commit = AppendCommit(
        String(namespace),
        String(table),
        String(md.table_uuid),
        columns^,
        pins^,
        Int64(len(infos)),
        rows,
        size,
        overwrite,
    )
    var count = len(infos)
    var writer = StoreSnapshotWriter[S](
        files.clone(),
        uuid^,
        overwrite,
        infos^,
        table_schema_json(schema),
        schema.schema_id,
        metadata_path^,
    )
    return _Prepared[S](commit^, writer^, rows, count)


def _delete_all[
    S: CloneableConditionalWriteStore
](
    files: TableFiles[S],
    uris: List[String],
    mut deleted: List[String],
    mut failures: List[String],
):
    for i in range(len(uris)):
        try:
            files.delete(uris[i])
            deleted.append(String(uris[i]))
        except e:
            failures.append(uris[i] + String(": ") + String(e))


def write_table[
    T: IcebergRestTransport,
    P: CatalogCredentialProvider,
    S: CloneableConditionalWriteStore,
    K: CommitClock,
    I: CommitIds,
](
    mut catalog: IcebergRestCatalog[T, P],
    files: TableFiles[S],
    mut clock: K,
    mut ids: I,
    namespace: String,
    table: String,
    batches: Slab[RecordBatch],
    overwrite: Bool,
    pinned_snapshot_ids: List[Int64],
) -> TableWriteOutcome:
    """Write `batches` into `namespace.table`, appending to it or, with
    `overwrite`, replacing every row of it (module header). `pinned_snapshot_ids`
    are the snapshots of the table the statement read; non-empty means a 409
    is a conflict, never a rebase."""
    var out = TableWriteOutcome()
    var data_uris = List[String]()
    var prepared: _Prepared[S]
    try:
        prepared = _prepare(
            catalog,
            files,
            ids,
            namespace,
            table,
            batches,
            overwrite,
            pinned_snapshot_ids,
            data_uris,
        )
    except e:
        out.message = String(e)
        _delete_all(files, data_uris, out.deleted, out.delete_failures)
        return out^

    var done = commit_append(
        catalog, prepared.writer, clock, ids, prepared.commit
    )
    out.committed = done.committed
    out.message = String(done.message)
    out.snapshot_id = done.snapshot_id
    out.commit_id = String(done.commit_id)
    out.landed_snapshot_id = done.landed_snapshot_id
    out.manifest_list = String(done.manifest_list)
    out.posts = done.posts
    if done.committed:
        out.rows_written = prepared.rows
        out.files_written = prepared.files
    if done.delete_statement_files:
        _delete_all(files, data_uris, out.deleted, out.delete_failures)
        var manifests = List[String]()
        if prepared.writer.manifest_uri.byte_length() > 0:
            manifests.append(String(prepared.writer.manifest_uri))
        _delete_all(files, manifests, out.deleted, out.delete_failures)
    _delete_all(
        files, done.manifest_lists_to_delete, out.deleted, out.delete_failures
    )
    return out^
