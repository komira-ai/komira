# =============================================================================
# test_gcp_store_registry.mojo -- write through the Secret Manager
# SecretWriter, then resolve through SecretRegistry to a CredentialConsumer,
# against the fake over TLS on loopback
# =============================================================================
#
# kci_gcp_secret_writer's `GcpSecretManagerWriter` and
# komira_gcp_secret_store's `GcpSecretManagerStore`, each over the generated
# client built by `gcp_loopback_client` (a verifying TLS connector that
# trusts only the fixture root), drive the fake (gcp_fake.mojo) through its
# TLS front:
#
#   the writer, global secrets at `localhost`: has_version of a secret that
#   does not exist (False), define_container twice (created, then the
#   no-op), has_version of the empty container (False: it has no `latest`),
#   a first value, has_version (True), a second value, and a write to a
#   secret that does not exist (created, then its version added);
#   the writer, a regional secret at `127.0.0.1`: a write to a secret that
#   does not exist (created without a replication policy, at its regional
#   path);
#   the writer, a secret the test seeds into the fake before the run with
#   version 1 ENABLED and version 2 (its `latest`) DISABLED: has_version
#   answers False, because the bare handle resolves `latest`, and the
#   registry below shows that resolve refused while version 1 still reads;
#   the registry: a `SecretRegistry` owning the global store, with bindings
#   to the secret (`latest`), to its version 1, to `versions/latest`, to the
#   created secret, to a secret that does not exist, and to the seeded
#   secret bare and at version 1; a second registry owning a regional store,
#   bound to the regional secret; each bound node revealed into a recording
#   `CredentialConsumer`;
#   then a write carrying a deploy token, refused before anything is sent,
#   and a writer whose token source gives another token, whose has_version
#   raises rather than answering False.
#
# Every version the writer adds carries its CRC32C, and the fake refuses a
# payload whose dataCrc32c is not its own (gcp_fake.mojo); every value the
# store reads back is checked against the dataCrc32c the fake returns.
#
# What each assertion catches:
#   * the bytes each node's reveal handed the consumer: a handle mapped to
#     the wrong resource name, a version number dropped (node 2 would see the
#     latest value), a payload not decoded, a regional secret sent to the
#     global path;
#   * has_version's answers: a probe that reads a missing secret or an empty
#     container as holding a version, a held one as empty, or a disabled
#     `latest` as readable (the answer must match what the resolve of the
#     bare handle does);
#   * the fake's request log, exactly (verb, path, query, host, status): the
#     probe's GetSecretVersion of `latest` (never `:access`, never a list),
#     a create-if-absent that creates before trying the add, a define that
#     is not idempotent, a regional create sent with a replication policy
#     (refused 400), a refused write that still sent;
#   * the raised texts, exactly (the byte counts are of what the fake
#     sent): a provider error swallowed (the wrongly tokened probe answering
#     False, the missing node resolving to an empty value), or a refusal
#     without the handle;
#   * custody: no raised text holds any written value, while the fake's error
#     bodies for the two adds to missing secrets carried them (the positive
#     control).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import StaticTokenSource
from kci_gcp_secret_writer import GcpSecretManagerWriter
from komira_gcp_secret_store import GcpSecretManagerStore
from komira_http_core.tls import tls_init
from komira_secret_registry import CredentialConsumer, SecretRegistry
from komira_secret_store import SecretValue

from komira_secrets_e2e import (
    GLOBAL_HOST,
    FakeSecretManager,
    GcpFakeServer,
    GcpSecret,
    GcpVersion,
    OTHER_ACCESS_TOKEN,
    REGIONAL_HOST,
    TEST_ACCESS_TOKEN,
    ClientLeg,
    gcp_fake_server,
    gcp_loopback_client,
    leaks,
    serve_while,
)
from komira_secrets_e2e.gcp_server import GcpConnector

comptime _Store = GcpSecretManagerStore[GcpConnector, StaticTokenSource]

comptime _S = "projects/demo-project/secrets/smtp"
comptime _F = "projects/demo-project/secrets/fresh"
comptime _R = "projects/demo-project/locations/us-central1/secrets/smtp"
comptime _D = "projects/demo-project/secrets/dim"
comptime _V1 = "gcp-adapter-canary-one-77d0"
comptime _V2 = "gcp-adapter-canary-two-b812"
comptime _V3 = "gcp-adapter-canary-fresh-0c4e"
comptime _V4 = "gcp-adapter-canary-regional-5a93"
comptime _V5 = "gcp-adapter-canary-dim-one-2b6f"
comptime _V6 = "gcp-adapter-canary-dim-two-c3e1"


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


