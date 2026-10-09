# Each generated Cloud Scheduler method, once: the request it puts on the
# wire, byte for byte (request line with the resource-name captures and the
# query, the headers, the JSON body), and the response it reads back.
#
# The expected forms are written here from the Cloud Scheduler v1 REST
# reference (projects.locations.jobs.create, .get, .list, .patch, .delete); no
# upstream test body is copied. The job is the shape komira deploys: an
# HTTP target called on a cron schedule with an OIDC token for an invoker
# service account, and a per-attempt deadline. The connector is
# komira_http_core's ScriptedConnector with a shared write capture; no
# socket is opened. Each client is pointed at `localhost` (resolved without
# the network) with `set_rest_host`; the default host is
# test_cloudscheduler_endpoint's subject.
#
# A body is the job as the caller states it: a field left at its default
# (`description`, `state`, `audience`) is omitted, as the proto3 JSON
# mapping omits it, and the service reads it as unset. The update mask
# names exactly the fields the caller sets, so the unset ones are not
# written over.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import GcpTokenSource, StaticTokenSource
from komira_gcp_cloudscheduler.cloudscheduler import (
    CloudSchedulerClient,
    CreateJobRequest,
    DeleteJobRequest,
    GetJobRequest,
    ListJobsRequest,
    UpdateJobRequest,
)
from komira_gcp_cloudscheduler.job import Job, Job_State
from komira_gcp_cloudscheduler.target import HttpMethod as TargetHttpMethod
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = CloudSchedulerClient[ScriptedConnector, StaticTokenSource]

# 2026-09-30T12:00:00Z and 2026-10-01T08:30:15Z.
comptime _T0 = Int64(1790769600)
comptime _T1 = Int64(1790843415)

comptime _NAME = "projects/demo-project/locations/us-central1/jobs/nightly-sync"

# The job as a caller states it.
comptime _JOB = (
    '{"name":"projects/demo-project/locations/us-central1/jobs/nightly-sync",'
    + '"schedule":"0 3 * * *","timeZone":"America/Chicago","attemptDeadline":"320s",'
    + '"httpTarget":{"uri":"https://sync-abc123-uc.a.run.app/tick","httpMethod":"POST",'
    + '"headers":{"Content-Type":"application/json"},"body":"e30=",'
    + '"oidcToken":{"serviceAccountEmail":"invoker@demo-project.iam.gserviceaccount.com"}}}'
)

# The job as the client writes it: byte for byte as stated, nothing the
# caller left unset added.
comptime _JOB_WIRE = _JOB

# The job as the service answers it: the stated fields, and its own.
comptime _JOB_ANSWER = (
    '{"name":"projects/demo-project/locations/us-central1/jobs/nightly-sync",'
    + '"schedule":"0 3 * * *","timeZone":"America/Chicago","attemptDeadline":"320s",'
    + '"httpTarget":{"uri":"https://sync-abc123-uc.a.run.app/tick","httpMethod":"POST",'
    + '"headers":{"Content-Type":"application/json","User-Agent":"Google-Cloud-Scheduler"},'
    + '"body":"e30=","oidcToken":{"serviceAccountEmail":'
    + '"invoker@demo-project.iam.gserviceaccount.com",'
    + '"audience":"https://sync-abc123-uc.a.run.app/tick"}},'
    + '"userUpdateTime":"2026-09-30T12:00:00Z","state":"ENABLED",'
    + '"scheduleTime":"2026-10-01T08:30:15Z",'
    + '"retryConfig":{"maxRetryDuration":"0s","minBackoffDuration":"5s",'
    + '"maxBackoffDuration":"3600s","maxDoublings":5}}'
)


struct CountingTokenSource(GcpTokenSource, Movable, Deinitable):
    """Counts the tokens asked of it in a cell the test keeps."""

    var calls: ArcPointer[Int]

    def __init__(out self, calls: ArcPointer[Int]):
        self.calls = calls

    def access_token(mut self) raises -> String:
        self.calls[] += 1
        return String("test-access-token")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    """A 200 with a JSON body, closing the connection after it."""
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(capture: ArcPointer[List[UInt8]], answer: String) raises -> _Client:
    var stream = ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(stream^)
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _expected(target: String, body: String = "") -> String:
    """The request as written: komira_http's Host, User-Agent and
    Content-Length, then the client's headers (lowercased on the wire), a
    content-type only with a body, then the body."""
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


