# The requests the generated `ArtifactRegistryClient` puts on the wire, one
# test per generated method: CreateRepository, GetRepository and
# DeleteRepository (a deploy that owns an image repository), ListRepositories
# (a teardown check that lists what is left in a location) and GetFile (a
# package upload that reads a file's hashes back). Each sends through the
# client over komira_http_core's ScriptedConnector with a shared write
# capture (no socket) and checks the request line and body, byte for byte,
# and the response it decoded. The client is pointed at `localhost`, so the
# send resolves no name; the default host is test_artifactregistry_default_host's.
#
# The expected forms are written from the Artifact Registry v1 REST
# reference (projects.locations.repositories.create/get/delete/list and
# projects.locations.repositories.files.get): the parent or name in the path,
# `repositoryId`, `pageSize`, `pageToken`, `filter` and `orderBy` in the
# query, and the Repository as the body of a create.
#
# The create body holds only the fields the caller set: a plain scalar left
# at its default (`name`, `kmsKeyName`, `sizeBytes`, the false booleans) and
# an empty list or map (`cleanupPolicies`) are omitted, as the proto3 JSON
# mapping omits them.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_artifactregistry.file import GetFileRequest, Hash_HashType
from komira_gcp_artifactregistry.repository import (
    CreateRepositoryRequest,
    DeleteRepositoryRequest,
    GetRepositoryRequest,
    ListRepositoriesRequest,
    Repository,
    Repository_Format,
)
from komira_gcp_artifactregistry.service import ArtifactRegistryClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource
comptime _CLIENT = ArtifactRegistryClient[SC, TS]

# A long-running operation as a create or delete answers it.
comptime _LRO = (
    '{"name":"projects/demo-project/locations/us-central1/operations/op-77",'
    + '"metadata":{"@type":"type.googleapis.com/google.devtools.artifactregistry.v1.OperationMetadata"}}'
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _capture() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _http(capture: ArcPointer[List[UInt8]], answer: String) raises -> HttpClient[SC]:
    return HttpClient[SC].with_defaults(
        SC.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
        )
    )


def _token() raises -> TS:
    return TS(String("test-access-token"))


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _head(capture: ArcPointer[List[UInt8]]) -> String:
    """The request line."""
    return String(_wire(capture).split("\r\n")[0])


def _body(capture: ArcPointer[List[UInt8]]) -> String:
    """What follows the header block."""
    var parts = _wire(capture).split("\r\n\r\n")
    return String(parts[1]) if len(parts) > 1 else String("")