def _tokens() raises -> StaticTokenSource:
    return StaticTokenSource(String(TEST_ACCESS_TOKEN))


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
        var w = GcpSecretManagerWriter(
            gcp_loopback_client(self.port, String(GLOBAL_HOST), _tokens())
        )
        self.probes.append(w.has_version(String(_S), String("")))
        w.define_container(String(_S), String(""))
        w.define_container(String(_S), String(""))
        self.probes.append(w.has_version(String(_S), String("")))
        w.write(String(_S), _v(_V1), String(""))
        self.probes.append(w.has_version(String(_S), String("")))
        w.write(String(_S), _v(_V2), String(""))
        w.write(String(_F), _v(_V3), String(""))

        var wr = GcpSecretManagerWriter(
            gcp_loopback_client(self.port, String(REGIONAL_HOST), _tokens())
        )
        wr.write(String(_R), _v(_V4), String(""))

        # The seeded secret: `latest` (version 2) DISABLED, version 1 ENABLED.
        self.probes.append(w.has_version(String(_D), String("")))

        var rec = _Recorder()
        var reg = SecretRegistry[_Store](
            _Store(gcp_loopback_client(self.port, String(GLOBAL_HOST), _tokens()))
        )
        reg.register(1, String("smtp"), String(_S))
        reg.register(2, String("smtp-first"), String(_S) + "/versions/1")
        reg.register(3, String("smtp-latest"), String(_S) + "/versions/latest")
        reg.register(4, String("fresh"), String(_F))
        reg.register(5, String("missing"), String("projects/demo-project/secrets/missing"))
        reg.register(6, String("dim"), String(_D))
        reg.register(8, String("dim-first"), String(_D) + "/versions/1")
        for node in range(1, 5):
            reg.reveal_for(node, rec)
        try:
            reg.reveal_for(5, rec)
        except e:
            self.errors.append(String(e))
        try:
            reg.reveal_for(6, rec)
        except e:
            self.errors.append(String(e))
        reg.reveal_for(8, rec)
        var regional = SecretRegistry[_Store](
            _Store(gcp_loopback_client(self.port, String(REGIONAL_HOST), _tokens()))
        )
        regional.register(7, String("smtp-regional"), String(_R))
        regional.reveal_for(7, rec)
        self.seen = rec.seen.copy()

        # A deploy token: refused before anything is sent.
        try:
            w.write(String(_S), _v(_V1), String("a-deploy-bearer-token"))
        except e:
            self.errors.append(String(e))
        # A writer whose token the fake does not accept: the probe raises.
        var other = GcpSecretManagerWriter(
            gcp_loopback_client(
                self.port, String(GLOBAL_HOST), StaticTokenSource(String(OTHER_ACCESS_TOKEN))
            )
        )
        try:
            _ = other.has_version(String(_S), String(""))
        except e:
            self.errors.append(String(e))


def _bytes(s: StaticString) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _seed_dim(mut server: GcpFakeServer):
    """A global secret `dim` whose version 1 is ENABLED and whose version 2,
    its `latest`, is DISABLED (the fake serves no state change, so the
    test sets it on the store before the run)."""
    ref store = server.fake.store
    var s = GcpSecret(String("dim"), String(""), store.now())
    s.versions.append(GcpVersion(1, _bytes(_V5), True, store.now()))
    var v2 = GcpVersion(2, _bytes(_V6), True, store.now())
    v2.state = String("DISABLED")
    s.versions.append(v2^)
    store.secrets.append(s^)


def _status(fake: FakeSecretManager, head: String, k: Int) -> String:
    """`head` as the client raises it for the fake's k-th error answer."""
    return (
        head
        + ", error.message "
        + String(fake.error_message_bytes[k])
        + " bytes, body "
        + String(fake.error_bodies[k].byte_length())
        + " bytes"
    )


