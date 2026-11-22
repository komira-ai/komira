# =============================================================================
# test_iceberg_rest_error_messages.mojo — the message of every REST error
#   response, by exact message, over a ScriptedIcebergRestTransport.
# =============================================================================
#
# A message starts with its token and keeps only the status and the
# ErrorModel `type` and `message`, never the raw body. Each case names the
# defect it would catch:
#   * Status sweeps: createTable and commitTable map EVERY status from 100 to
#     599 (200 aside) to the token of its class (409 is already-exists for a
#     create and a conflict for a commit; a 5xx on a commit is an unknown
#     outcome, anything else a refusal).
#   * Unreadable 200 bodies: a commit answered 200 with a body that cannot be
#     read is an unknown outcome, never a failure that lets the caller delete
#     its files; a direct create without a `metadata-location` is invalid.
#   * Error-model reading: a body that is not JSON, not an object, without an
#     `error` object, with only a type, only a message, or members that are
#     not strings adds exactly what the body holds and no more; an empty type
#     or message adds nothing; a 404 is a namespace error only for the type
#     NoSuchNamespaceException given as a string, and only on a table path.
#   * Never the raw body: every path that reads a response (config, load,
#     create, commit) yields the full message by equality when the body
#     carries a secret-looking string.
#   * Token test: `error_has_token` is true only for `<token>:` at the start.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from json import JsonValue

from iceberg_catalog.iceberg_rest_errors import (
    ICEBERG_CATALOG_FORBIDDEN,
    ICEBERG_CATALOG_REJECTED,
    ICEBERG_CATALOG_RESPONSE_INVALID,
    ICEBERG_CATALOG_UNAUTHORIZED,
    ICEBERG_CATALOG_UNAVAILABLE,
    ICEBERG_NAMESPACE_NOT_FOUND,
    ICEBERG_TABLE_ALREADY_EXISTS,
    ICEBERG_TABLE_NOT_FOUND,
    error_has_token,
    rest_error_message,
    with_error_model,
)
from iceberg_catalog.iceberg_rest_transport import (
    ScriptedIcebergRestTransport,
)
from iceberg_catalog.iceberg_rest_catalog_client import (
    COMMIT_CONFLICT,
    COMMIT_REFUSED,
    COMMIT_UNKNOWN,
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_table_changes import CreateTableRequest


comptime _CFG_OK: String = '{"overrides":{"prefix":"p"}}'
comptime _LOAD_OK: String = '{"metadata-location":"s3://wh/t/metadata/v1.json"}'
comptime _SECRET: String = "sk-live-SECRET-4242"


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
# createTable and commitTable statuses
# =============================================================================


def test_create_table_status_sweep() raises:
    for status in range(100, 600):
        if status == 200:
            continue
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        t.queue_response(status, String(_LOAD_OK))
        var c = _client(t^)
        var tok = _token_for(status, True)
        if status == 409:
            tok = ICEBERG_TABLE_ALREADY_EXISTS
        assert_equal(
            _create_error(c, _new_table(False)),
            tok + String(": createTable 'db.t': HTTP ") + String(status),
        )


def test_commit_table_status_sweep() raises:
    for status in range(100, 600):
        if status == 200:
            continue
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        t.queue_response(status, String(_LOAD_OK))
        var c = _client(t^)
        var r = c.commit_table(
            String("db"), String("t"), String("{}"), String("")
        )
        assert_equal(r.status, status)
        assert_false(Bool(r.table))
        if status == 409:
            assert_equal(r.kind, COMMIT_CONFLICT)
            assert_equal(r.message, String("commitTable 'db.t': HTTP 409"))
            continue
        if status >= 500 and status <= 599:
            assert_equal(r.kind, COMMIT_UNKNOWN)
        else:
            assert_equal(r.kind, COMMIT_REFUSED)
        assert_equal(
            r.message,
            _token_for(status, True)
            + String(": commitTable 'db.t': HTTP ")
            + String(status),
        )


def test_commit_table_200_with_unreadable_body_is_unknown() raises:
    var bodies = List[String]()
    var wants = List[String]()
    bodies.append(String("{not json"))
    wants.append(
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: commitTable 'db.t' response"
            " is not JSON"
        )
    )
    bodies.append(String("[]"))
    wants.append(
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: commitTable 'db.t' response"
            " is not a JSON object"
        )
    )
    bodies.append(String('{"metadata":{}}'))
    wants.append(
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: commitTable 'db.t' response"
            " has no 'metadata-location'"
        )
    )
    bodies.append(String('{"metadata-location":"s3://x/m.json"}'))
    wants.append(
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: commitTable 'db.t' response"
            " has no 'metadata'"
        )
    )
    for i in range(len(bodies)):
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        t.queue_response(200, bodies[i])
        var c = _client(t^)
        var r = c.commit_table(
            String("db"), String("t"), String("{}"), String("")
        )
        assert_equal(r.kind, COMMIT_UNKNOWN)
        assert_equal(r.status, 200)
        assert_equal(r.message, wants[i])


