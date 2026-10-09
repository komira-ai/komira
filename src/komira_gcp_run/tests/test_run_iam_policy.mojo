# The IAM policy of a Cloud Run service and of a Cloud Run job, through the
# generated `ServicesClient` and `JobsClient`: one wire row per method
# (GetIamPolicy, SetIamPolicy on each), its request line, headers and body
# byte for byte, and the policy it reads back. A service's policy says who
# may invoke it (`roles/run.invoker`); a job's says who may run it.
#
# The forms are written here from the Cloud Run Admin v2 REST reference
# (projects.locations.services.getIamPolicy, .setIamPolicy, and the same on
# jobs); no upstream test body is copied. getIamPolicy is a GET with no
# body, so its `GetPolicyOptions` rides the query as
# `options.requestedPolicyVersion`; setIamPolicy's body is the
# `SetIamPolicyRequest` less the `resource` its path carries.
#
# The connector is komira_http_core's ScriptedConnector with a shared write
# capture; no socket is opened. Each client is pointed at `localhost` with
# `set_rest_host`.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_run.iam_policy import GetIamPolicyRequest, SetIamPolicyRequest
from komira_gcp_run.job import JobsClient
from komira_gcp_run.options import GetPolicyOptions
from komira_gcp_run.policy import Policy
from komira_gcp_run.service import ServicesClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]

comptime _SERVICE = "projects/demo-project/locations/us-central1/services/web"
comptime _JOB = "projects/demo-project/locations/us-central1/jobs/nightly"

# The policy a read answers with: version 3, one binding, the etag
# "BwXhqDuVJ8g=".
comptime _POLICY = (
    '{"version":3,"bindings":[{"role":"roles/run.invoker",'
    + '"members":["serviceAccount:caller@example.com"]}],'
    + '"etag":"BwXhqDuVJ8g="}'
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _http(capture: ArcPointer[List[UInt8]]) -> HttpClient[ScriptedConnector]:
    return HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(_ok(_POLICY), capture)
        )
    )


def _services(
    capture: ArcPointer[List[UInt8]],
) raises -> ServicesClient[ScriptedConnector, StaticTokenSource]:
    var c = ServicesClient[ScriptedConnector, StaticTokenSource](
        _http(capture), StaticTokenSource(String("test-access-token"))
    )
    c.set_rest_host(String("localhost"))
    return c^


def _jobs(
    capture: ArcPointer[List[UInt8]],
) raises -> JobsClient[ScriptedConnector, StaticTokenSource]:
    var c = JobsClient[ScriptedConnector, StaticTokenSource](
        _http(capture), StaticTokenSource(String("test-access-token"))
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _expected(target: String, body: String = "") -> String:
    """The request as written: komira_http's Host, User-Agent and
    Content-Length, then the client's headers, a content-type only with a
    body, then the body."""
    var out = (
        target
        + " HTTP/1.1\r\n"
        + "Host: localhost\r\n"
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\n"
        + "authorization: Bearer test-access-token\r\n"
    )
    if body.byte_length() > 0:
        out += "content-type: application/json\r\n"
    return out + "\r\n" + body


def _get(name: String) raises -> GetIamPolicyRequest:
    return GetIamPolicyRequest(name, Optional[GetPolicyOptions](GetPolicyOptions(Int32(3))))


def _set(name: String) raises -> SetIamPolicyRequest:
    return SetIamPolicyRequest(name, decode_json[Policy](_POLICY), None)


# The body of each set: the policy as read, the `resource` in the path only.
comptime _SET_BODY = '{"policy":' + _POLICY + "}"


def _check_policy(p: Policy) raises:
    assert_equal(p.version, 3)
    assert_equal(len(p.bindings), 1)
    assert_equal(p.bindings[0].role, "roles/run.invoker")
    var etag: List[UInt8] = [0x07, 0x05, 0xE1, 0xA8, 0x3B, 0x95, 0x27, 0xC8]
    assert_true(p.etag == etag)


def test_service_get_iam_policy() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _services(capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.get_iam_policy[_RT](_get(_SERVICE), reactor)
    assert_equal(
        _wire(capture),
        _expected(
            String("GET /v2/") + _SERVICE + ":getIamPolicy?options.requestedPolicyVersion=3"
        ),
    )
    _check_policy(p)


def test_service_set_iam_policy() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _services(capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.set_iam_policy[_RT](_set(_SERVICE), reactor)
    assert_equal(
        _wire(capture),
        _expected(String("POST /v2/") + _SERVICE + ":setIamPolicy", _SET_BODY),
    )
    _check_policy(p)


def test_job_get_iam_policy() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _jobs(capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.get_iam_policy[_RT](_get(_JOB), reactor)
    assert_equal(
        _wire(capture),
        _expected(
            String("GET /v2/") + _JOB + ":getIamPolicy?options.requestedPolicyVersion=3"
        ),
    )
    _check_policy(p)


def test_job_set_iam_policy() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _jobs(capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.set_iam_policy[_RT](_set(_JOB), reactor)
    assert_equal(
        _wire(capture),
        _expected(String("POST /v2/") + _JOB + ":setIamPolicy", _SET_BODY),
    )
    _check_policy(p)


def main() raises:
    test_service_get_iam_policy()
    test_service_set_iam_policy()
    test_job_get_iam_policy()
    test_job_set_iam_policy()
    print("OK")
