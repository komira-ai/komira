# =============================================================================
# iceberg_catalog/iceberg_rest_test_catalog.mojo — an in-process Iceberg REST
#   catalog, for tests: it applies commits and can be scripted to fail.
# =============================================================================
#
# WHAT THIS IS. `InMemoryIcebergRestCatalog`, an `IcebergRestTransport` that
# answers the client's requests the way an Iceberg REST catalog does, with
# its tables in memory (docs/design/iceberg_tables.md, "Tests"):
#
#   * GET /v1/config: the `prefix` override, and `endpoints` and
#     `idempotency-key-lifetime` when set (`list_endpoints`,
#     `advertise_idempotency`).
#   * GET .../namespaces/{ns}/tables/{t}: the table's metadata location and
#     metadata; 404 `NoSuchNamespaceException` or `NoSuchTableException`.
#   * POST .../namespaces/{ns}/tables: a create. A staged create stores
#     nothing and returns the initial metadata with no location; a direct
#     create stores the table. 409 `AlreadyExistsException` when it exists.
#   * POST .../namespaces/{ns}/tables/{t}: a commit. Every requirement is
#     checked (409 `CommitFailedException` when one fails), then the updates
#     are applied in order (400 `BadRequestException` when one cannot be),
#     the new metadata gets the next location
#     (`<location>/metadata/v<N>.metadata.json`), and the pointer swaps. A
#     commit with `assert-create` creates the table.
#   * An `Idempotency-Key` seen before, while idempotency is advertised, is
#     answered with the stored response, and nothing is applied again.
#
# SCRIPTING. `before_next_commit` queues another writer's commit body, applied
# to the table just before the next commit request is handled (a concurrent
# append, schema change or spec change between a load and a commit).
# `fault_next_commit` queues how the next commit request is answered: a
# status (409, 500, 503, ...) or a dropped connection (status 0, which raises
# from `send`), before or after the commit is applied, optionally with the
# catalog rewriting the added snapshot's id, then another writer's commit,
# and an expired snapshot.
#
# Every request is recorded (method, path, body, idempotency key), and every
# applied commit is counted.
# =============================================================================

from json import JsonValue, parse_json_value, JSON_OBJECT

from .iceberg_metadata_apply import (
    ApplyState,
    COMMIT_FAILED,
    BAD_REQUEST,
    apply_update,
    check_requirement,
    empty_table_metadata,
    member_index,
    put_member,
    remove_snapshot,
    unpartitioned_spec,
    unsorted_order,
)
from .iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
    IcebergRestTransport,
)
from .iceberg_table_metadata import TableMetadata, parse_table_metadata


struct CommitFault(Copyable, Movable):
    """How one commit request is answered (`fault_next_commit`).

      * `status`: the status to answer with; 0 drops the connection (`send`
        raises).
      * `apply_first`: apply the commit before answering (the answer is then
        a lie about a commit that landed).
      * `rewrite_snapshot_id`: when non-zero, the catalog stores the added
        snapshot under this id instead (its summary is kept).
      * `then_body`: another writer's commit body applied after this one
        ("" for none).
      * `then_expire`: a snapshot id removed afterwards (0 for none)."""

    var status: Int
    var apply_first: Bool
    var rewrite_snapshot_id: Int64
    var then_body: String
    var then_expire: Int64

    def __init__(
        out self,
        status: Int,
        *,
        apply_first: Bool,
        rewrite_snapshot_id: Int64 = 0,
        then_body: String = String(""),
        then_expire: Int64 = 0,
    ):
        self.status = status
        self.apply_first = apply_first
        self.rewrite_snapshot_id = rewrite_snapshot_id
        self.then_body = String(then_body)
        self.then_expire = then_expire


struct _Table(Copyable, Movable):
    var namespace: String
    var name: String
    var metadata: JsonValue
    var version: Int

    def __init__(
        out self, var namespace: String, var name: String, var metadata: JsonValue
    ):
        self.namespace = namespace^
        self.name = name^
        self.metadata = metadata^
        self.version = 1

    def location(self) raises -> String:
        return (
            self.metadata.get(String("location")).as_string()
            + String("/metadata/v")
            + String(self.version)
            + String(".metadata.json")
        )


