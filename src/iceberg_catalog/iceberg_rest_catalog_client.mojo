# =============================================================================
# iceberg_catalog/iceberg_rest_catalog_client.mojo — the Iceberg REST catalog
#   client: config, load, create and commit (standard Iceberg REST protocol).
# =============================================================================
#
# WHAT THIS IS. An `IcebergCatalog` conformer that speaks the STANDARD Iceberg
# REST catalog protocol (https://github.com/apache/iceberg/blob/main/open-api/
# rest-catalog-open-api.yaml) over the `IcebergRestTransport` seam. It reads
# (config, loadTable) and writes (createTable, commitTable); the commit loop
# that decides what to send and what each answer means is the committer's
# (iceberg_commit.mojo). docs/design/iceberg_tables.md, "The REST write
# protocol", is the design.
#
# THE ENDPOINTS:
#   1. GET /v1/config[?warehouse=<w>]
#        -> `{"defaults":{...}, "overrides":{...}, "endpoints":[...],
#        "idempotency-key-lifetime":"PT30M"}`. From the merged `defaults` and
#        `overrides` (overrides win) the client keeps every string member,
#        the `prefix` among them. From the top level it keeps `endpoints`
#        (when listed, a request to an endpoint not listed is refused with
#        `ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED` before it is sent; when
#        omitted, the spec's default set applies, which has every endpoint
#        this client calls) and whether `idempotency-key-lifetime` is present
#        (the server honours `Idempotency-Key`). Fetched once, then cached.
#   2. GET /v1/{prefix}/namespaces/{ns}/tables/{table}: the loadTable
#        response, `metadata-location`, `metadata` (parsed into a typed
#        `TableMetadata` by `load_table_metadata`) and `config`.
#   3. POST /v1/{prefix}/namespaces/{ns}/tables: createTable, staged or not.
#   4. POST /v1/{prefix}/namespaces/{ns}/tables/{table}: commitTable, with
#        requirements and updates. Its answer is returned as a
#        `CommitResponse`, never raised: the committer decides what a 409, a
#        5xx or a lost connection means.
#
# Every POST carries `Content-Type: application/json`, and an
# `Idempotency-Key` header when the caller passes a key.
#
# ERRORS. Every message starts with its token (iceberg_rest_errors.mojo) and
# carries the catalog's ErrorModel `type` and `message`, never the raw body.
#
# AUTH — a bearer-token SEAM. `CatalogCredentialProvider` yields an
# `Authorization` header value (or "" for no auth); `StaticBearerToken` serves
# a fixed token.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. The client is parametric over
# `T: IcebergRestTransport` and `P: CatalogCredentialProvider`. `def`-based,
# Mojo 1.0.0.
# =============================================================================

from json import (
    JsonValue,
    parse_json_value,
    JSON_ARRAY,
    JSON_OBJECT,
    JSON_STRING,
)

from .iceberg_catalog import IcebergCatalog, ResolvedTable
from .iceberg_rest_errors import (
    ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED,
    ICEBERG_CATALOG_RESPONSE_INVALID,
    ICEBERG_CATALOG_UNAVAILABLE,
    ICEBERG_TABLE_ALREADY_EXISTS,
    rest_error_message,
    with_error_model,
)
from .iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
    IcebergRestTransport,
)
from .iceberg_table_changes import CreateTableRequest
from .iceberg_table_metadata import TableMetadata, parse_table_metadata


# =============================================================================
# §0 — endpoint facts.
# =============================================================================

comptime ICEBERG_REST_PORT: UInt16 = 443
# The Iceberg REST API version prefix — every path is rooted at `/v1`.
comptime ICEBERG_REST_API_ROOT: String = "/v1"

