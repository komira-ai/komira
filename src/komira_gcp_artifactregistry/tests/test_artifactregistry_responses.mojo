# The responses the generated Artifact Registry client decodes: a
# repository with its format, mode, docker config, labels, cleanup policies
# and timestamps; a list page; and google.longrunning's Operation, which
# CreateRepository and DeleteRepository answer: a name to follow, `done`,
# and on completion either `error` (a google.rpc.Status) or `response` (an
# Any holding the Repository, or Empty for a delete). Unlike Compute
# Engine's own Operation, its state is the `done` flag, and its failure is
# `error.code`, a google.rpc.Code.
#
# The bodies are written from the Artifact Registry v1 and the
# google.longrunning REST references and decoded with komira_proto_codec's
# lenient reader, as the generated client decodes every response; nothing is
# sent. An Any keeps its `@type` and its JSON members; nothing here unpacks
# it.
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_artifactregistry.operations import Operation
from komira_gcp_artifactregistry.repository import (
    CleanupPolicy_Action,
    ListRepositoriesResponse,
    Repository,
    Repository_Format,
    Repository_Mode,
)
from komira_proto_codec.codec import decode_json_lenient


def test_a_docker_repository() raises:
    var repo = decode_json_lenient[Repository](
        String(
            '{"name":"projects/demo-project/locations/us-central1/repositories/images",'
            + '"format":"DOCKER","mode":"STANDARD_REPOSITORY",'
            + '"description":"build images","labels":{"owner":"ci"},'
            + '"createTime":"2026-09-30T08:00:00.123456Z",'
            + '"updateTime":"2026-10-01T09:30:00Z","sizeBytes":"1048576",'
            + '"dockerConfig":{"immutableTags":true},'
            + '"cleanupPolicies":{"drop-untagged":{"id":"drop-untagged","action":"DELETE",'
            + '"condition":{"tagState":"UNTAGGED","olderThan":"604800s"}}},'
            + '"registryUri":"us-central1-docker.pkg.dev/demo-project/images",'
            + '"satisfiesPzs":true,"unknownLaterField":{"x":1}}'
        )
    )
    assert_true(repo.format == Repository_Format(Repository_Format.DOCKER))
    assert_true(repo.mode == Repository_Mode(Repository_Mode.STANDARD_REPOSITORY))
    assert_equal(repo.labels["owner"], "ci")
    assert_equal(repo.size_bytes, Int64(1048576))
    assert_true(repo.docker_config.value().immutable_tags)
    assert_true(repo.create_time)
    assert_true(repo.satisfies_pzs)
    ref policy = repo.cleanup_policies["drop-untagged"]
    assert_true(policy.action == CleanupPolicy_Action(CleanupPolicy_Action.DELETE))
    assert_true(policy.condition.value().older_than)


def test_a_list_page() raises:
    var page = decode_json_lenient[ListRepositoriesResponse](
        String(
            '{"repositories":[{"name":"projects/p/locations/l/repositories/a","format":"DOCKER"},'
            + '{"name":"projects/p/locations/l/repositories/b","format":"PYTHON"}],'
            + '"nextPageToken":"tok-3"}'
        )
    )
    assert_equal(len(page.repositories), 2)
    assert_true(
        page.repositories[1].format == Repository_Format(Repository_Format.PYTHON)
    )
    assert_equal(page.next_page_token, "tok-3")
    var last = decode_json_lenient[ListRepositoriesResponse](String("{}"))
    assert_equal(len(last.repositories), 0)
    assert_equal(last.next_page_token, "")


def test_an_operation_in_progress() raises:
    var op = decode_json_lenient[Operation](
        String(
            '{"name":"projects/demo-project/locations/us-central1/operations/op-77",'
            + '"metadata":{"@type":"type.googleapis.com/google.devtools.artifactregistry.v1.OperationMetadata"}}'
        )
    )
    assert_false(op.done)
    assert_false(op.error)
    assert_false(op.response)
    assert_equal(
        op.metadata.value().type_url,
        "type.googleapis.com/google.devtools.artifactregistry.v1.OperationMetadata",
    )


def test_an_operation_done_with_a_response() raises:
    var op = decode_json_lenient[Operation](
        String(
            '{"name":"projects/p/locations/l/operations/op-77","done":true,'
            + '"response":{"@type":"type.googleapis.com/google.devtools.artifactregistry.v1.Repository",'
            + '"name":"projects/p/locations/l/repositories/images","format":"DOCKER"}}'
        )
    )
    assert_true(op.done)
    assert_false(op.error)
    ref response = op.response.value()
    assert_equal(
        response.type_url,
        "type.googleapis.com/google.devtools.artifactregistry.v1.Repository",
    )
    assert_true(response.has_json_payload())


def test_an_operation_done_with_an_error() raises:
    var op = decode_json_lenient[Operation](
        String(
            '{"name":"projects/p/locations/l/operations/op-78","done":true,'
            + '"error":{"code":6,"message":"the repository already exists"}}'
        )
    )
    assert_true(op.done)
    assert_false(op.response)
    assert_equal(op.error.value().code, Int32(6))


def main() raises:
    test_a_docker_repository()
    test_a_list_page()
    test_an_operation_in_progress()
    test_an_operation_done_with_a_response()
    test_an_operation_done_with_an_error()
    print("OK")
