# =============================================================================
# kci_cloud_fake/dns.mojo: how the fake clouds lower the NAME types (DNS zone,
# DNS record, certificate), and the limits a shape puts on a certificate.
# =============================================================================
#
# A name resource runs as no identity: it holds no `identity` role and no
# grant (validate refuses `uses` on it), and it accepts no verb. The roles
# per shape are in shapes.mojo. Every node below exposes its output through
# an `out.<OUTPUT>` desired field (how the node behaves, not state: never in
# a digest; nodes.mojo).
#
#   * zone   -> `<id>/zone`: the field `domain` (the zone's name), and
#               `out.NAME` = `<id>-zone`.
#   * record -> `<id>/record`, of the shape's record kind (`<TYPE>` in it
#               replaced by the record type): an INPUT on the zone's NAME
#               (`zone`; kci resolves the zone's id to `<zone>/zone`, so the
#               record is created after its zone), the fields `name`, `type`,
#               each literal value as `value.<i>`, `ttl` (`<seconds>s`, the
#               versioned default 300 when unwritten); a CNAME's reference as
#               an INPUT on the producer's HOST at `value.<i>` (so the record
#               waits for, and follows, the service it names); and
#               `out.HOST` = the record's name.
#   * certificate -> `<id>/cert`: an input on the zone's NAME (`zone`), the
#               fields `domain.<i>`, and `out.NAME` = `<id>-cert`. On a shape
#               with a `dnsauth` row (gcp) it is preceded by `<id>/dnsauth`
#               (the field `domain`: the first name without its `*.`) and
#               `<id>/authrec` (the record that authorization asks for: an
#               input on the zone's NAME, the field `for`), and the
#               certificate depends on both.
#   A zone or a certificate with the author's cloud name (`physical_name`)
#   exposes that name as its NAME instead of `<id>-zone` / `<id>-cert`.
#
# LIMITS (`dns_limits`, the shapes' own; they cite this package):
#   * on a shape with a `dnsauth` row, this lowering emits one
#     authorization per certificate (the cloud accepts several; one per
#     certificate is the fake's choice), and one authorization covers one
#     name and its wildcard: every domain is the first name (without `*.`)
#     or `*.` and it;
#   * on a shape with `single_name_certificates` (azure), a certificate has
#     one domain, and it is not a wildcard.
# =============================================================================

from kci_reconciler import InputRef
from kci_cloud import (
    FIELD_CERTIFICATE,
    FIELD_DNS_RECORD,
    FIELD_DNS_ZONE,
    FINDING_LIMIT,
    Finding,
    LoweredNode,
    Setting,
    body_is,
    record_type_word,
    ttl_seconds,
)
from kci_resource_proto.resource import Resource

from kci_cloud_fake.limits import FAKE_CITATION
from kci_cloud_fake.metadata import fake_physical_name
from kci_cloud_fake.shapes import (
    ProviderShape,
    RECORD_TYPE_SLOT,
    ROLE_AUTH_RECORD,
    ROLE_CERT,
    ROLE_DNS_AUTH,
    ROLE_RECORD,
    ROLE_ZONE,
)


def fake_zone_name(resource_id: String) -> String:
    return resource_id + String("-zone")


def fake_certificate_name(resource_id: String) -> String:
    return resource_id + String("-cert")


def _no_uses(r: Resource, what: String) raises:
    if len(r.uses) > 0:
        raise Error(String("fake: ") + what + String(" \"") + r.id + String("\" has uses lines; validate refuses them"))


def _zone_input(zone: String, field: String) -> InputRef:
    # The zone by its resource id: kci resolves its primary node.
    return InputRef(zone, String("NAME"), field)


def lower_zone(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A zone's one role, with its domain."""
    _no_uses(r, String("dns_zone"))
    var fields = List[Setting]()
    fields.append(Setting(String("domain"), r.dns_zone.value().name.copy()))
    var named = fake_physical_name(r)
    fields.append(Setting(String("out.NAME"), named if named.byte_length() > 0 else fake_zone_name(r.id)))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_ZONE),
            r.id,
            shape.kind_of(FIELD_DNS_ZONE, String(ROLE_ZONE)),
            List[String](),
            List[InputRef](),
            fields^,
        )
    )
    return out^


def record_kind(shape: ProviderShape, type_word: String) raises -> String:
    """The shape's record kind, with `<TYPE>` replaced by `type_word`."""
    var kind = shape.kind_of(FIELD_DNS_RECORD, String(ROLE_RECORD))
    var at = kind.find(String(RECORD_TYPE_SLOT))
    if at < 0:
        return kind^
    return String(kind[byte=0:at]) + type_word + String(
        kind[byte = at + String(RECORD_TYPE_SLOT).byte_length() : kind.byte_length()]
    )