# The endpoint names of the spec's `endpoints` list, for the calls this client
# makes.
comptime ENDPOINT_LOAD_TABLE: String = (
    "GET /v1/{prefix}/namespaces/{namespace}/tables/{table}"
)
comptime ENDPOINT_CREATE_TABLE: String = (
    "POST /v1/{prefix}/namespaces/{namespace}/tables"
)
comptime ENDPOINT_COMMIT_TABLE: String = (
    "POST /v1/{prefix}/namespaces/{namespace}/tables/{table}"
)

# What a commit POST's answer means (`CommitResponse.kind`).
comptime COMMIT_APPLIED: Int = 0
"""200: the catalog applied the commit; `table` holds the new metadata."""
comptime COMMIT_CONFLICT: Int = 1
"""409: a requirement failed, and the request applied nothing."""
comptime COMMIT_UNKNOWN: Int = 2
"""Any 5xx, or a transport error: the commit may or may not have applied."""
comptime COMMIT_REFUSED: Int = 3
"""Any other status: refused; `message` holds the token message."""


# =============================================================================
# §1 — CatalogCredentialProvider — the bearer-token SEAM.
# =============================================================================


trait CatalogCredentialProvider(Movable, Deinitable):
    """Yields the `Authorization` header VALUE to attach to each REST request
    (e.g. `Bearer <token>`), or an empty String for an unauthenticated catalog.
    A SEAM: tests + the operator-supplies-a-token case use `StaticBearerToken`;
    an OAuth2 token-exchange flow is a documented follow-on conformer."""

    def authorization_header(mut self) raises -> String:
        """The `Authorization` header value for the next request, or "" for no
        auth. RAISES if a token-exchange conformer fails to obtain a token."""
        ...


struct StaticBearerToken(CatalogCredentialProvider, Movable, Deinitable):
    """A CatalogCredentialProvider that serves a FIXED bearer token — the common
    "operator supplies a token" case + the test path. Yields
    `Bearer <token>` (or "" when the token is empty -> an unauthenticated
    catalog).

    a plain owned-String field, no pointer, no wildcard origin."""

    var _token: String

    def __init__(out self, var token: String):
        self._token = token^

    def authorization_header(mut self) raises -> String:
        if self._token.byte_length() == 0:
            return String("")
        return String("Bearer ") + self._token


# =============================================================================
# §2 — LoadedTable and CommitResponse — what a load, create or commit returns.
# =============================================================================


struct LoadedTable(Copyable, Movable):
    """A loadTable, createTable or commitTable result: the metadata location
    ("" for a staged create, which has none yet), the typed metadata, the
    metadata as JSON text, and the per-table string `config`."""

    var metadata_location: String
    var metadata: TableMetadata
    var metadata_json: String
    var config_names: List[String]
    var config_values: List[String]

    def __init__(
        out self,
        var metadata_location: String,
        var metadata: TableMetadata,
        var metadata_json: String,
        var config_names: List[String],
        var config_values: List[String],
    ):
        self.metadata_location = metadata_location^
        self.metadata = metadata^
        self.metadata_json = metadata_json^
        self.config_names = config_names^
        self.config_values = config_values^


struct CommitResponse(Copyable, Movable):
    """The answer to one commit POST. `kind` is one of `COMMIT_APPLIED`,
    `COMMIT_CONFLICT`, `COMMIT_UNKNOWN` or `COMMIT_REFUSED`; `status` is the
    HTTP status (0 after a transport error); `message` is the token message
    for a refusal or an unknown outcome ("" otherwise); `table` is the new
    metadata after `COMMIT_APPLIED`."""

    var kind: Int
    var status: Int
    var message: String
    var table: Optional[LoadedTable]

    def __init__(
        out self,
        kind: Int,
        status: Int,
        var message: String,
        var table: Optional[LoadedTable],
    ):
        self.kind = kind
        self.status = status
        self.message = message^
        self.table = table^


# =============================================================================
# §3 — IcebergRestCatalog[T, P] — the REST catalog client.
# =============================================================================


