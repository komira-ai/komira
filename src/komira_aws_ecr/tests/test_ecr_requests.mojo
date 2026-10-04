# The requests komira_aws_ecr builds, exactly: method, path, the awsJson
# 1.1 headers (X-Amz-Target `AmazonEC2ContainerRegistry_V20150921.<Operation>`
# and Content-Type `application/x-amz-json-1.1`) and the body, members in
# the model's order and an unset member absent. One or more rows per
# operation, in the shapes the Amazon ECR API reference documents: a
# repository created (bare, and immutable with scan-on-push, KMS encryption
# and tags), repositories described by name and page by page, a registry
# login token asked for, and a repository's tag mutability set. Then the
# model's bounds, which `build_<op>_request` checks before any byte is
# written.
from komira_aws_ecr.komira_aws_ecr import (
    ECRENCRYPTION_TYPE_KMS,
    ECRIMAGE_TAG_MUTABILITY_IMMUTABLE,
    ECRIMAGE_TAG_MUTABILITY_MUTABLE,
    ECR_CONTENT_TYPE,
    ECR_SERVICE,
    ECR_TARGET_PREFIX,
    ECRCreateRepositoryRequest,
    ECRDescribeRepositoriesRequest,
    ECREncryptionConfiguration,
    ECRGetAuthorizationTokenRequest,
    ECRImageScanningConfiguration,
    ECRPutImageTagMutabilityRequest,
    ECRTag,
    build_create_repository_request,
    build_describe_repositories_request,
    build_get_authorization_token_request,
    build_put_image_tag_mutability_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


def _check_envelope(req: AwsRequest, op: String) raises:
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(req.header(String("X-Amz-Target")), "AmazonEC2ContainerRegistry_V20150921." + op)
    assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
    assert_equal(len(req.header_names), 2)


def test_wire_constants() raises:
    assert_equal(ECR_TARGET_PREFIX, "AmazonEC2ContainerRegistry_V20150921")
    assert_equal(ECR_CONTENT_TYPE, "application/x-amz-json-1.1")
    assert_equal(ECR_SERVICE, "ecr")


def test_create_repository_bare() raises:
    var req = build_create_repository_request(ECRCreateRepositoryRequest(String("team/jobs")))
    _check_envelope(req, String("CreateRepository"))
    assert_equal(req.body_text(), '{"repositoryName":"team/jobs"}')


def test_create_repository_configured() raises:
    var input = ECRCreateRepositoryRequest(String("team/jobs"))
    var tags: List[ECRTag] = [ECRTag(String("owner"), String("ci"))]
    input.set_tags(tags^)
    input.set_image_tag_mutability(String(ECRIMAGE_TAG_MUTABILITY_IMMUTABLE))
    var scan = ECRImageScanningConfiguration()
    scan.set_scan_on_push(True)
    input.set_image_scanning_configuration(scan^)
    var enc = ECREncryptionConfiguration(String(ECRENCRYPTION_TYPE_KMS))
    enc.set_kms_key(String("arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"))
    input.set_encryption_configuration(enc^)
    var req = build_create_repository_request(input)
    _check_envelope(req, String("CreateRepository"))
    assert_equal(
        req.body_text(),
        '{"repositoryName":"team/jobs","tags":[{"Key":"owner","Value":"ci"}],'
        + '"imageTagMutability":"IMMUTABLE","imageScanningConfiguration":{"scanOnPush":true},'
        + '"encryptionConfiguration":{"encryptionType":"KMS","kmsKey":'
        + '"arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"}}',
    )


def test_describe_repositories() raises:
    var input = ECRDescribeRepositoriesRequest()
    var names: List[String] = [String("team/jobs")]
    input.set_repository_names(names^)
    var req = build_describe_repositories_request(input)
    _check_envelope(req, String("DescribeRepositories"))
    assert_equal(req.body_text(), '{"repositoryNames":["team/jobs"]}')
    # Every repository, a page at a time: no member is required.
    assert_equal(build_describe_repositories_request(ECRDescribeRepositoriesRequest()).body_text(), "{}")
    var page = ECRDescribeRepositoriesRequest()
    page.set_registry_id(String("123456789012"))
    page.set_next_token(String("tok-2"))
    page.set_max_results(Int32(100))
    assert_equal(
        build_describe_repositories_request(page).body_text(),
        '{"registryId":"123456789012","nextToken":"tok-2","maxResults":100}',
    )


def test_get_authorization_token() raises:
    var req = build_get_authorization_token_request(ECRGetAuthorizationTokenRequest())
    _check_envelope(req, String("GetAuthorizationToken"))
    assert_equal(req.body_text(), "{}")


def test_put_image_tag_mutability() raises:
    var req = build_put_image_tag_mutability_request(
        ECRPutImageTagMutabilityRequest(String("team/jobs"), String(ECRIMAGE_TAG_MUTABILITY_MUTABLE))
    )
    _check_envelope(req, String("PutImageTagMutability"))
    assert_equal(req.body_text(), '{"repositoryName":"team/jobs","imageTagMutability":"MUTABLE"}')


def test_model_bounds() raises:
    # repositoryName has min length 2; repositoryNames and registryIds have
    # min size 1; maxResults min 1.
    with assert_raises(contains="repositoryName: the model states min length 2"):
        _ = build_create_repository_request(ECRCreateRepositoryRequest(String("j")))
    var none = ECRDescribeRepositoriesRequest()
    none.set_repository_names(List[String]())
    with assert_raises(contains="repositoryNames: the model states min size 1"):
        _ = build_describe_repositories_request(none)
    var zero = ECRDescribeRepositoriesRequest()
    zero.set_max_results(Int32(0))
    with assert_raises(contains="maxResults: the model states min value 1"):
        _ = build_describe_repositories_request(zero)
    var ids = ECRGetAuthorizationTokenRequest()
    ids.set_registry_ids(List[String]())
    with assert_raises(contains="registryIds: the model states min size 1"):
        _ = build_get_authorization_token_request(ids)


def main() raises:
    test_wire_constants()
    test_create_repository_bare()
    test_create_repository_configured()
    test_describe_repositories()
    test_get_authorization_token()
    test_put_image_tag_mutability()
    test_model_bounds()
    print("OK")
