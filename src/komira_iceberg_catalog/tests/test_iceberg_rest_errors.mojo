# =============================================================================
# test_iceberg_rest_errors.mojo — every failure the REST catalog client maps,
#   by exact message, over a ScriptedIcebergRestTransport (no sockets).
# =============================================================================
#
# Each case names the defect it would catch:
#   * Status sweeps: GET /v1/config and loadTable raise on EVERY non-200 status
#     (2xx, 3xx, 4xx, 5xx), each by its exact message. A check narrowed to
#     ">= 400" or "== 500" lets a 204 or a 301 through as a success.
#   * Malformed bodies: a config or loadTable body that is not a JSON object,
#     a `metadata-location` that is not a string, config members that are not
#     strings (skipped, never surfaced), a `defaults`/`overrides`/`config`
#     that is not an object (ignored).
#   * Side effects: a failed config fetch is NOT cached (the next resolve
#     fetches again); a raising credential provider sends nothing; a config
#     failure stops before the loadTable GET; the scripted transport raises
#     when its queue is exhausted and records the call it refused; every
#     request carries the client's host and port, Accept, and Authorization
#     only when the provider yields one.
#   * Order of checks: with two faults at once, the first-checked one is
#     reported (an HTTP status before a body parse; a 404 before the generic
#     status error; a missing location before a non-object `metadata`).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_iceberg_catalog.iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
    IcebergRestTransport,
    ScriptedIcebergRestTransport,
)
from komira_iceberg_catalog.iceberg_rest_catalog_client import (
    CatalogCredentialProvider,
    IcebergRestCatalog,
    StaticBearerToken,
)


comptime _CFG_OK: String = '{"overrides":{"prefix":"p"}}'
comptime _LOAD_OK: String = '{"metadata-location":"s3://wh/t/metadata/v1.json"}'
comptime _EM: String = " — body: "


def _client(
    var t: ScriptedIcebergRestTransport,
) -> IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken]:
    return IcebergRestCatalog[
        ScriptedIcebergRestTransport, StaticBearerToken
    ](String("catalog.example.com"), t^, StaticBearerToken(String("k")))


def _load_error(
    mut c: IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken],
    ns: String,
    tbl: String,
) -> String:
    """The message load_table raised, or "" when it returned."""
    try:
        var _r = c.load_table(ns, tbl)
    except e:
        return String(e)
    return String("")


def _statuses() -> List[Int]:
    var s = List[Int]()
    s.append(100)
    s.append(201)
    s.append(204)
    s.append(299)
    s.append(301)
    s.append(304)
    s.append(400)
    s.append(401)
    s.append(403)
    s.append(405)
    s.append(500)
    s.append(503)
    return s^


# =============================================================================
# status sweeps
# =============================================================================


def test_config_non_200_status_sweep() raises:
    var st = _statuses()
    st.append(404)
    for i in range(len(st)):
        var t = ScriptedIcebergRestTransport()
        # A body that would parse as a valid config: only the status fails.
        t.queue_response(st[i], String(_CFG_OK))
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            String("IcebergRestError: GET /v1/config returned HTTP ")
            + String(st[i])
            + String(_EM)
            + String(_CFG_OK),
        )
        # The config failure stops before any loadTable GET.
        ref rec = c.transport_ref()
        assert_equal(rec.call_count(), 1)


def test_load_table_non_200_status_sweep() raises:
    var st = _statuses()
    for i in range(len(st)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        # A body that would parse as a valid loadTable: only the status fails.
        t.queue_response(st[i], String(_LOAD_OK))
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            String("IcebergRestError: loadTable returned HTTP ")
            + String(st[i])
            + String(" for 'db.t'")
            + String(_EM)
            + String(_LOAD_OK),
        )


def test_load_table_404_exact_message() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG_OK))
    # Two faults: a 404 AND a body that is no JSON. The status is reported.
    t.queue_response(404, String("no such table"))
    var c = _client(t^)
    assert_equal(
        _load_error(c, String("ns"), String("tbl")),
        String("IcebergRestError: table not found (HTTP 404) for 'ns.tbl'")
        + String(_EM)
        + String("no such table"),
    )


# =============================================================================
# malformed bodies
# =============================================================================


def test_config_body_not_an_object() raises:
    var bodies = List[String]()
    bodies.append(String("[]"))
    bodies.append(String('"prefix"'))
    bodies.append(String("7"))
    bodies.append(String("null"))
    for i in range(len(bodies)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, bodies[i])
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            String("IcebergRestError: /v1/config response is not a JSON object"),
        )


