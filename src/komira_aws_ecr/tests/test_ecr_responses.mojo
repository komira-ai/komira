# The responses komira_aws_ecr decodes, one or more rows per operation, and
# the error forms Amazon ECR answers with. The wire texts are written here
# from the Amazon ECR API reference's examples, with made-up registries,
# repositories and tokens.
#
# Errors. ECR is awsJson 1.1: the body's `__type` names the error shape,
# which komira_aws_core's `aws_json_error_info` reads as the code (with or
# without a namespace); the modeled error shapes carry the message.
from komira_aws_ecr.komira_aws_ecr import (
    ECRRepositoryAlreadyExistsException,
    ECRRepositoryNotFoundException,
    parse_create_repository_response,
    parse_describe_repositories_response,
    parse_get_authorization_token_response,
    parse_put_image_tag_mutability_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_json_error_info
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def _repo() -> String:
    return String(
        '{"repositoryArn":"arn:aws:ecr:us-east-1:123456789012:repository/team/jobs",'
        + '"registryId":"123456789012","repositoryName":"team/jobs",'
        + '"repositoryUri":"123456789012.dkr.ecr.us-east-1.amazonaws.com/team/jobs",'
        + '"createdAt":1790812800.25,"imageTagMutability":"IMMUTABLE",'
        + '"imageScanningConfiguration":{"scanOnPush":true},'
        + '"encryptionConfiguration":{"encryptionType":"AES256"}}'
    )


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def test_create_repository() raises:
    var r = parse_create_repository_response(_ok(String('{"repository":') + _repo() + "}"))
    var repo = r.repository.value().copy()
    assert_equal(repo.repository_name.value(), "team/jobs")
    assert_equal(repo.repository_uri.value(), "123456789012.dkr.ecr.us-east-1.amazonaws.com/team/jobs")
    assert_equal(repo.created_at.value(), 1790812800.25)
    assert_equal(repo.image_tag_mutability.value(), "IMMUTABLE")
    assert_true(repo.image_scanning_configuration.value().scan_on_push.value())
    assert_equal(repo.encryption_configuration.value().encryption_type, "AES256")
    assert_false(Bool(repo.encryption_configuration.value().kms_key))


def test_describe_repositories() raises:
    var body = (
        String('{"repositories":[') + _repo() + ","
        + '{"repositoryName":"team/web","imageTagMutability":"MUTABLE",'
        + '"imageScanningConfiguration":{"scanOnPush":false}}],"nextToken":"tok-2"}'
    )
    var r = parse_describe_repositories_response(_ok(body))
    var repos = r.repositories.value().copy()
    assert_equal(len(repos), 2)
    assert_equal(repos[0].registry_id.value(), "123456789012")
    assert_equal(repos[1].repository_name.value(), "team/web")
    assert_false(repos[1].image_scanning_configuration.value().scan_on_push.value())
    assert_equal(r.next_token.value(), "tok-2")
    # The last page has no token.
    assert_false(Bool(parse_describe_repositories_response(_ok(String('{"repositories":[]}'))).next_token))


def test_get_authorization_token() raises:
    var r = parse_get_authorization_token_response(
        _ok(
            String(
                '{"authorizationData":[{"authorizationToken":"QVdTOmV4YW1wbGUtcGFzc3dvcmQ=",'
                + '"expiresAt":1790856000.0,'
                + '"proxyEndpoint":"https://123456789012.dkr.ecr.us-east-1.amazonaws.com"}]}'
            )
        )
    )
    var data = r.authorization_data.value().copy()
    assert_equal(len(data), 1)
    # The token stays as the service sent it: base64 of `AWS:<password>`.
    assert_equal(data[0].authorization_token.value(), "QVdTOmV4YW1wbGUtcGFzc3dvcmQ=")
    assert_equal(data[0].expires_at.value(), 1790856000.0)
    assert_equal(data[0].proxy_endpoint.value(), "https://123456789012.dkr.ecr.us-east-1.amazonaws.com")


def test_put_image_tag_mutability() raises:
    var r = parse_put_image_tag_mutability_response(
        _ok(
            String(
                '{"registryId":"123456789012","repositoryName":"team/jobs",'
                + '"imageTagMutability":"MUTABLE"}'
            )
        )
    )
    assert_equal(r.registry_id.value(), "123456789012")
    assert_equal(r.repository_name.value(), "team/jobs")
    assert_equal(r.image_tag_mutability.value(), "MUTABLE")


def test_a_body_that_is_not_json_is_refused() raises:
    with assert_raises():
        _ = parse_create_repository_response(_ok(String("<CreateRepositoryResponse/>")))
    with assert_raises():
        _ = parse_describe_repositories_response(_ok(String('{"repositories":[{"repositoryName":7}]}')))


def test_repository_not_found() raises:
    var resp = AwsResponse.of_text(
        400,
        String(
            "{\"__type\":\"RepositoryNotFoundException\",\"message\":\"The repository with name"
            " 'team/gone' does not exist in the registry with id '123456789012'\"}"
        ),
    )
    resp.add_header(String("x-amzn-RequestId"), String("6f2c1d0e-0000-4000-8000-1234567890ab"))
    assert_true(aws_is_error_status(resp.status))
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "RepositoryNotFoundException")
    assert_true(info.message.find("'team/gone' does not exist") >= 0)
    assert_equal(info.request_id, "6f2c1d0e-0000-4000-8000-1234567890ab")
    var e = ECRRepositoryNotFoundException.from_aws_json(parse_json_value(resp.body_text()))
    assert_true(e.message.value().find("team/gone") >= 0)


def test_repository_already_exists() raises:
    # A namespaced `__type` reads as the same code.
    var resp = AwsResponse.of_text(
        400,
        String(
            "{\"__type\":\"com.amazonaws.ecr#RepositoryAlreadyExistsException\",\"message\":\"The"
            " repository with name 'team/jobs' already exists in the registry with id"
            " '123456789012'\"}"
        ),
    )
    assert_equal(aws_json_error_info(resp).code, "RepositoryAlreadyExistsException")
    var e = ECRRepositoryAlreadyExistsException.from_aws_json(parse_json_value(resp.body_text()))
    assert_true(e.message.value().find("already exists") >= 0)


def main() raises:
    test_create_repository()
    test_describe_repositories()
    test_get_authorization_token()
    test_put_image_tag_mutability()
    test_a_body_that_is_not_json_is_refused()
    test_repository_not_found()
    test_repository_already_exists()
    print("OK")