struct IcebergRestCatalog[T: IcebergRestTransport, P: CatalogCredentialProvider](
    IcebergCatalog, Movable, Deinitable
):
    """The Iceberg REST catalog client, conforming to `IcebergCatalog`. Reads
    and writes tables over the standard Iceberg REST protocol, through the
    `T: IcebergRestTransport` seam (real HTTP in prod, in memory in tests)
    with the `P: CatalogCredentialProvider` bearer-token seam.

    Construction: `IcebergRestCatalog(host, transport, creds, port=...,
    warehouse=...)` (`port` defaults to `ICEBERG_REST_PORT`, 443; a non-empty
    `warehouse` is sent as the config request's `warehouse` query). The config
    is fetched lazily on the first request and CACHED.

    `host` / `_prefix` / `_warehouse` are owned Strings; `port` is the
    catalog's port; `_config_*` and `_endpoints` are owned `List[String]`;
    `_transport` / `_creds` are the parametric conformer values (owned, moved
    in). No pointer field, no wildcard origin."""

    var host: String
    var port: UInt16
    var _transport: Self.T
    var _creds: Self.P
    var _warehouse: String
    var _prefix: String
    var _config_fetched: Bool
    var _config_names: List[String]
    var _config_values: List[String]
    var _endpoints_listed: Bool
    var _endpoints: List[String]
    var _idempotency: Bool

    def __init__(
        out self,
        var host: String,
        var transport: Self.T,
        var creds: Self.P,
        *,
        port: UInt16 = ICEBERG_REST_PORT,
        warehouse: String = String(""),
    ):
        self.host = host^
        self.port = port
        self._transport = transport^
        self._creds = creds^
        self._warehouse = String(warehouse)
        self._prefix = String("")
        self._config_fetched = False
        self._config_names = List[String]()
        self._config_values = List[String]()
        self._endpoints_listed = False
        self._endpoints = List[String]()
        self._idempotency = False

    def transport_ref(ref self) -> ref [self._transport] Self.T:
        """A borrowed reference to the owned transport (the test double in
        tests — so a test can assert the recorded requests AFTER driving the
        client). The reference is rooted at `self._transport` (never a raw
        pointer — the `ref [self.field] T` return shape)."""
        return self._transport

    # -------------------------------------------------------------------------
    # request construction.
    # -------------------------------------------------------------------------

    def _headers(
        mut self, mut names: List[String], mut values: List[String]
    ) raises:
        """Accept, then Authorization when the credential provider yields
        one. No Host header: the HTTP client writes it from the URL's
        authority, which carries the port when it is not the scheme's default
        (RFC 9110 section 7.2)."""
        names.append(String("Accept"))
        values.append(String("application/json"))
        var auth = self._creds.authorization_header()
        if auth.byte_length() > 0:
            names.append(String("Authorization"))
            values.append(auth)

    def _build_request(mut self, var path: String) raises -> IcebergRestRequest:
        """A GET for `path` to `host`:`port`."""
        var names = List[String]()
        var values = List[String]()
        self._headers(names, values)
        return IcebergRestRequest(
            String(self.host), self.port, path^, names^, values^
        )

    def _build_post(
        mut self, var path: String, var body: String, idempotency_key: String
    ) raises -> IcebergRestRequest:
        """A POST of `body` to `path`, with `Content-Type: application/json`
        and, when `idempotency_key` is non-empty, `Idempotency-Key`."""
        var names = List[String]()
        var values = List[String]()
        self._headers(names, values)
        names.append(String("Content-Type"))
        values.append(String("application/json"))
        if idempotency_key.byte_length() > 0:
            names.append(String("Idempotency-Key"))
            values.append(String(idempotency_key))
        return IcebergRestRequest.post(
            String(self.host), self.port, path^, names^, values^, body^
        )

    def _send(
        mut self, request: IcebergRestRequest, what: String
    ) raises -> IcebergRestResponse:
        """Send `request`; a transport error raises
        `ICEBERG_CATALOG_UNAVAILABLE` naming `what` (config, load and create
        change nothing in the catalog, so the caller may retry them)."""
        try:
            return self._transport.send(request)
        except e:
            raise Error(
                ICEBERG_CATALOG_UNAVAILABLE
                + String(": ")
                + what
                + String(": transport error: ")
                + String(e)
            )

    # -------------------------------------------------------------------------
    # GET /v1/config — fetch (once, cached) the catalog prefix + merged config.
    # -------------------------------------------------------------------------

    def _ensure_config(mut self) raises:
        """Fetch GET /v1/config ONCE and cache it (module header). A no-op
        after the first success; a failure is not cached."""
        if self._config_fetched:
            return
        var path = ICEBERG_REST_API_ROOT + String("/config")
        if self._warehouse.byte_length() > 0:
            path += String("?warehouse=") + _percent_encode(self._warehouse)
        var req = self._build_request(path^)
        var resp = self._send(req, String("GET /v1/config"))
        if resp.status != 200:
            raise Error(
                rest_error_message(
                    resp.status, resp.body, String("GET /v1/config"), False
                )
            )
        var root = _parse_object(resp.body, String("/v1/config"))
        var names = List[String]()
        var values = List[String]()
        # `defaults` first, then `overrides` (overrides WIN).
        if root.has(String("defaults")):
            _merge_config_map(names, values, root.get(String("defaults")))
        if root.has(String("overrides")):
            _merge_config_map(names, values, root.get(String("overrides")))
        var endpoints_listed = False
        var endpoints = List[String]()
        if root.has(String("endpoints")):
            var arr = root.get(String("endpoints"))
            if arr.kind_tag() != JSON_ARRAY:
                raise Error(
                    ICEBERG_CATALOG_RESPONSE_INVALID
                    + String(": /v1/config 'endpoints' is not an array")
                )
            endpoints_listed = True
            for i in range(arr.array_len()):
                var e = arr.element_at(i)
                if e.kind_tag() == JSON_STRING:
                    endpoints.append(e.as_string())
        self._config_names = names^
        self._config_values = values^
        self._endpoints_listed = endpoints_listed
        self._endpoints = endpoints^
        self._idempotency = root.has(String("idempotency-key-lifetime"))
        self._prefix = self.config_value(String("prefix"))
        self._config_fetched = True

    def config_value(self, name: String) -> String:
        """The cached catalog config value for `name`; empty if absent. Valid
        after the first request."""
        for i in range(len(self._config_names)):
            if self._config_names[i] == name:
                return String(self._config_values[i])
        return String("")

    def prefix(self) -> String:
        """The cached catalog prefix (empty for a single-tenant catalog). Valid
        after the first request."""
        return String(self._prefix)

    def supports_idempotency(mut self) raises -> Bool:
        """True iff the config advertised `idempotency-key-lifetime`: the
        server honours `Idempotency-Key`. Fetches the config if needed."""
        self._ensure_config()
        return self._idempotency

    def require_endpoint(mut self, endpoint: String) raises:
        """Raise `ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED` when the config listed
        `endpoints` without `endpoint`. Fetches the config if needed."""
        self._ensure_config()
        if not self._endpoints_listed:
            return
        for i in range(len(self._endpoints)):
            if self._endpoints[i] == endpoint:
                return
        raise Error(
            ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED
            + String(": the catalog does not list '")
            + endpoint
            + String("'")
        )

    # -------------------------------------------------------------------------
    # GET .../tables/{table} — loadTable.
    # -------------------------------------------------------------------------

    def load_table(
        mut self, namespace: String, table: String
    ) raises -> ResolvedTable:
        """Resolve `namespace.table` -> its ResolvedTable (metadata-location +
        the metadata as JSON text + per-table config). RAISES with a token on
        any non-200 status, a malformed body, or a MISSING/empty
        metadata-location (never a silent empty string)."""
        var body = self._load_body(namespace, table)
        return _parse_load_table_response(body, namespace, table)

    def load_table_metadata(
        mut self, namespace: String, table: String
    ) raises -> LoadedTable:
        """The loadTable result, with the metadata parsed into a `TableMetadata`.

        Raises
        as `load_table` does, and `ICEBERG_CATALOG_RESPONSE_INVALID` when the
        response has no `metadata` object."""
        var body = self._load_body(namespace, table)
        var what = String("loadTable '") + _table_key(namespace, table) + "'"
        var t = _parse_loaded_table(body, what, True)
        return t^

    def _load_body(mut self, namespace: String, table: String) raises -> String:
        self.require_endpoint(ENDPOINT_LOAD_TABLE)
        var path = self._table_path(namespace, table)
        var req = self._build_request(path^)
        var what = String("loadTable '") + _table_key(namespace, table) + "'"
        var resp = self._send(req, what)
        if resp.status != 200:
            raise Error(
                rest_error_message(
                    resp.status,
                    resp.body,
                    what,
                    True,
                )
            )
        return String(resp.body)

    # -------------------------------------------------------------------------
    # POST .../tables — createTable.
    # -------------------------------------------------------------------------

    def create_table(
        mut self, namespace: String, request: CreateTableRequest
    ) raises -> LoadedTable:
        """POST a createTable. A staged create (`request.stage_create`)
        returns the table's initial metadata with an empty
        `metadata_location` and creates nothing; a direct create returns the
        created table. A 409 raises `ICEBERG_TABLE_ALREADY_EXISTS`; any other
        non-200 raises with its status's token."""
        self.require_endpoint(ENDPOINT_CREATE_TABLE)
        var path = self._namespace_path(namespace) + String("/tables")
        var req = self._build_post(path^, request.body(), String(""))
        var what = (
            String("createTable '") + _table_key(namespace, request.name) + "'"
        )
        var resp = self._send(req, what)
        if resp.status == 409:
            raise Error(
                with_error_model(
                    ICEBERG_TABLE_ALREADY_EXISTS
                    + String(": ")
                    + what
                    + String(": HTTP 409"),
                    resp.body,
                )
            )
        if resp.status != 200:
            raise Error(rest_error_message(resp.status, resp.body, what, True))
        return _parse_loaded_table(resp.body, what, not request.stage_create)

    # -------------------------------------------------------------------------
    # POST .../tables/{table} — commitTable.
    # -------------------------------------------------------------------------

    def commit_table(
        mut self,
        namespace: String,
        table: String,
        body: String,
        idempotency_key: String,
    ) raises -> CommitResponse:
        """POST the commit `body` (see `commit_table_body`), with
        `Idempotency-Key: <idempotency_key>` when it is non-empty. The answer
        is returned, never raised: 200 is `COMMIT_APPLIED` with the new
        metadata, 409 `COMMIT_CONFLICT`, any 5xx or a transport error
        `COMMIT_UNKNOWN`, anything else `COMMIT_REFUSED` with its token. A 200
        whose body cannot be read is `COMMIT_UNKNOWN`: the commit may have
        applied. Raises only before sending: an endpoint the catalog does not
        list, or a credential provider that fails."""
        self.require_endpoint(ENDPOINT_COMMIT_TABLE)
        var path = self._table_path(namespace, table)
        var req = self._build_post(path^, String(body), idempotency_key)
        var what = String("commitTable '") + _table_key(namespace, table) + "'"
        var resp: IcebergRestResponse
        try:
            resp = self._transport.send(req)
        except e:
            return CommitResponse(
                COMMIT_UNKNOWN,
                0,
                ICEBERG_CATALOG_UNAVAILABLE
                + String(": ")
                + what
                + String(": transport error: ")
                + String(e),
                None,
            )
        if resp.status == 200:
            try:
                var t = _parse_loaded_table(resp.body, what, True)
                return CommitResponse(
                    COMMIT_APPLIED, 200, String(""), Optional[LoadedTable](t^)
                )
            except e:
                return CommitResponse(COMMIT_UNKNOWN, 200, String(e), None)
        if resp.status == 409:
            return CommitResponse(
                COMMIT_CONFLICT,
                409,
                with_error_model(what + String(": HTTP 409"), resp.body),
                None,
            )
        var msg = rest_error_message(resp.status, resp.body, what, True)
        if resp.status >= 500 and resp.status <= 599:
            return CommitResponse(COMMIT_UNKNOWN, resp.status, msg^, None)
        return CommitResponse(COMMIT_REFUSED, resp.status, msg^, None)

    # -------------------------------------------------------------------------
    # paths.
    # -------------------------------------------------------------------------

    def _namespace_path(mut self, namespace: String) raises -> String:
        """`/v1/{prefix}/namespaces/{ns}` (the `{prefix}` segment omitted for
        an empty prefix). The prefix keeps its `/` as a path separator, as the
        Iceberg Java client's ResourcePaths does; each `/`-separated piece of
        it, and the namespace, are percent-encoded."""
        self._ensure_config()
        var p = String(ICEBERG_REST_API_ROOT)
        if self._prefix.byte_length() > 0:
            p += String("/") + _percent_encode_prefix(self._prefix)
        p += String("/namespaces/") + _percent_encode(namespace)
        return p^

    def _table_path(mut self, namespace: String, table: String) raises -> String:
        """`/v1/{prefix}/namespaces/{ns}/tables/{tbl}`, each part
        percent-encoded as one segment."""
        return (
            self._namespace_path(namespace)
            + String("/tables/")
            + _percent_encode(table)
        )


