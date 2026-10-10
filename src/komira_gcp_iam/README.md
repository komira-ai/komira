# komira_gcp_iam

A REST/JSON client for Google Cloud IAM v1 (the admin API at
`iam.googleapis.com`), generated at build time from the pinned googleapis
protos. `IAMClient[C, T]` sends through komira_http_client's `HttpClient`
over the komira_http_core `Connector` it is given, takes each request's
bearer token from a komira_gcp_core `GcpTokenSource`, and raises a non-2xx
answer through komira_gcp_core's `gcp_status_error`. It reads no
environment.

Ten methods are generated on `IAMClient`: ListServiceAccounts,
GetServiceAccount, CreateServiceAccount and DeleteServiceAccount;
GetIamPolicy and SetIamPolicy on a service account; GetRole, CreateRole,
UpdateRole and DeleteRole. One more is on `WorkloadIdentityPoolsClient`:
GetWorkloadIdentityPoolProvider (a workload identity provider's issuer,
audiences and attribute condition). The pinned googleapis declares the
workload identity pools only at v1beta, so that read is sent to
`/v1beta/projects/*/locations/*/workloadIdentityPools/*/providers/*` on
`iam.googleapis.com`, and its `WorkloadIdentityPoolProvider` carries the
fields the v1beta file declares. Not generated: service-account keys,
SignBlob and SignJwt, account updates (PatchServiceAccount binds a field of
the body into its path with the whole request as the body, which the
generator refuses), enabling, disabling and undeleting, ListRoles,
UndeleteRole, the query methods, LintPolicy, TestIamPermissions, and every
other workload identity pool and provider method. There is no IAM
Credentials client here (komira_gcp_core mints tokens itself).

A role method with more than one path binding (`roles/<id>`,
`organizations/<org>/roles/<id>`, `projects/<project>/roles/<id>`) is sent
to the first binding the name matches, and a name matching none is refused
before anything is sent: a predefined role cannot be created, updated or
deleted. A policy change is a read-modify-write that carries the etag it
read; the client invents none.

The client, accounts and roles are in `komira_gcp_iam.iam`, the policy
requests in `.iam_policy`, `Policy` in `.policy`, and
`WorkloadIdentityPoolsClient` with the provider and its request in
`.workload_identity_pool`.

## Examples

The examples send over komira_http_core's `ScriptedConnector`, which answers
from a script and records what was written: no socket is opened and
`localhost` needs no name lookup. Their service accounts are under the
reserved `example.com` domain (a real one is
`<account id>@<project>.iam.gserviceaccount.com`; the client sends the
address as written and checks no shape). Creating a service account: the
parent is in the path, the account id and account in the body:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import CODE_NOT_FOUND, StaticTokenSource, gcp_status_error_code
from komira_gcp_iam.iam import CreateServiceAccountRequest, DeleteRoleRequest, GetRoleRequest, GetServiceAccountRequest, IAMClient, ServiceAccount
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient

comptime Runtime = BlockingRuntime[NoopSink]
comptime Client = IAMClient[ScriptedConnector, StaticTokenSource]

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
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(
    http_answer(
        "200 OK",
        '{"name":"projects/demo/serviceAccounts/runner@example.com",'
        + '"projectId":"demo","email":"runner@example.com","displayName":"Runner"}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var account = decode_json_lenient[ServiceAccount](String('{"displayName":"Runner"}'))
var created = c.create_service_account[Runtime](
    CreateServiceAccountRequest(String("projects/demo"), String("runner"), account^),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith("POST /v1/projects/demo/serviceAccounts HTTP/1.1\r\n"))
assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire)
assert_true(wire.endswith(
    '\r\n\r\n{"accountId":"runner","serviceAccount":{"displayName":"Runner"}}'
))
assert_equal(created.email, "runner@example.com")
```

The account's email is one path segment, so its `@` is escaped:

<!-- mojo-hidden
from std.testing import assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_iam.iam import GetServiceAccountRequest, IAMClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime Client = IAMClient[ScriptedConnector, StaticTokenSource]

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
-->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(http_answer("200 OK", '{"email":"runner@example.com"}'), sent)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
_ = c.get_service_account[Runtime](
    GetServiceAccountRequest(String("projects/demo/serviceAccounts/runner@example.com")),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "GET /v1/projects/demo/serviceAccounts/runner%40example.com HTTP/1.1\r\n"
))
```

A role's name picks its binding: a predefined role and a project's custom
role go to different paths, and a predefined role cannot be deleted (no
DeleteRole binding takes it), so that request is refused before anything is
written:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_iam.iam import DeleteRoleRequest, GetRoleRequest, IAMClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime Client = IAMClient[ScriptedConnector, StaticTokenSource]

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
-->
```mojo
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()

var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(http_answer("200 OK", '{"name":"roles/viewer"}'), sent)
_ = c.get_role[Runtime](GetRoleRequest(String("roles/viewer")), reactor)
assert_true(String(unsafe_from_utf8=Span(sent[])).startswith("GET /v1/roles/viewer HTTP/1.1\r\n"))

var sent2 = ArcPointer[List[UInt8]](List[UInt8]())
var c2 = scripted_client(http_answer("200 OK", '{"name":"projects/demo/roles/deployer"}'), sent2)
_ = c2.get_role[Runtime](GetRoleRequest(String("projects/demo/roles/deployer")), reactor)
assert_true(String(unsafe_from_utf8=Span(sent2[])).startswith(
    "GET /v1/projects/demo/roles/deployer HTTP/1.1\r\n"
))

var sent3 = ArcPointer[List[UInt8]](List[UInt8]())
var c3 = scripted_client(http_answer("200 OK", "{}"), sent3)
var raised = String()
try:
    _ = c3.delete_role[Runtime](DeleteRoleRequest(String("roles/viewer"), List[UInt8]()), reactor)
except e:
    raised = String(e)
assert_equal(
    raised,
    "REST method DeleteRole: the request matches none of its paths:"
    + " /v1/{name=organizations/*/roles/*}, /v1/{name=projects/*/roles/*}",
)
assert_equal(len(sent3[]), 0)
```

A non-2xx answer raises. The error names the verb, the method, the HTTP
status and the canonical code from the `google.rpc.Status` envelope, and
quotes no byte of the body; `gcp_status_error_code` reads the code back:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import CODE_NOT_FOUND, StaticTokenSource, gcp_status_error_code
from komira_gcp_iam.iam import GetServiceAccountRequest, IAMClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime Client = IAMClient[ScriptedConnector, StaticTokenSource]

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
-->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(
    http_answer(
        "404 Not Found",
        '{"error":{"code":404,"message":"Unknown service account secret-sa","status":"NOT_FOUND"}}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var raised = String()
try:
    _ = c.get_service_account[Runtime](
        GetServiceAccountRequest(String("projects/demo/serviceAccounts/secret-sa@example.com")),
        reactor,
    )
except e:
    raised = String(e)
assert_true(raised.startswith("GET GetServiceAccount: HTTP 404, NOT_FOUND (code 5)"))
assert_false("secret-sa" in raised)
assert_equal(gcp_status_error_code("GET", "GetServiceAccount", raised), CODE_NOT_FOUND)
```
