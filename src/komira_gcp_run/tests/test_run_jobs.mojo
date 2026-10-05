# Each generated Cloud Run `Jobs` and `Executions` method, once: the
# request it puts on the wire, byte for byte (request line with the
# resource-name captures and the query, the headers, the JSON body), and
# the response it reads back. CreateJob, UpdateJob, DeleteJob, RunJob and
# CancelExecution answer with a google.longrunning.Operation, which
# test_run_operations polls.
#
# The expected forms are written here from the Cloud Run Admin v2 REST
# reference (projects.locations.jobs.create, .get, .list, .patch, .delete,
# .run, and jobs.executions.get, .cancel); no upstream test body is copied.
# The job is the shape komira runs to completion: one task of one container
# from an image pinned by digest, no retries and a timeout; a run overrides
# the container's arguments and environment. The connector is
# komira_http_core's ScriptedConnector with a shared write capture; no
# socket is opened. Each client is pointed at `localhost` with
# `set_rest_host`; the default host is test_run_endpoint's subject.
#
# komira_proto_codec writes a scalar or enum at its default (`"uid":""`,
# `..._UNSPECIFIED`), which the proto3 JSON mapping lets a writer omit and
# the service reads as unset; an empty list or map it leaves out. A
# `body: "*"` method (RunJob, CancelExecution) leaves its path field
# (`name`) out of the body, as google/api/http.proto states.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_run.condition import Condition_State
from komira_gcp_run.execution import (
    CancelExecutionRequest,
    ExecutionsClient,
    GetExecutionRequest,
)
from komira_gcp_run.job import (
    CreateJobRequest,
    DeleteJobRequest,
    ExecutionReference_CompletionStatus,
    GetJobRequest,
    JobsClient,
    ListJobsRequest,
    RunJobRequest,
    UpdateJobRequest,
)
from komira_gcp_run.launch_stage import LaunchStage
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]

# 2026-09-30T12:00:00Z and 2026-10-01T08:30:15Z.
comptime _T0 = Int64(1790769600)
comptime _T1 = Int64(1790843415)

comptime _PARENT = "projects/demo-project/locations/us-central1"
comptime _NAME = "projects/demo-project/locations/us-central1/jobs/build"
comptime _EXECUTION = (
    "projects/demo-project/locations/us-central1/jobs/build/executions/build-x7k2p"
)

# The job as a caller states it.
comptime _JOB = (
    '{"template":{"taskCount":1,"template":{"containers":[{"image":'
    + '"us-docker.pkg.dev/demo-project/apps/build@sha256:9a8b"}],"maxRetries":0,'
    + '"timeout":"600s"}}}'
)

# The same job as the client writes it, after its name.
comptime _JOB_WIRE_TAIL = (
    '"uid":"","generation":"0","creator":"",'
    + '"lastModifier":"","client":"","clientVersion":"",'
    + '"launchStage":"LAUNCH_STAGE_UNSPECIFIED","template":{'
    + '"parallelism":0,"taskCount":1,"template":{"containers":[{"name":"",'
    + '"image":"us-docker.pkg.dev/demo-project/apps/build@sha256:9a8b",'
    + '"workingDir":"",'
    + '"baseImageUri":""}],"timeout":"600s","serviceAccount":"",'
    + '"executionEnvironment":"EXECUTION_ENVIRONMENT_UNSPECIFIED","encryptionKey":"",'
    + '"maxRetries":0}},"observedGeneration":"0","executionCount":0,'
    + '"reconciling":false,"satisfiesPzs":false,"etag":""}'
)

# A running operation, as the mutating methods answer.
comptime _OPERATION = (
    '{"name":"projects/demo-project/locations/us-central1/operations/7d1c22",'
    + '"metadata":{"@type":"type.googleapis.com/google.cloud.run.v2.Execution",'
    + '"name":"projects/demo-project/locations/us-central1/jobs/build/executions/build-x7k2p"},'
    + '"done":false}'
)

