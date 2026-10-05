# The requests komira_aws_lambda builds, exactly: method, path (each
# operation's own API date prefix and the function name a URI label),
# query (`Qualifier`), headers and the body, members in the model's order
# and an unset member absent. One or more rows per operation, in the shapes
# the AWS Lambda API reference documents: an image function created
# (`ImageUri` nested in `Code`) and a zip one (`ZipFile` base64), read,
# its code (`ImageUri` at the top level) and configuration updated, a
# permission added, reserved concurrency put (under `/2017-10-31`), a
# function URL created, read and updated (under `/2021-10-31`), invoked
# (the payload is the raw body, the invocation type a header), and deleted.
from komira_aws_lambda.komira_aws_lambda import (
    LAMBDA_CONTENT_TYPE,
    LambdaAddPermissionRequest,
    LambdaCors,
    LambdaCreateFunctionRequest,
    LambdaCreateFunctionUrlConfigRequest,
    LambdaDeleteFunctionRequest,
    LambdaEnvironment,
    LambdaFunctionCode,
    LambdaGetFunctionRequest,
    LambdaGetFunctionUrlConfigRequest,
    LambdaImageConfig,
    LambdaInvocationRequest,
    LambdaPutFunctionConcurrencyRequest,
    LambdaUpdateFunctionCodeRequest,
    LambdaUpdateFunctionConfigurationRequest,
    LambdaUpdateFunctionUrlConfigRequest,
    build_add_permission_request,
    build_create_function_request,
    build_create_function_url_config_request,
    build_delete_function_request,
    build_get_function_request,
    build_get_function_url_config_request,
    build_invoke_request,
    build_put_function_concurrency_request,
    build_update_function_code_request,
    build_update_function_configuration_request,
    build_update_function_url_config_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


comptime _IMAGE = "123456789012.dkr.ecr.us-east-1.amazonaws.com/jobs@sha256:0f1e2d3c"
comptime _ROLE = "arn:aws:iam::123456789012:role/jobs-exec"
comptime _ARN = "arn:aws:lambda:us-east-1:123456789012:function:jobs"


def _check_json(req: AwsRequest) raises:
    assert_equal(req.header(String("Content-Type")), "application/json")
    assert_equal(len(req.header_names), 1)


def _check_bodiless(req: AwsRequest) raises:
    assert_equal(len(req.header_names), 0)
    assert_equal(len(req.body), 0)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def test_wire_constants() raises:
    assert_equal(LAMBDA_CONTENT_TYPE, "application/json")


def test_create_function_from_an_image() raises:
    var code = LambdaFunctionCode()
    code.set_image_uri(String(_IMAGE))
    var input = LambdaCreateFunctionRequest(String("jobs"), String(_ROLE), code^)
    input.set_package_type(String("Image"))
    input.set_timeout(Int32(30))
    input.set_memory_size(Int32(512))
    var vars = Dict[String, String]()
    vars["LOG_LEVEL"] = String("info")
    var env = LambdaEnvironment()
    env.set_variables(vars^)
    input.set_environment(env^)
    var image = LambdaImageConfig()
    image.set_command([String("--port=8080")])
    input.set_image_config(image^)
    input.set_architectures([String("arm64")])
    var req = build_create_function_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/2015-03-31/functions")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"FunctionName":"jobs","Role":"'
        + _ROLE
        + '","Code":{"ImageUri":"'
        + _IMAGE
        + '"},"Timeout":30,"MemorySize":512,"PackageType":"Image",'
        + '"Environment":{"Variables":{"LOG_LEVEL":"info"}},'
        + '"ImageConfig":{"Command":["--port=8080"]},"Architectures":["arm64"]}',
    )


def test_create_function_from_a_zip() raises:
    var code = LambdaFunctionCode()
    # A zip's local-file-header magic, "PK\x03\x04".
    code.set_zip_file([UInt8(0x50), UInt8(0x4B), UInt8(0x03), UInt8(0x04)])
    var input = LambdaCreateFunctionRequest(String("hook"), String(_ROLE), code^)
    input.set_runtime(String("python3.12"))
    input.set_handler(String("app.handler"))
    input.set_publish(True)
    var req = build_create_function_request(input)
    assert_equal(
        req.body_text(),
        '{"FunctionName":"hook","Runtime":"python3.12","Role":"'
        + _ROLE
        + '","Handler":"app.handler","Code":{"ZipFile":"UEsDBA=="},"Publish":true}',
    )


