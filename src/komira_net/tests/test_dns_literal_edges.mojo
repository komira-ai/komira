# =============================================================================
# test_dns_literal_edges.mojo
# =============================================================================
# parse_ip_literal at its boundaries: the loopback aliases match exactly (not
# as prefixes), the octet range ends at 255, a one-character host is no alias,
# and when a host has two faults the documented first check reports it.
# Hermetic: literals never call getaddrinfo.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_net.dns import parse_ip_literal
from komira_async.reactor.socket_setup import inet_loopback_be


def _raised(host: String) -> String:
    """The message parse_ip_literal raised for `host`, or "" if it returned."""
    try:
        _ = parse_ip_literal(host)
    except e:
        return String(e)
    return String("")


def test_aliases_match_exactly_not_as_prefixes() raises:
    """"localhost" and "127.0.0.1" are exact aliases: a longer name that starts
    with one is a DNS name (None) or a different literal (its own bytes)."""
    assert_false(Bool(parse_ip_literal(String("localhost.example.test"))))
    assert_false(Bool(parse_ip_literal(String("localhostx"))))
    var ten = parse_ip_literal(String("127.0.0.10"))
    assert_true(Bool(ten))
    assert_equal(Int(ten.value().v4_be), 127 | (10 << 24))
    assert_true(Int(ten.value().v4_be) != Int(inet_loopback_be()))


def test_one_digit_host_is_no_alias() raises:
    """Only the empty host is the empty alias: a one-digit host is a malformed
    literal, not loopback."""
    assert_equal(
        _raised(String("7")), String("dns: malformed IPv4 literal '7'")
    )


def test_octet_range_boundaries() raises:
    """255 is the last valid octet in every position and 256 the first
    invalid one; 0 is valid."""
    var zero = parse_ip_literal(String("0.0.0.0"))
    assert_true(Bool(zero))
    assert_equal(Int(zero.value().v4_be), 0)
    var hi = parse_ip_literal(String("0.255.0.255"))
    assert_true(Bool(hi))
    assert_equal(Int(hi.value().v4_be), (255 << 8) | (255 << 24))
    for pos in range(4):
        var octets = List[String]()
        for k in range(4):
            octets.append(String(k + 1))
        octets[pos] = String("256")
        var host = (
            octets[0] + "." + octets[1] + "." + octets[2] + "." + octets[3]
        )
        assert_equal(
            _raised(host),
            String("dns: IPv4 octet out of range in '") + host + "'",
        )


def test_a_letter_wins_over_a_malformed_shape() raises:
    """A host with a letter AND an empty octet is a DNS name: the
    digit-or-dot classification runs before any shape check, so it returns
    None and does not raise."""
    assert_false(Bool(parse_ip_literal(String("1..2.a"))))
    assert_false(Bool(parse_ip_literal(String("999.example.test"))))


def test_wrong_count_reported_before_octet_range() raises:
    """Three octets, one of them out of range: the count check runs first, so
    the message names the shape, not the range."""
    assert_equal(
        _raised(String("1.2.999")),
        String("dns: malformed IPv4 literal '1.2.999'"),
    )


def test_empty_octet_reported_before_count() raises:
    """An empty octet between dots AND a wrong count: the empty octet is seen
    first, while scanning, so the message is the empty-octet one."""
    assert_equal(
        _raised(String("1..2")), String("dns: malformed IP literal '1..2'")
    )
    assert_equal(
        _raised(String(".1.2.3")),
        String("dns: malformed IP literal '.1.2.3'"),
    )


def main() raises:
    test_aliases_match_exactly_not_as_prefixes()
    test_one_digit_host_is_no_alias()
    test_octet_range_boundaries()
    test_a_letter_wins_over_a_malformed_shape()
    test_wrong_count_reported_before_octet_range()
    test_empty_octet_reported_before_count()
    print("PASS komira_net.dns parse_ip_literal edges")
