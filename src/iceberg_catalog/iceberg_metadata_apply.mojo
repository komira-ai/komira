# =============================================================================
# iceberg_catalog/iceberg_metadata_apply.mojo — a catalog's side of a commit:
#   check requirements and apply updates to table metadata JSON.
# =============================================================================
#
# WHAT THIS IS. What an Iceberg REST catalog does with a `CommitTableRequest`,
# over the table metadata as a json DOM: `check_requirement` answers whether
# one requirement holds, and `apply_update` applies one update. The in-process
# test catalog (iceberg_rest_test_catalog.mojo) uses them to act as the
# catalog side of every commit the client sends; they are pure (no I/O).
#
# The rules follow the REST spec and Iceberg's TableMetadata builder, for the
# requirements and updates this package sends:
#   * `add-schema` gives the schema the next schema id (one more than the
#     highest, 0 for the first) and raises `last-column-id` to its highest
#     field id; `add-spec` and `add-sort-order` likewise give the next id
#     (a sort order with no fields is order 0), and `add-spec` raises
#     `last-partition-id`. An id of -1 in `set-current-schema`,
#     `set-default-spec` or `set-default-sort-order` means the one added last
#     in this commit.
#   * `add-snapshot` refuses a sequence number not above
#     `last-sequence-number`, and an id the table already has; it advances
#     `last-sequence-number`.
#   * `set-snapshot-ref` and `remove-snapshot-ref` on `main` keep
#     `current-snapshot-id` in step (-1 when `main` is removed).
#
# A refusal raises with the REST error type it would be answered with as the
# first word: `CommitFailedException` (a requirement failed: 409) or
# `BadRequestException` (an update the table cannot take: 400).
# =============================================================================

from json import JsonValue, JSON_ARRAY, JSON_NULL, JSON_OBJECT


comptime COMMIT_FAILED: String = "CommitFailedException"
comptime BAD_REQUEST: String = "BadRequestException"


# =============================================================================
# §0 — DOM helpers (object members by key).
# =============================================================================


def member_index(obj: JsonValue, key: String) -> Int:
    """The index of member `key` of an object, or -1."""
    for i in range(len(obj.obj_keys)):
        if obj.obj_keys[i] == key:
            return i
    return -1


def put_member(mut obj: JsonValue, key: String, var value: JsonValue) raises:
    """Set member `key` of an object, replacing it in place when present."""
    var i = member_index(obj, key)
    if i >= 0:
        obj.children[i] = value^
        return
    obj.set_member(String(key), value^)


def remove_member(mut obj: JsonValue, key: String):
    """Remove member `key` of an object, if present."""
    var i = member_index(obj, key)
    if i < 0:
        return
    _ = obj.obj_keys.pop(i)
    _ = obj.children.pop(i)


def int_member(obj: JsonValue, key: String, default: Int64) raises -> Int64:
    """Member `key` as an integer; `default` when absent or null."""
    var i = member_index(obj, key)
    if i < 0 or obj.children[i].kind_tag() == JSON_NULL:
        return default
    return obj.children[i].as_int64()


def _array_member(mut obj: JsonValue, key: String) raises -> Int:
    """The index of array member `key`, creating `[]` when absent."""
    var i = member_index(obj, key)
    if i < 0:
        obj.set_member(String(key), JsonValue.empty_array())
        return len(obj.obj_keys) - 1
    return i


def _object_member(mut obj: JsonValue, key: String) raises -> Int:
    """The index of object member `key`, creating `{}` when absent."""
    var i = member_index(obj, key)
    if i < 0:
        obj.set_member(String(key), JsonValue.empty_object())
        return len(obj.obj_keys) - 1
    return i


def _max_id(arr: JsonValue, key: String) raises -> Int64:
    """The highest `key` among an array's objects, or -1."""
    var m = Int64(-1)
    for i in range(len(arr.children)):
        var v = int_member(arr.children[i], key, -1)
        if v > m:
            m = v
    return m


# =============================================================================
# §1 — the starting metadata of a new table.
# =============================================================================


def empty_table_metadata() raises -> JsonValue:
    """The metadata a staged create's commit starts from: format version 2,
    no uuid, no location, no schema, spec, sort order or snapshot."""
    var m = JsonValue.empty_object()
    m.set_member(String("format-version"), JsonValue.from_i64(2))
    m.set_member(String("table-uuid"), JsonValue.from_string(String("")))
    m.set_member(String("location"), JsonValue.from_string(String("")))
    m.set_member(String("last-sequence-number"), JsonValue.from_i64(0))
    m.set_member(String("last-column-id"), JsonValue.from_i64(0))
    m.set_member(String("current-schema-id"), JsonValue.from_i64(-1))
    m.set_member(String("schemas"), JsonValue.empty_array())
    m.set_member(String("default-spec-id"), JsonValue.from_i64(0))
    m.set_member(String("partition-specs"), JsonValue.empty_array())
    m.set_member(String("last-partition-id"), JsonValue.from_i64(999))
    m.set_member(String("default-sort-order-id"), JsonValue.from_i64(0))
    m.set_member(String("sort-orders"), JsonValue.empty_array())
    m.set_member(String("properties"), JsonValue.empty_object())
    m.set_member(String("current-snapshot-id"), JsonValue.from_i64(-1))
    m.set_member(String("snapshots"), JsonValue.empty_array())
    m.set_member(String("refs"), JsonValue.empty_object())
    return m^


