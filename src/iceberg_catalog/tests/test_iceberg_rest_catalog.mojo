# =============================================================================
# test_iceberg_rest_catalog.mojo — the INBOUND Iceberg REST catalog READ client
#   GATE falsifiers (RESOLVE-ONLY; over a ScriptedIcebergRestTransport).
# =============================================================================
#
# The GATE falsifiers over a ScriptedIcebergRestTransport (canned JSON per call,
# ZERO sockets, ZERO network):
#
#   (1) GET /v1/config PARSE: the catalog config parses to the correct `prefix`
#       + the merged `defaults`/`overrides` (overrides WIN). FALSIFIER: a client
#       that ignored `overrides` would resolve the wrong prefix.
#   (2) loadTable PARSE: GET the loadTable endpoint -> the correct
#       `metadata-location` is extracted (the load-bearing output), and the
#       `metadata`/`config` are surfaced. FALSIFIER: a wrong metadata-location
#       field name -> the resolve would carry the wrong storage URI.
#   (3) MISSING metadata-location -> a CLEAN typed error (NOT a silent empty
#       string). FALSIFIER: a loadTable response with no `metadata-location`
#       must RAISE, not return ResolvedTable("").
#   (4) A 404 namespace/table -> a CLEAR typed error, not a crash. FALSIFIER: a
#       404 must map to an ICEBERG_TABLE_NOT_FOUND message carrying the
#       ErrorModel type and message.
#   (5) The BEARER TOKEN is attached to each request (assert the Authorization
#       header on the scripted transport). FALSIFIER: a client that dropped the
#       credential provider would send NO Authorization header.
#   (6) THE SEAM: the REST client AND a trivial storage-based stub both satisfy
#       `IcebergCatalog` (the read path is catalog-agnostic). FALSIFIER: if the
#       seam leaked REST-specifics, StorageBasedCatalog could not conform.
#   (7) CONFIG IS FETCHED ONCE + CACHED across loadTable calls (the prefix is not
#       re-fetched per resolve). FALSIFIER: a client that re-fetched config per
#       resolve would make 2 config GETs for 2 loadTable calls.
#   (9) CONFIG HANDLING: the `warehouse` query is percent-encoded; `endpoints`
#       listed without the load endpoint refuses ICEBERG_CATALOG_ENDPOINT_
#       UNSUPPORTED before any loadTable request, and `endpoints` that is not
#       an array is ICEBERG_CATALOG_RESPONSE_INVALID and not cached; omitted
#       `endpoints` allow everything; non-string entries name nothing;
#       `idempotency-key-lifetime` counts at the top level only.
#   (8) A PREFIX WITH `/` (`catalogs/<name>`) KEEPS `/` AS A PATH SEPARATOR; each
#       piece is percent-encoded. FALSIFIER: encoding the whole prefix as one
#       segment sends `%2F`, which the server does not route.
#
# These tests need no network: every call goes through the scripted transport.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from iceberg_catalog.iceberg_catalog import (
    IcebergCatalog,
    ResolvedTable,
    StorageBasedCatalog,
)
from iceberg_catalog.iceberg_rest_transport import (
    ScriptedIcebergRestTransport,
)
from iceberg_catalog.iceberg_rest_catalog_client import (
    ENDPOINT_COMMIT_TABLE,
    ENDPOINT_CREATE_TABLE,
    ENDPOINT_LOAD_TABLE,
    IcebergRestCatalog,
    StaticBearerToken,
)


comptime _HOST: String = "catalog.example.com"
comptime _TOKEN: String = "test-bearer-token-abc123"


# =============================================================================
# scripted-response fixtures — standard Iceberg REST JSON.
# =============================================================================


def _config_json() -> String:
    """A GET /v1/config response: a `prefix` in overrides, a default warehouse.
    `overrides` WINS over `defaults` for any shared key."""
    return String(
        '{"defaults":{"clients":"4","prefix":"default-prefix"},'
        + '"overrides":{"prefix":"prod","warehouse":"s3://wh/prod"}}'
    )


