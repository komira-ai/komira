"""The Firestore endpoint / insecure seam (the emulator arm).

Unit-tests the Firestore-emulator seam of
`komira_gcp_firestore.firestore_endpoint` and `FirestoreClient.set_endpoint`.
Hermetic — NO live emulator, NO network: the seam is proven by asserting the
resolution, the request the client writes (over a ScriptedFirestore), and the
connector SELECTION directly.

The three axes the seam must get right:

  1. ENDPOINT RESOLUTION (`parse_firestore_endpoint`):
       * no override -> the EXACT cloud default (firestore.googleapis.com:443,
         https, insecure=False) — the default-unchanged proof.
       * `host:port` + insecure -> host/port overridden, plaintext http.
       * host-only + insecure   -> the 8080 emulator-default port.

  2. WHERE THE CLIENT SENDS (`FirestoreClient.set_endpoint`):
       * no override -> firestore.googleapis.com, https, no `:port` in Host.
       * an insecure override -> http:// to host:port (the emulator), over a
         plaintext connector; the same override over a TLS-claiming connector
         is refused by the HttpClient (the scheme MUST match the connector).

  3. CONNECTOR SELECTION (`build_firestore_tls_connector` + the plaintext
     KernelTcpConnector):
       * insecure=False -> a public-CA TLS connector, verify_mode=VERIFY_PEER.
       * insecure=True  -> a verify-DISABLED TLS connector (VERIFY_SKIP), for a
         TLS-terminator-fronted endpoint.
       * the raw plaintext-emulator branch dials a bare KernelTcpConnector
         (is_tls()==False) — asserted here as the non-TLS counterpart.

These exercise the pure resolution + the connector construction surface WITHOUT
any TLS handshake or network IO (TlsConfig lazily allocates its s2n_config_t;
construction alone never dials).
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_http_client.pool import VERIFY_PEER, VERIFY_SKIP
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_http_core.transport.scripted import ScriptedConnector

from komira_gcp_core import StaticTokenSource
from komira_gcp_firestore.firestore_client import (
    FIRESTORE_EMULATOR_BEARER,
    FirestoreClient,
)
from komira_gcp_firestore.firestore_endpoint import (
    FIRESTORE_HOST,
    FIRESTORE_PORT,
    FIRESTORE_EMULATOR_DEFAULT_PORT,
    FirestoreEndpoint,
    parse_firestore_endpoint,
    build_firestore_tls_connector,
)
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore


# =============================================================================
# 1 — endpoint resolution
# =============================================================================


def test_endpoint_unset_is_exact_cloud_default() raises:
    """`parse_firestore_endpoint("", False)` == the production cloud endpoint,
    byte-identical to the pre-seam path (no override)."""
    print("  test_endpoint_unset_is_exact_cloud_default...")
    var e = parse_firestore_endpoint(String(""), False)
    assert_equal(
        e.host, String(FIRESTORE_HOST), "unset -> firestore.googleapis.com"
    )
    assert_equal(Int(e.port), Int(FIRESTORE_PORT), "unset -> prod port 443")
    assert_false(e.insecure, "unset -> secure (https TLS)")
    assert_true(e.is_https(), "unset -> https")
    assert_equal(e.scheme(), String("https"), "unset -> https scheme")
    # And it matches the canonical prod() value.
    var p = FirestoreEndpoint.prod()
    assert_equal(e.host, p.host, "unset == prod() host")
    assert_equal(Int(e.port), Int(p.port), "unset == prod() port")
    assert_equal(e.insecure, p.insecure, "unset == prod() insecure")
    print("    OK")


def test_endpoint_host_port_insecure_override() raises:
    """`parse_firestore_endpoint("firestore-emulator:8080", True)` overrides
    host + port and selects the plaintext emulator path."""
    print("  test_endpoint_host_port_insecure_override...")
    var e = parse_firestore_endpoint(String("firestore-emulator:8080"), True)
    assert_equal(e.host, String("firestore-emulator"), "host overridden")
    assert_equal(Int(e.port), 8080, "port overridden")
    assert_true(e.insecure, "insecure -> plaintext emulator")
    assert_false(e.is_https(), "insecure -> not https")
    assert_equal(e.scheme(), String("http"), "insecure -> http scheme")
    print("    OK")


def test_endpoint_host_only_insecure_uses_emulator_default_port() raises:
    """A host-only insecure endpoint falls back to the 8080 emulator default."""
    print("  test_endpoint_host_only_insecure_uses_emulator_default_port...")
    var e = parse_firestore_endpoint(String("localhost"), True)
    assert_equal(e.host, String("localhost"), "host-only parsed")
    assert_equal(
        Int(e.port),
        Int(FIRESTORE_EMULATOR_DEFAULT_PORT),
        "missing port -> emulator default 8080",
    )
    assert_true(e.insecure, "insecure honored")
    print("    OK")


def test_endpoint_explicit_cloud_hostport_secure() raises:
    """An explicit `host:port` with insecure=False stays the https cloud
    shape (a TLS-terminated custom endpoint, not the emulator)."""
    print("  test_endpoint_explicit_cloud_hostport_secure...")
    var e = parse_firestore_endpoint(
        String("firestore.googleapis.com:443"), False
    )
    assert_equal(e.host, String("firestore.googleapis.com"), "host parsed")
    assert_equal(Int(e.port), 443, "port parsed")
    assert_false(e.insecure, "secure honored")
    assert_true(e.is_https(), "secure -> https")
    print("    OK")


def test_endpoint_empty_insecure_honors_flag() raises:
    """Empty endpoint + insecure=True is degenerate (no host override) but the
    insecure flag is honored: prod host, emulator-default port, plaintext."""
    print("  test_endpoint_empty_insecure_honors_flag...")
    var e = parse_firestore_endpoint(String(""), True)
    assert_equal(e.host, String(FIRESTORE_HOST), "empty -> prod host")
    assert_equal(
        Int(e.port),
        Int(FIRESTORE_EMULATOR_DEFAULT_PORT),
        "empty+insecure -> emulator default port",
    )
    assert_true(e.insecure, "insecure honored even with empty endpoint")
    print("    OK")


# =============================================================================
# 2 — where the client sends (FirestoreClient.set_endpoint)
# =============================================================================

comptime _DOC = '[{"found":{"name":"projects/p/databases/(default)/documents/c/id"}}]'


def test_client_default_is_the_cloud_endpoint() raises:
    """No override: https to firestore.googleapis.com, Host without a port."""
    print("  test_client_default_is_the_cloud_endpoint...")
    var script = ScriptedFirestore()
    script.queue_response(200, String(_DOC))
    var client = FirestoreClient[ScriptedConnector](
        script.take_connector(), String("p"), String("(default)"), String("t")
    )
    _ = client.get_document(String("c"), String("id"))
    assert_equal(script.call_host(0), String("firestore.googleapis.com"))
    # An explicit cloud endpoint on 443 is the same request.
    var script2 = ScriptedFirestore()
    script2.queue_response(200, String(_DOC))
    var client2 = FirestoreClient[ScriptedConnector](
        script2.take_connector(), String("p"), String("(default)"), String("t")
    )
    client2.set_endpoint(parse_firestore_endpoint(String(""), False))
    _ = client2.get_document(String("c"), String("id"))
    assert_equal(script2.call_text(0), script.call_text(0))
    print("    OK")


def test_client_emulator_is_plaintext_host_port() raises:
    """An insecure override: http to host:port, over a plaintext connector."""
    print("  test_client_emulator_is_plaintext_host_port...")
    var script = ScriptedFirestore.plaintext()
    script.queue_response(200, String(_DOC))
    var client = FirestoreClient[ScriptedConnector](
        script.take_connector(), String("p"), String("(default)"), String("")
    )
    # An IP literal: a plaintext dial resolves its host before connecting, and
    # the test has no resolver.
    client.set_endpoint(parse_firestore_endpoint(String("127.0.0.1:8080"), True))
    _ = client.get_document(String("c"), String("id"))
    assert_equal(script.call_host(0), String("127.0.0.1:8080"))
    assert_equal(
        script.call_path(0), String("/v1/projects/p/databases/%28default%29/documents:batchGet")
    )
    print("    OK")


def test_client_emulator_gets_the_owner_bearer() raises:
    """The emulator bearer Google's libraries send, "owner", goes out as
    `Authorization: Bearer owner`."""
    print("  test_client_emulator_gets_the_owner_bearer...")
    var script = ScriptedFirestore.plaintext()
    script.queue_response(200, String(_DOC))
    var client = FirestoreClient[ScriptedConnector](
        script.take_connector(),
        String("p"),
        String("(default)"),
        String(FIRESTORE_EMULATOR_BEARER),
    )
    client.set_endpoint(parse_firestore_endpoint(String("127.0.0.1:8080"), True))
    _ = client.get_document(String("c"), String("id"))
    assert_equal(script.call_bearer(0), String("owner"))
    print("    OK")


def test_a_real_credential_is_never_sent_in_cleartext() raises:
    """A plaintext endpoint is refused for any token source but
    `FixedBearer`, so a real token cannot go out over http; a TLS endpoint
    is still accepted."""
    print("  test_a_real_credential_is_never_sent_in_cleartext...")
    var script = ScriptedFirestore.plaintext()
    var client = FirestoreClient[ScriptedConnector, StaticTokenSource](
        script.take_connector(),
        String("p"),
        String("(default)"),
        StaticTokenSource(String("ya29.real-looking-token")),
    )
    var raised = False
    try:
        client.set_endpoint(
            parse_firestore_endpoint(String("firestore-emulator:8080"), True)
        )
    except e:
        raised = True
        assert_true(String("cleartext") in String(e), String(e))
    assert_true(raised, "a plaintext endpoint must refuse a real credential")
    assert_equal(script.call_count(), 0)
    client.set_endpoint(parse_firestore_endpoint(String(""), False))
    print("    OK")


def test_client_emulator_over_a_tls_connector_is_refused() raises:
    """The scheme must match the connector: an http endpoint over a
    TLS-claiming connector never reaches the wire."""
    print("  test_client_emulator_over_a_tls_connector_is_refused...")
    var script = ScriptedFirestore()
    script.queue_response(200, String(_DOC))
    var client = FirestoreClient[ScriptedConnector](
        script.take_connector(), String("p"), String("(default)"), String("")
    )
    client.set_endpoint(parse_firestore_endpoint(String("localhost:8080"), True))
    var raised = False
    try:
        _ = client.get_document(String("c"), String("id"))
    except:
        raised = True
    assert_true(raised, "an http URL over a TLS connector must be refused")
    assert_equal(script.call_count(), 0)
    print("    OK")


# =============================================================================
# 3 — connector selection
# =============================================================================


def test_connector_cloud_is_verifying_tls() raises:
    """`build_firestore_tls_connector(host, insecure=False)` is a public-CA TLS
    connector with verify_mode=VERIFY_PEER."""
    print("  test_connector_cloud_is_verifying_tls...")
    var conn = build_firestore_tls_connector(
        String("firestore.googleapis.com"), False
    )
    assert_true(conn.is_tls(), "cloud connector is TLS")
    assert_equal(
        Int(conn.verify_mode()),
        Int(VERIFY_PEER),
        "cloud -> VERIFY_PEER (public-CA verification ON)",
    )
    _ = conn^
    print("    OK")


def test_connector_insecure_is_verify_disabled_tls() raises:
    """`build_firestore_tls_connector(host, insecure=True)` is a TLS connector
    with peer verification DISABLED (VERIFY_SKIP) — the TLS-terminator-fronted
    emulator path."""
    print("  test_connector_insecure_is_verify_disabled_tls...")
    var conn = build_firestore_tls_connector(String("localhost"), True)
    assert_true(conn.is_tls(), "insecure connector is still TLS-typed")
    assert_equal(
        Int(conn.verify_mode()),
        Int(VERIFY_SKIP),
        "insecure -> VERIFY_SKIP (peer verification DISABLED)",
    )
    _ = conn^
    print("    OK")


def test_plaintext_branch_connector_is_not_tls() raises:
    """The raw plaintext-emulator branch dials a bare KernelTcpConnector —
    NOT TLS (is_tls()==False), so an http:// URL passes HttpClient's scheme
    check. This documents the non-TLS counterpart of the connector selection."""
    print("  test_plaintext_branch_connector_is_not_tls...")
    var conn = KernelTcpConnector.new()
    assert_false(conn.is_tls(), "plaintext emulator branch is NOT TLS")
    _ = conn^
    print("    OK")


def main() raises:
    print("== Firestore endpoint/insecure seam ==")
    test_endpoint_unset_is_exact_cloud_default()
    test_endpoint_host_port_insecure_override()
    test_endpoint_host_only_insecure_uses_emulator_default_port()
    test_endpoint_explicit_cloud_hostport_secure()
    test_endpoint_empty_insecure_honors_flag()
    test_client_default_is_the_cloud_endpoint()
    test_client_emulator_is_plaintext_host_port()
    test_client_emulator_gets_the_owner_bearer()
    test_a_real_credential_is_never_sent_in_cleartext()
    test_client_emulator_over_a_tls_connector_is_refused()
    test_connector_cloud_is_verifying_tls()
    test_connector_insecure_is_verify_disabled_tls()
    test_plaintext_branch_connector_is_not_tls()
    print("== all Firestore endpoint/insecure seam tests passed ==")
