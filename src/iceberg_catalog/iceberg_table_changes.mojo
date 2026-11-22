# =============================================================================
# iceberg_catalog/iceberg_table_changes.mojo — the requirements and updates of
#   an Iceberg REST commit, and the JSON bodies of the create and commit
#   requests.
# =============================================================================
#
# WHAT THIS IS. Typed `TableRequirement` and `TableUpdate` values, each with
# its JSON as the Iceberg REST OpenAPI spells it (`TableRequirement`,
# `TableUpdate`), the `NewSnapshot` an `add-snapshot` carries, and the request
# bodies built from them (`commit_table_body`, `CreateTableRequest.body`).
#
# A requirement or update is one struct with a kind and the fields its kinds
# use; each is built only through its named constructor, so a value always
# has the fields its kind needs. Schemas, partition specs and sort orders are
# carried as their REST JSON (`JsonValue`): the client sends them as given,
# and the catalog assigns ids.
#
# Member order is fixed, so equal values serialize to equal bytes (the
# committer resends a byte-identical body under the same idempotency key).
# =============================================================================

from json import JsonValue


# =============================================================================
# §0 — TableRequirement.
# =============================================================================


struct TableRequirement(Copyable, Movable):
    """One requirement of a commit: the catalog applies the commit only when
    every requirement holds against the table's current metadata, and answers
    409 otherwise. `kind` is the REST `type`."""

    var kind: String
    var _text: String
    var _id: Optional[Int64]

    def __init__(
        out self, var kind: String, var text: String, id: Optional[Int64]
    ):
        self.kind = kind^
        self._text = text^
        self._id = id

    @staticmethod
    def assert_create() -> TableRequirement:
        """The table must not exist (a staged create's commit)."""
        return TableRequirement(String("assert-create"), String(""), None)

    @staticmethod
    def assert_table_uuid(var uuid: String) -> TableRequirement:
        """The table's uuid must be `uuid`: it was not dropped and recreated."""
        return TableRequirement(String("assert-table-uuid"), uuid^, None)

    @staticmethod
    def assert_ref_snapshot_id(
        var ref_name: String, snapshot_id: Optional[Int64]
    ) -> TableRequirement:
        """The ref `ref_name` must point at `snapshot_id`; None asserts that
        the ref does not exist."""
        return TableRequirement(
            String("assert-ref-snapshot-id"), ref_name^, snapshot_id
        )

    @staticmethod
    def assert_current_schema_id(schema_id: Int) -> TableRequirement:
        return TableRequirement(
            String("assert-current-schema-id"),
            String(""),
            Optional[Int64](Int64(schema_id)),
        )

    @staticmethod
    def assert_last_assigned_field_id(field_id: Int) -> TableRequirement:
        return TableRequirement(
            String("assert-last-assigned-field-id"),
            String(""),
            Optional[Int64](Int64(field_id)),
        )

    @staticmethod
    def assert_default_spec_id(spec_id: Int) -> TableRequirement:
        return TableRequirement(
            String("assert-default-spec-id"),
            String(""),
            Optional[Int64](Int64(spec_id)),
        )

    @staticmethod
    def assert_last_assigned_partition_id(
        partition_id: Int,
    ) -> TableRequirement:
        return TableRequirement(
            String("assert-last-assigned-partition-id"),
            String(""),
            Optional[Int64](Int64(partition_id)),
        )

    def to_json(self) raises -> JsonValue:
        """The requirement as the REST `TableRequirement` object."""
        var o = JsonValue.empty_object()
        o.set_member(String("type"), JsonValue.from_string(String(self.kind)))
        if self.kind == String("assert-table-uuid"):
            o.set_member(
                String("uuid"), JsonValue.from_string(String(self._text))
            )
        elif self.kind == String("assert-ref-snapshot-id"):
            o.set_member(
                String("ref"), JsonValue.from_string(String(self._text))
            )
            o.set_member(String("snapshot-id"), _opt_id(self._id))
        elif self.kind == String("assert-current-schema-id"):
            o.set_member(String("current-schema-id"), _opt_id(self._id))
        elif self.kind == String("assert-last-assigned-field-id"):
            o.set_member(String("last-assigned-field-id"), _opt_id(self._id))
        elif self.kind == String("assert-default-spec-id"):
            o.set_member(String("default-spec-id"), _opt_id(self._id))
        elif self.kind == String("assert-last-assigned-partition-id"):
            o.set_member(
                String("last-assigned-partition-id"), _opt_id(self._id)
            )
        return o^


# =============================================================================
# §1 — NewSnapshot.
# =============================================================================


