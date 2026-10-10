# =============================================================================
# kci_cloud/network.mojo: the rules of the NETWORK primitives (network,
# subnet, IP address) and of `Service.network`.
# =============================================================================
#
# GRAPH findings, true on every cloud, that validate collects for a network
# resource (`network_findings`):
#   * a network, a subnet and an IP address run as no identity, so none has
#     `uses` lines;
#   * an IPv4 range ("a.b.c.d/n", a network's or a subnet's `ipv4_cidr`) is
#     written, four decimal octets from 0 to 255 with no leading zero, a
#     prefix length n from 16 to 28, and no bit set after the first n
#     (`ipv4_cidr_problem`);
#   * a network's range is private: inside 10.0.0.0/8, 172.16.0.0/12 or
#     192.168.0.0/16;
#   * a subnet's `network` names a `network` of the list (the resource
#     itself, no output); its range lies inside that network's range; it
#     overlaps no earlier subnet of the same network (reported on the
#     later one); its `zone`, when written, is from 1 to 3.
# And `service_network_findings`: a service's `network`, when written, names
# a `subnet` of the list (the resource itself, no output).
#
# Whether a cloud needs a zone (its subnets are each in one zone) or can
# place a service in a subnet at all is that cloud's limit, not a rule here.
# =============================================================================

from kci_resource_proto.refs import Ref
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import FIELD_IP_ADDRESS, FIELD_NETWORK, FIELD_SUBNET
from kci_cloud.feed import field_of_id
from kci_cloud.messaging import check_typed_ref


comptime CIDR_PREFIX_MIN: Int = 16
"""The widest range: every built-in cloud's network and subnet take /16."""
comptime CIDR_PREFIX_MAX: Int = 28
"""The narrowest range: every built-in cloud's subnet takes /28."""
comptime ZONE_MIN: Int = 1
comptime ZONE_MAX: Int = 3
"""Every built-in cloud's regions with zones have at least three."""


