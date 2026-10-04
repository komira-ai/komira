# The requests komira_aws_secretsmanager builds, exactly: method, path, the
# awsJson 1.1 headers (X-Amz-Target `secretsmanager.<Operation>` and
# Content-Type `application/x-amz-json-1.1`) and the body, members in the
# model's order and an unset member absent. One or more rows per
# operation, in the shapes the AWS Secrets Manager API reference documents:
# a secret created with a string value, a description and tags (and one
# with a binary value), a new version put under a stage, the current value
# read (and one by stage), a secret described, deleted with a recovery
# window and without one, and restored. Then the model's bounds, which
# `build_<op>_request` checks before any byte is written.
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SECRETSMANAGER_CONTENT_TYPE,
    SECRETSMANAGER_SERVICE,
    SECRETSMANAGER_TARGET_PREFIX,
    SecretsManagerCreateSecretRequest,
    SecretsManagerDeleteSecretRequest,
    SecretsManagerDescribeSecretRequest,
    SecretsManagerGetSecretValueRequest,
    SecretsManagerPutSecretValueRequest,
    SecretsManagerRestoreSecretRequest,
    SecretsManagerTag,
    build_create_secret_request,
    build_delete_secret_request,
    build_describe_secret_request,
    build_get_secret_value_request,
    build_put_secret_value_request,
    build_restore_secret_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


# A client request token is the idempotency key of a write, at least 32
# characters (the AWS SDKs send a UUID).
comptime _TOKEN = "EXAMPLE1-90ab-cdef-fedc-ba987SECRET1"


def _check_envelope(req: AwsRequest, op: String) raises:
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(req.header(String("X-Amz-Target")), "secretsmanager." + op)
    assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
    assert_equal(len(req.header_names), 2)


def _tag(key: String, value: String) -> SecretsManagerTag:
    var t = SecretsManagerTag()
    t.set_key(key)
    t.set_value(value)
    return t^


def test_wire_constants() raises:
    assert_equal(SECRETSMANAGER_TARGET_PREFIX, "secretsmanager")
    assert_equal(SECRETSMANAGER_CONTENT_TYPE, "application/x-amz-json-1.1")
    assert_equal(SECRETSMANAGER_SERVICE, "secretsmanager")


def test_create_secret() raises:
    var input = SecretsManagerCreateSecretRequest(String("app/db"))
    input.set_client_request_token(String(_TOKEN))
    input.set_description(String("the database password"))
    # A JSON document as a secret string is a string, escaped.
    input.set_secret_string(String('{"user":"app","password":"p\\"w"}'))
    var tags: List[SecretsManagerTag] = [_tag(String("owner"), String("ci"))]
    input.set_tags(tags^)
    var req = build_create_secret_request(input)
    _check_envelope(req, String("CreateSecret"))
    assert_equal(
        req.body_text(),
        '{"Name":"app/db","ClientRequestToken":"' + String(_TOKEN) + '",'
        + '"Description":"the database password",'
        + '"SecretString":"{\\"user\\":\\"app\\",\\"password\\":\\"p\\\\\\"w\\"}",'
        + '"Tags":[{"Key":"owner","Value":"ci"}]}',
    )


def test_create_secret_binary() raises:
    var input = SecretsManagerCreateSecretRequest(String("app/key"))
    var key: List[UInt8] = [UInt8(0), UInt8(1), UInt8(2), UInt8(255)]
    input.set_secret_binary(key^)
    var req = build_create_secret_request(input)
    _check_envelope(req, String("CreateSecret"))
    # A blob is base64 on the wire.
    assert_equal(req.body_text(), '{"Name":"app/key","SecretBinary":"AAEC/w=="}')


def test_put_secret_value() raises:
    var input = SecretsManagerPutSecretValueRequest(String("app/db"))
    input.set_client_request_token(String(_TOKEN))
    input.set_secret_string(String("s3cr3t"))
    var stages: List[String] = [String("AWSCURRENT")]
    input.set_version_stages(stages^)
    var req = build_put_secret_value_request(input)
    _check_envelope(req, String("PutSecretValue"))
    assert_equal(
        req.body_text(),
        '{"SecretId":"app/db","ClientRequestToken":"' + String(_TOKEN)
        + '","SecretString":"s3cr3t","VersionStages":["AWSCURRENT"]}',
    )


def test_get_secret_value() raises:
    var req = build_get_secret_value_request(SecretsManagerGetSecretValueRequest(String("app/db")))
    _check_envelope(req, String("GetSecretValue"))
    assert_equal(req.body_text(), '{"SecretId":"app/db"}')
    var staged = SecretsManagerGetSecretValueRequest(
        String("arn:aws:secretsmanager:us-east-1:123456789012:secret:app/db-AbCdEf")
    )
    staged.set_version_stage(String("AWSPREVIOUS"))
    assert_equal(
        build_get_secret_value_request(staged).body_text(),
        '{"SecretId":"arn:aws:secretsmanager:us-east-1:123456789012:secret:app/db-AbCdEf",'
        + '"VersionStage":"AWSPREVIOUS"}',
    )


def test_describe_secret() raises:
    var req = build_describe_secret_request(SecretsManagerDescribeSecretRequest(String("app/db")))
    _check_envelope(req, String("DescribeSecret"))
    assert_equal(req.body_text(), '{"SecretId":"app/db"}')


def test_delete_secret() raises:
    var window = SecretsManagerDeleteSecretRequest(String("app/db"))
    window.set_recovery_window_in_days(Int64(7))
    var req = build_delete_secret_request(window)
    _check_envelope(req, String("DeleteSecret"))
    assert_equal(req.body_text(), '{"SecretId":"app/db","RecoveryWindowInDays":7}')
    var force = SecretsManagerDeleteSecretRequest(String("app/db"))
    force.set_force_delete_without_recovery(True)
    assert_equal(
        build_delete_secret_request(force).body_text(),
        '{"SecretId":"app/db","ForceDeleteWithoutRecovery":true}',
    )
    # Neither: the service's default window.
    assert_equal(
        build_delete_secret_request(SecretsManagerDeleteSecretRequest(String("app/db"))).body_text(),
        '{"SecretId":"app/db"}',
    )


def test_restore_secret() raises:
    var req = build_restore_secret_request(SecretsManagerRestoreSecretRequest(String("app/db")))
    _check_envelope(req, String("RestoreSecret"))
    assert_equal(req.body_text(), '{"SecretId":"app/db"}')


def test_model_bounds() raises:
    with assert_raises(contains="SecretId: the model states min length 1"):
        _ = build_get_secret_value_request(SecretsManagerGetSecretValueRequest(String("")))
    var short = SecretsManagerCreateSecretRequest(String("app/db"))
    short.set_client_request_token(String("too-short"))
    with assert_raises(contains="ClientRequestToken: the model states min length 32"):
        _ = build_create_secret_request(short)
    var empty = SecretsManagerPutSecretValueRequest(String("app/db"))
    empty.set_secret_binary(List[UInt8]())
    with assert_raises(contains="SecretBinary: the model states min size 1"):
        _ = build_put_secret_value_request(empty)
    var no_stage = SecretsManagerPutSecretValueRequest(String("app/db"))
    no_stage.set_version_stages(List[String]())
    with assert_raises(contains="VersionStages: the model states min size 1"):
        _ = build_put_secret_value_request(no_stage)


def main() raises:
    test_wire_constants()
    test_create_secret()
    test_create_secret_binary()
    test_put_secret_value()
    test_get_secret_value()
    test_describe_secret()
    test_delete_secret()
    test_restore_secret()
    test_model_bounds()
    print("OK")
