# =============================================================================
# iceberg_catalog/iceberg_table_metadata.mojo — the parts of an Iceberg table's
#   metadata the committer reads, parsed from a REST load or commit response.
# =============================================================================
#
# WHAT THIS IS. A typed `TableMetadata`, read from the `metadata` object of a
# loadTable, createTable or commitTable response (the table spec's
# metadata.json, v1 or v2), over json's DOM. It keeps what a commit needs:
# the table's identity (uuid, format version, location), the counters a
# commit asserts or advances (last sequence number, last column id, current
# schema id, default spec id, last partition id), the top-level columns of
# every schema, the table properties, every snapshot with its parent,
# sequence number, timestamp, manifest list and summary, and the snapshot
# `main` points at.
#
# Two rules of the spec (docs/design/iceberg_tables.md, "Load"):
#   * `main` is `refs.main`, else `current-snapshot-id` when `refs` is absent
#     (the spec says a `main` branch always exists);
#   * a `current-snapshot-id` of -1 means none, as older writers spell it.
#
# A member this parser does not need is ignored; a member it needs with the
# wrong JSON kind raises `ICEBERG_CATALOG_RESPONSE_INVALID`.
# =============================================================================

from json import (
    JsonValue,
    parse_json_value,
    JSON_ARRAY,
    JSON_NULL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
)

from .iceberg_rest_errors import ICEBERG_CATALOG_RESPONSE_INVALID


# =============================================================================
# §0 — the values.
# =============================================================================


struct SchemaField(Copyable, Movable):
    """One top-level column of a schema: its field id, name, whether it is
    required, and its type as the spec spells it (`int`, `long`,
    `decimal(9,2)`, ...). A nested type keeps its JSON text."""

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


struct TableSchema(Copyable, Movable):
    """A schema of the table: its id and its top-level columns."""

    var schema_id: Int
    var fields: List[SchemaField]

    def __init__(out self, schema_id: Int, var fields: List[SchemaField]):
        self.schema_id = schema_id
        self.fields = fields^

    def field_by_id(self, id: Int) -> Int:
        """The index of the column with field id `id`, or -1."""
        for i in range(len(self.fields)):
            if self.fields[i].id == id:
                return i
        return -1


struct TableSnapshot(Copyable, Movable):
    """A snapshot of the table, as its metadata lists it. `parent_id` is None
    for a snapshot with no parent; `sequence_number` is 0 in a v1 table.
    `summary_names`/`summary_values` are the summary's string members, the
    operation among them."""

    var snapshot_id: Int64
    var parent_id: Optional[Int64]
    var sequence_number: Int64
    var timestamp_ms: Int64
    var manifest_list: String
    var summary_names: List[String]
    var summary_values: List[String]

    def __init__(
        out self,
        snapshot_id: Int64,
        parent_id: Optional[Int64],
        sequence_number: Int64,
        timestamp_ms: Int64,
        var manifest_list: String,
        var summary_names: List[String],
        var summary_values: List[String],
    ):
        self.snapshot_id = snapshot_id
        self.parent_id = parent_id
        self.sequence_number = sequence_number
        self.timestamp_ms = timestamp_ms
        self.manifest_list = manifest_list^
        self.summary_names = summary_names^
        self.summary_values = summary_values^

    def summary(self, name: String) -> Optional[String]:
        """The summary member `name`, or None."""
        for i in range(len(self.summary_names)):
            if self.summary_names[i] == name:
                return Optional[String](String(self.summary_values[i]))
        return None