# =============================================================================
# §4 — response parsing (pure — over a raw JSON String).
# =============================================================================


def _table_key(namespace: String, table: String) -> String:
    return namespace + String(".") + table


def _parse_object(body: String, what: String) raises -> JsonValue:
    """The body as a JSON object, or `ICEBERG_CATALOG_RESPONSE_INVALID`."""
    var root: JsonValue
    try:
        root = parse_json_value(body)
    except:
        raise Error(
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": ")
            + what
            + String(" response is not JSON")
        )
    if root.kind_tag() != JSON_OBJECT:
        raise Error(
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": ")
            + what
            + String(" response is not a JSON object")
        )
    return root^


def _merge_config_map(
    mut names: List[String], mut values: List[String], m: JsonValue
) raises:
    """Merge a JSON object's string members into the config (a later map's
    key OVERWRITES an earlier one — overrides win). Not an object: ignored;
    a member that is not a string: skipped."""
    if m.kind_tag() != JSON_OBJECT:
        return
    for i in range(m.num_members()):
        if m.value_kind(i) != JSON_STRING:
            continue
        var k = m.key_at(i)
        var v = m.value_at(i).as_string()
        var found = False
        for j in range(len(names)):
            if names[j] == k:
                values[j] = v
                found = True
                break
        if not found:
            names.append(k^)
            values.append(v^)