def test_gcp_write_then_resolve_through_registry() raises:
    var server = gcp_fake_server()
    _seed_dim(server)
    var leg = _Flow(server.port())
    serve_while(server, leg)
    ref fake = server.fake

    assert_equal(len(leg.probes), 4)
    assert_false(leg.probes[0], "a secret that does not exist holds no version")
    assert_false(leg.probes[1], "an empty container holds no version")
    assert_true(leg.probes[2], "a written secret holds a version")
    assert_false(leg.probes[3], "a disabled latest is not a version the bare handle reads")

    var want_seen: List[String] = [_V2, _V1, _V2, _V3, _V5, _V4]
    assert_equal(len(leg.seen), len(want_seen))
    for i in range(len(want_seen)):
        assert_equal(leg.seen[i], want_seen[i], String("reveal ") + String(i))

    var g = String(" @") + GLOBAL_HOST + " "
    var r = String(" @") + REGIONAL_HOST + " "
    var probe = String("/versions/latest")
    var want_log: List[String] = [
        "GET /v1/" + _S + probe + g + "404 NOT_FOUND",
        "POST /v1/projects/demo-project/secrets?secretId=smtp" + g + "200",
        "POST /v1/projects/demo-project/secrets?secretId=smtp" + g + "409 ALREADY_EXISTS",
        "GET /v1/" + _S + probe + g + "404 NOT_FOUND",
        "POST /v1/" + _S + ":addVersion" + g + "200",
        "GET /v1/" + _S + probe + g + "200",
        "POST /v1/" + _S + ":addVersion" + g + "200",
        "POST /v1/" + _F + ":addVersion" + g + "404 NOT_FOUND",
        "POST /v1/projects/demo-project/secrets?secretId=fresh" + g + "200",
        "POST /v1/" + _F + ":addVersion" + g + "200",
        "POST /v1/" + _R + ":addVersion" + r + "404 NOT_FOUND",
        "POST /v1/projects/demo-project/locations/us-central1/secrets?secretId=smtp" + r + "200",
        "POST /v1/" + _R + ":addVersion" + r + "200",
        "GET /v1/" + _D + probe + g + "200",
        "GET /v1/" + _S + "/versions/latest:access" + g + "200",
        "GET /v1/" + _S + "/versions/1:access" + g + "200",
        "GET /v1/" + _S + "/versions/latest:access" + g + "200",
        "GET /v1/" + _F + "/versions/latest:access" + g + "200",
        "GET /v1/projects/demo-project/secrets/missing/versions/latest:access" + g + "404 NOT_FOUND",
        "GET /v1/" + _D + "/versions/latest:access" + g + "400 FAILED_PRECONDITION",
        "GET /v1/" + _D + "/versions/1:access" + g + "200",
        "GET /v1/" + _R + "/versions/latest:access" + r + "200",
        "GET /v1/" + _S + probe + g + "401 UNAUTHENTICATED",
    ]
    assert_equal(len(fake.log), len(want_log), "requests the fake answered")
    for i in range(len(want_log)):
        assert_equal(fake.log[i], want_log[i])
    var bearer = String("Bearer ") + TEST_ACCESS_TOKEN
    for i in range(len(fake.authorizations) - 1):
        assert_equal(fake.authorizations[i], bearer)

    # The raised texts, exactly. The fake's error answers, in order: the two
    # 404 probes, the 409 define, the two 404 adds, then the 404 access (5),
    # the 400 access of the disabled `latest` (6) and the 401 probe (7); the
    # byte counts are of what it sent.
    assert_equal(len(fake.error_bodies), 8)

    var want_errors: List[String] = [
        "GcpSecretManagerStore: resolve of secret_ref projects/demo-project/secrets/missing failed: "
        + _status(fake, String("GET AccessSecretVersion: HTTP 404, NOT_FOUND (code 5)"), 5),
        "GcpSecretManagerStore: resolve of secret_ref " + _D + " failed: "
        + _status(fake, String("GET AccessSecretVersion: HTTP 400, FAILED_PRECONDITION (code 9)"), 6),
        "GcpSecretManagerWriter: write refused: a deploy token was given, and each"
        + " request's bearer token comes from the client's token source; build the"
        + " client over the deploy principal's token source and pass an empty token",
        "GcpSecretManagerWriter: has_version of secret_ref " + _S + " failed: "
        + _status(fake, String("GET GetSecretVersion: HTTP 401, UNAUTHENTICATED (code 16)"), 7),
    ]
    assert_equal(len(leg.errors), len(want_errors))
    for i in range(len(want_errors)):
        assert_equal(leg.errors[i], want_errors[i])
        assert_false(leg.errors[i].find("a-deploy-bearer-token") >= 0, leg.errors[i])

    # Custody. The positive control: the adds to the two missing secrets
    # were answered with error bodies repeating their payloads.
    var fresh_on_wire = False
    var regional_on_wire = False
    for i in range(len(fake.error_bodies)):
        if leaks(fake.error_bodies[i], String(_V3)):
            fresh_on_wire = True
        if leaks(fake.error_bodies[i], String(_V4)):
            regional_on_wire = True
    assert_true(fresh_on_wire and regional_on_wire, "the fake's error bodies carry the payloads")
    var values: List[String] = [_V1, _V2, _V3, _V4, _V5, _V6]
    for i in range(len(leg.errors)):
        for k in range(len(values)):
            assert_false(leaks(leg.errors[i], values[k]), leg.errors[i])
    print("  test_gcp_write_then_resolve_through_registry PASS")


def main() raises:
    tls_init()
    test_gcp_write_then_resolve_through_registry()
    print("PASS komira_secrets_e2e GCP store and writer through the registry")