# The job as the service answers it.
comptime _JOB_ANSWER = (
    '{"name":"projects/demo-project/locations/us-central1/jobs/build",'
    + '"uid":"0a1b2c3d-4e5f-4061-8273-94a5b6c7d8e9","generation":"2",'
    + '"createTime":"2026-09-30T12:00:00Z","launchStage":"GA",'
    + '"template":{"taskCount":1,"template":{"containers":[{"image":'
    + '"us-docker.pkg.dev/demo-project/apps/build@sha256:9a8b"}],"maxRetries":0,'
    + '"timeout":"600s","serviceAccount":"builder@demo-project.iam.gserviceaccount.com"}},'
    + '"observedGeneration":"2","terminalCondition":{"type":"Ready",'
    + '"state":"CONDITION_SUCCEEDED"},"executionCount":4,'
    + '"latestCreatedExecution":{"name":"build-x7k2p",'
    + '"createTime":"2026-10-01T08:30:15Z","completionStatus":"EXECUTION_SUCCEEDED"},'
    + '"etag":"\\"CJbX1bQG\\""}'
)


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


def _http(
    capture: ArcPointer[List[UInt8]], answer: String
) -> HttpClient[ScriptedConnector]:
    return HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
        )
    )


def _jobs(
    capture: ArcPointer[List[UInt8]], answer: String
) raises -> JobsClient[ScriptedConnector, StaticTokenSource]:
    var c = JobsClient[ScriptedConnector, StaticTokenSource](
        _http(capture, answer), StaticTokenSource(String("test-access-token"))
    )
    c.set_rest_host(String("localhost"))
    return c^


