# =============================================================================
# kci_cloud/dns.mojo: the rules of the NAME primitives (DNS zone, DNS record,
# certificate), and the record's versioned TTL.
# =============================================================================
#
# GRAPH findings, true on every cloud, that validate collects for a name
# resource (`dns_findings`):
#   * a DNS zone, a DNS record and a certificate run as no identity, so none
#     has `uses` lines;
#   * every DNS name (a zone's `name`, a record's `name`, a CNAME's or an
#     MX's host, a certificate's `domains`) is lowercase, with no trailing
#     dot, at most 253 bytes, of at least two labels, each label 1 to 63
#     letters, digits and inner hyphens (`dns_name_problem`). A first label
#     `*` (a wildcard) is allowed in a record's `name` and a certificate's
#     domain only;
#   * a zone: one zone per domain in a list (two zones for one domain could
#     not both be the one the registrar points at);
#   * a record: its `zone` names a `dns_zone` of the list (the resource
#     itself, no output), and its `name` is that zone's name or below it; a
#     type is written (A, AAAA, CNAME, TXT or MX); at least one value, and a
#     CNAME exactly one and never at the zone's own name (it would hide the
#     zone's other records); a literal of its type (an A a dotted IPv4
#     address; an AAAA two or more colons and only hex digits, colons and
#     dots, at most 45 bytes; a CNAME a DNS name; a TXT 1 to 255 bytes; an MX
#     "<preference 0 to 65535> <DNS name>"); a reference only on a CNAME,
#     and only to a HOST (`values.check_value_ref` checks the producer); a
#     parameter or an empty value refused as in `env`; its `ttl`, when
#     written, whole seconds from 60 to 86400; one record set per (zone,
#     name, type), and a CNAME alone at its name (both reported on the later
#     record);
#   * a certificate: its `zone` as a record's; from 1 to 10 domains, each in
#     the zone, none listed twice.
#
# THE VERSIONED DEFAULT. An unwritten `ttl` is 300 seconds
# (`TTL_DEFAULT_SECONDS`) on every cloud. kci writes it out, so an author's
# file means the same thing whichever cloud's own default differs.
# =============================================================================

from kci_resource_proto.refs import Ref
from kci_resource_proto.resource import Resource

from kci_cloud.compose_refs import no_ref
from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import (
    Catalog,
    FIELD_CERTIFICATE,
    FIELD_DNS_RECORD,
    FIELD_DNS_ZONE,
)
from kci_cloud.messaging import check_typed_ref
from kci_cloud.values import check_value, check_value_ref


comptime TTL_DEFAULT_SECONDS: Int = 300
"""What an unwritten `DnsRecord.ttl` means."""
comptime TTL_MIN_SECONDS: Int = 60
comptime TTL_MAX_SECONDS: Int = 86400
comptime CERTIFICATE_DOMAINS_MAX: Int = 10
comptime DNS_NAME_MAX_BYTES: Int = 253
comptime DNS_LABEL_MAX_BYTES: Int = 63
comptime TXT_VALUE_MAX_BYTES: Int = 255
comptime MX_PREFERENCE_MAX: Int = 65535

comptime RECORD_A: Int = 1
comptime RECORD_AAAA: Int = 2
comptime RECORD_CNAME: Int = 3
comptime RECORD_TXT: Int = 4
comptime RECORD_MX: Int = 5


def record_type_word(t: Int) -> String:
    """The `RecordType` name of `t` (its number when it has none)."""
    if t == RECORD_A:
        return String("A")
    if t == RECORD_AAAA:
        return String("AAAA")
    if t == RECORD_CNAME:
        return String("CNAME")
    if t == RECORD_TXT:
        return String("TXT")
    if t == RECORD_MX:
        return String("MX")
    return String(t)


def ttl_seconds(r: Resource) -> Int:
    """DNS record `r`'s TTL in seconds: the written one, else the versioned
    default."""
    ref d = r.dns_record.value()
    if d.ttl:
        return Int(d.ttl.value().seconds)
    return TTL_DEFAULT_SECONDS


