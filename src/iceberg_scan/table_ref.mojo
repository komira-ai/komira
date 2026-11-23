# =============================================================================
# iceberg_scan/table_ref.mojo -- a path resolved to a pinned table, and its binding
# =============================================================================
#
# WHAT THIS IS. `resolve_iceberg_table` turns what a query names
# (`iceberg_scan('path')`) into an `IcebergTableRef`: the metadata file read,
# the snapshot and schema pinned, and the columns as Arrow fields.
# `iceberg_scan_binding` turns that into the `komira.iceberg.table`
# `ScanBinding` a logical plan carries, and `iceberg_table_ref_of` reads the
# reference back out of a binding at plan time.
#
# THE PATH is a `*.metadata.json` file, or a table directory. A directory is
# read through its `metadata/version-hint.text`, which holds N, and the file
# read is `metadata/v<N>.metadata.json`. A directory with no hint is refused
# `ICEBERG_TABLE_VERSION_UNKNOWN`, naming the path: no other file name is
# guessed. A path with a scheme is read only as `file:`; any other scheme is
# `ICEBERG_PATH_UNSUPPORTED`.
#
# THE TABLE ROOT is the directory given, or, for a metadata file, the parent
# of its `metadata/` directory. With `allow_moved_paths` every stored URI that
# starts with the table's recorded `location` is rewritten to the root plus the
# rest of the URI, so a table copied to another place still reads.
#
# THE PIN. `snapshot_id` is the snapshot asked for (`snapshot_from_id`, an
# unknown id is ICEBERG_SNAPSHOT_NOT_FOUND) or else the table's current
# snapshot (-1 when it has none, which reads as no rows). The schema is the
# asked-for snapshot's own `schema-id`, else the table's current schema; a
# plain read of the current snapshot uses the current schema, which is how a
# column added after the last commit reads as null.
#
# TYPES. boolean, int, long, float, double, string, date, timestamp,
# timestamptz and decimal(P,S) have an Arrow type; every other type (binary,
# uuid, fixed, time, struct, list, map) is `ICEBERG_TYPE_UNSUPPORTED` naming the
# column. Every column is nullable in the Arrow schema: a column added after a
# data file was written reads as nulls from that file.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from scan_source.pushdown_gate import PushdownGate
from scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_PINNED,
)
from scan_source.scan_params import ScanParams, param_hash_string
from scan_source.source_variant import SourceVariant, SOURCE_VARIANT_BINDING

from .local_file import local_is_dir, read_local_file
from .table_metadata import (
    ICEBERG_METADATA_INVALID,
    IcebergField,
    IcebergTableMetadata,
    parse_iceberg_metadata,
)


comptime ICEBERG_SCAN_KIND_NAME: StaticString = "komira.iceberg.table"

comptime ICEBERG_TABLE_VERSION_UNKNOWN: String = "ICEBERG_TABLE_VERSION_UNKNOWN"
comptime ICEBERG_TYPE_UNSUPPORTED: String = "ICEBERG_TYPE_UNSUPPORTED"
comptime ICEBERG_PATH_UNSUPPORTED: String = "ICEBERG_PATH_UNSUPPORTED"

comptime PARAM_METADATA_PATH: String = "metadata_path"
comptime PARAM_TABLE_ROOT: String = "table_root"
comptime PARAM_ALLOW_MOVED_PATHS: String = "allow_moved_paths"
comptime PARAM_SNAPSHOT_ID: String = "snapshot_id"
comptime PARAM_SCHEMA_ID: String = "schema_id"