def unpartitioned_spec() raises -> JsonValue:
    var s = JsonValue.empty_object()
    s.set_member(String("spec-id"), JsonValue.from_i64(0))
    s.set_member(String("fields"), JsonValue.empty_array())
    return s^


def unsorted_order() raises -> JsonValue:
    var s = JsonValue.empty_object()
    s.set_member(String("order-id"), JsonValue.from_i64(0))
    s.set_member(String("fields"), JsonValue.empty_array())
    return s^


# =============================================================================
# §2 — requirements.
# =============================================================================


def ref_snapshot_id(md: JsonValue, ref_name: String) raises -> Optional[Int64]:
    """The snapshot id ref `ref_name` points at, or None."""
    var r = member_index(md, String("refs"))
    if r < 0:
        return None
    var i = member_index(md.children[r], ref_name)
    if i < 0:
        return None
    return Optional[Int64](
        int_member(md.children[r].children[i], String("snapshot-id"), -1)
    )


def check_requirement(
    md: JsonValue, exists: Bool, req: JsonValue
) raises -> String:
    """"" when `req` holds for the table (`exists` False: the table does not
    exist, and `md` is ignored), else why not."""
    var t = req.get(String("type")).as_string()
    if t == String("assert-create"):
        if exists:
            return String("the table already exists")
        return String("")
    if not exists:
        return String("the table does not exist")
    if t == String("assert-table-uuid"):
        var want = req.get(String("uuid")).as_string()
        if md.get(String("table-uuid")).as_string() != want:
            return String("table uuid is not ") + want
        return String("")
    if t == String("assert-ref-snapshot-id"):
        var ref_name = req.get(String("ref")).as_string()
        var have = ref_snapshot_id(md, ref_name)
        var want_i = member_index(req, String("snapshot-id"))
        var want_none = (
            want_i < 0 or req.children[want_i].kind_tag() == JSON_NULL
        )
        if want_none:
            if have:
                return String("ref ") + ref_name + String(" exists")
            return String("")
        var want = req.children[want_i].as_int64()
        if not have or have.value() != want:
            return (
                String("ref ")
                + ref_name
                + String(" is not at snapshot ")
                + String(want)
            )
        return String("")
    if t == String("assert-current-schema-id"):
        return _assert_int(md, req, String("current-schema-id"), String("current-schema-id"))
    if t == String("assert-last-assigned-field-id"):
        return _assert_int(md, req, String("last-column-id"), String("last-assigned-field-id"))
    if t == String("assert-default-spec-id"):
        return _assert_int(md, req, String("default-spec-id"), String("default-spec-id"))
    if t == String("assert-last-assigned-partition-id"):
        return _assert_int(
            md, req, String("last-partition-id"), String("last-assigned-partition-id")
        )
    return String("unknown requirement ") + t


def _assert_int(
    md: JsonValue, req: JsonValue, md_key: String, req_key: String
) raises -> String:
    var want = req.get(req_key).as_int64()
    if int_member(md, md_key, -1) != want:
        return md_key + String(" is not ") + String(want)
    return String("")


# =============================================================================
# §3 — updates.
# =============================================================================


struct ApplyState(Movable):
    """The ids added last in one commit, for the `-1` forms."""

    var last_schema: Int64
    var last_spec: Int64
    var last_order: Int64

    def __init__(out self):
        self.last_schema = -1
        self.last_spec = -1
        self.last_order = -1