def test_create_table_200_without_location_is_invalid() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String(_CFG_OK))
    t.queue_response(200, String('{"metadata":{}}'))
    var c = _client(t^)
    assert_equal(
        _create_error(c, _new_table(False)),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: createTable 'db.t' response"
            " has no 'metadata-location'"
        ),
    )


# =============================================================================
# error-model reading, and never the raw body
# =============================================================================


def test_rest_error_message_without_an_error_model() raises:
    var bodies = List[String]()
    bodies.append(String(""))
    bodies.append(String("no such table"))
    bodies.append(String("{not json"))
    bodies.append(String("[]"))
    bodies.append(String("7"))
    bodies.append(String("null"))
    bodies.append(String('"error"'))
    # An object with no `error` member, and an `error` that is no object.
    bodies.append(String('{"message":"top","type":"TopType"}'))
    bodies.append(String('{"errors":{"message":"m","type":"T"}}'))
    bodies.append(String('{"error":"boom"}'))
    bodies.append(String('{"error":["m","T"]}'))
    bodies.append(String('{"error":null}'))
    bodies.append(String('{"error":{}}'))
    for i in range(len(bodies)):
        assert_equal(
            rest_error_message(
                500, bodies[i], String("loadTable 'db.t'"), True
            ),
            String("ICEBERG_CATALOG_UNAVAILABLE: loadTable 'db.t': HTTP 500"),
        )
        assert_equal(
            with_error_model(String("base"), bodies[i]), String("base")
        )


def test_rest_error_message_type_only_and_message_only() raises:
    assert_equal(
        rest_error_message(
            400,
            String('{"error":{"type":"BadRequestException","code":400}}'),
            String("createTable 'db.t'"),
            True,
        ),
        String(
            "ICEBERG_CATALOG_REJECTED: createTable 'db.t': HTTP 400:"
            " BadRequestException"
        ),
    )
    assert_equal(
        rest_error_message(
            400,
            String('{"error":{"message":"bad schema","code":400}}'),
            String("createTable 'db.t'"),
            True,
        ),
        String(
            "ICEBERG_CATALOG_REJECTED: createTable 'db.t': HTTP 400:"
            " bad schema"
        ),
    )
    assert_equal(
        rest_error_message(
            400,
            String(
                '{"error":{"message":"bad schema","type":"BadRequestException"}}'
            ),
            String("createTable 'db.t'"),
            True,
        ),
        String(
            "ICEBERG_CATALOG_REJECTED: createTable 'db.t': HTTP 400:"
            " BadRequestException: bad schema"
        ),
    )
    assert_equal(
        with_error_model(
            String("base"), String('{"error":{"message":"m","type":"T"}}')
        ),
        String("base: T: m"),
    )


