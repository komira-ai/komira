# =============================================================================
# test_iceberg_rest_errors.mojo — every failure of the REST catalog client's
#   config and loadTable path, by exact message, over a
#   ScriptedIcebergRestTransport (no sockets).
# =============================================================================
#
# Every message starts with its token. Each case names the defect it would
# catch:
#   * Status sweeps: GET /v1/config and loadTable map EVERY status from 100 to
#     599 (200 aside) to the token of its class: 404 on a table path by error
#     type (table or namespace), 401 and 419 unauthorized, 403 forbidden, any
#     5xx unavailable, everything else rejected (a 404 on config included). A
#     check narrowed to ">= 400" or "== 500" lets a 204 or a 301 through, and
#     a class test off by one moves a boundary status (499, 500, 599, 600)
#     into the wrong token.
#   * Transport errors: a raise from the transport on config, loadTable,
#     createTable or commitTable is ICEBERG_CATALOG_UNAVAILABLE naming the
#     request (an unknown outcome for a commit); a failed config is not
#     cached, and a failed load leaves the cached config alone.
#   * Malformed bodies: a config or loadTable body that is not JSON or not a
#     JSON object, a `metadata-location` that is not a string, config members
#     that are not strings (skipped, never surfaced), a `defaults`/
#     `overrides`/`config` that is not an object (ignored).
#   * Side effects: a failed config fetch is NOT cached (the next resolve
#     fetches again); a raising credential provider sends nothing; a config
#     failure stops before the loadTable GET; the scripted transport raises
#     when its queue is exhausted and records the call it refused; every
#     request carries the client's host and port, Accept, and Authorization
#     only when the provider yields one.
#   * Order of checks: with two faults at once, the first-checked one is
#     reported (an HTTP status before a body parse; a missing location before
#     a non-object `metadata`).
# The error-model reading and the createTable and commitTable statuses are in
# test_iceberg_rest_error_messages.mojo.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from json import JsonValue

from iceberg_catalog.iceberg_rest_errors import (
    ICEBERG_CATALOG_FORBIDDEN,
    ICEBERG_CATALOG_REJECTED,
    ICEBERG_CATALOG_UNAUTHORIZED,
    ICEBERG_CATALOG_UNAVAILABLE,
    ICEBERG_TABLE_NOT_FOUND,
)
from iceberg_catalog.iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
    IcebergRestTransport,
    ScriptedIcebergRestTransport,
)
from iceberg_catalog.iceberg_rest_catalog_client import (
    CatalogCredentialProvider,
    COMMIT_UNKNOWN,
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_table_changes import CreateTableRequest


comptime _CFG_OK: String = '{"overrides":{"prefix":"p"}}'
comptime _LOAD_OK: String = '{"metadata-location":"s3://wh/t/metadata/v1.json"}'


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


def _create_error(
    mut c: IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken],
    request: CreateTableRequest,
) -> String:
    """The message create_table raised, or "" when it returned."""
    try:
        var _r = c.create_table(String("db"), request)
    except e:
        return String(e)
    return String("")


def _new_table(stage: Bool) -> CreateTableRequest:
    return CreateTableRequest(
        String("t"), JsonValue.empty_object(), stage_create=stage
    )


def _token_for(status: Int, table_path: Bool) -> String:
    """The token a non-200 status maps to when no error type says otherwise."""
    if status == 404 and table_path:
        return ICEBERG_TABLE_NOT_FOUND
    if status == 401 or status == 419:
        return ICEBERG_CATALOG_UNAUTHORIZED
    if status == 403:
        return ICEBERG_CATALOG_FORBIDDEN
    if status >= 500 and status <= 599:
        return ICEBERG_CATALOG_UNAVAILABLE
    return ICEBERG_CATALOG_REJECTED


# =============================================================================
# status sweeps
# =============================================================================