def _config_members(
    root: JsonValue, mut names: List[String], mut values: List[String]
) raises:
    """The string members of the response's `config` object, if any."""
    if not root.has(String("config")):
        return
    var cfg = root.get(String("config"))
    if cfg.kind_tag() != JSON_OBJECT:
        return
    for i in range(cfg.num_members()):
        if cfg.value_kind(i) != JSON_STRING:
            continue
        names.append(cfg.key_at(i))
        values.append(cfg.value_at(i).as_string())


def _parse_loaded_table(
    body: String, what: String, need_location: Bool
) raises -> LoadedTable:
    """A LoadTableResult body -> LoadedTable. `metadata` must be an object;
    `metadata-location` must be a non-empty string when `need_location`, and
    may be absent or null otherwise (a staged create)."""
    var root = _parse_object(body, what)
    var location = String("")
    if root.has(String("metadata-location")):
        var lv = root.get(String("metadata-location"))
        if lv.kind_tag() == JSON_STRING:
            location = lv.as_string()
    if need_location and location.byte_length() == 0:
        raise Error(
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": ")
            + what
            + String(" response has no 'metadata-location'")
        )
    if not root.has(String("metadata")):
        raise Error(
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": ")
            + what
            + String(" response has no 'metadata'")
        )
    var mv = root.get(String("metadata"))
    var metadata = parse_table_metadata(mv)
    var names = List[String]()
    var values = List[String]()
    _config_members(root, names, values)
    return LoadedTable(location^, metadata^, mv.serialize(), names^, values^)