struct NewSnapshot(Copyable, Movable):
    """The snapshot an `add-snapshot` update adds. `parent_id` is None for a
    snapshot with no parent. The summary's members are written in the order
    given; `operation` comes first."""

    var snapshot_id: Int64
    var parent_id: Optional[Int64]
    var sequence_number: Int64
    var timestamp_ms: Int64
    var schema_id: Int
    var manifest_list: String
    var operation: String
    var summary_names: List[String]
    var summary_values: List[String]

    def __init__(
        out self,
        snapshot_id: Int64,
        parent_id: Optional[Int64],
        sequence_number: Int64,
        timestamp_ms: Int64,
        schema_id: Int,
        var manifest_list: String,
        var operation: String,
        var summary_names: List[String],
        var summary_values: List[String],
    ):
        self.snapshot_id = snapshot_id
        self.parent_id = parent_id
        self.sequence_number = sequence_number
        self.timestamp_ms = timestamp_ms
        self.schema_id = schema_id
        self.manifest_list = manifest_list^
        self.operation = operation^
        self.summary_names = summary_names^
        self.summary_values = summary_values^

    def to_json(self) raises -> JsonValue:
        """The snapshot as the REST `Snapshot` object."""
        var o = JsonValue.empty_object()
        o.set_member(String("snapshot-id"), JsonValue.from_i64(self.snapshot_id))
        if self.parent_id:
            o.set_member(
                String("parent-snapshot-id"),
                JsonValue.from_i64(self.parent_id.value()),
            )
        o.set_member(
            String("sequence-number"), JsonValue.from_i64(self.sequence_number)
        )
        o.set_member(String("timestamp-ms"), JsonValue.from_i64(self.timestamp_ms))
        o.set_member(String("schema-id"), JsonValue.from_i64(Int64(self.schema_id)))
        o.set_member(
            String("manifest-list"),
            JsonValue.from_string(String(self.manifest_list)),
        )
        var summary = JsonValue.empty_object()
        summary.set_member(
            String("operation"), JsonValue.from_string(String(self.operation))
        )
        for i in range(len(self.summary_names)):
            summary.set_member(
                String(self.summary_names[i]),
                JsonValue.from_string(String(self.summary_values[i])),
            )
        o.set_member(String("summary"), summary^)
        return o^


# =============================================================================
# §2 — TableUpdate.
# =============================================================================


struct TableUpdate(Copyable, Movable):
    """One update of a commit, applied in order. `action` is the REST
    `action`."""

    var action: String
    var _text: String
    var _id: Int64
    var _json: JsonValue
    var _names: List[String]
    var _values: List[String]
    var _snapshot: Optional[NewSnapshot]

    def __init__(out self, var action: String):
        self.action = action^
        self._text = String("")
        self._id = 0
        self._json = JsonValue()
        self._names = List[String]()
        self._values = List[String]()
        self._snapshot = None

    @staticmethod
    def assign_uuid(var uuid: String) -> TableUpdate:
        var u = TableUpdate(String("assign-uuid"))
        u._text = uuid^
        return u^

    @staticmethod
    def upgrade_format_version(format_version: Int) -> TableUpdate:
        var u = TableUpdate(String("upgrade-format-version"))
        u._id = Int64(format_version)
        return u^

    @staticmethod
    def add_schema(var schema: JsonValue) -> TableUpdate:
        """Add `schema` (the REST `Schema` object). The deprecated
        `last-column-id` member is not sent."""
        var u = TableUpdate(String("add-schema"))
        u._json = schema^
        return u^

    @staticmethod
    def set_current_schema(schema_id: Int) -> TableUpdate:
        """`-1` means the schema added last in this commit."""
        var u = TableUpdate(String("set-current-schema"))
        u._id = Int64(schema_id)
        return u^

    @staticmethod
    def add_spec(var spec: JsonValue) -> TableUpdate:
        var u = TableUpdate(String("add-spec"))
        u._json = spec^
        return u^

    @staticmethod
    def set_default_spec(spec_id: Int) -> TableUpdate:
        """`-1` means the spec added last in this commit."""
        var u = TableUpdate(String("set-default-spec"))
        u._id = Int64(spec_id)
        return u^

    @staticmethod
    def add_sort_order(var sort_order: JsonValue) -> TableUpdate:
        var u = TableUpdate(String("add-sort-order"))
        u._json = sort_order^
        return u^

    @staticmethod
    def set_default_sort_order(sort_order_id: Int) -> TableUpdate:
        """`-1` means the sort order added last in this commit."""
        var u = TableUpdate(String("set-default-sort-order"))
        u._id = Int64(sort_order_id)
        return u^

    @staticmethod
    def set_location(var location: String) -> TableUpdate:
        var u = TableUpdate(String("set-location"))
        u._text = location^
        return u^

    @staticmethod
    def set_properties(
        var names: List[String], var values: List[String]
    ) -> TableUpdate:
        """Set each property `names[i]` to `values[i]`."""
        var u = TableUpdate(String("set-properties"))
        u._names = names^
        u._values = values^
        return u^

    @staticmethod
    def add_snapshot(var snapshot: NewSnapshot) -> TableUpdate:
        var u = TableUpdate(String("add-snapshot"))
        u._snapshot = Optional[NewSnapshot](snapshot^)
        return u^

    @staticmethod
    def set_branch(var ref_name: String, snapshot_id: Int64) -> TableUpdate:
        """`set-snapshot-ref`: point the branch `ref_name` at
        `snapshot_id`."""
        var u = TableUpdate(String("set-snapshot-ref"))
        u._text = ref_name^
        u._id = snapshot_id
        return u^

    @staticmethod
    def remove_snapshot_ref(var ref_name: String) -> TableUpdate:
        var u = TableUpdate(String("remove-snapshot-ref"))
        u._text = ref_name^
        return u^

    def to_json(self) raises -> JsonValue:
        """The update as the REST `TableUpdate` object."""
        var o = JsonValue.empty_object()
        o.set_member(String("action"), JsonValue.from_string(String(self.action)))
        var a = self.action
        if a == String("assign-uuid"):
            o.set_member(String("uuid"), JsonValue.from_string(String(self._text)))
        elif a == String("upgrade-format-version"):
            o.set_member(String("format-version"), JsonValue.from_i64(self._id))
        elif a == String("add-schema"):
            o.set_member(String("schema"), self._json.copy())
        elif a == String("set-current-schema"):
            o.set_member(String("schema-id"), JsonValue.from_i64(self._id))
        elif a == String("add-spec"):
            o.set_member(String("spec"), self._json.copy())
        elif a == String("set-default-spec"):
            o.set_member(String("spec-id"), JsonValue.from_i64(self._id))
        elif a == String("add-sort-order"):
            o.set_member(String("sort-order"), self._json.copy())
        elif a == String("set-default-sort-order"):
            o.set_member(String("sort-order-id"), JsonValue.from_i64(self._id))
        elif a == String("set-location"):
            o.set_member(
                String("location"), JsonValue.from_string(String(self._text))
            )
        elif a == String("set-properties"):
            o.set_member(String("updates"), _string_map(self._names, self._values))
        elif a == String("add-snapshot"):
            o.set_member(String("snapshot"), self._snapshot.value().to_json())
        elif a == String("set-snapshot-ref"):
            o.set_member(
                String("ref-name"), JsonValue.from_string(String(self._text))
            )
            o.set_member(String("type"), JsonValue.from_string(String("branch")))
            o.set_member(String("snapshot-id"), JsonValue.from_i64(self._id))
        elif a == String("remove-snapshot-ref"):
            o.set_member(
                String("ref-name"), JsonValue.from_string(String(self._text))
            )
        return o^


