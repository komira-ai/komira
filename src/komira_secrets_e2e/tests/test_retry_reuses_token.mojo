# =============================================================================
# test_retry_reuses_token.mojo -- a retried write carries the same
# ClientRequestToken on the wire, and the fake applies it once
# =============================================================================
#
# Two scripted runs, each against its own fake, each through the client's
# plain verbs (`create_secret`, `put_secret_value`): its own retry loop, its
# own sleeps, a real socket.
#
#   * PutSecretValue answered 500 BEFORE the write is applied (after a plain
#     CreateSecret). The resend applies it, once. Here only the token
#     assertions can see a token minted per attempt (the resend's token equals
#     the first's, and the reported version is the first token): the first
#     send was never applied, so a fresh token would be taken as a new version
#     and the call would succeed. It runs first, so a failure in the other run cannot
#     hide it.
#   * CreateSecret APPLIED, then answered 500 (the answer lost on its way
#     back). The resend carries the same token, so the fake answers it from
#     the version the first request made (a replay) and makes no second
#     secret.
#
# What each asserts, from the fake's record of each request on the wire: two
# requests of the retried operation, answered 500 then 200; the two tokens
# byte-equal, a version 4 UUID, and the version id the client reports; how
# many writes were applied and replayed; the versions DescribeSecret lists.
# Last, a self-check of the FAKE, not of the client: the line
# komira_http_server writes to stdout for the scripted 500 (`server_log`,
# rendered by the server's own `error_response_log_line`) holds neither
# value, as the server's contract for a returned 5xx body requires. Nothing
# the client does can change that line; the check exists so a fake that
# echoed the request into a 5xx body (putting the value in the build log)
# goes red here. The client custody checks, with their positive control, are
# in test_secret_lifecycle and test_signature_refusals; this test raises no
# error to check.
#
# Defects it catches, each seen red with a mutant planted in komira_aws_core's
# `_send_with_retries`: a fresh token minted per attempt (red at the Put
# byte-equality assertion; the Create run goes red too, answered
# ResourceExistsException), and the token dropped on the resend (the resend
# carries none, this fake refuses it and the call raises). Either would
# duplicate a write the service had already applied.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerCreateSecretRequest,
    SecretsManagerDescribeSecretRequest,
    SecretsManagerGetSecretValueRequest,
    SecretsManagerPutSecretValueRequest,
)
from komira_secrets_e2e import (
    EXAMPLE_SECRET_ACCESS_KEY,
    FAKE_REGION,
    FAULT_500_AFTER_APPLY,
    FAULT_500_BEFORE_APPLY,
    ClientLeg,
    FakeSecretsManager,
    FakeServer,
    fake_credentials,
    leaks,
    loopback_client,
    serve_while,
)

comptime _NAME = "app/e2e-retry"
comptime _V1 = "kz9-custody-canary-retry-one-5d20"
comptime _V2 = "kz9-custody-canary-retry-two-9b6c"


struct _CreateRetried(ClientLeg):
    """CreateSecret answered 500 after it was applied, then the reads."""

    var port: UInt16
    var created_version: String
    var versions_listed: Int

    def __init__(out self, port: UInt16):
        self.port = port
        self.created_version = String("")
        self.versions_listed = -1

    def run(mut self) raises:
        var client = loopback_client(self.port, String(EXAMPLE_SECRET_ACCESS_KEY))
        var create = SecretsManagerCreateSecretRequest(String(_NAME))
        create.secret_string = Optional[String](String(_V1))
        var created = client.create_secret(create)
        self.created_version = created.version_id.value()
        var got = client.get_secret_value(SecretsManagerGetSecretValueRequest(String(_NAME)))
        assert_equal(got.secret_string.value(), _V1)
        var d = client.describe_secret(SecretsManagerDescribeSecretRequest(String(_NAME)))
        self.versions_listed = len(d.version_ids_to_stages.value())


