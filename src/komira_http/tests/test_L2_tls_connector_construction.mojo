"""TlsConnector construction smoke.

Validates the public construction surface of TlsConnector + TlsClientStream
WITHOUT any TLS handshake or network IO. The 4 sub-tests:

  1. TlsConnector.over(config, KernelTcpConnector.new()) constructs.
  2. is_tls() returns True (validates the Connector trait method).
  3. transport_kind() returns the underlying connector's kind
     (TRANSPORT_KIND_KERNEL_TCP for KernelTcpConnector underneath).
  4. set_server_name_for_next_connect(host) accepts a String.

These exercise the trait conformance + plumbing without the s2n handshake;
the handshake-driven tests live in test_https_verify_*.mojo.
"""

from std.testing import assert_equal, assert_true

from komira_http.client import (
    TlsConnector,
)
from komira_http.tls import TlsConfig
from komira_http.transport.io_stream import TRANSPORT_KIND_KERNEL_TCP
from komira_http.transport.kernel_tcp import KernelTcpConnector


def test_tls_connector_constructs_over_kernel_tcp() raises:
    """TlsConnector.over(config, KernelTcpConnector.new()) constructs
    cleanly. No FFI calls; the TlsConfig allocates an s2n_config_t
    internally (lazy tls_init); on drop both unwind."""
    print("  test_tls_connector_constructs_over_kernel_tcp...")
    var config = TlsConfig()
    var underlying = KernelTcpConnector.new()
    var connector = TlsConnector[KernelTcpConnector].over(
        config^, underlying^,
    )
    # If construction reached here, the public ctor works.
    _ = connector^
    print("    OK")


def test_is_tls_returns_true() raises:
    """The Connector trait's `is_tls()` method returns True for
    TlsConnector. This is the bool query HttpClient.send uses to
    validate scheme/connector compatibility."""
    print("  test_is_tls_returns_true...")
    var config = TlsConfig()
    var underlying = KernelTcpConnector.new()
    var connector = TlsConnector[KernelTcpConnector].over(
        config^, underlying^,
    )
    assert_true(connector.is_tls())
    _ = connector^
    print("    OK")


def test_transport_kind_matches_underlying() raises:
    """TlsConnector.transport_kind() delegates to the underlying
    connector — TLS does not change the transport class. For
    TlsConnector[KernelTcpConnector] the kind is TRANSPORT_KIND_KERNEL_TCP."""
    print("  test_transport_kind_matches_underlying...")
    var config = TlsConfig()
    var underlying = KernelTcpConnector.new()
    var connector = TlsConnector[KernelTcpConnector].over(
        config^, underlying^,
    )
    assert_equal(Int(connector.transport_kind()), Int(TRANSPORT_KIND_KERNEL_TCP))
    _ = connector^
    print("    OK")


def test_set_server_name_for_next_connect() raises:
    """set_server_name_for_next_connect(host) accepts a String. The
    actual SNI send happens during connect[RT] which the handshake
    tests exercise."""
    print("  test_set_server_name_for_next_connect...")
    var config = TlsConfig()
    var underlying = KernelTcpConnector.new()
    var connector = TlsConnector[KernelTcpConnector].over(
        config^, underlying^,
    )
    connector.set_server_name_for_next_connect(String("example.com"))
    # No observable side effect short of running connect — the test
    # validates that the public surface accepts the String + does not
    # raise.
    _ = connector^
    print("    OK")


def main() raises:
    print("== TlsConnector construction smoke ==")
    test_tls_connector_constructs_over_kernel_tcp()
    test_is_tls_returns_true()
    test_transport_kind_matches_underlying()
    test_set_server_name_for_next_connect()
    print("== TlsConnector construction PASSED (4 tests) ==")