def _parse_load_table_response(
    body: String, namespace: String, table: String
) raises -> ResolvedTable:
    """Parse a loadTable JSON body into a ResolvedTable. Extracts:
      * `metadata-location` — REQUIRED + non-empty (the load-bearing output). A
        missing, non-string or empty `metadata-location` RAISES
        `ICEBERG_CATALOG_RESPONSE_INVALID` (never a silent empty string).
      * `metadata` — the table metadata object, SURFACED verbatim as
        re-serialized raw JSON ("" when absent).
      * `config` — per-table string->string overrides.

    Pure — over the raw body String; no network, no client state."""
    var what = String("loadTable '") + _table_key(namespace, table) + "'"
    var root = _parse_object(body, what)
    if not root.has(String("metadata-location")):
        raise Error(
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": ")
            + what
            + String(" response has no 'metadata-location'")
        )
    var loc_val = root.get(String("metadata-location"))
    if loc_val.kind_tag() != JSON_STRING:
        raise Error(
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": ")
            + what
            + String(" 'metadata-location' is not a string")
        )
    var metadata_location = loc_val.as_string()
    if metadata_location.byte_length() == 0:
        raise Error(
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": ")
            + what
            + String(" 'metadata-location' is empty")
        )
    var metadata_json = String("")
    if root.has(String("metadata")):
        metadata_json = root.get(String("metadata")).serialize()
    var config_names = List[String]()
    var config_values = List[String]()
    _config_members(root, config_names, config_values)
    return ResolvedTable(
        metadata_location^,
        metadata_json^,
        config_names^,
        config_values^,
    )