struct IcebergTableRef(Copyable, Movable):
    """A table pinned to one snapshot and one schema (module header)."""

    var metadata_path: String
    """Local path of the metadata.json read."""
    var table_root: String
    """Local directory that relocated paths are joined to."""
    var location: String
    """The table's `location` as recorded."""
    var allow_moved_paths: Bool
    var format_version: Int
    var snapshot_id: Int64
    """-1: the table has no snapshot (reads as empty)."""
    var schema_id: Int
    var columns: List[IcebergField]
    var arrow_schema: Schema
    """One nullable Field per column, in schema order."""

    def __init__(
        out self,
        var metadata_path: String,
        var table_root: String,
        var location: String,
        allow_moved_paths: Bool,
        format_version: Int,
        snapshot_id: Int64,
        schema_id: Int,
        var columns: List[IcebergField],
        var arrow_schema: Schema,
    ):
        self.metadata_path = metadata_path^
        self.table_root = table_root^
        self.location = location^
        self.allow_moved_paths = allow_moved_paths
        self.format_version = format_version
        self.snapshot_id = snapshot_id
        self.schema_id = schema_id
        self.columns = columns^
        self.arrow_schema = arrow_schema^


# =============================================================================
# Types.
# =============================================================================


struct _Decimal(Copyable, Movable):
    var precision: Int
    var scale: Int

    def __init__(out self, precision: Int, scale: Int):
        self.precision = precision
        self.scale = scale


def _decimal_ps(type_name: String) -> Optional[_Decimal]:
    """(precision, scale) of `decimal(P,S)`, or None for any other spelling."""
    if not type_name.startswith("decimal(") or not type_name.endswith(")"):
        return None
    var inner = String(type_name[byte = 8 : type_name.byte_length() - 1])
    var comma = inner.find(",")
    if comma < 1 or comma >= inner.byte_length() - 1:
        return None
    var p = _digits(String(inner[byte=0:comma]))
    var s = _digits(String(inner[byte = comma + 1 : inner.byte_length()]))
    if p < 1 or s < 0:
        return None
    return Optional[_Decimal](_Decimal(p, s))


def _digits(s: String) -> Int:
    """The non-negative integer `s` spells, or -1."""
    if s.byte_length() == 0 or s.byte_length() > 9:
        return -1
    var v = 0
    for b in s.as_bytes():
        if b < 0x30 or b > 0x39:
            return -1
        v = v * 10 + Int(b - 0x30)
    return v


def _unsupported(column: String, type_name: String) -> Error:
    return Error(
        ICEBERG_TYPE_UNSUPPORTED
        + String(": column '")
        + column
        + String("' has the type '")
        + type_name
        + String("', which is not read yet")
    )


def iceberg_arrow_type(type_name: String, column: String) raises -> ArrowType:
    """The Arrow type of an Iceberg primitive type (module header).

    Raises:
        `ICEBERG_TYPE_UNSUPPORTED` naming `column` and the type."""
    if type_name == "boolean":
        return ArrowType.BOOL
    elif type_name == "int":
        return ArrowType.INT32
    elif type_name == "long":
        return ArrowType.INT64
    elif type_name == "float":
        return ArrowType.FLOAT32
    elif type_name == "double":
        return ArrowType.FLOAT64
    elif type_name == "string":
        return ArrowType.STRING
    elif type_name == "date":
        return ArrowType.DATE32
    elif type_name == "timestamp" or type_name == "timestamptz":
        return ArrowType.TIMESTAMP_US
    var ps = _decimal_ps(type_name)
    if ps:
        return ArrowType.DECIMAL128
    raise _unsupported(column, type_name)


def iceberg_arrow_field(column: IcebergField) raises -> Field:
    """The nullable Arrow field of a column: a decimal carries its precision
    and scale, a timestamptz its UTC zone."""
    var t = iceberg_arrow_type(column.type_name, column.name)
    if t == ArrowType.DECIMAL128:
        var ps = _decimal_ps(column.type_name).value().copy()
        try:
            return Field.decimal128(column.name, ps.precision, ps.scale, True)
        except:
            raise _unsupported(column.name, column.type_name)
    if column.type_name == "timestamptz":
        return Field.timestamp(column.name, ArrowType.TIMESTAMP_US, "UTC", True)
    if column.type_name == "timestamp":
        return Field.timestamp(column.name, ArrowType.TIMESTAMP_US, "", True)
    return Field(column.name, t, True)


