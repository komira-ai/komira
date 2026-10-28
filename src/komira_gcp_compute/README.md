# komira_gcp_compute

A REST/JSON client for 39 methods of Google Compute Engine v1, generated at
build time from the pinned googleapis `compute.proto`. Each
`<Service>Client[C, T]` (`InstancesClient`, `ZoneOperationsClient`,
`NetworksClient`, `FirewallsClient`, `BackendServicesClient`, ...) sends
through komira_http_client's `HttpClient` over the komira_http_core
`Connector` it is given, takes each request's bearer token from a
komira_gcp_core `GcpTokenSource`, and raises a non-2xx answer through
komira_gcp_core's `gcp_status_error`. It reads no environment. Every client
starts at `compute.googleapis.com`; `set_rest_host` points it elsewhere.

What is generated: Instances Insert, Get and Delete; ZoneOperations Get and
Wait, RegionOperations and GlobalOperations Wait; Regions Get; Get, Insert
and Delete of Networks and Subnetworks; Firewalls Get, Insert, Patch and
Delete; and Get and Insert (Patch where the load balancer is repointed,
UrlMaps InvalidateCache) of GlobalAddresses, SslCertificates, BackendBuckets,
RegionNetworkEndpointGroups, BackendServices, UrlMaps, TargetHttpProxies,
TargetHttpsProxies and GlobalForwardingRules. Nothing else: no listings, and
no deletes of the load-balancer resources.

Writes answer Compute Engine's own `Operation` (not google.longrunning's):
its `status` is PENDING, RUNNING or DONE, and a failure is `error.errors`
inside a DONE operation, so DONE alone is not success. A write's optional
`requestId` (which makes a retry idempotent on the server) is sent only when
the caller sets it. A Patch sends only the fields set, so it cannot clear a
list. Compute answers errors in the older envelope with no `error.status`,
so the canonical code is the HTTP status's: a 409 for a resource that
already exists is ABORTED, and the raised text carries the envelope's
`reason` (`alreadyExists`).

Every client, request and message is in `komira_gcp_compute.compute`.

## Examples

The examples send over komira_http_core's `ScriptedConnector`, which answers
from a script and records what was written: no socket is opened and
`localhost` needs no name lookup. Inserting a VM sends the `Instance` as the
body, the project and zone in the path, and answers the zonal operation:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import InsertInstanceRequest, Instance, InstancesClient, Operation_Status, WaitZoneOperationRequest, ZoneOperationsClient
from komira_gcp_core import CODE_ABORTED, StaticTokenSource, gcp_status_error_code
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient

comptime Runtime = BlockingRuntime[NoopSink]
comptime Http = HttpClient[ScriptedConnector]

def http_answer(status: String, body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ") + status + "\r\nContent-Type: application/json\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def scripted_http(answer: List[UInt8], sent: ArcPointer[List[UInt8]]) raises -> Http:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), sent)
    return Http.with_defaults(ScriptedConnector.with_stream_tls(stream^))

def token() raises -> StaticTokenSource:
    return StaticTokenSource(String("test-access-token"))

var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = InstancesClient[ScriptedConnector, StaticTokenSource](
    scripted_http(
        http_answer("200 OK", '{"name":"operation-1","operationType":"insert","status":"RUNNING"}'),
        sent,
    ),
    token(),
)
c.set_rest_host(String("localhost"))
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var vm = decode_json_lenient[Instance](
    String('{"name":"vm-1","machineType":"zones/us-central1-a/machineTypes/e2-small"}')
)
var op = c.insert[Runtime](
    InsertInstanceRequest(vm^, String("demo"), None, None, None, String("us-central1-a")),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "POST /compute/v1/projects/demo/zones/us-central1-a/instances HTTP/1.1\r\n"
))
assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire)
assert_true('"name":"vm-1"' in wire)
assert_false('"zone"' in wire)  # path fields are not repeated in the body
assert_equal(op.name.value(), "operation-1")
assert_true(op.status.value() == Operation_Status(Operation_Status.RUNNING))
```

Setting `requestId` (here with `sourceInstanceTemplate`) puts it in the
query; nothing fills one in for the caller:

<!-- mojo-hidden
from std.testing import assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import InsertInstanceRequest, Instance, InstancesClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient

comptime Runtime = BlockingRuntime[NoopSink]

comptime Http = HttpClient[ScriptedConnector]

def http_answer(status: String, body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ") + status + "\r\nContent-Type: application/json\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def scripted_http(answer: List[UInt8], sent: ArcPointer[List[UInt8]]) raises -> Http:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), sent)
    return Http.with_defaults(ScriptedConnector.with_stream_tls(stream^))

def token() raises -> StaticTokenSource:
    return StaticTokenSource(String("test-access-token"))
-->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = InstancesClient[ScriptedConnector, StaticTokenSource](
    scripted_http(http_answer("200 OK", '{"name":"operation-2","status":"PENDING"}'), sent),
    token(),
)
c.set_rest_host(String("localhost"))
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
_ = c.insert[Runtime](
    InsertInstanceRequest(
        decode_json_lenient[Instance](String('{"name":"vm-1"}')),
        String("demo"),
        String("4a1c6f0e-8a7e-4c55-9b61-0f2d1e3c5a7b"),
        String("global/instanceTemplates/worker"),
        None,
        String("us-central1-a"),
    ),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "POST /compute/v1/projects/demo/zones/us-central1-a/instances"
    + "?requestId=4a1c6f0e-8a7e-4c55-9b61-0f2d1e3c5a7b"
    + "&sourceInstanceTemplate=global%2FinstanceTemplates%2Fworker HTTP/1.1\r\n"
))
```

