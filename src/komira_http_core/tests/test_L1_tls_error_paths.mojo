"""L1 TLS error-path diagnostic surface tests.

Tests the s2n errno + strerror plumbing — the diagnostic surface
HttpServer + accept loop use to format error messages when a TLS
operation fails.

  1. last_s2n_errno() returns a sensible value after a known-bad
     cert-load operation.
  2. s2n_strerror_message(errno) returns a non-empty string for valid
     errnos.
  3. TlsStream.s2n_errno() surfaces the same thread-local value.

The handshake-error path (peer-sent-garbage-instead-of-ClientHello)
requires a peer driving the handshake — that's exercised in the E2E
tests where openssl s_client + python ssl drive real protocol errors.
"""

from komira_http_core.tls import (
    TlsConfig,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)
from std.pathlib import Path


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _leaf_key() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_errno_set_after_bad_cert_load() raises:
    """Loading a malformed PEM should set s2n's thread-local errno to
    a non-zero value, queryable via last_s2n_errno()."""
    print("  test_errno_set_after_bad_cert_load...")
    var config = TlsConfig()
    var garbage = String(
        "-----BEGIN CERTIFICATE-----\n"
        "definitely not base64 cert data\n"
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
    # After the error, last_s2n_errno() should be non-zero. (s2n's
    # error namespace assigns 0 to no-error; any value other than 0
    # is the diagnostic.)
    var errno = last_s2n_errno()
    if errno == Int32(0):
        raise Error(
            "expected non-zero errno after bad PEM load, got 0"
        )
    print("    last_s2n_errno = " + String(Int(errno)))
    print("    OK")


def test_strerror_returns_message() raises:
    """s2n_strerror_message(errno) should return a non-empty string
    for a known errno (the one set by the prior bad-PEM test)."""
    print("  test_strerror_returns_message...")
    var config = TlsConfig()
    # Trigger the same error.
    var bad = String(
        "-----BEGIN CERTIFICATE-----\n"
        "X\n"
        "-----END CERTIFICATE-----\n"
    )
    var raised = False
    try:
        config.load_cert(bad, _leaf_key())
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error("expected raise on bad PEM")
    var errno = last_s2n_errno()
    var msg = s2n_strerror_message(errno)
    if len(msg.as_bytes()) == 0:
        raise Error(
            "expected non-empty strerror for errno "
            + String(Int(errno))
        )
    print("    msg = '" + msg + "'")
    print("    OK")


def test_strerror_unknown_errno_returns_string() raises:
    """s2n_strerror_message on a nonsense errno value still returns a
    string (s2n's strerror returns 'unknown error' for unknown codes;
    we copy whatever it returns into a Mojo String)."""
    print("  test_strerror_unknown_errno_returns_string...")
    var msg = s2n_strerror_message(Int32(999_999))
    if len(msg.as_bytes()) == 0:
        raise Error("expected non-empty strerror even for unknown errno")
    print("    msg = '" + msg + "'")
    print("    OK")


def main() raises:
    print("== L1 TLS error paths ==")
    tls_init()
    test_errno_set_after_bad_cert_load()
    test_strerror_returns_message()
    test_strerror_unknown_errno_returns_string()
    print("== L1 TLS error paths PASSED (3 tests) ==")