def _octet(text: String) -> Int:
    """`text` as a decimal octet (0 to 255, no leading zero), or -1."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 3:
        return -1
    if len(b) > 1 and Int(b[0]) == ord("0"):
        return -1
    var v = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < ord("0") or c > ord("9"):
            return -1
        v = v * 10 + (c - ord("0"))
    if v > 255:
        return -1
    return v


def _parse(text: String, mut base: Int, mut prefix: Int) -> String:
    """Parse "a.b.c.d/n" into `base` (the address as a 32-bit number) and
    `prefix`; returns why it is not a range of the file header's form, or
    empty."""
    var slash = text.find("/")
    if slash < 0:
        return String("\"") + text + String("\" is not an IPv4 range \"a.b.c.d/n\"")
    var addr = String(text[byte=0:slash])
    var parts = addr.split(".")
    if len(parts) != 4:
        return String("\"") + text + String("\" is not an IPv4 range \"a.b.c.d/n\"")
    var v = 0
    for i in range(4):
        var o = _octet(String(parts[i]))
        if o < 0:
            return (
                String("\"") + text + String("\": \"") + String(parts[i])
                + String("\" is not an octet (0 to 255, no leading zero)")
            )
        v = v * 256 + o
    var n = String(text[byte = slash + 1 : text.byte_length()])
    var p = _octet(n)
    if p < 0:
        return String("\"") + text + String("\": \"") + n + String("\" is not a prefix length")
    if p < CIDR_PREFIX_MIN or p > CIDR_PREFIX_MAX:
        return (
            String("\"") + text + String("\": a prefix length is from ") + String(CIDR_PREFIX_MIN)
            + String(" to ") + String(CIDR_PREFIX_MAX) + String(", the sizes every built-in cloud takes")
        )
    if v % (1 << (32 - p)) != 0:
        return (
            String("\"") + text + String("\" has bits set after the first ") + String(p)
            + String("; the range is \"") + ipv4_text(v - v % (1 << (32 - p)), p) + String("\"")
        )
    base = v
    prefix = p
    return String("")


def ipv4_text(base: Int, prefix: Int) -> String:
    """`base` and `prefix` written as "a.b.c.d/n"."""
    return (
        String((base >> 24) & 255) + String(".") + String((base >> 16) & 255) + String(".")
        + String((base >> 8) & 255) + String(".") + String(base & 255) + String("/") + String(prefix)
    )


def ipv4_cidr_problem(text: String) -> String:
    """Why `text` is not an IPv4 range of the file header's form, or empty
    if it is."""
    var base = 0
    var prefix = 0
    return _parse(text, base, prefix)


def is_private(base: Int, prefix: Int) -> Bool:
    """True iff the range lies inside 10.0.0.0/8, 172.16.0.0/12 or
    192.168.0.0/16."""
    if prefix >= 8 and (base >> 24) == 10:
        return True
    if prefix >= 12 and (base >> 20) == 0xAC1:
        return True
    return prefix >= 16 and (base >> 16) == 0xC0A8


def contains(outer_base: Int, outer_prefix: Int, base: Int, prefix: Int) -> Bool:
    """True iff the range (`base`, `prefix`) lies inside the outer one."""
    if prefix < outer_prefix:
        return False
    var shift = 32 - outer_prefix
    return (base >> shift) == (outer_base >> shift)


def overlaps(a_base: Int, a_prefix: Int, b_base: Int, b_prefix: Int) -> Bool:
    """True iff the two ranges share an address (one holds the other)."""
    var shift = 32 - min(a_prefix, b_prefix)
    return (a_base >> shift) == (b_base >> shift)


def _no_uses(r: Resource, what: String, mut out: List[Finding]):
    if len(r.uses) > 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("uses"),
                what + String(" runs as no identity, so it has no uses lines; it is only referred to"),
            )
        )


def _network_findings(r: Resource, mut out: List[Finding]):
    var cidr = r.network.value().ipv4_cidr.copy()
    var path = String("network.ipv4_cidr")
    if cidr.byte_length() == 0:
        out.append(Finding(FINDING_GRAPH, r.id, path, String("no range: write the network's IPv4 range, \"a.b.c.d/n\"")))
        return
    var base = 0
    var prefix = 0
    var why = _parse(cidr, base, prefix)
    if why.byte_length() > 0:
        out.append(Finding(FINDING_GRAPH, r.id, path, why))
        return
    if not is_private(base, prefix):
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                path,
                String("\"") + cidr
                + String("\" is not a private range: a network lies inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16"),
            )
        )


def _network_range_of(resources: List[Resource], id: String, mut base: Int, mut prefix: Int) -> Bool:
    """The range of network `id` of the list, when it is a network with a
    range of the right form (else False: a finding of its own)."""
    for i in range(len(resources)):
        if resources[i].id == id and Bool(resources[i].network):
            return _parse(resources[i].network.value().ipv4_cidr, base, prefix).byte_length() == 0
    return False


def _subnet_range(r: Resource, mut net: String, mut base: Int, mut prefix: Int) -> Bool:
    """The network id and the range of subnet `r`, when both are written and
    of the right form."""
    ref s = r.subnet.value()
    if not s.network or s.network.value()._oneof0_case != 0:
        return False
    net = s.network.value().resource.copy()
    return _parse(s.ipv4_cidr, base, prefix).byte_length() == 0


def _subnet_findings(resources: List[Resource], r: Resource, mut out: List[Finding]):
    ref s = r.subnet.value()
    var has_network = Bool(s.network)
    if not has_network:
        out.append(Finding(FINDING_GRAPH, r.id, String("subnet.network"), String("no network")))
    else:
        check_typed_ref(
            resources, r.id, String("subnet.network"), s.network.value(), FIELD_NETWORK, String("network"), out
        )
    var path = String("subnet.ipv4_cidr")
    var base = 0
    var prefix = 0
    var ok = False
    if s.ipv4_cidr.byte_length() == 0:
        out.append(Finding(FINDING_GRAPH, r.id, path, String("no range: write the subnet's IPv4 range, \"a.b.c.d/n\"")))
    else:
        var why = _parse(s.ipv4_cidr, base, prefix)
        if why.byte_length() > 0:
            out.append(Finding(FINDING_GRAPH, r.id, path, why))
        else:
            ok = True
    if s.zone:
        var z = Int(s.zone.value())
        if z < ZONE_MIN or z > ZONE_MAX:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    r.id,
                    String("subnet.zone"),
                    String("zone ") + String(z) + String(" is not a zone: a zone is from ") + String(ZONE_MIN)
                    + String(" to ") + String(ZONE_MAX) + String(" (unset: no zone named)"),
                )
            )
    if not ok or not has_network or s.network.value()._oneof0_case != 0:
        return
    var net = s.network.value().resource.copy()
    if field_of_id(resources, net) != FIELD_NETWORK:
        return
    var nbase = 0
    var nprefix = 0
    if _network_range_of(resources, net, nbase, nprefix) and not contains(nbase, nprefix, base, prefix):
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                path,
                String("\"") + s.ipv4_cidr + String("\" is not inside the range of network \"") + net
                + String("\", \"") + ipv4_text(nbase, nprefix) + String("\""),
            )
        )
        return
    for i in range(len(resources)):
        ref o = resources[i]
        if o.id == r.id:
            break
        if not o.subnet:
            continue
        var onet = String("")
        var obase = 0
        var oprefix = 0
        if not _subnet_range(o, onet, obase, oprefix) or onet != net:
            continue
        if overlaps(base, prefix, obase, oprefix):
            out.append(
                Finding(
                    FINDING_GRAPH,
                    r.id,
                    path,
                    String("\"") + s.ipv4_cidr + String("\" overlaps subnet \"") + o.id + String("\" (\"")
                    + o.subnet.value().ipv4_cidr + String("\") of the same network \"") + net + String("\""),
                )
            )
            return


def network_findings(resources: List[Resource], field: Int, r: Resource) -> List[Finding]:
    """Every graph finding of the network resource `r` (body field
    `field`)."""
    var out = List[Finding]()
    if field == FIELD_NETWORK:
        _no_uses(r, String("a network"), out)
        _network_findings(r, out)
    elif field == FIELD_SUBNET:
        _no_uses(r, String("a subnet"), out)
        _subnet_findings(resources, r, out)
    elif field == FIELD_IP_ADDRESS:
        _no_uses(r, String("an IP address"), out)
    return out^


def service_network_findings(resources: List[Resource], r: Resource) -> List[Finding]:
    """A service's `network`, when written, names a `subnet` of the list;
    nothing for any other resource."""
    var out = List[Finding]()
    if not Bool(r.service) or not Bool(r.service.value().network):
        return out^
    check_typed_ref(
        resources, r.id, String("service.network"), r.service.value().network.value(), FIELD_SUBNET, String("subnet"), out
    )
    return out^


def service_subnet(r: Resource) -> String:
    """The subnet a service's `network` names, or empty (for a service
    without one, and for any other type)."""
    if Bool(r.service) and Bool(r.service.value().network):
        return r.service.value().network.value().resource.copy()
    return String("")
