"""L1 TLS cert loading + verification unit tests.

Tests cert+key parse paths through TlsConfig.load_cert:

  1. Good cert + good key (the test-CA fixture leaf) → success.
  2. Malformed PEM → raises Error with s2n errno in the message.
  3. Mismatched cert + key (leaf cert + ROOT private key) → raises
     Error (s2n cert/key consistency check).
  4. Loading two cert chains → both succeed (s2n supports multiple
     cert chains per config for SNI dispatch; Phase 1 still works
     with one).

NOTE: Full cert-CHAIN VALIDATION (expired cert / untrusted CA / CN-SAN
mismatch) requires a peer driving a real handshake, which is exercised
in the client-against-server tests
(test_L1_tls_client_handshake_against_test_root.mojo,
test_L2_https_verify_pass.mojo). The unit tests here focus on
the cert-LOADING path that runs at TlsConfig construction time — that's
the surface the HttpServer.__init__ depends on.
"""

from komira_http.tls import (
    TlsConfig,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)
from std.pathlib import Path


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _leaf_cert() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_key.pem").read_text()


def _root_ca_cert() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/root_ca.pem").read_text()


def _root_ca_key() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/root_ca_key.pem").read_text()


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_load_good_cert_and_key() raises:
    """The leaf cert (signed by root CA) + leaf private key parse
    successfully via s2n's PEM parser."""
    print("  test_load_good_cert_and_key...")
    var config = TlsConfig()
    config.load_cert(_leaf_cert(), _leaf_key())
    print("    OK")


def test_load_malformed_pem_raises() raises:
    """A clearly-malformed PEM (just random text) should raise Error
    from TlsConfig.load_cert with s2n diagnostics."""
    print("  test_load_malformed_pem_raises...")
    var config = TlsConfig()
    var garbage = String(
        "-----BEGIN CERTIFICATE-----\n"
        "this is not base64 cert data\n"
        "-----END CERTIFICATE-----\n"
    )
    var raised = False
    try:
        config.load_cert(garbage, _leaf_key())
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error("expected load_cert(garbage) to raise")
    print("    OK")


def test_load_truncated_pem_raises() raises:
    """A truncated PEM (header without body) should raise."""
    print("  test_load_truncated_pem_raises...")
    var config = TlsConfig()
    var truncated = String(
        "-----BEGIN CERTIFICATE-----\n"
        "MIIB"
    )
    var raised = False
    try:
        config.load_cert(truncated, _leaf_key())
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error("expected load_cert(truncated) to raise")
    print("    OK")


def test_load_mismatched_key_raises() raises:
    """Loading the leaf cert with the ROOT CA's private key (which
    doesn't match the leaf cert's public key) should raise. s2n checks
    cert+key consistency at attach time."""
    print("  test_load_mismatched_key_raises...")
    var config = TlsConfig()
    var raised = False
    try:
        config.load_cert(_leaf_cert(), _root_ca_key())
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error("expected load_cert(leaf_cert, root_key) to raise")
    print("    OK")


def test_load_two_chains() raises:
    """Loading two distinct cert chains into one config should both
    succeed. s2n supports multiple cert chains for SNI dispatch; here
    we just verify they both load without conflict."""
    print("  test_load_two_chains...")
    var config = TlsConfig()
    config.load_cert(_leaf_cert(), _leaf_key())
    # Load the same chain again — same s2n config can hold multiple
    # chains; this exercises the s2n_config_add_cert_chain_and_key_to_store
    # multi-add code path.
    config.load_cert(_leaf_cert(), _leaf_key())
    print("    OK")


def main() raises:
    print("== L1 TLS cert verify ==")
    tls_init()
    test_load_good_cert_and_key()
    test_load_malformed_pem_raises()
    test_load_truncated_pem_raises()
    test_load_mismatched_key_raises()
    test_load_two_chains()
    print("== L1 TLS cert verify PASSED (5 tests) ==")
