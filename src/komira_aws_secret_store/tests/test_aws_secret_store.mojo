# =============================================================================
# tests/test_aws_secret_store.mojo: the handle grammar, the store over a
# scripted answer, and the writer's refusals before anything is sent.
# =============================================================================
#
# No socket: the generated client sends over komira_http_core's
# ScriptedConnector, whose one canned answer each test chooses, or over a
# connector factory that raises "dialled" (`_no_dial`), so a refusal that
# leaked a send would raise that instead. The service itself (versions,
# staging labels, create-if-absent, a secret scheduled for deletion) is the
# subject of komira_secrets_e2e's test_aws_store_registry, over a stateful
# fake on a real socket.
#
# What each test catches:
#   * test_handle_grammar: a selector mapped to the wrong field, a second
#     selector or an unknown one accepted, an empty SecretId or value
#     accepted, a refusal that quotes the handle.
#   * test_resolve_secret_string / _secret_binary: the value taken from the
#     wrong member, or SecretBinary ignored; the store conforms to
#     `SecretStore` (called through a generic).
#   * test_resolve_neither_member: an answer with no value returned as an
#     empty value instead of raising.
#   * test_resolve_error_names_the_handle: an error answer swallowed, or
#     its body (which carries a canary value) put into the raised text.
#   * test_writer_refusals_send_nothing: a deploy token ignored, a handle
#     with a selector written, an ARN defined, a non-UTF-8 value sent; the
#     writer conforms to `SecretWriter` (called through a generic).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from kci_secret_writer import SecretWriter
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerClient,
    SecretsManagerEndpointConfig,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretStore, SecretValue

from komira_aws_secret_store import (
    AwsSecretsManagerStore,
    AwsSecretsManagerWriter,
    parse_aws_secret_ref,
)


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
    var not_utf8 = List[UInt8]()
    not_utf8.append(UInt8(0xFF))
    not_utf8.append(UInt8(0xFE))
    with assert_raises(contains="refused: the value is not UTF-8"):
        w.write(String("app/db"), SecretValue(Span(not_utf8)), String(""))
    # Every refusal above came before a send: the factory was never called.
    with assert_raises(contains="dialled"):
        _ = w.has_version(String("app/db"), String(""))
    print("  test_writer_refusals_send_nothing PASS")


def main() raises:
    test_handle_grammar()
    test_resolve_secret_string()
    test_resolve_secret_binary()
    test_resolve_neither_member()
    test_resolve_error_names_the_handle()
    test_writer_refusals_send_nothing()
    print("PASS komira_aws_secret_store")
