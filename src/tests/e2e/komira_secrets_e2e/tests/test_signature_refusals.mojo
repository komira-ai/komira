# =============================================================================
# test_signature_refusals.mojo -- the fake's SigV4 check is right, and a
# client signing with the wrong key is refused over the wire
# =============================================================================
#
# First the verifier on its own, so the e2e tests can trust its "accept":
#
#   * a request in the shape of the AWS SigV4 test suite's `get-vanilla`
#     case (GET / to example.amazonaws.com, signing host and x-amz-date, the
#     suite's example credential, service `service`), dated 20261001, whose
#     signature was computed outside komira with Python's hmac and hashlib
#     following the SigV4 steps: accepted; the same signature with one hex
#     digit changed, and the same request with a body it did not sign, are
#     refused InvalidSignatureException;
#   * the same request scoped to another service is refused with the
#     service's wording, naming the service it should be scoped to (what a
#     client signing with the wrong signing name is told);
#   * an unknown access key id is refused UnrecognizedClientException.
#
# Then over the wire: the generated client with a secret access key one
# character off sends a CreateSecret; the fake refuses it
# InvalidSignatureException (HTTP 400, not retried), the client raises that
# code and message, the refused request applies nothing, and the raised
# text does not hold the secret value although the fake's error body did.
# The same leg's client with the right key then creates the secret (the
# store then holds one secret and `applied_writes` is 1), so the refusal is
# the signature's, not the fake refusing everything.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerCreateSecretRequest,
)
from komira_secrets_e2e import (
    EXAMPLE_SECRET_ACCESS_KEY,
    FAKE_REGION,
    WRONG_SECRET_ACCESS_KEY,
    CannedCredential,
    ClientLeg,
    FakeSecretsManager,
    FakeServer,
    fake_credentials,
    leaks,
    loopback_client,
    serve_while,
    verify_sigv4,
)

# The get-vanilla shape, dated 20261001; the signature computed with
# Python hmac/hashlib, independently of komira.
comptime _SUITE_KEY = "AKIDEXAMPLE"
comptime _SUITE_SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
comptime _SUITE_SIGNATURE = "7a0a4e087877358b24e9fa928311c183edb8d061f172ea30a069c97614c4f113"

comptime _NAME = "app/e2e-signed"
comptime _VALUE = "kz9-custody-canary-signed-3e81"


def _vanilla(signature: String, service: String) -> Dict[String, String]:
    var h = Dict[String, String]()
    h[String("host")] = String("example.amazonaws.com")
    h[String("x-amz-date")] = String("20261001T123600Z")
    h[String("authorization")] = (
        String("AWS4-HMAC-SHA256 Credential=")
        + _SUITE_KEY
        + "/20261001/us-east-1/"
        + service
        + "/aws4_request, SignedHeaders=host;x-amz-date, Signature="
        + signature
    )
    return h^


def _suite_credentials() -> List[CannedCredential]:
    var out = List[CannedCredential]()
    out.append(CannedCredential(String(_SUITE_KEY), String(_SUITE_SECRET)))
    return out^


def test_the_verifier_against_the_suite() raises:
    var empty = List[UInt8]()
    var ok = verify_sigv4(
        String("GET"), String("/"), String(""),
        _vanilla(String(_SUITE_SIGNATURE), String("service")),
        Span(empty), _suite_credentials(), String("us-east-1"), String("service"),
    )
    assert_true(ok.ok, ok.message)

    var sig = String(_SUITE_SIGNATURE)
    var off = String(sig[byte=0:63]) + "0"
    var bad = verify_sigv4(
        String("GET"), String("/"), String(""),
        _vanilla(off, String("service")),
        Span(empty), _suite_credentials(), String("us-east-1"), String("service"),
    )
    assert_false(bad.ok)
    assert_equal(bad.code, "InvalidSignatureException")

    # A body the signature did not cover.
    var body = List[UInt8]()
    body.append(UInt8(0x7B))
    var tampered = verify_sigv4(
        String("GET"), String("/"), String(""),
        _vanilla(String(_SUITE_SIGNATURE), String("service")),
        Span(body), _suite_credentials(), String("us-east-1"), String("service"),
    )
    assert_false(tampered.ok)
    assert_equal(tampered.code, "InvalidSignatureException")

    var scoped = verify_sigv4(
        String("GET"), String("/"), String(""),
        _vanilla(String(_SUITE_SIGNATURE), String("service")),
        Span(empty), _suite_credentials(), String("us-east-1"), String("secretsmanager"),
    )
    assert_false(scoped.ok)
    assert_equal(scoped.code, "InvalidSignatureException")
    assert_equal(scoped.message, "Credential should be scoped to correct service: 'secretsmanager'.")

    var stranger = verify_sigv4(
        String("GET"), String("/"), String(""),
        _vanilla(String(_SUITE_SIGNATURE), String("service")),
        Span(empty), fake_credentials(), String("us-east-1"), String("service"),
    )
    assert_false(stranger.ok)
    assert_equal(stranger.code, "UnrecognizedClientException")
    print("  test_the_verifier_against_the_suite PASS")


struct _WrongKey(ClientLeg):
    var port: UInt16
    var refused: String
    var created_version: String

    def __init__(out self, port: UInt16):
        self.port = port
        self.refused = String("")
        self.created_version = String("")

    def run(mut self) raises:
        var create = SecretsManagerCreateSecretRequest(String(_NAME))
        create.secret_string = Optional[String](String(_VALUE))
        var wrong = loopback_client(self.port, String(WRONG_SECRET_ACCESS_KEY))
        try:
            _ = wrong.create_secret(create)
        except e:
            self.refused = String(e)
        var right = loopback_client(self.port, String(EXAMPLE_SECRET_ACCESS_KEY))
        self.created_version = right.create_secret(create).version_id.value()


def test_a_wrong_key_is_refused_over_the_wire() raises:
    var server = FakeServer(FakeSecretsManager(fake_credentials(), String(FAKE_REGION)))
    var leg = _WrongKey(server.port())
    serve_while(server, leg)
    ref f = server.fake

    assert_true(
        leg.refused.find(
            "SecretsManager.CreateSecret failed: HTTP 400 InvalidSignatureException"
            " The request signature we calculated does not match"
        ) >= 0,
        leg.refused,
    )
    assert_equal(len(f.log), 2)
    assert_equal(f.log[0], "secretsmanager CreateSecret 400 InvalidSignatureException")
    assert_equal(f.log[1], "secretsmanager CreateSecret 200")
    # The refused request reached no state; the second one made the secret.
    assert_equal(f.applied_writes, 1)
    assert_equal(len(f.store.secrets), 1)
    assert_true(leg.created_version.byte_length() == 36, leg.created_version)

    # Custody: on the wire, not in the raised text.
    assert_equal(len(f.error_bodies), 1)
    assert_true(leaks(f.error_bodies[0], String(_VALUE)), f.error_bodies[0])
    assert_false(leaks(leg.refused, String(_VALUE)), leg.refused)
    assert_equal(len(f.server_log), 0, "no 5xx, so no body-bearing server log line")
    print("  test_a_wrong_key_is_refused_over_the_wire PASS")


def main() raises:
    test_the_verifier_against_the_suite()
    test_a_wrong_key_is_refused_over_the_wire()
    print("PASS komira_secrets_e2e signature refusals")
