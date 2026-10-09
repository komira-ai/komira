# =============================================================================
# test_gcp_refusals.mojo -- what the generated GCP client raises when the
# fake refuses, over TLS on loopback, and that none of it holds a payload
# =============================================================================
#
# Each refusal is a google.rpc.Status envelope from the fake; the generated
# client raises it through komira_gcp_core's `gcp_status_error`. The leg
# sends, in order:
#
#   AccessSecretVersion of a secret that does not exist   404 NOT_FOUND
#   AddSecretVersion (with a payload) to that secret      404 NOT_FOUND
#   CreateSecret `dup`, then CreateSecret `dup` again     200, 409 ALREADY_EXISTS
#   AddSecretVersion whose dataCrc32c is not its data's   400 INVALID_ARGUMENT
#   AddSecretVersion from a token source with no token    401 UNAUTHENTICATED
#   AccessSecretVersion with another token                401 UNAUTHENTICATED
#   AccessSecretVersion of a regional name at the global  400 INVALID_ARGUMENT
#     host (the fake serves a location only at its own)
#   DeleteSecret of a secret that does not exist          404 NOT_FOUND
#
# What each assertion catches:
#   * each raised text EXACTLY, as komira_gcp_core renders it (verb, RPC,
#     HTTP status, code name and number, the byte counts of error.message
#     and the body, both taken from what the fake sent): a client that maps
#     a status to the wrong code, raises another error, or quotes the body;
#   * the fake's request log exactly, and the Authorization header of each
#     request: the token-less client sent `Bearer` with nothing after it,
#     and the other client its own token, so each 401 is the fake's verdict
#     on the header the client really sent;
#   * custody: no raised text holds any payload, although the fake's error
#     bodies DID carry three of them (the positive control: the 404, the 400
#     and the 401 to AddSecretVersion each repeat the payload).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_encoding import base64_encode
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.service import (
    AccessSecretVersionRequest,
    AddSecretVersionRequest,
    CreateSecretRequest,
    DeleteSecretRequest,
)
from komira_http_core.tls import tls_init
from komira_proto_codec.codec import decode_json

from komira_secrets_e2e import (
    GLOBAL_HOST,
    OTHER_ACCESS_TOKEN,
    TEST_ACCESS_TOKEN,
    ClientLeg,
    NoTokenSource,
    crc32c,
    gcp_fake_server,
    gcp_loopback_client,
    leaks,
    serve_while,
)

comptime _RT = BlockingRuntime[NoopSink]
comptime _P1 = "gsm-refusal-canary-absent-6b1d"
comptime _P2 = "gsm-refusal-canary-checksum-0c9e"
comptime _P3 = "gsm-refusal-canary-no-token-f472"


def _add(parent: String, value: String, crc: Int) raises -> AddSecretVersionRequest:
    var data = List[UInt8]()
    data.extend(Span(value.as_bytes()))
    var payload = String('{"data":"') + base64_encode(Span(data)) + '"'
    if crc >= 0:
        payload += String(',"dataCrc32c":"') + String(crc) + '"'
    return decode_json[AddSecretVersionRequest](
        String('{"parent":"') + parent + '","payload":' + payload + "}}"
    )


def _access(name: String) raises -> AccessSecretVersionRequest:
    return decode_json[AccessSecretVersionRequest](String('{"name":"') + name + '"}')


def _create(secret_id: String) raises -> CreateSecretRequest:
    return decode_json[CreateSecretRequest](
        String('{"parent":"projects/demo-project","secretId":"') + secret_id
        + '","secret":{"replication":{"automatic":{}}}}'
    )


struct _Refusals(ClientLeg):
    var port: UInt16
    # Every text the client raised, in order ("" where a call did not
    # raise, which fails the test after the join).
    var errors: List[String]

    def __init__(out self, port: UInt16):
        self.port = port
        self.errors = List[String]()

    def run(mut self) raises:
        var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var g = gcp_loopback_client(
            self.port, String(GLOBAL_HOST), StaticTokenSource(String(TEST_ACCESS_TOKEN))
        )
        var none = gcp_loopback_client(self.port, String(GLOBAL_HOST), NoTokenSource())
        var other = gcp_loopback_client(
            self.port, String(GLOBAL_HOST), StaticTokenSource(String(OTHER_ACCESS_TOKEN))
        )

        var text = String("")
        try:
            _ = g.access_secret_version[_RT](
                _access("projects/demo-project/secrets/absent/versions/latest"), reactor
            )
        except e:
            text = String(e)
        self.errors.append(text^)

        text = String("")
        try:
            _ = g.add_secret_version[_RT](_add("projects/demo-project/secrets/absent", _P1, -1), reactor)
        except e:
            text = String(e)
        self.errors.append(text^)

        _ = g.create_secret[_RT](_create("dup"), reactor)
        text = String("")
        try:
            _ = g.create_secret[_RT](_create("dup"), reactor)
        except e:
            text = String(e)
        self.errors.append(text^)

        # A checksum that is not the payload's: the real one, plus one.
        var p2 = List[UInt8]()
        p2.extend(Span(String(_P2).as_bytes()))
        text = String("")
        try:
            _ = g.add_secret_version[_RT](
                _add("projects/demo-project/secrets/dup", _P2, Int(crc32c(Span(p2))) + 1), reactor
            )
        except e:
            text = String(e)
        self.errors.append(text^)

        text = String("")
        try:
            _ = none.add_secret_version[_RT](_add("projects/demo-project/secrets/dup", _P3, -1), reactor)
        except e:
            text = String(e)
        self.errors.append(text^)

        text = String("")
        try:
            _ = other.access_secret_version[_RT](
                _access("projects/demo-project/secrets/dup/versions/latest"), reactor
            )
        except e:
            text = String(e)
        self.errors.append(text^)

        text = String("")
        try:
            _ = g.access_secret_version[_RT](
                _access("projects/demo-project/locations/us-central1/secrets/dup/versions/latest"),
                reactor,
            )
        except e:
            text = String(e)
        self.errors.append(text^)

        text = String("")
        try:
            _ = g.delete_secret[_RT](
                decode_json[DeleteSecretRequest]('{"name":"projects/demo-project/secrets/absent"}'),
                reactor,
            )
        except e:
            text = String(e)
        self.errors.append(text^)


