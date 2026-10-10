# `komira_gcp_fcm`

## Responsibility

Firebase Cloud Messaging HTTP v1 `messages:send` of a content-blind wake to
one device: the message says which item changed (`id`), what kind of event
it was (`kind`) and which service holds it (`source`), and nothing else. The
device fetches the content itself, over its own authenticated channel.

- The request: the JSON body (a data-only message with Android priority
  `HIGH`) and the path `/v1/projects/<project>/messages:send`, with the
  project id checked so that it cannot redirect the request.
- The answer, read as one of four outcomes: ACCEPTED (2xx), DEAD (HTTP 404, or
  FcmError `UNREGISTERED`: drop the token), TRANSIENT (429, 5xx, or no answer
  at all: retry, after the server's delay when it gave one) or REFUSED (any
  other status). An outcome's detail names the status, the codes and byte
  counts, never text from the body.
- `FcmClient`, which sends over komira_http_client with a bearer token from a
  komira_gcp_core `GcpTokenSource` (Application Default Credentials with the
  `firebase.messaging` scope in production).

FCM v1 has no googleapis proto, so the one REST call is written here. The
package reads no environment itself; the Application Default Credentials
entry reads the variables komira_gcp_core documents.

## API

Everything is exported from `komira_gcp_fcm`:

- `FcmWake(id, kind, source)`; `fcm_message_json(device_token, wake)`, the
  request body; `fcm_send_path(project_id)` and `check_project_id`.
- `classify_fcm_response(http_status, retry_after_s, body)` returns an
  `FcmOutcome` (`kind`, `http_status`, `message_name`, `fcm_error`,
  `retry_after_ms`, `detail`, and `is_accepted()`, `is_dead()`,
  `is_transient()`, `is_refused()`); `fcm_error_code(body)` reads the
  FcmError code; `fcm_outcome_name(kind)` names `FCM_ACCEPTED`, `FCM_DEAD`,
  `FCM_TRANSIENT` and `FCM_REFUSED`.
- `send_failure_outcome(error_text)`: what a send that got no answer means;
  `token_mint_error(error_text)`: the error a send raises when no token could
  be had, keeping only the HTTP status of the token source's error.
- `FcmClient[C, T](http, tokens, project_id, endpoint)` and its
  `send_one(device_token, wake)`; `FcmEndpoint.public()`,
  `FcmEndpoint.https(host, port)` and `FcmEndpoint.loopback_plaintext(port)`
  (a fake FCM in a test).
- `fcm_application_default_token_source(...)`, and `fcm_adc_options()`,
  which asks for `FCM_SCOPE` and nothing else.

## Examples

Every example below runs as a test when the package is built. None opens a
connection or needs credentials.

The request a send writes: the wake is the whole `data` map, and the project
id is checked before it is spliced into the path:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_gcp_fcm import FCM_HOST, FCM_PORT, FCM_SCOPE, FcmEndpoint, FcmWake, check_project_id, fcm_adc_options, fcm_message_json, fcm_send_path

var wake = FcmWake(String("evt-0001"), String("job.failed"), String("jobs.example.com"))
assert_equal(
    fcm_message_json(String("device-token-1"), wake),
    '{"message":{"token":"device-token-1","data":{"id":"evt-0001","kind":"job.failed",'
    + '"source":"jobs.example.com"},"android":{"priority":"HIGH"}}}',
)
assert_equal(fcm_send_path(String("demo-project")), "/v1/projects/demo-project/messages:send")

def refusal(project_id: String) -> String:
    try:
        check_project_id(project_id)
    except e:
        return String(e)
    return String()

assert_equal(refusal(String("demo-project")), "")
assert_equal(refusal(String("p/../other")), "komira_gcp_fcm: the project id holds a byte outside [a-z0-9.:-]")
assert_equal(refusal(String("..")), "komira_gcp_fcm: the project id does not start with [a-z0-9]")

var empty_field = String()
try:
    _ = fcm_message_json(String("device-token-1"), FcmWake(String(""), String("job.failed"), String("jobs")))
except e:
    empty_field = String(e)
assert_equal(empty_field, "komira_gcp_fcm: the wake id is empty")