def test_error_model_ignores_non_string_and_empty_members() raises:
    var bodies = List[String]()
    var wants = List[String]()
    # Both members present but not strings.
    bodies.append(String('{"error":{"type":5,"message":["x"]}}'))
    wants.append(String("base"))
    bodies.append(String('{"error":{"type":null,"message":{"a":"b"}}}'))
    wants.append(String("base"))
    bodies.append(String('{"error":{"type":true,"message":false}}'))
    wants.append(String("base"))
    # One string and one not: only the string is kept.
    bodies.append(String('{"error":{"type":"T","message":12}}'))
    wants.append(String("base: T"))
    bodies.append(String('{"error":{"type":12,"message":"m"}}'))
    wants.append(String("base: m"))
    # Empty strings add nothing.
    bodies.append(String('{"error":{"type":"","message":""}}'))
    wants.append(String("base"))
    bodies.append(String('{"error":{"type":"","message":"m"}}'))
    wants.append(String("base: m"))
    for i in range(len(bodies)):
        assert_equal(with_error_model(String("base"), bodies[i]), wants[i])


def test_namespace_token_needs_a_string_type_on_a_table_path() raises:
    assert_equal(
        rest_error_message(
            404,
            String('{"error":{"type":["NoSuchNamespaceException"]}}'),
            String("loadTable 'a.b'"),
            True,
        ),
        String("ICEBERG_TABLE_NOT_FOUND: loadTable 'a.b': HTTP 404"),
    )
    assert_equal(
        rest_error_message(
            404,
            String('{"error":{"type":"NoSuchNamespaceException"}}'),
            String("loadTable 'a.b'"),
            True,
        ),
        String(
            "ICEBERG_NAMESPACE_NOT_FOUND: loadTable 'a.b': HTTP 404:"
            " NoSuchNamespaceException"
        ),
    )
    # Off a table path a 404 is a rejection whatever the type says.
    assert_equal(
        rest_error_message(
            404,
            String('{"error":{"type":"NoSuchNamespaceException"}}'),
            String("GET /v1/config"),
            False,
        ),
        String(
            "ICEBERG_CATALOG_REJECTED: GET /v1/config: HTTP 404:"
            " NoSuchNamespaceException"
        ),
    )


def _secret_bodies() -> List[String]:
    """Bodies that carry a secret-looking string in places the message must
    not copy: an unknown member, a non-JSON text, an ErrorModel stack."""
    var b = List[String]()
    b.append(
        String(
            '{"error":{"message":"denied","type":"ForbiddenException",'
            + '"code":403,"stack":["at '
        )
        + _SECRET
        + String('"]},"token":"')
        + _SECRET
        + String('"}')
    )
    b.append(String("Authorization: Bearer ") + _SECRET)
    b.append(String('{"debug":"') + _SECRET + String('"}'))
    return b^


def _model_tail(i: Int) -> String:
    """What `_secret_bodies()[i]` contributes to a message: only the first
    body has an ErrorModel."""
    if i == 0:
        return String(": ForbiddenException: denied")
    return String("")


def test_rest_error_message_never_holds_the_raw_body() raises:
    var bodies = _secret_bodies()
    for i in range(len(bodies)):
        var want = String(
            "ICEBERG_CATALOG_FORBIDDEN: loadTable 'db.t': HTTP 403"
        ) + _model_tail(i)
        assert_equal(
            rest_error_message(
                403, bodies[i], String("loadTable 'db.t'"), True
            ),
            want,
        )
        var t = ScriptedIcebergRestTransport()
        t.queue_response(200, String(_CFG_OK))
        t.queue_response(403, bodies[i])
        var c = _client(t^)
        assert_equal(_load_error(c, String("db"), String("t")), want)