def _config_json_no_prefix() -> String:
    """A single-tenant GET /v1/config with NO prefix (the paths then omit the
    prefix segment)."""
    return String('{"defaults":{},"overrides":{"warehouse":"s3://wh"}}')


def _load_table_json() -> String:
    """A loadTable response with the load-bearing metadata-location + a nested
    `metadata` object + per-table `config`."""
    return String(
        '{"metadata-location":"s3://wh/prod/db/orders/metadata/00003-abc.metadata.json",'
        + '"metadata":{"format-version":2,"table-uuid":"uuid-1234",'
        + '"location":"s3://wh/prod/db/orders","current-snapshot-id":42},'
        + '"config":{"write.parquet.compression-codec":"zstd"}}'
    )


def _load_table_json_missing_location() -> String:
    """A MALFORMED loadTable response: NO `metadata-location` field. Must RAISE a
    clean error, not return an empty-string location."""
    return String(
        '{"metadata":{"format-version":2,"table-uuid":"uuid-1234"},'
        + '"config":{}}'
    )


def _load_table_json_empty_location() -> String:
    """A loadTable response with an EMPTY `metadata-location`. Must RAISE (a
    silent empty string is the exact bug the falsifier guards)."""
    return String('{"metadata-location":"","metadata":{},"config":{}}')


def _not_found_json() -> String:
    """A 404 loadTable error envelope (NoSuchTableException)."""
    return String(
        '{"error":{"message":"Table does not exist: db.orders",'
        + '"type":"NoSuchTableException","code":404}}'
    )


def _mk_client(
    var transport: ScriptedIcebergRestTransport, var token: String
) -> IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken]:
    """Build a REST catalog client over the scripted transport + a static bearer
    token."""
    return IcebergRestCatalog[
        ScriptedIcebergRestTransport, StaticBearerToken
    ](String(_HOST), transport^, StaticBearerToken(token^))


# =============================================================================
# (1) GET /v1/config parse -> correct prefix + overrides.
# =============================================================================


def test_config_parse_prefix_and_overrides() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    # A resolve triggers the (cached) config fetch.
    var resolved = client.load_table(String("db"), String("orders"))
    # `overrides.prefix` wins over `defaults.prefix`.
    assert_equal(client.prefix(), String("prod"))
    # A `defaults`-only key survives the merge.
    assert_equal(client.config_value(String("clients")), String("4"))
    # An `overrides`-only key is present.
    assert_equal(
        client.config_value(String("warehouse")), String("s3://wh/prod")
    )
    # Sanity: the resolve produced a location (detailed in test (2)).
    assert_true(resolved.has_location())


# =============================================================================
# (2) loadTable parse -> correct metadata-location + metadata + config surfaced.
# =============================================================================


def test_load_table_parse_metadata_location() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var resolved = client.load_table(String("db"), String("orders"))
    # THE LOAD-BEARING OUTPUT — the metadata-location.
    assert_equal(
        resolved.metadata_location,
        String("s3://wh/prod/db/orders/metadata/00003-abc.metadata.json"),
    )
    assert_true(resolved.has_location())
    # `metadata` surfaced verbatim (re-serialized) — contains the table-uuid.
    assert_true(resolved.metadata.byte_length() > 0)
    assert_true(_contains(resolved.metadata, String("uuid-1234")))
    assert_true(_contains(resolved.metadata, String("format-version")))
    # per-table `config` surfaced.
    assert_equal(
        resolved.config_value(String("write.parquet.compression-codec")),
        String("zstd"),
    )
    # The loadTable path was built with the resolved prefix + the ns/table.
    ref rec = client.transport_ref()
    assert_equal(rec.call_path(0), String("/v1/config"))
    assert_equal(
        rec.call_path(1), String("/v1/prod/namespaces/db/tables/orders")
    )


# =============================================================================
# (3) Missing metadata-location -> a CLEAN typed error (NOT a silent empty str).
# =============================================================================


def test_missing_metadata_location_raises() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json_missing_location())
    var client = _mk_client(t^, String(_TOKEN))
    var raised = False
    try:
        var _r = client.load_table(String("db"), String("orders"))
    except e:
        raised = True
        assert_equal(
            String(e),
            String(
                "ICEBERG_CATALOG_RESPONSE_INVALID: loadTable 'db.orders'"
                " response has no 'metadata-location'"
            ),
        )
    assert_true(raised)


