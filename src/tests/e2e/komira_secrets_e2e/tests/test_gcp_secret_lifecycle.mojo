# =============================================================================
# test_gcp_secret_lifecycle.mojo -- the generated GCP Secret Manager client
# against the fake, over TLS on loopback
# =============================================================================
#
# The generated SecretManagerServiceClient (komira_gcp_secretmanager), over
# a verifying TlsConnector that trusts only the fixture root, with a static
# GcpTokenSource, drives the fake (gcp_fake.mojo) through its TLS front:
#
#   global (`localhost`): CreateSecret, AddSecretVersion with a dataCrc32c,
#   AddSecretVersion without one, ListSecretVersions a page of one at a
#   time (newest first, the second page by the token the first returned),
#   AccessSecretVersion `latest` and `1`;
#   regional (`127.0.0.1`, location us-central1, the same secret id):
#   CreateSecret without a replication policy, AddSecretVersion,
#   AccessSecretVersion;
#   then ListSecrets in each location, DeleteSecret of the global secret,
#   ListSecrets (empty), DeleteSecret of the regional one, ListSecrets
#   (empty).
#
# What each assertion catches:
#   * names, version numbers, states, times and the decoded payload bytes
#     read back: a path, query or body the client spells wrong (the fake
#     answers an unknown path 404 and a regional path at the global host
#     400), or a response it decodes wrong;
#   * the payload's CRC32C: the client has no CRC32C code of its own, so
#     the fake's `crc32c` both makes the dataCrc32c the test sends and
#     checks it (refusing one that is not the payload's), and makes the one
#     each access returns. What that proves is that the client carried the
#     payload bytes and the int64-as-string checksum unchanged, both ways;
#     the checksum itself is proved by the published values below;
#   * the fake's request log, exactly (verb, path, query, Host, status): a
#     regional secret sent at the global path or host, a call retried or not
#     sent, a page token not sent back;
#   * every Authorization header the fake received is `Bearer` and the
#     token source's token;
#   * the front's record: every TLS handshake completed, and every
#     connection presented `localhost` (the global client's is the dial
#     host it pushed, the regional client's its pin).
#
# The fake's CRC32C is checked first against published values: in the
# lifecycle the same function makes and checks every checksum, so only those
# values prove it computes CRC32C at all.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_encoding import base64_encode
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.resources import SecretVersion_State
from komira_gcp_secretmanager.service import (
    AccessSecretVersionRequest,
    AddSecretVersionRequest,
    CreateSecretRequest,
    DeleteSecretRequest,
    ListSecretVersionsRequest,
    ListSecretsRequest,
)
from komira_http_core.tls import tls_init
from komira_proto_codec.codec import decode_json

from komira_secrets_e2e import (
    GLOBAL_HOST,
    REGIONAL_HOST,
    TEST_ACCESS_TOKEN,
    ClientLeg,
    crc32c,
    gcp_fake_server,
    gcp_loopback_client,
    serve_while,
)