def test_config_maps_skip_non_objects_and_non_strings() raises:
    var t = ScriptedIcebergRestTransport()
    # `defaults` is an array (ignored); `overrides` mixes a number, a bool, an
    # object, a null and two strings: only the strings are kept.
    t.queue_response(
        200,
        String(
            '{"defaults":["prefix","x"],"overrides":{"n":3,"prefix":"pp",'
            + '"b":true,"o":{"prefix":"inner"},"z":null,"w":"s3://w"}}'
        ),
    )
    t.queue_response(200, String(_LOAD_OK))
    var c = _client(t^)
    var _r = c.load_table(String("db"), String("t"))
    assert_equal(c.prefix(), String("pp"))
    assert_equal(c.config_value(String("w")), String("s3://w"))
    assert_equal(c.config_value(String("n")), String(""))
    assert_equal(c.config_value(String("b")), String(""))
    assert_equal(c.config_value(String("o")), String(""))
    assert_equal(c.config_value(String("z")), String(""))
    ref rec = c.transport_ref()
    assert_equal(rec.call_path(1), String("/v1/pp/namespaces/db/tables/t"))


def test_config_overrides_not_an_object_keeps_defaults() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        200, String('{"defaults":{"prefix":"d"},"overrides":"prefix"}')
    )
    t.queue_response(200, String(_LOAD_OK))
    var c = _client(t^)
    var _r = c.load_table(String("db"), String("t"))
    assert_equal(c.prefix(), String("d"))


def test_load_table_body_not_an_object() raises:
    var bodies = List[String]()
    bodies.append(String("[]"))
    bodies.append(String('"s3://wh/t/metadata/v1.json"'))
    bodies.append(String("false"))
    for i in range(len(bodies)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        t.queue_response(200, bodies[i])
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            String("IcebergRestError: loadTable response is not a JSON object"),
        )


def test_metadata_location_not_a_string() raises:
    var bodies = List[String]()
    bodies.append(String('{"metadata-location":5}'))
    bodies.append(String('{"metadata-location":null}'))
    bodies.append(String('{"metadata-location":["s3://wh/x"]}'))
    bodies.append(String('{"metadata-location":{"uri":"s3://wh/x"}}'))
    for i in range(len(bodies)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        t.queue_response(200, bodies[i])
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            String("IcebergRestError: loadTable 'metadata-location' is not a string"),
        )


def test_missing_and_empty_location_exact_messages() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG_OK))
    # Two faults: no location AND a `metadata` that is no object.
    t.queue_response(200, String('{"metadata":7,"metadata-locations":"s3://x"}'))
    t.queue_response(200, String('{"metadata-location":"","config":5}'))
    var c = _client(t^)
    assert_equal(
        _load_error(c, String("db"), String("a")),
        String(
            "IcebergRestError: loadTable response for 'db.a' has no"
            " 'metadata-location' field (cannot resolve the table's storage"
            " location)"
        ),
    )
    assert_equal(
        _load_error(c, String("db"), String("b")),
        String(
            "IcebergRestError: loadTable 'metadata-location' is EMPTY for"
            " 'db.b' (cannot resolve the table's storage location)"
        ),
    )


def test_load_table_config_keeps_only_string_members() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG_OK))
    t.queue_response(
        200,
        String(
            '{"metadata-location":"s3://wh/t/m.json","config":{"a":"1",'
            + '"n":2,"b":"2","o":{},"c":"3"}}'
        ),
    )
    var c = _client(t^)
    var r = c.load_table(String("db"), String("t"))
    assert_equal(len(r.config_names), 3)
    assert_equal(len(r.config_values), 3)
    assert_equal(r.config_names[0], String("a"))
    assert_equal(r.config_names[1], String("b"))
    assert_equal(r.config_names[2], String("c"))
    assert_equal(r.config_values[0], String("1"))
    assert_equal(r.config_values[1], String("2"))
    assert_equal(r.config_values[2], String("3"))
    # No `metadata` key: surfaced as "".
    assert_equal(r.metadata, String(""))


def test_load_table_config_not_an_object_is_ignored() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG_OK))
    t.queue_response(
        200,
        String('{"metadata-location":"s3://wh/t/m.json","config":["a","1"]}'),
    )
    var c = _client(t^)
    var r = c.load_table(String("db"), String("t"))
    assert_equal(r.metadata_location, String("s3://wh/t/m.json"))
    assert_equal(len(r.config_names), 0)


# =============================================================================
# side effects
# =============================================================================


def test_failed_config_is_not_cached() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(503, String("busy"))
    t.queue_response(200, String(_CFG_OK))
    t.queue_response(200, String(_LOAD_OK))
    var c = _client(t^)
    var first = _load_error(c, String("db"), String("t"))
    assert_true(first.startswith(String("IcebergRestError: GET /v1/config")))
    var r = c.load_table(String("db"), String("t"))
    assert_equal(r.metadata_location, String("s3://wh/t/metadata/v1.json"))
    assert_equal(c.prefix(), String("p"))
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 3)
    assert_equal(rec.call_path(0), String("/v1/config"))
    assert_equal(rec.call_path(1), String("/v1/config"))
    assert_equal(rec.call_path(2), String("/v1/p/namespaces/db/tables/t"))


