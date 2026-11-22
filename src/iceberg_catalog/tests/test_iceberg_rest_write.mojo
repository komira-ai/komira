# =============================================================================
# test_iceberg_rest_write.mojo — the REST write path of the catalog client over
#   a ScriptedIcebergRestTransport (no sockets): the request values, the
#   scripted transport's recording, createTable and commitTable by exact path,
#   header, body bytes and message.
# =============================================================================
#
# Each case names the defect it would catch:
#   * IcebergRestMethod / IcebergRestRequest: a post that reported GET, a copy
#     that dropped the method, body, a header or the port, or shared storage
#     with its original (the committer resends a copy under the same key);
#   * the scripted transport records method, body and every header of each call
#     (a recorder that lost the POST body or a header hides what was sent);
#   * createTable: the path with and without a prefix and with a percent-encoded
#     namespace; the body bytes with and without location and properties; a
#     Content-Type and never an Idempotency-Key; a staged create returns an
#     empty location while a direct create without one is invalid; 409 is
#     ICEBERG_TABLE_ALREADY_EXISTS with the ErrorModel; every other status keeps
#     its token; a transport error is ICEBERG_CATALOG_UNAVAILABLE; an unlisted
#     endpoint is refused before anything is sent;
#   * commitTable: every answer kind (200 applied, 200 unreadable -> unknown,
#     409 conflict, 5xx and a raise -> unknown, the rest refused) with its
#     status and message; an Idempotency-Key header only when a key is passed;
#     the exact body sent; an unlisted endpoint or a failing credential
#     provider raises before anything is sent;
#   * supports_idempotency and require_endpoint read the cached config.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from json import parse_json_value

from iceberg_catalog.iceberg_rest_transport import (
    IcebergRestMethod,
    IcebergRestRequest,
    ScriptedIcebergRestTransport,
)
from iceberg_catalog.iceberg_rest_catalog_client import (
    CatalogCredentialProvider,
    COMMIT_APPLIED,
    COMMIT_CONFLICT,
    COMMIT_REFUSED,
    COMMIT_UNKNOWN,
    CommitResponse,
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_table_changes import CreateTableRequest


comptime _Client = IcebergRestCatalog[
    ScriptedIcebergRestTransport, StaticBearerToken
]

comptime _CFG: String = '{"overrides":{"prefix":"p"}}'
comptime _CFG_NO_PREFIX: String = "{}"
comptime _META: String = (
    '{"format-version":2,"table-uuid":"u-1","location":"s3://wh/db/t",'
    '"last-column-id":1,"schemas":[{"schema-id":0,"fields":[{"id":1,'
    '"name":"a","required":true,"type":"long"}]}],"current-schema-id":0}'
)
comptime _LOCATION: String = "s3://wh/db/t/metadata/v1.json"
comptime _RESULT: String = (
    '{"metadata-location":"s3://wh/db/t/metadata/v1.json","metadata":'
    + _META
    + ',"config":{"k":"v"}}'
)
comptime _STAGED_RESULT: String = (
    '{"metadata":' + _META + ',"config":{"k":"v"}}'
)
comptime _SCHEMA_JSON: String = (
    '{"type":"struct","schema-id":0,"fields":[{"id":1,"name":"a",'
    '"required":true,"type":"long"}]}'
)
comptime _CREATE_EP: String = "POST /v1/{prefix}/namespaces/{namespace}/tables"
comptime _COMMIT_EP: String = (
    "POST /v1/{prefix}/namespaces/{namespace}/tables/{table}"
)
comptime _LOAD_EP: String = (
    "GET /v1/{prefix}/namespaces/{namespace}/tables/{table}"
)
comptime _COMMIT_BODY: String = '{"requirements":[],"updates":[]}'
comptime _NO_RESPONSE: String = (
    "ScriptedIcebergRestTransport.send: no scripted response for call #1 (path "
)


def _client_for(config: String, status: Int, body: String) -> _Client:
    """A client whose config answers 200 `config` and whose next call answers
    `status` `body`."""
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(config))
    t.queue_response(status, String(body))
    return _Client(
        String("catalog.example.com"), t^, StaticBearerToken(String("k"))
    )


def _client_with_config(config: String) -> _Client:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(config))
    return _Client(
        String("catalog.example.com"), t^, StaticBearerToken(String("k"))
    )


