# =============================================================================
# test_dns_literal.mojo
# =============================================================================
# The DNS resolver.
# Unit tests for parse_ip_literal — the IP-literal FAST PATH. These are
# hermetic: no network, no getaddrinfo (literals never call it).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_net.dns import IpAddr, parse_ip_literal
from komira_async.reactor.socket_setup import inet_loopback_be


comptime _AF_INET: Int32 = Int32(2)


def test_loopback_aliases_some_loopback() raises:
    """Loopback aliases ("", "localhost", "127.0.0.1") → Some(loopback)."""
    var a = parse_ip_literal(String(""))
    assert_true(Bool(a))
    assert_equal(Int(a.value().v4_be), Int(inet_loopback_be()))
    assert_equal(Int(a.value().family), Int(_AF_INET))
    assert_true(a.value().is_ipv4())

    var b = parse_ip_literal(String("localhost"))
    assert_true(Bool(b))
    assert_equal(Int(b.value().v4_be), Int(inet_loopback_be()))

    var c = parse_ip_literal(String("127.0.0.1"))
    assert_true(Bool(c))
    assert_equal(Int(c.value().v4_be), Int(inet_loopback_be()))


def test_dotted_quad_byte_order() raises:
    """Valid dotted-quads → Some with correct network-byte-order packing
    (byte[0] == first octet, matching inet_loopback_be / sockaddr_in_bytes)."""
    # 127.0.0.1 hand-packed = 0x0100007F (octets little-end-first into UInt32).
    var lo = parse_ip_literal(String("127.0.0.1"))
    assert_true(Bool(lo))
    assert_equal(Int(lo.value().v4_be), 0x0100007F)

    # 1.2.3.4 → byte[0]=1, byte[1]=2, byte[2]=3, byte[3]=4 → 0x04030201.
    var q = parse_ip_literal(String("1.2.3.4"))
    assert_true(Bool(q))
    assert_equal(Int(q.value().v4_be), 0x04030201)

    # 255.255.255.255 → all bytes 0xFF → 0xFFFFFFFF.
    var bcast = parse_ip_literal(String("255.255.255.255"))
    assert_true(Bool(bcast))
    assert_equal(Int(bcast.value().v4_be), 0xFFFFFFFF)

    # 10.0.0.50 (a typical pinned ClusterIP) → byte[0]=10 ... byte[3]=50.
    var k = parse_ip_literal(String("10.0.0.50"))
    assert_true(Bool(k))
    var expect = 10 | (0 << 8) | (0 << 16) | (50 << 24)
    assert_equal(Int(k.value().v4_be), expect)


def test_non_literal_returns_none() raises:
    """A real hostname (contains a non-digit-non-dot char) → None (needs DNS).
    This is the behavioral change: the old pg code RAISED on these names."""
    var h1 = parse_ip_literal(String("postgres.example.svc.cluster.local"))
    assert_false(Bool(h1))

    var h2 = parse_ip_literal(String("s3.us-east-1.amazonaws.com"))
    assert_false(Bool(h2))

    var h3 = parse_ip_literal(String("example.com"))
    assert_false(Bool(h3))

    # A bare label with a letter is also a DNS name, not a literal.
    var h4 = parse_ip_literal(String("db"))
    assert_false(Bool(h4))


def test_malformed_literal_raises() raises:
    """Malformed dotted-quads (all-digit-and-dot but not a valid IPv4) RAISE —
    same as today's pg behavior."""
    # Octet > 255.
    var raised1 = False
    try:
        var _r = parse_ip_literal(String("1.2.3.999"))
    except:
        raised1 = True
    assert_true(raised1)

    # Too few octets.
    var raised2 = False
    try:
        var _r = parse_ip_literal(String("1.2.3"))
    except:
        raised2 = True
    assert_true(raised2)

    # Too many octets.
    var raised3 = False
    try:
        var _r = parse_ip_literal(String("1.2.3.4.5"))
    except:
        raised3 = True
    assert_true(raised3)

    # Empty octet between dots.
    var raised4 = False
    try:
        var _r = parse_ip_literal(String("1..2.3"))
    except:
        raised4 = True
    assert_true(raised4)


def main() raises:
    test_loopback_aliases_some_loopback()
    test_dotted_quad_byte_order()
    test_non_literal_returns_none()
    test_malformed_literal_raises()
    print("PASS komira_async.net.dns parse_ip_literal")
