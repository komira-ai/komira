# A non-2xx answer to each generated Secret Manager method raises through
# komira_gcp_core's `gcp_status_error`: the error names the verb, the RPC,
# the HTTP status and the canonical code of the `google.rpc.Status`
# envelope, and counts bytes. It never repeats a byte of the body: a
# Secret Manager error `message` names the project, the secret and the
# principal, and each test checks for them.
#
# One envelope per method, each the error a caller of that method meets
# (an absent version, an existing secret, a disabled secret, a stale etag,
# a missing permission, an absent secret, an absent `latest`), hand-written
# in the form the Cloud APIs error model documents. The connector is komira_http_core's
# ScriptedConnector; no socket is used.
from std.testing import assert_equal, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.service import (
    AccessSecretVersionRequest,
    AddSecretVersionRequest,
    CreateSecretRequest,
    DeleteSecretRequest,
    GetSecretVersionRequest,
    ListSecretVersionsRequest,
    ListSecretsRequest,
    SecretManagerServiceClient,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _envelope(code: Int, status: String, message: String) -> String:
    return (
        String('{"error":{"code":')
        + String(code)
        + ',"message":"'
        + message
        + '","status":"'
        + status
        + '"}}'
    )


def _client(status_line: String, body: String) raises -> _Client:
    var answer = _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(answer^))
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _expected(head: String, message: String, body: String) -> String:
    return (
        head
        + ", error.message "
        + String(message.byte_length())
        + " bytes, body "
        + String(body.byte_length())
        + " bytes"
    )


def test_access_secret_version_not_found() raises:
    var message = String(
        "Secret Version [projects/private-project/secrets/smtp-password/versions/9]"
        + " not found or has no versions."
    )
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _client("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.access_secret_version[_RT](
            decode_json[AccessSecretVersionRequest](
                '{"name":"projects/private-project/secrets/smtp-password/versions/9"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET AccessSecretVersion: HTTP 404, NOT_FOUND (code 5)", message, body),
    )
    assert_false("private-project" in got)
    assert_false("smtp-password" in got)


def test_create_secret_already_exists() raises:
    var message = String("Secret [projects/123456789012/secrets/smtp-password] already exists.")
    var body = _envelope(409, "ALREADY_EXISTS", message)
    var c = _client("409 Conflict", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.create_secret[_RT](
            decode_json[CreateSecretRequest](
                '{"parent":"projects/private-project","secretId":"smtp-password",'
                + '"secret":{"replication":{"automatic":{}}}}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("POST CreateSecret: HTTP 409, ALREADY_EXISTS (code 6)", message, body),
    )
    assert_false("smtp-password" in got)


def test_add_secret_version_failed_precondition() raises:
    var message = String(
        "Secret [projects/123456789012/secrets/smtp-password] is in DISABLED state."
    )
    var body = _envelope(400, "FAILED_PRECONDITION", message)
    var c = _client("400 Bad Request", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.add_secret_version[_RT](
            decode_json[AddSecretVersionRequest](
                '{"parent":"projects/private-project/secrets/smtp-password",'
                + '"payload":{"data":"aHVudGVyMg=="}}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected(
            "POST AddSecretVersion: HTTP 400, FAILED_PRECONDITION (code 9)", message, body
        ),
    )
    assert_false("DISABLED" in got)
    assert_false("aHVudGVyMg" in got)


def test_delete_secret_stale_etag() raises:
    var message = String(
        "The etag provided for Secret [projects/123456789012/secrets/smtp-password]"
        + " does not match the current etag."
    )
    var body = _envelope(400, "FAILED_PRECONDITION", message)
    var c = _client("400 Bad Request", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.delete_secret[_RT](
            decode_json[DeleteSecretRequest](
                '{"name":"projects/private-project/secrets/smtp-password","etag":"\\"old\\""}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("DELETE DeleteSecret: HTTP 400, FAILED_PRECONDITION (code 9)", message, body),
    )
    assert_false("etag" in got)


def test_list_secrets_permission_denied() raises:
    var message = String(
        "Permission 'secretmanager.secrets.list' denied for resource"
        + " 'projects/private-project' (or it may not exist)."
    )
    var body = _envelope(403, "PERMISSION_DENIED", message)
    var c = _client("403 Forbidden", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.list_secrets[_RT](
            decode_json[ListSecretsRequest]('{"parent":"projects/private-project"}'),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET ListSecrets: HTTP 403, PERMISSION_DENIED (code 7)", message, body),
    )
    assert_false("private-project" in got)
    assert_false("secretmanager.secrets.list" in got)


def test_list_secret_versions_not_found() raises:
    var message = String("Secret [projects/123456789012/secrets/gone] not found.")
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _client("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.list_secret_versions[_RT](
            decode_json[ListSecretVersionsRequest](
                '{"parent":"projects/private-project/secrets/gone"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET ListSecretVersions: HTTP 404, NOT_FOUND (code 5)", message, body),
    )
    assert_false("gone" in got)


def test_get_secret_version_not_found() raises:
    var message = String(
        "Secret Version [projects/123456789012/secrets/smtp-password/versions/latest]"
        + " not found or has no versions."
    )
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _client("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.get_secret_version[_RT](
            decode_json[GetSecretVersionRequest](
                '{"name":"projects/private-project/secrets/smtp-password/versions/latest"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET GetSecretVersion: HTTP 404, NOT_FOUND (code 5)", message, body),
    )
    assert_false("smtp-password" in got)


def main() raises:
    test_access_secret_version_not_found()
    test_create_secret_already_exists()
    test_add_secret_version_failed_precondition()
    test_delete_secret_stale_etag()
    test_list_secrets_permission_denied()
    test_list_secret_versions_not_found()
    test_get_secret_version_not_found()
    print("OK")
