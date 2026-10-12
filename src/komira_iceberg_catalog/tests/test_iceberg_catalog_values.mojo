# =============================================================================
# test_iceberg_catalog_values.mojo — the value types and pure helpers of the
#   Iceberg catalog client: ResolvedTable, StorageBasedCatalog,
#   StaticBearerToken, IcebergRestRequest/Response, and the percent-encoding
#   of the loadTable path (driven through the public client).
# =============================================================================
#
# Each case names the defect it would catch:
#   * ResolvedTable.copy is a deep, field-by-field copy (a copy that dropped or
#     aliased a field would differ from its source, or change with it).
#   * ResolvedTable.config_value matches a key exactly and returns "" when it
#     is absent (a prefix match, or a found-index off by one, returns the
#     wrong value).
#   * has_location is False for an empty location only.
#   * StorageBasedCatalog matches the whole `namespace.table` key, never a
#     prefix of it, and resolves each of several registered tables.
#   * StaticBearerToken yields exactly `Bearer <token>`, and "" for "".
#   * IcebergRestResponse.is_ok is True for 200 only.
#   * IcebergRestRequest.header_value is an exact, case-sensitive lookup.
#   * The loadTable path percent-encodes every byte outside RFC 3986's
#     unreserved set, swept over all 128 ASCII code points and over multi-byte
#     UTF-8 (high bytes in both nibbles). The oracle is computed here by a
#     different method (membership in a literal unreserved alphabet) plus
#     fixed vectors, never by calling the encoder under test.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_iceberg_catalog.iceberg_catalog import (
    ResolvedTable,
    StorageBasedCatalog,
)
from komira_iceberg_catalog.iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
    ScriptedIcebergRestTransport,
)
from komira_iceberg_catalog.iceberg_rest_catalog_client import (
    IcebergRestCatalog,
    StaticBearerToken,
)


comptime _UNRESERVED: String = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
)
comptime _HEX: String = "0123456789ABCDEF"
comptime _LOAD_OK: String = '{"metadata-location":"s3://wh/t/metadata/v1.json"}'