# =============================================================================
# Paths.
# =============================================================================


def _scheme_of(uri: String) -> String:
    """The lower-cased scheme of `uri` (letters, digits, `+`, `-`, `.`, then
    `:`, at least two characters), or "" for a bare path."""
    var bytes = uri.as_bytes()
    var n = len(bytes)
    for i in range(n):
        var c = bytes[i]
        if c == 0x3A:
            if i < 2:
                return String("")
            return String(uri[byte=0:i]).lower()
        var letter = (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A)
        var digit = c >= 0x30 and c <= 0x39
        var punct = c == 0x2B or c == 0x2D or c == 0x2E
        if i == 0 and not letter:
            return String("")
        if not (letter or digit or punct):
            return String("")
    return String("")


def _strip_file_scheme(uri: String) raises -> String:
    """`file:///a/b` and `file:/a/b` as `/a/b`; a path that has no scheme as
    it is. Any other scheme is ICEBERG_PATH_UNSUPPORTED."""
    var scheme = _scheme_of(uri)
    if scheme.byte_length() == 0:
        return uri
    if scheme != "file":
        raise Error(
            ICEBERG_PATH_UNSUPPORTED
            + String(": '")
            + uri
            + String("' has the scheme '")
            + scheme
            + String("'; only local files (a bare path or a file: URI) are read")
        )
    var rest = String(uri[byte=5 : uri.byte_length()])
    if rest.startswith("//"):
        rest = String(rest[byte=2 : rest.byte_length()])
        if not rest.startswith("/"):
            raise Error(
                ICEBERG_PATH_UNSUPPORTED
                + String(": '")
                + uri
                + String("' names a host; only local files are read")
            )
    return rest^


def _without_trailing_slash(path: String) -> String:
    var end = path.byte_length()
    while end > 1 and path.as_bytes()[end - 1] == 0x2F:
        end -= 1
    return String(path[byte=0:end])


def _dirname(path: String) -> String:
    """The parent directory of `path`: everything before its last `/`
    ("." when it has none, "/" for a child of the root)."""
    var p = _without_trailing_slash(path)
    var bytes = p.as_bytes()
    var i = len(bytes) - 1
    while i >= 0 and bytes[i] != 0x2F:
        i -= 1
    if i < 0:
        return String(".")
    if i == 0:
        return String("/")
    return String(p[byte=0:i])


def _basename(path: String) -> String:
    var p = _without_trailing_slash(path)
    var bytes = p.as_bytes()
    var i = len(bytes) - 1
    while i >= 0 and bytes[i] != 0x2F:
        i -= 1
    return String(p[byte = i + 1 : p.byte_length()])


def local_path_of(uri: String, table: IcebergTableRef) raises -> String:
    """The local path of a path stored in the table's metadata or manifests.

    A file: URI and a bare path read as the path they spell. With
    `allow_moved_paths`, a URI under the table's recorded `location` is
    rewritten to the table root plus the rest of the URI first, whatever its
    scheme. Any other scheme is `ICEBERG_PATH_UNSUPPORTED`."""
    if table.allow_moved_paths and table.location.byte_length() > 0:
        var loc = _normal_location(table.location)
        var norm = _normal_location(uri)
        if norm.startswith(loc):
            var rest = String(norm[byte = loc.byte_length() : norm.byte_length()])
            if rest.byte_length() == 0 or rest.startswith("/"):
                return _without_trailing_slash(table.table_root) + rest
    return _strip_file_scheme(uri)


def _normal_location(uri: String) -> String:
    """`uri` with a `file:` scheme removed, and without a trailing slash; a
    URI of another scheme as it is."""
    var s = uri
    if _scheme_of(uri) == "file":
        try:
            s = _strip_file_scheme(uri)
        except:
            pass
    return _without_trailing_slash(s)


# =============================================================================
# Resolving a path.
# =============================================================================