def test_empty_metadata_location_raises() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json_empty_location())
    var client = _mk_client(t^, String(_TOKEN))
    var raised = False
    try:
        var _r = client.load_table(String("db"), String("orders"))
    except e:
        raised = True
        assert_equal(
            String(e),
            String(
                "ICEBERG_CATALOG_RESPONSE_INVALID: loadTable 'db.orders'"
                " 'metadata-location' is empty"
            ),
        )
    assert_true(raised)


# =============================================================================
# (4) A 404 namespace/table -> a CLEAR typed error, not a crash.
# =============================================================================


def test_not_found_raises() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(404, _not_found_json())
    var client = _mk_client(t^, String(_TOKEN))
    var raised = False
    try:
        var _r = client.load_table(String("db"), String("orders"))
    except e:
        raised = True
        assert_equal(
            String(e),
            String(
                "ICEBERG_TABLE_NOT_FOUND: loadTable 'db.orders': HTTP 404:"
                " NoSuchTableException: Table does not exist: db.orders"
            ),
        )
    assert_true(raised)


# =============================================================================
# (5) The BEARER TOKEN is attached to each request.
# =============================================================================


def test_bearer_token_attached() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var _r = client.load_table(String("db"), String("orders"))
    # BOTH the config GET and the loadTable GET carry the bearer token.
    ref rec = client.transport_ref()
    assert_equal(
        rec.call_auth(0), String("Bearer test-bearer-token-abc123")
    )
    assert_equal(
        rec.call_auth(1), String("Bearer test-bearer-token-abc123")
    )


def test_no_token_omits_auth_header() raises:
    """An empty token -> an unauthenticated catalog -> NO Authorization header on
    the request (the no-auth path)."""
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(""))
    var _r = client.load_table(String("db"), String("orders"))
    ref rec = client.transport_ref()
    assert_equal(rec.call_auth(0), String(""))
    assert_equal(rec.call_auth(1), String(""))


# =============================================================================
# (6) THE SEAM: REST client + storage-based stub both satisfy IcebergCatalog.
# =============================================================================


def _resolve_through_seam[C: IcebergCatalog](
    mut catalog: C, namespace: String, table: String
) raises -> String:
    """Drive ANY IcebergCatalog conformer through the seam + return the resolved
    metadata-location. This function is generic over the catalog conformer — it
    is the catalog-agnostic read-path shape. That it compiles + runs for BOTH
    the REST client AND the storage-based stub IS the seam proof."""
    var resolved = catalog.load_table(namespace, table)
    return resolved.metadata_location


def test_seam_covers_rest_and_storage_based() raises:
    # (a) the REST conformer through the seam.
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    var rest = _mk_client(t^, String(_TOKEN))
    var rest_loc = _resolve_through_seam(rest, String("db"), String("orders"))
    assert_equal(
        rest_loc,
        String("s3://wh/prod/db/orders/metadata/00003-abc.metadata.json"),
    )

    # (b) the storage-based conformer through the SAME seam.
    var storage = StorageBasedCatalog()
    storage.register(
        String("db"),
        String("orders"),
        String("s3://wh/local/db/orders/metadata/v7.metadata.json"),
    )
    var storage_loc = _resolve_through_seam(
        storage, String("db"), String("orders")
    )
    assert_equal(
        storage_loc,
        String("s3://wh/local/db/orders/metadata/v7.metadata.json"),
    )


def test_storage_based_unregistered_raises() raises:
    var storage = StorageBasedCatalog()
    var raised = False
    try:
        var _r = storage.load_table(String("db"), String("missing"))
    except e:
        raised = True
        assert_equal(
            String(e),
            String(
                "IcebergCatalogError: no table registered for 'db.missing'"
                " (StorageBasedCatalog)"
            ),
        )
    assert_true(raised)


# =============================================================================
# (7) Config is fetched ONCE + cached across loadTable calls.
# =============================================================================


