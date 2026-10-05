# The generated API Gateway v2 client (`ApiGatewayV2ApiGatewayV2Client`)
# end to end over komira_http_client and komira_http_core's
# ScriptedConnector (no socket).
#
# Every verb meets one error answer and raises it under the restJson1 code
# API Gateway names in `X-Amzn-Errortype`, with the body's `message`: a
# create the service refuses (400) or that conflicts (409), and a read,
# update, nested create or delete under a missing API (404). None is a
# status or code botocore retries, so each call is one request. A create
# and a list are answered successfully.
#
# Then each verb's request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an error naming the
# request head, so each row asserts the request line, the Host the endpoint
# ruleset resolved, the content type of a request with a body, and the
# SigV4 scope: signing name `apigateway`, the v1 name the v2 API is served
# and signed under.
from komira_aws_apigatewayv2.komira_aws_apigatewayv2 import (
    ApiGatewayV2ApiGatewayV2Client,
    ApiGatewayV2CreateApiRequest,
    ApiGatewayV2CreateAuthorizerRequest,
    ApiGatewayV2CreateIntegrationRequest,
    ApiGatewayV2CreateRouteRequest,
    ApiGatewayV2CreateStageRequest,
    ApiGatewayV2DeleteApiRequest,
    ApiGatewayV2EndpointConfig,
    ApiGatewayV2GetApiRequest,
    ApiGatewayV2GetApisRequest,
    ApiGatewayV2GetAuthorizersRequest,
    ApiGatewayV2GetIntegrationsRequest,
    ApiGatewayV2GetRoutesRequest,
    ApiGatewayV2GetStagesRequest,
    ApiGatewayV2UpdateApiRequest,
    ApiGatewayV2UpdateAuthorizerRequest,
)
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsCredential,
    AwsEchoConnector,
    StaticCredsSource,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from std.testing import assert_equal, assert_raises, assert_true


comptime _API = "a1b2c3d4e5"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String, headers: String) -> ScriptedStream:
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 ")
            + String(status)
            + " "
            + reason
            + "\r\nContent-Type: application/json\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + headers
            + "\r\n"
            + body
        )
    )


def _mk_created() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            201,
            "Created",
            '{"apiEndpoint":"https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com",'
            + '"apiId":"a1b2c3d4e5","name":"jobs-edge","protocolType":"HTTP",'
            + '"routeSelectionExpression":"$request.method $request.path"}',
            "",
        )
    )


def _mk_listed() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"items":[{"apiId":"a1b2c3d4e5","name":"jobs-edge","protocolType":"HTTP",'
            + '"routeSelectionExpression":"$request.method $request.path"}],"nextToken":"tok2"}',
            "",
        )
    )


def _mk_not_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            '{"message":"Invalid API identifier specified 123456789012:a1b2c3d4e5","resourceType":"Api"}',
            "X-Amzn-Errortype: NotFoundException\r\n",
        )
    )


def _mk_conflict() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            409,
            "Conflict",
            '{"message":"The resource already exists for this API"}',
            "X-Amzn-Errortype: ConflictException\r\n",
        )
    )