def _read_version_hint(dir: String) raises -> Int:
    var hint = dir + String("/metadata/version-hint.text")
    var bytes: List[UInt8]
    try:
        bytes = read_local_file(hint)
    except:
        raise Error(
            ICEBERG_TABLE_VERSION_UNKNOWN
            + String(": ")
            + dir
            + String(" has no metadata/version-hint.text; name the .metadata.json file")
        )
    var start = 0
    var end = len(bytes)
    while start < end and _is_space(bytes[start]):
        start += 1
    while end > start and _is_space(bytes[end - 1]):
        end -= 1
    var text = String(unsafe_from_utf8=Span(bytes)[start:end])
    var n = _digits(text)
    if n < 0:
        raise Error(
            ICEBERG_METADATA_INVALID
            + String(": ")
            + hint
            + String(" does not hold a version number")
        )
    return n


def _is_space(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x0A or b == 0x0D or b == 0x09


def _is_directory(path: String) raises -> Bool:
    try:
        return local_is_dir(path)
    except:
        raise Error(
            ICEBERG_METADATA_INVALID + String(": no table at '") + path + String("'")
        )


def _read_metadata(path: String) raises -> IcebergTableMetadata:
    var bytes: List[UInt8]
    try:
        bytes = read_local_file(path)
    except:
        raise Error(
            ICEBERG_METADATA_INVALID
            + String(": cannot read the metadata file '")
            + path
            + String("'")
        )
    return parse_iceberg_metadata(String(unsafe_from_utf8=Span(bytes)))


def _columns_of(md: IcebergTableMetadata, schema_id: Int) raises -> List[IcebergField]:
    var schema = md.schema_by_id(schema_id)
    return schema.fields.copy()


def _arrow_schema_of(columns: List[IcebergField]) raises -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(columns)):
        sb.add_field(iceberg_arrow_field(columns[i]))
    return sb.build()


def _pinned_ref(
    metadata_path: String,
    table_root: String,
    md: IcebergTableMetadata,
    allow_moved_paths: Bool,
    snapshot_id: Int64,
    schema_id: Int,
) raises -> IcebergTableRef:
    var columns = _columns_of(md, schema_id)
    var arrow = _arrow_schema_of(columns)
    return IcebergTableRef(
        metadata_path,
        table_root,
        md.location,
        allow_moved_paths,
        md.format_version,
        snapshot_id,
        schema_id,
        columns^,
        arrow^,
    )


def resolve_iceberg_table(
    path: String, allow_moved_paths: Bool, snapshot_id: Optional[Int64]
) raises -> IcebergTableRef:
    """Resolve what `iceberg_scan` names to a pinned table (module header).

    Raises:
        ICEBERG_METADATA_INVALID (no such path, or text that is not metadata),
        ICEBERG_TABLE_VERSION_UNKNOWN, ICEBERG_PATH_UNSUPPORTED,
        ICEBERG_SNAPSHOT_NOT_FOUND, ICEBERG_TYPE_UNSUPPORTED and
        OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED (format-version 3)."""
    var local = _strip_file_scheme(path)
    var metadata_path: String
    var table_root: String
    if _is_directory(local):
        table_root = _without_trailing_slash(local)
        var n = _read_version_hint(table_root)
        metadata_path = (
            table_root + String("/metadata/v") + String(n) + String(".metadata.json")
        )
    else:
        metadata_path = local
        var parent = _dirname(local)
        if _basename(parent) == "metadata":
            table_root = _dirname(parent)
        else:
            table_root = parent
    var md = _read_metadata(metadata_path)
    var pinned: Int64 = -1
    var schema_id = md.current_schema_id
    if snapshot_id:
        var snap = md.snapshot_by_id(snapshot_id.value())
        pinned = snap.snapshot_id
        if snap.schema_id:
            schema_id = snap.schema_id.value()
    elif md.current_snapshot_id:
        pinned = md.current_snapshot_id.value()
    return _pinned_ref(
        metadata_path, table_root, md, allow_moved_paths, pinned, schema_id
    )


