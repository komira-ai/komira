# Each generated Secret Manager method, once: the request it puts on the
# wire, byte for byte (request line with the resource-name captures and the
# query, the headers, the JSON body), and the response it reads back.
#
# The expected forms are written here from the Secret Manager v1 REST
# reference (projects.secrets.create, .addVersion, .delete, .list,
# projects.secrets.versions.access, .get, .list); no upstream test body is
# copied. The connector is komira_http_core's ScriptedConnector with a
# shared write capture, so the bytes the client wrote outlive the stream it
# dialled; no socket is opened. Each client is pointed at `localhost`
# (resolved without the network) with `set_rest_host`; the default host is
# test_secretmanager_endpoint's subject.
#
# A body omits a plain scalar or enum at its default (`name`, `etag`,
# `..._UNSPECIFIED`) and an empty list or map, as the proto3 JSON mapping
# omits them; the service reads each as unset. A
# `body: "*"` method (AddSecretVersion) leaves its path field (`parent`)
# out of the body, as google/api/http.proto states.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.resources import SecretVersion_State
from komira_gcp_secretmanager.service import (
    AccessSecretVersionRequest,
    AddSecretVersionRequest,
    CreateSecretRequest,
    DeleteSecretRequest,
    GetSecretVersionRequest,
    ListSecretVersionsRequest,
    ListSecretsRequest,
    SecretManagerServiceClient,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource]

# 2026-09-30T12:00:00Z and 2026-10-01T08:30:15Z.
comptime _T0 = Int64(1790769600)
comptime _T1 = Int64(1790843415)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    """A 200 with a JSON body, closing the connection after it."""
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(capture: ArcPointer[List[UInt8]], answer: String) raises -> _Client:
    var stream = ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(stream^)
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _expected(target: String, body: String = "") -> String:
    """The request as written: komira_http's Host, User-Agent and
    Content-Length, then the client's headers (lowercased on the wire), a
    content-type only with a body, then the body."""
    var out = (
        target
        + " HTTP/1.1\r\n"
        + "Host: localhost\r\n"
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\n"
        + "authorization: Bearer test-access-token\r\n"
    )
    if body.byte_length() > 0:
        out += "content-type: application/json\r\n"
    return out + "\r\n" + body


def test_access_secret_version() raises:
    # GET .../versions/{version}:access; `latest` is a version alias.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        '{"name":"projects/123456789012/secrets/smtp-password/versions/3",'
        + '"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var resp = c.access_secret_version[_RT](
        decode_json[AccessSecretVersionRequest](
            '{"name":"projects/demo-project/secrets/smtp-password/versions/latest"}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "GET /v1/projects/demo-project/secrets/smtp-password/versions/latest:access"
        ),
    )
    assert_equal(resp.name, "projects/123456789012/secrets/smtp-password/versions/3")
    ref payload = resp.payload.value()
    assert_equal(String(unsafe_from_utf8=Span(payload.data)), "hunter2")
    assert_equal(payload.data_crc32c.value(), Int64(1736498283))


def test_add_secret_version() raises:
    # POST .../secrets/{secret}:addVersion with `body: "*"`. 1736498283 is the
    # CRC32C (Castagnoli) of "hunter2", the decoded payload.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        '{"name":"projects/123456789012/secrets/smtp-password/versions/4",'
        + '"createTime":"2026-09-30T12:00:00Z","state":"ENABLED",'
        + '"replicationStatus":{"automatic":{}},"etag":"\\"1640b3f2c1e5a8\\"",'
        + '"clientSpecifiedPayloadChecksum":true}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var resp = c.add_secret_version[_RT](
        decode_json[AddSecretVersionRequest](
            '{"parent":"projects/demo-project/secrets/smtp-password",'
            + '"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "POST /v1/projects/demo-project/secrets/smtp-password:addVersion",
            '{"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}',
        ),
    )
    assert_equal(resp.name, "projects/123456789012/secrets/smtp-password/versions/4")
    assert_equal(resp.create_time.value().seconds, _T0)
    assert_true(resp.state == SecretVersion_State(SecretVersion_State.ENABLED))
    assert_true(Bool(resp.replication_status.value().automatic))
    assert_equal(resp.etag, '"1640b3f2c1e5a8"')
    assert_true(resp.client_specified_payload_checksum)


def test_create_secret() raises:
    # POST .../secrets?secretId=..., the Secret as the body.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        '{"name":"projects/123456789012/secrets/smtp-password",'
        + '"replication":{"automatic":{}},"createTime":"2026-09-30T12:00:00Z",'
        + '"labels":{"owner":"deploy"},"etag":"\\"16a0c1\\"",'
        + '"versionAliases":{"current":"3"}}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var resp = c.create_secret[_RT](
        decode_json[CreateSecretRequest](
            '{"parent":"projects/demo-project","secretId":"smtp-password",'
            + '"secret":{"replication":{"automatic":{}},"labels":{"owner":"deploy"}}}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "POST /v1/projects/demo-project/secrets?secretId=smtp-password",
            '{"replication":{"automatic":{}},"labels":{"owner":"deploy"}}',
        ),
    )
    assert_equal(resp.name, "projects/123456789012/secrets/smtp-password")
    assert_true(Bool(resp.replication.value().automatic))
    assert_false(Bool(resp.replication.value().user_managed))
    assert_equal(resp.create_time.value().seconds, _T0)
    assert_equal(resp.labels["owner"], "deploy")
    assert_equal(resp.etag, '"16a0c1"')
    assert_equal(resp.version_aliases["current"], Int64(3))


