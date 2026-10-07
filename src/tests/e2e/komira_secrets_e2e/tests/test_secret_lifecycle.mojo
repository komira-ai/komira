# =============================================================================
# test_secret_lifecycle.mojo -- a secret's life, generated client against the
# fake, over a real socket
# =============================================================================
#
# The generated SecretsManagerClient, built as an application builds it but
# pointed at http://127.0.0.1:<port>, drives the fake through:
#
#   CreateSecret (no ClientRequestToken set: the client fills one), then
#   GetSecretValue, PutSecretValue, DescribeSecret (two versions, the first
#   now AWSPREVIOUS), GetSecretValue by AWSPREVIOUS, DeleteSecret with a
#   7-day recovery window (the hand-written verb), DescribeSecret (the
#   DeletedDate), CreateSecret on the held name (refused
#   InvalidRequestException, which `secret_name_is_scheduled_for_deletion`
#   recognises), GetSecretValue and PutSecretValue while scheduled (refused),
#   RestoreSecret, and GetSecretValue (the second value, AWSCURRENT again).
#
# Every request is signed by the client and verified by the fake's own SigV4
# check, so each 200 also proves the client signed what it sent, scoped to
# the right service.
#
# What each assertion catches:
#   * the values, version ids and stages read back: a request or response
#     the generated codec spells wrong, or a verb sending the wrong operation;
#   * the fake's request log, exactly: a call retried that should not be (a
#     400 is not retried), a call sent twice, or one not sent;
#   * the filled token is a version 4 UUID and is the id of the version the
#     fake made: a client sending no token, or a different one than it
#     reports;
#   * custody: no error text the client raised holds either secret value,
#     while the fake's error bodies DID carry the value on the wire (the
#     positive control, so the check can see a leak). The leg answers no
#     5xx, so komira_http_server wrote no line carrying a response body
#     (`server_log` is empty). The process's stdout itself is not captured,
#     and the fake's own request log is not a custody check: it has no field
#     a value could be in.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerCreateSecretRequest,
    SecretsManagerDeleteSecretRequest,
    SecretsManagerDescribeSecretRequest,
    SecretsManagerGetSecretValueRequest,
    SecretsManagerPutSecretValueRequest,
    SecretsManagerRestoreSecretRequest,
)
from komira_aws_secretsmanager.secretsmanager_overrides import (
    delete_secret,
    secret_name_is_scheduled_for_deletion,
)
from komira_secrets_e2e import (
    EXAMPLE_SECRET_ACCESS_KEY,
    FAKE_REGION,
    ClientLeg,
    FakeSecretsManager,
    FakeServer,
    fake_credentials,
    leaks,
    loopback_client,
    serve_while,
)

comptime _NAME = "app/e2e-db"
# Distinctive values, so a leak anywhere is found by a plain search.
comptime _V1 = "kz9-custody-canary-one-7f3a91"
comptime _V2 = "kz9-custody-canary-two-c41e07"


def assert_uuid4(tok: String) raises:
    """A version 4 UUID, lowercase and hyphenated, as botocore makes one."""
    assert_equal(tok.byte_length(), 36, tok)
    var hex = String("0123456789abcdef")
    for i in range(36):
        var ch = String(tok[byte = i : i + 1])
        if i == 8 or i == 13 or i == 18 or i == 23:
            assert_equal(ch, "-", tok)
        else:
            assert_true(hex.find(ch) >= 0, tok)
    assert_equal(String(tok[byte=14:15]), "4", tok)


def _stages(s: List[String]) -> String:
    var out = String("")
    for i in range(len(s)):
        if i > 0:
            out += ","
        out += s[i]
    return out^


