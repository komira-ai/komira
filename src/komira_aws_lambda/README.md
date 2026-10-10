# komira_aws_lambda

An AWS Lambda client generated at build time from botocore's `lambda`
service model (restJson1), for a function's lifecycle as a deployment drives
it: `CreateFunction`, `GetFunction`, `UpdateFunctionCode`,
`UpdateFunctionConfiguration`, `AddPermission`, `PutFunctionConcurrency`,
`CreateFunctionUrlConfig`, `GetFunctionUrlConfig`,
`UpdateFunctionUrlConfig`, `Invoke` and `DeleteFunction`.

The module `komira_aws_lambda.komira_aws_lambda` has, for each operation, a
request struct (`LambdaGetFunctionRequest`, `LambdaInvocationRequest`, ...),
`build_<op>_request` (the exact `komira_aws_core.AwsRequest`: method, a path
carrying the operation's own API date such as `/2015-03-31/functions/...`,
query, headers and body; the model's bounds are checked before a request
exists), `parse_<op>_response` and `resolve_<op>_endpoint` (the service's
published endpoint ruleset, embedded in the module, over a
`LambdaEndpointConfig`). `LambdaClient[C, S]` puts them together: each call
resolves its endpoint, signs with SigV4 (signing name `lambda`) using the
credentials source `S`, sends over the `komira_http_core` `Connector` `C` it
is given, retries as the AWS SDKs' standard mode does, and returns the
decoded result or raises `<Operation> failed: HTTP <status> <code>
<message>`.

`Invoke`'s payload is the request body as given, and the function's answer
is the response body. A function that ran and failed is not a failed call:
Lambda answers 200 and names the failure in `X-Amz-Function-Error`, which
`invoke` returns as `function_error`. The package reads no environment
variable and no credential file, and it does not package or upload code.

## Examples

Requests, exactly as they go on the wire: a `GetFunction` by ARN (the `:`
of the ARN percent-encoded in the path), an `Invoke` whose payload is the
body, and a name the model's bounds refuse:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_lambda.komira_aws_lambda import LambdaGetFunctionRequest, LambdaInvocationRequest, build_get_function_request, build_invoke_request

var get = LambdaGetFunctionRequest(String("arn:aws:lambda:us-east-1:123456789012:function:jobs"))
get.set_qualifier(String("live"))
var req = build_get_function_request(get)
assert_equal(req.method, "GET")
assert_equal(
    req.uri,
    "/2015-03-31/functions/arn%3Aaws%3Alambda%3Aus-east-1%3A123456789012%3Afunction%3Ajobs?Qualifier=live",
)
assert_equal(len(req.body), 0)

var invoke = LambdaInvocationRequest(String("jobs"))
invoke.set_invocation_type(String("RequestResponse"))
var payload = List[UInt8]()
payload.extend(Span(String('{"rawPath":"/healthz"}').as_bytes()))
invoke.set_payload(payload^)
var call = build_invoke_request(invoke)
assert_equal(call.method, "POST")
assert_equal(call.uri, "/2015-03-31/functions/jobs/invocations")
assert_equal(call.header(String("X-Amz-Invocation-Type")), "RequestResponse")
assert_equal(call.header(String("Content-Type")), "application/octet-stream")
assert_equal(call.body_text(), '{"rawPath":"/healthz"}')

# `FunctionName` has a minimum length of 1 in the model.
with assert_raises(contains="FunctionName"):
    _ = build_get_function_request(LambdaGetFunctionRequest(String("")))
```

Where a call goes, from the endpoint ruleset:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_lambda.komira_aws_lambda import LambdaEndpointConfig, LambdaGetFunctionRequest, komira_aws_lambda_endpoint_rules, resolve_get_function_endpoint

var rules = komira_aws_lambda_endpoint_rules()
var input = LambdaGetFunctionRequest(String("jobs"))
assert_equal(
    resolve_get_function_endpoint(rules, LambdaEndpointConfig(String("us-west-2")), input).url,
    "https://lambda.us-west-2.amazonaws.com",
)
assert_equal(
    resolve_get_function_endpoint(rules, LambdaEndpointConfig(String("cn-north-1")), input).url,
    "https://lambda.cn-north-1.amazonaws.com.cn",
)
```

The client end to end, with no socket: `komira_http_core`'s
`ScriptedConnector` answers with canned HTTP responses, so each call is
built, resolved, signed, sent, and its answer decoded or raised, all in
memory. A real program passes a connector that dials the network instead.
The second call shows a function that threw: `invoke` returns, with
`function_error` set and the error payload intact.

<!-- mojo-hidden from std.testing import assert_equal, assert_raises, assert_true -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_lambda.komira_aws_lambda import LambdaClient, LambdaEndpointConfig, LambdaGetFunctionRequest, LambdaInvocationRequest
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

def _answer(status: Int, reason: String, body: String, headers: String) -> ScriptedStream:
    var text = (
        String("HTTP/1.1 ") + String(status) + " " + reason
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n" + headers + "\r\n" + body
    )
    var raw = List[UInt8]()
    raw.extend(Span(text.as_bytes()))
    return ScriptedStream.from_read_script(raw^)

def _ran() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(200, "OK", '{"statusCode":200,"body":"ok"}', "X-Amz-Executed-Version: $LATEST\r\n")
    )

def _threw() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"errorMessage":"boom","errorType":"Error"}',
            "X-Amz-Executed-Version: $LATEST\r\nX-Amz-Function-Error: Unhandled\r\n",
        )
    )

def _not_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            '{"Type":"User","Message":"Function not found: jobs"}',
            "X-Amzn-Errortype: ResourceNotFoundException\r\n",
        )
    )

def _lambda(mk: def () raises thin -> ScriptedConnector) raises -> LambdaClient[ScriptedConnector, StaticCredsSource]:
    # A custom endpoint: the scripted connector is plain HTTP and dials nothing.
    var config = LambdaEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return LambdaClient[ScriptedConnector, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential(String("AKIDEXAMPLE"), String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), String(""))),
        String("us-east-1"),
        config^,
    )

def _health_check() -> LambdaInvocationRequest:
    var input = LambdaInvocationRequest(String("jobs"))
    input.set_invocation_type(String("RequestResponse"))
    var payload = List[UInt8]()
    payload.extend(Span(String('{"rawPath":"/healthz"}').as_bytes()))
    input.set_payload(payload^)
    return input^

var client = _lambda(_ran)
var out = client.invoke(_health_check())
assert_equal(out.status_code.value(), Int32(200))
assert_equal(out.executed_version.value(), "$LATEST")
assert_equal(String(unsafe_from_utf8=Span(out.payload.value())), '{"statusCode":200,"body":"ok"}')
assert_true(not out.function_error)

var failed = _lambda(_threw)
var err = failed.invoke(_health_check())
assert_equal(err.function_error.value(), "Unhandled")
assert_equal(String(unsafe_from_utf8=Span(err.payload.value())), '{"errorMessage":"boom","errorType":"Error"}')

var missing = _lambda(_not_found)
with assert_raises(contains="GetFunction failed: HTTP 404 ResourceNotFoundException Function not found: jobs"):
    _ = missing.get_function(LambdaGetFunctionRequest(String("jobs")))
```