def test_config_non_200_status_sweep() raises:
    for status in range(100, 600):
        if status == 200:
            continue
        var t = ScriptedIcebergRestTransport()
        # A body that would parse as a valid config: only the status fails.
        t.queue_response(status, String(_CFG_OK))
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            _token_for(status, False)
            + String(": GET /v1/config: HTTP ")
            + String(status),
        )
        # The config failure stops before any loadTable GET.
        ref rec = c.transport_ref()
        assert_equal(rec.call_count(), 1)


def test_config_status_tokens_by_class() raises:
    var statuses = List[Int]()
    var tokens = List[String]()
    statuses.append(100)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(204)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(301)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(400)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(401)
    tokens.append(ICEBERG_CATALOG_UNAUTHORIZED)
    statuses.append(403)
    tokens.append(ICEBERG_CATALOG_FORBIDDEN)
    statuses.append(404)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(419)
    tokens.append(ICEBERG_CATALOG_UNAUTHORIZED)
    statuses.append(499)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(500)
    tokens.append(ICEBERG_CATALOG_UNAVAILABLE)
    statuses.append(599)
    tokens.append(ICEBERG_CATALOG_UNAVAILABLE)
    statuses.append(600)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    for i in range(len(statuses)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(statuses[i], String(_CFG_OK))
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            tokens[i]
            + String(": GET /v1/config: HTTP ")
            + String(statuses[i]),
        )


def test_load_table_non_200_status_sweep() raises:
    for status in range(100, 600):
        if status == 200:
            continue
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        # A body that would parse as a valid loadTable: only the status fails.
        t.queue_response(status, String(_LOAD_OK))
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            _token_for(status, True)
            + String(": loadTable 'db.t': HTTP ")
            + String(status),
        )


def test_load_table_status_tokens_by_class() raises:
    var statuses = List[Int]()
    var tokens = List[String]()
    statuses.append(204)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(301)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(400)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(401)
    tokens.append(ICEBERG_CATALOG_UNAUTHORIZED)
    statuses.append(403)
    tokens.append(ICEBERG_CATALOG_FORBIDDEN)
    statuses.append(404)
    tokens.append(ICEBERG_TABLE_NOT_FOUND)
    statuses.append(409)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(419)
    tokens.append(ICEBERG_CATALOG_UNAUTHORIZED)
    statuses.append(499)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    statuses.append(500)
    tokens.append(ICEBERG_CATALOG_UNAVAILABLE)
    statuses.append(503)
    tokens.append(ICEBERG_CATALOG_UNAVAILABLE)
    statuses.append(599)
    tokens.append(ICEBERG_CATALOG_UNAVAILABLE)
    statuses.append(600)
    tokens.append(ICEBERG_CATALOG_REJECTED)
    for i in range(len(statuses)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        t.queue_response(statuses[i], String(_LOAD_OK))
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            tokens[i]
            + String(": loadTable 'db.t': HTTP ")
            + String(statuses[i]),
        )


def test_load_table_404_by_error_type() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG_OK))
    # Two faults: a 404 AND a body that is no JSON. The status is reported.
    t.queue_response(404, String("no such table"))
    t.queue_response(
        404,
        String(
            '{"error":{"message":"Namespace does not exist: ns","type":'
            + '"NoSuchNamespaceException","code":404}}'
        ),
    )
    t.queue_response(
        404,
        String(
            '{"error":{"message":"Table does not exist: ns.tbl","type":'
            + '"NoSuchTableException","code":404}}'
        ),
    )
    t.queue_response(
        404, String('{"error":{"message":"gone","type":"SomethingElse"}}')
    )
    var c = _client(t^)
    assert_equal(
        _load_error(c, String("ns"), String("tbl")),
        String("ICEBERG_TABLE_NOT_FOUND: loadTable 'ns.tbl': HTTP 404"),
    )
    assert_equal(
        _load_error(c, String("ns"), String("tbl")),
        String(
            "ICEBERG_NAMESPACE_NOT_FOUND: loadTable 'ns.tbl': HTTP 404:"
            " NoSuchNamespaceException: Namespace does not exist: ns"
        ),
    )
    assert_equal(
        _load_error(c, String("ns"), String("tbl")),
        String(
            "ICEBERG_TABLE_NOT_FOUND: loadTable 'ns.tbl': HTTP 404:"
            " NoSuchTableException: Table does not exist: ns.tbl"
        ),
    )
    assert_equal(
        _load_error(c, String("ns"), String("tbl")),
        String(
            "ICEBERG_TABLE_NOT_FOUND: loadTable 'ns.tbl': HTTP 404:"
            " SomethingElse: gone"
        ),
    )


