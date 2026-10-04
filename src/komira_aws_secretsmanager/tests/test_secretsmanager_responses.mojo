# The responses komira_aws_secretsmanager decodes, one or more rows per
# operation, and the error forms AWS Secrets Manager answers with. The wire
# texts are written here from the AWS Secrets Manager API reference's
# examples, with made-up secrets, versions and dates.
#
# Errors. Secrets Manager is awsJson 1.1: the body's `__type` names the
# error shape, which komira_aws_core's `aws_json_error_info` reads as the
# code, and its message is in `Message`, capitalized; the modeled error
# shapes carry it. A name still held by a secret scheduled for deletion is
# an InvalidRequestException, not a ResourceExistsException: the row below
# keeps the two apart.
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerInvalidRequestException,
    SecretsManagerResourceExistsException,
    SecretsManagerResourceNotFoundException,
    parse_create_secret_response,
    parse_delete_secret_response,
    parse_describe_secret_response,
    parse_get_secret_value_response,
    parse_put_secret_value_response,
    parse_restore_secret_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_json_error_info
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:app/db-AbCdEf"
comptime _V1 = "EXAMPLE1-90ab-cdef-fedc-ba987SECRET1"
comptime _V2 = "EXAMPLE2-90ab-cdef-fedc-ba987SECRET2"


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def test_create_secret() raises:
    var r = parse_create_secret_response(
        _ok(String('{"ARN":"') + _ARN + '","Name":"app/db","VersionId":"' + _V1 + '"}')
    )
    assert_equal(r.arn.value(), _ARN)
    assert_equal(r.name.value(), "app/db")
    assert_equal(r.version_id.value(), _V1)
    assert_false(Bool(r.replication_status))


def test_put_secret_value() raises:
    var r = parse_put_secret_value_response(
        _ok(
            String('{"ARN":"') + _ARN + '","Name":"app/db","VersionId":"' + _V2
            + '","VersionStages":["AWSCURRENT"]}'
        )
    )
    assert_equal(r.version_id.value(), _V2)
    assert_equal(len(r.version_stages.value()), 1)
    assert_equal(r.version_stages.value()[0], "AWSCURRENT")


def test_get_secret_value_string() raises:
    var r = parse_get_secret_value_response(
        _ok(
            String('{"ARN":"') + _ARN + '","Name":"app/db","VersionId":"' + _V1
            + '","SecretString":"{\\"user\\":\\"app\\",\\"password\\":\\"s3cr3t\\"}",'
            + '"VersionStages":["AWSCURRENT"],"CreatedDate":1790812800.123}'
        )
    )
    assert_equal(r.secret_string.value(), '{"user":"app","password":"s3cr3t"}')
    assert_false(Bool(r.secret_binary))
    assert_equal(r.created_date.value(), 1790812800.123)


def test_get_secret_value_binary() raises:
    var r = parse_get_secret_value_response(
        _ok(String('{"ARN":"') + _ARN + '","Name":"app/key","SecretBinary":"AAEC/w=="}')
    )
    var b = r.secret_binary.value().copy()
    assert_equal(len(b), 4)
    assert_equal(b[0], UInt8(0))
    assert_equal(b[3], UInt8(255))
    assert_false(Bool(r.secret_string))


def test_describe_secret() raises:
    var body = (
        String('{"ARN":"') + _ARN + '","Name":"app/db","Description":"the database password",'
        + '"LastChangedDate":1790812800,"DeletedDate":1790899200.5,'
        + '"Tags":[{"Key":"owner","Value":"ci"}],'
        + '"VersionIdsToStages":{"' + _V1 + '":["AWSPREVIOUS"],"' + _V2 + '":["AWSCURRENT","AWSPENDING"]},'
        + '"CreatedDate":1790726400}'
    )
    var r = parse_describe_secret_response(_ok(body))
    assert_equal(r.name.value(), "app/db")
    assert_equal(r.description.value(), "the database password")
    # A secret scheduled for deletion says when it was deleted.
    assert_equal(r.deleted_date.value(), 1790899200.5)
    assert_equal(r.last_changed_date.value(), 1790812800.0)
    assert_equal(r.tags.value()[0].key.value(), "owner")
    var stages = r.version_ids_to_stages.value().copy()
    assert_equal(len(stages), 2)
    assert_equal(stages[_V1][0], "AWSPREVIOUS")
    assert_equal(len(stages[_V2]), 2)
    assert_equal(stages[_V2][1], "AWSPENDING")


def test_delete_and_restore() raises:
    var d = parse_delete_secret_response(
        _ok(String('{"ARN":"') + _ARN + '","Name":"app/db","DeletionDate":1791417600}')
    )
    assert_equal(d.deletion_date.value(), 1791417600.0)
    var r = parse_restore_secret_response(_ok(String('{"ARN":"') + _ARN + '","Name":"app/db"}'))
    assert_equal(r.arn.value(), _ARN)


def test_a_body_that_is_not_json_is_refused() raises:
    with assert_raises():
        _ = parse_get_secret_value_response(_ok(String("not json")))
    with assert_raises():
        _ = parse_get_secret_value_response(_ok(String('{"SecretString":12}')))


def test_resource_not_found() raises:
    var resp = AwsResponse.of_text(
        400,
        String(
            "{\"__type\":\"ResourceNotFoundException\","
            "\"Message\":\"Secrets Manager can't find the specified secret.\"}"
        ),
    )
    resp.add_header(String("x-amzn-RequestId"), String("0f8fad5b-d9cb-469f-a165-70867728950e"))
    assert_true(aws_is_error_status(resp.status))
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "ResourceNotFoundException")
    assert_equal(info.message, "Secrets Manager can't find the specified secret.")
    assert_equal(info.request_id, "0f8fad5b-d9cb-469f-a165-70867728950e")
    var e = SecretsManagerResourceNotFoundException.from_aws_json(parse_json_value(resp.body_text()))
    assert_equal(e.message.value(), "Secrets Manager can't find the specified secret.")


def test_name_taken() raises:
    var exists = AwsResponse.of_text(
        400,
        String(
            '{"__type":"ResourceExistsException",'
            + '"Message":"The operation failed because the secret app/db already exists."}'
        ),
    )
    assert_equal(aws_json_error_info(exists).code, "ResourceExistsException")
    var e = SecretsManagerResourceExistsException.from_aws_json(parse_json_value(exists.body_text()))
    assert_true(e.message.value().find("already exists") >= 0)
    # The name of a secret scheduled for deletion is still taken, and the
    # service says so as an InvalidRequestException.
    var held = AwsResponse.of_text(
        400,
        String(
            "{\"__type\":\"InvalidRequestException\",\"Message\":\"You can't create this secret"
            " because a secret with this name is already scheduled for deletion.\"}"
        ),
    )
    assert_equal(aws_json_error_info(held).code, "InvalidRequestException")
    var h = SecretsManagerInvalidRequestException.from_aws_json(parse_json_value(held.body_text()))
    assert_true(h.message.value().find("scheduled for deletion") >= 0)


def main() raises:
    test_create_secret()
    test_put_secret_value()
    test_get_secret_value_string()
    test_get_secret_value_binary()
    test_describe_secret()
    test_delete_and_restore()
    test_a_body_that_is_not_json_is_refused()
    test_resource_not_found()
    test_name_taken()
    print("OK")
