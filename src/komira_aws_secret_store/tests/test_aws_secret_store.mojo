# =============================================================================
# tests/test_aws_secret_store.mojo: the handle grammar and the store over a
# scripted answer.
# =============================================================================
#
# No socket: the generated client sends over komira_http_core's
# ScriptedConnector, whose one canned answer each test chooses, or over a
# connector factory that raises "dialled" (`_no_dial`), so a refusal that
# leaked a send would raise that instead. The service itself (versions,
# staging labels, a secret scheduled for deletion) is the subject of
# komira_secrets_e2e's test_aws_store_registry, over a stateful fake on a
# real socket. The writer's tests are kci_aws_secret_writer's.
#
# What each test catches:
#   * test_handle_grammar: a selector mapped to the wrong field, a second
#     selector or an unknown one accepted, an empty SecretId or value
#     accepted, a refusal that quotes the handle.
#   * test_handle_shapes: a name outside `[A-Za-z0-9/_+=.@-]{1,512}` (a
#     pasted value, a space, an over-long name) accepted, a partial or
#     malformed ARN accepted, a versionId or label outside its set
#     accepted, a refusal that quotes the handle; and the edges that must
#     pass (512 bytes, every allowed character, a GovCloud ARN).
#   * test_resolve_secret_string / _secret_binary: the value taken from the
#     wrong member, or SecretBinary ignored; the store conforms to
#     `SecretStore` (called through a generic).
#   * test_resolve_neither_member: an answer with no value returned as an
#     empty value instead of raising.
#   * test_resolve_error_names_the_handle: an error answer swallowed, or
#     its body (which carries a canary value) put into the raised text; a
#     handle outside the grammar sent.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerClient,
    SecretsManagerEndpointConfig,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretStore, SecretValue

from komira_aws_secret_store import AwsSecretsManagerStore, parse_aws_secret_ref


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
            + "\r\nConnection: close\r\n"
            + "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890aa\r\n\r\n"
            + body
        )
    )


def _string_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"ARN":"arn:aws:secretsmanager:us-east-1:000000000000:secret:app/db-AbCdEf",'
            + '"Name":"app/db","VersionId":"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111",'
            + '"SecretString":"s3cr3t-text","VersionStages":["AWSCURRENT"]}',
        )
    )


def _binary_answer() raises -> ScriptedConnector:
    # "aGVsbG8tYmluYXJ5" is base64 of "hello-binary".
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"Name":"app/blob","VersionId":"a1b2c3d4-5678-90ab-cdef-EXAMPLE22222",'
            + '"SecretBinary":"aGVsbG8tYmluYXJ5","VersionStages":["AWSCURRENT"]}',
        )
    )


def _empty_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(200, "OK", '{"Name":"app/none","VersionStages":["AWSCURRENT"]}')
    )


def _missing_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"__type":"ResourceNotFoundException","Message":"Secrets Manager'
            + " can't find the specified secret.\",\"SecretString\":\"leak-canary-71\"}",
        )
    )


def _no_dial() raises -> ScriptedConnector:
    raise Error("dialled")


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


def _text(v: SecretValue) -> String:
    var out = List[UInt8]()
    out.extend(v.revealed_bytes())
    return String(unsafe_from_utf8=Span(out))


def _resolve[S: SecretStore](mut store: S, secret_ref: String) raises -> SecretValue:
    return store.resolve(secret_ref)


def test_handle_grammar() raises:
    var plain = parse_aws_secret_ref(String("app/db"))
    assert_equal(plain.secret_id, "app/db")
    assert_true(plain.is_plain())
    assert_equal(String(plain), "app/db")

    var arn = parse_aws_secret_ref(
        String("arn:aws:secretsmanager:us-east-1:000000000000:secret:app/db-AbCdEf")
    )
    assert_equal(arn.secret_id, "arn:aws:secretsmanager:us-east-1:000000000000:secret:app/db-AbCdEf")
    assert_true(arn.is_plain())

    var stage = parse_aws_secret_ref(String("app/db?versionStage=AWSPREVIOUS"))
    assert_equal(stage.secret_id, "app/db")
    assert_false(Bool(stage.version_id))
    assert_equal(stage.version_stage.value(), "AWSPREVIOUS")
    assert_false(stage.is_plain())
    assert_equal(String(stage), "app/db?versionStage=AWSPREVIOUS")

    var vid = parse_aws_secret_ref(String("app/db?versionId=a1b2c3d4-5678-90ab-cdef-EXAMPLE11111"))
    assert_equal(vid.version_id.value(), "a1b2c3d4-5678-90ab-cdef-EXAMPLE11111")
    assert_false(Bool(vid.version_stage))

    var refused: List[String] = [
        "",
        "?versionStage=AWSCURRENT",
        "canary-zz9?versionStage=",
        "canary-zz9?versionId=x&versionStage=y",
        "canary-zz9?versionStage=a?b",
        "canary-zz9?label=AWSCURRENT",
        "canary-zz9?versionStage",
    ]
    var why: List[String] = [
        "secret_ref is empty",
        "names no secret before its '?'",
        "versionStage is empty",
        "more than one selector",
        "more than one selector",
        "neither versionId nor versionStage",
        "has no '='",
    ]
    for i in range(len(refused)):
        var text = String("")
        try:
            _ = parse_aws_secret_ref(refused[i])
        except e:
            text = String(e)
        assert_true(text.find(why[i]) >= 0, text)
        assert_false(text.find("canary-zz9") >= 0, text)
    print("  test_handle_grammar PASS")


