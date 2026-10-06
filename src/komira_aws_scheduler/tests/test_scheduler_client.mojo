# The generated EventBridge Scheduler client (`SchedulerClient`)
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
#
# Last, `ClientToken`, which the model marks an idempotency token on
# CreateSchedule, UpdateSchedule and DeleteSchedule. Each verb meets a 500
# and is resent (the standard retry mode resends a 500 whatever the verb),
# over its `_with` form and a transport that records each attempt. An unset
# token is filled, as botocore does, with one version 4 UUID per call: the
# same token rides on both attempts, so the service can recognise the
# resend as the same call, and the next call draws a new one. On
# DeleteSchedule the token is bound to the query (`clientToken`), and is
# filled there. A token the caller set rides on both attempts, unchanged.
from komira_aws_scheduler.komira_aws_scheduler import (
    SchedulerCreateScheduleInput,
    SchedulerDeleteScheduleInput,
    SchedulerEndpointConfig,
    SchedulerFlexibleTimeWindow,
    SchedulerGetScheduleInput,
    SchedulerClient,
    SchedulerTarget,
    SchedulerUpdateScheduleInput,
)
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsConnectorTransport,
    AwsCredential,
    AwsEchoConnector,
    AwsHttpTransport,
    AwsRetryQuota,
    CredentialHttpRequest,
    FixedClock,
    HttpResult,
    StaticCredsSource,
    aws_standard_retry_policy,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock, RecordingSleeper, RetryLoop, SplitMix64Rng
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
            "X-Amzn-Errortype: ConflictException:http://example.com/doc/scheduler/\r\n",
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
) raises -> SchedulerClient[C, StaticCredsSource]:
    var config = SchedulerEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return SchedulerClient[C, StaticCredsSource](
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
    # The unset `ClientToken` is filled, and rides on the query ahead of
    # `groupName`, as the builder adds them; its value is a fresh UUID.
    var client = _client(_mk_echo)
    try:
        _ = client.delete_schedule(_delete())
        raise Error("the echo answered nothing")
    except e:
        var wire = _wire_of(String(e), "DeleteSchedule")
        var head = String("delete /schedules/nightly-reap?clienttoken=")
        assert_true(wire.startswith(head), wire)
        var token = String(wire[byte = head.byte_length() : head.byte_length() + 36])
        _check_v4(token)
        _check(wire, head + token + "&groupname=apps", False)


# ---- ClientToken on a resent call -------------------------------------------


struct Recording[X: AwsHttpTransport](AwsHttpTransport, Movable, Deinitable):
    var inner: Self.X
    var sent: List[CredentialHttpRequest]

    def __init__(out self, var inner: Self.X):
        self.inner = inner^
        self.sent = List[CredentialHttpRequest]()

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self.sent.append(req.copy())
        return self.inner.send(req)


def _never() raises -> ScriptedConnector:
    raise Error("a verb over injected seams dialed through the factory")


comptime _CALLERS = "c0ffee00-0000-4000-8000-000000000001"


def _check_v4(token: String) raises:
    """`token` is a version 4 UUID in Python's `str(uuid.uuid4())` form:
    36 bytes, lowercase hex in 8-4-4-4-12 groups, version nibble 4 and
    variant 10xx."""
    assert_equal(token.byte_length(), 36, msg=token)
    var b = token.as_bytes()
    for i in range(36):
        var c = b[i]
        if i == 8 or i == 13 or i == 18 or i == 23:
            assert_equal(c, UInt8(ord("-")), msg=token)
        else:
            var hex = (c >= UInt8(ord("0")) and c <= UInt8(ord("9"))) or (
                c >= UInt8(ord("a")) and c <= UInt8(ord("f"))
            )
            assert_true(hex, token)
    assert_equal(b[14], UInt8(ord("4")), msg=token)
    var v = b[19]
    assert_true(
        v == UInt8(ord("8")) or v == UInt8(ord("9")) or v == UInt8(ord("a")) or v == UInt8(ord("b")),
        token,
    )


def _token_after(text: String, marker: String) raises -> String:
    """The 36 bytes after `marker` in `text`, which must hold it once."""
    var at = text.find(marker)
    assert_true(at >= 0, marker + " is not in " + text)
    assert_equal(text.find(marker, at + 1), -1, msg=text)
    var start = at + marker.byte_length()
    return String(text[byte = start : start + 36])


def _body_token(req: CredentialHttpRequest) raises -> String:
    return _token_after(req.body_text(), '"ClientToken":"')


def _query_token(req: CredentialHttpRequest) raises -> String:
    return _token_after(req.target, "clientToken=")


def _resent(ok_body: String) raises -> Recording[AwsConnectorTransport[ScriptedConnector]]:
    """A transport that answers 500 and then 200 with `ok_body`, and records
    each attempt as it reached the HTTP client."""
    var script = ScriptedConnector.with_stream(
        _answer(
            500,
            "Internal Server Error",
            '{"Message":"Unexpected error."}',
            "X-Amzn-Errortype: InternalServerException\r\n",
        )
    )
    script.arm_next(_answer(200, "OK", ok_body, ""))
    return Recording(AwsConnectorTransport[ScriptedConnector](HttpClientConfig.defaults(), script^))


def _loop() raises -> RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng]:
    return RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        aws_standard_retry_policy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(7)
    )


