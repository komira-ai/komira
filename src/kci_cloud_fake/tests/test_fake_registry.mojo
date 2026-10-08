# =============================================================================
# test_fake_registry.mojo
# =============================================================================
#
# The registry primitive on the fake clouds. One graph throughout: the
# registry `images` (OCI); a container job `builder` that pushes to it (a
# `uses` line, WRITE), reads its ADDRESS, and whose identity writes the
# cell's METRICS (a `uses` line the kit turns off); the service account
# `puller`; and the grant `pull-images` that lets `puller` pull (READ).
#
# 1. A GOLDEN LOWERING PER SHAPE (generic, aws, gcp, azure): the registry
#    node's kind, wanted, retention and desired fields (one node holding its
#    format, exposing its ADDRESS); both edges to it (the builder's WRITE
#    line `u-<h>` and the pull grant), each the shape's grant kind,
#    depending on its principal's identity and on the registry; and
#    `builder`'s run reading the registry's ADDRESS. The JSON of the
#    generic lowering of a registry alone is pinned.
# 2. THE KIT ON EVERY HOSTING SHAPE: the kci_cloud conformance kit (twelve
#    steps) on generic, aws, gcp and azure, each under a random id,
#    tampering with `images/registry` (written DELETE there: the kit
#    destroys what it applied and expects nothing left); the changed graph
#    changes the builder's args.
# 3. AFTER AN APPLY: the registry is created before the builder's run and
#    before both edges; the run is bound to the registry's ADDRESS
#    (`registry.fake/images`); WRITE -> READ_WRITE on the builder's line is
#    an update of that edge alone (the verb is not in its role); a destroy
#    keeps the registry (KEEP by default, marked `retain`) and deletes the
#    rest.
# 4. ONPREM DECLARES THE REGISTRY NOT_YET, naming Q24, and refuses the graph
#    before anything is created (one coverage finding, naming the built-in
#    clouds that host it).
# 5. FAKE-LIMITED DECLARES THE REGISTRY NOT_YET, and refuses one (coverage).
# 6. `uses` ON A REGISTRY never reaches a lowering: the fake's own lowering,
#    asked directly, refuses it.
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
    FIELD_REGISTRY,
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
    ONPREM_REGISTRY_REASON,
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
    retention: String = String(""),
    push: String = String("WRITE"),
    metrics: Bool = True,
    arg: String = String("--push"),
) -> String:
    """The graph of the file header. `retention` is the registry's written
    retention (empty: unset, KEEP); `push` the builder's verb on it;
    `metrics` keeps the builder's METRICS line; `arg` is its one arg."""
    var ret = String('"retention":"') + retention + String('",') if retention.byte_length() > 0 else String("")
    var uses = String('"uses":[{"target":{"resource":"images"},"access":"') + push + String('"}')
    if metrics:
        uses += String(',{"cell":"METRICS","access":"WRITE"}')
    uses += String("],")
    return (
        String('{"resource":[')
        + String('{"id":"images",') + ret + String('"registry":{"format":"OCI"}},')
        + String('{"id":"builder",') + uses
        + String('"containerJob":{"image":{"digest":"sha256:b1"},"args":["') + arg + String('"],')
        + String('"env":{"REGISTRY":{"ref":{"resource":"images","standard":"ADDRESS"}}}}},')
        + String('{"id":"puller","serviceAccount":{}},')
        + String('{"id":"pull-images","grant":{"principal":{"resource":"puller"},"target":{"resource":"images"},')
        + String('"access":"READ"}}')
        + String("]}")
    )


def _hosting_shapes() -> List[ProviderShape]:
    """The fake's own shape, then the built-in clouds that host a registry."""
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    return l^


# ---- 1. a golden lowering per shape ------------------------------------------------------


