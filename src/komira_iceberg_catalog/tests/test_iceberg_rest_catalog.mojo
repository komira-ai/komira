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
#       404 must map to a "table not found" Error.
#   (5) The BEARER TOKEN is attached to each request (assert the Authorization
#       header on the scripted transport). FALSIFIER: a client that dropped the
#       credential provider would send NO Authorization header.
#   (6) THE SEAM: the REST client AND a trivial storage-based stub both satisfy
#       `IcebergCatalog` (the read path is catalog-agnostic). FALSIFIER: if the
#       seam leaked REST-specifics, StorageBasedCatalog could not conform.
#   (7) CONFIG IS FETCHED ONCE + CACHED across loadTable calls (the prefix is not
#       re-fetched per resolve). FALSIFIER: a client that re-fetched config per
#       resolve would make 2 config GETs for 2 loadTable calls.
#
# These tests need no network: every call goes through the scripted transport.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_iceberg_catalog.iceberg_catalog import (
    IcebergCatalog,
    ResolvedTable,
    StorageBasedCatalog,
)
from komira_iceberg_catalog.iceberg_rest_transport import (
    ScriptedIcebergRestTransport,
)
from komira_iceberg_catalog.iceberg_rest_catalog_client import (
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
        # The error names the missing field (fail loud).
        assert_true(_contains(String(e), String("metadata-location")))
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
        assert_true(_contains(String(e), String("EMPTY")))
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
        assert_true(_contains(String(e), String("404")))
        assert_true(_contains(String(e), String("not found")))
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
        assert_true(_contains(String(e), String("db.missing")))
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
    print("test_iceberg_rest_catalog: ALL PASS")
