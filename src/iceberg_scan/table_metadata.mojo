# =============================================================================
# iceberg_scan/table_metadata.mojo -- the metadata.json of any Iceberg writer
# =============================================================================
#
# WHAT THIS IS. A typed `IcebergTableMetadata`, parsed over json's DOM from the
# text of a `*.metadata.json` file that any writer produced (Java, Spark,
# pyiceberg, this repository's writer): pretty-printed or compact, v1 or v2.
# It keeps what a scan needs: the table's `location`, every schema, every
# partition spec, every snapshot with its manifest list, the snapshot `main`
# points at, and the table's name mapping property.
#
# VERSIONS.
#   * v2 lists `schemas`, `partition-specs` and a `sequence-number` per
#     snapshot. A table that lists no partition spec at all is unpartitioned
#     (one empty spec, `default-spec-id`).
#   * v1 carries one `schema` and one `partition-spec` (a bare array of
#     fields) when the plural members are absent, has no sequence numbers (they
#     read as 0), and may list a snapshot's manifests inline (`manifests`)
#     instead of a `manifest-list`.
#   * format version 3 and above is refused by name:
#     `OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: format-version 3`.
#
# THE CURRENT SNAPSHOT is `refs.main.snapshot-id` when `refs` has a `main`,
# else `current-snapshot-id`, where -1 and null mean none.
#
# TYPES. A schema field's `type_name` is the primitive's spelling with its
# spaces removed (`decimal(9,2)`, `fixed[16]`; Java writes `decimal(9, 2)`),
# or the type's JSON text for a nested type (struct, list, map), which a use
# refuses with ICEBERG_TYPE_UNSUPPORTED.
#
# ERRORS. `ICEBERG_METADATA_INVALID: <what>` for text that is not metadata,
# `ICEBERG_SNAPSHOT_NOT_FOUND: <id>` for a snapshot the table does not list.
# =============================================================================

from json import (
    JsonValue,
    parse_json_value,
    JSON_ARRAY,
    JSON_BOOL,
    JSON_NULL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
)


comptime ICEBERG_METADATA_INVALID: String = "ICEBERG_METADATA_INVALID"
comptime ICEBERG_SNAPSHOT_NOT_FOUND: String = "ICEBERG_SNAPSHOT_NOT_FOUND"
comptime OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: String = (
    "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED"
)
comptime NAME_MAPPING_PROPERTY: String = "schema.name-mapping.default"


struct IcebergField(Copyable, Movable):
    """One top-level column of a schema."""

    var id: Int
    var name: String
    var required: Bool
    var type_name: String

    def __init__(
        out self, id: Int, var name: String, required: Bool, var type_name: String
    ):
        self.id = id
        self.name = name^
        self.required = required
        self.type_name = type_name^


struct IcebergSchemaDef(Copyable, Movable):
    """A schema of the table: its id and its top-level columns."""

    var schema_id: Int
    var fields: List[IcebergField]

    def __init__(out self, schema_id: Int, var fields: List[IcebergField]):
        self.schema_id = schema_id
        self.fields = fields^


struct IcebergPartitionField(Copyable, Movable):
    """One field of a partition spec: the source column's id, the partition
    field's id and name, and the transform's spelling (`identity`,
    `bucket[16]`, `day`, ...)."""

    var source_id: Int
    var field_id: Int
    var name: String
    var transform: String

    def __init__(
        out self,
        source_id: Int,
        field_id: Int,
        var name: String,
        var transform: String,
    ):
        self.source_id = source_id
        self.field_id = field_id
        self.name = name^
        self.transform = transform^


struct IcebergPartitionSpecDef(Copyable, Movable):
    """A partition spec of the table: its id and its fields."""

    var spec_id: Int
    var fields: List[IcebergPartitionField]

    def __init__(out self, spec_id: Int, var fields: List[IcebergPartitionField]):
        self.spec_id = spec_id
        self.fields = fields^