struct _Lifecycle(ClientLeg):
    var port: UInt16
    # Every error text the client raised, in order.
    var errors: List[String]
    var first_version: String
    var second_version: String
    var created_arn: String

    def __init__(out self, port: UInt16):
        self.port = port
        self.errors = List[String]()
        self.first_version = String("")
        self.second_version = String("")
        self.created_arn = String("")

    def run(mut self) raises:
        var client = loopback_client(self.port, String(EXAMPLE_SECRET_ACCESS_KEY))

        # CreateSecret, no token set: the client fills one.
        var create = SecretsManagerCreateSecretRequest(String(_NAME))
        create.secret_string = Optional[String](String(_V1))
        var created = client.create_secret(create)
        assert_equal(created.name.value(), _NAME)
        self.created_arn = created.arn.value()
        assert_true(
            self.created_arn.startswith(
                String("arn:aws:secretsmanager:") + FAKE_REGION + ":000000000000:secret:" + _NAME + "-"
            ),
            self.created_arn,
        )
        self.first_version = created.version_id.value()
        assert_uuid4(self.first_version)

        var got = client.get_secret_value(SecretsManagerGetSecretValueRequest(String(_NAME)))
        assert_equal(got.secret_string.value(), _V1)
        assert_equal(got.version_id.value(), self.first_version)
        assert_equal(_stages(got.version_stages.value()), "AWSCURRENT")
        assert_equal(got.arn.value(), self.created_arn)

        var put = SecretsManagerPutSecretValueRequest(String(_NAME))
        put.secret_string = Optional[String](String(_V2))
        var p = client.put_secret_value(put)
        self.second_version = p.version_id.value()
        assert_uuid4(self.second_version)
        assert_true(self.second_version != self.first_version)
        assert_equal(_stages(p.version_stages.value()), "AWSCURRENT")

        var d = client.describe_secret(SecretsManagerDescribeSecretRequest(String(_NAME)))
        var map = d.version_ids_to_stages.value().copy()
        assert_equal(len(map), 2)
        assert_equal(_stages(map[self.first_version]), "AWSPREVIOUS")
        assert_equal(_stages(map[self.second_version]), "AWSCURRENT")
        assert_false(Bool(d.deleted_date))

        var prev = SecretsManagerGetSecretValueRequest(String(_NAME))
        prev.version_stage = Optional[String](String("AWSPREVIOUS"))
        var old = client.get_secret_value(prev)
        assert_equal(old.secret_string.value(), _V1)
        assert_equal(old.version_id.value(), self.first_version)

        # DeleteSecret with a recovery window: the name stays held.
        var del_req = SecretsManagerDeleteSecretRequest(String(_NAME))
        del_req.recovery_window_in_days = Optional[Int64](Int64(7))
        var deleted = delete_secret(client, del_req)
        assert_equal(deleted.name.value(), _NAME)
        var held = client.describe_secret(SecretsManagerDescribeSecretRequest(String(_NAME)))
        assert_true(Bool(held.deleted_date))
        assert_equal(held.deleted_date.value(), deleted.deletion_date.value())
        assert_true(held.deleted_date.value() - held.created_date.value() >= 7.0 * 86400.0)

        # CreateSecret on the held name: refused, and recognised.
        var again = SecretsManagerCreateSecretRequest(String(_NAME))
        again.secret_string = Optional[String](String(_V1))
        var text = String("")
        try:
            _ = client.create_secret(again)
        except e:
            text = String(e)
        self.errors.append(text.copy())
        assert_true(
            text.find("SecretsManager.CreateSecret failed: HTTP 400 InvalidRequestException") >= 0,
            text,
        )
        assert_true(secret_name_is_scheduled_for_deletion(text), text)

        # The value can be neither read nor written while scheduled.
        text = String("")
        try:
            _ = client.get_secret_value(SecretsManagerGetSecretValueRequest(String(_NAME)))
        except e:
            text = String(e)
        self.errors.append(text.copy())
        assert_true(text.find("HTTP 400 InvalidRequestException") >= 0, text)
        var late = SecretsManagerPutSecretValueRequest(String(_NAME))
        late.secret_string = Optional[String](String(_V2))
        text = String("")
        try:
            _ = client.put_secret_value(late)
        except e:
            text = String(e)
        self.errors.append(text.copy())
        assert_true(text.find("HTTP 400 InvalidRequestException") >= 0, text)

        var restored = client.restore_secret(SecretsManagerRestoreSecretRequest(String(_NAME)))
        assert_equal(restored.arn.value(), self.created_arn)

        var back = client.get_secret_value(SecretsManagerGetSecretValueRequest(String(_NAME)))
        assert_equal(back.secret_string.value(), _V2)
        assert_equal(back.version_id.value(), self.second_version)
        assert_equal(_stages(back.version_stages.value()), "AWSCURRENT")
        var after = client.describe_secret(SecretsManagerDescribeSecretRequest(String(_NAME)))
        assert_false(Bool(after.deleted_date))


def test_secret_lifecycle_over_loopback() raises:
    var server = FakeServer(FakeSecretsManager(fake_credentials(), String(FAKE_REGION)))
    var leg = _Lifecycle(server.port())
    serve_while(server, leg)
    ref fake = server.fake

    var want: List[String] = [
        "CreateSecret 200",
        "GetSecretValue 200",
        "PutSecretValue 200",
        "DescribeSecret 200",
        "GetSecretValue 200",
        "DeleteSecret 200",
        "DescribeSecret 200",
        "CreateSecret 400 InvalidRequestException",
        "GetSecretValue 400 InvalidRequestException",
        "PutSecretValue 400 InvalidRequestException",
        "RestoreSecret 200",
        "GetSecretValue 200",
        "DescribeSecret 200",
    ]
    assert_equal(len(fake.log), len(want), "requests the fake answered")
    for i in range(len(want)):
        assert_equal(fake.log[i], String("secretsmanager ") + want[i])

    # The token the client filled is the version the fake made.
    var creates = fake.operations(String("CreateSecret"))
    assert_equal(creates[0].token, leg.first_version)
    var puts = fake.operations(String("PutSecretValue"))
    assert_equal(puts[0].token, leg.second_version)
    # Create, put, delete, restore; nothing replayed.
    assert_equal(fake.applied_writes, 4)
    assert_equal(fake.replayed_writes, 0)

    # Custody. The positive control first: the values were on the wire, in
    # the fake's error bodies.
    var on_wire = False
    for i in range(len(fake.error_bodies)):
        if leaks(fake.error_bodies[i], String(_V1)) or leaks(fake.error_bodies[i], String(_V2)):
            on_wire = True
    assert_true(on_wire, "the fake's error bodies carry the request's value")
    assert_equal(len(leg.errors), 3)
    for i in range(len(leg.errors)):
        assert_false(leaks(leg.errors[i], String(_V1)), leg.errors[i])
        assert_false(leaks(leg.errors[i], String(_V2)), leg.errors[i])
    assert_equal(len(fake.server_log), 0, "no 5xx, so no body-bearing server log line")
    print("  test_secret_lifecycle_over_loopback PASS")


def main() raises:
    test_secret_lifecycle_over_loopback()
    print("PASS komira_secrets_e2e secret lifecycle")