def lower_record(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A record's one role: its record set (see the file header)."""
    _no_uses(r, String("dns_record"))
    ref d = r.dns_record.value()
    var type_word = record_type_word(d.type.value)
    var fields = List[Setting]()
    var refs = List[InputRef]()
    refs.append(_zone_input(d.zone.value().resource, String("zone")))
    fields.append(Setting(String("name"), d.name.copy()))
    fields.append(Setting(String("type"), type_word.copy()))
    for i in range(len(d.values)):
        ref v = d.values[i]
        var field = String("value.") + String(i)
        if v._oneof0_case == 3:
            # The producer by its resource id: kci resolves its primary node.
            refs.append(InputRef(v.ref_.value().resource.copy(), String("HOST"), field^))
        else:
            fields.append(Setting(field^, v.literal.value().copy()))
    fields.append(Setting(String("ttl"), String(ttl_seconds(r)) + String("s")))
    fields.append(Setting(String("out.HOST"), d.name.copy()))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_RECORD),
            r.id,
            record_kind(shape, type_word),
            List[String](),
            refs^,
            fields^,
        )
    )
    return out^


def _base_name(domain: String) -> String:
    """`domain` without a leading `*.`."""
    if domain.startswith("*."):
        return String(domain[byte = 2 : domain.byte_length()])
    return domain.copy()


def lower_certificate(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A certificate's roles (see the file header)."""
    _no_uses(r, String("certificate"))
    ref c = r.certificate.value()
    var zone = c.zone.value().resource.copy()
    var out = List[LoweredNode]()
    var deps = List[String]()
    if shape.has(FIELD_CERTIFICATE, String(ROLE_DNS_AUTH)):
        var auth = r.id + String("/") + String(ROLE_DNS_AUTH)
        var base = _base_name(c.domains[0]) if len(c.domains) > 0 else String("")
        var af = List[Setting]()
        af.append(Setting(String("domain"), base.copy()))
        out.append(
            LoweredNode(
                auth.copy(),
                r.id,
                shape.kind_of(FIELD_CERTIFICATE, String(ROLE_DNS_AUTH)),
                List[String](),
                List[InputRef](),
                af^,
            )
        )
        var rec = r.id + String("/") + String(ROLE_AUTH_RECORD)
        var rdeps = List[String]()
        rdeps.append(auth.copy())
        var rrefs = List[InputRef]()
        rrefs.append(_zone_input(zone, String("zone")))
        var rf = List[Setting]()
        rf.append(Setting(String("for"), base^))
        out.append(
            LoweredNode(
                rec.copy(),
                r.id,
                shape.kind_of(FIELD_CERTIFICATE, String(ROLE_AUTH_RECORD)),
                rdeps^,
                rrefs^,
                rf^,
            )
        )
        deps.append(auth^)
        deps.append(rec^)
    var refs = List[InputRef]()
    refs.append(_zone_input(zone, String("zone")))
    var fields = List[Setting]()
    for i in range(len(c.domains)):
        fields.append(Setting(String("domain.") + String(i), c.domains[i].copy()))
    var named = fake_physical_name(r)
    fields.append(Setting(String("out.NAME"), named if named.byte_length() > 0 else fake_certificate_name(r.id)))
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_CERT),
            r.id,
            shape.kind_of(FIELD_CERTIFICATE, String(ROLE_CERT)),
            deps^,
            refs^,
            fields^,
        )
    )
    return out^


def dns_limits(r: Resource, shape: ProviderShape, cloud: String, mut out: List[Finding]):
    """The limits a shape puts on a certificate (see the file header)."""
    if not body_is(r, FIELD_CERTIFICATE):
        return
    ref c = r.certificate.value()
    var n = len(c.domains)
    if n == 0:
        return  # a graph finding
    if shape.single_name_certificates:
        if n > 1:
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("certificate.domains"),
                    String("on cloud \"")
                    + cloud
                    + String("\" a certificate covers one name; write one certificate per name"),
                    String(FAKE_CITATION),
                )
            )
        if c.domains[0].startswith("*."):
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("certificate.domains[0]"),
                    String("on cloud \"") + cloud + String("\" a certificate cannot be a wildcard"),
                    String(FAKE_CITATION),
                )
            )
    if shape.has(FIELD_CERTIFICATE, String(ROLE_DNS_AUTH)):
        var base = _base_name(c.domains[0])
        for i in range(1, n):
            if c.domains[i] == base or c.domains[i] == String("*.") + base:
                continue
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("certificate.domains[") + String(i) + String("]"),
                    String("on cloud \"")
                    + cloud
                    + String("\" a certificate is validated by one DNS authorization, for one name and its")
                    + String(" wildcard; \"")
                    + c.domains[i]
                    + String("\" is neither \"")
                    + base
                    + String("\" nor \"*.")
                    + base
                    + String("\""),
                    String(FAKE_CITATION),
                )
            )
