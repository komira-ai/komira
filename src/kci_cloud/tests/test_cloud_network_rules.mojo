# =============================================================================
# test_cloud_network_rules.mojo
# =============================================================================
#
# The network rules (network.mojo) through `graph_findings`, the
# cloud-independent half of validate. No cloud is needed: the fakes in
# kci_cloud_fake run these graphs on every shape.
#
# 1. EVERY NETWORK REFUSAL, IN ONE PASS, each pinned by resource, field path
#    and reason: a network range that is empty, has no `/`, has three
#    octets, an octet of 256, an octet with a leading zero, a prefix of 15,
#    of 29, of `x`, a bit set after the prefix, a public range (8.8.0.0/16)
#    and one just past 172.16.0.0/12 (172.32.0.0/16); `uses` on a network, a
#    subnet and an IP address; a subnet with no network, a missing one, a
#    service as its network, an output as its network, itself as its
#    network, no range, a bit set after the prefix, a range outside its
#    network, a range overlapping an earlier subnet of the same network, a
#    zone of 0 and of 4 (and a subnet of a network whose own range is
#    refused is held to no range: only the network is reported); a service whose `network` is missing, a network
#    (not a subnet), or an output; a NAME asked of an IP address; a grant
#    whose principal is a network; CALL asked of a network. Nothing else is
#    reported.
# 2. A GOOD NETWORK GRAPH IS CLEAN: a network in each private block, at the
#    prefix bounds 16 and 28; subnets at /16 (the whole network) and /28,
#    side by side, in zones 1 and 3 and in none; the same range in two
#    networks; retention KEEP on all three types; a service in a subnet that
#    reads a network's and a subnet's NAME and an address's ADDRESS.
# 3. THE RANGE HELPERS: `ipv4_cidr_problem` at its bounds, `ipv4_text`,
#    `is_private` at the edges of each block, `contains`, `overlaps` (both
#    ways, and side by side), `service_subnet`.
# 4. THE CATALOG ROWS: `network` (23), `subnet` (29) and `ip_address` (30)
#    are PORTABLE, expose NAME, NAME and ADDRESS, accept no verb, take
#    retention with the default DELETE, land on `network`, `subnet` and
#    `address`, and are the twelfth, eighteenth and nineteenth arms.
# Each test names the defect it catches in its docstring.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    CIDR_PREFIX_MAX,
    CIDR_PREFIX_MIN,
    FIELD_IP_ADDRESS,
    FIELD_NETWORK,
    FIELD_SUBNET,
    PORTABLE,
    RETENTION_DELETE,
    Catalog,
    Finding,
    body_arms,
    contains,
    effective_retention,
    graph_findings,
    ipv4_cidr_problem,
    ipv4_text,
    is_private,
    overlaps,
    primary_node,
    service_subnet,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _lines(findings: List[Finding]) -> List[String]:
    var out = List[String]()
    for i in range(len(findings)):
        out.append(findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason)
    return out^


def _expect(lines: List[String], prefix: String, reason: String) raises:
    """Exactly one finding starts with `prefix` (`id|path|`) and holds
    `reason`."""
    var n = 0
    var all = String("")
    for i in range(len(lines)):
        all += lines[i] + String("\n")
        if lines[i].startswith(prefix) and lines[i].find(reason) >= 0:
            n += 1
    assert_equal(n, 1, String("one finding ") + prefix + String(" ... ") + reason + String(" in:\n") + all)


comptime IMG = '"image":{"digest":"sha256:0011"}'


def _net(id: String, cidr: String) -> String:
    return String('{"id":"') + id + String('","network":{"ipv4Cidr":"') + cidr + String('"}},')


def _sub(id: String, network: String, cidr: String, zone: String = String("")) -> String:
    """A subnet; `network` is the JSON of its `network` Ref (empty: none),
    `zone` the JSON number (empty: unset)."""
    var s = String('{"id":"') + id + String('","subnet":{')
    var sep = String("")
    if network.byte_length() > 0:
        s += String('"network":') + network
        sep = String(",")
    if cidr.byte_length() > 0:
        s += sep + String('"ipv4Cidr":"') + cidr + String('"')
        sep = String(",")
    if zone.byte_length() > 0:
        s += sep + String('"zone":') + zone
    return s + String("}},")


