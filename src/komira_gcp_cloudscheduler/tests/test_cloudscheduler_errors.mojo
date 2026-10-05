# A non-2xx answer to each generated Cloud Scheduler method raises through
# komira_gcp_core's `gcp_status_error`: the error names the verb, the RPC,
# the HTTP status and the canonical code of the `google.rpc.Status`
# envelope, and counts bytes. It never repeats a byte of the body: a Cloud
# Scheduler error `message` names the project, the job and the invoker,
# and each test checks for them.
#
# One envelope per method, each the error a caller of that method meets (a
# job that exists, a job that does not, an unparseable schedule, a missing
# permission), hand-written in the form the Cloud APIs error model
# documents. The connector is komira_http_core's ScriptedConnector; no
# socket is used.
from std.testing import assert_equal, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_cloudscheduler.cloudscheduler import (
    CloudSchedulerClient,
    CreateJobRequest,
    DeleteJobRequest,
    GetJobRequest,
    UpdateJobRequest,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = CloudSchedulerClient[ScriptedConnector, StaticTokenSource]

comptime _NAME = "projects/private-project/locations/us-central1/jobs/nightly-sync"


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


def _job() -> String:
    return (
        String('{"name":"')
        + _NAME
        + '","schedule":"0 3 * * *","httpTarget":{"uri":"https://private.example/tick"}}'
    )


def test_create_job_already_exists() raises:
    var message = String("Job " + _NAME + " already exists.")
    var body = _envelope(409, "ALREADY_EXISTS", message)
    var c = _client("409 Conflict", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.create_job[_RT](
            decode_json[CreateJobRequest](
                String('{"parent":"projects/private-project/locations/us-central1","job":')
                + _job()
                + "}"
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got, _expected("POST CreateJob: HTTP 409, ALREADY_EXISTS (code 6)", message, body)
    )
    assert_false("private-project" in got)
    assert_false("nightly-sync" in got)


def test_get_job_not_found() raises:
    var message = String("Job not found.")
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _client("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.get_job[_RT](
            decode_json[GetJobRequest](String('{"name":"') + _NAME + '"}'), reactor
        )
    except e:
        got = String(e)
    assert_equal(got, _expected("GET GetJob: HTTP 404, NOT_FOUND (code 5)", message, body))
    assert_false("nightly-sync" in got)


def test_update_job_invalid_schedule() raises:
    var message = String("Schedule or time zone is invalid.")
    var body = _envelope(400, "INVALID_ARGUMENT", message)
    var c = _client("400 Bad Request", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.update_job[_RT](
            decode_json[UpdateJobRequest](
                String('{"updateMask":"schedule","job":') + _job() + "}"
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got, _expected("PATCH UpdateJob: HTTP 400, INVALID_ARGUMENT (code 3)", message, body)
    )
    assert_false("Schedule" in got)


def test_delete_job_permission_denied() raises:
    var message = String(
        "The principal (user or service account) lacks IAM permission"
        + " cloudscheduler.jobs.delete for the resource "
        + _NAME
        + "."
    )
    var body = _envelope(403, "PERMISSION_DENIED", message)
    var c = _client("403 Forbidden", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.delete_job[_RT](
            decode_json[DeleteJobRequest](String('{"name":"') + _NAME + '"}'), reactor
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("DELETE DeleteJob: HTTP 403, PERMISSION_DENIED (code 7)", message, body),
    )
    assert_false("cloudscheduler.jobs.delete" in got)
    assert_false("private-project" in got)


def main() raises:
    test_create_job_already_exists()
    test_get_job_not_found()
    test_update_job_invalid_schedule()
    test_delete_job_permission_denied()
    print("OK")