def test_config_404_with_namespace_type_is_rejected() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(
        404,
        String(
            '{"error":{"message":"nope","type":"NoSuchNamespaceException"}}'
        ),
    )
    var c = _client(t^)
    assert_equal(
        _load_error(c, String("db"), String("t")),
        String(
            "ICEBERG_CATALOG_REJECTED: GET /v1/config: HTTP 404:"
            " NoSuchNamespaceException: nope"
        ),
    )


# =============================================================================
# transport errors
# =============================================================================


struct _DroppingTransport(IcebergRestTransport, Movable, Deinitable):
    """Answers from a scripted queue, except the calls (numbered from 0) in
    `dropped`, which raise as a lost connection does. Records the path of
    every call, dropped or not."""

    var inner: ScriptedIcebergRestTransport
    var dropped: List[Int]
    var paths: List[String]

    def __init__(
        out self, var inner: ScriptedIcebergRestTransport, var dropped: List[Int]
    ):
        self.inner = inner^
        self.dropped = dropped^
        self.paths = List[String]()

    def send(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        var n = len(self.paths)
        self.paths.append(String(request.path))
        for i in range(len(self.dropped)):
            if self.dropped[i] == n:
                raise Error("connection reset")
        return self.inner.send(request)


def _dropping_client(
    var inner: ScriptedIcebergRestTransport, var dropped: List[Int]
) -> IcebergRestCatalog[_DroppingTransport, StaticBearerToken]:
    return IcebergRestCatalog[_DroppingTransport, StaticBearerToken](
        String("catalog.example.com"),
        _DroppingTransport(inner^, dropped^),
        StaticBearerToken(String("k")),
    )


def _load_error_of(
    mut c: IcebergRestCatalog[_DroppingTransport, StaticBearerToken],
) -> String:
    try:
        var _r = c.load_table(String("db"), String("t"))
    except e:
        return String(e)
    return String("")


def test_transport_error_on_config_is_unavailable_and_not_cached() raises:
    var inner = ScriptedIcebergRestTransport()
    inner.queue_response(200, String(_CFG_OK))
    inner.queue_response(200, String(_LOAD_OK))
    var dropped = List[Int]()
    dropped.append(0)
    var c = _dropping_client(inner^, dropped^)
    assert_equal(
        _load_error_of(c),
        String(
            "ICEBERG_CATALOG_UNAVAILABLE: GET /v1/config: transport error:"
            " connection reset"
        ),
    )
    # The retry fetches the config again and then loads.
    var r = c.load_table(String("db"), String("t"))
    assert_equal(r.metadata_location, String("s3://wh/t/metadata/v1.json"))
    ref rec = c.transport_ref()
    assert_equal(len(rec.paths), 3)
    assert_equal(rec.paths[0], String("/v1/config"))
    assert_equal(rec.paths[1], String("/v1/config"))
    assert_equal(rec.paths[2], String("/v1/p/namespaces/db/tables/t"))


def test_transport_error_on_load_is_unavailable_and_keeps_config() raises:
    var inner = ScriptedIcebergRestTransport()
    inner.queue_response(200, String(_CFG_OK))
    inner.queue_response(200, String(_LOAD_OK))
    var dropped = List[Int]()
    dropped.append(1)
    var c = _dropping_client(inner^, dropped^)
    assert_equal(
        _load_error_of(c),
        String(
            "ICEBERG_CATALOG_UNAVAILABLE: loadTable 'db.t': transport error:"
            " connection reset"
        ),
    )
    var r = c.load_table(String("db"), String("t"))
    assert_equal(r.metadata_location, String("s3://wh/t/metadata/v1.json"))
    # The config was read once: the second load goes straight to the table.
    ref rec = c.transport_ref()
    assert_equal(len(rec.paths), 3)
    assert_equal(rec.paths[0], String("/v1/config"))
    assert_equal(rec.paths[1], String("/v1/p/namespaces/db/tables/t"))
    assert_equal(rec.paths[2], String("/v1/p/namespaces/db/tables/t"))


def test_transport_error_on_create_is_unavailable() raises:
    var inner = ScriptedIcebergRestTransport()
    inner.queue_response(200, String(_CFG_OK))
    var dropped = List[Int]()
    dropped.append(1)
    var c = _dropping_client(inner^, dropped^)
    var msg = String("")
    try:
        var _r = c.create_table(String("db"), _new_table(False))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "ICEBERG_CATALOG_UNAVAILABLE: createTable 'db.t': transport error:"
            " connection reset"
        ),
    )


