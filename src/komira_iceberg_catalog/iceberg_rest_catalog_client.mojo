# =============================================================================
# komira_iceberg_catalog/iceberg_rest_catalog_client.mojo — the INBOUND Iceberg
#   REST catalog READ client (RESOLVE-ONLY, standard Iceberg REST protocol).
# =============================================================================
#
# WHAT THIS IS. An `IcebergCatalog` conformer that resolves `namespace.table` ->
# its current metadata-location by speaking the STANDARD Iceberg REST catalog
# protocol (https://github.com/apache/iceberg/blob/main/open-api/rest-catalog-
# open-api.yaml) over the `komira_http` transport. RESOLVE-ONLY: it
# implements the two READ endpoints the resolve path needs, and NOTHING else —
# no `createTable`, no `updateTable`/`commitTable`, no 409-retry (explicitly OUT
# by design; writes stay storage-based).
#
# THE TWO ENDPOINTS (standard Iceberg REST):
#   1. GET /v1/config
#        -> `{"overrides":{...}, "defaults":{...}}`. The `overrides`/`defaults`
#        maps carry catalog config; the load-bearing datum is the `prefix` (a
#        multi-tenant catalog namespaces its resource paths under a per-catalog
#        prefix). The client fetches this ONCE and caches the prefix + the
#        merged config for the life of the client.
#   2. GET /v1/{prefix}/namespaces/{namespace}/tables/{table}
#        -> the loadTable response: `{"metadata-location":"s3://.../metadata.json",
#        "metadata":{...}, "config":{...}}`. `metadata-location` is the
#        LOAD-BEARING output (the storage location the storage-based reader then
#        consumes); `metadata` is the parsed table metadata (SURFACED verbatim as
#        raw JSON — see the metadata-parser note below); `config` is per-table
#        overrides.
#
# AUTH — a bearer-token SEAM. `CatalogCredentialProvider` yields an
# `Authorization: Bearer <token>` header value (or "" for no auth). Kept a SEAM:
# a `StaticBearerToken` provider serves a fixed token (tests + the common
# "operator supplies a token" case); a token-EXCHANGE / OAuth2 client-credentials
# flow is a documented FOLLOW-ON, not part of this package. (Glue-native SigV4-for-`glue`
# is a SEPARATE documented follow-on.)
#
# JSON PARSING — REUSED. The loadTable + config responses are parsed with the
# recursive-descent JSON DOM parser `komira_json.parse_json_value`
# (-> `JsonValue` with `.get`/`.has`/`.as_string`/nested object+array). ZERO new
# JSON parser is written here.
#
# THE INBOUND `metadata` DOC — a FLAGGED FOLLOW-ON, not parsed here.
# an Iceberg metadata.json WRITER BUILDS the JSON via String concat); it has NO parser for an INBOUND metadata
# document. So this client SURFACES the loadTable `metadata` object as a raw JSON
# String on `ResolvedTable.metadata` (re-serialized from the parsed DOM) and does
# NOT decode it into an IcebergSchema / snapshot list. Decoding the inbound
# metadata.json into typed structures is a flagged follow-on (a new inbound
# metadata parser) — the resolve path does not need it: the storage-based reader
# re-reads the metadata.json from the metadata-location it is handed.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. The HTTP internals are encapsulated behind
# the `IcebergRestTransport` seam (no raw pointers cross the boundary). The
# client is parametric over `T: IcebergRestTransport`. `def`-based, Mojo 1.0.0b2.
# =============================================================================

from komira_json import (
    JsonValue,
    parse_json_value,
    JSON_OBJECT,
    JSON_STRING,
)

from .iceberg_catalog import IcebergCatalog, ResolvedTable
from .iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
    IcebergRestTransport,
)


# =============================================================================
# §0 — endpoint facts.
# =============================================================================

comptime ICEBERG_REST_PORT: UInt16 = 443
# The Iceberg REST API version prefix — every path is rooted at `/v1`.
comptime ICEBERG_REST_API_ROOT: String = "/v1"


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
# §2 — IcebergRestCatalog[T, P] — the REST catalog client (IcebergCatalog).
# =============================================================================


