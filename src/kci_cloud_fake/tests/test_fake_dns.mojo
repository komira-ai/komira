# =============================================================================
# test_fake_dns.mojo
# =============================================================================
#
# The name primitives (DNS zone, DNS record, certificate) on the fake clouds.
# One graph throughout: a service `api` (internal; its identity writes the
# cell's METRICS, a `uses` line the kit turns off); the zone `site`
# (example.com); the CNAME `www` (www.example.com, following `api`'s HOST,
# TTL 600 s); the A record `apex` (example.com, two addresses, the default
# TTL); and the certificate `tls` for example.com in `site`.
#
# 1. A GOLDEN LOWERING PER SHAPE (generic, aws, gcp, azure): per name node
#    its kind, wanted, retention, dependencies, inputs and desired fields.
#    A zone is one node with its domain; a record one node of its type
#    (azure: the ARM type names it) that reads the zone's NAME and, for the
#    CNAME, `api`'s HOST as inputs, with the versioned TTL written out; a
#    certificate one node reading the zone's NAME, and on gcp its DNS
#    authorization and that authorization's record before it. The JSON of
#    the generic lowering of a zone alone is pinned.
# 2. THE KIT ON EVERY HOSTING SHAPE: the kci_cloud conformance kit (twelve
#    steps) on generic, aws, gcp and azure, each under a random id,
#    tampering with `www/record`; the changed graph moves the CNAME's TTL.
# 3. AFTER AN APPLY: the CNAME is bound to `api`'s HOST as the fake writes
#    it (`api.fake`) and created after both the zone and `api/run`; the
#    certificate after the zone; a TTL change is an update of the record
#    alone; a service reading the record's HOST, the zone's NAME and the
#    certificate's NAME gets the values the nodes expose; a destroy keeps a
#    KEEP zone (marked `retain`) and deletes the rest.
# 4. ONPREM DECLARES THE THREE NOT_YET, naming Q18 (zone, record) and Q19
#    (certificate), and refuses the graph before anything is created.
# 5. THE CERTIFICATE LIMITS PER SHAPE: azure refuses a second name and a
#    wildcard; gcp refuses a name that is neither the first nor its
#    wildcard; generic and aws accept both graphs.
# 6. FAKE-LIMITED DECLARES THE THREE NOT_YET, and refuses one (coverage).
# 7. `uses` ON A NAME never reaches a lowering: the fake's own lowering,
#    asked directly, refuses it for each of the three.
# 8. THE RECORD KIND: `<TYPE>` in a shape's record kind is replaced by the
#    record type; a kind without it is kept.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    Provenance,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_cloud import (
    Feed,
    Firing,
    Finding,
    GrantEdge,
    FIELD_CERTIFICATE,
    FIELD_DNS_RECORD,
    FIELD_DNS_ZONE,
    NOT_YET,
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    LoweredNode,
    apply_resources,
    describe,
    destroy_resources,
    lower_data,
    lowering_json,
    plan_resources,
    retention_name,
    run_conformance,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, FakeLimitedCloud, ProviderShape, record_kind


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _graph(
    ttl: String = String("600"),
    metrics: Bool = True,
    zone_retention: String = String("DELETE"),
    domains: String = String('"example.com"'),
    reader: Bool = False,
) -> String:
    var uses = String('"uses":[{"cell":"METRICS","access":"WRITE"}],') if metrics else String("")
    var j = (
        String('{"resource":[')
        + String('{"id":"api",') + uses
        + String('"service":{"image":{"digest":"sha256:a1"},"internal":{},"scale":{"min":1,"max":2}}},')
        + String('{"id":"site","retention":"') + zone_retention + String('","dnsZone":{"name":"example.com"}},')
        + String('{"id":"www","dnsRecord":{"name":"www.example.com","zone":{"resource":"site"},"type":"CNAME",')
        + String('"values":[{"ref":{"resource":"api","standard":"HOST"}}],"ttl":"') + ttl + String('s"}},')
        + String('{"id":"apex","dnsRecord":{"name":"example.com","zone":{"resource":"site"},"type":"A",')
        + String('"values":[{"literal":"192.0.2.1"},{"literal":"192.0.2.2"}]}},')
        + String('{"id":"tls","certificate":{"domains":[') + domains + String('],"zone":{"resource":"site"}}}')
    )
    if reader:
        j += String(',{"id":"web","service":{"image":{"digest":"sha256:a1"},"internal":{},"env":{')
        j += String('"CERT":{"ref":{"resource":"tls","standard":"NAME"}},')
        j += String('"SITE":{"ref":{"resource":"www","standard":"HOST"}},')
        j += String('"ZONE":{"ref":{"resource":"site","standard":"NAME"}}}}}')
    return j + String("]}")