comptime CORE = '{"resource":"core"}'


# ---- 1. every refusal, in one pass ------------------------------------------------


def test_every_network_refusal_in_one_pass() raises:
    """Catches: any one rule dropped (its line is missing), a bound off by one
    (a prefix of 15 or 29, an octet of 256, a zone of 0 or 4, 172.32.0.0
    taken as private), a rule that fires on the wrong resource or path, and
    a rule that fires on a good resource (the total)."""
    var g = _list(
        String('{"resource":[')
        + _net(String("core"), String("10.20.0.0/16"))
        + _sub(String("a"), String(CORE), String("10.20.0.0/24"), String("1"))
        + String('{"id":"api","service":{') + String(IMG) + String(',"internal":{}}},')
        + String('{"id":"n-empty","network":{}},')
        + _net(String("n-noslash"), String("10.0.0.0"))
        + _net(String("n-three"), String("10.0.0/16"))
        + _net(String("n-octet"), String("10.0.256.0/16"))
        + _net(String("n-lead"), String("10.01.0.0/16"))
        + _net(String("n-wide"), String("10.0.0.0/15"))
        + _net(String("n-narrow"), String("10.0.0.0/29"))
        + _net(String("n-prefix"), String("10.0.0.0/x"))
        + _net(String("n-host"), String("10.20.1.0/16"))
        + _net(String("n-public"), String("8.8.0.0/16"))
        + _net(String("n-172"), String("172.32.0.0/16"))
        + String('{"id":"n-uses","network":{"ipv4Cidr":"10.30.0.0/16"},')
        + String('"uses":[{"target":{"resource":"api"},"access":"CALL"}]},')
        + _sub(String("s-none"), String(""), String("10.20.30.0/24"))
        + _sub(String("s-gone"), String('{"resource":"nope"}'), String("10.20.31.0/24"))
        + _sub(String("s-svc"), String('{"resource":"api"}'), String("10.20.32.0/24"))
        + _sub(String("s-out"), String('{"resource":"core","standard":"NAME"}'), String("10.20.33.0/24"))
        + _sub(String("s-self"), String('{"resource":"s-self"}'), String("10.20.34.0/24"))
        + _sub(String("s-empty"), String(CORE), String(""))
        + _sub(String("s-host"), String(CORE), String("10.20.2.1/24"))
        + _sub(String("s-outside"), String(CORE), String("10.30.0.0/24"))
        + _sub(String("s-overlap"), String(CORE), String("10.20.0.128/25"))
        + _sub(String("s-badnet"), String('{"resource":"n-noslash"}'), String("10.0.0.0/24"))
        + _sub(String("s-zone0"), String(CORE), String("10.20.10.0/24"), String("0"))
        + _sub(String("s-zone4"), String(CORE), String("10.20.11.0/24"), String("4"))
        + String('{"id":"s-uses","subnet":{"network":{"resource":"core"},"ipv4Cidr":"10.20.12.0/24"},')
        + String('"uses":[{"cell":"LOGS","access":"WRITE"}]},')
        + String('{"id":"i-uses","ipAddress":{},"uses":[{"target":{"resource":"api"},"access":"CALL"}]},')
        + String('{"id":"ip","ipAddress":{}},')
        + String('{"id":"v-gone","service":{') + String(IMG) + String(',"internal":{},"network":{"resource":"nope"}}},')
        + String('{"id":"v-net","service":{') + String(IMG) + String(',"internal":{},"network":') + String(CORE)
        + String("}},")
        + String('{"id":"v-out","service":{') + String(IMG)
        + String(',"internal":{},"network":{"resource":"a","standard":"NAME"},')
        + String('"env":{"IP":{"ref":{"resource":"ip","standard":"NAME"}}}}},')
        + String('{"id":"g-from-net","grant":{"principal":{"resource":"core"},"target":{"resource":"api"},')
        + String('"access":"CALL"}},')
        + String('{"id":"caller","serviceAccount":{},"uses":[{"target":{"resource":"core"},"access":"CALL"}]}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    var nr = String("n-empty|network.ipv4_cidr|")
    _expect(l, nr, "no range: write the network's IPv4 range")
    _expect(l, "n-noslash|network.ipv4_cidr|", '"10.0.0.0" is not an IPv4 range "a.b.c.d/n"')
    _expect(l, "n-three|network.ipv4_cidr|", '"10.0.0/16" is not an IPv4 range "a.b.c.d/n"')
    _expect(l, "n-octet|network.ipv4_cidr|", '"10.0.256.0/16": "256" is not an octet (0 to 255, no leading zero)')
    _expect(l, "n-lead|network.ipv4_cidr|", '"10.01.0.0/16": "01" is not an octet')
    _expect(l, "n-wide|network.ipv4_cidr|", '"10.0.0.0/15": a prefix length is from 16 to 28')
    _expect(l, "n-narrow|network.ipv4_cidr|", '"10.0.0.0/29": a prefix length is from 16 to 28')
    _expect(l, "n-prefix|network.ipv4_cidr|", '"10.0.0.0/x": "x" is not a prefix length')
    _expect(l, "n-host|network.ipv4_cidr|", '"10.20.1.0/16" has bits set after the first 16; the range is "10.20.0.0/16"')
    _expect(l, "n-public|network.ipv4_cidr|", '"8.8.0.0/16" is not a private range')
    _expect(l, "n-172|network.ipv4_cidr|", '"172.32.0.0/16" is not a private range')
    _expect(l, "n-uses|uses|", "a network runs as no identity, so it has no uses lines")
    _expect(l, "s-none|subnet.network|", "no network")
    _expect(l, "s-gone|subnet.network|", 'ref to missing resource "nope"')
    _expect(l, "s-svc|subnet.network|", 'must name a network; "api" is not one')
    _expect(l, "s-out|subnet.network|", "names a network, not one of its outputs")
    _expect(l, "s-self|subnet.network|", "refers to its own resource")
    _expect(l, "s-empty|subnet.ipv4_cidr|", "no range: write the subnet's IPv4 range")
    _expect(l, "s-host|subnet.ipv4_cidr|", '"10.20.2.1/24" has bits set after the first 24; the range is "10.20.2.0/24"')
    _expect(l, "s-outside|subnet.ipv4_cidr|", '"10.30.0.0/24" is not inside the range of network "core", "10.20.0.0/16"')
    _expect(
        l,
        "s-overlap|subnet.ipv4_cidr|",
        '"10.20.0.128/25" overlaps subnet "a" ("10.20.0.0/24") of the same network "core"',
    )
    _expect(l, "s-zone0|subnet.zone|", "zone 0 is not a zone: a zone is from 1 to 3 (unset: no zone named)")
    _expect(l, "s-zone4|subnet.zone|", "zone 4 is not a zone: a zone is from 1 to 3")
    _expect(l, "s-uses|uses|", "a subnet runs as no identity, so it has no uses lines")
    _expect(l, "i-uses|uses|", "an IP address runs as no identity")
    _expect(l, "v-gone|service.network|", 'ref to missing resource "nope"')
    _expect(l, "v-net|service.network|", 'must name a subnet; "core" is not one')
    _expect(l, "v-out|service.network|", "names a subnet, not one of its outputs")
    _expect(l, "v-out|service.env.IP|", '"ip" (ip_address) does not expose NAME')
    _expect(l, "g-from-net|grant.principal|", "the principal must be a service_account")
    _expect(l, "caller|uses[0]|", 'network "core" does not accept access CALL')
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 31, String("nothing else is reported:\n") + all)
    print("  test_every_network_refusal_in_one_pass: PASS")


# ---- 2. a good network graph is clean -----------------------------------------------


def test_a_good_network_graph_is_clean() raises:
    """Catches: a valid range refused at a bound (/16, /28, the first and
    last private blocks), side-by-side subnets taken as overlapping, the
    same range in two networks taken as an overlap, a zone at its bounds or
    unset refused, retention refused on a network type, and a service in a
    subnet refused."""
    var g = _list(
        String('{"resource":[')
        + String('{"id":"core","retention":"KEEP","network":{"ipv4Cidr":"10.0.0.0/16"}},')
        + _net(String("lab"), String("172.16.0.0/16"))
        + _net(String("tiny"), String("172.31.255.240/28"))
        + _net(String("home"), String("192.168.0.0/16"))
        + _sub(String("a"), String(CORE), String("10.0.0.0/24"), String("1"))
        + _sub(String("b"), String(CORE), String("10.0.1.0/24"), String("3"))
        + _net(String("dup"), String("10.0.0.0/16"))
        + _sub(String("dup-a"), String('{"resource":"dup"}'), String("10.0.0.0/24"))
        + String('{"id":"c","retention":"KEEP","subnet":{"network":{"resource":"core"},"ipv4Cidr":"10.0.2.0/28"}},')
        + _sub(String("lab-a"), String('{"resource":"lab"}'), String("172.16.0.0/24"))
        + _sub(String("tiny-all"), String('{"resource":"tiny"}'), String("172.31.255.240/28"))
        + _sub(String("home-all"), String('{"resource":"home"}'), String("192.168.0.0/16"), String("2"))
        + String('{"id":"ip","retention":"KEEP","ipAddress":{}},')
        + String('{"id":"api","service":{') + String(IMG) + String(',"internal":{},"network":{"resource":"a"},')
        + String('"env":{"IP":{"ref":{"resource":"ip","standard":"ADDRESS"}},')
        + String('"NET":{"ref":{"resource":"core","standard":"NAME"}},')
        + String('"SUB":{"ref":{"resource":"a","standard":"NAME"}}}}}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 0, String("a good network graph is clean:\n") + all)
    print("  test_a_good_network_graph_is_clean: PASS")


# ---- 3. the range helpers -------------------------------------------------------------


def test_the_range_helpers() raises:
    """Catches: a range form accepted that is not one (a leading zero, a
    fifth octet, a prefix with a leading zero), a bound off by one, a block
    edge of `is_private` off by one, `contains` that ignores the outer
    prefix, and `overlaps` that is not symmetric."""
    assert_equal(CIDR_PREFIX_MIN, 16)
    assert_equal(CIDR_PREFIX_MAX, 28)
    for good in ["0.0.0.0/16", "255.255.255.240/28", "10.0.0.0/16", "10.255.255.0/24"]:
        assert_equal(ipv4_cidr_problem(String(good)), "", String(good))
    for bad in ["", "10.0.0.0/016", "10.0.0.0.0/16", "10.0.0.0/", "/16", "10..0.0/16", "10.0.0.-1/16", "a.b.c.d/16"]:
        assert_true(ipv4_cidr_problem(String(bad)).byte_length() > 0, String("refused: ") + String(bad))
    assert_equal(ipv4_text(0x0A140000, 16), "10.20.0.0/16")
    assert_equal(ipv4_text(0xC0A8FFF0, 28), "192.168.255.240/28")
    # The edges of the three private blocks.
    assert_true(is_private(0x0A000000, 16), "10.0.0.0/16")
    assert_true(is_private(0x0AFF0000, 16), "10.255.0.0/16")
    assert_false(is_private(0x0B000000, 16), "11.0.0.0/16")
    assert_false(is_private(0x09FF0000, 16), "9.255.0.0/16")
    assert_false(is_private(0xAC0F0000, 16), "172.15.0.0/16")
    assert_true(is_private(0xAC100000, 16), "172.16.0.0/16")
    assert_true(is_private(0xAC1F0000, 16), "172.31.0.0/16")
    assert_false(is_private(0xAC200000, 16), "172.32.0.0/16")
    assert_false(is_private(0xC0A70000, 16), "192.167.0.0/16")
    assert_true(is_private(0xC0A80000, 16), "192.168.0.0/16")
    assert_false(is_private(0xC0A90000, 16), "192.169.0.0/16")
    # contains: the outer's prefix decides; a wider inner range is never in.
    assert_true(contains(0x0A140000, 16, 0x0A140400, 24), "10.20.4.0/24 in 10.20.0.0/16")
    assert_true(contains(0x0A140000, 16, 0x0A140000, 16), "a range holds itself")
    assert_false(contains(0x0A140000, 16, 0x0A150000, 24), "10.21.0.0/24 is outside")
    assert_false(contains(0x0A140400, 24, 0x0A140000, 16), "a wider range is not inside a narrower one")
    # overlaps: either way round; neighbours do not.
    assert_true(overlaps(0x0A140000, 24, 0x0A140080, 25), "a /25 inside a /24")
    assert_true(overlaps(0x0A140080, 25, 0x0A140000, 24), "and the other way round")
    assert_false(overlaps(0x0A140000, 24, 0x0A140100, 24), "side by side")
    var g = _list(
        String('{"resource":[') + _sub(String("a"), String(CORE), String("10.0.0.0/24"))
        + String('{"id":"api","service":{') + String(IMG) + String(',"network":{"resource":"a"}}},')
        + String('{"id":"web","service":{') + String(IMG) + String("}}")
        + String("]}")
    )
    assert_equal(service_subnet(g[1]), "a", "a service's subnet")
    assert_equal(service_subnet(g[2]), "", "a service in no subnet")
    assert_equal(service_subnet(g[0]), "", "not a service")
    print("  test_the_range_helpers: PASS")


# ---- 4. the catalog rows ---------------------------------------------------------------


def test_the_network_rows() raises:
    """Catches: a row at another field or arm position (a decoded subnet
    would map to another type), a portability other than PORTABLE, an
    output other than the one each exposes, a verb on a network type
    (placing a workload in a subnet is a field, not a grant), no retention
    or a default other than DELETE, and a primary role other than
    `network`, `subnet` and `address` (or one over 8 bytes)."""
    assert_equal(FIELD_NETWORK, 23)
    assert_equal(FIELD_SUBNET, 29)
    assert_equal(FIELD_IP_ADDRESS, 30)
    var c = Catalog.v1()
    var arms = body_arms()
    var fields = [FIELD_NETWORK, FIELD_SUBNET, FIELD_IP_ADDRESS]
    var names = ["network", "subnet", "ip_address"]
    var roles = ["network", "subnet", "address"]
    var outputs = ["NAME", "NAME", "ADDRESS"]
    var positions = [11, 17, 18]
    for i in range(3):
        ref t = c.types[c.index_of(fields[i])]
        assert_equal(t.name, String(names[i]))
        assert_equal(t.portability, PORTABLE)
        assert_equal(len(t.exposes), 1, String(names[i]) + " exposes one output")
        assert_equal(t.exposes[0], String(outputs[i]))
        assert_equal(len(t.accepts), 0, String(names[i]) + " accepts no verb")
        assert_true(t.takes_retention(), String(names[i]) + " takes retention")
        assert_equal(t.retention_default, RETENTION_DELETE, String(names[i]) + ": DELETE by default")
        assert_equal(t.primary_role, String(roles[i]))
        assert_true(t.primary_role.byte_length() <= 8, "a role word is 8 bytes at most")
        assert_equal(arms[positions[i]].field, fields[i], String(names[i]) + " by declaration order")
        assert_equal(arms[positions[i]].name, String(names[i]))
    var l = _list(
        String('{"resource":[') + _net(String("core"), String("10.0.0.0/16"))
        + _sub(String("a"), String(CORE), String("10.0.0.0/24"))
        + String('{"id":"ip","ipAddress":{}}]}')
    )
    for i in range(3):
        assert_equal(effective_retention(c, l[i]), RETENTION_DELETE, l[i].id + ": unset is DELETE")
    assert_equal(primary_node(c, l, String("core")), "core/network")
    assert_equal(primary_node(c, l, String("a")), "a/subnet")
    assert_equal(primary_node(c, l, String("ip")), "ip/address")
    print("  test_the_network_rows: PASS")


def main() raises:
    print("test_cloud_network_rules")
    test_every_network_refusal_in_one_pass()
    test_a_good_network_graph_is_clean()
    test_the_range_helpers()
    test_the_network_rows()
    print("ALL kci_cloud NETWORK RULE TESTS PASSED")
