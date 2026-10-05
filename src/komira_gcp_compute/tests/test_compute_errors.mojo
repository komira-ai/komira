# A non-2xx answer from Compute Engine raises through komira_gcp_core's
# `gcp_status_error`: the error names the verb, the RPC, the HTTP status
# and the canonical code, and counts bytes; it never repeats a byte of the
# body (a compute error message names the project, zone and resource).
#
# Compute v1 answers with the older error envelope: `error.code` (the HTTP
# status), `error.message` and an `error.errors[]` list of
# `{message, domain, reason}`, and no `error.status` (the raised text says
# so). The canonical code is then the HTTP status's (komira_gcp_core
# `code_from_http_status`): 404 is NOT_FOUND, and a 409 is ABORTED, the
# first code google/rpc/code.proto lists for 409, not ALREADY_EXISTS. The
# raised text carries the first `errors[].reason` (a fixed machine token,
# `reason alreadyExists`), so a caller that adopts an existing resource on
# an insert conflict tells that 409 from any other by its reason.
#
# The envelopes are written in the form the Compute Engine v1 error
# reference documents; the connector is komira_http_core's
# ScriptedConnector pointed at `localhost` (no socket, no name lookup).
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import (
    GetInstanceRequest,
    InsertNetworkRequest,
    InstancesClient,
    Network,
    NetworksClient,
)
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status_line: String, content_type: String, body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Type: "
        + content_type
        + "\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _http(var answer: List[UInt8]) raises -> HttpClient[SC]:
    return HttpClient[SC].with_defaults(
        SC.with_stream_tls(ScriptedStream.from_read_script(answer^))
    )


def _get_raised(var answer: List[UInt8]) raises -> String:
    """The error Instances.Get raises on `answer`; fails if it returns."""
    var c = InstancesClient[SC, TS](
        _http(answer^), TS(String("test-access-token"))
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    try:
        _ = c.get[_RT](
            GetInstanceRequest(
                String("job-vm-1"), String("private-project"), String("us-central1-a")
            ),
            reactor,
        )
    except e:
        return String(e)
    raise Error("Instances.Get returned on a non-2xx answer")


def _insert_raised(var answer: List[UInt8]) raises -> String:
    """The error Networks.Insert raises on `answer`; fails if it returns."""
    var c = NetworksClient[SC, TS](
        _http(answer^), TS(String("test-access-token"))
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var net = decode_json_lenient[Network](String('{"name":"apps"}'))
    try:
        _ = c.insert[_RT](
            InsertNetworkRequest(net^, String("private-project"), None), reactor
        )
    except e:
        return String(e)
    raise Error("Networks.Insert returned on a non-2xx answer")


def test_not_found_without_a_status_maps_from_http() raises:
    var message = String(
        "The resource 'projects/private-project/zones/us-central1-a/instances/job-vm-1'"
        + " was not found"
    )
    var body = String('{"error":{"code":404,"message":"') + message + String(
        '","errors":[{"message":"'
    ) + message + String('","domain":"global","reason":"notFound"}]}}')
    var got = _get_raised(_answer("404 Not Found", "application/json", body))
    assert_equal(
        got,
        String("GET Get: HTTP 404, NOT_FOUND (code 5), reason notFound,")
        + " error.status absent or"
        + " not a status token, error.message "
        + String(message.byte_length())
        + " bytes, body "
        + String(body.byte_length())
        + " bytes",
    )
    assert_false("private-project" in got)
    assert_false("job-vm-1" in got)
    assert_false("was not found" in got)


def test_already_exists_on_insert_is_aborted() raises:
    var body = String(
        '{"error":{"code":409,"message":"The resource'
        + " 'projects/private-project/global/networks/apps' already exists\","
        + '"errors":[{"message":"The resource'
        + " 'projects/private-project/global/networks/apps' already exists\","
        + '"domain":"global","reason":"alreadyExists"}]}}'
    )
    var got = _insert_raised(_answer("409 Conflict", "application/json", body))
    assert_true(
        got.startswith("POST Insert: HTTP 409, ABORTED (code 10), reason alreadyExists, "),
        got,
    )
    assert_false("private-project" in got)
    assert_false("already exists" in got)


def test_another_conflict_has_another_reason() raises:
    # A 409 that is not "already exists" (the network is still being
    # created) reads differently, so an insert that adopts an existing
    # resource does not adopt one that is not there yet.
    var body = String(
        '{"error":{"code":409,"message":"The resource'
        + " 'projects/private-project/global/networks/apps' is not ready\","
        + '"errors":[{"message":"The resource'
        + " 'projects/private-project/global/networks/apps' is not ready\","
        + '"domain":"global","reason":"resourceNotReady"}]}}'
    )
    var got = _insert_raised(_answer("409 Conflict", "application/json", body))
    assert_true(
        got.startswith("POST Insert: HTTP 409, ABORTED (code 10), reason resourceNotReady, "),
        got,
    )
    assert_false("alreadyExists" in got)
    assert_false("private-project" in got)


def test_permission_denied_on_a_get() raises:
    var body = String(
        '{"error":{"code":403,"message":"Required compute.instances.get'
        + " permission for projects/private-project/zones/us-central1-a/instances/job-vm-1\","
        + '"errors":[{"domain":"global","reason":"forbidden"}]}}'
    )
    var got = _get_raised(_answer("403 Forbidden", "application/json", body))
    assert_true(got.startswith("GET Get: HTTP 403, PERMISSION_DENIED (code 7), "))
    assert_false("compute.instances.get" in got)
    assert_false("private-project" in got)


def test_rate_limited() raises:
    var body = String(
        '{"error":{"code":429,"message":"Rate Limit Exceeded",'
        + '"errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}'
    )
    var got = _get_raised(_answer("429 Too Many Requests", "application/json", body))
    assert_true(got.startswith("GET Get: HTTP 429, RESOURCE_EXHAUSTED (code 8), "))


def test_a_front_end_page_is_counted_not_quoted() raises:
    var body = String("<html><body>upstream connect error</body></html>")
    var got = _get_raised(_answer("503 Service Unavailable", "text/html", body))
    assert_equal(
        got,
        String("GET Get: HTTP 503, UNAVAILABLE (code 14), ")
        + "body is not a JSON document, body "
        + String(body.byte_length())
        + " bytes",
    )


def test_empty_error_body() raises:
    var got = _insert_raised(_answer("404 Not Found", "application/json", ""))
    assert_equal(
        got,
        "POST Insert: HTTP 404, NOT_FOUND (code 5), no google.rpc.Status"
        " envelope, body 0 bytes",
    )


def main() raises:
    test_not_found_without_a_status_maps_from_http()
    test_already_exists_on_insert_is_aborted()
    test_another_conflict_has_another_reason()
    test_permission_denied_on_a_get()
    test_rate_limited()
    test_a_front_end_page_is_counted_not_quoted()
    test_empty_error_body()
    print("OK")
