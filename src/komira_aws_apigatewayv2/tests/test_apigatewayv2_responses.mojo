# The responses komira_aws_apigatewayv2 decodes, one or more rows per
# operation, and the restJson1 error form API Gateway answers with. The
# wire texts are written here from the API Gateway v2 API reference, with
# made-up ids. Every member is read under its lowerCamel wire name
# (`apiId`, `protocolType`), and a timestamp (`createdDate`) is ISO 8601.
#
# Errors. API Gateway names the error in the `X-Amzn-Errortype` header and
# carries `message` (and, for NotFoundException, `resourceType`) in the
# body.
from komira_aws_apigatewayv2.komira_aws_apigatewayv2 import (
    ApiGatewayV2ConflictException,
    ApiGatewayV2NotFoundException,
    parse_create_api_response,
    parse_create_authorizer_response,
    parse_create_integration_response,
    parse_create_route_response,
    parse_create_stage_response,
    parse_delete_api_response,
    parse_get_api_response,
    parse_get_apis_response,
    parse_get_authorizers_response,
    parse_get_integrations_response,
    parse_get_routes_response,
    parse_get_stages_response,
    parse_update_api_response,
    parse_update_authorizer_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_rest_json_error
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_true


comptime _API_JSON = (
    '{"apiEndpoint":"https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com",'
    + '"apiId":"a1b2c3d4e5","apiKeySelectionExpression":"$request.header.x-api-key",'
    + '"createdDate":"2026-10-01T00:00:00Z","description":"front door",'
    + '"disableExecuteApiEndpoint":false,"name":"jobs-edge","protocolType":"HTTP",'
    + '"routeSelectionExpression":"$request.method $request.path","tags":{"app":"jobs"}}'
)

comptime _AUTHORIZER_JSON = (
    '{"authorizerId":"auth01","authorizerPayloadFormatVersion":"2.0",'
    + '"authorizerResultTtlInSeconds":0,"authorizerType":"REQUEST",'
    + '"authorizerUri":"arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/'
    + 'arn:aws:lambda:us-east-1:123456789012:function:edge-auth/invocations",'
    + '"enableSimpleResponses":true,"identitySource":["$request.header.Authorization"],'
    + '"name":"edge-auth"}'
)

comptime _INTEGRATION_JSON = (
    '{"connectionType":"INTERNET","integrationId":"int01","integrationMethod":"POST",'
    + '"integrationType":"AWS_PROXY",'
    + '"integrationUri":"arn:aws:lambda:us-east-1:123456789012:function:jobs",'
    + '"payloadFormatVersion":"2.0","timeoutInMillis":29000}'
)

comptime _ROUTE_JSON = (
    '{"apiKeyRequired":false,"authorizationType":"CUSTOM","authorizerId":"auth01",'
    + '"routeId":"rt01","routeKey":"ANY /{proxy+}","target":"integrations/int01"}'
)

comptime _STAGE_JSON = (
    '{"autoDeploy":true,"createdDate":"2026-10-01T00:00:00Z",'
    + '"defaultRouteSettings":{"detailedMetricsEnabled":false},'
    + '"lastUpdatedDate":"2026-10-01T00:00:01Z","stageName":"$default"}'
)


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def test_create_and_get_and_update_api() raises:
    var created = parse_create_api_response(AwsResponse.of_text(201, String(_API_JSON)))
    assert_equal(created.api_id.value(), "a1b2c3d4e5")
    assert_equal(created.api_endpoint.value(), "https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com")
    assert_equal(created.name.value(), "jobs-edge")
    assert_equal(created.protocol_type.value(), "HTTP")
    assert_equal(created.created_date.value(), Float64(1790812800))
    assert_false(created.disable_execute_api_endpoint.value())
    assert_equal(created.tags.value()["app"], "jobs")
    var got = parse_get_api_response(_ok(String(_API_JSON)))
    assert_equal(got.route_selection_expression.value(), "$request.method $request.path")
    var updated = parse_update_api_response(_ok(String(_API_JSON)))
    assert_equal(updated.description.value(), "front door")


def test_get_apis() raises:
    var r = parse_get_apis_response(_ok(String('{"items":[') + _API_JSON + '],"nextToken":"tok2"}'))
    assert_equal(len(r.items.value()), 1)
    ref api = r.items.value()[0]
    assert_equal(api.api_id.value(), "a1b2c3d4e5")
    assert_equal(api.name, "jobs-edge")
    assert_equal(api.protocol_type, "HTTP")
    assert_equal(r.next_token.value(), "tok2")
    var last = parse_get_apis_response(_ok(String('{"items":[]}')))
    assert_equal(len(last.items.value()), 0)
    assert_false(Bool(last.next_token))


def test_delete_api() raises:
    _ = parse_delete_api_response(AwsResponse.of_text(204, String("")))


def test_stages() raises:
    var created = parse_create_stage_response(AwsResponse.of_text(201, String(_STAGE_JSON)))
    assert_equal(created.stage_name.value(), "$default")
    assert_true(created.auto_deploy.value())
    assert_equal(created.last_updated_date.value(), Float64(1790812801))
    var list = parse_get_stages_response(_ok(String('{"items":[') + _STAGE_JSON + "]}"))
    assert_equal(list.items.value()[0].stage_name, "$default")


def test_integrations() raises:
    var created = parse_create_integration_response(AwsResponse.of_text(201, String(_INTEGRATION_JSON)))
    assert_equal(created.integration_id.value(), "int01")
    assert_equal(created.integration_type.value(), "AWS_PROXY")
    assert_equal(created.payload_format_version.value(), "2.0")
    assert_equal(created.timeout_in_millis.value(), Int32(29000))
    var list = parse_get_integrations_response(_ok(String('{"items":[') + _INTEGRATION_JSON + "]}"))
    assert_equal(list.items.value()[0].integration_uri.value(), "arn:aws:lambda:us-east-1:123456789012:function:jobs")


def test_routes() raises:
    var created = parse_create_route_response(AwsResponse.of_text(201, String(_ROUTE_JSON)))
    assert_equal(created.route_id.value(), "rt01")
    assert_equal(created.route_key.value(), "ANY /{proxy+}")
    assert_equal(created.authorization_type.value(), "CUSTOM")
    var list = parse_get_routes_response(_ok(String('{"items":[') + _ROUTE_JSON + '],"nextToken":"tok3"}'))
    assert_equal(list.items.value()[0].target.value(), "integrations/int01")
    assert_equal(list.next_token.value(), "tok3")


def test_authorizers() raises:
    var created = parse_create_authorizer_response(AwsResponse.of_text(201, String(_AUTHORIZER_JSON)))
    assert_equal(created.authorizer_id.value(), "auth01")
    assert_equal(created.authorizer_type.value(), "REQUEST")
    assert_equal(created.authorizer_result_ttl_in_seconds.value(), Int32(0))
    assert_true(created.enable_simple_responses.value())
    assert_equal(created.identity_source.value()[0], "$request.header.Authorization")
    var list = parse_get_authorizers_response(_ok(String('{"items":[') + _AUTHORIZER_JSON + "]}"))
    assert_equal(list.items.value()[0].name, "edge-auth")
    var updated = parse_update_authorizer_response(_ok(String(_AUTHORIZER_JSON)))
    assert_equal(updated.name.value(), "edge-auth")


def test_not_found() raises:
    var r = AwsResponse.of_text(
        404, String('{"message":"Invalid API identifier specified 123456789012:a1b2c3d4e5","resourceType":"Api"}')
    )
    r.add_header(String("X-Amzn-Errortype"), String("NotFoundException"))
    r.add_header(String("x-amzn-RequestId"), String("2a3b4c5d-0000-4000-8000-00000000000d"))
    assert_true(aws_is_error_status(r.status))
    var info = aws_rest_json_error(r)
    assert_equal(info.code, "NotFoundException")
    assert_equal(info.message, "Invalid API identifier specified 123456789012:a1b2c3d4e5")
    assert_equal(info.request_id, "2a3b4c5d-0000-4000-8000-00000000000d")
    var e = ApiGatewayV2NotFoundException.from_aws_json(parse_json_value(r.body_text()))
    assert_equal(e.resource_type.value(), "Api")


def test_conflict() raises:
    var r = AwsResponse.of_text(409, String('{"message":"Route with key ANY /{proxy+} already exists for this API"}'))
    r.add_header(String("X-Amzn-Errortype"), String("ConflictException"))
    var info = aws_rest_json_error(r)
    assert_equal(info.status, 409)
    assert_equal(info.code, "ConflictException")
    var e = ApiGatewayV2ConflictException.from_aws_json(parse_json_value(r.body_text()))
    assert_equal(e.message.value(), "Route with key ANY /{proxy+} already exists for this API")


def main() raises:
    test_create_and_get_and_update_api()
    test_get_apis()
    test_delete_api()
    test_stages()
    test_integrations()
    test_routes()
    test_authorizers()
    test_not_found()
    test_conflict()
    print("OK")
