# =============================================================================
# test_fake_kci_app.mojo
# =============================================================================
#
# `kci.app@1`, THE DEFINITION KCI SHIPS (kci_composites), EXPANDED AND
# DEPLOYED on the fake clouds. The list: a DNS zone `www` (example.com) and
# `web`, an instance of kci.app@1 (image, public, port 8081, an env, the
# domain shop.example.com in `www`).
#
# 1. THE EXPANSION: `web/account` (a service account), `web/api` (a public
#    service running as it, with the image, the port and the env written by
#    bindings) and `web/host` (a CNAME in `www`, named by `domain`, naming
#    `web/api`'s HOST).
# 2. A GOLDEN LOWERING PER SHAPE: generic, aws, gcp and azure lower the
#    whole list (the service's own identity turned off under `run_as`; the
#    record reading the zone's NAME and the run's HOST; azure's public
#    ingress folded into the run node). onprem has no DNS yet (NOT_YET,
#    Q18): the list is refused before anything is lowered, naming the
#    zone and the record; with no `domain` (so no `host`), no zone and
#    `min_instances: 1` (`max_instances: 3`), onprem validates and lowers
#    the rest (the
#    Deployment, the in-cluster Service the Ingress fronts, the Vault role);
#    without `min_instances` it refuses the service, which cannot scale to
#    zero there (Q21, open), at `web/api`'s `service.scale.min`, the field
#    the input is bound to.
# 3. AFTER AN APPLY (generic): the record's value is the service's host;
#    an instance that stops setting `domain` deletes the record (and only
#    it); `public: false` turns the public role off and touches nothing
#    else of the service's but its run.
# 4. REFUSALS, through validate on the generic fake, for every input:
#    `image` and `public` unbound (both required: there is no default
#    exposure); `public` not true or false; `port` not an integer; `domain`
#    without `zone` (the record has no zone: DnsRecord's rule); `domain` at
#    the zone's own name (a CNAME is never there; whether kci.app answers
#    the zone's own name with A/AAAA records or a provider alias is HELD
#    for the design owner, so this is refused, not lowered).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    Provenance,
    VERB_CREATE,
    VERB_DELETE,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    Finding,
    LoweredNode,
    apply_resources,
    describe,
    expand,
    lower_data,
    retention_name,
    validate_for,
)
from kci_composites import read_kci_definitions
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, ProviderShape, builtin_shapes


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _findings(fs: List[Finding]) -> String:
    var s = String("")
    for i in range(len(fs)):
        s += fs[i].resource_id + String(" | ") + fs[i].field_path + String(" | ") + fs[i].reason + String("\n")
    return s^


comptime _FULL = '"public":{"literal":"true"},"port":{"literal":"8081"},"domain":{"literal":"shop.example.com"},"zone":{"ref":{"resource":"www"}}'


def _graph(inputs: String = String(_FULL), image: Bool = True, zone: Bool = True) -> String:
    """`www` unless `zone` is False, and `web` with `inputs`, the image
    unless `image` is False, and the env LEVEL=info."""
    var s = String('{"resource":[')
    if zone:
        s += String('{"id":"www","dnsZone":{"name":"example.com"}},')
    s += String('{"id":"web","composite":{"definition":"kci.app","version":"1","input":{') + inputs + String("}")
    if image:
        s += String(',"imageInput":{"image":{"digest":"sha256:a1"}}')
    s += String(',"mapInput":{"env":{"value":{"LEVEL":{"literal":"info"}}}}}}]}')
    return s^


# ---- 1. the expansion -------------------------------------------------------------------------


def test_the_expansion() raises:
    """Catches: kci.app's components or bindings changed (a run_as lost, a
    binding not written, the record not following the service's HOST, the
    record present without a domain)."""
    var x = expand(Catalog.v1(), read_kci_definitions(), _list(_graph()))
    assert_equal(len(x.findings), 0, _findings(x.findings))
    var ids = String("")
    for i in range(len(x.resources)):
        ids += x.resources[i].id + String(";")
    assert_equal(ids, "www;web/account;web/api;web/host;", "the expanded list")
    ref api = x.resources[2].service.value()
    assert_equal(api.image.value().digest.value(), "sha256:a1", "the image")
    assert_equal(Int(api.port), 8081, "the port")
    assert_true(Bool(api.public), "public")
    assert_equal(api.run_as.value().resource, "web/account", "runs as the account")
    assert_equal(api.env["LEVEL"].literal.value(), "info", "the env")
    ref host = x.resources[3].dns_record.value()
    assert_equal(host.name, "shop.example.com", "the domain")
    assert_equal(host.zone.value().resource, "www", "the zone, bound at the top")
    assert_equal(host.values[0].ref_.value().resource, "web/api", "the record names the service")
    assert_equal(host.values[0].ref_.value().standard.value().json_name(), "HOST")
    var bare = expand(Catalog.v1(), read_kci_definitions(), _list(_graph(String('"public":{"literal":"false"}'), zone=False)))
    assert_equal(len(bare.findings), 0, _findings(bare.findings))
    assert_equal(len(bare.resources), 2, "no domain: no host")
    assert_true(not Bool(bare.resources[1].service.value().public), "public: false")
    print("  test_the_expansion: PASS")