def _create_request(stage: Bool) raises -> CreateTableRequest:
    return CreateTableRequest(
        String("t"), parse_json_value(_SCHEMA_JSON), stage_create=stage
    )


def _create_error(mut c: _Client, request: CreateTableRequest) -> String:
    """The message create_table raised, or "" when it returned."""
    try:
        var _r = c.create_table(String("db"), request)
    except e:
        return String(e)
    return String("")


def _create_failure(status: Int, body: String, stage: Bool) raises -> String:
    var c = _client_for(_CFG, status, body)
    return _create_error(c, _create_request(stage))


def _commit(status: Int, body: String) raises -> CommitResponse:
    var c = _client_for(_CFG, status, body)
    return c.commit_table(
        String("db"), String("t"), String(_COMMIT_BODY), String("")
    )


# =============================================================================
# IcebergRestMethod and IcebergRestRequest
# =============================================================================


def test_method_get_and_post_name_themselves() raises:
    assert_false(IcebergRestMethod.get().is_post())
    assert_true(IcebergRestMethod.post().is_post())
    assert_equal(IcebergRestMethod.get().name(), String("GET"))
    assert_equal(IcebergRestMethod.post().name(), String("POST"))


def _names() -> List[String]:
    var n = List[String]()
    n.append(String("Accept"))
    n.append(String("X-One"))
    return n^


def _values() -> List[String]:
    var v = List[String]()
    v.append(String("application/json"))
    v.append(String("1"))
    return v^


def test_get_request_has_get_method_and_empty_body() raises:
    var r = IcebergRestRequest(
        String("h.example.com"), 8181, String("/v1/config"), _names(), _values()
    )
    assert_false(r.method.is_post())
    assert_equal(r.host, String("h.example.com"))
    assert_equal(r.port, UInt16(8181))
    assert_equal(r.path, String("/v1/config"))
    assert_equal(r.body, String(""))
    assert_equal(r.header_value(String("X-One")), String("1"))
    assert_equal(r.header_value(String("Missing")), String(""))


def test_post_request_carries_method_and_body() raises:
    var r = IcebergRestRequest.post(
        String("h.example.com"),
        443,
        String("/v1/x"),
        _names(),
        _values(),
        String('{"a":1}'),
    )
    assert_true(r.method.is_post())
    assert_equal(r.body, String('{"a":1}'))
    assert_equal(r.path, String("/v1/x"))
    assert_equal(r.header_value(String("Accept")), String("application/json"))


def test_copy_of_a_post_keeps_every_field_and_is_independent() raises:
    var r = IcebergRestRequest.post(
        String("h.example.com"),
        8443,
        String("/v1/x"),
        _names(),
        _values(),
        String('{"a":1}'),
    )
    var c = r.copy()
    assert_true(c.method.is_post())
    assert_equal(c.host, String("h.example.com"))
    assert_equal(c.port, UInt16(8443))
    assert_equal(c.path, String("/v1/x"))
    assert_equal(c.body, String('{"a":1}'))
    assert_equal(len(c.header_names), 2)
    assert_equal(c.header_names[0], String("Accept"))
    assert_equal(c.header_values[1], String("1"))
    c.body = String("changed")
    c.header_values[1] = String("2")
    c.path = String("/other")
    assert_equal(r.body, String('{"a":1}'))
    assert_equal(r.header_value(String("X-One")), String("1"))
    assert_equal(r.path, String("/v1/x"))


def test_copy_of_a_get_stays_a_get_with_empty_body() raises:
    var r = IcebergRestRequest(
        String("h.example.com"), 80, String("/v1/config"), _names(), _values()
    )
    var c = r.copy()
    assert_false(c.method.is_post())
    assert_equal(c.body, String(""))
    assert_equal(c.port, UInt16(80))
    assert_equal(c.path, String("/v1/config"))


# =============================================================================
# the scripted transport's recording
# =============================================================================


