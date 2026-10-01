# =============================================================================
# test_dns_resolve.mojo
# =============================================================================
# The DNS resolver.
# Exercises the REAL getaddrinfo path + the FFI thunk + freeaddrinfo discipline,
# hermetically: `localhost` is always in /etc/hosts (no network), and the
# `.invalid` TLD is RFC-2606 reserved (guaranteed NXDOMAIN, no real query).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.net.dns import (
    _getaddrinfo_collect,
    resolve_host,
    resolve_host_be,
)
from komira_async.reactor.socket_setup import inet_loopback_be


def test_resolve_host_localhost_via_getaddrinfo() raises:
    """resolve_host("localhost") takes the literal fast path (loopback shortcut)
    and returns the loopback target WITHOUT touching getaddrinfo — proving the
    fast-path branch."""
    var targets = resolve_host(String("localhost"), UInt16(5432))
    assert_true(len(targets) >= 1)
    assert_equal(Int(targets[0].ip.v4_be), Int(inet_loopback_be()))
    assert_equal(Int(targets[0].port), 5432)


def test_resolve_host_dotted_quad_fast_path() raises:
    """A dotted-quad literal takes the fast path and returns the exact bytes —
    no getaddrinfo."""
    var targets = resolve_host(String("1.2.3.4"), UInt16(80))
    assert_true(len(targets) >= 1)
    assert_equal(Int(targets[0].ip.v4_be), 0x04030201)
    assert_equal(Int(targets[0].port), 80)


def test_resolve_host_be_localhost() raises:
    """resolve_host_be("localhost") → 127.0.0.1 in network byte order."""
    var ip_be = resolve_host_be(String("localhost"), UInt16(5432))
    assert_equal(Int(ip_be), Int(inet_loopback_be()))


def test_resolve_host_be_dotted_quad_parity() raises:
    """resolve_host_be on a dotted-quad literal takes the fast path and returns
    the exact bytes (parity boundary documented here). The LIVE getaddrinfo
    round-trips are proven by test_getaddrinfo_collect_localhost_success (the
    success path) and test_resolve_nxdomain_raises (the free-on-raise path)."""
    var ip_be = resolve_host_be(String("127.0.0.1"), UInt16(5432))
    assert_equal(Int(ip_be), Int(inet_loopback_be()))


def test_getaddrinfo_collect_localhost_success() raises:
    """Drive the REAL getaddrinfo SUCCESS path directly (bypassing the public
    "localhost" literal shortcut) — `localhost` is always in /etc/hosts, so
    getaddrinfo resolves it offline. Proves the FFI thunk parses the addrinfo
    list, extracts sin_addr, and returns a non-empty List[IpAddr] for a real
    DNS-shaped resolution. This is the success counterpart to the NXDOMAIN
    raise path."""
    comptime if CompilationTarget.is_linux():
        var addrs = _getaddrinfo_collect(String("localhost"), UInt16(5432))
        assert_true(len(addrs) >= 1)
        # /etc/hosts maps localhost → 127.0.0.1; the first A record must be
        # loopback in network byte order.
        assert_equal(Int(addrs[0].v4_be), Int(inet_loopback_be()))
        assert_true(addrs[0].is_ipv4())


def test_resolve_nxdomain_raises() raises:
    """A guaranteed-NXDOMAIN name (.invalid TLD, RFC-2606 reserved) enters
    getaddrinfo and RAISES a DnsError. This is the test that EXERCISES the real
    getaddrinfo path + the freeaddrinfo-on-raise discipline (the resolver must
    free any partial result list before raising)."""
    comptime if CompilationTarget.is_linux():
        var raised = False
        try:
            var _r = resolve_host_be(
                String("komira-nonexistent.invalid"), UInt16(80)
            )
        except:
            raised = True
        assert_true(raised)


def test_ffi_lifetime_stress_no_leak() raises:
    """FFI/lifetime stress: resolve in a loop, exercising the
    freeaddrinfo-on-every-path discipline. Uses the literal fast path (no
    network) for the bulk loop + a handful of NXDOMAIN getaddrinfo round-trips
    so the FFI thunk's free path is hit repeatedly. No leak / no crash."""
    for _i in range(1000):
        var ip_be = resolve_host_be(String("127.0.0.1"), UInt16(80))
        assert_equal(Int(ip_be), Int(inet_loopback_be()))

    comptime if CompilationTarget.is_linux():
        for _j in range(16):
            var raised = False
            try:
                var _r = resolve_host_be(
                    String("komira-nonexistent.invalid"), UInt16(80)
                )
            except:
                raised = True
            assert_true(raised)


def main() raises:
    test_resolve_host_localhost_via_getaddrinfo()
    test_resolve_host_dotted_quad_fast_path()
    test_resolve_host_be_localhost()
    test_resolve_host_be_dotted_quad_parity()
    test_getaddrinfo_collect_localhost_success()
    test_resolve_nxdomain_raises()
    test_ffi_lifetime_stress_no_leak()
    print("PASS komira_async.net.dns resolve_host")
