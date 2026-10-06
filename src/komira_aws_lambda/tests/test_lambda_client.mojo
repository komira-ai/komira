# The generated Lambda client (`LambdaClient`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket).
#
# Every verb meets one error answer and raises it under the restJson1 code
# Lambda names in `X-Amzn-Errortype`, with the body's message: a create, a
# permission, a function URL or an update that conflicts (409), a read,
# invoke, URL update or delete of a missing function (404), and a
# concurrency the service refuses (400). None is a status or code botocore
# retries, so each call is one request. A read and an invoke are answered
# successfully, and an invoke of a function that threw (a 200 carrying
# `X-Amz-Function-Error`) returns with that error set rather than raising.
#
# Then each verb's request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an error naming the
# request head, so each row asserts the request line (each operation's own
# API date prefix), the Host the endpoint ruleset resolved, the content
# type of a request with a body, and the SigV4 scope (signing name
# `lambda`).
from komira_aws_lambda.komira_aws_lambda import (
    LambdaAddPermissionRequest,
    LambdaCreateFunctionRequest,
    LambdaCreateFunctionUrlConfigRequest,
    LambdaDeleteFunctionRequest,
    LambdaEndpointConfig,
    LambdaFunctionCode,
    LambdaGetFunctionRequest,
    LambdaGetFunctionUrlConfigRequest,
    LambdaInvocationRequest,
    LambdaClient,
    LambdaPutFunctionConcurrencyRequest,
    LambdaUpdateFunctionCodeRequest,
    LambdaUpdateFunctionConfigurationRequest,
    LambdaUpdateFunctionUrlConfigRequest,
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


comptime _IMAGE = "123456789012.dkr.ecr.us-east-1.amazonaws.com/jobs@sha256:0f1e2d3c"
comptime _ROLE = "arn:aws:iam::123456789012:role/jobs-exec"


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


def _mk_function() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"Configuration":{"FunctionName":"jobs","State":"Active",'
            + '"LastUpdateStatus":"Successful","PackageType":"Image"},'
            + '"Code":{"RepositoryType":"ECR","ImageUri":"'
            + _IMAGE
            + '"}}',
            "",
        )
    )


def _mk_invoked() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"statusCode":200,"body":"ok"}',
            "X-Amz-Executed-Version: $LATEST\r\n",
        )
    )


def _mk_function_failed() raises -> ScriptedConnector:
    # The function ran and threw: Lambda still answers 200, names the
    # failure in `X-Amz-Function-Error`, and the payload is the error.
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"errorMessage":"boom","errorType":"Error"}',
            "X-Amz-Executed-Version: $LATEST\r\nX-Amz-Function-Error: Unhandled\r\n",
        )
    )


def _mk_conflict() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            409,
            "Conflict",
            '{"Type":"User","message":"The resource already exists or is being updated."}',
            "X-Amzn-Errortype: ResourceConflictException\r\n",
        )
    )


def _mk_not_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            '{"Type":"User","Message":"Function not found: jobs"}',
            "X-Amzn-Errortype: ResourceNotFoundException\r\n",
        )
    )