def _attempts(transport: Recording[AwsConnectorTransport[ScriptedConnector]]) raises -> List[CredentialHttpRequest]:
    assert_equal(len(transport.sent), 2)
    var out = List[CredentialHttpRequest]()
    for i in range(len(transport.sent)):
        out.append(transport.sent[i].copy())
    return out^


def _resent_create(input: SchedulerCreateScheduleInput) raises -> List[CredentialHttpRequest]:
    var transport = _resent(String('{"ScheduleArn":"') + _ARN + '"}')
    var clock = FixedClock(1790812800)
    var loop = _loop()
    var budget = AwsRetryQuota()
    var client = _client(_never)
    var res = client.create_schedule_with(input, transport, clock, loop, budget)
    assert_equal(res.status, 200)
    return _attempts(transport)


def _resent_update(input: SchedulerUpdateScheduleInput) raises -> List[CredentialHttpRequest]:
    var transport = _resent(String('{"ScheduleArn":"') + _ARN + '"}')
    var clock = FixedClock(1790812800)
    var loop = _loop()
    var budget = AwsRetryQuota()
    var client = _client(_never)
    var res = client.update_schedule_with(input, transport, clock, loop, budget)
    assert_equal(res.status, 200)
    return _attempts(transport)


def _resent_delete(input: SchedulerDeleteScheduleInput) raises -> List[CredentialHttpRequest]:
    var transport = _resent(String("{}"))
    var clock = FixedClock(1790812800)
    var loop = _loop()
    var budget = AwsRetryQuota()
    var client = _client(_never)
    var res = client.delete_schedule_with(input, transport, clock, loop, budget)
    assert_equal(res.status, 200)
    return _attempts(transport)


def test_a_resent_create_carries_the_callers_token() raises:
    var input = _create()
    input.set_client_token(String(_CALLERS))
    var sent = _resent_create(input)
    assert_equal(_body_token(sent[0]), _CALLERS)
    assert_equal(sent[1].body_text(), sent[0].body_text())


def test_an_unset_create_token_is_filled_once_per_call() raises:
    var first = _resent_create(_create())
    var token = _body_token(first[0])
    _check_v4(token)
    # The resend is the same bytes, token and all.
    assert_equal(first[1].body_text(), first[0].body_text())
    # The next call is a new create, under a new token.
    var second = _resent_create(_create())
    var again = _body_token(second[0])
    _check_v4(again)
    assert_true(again != token, again)
    assert_equal(_body_token(second[1]), again)


def test_an_unset_update_token_is_filled_once_per_call() raises:
    var first = _resent_update(_update())
    var token = _body_token(first[0])
    _check_v4(token)
    assert_equal(first[1].body_text(), first[0].body_text())
    var second = _resent_update(_update())
    var again = _body_token(second[0])
    _check_v4(again)
    assert_true(again != token, again)


def test_a_resent_update_carries_the_callers_token() raises:
    var input = _update()
    input.set_client_token(String(_CALLERS))
    var sent = _resent_update(input)
    assert_equal(_body_token(sent[0]), _CALLERS)
    assert_equal(sent[1].body_text(), sent[0].body_text())


def test_an_unset_delete_token_is_filled_on_the_query() raises:
    # DeleteSchedule binds ClientToken to the query string, and the fill is
    # before the request is built, so it rides there.
    var first = _resent_delete(_delete())
    var token = _query_token(first[0])
    _check_v4(token)
    assert_equal(first[0].target, String("/schedules/nightly-reap?clientToken=") + token + "&groupName=apps")
    assert_equal(first[1].target, first[0].target)
    var second = _resent_delete(_delete())
    var again = _query_token(second[0])
    _check_v4(again)
    assert_true(again != token, again)


def test_a_resent_delete_carries_the_callers_token() raises:
    var input = _delete()
    input.set_client_token(String(_CALLERS))
    var sent = _resent_delete(input)
    assert_equal(sent[0].target, String("/schedules/nightly-reap?clientToken=") + _CALLERS + "&groupName=apps")
    assert_equal(sent[1].target, sent[0].target)


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
    test_a_resent_create_carries_the_callers_token()
    test_an_unset_create_token_is_filled_once_per_call()
    test_an_unset_update_token_is_filled_once_per_call()
    test_a_resent_update_carries_the_callers_token()
    test_an_unset_delete_token_is_filled_on_the_query()
    test_a_resent_delete_carries_the_callers_token()
    print("OK")