# ---- 2. a golden lowering per shape ----------------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per node: id, kind, wanted (+ or -), retention, dependencies
    (`<`), inputs (`[producer.OUTPUT>field]`) and desired fields (`{}`)."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
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


def _lowered(shape: ProviderShape, graph: String) raises -> String:
    var x = expand(Catalog.v1(), read_kci_definitions(), _list(graph))
    assert_equal(len(x.findings), 0, _findings(x.findings))
    var cloud = FakeCloud(String("p-a1"), shape=shape.copy())
    return _summary(lower_data(cloud, x.resources))


comptime _GOLDEN_GENERIC = (
    'www/zone zone + delete {domain=example.com;out.NAME=www-zone}\n'
    + 'web/account/identity identity + delete {account=true}\n'
    + 'web/account/u-b6mdyh grant + delete <web/account/identity {principal=web/account;cell=LOGS;access=WRITE}\n'
    + 'web/api/identity identity - delete {}\n'
    + 'web/api/run run + delete <web/account/identity {img=sha256:a1@linux/amd64;port=8081;service.env.LEVEL=info;size=1000m/512MB;scale=0..10;health=;timeout=60s0n;concurrency=0;run_as=web/account;serves=true}\n'
    + 'web/api/public public + delete <web/api/run {mechanism=invoker}\n'
    + 'web/host/record record + delete [www/zone.NAME>zone,web/api/run.HOST>value.0] {name=shop.example.com;type=CNAME;ttl=300s;out.HOST=shop.example.com}\n'
)
comptime _GOLDEN_AWS = (
    'www/zone AWS::Route53::HostedZone + delete {domain=example.com;out.NAME=www-zone}\n'
    + 'web/account/identity AWS::IAM::Role + delete {account=true}\n'
    + 'web/account/u-b6mdyh AWS::IAM::RolePolicy + delete <web/account/identity {principal=web/account;cell=LOGS;access=WRITE}\n'
    + 'web/api/identity AWS::IAM::Role - delete {}\n'
    + 'web/api/run AWS::Lambda::Function + delete <web/account/identity {img=sha256:a1@linux/amd64;port=8081;service.env.LEVEL=info;size=1000m/512MB;scale=0..10;health=;timeout=60s0n;concurrency=0;run_as=web/account;serves=true}\n'
    + 'web/api/public AWS::Lambda::Url + delete <web/api/run {mechanism=invoker}\n'
    + 'web/host/record AWS::Route53::RecordSet + delete [www/zone.NAME>zone,web/api/run.HOST>value.0] {name=shop.example.com;type=CNAME;ttl=300s;out.HOST=shop.example.com}\n'
)
comptime _GOLDEN_GCP = (
    'www/zone dns.googleapis.com/ManagedZone + delete {domain=example.com;out.NAME=www-zone}\n'
    + 'web/account/identity iam.googleapis.com/ServiceAccount + delete {account=true}\n'
    + 'web/account/u-b6mdyh setIamPolicy + delete <web/account/identity {principal=web/account;cell=LOGS;access=WRITE}\n'
    + 'web/api/identity iam.googleapis.com/ServiceAccount - delete {}\n'
    + 'web/api/run run.googleapis.com/Service + delete <web/account/identity {img=sha256:a1@linux/amd64;port=8081;service.env.LEVEL=info;size=1000m/512MB;scale=0..10;health=;timeout=60s0n;concurrency=0;run_as=web/account;serves=true}\n'
    + 'web/api/public setIamPolicy + delete <web/api/run {mechanism=invoker}\n'
    + 'web/host/record dns.googleapis.com/ResourceRecordSet + delete [www/zone.NAME>zone,web/api/run.HOST>value.0] {name=shop.example.com;type=CNAME;ttl=300s;out.HOST=shop.example.com}\n'
)
comptime _GOLDEN_AZURE = (
    'www/zone Microsoft.Network/dnsZones + delete {domain=example.com;out.NAME=www-zone}\n'
    + 'web/account/identity Microsoft.ManagedIdentity/userAssignedIdentities + delete {account=true}\n'
    + 'web/account/u-b6mdyh Microsoft.Authorization/roleAssignments + delete <web/account/identity {principal=web/account;cell=LOGS;access=WRITE}\n'
    + 'web/api/identity Microsoft.ManagedIdentity/userAssignedIdentities - delete {}\n'
    + 'web/api/run Microsoft.App/containerApps + delete <web/account/identity {img=sha256:a1@linux/amd64;port=8081;service.env.LEVEL=info;size=1000m/512MB;scale=0..10;health=;timeout=60s0n;concurrency=0;ingress=invoker;run_as=web/account;serves=true}\n'
    + 'web/host/record Microsoft.Network/dnsZones/CNAME + delete [www/zone.NAME>zone,web/api/run.HOST>value.0] {name=shop.example.com;type=CNAME;ttl=300s;out.HOST=shop.example.com}\n'
)
comptime _GOLDEN_ONPREM_BARE = (
    'web/account/identity v1/ServiceAccount + delete {account=true;cell.LOGS=WRITE}\n'
    + 'web/account/vault vault:auth/kubernetes/role + delete <web/account/identity {}\n'
    + 'web/api/identity v1/ServiceAccount - delete {}\n'
    + 'web/api/vault vault:auth/kubernetes/role - delete <web/api/identity {}\n'
    + 'web/api/run apps/v1/Deployment + delete <web/account/identity {img=sha256:a1@linux/amd64;port=8081;service.env.LEVEL=info;size=1000m/512MB;scale=1..3;health=;timeout=60s0n;concurrency=0;run_as=web/account;serves=true}\n'
    + 'web/api/endpoint v1/Service + delete <web/api/run {port=8081}\n'
    + 'web/api/public networking.k8s.io/v1/Ingress + delete <web/api/endpoint {mechanism=invoker}\n'
)