def test_malformed_config_is_not_cached() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String("[]"))
    t.queue_response(200, String(_CFG_OK))
    t.queue_response(200, String(_LOAD_OK))
    var c = _client(t^)
    var first = _load_error(c, String("db"), String("t"))
    assert_true(first.startswith(String("IcebergRestError: /v1/config")))
    var _r = c.load_table(String("db"), String("t"))
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 3)
    assert_equal(rec.call_path(1), String("/v1/config"))


struct _RaisingCredentials(CatalogCredentialProvider, Movable, Deinitable):
    """A credential provider whose token exchange fails."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def authorization_header(mut self) raises -> String:
        self.calls += 1
        raise Error("token exchange failed")


def test_credential_failure_sends_nothing() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG_OK))
    t.queue_response(200, String(_LOAD_OK))
    var c = IcebergRestCatalog[ScriptedIcebergRestTransport, _RaisingCredentials](
        String("catalog.example.com"), t^, _RaisingCredentials()
    )
    var msg = String("")
    try:
        var _r = c.load_table(String("db"), String("t"))
    except e:
        msg = String(e)
    assert_equal(msg, String("token exchange failed"))
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 0)


def test_scripted_transport_exhausted_raises() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG_OK))
    var c = _client(t^)
    assert_equal(
        _load_error(c, String("db"), String("t")),
        String(
            "ScriptedIcebergRestTransport.get: no scripted response for call"
            " #1 (path /v1/p/namespaces/db/tables/t); queue more responses"
        ),
    )
    # The refused call is still recorded, with its Authorization header.
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 2)
    assert_equal(rec.call_auth(1), String("Bearer k"))


def test_client_defaults_and_port() raises:
    var t = ScriptedIcebergRestTransport()
    var c = _client(t^)
    assert_equal(c.host, String("catalog.example.com"))
    assert_equal(c.port, UInt16(443))
    # Before any resolve nothing is cached.
    assert_equal(c.prefix(), String(""))
    assert_equal(c.config_value(String("prefix")), String(""))
    var t2 = ScriptedIcebergRestTransport()
    var c2 = IcebergRestCatalog[
        ScriptedIcebergRestTransport, StaticBearerToken
    ](String("h.example.com"), t2^, StaticBearerToken(String("")), port=8181)
    assert_equal(c2.port, UInt16(8181))


struct _RecordingTransport(IcebergRestTransport, Movable, Deinitable):
    """Keeps every request whole (host, port, every header) and answers a
    config GET, then a loadTable GET."""

    var hosts: List[String]
    var ports: List[UInt16]
    var headers: List[String]

    def __init__(out self):
        self.hosts = List[String]()
        self.ports = List[UInt16]()
        self.headers = List[String]()

    def get(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        self.hosts.append(String(request.host))
        self.ports.append(request.port)
        var h = String("")
        for i in range(len(request.header_names)):
            h += request.header_names[i] + "=" + request.header_values[i] + ";"
        self.headers.append(h^)
        if len(self.hosts) == 1:
            return IcebergRestResponse(200, String(_CFG_OK))
        return IcebergRestResponse(200, String(_LOAD_OK))


def test_requests_carry_host_port_and_headers() raises:
    var c = IcebergRestCatalog[_RecordingTransport, StaticBearerToken](
        String("h.example.com"),
        _RecordingTransport(),
        StaticBearerToken(String("k")),
        port=8181,
    )
    var _r = c.load_table(String("db"), String("t"))
    ref rec = c.transport_ref()
    assert_equal(len(rec.hosts), 2)
    for i in range(2):
        assert_equal(rec.hosts[i], String("h.example.com"))
        assert_equal(rec.ports[i], UInt16(8181))
        # Exactly these headers, in this order: no Host (the HTTP client
        # writes it from the URL).
        assert_equal(
            rec.headers[i],
            String("Accept=application/json;Authorization=Bearer k;"),
        )
    var c2 = IcebergRestCatalog[_RecordingTransport, StaticBearerToken](
        String("h.example.com"), _RecordingTransport(), StaticBearerToken(String(""))
    )
    var _r2 = c2.load_table(String("db"), String("t"))
    ref rec2 = c2.transport_ref()
    assert_equal(rec2.ports[0], UInt16(443))
    assert_equal(rec2.headers[0], String("Accept=application/json;"))
    assert_equal(rec2.headers[1], String("Accept=application/json;"))


def main() raises:
    test_config_non_200_status_sweep()
    test_load_table_non_200_status_sweep()
    test_load_table_404_exact_message()
    test_config_body_not_an_object()
    test_config_maps_skip_non_objects_and_non_strings()
    test_config_overrides_not_an_object_keeps_defaults()
    test_load_table_body_not_an_object()
    test_metadata_location_not_a_string()
    test_missing_and_empty_location_exact_messages()
    test_load_table_config_keeps_only_string_members()
    test_load_table_config_not_an_object_is_ignored()
    test_failed_config_is_not_cached()
    test_malformed_config_is_not_cached()
    test_credential_failure_sends_nothing()
    test_scripted_transport_exhausted_raises()
    test_client_defaults_and_port()
    test_requests_carry_host_port_and_headers()
    print("test_iceberg_rest_errors: ALL PASS")