comptime _RT = BlockingRuntime[NoopSink]
comptime _G = "projects/demo-project"
comptime _R = "projects/demo-project/locations/us-central1"
comptime _GN = "projects/000000000000/secrets/db-password"
comptime _RN = "projects/000000000000/locations/us-central1/secrets/db-password"
# 2026-10-01T00:00:00Z, the fake's first instant.
comptime _EPOCH = Int64(1790812800)
comptime _V1 = "gsm-custody-canary-one-5d20b8"
comptime _V2 = "gsm-custody-canary-two-a7c3f1"
comptime _V3 = "gsm-custody-canary-regional-19e4"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _text(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _add(parent: String, value: String, with_crc: Bool) raises -> AddSecretVersionRequest:
    var data = _bytes(value)
    var payload = String('{"data":"') + base64_encode(Span(data)) + '"'
    if with_crc:
        payload += String(',"dataCrc32c":"') + String(Int(crc32c(Span(data)))) + '"'
    return decode_json[AddSecretVersionRequest](
        String('{"parent":"') + parent + '","payload":' + payload + "}}"
    )


def _access(name: String) raises -> AccessSecretVersionRequest:
    return decode_json[AccessSecretVersionRequest](String('{"name":"') + name + '"}')


def _list_versions(parent: String, token: String) raises -> ListSecretVersionsRequest:
    var j = String('{"parent":"') + parent + '","pageSize":1'
    if token.byte_length() > 0:
        j += String(',"pageToken":"') + token + '"'
    return decode_json[ListSecretVersionsRequest](j + "}")


def _list(parent: String) raises -> ListSecretsRequest:
    return decode_json[ListSecretsRequest](String('{"parent":"') + parent + '"}')


def _delete(name: String) raises -> DeleteSecretRequest:
    return decode_json[DeleteSecretRequest](String('{"name":"') + name + '"}')


struct _Lifecycle(ClientLeg):
    var port: UInt16

    def __init__(out self, port: UInt16):
        self.port = port

    def run(mut self) raises:
        var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var g = gcp_loopback_client(
            self.port, String(GLOBAL_HOST), StaticTokenSource(String(TEST_ACCESS_TOKEN))
        )

        var created = g.create_secret[_RT](
            decode_json[CreateSecretRequest](
                String('{"parent":"') + _G + '","secretId":"db-password",'
                + '"secret":{"replication":{"automatic":{}}}}'
            ),
            reactor,
        )
        assert_equal(created.name, _GN)
        assert_true(Bool(created.replication.value().automatic))
        assert_equal(created.create_time.value().seconds, _EPOCH + 1)

        var v1 = g.add_secret_version[_RT](_add(String(_G) + "/secrets/db-password", _V1, True), reactor)
        assert_equal(v1.name, String(_GN) + "/versions/1")
        assert_true(v1.state == SecretVersion_State(SecretVersion_State.ENABLED))
        assert_true(v1.client_specified_payload_checksum)
        assert_true(Bool(v1.replication_status.value().automatic))
        assert_equal(v1.create_time.value().seconds, _EPOCH + 2)
        var v2 = g.add_secret_version[_RT](_add(String(_G) + "/secrets/db-password", _V2, False), reactor)
        assert_equal(v2.name, String(_GN) + "/versions/2")
        assert_false(v2.client_specified_payload_checksum)

        # A page of one at a time, newest first.
        var p1 = g.list_secret_versions[_RT](
            _list_versions(String(_G) + "/secrets/db-password", String("")), reactor
        )
        assert_equal(len(p1.versions), 1)
        assert_equal(p1.versions[0].name, String(_GN) + "/versions/2")
        assert_equal(p1.total_size, Int32(2))
        assert_equal(p1.next_page_token, "page-1")
        var p2 = g.list_secret_versions[_RT](
            _list_versions(String(_G) + "/secrets/db-password", p1.next_page_token), reactor
        )
        assert_equal(len(p2.versions), 1)
        assert_equal(p2.versions[0].name, String(_GN) + "/versions/1")
        assert_equal(p2.next_page_token, "")

        var latest = g.access_secret_version[_RT](
            _access(String(_G) + "/secrets/db-password/versions/latest"), reactor
        )
        assert_equal(latest.name, String(_GN) + "/versions/2")
        assert_equal(_text(latest.payload.value().data), _V2)
        assert_equal(
            latest.payload.value().data_crc32c.value(),
            Int64(Int(crc32c(Span(_bytes(_V2))))),
        )
        var first = g.access_secret_version[_RT](
            _access(String(_G) + "/secrets/db-password/versions/1"), reactor
        )
        assert_equal(_text(first.payload.value().data), _V1)
        assert_equal(
            first.payload.value().data_crc32c.value(),
            Int64(Int(crc32c(Span(_bytes(_V1))))),
        )

        # The regional secret, at its regional host and path.
        var r = gcp_loopback_client(
            self.port, String(REGIONAL_HOST), StaticTokenSource(String(TEST_ACCESS_TOKEN))
        )
        var rc = r.create_secret[_RT](
            decode_json[CreateSecretRequest](
                String('{"parent":"') + _R + '","secretId":"db-password","secret":{}}'
            ),
            reactor,
        )
        assert_equal(rc.name, _RN)
        assert_false(Bool(rc.replication))
        var rv = r.add_secret_version[_RT](_add(String(_R) + "/secrets/db-password", _V3, True), reactor)
        assert_equal(rv.name, String(_RN) + "/versions/1")
        assert_false(Bool(rv.replication_status))
        var ra = r.access_secret_version[_RT](
            _access(String(_R) + "/secrets/db-password/versions/latest"), reactor
        )
        assert_equal(ra.name, String(_RN) + "/versions/1")
        assert_equal(_text(ra.payload.value().data), _V3)

        var gl = g.list_secrets[_RT](_list(String(_G)), reactor)
        assert_equal(len(gl.secrets), 1)
        assert_equal(gl.secrets[0].name, _GN)
        assert_equal(gl.total_size, Int32(1))
        var rl = r.list_secrets[_RT](_list(String(_R)), reactor)
        assert_equal(len(rl.secrets), 1)
        assert_equal(rl.secrets[0].name, _RN)

        _ = g.delete_secret[_RT](_delete(String(_G) + "/secrets/db-password"), reactor)
        assert_equal(len(g.list_secrets[_RT](_list(String(_G)), reactor).secrets), 0)
        _ = r.delete_secret[_RT](_delete(String(_R) + "/secrets/db-password"), reactor)
        assert_equal(len(r.list_secrets[_RT](_list(String(_R)), reactor).secrets), 0)


def test_crc32c_matches_published_values() raises:
    # RFC 3720 appendix B.4 (32 zero bytes) and the CRC-32C check value of
    # "123456789"; "hunter2" is komira_gcp_secretmanager's own test vector.
    var zeros = List[UInt8]()
    zeros.resize(32, UInt8(0))
    assert_equal(Int(crc32c(Span(zeros))), 0x8A9136AA)
    assert_equal(Int(crc32c(Span(_bytes("123456789")))), 0xE3069283)
    assert_equal(Int(crc32c(Span(_bytes("hunter2")))), 1736498283)
    print("  test_crc32c_matches_published_values PASS")


def test_gcp_secret_lifecycle_over_tls() raises:
    var server = gcp_fake_server()
    var leg = _Lifecycle(server.port())
    serve_while(server, leg)
    ref fake = server.fake

    var g = String(" @") + GLOBAL_HOST + " 200"
    var r = String(" @") + REGIONAL_HOST + " 200"
    var want: List[String] = [
        "POST /v1/projects/demo-project/secrets?secretId=db-password" + g,
        "POST /v1/projects/demo-project/secrets/db-password:addVersion" + g,
        "POST /v1/projects/demo-project/secrets/db-password:addVersion" + g,
        "GET /v1/projects/demo-project/secrets/db-password/versions?pageSize=1" + g,
        "GET /v1/projects/demo-project/secrets/db-password/versions?pageSize=1&pageToken=page-1" + g,
        "GET /v1/projects/demo-project/secrets/db-password/versions/latest:access" + g,
        "GET /v1/projects/demo-project/secrets/db-password/versions/1:access" + g,
        "POST /v1/projects/demo-project/locations/us-central1/secrets?secretId=db-password" + r,
        "POST /v1/projects/demo-project/locations/us-central1/secrets/db-password:addVersion" + r,
        "GET /v1/projects/demo-project/locations/us-central1/secrets/db-password/versions/latest:access" + r,
        "GET /v1/projects/demo-project/secrets" + g,
        "GET /v1/projects/demo-project/locations/us-central1/secrets" + r,
        "DELETE /v1/projects/demo-project/secrets/db-password" + g,
        "GET /v1/projects/demo-project/secrets" + g,
        "DELETE /v1/projects/demo-project/locations/us-central1/secrets/db-password" + r,
        "GET /v1/projects/demo-project/locations/us-central1/secrets" + r,
    ]
    assert_equal(len(fake.log), len(want), "requests the fake answered")
    for i in range(len(want)):
        assert_equal(fake.log[i], want[i])
    for i in range(len(fake.authorizations)):
        assert_equal(fake.authorizations[i], String("Bearer ") + TEST_ACCESS_TOKEN)
    assert_equal(len(fake.error_bodies), 0)
    # komira_http_client keeps no HTTP/1.1-over-TLS connection alive
    # (`_dispatch_pooled_buffered` pools h1 over plaintext only), so today
    # each request is a connection of its own; at least one per client,
    # at most one per request, every one presenting `localhost`.
    var conns = len(server.front.snis)
    assert_true(conns >= 2 and conns <= len(want), String(conns))
    for i in range(conns):
        assert_equal(server.front.snis[i], GLOBAL_HOST)
    # Drain before asserting that no connection is left open. The client
    # closes each connection (every one today, and pooled ones when its
    # clients drop at the end of `run`) BEFORE the leg raises the stop
    # flag, so by the time `serve_while` has joined, every close_notify or
    # FIN is already queued in the kernel; but the server thread may have
    # stopped stepping before the front read the last of them. Stepping
    # the front here (non-blocking, no server needed) reads those queued
    # closes, so the outcome does not depend on thread scheduling: one step
    # suffices, and the bound only guards a defect that keeps a pair open.
    var drains = 0
    while server.front.open_pairs() > 0 and drains < 100:
        server.front.step()
        drains += 1
    assert_equal(server.front.open_pairs(), 0, "a connection left open")
    assert_equal(server.front.handshakes_failed, 0)
    print("  test_gcp_secret_lifecycle_over_tls PASS")


def main() raises:
    tls_init()
    test_crc32c_matches_published_values()
    test_gcp_secret_lifecycle_over_tls()
    print("PASS komira_secrets_e2e GCP secret lifecycle")