def test_golden_lowering_per_shape() raises:
    """Catches: a node of kci.app missing, extra, of the wrong provider kind
    or out of order on any shape; the service's own identity left on beside
    the account; the record not reading the zone and the service's host;
    azure's public role not folded; onprem lowering a record it has no DNS
    for."""
    var shapes = builtin_shapes()
    var want: List[String] = [String(_GOLDEN_AWS), String(_GOLDEN_GCP), String(_GOLDEN_AZURE)]
    var bad = String("")
    var generic = _lowered(ProviderShape.generic(), _graph())
    if generic != String(_GOLDEN_GENERIC):
        bad += String("\n==== generic\n") + generic
    for s in range(3):
        var got = _lowered(shapes[s], _graph())
        if got != want[s]:
            bad += String("\n==== ") + shapes[s].name + String("\n") + got
    var bare = String('"public":{"literal":"true"},"port":{"literal":"8081"},"min_instances":{"literal":"1"},"max_instances":{"literal":"3"}')
    var onprem = _lowered(ProviderShape.onprem(), _graph(bare, zone=False))
    if onprem != String(_GOLDEN_ONPREM_BARE):
        bad += String("\n==== onprem (no domain)\n") + onprem
    assert_equal(bad, String(""), "the lowering per shape")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-o"), shape=ProviderShape.onprem())))
    reg.add(describe(FakeCloud(String("p-a"), shape=ProviderShape.aws())))
    var op = FakeCloud(String("p-o"), shape=ProviderShape.onprem())
    var ok = validate_for(reg, op, _list(_graph(bare, zone=False)), read_kci_definitions())
    assert_equal(len(ok), 0, String("onprem takes kci.app with no domain and one instance at least:\n") + _findings(ok))
    var full = String(_FULL) + String(',"min_instances":{"literal":"1"},"max_instances":{"literal":"3"}')
    var fs = validate_for(reg, op, _list(_graph(full)), read_kci_definitions())
    var got = _findings(fs)
    assert_equal(len(fs), 2, String("onprem refuses the zone and the record:\n") + got)
    assert_true(got.find("www |  | dns_zone (PORTABLE): no adapter in cloud \"p-o\" (NOT_YET: ") >= 0 and got.find("Q18") >= 0, got)
    assert_true(got.find("web/host |  | dns_record (PORTABLE): no adapter in cloud \"p-o\" (NOT_YET: ") >= 0, got)
    var zero = validate_for(reg, op, _list(_graph(String('"public":{"literal":"true"}'), zone=False)), read_kci_definitions())
    assert_equal(len(zero), 1, _findings(zero))
    assert_true(_findings(zero).find("web/api | service.scale.min | ") >= 0 and _findings(zero).find("Q21") >= 0, _findings(zero))
    print("  test_golden_lowering_per_shape: PASS")


# ---- 3. after an apply --------------------------------------------------------------------------------


def _verbs(applied: List[AppliedNode]) -> String:
    """Every node that is not a NOOP, as `id:verb;`, in order."""
    var s = String("")
    for i in range(len(applied)):
        if applied[i].verb == VERB_NOOP:
            continue
        var v = String("create") if applied[i].verb == VERB_CREATE else (
            String("update") if applied[i].verb == VERB_UPDATE else (
                String("delete") if applied[i].verb == VERB_DELETE else String(applied[i].verb)
            )
        )
        s += applied[i].logical_id + String(":") + v + String(";")
    return s^