struct TableMetadata(Copyable, Movable):
    """The parts of a table's metadata a commit reads (module header)."""

    var format_version: Int
    var table_uuid: String
    var location: String
    var last_sequence_number: Int64
    var last_column_id: Int
    var current_schema_id: Int
    var default_spec_id: Int
    var last_partition_id: Int
    var schemas: List[TableSchema]
    var property_names: List[String]
    var property_values: List[String]
    var snapshots: List[TableSnapshot]
    var main_snapshot_id: Optional[Int64]

    def __init__(out self):
        """An empty v2 metadata: no uuid, no schema, no snapshot."""
        self.format_version = 2
        self.table_uuid = String("")
        self.location = String("")
        self.last_sequence_number = 0
        self.last_column_id = 0
        self.current_schema_id = 0
        self.default_spec_id = 0
        self.last_partition_id = 0
        self.schemas = List[TableSchema]()
        self.property_names = List[String]()
        self.property_values = List[String]()
        self.snapshots = List[TableSnapshot]()
        self.main_snapshot_id = None

    def property(self, name: String) -> Optional[String]:
        """The table property `name`, or None."""
        for i in range(len(self.property_names)):
            if self.property_names[i] == name:
                return Optional[String](String(self.property_values[i]))
        return None

    def snapshot_index(self, snapshot_id: Int64) -> Int:
        """The index in `snapshots` of the snapshot `snapshot_id`, or -1."""
        for i in range(len(self.snapshots)):
            if self.snapshots[i].snapshot_id == snapshot_id:
                return i
        return -1

    def schema_index(self, schema_id: Int) -> Int:
        """The index in `schemas` of the schema `schema_id`, or -1."""
        for i in range(len(self.schemas)):
            if self.schemas[i].schema_id == schema_id:
                return i
        return -1

    def main_ancestry(self) -> List[Int64]:
        """The ids of `main`'s snapshot and its ancestors, newest first,
        following each parent while the table still lists it. Stops at a
        parent the table no longer lists (expired), and after as many steps
        as there are snapshots, so a parent cycle in a malformed metadata
        cannot loop."""
        var out = List[Int64]()
        if not self.main_snapshot_id:
            return out^
        var cur = self.main_snapshot_id.value()
        var steps = 0
        while steps <= len(self.snapshots):
            out.append(cur)
            var i = self.snapshot_index(cur)
            if i < 0:
                break
            if not self.snapshots[i].parent_id:
                break
            cur = self.snapshots[i].parent_id.value()
            steps += 1
        return out^

    def in_main_ancestry(self, snapshot_id: Int64) -> Bool:
        """True iff `snapshot_id` is `main` or an ancestor of `main`, and the
        table still lists it."""
        if self.snapshot_index(snapshot_id) < 0:
            return False
        var anc = self.main_ancestry()
        for i in range(len(anc)):
            if anc[i] == snapshot_id:
                return True
        return False

    def find_in_main_ancestry(
        self, summary_name: String, summary_value: String
    ) -> Optional[Int64]:
        """The id of the newest snapshot in `main`'s ancestry whose summary
        has `summary_name` = `summary_value`, or None."""
        var anc = self.main_ancestry()
        for i in range(len(anc)):
            var j = self.snapshot_index(anc[i])
            if j < 0:
                continue
            var v = self.snapshots[j].summary(summary_name)
            if v and v.value() == summary_value:
                return Optional[Int64](anc[i])
        return None


# =============================================================================
# §1 — the parser.
# =============================================================================


def parse_table_metadata_text(text: String) raises -> TableMetadata:
    """Parse metadata JSON text (module header). Raises
    `ICEBERG_CATALOG_RESPONSE_INVALID` when it is not a JSON object."""
    var root: JsonValue
    try:
        root = parse_json_value(text)
    except:
        raise Error(
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": table metadata is not JSON")
        )
    return parse_table_metadata(root)


