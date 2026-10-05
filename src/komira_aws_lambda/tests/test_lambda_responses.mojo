# The responses komira_aws_lambda decodes, one or more rows per operation,
# and the restJson1 error form Lambda answers with. The wire texts are
# written here from the AWS Lambda API reference, with made-up names,
# digests and ids.
#
# Errors. Lambda names the error in the `X-Amzn-Errortype` header; the body
# carries `Type` and `Message`. komira_aws_core's `aws_rest_json_error`
# reads the code from the header and the message from the body, and the
# generated error shapes read the body.
from komira_aws_lambda.komira_aws_lambda import (
    LambdaResourceConflictException,
    LambdaResourceNotFoundException,
    parse_add_permission_response,
    parse_create_function_response,
    parse_create_function_url_config_response,
    parse_delete_function_response,
    parse_get_function_response,
    parse_get_function_url_config_response,
    parse_invoke_response,
    parse_put_function_concurrency_response,
    parse_update_function_code_response,
    parse_update_function_configuration_response,
    parse_update_function_url_config_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_rest_json_error
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_true


comptime _ARN = "arn:aws:lambda:us-east-1:123456789012:function:jobs"
comptime _IMAGE = "123456789012.dkr.ecr.us-east-1.amazonaws.com/jobs@sha256:0f1e2d3c"

# A FunctionConfiguration as CreateFunction, UpdateFunctionCode and
# UpdateFunctionConfiguration answer it, an update in progress.
comptime _CONFIG = (
    '{"FunctionName":"jobs","FunctionArn":"'
    + _ARN
    + '","Role":"arn:aws:iam::123456789012:role/jobs-exec","CodeSize":0,'
    + '"Timeout":30,"MemorySize":512,"LastModified":"2026-10-01T00:00:00.000+0000",'
    + '"CodeSha256":"0f1e2d3c","Version":"$LATEST",'
    + '"Environment":{"Variables":{"LOG_LEVEL":"info"}},'
    + '"TracingConfig":{"Mode":"PassThrough"},"RevisionId":"9a8b7c6d-0000-4000-8000-000000000001",'
    + '"State":"Active","LastUpdateStatus":"InProgress",'
    + '"LastUpdateStatusReason":"The function is being created.",'
    + '"LastUpdateStatusReasonCode":"Creating","PackageType":"Image",'
    + '"ImageConfigResponse":{"ImageConfig":{"Command":["--port=8080"]}},'
    + '"Architectures":["arm64"],"EphemeralStorage":{"Size":512},'
    + '"SnapStart":{"ApplyOn":"None","OptimizationStatus":"Off"},'
    + '"LoggingConfig":{"LogFormat":"Text","LogGroup":"/aws/lambda/jobs"}}'
)


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def test_create_function() raises:
    var r = parse_create_function_response(AwsResponse.of_text(201, String(_CONFIG)))
    assert_equal(r.function_name.value(), "jobs")
    assert_equal(r.function_arn.value(), _ARN)
    assert_equal(r.package_type.value(), "Image")
    assert_equal(r.timeout.value(), Int32(30))
    assert_equal(r.memory_size.value(), Int32(512))
    assert_equal(r.code_size.value(), Int64(0))
    assert_equal(r.version.value(), "$LATEST")
    assert_equal(r.state.value(), "Active")
    assert_equal(r.last_update_status.value(), "InProgress")
    assert_equal(r.last_update_status_reason_code.value(), "Creating")
    assert_equal(r.environment.value().variables.value()["LOG_LEVEL"], "info")
    assert_equal(r.image_config_response.value().image_config.value().command.value()[0], "--port=8080")
    assert_equal(r.architectures.value()[0], "arm64")
    assert_equal(r.ephemeral_storage.value().size, Int32(512))
    assert_equal(r.logging_config.value().log_group.value(), "/aws/lambda/jobs")
    assert_false(Bool(r.handler))


def test_update_function_code_and_configuration() raises:
    var code = parse_update_function_code_response(_ok(String(_CONFIG)))
    assert_equal(code.revision_id.value(), "9a8b7c6d-0000-4000-8000-000000000001")
    var conf = parse_update_function_configuration_response(_ok(String(_CONFIG)))
    assert_equal(conf.last_update_status.value(), "InProgress")


def test_get_function() raises:
    var r = parse_get_function_response(
        _ok(
            String('{"Configuration":')
            + _CONFIG
            + ',"Code":{"RepositoryType":"ECR","ImageUri":"'
            + _IMAGE
            + '","ResolvedImageUri":"123456789012.dkr.ecr.us-east-1.amazonaws.com/jobs@sha256:0f1e2d3c"},'
            + '"Tags":{"app":"jobs"},"Concurrency":{"ReservedConcurrentExecutions":5}}'
        )
    )
    assert_equal(r.configuration.value().function_name.value(), "jobs")
    assert_equal(r.code.value().repository_type.value(), "ECR")
    assert_equal(r.code.value().image_uri.value(), _IMAGE)
    assert_equal(r.tags.value()["app"], "jobs")
    assert_equal(r.concurrency.value().reserved_concurrent_executions.value(), Int32(5))


def test_add_permission() raises:
    # `Statement` is a JSON document carried as a string.
    var r = parse_add_permission_response(
        AwsResponse.of_text(
            201,
            String(
                '{"Statement":"{\\"Sid\\":\\"apigw-invoke\\",\\"Effect\\":\\"Allow\\",'
                + '\\"Action\\":\\"lambda:InvokeFunction\\"}"}'
            ),
        )
    )
    assert_equal(
        r.statement.value(),
        '{"Sid":"apigw-invoke","Effect":"Allow","Action":"lambda:InvokeFunction"}',
    )


def test_put_function_concurrency() raises:
    var r = parse_put_function_concurrency_response(_ok(String('{"ReservedConcurrentExecutions":5}')))
    assert_equal(r.reserved_concurrent_executions.value(), Int32(5))


def test_function_url_configs() raises:
    var created = parse_create_function_url_config_response(
        AwsResponse.of_text(
            201,
            String(
                '{"FunctionUrl":"https://abcdefghijklmnop.lambda-url.us-east-1.on.aws/",'
                + '"FunctionArn":"'
                + _ARN
                + '","AuthType":"AWS_IAM","Cors":{"AllowOrigins":["https://app.example.com"]},'
                + '"CreationTime":"2026-10-01T00:00:00.000Z","InvokeMode":"BUFFERED"}'
            ),
        )
    )
    assert_equal(created.function_url, "https://abcdefghijklmnop.lambda-url.us-east-1.on.aws/")
    assert_equal(created.auth_type, "AWS_IAM")
    assert_equal(created.cors.value().allow_origins.value()[0], "https://app.example.com")
    assert_equal(created.invoke_mode.value(), "BUFFERED")
    var url_body = String(
        '{"FunctionUrl":"https://abcdefghijklmnop.lambda-url.us-east-1.on.aws/",'
        + '"FunctionArn":"'
        + _ARN
        + '","AuthType":"NONE","CreationTime":"2026-10-01T00:00:00.000Z",'
        + '"LastModifiedTime":"2026-10-02T00:00:00.000Z"}'
    )
    var got = parse_get_function_url_config_response(_ok(url_body))
    assert_equal(got.auth_type, "NONE")
    assert_equal(got.last_modified_time, "2026-10-02T00:00:00.000Z")
    assert_false(Bool(got.cors))
    var updated = parse_update_function_url_config_response(_ok(url_body))
    assert_equal(updated.function_arn, _ARN)


def test_invoke() raises:
    # The payload is the body, verbatim; the function's own failure is a
    # header on a 200, and the log tail is base64 in another.
    var resp = AwsResponse.of_text(200, String('{"errorMessage":"boom","errorType":"Error"}'))
    resp.add_header(String("X-Amz-Function-Error"), String("Unhandled"))
    resp.add_header(String("X-Amz-Executed-Version"), String("$LATEST"))
    resp.add_header(String("X-Amz-Log-Result"), String("U1RBUlQgUmVxdWVzdElk"))
    var r = parse_invoke_response(resp)
    assert_equal(r.status_code.value(), Int32(200))
    assert_equal(r.function_error.value(), "Unhandled")
    assert_equal(r.executed_version.value(), "$LATEST")
    assert_equal(r.log_result.value(), "U1RBUlQgUmVxdWVzdElk")
    var payload = r.payload.value().copy()
    assert_equal(String(unsafe_from_utf8=Span(payload)), '{"errorMessage":"boom","errorType":"Error"}')


def test_invoke_event_accepted() raises:
    # An asynchronous invoke answers 202 with no payload.
    var r = parse_invoke_response(AwsResponse.of_text(202, String("")))
    assert_equal(r.status_code.value(), Int32(202))
    assert_false(Bool(r.payload))
    assert_false(Bool(r.function_error))


def test_delete_function() raises:
    var r = parse_delete_function_response(AwsResponse.of_text(204, String("")))
    assert_equal(r.status_code.value(), Int32(204))


def _error(status: Int, kind: String, body: String) -> AwsResponse:
    var r = AwsResponse.of_text(status, body)
    r.add_header(String("X-Amzn-Errortype"), kind)
    r.add_header(String("x-amzn-RequestId"), String("1f2e3d4c-0000-4000-8000-00000000000c"))
    return r^


def test_not_found() raises:
    var r = _error(
        404,
        String("ResourceNotFoundException"),
        String('{"Type":"User","Message":"Function not found: ') + _ARN + '"}',
    )
    assert_true(aws_is_error_status(r.status))
    var info = aws_rest_json_error(r)
    assert_equal(info.code, "ResourceNotFoundException")
    assert_equal(info.message, String("Function not found: ") + _ARN)
    assert_equal(info.request_id, "1f2e3d4c-0000-4000-8000-00000000000c")
    var e = LambdaResourceNotFoundException.from_aws_json(parse_json_value(r.body_text()))
    assert_equal(e.type.value(), "User")
    assert_equal(e.message.value(), String("Function not found: ") + _ARN)


def test_update_in_progress() raises:
    var r = _error(
        409,
        String("ResourceConflictException"),
        String(
            '{"Type":"User","message":"The operation cannot be performed at this time. '
            + 'An update is in progress for resource: '
            + _ARN
            + '"}'
        ),
    )
    var info = aws_rest_json_error(r)
    assert_equal(info.status, 409)
    assert_equal(info.code, "ResourceConflictException")
    assert_true(info.message.startswith("The operation cannot be performed at this time."))
    var e = LambdaResourceConflictException.from_aws_json(parse_json_value(r.body_text()))
    assert_equal(e.type.value(), "User")


def main() raises:
    test_create_function()
    test_update_function_code_and_configuration()
    test_get_function()
    test_add_permission()
    test_put_function_concurrency()
    test_function_url_configs()
    test_invoke()
    test_invoke_event_accepted()
    test_delete_function()
    test_not_found()
    test_update_in_progress()
    print("OK")