def _mk_bad() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"message":"Invalid request input"}',
            "X-Amzn-Errortype: BadRequestException\r\n",
        )
    )


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.json()


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> ApiGatewayV2ApiGatewayV2Client[C, StaticCredsSource]:
    var config = ApiGatewayV2EndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return ApiGatewayV2ApiGatewayV2Client[C, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(
            AwsCredential(
                String("AKIDEXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                String(""),
            )
        ),
        String("us-east-1"),
        config^,
    )


def _create_api() -> ApiGatewayV2CreateApiRequest:
    return ApiGatewayV2CreateApiRequest(String("jobs-edge"), String("HTTP"))


def _authorizer() -> ApiGatewayV2CreateAuthorizerRequest:
    var input = ApiGatewayV2CreateAuthorizerRequest(
        String(_API), String("REQUEST"), [String("$request.header.Authorization")], String("edge-auth")
    )
    input.set_authorizer_payload_format_version(String("2.0"))
    return input^


def _integration() -> ApiGatewayV2CreateIntegrationRequest:
    var input = ApiGatewayV2CreateIntegrationRequest(String(_API), String("AWS_PROXY"))
    input.set_integration_uri(String("arn:aws:lambda:us-east-1:123456789012:function:jobs"))
    return input^


def _route() -> ApiGatewayV2CreateRouteRequest:
    return ApiGatewayV2CreateRouteRequest(String(_API), String("ANY /{proxy+}"))


def _stage() -> ApiGatewayV2CreateStageRequest:
    return ApiGatewayV2CreateStageRequest(String(_API), String("$default"))


def _update_api() -> ApiGatewayV2UpdateApiRequest:
    var input = ApiGatewayV2UpdateApiRequest(String(_API))
    input.set_description(String("front door"))
    return input^


def _update_authorizer() -> ApiGatewayV2UpdateAuthorizerRequest:
    var input = ApiGatewayV2UpdateAuthorizerRequest(String(_API), String("auth01"))
    input.set_authorizer_result_ttl_in_seconds(Int32(0))
    return input^


# ---- answered ----------------------------------------------------------------


def test_create_api_answered() raises:
    var client = _client(_mk_created)
    var out = client.create_api(_create_api())
    assert_equal(out.api_id.value(), _API)
    assert_equal(out.api_endpoint.value(), "https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com")


def test_get_apis_answered() raises:
    var client = _client(_mk_listed)
    var out = client.get_apis(ApiGatewayV2GetApisRequest())
    assert_equal(out.items.value()[0].api_id.value(), _API)
    assert_equal(out.next_token.value(), "tok2")


# ---- one error per verb ------------------------------------------------------

comptime _MISSING = " failed: HTTP 404 NotFoundException Invalid API identifier specified 123456789012:a1b2c3d4e5"
comptime _CONFLICT = " failed: HTTP 409 ConflictException The resource already exists for this API"
comptime _BAD = " failed: HTTP 400 BadRequestException Invalid request input"


def test_create_api_bad_request() raises:
    var client = _client(_mk_bad)
    with assert_raises(contains=String("CreateApi") + _BAD):
        _ = client.create_api(_create_api())


def test_get_apis_bad_request() raises:
    var client = _client(_mk_bad)
    with assert_raises(contains=String("GetApis") + _BAD):
        _ = client.get_apis(ApiGatewayV2GetApisRequest())


def test_create_authorizer_bad_request() raises:
    var client = _client(_mk_bad)
    with assert_raises(contains=String("CreateAuthorizer") + _BAD):
        _ = client.create_authorizer(_authorizer())


def test_create_route_conflict() raises:
    var client = _client(_mk_conflict)
    with assert_raises(contains=String("CreateRoute") + _CONFLICT):
        _ = client.create_route(_route())


def test_create_stage_conflict() raises:
    var client = _client(_mk_conflict)
    with assert_raises(contains=String("CreateStage") + _CONFLICT):
        _ = client.create_stage(_stage())


def test_create_integration_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("CreateIntegration") + _MISSING):
        _ = client.create_integration(_integration())


def test_get_api_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("GetApi") + _MISSING):
        _ = client.get_api(ApiGatewayV2GetApiRequest(String(_API)))


def test_update_api_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("UpdateApi") + _MISSING):
        _ = client.update_api(_update_api())


def test_delete_api_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("DeleteApi") + _MISSING):
        _ = client.delete_api(ApiGatewayV2DeleteApiRequest(String(_API)))


def test_get_stages_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("GetStages") + _MISSING):
        _ = client.get_stages(ApiGatewayV2GetStagesRequest(String(_API)))


def test_get_integrations_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("GetIntegrations") + _MISSING):
        _ = client.get_integrations(ApiGatewayV2GetIntegrationsRequest(String(_API)))


def test_get_routes_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("GetRoutes") + _MISSING):
        _ = client.get_routes(ApiGatewayV2GetRoutesRequest(String(_API)))


def test_get_authorizers_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("GetAuthorizers") + _MISSING):
        _ = client.get_authorizers(ApiGatewayV2GetAuthorizersRequest(String(_API)))


def test_update_authorizer_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("UpdateAuthorizer") + _MISSING):
        _ = client.update_authorizer(_update_authorizer())


# ---- each verb on the wire ---------------------------------------------------