def _is_label_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("-"))
    )


def _label_ok(label: String) -> Bool:
    var n = label.byte_length()
    if n == 0 or n > DNS_LABEL_MAX_BYTES:
        return False
    var bytes = label.as_bytes()
    if bytes[0] == UInt8(ord("-")) or bytes[n - 1] == UInt8(ord("-")):
        return False
    for c in bytes:
        if not _is_label_byte(c):
            return False
    return True


def dns_name_problem(name: String, wildcard: Bool) -> String:
    """Why `name` is not a DNS name (see the file header); empty when it is.
    `wildcard` allows a first label `*`."""
    var head = String("\"") + name + String("\" is not a DNS name: ")
    if name.byte_length() == 0:
        return String("no name")
    if name.byte_length() > DNS_NAME_MAX_BYTES:
        return head + String("it is longer than ") + String(DNS_NAME_MAX_BYTES) + String(" bytes")
    var parts = name.split(".")
    if len(parts) < 2:
        return head + String("it has fewer than two labels")
    for i in range(len(parts)):
        var label = String(parts[i])
        if label == "*":
            if i == 0 and wildcard:
                continue
            return head + String("a wildcard `*` is only the first label of a record name or a certificate domain")
        if not _label_ok(label):
            return (
                head
                + String("label \"")
                + label
                + String("\" is not 1 to 63 lowercase letters, digits and inner hyphens")
            )
    return String("")


def in_zone(name: String, zone: String) -> Bool:
    """`name` is the zone's own name or a name below it."""
    return name == zone or name.endswith(String(".") + zone)


def zone_name_of(resources: List[Resource], id: String) -> String:
    """The domain of the `dns_zone` resource `id`, or empty when `id` is not
    one."""
    for i in range(len(resources)):
        if resources[i].id == id and resources[i].dns_zone:
            return resources[i].dns_zone.value().name.copy()
    return String("")


def _ipv4(s: String) -> Bool:
    var parts = s.split(".")
    if len(parts) != 4:
        return False
    for i in range(4):
        var p = String(parts[i])
        var n = p.byte_length()
        if n == 0 or n > 3:
            return False
        var v = 0
        for c in p.as_bytes():
            if c < UInt8(ord("0")) or c > UInt8(ord("9")):
                return False
            v = v * 10 + Int(c - UInt8(ord("0")))
        if v > 255 or (n > 1 and p.as_bytes()[0] == UInt8(ord("0"))):
            return False
    return True