# =============================================================================
# §5 — percent-encoding for path segments.
# =============================================================================


def _percent_encode(s: String) -> String:
    """Percent-encode one path segment per RFC 3986: every byte outside the
    unreserved set `A-Z a-z 0-9 - _ . ~` is `%XX`-encoded. This keeps a
    namespace or table containing `/`, spaces, or the `%1F` multi-level
    namespace separator wire-safe in the request path."""
    return _percent_encode_impl(s, keep_slash=False)


def _percent_encode_prefix(s: String) -> String:
    """Percent-encode the catalog prefix: like `_percent_encode`, except a `/`
    is kept as a path separator (`ten ant/1` -> `ten%20ant/1`)."""
    return _percent_encode_impl(s, keep_slash=True)


def _percent_encode_impl(s: String, keep_slash: Bool) -> String:
    """Percent-encode every byte outside the unreserved set; a `/` is kept
    as-is when `keep_slash` is set."""
    var hexdigits = "0123456789ABCDEF"
    var hb = hexdigits.as_bytes()
    var out = String("")
    var src = s.as_bytes()
    for i in range(len(src)):
        var c = src[i]
        var unreserved = (
            (c >= 0x41 and c <= 0x5A)  # A-Z
            or (c >= 0x61 and c <= 0x7A)  # a-z
            or (c >= 0x30 and c <= 0x39)  # 0-9
            or c == 0x2D  # '-'
            or c == 0x5F  # '_'
            or c == 0x2E  # '.'
            or c == 0x7E  # '~'
            or (keep_slash and c == 0x2F)  # '/' in a prefix
        )
        if unreserved:
            out += chr(Int(c))
        else:
            out += "%"
            out += chr(Int(hb[(Int(c) >> 4) & 0xF]))
            out += chr(Int(hb[Int(c) & 0xF]))
    return out^