def apply_update(
    mut md: JsonValue, mut st: ApplyState, up: JsonValue
) raises:
    """Apply one update to `md` (module header). Raises `BadRequestException
    ...` for an update the table cannot take."""
    var a = up.get(String("action")).as_string()
    if a == String("assign-uuid"):
        put_member(md, String("table-uuid"), up.get(String("uuid")))
    elif a == String("upgrade-format-version"):
        put_member(md, String("format-version"), up.get(String("format-version")))
    elif a == String("add-schema"):
        var i = _array_member(md, String("schemas"))
        var id = _max_id(md.children[i], String("schema-id")) + 1
        var schema = up.get(String("schema"))
        put_member(schema, String("schema-id"), JsonValue.from_i64(id))
        var top = _max_id(schema.get(String("fields")), String("id"))
        if top > int_member(md, String("last-column-id"), 0):
            put_member(md, String("last-column-id"), JsonValue.from_i64(top))
        md.children[i].push(schema^)
        st.last_schema = id
    elif a == String("set-current-schema"):
        var id = up.get(String("schema-id")).as_int64()
        if id == -1:
            id = st.last_schema
        put_member(md, String("current-schema-id"), JsonValue.from_i64(id))
    elif a == String("add-spec"):
        var i = _array_member(md, String("partition-specs"))
        var id = _max_id(md.children[i], String("spec-id")) + 1
        var spec = up.get(String("spec"))
        put_member(spec, String("spec-id"), JsonValue.from_i64(id))
        var top = _max_id(spec.get(String("fields")), String("field-id"))
        if top > int_member(md, String("last-partition-id"), 999):
            put_member(md, String("last-partition-id"), JsonValue.from_i64(top))
        md.children[i].push(spec^)
        st.last_spec = id
    elif a == String("set-default-spec"):
        var id = up.get(String("spec-id")).as_int64()
        if id == -1:
            id = st.last_spec
        put_member(md, String("default-spec-id"), JsonValue.from_i64(id))
    elif a == String("add-sort-order"):
        var i = _array_member(md, String("sort-orders"))
        var order = up.get(String("sort-order"))
        var id = Int64(0)
        if order.get(String("fields")).array_len() > 0:
            id = _max_id(md.children[i], String("order-id")) + 1
            if id == 0:
                id = 1
        put_member(order, String("order-id"), JsonValue.from_i64(id))
        if _index_with(md.children[i], String("order-id"), id) < 0:
            md.children[i].push(order^)
        st.last_order = id
    elif a == String("set-default-sort-order"):
        var id = up.get(String("sort-order-id")).as_int64()
        if id == -1:
            id = st.last_order
        put_member(md, String("default-sort-order-id"), JsonValue.from_i64(id))
    elif a == String("set-location"):
        put_member(md, String("location"), up.get(String("location")))
    elif a == String("set-properties"):
        var i = _object_member(md, String("properties"))
        var u = up.get(String("updates"))
        for k in range(u.num_members()):
            put_member(md.children[i], u.key_at(k), u.value_at(k))
    elif a == String("add-snapshot"):
        _add_snapshot(md, up.get(String("snapshot")))
    elif a == String("set-snapshot-ref"):
        var name = up.get(String("ref-name")).as_string()
        var id = up.get(String("snapshot-id")).as_int64()
        if _index_with(md.get(String("snapshots")), String("snapshot-id"), id) < 0:
            raise Error(
                BAD_REQUEST
                + String(": cannot set ref ")
                + name
                + String(" to unknown snapshot ")
                + String(id)
            )
        var r = JsonValue.empty_object()
        r.set_member(String("snapshot-id"), JsonValue.from_i64(id))
        r.set_member(String("type"), JsonValue.from_string(String("branch")))
        var ri = _object_member(md, String("refs"))
        put_member(md.children[ri], name, r^)
        if name == String("main"):
            put_member(md, String("current-snapshot-id"), JsonValue.from_i64(id))
    elif a == String("remove-snapshot-ref"):
        var name = up.get(String("ref-name")).as_string()
        var ri = _object_member(md, String("refs"))
        remove_member(md.children[ri], name)
        if name == String("main"):
            put_member(md, String("current-snapshot-id"), JsonValue.from_i64(-1))
    else:
        raise Error(BAD_REQUEST + String(": unknown update ") + a)


def _index_with(arr: JsonValue, key: String, id: Int64) raises -> Int:
    """The index of the array's object whose `key` is `id`, or -1."""
    for i in range(len(arr.children)):
        if int_member(arr.children[i], key, -1) == id:
            return i
    return -1


def _add_snapshot(mut md: JsonValue, var snap: JsonValue) raises:
    var seq = int_member(snap, String("sequence-number"), 0)
    var last = int_member(md, String("last-sequence-number"), 0)
    if seq <= last:
        raise Error(
            BAD_REQUEST
            + String(": sequence number ")
            + String(seq)
            + String(" is not above last-sequence-number ")
            + String(last)
        )
    var i = _array_member(md, String("snapshots"))
    var id = snap.get(String("snapshot-id")).as_int64()
    if _index_with(md.children[i], String("snapshot-id"), id) >= 0:
        raise Error(
            BAD_REQUEST + String(": snapshot ") + String(id) + String(" exists")
        )
    md.children[i].push(snap^)
    put_member(md, String("last-sequence-number"), JsonValue.from_i64(seq))


def remove_snapshot(mut md: JsonValue, snapshot_id: Int64) raises:
    """Expire snapshot `snapshot_id`: drop it from `snapshots` (refs that
    point at it are left as they are)."""
    var i = _array_member(md, String("snapshots"))
    var j = _index_with(md.children[i], String("snapshot-id"), snapshot_id)
    if j >= 0:
        _ = md.children[i].children.pop(j)