def test_scripted_transport_records_method_body_and_every_header() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String("a"))
    t.queue_response(201, String("b"))
    var get = IcebergRestRequest(
        String("h"), 443, String("/v1/g"), _names(), _values()
    )
    var post_names = _names()
    post_names.append(String("Idempotency-Key"))
    var post_values = _values()
    post_values.append(String("key-9"))
    var post = IcebergRestRequest.post(
        String("h"), 443, String("/v1/p"), post_names^, post_values^, String("{}")
    )
    var r0 = t.send(get)
    var r1 = t.send(post)
    assert_equal(r0.status, 200)
    assert_equal(r0.body, String("a"))
    assert_equal(r1.status, 201)
    assert_equal(r1.body, String("b"))
    assert_equal(t.call_count(), 2)
    assert_equal(t.call_method(0), String("GET"))
    assert_equal(t.call_method(1), String("POST"))
    assert_equal(t.call_path(0), String("/v1/g"))
    assert_equal(t.call_path(1), String("/v1/p"))
    assert_equal(t.call_body(0), String(""))
    assert_equal(t.call_body(1), String("{}"))
    assert_equal(t.call_header(0, String("Accept")), String("application/json"))
    assert_equal(t.call_header(1, String("Accept")), String("application/json"))
    assert_equal(t.call_header(1, String("X-One")), String("1"))
    assert_equal(t.call_header(1, String("Idempotency-Key")), String("key-9"))
    assert_true(t.call_has_header(1, String("Idempotency-Key")))
    assert_false(t.call_has_header(0, String("Idempotency-Key")))
    assert_equal(t.call_header(0, String("Idempotency-Key")), String(""))
    assert_false(t.call_has_header(1, String("idempotency-key")))
    assert_equal(t.call_auth(1), String(""))


def test_scripted_transport_with_no_response_left_raises_and_records() raises:
    var t = ScriptedIcebergRestTransport()
    var r = IcebergRestRequest(
        String("h"), 443, String("/v1/g"), _names(), _values()
    )
    var msg = String("")
    try:
        var _x = t.send(r)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "ScriptedIcebergRestTransport.send: no scripted response for call"
            " #0 (path /v1/g); queue more responses"
        ),
    )
    assert_equal(t.call_count(), 1)
    assert_equal(t.call_path(0), String("/v1/g"))


# =============================================================================
# createTable: path, headers, body bytes
# =============================================================================


def test_create_table_posts_to_the_prefixed_namespace_path() raises:
    var c = _client_for(_CFG, 200, _STAGED_RESULT)
    var _t = c.create_table(String("db"), _create_request(True))
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 2)
    assert_equal(rec.call_method(1), String("POST"))
    assert_equal(rec.call_path(1), String("/v1/p/namespaces/db/tables"))


def test_create_table_path_without_a_prefix_has_no_prefix_segment() raises:
    var c = _client_for(_CFG_NO_PREFIX, 200, _STAGED_RESULT)
    var _t = c.create_table(String("db"), _create_request(True))
    ref rec = c.transport_ref()
    assert_equal(rec.call_path(1), String("/v1/namespaces/db/tables"))


def test_create_table_percent_encodes_the_namespace_and_prefix() raises:
    var c = _client_for(
        '{"overrides":{"prefix":"ten ant/1"}}', 200, _STAGED_RESULT
    )
    var ns = String("a b") + chr(0x1F) + String("c/d")
    var _t = c.create_table(ns, _create_request(True))
    ref rec = c.transport_ref()
    assert_equal(
        rec.call_path(1),
        String("/v1/ten%20ant/1/namespaces/a%20b%1Fc%2Fd/tables"),
    )


def test_create_table_body_of_a_staged_create_without_location() raises:
    var c = _client_for(_CFG, 200, _STAGED_RESULT)
    var _t = c.create_table(String("db"), _create_request(True))
    ref rec = c.transport_ref()
    assert_equal(
        rec.call_body(1),
        String(
            '{"name":"t","schema":'
            + _SCHEMA_JSON
            + ',"stage-create":true,"properties":{}}'
        ),
    )


def test_create_table_body_of_a_direct_create_with_location_and_properties() raises:
    var c = _client_for(_CFG, 200, _RESULT)
    var req = _create_request(False)
    req.location = String("s3://wh/db/t")
    req.set_property(String("write.format.default"), String("parquet"))
    req.set_property(String("owner"), String("komira"))
    var _t = c.create_table(String("db"), req)
    ref rec = c.transport_ref()
    assert_equal(
        rec.call_body(1),
        String(
            '{"name":"t","location":"s3://wh/db/t","schema":'
            + _SCHEMA_JSON
            + ',"stage-create":false,"properties":{"write.format.default":'
            '"parquet","owner":"komira"}}'
        ),
    )


