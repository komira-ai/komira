# =============================================================================
# tests/test_aws_secret_writer.mojo: the writer's refusals, its
# create-if-absent race and its probe, over scripted answers.
# =============================================================================
#
# No socket. The generated client calls its connector factory once per
# operation, and a factory is a thin function, so a sequence of answers is
# served by a factory that counts its own calls in a process-global
# komira_counters `GlobalCounter` (`_DIALS`) and answers call k with script
# k; a call past the script raises "dialled too often". `_no_dial` raises
# "dialled" on any call, so a refusal that leaked a send would raise that
# instead. The service's behaviour (versions, staging labels,
# create-if-absent, deletion) is the subject of komira_secrets_e2e's
# test_aws_store_registry, over a stateful fake on a real socket.
#
# What each test catches:
#   * test_writer_refusals_send_nothing: a deploy token ignored, a handle
#     with a selector written, an ARN defined, a non-UTF-8 value sent, a
#     handle outside the grammar sent; the writer conforms to
#     `SecretWriter` (called through a generic).
#   * test_write_create_race: PutSecretValue answered
#     ResourceNotFoundException, then CreateSecret answered
#     ResourceExistsException (another writer created the secret in
#     between), then PutSecretValue answered 200: the write succeeds after
#     exactly three sends. Red under "raise on any create error" (the write
#     raises) and under "return after the create" (two sends).
#   * test_write_create_other_error: the same, but CreateSecret answered
#     AccessDeniedException: the write raises naming the handle and the
#     code, after two sends. Red under "swallow any create error".
#   * test_has_version_reads_awscurrent: DescribeSecret answers in which
#     only AWSPENDING (or AWSPREVIOUS) is held answer False, AWSCURRENT on
#     any version answers True, no versions and ResourceNotFoundException
#     answer False, and AccessDeniedException and a secret scheduled for
#     deletion raise. Red under "any stage counts".
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from kci_secret_writer import SecretWriter
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerClient,
    SecretsManagerEndpointConfig,
)
from komira_counters.global_counter import GlobalCounter
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretValue

from kci_aws_secret_writer import AwsSecretsManagerWriter

comptime _DIALS = GlobalCounter["kci_aws_secret_writer_test_dials"]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String) -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _bytes(
                String("HTTP/1.1 ")
                + String(status)
                + " "
                + reason
                + "\r\nContent-Type: application/x-amz-json-1.1\r\nContent-Length: "
                + String(body.byte_length())
                + "\r\nConnection: close\r\n"
                + "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890aa\r\n\r\n"
                + body
            )
        )
    )


def _error(code: String, message: String) -> ScriptedConnector:
    return _answer(
        400,
        "Bad Request",
        String('{"__type":"') + code + '","Message":"' + message + '"}',
    )


def _put_ok() -> ScriptedConnector:
    return _answer(
        200,
        "OK",
        '{"ARN":"arn:aws:secretsmanager:us-east-1:000000000000:secret:app/db-AbCdEf",'
        + '"Name":"app/db","VersionId":"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111",'
        + '"VersionStages":["AWSCURRENT"]}',
    )


def _not_found() -> ScriptedConnector:
    return _error(
        String("ResourceNotFoundException"),
        String("Secrets Manager can't find the specified secret."),
    )


def _race() raises -> ScriptedConnector:
    """Put: not found; Create: the name is taken; Put: 200."""
    var k = _DIALS.read()
    _DIALS.incr()
    if k == 0:
        return _not_found()
    if k == 1:
        return _error(
            String("ResourceExistsException"),
            String("The operation failed because the secret app/db already exists."),
        )
    if k == 2:
        return _put_ok()
    raise Error("dialled too often")


def _create_denied() raises -> ScriptedConnector:
    """Put: not found; Create: access denied."""
    var k = _DIALS.read()
    _DIALS.incr()
    if k == 0:
        return _not_found()
    if k == 1:
        return _error(
            String("AccessDeniedException"),
            String("User is not authorized to perform secretsmanager:CreateSecret"),
        )
    raise Error("dialled too often")


def _no_dial() raises -> ScriptedConnector:
    raise Error("dialled")


def _described(body: String) -> ScriptedConnector:
    return _answer(200, "OK", body)


def _pending_only() raises -> ScriptedConnector:
    return _described(
        '{"Name":"app/db","VersionIdsToStages":'
        + '{"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111":["AWSPENDING"]}}'
    )


def _previous_and_pending() raises -> ScriptedConnector:
    return _described(
        '{"Name":"app/db","VersionIdsToStages":'
        + '{"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111":["AWSPREVIOUS"],'
        + '"a1b2c3d4-5678-90ab-cdef-EXAMPLE22222":["AWSPENDING"]}}'
    )


def _current_second() raises -> ScriptedConnector:
    return _described(
        '{"Name":"app/db","VersionIdsToStages":'
        + '{"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111":["AWSPREVIOUS"],'
        + '"a1b2c3d4-5678-90ab-cdef-EXAMPLE22222":["AWSPENDING","AWSCURRENT"]}}'
    )


def _no_versions() raises -> ScriptedConnector:
    return _described('{"Name":"app/db"}')


def _missing() raises -> ScriptedConnector:
    return _not_found()


def _denied() raises -> ScriptedConnector:
    return _error(
        String("AccessDeniedException"),
        String("User is not authorized to perform secretsmanager:DescribeSecret"),
    )