def _hosting_shapes() -> List[ProviderShape]:
    """The fake's own shape, then the built-in clouds that host names."""
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    return l^


# ---- 1. a golden lowering per shape ------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per name node (owner site, www, apex or tls): id, kind,
    wanted (+ or -), retention, dependencies (`<`), inputs
    (`[producer.OUTPUT>field]`) and desired fields (`{}`)."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        if n.owner != "site" and n.owner != "www" and n.owner != "apex" and n.owner != "tls":
            continue
        s += n.id + String(" ") + n.kind + String(" ") + (String("+") if n.wanted else String("-"))
        s += String(" ") + retention_name(n.retention)
        for k in range(len(n.depends_on)):
            s += (String(" <") if k == 0 else String(",")) + n.depends_on[k]
        for k in range(len(n.inputs)):
            ref inp = n.inputs[k]
            s += (String(" [") if k == 0 else String(",")) + inp.producer + String(".") + inp.output
            s += String(">") + inp.field
            if k == len(n.inputs) - 1:
                s += String("]")
        s += String(" {")
        for k in range(len(n.desired)):
            if k > 0:
                s += String(";")
            s += n.desired[k].key + String("=") + n.desired[k].value
        s += String("}\n")
    return s^


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-n7"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_graph(zone_retention=String("KEEP")))))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


def _golden(zone: String, cname: String, a: String, cert: String, auth: String = String(""), rec: String = String("")) -> String:
    var s = String("site/zone ") + zone + String(" + keep {domain=example.com;out.NAME=site-zone}\n")
    s += String("www/record ") + cname + String(" + delete [site/zone.NAME>zone,api/run.HOST>value.0]")
    s += String(" {name=www.example.com;type=CNAME;ttl=600s;out.HOST=www.example.com}\n")
    s += String("apex/record ") + a + String(" + delete [site/zone.NAME>zone]")
    s += String(" {name=example.com;type=A;value.0=192.0.2.1;value.1=192.0.2.2;ttl=300s;out.HOST=example.com}\n")
    var deps = String("")
    if auth.byte_length() > 0:
        s += String("tls/dnsauth ") + auth + String(" + delete {domain=example.com}\n")
        s += String("tls/authrec ") + rec + String(" + delete <tls/dnsauth [site/zone.NAME>zone] {for=example.com}\n")
        deps = String(" <tls/dnsauth,tls/authrec")
    s += String("tls/cert ") + cert + String(" + delete") + deps
    s += String(" [site/zone.NAME>zone] {domain.0=example.com;out.NAME=tls-cert}\n")
    return s^


def test_golden_lowering_per_shape() raises:
    """Catches: a name role missing, extra or of the wrong provider kind on
    any shape; an azure record kind that does not name its type; a record
    that does not read its zone's NAME (it could be created before the
    zone) or a CNAME that does not read its producer's HOST (it would not
    follow the service); the TTL default not written out; the values
    reordered or merged; a gcp certificate without its authorization and
    record, or created before them; a zone's KEEP not carried."""
    assert_equal(
        _lowered(ProviderShape.generic()),
        _golden(String("zone"), String("record"), String("record"), String("certificate")),
        "generic",
    )
    assert_equal(
        _lowered(ProviderShape.aws()),
        _golden(
            String("AWS::Route53::HostedZone"),
            String("AWS::Route53::RecordSet"),
            String("AWS::Route53::RecordSet"),
            String("AWS::CertificateManager::Certificate"),
        ),
        "aws",
    )
    assert_equal(
        _lowered(ProviderShape.gcp()),
        _golden(
            String("dns.googleapis.com/ManagedZone"),
            String("dns.googleapis.com/ResourceRecordSet"),
            String("dns.googleapis.com/ResourceRecordSet"),
            String("certificatemanager.googleapis.com/Certificate"),
            auth=String("certificatemanager.googleapis.com/DnsAuthorization"),
            rec=String("dns.googleapis.com/ResourceRecordSet"),
        ),
        "gcp",
    )
    assert_equal(
        _lowered(ProviderShape.azure()),
        _golden(
            String("Microsoft.Network/dnsZones"),
            String("Microsoft.Network/dnsZones/CNAME"),
            String("Microsoft.Network/dnsZones/A"),
            String("Microsoft.App/managedEnvironments/managedCertificates"),
        ),
        "azure",
    )
    var cloud = FakeCloud()
    assert_equal(
        lowering_json(lower_data(cloud, _list(String('{"resource":[{"id":"site","dnsZone":{"name":"example.com"}}]}')))),
        String('[\n  {"id":"site/zone","owner":"site","kind":"zone","wanted":true,')
        + String('"retention":"delete","depends_on":[],"inputs":[],')
        + String('"desired":{"domain":"example.com","out.NAME":"site-zone"}}\n]'),
    )
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. the kit on every hosting shape --------------------------------------------------------