var endpoint = FcmEndpoint.public()
assert_equal(endpoint.host, FCM_HOST)
assert_equal(endpoint.port, FCM_PORT)
assert_true(endpoint.tls)
assert_equal(len(fcm_adc_options().scopes), 1)
assert_equal(fcm_adc_options().scopes[0], FCM_SCOPE)
```

Reading the answer. The caller acts on the kind: keep the token, drop it, or
retry after `retry_after_ms`. The detail never repeats the body's text:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_gcp_fcm import FCM_DEAD, FCM_ERROR_TYPE, classify_fcm_response, fcm_error_code, fcm_outcome_name

def body_of(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def fcm_error(status: Int, name: String, code: String) -> List[UInt8]:
    return body_of(
        '{"error":{"code":' + String(status) + ',"message":"token secret-abc is not registered",'
        + '"status":"' + name + '","details":[{"@type":"' + FCM_ERROR_TYPE + '","errorCode":"' + code + '"}]}}'
    )

var accepted = classify_fcm_response(200, -1, body_of('{"name":"projects/demo-project/messages/0:1"}'))
assert_true(accepted.is_accepted())
assert_equal(accepted.message_name, "projects/demo-project/messages/0:1")

var gone = classify_fcm_response(404, -1, fcm_error(404, "NOT_FOUND", "UNREGISTERED"))
assert_true(gone.is_dead())
assert_equal(fcm_outcome_name(gone.kind), fcm_outcome_name(FCM_DEAD))
assert_equal(gone.fcm_error, "UNREGISTERED")
assert_false("secret-abc" in gone.detail)

# UNREGISTERED means the token is dead whatever the status.
assert_true(classify_fcm_response(400, -1, fcm_error(400, "INVALID_ARGUMENT", "UNREGISTERED")).is_dead())
assert_equal(fcm_error_code(fcm_error(400, "INVALID_ARGUMENT", "UNREGISTERED")), "UNREGISTERED")

var busy = classify_fcm_response(503, 30, fcm_error(503, "UNAVAILABLE", "UNAVAILABLE"))
assert_true(busy.is_transient())
assert_equal(busy.retry_after_ms, Int64(30_000))

var forbidden = classify_fcm_response(403, -1, fcm_error(403, "PERMISSION_DENIED", "SENDER_ID_MISMATCH"))
assert_true(forbidden.is_refused())
assert_equal(forbidden.retry_after_ms, Int64(-1))
```

A send that got no answer is TRANSIENT, except a URL the connector cannot
dial (every send would fail the same way), which raises. A token source's
error is cut down to its HTTP status:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_gcp_fcm import send_failure_outcome, token_mint_error

var no_answer = send_failure_outcome(String("HttpError[CONNECT_FAILED]: connection refused"))
assert_true(no_answer.is_transient())
assert_equal(no_answer.http_status, 0)
assert_equal(no_answer.detail, "POST FirebaseMessaging.SendMessage: no answer, HttpError[CONNECT_FAILED]")

var raised = False
try:
    _ = send_failure_outcome(String("HttpError[URL_INVALID]: https over a plaintext connector"))
except:
    raised = True
assert_true(raised)

assert_equal(
    String(token_mint_error(String("metadata server answered HTTP 503: {\"secret\":1}"))),
    "komira_gcp_fcm: no access token (HTTP 503); nothing was sent",
)
```

A whole send through `FcmClient`, over komira_http_core's scripted connector
(which answers from a script and records what was written, so nothing
leaves the process) and a fixed token:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from komira_gcp_fcm import FcmWake

def body_of(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^
-->
```mojo
from std.memory import ArcPointer
from komira_gcp_core import StaticTokenSource
from komira_gcp_fcm import FcmClient
from komira_http_client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

var answer_body = String('{"name":"projects/demo-project/messages/0:7"}')
var answer = (
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
    + String(answer_body.byte_length())
    + "\r\nConnection: close\r\n\r\n"
    + answer_body
)
var written = ArcPointer[List[UInt8]](List[UInt8]())
var stream = ScriptedStream.from_read_script_with_capture(body_of(answer), written)
var client = FcmClient[ScriptedConnector, StaticTokenSource](
    HttpClient[ScriptedConnector].with_defaults(ScriptedConnector.with_stream_tls(stream^)),
    StaticTokenSource(String("ya29.example-token")),
    String("demo-project"),
)
var outcome = client.send_one(String("device-token-1"), FcmWake(String("evt-7"), String("job.done"), String("jobs")))
assert_true(outcome.is_accepted())
assert_equal(outcome.message_name, "projects/demo-project/messages/0:7")

var request_bytes = written[].copy()
var request = String(unsafe_from_utf8=Span(request_bytes))
assert_true(request.startswith("POST /v1/projects/demo-project/messages:send "))
assert_true("Bearer ya29.example-token" in request)
assert_true('"data":{"id":"evt-7","kind":"job.done","source":"jobs"}' in request)
```
