# =============================================================================
# table_model.mojo -- the values a test table is described and recorded with.
# =============================================================================
#
# A table is described by columns (`TableColumn`), cells (`TableCell`) grouped
# in rows (`TableRow`), and the files a commit writes. The `*Record` structs
# are what the builder remembers about what it wrote, so a later commit can
# list the same files again (a manifest that carries an entry over, a delete
# file that names a data file by its stored path).
#
# Column types are the six the conformance tables use. Every cell of an
# integer-like column (long, int, date as days since the Unix epoch, boolean as
# 0 or 1) keeps its value in `i`, a double in `f`, a string in `s`.
# =============================================================================

comptime TT_LONG: Int = 0
comptime TT_INT: Int = 1
comptime TT_STRING: Int = 2
comptime TT_DOUBLE: Int = 3
comptime TT_DATE: Int = 4
comptime TT_BOOLEAN: Int = 5

# manifest_entry.status
comptime STATUS_EXISTING: Int = 0
comptime STATUS_ADDED: Int = 1
comptime STATUS_DELETED: Int = 2

# data_file.content, and the manifest list's content (0 data, 1 deletes)
comptime CONTENT_DATA: Int = 0
comptime CONTENT_POSITION_DELETES: Int = 1
comptime CONTENT_EQUALITY_DELETES: Int = 2

comptime FORMAT_PARQUET: String = "PARQUET"
comptime FORMAT_AVRO: String = "AVRO"

# The first partition field of a spec has this id; the next ones follow.
comptime PARTITION_FIELD_ID_START: Int = 1000

# A snapshot's id is this plus its commit number (1, 2, ...).
comptime SNAPSHOT_ID_BASE: Int = 6_000_000_000


@fieldwise_init
struct TableColumn(Copyable, Movable):
    """One column of the table schema: its Iceberg field id, name, a `TT_*`
    type and whether it is `required` (NOT NULL)."""

    var id: Int
    var name: String
    var type_tag: Int
    var required: Bool


@fieldwise_init
struct TableCell(Copyable, Movable):
    """One value, or a null (`is_null`; the other fields are then unused)."""

    var is_null: Bool
    var i: Int64
    var f: Float64
    var s: String


def null_cell() -> TableCell:
    """A null."""
    return TableCell(True, Int64(0), Float64(0.0), String(""))


def int_cell(v: Int) -> TableCell:
    """A value of a long, int or date (days since the Unix epoch) column."""
    return TableCell(False, Int64(v), Float64(0.0), String(""))


def bool_cell(v: Bool) -> TableCell:
    """A value of a boolean column."""
    return TableCell(False, Int64(1) if v else Int64(0), Float64(0.0), String(""))


def double_cell(v: Float64) -> TableCell:
    """A value of a double column (NaN included)."""
    return TableCell(False, Int64(0), v, String(""))


def string_cell(v: String) -> TableCell:
    """A value of a string column."""
    return TableCell(False, Int64(0), Float64(0.0), v.copy())


@fieldwise_init
struct TableRow(Copyable, Movable):
    """One row: a cell per column, in column order."""

    var cells: List[TableCell]


def is_int_like(type_tag: Int) -> Bool:
    """Whether a column of this type keeps its cells in `TableCell.i`."""
    return (
        type_tag == TT_LONG
        or type_tag == TT_INT
        or type_tag == TT_DATE
        or type_tag == TT_BOOLEAN
    )


def _write_type_name(mut out: String, type_tag: Int) raises:
    # The arms append: a ladder that returned its literals would select a
    # constant at run time (see src/iceberg/iceberg_types.mojo).
    if type_tag == TT_LONG:
        out += "long"
    elif type_tag == TT_INT:
        out += "int"
    elif type_tag == TT_STRING:
        out += "string"
    elif type_tag == TT_DOUBLE:
        out += "double"
    elif type_tag == TT_DATE:
        out += "date"
    elif type_tag == TT_BOOLEAN:
        out += "boolean"
    else:
        raise Error("komira_iceberg_test_tables: unknown column type " + String(type_tag))


def iceberg_type_name(type_tag: Int) raises -> String:
    """The Iceberg schema spelling of a `TT_*` type: `long`, `int`, `string`,
    `double`, `date` or `boolean`."""
    var out = String()
    _write_type_name(out, type_tag)
    return out^


@fieldwise_init
struct ColumnMetrics(Copyable, Movable):
    """What a data file's manifest entry records for one column: how many
    values (nulls included), how many are null, how many are NaN (-1 when the
    column is not a double) and, unless every value is null or NaN, the
    single-value serializations of the lowest and highest value."""

    var field_id: Int
    var value_count: Int64
    var null_count: Int64
    var nan_count: Int64
    var has_bounds: Bool
    var lower: List[UInt8]
    var upper: List[UInt8]


@fieldwise_init
struct TableFileRecord(Copyable, Movable):
    """A file the builder wrote: `name` is what the caller called it,
    `rel_path` its path under the table root and `uri` the path as the
    manifests record it (the table location plus `rel_path`)."""

    var name: String
    var rel_path: String
    var uri: String
    var content: Int
    var file_format: String
    var partition: List[TableCell]
    var record_count: Int64
    var size_bytes: Int64
    var metrics: List[ColumnMetrics]
    var equality_ids: List[Int]
    var referenced_data_file: String


@fieldwise_init
struct ManifestEntryRecord(Copyable, Movable):
    """One entry of a manifest: a `STATUS_*`, the index of its file in the
    builder's file list, the id of the snapshot the entry records and the
    file's data sequence number."""

    var status: Int
    var file_index: Int
    var snapshot_id: Int64
    var data_seq: Int64


@fieldwise_init
struct ManifestRecord(Copyable, Movable):
    """A manifest file the builder wrote, as its manifest list lists it."""

    var rel_path: String
    var uri: String
    var content: Int
    var sequence_number: Int64
    var min_sequence_number: Int64
    var added_snapshot_id: Int64
    var length: Int64
    var entries: List[ManifestEntryRecord]


@fieldwise_init
struct SnapshotRecord(Copyable, Movable):
    """A committed snapshot, as the table metadata lists it."""

    var snapshot_id: Int64
    var parent_snapshot_id: Int64
    var sequence_number: Int64
    var timestamp_ms: Int64
    var manifest_list_uri: String
    var operation: String
    var added_data_files: Int
    var added_delete_files: Int
    var added_records: Int64
