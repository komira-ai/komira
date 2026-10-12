# komira_gcp_serviceusage

A Service Usage v1 client, generated at build time from the googleapis
protos (`google/api/serviceusage/v1`) over REST/JSON. `ServiceUsageClient`
carries three methods: `enable_service` and `disable_service` (turn an API
on or off for a project) and `get_service` (read whether it is on).

Enabling and disabling are long-running: each returns the google.longrunning
`Operation` as read (still running, done with a `response`, or done with an
`error` status), its payloads kept as opaque `Any` values. Nothing here polls
the operation; a caller converges by reading `get_service` until its `state`
is `ENABLED`. A `Service`'s `config` is not generated, so a read skips it.

The client sends through a komira_http_client `HttpClient` over the
komira_http_core `Connector` it is given, asks a komira_gcp_core
`GcpTokenSource` for one bearer token per request, and raises a non-2xx
answer through komira_gcp_core's `gcp_status_error`, which never quotes the
body. It starts at `serviceusage.googleapis.com`; `set_rest_host` points it
elsewhere. It reads no environment. ListServices, the batch methods and the
Operations service are not generated.

## Examples

The examples send through komira_http_core's `ScriptedConnector`, which
answers from a canned response and captures the bytes the client wrote; no
socket is opened. The client is pointed at `localhost` so nothing is looked
up in DNS.

Enable an API for a project. The name rides the path, so the body is empty;
the answer is an operation still running:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_serviceusage.resources import State
from komira_gcp_serviceusage.serviceusage import EnableServiceRequest, GetServiceRequest, ServiceUsageClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]
comptime RUN_API = "projects/demo-project/services/run.googleapis.com"


def usage_answering(body: String, sent: ArcPointer[List[UInt8]]) raises -> ServiceUsageClient[ScriptedConnector, StaticTokenSource]:
    """A client whose one request is answered 200 with `body`."""
    var text = (
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var reply = List[UInt8]()
    reply.extend(Span(text.as_bytes()))
    var client = ServiceUsageClient[ScriptedConnector, StaticTokenSource](
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
var client = usage_answering(
    String('{"name":"operations/op-1","metadata":{"@type":')
    + '"type.googleapis.com/google.api.serviceusage.v1.OperationMetadata"}}',
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var operation = client.enable_service[Runtime](EnableServiceRequest(String(RUN_API)), reactor)

var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "POST /v1/projects/demo-project/services/run.googleapis.com:enable HTTP/1.1\r\n"
))
assert_true(wire.endswith("\r\n\r\n{}"))
assert_equal(operation.name, "operations/op-1")
assert_false(operation.done)
assert_false(Bool(operation.error))
```

Read whether it is on. The answer's `config` is skipped; the name, parent
and state are read:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_serviceusage.resources import State
from komira_gcp_serviceusage.serviceusage import GetServiceRequest, ServiceUsageClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime RUN_API = "projects/demo-project/services/run.googleapis.com"

def usage_answering(body: String, sent: ArcPointer[List[UInt8]]) raises -> ServiceUsageClient[ScriptedConnector, StaticTokenSource]:
    """A client whose one request is answered 200 with `body`."""
    var text = (
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var reply = List[UInt8]()
    reply.extend(Span(text.as_bytes()))
    var client = ServiceUsageClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(reply^, sent)
            )
        ),
        StaticTokenSource(String("a-token")),
    )
    client.set_rest_host(String("localhost"))
    return client^
-->
```mojo
var get_sent = ArcPointer[List[UInt8]](List[UInt8]())
var reader = usage_answering(
    String('{"name":"projects/123456789012/services/run.googleapis.com",')
    + '"config":{"name":"run.googleapis.com","title":"Cloud Run Admin API"},'
    + '"state":"ENABLED","parent":"projects/123456789012"}',
    get_sent,
)
var rt2 = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor2 = rt2.reactor()
var service = reader.get_service[Runtime](GetServiceRequest(String(RUN_API)), reactor2)

var get_wire = String(unsafe_from_utf8=Span(get_sent[]))
assert_true(get_wire.startswith(
    "GET /v1/projects/demo-project/services/run.googleapis.com HTTP/1.1\r\n"
))
assert_equal(service.parent, "projects/123456789012")
assert_true(service.state == State(State.ENABLED))
```