def _mk_invalid() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"Type":"User","message":"Specified ReservedConcurrentExecutions decreases the'
            + ' account UnreservedConcurrentExecution below its minimum value of [10]."}',
            "X-Amzn-Errortype: InvalidParameterValueException\r\n",
        )
    )


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.json()


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> LambdaClient[C, StaticCredsSource]:
    var config = LambdaEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return LambdaClient[C, StaticCredsSource](
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


def _create() -> LambdaCreateFunctionRequest:
    var code = LambdaFunctionCode()
    code.set_image_uri(String(_IMAGE))
    var input = LambdaCreateFunctionRequest(String("jobs"), String(_ROLE), code^)
    input.set_package_type(String("Image"))
    return input^


def _permission() -> LambdaAddPermissionRequest:
    return LambdaAddPermissionRequest(
        String("jobs"), String("apigw-invoke"), String("lambda:InvokeFunction"), String("apigateway.amazonaws.com")
    )


def _code() -> LambdaUpdateFunctionCodeRequest:
    var input = LambdaUpdateFunctionCodeRequest(String("jobs"))
    input.set_image_uri(String(_IMAGE))
    return input^


def _configuration() -> LambdaUpdateFunctionConfigurationRequest:
    var input = LambdaUpdateFunctionConfigurationRequest(String("jobs"))
    input.set_timeout(Int32(60))
    return input^


def _url_update() -> LambdaUpdateFunctionUrlConfigRequest:
    var input = LambdaUpdateFunctionUrlConfigRequest(String("jobs"))
    input.set_auth_type(String("AWS_IAM"))
    return input^


def _invoke() -> LambdaInvocationRequest:
    var input = LambdaInvocationRequest(String("jobs"))
    input.set_invocation_type(String("RequestResponse"))
    input.set_payload(_bytes(String('{"rawPath":"/healthz"}')))
    return input^


# ---- answered ----------------------------------------------------------------


def test_get_function_answered() raises:
    var client = _client(_mk_function)
    var out = client.get_function(LambdaGetFunctionRequest(String("jobs")))
    assert_equal(out.configuration.value().last_update_status.value(), "Successful")
    assert_equal(out.code.value().image_uri.value(), _IMAGE)


def test_invoke_answered() raises:
    var client = _client(_mk_invoked)
    var out = client.invoke(_invoke())
    assert_equal(out.status_code.value(), Int32(200))
    assert_equal(out.executed_version.value(), "$LATEST")
    var payload = out.payload.value().copy()
    assert_equal(String(unsafe_from_utf8=Span(payload)), '{"statusCode":200,"body":"ok"}')
    assert_true(not out.function_error)


def test_invoke_of_a_function_that_failed_returns() raises:
    # A function error is the function's, not the call's: `invoke` returns
    # with `function_error` set and the error payload intact, and does not
    # raise.
    var client = _client(_mk_function_failed)
    var out = client.invoke(_invoke())
    assert_equal(out.status_code.value(), Int32(200))
    assert_equal(out.function_error.value(), "Unhandled")
    var payload = out.payload.value().copy()
    assert_equal(String(unsafe_from_utf8=Span(payload)), '{"errorMessage":"boom","errorType":"Error"}')


# ---- one error per verb ------------------------------------------------------

comptime _CONFLICT = " failed: HTTP 409 ResourceConflictException The resource already exists or is being updated."
comptime _MISSING = " failed: HTTP 404 ResourceNotFoundException Function not found: jobs"


def test_add_permission_conflict() raises:
    var client = _client(_mk_conflict)
    with assert_raises(contains=String("AddPermission") + _CONFLICT):
        _ = client.add_permission(_permission())


def test_create_function_conflict() raises:
    var client = _client(_mk_conflict)
    with assert_raises(contains=String("CreateFunction") + _CONFLICT):
        _ = client.create_function(_create())


def test_create_function_url_config_conflict() raises:
    var client = _client(_mk_conflict)
    with assert_raises(contains=String("CreateFunctionUrlConfig") + _CONFLICT):
        _ = client.create_function_url_config(LambdaCreateFunctionUrlConfigRequest(String("jobs"), String("AWS_IAM")))


def test_update_function_code_conflict() raises:
    var client = _client(_mk_conflict)
    with assert_raises(contains=String("UpdateFunctionCode") + _CONFLICT):
        _ = client.update_function_code(_code())


def test_update_function_configuration_conflict() raises:
    var client = _client(_mk_conflict)
    with assert_raises(contains=String("UpdateFunctionConfiguration") + _CONFLICT):
        _ = client.update_function_configuration(_configuration())


def test_get_function_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("GetFunction") + _MISSING):
        _ = client.get_function(LambdaGetFunctionRequest(String("jobs")))


def test_get_function_url_config_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("GetFunctionUrlConfig") + _MISSING):
        _ = client.get_function_url_config(LambdaGetFunctionUrlConfigRequest(String("jobs")))


def test_update_function_url_config_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("UpdateFunctionUrlConfig") + _MISSING):
        _ = client.update_function_url_config(_url_update())


def test_invoke_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("Invoke") + _MISSING):
        _ = client.invoke(_invoke())


def test_delete_function_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(contains=String("DeleteFunction") + _MISSING):
        _ = client.delete_function(LambdaDeleteFunctionRequest(String("jobs")))


def test_put_function_concurrency_invalid() raises:
    var client = _client(_mk_invalid)
    with assert_raises(
        contains="PutFunctionConcurrency failed: HTTP 400 InvalidParameterValueException Specified ReservedConcurrentExecutions"
    ):
        _ = client.put_function_concurrency(LambdaPutFunctionConcurrencyRequest(String("jobs"), Int32(990)))


# ---- each verb on the wire ---------------------------------------------------


