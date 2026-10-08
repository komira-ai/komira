# =============================================================================
# test_aws_store_registry.mojo -- write through the Secrets Manager
# SecretWriter, then resolve through SecretRegistry to a CredentialConsumer,
# against the fake over a real socket
# =============================================================================
#
# kci_aws_secret_writer's `AwsSecretsManagerWriter` and
# komira_aws_secret_store's `AwsSecretsManagerStore`, each over the
# generated client pointed at the fake (client.mojo), drive it through:
#
#   the writer: has_version of a secret that does not exist (False),
#   define_container twice (created, then the no-op), has_version of the
#   empty container (False), a first value written into it, has_version
#   (True), a write to a secret that does not exist (created with the value),
#   a second value written over the first;
#   the registry: a `SecretRegistry` owning the store, with bindings to the
#   bare name (AWSCURRENT), to `?versionStage=AWSPREVIOUS`, to `?versionId=`
#   the first version's id, to the created secret, to the secret's ARN, and
#   to a secret that does not exist; each bound node revealed into a
#   recording `CredentialConsumer`;
#   then a secret scheduled for deletion, which has_version and write both
#   refuse; a write carrying a deploy token, refused before anything is
#   sent; a writer signing with a wrong key, whose has_version raises
#   rather than answering False; and a secret whose one version holds only
#   AWSPENDING (put with the generated client's VersionStages), which
#   has_version answers False: the bare handle reads AWSCURRENT.
#
# What each assertion catches:
#   * the bytes each node's reveal handed the consumer: a handle mapped to
#     the wrong SecretId, a version stage or id dropped from the request
#     (the AWSPREVIOUS and versionId nodes would see the current value), a
#     SecretString read from the wrong member, a write that did not make the
#     new version current;
#   * has_version's answers: a probe that reads a missing secret, an empty
#     container or an AWSPENDING-only secret as holding a version, or a held
#     one as empty;
#   * the fake's request log, exactly: a create-if-absent that creates
#     before trying the put, a define that is not idempotent, a deleted
#     secret's write turned into a create, a refused write that still sent,
#     a probe that reads the value (GetSecretValue) instead of metadata;
#   * the raised texts, exactly: a provider error swallowed (the wrongly
#     keyed probe answering False, the missing node resolving to an empty
#     value), a refusal without the handle, or anything added to the
#     service's code and message;
#   * custody: no raised text holds any written value, while the fake's error
#     body for the put to the missing secret carried one (the positive
#     control).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import StaticCredsSource
from kci_aws_secret_writer import AwsSecretsManagerWriter
from komira_aws_secret_store import AwsSecretsManagerStore
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerDeleteSecretRequest,
    SecretsManagerGetSecretValueRequest,
    SecretsManagerPutSecretValueRequest,
)
from komira_aws_secretsmanager.secretsmanager_overrides import delete_secret
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_secret_registry import CredentialConsumer, SecretRegistry
from komira_secret_store import SecretValue

from komira_secrets_e2e import (
    EXAMPLE_SECRET_ACCESS_KEY,
    FAKE_REGION,
    WRONG_SECRET_ACCESS_KEY,
    ClientLeg,
    FakeSecretsManager,
    FakeServer,
    fake_credentials,
    leaks,
    loopback_client,
    serve_while,
)

comptime _Store = AwsSecretsManagerStore[KernelTcpConnector, StaticCredsSource]

comptime _V1 = "aws-adapter-canary-one-3c81"
comptime _V2 = "aws-adapter-canary-fresh-9d07"
comptime _V3 = "aws-adapter-canary-three-e5a2"
comptime _V4 = "aws-adapter-canary-late-41fb"
comptime _V5 = "aws-adapter-canary-pending-6e2d"


struct _Recorder(CredentialConsumer, Movable):
    """Copies each revealed value out (a test double: a connector would
    use the bytes and keep nothing)."""

    var seen: List[String]

    def __init__(out self):
        self.seen = List[String]()

    def consume(mut self, secret: Span[UInt8, _]) raises:
        var b = List[UInt8]()
        b.extend(secret)
        self.seen.append(String(unsafe_from_utf8=Span(b)))