# =============================================================================
# The binding.
# =============================================================================


def iceberg_scan_binding(table: IcebergTableRef) -> ScanBinding:
    """The `komira.iceberg.table` binding of a pinned table.

    Identity is the metadata path, the table root, `allow_moved_paths`, the
    snapshot and the schema. The gate is the zonemap family's (conjunctive
    comparisons against literals), so the optimizer pushes such conjuncts into
    the scan, where `plan_iceberg_scan` uses them to skip files; the cutter
    re-applies them as an operator, so pruning never changes a result."""
    var params = ScanParams()
    params.put_str(String(PARAM_METADATA_PATH), table.metadata_path)
    params.put_str(String(PARAM_TABLE_ROOT), table.table_root)
    params.put_bool(String(PARAM_ALLOW_MOVED_PATHS), table.allow_moved_paths)
    params.put_i64(String(PARAM_SNAPSHOT_ID), table.snapshot_id)
    params.put_i64(String(PARAM_SCHEMA_ID), Int64(table.schema_id))
    var kind = String(ICEBERG_SCAN_KIND_NAME)
    var fp = params.hash_into(param_hash_string(kind, UInt64(scan_kind_id(kind))))
    var token = UInt64(0)
    if table.snapshot_id >= 0:
        token = UInt64(table.snapshot_id)
    return ScanBinding(
        kind_id=scan_kind_id(kind),
        kind_name=kind,
        name=table.metadata_path,
        params=params^,
        schema=table.arrow_schema.copy(),
        fingerprint=fp,
        structural_id=fp,
        gate=PushdownGate.conjunctive_comparison(False),
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=token,
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )


def is_iceberg_binding(source: SourceVariant) -> Bool:
    """True iff `source` is a binding of the `komira.iceberg.table` kind."""
    if source.tag != SOURCE_VARIANT_BINDING:
        return False
    return source.binding_ref().kind_name == String(ICEBERG_SCAN_KIND_NAME)


struct IcebergPinnedTable(Movable):
    """A table of a binding with the metadata it was pinned from, so a planner
    reads each file once."""

    var table: IcebergTableRef
    var metadata: IcebergTableMetadata

    def __init__(
        out self, var table: IcebergTableRef, var metadata: IcebergTableMetadata
    ):
        self.table = table^
        self.metadata = metadata^


def iceberg_pinned_table_of(binding: ScanBinding) raises -> IcebergPinnedTable:
    """The table a `komira.iceberg.table` binding names, read again: the
    metadata file is re-read and the binding's snapshot and schema are
    re-pinned, so a metadata file that no longer lists them is refused.

    Raises:
        ICEBERG_METADATA_INVALID when the binding is of another kind, and what
        `resolve_iceberg_table` raises."""
    if binding.kind_name != String(ICEBERG_SCAN_KIND_NAME):
        raise Error(
            ICEBERG_METADATA_INVALID
            + String(": a '")
            + binding.kind_name
            + String("' binding is not an Iceberg table")
        )
    var metadata_path = binding.params.get_str(String(PARAM_METADATA_PATH))
    var md = _read_metadata(metadata_path)
    var snapshot_id = binding.params.get_i64(String(PARAM_SNAPSHOT_ID), -1)
    if snapshot_id >= 0:
        _ = md.snapshot_by_id(snapshot_id)
    var table = _pinned_ref(
        metadata_path,
        binding.params.get_str(String(PARAM_TABLE_ROOT)),
        md,
        binding.params.get_bool(String(PARAM_ALLOW_MOVED_PATHS)),
        snapshot_id,
        Int(binding.params.get_i64(String(PARAM_SCHEMA_ID))),
    )
    return IcebergPinnedTable(table^, md^)


def iceberg_table_ref_of(binding: ScanBinding) raises -> IcebergTableRef:
    """`iceberg_pinned_table_of`, without the metadata."""
    var pinned = iceberg_pinned_table_of(binding)
    return pinned.table.copy()
