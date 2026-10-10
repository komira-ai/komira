# =============================================================================
# test_fake_network.mojo
# =============================================================================
#
# The network primitives (network, subnet, IP address) and `Service.network`
# on the fake clouds. One graph throughout: the network `core`
# (10.20.0.0/16); its subnet `edge` (10.20.4.0/24, zone 2); the IP address
# `ingress-ip`; and an internal service `api` (one to three instances) whose
# outbound connections leave through `edge`, that reads `ingress-ip`'s
# ADDRESS, and whose identity writes the cell's METRICS (a `uses` line the
# kit turns off).
#
# 1. A GOLDEN LOWERING PER SHAPE (generic, aws, gcp, azure): per network
#    node its kind, wanted, retention, dependencies, inputs and desired
#    fields; and `api`'s run node's dependencies and inputs. A network is
#    one node holding its range (gcp: a network with no range and no
#    automatic subnets); a subnet one node that reads its network's NAME,
#    with its zone where subnets are each in one zone (aws); an IP address
#    one node; the service's run reads the subnet's NAME (azure: the graph
#    without the service's `network`, a limit there, test 4). The JSON of
#    the generic lowering of a network alone is pinned.
# 2. THE KIT ON EVERY HOSTING SHAPE: the kci_cloud conformance kit (twelve
#    steps) on generic, aws, gcp and azure, each under a random id,
#    tampering with `edge/subnet`; the changed graph raises `api`'s scale.
# 3. AFTER AN APPLY: the subnet is created after the network and `api`'s run
#    after the subnet, each bound to the NAME the node before exposes
#    (`core-network`, `edge-subnet`) and `api` to the address's ADDRESS;
#    taking the service out of the subnet updates its run alone; a destroy
#    keeps a KEEP network (marked `retain`) and deletes the rest.
# 4. THE LIMITS PER SHAPE: aws refuses a subnet with no zone; azure refuses
#    a service with a `network`, through plan with the exact text and
#    nothing created. Every other shape takes each.
# 5. ONPREM DECLARES THE THREE NOT_YET, naming Q23, and refuses the graph
#    before anything is created (a coverage finding per network resource,
#    naming the built-in clouds that host it).
# 6. FAKE-LIMITED DECLARES THE THREE NOT_YET, and refuses one (coverage).
# 7. `uses` ON A NETWORK TYPE never reaches a lowering: the fake's own
#    lowering, asked directly, refuses it for each of the three.
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
    GrantEdge,
    FIELD_IP_ADDRESS,
    FIELD_NETWORK,
    FIELD_SUBNET,
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