struct IcebergRestCatalog[T: IcebergRestTransport, P: CatalogCredentialProvider](
    IcebergCatalog, Movable, Deinitable
):
    """The INBOUND Iceberg REST catalog client, conforming to `IcebergCatalog`.
    Resolves `namespace.table` -> its metadata-location over the standard Iceberg
    REST protocol, through the `T: IcebergRestTransport` seam (real HTTP in prod,
    scripted JSON in tests) with the `P: CatalogCredentialProvider` bearer-token
    seam.

    Construction: `IcebergRestCatalog(host, transport, creds, port=...)`
    (`port` defaults to `ICEBERG_REST_PORT`, 443). The catalog
    `prefix` is fetched lazily from GET /v1/config on the FIRST resolve and
    CACHED (a multi-tenant catalog namespaces its paths under a per-catalog
    prefix; a single-tenant catalog returns an empty prefix, in which case the
    paths omit the prefix segment).

    `host` / `_prefix` are owned Strings; `port` is the catalog's port;
    `_config_*` are owned
    `List[String]`; `_transport` / `_creds` are the parametric conformer values
    (owned, moved in). No pointer field, no wildcard origin."""

    var host: String
    var port: UInt16
    var _transport: Self.T
    var _creds: Self.P
    var _prefix: String
    var _config_fetched: Bool
    var _config_names: List[String]
    var _config_values: List[String]

    def __init__(
        out self,
        var host: String,
        var transport: Self.T,
        var creds: Self.P,
        *,
        port: UInt16 = ICEBERG_REST_PORT,
    ):
        self.host = host^
        self.port = port
        self._transport = transport^
        self._creds = creds^
        self._prefix = String("")
        self._config_fetched = False
        self._config_names = List[String]()
        self._config_values = List[String]()

    def transport_ref(ref self) -> ref [self._transport] Self.T:
        """A borrowed reference to the owned transport (the scripted double in
        tests — so a test can assert the recorded call paths + Authorization
        headers AFTER driving the client). The reference is rooted at
        `self._transport` (never a raw pointer — the RFC `ref [self.field] T`
        return shape)."""
        return self._transport

    # -------------------------------------------------------------------------
    # request construction — the outgoing GET (path + Authorization header).
    # -------------------------------------------------------------------------

    def _build_request(mut self, var path: String) raises -> IcebergRestRequest:
        """Build a GET for `path` to `host`:`port` with the Accept header + the
        bearer Authorization header (when the credential provider yields one).
        The Authorization header is attached ONLY when non-empty (an
        unauthenticated catalog gets no Authorization header). No Host header:
        the HTTP client writes it from the URL's authority, which carries the
        port when it is not the scheme's default (RFC 9110 section 7.2)."""
        var names = List[String]()
        var values = List[String]()
        names.append(String("Accept"))
        values.append(String("application/json"))
        var auth = self._creds.authorization_header()
        if auth.byte_length() > 0:
            names.append(String("Authorization"))
            values.append(auth)
        return IcebergRestRequest(
            String(self.host), self.port, path^, names^, values^
        )

    # -------------------------------------------------------------------------
    # GET /v1/config — fetch (once, cached) the catalog prefix + merged config.
    # -------------------------------------------------------------------------

    def _ensure_config(mut self) raises:
        """Fetch GET /v1/config ONCE and cache the `prefix` + the merged
        `defaults`+`overrides` config. Idempotent — a no-op after the first
        call. RAISES on a non-200 config response or a malformed config body."""
        if self._config_fetched:
            return
        var path = ICEBERG_REST_API_ROOT + String("/config")
        var req = self._build_request(path^)
        var resp = self._transport.get(req)
        if resp.status != 200:
            raise Error(
                String("IcebergRestError: GET /v1/config returned HTTP ")
                + String(resp.status)
                + String(" — body: ")
                + resp.body
            )
        var root = parse_json_value(resp.body)
        if root.kind_tag() != JSON_OBJECT:
            raise Error(
                "IcebergRestError: /v1/config response is not a JSON object"
            )
        # `defaults` first, then `overrides` (overrides WIN — the spec: a client
        # merges defaults under its own config, then overrides on top). The
        # `prefix` (from either map, overrides winning) is the load-bearing datum.
        if root.has(String("defaults")):
            self._merge_config_map(root.get(String("defaults")))
        if root.has(String("overrides")):
            self._merge_config_map(root.get(String("overrides")))
        self._prefix = self.config_value(String("prefix"))
        self._config_fetched = True

    def _merge_config_map(mut self, m: JsonValue) raises:
        """Merge a JSON object's string members into the cached config (a later
        map's key OVERWRITES an earlier one — overrides-win)."""
        if m.kind_tag() != JSON_OBJECT:
            return
        for i in range(m.num_members()):
            var k = m.key_at(i)
            # Only string-valued config entries are surfaced (the Iceberg REST
            # config maps are string->string).
            if m.value_kind(i) != JSON_STRING:
                continue
            var v = m.value_at(i).as_string()
            self._set_config(k^, v^)

    def _set_config(mut self, var key: String, var value: String):
        """Set (or overwrite) a cached config entry."""
        for i in range(len(self._config_names)):
            if self._config_names[i] == key:
                self._config_values[i] = value^
                return
        self._config_names.append(key^)
        self._config_values.append(value^)

    def config_value(self, name: String) -> String:
        """The cached catalog config value for `name`; empty if absent. Valid
        after the first resolve (or an explicit `_ensure_config`). Exposed so a
        caller/test can read the resolved `prefix` + `overrides`."""
        for i in range(len(self._config_names)):
            if self._config_names[i] == name:
                return String(self._config_values[i])
        return String("")

    def prefix(self) -> String:
        """The cached catalog prefix (empty for a single-tenant catalog). Valid
        after the first resolve."""
        return String(self._prefix)

    # -------------------------------------------------------------------------
    # GET /v1/{prefix}/namespaces/{ns}/tables/{table} — the loadTable resolve.
    # -------------------------------------------------------------------------

    def load_table(
        mut self, namespace: String, table: String
    ) raises -> ResolvedTable:
        """Resolve `namespace.table` -> its ResolvedTable (metadata-location +
        raw metadata + per-table config). Fetches /v1/config once (cached) then
        GETs the loadTable endpoint. RAISES on a 404 (NoSuchTable/Namespace), a
        non-200 status, a malformed body, or a MISSING/empty metadata-location
        (fail loud — never a silent empty string)."""
        self._ensure_config()
        var path = self._load_table_path(namespace, table)
        var req = self._build_request(path^)
        var resp = self._transport.get(req)
        if resp.status == 404:
            raise Error(
                String(
                    "IcebergRestError: table not found (HTTP 404) for '"
                )
                + namespace
                + String(".")
                + table
                + String("' — body: ")
                + resp.body
            )
        if resp.status != 200:
            raise Error(
                String("IcebergRestError: loadTable returned HTTP ")
                + String(resp.status)
                + String(" for '")
                + namespace
                + String(".")
                + table
                + String("' — body: ")
                + resp.body
            )
        return _parse_load_table_response(resp.body, namespace, table)

    def _load_table_path(self, namespace: String, table: String) raises -> String:
        """Build the loadTable path: `/v1/{prefix}/namespaces/{ns}/tables/{tbl}`
        (the `{prefix}` segment omitted for an empty prefix). Namespace + table
        are percent-encoded (a multi-level namespace uses the `%1F`-encoded unit
        separator per the spec; a single-level namespace percent-encodes only the
        reserved chars)."""
        var p = String(ICEBERG_REST_API_ROOT)
        if self._prefix.byte_length() > 0:
            p += String("/") + _percent_encode(self._prefix)
        p += String("/namespaces/") + _percent_encode(namespace)
        p += String("/tables/") + _percent_encode(table)
        return p^