def test_transport_error_on_commit_is_an_unknown_outcome() raises:
    var inner = ScriptedIcebergRestTransport()
    inner.queue_response(200, String(_CFG_OK))
    var dropped = List[Int]()
    dropped.append(1)
    var c = _dropping_client(inner^, dropped^)
    var r = c.commit_table(String("db"), String("t"), String("{}"), String(""))
    assert_equal(r.kind, COMMIT_UNKNOWN)
    assert_equal(r.status, 0)
    assert_false(Bool(r.table))
    assert_equal(
        r.message,
        String(
            "ICEBERG_CATALOG_UNAVAILABLE: commitTable 'db.t': transport error:"
            " connection reset"
        ),
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
            String(
                "ICEBERG_CATALOG_RESPONSE_INVALID: /v1/config response is not a"
                " JSON object"
            ),
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
            String(
                "ICEBERG_CATALOG_RESPONSE_INVALID: loadTable 'db.t' response is"
                " not a JSON object"
            ),
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
            String(
                "ICEBERG_CATALOG_RESPONSE_INVALID: loadTable 'db.t'"
                " 'metadata-location' is not a string"
            ),
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
            "ICEBERG_CATALOG_RESPONSE_INVALID: loadTable 'db.a' response has"
            " no 'metadata-location'"
        ),
    )
    assert_equal(
        _load_error(c, String("db"), String("b")),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: loadTable 'db.b'"
            " 'metadata-location' is empty"
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
    assert_equal(
        _load_error(c, String("db"), String("t")),
        String("ICEBERG_CATALOG_UNAVAILABLE: GET /v1/config: HTTP 503"),
    )
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
    assert_equal(
        _load_error(c, String("db"), String("t")),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: /v1/config response is not a"
            " JSON object"
        ),
    )
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
            "ICEBERG_CATALOG_UNAVAILABLE: loadTable 'db.t': transport error:"
            " ScriptedIcebergRestTransport.send: no scripted response for"
            " call #1 (path /v1/p/namespaces/db/tables/t); queue more"
            " responses"
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

    def send(
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


def test_config_and_load_bodies_that_are_not_json() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String("{not json"))
    t.queue_response(200, String(_CFG_OK))
    t.queue_response(200, String("<html>gateway</html>"))
    var c = _client(t^)
    assert_equal(
        _load_error(c, String("db"), String("t")),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: /v1/config response is not"
            " JSON"
        ),
    )
    assert_equal(
        _load_error(c, String("db"), String("t")),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: loadTable 'db.t' response is"
            " not JSON"
        ),
    )


def main() raises:
    test_config_non_200_status_sweep()
    test_config_status_tokens_by_class()
    test_load_table_non_200_status_sweep()
    test_load_table_status_tokens_by_class()
    test_load_table_404_by_error_type()
    test_config_404_with_namespace_type_is_rejected()
    test_transport_error_on_config_is_unavailable_and_not_cached()
    test_transport_error_on_load_is_unavailable_and_keeps_config()
    test_transport_error_on_create_is_unavailable()
    test_transport_error_on_commit_is_an_unknown_outcome()
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
    test_config_and_load_bodies_that_are_not_json()
    print("test_iceberg_rest_errors: ALL PASS")