from kci_cloud_fake import (
    ONPREM_NETWORK_REASON,
    SERVICE_NETWORK_REASON_AZURE,
    SUBNET_ZONE_REASON_AWS,
    FakeCloud,
    FakeLimitedCloud,
    ProviderShape,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _graph(
    svc_net: Bool = True,
    metrics: Bool = True,
    scale_max: String = String("3"),
    core_retention: String = String("DELETE"),
    zone: Bool = True,
) -> String:
    """The graph of the file header. `svc_net` keeps `api`'s `network`;
    `metrics` its METRICS line; `scale_max` is its scale's max; `zone` keeps the
    subnet's zone."""
    var uses = String('"uses":[{"cell":"METRICS","access":"WRITE"}],') if metrics else String("")
    var net = String(',"network":{"resource":"edge"}') if svc_net else String("")
    var z = String(',"zone":2') if zone else String("")
    return (
        String('{"resource":[')
        + String('{"id":"core","retention":"') + core_retention + String('","network":{"ipv4Cidr":"10.20.0.0/16"}},')
        + String('{"id":"edge","subnet":{"network":{"resource":"core"},"ipv4Cidr":"10.20.4.0/24"') + z + String("}},")
        + String('{"id":"ingress-ip","ipAddress":{}},')
        + String('{"id":"api",') + uses
        + String('"service":{"image":{"digest":"sha256:a1"},"internal":{},"scale":{"min":1,"max":') + scale_max + String("},")
        + String('"env":{"PUBLIC_IP":{"ref":{"resource":"ingress-ip","standard":"ADDRESS"}}}') + net + String("}}")
        + String("]}")
    )


def _hosting_shapes() -> List[ProviderShape]:
    """The fake's own shape, then the built-in clouds that host networks."""
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    return l^


def _shape_graph(shape: ProviderShape, metrics: Bool = True, scale_max: String = String("3")) -> String:
    """`_graph` with what `shape` takes: azure places no service in a subnet
    (test 4)."""
    return _graph(svc_net=shape.service_network_limit.byte_length() == 0, metrics=metrics, scale_max=scale_max)


# ---- 1. a golden lowering per shape ------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per network node (owner core, edge or ingress-ip): id, kind,
    wanted (+ or -), retention, dependencies (`<`), inputs
    (`[producer.OUTPUT>field]`) and desired fields (`{}`); then `api/run`'s
    dependencies and inputs."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        var net = n.owner == "core" or n.owner == "edge" or n.owner == "ingress-ip"
        if not net and n.id != "api/run":
            continue
        s += n.id
        if net:
            s += String(" ") + n.kind + String(" ") + (String("+") if n.wanted else String("-"))
            s += String(" ") + retention_name(n.retention)
        for k in range(len(n.depends_on)):
            s += (String(" <") if k == 0 else String(",")) + n.depends_on[k]
        for k in range(len(n.inputs)):
            ref inp = n.inputs[k]
            s += (String(" [") if k == 0 else String(",")) + inp.producer + String(".") + inp.output
            s += String(">") + inp.field
            if k == len(n.inputs) - 1:
                s += String("]")
        if net:
            s += String(" {")
            for k in range(len(n.desired)):
                if k > 0:
                    s += String(";")
                s += n.desired[k].key + String("=") + n.desired[k].value
            s += String("}")
        s += String("\n")
    return s^


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-n7"), shape=shape.copy())
    var json = _graph(svc_net=shape.service_network_limit.byte_length() == 0, core_retention=String("KEEP"))
    var got = _summary(lower_data(cloud, _list(json)))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


def _golden(
    network: String, subnet: String, address: String, ranged: Bool = True, zoned: Bool = False, svc_net: Bool = True
) -> String:
    var s = String("core/network ") + network + String(" + keep {")
    s += (String("ipv4_cidr=10.20.0.0/16") if ranged else String("subnets=custom")) + String(";out.NAME=core-network}\n")
    s += String("edge/subnet ") + subnet + String(" + delete [core/network.NAME>network] {ipv4_cidr=10.20.4.0/24;")
    s += (String("zone=2;") if zoned else String("")) + String("out.NAME=edge-subnet}\n")
    s += String("ingress-ip/address ") + address + String(" + delete {version=IPV4;out.ADDRESS=ingress-ip.ip.fake}\n")
    s += String("api/run <api/identity [ingress-ip/address.ADDRESS>service.env.PUBLIC_IP")
    s += (String(",edge/subnet.NAME>network]\n") if svc_net else String("]\n"))
    return s^


def test_golden_lowering_per_shape() raises:
    """Catches: a network role missing, extra or of the wrong provider kind
    on any shape; a subnet that does not read its network's NAME (it could
    be created before the network); a service's run that does not read its
    subnet's NAME (it would not follow the subnet, or be created before
    it); a zone lowered where subnets span the region, or dropped where a
    subnet is in one zone; a gcp network given a range of its own; a KEEP
    network's retention not carried."""
    assert_equal(
        _lowered(ProviderShape.generic()),
        _golden(String("network"), String("subnet"), String("address")),
        "generic",
    )
    assert_equal(
        _lowered(ProviderShape.aws()),
        _golden(String("AWS::EC2::VPC"), String("AWS::EC2::Subnet"), String("AWS::EC2::EIP"), zoned=True),
        "aws",
    )
    assert_equal(
        _lowered(ProviderShape.gcp()),
        _golden(
            String("compute.googleapis.com/Network"),
            String("compute.googleapis.com/Subnetwork"),
            String("compute.googleapis.com/Address"),
            ranged=False,
        ),
        "gcp",
    )
    assert_equal(
        _lowered(ProviderShape.azure()),
        _golden(
            String("Microsoft.Network/virtualNetworks"),
            String("Microsoft.Network/virtualNetworks/subnets"),
            String("Microsoft.Network/publicIPAddresses"),
            svc_net=False,
        ),
        "azure",
    )
    var cloud = FakeCloud()
    assert_equal(
        lowering_json(lower_data(cloud, _list(String('{"resource":[{"id":"core","network":{"ipv4Cidr":"10.20.0.0/16"}}]}')))),
        String('[\n  {"id":"core/network","owner":"core","kind":"network","wanted":true,')
        + String('"retention":"delete","depends_on":[],"inputs":[],')
        + String('"desired":{"ipv4_cidr":"10.20.0.0/16","out.NAME":"core-network"}}\n]'),
    )
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. the kit on every hosting shape --------------------------------------------------------


def test_the_kit_on_every_hosting_shape() raises:
    """Catches: a network node whose create skips the stamp, the retention
    mark or the run-id label; a digest that moves on a re-apply (an output
    field in the digest would); a tampered subnet not planned as an update;
    a lowering that keys on the cloud's id."""
    var shapes = _hosting_shapes()
    var ids = [String("p-5h"), String("p-v2"), String("p-q8n"), String("p-x4")]
    for s in range(len(shapes)):
        ref shape = shapes[s]
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shape.copy())))
        var cloud = FakeCloud(ids[s], shape=shape.copy())
        try:
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_shape_graph(shape)),
                _list(_shape_graph(shape, scale_max=String("4"))),
                _list(_shape_graph(shape, metrics=False, scale_max=String("4"))),
                String("edge/subnet"),
            )
        except e:
            raise Error(shape.name + String(" shape: ") + String(e))
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
    """Catches: a subnet created before its network, a service's run created
    before its subnet, a subnet or a run bound to nothing (or to another
    output), an address not exposed (or exposed with another value), taking
    a service out of its subnet planned as anything but an update of its run
    alone, and a KEEP network deleted by destroy (or a DELETE subnet
    kept)."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var a = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(core_retention=String("KEEP"))), Creds.none(), st))
    assert_true(_at(a, String("core/network")) < _at(a, String("edge/subnet")), "the subnet after its network")
    assert_true(_at(a, String("edge/subnet")) < _at(a, String("api/run")), "the service after its subnet")
    var edge = _digest(cloud, String("edge/subnet"))
    assert_true(edge.find("|network=core-network") >= 0, "the subnet is bound to its network's NAME: " + edge)
    assert_true(edge.find("out.") < 0, "an output is never in a digest: " + edge)
    var run = _digest(cloud, String("api/run"))
    assert_true(run.find("|network=edge-subnet") >= 0, "the run is bound to its subnet's NAME: " + run)
    assert_true(run.find("|service.env.PUBLIC_IP=ingress-ip.ip.fake") >= 0, "the address's ADDRESS: " + run)

    var b = _done(
        apply_resources(reg, cloud, _ctx(), _list(_graph(svc_net=False, core_retention=String("KEEP"))), Creds.none(), st)
    )
    for i in range(len(b)):
        var want = VERB_UPDATE if b[i].logical_id == "api/run" else VERB_NOOP
        assert_equal(b[i].verb, want, b[i].logical_id + String(": out of the subnet updates the run alone"))
    assert_true(_digest(cloud, String("api/run")).find("|network=") < 0, "the run is in no subnet")

    _ = destroy_resources(
        reg, cloud, _ctx(), _list(_graph(svc_net=False, core_retention=String("KEEP"))), Creds.none(), st
    )
    var labels = cloud.live_labels(String("core/network"))
    var kept = False
    for i in range(len(labels)):
        if labels[i].key == "kci-retention" and labels[i].value == "retain":
            kept = True
    assert_true(kept, "core/network is still there, marked kci-retention=retain")
    assert_equal(cloud.live_count(), 1, "only the KEEP network is left")
    print("  test_after_an_apply: PASS")


# ---- 4. the limits per shape ----------------------------------------------------------------------


def _limit_lines(shape: ProviderShape, json: String) raises -> List[String]:
    """Every limit finding of `json` on `shape`, as `id|path|reason`."""
    var cloud = FakeCloud(String("p-l"), shape=shape.copy())
    var l = _list(json)
    var out = List[String]()
    for i in range(len(l)):
        var got = cloud.check(l[i], List[Feed](), List[Firing]())
        for k in range(len(got)):
            out.append(l[i].id + String("|") + got[k].field_path + String("|") + got[k].reason)
    return out^


def test_limits_per_shape() raises:
    """Catches: aws taking a subnet with no zone (an EC2 subnet is in one),
    azure placing one container app in a subnet (its environment joins the
    network), a limit at the wrong path or keyed on the cloud's id, and
    another shape refusing what it hosts."""
    var shapes = _hosting_shapes()
    var no_zone = _graph(svc_net=False, zone=False)
    var in_net = _graph()
    for s in range(len(shapes)):
        ref shape = shapes[s]
        var n = shape.name
        var z = _limit_lines(shape, no_zone)
        if n == "aws":
            assert_equal(len(z), 1, n)
            assert_equal(
                z[0],
                String('edge|subnet.zone|on cloud "p-l" a subnet is in one zone: ') + String(SUBNET_ZONE_REASON_AWS)
                + String("; write its zone (1 to 3)"),
            )
        else:
            assert_equal(len(z), 0, n + String(": a subnet with no zone"))
        var v = _limit_lines(shape, in_net)
        if n == "azure":
            assert_equal(len(v), 1, n)
            assert_equal(
                v[0],
                String('api|service.network|on cloud "p-l" a service cannot be placed in a subnet: ')
                + String(SERVICE_NETWORK_REASON_AZURE),
            )
        else:
            assert_equal(len(v), 0, n + String(": a service in a subnet"))
    # Through plan on azure: the exact refusal, nothing created.
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-l"), shape=ProviderShape.azure())))
    var cloud = FakeCloud(String("p-l"), shape=ProviderShape.azure())
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(in_net), Creds.none(), st)
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "p-l". Nothing was created.')
            + String('\n  resource "api" field service.network: on cloud "p-l" a service cannot be placed in a subnet: ')
            + String(SERVICE_NETWORK_REASON_AZURE)
            + String(" (citation: kci_cloud_fake: reference limits)"),
        )
    assert_true(raised, "azure refuses a service in a subnet at validate")
    assert_equal(cloud.mutations(), 0)
    print("  test_limits_per_shape: PASS")


# ---- 5. onprem declares the three NOT_YET -------------------------------------------------------


def test_onprem_refuses_networks_naming_q23() raises:
    """Catches: onprem picking a network backing (it must not, until Q23 is
    answered), an absence of the wrong kind or reason, a coverage finding
    missing for one of the three resources, and a refusal after a create."""
    var cloud = FakeCloud(String("p-onp"), shape=ProviderShape.onprem())
    assert_true(not cloud.complete(), "a cloud with a NOT_YET type is not complete")
    assert_true(String(ONPREM_NETWORK_REASON).find("(Q23:") >= 0, "the reason names Q23")
    var absent = cloud.absences()
    var fields = [FIELD_NETWORK, FIELD_SUBNET, FIELD_IP_ADDRESS]
    for k in range(3):
        var found = 0
        for i in range(len(absent)):
            if absent[i].field == fields[k]:
                found += 1
                assert_equal(absent[i].kind, NOT_YET)
                assert_equal(absent[i].reason, String(ONPREM_NETWORK_REASON))
        assert_equal(found, 1, String("onprem declares field ") + String(fields[k]) + " NOT_YET once")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-onp"), shape=ProviderShape.onprem())))
    reg.add(describe(FakeCloud(String("p-gc"), shape=ProviderShape.gcp())))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st)
    except e:
        raised = True
        var text = String('kci: cannot apply this graph to cloud "p-onp". Nothing was created.')
        var ids = ["core", "edge", "ingress-ip"]
        var types = ["network", "subnet", "ip_address"]
        for i in range(3):
            text += String('\n  resource "') + String(ids[i]) + String('": ') + String(types[i])
            text += String(' (PORTABLE): no adapter in cloud "p-onp" (NOT_YET: ') + String(ONPREM_NETWORK_REASON)
            text += String(")\n      clouds built into this kci that implement it: p-gc")
        assert_equal(String(e), text)
    assert_true(raised, "networks are refused on onprem")
    assert_equal(cloud.mutations(), 0, "nothing was created")
    print("  test_onprem_refuses_networks_naming_q23: PASS")


# ---- 6. fake-limited declares the three NOT_YET ---------------------------------------------------


def test_fake_limited_declares_networks_not_yet() raises:
    """Catches: fake-limited claiming a network type it cannot lower, or
    declaring one absent of the wrong kind."""
    var limited = FakeLimitedCloud()
    var absent = limited.absences()
    var fields = [FIELD_NETWORK, FIELD_SUBNET, FIELD_IP_ADDRESS]
    for k in range(3):
        var n = 0
        for i in range(len(absent)):
            if absent[i].field == fields[k]:
                n += 1
                assert_equal(absent[i].kind, NOT_YET)
                assert_equal(absent[i].reason, "fake-limited has no networks")
        assert_equal(n, 1, String("fake-limited declares ") + String(fields[k]) + " NOT_YET once")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeLimitedCloud()))
    reg.add(describe(FakeCloud(String("p-z"))))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(
            reg, limited, _ctx(), _list(String('{"resource":[{"id":"ingress-ip","ipAddress":{}}]}')), Creds.none(), st
        )
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "fake-limited". Nothing was created.')
            + String('\n  resource "ingress-ip": ip_address (PORTABLE): no adapter in cloud "fake-limited"')
            + String(" (NOT_YET: fake-limited has no networks)")
            + String("\n      clouds built into this kci that implement it: p-z"),
        )
    assert_true(raised, "an IP address is refused on fake-limited")
    assert_equal(limited.mutations(), 0)
    print("  test_fake_limited_declares_networks_not_yet: PASS")


# ---- 7. uses on a network type ----------------------------------------------------------------------


def test_uses_on_a_network_type_never_reaches_a_lowering() raises:
    """Catches: a network resource lowered with `uses` lines (as if it held
    an identity) by the fake's lowering asked directly, for any of the three
    (validate's refusal is pinned in kci_cloud's test_cloud_network_rules)."""
    var uses = String('"uses":[{"cell":"LOGS","access":"WRITE"}],')
    var bad = _list(
        String('{"resource":[{"id":"core",') + uses + String('"network":{"ipv4Cidr":"10.20.0.0/16"}},')
        + String('{"id":"edge",') + uses + String('"subnet":{"network":{"resource":"core"},"ipv4Cidr":"10.20.4.0/24"}},')
        + String('{"id":"ingress-ip",') + uses + String('"ipAddress":{}}]}')
    )
    var what = ["network", "subnet", "ip_address"]
    for i in range(3):
        var raised = False
        try:
            _ = FakeCloud().lower(bad[i], List[GrantEdge](), List[Feed](), List[Firing]())
        except e:
            raised = True
            assert_true(String(e).find(String(what[i]) + ' "') >= 0, String(e))
            assert_true(String(e).find("has uses lines; validate refuses them") >= 0, String(e))
        assert_true(raised, String(what[i]) + ": the lowering refuses uses")
    print("  test_uses_on_a_network_type_never_reaches_a_lowering: PASS")


def main() raises:
    print("test_fake_network")
    test_golden_lowering_per_shape()
    test_the_kit_on_every_hosting_shape()
    test_after_an_apply()
    test_limits_per_shape()
    test_onprem_refuses_networks_naming_q23()
    test_fake_limited_declares_networks_not_yet()
    test_uses_on_a_network_type_never_reaches_a_lowering()
    print("ALL kci_cloud_fake NETWORK TESTS PASSED")
