# komira_gcp_cloudscheduler

A REST/JSON client for Google Cloud Scheduler v1, generated at build time
from the pinned googleapis protos. `CloudSchedulerClient[C, T]` sends through
komira_http_client's `HttpClient` over the komira_http_core `Connector` it
is given, takes each request's bearer token from a komira_gcp_core
`GcpTokenSource`, and raises a non-2xx answer through komira_gcp_core's
`gcp_status_error`. It reads no environment.

Five methods are generated, what it takes to keep a scheduled call in step
with its declaration: GetJob (NOT_FOUND means absent), CreateJob, UpdateJob
(PATCH, with an update mask naming the fields stated), DeleteJob, and
ListJobs (a location's jobs, a page at a time). The service's other methods
(pausing, resuming, running a job) are not generated. None of these methods returns a long-running operation. The
client starts at `cloudscheduler.googleapis.com`, the service's one
endpoint; a job's region is part of its name.

The client and its requests are in `komira_gcp_cloudscheduler.cloudscheduler`,
`Job` in `.job` and the targets in `.target`.

## Examples

The examples send over komira_http_core's `ScriptedConnector`, which answers
from a script and records what was written: no socket is opened and
`localhost` needs no name lookup. Creating a job sends the `Job` as the
body and decodes the job the service answers with:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_cloudscheduler.cloudscheduler import CloudSchedulerClient, CreateJobRequest, GetJobRequest, UpdateJobRequest
from komira_gcp_cloudscheduler.job import Job_State
from komira_gcp_core import CODE_NOT_FOUND, StaticTokenSource, gcp_status_error_code
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json

comptime Runtime = BlockingRuntime[NoopSink]
comptime Client = CloudSchedulerClient[ScriptedConnector, StaticTokenSource]

def http_answer(status: String, body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ") + status + "\r\nContent-Type: application/json\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def scripted_client(answer: List[UInt8], sent: ArcPointer[List[UInt8]]) raises -> Client:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), sent)
    var c = Client(
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector.with_stream_tls(stream^)),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^
def job_json() -> String:
    return (
        String('{"name":"projects/demo/locations/us-central1/jobs/nightly-sync",')
        + '"schedule":"0 3 * * *","timeZone":"America/Chicago",'
        + '"httpTarget":{"uri":"https://sync.example/tick","httpMethod":"POST"}}'
    )

var sent = ArcPointer[List[UInt8]](List[UInt8]())
var answer = String(
    '{"name":"projects/demo/locations/us-central1/jobs/nightly-sync","schedule":"0 3 * * *",'
    + '"httpTarget":{"uri":"https://sync.example/tick"},"state":"ENABLED"}'
)
var c = scripted_client(http_answer("200 OK", answer), sent)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var job = c.create_job[Runtime](
    decode_json[CreateJobRequest](
        String('{"parent":"projects/demo/locations/us-central1","job":') + job_json() + "}"
    ),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith("POST /v1/projects/demo/locations/us-central1/jobs HTTP/1.1\r\n"))
assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire)
assert_true(wire.endswith("\r\n\r\n" + job_json()))
assert_equal(job.schedule, "0 3 * * *")
assert_true(job.state == Job_State(Job_State.ENABLED))
assert_equal(job.http_target.value().uri, "https://sync.example/tick")
```

Converging a job in place: UpdateJob is a PATCH addressed by the job's own
name, and the update mask travels as one query parameter:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(http_answer("200 OK", job_json()), sent)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
_ = c.update_job[Runtime](
    decode_json[UpdateJobRequest](
        String('{"updateMask":"schedule,timeZone","job":') + job_json() + "}"
    ),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "PATCH /v1/projects/demo/locations/us-central1/jobs/nightly-sync"
    + "?updateMask=schedule%2CtimeZone HTTP/1.1\r\n"
))
```

An UpdateJob with no job has no resource to address: it is refused before a
token is asked for or anything is written:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(http_answer("200 OK", "{}"), sent)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var raised = String()
try:
    _ = c.update_job[Runtime](decode_json[UpdateJobRequest]('{"updateMask":"schedule"}'), reactor)
except e:
    raised = String(e)
assert_equal(
    raised, "update_job: the request's `job` is unset, and the path is built from `job.name`"
)
assert_equal(len(sent[]), 0)
```

A job that does not exist is a NOT_FOUND error. The error names the verb,
the method, the HTTP status and the canonical code from the
`google.rpc.Status` envelope, and quotes no byte of the body;
`gcp_status_error_code` reads the code back, so absent is told apart from
failed:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(
    http_answer(
        "404 Not Found",
        '{"error":{"code":404,"message":"Job not found: secret-job","status":"NOT_FOUND"}}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var raised = String()
try:
    _ = c.get_job[Runtime](
        decode_json[GetJobRequest]('{"name":"projects/demo/locations/us-central1/jobs/secret-job"}'),
        reactor,
    )
except e:
    raised = String(e)
assert_true(raised.startswith("GET GetJob: HTTP 404, NOT_FOUND (code 5)"))
assert_false("secret-job" in raised)
assert_equal(gcp_status_error_code("GET", "GetJob", raised), CODE_NOT_FOUND)
```