struct IcebergSnapshotDef(Copyable, Movable):
    """A snapshot of the table. `manifest_list` is "" for a v1 snapshot that
    lists `manifests` inline; `sequence_number` is 0 in a v1 table."""

    var snapshot_id: Int64
    var sequence_number: Int64
    var schema_id: Optional[Int]
    var manifest_list: String
    var manifests: List[String]

    def __init__(
        out self,
        snapshot_id: Int64,
        sequence_number: Int64,
        schema_id: Optional[Int],
        var manifest_list: String,
        var manifests: List[String],
    ):
        self.snapshot_id = snapshot_id
        self.sequence_number = sequence_number
        self.schema_id = schema_id
        self.manifest_list = manifest_list^
        self.manifests = manifests^


struct IcebergTableMetadata(Copyable, Movable):
    """The parts of a table's metadata a scan reads (module header)."""

    var format_version: Int
    var location: String
    var current_snapshot_id: Optional[Int64]
    var current_schema_id: Int
    var schemas: List[IcebergSchemaDef]
    var specs: List[IcebergPartitionSpecDef]
    var default_spec_id: Int
    var snapshots: List[IcebergSnapshotDef]
    var name_mapping: String
    """`properties["schema.name-mapping.default"]`, or "" when unset."""

    def __init__(out self):
        self.format_version = 2
        self.location = String("")
        self.current_snapshot_id = None
        self.current_schema_id = 0
        self.schemas = List[IcebergSchemaDef]()
        self.specs = List[IcebergPartitionSpecDef]()
        self.default_spec_id = 0
        self.snapshots = List[IcebergSnapshotDef]()
        self.name_mapping = String("")

    def schema_by_id(self, id: Int) raises -> IcebergSchemaDef:
        """The schema `id`, or `ICEBERG_METADATA_INVALID`."""
        for i in range(len(self.schemas)):
            if self.schemas[i].schema_id == id:
                return self.schemas[i].copy()
        raise Error(_invalid(String("the table has no schema ") + String(id)))

    def spec_by_id(self, id: Int) raises -> IcebergPartitionSpecDef:
        """The partition spec `id`, or `ICEBERG_METADATA_INVALID`."""
        for i in range(len(self.specs)):
            if self.specs[i].spec_id == id:
                return self.specs[i].copy()
        raise Error(
            _invalid(String("the table has no partition spec ") + String(id))
        )

    def snapshot_by_id(self, id: Int64) raises -> IcebergSnapshotDef:
        """The snapshot `id`, or `ICEBERG_SNAPSHOT_NOT_FOUND`."""
        for i in range(len(self.snapshots)):
            if self.snapshots[i].snapshot_id == id:
                return self.snapshots[i].copy()
        raise Error(
            ICEBERG_SNAPSHOT_NOT_FOUND
            + String(": the table has no snapshot ")
            + String(id)
        )


# =============================================================================
# The parser.
# =============================================================================


def parse_iceberg_metadata(text: String) raises -> IcebergTableMetadata:
    """Parse the text of a metadata.json (module header).

    Raises:
        `ICEBERG_METADATA_INVALID: ...` for text that is not JSON or not
        metadata, and `OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: format-version N`
        for a table of format version 3 or above."""
    var root: JsonValue
    try:
        root = parse_json_value(text)
    except e:
        raise Error(_invalid(String("not JSON: ") + String(e)))
    return parse_iceberg_metadata_value(root)