def test_create_table_sends_content_type_and_no_idempotency_key() raises:
    var c = _client_for(_CFG, 200, _STAGED_RESULT)
    var _t = c.create_table(String("db"), _create_request(True))
    ref rec = c.transport_ref()
    assert_equal(
        rec.call_header(1, String("Content-Type")), String("application/json")
    )
    assert_equal(
        rec.call_header(1, String("Accept")), String("application/json")
    )
    assert_equal(rec.call_auth(1), String("Bearer k"))
    assert_false(rec.call_has_header(1, String("Idempotency-Key")))
    assert_false(rec.call_has_header(0, String("Content-Type")))


# =============================================================================
# createTable: the result
# =============================================================================


def test_staged_create_returns_empty_location_and_the_initial_metadata() raises:
    var c = _client_for(_CFG, 200, _STAGED_RESULT)
    var t = c.create_table(String("db"), _create_request(True))
    assert_equal(t.metadata_location, String(""))
    assert_equal(t.metadata.table_uuid, String("u-1"))
    assert_equal(t.metadata.location, String("s3://wh/db/t"))
    assert_equal(t.metadata.last_column_id, 1)
    assert_equal(len(t.metadata.schemas), 1)
    assert_equal(t.metadata.schemas[0].fields[0].name, String("a"))
    assert_equal(t.metadata_json, String(_META))
    assert_equal(len(t.config_names), 1)
    assert_equal(t.config_names[0], String("k"))
    assert_equal(t.config_values[0], String("v"))


def test_staged_create_keeps_a_location_the_catalog_returns() raises:
    var c = _client_for(_CFG, 200, _RESULT)
    var t = c.create_table(String("db"), _create_request(True))
    assert_equal(t.metadata_location, String(_LOCATION))


def test_direct_create_returns_the_location_and_metadata() raises:
    var c = _client_for(_CFG, 200, _RESULT)
    var t = c.create_table(String("db"), _create_request(False))
    assert_equal(t.metadata_location, String(_LOCATION))
    assert_equal(t.metadata.table_uuid, String("u-1"))


def test_direct_create_without_a_location_is_invalid() raises:
    assert_equal(
        _create_failure(200, _STAGED_RESULT, False),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: createTable 'db.t' response"
            " has no 'metadata-location'"
        ),
    )


def test_direct_create_with_a_non_string_location_is_invalid() raises:
    assert_equal(
        _create_failure(
            200, '{"metadata-location":7,"metadata":' + _META + "}", False
        ),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: createTable 'db.t' response"
            " has no 'metadata-location'"
        ),
    )


def test_create_without_metadata_is_invalid() raises:
    assert_equal(
        _create_failure(200, '{"metadata-location":"s3://x"}', False),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: createTable 'db.t' response"
            " has no 'metadata'"
        ),
    )


def test_create_with_a_body_that_is_not_json_is_invalid() raises:
    assert_equal(
        _create_failure(200, String("not json"), True),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: createTable 'db.t' response"
            " is not JSON"
        ),
    )


def test_create_with_a_body_that_is_not_an_object_is_invalid() raises:
    assert_equal(
        _create_failure(200, String("[1]"), True),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: createTable 'db.t' response"
            " is not a JSON object"
        ),
    )


# =============================================================================
# createTable: errors
# =============================================================================


def test_create_conflict_is_table_already_exists_with_the_error_model() raises:
    assert_equal(
        _create_failure(
            409,
            '{"error":{"message":"Table already exists: db.t","type":'
            '"AlreadyExistsException","code":409}}',
            False,
        ),
        String(
            "ICEBERG_TABLE_ALREADY_EXISTS: createTable 'db.t': HTTP 409:"
            " AlreadyExistsException: Table already exists: db.t"
        ),
    )


def test_create_conflict_without_an_error_model_keeps_only_the_status() raises:
    assert_equal(
        _create_failure(409, String("secret raw body"), False),
        String("ICEBERG_TABLE_ALREADY_EXISTS: createTable 'db.t': HTTP 409"),
    )


def test_create_bad_request_is_rejected() raises:
    assert_equal(
        _create_failure(
            400,
            '{"error":{"message":"bad schema","type":"BadRequestException"}}',
            False,
        ),
        String(
            "ICEBERG_CATALOG_REJECTED: createTable 'db.t': HTTP 400:"
            " BadRequestException: bad schema"
        ),
    )


