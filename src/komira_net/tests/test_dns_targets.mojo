# =============================================================================
# test_dns_targets.mojo
# =============================================================================
# The steps of resolve_host and resolve_host_be after the lookup, driven with
# hand-built lists: one connect target per address in order, the first
# target's address, and the two NO_IPV4_RECORD guards. A real lookup gives
# only one record on the build machines (the hosts file maps a name to one
# IPv4 address), so a list of two is built here. Hermetic: no lookup runs.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_net.dns import (
    IpAddr,
    SockAddr,
    _connect_targets,
    _first_ip_be,
    _raise_if_no_a_record,
)


comptime _AF_INET: Int32 = Int32(2)
comptime _A_BE: UInt32 = UInt32(0x04040808)  # 8.8.4.4
comptime _B_BE: UInt32 = UInt32(0x2A0200C0)  # 192.0.2.42


def _two_addrs() -> List[IpAddr]:
    var addrs = List[IpAddr]()
    addrs.append(IpAddr(_AF_INET, _A_BE))
    addrs.append(IpAddr(_AF_INET, _B_BE))
    return addrs^


def test_one_target_per_address_in_order() raises:
    """Two addresses give two targets, in the same order, each with the
    caller's port."""
    var targets = _connect_targets(_two_addrs(), UInt16(443))
    assert_equal(len(targets), 2)
    assert_equal(Int(targets[0].ip.v4_be), Int(_A_BE))
    assert_equal(Int(targets[1].ip.v4_be), Int(_B_BE))
    assert_true(targets[1].ip.is_ipv4())
    assert_equal(Int(targets[0].port), 443)
    assert_equal(Int(targets[1].port), 443)


def test_no_address_gives_no_target() raises:
    var targets = _connect_targets(List[IpAddr](), UInt16(443))
    assert_equal(len(targets), 0)


def test_first_ip_be_is_the_first_target() raises:
    var targets = _connect_targets(_two_addrs(), UInt16(80))
    assert_equal(Int(_first_ip_be(targets, String("h.test"))), Int(_A_BE))


def test_first_ip_be_of_no_target_raises() raises:
    var msg = String("")
    try:
        _ = _first_ip_be(List[SockAddr](), String("h.test"))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "DnsError[NO_IPV4_RECORD]: host 'h.test' produced no connect"
            " target"
        ),
    )


def test_no_a_record_raises_only_for_zero() raises:
    """Zero A records raise NO_IPV4_RECORD with the host named; one or two
    do not raise."""
    var msg = String("")
    try:
        _raise_if_no_a_record(0, String("h.test"))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("DnsError[NO_IPV4_RECORD]: host 'h.test' has no IPv4 (A) record"),
    )
    _raise_if_no_a_record(1, String("h.test"))
    _raise_if_no_a_record(2, String("h.test"))


def main() raises:
    test_one_target_per_address_in_order()
    test_no_address_gives_no_target()
    test_first_ip_be_is_the_first_target()
    test_first_ip_be_of_no_target_raises()
    test_no_a_record_raises_only_for_zero()
    print("PASS komira_net.dns connect targets and guards")
