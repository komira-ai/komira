# komira_gcp_artifactregistry

A REST/JSON client for Google Cloud Artifact Registry v1, generated at build
time from the pinned googleapis protos. `ArtifactRegistryClient[C, T]` sends
through komira_http_client's `HttpClient` over the komira_http_core
`Connector` it is given, takes each request's bearer token from a
komira_gcp_core `GcpTokenSource`, and raises a non-2xx answer through
komira_gcp_core's `gcp_status_error`. It reads no environment.

Seven methods are generated: CreateRepository, GetRepository,
DeleteRepository, ListRepositories, GetFile (a file's size and hashes), and
GetIamPolicy and SetIamPolicy on a repository (a read-modify-write that
carries the etag it read; GetIamPolicy asks for its policy version in the
query as `options.requestedPolicyVersion`). Not generated:
TestIamPermissions, Docker images, packages, versions, tags, rules,
settings, the file listing, and the operation poll:
CreateRepository and DeleteRepository answer a google.longrunning
`Operation`, and this package cannot follow it. The client starts at
`artifactregistry.googleapis.com`; a regional endpoint is named with
`set_rest_host`.

The client is in `komira_gcp_artifactregistry.service`, the repository
messages in `.repository`, the file messages in `.file`, `Operation` in
`.operations`, the policy requests in `.iam_policy` and `Policy` in
`.policy`.

## Examples

The examples send over komira_http_core's `ScriptedConnector`, which answers
from a script and records what was written: no socket is opened and
`localhost` needs no name lookup. Reading a repository back: the request
line and bearer header the client wrote, and the answer decoded into a
`Repository`:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_artifactregistry.repository import GetRepositoryRequest, ListRepositoriesRequest, Repository_Format
from komira_gcp_artifactregistry.service import ArtifactRegistryClient
from komira_gcp_core import CODE_PERMISSION_DENIED, StaticTokenSource, gcp_status_error_code
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]
comptime Client = ArtifactRegistryClient[ScriptedConnector, StaticTokenSource]

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
        '{"name":"projects/demo/locations/us-central1/repositories/images",'
        + '"format":"DOCKER","registryUri":"us-central1-docker.pkg.dev/demo/images"}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var repo = c.get_repository[Runtime](
    GetRepositoryRequest(String("projects/demo/locations/us-central1/repositories/images")),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "GET /v1/projects/demo/locations/us-central1/repositories/images HTTP/1.1\r\n"
))
assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire)
assert_true(repo.format == Repository_Format(Repository_Format.DOCKER))
assert_equal(repo.registry_uri, "us-central1-docker.pkg.dev/demo/images")
```

Listing repositories: a field at its default value (here the empty page
token) stays out of the query, and the page's `nextPageToken` is decoded:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_artifactregistry.repository import ListRepositoriesRequest
from komira_gcp_artifactregistry.service import ArtifactRegistryClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime Client = ArtifactRegistryClient[ScriptedConnector, StaticTokenSource]

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
        "200 OK",
        '{"repositories":[{"name":"projects/demo/locations/us-central1/repositories/images",'
        + '"format":"DOCKER"}],"nextPageToken":"tok-2"}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var page = c.list_repositories[Runtime](
    ListRepositoriesRequest(
        String("projects/demo/locations/us-central1"), Int32(50), String(""), String(""), String("")
    ),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "GET /v1/projects/demo/locations/us-central1/repositories?pageSize=50 HTTP/1.1\r\n"
))
assert_equal(len(page.repositories), 1)
assert_equal(page.next_page_token, "tok-2")
```

A resource name outside the method's path pattern
(`projects/*/locations/*/repositories/*`) is refused before anything is
written:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_artifactregistry.repository import GetRepositoryRequest
from komira_gcp_artifactregistry.service import ArtifactRegistryClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime Client = ArtifactRegistryClient[ScriptedConnector, StaticTokenSource]

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
var c = scripted_client(http_answer("200 OK", "{}"), sent)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var refused = False
try:
    _ = c.get_repository[Runtime](
        GetRepositoryRequest(String("projects/demo/repositories/images")), reactor
    )
except:
    refused = True
assert_true(refused)
assert_equal(len(sent[]), 0)
```

A non-2xx answer raises. The error names the verb, the method, the HTTP
status and the canonical code from the `google.rpc.Status` envelope, and
quotes no byte of the body; `gcp_status_error_code` reads the code back:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_artifactregistry.repository import GetRepositoryRequest
from komira_gcp_artifactregistry.service import ArtifactRegistryClient
from komira_gcp_core import CODE_PERMISSION_DENIED, StaticTokenSource, gcp_status_error_code
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime Client = ArtifactRegistryClient[ScriptedConnector, StaticTokenSource]

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
        "403 Forbidden",
        '{"error":{"code":403,"message":"Permission denied on secret-repo",'
        + '"status":"PERMISSION_DENIED"}}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var raised = String()
try:
    _ = c.get_repository[Runtime](
        GetRepositoryRequest(String("projects/demo/locations/us-central1/repositories/secret-repo")),
        reactor,
    )
except e:
    raised = String(e)
assert_true(raised.startswith("GET GetRepository: HTTP 403, PERMISSION_DENIED (code 7)"))
assert_false("secret-repo" in raised)
assert_equal(gcp_status_error_code("GET", "GetRepository", raised), CODE_PERMISSION_DENIED)
```
