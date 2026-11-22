# =============================================================================
# iceberg_catalog/iceberg_rest_errors.mojo — the error tokens of the Iceberg
#   catalog client and committer, and the mapping of a REST error response to
#   a message that starts with its token.
# =============================================================================
#
# Every error this package raises starts with its token
# (docs/design/iceberg_tables.md, "Errors"). A message never carries a raw
# response body or a secret: from a REST error response it keeps only the
# status, and the `type` and `message` of the catalog's `ErrorModel`
# (`{"error": {"message": ..., "type": ..., "code": ...}}`).
# =============================================================================

from json import JsonValue, parse_json_value, JSON_OBJECT, JSON_STRING


# =============================================================================
# §0 — the tokens.
# =============================================================================

comptime ICEBERG_NAMESPACE_NOT_FOUND: String = "ICEBERG_NAMESPACE_NOT_FOUND"
comptime ICEBERG_TABLE_NOT_FOUND: String = "ICEBERG_TABLE_NOT_FOUND"
comptime ICEBERG_TABLE_ALREADY_EXISTS: String = "ICEBERG_TABLE_ALREADY_EXISTS"
comptime ICEBERG_CATALOG_UNAUTHORIZED: String = "ICEBERG_CATALOG_UNAUTHORIZED"
comptime ICEBERG_CATALOG_FORBIDDEN: String = "ICEBERG_CATALOG_FORBIDDEN"
comptime ICEBERG_CATALOG_REJECTED: String = "ICEBERG_CATALOG_REJECTED"
comptime ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: String = (
    "ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED"
)
comptime ICEBERG_CATALOG_UNAVAILABLE: String = "ICEBERG_CATALOG_UNAVAILABLE"
comptime ICEBERG_CATALOG_RESPONSE_INVALID: String = (
    "ICEBERG_CATALOG_RESPONSE_INVALID"
)
comptime ICEBERG_COMMIT_CONFLICT: String = "ICEBERG_COMMIT_CONFLICT"
comptime ICEBERG_COMMIT_STATE_UNKNOWN: String = "ICEBERG_COMMIT_STATE_UNKNOWN"
comptime ICEBERG_TABLE_REPLACED: String = "ICEBERG_TABLE_REPLACED"
comptime ICEBERG_SCHEMA_INCOMPATIBLE: String = "ICEBERG_SCHEMA_INCOMPATIBLE"
comptime ICEBERG_WRITE_FORMAT_UNSUPPORTED: String = (
    "ICEBERG_WRITE_FORMAT_UNSUPPORTED"
)


def error_has_token(message: String, token: String) -> Bool:
    """True iff `message` starts with `token` followed by `:`, the form every
    message of this package has."""
    return message.startswith(token + String(":"))


# =============================================================================
# §1 — a REST error response -> a message.
# =============================================================================


def rest_error_message(
    status: Int, body: String, what: String, table_path: Bool
) -> String:
    """The message for a non-200 response to the request `what`.

    `what` names the request, for example `loadTable 'db.t'`. The token
    follows the status:

      * 404 on a table path: `ICEBERG_NAMESPACE_NOT_FOUND` when the error type
        is `NoSuchNamespaceException`, else `ICEBERG_TABLE_NOT_FOUND`;
      * 401 and 419: `ICEBERG_CATALOG_UNAUTHORIZED`;
      * 403: `ICEBERG_CATALOG_FORBIDDEN`;
      * any 5xx: `ICEBERG_CATALOG_UNAVAILABLE`;
      * anything else (400, a 404 off a table path, a 2xx other than 200, a
        3xx): `ICEBERG_CATALOG_REJECTED`.

    The message is `<token>: <what>: HTTP <status>`, followed by
    `: <type>: <message>` when the body is an ErrorModel. Never the body."""
    var token: String
    var err_type = _error_model_field(body, String("type"))
    if status == 404 and table_path:
        if err_type == String("NoSuchNamespaceException"):
            token = ICEBERG_NAMESPACE_NOT_FOUND
        else:
            token = ICEBERG_TABLE_NOT_FOUND
    elif status == 401 or status == 419:
        token = ICEBERG_CATALOG_UNAUTHORIZED
    elif status == 403:
        token = ICEBERG_CATALOG_FORBIDDEN
    elif status >= 500 and status <= 599:
        token = ICEBERG_CATALOG_UNAVAILABLE
    else:
        token = ICEBERG_CATALOG_REJECTED
    return with_error_model(
        token + String(": ") + what + String(": HTTP ") + String(status), body
    )


def with_error_model(var message: String, body: String) -> String:
    """`message`, followed by `: <type>: <message>` from the body's ErrorModel
    when it has one (either part alone when only one is a string)."""
    var err_type = _error_model_field(body, String("type"))
    var err_msg = _error_model_field(body, String("message"))
    if err_type.byte_length() > 0:
        message += String(": ") + err_type
    if err_msg.byte_length() > 0:
        message += String(": ") + err_msg
    return message^


def _error_model_field(body: String, name: String) -> String:
    """The string member `name` of the body's `error` object; "" when the body
    is not JSON, has no `error` object, or the member is absent or not a
    string."""
    try:
        var root = parse_json_value(body)
        if root.kind_tag() != JSON_OBJECT or not root.has(String("error")):
            return String("")
        var err = root.get(String("error"))
        if err.kind_tag() != JSON_OBJECT or not err.has(name):
            return String("")
        var v = err.get(name)
        if v.kind_tag() != JSON_STRING:
            return String("")
        return v.as_string()
    except:
        return String("")
