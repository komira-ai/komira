# =============================================================================
# test_gcp_store_registry.mojo -- write through the Secret Manager
# SecretWriter, then resolve through SecretRegistry to a CredentialConsumer,
# against the fake over TLS on loopback
# =============================================================================
#
# komira_gcp_secret_store's `GcpSecretManagerWriter` and
# `GcpSecretManagerStore`, each over the generated client built by
# `gcp_loopback_client` (a verifying TLS connector that trusts only the
# fixture root), drive the fake (gcp_fake.mojo) through its TLS front:
#
#   the writer, global secrets at `localhost`: has_version of a secret that
#   does not exist (False), define_container twice (created, then the
#   no-op), has_version of the empty container (False), a first value,
#   has_version (True), a second value, and a write to a secret that does
#   not exist (created, then its version added);
#   the writer, a regional secret at `127.0.0.1`: a write to a secret that
#   does not exist (created without a replication policy, at its regional
#   path);
#   the registry: a `SecretRegistry` owning the global store, with bindings
#   to the secret (`latest`), to its version 1, to `versions/latest`, to the
#   created secret and to a secret that does not exist; a second registry
#   owning a regional store, bound to the regional secret; each bound node
#   revealed into a recording `CredentialConsumer`;
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
#     container as holding a version, or a held one as empty;
#   * the fake's request log, exactly (verb, path, query, host, status): the
#     probe's filter and page size, a create-if-absent that creates before
#     trying the add, a define that is not idempotent, a regional create sent
#     with a replication policy (refused 400), a refused write that still
#     sent, a probe that reads a value (AccessSecretVersion) instead of
#     listing;
#   * the raised texts: a provider error swallowed (the wrongly tokened probe
#     answering False, the missing node resolving to an empty value), or a
#     refusal without the handle;
#   * custody: no raised text holds any written value, while the fake's error
#     bodies for the two adds to missing secrets carried them (the positive
#     control).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import StaticTokenSource
from komira_gcp_secret_store import GcpSecretManagerStore, GcpSecretManagerWriter
from komira_http_core.tls import tls_init
from komira_secret_registry import CredentialConsumer, SecretRegistry
from komira_secret_store import SecretValue

from komira_secrets_e2e import (
    GLOBAL_HOST,
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
comptime _V1 = "gcp-adapter-canary-one-77d0"
comptime _V2 = "gcp-adapter-canary-two-b812"
comptime _V3 = "gcp-adapter-canary-fresh-0c4e"
comptime _V4 = "gcp-adapter-canary-regional-5a93"


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

        var rec = _Recorder()
        var reg = SecretRegistry[_Store](
            _Store(gcp_loopback_client(self.port, String(GLOBAL_HOST), _tokens()))
        )
        reg.register(1, String("smtp"), String(_S))
        reg.register(2, String("smtp-first"), String(_S) + "/versions/1")
        reg.register(3, String("smtp-latest"), String(_S) + "/versions/latest")
        reg.register(4, String("fresh"), String(_F))
        reg.register(5, String("missing"), String("projects/demo-project/secrets/missing"))
        for node in range(1, 5):
            reg.reveal_for(node, rec)
        try:
            reg.reveal_for(5, rec)
        except e:
            self.errors.append(String(e))
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


def test_gcp_write_then_resolve_through_registry() raises:
    var server = gcp_fake_server()
    var leg = _Flow(server.port())
    serve_while(server, leg)
    ref fake = server.fake

    assert_equal(len(leg.probes), 3)
    assert_false(leg.probes[0], "a secret that does not exist holds no version")
    assert_false(leg.probes[1], "an empty container holds no version")
    assert_true(leg.probes[2], "a written secret holds a version")

    var want_seen: List[String] = [_V2, _V1, _V2, _V3, _V4]
    assert_equal(len(leg.seen), len(want_seen))
    for i in range(len(want_seen)):
        assert_equal(leg.seen[i], want_seen[i], String("reveal ") + String(i))

    var g = String(" @") + GLOBAL_HOST + " "
    var r = String(" @") + REGIONAL_HOST + " "
    var probe = String("/versions?pageSize=1&filter=state%3AENABLED")
    var want_log: List[String] = [
        "GET /v1/" + _S + probe + g + "404 NOT_FOUND",
        "POST /v1/projects/demo-project/secrets?secretId=smtp" + g + "200",
        "POST /v1/projects/demo-project/secrets?secretId=smtp" + g + "409 ALREADY_EXISTS",
        "GET /v1/" + _S + probe + g + "200",
        "POST /v1/" + _S + ":addVersion" + g + "200",
        "GET /v1/" + _S + probe + g + "200",
        "POST /v1/" + _S + ":addVersion" + g + "200",
        "POST /v1/" + _F + ":addVersion" + g + "404 NOT_FOUND",
        "POST /v1/projects/demo-project/secrets?secretId=fresh" + g + "200",
        "POST /v1/" + _F + ":addVersion" + g + "200",
        "POST /v1/" + _R + ":addVersion" + r + "404 NOT_FOUND",
        "POST /v1/projects/demo-project/locations/us-central1/secrets?secretId=smtp" + r + "200",
        "POST /v1/" + _R + ":addVersion" + r + "200",
        "GET /v1/" + _S + "/versions/latest:access" + g + "200",
        "GET /v1/" + _S + "/versions/1:access" + g + "200",
        "GET /v1/" + _S + "/versions/latest:access" + g + "200",
        "GET /v1/" + _F + "/versions/latest:access" + g + "200",
        "GET /v1/projects/demo-project/secrets/missing/versions/latest:access" + g + "404 NOT_FOUND",
        "GET /v1/" + _R + "/versions/latest:access" + r + "200",
        "GET /v1/" + _S + probe + g + "401 UNAUTHENTICATED",
    ]
    assert_equal(len(fake.log), len(want_log), "requests the fake answered")
    for i in range(len(want_log)):
        assert_equal(fake.log[i], want_log[i])
    var bearer = String("Bearer ") + TEST_ACCESS_TOKEN
    for i in range(len(fake.authorizations) - 1):
        assert_equal(fake.authorizations[i], bearer)

    var heads: List[String] = [
        "GcpSecretManagerStore: resolve of secret_ref projects/demo-project/secrets/missing"
        + " failed: GET AccessSecretVersion: HTTP 404, NOT_FOUND (code 5)",
        "GcpSecretManagerWriter: write refused: a deploy token was given",
        "GcpSecretManagerWriter: has_version of secret_ref " + _S
        + " failed: GET ListSecretVersions: HTTP 401, UNAUTHENTICATED (code 16)",
    ]
    assert_equal(len(leg.errors), len(heads))
    for i in range(len(heads)):
        assert_true(leg.errors[i].startswith(heads[i]), leg.errors[i])
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
    var values: List[String] = [_V1, _V2, _V3, _V4]
    for i in range(len(leg.errors)):
        for k in range(len(values)):
            assert_false(leaks(leg.errors[i], values[k]), leg.errors[i])
    print("  test_gcp_write_then_resolve_through_registry PASS")


def main() raises:
    tls_init()
    test_gcp_write_then_resolve_through_registry()
    print("PASS komira_secrets_e2e GCP store and writer through the registry")