def test_config_fetched_once_cached() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var _r1 = client.load_table(String("db"), String("orders"))
    var _r2 = client.load_table(String("db"), String("orders"))
    # 3 calls total: ONE config + TWO loadTable (config NOT re-fetched).
    ref rec = client.transport_ref()
    assert_equal(rec.call_count(), 3)
    assert_equal(rec.call_path(0), String("/v1/config"))
    assert_equal(
        rec.call_path(1), String("/v1/prod/namespaces/db/tables/orders")
    )
    assert_equal(
        rec.call_path(2), String("/v1/prod/namespaces/db/tables/orders")
    )


# =============================================================================
# single-tenant (no prefix) path building.
# =============================================================================


def test_no_prefix_omits_prefix_segment() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json_no_prefix())
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var _r = client.load_table(String("db"), String("orders"))
    assert_equal(client.prefix(), String(""))
    # No prefix segment -> /v1/namespaces/... (not /v1//namespaces/...).
    ref rec = client.transport_ref()
    assert_equal(
        rec.call_path(1), String("/v1/namespaces/db/tables/orders")
    )


# =============================================================================
# multi-segment prefix: a `/` in the prefix stays a path separator.
# =============================================================================


def test_multi_segment_prefix_keeps_slash() raises:
    """A config prefix with a `/` (Unity Catalog's `catalogs/<name>` form) is
    joined into the path with its `/` kept, as the Iceberg Java client's
    ResourcePaths does; each `/`-separated piece is still percent-encoded.
    FALSIFIER: a client that encodes the whole prefix as one segment sends
    `/v1/ten%20ant%2F1/...`, which the server does not route."""
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200, String('{"defaults":{},"overrides":{"prefix":"ten ant/1"}}')
    )
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var _r = client.load_table(String("db"), String("t"))
    assert_equal(client.prefix(), String("ten ant/1"))
    ref rec = client.transport_ref()
    assert_equal(
        rec.call_path(1), String("/v1/ten%20ant/1/namespaces/db/tables/t")
    )


def test_unity_style_prefix_path() raises:
    """The prefix form Unity Catalog returns: `catalogs/main`."""
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200, String('{"defaults":{},"overrides":{"prefix":"catalogs/main"}}')
    )
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var _r = client.load_table(String("db"), String("orders"))
    ref rec = client.transport_ref()
    assert_equal(
        rec.call_path(1), String("/v1/catalogs/main/namespaces/db/tables/orders")
    )


# =============================================================================
# config handling: warehouse, endpoints, idempotency-key-lifetime.
# =============================================================================


def _config_with_endpoints(endpoints_json: String) -> String:
    return (
        String('{"defaults":{},"overrides":{"prefix":"prod"},"endpoints":')
        + endpoints_json
        + String("}")
    )


def _load_error(
    mut c: IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken],
) -> String:
    """The message load_table raised, or "" when it returned."""
    try:
        var _r = c.load_table(String("db"), String("orders"))
    except e:
        return String(e)
    return String("")


def _require_error(
    mut c: IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken],
    endpoint: String,
) -> String:
    """The message require_endpoint raised, or "" when it returned."""
    try:
        c.require_endpoint(endpoint)
    except e:
        return String(e)
    return String("")


def test_warehouse_is_a_percent_encoded_config_query() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    var client = IcebergRestCatalog[
        ScriptedIcebergRestTransport, StaticBearerToken
    ](
        String(_HOST),
        t^,
        StaticBearerToken(String(_TOKEN)),
        warehouse=String("s3://wh/my wh&x=1"),
    )
    var _r = client.load_table(String("db"), String("orders"))
    ref rec = client.transport_ref()
    assert_equal(
        rec.call_path(0),
        String("/v1/config?warehouse=s3%3A%2F%2Fwh%2Fmy%20wh%26x%3D1"),
    )
    assert_equal(
        rec.call_path(1), String("/v1/prod/namespaces/db/tables/orders")
    )


def test_no_warehouse_sends_no_query() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var _r = client.load_table(String("db"), String("orders"))
    ref rec = client.transport_ref()
    assert_equal(rec.call_path(0), String("/v1/config"))


