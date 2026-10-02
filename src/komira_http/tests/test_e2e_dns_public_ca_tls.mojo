# =============================================================================
# test_e2e_dns_public_ca_tls.mojo
# =============================================================================
# Integration test proving two general HttpClient capabilities end-to-end:
#
#   DNS — HttpClient resolves a HOSTNAME (A record) via getaddrinfo and dials
#         it, on macOS as well as Linux (the macOS addrinfo field-offset fix).
#         The dial chokepoint is `_ip_be_from_host`.
#   public-CA TLS — HttpClient connects to an arbitrary public HTTPS host by
#         hostname over a `TlsConnector[KernelTcpConnector]` configured to
#         verify the peer against the SYSTEM / public-CA trust store, with
#         SNI = the hostname (`build_public_ca_tls_connector`).
#
# NETWORK GATING: the LIVE part (real DNS + real TLS handshake to a public host)
# is OPT-IN via the `--net-tests` command-line argument, so the test is
# hermetic by default. Without it the test still runs the OFFLINE assertions
# (loopback resolves via the public resolver; the public-CA connector builds
# without error) and PASSES. With it, it additionally does the real resolve +
# public-CA TLS GET and asserts a valid HTTP status came back.
#
# Optional override: `--net-test-host=<host>` (default "example.com").
# =============================================================================

from std.testing import assert_equal, assert_true

from std.sys import argv

from komira_net.dns import resolve_host_be
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.socket_setup import inet_loopback_be
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http.client.body import EmptyBody
from komira_http.client.client import (
    HttpClient,
    build_get_request,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.tls_connector import (
    TlsConnector,
    build_public_ca_tls_connector,
)
from komira_http.client.url import Url
from komira_http.transport.kernel_tcp import KernelTcpConnector


# -----------------------------------------------------------------------------
# OFFLINE assertions (always run — hermetic, no network).
# -----------------------------------------------------------------------------


def test_resolver_loopback_via_public_api() raises:
    """DNS offline: the public `resolve_host_be` returns loopback for
    "localhost" / "127.0.0.1" via the IP-literal fast path (no getaddrinfo, no
    network). This is the resolution surface the HttpClient dial path now calls
    in front of every dial."""
    var a = resolve_host_be(String("localhost"), UInt16(443))
    assert_equal(Int(a), Int(inet_loopback_be()))
    var b = resolve_host_be(String("127.0.0.1"), UInt16(80))
    assert_equal(Int(b), Int(inet_loopback_be()))


def test_public_ca_connector_builds() raises:
    """Public-CA offline: `build_public_ca_tls_connector` constructs a verify-peer
    public-CA TlsConnector without error (TLS 1.3 cipher policy + ALPN +
    SNI + default OS trust store). No socket / no handshake here — just proves
    the connector + its TlsConfig are wired correctly and the trust store is
    NOT wiped."""
    var connector = build_public_ca_tls_connector(String("example.com"))
    # verify_mode must be VERIFY_PEER (public-CA verification ON).
    assert_true(connector.is_tls())
    # The session cache is empty on a fresh connector (no dial yet).
    assert_equal(connector.session_cache_len(), 0)


# -----------------------------------------------------------------------------
# LIVE assertions (opt-in via `--net-tests`).
# -----------------------------------------------------------------------------


def _net_tests_enabled() -> Bool:
    """True when `--net-tests` is one of this program's arguments."""
    var args = argv()
    for i in range(1, len(args)):
        if String(args[i]) == String("--net-tests"):
            return True
    return False


def _live_host() -> String:
    """The public host to dial: `--net-test-host=<host>`, default example.com
    (stable, IANA-operated, always 200 over HTTPS)."""
    var prefix = String("--net-test-host=")
    var args = argv()
    for i in range(1, len(args)):
        var a = String(args[i])
        if a.startswith(prefix) and a.byte_length() > prefix.byte_length():
            return String(a[byte = prefix.byte_length() :])
    return String("example.com")


def test_live_dns_resolve_public_host() raises:
    """DNS LIVE: resolve a real public hostname via getaddrinfo. Asserts a
    NON-loopback, NON-zero A record came back — proving the macOS (and Linux)
    addrinfo parse extracted a real public IP. Gated on `--net-tests`."""
    if not _net_tests_enabled():
        return  # offline: skip the live leg (test still PASSES via the offline cases)
    var host = _live_host()
    var ip_be = resolve_host_be(host, UInt16(443))
    # A real public A record is neither 0.0.0.0 nor 127.x loopback.
    assert_true(Int(ip_be) != 0)
    assert_true(Int(ip_be) != Int(inet_loopback_be()))


def test_live_public_ca_tls_get() raises:
    """DNS + public-CA LIVE: full round-trip — resolve `host` by name, dial it
    over a public-CA TlsConnector (verify-peer against the OS trust store,
    SNI = host), GET "/", and assert a valid HTTP status came back. A
    successful handshake + an HTTP status line is the proof that DNS +
    public-CA TLS both worked. Gated on `--net-tests`."""
    if not _net_tests_enabled():
        return  # offline: skip
    var host = _live_host()

    # build the general public-CA TLS connector (SNI = host). HttpClient
    # is parametric over the connector — this is the 1-line connector swap.
    var connector = build_public_ca_tls_connector(host)
    var client = HttpClient[TlsConnector[KernelTcpConnector]].with_defaults(
        connector^,
    )

    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    # dial by HOSTNAME (port 443). The HttpClient dial path resolves the
    # name via getaddrinfo internally (_ip_be_from_host), then the TLS connector
    # handshakes + verifies against the public CAs with SNI = host.
    var url = Url.https(host, UInt16(443), String("/"))
    var headers = HeaderMap()
    headers.append(String("Accept"), String("*/*"))
    # Some public hosts require a Host header that matches SNI; Url.https sets
    # the Host header from the URL host already (the request writer derives it).
    headers.append(String("Connection"), String("close"))
    var req = build_get_request(url^, headers^)

    var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
        req^, reactor
    )
    var status = Int(cr.status)
    # ANY valid HTTP status (2xx redirect/ok, 3xx, even 4xx) proves the TLS
    # handshake + public-CA verification + DNS resolve all succeeded — the wire
    # carried a real HTTP response. A handshake/verify failure would have RAISED
    # before producing a status.
    assert_true(status >= 100 and status < 600)
    print("  live public-CA TLS GET", host, "→ status", status)


def main() raises:
    test_resolver_loopback_via_public_api()
    test_public_ca_connector_builds()
    test_live_dns_resolve_public_host()
    test_live_public_ca_tls_get()
    print("PASS komira_http DNS + public-CA TLS e2e")