def test_delete_secret() raises:
    # DELETE .../secrets/{secret}?etag=...; the answer is an Empty.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, "{}")
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.delete_secret[_RT](
        decode_json[DeleteSecretRequest](
            '{"name":"projects/demo-project/secrets/smtp-password",'
            + '"etag":"\\"16a0c1\\""}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "DELETE /v1/projects/demo-project/secrets/smtp-password?etag=%2216a0c1%22"
        ),
    )


def test_list_secrets() raises:
    # GET .../secrets with the paging and filter parameters, each a query
    # key named by its JSON name, percent-encoded.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        '{"secrets":[{"name":"projects/123456789012/secrets/app-a",'
        + '"replication":{"userManaged":{"replicas":[{"location":"us-central1"}]}},'
        + '"createTime":"2026-10-01T08:30:15Z"},'
        + '{"name":"projects/123456789012/secrets/app-b","replication":{"automatic":{}}}],'
        + '"nextPageToken":"CgVhcHAtYg==","totalSize":7}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var resp = c.list_secrets[_RT](
        decode_json[ListSecretsRequest](
            '{"parent":"projects/demo-project","pageSize":25,'
            + '"pageToken":"CgVhcHAtYQ==","filter":"name:app- AND labels.owner=deploy"}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "GET /v1/projects/demo-project/secrets?pageSize=25"
            + "&pageToken=CgVhcHAtYQ%3D%3D"
            + "&filter=name%3Aapp-%20AND%20labels.owner%3Ddeploy"
        ),
    )
    assert_equal(len(resp.secrets), 2)
    assert_equal(resp.secrets[0].name, "projects/123456789012/secrets/app-a")
    ref replicas = resp.secrets[0].replication.value().user_managed.value().replicas
    assert_equal(len(replicas), 1)
    assert_equal(replicas[0].location, "us-central1")
    assert_equal(resp.secrets[0].create_time.value().seconds, _T1)
    assert_true(Bool(resp.secrets[1].replication.value().automatic))
    assert_equal(resp.next_page_token, "CgVhcHAtYg==")
    assert_equal(resp.total_size, Int32(7))


def test_list_secret_versions() raises:
    # GET .../secrets/{secret}/versions; a first page sends no pageToken and
    # an unset pageSize sends none.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        '{"versions":[{"name":"projects/123456789012/secrets/smtp-password/versions/2",'
        + '"state":"ENABLED"},{"name":"projects/123456789012/secrets/smtp-password/versions/1",'
        + '"state":"DESTROYED","destroyTime":"2026-10-01T08:30:15Z"}],"totalSize":2}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var resp = c.list_secret_versions[_RT](
        decode_json[ListSecretVersionsRequest](
            '{"parent":"projects/demo-project/secrets/smtp-password",'
            + '"filter":"state:ENABLED"}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "GET /v1/projects/demo-project/secrets/smtp-password/versions"
            + "?filter=state%3AENABLED"
        ),
    )
    assert_equal(len(resp.versions), 2)
    assert_true(resp.versions[0].state == SecretVersion_State(SecretVersion_State.ENABLED))
    assert_true(
        resp.versions[1].state == SecretVersion_State(SecretVersion_State.DESTROYED)
    )
    assert_equal(resp.versions[1].destroy_time.value().seconds, _T1)
    assert_equal(resp.next_page_token, "")
    assert_equal(resp.total_size, Int32(2))


def test_get_secret_version() raises:
    # GET .../versions/{version}, no verb: the version's metadata (its state
    # among it) and never a payload; `latest` is a version alias here too.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        '{"name":"projects/123456789012/secrets/smtp-password/versions/3",'
        + '"createTime":"2026-09-30T12:00:00Z","state":"DISABLED","etag":"\\"e3\\""}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var resp = c.get_secret_version[_RT](
        decode_json[GetSecretVersionRequest](
            '{"name":"projects/demo-project/secrets/smtp-password/versions/latest"}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected("GET /v1/projects/demo-project/secrets/smtp-password/versions/latest"),
    )
    assert_equal(resp.name, "projects/123456789012/secrets/smtp-password/versions/3")
    assert_true(resp.state == SecretVersion_State(SecretVersion_State.DISABLED))
    assert_equal(resp.create_time.value().seconds, _T0)

    # A regional version is sent at its regional path.
    var regional = ArcPointer[List[UInt8]](List[UInt8]())
    var r = _client(
        regional,
        '{"name":"projects/123456789012/locations/us-central1/secrets/s/versions/1",'
        + '"state":"ENABLED"}',
    )
    var resp_r = r.get_secret_version[_RT](
        decode_json[GetSecretVersionRequest](
            '{"name":"projects/demo-project/locations/us-central1/secrets/s/versions/1"}'
        ),
        reactor,
    )
    assert_equal(
        _wire(regional),
        _expected("GET /v1/projects/demo-project/locations/us-central1/secrets/s/versions/1"),
    )
    assert_true(resp_r.state == SecretVersion_State(SecretVersion_State.ENABLED))


def main() raises:
    test_access_secret_version()
    test_add_secret_version()
    test_create_secret()
    test_delete_secret()
    test_list_secrets()
    test_list_secret_versions()
    test_get_secret_version()
    print("OK")
