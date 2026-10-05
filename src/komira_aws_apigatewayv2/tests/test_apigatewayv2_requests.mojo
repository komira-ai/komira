# The requests komira_aws_apigatewayv2 builds, exactly: method, path (the
# API and authorizer ids URI labels), query (`maxResults`, `nextToken`),
# headers and the JSON body. Every member is sent under its lowerCamel
# wire name (`name`, `protocolType`), not its PascalCase member name; the
# rows pin that in both directions (test_apigatewayv2_responses reads them
# back). One or more rows per operation, in the shapes the API Gateway v2
# API reference documents for an HTTP API front door: the API created,
# listed, read, updated (PATCH) and deleted; a `$default` auto-deploy
# stage; an AWS_PROXY integration to a Lambda function; an `ANY
# /{proxy+}` route behind a custom REQUEST authorizer; the authorizer
# created and updated.
from komira_aws_apigatewayv2.komira_aws_apigatewayv2 import (
    APIGATEWAYV2_CONTENT_TYPE,
    APIGATEWAYV2_SERVICE,
    ApiGatewayV2CreateApiRequest,
    ApiGatewayV2CreateAuthorizerRequest,
    ApiGatewayV2CreateIntegrationRequest,
    ApiGatewayV2CreateRouteRequest,
    ApiGatewayV2CreateStageRequest,
    ApiGatewayV2DeleteApiRequest,
    ApiGatewayV2GetApiRequest,
    ApiGatewayV2GetApisRequest,
    ApiGatewayV2GetAuthorizersRequest,
    ApiGatewayV2GetIntegrationsRequest,
    ApiGatewayV2GetRoutesRequest,
    ApiGatewayV2GetStagesRequest,
    ApiGatewayV2UpdateApiRequest,
    ApiGatewayV2UpdateAuthorizerRequest,
    build_create_api_request,
    build_create_authorizer_request,
    build_create_integration_request,
    build_create_route_request,
    build_create_stage_request,
    build_delete_api_request,
    build_get_api_request,
    build_get_apis_request,
    build_get_authorizers_request,
    build_get_integrations_request,
    build_get_routes_request,
    build_get_stages_request,
    build_update_api_request,
    build_update_authorizer_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


comptime _API = "a1b2c3d4e5"
comptime _FN = "arn:aws:lambda:us-east-1:123456789012:function:jobs"
comptime _AUTH_URI = (
    "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/"
    + "arn:aws:lambda:us-east-1:123456789012:function:edge-auth/invocations"
)


def _check_json(req: AwsRequest) raises:
    assert_equal(req.header(String("Content-Type")), "application/json")
    assert_equal(len(req.header_names), 1)


def _check_bodiless(req: AwsRequest) raises:
    assert_equal(len(req.header_names), 0)
    assert_equal(len(req.body), 0)


def test_wire_constants() raises:
    assert_equal(APIGATEWAYV2_CONTENT_TYPE, "application/json")
    # The v2 API is signed under the v1 service name.
    assert_equal(APIGATEWAYV2_SERVICE, "apigateway")


def test_create_api() raises:
    var input = ApiGatewayV2CreateApiRequest(String("jobs-edge"), String("HTTP"))
    input.set_description(String("front door"))
    var tags = Dict[String, String]()
    tags["app"] = String("jobs")
    input.set_tags(tags^)
    var req = build_create_api_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/apis")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"description":"front door","name":"jobs-edge","protocolType":"HTTP","tags":{"app":"jobs"}}',
    )


def test_get_apis() raises:
    var req = build_get_apis_request(ApiGatewayV2GetApisRequest())
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/v2/apis")
    _check_bodiless(req)


def test_get_apis_next_page() raises:
    var input = ApiGatewayV2GetApisRequest()
    input.set_max_results(String("25"))
    input.set_next_token(String("tok/2=="))
    var req = build_get_apis_request(input)
    # A query value is percent-encoded; `maxResults` is a string in this model.
    assert_equal(req.uri, "/v2/apis?maxResults=25&nextToken=tok%2F2%3D%3D")


def test_get_api() raises:
    var req = build_get_api_request(ApiGatewayV2GetApiRequest(String(_API)))
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5")
    _check_bodiless(req)


def test_update_api() raises:
    var input = ApiGatewayV2UpdateApiRequest(String(_API))
    input.set_description(String("front door, v2"))
    input.set_disable_execute_api_endpoint(False)
    var req = build_update_api_request(input)
    assert_equal(req.method, "PATCH")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5")
    _check_json(req)
    # An explicit false is sent; an unset member is absent.
    assert_equal(req.body_text(), '{"description":"front door, v2","disableExecuteApiEndpoint":false}')