struct _PutRetried(ClientLeg):
    """A plain CreateSecret, then PutSecretValue answered 500 before it was
    applied, then the reads."""

    var port: UInt16
    var put_version: String
    var versions_listed: Int

    def __init__(out self, port: UInt16):
        self.port = port
        self.put_version = String("")
        self.versions_listed = -1

    def run(mut self) raises:
        var client = loopback_client(self.port, String(EXAMPLE_SECRET_ACCESS_KEY))
        var create = SecretsManagerCreateSecretRequest(String(_NAME))
        create.secret_string = Optional[String](String(_V1))
        _ = client.create_secret(create)
        var put = SecretsManagerPutSecretValueRequest(String(_NAME))
        put.secret_string = Optional[String](String(_V2))
        var p = client.put_secret_value(put)
        self.put_version = p.version_id.value()
        var got = client.get_secret_value(SecretsManagerGetSecretValueRequest(String(_NAME)))
        assert_equal(got.secret_string.value(), _V2)
        var d = client.describe_secret(SecretsManagerDescribeSecretRequest(String(_NAME)))
        self.versions_listed = len(d.version_ids_to_stages.value())


def _assert_uuid4(tok: String) raises:
    assert_equal(tok.byte_length(), 36, tok)
    for i in [8, 13, 18, 23]:
        assert_equal(String(tok[byte = i : i + 1]), "-", tok)
    assert_equal(String(tok[byte=14:15]), "4", tok)


def _assert_server_log_clean(f: FakeSecretsManager, want: Int) raises:
    """Self-check of the fake: the server's stdout lines for its 500s carry
    no value (the server's 5xx-body logging contract)."""
    assert_equal(len(f.server_log), want, "one server log line per scripted 500")
    for i in range(len(f.server_log)):
        assert_false(leaks(f.server_log[i], String(_V1)), f.server_log[i])
        assert_false(leaks(f.server_log[i], String(_V2)), f.server_log[i])


def test_a_create_answered_500_after_apply_is_replayed() raises:
    var fake = FakeSecretsManager(fake_credentials(), String(FAKE_REGION))
    fake.arm_fault(String("CreateSecret"), FAULT_500_AFTER_APPLY)
    var server = FakeServer(fake^)
    var leg = _CreateRetried(server.port())
    serve_while(server, leg)
    ref f = server.fake

    var creates = f.operations(String("CreateSecret"))
    assert_equal(len(creates), 2, "CreateSecret requests on the wire")
    assert_equal(creates[0].status, 500)
    assert_equal(creates[1].status, 200)
    _assert_uuid4(creates[0].token)
    # Byte for byte: the same token on the resend.
    assert_equal(creates[1].token, creates[0].token)
    assert_equal(leg.created_version, creates[0].token)
    # Applied once; the resend was a replay.
    assert_equal(f.applied_writes, 1)
    assert_equal(f.replayed_writes, 1)
    assert_equal(len(f.store.secrets), 1)
    assert_equal(len(f.store.secrets[0].versions), 1)
    assert_equal(leg.versions_listed, 1)
    _assert_server_log_clean(f, 1)
    print("  test_a_create_answered_500_after_apply_is_replayed PASS")


def test_a_put_answered_500_before_apply_keeps_its_token() raises:
    var fake = FakeSecretsManager(fake_credentials(), String(FAKE_REGION))
    fake.arm_fault(String("PutSecretValue"), FAULT_500_BEFORE_APPLY)
    var server = FakeServer(fake^)
    var leg = _PutRetried(server.port())
    serve_while(server, leg)
    ref f = server.fake

    var puts = f.operations(String("PutSecretValue"))
    assert_equal(len(puts), 2, "PutSecretValue requests on the wire")
    assert_equal(puts[0].status, 500)
    assert_equal(puts[1].status, 200)
    _assert_uuid4(puts[0].token)
    # Byte for byte. Only these two assertions can see a token minted per
    # attempt: the first send was never applied, so a fresh token on the
    # resend is accepted as a new version (the reported version would then be
    # the new token) and every other assertion passes.
    assert_equal(puts[1].token, puts[0].token)
    assert_equal(leg.put_version, puts[0].token)
    # Create and put, each applied once; nothing replayed.
    assert_equal(f.applied_writes, 2)
    assert_equal(f.replayed_writes, 0)
    assert_equal(len(f.store.secrets), 1)
    assert_equal(len(f.store.secrets[0].versions), 2)
    assert_equal(leg.versions_listed, 2)
    _assert_server_log_clean(f, 1)
    print("  test_a_put_answered_500_before_apply_keeps_its_token PASS")


def main() raises:
    test_a_put_answered_500_before_apply_keeps_its_token()
    test_a_create_answered_500_after_apply_is_replayed()
    print("PASS komira_secrets_e2e retry reuses token")