def _executions(
    capture: ArcPointer[List[UInt8]], answer: String
) raises -> ExecutionsClient[ScriptedConnector, StaticTokenSource]:
    var c = ExecutionsClient[ScriptedConnector, StaticTokenSource](
        _http(capture, answer), StaticTokenSource(String("test-access-token"))
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


def test_create_job() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _jobs(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.create_job[_RT](
        decode_json[CreateJobRequest](
            String('{"parent":"') + _PARENT + '","jobId":"build","job":' + _JOB + "}"
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("POST /v2/") + _PARENT + "/jobs?jobId=build",
            String('{"name":"",') + _JOB_WIRE_TAIL,
        ),
    )
    assert_equal(op.name, "projects/demo-project/locations/us-central1/operations/7d1c22")
    assert_false(op.done)


def test_get_job() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _jobs(capture, _JOB_ANSWER)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var job = c.get_job[_RT](
        decode_json[GetJobRequest](String('{"name":"') + _NAME + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("GET /v2/") + _NAME))
    assert_equal(job.name, _NAME)
    assert_equal(job.generation, Int64(2))
    assert_true(job.launch_stage == LaunchStage(LaunchStage.GA))
    assert_equal(job.create_time.value().seconds, _T0)
    ref task = job.template.value().template.value()
    assert_equal(task.service_account, "builder@demo-project.iam.gserviceaccount.com")
    assert_equal(task.max_retries.value(), Int32(0))
    assert_equal(task.timeout.value().seconds, Int64(600))
    assert_equal(job.execution_count, Int32(4))
    ref latest = job.latest_created_execution.value()
    assert_equal(latest.name, "build-x7k2p")
    assert_equal(latest.create_time.value().seconds, _T1)
    assert_true(
        latest.completion_status
        == ExecutionReference_CompletionStatus(
            ExecutionReference_CompletionStatus.EXECUTION_SUCCEEDED
        )
    )
    assert_true(
        job.terminal_condition.value().state
        == Condition_State(Condition_State.CONDITION_SUCCEEDED)
    )
    assert_equal(job.etag, '"CJbX1bQG"')


def test_list_jobs() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _jobs(
        capture, String('{"jobs":[') + _JOB_ANSWER + '],"nextPageToken":""}'
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var page = c.list_jobs[_RT](
        decode_json[ListJobsRequest](
            String('{"parent":"') + _PARENT + '","pageToken":"Cgdidl9sZA=="}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(String("GET /v2/") + _PARENT + "/jobs?pageToken=Cgdidl9sZA%3D%3D"),
    )
    assert_equal(len(page.jobs), 1)
    assert_equal(page.jobs[0].name, _NAME)
    assert_equal(page.next_page_token, "")


def test_update_job() raises:
    # PATCH /v2/{job.name=...}: the path is the body's job name. Run's
    # UpdateJob has no update mask: the Job replaces the old one whole.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _jobs(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.update_job[_RT](
        decode_json[UpdateJobRequest](
            String('{"job":{"name":"')
            + _NAME
            + '",'
            + String(String(_JOB)[byte=1:])
            + ',"validateOnly":true}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("PATCH /v2/") + _NAME + "?validateOnly=true",
            String('{"name":"') + _NAME + '",' + _JOB_WIRE_TAIL,
        ),
    )
    assert_false(op.done)


def test_delete_job() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _jobs(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.delete_job[_RT](
        decode_json[DeleteJobRequest](String('{"name":"') + _NAME + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("DELETE /v2/") + _NAME))


def test_run_job() raises:
    # POST .../jobs/{job}:run with `body: "*"`, overriding the container's
    # arguments and environment for this execution.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _jobs(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.run_job[_RT](
        decode_json[RunJobRequest](
            String('{"name":"')
            + _NAME
            + '","overrides":{"containerOverrides":[{"args":["--commit=4f2a"],'
            + '"env":[{"name":"STAGE","value":"test"}]}],"taskCount":1,"timeout":"600s"}}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("POST /v2/") + _NAME + ":run",
            String('{"validateOnly":false,"etag":"","overrides":{"containerOverrides":')
            + '[{"name":"","args":["--commit=4f2a"],"env":[{"name":"STAGE","value":"test"}],'
            + '"clearArgs":false}],"taskCount":1,"timeout":"600s"}}',
        ),
    )
    # The execution the run started is named in the operation's metadata.
    assert_equal(
        op.metadata.value().type_url, "type.googleapis.com/google.cloud.run.v2.Execution"
    )
    assert_equal(
        op.metadata.value().json_members.obj_keys[0], "name"
    )
    assert_equal(op.metadata.value().json_members.children[0].text, _EXECUTION)


def test_get_execution() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _executions(
        capture,
        String('{"name":"')
        + _EXECUTION
        + '","uid":"9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a","job":"build",'
        + '"createTime":"2026-09-30T12:00:00Z","completionTime":"2026-10-01T08:30:15Z",'
        + '"parallelism":1,"taskCount":1,"succeededCount":1,'
        + '"conditions":[{"type":"Completed","state":"CONDITION_SUCCEEDED",'
        + '"lastTransitionTime":"2026-10-01T08:30:15Z"}],'
        + '"logUri":"https://console.cloud.google.com/logs/viewer?project=demo-project",'
        + '"etag":"\\"e1\\""}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var ex = c.get_execution[_RT](
        decode_json[GetExecutionRequest](String('{"name":"') + _EXECUTION + '"}'),
        reactor,
    )
    assert_equal(_wire(capture), _expected(String("GET /v2/") + _EXECUTION))
    assert_equal(ex.name, _EXECUTION)
    assert_equal(ex.job, "build")
    assert_equal(ex.task_count, Int32(1))
    assert_equal(ex.succeeded_count, Int32(1))
    assert_equal(ex.failed_count, Int32(0))
    assert_equal(ex.completion_time.value().seconds, _T1)
    assert_equal(len(ex.conditions), 1)
    assert_equal(ex.conditions[0].type, "Completed")
    assert_true(
        ex.conditions[0].state == Condition_State(Condition_State.CONDITION_SUCCEEDED)
    )
    assert_equal(
        ex.log_uri, "https://console.cloud.google.com/logs/viewer?project=demo-project"
    )


def test_cancel_execution() raises:
    # POST .../executions/{execution}:cancel with `body: "*"`.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _executions(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.cancel_execution[_RT](
        decode_json[CancelExecutionRequest](String('{"name":"') + _EXECUTION + '"}'),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("POST /v2/") + _EXECUTION + ":cancel",
            String('{"validateOnly":false,"etag":""}'),
        ),
    )
    assert_false(op.done)


def main() raises:
    test_create_job()
    test_get_job()
    test_list_jobs()
    test_update_job()
    test_delete_job()
    test_run_job()
    test_get_execution()
    test_cancel_execution()
    print("OK")