def test_create_unauthorized_and_forbidden_keep_their_tokens() raises:
    assert_equal(
        _create_failure(401, String(""), False),
        String("ICEBERG_CATALOG_UNAUTHORIZED: createTable 'db.t': HTTP 401"),
    )
    assert_equal(
        _create_failure(403, String(""), True),
        String("ICEBERG_CATALOG_FORBIDDEN: createTable 'db.t': HTTP 403"),
    )


def test_create_missing_namespace_is_namespace_not_found() raises:
    assert_equal(
        _create_failure(
            404,
            '{"error":{"message":"Namespace does not exist: db","type":'
            '"NoSuchNamespaceException","code":404}}',
            True,
        ),
        String(
            "ICEBERG_NAMESPACE_NOT_FOUND: createTable 'db.t': HTTP 404:"
            " NoSuchNamespaceException: Namespace does not exist: db"
        ),
    )


def test_create_404_of_another_type_is_table_not_found() raises:
    assert_equal(
        _create_failure(404, String(""), True),
        String("ICEBERG_TABLE_NOT_FOUND: createTable 'db.t': HTTP 404"),
    )


def test_create_server_errors_are_unavailable() raises:
    assert_equal(
        _create_failure(500, String(""), False),
        String("ICEBERG_CATALOG_UNAVAILABLE: createTable 'db.t': HTTP 500"),
    )
    assert_equal(
        _create_failure(503, '{"error":{"message":"busy"}}', False),
        String(
            "ICEBERG_CATALOG_UNAVAILABLE: createTable 'db.t': HTTP 503: busy"
        ),
    )


def test_create_transport_error_is_catalog_unavailable() raises:
    var c = _client_with_config(_CFG)
    assert_equal(
        _create_error(c, _create_request(True)),
        String(
            "ICEBERG_CATALOG_UNAVAILABLE: createTable 'db.t': transport error: "
            + _NO_RESPONSE
            + "/v1/p/namespaces/db/tables); queue more responses"
        ),
    )


def test_create_is_refused_before_sending_when_the_endpoint_is_unlisted() raises:
    var c = _client_for(
        '{"endpoints":["' + _LOAD_EP + '","' + _COMMIT_EP + '"]}',
        200,
        _STAGED_RESULT,
    )
    assert_equal(
        _create_error(c, _create_request(True)),
        String(
            "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not list"
            " 'POST /v1/{prefix}/namespaces/{namespace}/tables'"
        ),
    )
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 1)
    assert_equal(rec.call_path(0), String("/v1/config"))


def test_create_is_sent_when_the_endpoint_is_listed() raises:
    var c = _client_for(
        '{"endpoints":[7,"' + _CREATE_EP + '"]}', 200, _STAGED_RESULT
    )
    var t = c.create_table(String("db"), _create_request(True))
    assert_equal(t.metadata.table_uuid, String("u-1"))
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 2)


# =============================================================================
# commitTable: the request
# =============================================================================


def test_commit_posts_the_exact_body_to_the_table_path() raises:
    var c = _client_for(_CFG, 200, _RESULT)
    var _r = c.commit_table(
        String("db"), String("t t"), String(_COMMIT_BODY), String("")
    )
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 2)
    assert_equal(rec.call_method(1), String("POST"))
    assert_equal(rec.call_path(1), String("/v1/p/namespaces/db/tables/t%20t"))
    assert_equal(rec.call_body(1), String(_COMMIT_BODY))
    assert_equal(
        rec.call_header(1, String("Content-Type")), String("application/json")
    )
    assert_equal(rec.call_auth(1), String("Bearer k"))


def test_commit_without_a_key_sends_no_idempotency_key() raises:
    var c = _client_for(_CFG_NO_PREFIX, 200, _RESULT)
    var _r = c.commit_table(
        String("db"), String("t"), String(_COMMIT_BODY), String("")
    )
    ref rec = c.transport_ref()
    assert_equal(rec.call_path(1), String("/v1/namespaces/db/tables/t"))
    assert_false(rec.call_has_header(1, String("Idempotency-Key")))