def _check_answered_job(job: Job) raises:
    assert_equal(job.name, _NAME)
    assert_equal(job.schedule, "0 3 * * *")
    assert_equal(job.time_zone, "America/Chicago")
    assert_true(job.state == Job_State(Job_State.ENABLED))
    assert_equal(job.user_update_time.value().seconds, _T0)
    assert_equal(job.schedule_time.value().seconds, _T1)
    assert_equal(job.attempt_deadline.value().seconds, Int64(320))
    ref target = job.http_target.value()
    assert_equal(target.uri, "https://sync-abc123-uc.a.run.app/tick")
    assert_true(target.http_method == TargetHttpMethod(TargetHttpMethod.POST))
    assert_equal(String(unsafe_from_utf8=Span(target.body)), "{}")
    assert_equal(target.headers["User-Agent"], "Google-Cloud-Scheduler")
    ref oidc = target.oidc_token.value()
    assert_equal(oidc.service_account_email, "invoker@demo-project.iam.gserviceaccount.com")
    assert_equal(oidc.audience, "https://sync-abc123-uc.a.run.app/tick")
    assert_false(Bool(target.oauth_token))
    assert_false(Bool(job.pubsub_target))
    ref retry = job.retry_config.value()
    assert_equal(retry.min_backoff_duration.value().seconds, Int64(5))
    assert_equal(retry.max_doublings, Int32(5))


def test_create_job() raises:
    # POST .../locations/{location}/jobs, the Job as the body.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _JOB_ANSWER)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var job = c.create_job[_RT](
        decode_json[CreateJobRequest](
            String('{"parent":"projects/demo-project/locations/us-central1","job":')
            + _JOB
            + "}"
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected("POST /v1/projects/demo-project/locations/us-central1/jobs", _JOB_WIRE),
    )
    _check_answered_job(job)


def test_get_job() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _JOB_ANSWER)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var job = c.get_job[_RT](
        decode_json[GetJobRequest](String('{"name":"') + _NAME + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("GET /v1/") + _NAME))
    _check_answered_job(job)


def test_list_jobs() raises:
    # GET .../locations/{location}/jobs, the page in the query.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        String('{"jobs":[') + _JOB_ANSWER + '],"nextPageToken":"CgZuaWdodA=="}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var page = c.list_jobs[_RT](
        decode_json[ListJobsRequest](
            '{"parent":"projects/demo-project/locations/us-central1",'
            + '"pageSize":100,"pageToken":"CgRh="}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "GET /v1/projects/demo-project/locations/us-central1/jobs"
            + "?pageSize=100&pageToken=CgRh%3D"
        ),
    )
    assert_equal(len(page.jobs), 1)
    _check_answered_job(page.jobs[0])
    assert_equal(page.next_page_token, "CgZuaWdodA==")


def test_update_job() raises:
    # PATCH /v1/{job.name=...}: the path is the body's job name, and the
    # update mask is one query parameter, its paths in lowerCamelCase joined
    # by commas (percent-encoded).
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _JOB_ANSWER)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var job = c.update_job[_RT](
        decode_json[UpdateJobRequest](
            String('{"updateMask":"schedule,timeZone,attemptDeadline,httpTarget","job":')
            + _JOB
            + "}"
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("PATCH /v1/")
            + _NAME
            + "?updateMask=schedule%2CtimeZone%2CattemptDeadline%2ChttpTarget",
            _JOB_WIRE,
        ),
    )
    _check_answered_job(job)


def test_update_job_without_a_mask_sends_none() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _JOB_ANSWER)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.update_job[_RT](
        decode_json[UpdateJobRequest](String('{"job":') + _JOB + "}"), reactor
    )
    assert_equal(_wire(capture), _expected(String("PATCH /v1/") + _NAME, _JOB_WIRE))


def test_update_job_without_a_job_is_refused_before_any_send() raises:
    # The path is built from job.name: with no job there is no resource to
    # address, and nothing is asked of the token source or dialled.
    var calls = ArcPointer[Int](0)
    var c = CloudSchedulerClient[ScriptedConnector, CountingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok("{}")))
        ),
        CountingTokenSource(calls),
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.update_job[_RT](
            decode_json[UpdateJobRequest]('{"updateMask":"schedule"}'), reactor
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        "update_job: the request's `job` is unset, and the path is built from `job.name`",
    )
    assert_equal(calls[], 0)
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_delete_job() raises:
    # DELETE .../jobs/{job}; the answer is an Empty.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, "{}")
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.delete_job[_RT](
        decode_json[DeleteJobRequest](String('{"name":"') + _NAME + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("DELETE /v1/") + _NAME))


def main() raises:
    test_create_job()
    test_get_job()
    test_list_jobs()
    test_update_job()
    test_update_job_without_a_mask_sends_none()
    test_update_job_without_a_job_is_refused_before_any_send()
    test_delete_job()
    print("OK")