def _client(capture: ArcPointer[List[UInt8]], answer: String) raises -> _CLIENT:
    var c = _CLIENT(_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    return c^


def test_create_repository() raises:
    var capture = _capture()
    var c = _client(capture, _LRO)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var repo = decode_json_lenient[Repository](
        String(
            '{"format":"DOCKER","mode":"STANDARD_REPOSITORY",'
            + '"description":"build images","labels":{"owner":"ci"},'
            + '"dockerConfig":{"immutableTags":true}}'
        )
    )
    var op = c.create_repository[_RT](
        CreateRepositoryRequest(
            String("projects/demo-project/locations/us-central1"),
            String("images"),
            repo^,
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /v1/projects/demo-project/locations/us-central1/repositories"
        + "?repositoryId=images HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"format":"DOCKER","description":"build images",'
        + '"labels":{"owner":"ci"},"mode":"STANDARD_REPOSITORY",'
        + '"dockerConfig":{"immutableTags":true}}',
    )
    assert_equal(
        op.name, "projects/demo-project/locations/us-central1/operations/op-77"
    )
    assert_false(op.done)


def test_get_repository() raises:
    var capture = _capture()
    var answer = String(
        '{"name":"projects/demo-project/locations/us-central1/repositories/images",'
        + '"format":"DOCKER","registryUri":"us-central1-docker.pkg.dev/demo-project/images"}'
    )
    var c = _client(capture, answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var repo = c.get_repository[_RT](
        GetRepositoryRequest(
            String("projects/demo-project/locations/us-central1/repositories/images")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/us-central1/repositories/images HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    assert_true(repo.format == Repository_Format(Repository_Format.DOCKER))
    assert_equal(repo.registry_uri, "us-central1-docker.pkg.dev/demo-project/images")


def test_get_repository_refuses_a_name_outside_the_pattern() raises:
    # The name must match `projects/*/locations/*/repositories/*`; anything
    # else is refused before a dial, never sent as a different path.
    var capture = _capture()
    var c = _client(capture, "{}")
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var raised = False
    try:
        _ = c.get_repository[_RT](
            GetRepositoryRequest(String("projects/demo-project/repositories/images")),
            reactor,
        )
    except:
        raised = True
    assert_true(raised, "a name outside the pattern was sent")
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_delete_repository() raises:
    var capture = _capture()
    var c = _client(capture, _LRO)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.delete_repository[_RT](
        DeleteRepositoryRequest(
            String("projects/demo-project/locations/us-central1/repositories/images")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "DELETE /v1/projects/demo-project/locations/us-central1/repositories/images HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    assert_true(op.metadata)
    assert_equal(
        op.metadata.value().type_url,
        "type.googleapis.com/google.devtools.artifactregistry.v1.OperationMetadata",
    )


def test_list_repositories_first_page() raises:
    # Default-valued query fields stay out: no `pageToken=` on a first page.
    var capture = _capture()
    var answer = String(
        '{"repositories":[{"name":"projects/demo-project/locations/us-central1/repositories/images",'
        + '"format":"DOCKER"}],"nextPageToken":"tok-2"}'
    )
    var c = _client(capture, answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var page = c.list_repositories[_RT](
        ListRepositoriesRequest(
            String("projects/demo-project/locations/us-central1"),
            Int32(50),
            String(""),
            String(""),
            String(""),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/us-central1/repositories?pageSize=50 HTTP/1.1",
    )
    assert_equal(len(page.repositories), 1)
    assert_equal(page.next_page_token, "tok-2")


def test_list_repositories_next_page_with_a_filter() raises:
    var capture = _capture()
    var c = _client(capture, '{"repositories":[]}')
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var page = c.list_repositories[_RT](
        ListRepositoriesRequest(
            String("projects/demo-project/locations/us-central1"),
            Int32(50),
            String("tok-2"),
            String('name="projects/demo-project/locations/us-central1/repositories/app-*"'),
            String("name"),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/us-central1/repositories"
        + "?pageSize=50&pageToken=tok-2"
        + "&filter=name%3D%22projects%2Fdemo-project%2Flocations%2Fus-central1"
        + "%2Frepositories%2Fapp-%2A%22&orderBy=name HTTP/1.1",
    )
    assert_equal(len(page.repositories), 0)
    assert_equal(page.next_page_token, "")


def test_get_file() raises:
    var capture = _capture()
    var answer = String(
        '{"name":"projects/demo-project/locations/us-central1/repositories/pkgs/files/demo-1.0.0.tar.gz",'
        + '"sizeBytes":"2048","hashes":[{"type":"SHA256",'
        + '"value":"n4bQgYhMfWWaL+qgxVrQFaO/TxsrC4Is0V1sFbDwCgg="}],'
        + '"createTime":"2026-10-01T12:00:00Z"}'
    )
    var c = _client(capture, answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var f = c.get_file[_RT](
        GetFileRequest(
            String(
                "projects/demo-project/locations/us-central1/repositories/pkgs/files/demo-1.0.0.tar.gz"
            )
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/us-central1/repositories/pkgs"
        + "/files/demo-1.0.0.tar.gz HTTP/1.1",
    )
    assert_equal(f.size_bytes, Int64(2048))
    assert_equal(len(f.hashes), 1)
    assert_true(f.hashes[0].type == Hash_HashType(Hash_HashType.SHA256))
    # The base64 value decodes to the 32 digest bytes.
    assert_equal(len(f.hashes[0].value), 32)
    assert_equal(f.hashes[0].value[0], UInt8(0x9F))
    assert_true(f.create_time)


def test_get_file_keeps_an_escaped_file_id_escaped() raises:
    # A file id holding `/` is escaped in its resource name (`%2F`). The
    # `files/**` variable is a multi-segment one, which google.api.http
    # sends with every byte outside the unreserved set and `/` encoded, so
    # the name's `%` goes out as `%25`; the server decodes it back to the
    # name as given (http.proto: multi-segment variables, and `%2F` is left
    # undecoded).
    var capture = _capture()
    var c = _client(capture, '{"name":"x"}')
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.get_file[_RT](
        GetFileRequest(
            String(
                "projects/demo-project/locations/us-central1/repositories/pkgs/files/demo%2F1.0.0%2Fdemo.whl"
            )
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/us-central1/repositories/pkgs"
        + "/files/demo%252F1.0.0%252Fdemo.whl HTTP/1.1",
    )


def main() raises:
    test_create_repository()
    test_get_repository()
    test_get_repository_refuses_a_name_outside_the_pattern()
    test_delete_repository()
    test_list_repositories_first_page()
    test_list_repositories_next_page_with_a_filter()
    test_get_file()
    test_get_file_keeps_an_escaped_file_id_escaped()
    print("OK")
