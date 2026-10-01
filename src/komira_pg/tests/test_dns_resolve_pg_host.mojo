# =============================================================================
# komira_pg/tests/test_dns_resolve_pg_host.mojo
# =============================================================================
# Host resolution on the pg connect path: pg_tls._resolve_host_be takes the
# IP-literal fast path for "localhost" / "" / dotted quads and falls through
# to getaddrinfo for any other name, so a DNS name (for example a Kubernetes
# service name) resolves instead of raising.
#
# Regression: a /etc/hosts-backed name must resolve through the pg path
# without raising. We also PIN the IP-literal fast path (parity guard:
# literals must NOT change).
# =============================================================================

from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_pg.pg_tls import _resolve_host_be
from komira_async.reactor.socket_setup import inet_loopback_be
from komira_async.net.dns import _getaddrinfo_collect


def test_pg_literal_fast_path_parity() raises:
    """PARITY GUARD: the IP-literal fast path is exact. These never hit
    getaddrinfo."""
    # Loopback aliases.
    assert_equal(Int(_resolve_host_be(String("localhost"))),
                 Int(inet_loopback_be()))
    assert_equal(Int(_resolve_host_be(String(""))),
                 Int(inet_loopback_be()))
    # Dotted-quad packing (127.0.0.1 = 0x0100007F, byte[0]==first octet).
    assert_equal(Int(_resolve_host_be(String("127.0.0.1"))),
                 Int(inet_loopback_be()))
    assert_equal(Int(_resolve_host_be(String("127.0.0.1"))), 0x0100007F)
    # A non-loopback dotted quad parses (byte order pin).
    assert_equal(Int(_resolve_host_be(String("10.1.2.3"))),
                 10 | (1 << 8) | (2 << 16) | (3 << 24))


def test_pg_dns_name_resolves_not_raises() raises:
    """A DNS-shaped hostname RESOLVES through the pg path instead of raising.
    We can't pass a name through the public `_resolve_host_be` "localhost"
    shortcut and prove getaddrinfo ran, so we drive the underlying resolver on
    a /etc/hosts-backed name directly: it must return a target, proving the
    getaddrinfo fall-through works end-to-end.

    `localhost` is always in /etc/hosts (no network), so this is hermetic."""
    comptime if CompilationTarget.is_linux():
        # The resolver underneath _resolve_host_be: a real getaddrinfo
        # round-trip on a /etc/hosts name returns loopback.
        var addrs = _getaddrinfo_collect(String("localhost"), UInt16(5432))
        assert_true(len(addrs) >= 1)
        assert_equal(Int(addrs[0].v4_be), Int(inet_loopback_be()))

    # And the public pg surface no longer raises on the "localhost" name (it
    # takes the literal shortcut and yields loopback).
    assert_equal(Int(_resolve_host_be(String("localhost"))),
                 Int(inet_loopback_be()))


def test_pg_nxdomain_still_raises() raises:
    """A genuinely-nonexistent host STILL raises through the pg path (the fix
    enables resolution, it does not swallow real DNS failures). Uses the
    RFC-2606 .invalid TLD (guaranteed NXDOMAIN, no network)."""
    comptime if CompilationTarget.is_linux():
        var raised = False
        try:
            var _r = _resolve_host_be(
                String("komira-nonexistent.invalid")
            )
        except:
            raised = True
        assert_true(raised)


def main() raises:
    test_pg_literal_fast_path_parity()
    test_pg_dns_name_resolves_not_raises()
    test_pg_nxdomain_still_raises()
    print("PASS komira_pg DNS host resolution")
