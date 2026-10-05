# A non-2xx answer from Artifact Registry raises through komira_gcp_core's
# `gcp_status_error`: the error names the verb, the RPC, the HTTP status and
# the canonical code from the `google.rpc.Status` envelope's `status`, and
# counts bytes; it never repeats a byte of the body (an error message names
# the project, location and repository).
#
# The envelopes are written in the form the Cloud APIs error model documents
# (`{"error": {"code", "message", "status"}}`); the connector is
# komira_http_core's ScriptedConnector pointed at `localhost` (no socket, no
# name lookup). A create that finds the repository already there answers
# 409 ALREADY_EXISTS, which a deploy that adopts an existing repository keys
# on.
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_artifactregistry.repository import (
    CreateRepositoryRequest,
    GetRepositoryRequest,
    Repository,
)
from komira_gcp_artifactregistry.service import ArtifactRegistryClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource
comptime _NAME = "projects/private-project/locations/us-central1/repositories/images"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status_line: String, body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(var answer: List[UInt8]) raises -> ArtifactRegistryClient[SC, TS]:
    var c = ArtifactRegistryClient[SC, TS](
        HttpClient[SC].with_defaults(
            SC.with_stream_tls(ScriptedStream.from_read_script(answer^))
        ),
        TS(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _get_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    try:
        _ = c.get_repository[_RT](GetRepositoryRequest(String(_NAME)), reactor)
    except e:
        return String(e)
    raise Error("GetRepository returned on a non-2xx answer")


def _create_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var repo = decode_json_lenient[Repository](String('{"format":"DOCKER"}'))
    try:
        _ = c.create_repository[_RT](
            CreateRepositoryRequest(
                String("projects/private-project/locations/us-central1"),
                String("images"),
                repo^,
            ),
            reactor,
        )
    except e:
        return String(e)
    raise Error("CreateRepository returned on a non-2xx answer")


def test_not_found() raises:
    var message = String("Requested entity was not found.")
    var body = String('{"error":{"code":404,"message":"') + message + String(
        '","status":"NOT_FOUND"}}'
    )
    var got = _get_raised(_answer("404 Not Found", body))
    assert_equal(
        got,
        String("GET GetRepository: HTTP 404, NOT_FOUND (code 5), error.message ")
        + String(message.byte_length())
        + " bytes, body "
        + String(body.byte_length())
        + " bytes",
    )


def test_already_exists_on_create() raises:
    var body = String(
        '{"error":{"code":409,"message":"the repository already exists: '
        + _NAME
        + '","status":"ALREADY_EXISTS"}}'
    )
    var got = _create_raised(_answer("409 Conflict", body))
    assert_true(
        got.startswith("POST CreateRepository: HTTP 409, ALREADY_EXISTS (code 6), ")
    )
    assert_false("private-project" in got)


def test_permission_denied() raises:
    var body = String(
        '{"error":{"code":403,"message":"Permission'
        + " 'artifactregistry.repositories.get' denied on resource '"
        + _NAME
        + "' (or it may not exist).\",\"status\":\"PERMISSION_DENIED\"}}"
    )
    var got = _get_raised(_answer("403 Forbidden", body))
    assert_true(
        got.startswith("GET GetRepository: HTTP 403, PERMISSION_DENIED (code 7), ")
    )
    assert_false("private-project" in got)
    assert_false("repositories.get" in got)


def test_empty_error_body() raises:
    var got = _get_raised(_answer("503 Service Unavailable", ""))
    assert_equal(
        got,
        "GET GetRepository: HTTP 503, UNAVAILABLE (code 14), no google.rpc.Status"
        " envelope, body 0 bytes",
    )


def main() raises:
    test_not_found()
    test_already_exists_on_create()
    test_permission_denied()
    test_empty_error_body()
    print("OK")