def _v(s: StaticString) raises -> SecretValue:
    return SecretValue.from_string(String(s))


struct _Flow(ClientLeg):
    var port: UInt16
    var probes: List[Bool]
    var seen: List[String]
    var errors: List[String]

    def __init__(out self, port: UInt16):
        self.port = port
        self.probes = List[Bool]()
        self.seen = List[String]()
        self.errors = List[String]()

    def run(mut self) raises:
        var key = String(EXAMPLE_SECRET_ACCESS_KEY)
        var w = AwsSecretsManagerWriter(loopback_client(self.port, key))
        self.probes.append(w.has_version(String("app/smtp"), String("")))
        w.define_container(String("app/smtp"), String(""))
        w.define_container(String("app/smtp"), String(""))
        self.probes.append(w.has_version(String("app/smtp"), String("")))
        w.write(String("app/smtp"), _v(_V1), String(""))
        self.probes.append(w.has_version(String("app/smtp"), String("")))
        w.write(String("app/fresh"), _v(_V2), String(""))
        w.write(String("app/smtp"), _v(_V3), String(""))

        # The first value's version id and the secret's ARN, read with the
        # generated client itself.
        var raw = loopback_client(self.port, key)
        var prev = SecretsManagerGetSecretValueRequest(String("app/smtp"))
        prev.version_stage = Optional[String](String("AWSPREVIOUS"))
        var first = raw.get_secret_value(prev)
        var first_id = first.version_id.value()
        var arn = first.arn.value()

        var reg = SecretRegistry[_Store](_Store(loopback_client(self.port, key)))
        reg.register(1, String("smtp"), String("app/smtp"))
        reg.register(2, String("smtp-previous"), String("app/smtp?versionStage=AWSPREVIOUS"))
        reg.register(3, String("smtp-first"), String("app/smtp?versionId=") + first_id)
        reg.register(4, String("fresh"), String("app/fresh"))
        reg.register(5, String("smtp-by-arn"), arn)
        reg.register(6, String("missing"), String("app/missing"))
        var rec = _Recorder()
        for node in range(1, 6):
            reg.reveal_for(node, rec)
        try:
            reg.reveal_for(6, rec)
        except e:
            self.errors.append(String(e))
        self.seen = rec.seen.copy()

        # A secret scheduled for deletion: neither probed nor written.
        var del_req = SecretsManagerDeleteSecretRequest(String("app/fresh"))
        del_req.recovery_window_in_days = Optional[Int64](Int64(7))
        _ = delete_secret(raw, del_req)
        try:
            _ = w.has_version(String("app/fresh"), String(""))
        except e:
            self.errors.append(String(e))
        try:
            w.write(String("app/fresh"), _v(_V4), String(""))
        except e:
            self.errors.append(String(e))
        # A deploy token: refused before anything is sent.
        try:
            w.write(String("app/smtp"), _v(_V4), String("a-deploy-bearer-token"))
        except e:
            self.errors.append(String(e))
        # A writer that signs with the wrong key: the probe raises.
        var bad = AwsSecretsManagerWriter(
            loopback_client(self.port, String(WRONG_SECRET_ACCESS_KEY))
        )
        try:
            _ = bad.has_version(String("app/smtp"), String(""))
        except e:
            self.errors.append(String(e))

        # A secret whose one version holds only AWSPENDING: no AWSCURRENT.
        w.define_container(String("app/pending"), String(""))
        var pending = SecretsManagerPutSecretValueRequest(String("app/pending"))
        pending.secret_string = Optional[String](String(_V5))
        var stages = List[String]()
        stages.append(String("AWSPENDING"))
        pending.set_version_stages(stages^)
        _ = raw.put_secret_value(pending)
        self.probes.append(w.has_version(String("app/pending"), String("")))