def test_client_errors_never_hold_the_raw_body_on_any_path() raises:
    var bodies = _secret_bodies()
    for i in range(len(bodies)):
        var tail = _model_tail(i)
        # config
        var t = ScriptedIcebergRestTransport()
        t.queue_response(401, bodies[i])
        var c = _client(t^)
        assert_equal(
            _load_error(c, String("db"), String("t")),
            String("ICEBERG_CATALOG_UNAUTHORIZED: GET /v1/config: HTTP 401")
            + tail,
        )

        # createTable: a 409 and a 500
        var t2 = ScriptedIcebergRestTransport()
        t2.queue_response(200, String(_CFG_OK))
        t2.queue_response(409, bodies[i])
        t2.queue_response(500, bodies[i])
        var c2 = _client(t2^)
        assert_equal(
            _create_error(c2, _new_table(False)),
            String("ICEBERG_TABLE_ALREADY_EXISTS: createTable 'db.t': HTTP 409")
            + tail,
        )
        assert_equal(
            _create_error(c2, _new_table(False)),
            String("ICEBERG_CATALOG_UNAVAILABLE: createTable 'db.t': HTTP 500")
            + tail,
        )

        # commitTable: 409, 500, 400
        var t3 = ScriptedIcebergRestTransport()
        t3.queue_response(200, String(_CFG_OK))
        t3.queue_response(409, bodies[i])
        t3.queue_response(500, bodies[i])
        t3.queue_response(400, bodies[i])
        var c3 = _client(t3^)
        var r1 = c3.commit_table(
            String("db"), String("t"), String("{}"), String("")
        )
        assert_equal(r1.kind, COMMIT_CONFLICT)
        assert_equal(r1.message, String("commitTable 'db.t': HTTP 409") + tail)
        var r2 = c3.commit_table(
            String("db"), String("t"), String("{}"), String("")
        )
        assert_equal(r2.kind, COMMIT_UNKNOWN)
        assert_equal(
            r2.message,
            String("ICEBERG_CATALOG_UNAVAILABLE: commitTable 'db.t': HTTP 500")
            + tail,
        )
        var r3 = c3.commit_table(
            String("db"), String("t"), String("{}"), String("")
        )
        assert_equal(r3.kind, COMMIT_REFUSED)
        assert_equal(
            r3.message,
            String("ICEBERG_CATALOG_REJECTED: commitTable 'db.t': HTTP 400")
            + tail,
        )


def test_error_has_token_requires_token_colon_at_the_start() raises:
    var tok = String("ICEBERG_CATALOG_UNAVAILABLE")
    assert_true(error_has_token(String("ICEBERG_CATALOG_UNAVAILABLE: x"), tok))
    assert_true(error_has_token(String("ICEBERG_CATALOG_UNAVAILABLE:"), tok))
    assert_false(error_has_token(String("ICEBERG_CATALOG_UNAVAILABLE"), tok))
    assert_false(error_has_token(String("ICEBERG_CATALOG_UNAVAILABLE x"), tok))
    assert_false(
        error_has_token(String("ICEBERG_CATALOG_UNAVAILABLEX: x"), tok)
    )
    assert_false(
        error_has_token(String("x ICEBERG_CATALOG_UNAVAILABLE: x"), tok)
    )
    assert_false(error_has_token(String("ICEBERG_CATALOG: x"), tok))
    assert_false(error_has_token(String(""), tok))
    assert_false(error_has_token(String("ICEBERG_CATALOG_REJECTED: x"), tok))
    # A message built by the mapping carries its own token and no other.
    var m = rest_error_message(404, String(""), String("loadTable 'a.b'"), True)
    assert_true(error_has_token(m, ICEBERG_TABLE_NOT_FOUND))
    assert_false(error_has_token(m, ICEBERG_NAMESPACE_NOT_FOUND))
    assert_false(error_has_token(m, ICEBERG_TABLE_ALREADY_EXISTS))
    assert_false(error_has_token(m, ICEBERG_CATALOG_RESPONSE_INVALID))


def main() raises:
    test_create_table_status_sweep()
    test_commit_table_status_sweep()
    test_commit_table_200_with_unreadable_body_is_unknown()
    test_create_table_200_without_location_is_invalid()
    test_rest_error_message_without_an_error_model()
    test_rest_error_message_type_only_and_message_only()
    test_error_model_ignores_non_string_and_empty_members()
    test_namespace_token_needs_a_string_type_on_a_table_path()
    test_rest_error_message_never_holds_the_raw_body()
    test_client_errors_never_hold_the_raw_body_on_any_path()
    test_error_has_token_requires_token_colon_at_the_start()
    print("test_iceberg_rest_error_messages: ALL PASS")