def _ipv6_shaped(s: String) -> Bool:
    if s.byte_length() > 45:
        return False
    var colons = 0
    for c in s.as_bytes():
        if c == UInt8(ord(":")):
            colons += 1
        elif not (
            (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or (c >= UInt8(ord("a")) and c <= UInt8(ord("f")))
            or c == UInt8(ord("."))
        ):
            return False
    return colons >= 2


def _mx_ok(s: String) -> Bool:
    var sp = s.find(" ")
    if sp <= 0 or sp > 5:
        return False
    var v = 0
    for c in String(s[byte=0:sp]).as_bytes():
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return False
        v = v * 10 + Int(c - UInt8(ord("0")))
    if v > MX_PREFERENCE_MAX:
        return False
    return dns_name_problem(String(s[byte = sp + 1 : s.byte_length()]), False).byte_length() == 0


def _literal_problem(t: Int, lit: String) -> String:
    """Why `lit` is not a value of a record of type `t`; empty when it is."""
    var q = String("\"") + lit + String("\"")
    if t == RECORD_A and not _ipv4(lit):
        return q + String(" is not an IPv4 address")
    if t == RECORD_AAAA and not _ipv6_shaped(lit):
        return q + String(" is not an IPv6 address")
    if t == RECORD_CNAME:
        return dns_name_problem(lit, False)
    if t == RECORD_TXT and (lit.byte_length() == 0 or lit.byte_length() > TXT_VALUE_MAX_BYTES):
        return String("a TXT value is 1 to ") + String(TXT_VALUE_MAX_BYTES) + String(" bytes")
    if t == RECORD_MX and not _mx_ok(lit):
        return q + String(" is not an MX value \"<preference 0 to 65535> <DNS name>\"")
    return String("")


def _zone_of(
    resources: List[Resource], id: String, path: String, has: Bool, zone: Ref, mut out: List[Finding]
) -> String:
    """The domain of the zone a record or a certificate names, or empty after
    a finding."""
    if not has:
        out.append(Finding(FINDING_GRAPH, id, path, String("no zone")))
        return String("")
    var before = len(out)
    check_typed_ref(resources, id, path, zone, FIELD_DNS_ZONE, String("dns_zone"), out)
    if len(out) != before:
        return String("")
    return zone_name_of(resources, zone.resource)


def _not_in_zone(id: String, path: String, name: String, zone_id: String, zone: String) -> Finding:
    return Finding(
        FINDING_GRAPH,
        id,
        path,
        String("\"") + name + String("\" is not in zone \"") + zone_id + String("\" (") + zone + String(")"),
    )


def _zone_findings(resources: List[Resource], r: Resource, mut out: List[Finding]):
    var name = r.dns_zone.value().name.copy()
    var bad = dns_name_problem(name, False)
    if bad.byte_length() > 0:
        out.append(Finding(FINDING_GRAPH, r.id, String("dns_zone.name"), bad))
        return
    for i in range(len(resources)):
        ref o = resources[i]
        if o.id == r.id:
            break
        if o.dns_zone and o.dns_zone.value().name == name:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    r.id,
                    String("dns_zone.name"),
                    String("zone \"")
                    + o.id
                    + String("\" already holds \"")
                    + name
                    + String("\"; a domain has one zone in a list"),
                )
            )
            break


def _record_value_findings(
    catalog: Catalog, resources: List[Resource], r: Resource, t: Int, mut out: List[Finding]
):
    ref d = r.dns_record.value()
    var id = r.id.copy()
    if len(d.values) == 0:
        out.append(Finding(FINDING_GRAPH, id, String("dns_record.values"), String("no values")))
        return
    if t == RECORD_CNAME and len(d.values) > 1:
        out.append(Finding(FINDING_GRAPH, id, String("dns_record.values"), String("a CNAME has exactly one value")))
    for i in range(len(d.values)):
        ref v = d.values[i]
        var path = String("dns_record.values[") + String(i) + String("]")
        if v._oneof0_case == 3:
            if t != RECORD_CNAME:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        path,
                        String("a reference is only a CNAME's value (the HOST it follows); the values of ")
                        + String("a ")
                        + record_type_word(t)
                        + String(" record are literals"),
                    )
                )
                continue
            var before = len(out)
            check_value_ref(catalog, resources, id, path, v.ref_.value(), out)
            if len(out) == before and v.ref_.value().standard.value().json_name() != "HOST":
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        path,
                        String("a CNAME follows a HOST, not ") + v.ref_.value().standard.value().json_name(),
                    )
                )
            continue
        if v._oneof0_case != 1:
            check_value(catalog, resources, id, path, v, out)
            continue
        var bad = _literal_problem(t, v.literal.value())
        if bad.byte_length() > 0:
            out.append(Finding(FINDING_GRAPH, id, path, bad))