def test_aws_write_then_resolve_through_registry() raises:
    var server = FakeServer(FakeSecretsManager(fake_credentials(), String(FAKE_REGION)))
    var leg = _Flow(server.port())
    serve_while(server, leg)
    ref fake = server.fake

    assert_equal(len(leg.probes), 4)
    assert_false(leg.probes[0], "a secret that does not exist holds no version")
    assert_false(leg.probes[1], "an empty container holds no version")
    assert_true(leg.probes[2], "a written secret holds a version")
    assert_false(leg.probes[3], "an AWSPENDING-only secret holds no AWSCURRENT version")

    var want_seen: List[String] = [_V3, _V1, _V1, _V2, _V3]
    assert_equal(len(leg.seen), len(want_seen))
    for i in range(len(want_seen)):
        assert_equal(leg.seen[i], want_seen[i], String("node ") + String(i + 1))

    var want_log: List[String] = [
        "DescribeSecret 400 ResourceNotFoundException",
        "CreateSecret 200",
        "CreateSecret 400 ResourceExistsException",
        "DescribeSecret 200",
        "PutSecretValue 200",
        "DescribeSecret 200",
        "PutSecretValue 400 ResourceNotFoundException",
        "CreateSecret 200",
        "PutSecretValue 200",
        "GetSecretValue 200",
        "GetSecretValue 200",
        "GetSecretValue 200",
        "GetSecretValue 200",
        "GetSecretValue 200",
        "GetSecretValue 200",
        "GetSecretValue 400 ResourceNotFoundException",
        "DeleteSecret 200",
        "DescribeSecret 200",
        "PutSecretValue 400 InvalidRequestException",
        "DescribeSecret 400 InvalidSignatureException",
        "CreateSecret 200",
        "PutSecretValue 200",
        "DescribeSecret 200",
    ]
    assert_equal(len(fake.log), len(want_log), "requests the fake answered")
    for i in range(len(want_log)):
        assert_equal(fake.log[i], String("secretsmanager ") + want_log[i])
    # Three creates (two containers; the fresh secret with its value), three
    # puts and one deletion; nothing replayed.
    assert_equal(fake.applied_writes, 7)
    assert_equal(fake.replayed_writes, 0)

    var want_errors: List[String] = [
        "AwsSecretsManagerStore: resolve of secret_ref app/missing failed:"
        + " SecretsManager.GetSecretValue failed: HTTP 400 ResourceNotFoundException"
        + " Secrets Manager can't find the specified secret.",
        "AwsSecretsManagerWriter: has_version of secret_ref app/fresh failed:"
        + " the secret is scheduled for deletion: restore it (RestoreSecret) or"
        + " wait for the deletion before writing",
        "AwsSecretsManagerWriter: write of secret_ref app/fresh failed:"
        + " SecretsManager.PutSecretValue failed: HTTP 400 InvalidRequestException"
        + " You can't perform this operation on the secret because it was marked"
        + " for deletion.",
        "AwsSecretsManagerWriter: write refused: a deploy token was given, and"
        + " Secrets Manager signs each request with the client's credential"
        + " source; build the client over the deploy principal's credentials and"
        + " pass an empty token",
        "AwsSecretsManagerWriter: has_version of secret_ref app/smtp failed:"
        + " SecretsManager.DescribeSecret failed: HTTP 400 InvalidSignatureException"
        + " The request signature we calculated does not match the signature you"
        + " provided. Check your AWS Secret Access Key and signing method.",
    ]
    assert_equal(len(leg.errors), len(want_errors))
    for i in range(len(want_errors)):
        assert_equal(leg.errors[i], want_errors[i])

    # Custody. The positive control: the put to the missing secret was
    # answered with an error body repeating its value.
    var on_wire = False
    for i in range(len(fake.error_bodies)):
        if leaks(fake.error_bodies[i], String(_V2)):
            on_wire = True
    assert_true(on_wire, "the fake's error body carries the put's value")
    var values: List[String] = [_V1, _V2, _V3, _V4, _V5]
    for i in range(len(leg.errors)):
        for k in range(len(values)):
            assert_false(leaks(leg.errors[i], values[k]), leg.errors[i])
    print("  test_aws_write_then_resolve_through_registry PASS")


def main() raises:
    test_aws_write_then_resolve_through_registry()
    print("PASS komira_secrets_e2e AWS store and writer through the registry")