def test_get_function() raises:
    var req = build_get_function_request(LambdaGetFunctionRequest(String("jobs")))
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/2015-03-31/functions/jobs")
    _check_bodiless(req)


def test_get_function_by_arn_and_qualifier() raises:
    # An ARN's ':' is percent-encoded in the label.
    var input = LambdaGetFunctionRequest(String(_ARN))
    input.set_qualifier(String("live"))
    var req = build_get_function_request(input)
    assert_equal(
        req.uri,
        "/2015-03-31/functions/arn%3Aaws%3Alambda%3Aus-east-1%3A123456789012%3Afunction%3Ajobs?Qualifier=live",
    )


def test_update_function_code() raises:
    var input = LambdaUpdateFunctionCodeRequest(String("jobs"))
    input.set_image_uri(String(_IMAGE))
    var req = build_update_function_code_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/2015-03-31/functions/jobs/code")
    _check_json(req)
    # `ImageUri` at the top level here, nested in `Code` on CreateFunction.
    assert_equal(req.body_text(), String('{"ImageUri":"') + _IMAGE + '"}')


def test_update_function_code_published() raises:
    var input = LambdaUpdateFunctionCodeRequest(String("jobs"))
    input.set_image_uri(String(_IMAGE))
    input.set_publish(True)
    input.set_revision_id(String("rev-1"))
    var req = build_update_function_code_request(input)
    assert_equal(
        req.body_text(),
        String('{"ImageUri":"') + _IMAGE + '","Publish":true,"RevisionId":"rev-1"}',
    )


def test_update_function_configuration() raises:
    var input = LambdaUpdateFunctionConfigurationRequest(String("jobs"))
    input.set_role(String(_ROLE))
    input.set_timeout(Int32(60))
    input.set_memory_size(Int32(1024))
    var vars = Dict[String, String]()
    vars["LOG_LEVEL"] = String("debug")
    vars["REGION_HINT"] = String("us-east-1")
    var env = LambdaEnvironment()
    env.set_variables(vars^)
    input.set_environment(env^)
    var image = LambdaImageConfig()
    image.set_entry_point([String("/app/jobs")])
    image.set_command([String("--port=8080"), String("--verbose")])
    input.set_image_config(image^)
    var req = build_update_function_configuration_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/2015-03-31/functions/jobs/configuration")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"Role":"'
        + _ROLE
        + '","Timeout":60,"MemorySize":1024,'
        + '"Environment":{"Variables":{"LOG_LEVEL":"debug","REGION_HINT":"us-east-1"}},'
        + '"ImageConfig":{"EntryPoint":["/app/jobs"],"Command":["--port=8080","--verbose"]}}',
    )


def test_add_permission() raises:
    var input = LambdaAddPermissionRequest(
        String("jobs"),
        String("apigw-invoke"),
        String("lambda:InvokeFunction"),
        String("apigateway.amazonaws.com"),
    )
    input.set_source_arn(String("arn:aws:execute-api:us-east-1:123456789012:a1b2c3d4e5/*"))
    var req = build_add_permission_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/2015-03-31/functions/jobs/policy")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"StatementId":"apigw-invoke","Action":"lambda:InvokeFunction",'
        + '"Principal":"apigateway.amazonaws.com",'
        + '"SourceArn":"arn:aws:execute-api:us-east-1:123456789012:a1b2c3d4e5/*"}',
    )


def test_add_permission_for_a_function_url() raises:
    var input = LambdaAddPermissionRequest(
        String("jobs"), String("url-invoke"), String("lambda:InvokeFunctionUrl"), String("*")
    )
    input.set_function_url_auth_type(String("NONE"))
    input.set_qualifier(String("live"))
    var req = build_add_permission_request(input)
    assert_equal(req.uri, "/2015-03-31/functions/jobs/policy?Qualifier=live")
    assert_equal(
        req.body_text(),
        '{"StatementId":"url-invoke","Action":"lambda:InvokeFunctionUrl","Principal":"*",'
        + '"FunctionUrlAuthType":"NONE"}',
    )


def test_put_function_concurrency() raises:
    var req = build_put_function_concurrency_request(LambdaPutFunctionConcurrencyRequest(String("jobs"), Int32(5)))
    assert_equal(req.method, "PUT")
    # This operation's own API date, not the service's.
    assert_equal(req.uri, "/2017-10-31/functions/jobs/concurrency")
    _check_json(req)
    assert_equal(req.body_text(), '{"ReservedConcurrentExecutions":5}')