def test_commit_with_a_key_sends_it_as_idempotency_key() raises:
    var c = _client_for(_CFG, 200, _RESULT)
    var _r = c.commit_table(
        String("db"), String("t"), String(_COMMIT_BODY), String("key-123")
    )
    ref rec = c.transport_ref()
    assert_true(rec.call_has_header(1, String("Idempotency-Key")))
    assert_equal(rec.call_header(1, String("Idempotency-Key")), String("key-123"))
    assert_false(rec.call_has_header(0, String("Idempotency-Key")))


def test_commit_without_a_token_sends_no_authorization() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG))
    t.queue_response(200, String(_RESULT))
    var c = _Client(
        String("catalog.example.com"), t^, StaticBearerToken(String(""))
    )
    var _r = c.commit_table(
        String("db"), String("t"), String(_COMMIT_BODY), String("")
    )
    ref rec = c.transport_ref()
    assert_false(rec.call_has_header(1, String("Authorization")))


# =============================================================================
# commitTable: every answer kind
# =============================================================================


def test_commit_200_is_applied_with_the_new_metadata() raises:
    var r = _commit(200, _RESULT)
    assert_equal(r.kind, COMMIT_APPLIED)
    assert_equal(r.status, 200)
    assert_equal(r.message, String(""))
    assert_true(Bool(r.table))
    ref t = r.table.value()
    assert_equal(t.metadata_location, String(_LOCATION))
    assert_equal(t.metadata.table_uuid, String("u-1"))
    assert_equal(t.metadata_json, String(_META))


def test_commit_200_with_an_unreadable_body_is_unknown() raises:
    var r = _commit(200, String("<html>"))
    assert_equal(r.kind, COMMIT_UNKNOWN)
    assert_equal(r.status, 200)
    assert_equal(
        r.message,
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: commitTable 'db.t' response is"
            " not JSON"
        ),
    )
    assert_false(Bool(r.table))


def test_commit_200_without_a_location_is_unknown() raises:
    var r = _commit(200, _STAGED_RESULT)
    assert_equal(r.kind, COMMIT_UNKNOWN)
    assert_equal(r.status, 200)
    assert_equal(
        r.message,
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: commitTable 'db.t' response has"
            " no 'metadata-location'"
        ),
    )
    assert_false(Bool(r.table))


def test_commit_409_is_a_conflict_with_its_message() raises:
    var r = _commit(
        409,
        '{"error":{"message":"Requirement failed: branch main has changed",'
        '"type":"CommitFailedException","code":409}}',
    )
    assert_equal(r.kind, COMMIT_CONFLICT)
    assert_equal(r.status, 409)
    assert_equal(
        r.message,
        String(
            "commitTable 'db.t': HTTP 409: CommitFailedException: Requirement"
            " failed: branch main has changed"
        ),
    )
    assert_false(Bool(r.table))


def test_commit_409_without_an_error_model_keeps_only_the_status() raises:
    var r = _commit(409, String("raw"))
    assert_equal(r.kind, COMMIT_CONFLICT)
    assert_equal(r.message, String("commitTable 'db.t': HTTP 409"))


def test_commit_5xx_is_unknown_with_the_status_and_token() raises:
    var statuses = List[Int]()
    statuses.append(500)
    statuses.append(502)
    statuses.append(503)
    statuses.append(504)
    for i in range(len(statuses)):
        var r = _commit(statuses[i], '{"error":{"message":"down"}}')
        assert_equal(r.kind, COMMIT_UNKNOWN)
        assert_equal(r.status, statuses[i])
        assert_equal(
            r.message,
            String("ICEBERG_CATALOG_UNAVAILABLE: commitTable 'db.t': HTTP ")
            + String(statuses[i])
            + String(": down"),
        )
        assert_false(Bool(r.table))


def test_commit_transport_raise_is_unknown_with_status_zero() raises:
    var c = _client_with_config(_CFG)
    var r = c.commit_table(
        String("db"), String("t"), String(_COMMIT_BODY), String("k1")
    )
    assert_equal(r.kind, COMMIT_UNKNOWN)
    assert_equal(r.status, 0)
    assert_equal(
        r.message,
        String(
            "ICEBERG_CATALOG_UNAVAILABLE: commitTable 'db.t': transport error: "
            + _NO_RESPONSE
            + "/v1/p/namespaces/db/tables/t); queue more responses"
        ),
    )
    assert_false(Bool(r.table))
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 2)
    assert_equal(rec.call_header(1, String("Idempotency-Key")), String("k1"))