def test_gcp_refusals_over_tls() raises:
    var server = gcp_fake_server()
    var leg = _Refusals(server.port())
    serve_while(server, leg)
    ref fake = server.fake

    var at = String(" @") + GLOBAL_HOST + " "
    var want_log: List[String] = [
        "GET /v1/projects/demo-project/secrets/absent/versions/latest:access" + at + "404 NOT_FOUND",
        "POST /v1/projects/demo-project/secrets/absent:addVersion" + at + "404 NOT_FOUND",
        "POST /v1/projects/demo-project/secrets?secretId=dup" + at + "200",
        "POST /v1/projects/demo-project/secrets?secretId=dup" + at + "409 ALREADY_EXISTS",
        "POST /v1/projects/demo-project/secrets/dup:addVersion" + at + "400 INVALID_ARGUMENT",
        "POST /v1/projects/demo-project/secrets/dup:addVersion" + at + "401 UNAUTHENTICATED",
        "GET /v1/projects/demo-project/secrets/dup/versions/latest:access" + at + "401 UNAUTHENTICATED",
        "GET /v1/projects/demo-project/locations/us-central1/secrets/dup/versions/latest:access"
        + at + "400 INVALID_ARGUMENT",
        "DELETE /v1/projects/demo-project/secrets/absent" + at + "404 NOT_FOUND",
    ]
    assert_equal(len(fake.log), len(want_log), "requests the fake answered")
    for i in range(len(want_log)):
        assert_equal(fake.log[i], want_log[i])

    var bearer = String("Bearer ") + TEST_ACCESS_TOKEN
    for i in range(len(fake.authorizations)):
        if i == 5:
            # The token-less client: the scheme and nothing after it (the
            # server's parser drops the trailing space).
            assert_equal(String(fake.authorizations[i].strip()), "Bearer")
        elif i == 6:
            assert_equal(fake.authorizations[i], String("Bearer ") + OTHER_ACCESS_TOKEN)
        else:
            assert_equal(fake.authorizations[i], bearer)

    # The raised texts, exactly; the byte counts are of what the fake sent.
    var heads: List[String] = [
        "GET AccessSecretVersion: HTTP 404, NOT_FOUND (code 5)",
        "POST AddSecretVersion: HTTP 404, NOT_FOUND (code 5)",
        "POST CreateSecret: HTTP 409, ALREADY_EXISTS (code 6)",
        "POST AddSecretVersion: HTTP 400, INVALID_ARGUMENT (code 3)",
        "POST AddSecretVersion: HTTP 401, UNAUTHENTICATED (code 16)",
        "GET AccessSecretVersion: HTTP 401, UNAUTHENTICATED (code 16)",
        "GET AccessSecretVersion: HTTP 400, INVALID_ARGUMENT (code 3)",
        "DELETE DeleteSecret: HTTP 404, NOT_FOUND (code 5)",
    ]
    assert_equal(len(leg.errors), len(heads))
    assert_equal(len(fake.error_bodies), len(heads))
    for i in range(len(heads)):
        assert_equal(
            leg.errors[i],
            heads[i]
            + ", error.message "
            + String(fake.error_message_bytes[i])
            + " bytes, body "
            + String(fake.error_bodies[i].byte_length())
            + " bytes",
        )

    # Custody. The positive control first: three payloads were on the wire,
    # in the error bodies answering the three AddSecretVersion requests.
    assert_true(leaks(fake.error_bodies[1], String(_P1)), fake.error_bodies[1])
    assert_true(leaks(fake.error_bodies[3], String(_P2)), fake.error_bodies[3])
    assert_true(leaks(fake.error_bodies[4], String(_P3)), fake.error_bodies[4])
    for i in range(len(leg.errors)):
        assert_false(leaks(leg.errors[i], String(_P1)), leg.errors[i])
        assert_false(leaks(leg.errors[i], String(_P2)), leg.errors[i])
        assert_false(leaks(leg.errors[i], String(_P3)), leg.errors[i])
    print("  test_gcp_refusals_over_tls PASS")


def main() raises:
    tls_init()
    test_gcp_refusals_over_tls()
    print("PASS komira_secrets_e2e GCP refusals")
