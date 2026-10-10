# komira_gcp_run

Cloud Run Admin v2 clients, generated at build time from the googleapis
protos (`google/cloud/run/v2`) over REST/JSON:

- `ServicesClient`: create, get, list, update in place and delete a service,
  and read and write its IAM policy (who may invoke it);
- `RevisionsClient`: list and delete revisions (a keep-last-N prune);
- `JobsClient`: create, get, list, update, delete and run a job, a run
  taking per-run argument and environment overrides, and read and write its
  IAM policy (who may run it);
- `WorkerPoolsClient`: create, get, list, update in place and delete a
  worker pool (a background worker: containers with no ingress);
- `ExecutionsClient`: read and cancel the execution a run started;
- `OperationsClient`: read or wait on the long-running operation every
  mutating method returns, at Run's own operation paths.

Each sends through a komira_http_client `HttpClient` over the
komira_http_core `Connector` it is given, asks a komira_gcp_core
`GcpTokenSource` for one bearer token per request, and raises a non-2xx
answer through komira_gcp_core's `gcp_status_error`, which never quotes the
body. Every client starts at `run.googleapis.com` (a resource's region is
part of its name); `set_rest_host` points it elsewhere. The request and
response types are generated with them, and a request can be written as
its proto3 JSON and read with komira_proto_codec's `decode_json`. The
package reads no environment.

No other method of these services is generated. A mutating method returns the operation; nothing
here polls it on its own.

## Examples

The examples send through komira_http_core's `ScriptedConnector`, which
answers from a canned response and captures the bytes the client wrote; no
socket is opened. Each client is pointed at `localhost` so nothing is
looked up in DNS.

Read a job: the request on the wire and the job decoded.

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_run.condition import Condition_State
from komira_gcp_run.job import GetJobRequest, JobsClient, RunJobRequest
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json

comptime Runtime = BlockingRuntime[NoopSink]
comptime JOB = "projects/demo-project/locations/us-central1/jobs/build"


def jobs_answering(body: String, sent: ArcPointer[List[UInt8]]) raises -> JobsClient[ScriptedConnector, StaticTokenSource]:
    """A JobsClient whose one request is answered 200 with `body`."""
    var text = (
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var reply = List[UInt8]()
    reply.extend(Span(text.as_bytes()))
    var client = JobsClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(reply^, sent)
            )
        ),
        StaticTokenSource(String("a-token")),
    )
    client.set_rest_host(String("localhost"))
    return client^


var sent = ArcPointer[List[UInt8]](List[UInt8]())
var jobs = jobs_answering(
    String('{"name":"') + JOB + '","generation":"2",'
    + '"template":{"taskCount":1,"template":{"containers":[{"image":'
    + '"us-docker.pkg.dev/demo-project/apps/build@sha256:9a8b"}],'
    + '"maxRetries":0,"timeout":"600s"}},'
    + '"terminalCondition":{"type":"Ready","state":"CONDITION_SUCCEEDED"},'
    + '"executionCount":4}',
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var job = jobs.get_job[Runtime](
    decode_json[GetJobRequest](String('{"name":"') + JOB + '"}'), reactor
)

var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(String("GET /v2/") + JOB + " HTTP/1.1\r\nHost: localhost\r\n"))
assert_true("authorization: Bearer a-token\r\n" in wire)

assert_equal(job.name, JOB)
assert_equal(job.generation, Int64(2))  # an int64 arrives as a JSON string
assert_equal(job.execution_count, Int32(4))
ref task = job.template.value().template.value()
assert_equal(task.timeout.value().seconds, Int64(600))
assert_true(
    job.terminal_condition.value().state
    == Condition_State(Condition_State.CONDITION_SUCCEEDED)
)
```

Run it with a per-run argument and environment override. The path field
(`name`) is not repeated in the body, and the answer is the long-running
operation, whose metadata names the execution the run started:

```mojo
var run_sent = ArcPointer[List[UInt8]](List[UInt8]())
var runner = jobs_answering(
    String('{"name":"projects/demo-project/locations/us-central1/operations/7d1c22",')
    + '"metadata":{"@type":"type.googleapis.com/google.cloud.run.v2.Execution",'
    + '"name":"' + JOB + '/executions/build-x7k2p"},"done":false}',
    run_sent,
)
var rt2 = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor2 = rt2.reactor()
var operation = runner.run_job[Runtime](
    decode_json[RunJobRequest](
        String('{"name":"') + JOB + '","overrides":{"containerOverrides":['
        + '{"args":["--commit=4f2a"],"env":[{"name":"STAGE","value":"test"}]}]}}'
    ),
    reactor2,
)

var run_wire = String(unsafe_from_utf8=Span(run_sent[]))
assert_true(run_wire.startswith(String("POST /v2/") + JOB + ":run HTTP/1.1\r\n"))
assert_true(run_wire.endswith(
    '{"overrides":{"containerOverrides":[{"args":["--commit=4f2a"],'
    + '"env":[{"name":"STAGE","value":"test"}]}]}}'
))
assert_false(operation.done)
assert_equal(operation.metadata.value().type_url, "type.googleapis.com/google.cloud.run.v2.Execution")
assert_equal(operation.metadata.value().json_members.children[0].text, String(JOB) + "/executions/build-x7k2p")
```