def test_after_an_apply() raises:
    """Catches: the record's value not the live service's host; an instance
    that stops setting `domain` leaving the record live (N24) or touching
    anything else; a public service made internal keeping its public role."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var defs = read_kci_definitions()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st, defs))
    var at = cloud.store[].find(String("web/host/record"))
    assert_true(at >= 0, "the record is live")
    var rec = cloud.store[].digests[at].copy()
    assert_true(rec.find("web-api") >= 0 or rec.find("web/api") >= 0, String("the record names the service's host: ") + rec)
    var nodom = String('"public":{"literal":"true"},"port":{"literal":"8081"},"zone":{"ref":{"resource":"www"}}')
    var v = _verbs(_done(apply_resources(reg, cloud, _ctx(), _list(_graph(nodom)), Creds.none(), st, defs)))
    assert_equal(v, "web/host/record:delete;", "no domain: the record alone is deleted")
    var internal = String('"public":{"literal":"false"},"port":{"literal":"8081"},"zone":{"ref":{"resource":"www"}}')
    v = _verbs(_done(apply_resources(reg, cloud, _ctx(), _list(_graph(internal)), Creds.none(), st, defs)))
    assert_true(v.find("web/api/public:delete;") >= 0, v)
    assert_true(v.find("web/account") < 0 and v.find("www/") < 0, v)
    print("  test_after_an_apply: PASS")


# ---- 4. refusals ----------------------------------------------------------------------------------------


def _refused(graph: String, rid: String, field: String, needle: String) raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var fs = validate_for(reg, FakeCloud(), _list(graph), read_kci_definitions())
    var got = _findings(fs)
    assert_equal(len(fs), 1, String("one finding (") + needle + String("), got:\n") + got)
    assert_equal(fs[0].resource_id, rid, got)
    assert_equal(fs[0].field_path, field, got)
    assert_true(fs[0].reason.find(needle) >= 0, String("reason holds ") + needle + String(":\n") + got)


def test_refusals() raises:
    """Catches: kci.app's required inputs not required (N25: `public` with a
    default would decide the exposure for the author), and each input
    accepted where its type or the expanded record's rule refuses it
    (zone: a binding that dropped the record's zone type check would
    accept a service as a zone; min_instances: a negative scale is refused
    when the binding writes it, since Scale.min is unsigned). No rule
    orders min and max today, so a max below the min has no refusal to
    test."""
    _refused(_graph(image=False), "web", "composite.input", "required input \"image\" of kci.app@1 is not bound")
    _refused(
        _graph(String('"port":{"literal":"8081"}')), "web", "composite.input", "required input \"public\" of kci.app@1 is not bound"
    )
    _refused(_graph(String('"public":{"literal":"yes"}')), "web", "composite.input.public", "a BOOL input is true or false")
    _refused(
        _graph(String('"public":{"literal":"true"},"port":{"literal":"http"}')),
        "web",
        "composite.input.port",
        "an INT input is a decimal integer",
    )
    _refused(
        _graph(String('"public":{"literal":"true"},"domain":{"literal":"shop.example.com"}')),
        "web/host",
        "dns_record.zone",
        "no zone",
    )
    _refused(
        _graph(String('"public":{"literal":"true"},"domain":{"literal":"example.com"},"zone":{"ref":{"resource":"www"}}')),
        "web/host",
        "dns_record.name",
        "a CNAME is never at its zone's own name",
    )
    _refused(
        _graph(String('"public":{"literal":"true"},"domain":{"literal":"shop.example.com"},"zone":{"ref":{"resource":"web","path":"api"}}')),
        "web/host",
        "dns_record.zone",
        "must name a dns_zone",
    )
    _refused(
        _graph(String('"public":{"literal":"true"},"min_instances":{"literal":"-1"},"max_instances":{"literal":"2"}')),
        "web/api",
        "bind[3] service.scale.min",
        "input \"min_instances\": JsonError: non-digit in integer text",
    )
    var noenv = _graph(String('"public":{"literal":"true"}')).replace('"LEVEL":{"literal":"info"}', '"LEVEL":{}')
    _refused(noenv, "web", "composite.map_input.env.LEVEL", "has no value")
    print("  test_refusals: PASS")


def main() raises:
    print("test_fake_kci_app: kci.app@1 expanded and deployed on the fakes")
    test_the_expansion()
    test_golden_lowering_per_shape()
    test_after_an_apply()
    test_refusals()
    print("ALL kci_cloud_fake kci.app TESTS PASSED")