def parse_iceberg_metadata_value(m: JsonValue) raises -> IcebergTableMetadata:
    """As `parse_iceberg_metadata`, over a parsed document."""
    if m.kind_tag() != JSON_OBJECT:
        raise Error(_invalid(String("the document is not a JSON object")))
    var t = IcebergTableMetadata()
    t.format_version = _req_int(m, String("format-version"))
    if t.format_version >= 3:
        raise Error(
            OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED
            + String(": format-version ")
            + String(t.format_version)
        )
    if t.format_version < 1:
        raise Error(
            _invalid(String("format-version ") + String(t.format_version))
        )
    t.location = _opt_string(m, String("location"))

    if m.has(String("schemas")):
        var arr = _member(m, String("schemas"), JSON_ARRAY)
        for i in range(arr.array_len()):
            t.schemas.append(_parse_schema(arr.element_at(i)))
    elif m.has(String("schema")):
        t.schemas.append(
            _parse_schema(_member(m, String("schema"), JSON_OBJECT))
        )
    if m.has(String("current-schema-id")):
        t.current_schema_id = _req_int(m, String("current-schema-id"))
    elif len(t.schemas) > 0:
        t.current_schema_id = t.schemas[0].schema_id

    if m.has(String("partition-specs")):
        var arr = _member(m, String("partition-specs"), JSON_ARRAY)
        for i in range(arr.array_len()):
            t.specs.append(_parse_spec(arr.element_at(i)))
    elif m.has(String("partition-spec")):
        var fields = _member(m, String("partition-spec"), JSON_ARRAY)
        t.specs.append(IcebergPartitionSpecDef(0, _parse_spec_fields(fields)))
    t.default_spec_id = Int(_opt_int64(m, String("default-spec-id"), 0))
    if len(t.specs) == 0:
        # A v1 table written without a spec is unpartitioned.
        t.specs.append(
            IcebergPartitionSpecDef(t.default_spec_id, List[IcebergPartitionField]())
        )

    if m.has(String("properties")):
        var props = _member(m, String("properties"), JSON_OBJECT)
        if props.has(NAME_MAPPING_PROPERTY):
            var v = props.get(NAME_MAPPING_PROPERTY)
            if v.kind_tag() == JSON_STRING:
                t.name_mapping = v.as_string()

    if m.has(String("snapshots")):
        var snaps = _member(m, String("snapshots"), JSON_ARRAY)
        for i in range(snaps.array_len()):
            t.snapshots.append(_parse_snapshot(snaps.element_at(i)))

    t.current_snapshot_id = _current_snapshot_id(m)
    return t^


def _current_snapshot_id(m: JsonValue) raises -> Optional[Int64]:
    """`refs.main.snapshot-id` when `refs` has a `main`; else
    `current-snapshot-id`, with -1 and null read as none."""
    if m.has(String("refs")):
        var refs = _member(m, String("refs"), JSON_OBJECT)
        if refs.has(String("main")):
            var main_ref = _member(refs, String("main"), JSON_OBJECT)
            return Optional[Int64](_req_int64(main_ref, String("snapshot-id")))
    if not m.has(String("current-snapshot-id")):
        return None
    var v = m.get(String("current-snapshot-id"))
    if v.kind_tag() == JSON_NULL:
        return None
    var id = _req_int64(m, String("current-snapshot-id"))
    if id == -1:
        return None
    return Optional[Int64](id)


def _parse_schema(s: JsonValue) raises -> IcebergSchemaDef:
    if s.kind_tag() != JSON_OBJECT:
        raise Error(_invalid(String("a schema is not a JSON object")))
    var schema_id = Int(_opt_int64(s, String("schema-id"), 0))
    var fields = List[IcebergField]()
    if s.has(String("fields")):
        var arr = _member(s, String("fields"), JSON_ARRAY)
        for i in range(arr.array_len()):
            var f = arr.element_at(i)
            if f.kind_tag() != JSON_OBJECT:
                raise Error(_invalid(String("a schema field is not a JSON object")))
            var tv = f.get(String("type")) if f.has(String("type")) else JsonValue()
            var type_name: String
            if tv.kind_tag() == JSON_STRING:
                type_name = _without_spaces(tv.as_string())
            elif tv.kind_tag() == JSON_OBJECT:
                type_name = tv.serialize()
            else:
                raise Error(_invalid(String("a schema field has no type")))
            var required = False
            if f.has(String("required")):
                var rv = f.get(String("required"))
                if rv.kind_tag() == JSON_BOOL:
                    required = rv.as_bool()
            fields.append(
                IcebergField(
                    _req_int(f, String("id")),
                    _opt_string(f, String("name")),
                    required,
                    type_name^,
                )
            )
    return IcebergSchemaDef(schema_id, fields^)


