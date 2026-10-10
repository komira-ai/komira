# komira_aws_apigatewayv2

An Amazon API Gateway v2 client generated at build time from botocore's
`apigatewayv2` service model (restJson1), for an HTTP API front door's
lifecycle: `CreateApi`, `GetApis`, `GetApi`, `UpdateApi`, `DeleteApi`,
`CreateStage`, `GetStages`, `CreateIntegration`, `GetIntegrations`,
`CreateRoute`, `GetRoutes`, `CreateAuthorizer`, `GetAuthorizers` and
`UpdateAuthorizer`.

The module `komira_aws_apigatewayv2.komira_aws_apigatewayv2` has, for each
operation, a request struct (`ApiGatewayV2CreateApiRequest`, ...),
`build_<op>_request` (the exact `komira_aws_core.AwsRequest`: method, path
under `/v2/apis`, query, and a JSON body whose members travel under their
lowerCamel wire names; the model's bounds are checked before a request
exists), `parse_<op>_response` and `resolve_<op>_endpoint` (the service's
published endpoint ruleset, embedded in the module, over an
`ApiGatewayV2EndpointConfig`). The v2 API is served and signed under the v1
names: the host is `apigateway.<region>` and the signing name `apigateway`.
`ApiGatewayV2Client[C, S]` puts them together: each call resolves its
endpoint, signs with SigV4 using the credentials source `S`, sends over the
`komira_http_core` `Connector` `C` it is given, retries as the AWS SDKs'
standard mode does, and returns the decoded result or raises
`<Operation> failed: HTTP <status> <code> <message>`.

The package reads no environment variable and no credential file. It
manages the API's configuration; it does not serve HTTP traffic.

## Examples

Requests, exactly as they go on the wire:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_apigatewayv2.komira_aws_apigatewayv2 import ApiGatewayV2CreateApiRequest, ApiGatewayV2CreateStageRequest, ApiGatewayV2GetApisRequest, build_create_api_request, build_create_stage_request, build_get_apis_request

var api = ApiGatewayV2CreateApiRequest(String("jobs-edge"), String("HTTP"))
api.set_description(String("front door"))
var req = build_create_api_request(api)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/v2/apis")
assert_equal(req.header(String("Content-Type")), "application/json")
assert_equal(req.body_text(), '{"description":"front door","name":"jobs-edge","protocolType":"HTTP"}')

# `$default` is a stage name, sent in the body.
var stage = ApiGatewayV2CreateStageRequest(String("a1b2c3d4e5"), String("$default"))
stage.set_auto_deploy(True)
var made = build_create_stage_request(stage)
assert_equal(made.uri, "/v2/apis/a1b2c3d4e5/stages")
assert_equal(made.body_text(), '{"autoDeploy":true,"stageName":"$default"}')

# The next page: query values percent-encoded.
var page = ApiGatewayV2GetApisRequest()
page.set_max_results(String("25"))
page.set_next_token(String("tok/2=="))
var listed = build_get_apis_request(page)
assert_equal(listed.method, "GET")
assert_equal(listed.uri, "/v2/apis?maxResults=25&nextToken=tok%2F2%3D%3D")
```

Where a call goes, and what it is signed as, from the endpoint ruleset:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_apigatewayv2.komira_aws_apigatewayv2 import ApiGatewayV2EndpointConfig, ApiGatewayV2GetApisRequest, komira_aws_apigatewayv2_endpoint_rules, resolve_get_apis_endpoint
from komira_aws_core import aws_signing_target

var got = resolve_get_apis_endpoint(
    komira_aws_apigatewayv2_endpoint_rules(),
    ApiGatewayV2EndpointConfig(String("us-west-2")),
    ApiGatewayV2GetApisRequest(),
)
assert_equal(got.url, "https://apigateway.us-west-2.amazonaws.com")
var target = aws_signing_target(got, String("us-west-2"), String("apigateway"))
assert_equal(target.signing_name, "apigateway")
assert_equal(target.signing_region, "us-west-2")
```

The client end to end, with no socket: `komira_http_core`'s
`ScriptedConnector` answers with canned HTTP responses, so each call is
built, resolved, signed, sent, and its answer decoded or raised, all in
memory. A real program passes a connector that dials the network instead.

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_apigatewayv2.komira_aws_apigatewayv2 import ApiGatewayV2Client, ApiGatewayV2CreateApiRequest, ApiGatewayV2EndpointConfig, ApiGatewayV2GetApiRequest
from komira_aws_core import AwsCredential, StaticCredsSource
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

def _created() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            201,
            "Created",
            '{"apiEndpoint":"https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com",'
            + '"apiId":"a1b2c3d4e5","name":"jobs-edge","protocolType":"HTTP"}',
            "",
        )
    )

def _not_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            '{"message":"Invalid API identifier specified 123456789012:gone","resourceType":"Api"}',
            "X-Amzn-Errortype: NotFoundException\r\n",
        )
    )

def _apigw(mk: def () raises thin -> ScriptedConnector) raises -> ApiGatewayV2Client[ScriptedConnector, StaticCredsSource]:
    # A custom endpoint: the scripted connector is plain HTTP and dials nothing.
    var config = ApiGatewayV2EndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return ApiGatewayV2Client[ScriptedConnector, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential(String("AKIDEXAMPLE"), String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), String(""))),
        String("us-east-1"),
        config^,
    )

var client = _apigw(_created)
var out = client.create_api(ApiGatewayV2CreateApiRequest(String("jobs-edge"), String("HTTP")))
assert_equal(out.api_id.value(), "a1b2c3d4e5")
assert_equal(out.api_endpoint.value(), "https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com")

var missing = _apigw(_not_found)
with assert_raises(contains="GetApi failed: HTTP 404 NotFoundException Invalid API identifier specified 123456789012:gone"):
    _ = missing.get_api(ApiGatewayV2GetApiRequest(String("gone")))
```