def test_the_kit_on_every_hosting_shape() raises:
    """Catches: a name node whose create skips the stamp, the retention mark
    or the run-id label; a digest that moves on a re-apply (an output field
    in the digest would); a tampered record not planned as an update; a TTL
    change not an update; a lowering that keys on the cloud's id."""
    var shapes = _hosting_shapes()
    var ids = [String("p-3q"), String("p-w8"), String("p-k2m"), String("p-z0")]
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shapes[s].copy())))
        var cloud = FakeCloud(ids[s], shape=shapes[s].copy())
        try:
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_graph()),
                _list(_graph(String("900"))),
                _list(_graph(String("900"), metrics=False)),
                String("www/record"),
            )
        except e:
            raise Error(shapes[s].name + String(" shape: ") + String(e))
    print("  test_the_kit_on_every_hosting_shape: PASS")


# ---- 3. after an apply ---------------------------------------------------------------------------


def _at(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return i
    return -1


def _digest(cloud: FakeCloud, id: String) raises -> String:
    var at = cloud.store[].find(id)
    assert_true(at >= 0, id + String(" is live"))
    return cloud.store[].digests[at].copy()


def test_after_an_apply() raises:
    """Catches: a CNAME bound to nothing (or to another output) for its
    producer, a record or a certificate created before its zone, a CNAME
    created before the service it follows, a TTL change planned as anything
    but an update of that record alone, an output a node does not expose
    (or exposes with another value), and a KEEP zone deleted by destroy (or
    a DELETE record kept)."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var json = _graph(zone_retention=String("KEEP"), reader=True)
    var a = _done(apply_resources(reg, cloud, _ctx(), _list(json), Creds.none(), st))
    for id in ["www/record", "apex/record", "tls/cert"]:
        assert_true(_at(a, String("site/zone")) < _at(a, String(id)), String(id) + " after its zone")
    assert_true(_at(a, String("api/run")) < _at(a, String("www/record")), "the CNAME after the service")
    var www = _digest(cloud, String("www/record"))
    assert_true(www.find("|value.0=api.fake") >= 0, "the CNAME is bound to api's HOST: " + www)
    assert_true(www.find("|zone=site-zone") >= 0, "the record is bound to its zone's NAME: " + www)
    assert_true(www.find("out.") < 0, "an output is never in a digest: " + www)
    var web = _digest(cloud, String("web/run"))
    for want in ["|service.env.CERT=tls-cert", "|service.env.SITE=www.example.com", "|service.env.ZONE=site-zone"]:
        assert_true(web.find(String(want)) >= 0, String(want) + " in " + web)

    var b = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(String("900"), zone_retention=String("KEEP"), reader=True)), Creds.none(), st))
    for i in range(len(b)):
        var want = VERB_UPDATE if b[i].logical_id == "www/record" else VERB_NOOP
        assert_equal(b[i].verb, want, b[i].logical_id + String(": a TTL change updates its record alone"))

    _ = destroy_resources(reg, cloud, _ctx(), _list(_graph(String("900"), zone_retention=String("KEEP"), reader=True)), Creds.none(), st)
    var labels = cloud.live_labels(String("site/zone"))
    var kept = False
    for i in range(len(labels)):
        if labels[i].key == "kci-retention" and labels[i].value == "retain":
            kept = True
    assert_true(kept, "site/zone is still there, marked kci-retention=retain")
    assert_equal(cloud.live_count(), 1, "only the KEEP zone is left")
    print("  test_after_an_apply: PASS")


# ---- 4. onprem declares the three NOT_YET -------------------------------------------------------


def test_onprem_refuses_names_naming_q18_and_q19() raises:
    """Catches: onprem picking a DNS server or a certificate issuer (it must
    not, until Q18 and Q19 are answered), an absence of the wrong kind or
    reason, a coverage finding missing for one of the four resources, and a
    refusal after a create."""
    var cloud = FakeCloud(String("p-onp"), shape=ProviderShape.onprem())
    assert_true(not cloud.complete(), "a cloud with a NOT_YET type is not complete")
    var dns = String(
        "the onprem DNS server that holds a zone and its records is an open question (Q18: PowerDNS,"
        " CoreDNS, ExternalDNS with PowerDNS or RFC 2136, or the customer's own DNS)"
    )
    var issuer = String(
        "the onprem issuer of a managed certificate is an open question (Q19: cert-manager with an ACME"
        " issuer, a Vault PKI issuer, the customer's CA, or step-ca)"
    )
    var absent = cloud.absences()
    var fields = [FIELD_DNS_ZONE, FIELD_DNS_RECORD, FIELD_CERTIFICATE]
    for k in range(3):
        var found = 0
        for i in range(len(absent)):
            if absent[i].field == fields[k]:
                found += 1
                assert_equal(absent[i].kind, NOT_YET)
                assert_equal(absent[i].reason, issuer if k == 2 else dns)
        assert_equal(found, 1, String("onprem declares field ") + String(fields[k]) + " NOT_YET once")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-onp"), shape=ProviderShape.onprem())))
    reg.add(describe(FakeCloud(String("p-az"), shape=ProviderShape.azure())))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st)
    except e:
        raised = True
        var text = String('kci: cannot apply this graph to cloud "p-onp". Nothing was created.')
        var ids = ["site", "www", "apex", "tls"]
        var types = ["dns_zone", "dns_record", "dns_record", "certificate"]
        for i in range(4):
            text += String('\n  resource "') + String(ids[i]) + String('": ') + String(types[i])
            text += String(' (PORTABLE): no adapter in cloud "p-onp" (NOT_YET: ')
            text += (issuer if i == 3 else dns) + String(")")
            text += String("\n      clouds built into this kci that implement it: p-az")
        assert_equal(String(e), text)
    assert_true(raised, "names are refused on onprem")
    assert_equal(cloud.mutations(), 0, "nothing was created")
    print("  test_onprem_refuses_names_naming_q18_and_q19: PASS")


# ---- 5. the certificate limits per shape ----------------------------------------------------------


def _check_lines(shape: ProviderShape, domains: String) raises -> List[String]:
    """The limit findings of `tls` on `shape`, as `path|reason`."""
    var cloud = FakeCloud(String("p-l"), shape=shape.copy())
    var l = _list(_graph(domains=domains))
    var got = cloud.check(l[4], List[Feed](), List[Firing]())
    var out = List[String]()
    for i in range(len(got)):
        out.append(got[i].field_path + String("|") + got[i].reason)
    return out^


def test_certificate_limits_per_shape() raises:
    """Catches: azure accepting a second name or a wildcard (a container
    apps managed certificate is one name), gcp accepting a name its one DNS
    authorization does not cover, any shape refusing a certificate it can
    host, and a limit keyed on the cloud's id rather than the shape's data."""
    var two = String('"example.com","*.example.com"')
    var other = String('"example.com","api.example.com"')
    var wild = String('"*.example.com"')
    var az = _check_lines(ProviderShape.azure(), two)
    assert_equal(len(az), 1, "azure: two names")
    assert_equal(az[0], 'certificate.domains|on cloud "p-l" a certificate covers one name; write one certificate per name')
    az = _check_lines(ProviderShape.azure(), wild)
    assert_equal(len(az), 1, "azure: a wildcard")
    assert_equal(az[0], 'certificate.domains[0]|on cloud "p-l" a certificate cannot be a wildcard')
    var g = _check_lines(ProviderShape.gcp(), other)
    assert_equal(len(g), 1, "gcp: an unrelated name")
    assert_equal(
        g[0],
        String('certificate.domains[1]|on cloud "p-l" a certificate is validated by one DNS authorization, for one')
        + String(' name and its wildcard; "api.example.com" is neither "example.com" nor "*.example.com"'),
    )
    assert_equal(len(_check_lines(ProviderShape.gcp(), two)), 0, "gcp: a name and its wildcard")
    assert_equal(len(_check_lines(ProviderShape.gcp(), wild)), 0, "gcp: a wildcard alone")
    var open_shapes = List[ProviderShape]()
    open_shapes.append(ProviderShape.generic())
    open_shapes.append(ProviderShape.aws())
    for i in range(len(open_shapes)):
        ref shape = open_shapes[i]
        assert_equal(len(_check_lines(shape, other)), 0, shape.name + ": many names")
        assert_equal(len(_check_lines(shape, wild)), 0, shape.name + ": a wildcard")
    # Through validate: refused before anything is created.
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-l"), shape=ProviderShape.azure())))
    var cloud = FakeCloud(String("p-l"), shape=ProviderShape.azure())
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(_graph(domains=wild)), Creds.none(), st)
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "p-l". Nothing was created.')
            + String('\n  resource "tls" field certificate.domains[0]: on cloud "p-l" a certificate cannot be')
            + String(" a wildcard (citation: kci_cloud_fake: reference limits)"),
        )
    assert_true(raised, "azure refuses a wildcard certificate at validate")
    assert_equal(cloud.mutations(), 0)
    print("  test_certificate_limits_per_shape: PASS")


# ---- 6. fake-limited declares the three NOT_YET ---------------------------------------------------


def test_fake_limited_declares_names_not_yet() raises:
    """Catches: fake-limited claiming a name type it cannot lower, or
    declaring one absent of the wrong kind."""
    var limited = FakeLimitedCloud()
    var absent = limited.absences()
    var fields = [FIELD_DNS_ZONE, FIELD_DNS_RECORD, FIELD_CERTIFICATE]
    for k in range(3):
        var n = 0
        for i in range(len(absent)):
            if absent[i].field == fields[k]:
                n += 1
                assert_equal(absent[i].kind, NOT_YET)
        assert_equal(n, 1, String("fake-limited declares ") + String(fields[k]) + " NOT_YET once")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeLimitedCloud()))
    reg.add(describe(FakeCloud(String("p-z"))))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(
            reg, limited, _ctx(), _list(String('{"resource":[{"id":"site","dnsZone":{"name":"example.com"}}]}')),
            Creds.none(), st,
        )
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "fake-limited". Nothing was created.')
            + String('\n  resource "site": dns_zone (PORTABLE): no adapter in cloud "fake-limited"')
            + String(" (NOT_YET: fake-limited has no DNS)")
            + String("\n      clouds built into this kci that implement it: p-z"),
        )
    assert_true(raised, "a zone is refused on fake-limited")
    assert_equal(limited.mutations(), 0)
    print("  test_fake_limited_declares_names_not_yet: PASS")


# ---- 7. uses on a name ------------------------------------------------------------------------------


def test_uses_on_a_name_never_reaches_a_lowering() raises:
    """Catches: a name resource lowered with `uses` lines (as if it held an
    identity) by the fake's lowering asked directly, for any of the three
    (validate's refusal is pinned in kci_cloud's test_cloud_dns_rules)."""
    var uses = String('"uses":[{"cell":"LOGS","access":"WRITE"}],')
    var bad = _list(
        String('{"resource":[{"id":"site",') + uses + String('"dnsZone":{"name":"example.com"}},')
        + String('{"id":"www",') + uses + String('"dnsRecord":{"name":"www.example.com","zone":{"resource":"site"},')
        + String('"type":"A","values":[{"literal":"192.0.2.1"}]}},')
        + String('{"id":"tls",') + uses + String('"certificate":{"domains":["example.com"],"zone":{"resource":"site"}}}]}')
    )
    var what = ["dns_zone", "dns_record", "certificate"]
    for i in range(3):
        var raised = False
        try:
            _ = FakeCloud().lower(bad[i], List[GrantEdge](), List[Feed](), List[Firing]())
        except e:
            raised = True
            assert_true(String(e).find(String(what[i]) + ' "') >= 0, String(e))
            assert_true(String(e).find("has uses lines; validate refuses them") >= 0, String(e))
        assert_true(raised, String(what[i]) + ": the lowering refuses uses")
    print("  test_uses_on_a_name_never_reaches_a_lowering: PASS")


# ---- 8. the record kind -----------------------------------------------------------------------------


def test_the_record_kind() raises:
    """Catches: `<TYPE>` left in a kind, replaced by the wrong word, or a
    kind without it changed."""
    var az = ProviderShape.azure()
    for t in ["A", "AAAA", "CNAME", "TXT", "MX"]:
        assert_equal(record_kind(az, String(t)), String("Microsoft.Network/dnsZones/") + String(t))
    assert_equal(record_kind(ProviderShape.aws(), String("MX")), "AWS::Route53::RecordSet")
    print("  test_the_record_kind: PASS")


def main() raises:
    print("test_fake_dns")
    test_golden_lowering_per_shape()
    test_the_kit_on_every_hosting_shape()
    test_after_an_apply()
    test_onprem_refuses_names_naming_q18_and_q19()
    test_certificate_limits_per_shape()
    test_fake_limited_declares_names_not_yet()
    test_uses_on_a_name_never_reaches_a_lowering()
    test_the_record_kind()
    print("ALL kci_cloud_fake NAME TESTS PASSED")