comptime _PUSH_ROLE = "builder/u-ivwetu"
"""The role of the builder's line on `images`: sha256("builder|images"),
6 base32 characters, computed with Python hashlib."""


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per registry node (owner images) and per edge to it (the
    builder's line, the pull grant): id, kind, wanted (+ or -), retention,
    dependencies (`<`) and desired fields (`{}`); then `builder/run`'s
    dependencies and inputs (`[producer.OUTPUT>field]`)."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        var full = n.owner == "images" or n.id == String(_PUSH_ROLE) or n.id == "pull-images/grant"
        if not full and n.id != "builder/run":
            continue
        s += n.id
        if full:
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
        if full:
            s += String(" {")
            for k in range(len(n.desired)):
                if k > 0:
                    s += String(";")
                s += n.desired[k].key + String("=") + n.desired[k].value
            s += String("}")
        s += String("\n")
    return s^


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-r3"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_graph())))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


def _golden(registry: String, grant: String) -> String:
    var s = String("images/registry ") + registry + String(" + keep {format=OCI;out.ADDRESS=registry.fake/images}\n")
    s += String("builder/run <builder/identity [images/registry.ADDRESS>container_job.env.REGISTRY]\n")
    s += String(_PUSH_ROLE) + String(" ") + grant
    s += String(" + delete <builder/identity,images/registry {principal=builder;target=images;access=WRITE}\n")
    s += String("pull-images/grant ") + grant
    s += String(" + delete <puller/identity,images/registry {principal=puller;target=images;access=READ}\n")
    return s^


def test_golden_lowering_per_shape() raises:
    """Catches: the registry role missing, extra or of the wrong provider
    kind on any shape; its format or its ADDRESS not lowered; a default
    retention other than KEEP; an edge to a registry lowered to another kind
    (or folded), or not depending on the registry (a push grant created
    before the registry exists); a run that does not read the registry's
    ADDRESS (it could start before the registry, and would not follow
    it)."""
    assert_equal(_lowered(ProviderShape.generic()), _golden(String("registry"), String("grant")), "generic")
    assert_equal(
        _lowered(ProviderShape.aws()),
        _golden(String("AWS::ECR::Repository"), String("AWS::IAM::RolePolicy")),
        "aws",
    )
    assert_equal(
        _lowered(ProviderShape.gcp()),
        _golden(String("artifactregistry.googleapis.com/Repository"), String("setIamPolicy")),
        "gcp",
    )
    assert_equal(
        _lowered(ProviderShape.azure()),
        _golden(String("Microsoft.ContainerRegistry/registries"), String("Microsoft.Authorization/roleAssignments")),
        "azure",
    )
    var cloud = FakeCloud()
    assert_equal(
        lowering_json(lower_data(cloud, _list(String('{"resource":[{"id":"images","registry":{"format":"OCI"}}]}')))),
        String('[\n  {"id":"images/registry","owner":"images","kind":"registry","wanted":true,')
        + String('"retention":"keep","depends_on":[],"inputs":[],')
        + String('"desired":{"format":"OCI","out.ADDRESS":"registry.fake/images"}}\n]'),
    )
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. the kit on every hosting shape --------------------------------------------------------


def test_the_kit_on_every_hosting_shape() raises:
    """Catches: a registry node whose create skips the stamp, the retention
    mark or the run-id label; a digest that moves on a re-apply (an output
    field in the digest would); a tampered registry not planned as an
    update; a turned-off edge not deleted; a lowering that keys on the
    cloud's id."""
    var shapes = _hosting_shapes()
    var ids = [String("p-9c"), String("p-e4k"), String("p-2wz"), String("p-r7")]
    for s in range(len(shapes)):
        ref shape = shapes[s]
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shape.copy())))
        var cloud = FakeCloud(ids[s], shape=shape.copy())
        try:
            # The kit destroys what it applied and expects nothing left, so
            # `images` is written DELETE here (its KEEP default is test 3's).
            var d = String("DELETE")
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_graph(retention=d)),
                _list(_graph(retention=d, arg=String("--push-all"))),
                _list(_graph(retention=d, metrics=False, arg=String("--push-all"))),
                String("images/registry"),
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
    """Catches: a run or an edge created before the registry, a run bound to
    nothing (or to another output) for the registry, an address not exposed
    (or exposed with another value), a changed verb planned as anything but
    an update of its edge alone, and a registry deleted by destroy at its
    default retention (or anything else kept)."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var a = _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st))
    var at = _at(a, String("images/registry"))
    assert_true(at >= 0, "the registry is applied")
    for id in [String("builder/run"), String(_PUSH_ROLE), String("pull-images/grant")]:
        assert_true(at < _at(a, id), id + String(" after the registry"))
    var run = _digest(cloud, String("builder/run"))
    assert_true(
        run.find("|container_job.env.REGISTRY=registry.fake/images") >= 0, "the run holds the registry's ADDRESS: " + run
    )
    var r = _digest(cloud, String("images/registry"))
    assert_true(r.find("out.") < 0, "an output is never in a digest: " + r)

    var b = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(push=String("READ_WRITE"))), Creds.none(), st))
    for i in range(len(b)):
        var want = VERB_UPDATE if b[i].logical_id == String(_PUSH_ROLE) else VERB_NOOP
        assert_equal(b[i].verb, want, b[i].logical_id + String(": WRITE -> READ_WRITE updates the edge alone"))
    assert_true(_digest(cloud, String(_PUSH_ROLE)).find("READ_WRITE") >= 0, "the edge holds the new verb")

    _ = destroy_resources(reg, cloud, _ctx(), _list(_graph(push=String("READ_WRITE"))), Creds.none(), st)
    var labels = cloud.live_labels(String("images/registry"))
    var kept = False
    for i in range(len(labels)):
        if labels[i].key == "kci-retention" and labels[i].value == "retain":
            kept = True
    assert_true(kept, "images/registry is still there, marked kci-retention=retain")
    assert_equal(cloud.live_count(), 1, "only the KEEP registry is left")
    print("  test_after_an_apply: PASS")


# ---- 4. onprem declares the registry NOT_YET -------------------------------------------------


def test_onprem_refuses_a_registry_naming_q24() raises:
    """Catches: onprem picking a registry backing (it must not, until Q24 is
    answered), an absence of the wrong kind or reason, the coverage finding
    missing, and a refusal after a create."""
    var cloud = FakeCloud(String("p-onp"), shape=ProviderShape.onprem())
    assert_true(not cloud.complete(), "a cloud with a NOT_YET type is not complete")
    assert_true(String(ONPREM_REGISTRY_REASON).find("(Q24:") >= 0, "the reason names Q24")
    var absent = cloud.absences()
    var found = 0
    for i in range(len(absent)):
        if absent[i].field == FIELD_REGISTRY:
            found += 1
            assert_equal(absent[i].kind, NOT_YET)
            assert_equal(absent[i].reason, String(ONPREM_REGISTRY_REASON))
    assert_equal(found, 1, "onprem declares the registry NOT_YET once")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-onp"), shape=ProviderShape.onprem())))
    reg.add(describe(FakeCloud(String("p-gc"), shape=ProviderShape.gcp())))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st)
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "p-onp". Nothing was created.')
            + String('\n  resource "images": registry (PORTABLE): no adapter in cloud "p-onp" (NOT_YET: ')
            + String(ONPREM_REGISTRY_REASON)
            + String(")\n      clouds built into this kci that implement it: p-gc"),
        )
    assert_true(raised, "a registry is refused on onprem")
    assert_equal(cloud.mutations(), 0, "nothing was created")
    print("  test_onprem_refuses_a_registry_naming_q24: PASS")


# ---- 5. fake-limited declares the registry NOT_YET ------------------------------------------------


def test_fake_limited_declares_the_registry_not_yet() raises:
    """Catches: fake-limited claiming a registry it cannot lower, or
    declaring it absent of the wrong kind."""
    var limited = FakeLimitedCloud()
    var absent = limited.absences()
    var n = 0
    for i in range(len(absent)):
        if absent[i].field == FIELD_REGISTRY:
            n += 1
            assert_equal(absent[i].kind, NOT_YET)
            assert_equal(absent[i].reason, "fake-limited has no registry")
    assert_equal(n, 1, "fake-limited declares the registry NOT_YET once")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeLimitedCloud()))
    reg.add(describe(FakeCloud(String("p-z"))))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(
            reg,
            limited,
            _ctx(),
            _list(String('{"resource":[{"id":"images","registry":{"format":"OCI"}}]}')),
            Creds.none(),
            st,
        )
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "fake-limited". Nothing was created.')
            + String('\n  resource "images": registry (PORTABLE): no adapter in cloud "fake-limited"')
            + String(" (NOT_YET: fake-limited has no registry)")
            + String("\n      clouds built into this kci that implement it: p-z"),
        )
    assert_true(raised, "a registry is refused on fake-limited")
    assert_equal(limited.mutations(), 0)
    print("  test_fake_limited_declares_the_registry_not_yet: PASS")


# ---- 6. uses on a registry ----------------------------------------------------------------------


def test_uses_on_a_registry_never_reaches_a_lowering() raises:
    """Catches: a registry lowered with `uses` lines (as if it held an
    identity) by the fake's lowering asked directly (validate's refusal is
    pinned in kci_cloud's test_cloud_registry_rules)."""
    var bad = _list(
        String('{"resource":[{"id":"images","uses":[{"cell":"LOGS","access":"WRITE"}],')
        + String('"registry":{"format":"OCI"}}]}')
    )
    var raised = False
    try:
        _ = FakeCloud().lower(bad[0], List[GrantEdge](), List[Feed](), List[Firing]())
    except e:
        raised = True
        assert_true(String(e).find('registry "images" has uses lines; validate refuses them') >= 0, String(e))
    assert_true(raised, "the lowering refuses uses on a registry")
    print("  test_uses_on_a_registry_never_reaches_a_lowering: PASS")


def main() raises:
    print("test_fake_registry")
    test_golden_lowering_per_shape()
    test_the_kit_on_every_hosting_shape()
    test_after_an_apply()
    test_onprem_refuses_a_registry_naming_q24()
    test_fake_limited_declares_the_registry_not_yet()
    test_uses_on_a_registry_never_reaches_a_lowering()
    print("ALL kci_cloud_fake REGISTRY TESTS PASSED")