def _parse_spec(s: JsonValue) raises -> IcebergPartitionSpecDef:
    if s.kind_tag() != JSON_OBJECT:
        raise Error(_invalid(String("a partition spec is not a JSON object")))
    var spec_id = Int(_opt_int64(s, String("spec-id"), 0))
    if not s.has(String("fields")):
        return IcebergPartitionSpecDef(spec_id, List[IcebergPartitionField]())
    var fields = _member(s, String("fields"), JSON_ARRAY)
    return IcebergPartitionSpecDef(spec_id, _parse_spec_fields(fields))


def _parse_spec_fields(arr: JsonValue) raises -> List[IcebergPartitionField]:
    var out = List[IcebergPartitionField]()
    for i in range(arr.array_len()):
        var f = arr.element_at(i)
        if f.kind_tag() != JSON_OBJECT:
            raise Error(
                _invalid(String("a partition field is not a JSON object"))
            )
        out.append(
            IcebergPartitionField(
                _req_int(f, String("source-id")),
                Int(_opt_int64(f, String("field-id"), Int64(1000 + i))),
                _opt_string(f, String("name")),
                _without_spaces(_opt_string(f, String("transform"))),
            )
        )
    return out^


def _parse_snapshot(s: JsonValue) raises -> IcebergSnapshotDef:
    if s.kind_tag() != JSON_OBJECT:
        raise Error(_invalid(String("a snapshot is not a JSON object")))
    var schema_id: Optional[Int] = None
    if s.has(String("schema-id")):
        schema_id = Optional[Int](_req_int(s, String("schema-id")))
    var manifests = List[String]()
    if s.has(String("manifests")):
        var arr = _member(s, String("manifests"), JSON_ARRAY)
        for i in range(arr.array_len()):
            var v = arr.element_at(i)
            if v.kind_tag() != JSON_STRING:
                raise Error(_invalid(String("a manifest path is not a string")))
            manifests.append(v.as_string())
    return IcebergSnapshotDef(
        _req_int64(s, String("snapshot-id")),
        _opt_int64(s, String("sequence-number"), 0),
        schema_id,
        _opt_string(s, String("manifest-list")),
        manifests^,
    )


# =============================================================================
# Member readers.
# =============================================================================


def _invalid(what: String) -> String:
    return ICEBERG_METADATA_INVALID + String(": ") + what


def _without_spaces(s: String) -> String:
    var out = List[UInt8]()
    for b in s.as_bytes():
        if b != 0x20:
            out.append(b)
    return String(unsafe_from_utf8=Span(out))


def _member(obj: JsonValue, name: String, kind: Int) raises -> JsonValue:
    """The member `name`, which must be present with JSON kind `kind`."""
    if not obj.has(name):
        raise Error(_invalid(String("'") + name + String("' is missing")))
    var v = obj.get(name)
    if v.kind_tag() != kind:
        raise Error(
            _invalid(String("'") + name + String("' has the wrong JSON type"))
        )
    return v^


def _req_int64(obj: JsonValue, name: String) raises -> Int64:
    var v = _member(obj, name, JSON_NUMBER)
    try:
        return v.as_int64()
    except:
        raise Error(
            _invalid(String("'") + name + String("' is not a 64-bit integer"))
        )


def _req_int(obj: JsonValue, name: String) raises -> Int:
    return Int(_req_int64(obj, name))


def _opt_int64(obj: JsonValue, name: String, default: Int64) raises -> Int64:
    if not obj.has(name):
        return default
    return _req_int64(obj, name)


def _opt_string(obj: JsonValue, name: String) raises -> String:
    if not obj.has(name):
        return String("")
    return _member(obj, name, JSON_STRING).as_string()
