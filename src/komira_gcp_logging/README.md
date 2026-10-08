# komira_gcp_logging

A Cloud Logging v2 client, generated at build time from the googleapis protos
(`google/logging/v2`) over REST/JSON. It carries one method,
`LoggingServiceV2Client.list_log_entries` (`POST /v2/entries:list`), which
reads one page of log entries per call; a caller pages by sending the
response's `next_page_token` back as the next request's `page_token`. The
request, response and entry types (`ListLogEntriesRequest`,
`ListLogEntriesResponse`, `LogEntry` with its resource, HTTP request and
severity) are generated alongside it.

The client sends through a komira_http_client `HttpClient` over whatever
komira_http_core `Connector` it is given, asks a komira_gcp_core
`GcpTokenSource` for one bearer token per request, and raises a non-2xx
answer as an error naming the verb, the RPC, the HTTP status and the
canonical code (plus the envelope's `reason` when it is a bare machine
token, and byte counts), never the body's free text. It starts at the service's
declared host, `logging.googleapis.com`; `set_rest_host` points it
elsewhere. It reads no environment.

It does not write, delete or tail logs (WriteLogEntries, DeleteLog,
TailLogEntries and the listings are not generated), does not follow a
redirect, and does not retry.

## Examples

The examples send through komira_http_core's `ScriptedConnector`, which
answers from a canned response and captures the bytes the client wrote; no
socket is opened. The client is pointed at `localhost` so nothing is looked
up in DNS.

One page of entries: the request on the wire and the decoded answer.

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_logging.log_severity import LogSeverity
from komira_gcp_logging.logging import ListLogEntriesRequest, LoggingServiceV2Client
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]


def http_200(body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^


var answer = String(
    '{"entries":[{"logName":"projects/demo-project/logs/app",'
    + '"textPayload":"step 1 of 3","severity":"INFO","insertId":"abc123",'
    + '"timestamp":"2026-09-12T10:00:00Z"}],"nextPageToken":"page-2"}'
)
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var client = LoggingServiceV2Client[ScriptedConnector, StaticTokenSource](
    HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(http_200(answer), sent)
        )
    ),
    StaticTokenSource(String("a-token")),
)
client.set_rest_host(String("localhost"))

var names = List[String]()
names.append(String("projects/demo-project"))
var request = ListLogEntriesRequest(
    names^, String("severity>=INFO"), String("timestamp asc"), Int32(50), String("")
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var page = client.list_log_entries[Runtime](request, reactor)

# The request: one POST with the bearer and the JSON body (a field left at
# its default, here the empty page token, is not sent).
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith("POST /v2/entries:list HTTP/1.1\r\nHost: localhost\r\n"))
assert_true("authorization: Bearer a-token\r\n" in wire)
assert_true(wire.endswith(
    '{"resourceNames":["projects/demo-project"],"filter":"severity>=INFO",'
    + '"orderBy":"timestamp asc","pageSize":50}'
))

# The answer, decoded.
assert_equal(len(page.entries), 1)
assert_equal(page.next_page_token, "page-2")
assert_equal(page.entries[0].text_payload.value(), "step 1 of 3")
assert_equal(page.entries[0].severity.value, LogSeverity.INFO)
assert_equal(page.entries[0].insert_id, "abc123")
```

A refusal raises. The error names the RPC, the HTTP status and the canonical
code, and counts the body's bytes instead of quoting them, so a project
name or filter in the service's message never reaches a log:

```mojo
var denied = String(
    '{"error":{"code":403,"message":"denied on projects/private-name",'
    + '"status":"PERMISSION_DENIED"}}'
)
var text = (
    String("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n")
    + "Content-Length: " + String(denied.byte_length())
    + "\r\nConnection: close\r\n\r\n" + denied
)
var reply = List[UInt8]()
reply.extend(Span(text.as_bytes()))
var refusing = LoggingServiceV2Client[ScriptedConnector, StaticTokenSource](
    HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(reply^))
    ),
    StaticTokenSource(String("a-token")),
)
refusing.set_rest_host(String("localhost"))
var some_names = List[String]()
some_names.append(String("projects/private-name"))
var some_request = ListLogEntriesRequest(
    some_names^, String(""), String("timestamp asc"), Int32(10), String("")
)
var rt2 = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor2 = rt2.reactor()
var error = String("")
try:
    _ = refusing.list_log_entries[Runtime](some_request, reactor2)
except e:
    error = String(e)
assert_true(error.startswith("POST ListLogEntries: HTTP 403, PERMISSION_DENIED (code 7)"))
assert_false("private-name" in error)
```