def test_create_function_url_config() raises:
    var input = LambdaCreateFunctionUrlConfigRequest(String("jobs"), String("AWS_IAM"))
    var cors = LambdaCors()
    cors.set_allow_origins([String("https://app.example.com")])
    cors.set_allow_methods([String("GET"), String("POST")])
    cors.set_max_age(Int32(300))
    input.set_cors(cors^)
    var req = build_create_function_url_config_request(input)
    assert_equal(req.method, "POST")
    # Function URL operations live under /2021-10-31.
    assert_equal(req.uri, "/2021-10-31/functions/jobs/url")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"AuthType":"AWS_IAM","Cors":{"AllowMethods":["GET","POST"],'
        + '"AllowOrigins":["https://app.example.com"],"MaxAge":300}}',
    )


def test_get_function_url_config() raises:
    var req = build_get_function_url_config_request(LambdaGetFunctionUrlConfigRequest(String("jobs")))
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/2021-10-31/functions/jobs/url")
    _check_bodiless(req)


def test_update_function_url_config() raises:
    var input = LambdaUpdateFunctionUrlConfigRequest(String("jobs"))
    input.set_auth_type(String("NONE"))
    input.set_invoke_mode(String("BUFFERED"))
    var req = build_update_function_url_config_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/2021-10-31/functions/jobs/url")
    _check_json(req)
    assert_equal(req.body_text(), '{"AuthType":"NONE","InvokeMode":"BUFFERED"}')


def test_invoke() raises:
    var input = LambdaInvocationRequest(String("jobs"))
    input.set_invocation_type(String("RequestResponse"))
    input.set_log_type(String("Tail"))
    input.set_payload(_bytes(String('{"version":"2.0","rawPath":"/healthz"}')))
    var req = build_invoke_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/2015-03-31/functions/jobs/invocations")
    assert_equal(req.header(String("X-Amz-Invocation-Type")), "RequestResponse")
    assert_equal(req.header(String("X-Amz-Log-Type")), "Tail")
    # The payload is the body as given (a blob payload, not a JSON member),
    # typed application/octet-stream as Smithy's restJson1 types a blob
    # payload.
    assert_equal(req.header(String("Content-Type")), "application/octet-stream")
    assert_equal(len(req.header_names), 3)
    assert_equal(req.body_text(), '{"version":"2.0","rawPath":"/healthz"}')


def test_invoke_async_with_a_qualifier_and_no_payload() raises:
    var input = LambdaInvocationRequest(String("jobs"))
    input.set_invocation_type(String("Event"))
    input.set_qualifier(String("7"))
    var req = build_invoke_request(input)
    assert_equal(req.uri, "/2015-03-31/functions/jobs/invocations?Qualifier=7")
    assert_equal(req.header(String("X-Amz-Invocation-Type")), "Event")
    assert_equal(len(req.header_names), 1)
    assert_equal(len(req.body), 0)


def test_delete_function() raises:
    var req = build_delete_function_request(LambdaDeleteFunctionRequest(String("jobs")))
    assert_equal(req.method, "DELETE")
    assert_equal(req.uri, "/2015-03-31/functions/jobs")
    _check_bodiless(req)


def test_refusals_before_the_wire() raises:
    # `FunctionName` is `min: 1` in the model; reserved concurrency is at
    # least 0.
    with assert_raises(contains="FunctionName"):
        _ = build_get_function_request(LambdaGetFunctionRequest(String("")))
    with assert_raises(contains="ReservedConcurrentExecutions"):
        _ = build_put_function_concurrency_request(LambdaPutFunctionConcurrencyRequest(String("jobs"), Int32(-1)))


def main() raises:
    test_wire_constants()
    test_create_function_from_an_image()
    test_create_function_from_a_zip()
    test_get_function()
    test_get_function_by_arn_and_qualifier()
    test_update_function_code()
    test_update_function_code_published()
    test_update_function_configuration()
    test_add_permission()
    test_add_permission_for_a_function_url()
    test_put_function_concurrency()
    test_create_function_url_config()
    test_get_function_url_config()
    test_update_function_url_config()
    test_invoke()
    test_invoke_async_with_a_qualifier_and_no_payload()
    test_delete_function()
    test_refusals_before_the_wire()
    print("OK")