def _deleted() raises -> ScriptedConnector:
    return _described(
        '{"Name":"app/db","DeletedDate":1790812800.0,"VersionIdsToStages":'
        + '{"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111":["AWSCURRENT"]}}'
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


def _write[W: SecretWriter](
    mut w: W, secret_ref: String, value: String, token: String
) raises:
    w.write(secret_ref, SecretValue.from_string(value), token)


def test_writer_refusals_send_nothing() raises:
    var w = AwsSecretsManagerWriter(_client(_no_dial))
    var texts = List[String]()
    try:
        _write(w, String("app/db"), String("v"), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    try:
        _ = w.has_version(String("app/db"), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    try:
        w.define_container(String("app/db"), String("deploy-bearer-canary"))
    except e:
        texts.append(String(e))
    for i in range(len(texts)):
        assert_true(texts[i].find("refused: a deploy token was given") >= 0, texts[i])
        assert_false(texts[i].find("deploy-bearer-canary") >= 0, texts[i])
    assert_equal(len(texts), 3)

    with assert_raises(contains="write refused: the handle pins a version"):
        _write(w, String("app/db?versionStage=AWSPREVIOUS"), String("v"), String(""))
    with assert_raises(contains="has_version refused: the handle pins a version"):
        _ = w.has_version(String("app/db?versionId=a1b2c3d4-5678-90ab-cdef-EXAMPLE11111"), String(""))
    with assert_raises(contains="define_container refused: the handle is an ARN"):
        w.define_container(
            String("arn:aws:secretsmanager:us-east-1:000000000000:secret:app/db-AbCdEf"), String("")
        )
    var pasted = String("")
    try:
        _write(w, String('{"password":"pasted-canary"}'), String("v"), String(""))
    except e:
        pasted = String(e)
    assert_true(pasted.startswith("AwsSecretsManagerWriter: write refused: secret_ref is not a secret name"), pasted)
    assert_false(pasted.find("pasted-canary") >= 0, pasted)
    var not_utf8 = List[UInt8]()
    not_utf8.append(UInt8(0xFF))
    not_utf8.append(UInt8(0xFE))
    with assert_raises(contains="refused: the value is not UTF-8"):
        w.write(String("app/db"), SecretValue(Span(not_utf8)), String(""))
    # Every refusal above came before a send: the factory was never called.
    with assert_raises(contains="dialled"):
        _ = w.has_version(String("app/db"), String(""))
    print("  test_writer_refusals_send_nothing PASS")


def test_write_create_race() raises:
    _DIALS.reset()
    var w = AwsSecretsManagerWriter(_client(_race))
    _write(w, String("app/db"), String("raced-value"), String(""))
    assert_equal(_DIALS.read(), 3, "Put, Create, Put")
    print("  test_write_create_race PASS")


def test_write_create_other_error() raises:
    _DIALS.reset()
    var w = AwsSecretsManagerWriter(_client(_create_denied))
    var text = String("")
    try:
        _write(w, String("app/db"), String("denied-canary-value"), String(""))
    except e:
        text = String(e)
    assert_true(
        text.startswith(
            "AwsSecretsManagerWriter: write of secret_ref app/db failed:"
            " SecretsManager.CreateSecret failed: HTTP 400 AccessDeniedException"
        ),
        text,
    )
    assert_false(text.find("denied-canary-value") >= 0, text)
    assert_equal(_DIALS.read(), 2, "Put, Create, and no second Put")
    print("  test_write_create_other_error PASS")


def test_has_version_reads_awscurrent() raises:
    var pending = AwsSecretsManagerWriter(_client(_pending_only))
    assert_false(
        pending.has_version(String("app/db"), String("")),
        "a version labelled only AWSPENDING is not what the bare handle reads",
    )
    var older = AwsSecretsManagerWriter(_client(_previous_and_pending))
    assert_false(older.has_version(String("app/db"), String("")))
    var current = AwsSecretsManagerWriter(_client(_current_second))
    assert_true(current.has_version(String("app/db"), String("")))
    var empty = AwsSecretsManagerWriter(_client(_no_versions))
    assert_false(empty.has_version(String("app/db"), String("")))
    var missing = AwsSecretsManagerWriter(_client(_missing))
    assert_false(missing.has_version(String("app/db"), String("")))

    var denied = AwsSecretsManagerWriter(_client(_denied))
    with assert_raises(
        contains="has_version of secret_ref app/db failed: SecretsManager.DescribeSecret failed: HTTP 400 AccessDeniedException"
    ):
        _ = denied.has_version(String("app/db"), String(""))
    var deleted = AwsSecretsManagerWriter(_client(_deleted))
    with assert_raises(
        contains="has_version of secret_ref app/db failed: the secret is scheduled for deletion"
    ):
        _ = deleted.has_version(String("app/db"), String(""))
    print("  test_has_version_reads_awscurrent PASS")


def main() raises:
    # Each leg runs; the failures are raised together at the end, so one
    # red run names every failing leg.
    var failed = List[String]()
    try:
        test_writer_refusals_send_nothing()
    except e:
        failed.append(String("test_writer_refusals_send_nothing: ") + String(e))
    try:
        test_write_create_race()
    except e:
        failed.append(String("test_write_create_race: ") + String(e))
    try:
        test_write_create_other_error()
    except e:
        failed.append(String("test_write_create_other_error: ") + String(e))
    try:
        test_has_version_reads_awscurrent()
    except e:
        failed.append(String("test_has_version_reads_awscurrent: ") + String(e))
    if len(failed) > 0:
        var text = String("FAILED:")
        for i in range(len(failed)):
            text += String("\n  ") + failed[i]
        raise Error(text)
    print("PASS kci_aws_secret_writer")