# =============================================================================
# §3 — request bodies.
# =============================================================================


def commit_table_body(
    requirements: List[TableRequirement], updates: List[TableUpdate]
) raises -> String:
    """The `CommitTableRequest` body: `{"requirements":[...],"updates":[...]}`."""
    var reqs = JsonValue.empty_array()
    for i in range(len(requirements)):
        reqs.push(requirements[i].to_json())
    var ups = JsonValue.empty_array()
    for i in range(len(updates)):
        ups.push(updates[i].to_json())
    var o = JsonValue.empty_object()
    o.set_member(String("requirements"), reqs^)
    o.set_member(String("updates"), ups^)
    return o.serialize()


struct CreateTableRequest(Copyable, Movable):
    """A `CreateTableRequest`: the table's name, its schema (the REST `Schema`
    object), whether the create is staged, and its properties. A staged
    create (`stage_create`) creates nothing: the catalog returns the
    table's initial metadata, and the table appears with the commit that
    carries `assert-create`. `location` is sent only when non-empty; the
    catalog chooses one otherwise."""

    var name: String
    var schema: JsonValue
    var stage_create: Bool
    var location: String
    var property_names: List[String]
    var property_values: List[String]

    def __init__(
        out self,
        var name: String,
        var schema: JsonValue,
        *,
        stage_create: Bool,
    ):
        self.name = name^
        self.schema = schema^
        self.stage_create = stage_create
        self.location = String("")
        self.property_names = List[String]()
        self.property_values = List[String]()

    def set_property(mut self, var name: String, var value: String):
        """Add the property `name` = `value` (sent in the order added)."""
        self.property_names.append(name^)
        self.property_values.append(value^)

    def body(self) raises -> String:
        """The request body as JSON text."""
        var o = JsonValue.empty_object()
        o.set_member(String("name"), JsonValue.from_string(String(self.name)))
        if self.location.byte_length() > 0:
            o.set_member(
                String("location"), JsonValue.from_string(String(self.location))
            )
        o.set_member(String("schema"), self.schema.copy())
        o.set_member(String("stage-create"), JsonValue.from_bool(self.stage_create))
        o.set_member(
            String("properties"),
            _string_map(self.property_names, self.property_values),
        )
        return o.serialize()


# =============================================================================
# §4 — helpers.
# =============================================================================


def _opt_id(id: Optional[Int64]) -> JsonValue:
    """`id` as a JSON number, or JSON null for None."""
    if id:
        return JsonValue.from_i64(id.value())
    return JsonValue.null()


def _string_map(names: List[String], values: List[String]) raises -> JsonValue:
    var o = JsonValue.empty_object()
    for i in range(len(names)):
        o.set_member(String(names[i]), JsonValue.from_string(String(values[i])))
    return o^
