# The generated EventBridge Scheduler client (`SchedulerSchedulerClient`)
# end to end over komira_http_client and komira_http_core's
# ScriptedConnector (no socket).
#
# Every verb meets one error answer and raises it under the restJson1 code
# the service names in `X-Amzn-Errortype`, with the body's `Message`: a
# create that conflicts (409), a read and a delete of a missing schedule
# (404), an update the service refuses (400). None is a status or code
# botocore retries, so each call is one request. Two verbs are answered
# successfully.
#
# Then each verb's request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an error naming the
# request head, so each row asserts the request line (method, path and
# query), the Host the endpoint ruleset resolved, the content type of a
# request with a body, and the SigV4 scope (signing name `scheduler`).
from komira_aws_scheduler.komira_aws_scheduler import (
    SchedulerCreateScheduleInput,
    SchedulerDeleteScheduleInput,
    SchedulerEndpointConfig,
    SchedulerFlexibleTimeWindow,
    SchedulerGetScheduleInput,
    SchedulerSchedulerClient,
    SchedulerTarget,
    SchedulerUpdateScheduleInput,
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


comptime _FN = "arn:aws:lambda:us-east-1:123456789012:function:reaper"
comptime _ROLE = "arn:aws:iam::123456789012:role/scheduler-invoke"
comptime _ARN = "arn:aws:scheduler:us-east-1:123456789012:schedule/apps/nightly-reap"


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
        _answer(200, "OK", String('{"ScheduleArn":"') + _ARN + '"}', "")
    )


def _mk_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            String('{"Arn":"')
            + _ARN
            + '","Name":"nightly-reap","GroupName":"apps","State":"ENABLED",'
            + '"ScheduleExpression":"cron(0 3 * * ? *)","FlexibleTimeWindow":{"Mode":"OFF"},'
            + '"Target":{"Arn":"'
            + _FN
            + '","RoleArn":"'
            + _ROLE
            + '"}}',
            "",
        )
    )


def _mk_conflict() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            409,
            "Conflict",
            '{"Message":"Schedule nightly-reap already exists."}',
            "X-Amzn-Errortype: ConflictException:http://internal.amazon.com/coral/com.amazonaws.chronos/\r\n",
        )
    )


def _mk_not_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            '{"Message":"Schedule nightly-reap does not exist."}',
            "X-Amzn-Errortype: ResourceNotFoundException\r\n",
        )
    )


def _mk_invalid() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"Message":"Invalid request: FlexibleTimeWindow is required."}',
            "X-Amzn-Errortype: ValidationException\r\n",
        )
    )


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.json()


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> SchedulerSchedulerClient[C, StaticCredsSource]:
    var config = SchedulerEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return SchedulerSchedulerClient[C, StaticCredsSource](
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


def _off() -> SchedulerFlexibleTimeWindow:
    return SchedulerFlexibleTimeWindow(String("OFF"))


def _create() -> SchedulerCreateScheduleInput:
    var input = SchedulerCreateScheduleInput(
        _off(), String("nightly-reap"), String("cron(0 3 * * ? *)"), SchedulerTarget(String(_FN), String(_ROLE))
    )
    input.set_group_name(String("apps"))
    return input^


def _update() -> SchedulerUpdateScheduleInput:
    var input = SchedulerUpdateScheduleInput(
        _off(), String("nightly-reap"), String("cron(0 4 * * ? *)"), SchedulerTarget(String(_FN), String(_ROLE))
    )
    input.set_group_name(String("apps"))
    return input^


def _get() -> SchedulerGetScheduleInput:
    var input = SchedulerGetScheduleInput(String("nightly-reap"))
    input.set_group_name(String("apps"))
    return input^


def _delete() -> SchedulerDeleteScheduleInput:
    var input = SchedulerDeleteScheduleInput(String("nightly-reap"))
    input.set_group_name(String("apps"))
    return input^


# ---- answered ----------------------------------------------------------------


def test_create_schedule_answered() raises:
    var client = _client(_mk_created)
    assert_equal(client.create_schedule(_create()).schedule_arn, _ARN)


def test_get_schedule_answered() raises:
    var client = _client(_mk_found)
    var out = client.get_schedule(_get())
    assert_equal(out.arn.value(), _ARN)
    assert_equal(out.state.value(), "ENABLED")
    assert_equal(out.target.value().role_arn, _ROLE)


# ---- one error per verb ------------------------------------------------------


def test_create_schedule_conflict() raises:
    var client = _client(_mk_conflict)
    with assert_raises(
        contains="CreateSchedule failed: HTTP 409 ConflictException Schedule nightly-reap already exists."
    ):
        _ = client.create_schedule(_create())


def test_get_schedule_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(
        contains="GetSchedule failed: HTTP 404 ResourceNotFoundException Schedule nightly-reap does not exist."
    ):
        _ = client.get_schedule(_get())


def test_update_schedule_invalid() raises:
    var client = _client(_mk_invalid)
    with assert_raises(
        contains=(
            "UpdateSchedule failed: HTTP 400 ValidationException Invalid request:"
            " FlexibleTimeWindow is required."
        )
    ):
        _ = client.update_schedule(_update())


def test_delete_schedule_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(
        contains="DeleteSchedule failed: HTTP 404 ResourceNotFoundException Schedule nightly-reap does not exist."
    ):
        _ = client.delete_schedule(_delete())


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
        "/us-east-1/scheduler/aws4_request, signedheaders=",
    ]
    if has_body:
        want.append("content-type: application/json")
    for i in range(len(want)):
        assert_true(wire.find(want[i]) >= 0, want[i] + " is not in " + wire)
    if not has_body:
        assert_true(wire.find("content-type") < 0, wire)


def test_create_schedule_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_schedule(_create())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateSchedule"), "post /schedules/nightly-reap", True)


def test_get_schedule_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.get_schedule(_get())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetSchedule"), "get /schedules/nightly-reap?groupname=apps", False)


def test_update_schedule_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.update_schedule(_update())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "UpdateSchedule"), "put /schedules/nightly-reap", True)


def test_delete_schedule_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.delete_schedule(_delete())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "DeleteSchedule"), "delete /schedules/nightly-reap?groupname=apps", False)


def main() raises:
    test_create_schedule_answered()
    test_get_schedule_answered()
    test_create_schedule_conflict()
    test_get_schedule_not_found()
    test_update_schedule_invalid()
    test_delete_schedule_not_found()
    test_create_schedule_on_the_wire()
    test_get_schedule_on_the_wire()
    test_update_schedule_on_the_wire()
    test_delete_schedule_on_the_wire()
    print("OK")