def _record_findings(catalog: Catalog, resources: List[Resource], r: Resource, mut out: List[Finding]):
    ref d = r.dns_record.value()
    var id = r.id.copy()
    var zone = _zone_of(
        resources,
        id,
        String("dns_record.zone"),
        Bool(d.zone),
        d.zone.value().copy() if d.zone else no_ref(),
        out,
    )
    var bad = dns_name_problem(d.name, True)
    if bad.byte_length() > 0:
        out.append(Finding(FINDING_GRAPH, id, String("dns_record.name"), bad))
    elif zone.byte_length() > 0 and not in_zone(d.name, zone):
        out.append(_not_in_zone(id, String("dns_record.name"), d.name, d.zone.value().resource, zone))
    var t = d.type.value
    if t < RECORD_A or t > RECORD_MX:
        out.append(
            Finding(FINDING_GRAPH, id, String("dns_record.type"), String("a record type: A, AAAA, CNAME, TXT or MX"))
        )
        return
    if t == RECORD_CNAME and zone.byte_length() > 0 and d.name == zone:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                String("dns_record.name"),
                String("a CNAME is never at its zone's own name: it would hide the zone's other records"),
            )
        )
    _record_value_findings(catalog, resources, r, t, out)
    if d.ttl:
        var secs = Int(d.ttl.value().seconds)
        if Int(d.ttl.value().nanos) != 0 or secs < TTL_MIN_SECONDS or secs > TTL_MAX_SECONDS:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    String("dns_record.ttl"),
                    String("whole seconds from ")
                    + String(TTL_MIN_SECONDS)
                    + String(" to ")
                    + String(TTL_MAX_SECONDS)
                    + String("; unset means ")
                    + String(TTL_DEFAULT_SECONDS),
                )
            )
    if not d.zone:
        return
    # One record set per (zone, name, type), and a CNAME alone at its name:
    # reported once, on the later record.
    for i in range(len(resources)):
        ref o = resources[i]
        if o.id == id:
            break
        if not o.dns_record or not o.dns_record.value().zone:
            continue
        ref od = o.dns_record.value()
        if od.zone.value().resource != d.zone.value().resource or od.name != d.name:
            continue
        var ot = od.type.value
        if ot == t:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    String("dns_record"),
                    String("\"")
                    + o.id
                    + String("\" already holds the ")
                    + record_type_word(t)
                    + String(" records of \"")
                    + d.name
                    + String("\"; one record set per name and type"),
                )
            )
            break
        if ot == RECORD_CNAME or t == RECORD_CNAME:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    String("dns_record"),
                    String("\"")
                    + o.id
                    + String("\" holds the ")
                    + record_type_word(ot)
                    + String(" records of \"")
                    + d.name
                    + String("\"; a CNAME is the only record set at its name"),
                )
            )
            break


def _certificate_findings(resources: List[Resource], r: Resource, mut out: List[Finding]):
    ref c = r.certificate.value()
    var id = r.id.copy()
    var zone = _zone_of(
        resources,
        id,
        String("certificate.zone"),
        Bool(c.zone),
        c.zone.value().copy() if c.zone else no_ref(),
        out,
    )
    var n = len(c.domains)
    if n == 0 or n > CERTIFICATE_DOMAINS_MAX:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                String("certificate.domains"),
                String("from 1 to ") + String(CERTIFICATE_DOMAINS_MAX) + String(" domains, not ") + String(n),
            )
        )
    for i in range(n):
        var path = String("certificate.domains[") + String(i) + String("]")
        ref name = c.domains[i]
        var bad = dns_name_problem(name, True)
        if bad.byte_length() > 0:
            out.append(Finding(FINDING_GRAPH, id, path, bad))
            continue
        if zone.byte_length() > 0 and not in_zone(name, zone):
            out.append(_not_in_zone(id, path, name, c.zone.value().resource, zone))
        for k in range(i):
            if c.domains[k] == name:
                out.append(Finding(FINDING_GRAPH, id, path, String("\"") + name + String("\" is listed twice")))
                break


def dns_findings(catalog: Catalog, resources: List[Resource], field: Int, r: Resource) -> List[Finding]:
    """Every graph finding of the name resource `r` (a `dns_zone`, a
    `dns_record` or a `certificate`, by its body `field`) in `resources`;
    empty for any other type."""
    var out = List[Finding]()
    var name: String
    if field == FIELD_DNS_ZONE:
        name = String("dns_zone")
        _zone_findings(resources, r, out)
    elif field == FIELD_DNS_RECORD:
        name = String("dns_record")
        _record_findings(catalog, resources, r, out)
    elif field == FIELD_CERTIFICATE:
        name = String("certificate")
        _certificate_findings(resources, r, out)
    else:
        return out^
    if len(r.uses) > 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("uses"),
                String("a ") + name + String(" runs as no identity, so it cannot use another resource"),
            )
        )
    return out^