def _wire_of(text: String, op: String) raises -> String:
    var marker = op + " failed: HTTP 400 " + AWS_ECHO_CODE + " "
    var at = text.find(marker)
    assert_true(at >= 0, text)
    return String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()


def _check(wire: String, line: String, has_body: Bool) raises:
    assert_true(wire.startswith(line + " http/1.1 | "), wire)
    var want: List[String] = [
        "host: 127.0.0.1:4566",
        "/us-east-1/apigateway/aws4_request, signedheaders=",
    ]
    if has_body:
        want.append("content-type: application/json")
    for i in range(len(want)):
        assert_true(wire.find(want[i]) >= 0, want[i] + " is not in " + wire)
    if not has_body:
        assert_true(wire.find("content-type") < 0, wire)


def test_create_api_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_api(_create_api())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateApi"), "post /v2/apis", True)


def test_get_apis_on_the_wire() raises:
    var client = _client(_mk_echo)
    var input = ApiGatewayV2GetApisRequest()
    input.set_next_token(String("tok2"))
    try:
        _ = client.get_apis(input)
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetApis"), "get /v2/apis?nexttoken=tok2", False)


def test_get_api_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.get_api(ApiGatewayV2GetApiRequest(String(_API)))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetApi"), "get /v2/apis/a1b2c3d4e5", False)


def test_update_api_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.update_api(_update_api())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "UpdateApi"), "patch /v2/apis/a1b2c3d4e5", True)


def test_delete_api_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.delete_api(ApiGatewayV2DeleteApiRequest(String(_API)))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "DeleteApi"), "delete /v2/apis/a1b2c3d4e5", False)


def test_create_stage_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_stage(_stage())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateStage"), "post /v2/apis/a1b2c3d4e5/stages", True)


def test_get_stages_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.get_stages(ApiGatewayV2GetStagesRequest(String(_API)))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetStages"), "get /v2/apis/a1b2c3d4e5/stages", False)


def test_create_integration_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_integration(_integration())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateIntegration"), "post /v2/apis/a1b2c3d4e5/integrations", True)


def test_get_integrations_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.get_integrations(ApiGatewayV2GetIntegrationsRequest(String(_API)))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetIntegrations"), "get /v2/apis/a1b2c3d4e5/integrations", False)


def test_create_route_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_route(_route())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateRoute"), "post /v2/apis/a1b2c3d4e5/routes", True)


def test_get_routes_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.get_routes(ApiGatewayV2GetRoutesRequest(String(_API)))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetRoutes"), "get /v2/apis/a1b2c3d4e5/routes", False)


def test_create_authorizer_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_authorizer(_authorizer())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateAuthorizer"), "post /v2/apis/a1b2c3d4e5/authorizers", True)


def test_get_authorizers_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.get_authorizers(ApiGatewayV2GetAuthorizersRequest(String(_API)))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetAuthorizers"), "get /v2/apis/a1b2c3d4e5/authorizers", False)


def test_update_authorizer_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.update_authorizer(_update_authorizer())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "UpdateAuthorizer"), "patch /v2/apis/a1b2c3d4e5/authorizers/auth01", True)


def main() raises:
    test_create_api_answered()
    test_get_apis_answered()
    test_create_api_bad_request()
    test_get_apis_bad_request()
    test_create_authorizer_bad_request()
    test_create_route_conflict()
    test_create_stage_conflict()
    test_create_integration_not_found()
    test_get_api_not_found()
    test_update_api_not_found()
    test_delete_api_not_found()
    test_get_stages_not_found()
    test_get_integrations_not_found()
    test_get_routes_not_found()
    test_get_authorizers_not_found()
    test_update_authorizer_not_found()
    test_create_api_on_the_wire()
    test_get_apis_on_the_wire()
    test_get_api_on_the_wire()
    test_update_api_on_the_wire()
    test_delete_api_on_the_wire()
    test_create_stage_on_the_wire()
    test_get_stages_on_the_wire()
    test_create_integration_on_the_wire()
    test_get_integrations_on_the_wire()
    test_create_route_on_the_wire()
    test_get_routes_on_the_wire()
    test_create_authorizer_on_the_wire()
    test_get_authorizers_on_the_wire()
    test_update_authorizer_on_the_wire()
    print("OK")