def test_endpoints_without_load_refuse_before_any_load_request() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200,
        _config_with_endpoints(
            String(
                '["POST /v1/{prefix}/namespaces/{namespace}/tables",'
                + '"POST /v1/{prefix}/namespaces/{namespace}/tables/{table}"]'
            )
        ),
    )
    var client = _mk_client(t^, String(_TOKEN))
    var want = String(
        "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not list"
        " 'GET /v1/{prefix}/namespaces/{namespace}/tables/{table}'"
    )
    assert_equal(_load_error(client), want)
    # The config answered once, and no loadTable request was sent.
    ref rec = client.transport_ref()
    assert_equal(rec.call_count(), 1)
    assert_equal(rec.call_path(0), String("/v1/config"))
    # The refusal is repeatable from the cached config.
    assert_equal(_load_error(client), want)
    assert_equal(rec.call_count(), 1)
    # load_table_metadata refuses the same way.
    var metadata_error = String("")
    try:
        var _m = client.load_table_metadata(String("db"), String("orders"))
    except e:
        metadata_error = String(e)
    assert_equal(metadata_error, want)
    assert_equal(rec.call_count(), 1)


def test_require_endpoint_checks_each_endpoint_the_client_calls() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200,
        _config_with_endpoints(
            String(
                '["GET /v1/{prefix}/namespaces/{namespace}/tables/{table}"]'
            )
        ),
    )
    var client = _mk_client(t^, String(_TOKEN))
    assert_equal(_require_error(client, ENDPOINT_LOAD_TABLE), String(""))
    assert_equal(
        _require_error(client, ENDPOINT_CREATE_TABLE),
        String(
            "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not list"
            " 'POST /v1/{prefix}/namespaces/{namespace}/tables'"
        ),
    )
    assert_equal(
        _require_error(client, ENDPOINT_COMMIT_TABLE),
        String(
            "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not list"
            " 'POST /v1/{prefix}/namespaces/{namespace}/tables/{table}'"
        ),
    )


def test_endpoints_listing_load_allow_the_load() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200,
        _config_with_endpoints(
            String('["GET /v1/config","')
            + ENDPOINT_LOAD_TABLE
            + String('","POST /v1/{prefix}/namespaces/{namespace}/tables"]')
        ),
    )
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var r = client.load_table(String("db"), String("orders"))
    assert_equal(
        r.metadata_location,
        String("s3://wh/prod/db/orders/metadata/00003-abc.metadata.json"),
    )
    ref rec = client.transport_ref()
    assert_equal(rec.call_count(), 2)


def test_endpoints_omitted_allow_every_endpoint() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    assert_equal(_require_error(client, ENDPOINT_LOAD_TABLE), String(""))
    assert_equal(_require_error(client, ENDPOINT_CREATE_TABLE), String(""))
    assert_equal(_require_error(client, ENDPOINT_COMMIT_TABLE), String(""))
    var _r = client.load_table(String("db"), String("orders"))
    ref rec = client.transport_ref()
    assert_equal(rec.call_count(), 2)


def test_endpoints_that_is_not_an_array_is_invalid_and_not_cached() raises:
    var bad = List[String]()
    bad.append(String('"GET /v1/config"'))
    bad.append(String("null"))
    bad.append(String("{}"))
    bad.append(String("7"))
    for i in range(len(bad)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, _config_with_endpoints(bad[i]))
        t.queue_response(200, _config_json())
        t.queue_response(200, _load_table_json())
        var client = _mk_client(t^, String(_TOKEN))
        assert_equal(
            _load_error(client),
            String(
                "ICEBERG_CATALOG_RESPONSE_INVALID: /v1/config 'endpoints' is"
                " not an array"
            ),
        )
        # Not cached: the next request fetches the config again.
        var r = client.load_table(String("db"), String("orders"))
        assert_equal(
            r.metadata_location,
            String("s3://wh/prod/db/orders/metadata/00003-abc.metadata.json"),
        )
        ref rec = client.transport_ref()
        assert_equal(rec.call_count(), 3)
        assert_equal(rec.call_path(0), String("/v1/config"))
        assert_equal(rec.call_path(1), String("/v1/config"))