struct InMemoryIcebergRestCatalog(IcebergRestTransport, Movable):
    """The in-process catalog (module header)."""

    var _prefix: String
    var _warehouse_root: String
    var _endpoints: Optional[List[String]]
    var _idempotency: Bool
    var _namespaces: List[String]
    var _tables: List[_Table]
    var _uuid_counter: Int
    var _before: List[String]
    var _faults: List[CommitFault]
    var _idem_keys: List[String]
    var _idem_status: List[Int]
    var _idem_body: List[String]
    var applied_commits: Int
    var request_methods: List[String]
    var request_paths: List[String]
    var request_bodies: List[String]
    var request_keys: List[String]

    def __init__(out self, var prefix: String, var warehouse_root: String):
        """A catalog whose config names `prefix`, and whose tables are created
        under `<warehouse_root>/<namespace>/<table>`."""
        self._prefix = prefix^
        self._warehouse_root = warehouse_root^
        self._endpoints = None
        self._idempotency = False
        self._namespaces = List[String]()
        self._tables = List[_Table]()
        self._uuid_counter = 0
        self._before = List[String]()
        self._faults = List[CommitFault]()
        self._idem_keys = List[String]()
        self._idem_status = List[Int]()
        self._idem_body = List[String]()
        self.applied_commits = 0
        self.request_methods = List[String]()
        self.request_paths = List[String]()
        self.request_bodies = List[String]()
        self.request_keys = List[String]()

    # -------------------------------------------------------------------------
    # setup and scripting.
    # -------------------------------------------------------------------------

    def create_namespace(mut self, var namespace: String):
        self._namespaces.append(namespace^)

    def list_endpoints(mut self, var endpoints: List[String]):
        """Answer config with this `endpoints` list."""
        self._endpoints = Optional[List[String]](endpoints^)

    def advertise_idempotency(mut self):
        """Answer config with `idempotency-key-lifetime`, and honour keys."""
        self._idempotency = True

    def before_next_commit(mut self, var body: String):
        """Apply this commit body (another writer's) to the target table just
        before the next commit request is handled."""
        self._before.append(body^)

    def fault_next_commit(mut self, var fault: CommitFault):
        """Answer the next commit request as `fault` says (FIFO)."""
        self._faults.append(fault^)

    # -------------------------------------------------------------------------
    # inspection.
    # -------------------------------------------------------------------------

    def has_table(self, namespace: String, name: String) -> Bool:
        return self._find(namespace, name) >= 0

    def metadata_json(self, namespace: String, name: String) raises -> String:
        var i = self._find(namespace, name)
        if i < 0:
            raise Error("InMemoryIcebergRestCatalog: no table " + name)
        return self._tables[i].metadata.serialize()

    def metadata(self, namespace: String, name: String) raises -> TableMetadata:
        var i = self._find(namespace, name)
        if i < 0:
            raise Error("InMemoryIcebergRestCatalog: no table " + name)
        return parse_table_metadata(self._tables[i].metadata)

    def expire_snapshot(
        mut self, namespace: String, name: String, snapshot_id: Int64
    ) raises:
        var i = self._find(namespace, name)
        if i >= 0:
            remove_snapshot(self._tables[i].metadata, snapshot_id)

    def request_count(self) -> Int:
        return len(self.request_paths)

    # -------------------------------------------------------------------------
    # the transport.
    # -------------------------------------------------------------------------

    def send(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        self.request_methods.append(request.method.name())
        self.request_paths.append(String(request.path))
        self.request_bodies.append(String(request.body))
        var key = request.header_value(String("Idempotency-Key"))
        self.request_keys.append(key)
        if self._idempotency and key.byte_length() > 0:
            for i in range(len(self._idem_keys)):
                if self._idem_keys[i] == key:
                    return IcebergRestResponse(
                        self._idem_status[i], String(self._idem_body[i])
                    )
        var path = String(request.path)
        if path == String("/v1/config") or path.startswith(
            String("/v1/config?")
        ):
            return IcebergRestResponse(200, self._config_body())
        var parts = self._route(path)
        if len(parts) == 0:
            return _error(404, String("NoSuchPathException"), path)
        var ns = parts[0]
        if not self._has_namespace(ns):
            return _error(
                404,
                String("NoSuchNamespaceException"),
                String("Namespace does not exist: ") + ns,
            )
        if len(parts) == 1:
            if not request.method.is_post():
                return _error(405, String("MethodNotAllowed"), path)
            var resp = self._create(ns, request.body)
            self._remember(key, resp)
            return resp^
        var name = parts[1]
        if not request.method.is_post():
            var i = self._find(ns, name)
            if i < 0:
                return _error(
                    404,
                    String("NoSuchTableException"),
                    String("Table does not exist: ") + ns + "." + name,
                )
            return IcebergRestResponse(200, self._table_body(i))
        return self._commit_request(ns, name, request.body, key)

    # -------------------------------------------------------------------------
    # internals.
    # -------------------------------------------------------------------------

    def _remember(mut self, key: String, resp: IcebergRestResponse):
        if self._idempotency and key.byte_length() > 0:
            self._idem_keys.append(key)
            self._idem_status.append(resp.status)
            self._idem_body.append(String(resp.body))

    def _config_body(self) raises -> String:
        var o = JsonValue.empty_object()
        var ov = JsonValue.empty_object()
        if self._prefix.byte_length() > 0:
            ov.set_member(String("prefix"), JsonValue.from_string(self._prefix))
        o.set_member(String("defaults"), JsonValue.empty_object())
        o.set_member(String("overrides"), ov^)
        if self._endpoints:
            var arr = JsonValue.empty_array()
            ref eps = self._endpoints.value()
            for i in range(len(eps)):
                arr.push(JsonValue.from_string(String(eps[i])))
            o.set_member(String("endpoints"), arr^)
        if self._idempotency:
            o.set_member(
                String("idempotency-key-lifetime"),
                JsonValue.from_string(String("PT30M")),
            )
        return o.serialize()

    def _route(self, path: String) -> List[String]:
        """[namespace] for `.../namespaces/{ns}/tables`, [namespace, table]
        for `.../namespaces/{ns}/tables/{t}`, else []. Segments are
        percent-decoded."""
        var out = List[String]()
        var root = String("/v1/")
        if self._prefix.byte_length() > 0:
            root += self._prefix + String("/")
        root += String("namespaces/")
        if not path.startswith(root):
            return out^
        var rest = String(path[byte = root.byte_length() :])
        var segs = rest.split("/")
        if len(segs) < 2 or len(segs) > 3 or String(segs[1]) != String("tables"):
            return out^
        out.append(_percent_decode(String(segs[0])))
        if len(segs) == 3:
            out.append(_percent_decode(String(segs[2])))
        return out^

    def _has_namespace(self, ns: String) -> Bool:
        for i in range(len(self._namespaces)):
            if self._namespaces[i] == ns:
                return True
        return False

    def _find(self, ns: String, name: String) -> Int:
        for i in range(len(self._tables)):
            if self._tables[i].namespace == ns and self._tables[i].name == name:
                return i
        return -1

    def _next_uuid(mut self) -> String:
        self._uuid_counter += 1
        var d = String(self._uuid_counter)
        var pad = String("")
        for _ in range(12 - d.byte_length()):
            pad += "0"
        return String("00000000-0000-4000-8000-") + pad + d

    def _table_body(self, i: Int) raises -> String:
        var o = JsonValue.empty_object()
        o.set_member(
            String("metadata-location"),
            JsonValue.from_string(self._tables[i].location()),
        )
        o.set_member(String("metadata"), self._tables[i].metadata.copy())
        o.set_member(String("config"), JsonValue.empty_object())
        return o.serialize()

    def _create(mut self, ns: String, body: String) raises -> IcebergRestResponse:
        var req = parse_json_value(body)
        var name = req.get(String("name")).as_string()
        if self._find(ns, name) >= 0:
            return _error(
                409,
                String("AlreadyExistsException"),
                String("Table already exists: ") + ns + "." + name,
            )
        var md = empty_table_metadata()
        var st = ApplyState()
        var location = self._warehouse_root + "/" + ns + "/" + name
        if req.has(String("location")):
            location = req.get(String("location")).as_string()
        var ups = List[JsonValue]()
        ups.append(_update(String("assign-uuid"), String("uuid"), JsonValue.from_string(self._next_uuid())))
        ups.append(_update(String("add-schema"), String("schema"), req.get(String("schema"))))
        ups.append(_update(String("set-current-schema"), String("schema-id"), JsonValue.from_i64(-1)))
        ups.append(_update(String("add-spec"), String("spec"), unpartitioned_spec()))
        ups.append(_update(String("set-default-spec"), String("spec-id"), JsonValue.from_i64(-1)))
        ups.append(_update(String("add-sort-order"), String("sort-order"), unsorted_order()))
        ups.append(_update(String("set-default-sort-order"), String("sort-order-id"), JsonValue.from_i64(-1)))
        ups.append(_update(String("set-location"), String("location"), JsonValue.from_string(location)))
        if req.has(String("properties")):
            ups.append(_update(String("set-properties"), String("updates"), req.get(String("properties"))))
        for i in range(len(ups)):
            apply_update(md, st, ups[i])
        var staged = False
        if req.has(String("stage-create")):
            staged = req.get(String("stage-create")).as_bool()
        var o = JsonValue.empty_object()
        if staged:
            o.set_member(String("metadata"), md^)
            o.set_member(String("config"), JsonValue.empty_object())
            return IcebergRestResponse(200, o.serialize())
        self._tables.append(_Table(String(ns), String(name), md^))
        return IcebergRestResponse(200, self._table_body(len(self._tables) - 1))

    def _commit_request(
        mut self, ns: String, name: String, body: String, key: String
    ) raises -> IcebergRestResponse:
        if len(self._before) > 0:
            var other = self._before.pop(0)
            _ = self._apply_commit(ns, name, other, 0)
        if len(self._faults) == 0:
            var resp = self._apply_commit(ns, name, body, 0)
            self._remember(key, resp)
            return resp^
        var f = self._faults.pop(0)
        var applied = IcebergRestResponse(0, String(""))
        if f.apply_first:
            applied = self._apply_commit(ns, name, body, f.rewrite_snapshot_id)
            self._remember(key, applied)
        if f.then_body.byte_length() > 0:
            _ = self._apply_commit(ns, name, f.then_body, 0)
        if f.then_expire != 0:
            self.expire_snapshot(ns, name, f.then_expire)
        if f.status == 0:
            raise Error("InMemoryIcebergRestCatalog: connection dropped")
        if f.status == 409:
            return _error(409, String(COMMIT_FAILED), String("scripted conflict"))
        return _error(f.status, String("ServiceFailureException"), String("scripted failure"))

    def _apply_commit(
        mut self, ns: String, name: String, body: String, rewrite_id: Int64
    ) raises -> IcebergRestResponse:
        """Check and apply one commit body; the response it is answered with."""
        var req = parse_json_value(body)
        var i = self._find(ns, name)
        var exists = i >= 0
        var md: JsonValue
        if exists:
            md = self._tables[i].metadata.copy()
        else:
            md = empty_table_metadata()
        var reqs = req.get(String("requirements"))
        var creates = False
        for k in range(reqs.array_len()):
            var r = reqs.element_at(k)
            if r.get(String("type")).as_string() == String("assert-create"):
                creates = True
            var why = check_requirement(md, exists, r)
            if why.byte_length() > 0:
                if not exists and not creates:
                    return _error(
                        404,
                        String("NoSuchTableException"),
                        String("Table does not exist: ") + ns + "." + name,
                    )
                return _error(
                    409,
                    String(COMMIT_FAILED),
                    String("Requirement failed: ") + why,
                )
        if not exists and not creates:
            return _error(
                404,
                String("NoSuchTableException"),
                String("Table does not exist: ") + ns + "." + name,
            )
        var st = ApplyState()
        var ups = req.get(String("updates"))
        try:
            for k in range(ups.array_len()):
                var u = ups.element_at(k)
                if rewrite_id != 0:
                    u = _rewrite(u^, rewrite_id)
                apply_update(md, st, u)
        except e:
            return _error(400, String(BAD_REQUEST), String(e))
        if exists:
            self._tables[i].metadata = md^
            self._tables[i].version += 1
        else:
            self._tables.append(_Table(String(ns), String(name), md^))
            i = len(self._tables) - 1
        self.applied_commits += 1
        return IcebergRestResponse(200, self._table_body(i))


# =============================================================================
# helpers.
# =============================================================================


def _error(status: Int, err_type: String, message: String) raises -> IcebergRestResponse:
    var e = JsonValue.empty_object()
    e.set_member(String("message"), JsonValue.from_string(String(message)))
    e.set_member(String("type"), JsonValue.from_string(String(err_type)))
    e.set_member(String("code"), JsonValue.from_i64(Int64(status)))
    var o = JsonValue.empty_object()
    o.set_member(String("error"), e^)
    return IcebergRestResponse(status, o.serialize())


def _update(action: String, key: String, var value: JsonValue) raises -> JsonValue:
    var o = JsonValue.empty_object()
    o.set_member(String("action"), JsonValue.from_string(String(action)))
    o.set_member(String(key), value^)
    return o^


def _rewrite(var up: JsonValue, id: Int64) raises -> JsonValue:
    """The update with the snapshot id it adds or points `main` at replaced
    by `id` (a catalog that rewrites the snapshot)."""
    var a = up.get(String("action")).as_string()
    if a == String("add-snapshot"):
        var i = member_index(up, String("snapshot"))
        put_member(up.children[i], String("snapshot-id"), JsonValue.from_i64(id))
    elif a == String("set-snapshot-ref"):
        put_member(up, String("snapshot-id"), JsonValue.from_i64(id))
    return up^


def _hex(c: UInt8) -> Int:
    if c >= 0x30 and c <= 0x39:
        return Int(c) - 0x30
    if c >= 0x41 and c <= 0x46:
        return Int(c) - 0x41 + 10
    if c >= 0x61 and c <= 0x66:
        return Int(c) - 0x61 + 10
    return -1


def _percent_decode(s: String) -> String:
    """Decode `%XX` escapes; any other byte is kept."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        if b[i] == 0x25 and i + 2 < len(b):
            var hi = _hex(b[i + 1])
            var lo = _hex(b[i + 2])
            if hi >= 0 and lo >= 0:
                out.append(UInt8(hi * 16 + lo))
                i += 3
                continue
        out.append(b[i])
        i += 1
    return String(unsafe_from_utf8=Span(out))