def _wire_of(text: String, op: String) raises -> String:
    var marker = op + " failed: HTTP 400 " + AWS_ECHO_CODE + " "
    var at = text.find(marker)
    assert_true(at >= 0, text)
    return String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()


def _check(wire: String, line: String, content_type: String) raises:
    assert_true(wire.startswith(line + " http/1.1 | "), wire)
    var want: List[String] = [
        "host: 127.0.0.1:4566",
        "/us-east-1/lambda/aws4_request, signedheaders=",
    ]
    if content_type.byte_length() > 0:
        want.append("content-type: " + content_type)
    for i in range(len(want)):
        assert_true(wire.find(want[i]) >= 0, want[i] + " is not in " + wire)
    if content_type.byte_length() == 0:
        assert_true(wire.find("content-type") < 0, wire)


comptime _JSON = "application/json"


def test_add_permission_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.add_permission(_permission())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "AddPermission"), "post /2015-03-31/functions/jobs/policy", _JSON)


def test_create_function_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_function(_create())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateFunction"), "post /2015-03-31/functions", _JSON)


def test_create_function_url_config_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_function_url_config(LambdaCreateFunctionUrlConfigRequest(String("jobs"), String("AWS_IAM")))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateFunctionUrlConfig"), "post /2021-10-31/functions/jobs/url", _JSON)


def test_delete_function_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.delete_function(LambdaDeleteFunctionRequest(String("jobs")))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "DeleteFunction"), "delete /2015-03-31/functions/jobs", "")


def test_get_function_on_the_wire() raises:
    var client = _client(_mk_echo)
    var input = LambdaGetFunctionRequest(String("jobs"))
    input.set_qualifier(String("live"))
    try:
        _ = client.get_function(input)
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetFunction"), "get /2015-03-31/functions/jobs?qualifier=live", "")


def test_get_function_url_config_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.get_function_url_config(LambdaGetFunctionUrlConfigRequest(String("jobs")))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetFunctionUrlConfig"), "get /2021-10-31/functions/jobs/url", "")


def test_invoke_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.invoke(_invoke())
        raise Error("the echo answered nothing")
    except e:
        var wire = _wire_of(String(e), "Invoke")
        _check(wire, "post /2015-03-31/functions/jobs/invocations", "application/octet-stream")
        assert_true(wire.find("x-amz-invocation-type: requestresponse") >= 0, wire)
        assert_true(wire.find("signedheaders=content-type;host;x-amz-date;x-amz-invocation-type,") >= 0, wire)


def test_put_function_concurrency_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.put_function_concurrency(LambdaPutFunctionConcurrencyRequest(String("jobs"), Int32(5)))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "PutFunctionConcurrency"), "put /2017-10-31/functions/jobs/concurrency", _JSON)


def test_update_function_code_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.update_function_code(_code())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "UpdateFunctionCode"), "put /2015-03-31/functions/jobs/code", _JSON)


def test_update_function_configuration_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.update_function_configuration(_configuration())
        raise Error("the echo answered nothing")
    except e:
        _check(
            _wire_of(String(e), "UpdateFunctionConfiguration"),
            "put /2015-03-31/functions/jobs/configuration",
            _JSON,
        )


def test_update_function_url_config_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.update_function_url_config(_url_update())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "UpdateFunctionUrlConfig"), "put /2021-10-31/functions/jobs/url", _JSON)


def main() raises:
    test_get_function_answered()
    test_invoke_answered()
    test_invoke_of_a_function_that_failed_returns()
    test_add_permission_conflict()
    test_create_function_conflict()
    test_create_function_url_config_conflict()
    test_update_function_code_conflict()
    test_update_function_configuration_conflict()
    test_get_function_not_found()
    test_get_function_url_config_not_found()
    test_update_function_url_config_not_found()
    test_invoke_not_found()
    test_delete_function_not_found()
    test_put_function_concurrency_invalid()
    test_add_permission_on_the_wire()
    test_create_function_on_the_wire()
    test_create_function_url_config_on_the_wire()
    test_delete_function_on_the_wire()
    test_get_function_on_the_wire()
    test_get_function_url_config_on_the_wire()
    test_invoke_on_the_wire()
    test_put_function_concurrency_on_the_wire()
    test_update_function_code_on_the_wire()
    test_update_function_configuration_on_the_wire()
    test_update_function_url_config_on_the_wire()
    print("OK")