def test_resolve_secret_string() raises:
    var store = AwsSecretsManagerStore(_client(_string_answer))
    var v = _resolve(store, String("app/db"))
    assert_equal(_text(v), "s3cr3t-text")
    assert_equal(String(v), "SecretValue(<redacted:11B>)")
    print("  test_resolve_secret_string PASS")


def test_resolve_secret_binary() raises:
    var store = AwsSecretsManagerStore(_client(_binary_answer))
    assert_equal(_text(_resolve(store, String("app/blob"))), "hello-binary")
    print("  test_resolve_secret_binary PASS")


def test_resolve_neither_member() raises:
    var store = AwsSecretsManagerStore(_client(_empty_answer))
    with assert_raises(
        contains="resolve of secret_ref app/none failed: the answer holds neither a SecretString nor a SecretBinary"
    ):
        _ = store.resolve(String("app/none"))
    print("  test_resolve_neither_member PASS")


def test_resolve_error_names_the_handle() raises:
    var store = AwsSecretsManagerStore(_client(_missing_answer))
    var text = String("")
    try:
        _ = store.resolve(String("app/gone"))
    except e:
        text = String(e)
    assert_true(
        text.startswith(
            "AwsSecretsManagerStore: resolve of secret_ref app/gone failed:"
            " SecretsManager.GetSecretValue failed: HTTP 400 ResourceNotFoundException"
        ),
        text,
    )
    assert_false(text.find("leak-canary-71") >= 0, text)
    # A handle outside the grammar is refused before any send.
    var none = AwsSecretsManagerStore(_client(_no_dial))
    text = String("")
    try:
        _ = none.resolve(String("app/db?stage=x"))
    except e:
        text = String(e)
    assert_true(text.startswith("AwsSecretsManagerStore: secret_ref's selector"), text)
    print("  test_resolve_error_names_the_handle PASS")


def _refusal(secret_ref: String) -> String:
    try:
        _ = parse_aws_secret_ref(secret_ref)
    except e:
        return String(e)
    return String("accepted")


def test_handle_shapes() raises:
    var long_name = String("")
    for _ in range(512):
        long_name += "a"
    assert_equal(parse_aws_secret_ref(long_name).secret_id, long_name)
    assert_equal(
        parse_aws_secret_ref(String("a/b_c+d=e.f@g-h0Z")).secret_id, "a/b_c+d=e.f@g-h0Z"
    )
    var gov = String("arn:aws-us-gov:secretsmanager:us-gov-west-1:123456789012:secret:app/db-a1B2c3")
    assert_equal(parse_aws_secret_ref(gov).secret_id, gov)
    assert_equal(
        parse_aws_secret_ref(gov + "?versionStage=AWSPENDING").version_stage.value(),
        "AWSPENDING",
    )

    var refused: List[String] = [
        # A pasted value: JSON, a space, a quote, a newline, a non-ASCII byte.
        '{"password":"canary-zz9"}',
        "canary-zz9 x",
        "canary-zz9'",
        "canary-zz9\n",
        "canary-zz9é",
        "canary-zz9#",
        long_name + "canary-zz9",
        # ARNs: partial (no suffix), wrong service, account, partition,
        # region, resource type, suffix; a name outside the set.
        "arn:aws:secretsmanager:us-east-1:000000000000:secret:canary-zz9",
        "arn:aws:s3:us-east-1:000000000000:secret:canary-zz9-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:00000000000:secret:canary-zz9-AbCdEf",
        "arn:AWS:secretsmanager:us-east-1:000000000000:secret:canary-zz9-AbCdEf",
        "arn:aws:secretsmanager:US-EAST-1:000000000000:secret:canary-zz9-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:000000000000:key:canary-zz9-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:000000000000:secret:canary-zz9-AbC#ef",
        "arn:aws:secretsmanager:us-east-1:000000000000:secret:canary zz9-AbCdEf",
        # Selector values outside their sets.
        "app/db?versionId=canary-zz9",
        "app/db?versionId=canary-zz9_000000000000000000000000000",
        "app/db?versionStage=canary zz9",
    ]
    var why: List[String] = [
        "is not a secret name",
        "is not a secret name",
        "is not a secret name",
        "is not a secret name",
        "is not a secret name",
        "is not a secret name",
        "is not a secret name",
        "not a full Secrets Manager secret ARN",
        "not a full Secrets Manager secret ARN",
        "not a full Secrets Manager secret ARN",
        "not a full Secrets Manager secret ARN",
        "not a full Secrets Manager secret ARN",
        "not a full Secrets Manager secret ARN",
        "not a full Secrets Manager secret ARN",
        "not a full Secrets Manager secret ARN",
        "versionId is not 32 to 64",
        "versionId is not 32 to 64",
        "versionStage is not 1 to 256",
    ]
    assert_equal(len(refused), len(why))
    for i in range(len(refused)):
        var text = _refusal(refused[i])
        assert_true(text.find(why[i]) >= 0, String(i) + ": " + text)
        assert_false(text.find("canary") >= 0, text)
    print("  test_handle_shapes PASS")


def main() raises:
    test_handle_grammar()
    test_resolve_secret_string()
    test_resolve_secret_binary()
    test_resolve_neither_member()
    test_resolve_error_names_the_handle()
    test_handle_shapes()
    print("PASS komira_aws_secret_store")
