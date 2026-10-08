# komira_gcp_cloudresourcemanager

A REST/JSON client for the Projects service of Google Cloud Resource Manager
v3, generated at build time from the pinned googleapis protos.
`ProjectsClient[C, T]` sends through komira_http_client's `HttpClient` over
the komira_http_core `Connector` it is given, takes each request's bearer
token from a komira_gcp_core `GcpTokenSource`, and raises a non-2xx answer
through komira_gcp_core's `gcp_status_error`. It reads no environment.

Four methods are generated: GetProject (resolves a project id to its number,
`projects/<number>`), GetIamPolicy, SetIamPolicy and TestIamPermissions. Not
generated: listing, searching, creating, updating, moving, deleting and
undeleting projects, and the Folders, Organizations and tag services.

A policy change is a read-modify-write: read the policy with GetIamPolicy,
change the bindings, send it back with SetIamPolicy. The client passes the
etag through untouched and invents none, so a policy changed since the read
is refused with 409 `ABORTED`, which the caller answers by reading again.

The client is in `komira_gcp_cloudresourcemanager.projects`, the policy
requests in `.iam_policy`, `Policy` and `Binding` in `.policy` and
`GetPolicyOptions` in `.options`.

## Examples

The examples send over komira_http_core's `ScriptedConnector`, which answers
from a script and records what was written: no socket is opened and
`localhost` needs no name lookup. Reading a project by its id answers with
its number:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_cloudresourcemanager.iam_policy import GetIamPolicyRequest, SetIamPolicyRequest
from komira_gcp_cloudresourcemanager.options import GetPolicyOptions
from komira_gcp_cloudresourcemanager.policy import Policy
from komira_gcp_cloudresourcemanager.projects import GetProjectRequest, Project_State, ProjectsClient
from komira_gcp_core import CODE_ABORTED, StaticTokenSource, gcp_status_error_code
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient

comptime Runtime = BlockingRuntime[NoopSink]
comptime Client = ProjectsClient[ScriptedConnector, StaticTokenSource]

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
def policy_json() -> String:
    return (
        String('{"version":1,"etag":"BwXhqDuVJ8g=","bindings":[')
        + '{"role":"roles/run.invoker","members":["serviceAccount:caller@example.com"]},'
        + '{"role":"roles/viewer","members":["group:readers@example.com"]}]}'
    )

var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(
    http_answer(
        "200 OK",
        '{"name":"projects/123456789012","projectId":"demo","state":"ACTIVE",'
        + '"labels":{"team":"data"}}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var p = c.get_project[Runtime](GetProjectRequest(String("projects/demo")), reactor)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith("GET /v3/projects/demo HTTP/1.1\r\n"))
assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire)
assert_equal(p.name, "projects/123456789012")
assert_equal(p.project_id, "demo")
assert_true(p.state == Project_State(Project_State.ACTIVE))
assert_equal(p.labels["team"], "data")
```

A name outside the method's path pattern (`projects/*`) is refused before
anything is written:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(http_answer("200 OK", "{}"), sent)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var raised = String()
try:
    _ = c.get_project[Runtime](GetProjectRequest(String("demo")), reactor)
except e:
    raised = String(e)
assert_equal(raised, "path variable `name` does not match `projects/*`")
assert_equal(len(sent[]), 0)
```

The read-modify-write: read the policy (the options ride in the body), drop
the first binding, and write it back; the write carries the etag the read
gave, byte for byte:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
var read_sent = ArcPointer[List[UInt8]](List[UInt8]())
var reader = scripted_client(http_answer("200 OK", policy_json()), read_sent)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var policy = reader.get_iam_policy[Runtime](
    GetIamPolicyRequest(String("projects/demo"), GetPolicyOptions(Int32(3))), reactor
)
var read_wire = String(unsafe_from_utf8=Span(read_sent[]))
assert_true(read_wire.startswith("POST /v3/projects/demo:getIamPolicy HTTP/1.1\r\n"))
assert_true(read_wire.endswith('\r\n\r\n{"options":{"requestedPolicyVersion":3}}'))
assert_equal(len(policy.bindings), 2)
_ = policy.bindings.pop(0)

var write_sent = ArcPointer[List[UInt8]](List[UInt8]())
var writer = scripted_client(http_answer("200 OK", policy_json()), write_sent)
_ = writer.set_iam_policy[Runtime](
    SetIamPolicyRequest(String("projects/demo"), policy^, None), reactor
)
var write_wire = String(unsafe_from_utf8=Span(write_sent[]))
assert_true(write_wire.startswith("POST /v3/projects/demo:setIamPolicy HTTP/1.1\r\n"))
assert_true(write_wire.endswith(
    '\r\n\r\n{"policy":{"version":1,"bindings":['
    + '{"role":"roles/viewer","members":["group:readers@example.com"]}],'
    + '"etag":"BwXhqDuVJ8g="}}'
))
```

A write over a stale etag is answered 409 `ABORTED`. The error names the
verb, the method, the HTTP status and the canonical code, and quotes no byte
of the body (here, neither etag); `gcp_status_error_code` reads the code
back, so a caller knows to read again:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(
    http_answer(
        "409 Conflict",
        '{"error":{"code":409,"message":"There were concurrent policy changes.'
        + " The request's ETag 'BwXhqDuVJ8g=' did not match the current policy's"
        + " ETag 'BwXhqEc2a1U='.\",\"status\":\"ABORTED\"}}",
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var raised = String()
try:
    var stale = decode_json_lenient[Policy](policy_json())
    _ = c.set_iam_policy[Runtime](SetIamPolicyRequest(String("projects/demo"), stale^, None), reactor)
except e:
    raised = String(e)
assert_true(raised.startswith("POST SetIamPolicy: HTTP 409, ABORTED (code 10)"))
assert_false("BwXh" in raised)
assert_equal(gcp_status_error_code("POST", "SetIamPolicy", raised), CODE_ABORTED)
```