def test_non_string_endpoint_entries_are_ignored() raises:
    # Entries that are not strings do not name an endpoint, and do not stop
    # the string entry beside them from counting.
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200,
        _config_with_endpoints(
            String('[5,null,{"x":1},["a"],true,"')
            + ENDPOINT_LOAD_TABLE
            + String('"]')
        ),
    )
    t.queue_response(200, _load_table_json())
    var client = _mk_client(t^, String(_TOKEN))
    var _r = client.load_table(String("db"), String("orders"))
    ref rec = client.transport_ref()
    assert_equal(rec.call_count(), 2)


def test_endpoints_with_no_string_entries_list_nothing() raises:
    var lists = List[String]()
    lists.append(String("[]"))
    lists.append(String("[5,null,{}]"))
    for i in range(len(lists)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, _config_with_endpoints(lists[i]))
        var client = _mk_client(t^, String(_TOKEN))
        assert_equal(
            _load_error(client),
            String(
                "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not"
                " list 'GET /v1/{prefix}/namespaces/{namespace}/tables/{table}'"
            ),
        )
        ref rec = client.transport_ref()
        assert_equal(rec.call_count(), 1)


def test_idempotency_key_lifetime_is_read_from_the_top_level() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200,
        String(
            '{"defaults":{},"overrides":{"prefix":"prod"},'
            + '"idempotency-key-lifetime":"PT30M"}'
        ),
    )
    var client = _mk_client(t^, String(_TOKEN))
    # The first call fetches the config; the second reads the cache.
    assert_true(client.supports_idempotency())
    assert_true(client.supports_idempotency())
    ref rec = client.transport_ref()
    assert_equal(rec.call_count(), 1)


def test_idempotency_key_lifetime_inside_the_maps_does_not_count() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200,
        String(
            '{"defaults":{"idempotency-key-lifetime":"PT30M"},'
            + '"overrides":{"idempotency-key-lifetime":"PT30M"}}'
        ),
    )
    var client = _mk_client(t^, String(_TOKEN))
    assert_false(client.supports_idempotency())


def test_idempotency_absent_is_not_supported() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, _config_json())
    var client = _mk_client(t^, String(_TOKEN))
    assert_false(client.supports_idempotency())
    ref rec = client.transport_ref()
    assert_equal(rec.call_count(), 1)


# =============================================================================
# helper — substring containment (no stdlib `in` on String here).
# =============================================================================


def _contains(haystack: String, needle: String) -> Bool:
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    var hn = len(h)
    var nn = len(n)
    if nn == 0:
        return True
    if nn > hn:
        return False
    for start in range(hn - nn + 1):
        var matched = True
        for j in range(nn):
            if h[start + j] != n[j]:
                matched = False
                break
        if matched:
            return True
    return False


def main() raises:
    test_config_parse_prefix_and_overrides()
    test_load_table_parse_metadata_location()
    test_missing_metadata_location_raises()
    test_empty_metadata_location_raises()
    test_not_found_raises()
    test_bearer_token_attached()
    test_no_token_omits_auth_header()
    test_seam_covers_rest_and_storage_based()
    test_storage_based_unregistered_raises()
    test_config_fetched_once_cached()
    test_no_prefix_omits_prefix_segment()
    test_multi_segment_prefix_keeps_slash()
    test_unity_style_prefix_path()
    test_warehouse_is_a_percent_encoded_config_query()
    test_no_warehouse_sends_no_query()
    test_endpoints_without_load_refuse_before_any_load_request()
    test_require_endpoint_checks_each_endpoint_the_client_calls()
    test_endpoints_listing_load_allow_the_load()
    test_endpoints_omitted_allow_every_endpoint()
    test_endpoints_that_is_not_an_array_is_invalid_and_not_cached()
    test_non_string_endpoint_entries_are_ignored()
    test_endpoints_with_no_string_entries_list_nothing()
    test_idempotency_key_lifetime_is_read_from_the_top_level()
    test_idempotency_key_lifetime_inside_the_maps_does_not_count()
    test_idempotency_absent_is_not_supported()
    print("test_iceberg_rest_catalog: ALL PASS")