def parse_table_metadata(m: JsonValue) raises -> TableMetadata:
    """Parse the `metadata` object of a REST response (module header)."""
    if m.kind_tag() != JSON_OBJECT:
        raise Error(_invalid(String("table metadata is not a JSON object")))
    var t = TableMetadata()
    t.format_version = _req_int(m, String("format-version"))
    t.table_uuid = _opt_string(m, String("table-uuid"))
    t.location = _opt_string(m, String("location"))
    t.last_sequence_number = _opt_int64(m, String("last-sequence-number"), 0)
    t.last_column_id = Int(_opt_int64(m, String("last-column-id"), 0))
    t.default_spec_id = Int(_opt_int64(m, String("default-spec-id"), 0))
    t.last_partition_id = Int(_opt_int64(m, String("last-partition-id"), 0))

    # Schemas: v2 lists them under `schemas`; v1 may carry one `schema`.
    if m.has(String("schemas")):
        var arr = _member(m, String("schemas"), JSON_ARRAY)
        for i in range(arr.array_len()):
            t.schemas.append(_parse_schema(arr.element_at(i)))
    elif m.has(String("schema")):
        t.schemas.append(_parse_schema(_member(m, String("schema"), JSON_OBJECT)))
    if m.has(String("current-schema-id")):
        t.current_schema_id = _req_int(m, String("current-schema-id"))
    elif len(t.schemas) > 0:
        t.current_schema_id = t.schemas[0].schema_id

    if m.has(String("properties")):
        var props = _member(m, String("properties"), JSON_OBJECT)
        for i in range(props.num_members()):
            if props.value_kind(i) != JSON_STRING:
                continue
            t.property_names.append(props.key_at(i))
            t.property_values.append(props.value_at(i).as_string())

    if m.has(String("snapshots")):
        var snaps = _member(m, String("snapshots"), JSON_ARRAY)
        for i in range(snaps.array_len()):
            t.snapshots.append(_parse_snapshot(snaps.element_at(i)))

    t.main_snapshot_id = _main_snapshot_id(m)
    return t^


def _main_snapshot_id(m: JsonValue) raises -> Optional[Int64]:
    """`refs.main.snapshot-id` when `refs` is present (None when it has no
    `main`); else `current-snapshot-id`, with -1 and null read as none."""
    if m.has(String("refs")):
        var refs = _member(m, String("refs"), JSON_OBJECT)
        if not refs.has(String("main")):
            return None
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


def _parse_schema(s: JsonValue) raises -> TableSchema:
    if s.kind_tag() != JSON_OBJECT:
        raise Error(_invalid(String("a schema is not a JSON object")))
    var schema_id = Int(_opt_int64(s, String("schema-id"), 0))
    var fields = List[SchemaField]()
    if s.has(String("fields")):
        var arr = _member(s, String("fields"), JSON_ARRAY)
        for i in range(arr.array_len()):
            var f = arr.element_at(i)
            if f.kind_tag() != JSON_OBJECT:
                raise Error(_invalid(String("a schema field is not a JSON object")))
            var type_name: String
            var tv = f.get(String("type")) if f.has(String("type")) else JsonValue()
            if tv.kind_tag() == JSON_STRING:
                type_name = tv.as_string()
            elif tv.kind_tag() == JSON_OBJECT:
                type_name = tv.serialize()
            else:
                raise Error(_invalid(String("a schema field has no type")))
            var required = False
            if f.has(String("required")):
                required = f.get(String("required")).as_bool()
            fields.append(
                SchemaField(
                    _req_int(f, String("id")),
                    _opt_string(f, String("name")),
                    required,
                    type_name^,
                )
            )
    return TableSchema(schema_id, fields^)


def _parse_snapshot(s: JsonValue) raises -> TableSnapshot:
    if s.kind_tag() != JSON_OBJECT:
        raise Error(_invalid(String("a snapshot is not a JSON object")))
    var parent: Optional[Int64] = None
    if s.has(String("parent-snapshot-id")):
        if s.get(String("parent-snapshot-id")).kind_tag() != JSON_NULL:
            parent = Optional[Int64](_req_int64(s, String("parent-snapshot-id")))
    var names = List[String]()
    var values = List[String]()
    if s.has(String("summary")):
        var sm = _member(s, String("summary"), JSON_OBJECT)
        for i in range(sm.num_members()):
            if sm.value_kind(i) != JSON_STRING:
                continue
            names.append(sm.key_at(i))
            values.append(sm.value_at(i).as_string())
    return TableSnapshot(
        _req_int64(s, String("snapshot-id")),
        parent,
        _opt_int64(s, String("sequence-number"), 0),
        _opt_int64(s, String("timestamp-ms"), 0),
        _opt_string(s, String("manifest-list")),
        names^,
        values^,
    )


# =============================================================================
# §2 — member readers.
# =============================================================================


def _invalid(what: String) -> String:
    return ICEBERG_CATALOG_RESPONSE_INVALID + String(": ") + what


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