def test_delete_api() raises:
    var req = build_delete_api_request(ApiGatewayV2DeleteApiRequest(String(_API)))
    assert_equal(req.method, "DELETE")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5")
    _check_bodiless(req)


def test_create_stage() raises:
    var input = ApiGatewayV2CreateStageRequest(String(_API), String("$default"))
    input.set_auto_deploy(True)
    var req = build_create_stage_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/stages")
    _check_json(req)
    # `$default` travels in the body, never in a path.
    assert_equal(req.body_text(), '{"autoDeploy":true,"stageName":"$default"}')


def test_get_stages() raises:
    var req = build_get_stages_request(ApiGatewayV2GetStagesRequest(String(_API)))
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/stages")
    _check_bodiless(req)


def test_create_integration() raises:
    var input = ApiGatewayV2CreateIntegrationRequest(String(_API), String("AWS_PROXY"))
    input.set_integration_uri(String(_FN))
    input.set_payload_format_version(String("2.0"))
    input.set_timeout_in_millis(Int32(29000))
    var req = build_create_integration_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/integrations")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"integrationType":"AWS_PROXY","integrationUri":"'
        + _FN
        + '","payloadFormatVersion":"2.0","timeoutInMillis":29000}',
    )


def test_get_integrations() raises:
    var req = build_get_integrations_request(ApiGatewayV2GetIntegrationsRequest(String(_API)))
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/integrations")
    _check_bodiless(req)


def test_create_route() raises:
    var input = ApiGatewayV2CreateRouteRequest(String(_API), String("ANY /{proxy+}"))
    input.set_authorization_type(String("CUSTOM"))
    input.set_authorizer_id(String("auth01"))
    input.set_target(String("integrations/int01"))
    var req = build_create_route_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/routes")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"authorizationType":"CUSTOM","authorizerId":"auth01","routeKey":"ANY /{proxy+}",'
        + '"target":"integrations/int01"}',
    )


def test_get_routes() raises:
    var input = ApiGatewayV2GetRoutesRequest(String(_API))
    input.set_next_token(String("tok2"))
    var req = build_get_routes_request(input)
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/routes?nextToken=tok2")
    _check_bodiless(req)


def test_create_authorizer() raises:
    var input = ApiGatewayV2CreateAuthorizerRequest(
        String(_API), String("REQUEST"), [String("$request.header.Authorization")], String("edge-auth")
    )
    input.set_authorizer_uri(String(_AUTH_URI))
    input.set_authorizer_payload_format_version(String("2.0"))
    input.set_enable_simple_responses(True)
    input.set_authorizer_result_ttl_in_seconds(Int32(0))
    var req = build_create_authorizer_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/authorizers")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"authorizerPayloadFormatVersion":"2.0","authorizerResultTtlInSeconds":0,'
        + '"authorizerType":"REQUEST","authorizerUri":"'
        + _AUTH_URI
        + '","enableSimpleResponses":true,'
        + '"identitySource":["$request.header.Authorization"],"name":"edge-auth"}',
    )


def test_get_authorizers() raises:
    var req = build_get_authorizers_request(ApiGatewayV2GetAuthorizersRequest(String(_API)))
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/authorizers")
    _check_bodiless(req)


def test_update_authorizer() raises:
    var input = ApiGatewayV2UpdateAuthorizerRequest(String(_API), String("auth01"))
    input.set_authorizer_result_ttl_in_seconds(Int32(300))
    input.set_identity_source([String("$request.header.Authorization"), String("$context.routeKey")])
    var req = build_update_authorizer_request(input)
    assert_equal(req.method, "PATCH")
    # The one operation with two labels.
    assert_equal(req.uri, "/v2/apis/a1b2c3d4e5/authorizers/auth01")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"authorizerResultTtlInSeconds":300,'
        + '"identitySource":["$request.header.Authorization","$context.routeKey"]}',
    )


def test_refusals_before_the_wire() raises:
    # A REQUEST authorizer's result TTL is bounded to [0, 3600] by the model.
    var input = ApiGatewayV2UpdateAuthorizerRequest(String(_API), String("auth01"))
    input.set_authorizer_result_ttl_in_seconds(Int32(3601))
    with assert_raises(contains="ApiGatewayV2UpdateAuthorizerRequest.authorizerResultTtlInSeconds"):
        _ = build_update_authorizer_request(input)


def main() raises:
    test_wire_constants()
    test_create_api()
    test_get_apis()
    test_get_apis_next_page()
    test_get_api()
    test_update_api()
    test_delete_api()
    test_create_stage()
    test_get_stages()
    test_create_integration()
    test_get_integrations()
    test_create_route()
    test_get_routes()
    test_create_authorizer()
    test_get_authorizers()
    test_update_authorizer()
    test_refusals_before_the_wire()
    print("OK")
