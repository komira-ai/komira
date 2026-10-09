# komira_aws_lambda_http

Run a `komira_http_server` `RequestDispatcher` on AWS Lambda behind API
Gateway, without the dispatcher learning it is on Lambda. The package
converts between Lambda's event payloads and the `HttpRequest` /
`HttpResponse` of `komira_http_core`, and drives the invoke loop:

- `api_gateway_v2_event_to_request` / `response_to_api_gateway_v2`: the API
  Gateway payload-format-2.0 proxy event to an `HttpRequest`, and an
  `HttpResponse` back to the JSON API Gateway expects. A 1.0 event is
  refused. The body's base64 flag is honoured inbound and derived from the
  bytes outbound; `Set-Cookie` goes out as the `cookies` array. A Lambda
  authorizer's context reaches the handler as headers under a prefix the
  caller chooses (`AuthorizerHeaderPrefix`), and any client header under that
  prefix is dropped on entry, so the context cannot be forged.
- `parse_api_gateway_authorizer_event` / `authorizer_simple_response_json`:
  the REQUEST-authorizer event and its simple response. A deny always
  serializes an empty context.
- `eventbridge_tick_event_to_request` and `classify_lambda_event`: an
  EventBridge Scheduler invoke carrying `{"httpMethod", "path"}` becomes a
  request; `classify_lambda_event` tells it from an API Gateway event by the
  presence of `version`.
- `run_api_gateway_pump`, `run_api_gateway_and_tick_pump` and
  `run_authorizer_pump`: the invoke loops, generic over a
  `LambdaInvocationTransport` (the Lambda Runtime API) and a
  `LambdaPostResponseFlush` (a drain run after the result is posted and
  before the next poll).

It contains no Lambda Runtime API client and no `Runtime` conformer
(`AwsLambdaRuntime` is in `komira_async`); a binary supplies those. It reads
no environment variable.

## Examples

An API Gateway 2.0 proxy event becomes the request a dispatcher takes: the
method from `requestContext.http`, the cookies folded into one header, and
the authorizer's context under the chosen prefix:

<!-- mojo-hidden from std.testing import assert_equal, assert_false -->
```mojo
from komira_aws_lambda_http import AuthorizerHeaderPrefix, api_gateway_v2_event_to_request
from komira_http_core.codec.types import HTTP_METHOD_POST

var event = String(
    '{"version": "2.0", "rawPath": "/api/v1/items", "rawQueryString": "tag=a&tag=b",'
    + '"cookies": ["session=abc", "theme=dark"],'
    + '"headers": {"Content-Type": "application/json", "X-Example-Authz-Plan": "forged"},'
    + '"requestContext": {"http": {"method": "POST"},'
    + '"authorizer": {"lambda": {"subjectId": "subject-1"}}},'
    + '"body": "{\\"n\\": 1}", "isBase64Encoded": false}'
)
var req = api_gateway_v2_event_to_request(event, AuthorizerHeaderPrefix(String("x-example-authz-")))
assert_equal(req.method.code, HTTP_METHOD_POST)
assert_equal(req.path, "/api/v1/items")
assert_equal(req.query_string, "tag=a&tag=b")
assert_equal(req.headers["content-type"], "application/json")
assert_equal(req.headers["cookie"], "session=abc; theme=dark")
assert_equal(req.headers["x-example-authz-subjectid"], "subject-1")
# A client header under the prefix never reaches the handler.
assert_false("x-example-authz-plan" in req.headers)
assert_equal(String(unsafe_from_utf8=Span(req.body)), '{"n": 1}')
```

The response going back: text stays text, and `Set-Cookie` becomes the
`cookies` array, the only channel API Gateway 2.0 honours:

<!-- mojo-hidden from std.testing import assert_equal, assert_false -->
```mojo
from komira_aws_lambda_http import response_to_api_gateway_v2
from komira_http_core.codec.types import HttpResponse
from komira_json import parse_json_value

var res = HttpResponse(status=Int32(201))
res.headers[String("content-type")] = String("application/json")
res.headers[String("set-cookie")] = String("session=abc; HttpOnly")
res.body.extend(Span(String('{"ok": true}').as_bytes()))

var v = parse_json_value(response_to_api_gateway_v2(res^))
assert_equal(v.get(String("statusCode")).text, "201")
assert_equal(v.get(String("body")).as_string(), '{"ok": true}')
assert_false(v.get(String("isBase64Encoded")).as_bool())
assert_equal(v.get(String("cookies")).element_at(0).as_string(), "session=abc; HttpOnly")
assert_false(v.get(String("headers")).has(String("set-cookie")))
```

A REQUEST-authorizer event read, and the two simple responses: an allow
with its context, and a deny, whose context is always empty:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_aws_lambda_http import AUTHZ_ANSWER_ALLOW, AUTHZ_ANSWER_DENY, AuthorizerAnswer, authorizer_simple_response_json, parse_api_gateway_authorizer_event
from komira_json import parse_json_value

var ev = parse_api_gateway_authorizer_event(
    String(
        '{"version": "2.0", "type": "REQUEST", "routeKey": "POST /v1/messages",'
        + '"rawPath": "/v1/messages", "identitySource": ["Bearer tok-live"],'
        + '"headers": {"Authorization": "Bearer tok-live"},'
        + '"requestContext": {"requestId": "gw-req-42", "http": {"method": "POST"}}}'
    )
)
assert_equal(ev.route_key, "POST /v1/messages")
assert_equal(ev.http_method, "POST")
assert_equal(ev.header(String("authorization")), "Bearer tok-live")

var allow = AuthorizerAnswer(AUTHZ_ANSWER_ALLOW)
allow.add_context(String("subject_id"), String("subject-1"))
var yes = parse_json_value(authorizer_simple_response_json(allow))
assert_true(yes.get(String("isAuthorized")).as_bool())
assert_equal(yes.get(String("context")).get(String("subject_id")).as_string(), "subject-1")

var deny = AuthorizerAnswer(AUTHZ_ANSWER_DENY)
deny.add_context(String("subject_id"), String("subject-1"))
var no = parse_json_value(authorizer_simple_response_json(deny))
assert_false(no.get(String("isAuthorized")).as_bool())
assert_false(no.get(String("context")).has(String("subject_id")))
```

A scheduled tick and an API Gateway event told apart by `version`, and the
tick turned into the request it names:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_lambda_http import LAMBDA_EVENT_KIND_API_GATEWAY, LAMBDA_EVENT_KIND_SCHEDULED_TICK, classify_lambda_event, eventbridge_tick_event_to_request
from komira_http_core.codec.types import HTTP_METHOD_POST

var tick = String('{"httpMethod":"POST","path":"/tick/reconcile?full=1"}')
assert_equal(classify_lambda_event(tick), LAMBDA_EVENT_KIND_SCHEDULED_TICK)
assert_equal(
    classify_lambda_event(String('{"version": "2.0", "rawPath": "/x", "requestContext": {"http": {"method": "GET"}}}')),
    LAMBDA_EVENT_KIND_API_GATEWAY,
)
var req = eventbridge_tick_event_to_request(tick)
assert_equal(req.method.code, HTTP_METHOD_POST)
assert_equal(req.path, "/tick/reconcile")
assert_equal(req.query_string, "full=1")
assert_equal(len(req.body), 0)
```