def _names(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


# =============================================================================
# ResolvedTable
# =============================================================================


def test_resolved_table_copy_is_deep_and_complete() raises:
    var src = ResolvedTable(
        String("s3://wh/db/t/metadata/v2.metadata.json"),
        String('{"format-version":2}'),
        _names(String("k1"), String("k2")),
        _names(String("v1"), String("v2")),
    )
    var dup = src.copy()
    assert_equal(dup.metadata_location, src.metadata_location)
    assert_equal(dup.metadata, String('{"format-version":2}'))
    assert_equal(len(dup.config_names), 2)
    assert_equal(dup.config_value(String("k1")), String("v1"))
    assert_equal(dup.config_value(String("k2")), String("v2"))
    # Independent storage: changing the copy leaves the source alone.
    dup.config_values[0] = String("changed")
    dup.metadata_location = String("")
    assert_equal(src.config_value(String("k1")), String("v1"))
    assert_true(src.has_location())
    assert_false(dup.has_location())


def test_resolved_table_config_value_exact_match_and_absent() raises:
    var r = ResolvedTable(
        String("s3://wh/t"),
        String(""),
        _names(String("write.format"), String("write")),
        _names(String("parquet"), String("short")),
    )
    # The second key is a prefix of the first: each resolves to its own value.
    assert_equal(r.config_value(String("write")), String("short"))
    assert_equal(r.config_value(String("write.format")), String("parquet"))
    # Absent keys, including a prefix and an extension of a present key.
    assert_equal(r.config_value(String("wri")), String(""))
    assert_equal(r.config_value(String("write.format.x")), String(""))
    assert_equal(r.config_value(String("WRITE")), String(""))


def test_resolved_table_with_location_is_location_only() raises:
    var r = ResolvedTable.with_location(String("s3://wh/t/metadata/v9.json"))
    assert_equal(r.metadata_location, String("s3://wh/t/metadata/v9.json"))
    assert_equal(r.metadata, String(""))
    assert_equal(len(r.config_names), 0)
    assert_equal(len(r.config_values), 0)
    assert_true(r.has_location())
    assert_false(ResolvedTable.with_location(String("")).has_location())
    # One byte is enough to count as a location.
    assert_true(ResolvedTable.with_location(String("x")).has_location())


# =============================================================================
# StorageBasedCatalog
# =============================================================================


def test_storage_based_resolves_each_registered_table() raises:
    var c = StorageBasedCatalog()
    c.register(String("db"), String("orders"), String("s3://a/orders.json"))
    c.register(String("db"), String("items"), String("s3://a/items.json"))
    c.register(String("sales"), String("orders"), String("s3://b/orders.json"))
    assert_equal(
        c.load_table(String("db"), String("orders")).metadata_location,
        String("s3://a/orders.json"),
    )
    assert_equal(
        c.load_table(String("db"), String("items")).metadata_location,
        String("s3://a/items.json"),
    )
    var last = c.load_table(String("sales"), String("orders"))
    assert_equal(last.metadata_location, String("s3://b/orders.json"))
    assert_equal(last.metadata, String(""))
    assert_equal(len(last.config_names), 0)


def test_storage_based_key_is_matched_whole() raises:
    var c = StorageBasedCatalog()
    c.register(String("db"), String("orders"), String("s3://a/orders.json"))
    # A prefix and an extension of the registered key are both unknown.
    var probes = List[String]()
    probes.append(String("order"))
    probes.append(String("orders2"))
    probes.append(String(""))
    for i in range(len(probes)):
        var raised = False
        try:
            var _r = c.load_table(String("db"), probes[i])
        except e:
            raised = True
            assert_equal(
                String(e),
                String("IcebergCatalogError: no table registered for 'db.")
                + probes[i]
                + String("' (StorageBasedCatalog)"),
            )
        assert_true(raised, String("resolved unregistered db.") + probes[i])


# =============================================================================
# StaticBearerToken, IcebergRestResponse, IcebergRestRequest
# =============================================================================


def test_static_bearer_token_header() raises:
    var t = StaticBearerToken(String("tok"))
    assert_equal(t.authorization_header(), String("Bearer tok"))
    # A second call yields the same value (the token is not consumed).
    assert_equal(t.authorization_header(), String("Bearer tok"))
    var none = StaticBearerToken(String(""))
    assert_equal(none.authorization_header(), String(""))


def test_response_is_ok_only_for_200() raises:
    assert_true(IcebergRestResponse(200, String("")).is_ok())
    var others = List[Int]()
    others.append(199)
    others.append(201)
    others.append(204)
    others.append(304)
    others.append(404)
    others.append(500)
    for i in range(len(others)):
        assert_false(
            IcebergRestResponse(others[i], String("")).is_ok(),
            String("is_ok for ") + String(others[i]),
        )


def test_request_header_value_exact_lookup() raises:
    var req = IcebergRestRequest(
        String("catalog.example.com"),
        UInt16(8181),
        String("/v1/config"),
        _names(String("Accept"), String("Authorization")),
        _names(String("application/json"), String("Bearer z")),
    )
    assert_equal(req.host, String("catalog.example.com"))
    assert_equal(req.port, UInt16(8181))
    assert_equal(req.path, String("/v1/config"))
    assert_equal(req.header_value(String("Accept")), String("application/json"))
    assert_equal(req.header_value(String("Authorization")), String("Bearer z"))
    assert_equal(req.header_value(String("authorization")), String(""))
    assert_equal(req.header_value(String("Auth")), String(""))
    assert_equal(req.header_value(String("Host")), String(""))


# =============================================================================
# percent-encoding of the loadTable path, through the public client.
# =============================================================================


def _oracle_encode(s: String) -> String:
    """RFC 3986 path-segment encoding by alphabet membership (the encoder under
    test uses byte ranges)."""
    var alpha = _UNRESERVED.as_bytes()
    var hx = _HEX.as_bytes()
    var out = String("")
    var src = s.as_bytes()
    for i in range(len(src)):
        var b = src[i]
        var keep = False
        for j in range(len(alpha)):
            if alpha[j] == b:
                keep = True
                break
        if keep:
            out += chr(Int(b))
        else:
            out += "%"
            out += chr(Int(hx[Int(b) // 16]))
            out += chr(Int(hx[Int(b) % 16]))
    return out^


def _path_for(prefix_cfg: String, namespace: String, table: String) raises -> String:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, prefix_cfg)
    t.queue_response(200, String(_LOAD_OK))
    var client = IcebergRestCatalog[
        ScriptedIcebergRestTransport, StaticBearerToken
    ](String("catalog.example.com"), t^, StaticBearerToken(String("")))
    var _r = client.load_table(namespace, table)
    ref rec = client.transport_ref()
    assert_equal(rec.call_count(), 2)
    return rec.call_path(1)


def test_path_encoding_fixed_vectors() raises:
    # A prefix with a space, a multi-level namespace joined by the unit
    # separator, a table with a reserved character and a non-ASCII one. The
    # prefix holds no `/`: the client encodes it as %2F, while the reference
    # client keeps it (komira-ai/komira#1508), so no test pins either answer.
    var path = _path_for(
        String('{"overrides":{"prefix":"ten ant1"}}'),
        String("a") + chr(0x1F) + String("b"),
        String("t%1é"),
    )
    assert_equal(
        path,
        String("/v1/ten%20ant1/namespaces/a%1Fb/tables/t%251%C3%A9"),
    )


def test_path_encoding_sweeps_ascii_and_multibyte() raises:
    # Every ASCII code point 0x00..0x7F in the table segment; every Latin-1
    # code point U+0080..U+00FF (two-byte UTF-8, lead bytes 0xC2/0xC3 and
    # continuation bytes 0x80..0xBF) in the namespace; three- and four-byte
    # UTF-8 in the prefix (lead bytes 0xE2, 0xF0).
    var ascii = String("")
    for c in range(0x80):
        ascii += chr(c)
    var latin = String("")
    for c in range(0x80, 0x100):
        latin += chr(c)
    var wide = chr(0x20AC) + chr(0x1F600) + chr(0xFFFD)
    var path = _path_for(
        String('{"defaults":{"prefix":"') + wide + String('"}}'),
        latin,
        ascii,
    )
    var expect = (
        String("/v1/")
        + _oracle_encode(wide)
        + String("/namespaces/")
        + _oracle_encode(latin)
        + String("/tables/")
        + _oracle_encode(ascii)
    )
    assert_equal(path, expect)
    # Spot checks of the oracle itself at each range edge.
    assert_equal(_oracle_encode(String("@AZ[`az{/09:")),
        String("%40AZ%5B%60az%7B%2F09%3A"))
    assert_equal(_oracle_encode(String("-_.~ ,!")), String("-_.~%20%2C%21"))
    assert_equal(_oracle_encode(chr(0xFF)), String("%C3%BF"))
    assert_equal(_oracle_encode(chr(0x1F600)), String("%F0%9F%98%80"))


def main() raises:
    test_resolved_table_copy_is_deep_and_complete()
    test_resolved_table_config_value_exact_match_and_absent()
    test_resolved_table_with_location_is_location_only()
    test_storage_based_resolves_each_registered_table()
    test_storage_based_key_is_matched_whole()
    test_static_bearer_token_header()
    test_response_is_ok_only_for_200()
    test_request_header_value_exact_lookup()
    test_path_encoding_fixed_vectors()
    test_path_encoding_sweeps_ascii_and_multibyte()
    print("test_iceberg_catalog_values: ALL PASS")
