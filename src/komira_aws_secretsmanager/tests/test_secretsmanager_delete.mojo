# DeleteSecret through its hand-written owner, secretsmanager_overrides, over
# the generated client and komira_http_core's ScriptedConnector (no socket).
#
# Rows: a recovery window together with a forced delete is refused, and so
# is a window of 3 or of 31 days, each before a connection is made (the
# connector factory raises if called); a window of 7 or of 30 days, a forced
# delete and a delete with neither are sent and their answers decoded. A
# CreateSecret refused because the name is held by a secret scheduled for
# deletion is recognised as that, and a plain name collision is not.
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerCreateSecretRequest,
    SecretsManagerDeleteSecretRequest,
    SecretsManagerDeleteSecretResponse,
    SecretsManagerEndpointConfig,
    SecretsManagerClient,
)
from komira_aws_secretsmanager.secretsmanager_overrides import (
    delete_secret,
    secret_name_is_scheduled_for_deletion,
)
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String) -> ScriptedStream:
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 ")
            + String(status)
            + " "
            + reason
            + "\r\nContent-Type: application/x-amz-json-1.1\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n\r\n"
            + body
        )
    )


def _mk_deleted() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"ARN":"arn:aws:secretsmanager:us-east-1:000000000000:secret:app/db-AbCdEf","Name":"app/db","DeletionDate":1790812800.0}',
        )
    )


def _mk_never() raises -> ScriptedConnector:
    raise Error("no connection was to be made")


def _mk_held() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"__type":"InvalidRequestException","Message":"You can\'t create this secret because a secret with this name is already scheduled for deletion."}',
        )
    )


def _mk_exists() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"__type":"ResourceExistsException","Message":"The operation failed because the secret app/db already exists."}',
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> SecretsManagerClient[C, StaticCredsSource]:
    var config = SecretsManagerEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return SecretsManagerClient[C, StaticCredsSource](
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


def _request(window: Optional[Int64], force: Optional[Bool]) -> SecretsManagerDeleteSecretRequest:
    var r = SecretsManagerDeleteSecretRequest(String("app/db"))
    r.recovery_window_in_days = window
    r.force_delete_without_recovery = force
    return r^


def test_a_window_with_a_forced_delete_is_refused() raises:
    var client = _client(_mk_never)
    with assert_raises(contains="ForceDeleteWithoutRecovery and RecoveryWindowInDays are mutually exclusive"):
        _ = delete_secret(client, _request(Optional[Int64](7), Optional[Bool](True)))


def test_a_window_outside_7_to_30_is_refused() raises:
    var client = _client(_mk_never)
    with assert_raises(contains="RecoveryWindowInDays is 3, and Secrets Manager accepts 7..30"):
        _ = delete_secret(client, _request(Optional[Int64](3), Optional[Bool]()))
    with assert_raises(contains="RecoveryWindowInDays is 31, and Secrets Manager accepts 7..30"):
        _ = delete_secret(client, _request(Optional[Int64](31), Optional[Bool](False)))


def test_an_accepted_delete_is_sent() raises:
    var requests: List[SecretsManagerDeleteSecretRequest] = [
        _request(Optional[Int64](7), Optional[Bool]()),
        _request(Optional[Int64](30), Optional[Bool](False)),
        _request(Optional[Int64](), Optional[Bool](True)),
        _request(Optional[Int64](), Optional[Bool]()),
    ]
    for i in range(len(requests)):
        var client = _client(_mk_deleted)
        var out: SecretsManagerDeleteSecretResponse
        try:
            out = delete_secret(client, requests[i])
        except e:
            raise Error(String("row ") + String(i) + ": " + String(e))
        assert_equal(out.name.value(), "app/db")
        assert_true(Bool(out.deletion_date))


def test_a_name_held_by_a_deletion_is_recognised() raises:
    var held = _client(_mk_held)
    var text = String("")
    try:
        _ = held.create_secret(SecretsManagerCreateSecretRequest(String("app/db")))
    except e:
        text = String(e)
    assert_true(secret_name_is_scheduled_for_deletion(text), text)

    var exists = _client(_mk_exists)
    text = String("")
    try:
        _ = exists.create_secret(SecretsManagerCreateSecretRequest(String("app/db")))
    except e:
        text = String(e)
    assert_true(text.find("ResourceExistsException") >= 0, text)
    assert_false(secret_name_is_scheduled_for_deletion(text), text)


def main() raises:
    test_a_window_with_a_forced_delete_is_refused()
    test_a_window_outside_7_to_30_is_refused()
    test_an_accepted_delete_is_sent()
    test_a_name_held_by_a_deletion_is_recognised()
    print("OK")