def test_commit_refusals_keep_their_token_messages() raises:
    var statuses = List[Int]()
    var tokens = List[String]()
    statuses.append(400)
    tokens.append(String("ICEBERG_CATALOG_REJECTED"))
    statuses.append(401)
    tokens.append(String("ICEBERG_CATALOG_UNAUTHORIZED"))
    statuses.append(403)
    tokens.append(String("ICEBERG_CATALOG_FORBIDDEN"))
    statuses.append(404)
    tokens.append(String("ICEBERG_TABLE_NOT_FOUND"))
    statuses.append(419)
    tokens.append(String("ICEBERG_CATALOG_UNAUTHORIZED"))
    statuses.append(302)
    tokens.append(String("ICEBERG_CATALOG_REJECTED"))
    for i in range(len(statuses)):
        var r = _commit(statuses[i], String(""))
        assert_equal(r.kind, COMMIT_REFUSED)
        assert_equal(r.status, statuses[i])
        assert_equal(
            r.message,
            tokens[i]
            + String(": commitTable 'db.t': HTTP ")
            + String(statuses[i]),
        )
        assert_false(Bool(r.table))


def test_commit_404_for_a_missing_namespace_is_refused_with_its_type() raises:
    var r = _commit(
        404,
        '{"error":{"message":"no db","type":"NoSuchNamespaceException"}}',
    )
    assert_equal(r.kind, COMMIT_REFUSED)
    assert_equal(
        r.message,
        String(
            "ICEBERG_NAMESPACE_NOT_FOUND: commitTable 'db.t': HTTP 404:"
            " NoSuchNamespaceException: no db"
        ),
    )


def test_commit_is_refused_before_sending_when_the_endpoint_is_unlisted() raises:
    var c = _client_for(
        '{"endpoints":["' + _LOAD_EP + '","' + _CREATE_EP + '"]}', 200, _RESULT
    )
    var msg = String("")
    try:
        var _r = c.commit_table(
            String("db"), String("t"), String(_COMMIT_BODY), String("")
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not list"
            " 'POST /v1/{prefix}/namespaces/{namespace}/tables/{table}'"
        ),
    )
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 1)


def test_commit_is_sent_when_the_endpoint_is_listed() raises:
    var c = _client_for('{"endpoints":["' + _COMMIT_EP + '"]}', 200, _RESULT)
    var r = c.commit_table(
        String("db"), String("t"), String(_COMMIT_BODY), String("")
    )
    assert_equal(r.kind, COMMIT_APPLIED)


struct _FailingCredentials(CatalogCredentialProvider, Movable, Deinitable):
    def __init__(out self):
        pass

    def authorization_header(mut self) raises -> String:
        raise Error("token exchange failed")


def test_a_failing_credential_provider_raises_before_anything_is_sent() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG))
    t.queue_response(200, String(_RESULT))
    var c = IcebergRestCatalog[
        ScriptedIcebergRestTransport, _FailingCredentials
    ](String("catalog.example.com"), t^, _FailingCredentials())
    var commit_msg = String("")
    try:
        var _r = c.commit_table(
            String("db"), String("t"), String(_COMMIT_BODY), String("")
        )
    except e:
        commit_msg = String(e)
    assert_equal(commit_msg, String("token exchange failed"))
    var create_msg = String("")
    try:
        var _t = c.create_table(String("db"), _create_request(True))
    except e:
        create_msg = String(e)
    assert_equal(create_msg, String("token exchange failed"))


# =============================================================================
# supports_idempotency and require_endpoint
# =============================================================================


def test_supports_idempotency_follows_the_advertised_lifetime() raises:
    var yes = _client_with_config('{"idempotency-key-lifetime":"PT30M"}')
    assert_true(yes.supports_idempotency())
    # The config is fetched once and cached.
    assert_true(yes.supports_idempotency())
    ref rec = yes.transport_ref()
    assert_equal(rec.call_count(), 1)
    assert_equal(rec.call_path(0), String("/v1/config"))
    var no = _client_with_config(_CFG)
    assert_false(no.supports_idempotency())


def test_require_endpoint_accepts_anything_when_none_are_listed() raises:
    var c = _client_with_config(_CFG)
    c.require_endpoint(String("POST /v1/anything"))
    ref rec = c.transport_ref()
    assert_equal(rec.call_count(), 1)