Waiting on an operation: a write that failed comes back as a 200 whose
operation is DONE with `error` set, so the caller reads `error` after DONE:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import Operation_Status, WaitZoneOperationRequest, ZoneOperationsClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime Http = HttpClient[ScriptedConnector]

def http_answer(status: String, body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ") + status + "\r\nContent-Type: application/json\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def scripted_http(answer: List[UInt8], sent: ArcPointer[List[UInt8]]) raises -> Http:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), sent)
    return Http.with_defaults(ScriptedConnector.with_stream_tls(stream^))

def token() raises -> StaticTokenSource:
    return StaticTokenSource(String("test-access-token"))
-->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var ops = ZoneOperationsClient[ScriptedConnector, StaticTokenSource](
    scripted_http(
        http_answer(
            "200 OK",
            '{"name":"operation-1","status":"DONE","httpErrorStatusCode":409,'
            + '"error":{"errors":[{"code":"RESOURCE_ALREADY_EXISTS",'
            + '"message":"The resource already exists"}]}}',
        ),
        sent,
    ),
    token(),
)
ops.set_rest_host(String("localhost"))
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var op = ops.wait[Runtime](
    WaitZoneOperationRequest(String("operation-1"), String("demo"), String("us-central1-a")),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "POST /compute/v1/projects/demo/zones/us-central1-a/operations/operation-1/wait HTTP/1.1\r\n"
))
assert_true(op.status.value() == Operation_Status(Operation_Status.DONE))
assert_equal(op.http_error_status_code.value(), 409)
assert_equal(op.error.value().errors[0].code.value(), "RESOURCE_ALREADY_EXISTS")
```

A non-2xx answer raises. Compute's older envelope names no status, so the
code comes from the HTTP status (409 is ABORTED) and the envelope's
`reason` tells "already exists" apart; no byte of the message is quoted:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import InsertInstanceRequest, Instance, InstancesClient
from komira_gcp_core import CODE_ABORTED, StaticTokenSource, gcp_status_error_code
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient

comptime Runtime = BlockingRuntime[NoopSink]

comptime Http = HttpClient[ScriptedConnector]

def http_answer(status: String, body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ") + status + "\r\nContent-Type: application/json\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def scripted_http(answer: List[UInt8], sent: ArcPointer[List[UInt8]]) raises -> Http:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), sent)
    return Http.with_defaults(ScriptedConnector.with_stream_tls(stream^))

def token() raises -> StaticTokenSource:
    return StaticTokenSource(String("test-access-token"))
-->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = InstancesClient[ScriptedConnector, StaticTokenSource](
    scripted_http(
        http_answer(
            "409 Conflict",
            '{"error":{"code":409,"message":"The resource secret-vm already exists",'
            + '"errors":[{"message":"The resource secret-vm already exists",'
            + '"domain":"global","reason":"alreadyExists"}]}}',
        ),
        sent,
    ),
    token(),
)
c.set_rest_host(String("localhost"))
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var raised = String()
try:
    _ = c.insert[Runtime](
        InsertInstanceRequest(
            decode_json_lenient[Instance](String('{"name":"secret-vm"}')),
            String("demo"), None, None, None, String("us-central1-a"),
        ),
        reactor,
    )
except e:
    raised = String(e)
assert_true(raised.startswith("POST Insert: HTTP 409, ABORTED (code 10), reason alreadyExists, "))
assert_false("secret-vm" in raised)
assert_equal(gcp_status_error_code("POST", "Insert", raised), CODE_ABORTED)
```