# =============================================================================
# §3 — loadTable response parsing (pure — over a raw JSON String).
# =============================================================================


def _parse_load_table_response(
    body: String, namespace: String, table: String
) raises -> ResolvedTable:
    """Parse a loadTable JSON body into a ResolvedTable. Extracts:
      * `metadata-location` — REQUIRED + non-empty (the load-bearing output). A
        missing OR empty `metadata-location` RAISES (fail loud, never a silent
        empty string). This is the falsifier: a wrong/missing field -> a clean
        typed error.
      * `metadata` — the table metadata object, SURFACED verbatim as re-serialized
        raw JSON (the inbound metadata.json parser is a flagged follow-on).
      * `config` — per-table string->string overrides.

    Pure — over the raw body String; no network, no client state."""
    var root = parse_json_value(body)
    if root.kind_tag() != JSON_OBJECT:
        raise Error(
            "IcebergRestError: loadTable response is not a JSON object"
        )

    # metadata-location — REQUIRED, non-empty.
    if not root.has(String("metadata-location")):
        raise Error(
            String(
                "IcebergRestError: loadTable response for '"
            )
            + namespace
            + String(".")
            + table
            + String(
                "' has no 'metadata-location' field (cannot resolve the table's"
                " storage location)"
            )
        )
    var loc_val = root.get(String("metadata-location"))
    if loc_val.kind_tag() != JSON_STRING:
        raise Error(
            "IcebergRestError: loadTable 'metadata-location' is not a string"
        )
    var metadata_location = loc_val.as_string()
    if metadata_location.byte_length() == 0:
        raise Error(
            String(
                "IcebergRestError: loadTable 'metadata-location' is EMPTY for '"
            )
            + namespace
            + String(".")
            + table
            + String("' (cannot resolve the table's storage location)")
        )

    # metadata — surfaced verbatim as re-serialized raw JSON (may be absent).
    var metadata_json = String("")
    if root.has(String("metadata")):
        metadata_json = root.get(String("metadata")).serialize()

    # config — per-table string->string overrides (may be absent).
    var config_names = List[String]()
    var config_values = List[String]()
    if root.has(String("config")):
        var cfg = root.get(String("config"))
        if cfg.kind_tag() == JSON_OBJECT:
            for i in range(cfg.num_members()):
                if cfg.value_kind(i) != JSON_STRING:
                    continue
                config_names.append(cfg.key_at(i))
                config_values.append(cfg.value_at(i).as_string())

    return ResolvedTable(
        metadata_location^,
        metadata_json^,
        config_names^,
        config_values^,
    )


# =============================================================================
# §4 — percent-encoding for path segments.
# =============================================================================


def _percent_encode(s: String) -> String:
    """Percent-encode a path segment per RFC 3986 — every byte outside the
    unreserved set `A-Z a-z 0-9 - _ . ~` is `%XX`-encoded. This keeps a
    namespace/table/prefix containing `/`, spaces, or the `%1F` multi-level
    namespace separator wire-safe in the request path."""
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
        )
        if unreserved:
            out += chr(Int(c))
        else:
            out += "%"
            out += chr(Int(hb[(Int(c) >> 4) & 0xF]))
            out += chr(Int(hb[Int(c) & 0xF]))
    return out^