def test_require_endpoint_accepts_a_listed_endpoint() raises:
    var c = _client_with_config(
        '{"endpoints":["' + _LOAD_EP + '","' + _CREATE_EP + '"]}'
    )
    c.require_endpoint(String(_CREATE_EP))
    c.require_endpoint(String(_LOAD_EP))


def test_require_endpoint_refuses_an_unlisted_endpoint_by_name() raises:
    var c = _client_with_config('{"endpoints":["' + _LOAD_EP + '"]}')
    var msg = String("")
    try:
        c.require_endpoint(String("POST /v1/other"))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not list"
            " 'POST /v1/other'"
        ),
    )


def test_require_endpoint_refuses_everything_for_an_empty_list() raises:
    var c = _client_with_config('{"endpoints":[]}')
    var msg = String("")
    try:
        c.require_endpoint(String(_LOAD_EP))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not list '"
            + _LOAD_EP
            + "'"
        ),
    )


def main() raises:
    test_method_get_and_post_name_themselves()
    test_get_request_has_get_method_and_empty_body()
    test_post_request_carries_method_and_body()
    test_copy_of_a_post_keeps_every_field_and_is_independent()
    test_copy_of_a_get_stays_a_get_with_empty_body()
    test_scripted_transport_records_method_body_and_every_header()
    test_scripted_transport_with_no_response_left_raises_and_records()
    test_create_table_posts_to_the_prefixed_namespace_path()
    test_create_table_path_without_a_prefix_has_no_prefix_segment()
    test_create_table_percent_encodes_the_namespace_and_prefix()
    test_create_table_body_of_a_staged_create_without_location()
    test_create_table_body_of_a_direct_create_with_location_and_properties()
    test_create_table_sends_content_type_and_no_idempotency_key()
    test_staged_create_returns_empty_location_and_the_initial_metadata()
    test_staged_create_keeps_a_location_the_catalog_returns()
    test_direct_create_returns_the_location_and_metadata()
    test_direct_create_without_a_location_is_invalid()
    test_direct_create_with_a_non_string_location_is_invalid()
    test_create_without_metadata_is_invalid()
    test_create_with_a_body_that_is_not_json_is_invalid()
    test_create_with_a_body_that_is_not_an_object_is_invalid()
    test_create_conflict_is_table_already_exists_with_the_error_model()
    test_create_conflict_without_an_error_model_keeps_only_the_status()
    test_create_bad_request_is_rejected()
    test_create_unauthorized_and_forbidden_keep_their_tokens()
    test_create_missing_namespace_is_namespace_not_found()
    test_create_404_of_another_type_is_table_not_found()
    test_create_server_errors_are_unavailable()
    test_create_transport_error_is_catalog_unavailable()
    test_create_is_refused_before_sending_when_the_endpoint_is_unlisted()
    test_create_is_sent_when_the_endpoint_is_listed()
    test_commit_posts_the_exact_body_to_the_table_path()
    test_commit_without_a_key_sends_no_idempotency_key()
    test_commit_with_a_key_sends_it_as_idempotency_key()
    test_commit_without_a_token_sends_no_authorization()
    test_commit_200_is_applied_with_the_new_metadata()
    test_commit_200_with_an_unreadable_body_is_unknown()
    test_commit_200_without_a_location_is_unknown()
    test_commit_409_is_a_conflict_with_its_message()
    test_commit_409_without_an_error_model_keeps_only_the_status()
    test_commit_5xx_is_unknown_with_the_status_and_token()
    test_commit_transport_raise_is_unknown_with_status_zero()
    test_commit_refusals_keep_their_token_messages()
    test_commit_404_for_a_missing_namespace_is_refused_with_its_type()
    test_commit_is_refused_before_sending_when_the_endpoint_is_unlisted()
    test_commit_is_sent_when_the_endpoint_is_listed()
    test_a_failing_credential_provider_raises_before_anything_is_sent()
    test_supports_idempotency_follows_the_advertised_lifetime()
    test_require_endpoint_accepts_anything_when_none_are_listed()
    test_require_endpoint_accepts_a_listed_endpoint()
    test_require_endpoint_refuses_an_unlisted_endpoint_by_name()
    test_require_endpoint_refuses_everything_for_an_empty_list()
    print("test_iceberg_rest_write: ALL PASS")
