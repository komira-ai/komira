# =============================================================================
# test_fake_adoption.mojo
# =============================================================================
#
# SAFE ADOPTION ON EVERY SHAPE (generic, aws, gcp, azure, onprem), part 1:
# the read before planning, the adoption itself, the plan that says so, and
# the refused replace. Part 2 (test_fake_adoption_release.mojo) is the
# delete side: destroy, release and the closed world.
#
# One list throughout: the bucket `logs` under the cloud name `acme-logs`,
# with one label, which `adopt`s; and the service account `reader`. Every
# shape hosts both (on onprem the types it holds NOT_YET are refused by
# coverage before any read, like any other graph). The object an adoption
# expects is planted with `FakeCloud.plant_like`: the kind, state and name
# the bucket's primary node declares, unstamped.
#
# 1. NOTHING STANDS THERE: plan and apply are refused before any change,
#    naming the node, the declared kind and name, and the cloud. No served
#    call.
# 2. SOMETHING ELSE STANDS THERE, one way at a time: another kind, another
#    cloud name, another value of a field of its shape (`versioning`). Each
#    is refused naming both sides; nothing changes. An object whose only
#    difference is the author's label IS taken (the adoption writes it).
# 3. THE ADOPTION: the plan marks `logs/bucket (adopted)`; the apply stamps
#    the object (an update, never a create) with the adoption mark
#    `kci_adopted=true` and no run-id; `list_owned` reports it adopted; a
#    re-plan still marks it (now from the mark), and a re-apply is a no-op.
#    No other node is marked.
# 4. ONCE KCI'S, THE FILE MAY CHANGE IT: after the adoption a changed field
#    (`versioning`) is planned and applied as an update; the read does not
#    refuse an object kci already stamped.
# 5. A REPLACE IS REFUSED: once the cloud cannot change the object in place
#    (`FakeStore.replace_only`), a change to it is refused at plan and at
#    apply before any change, naming the replace; ADOPT_DELETABLE is
#    refused the same way (it allows a delete, never a replace).
# 6. APPLY'S OWN PLAN STEPS ASIDE FOR AN OWNERSHIP REFUSAL: with an adopted
#    bucket and a foreign object at the reader's node, apply returns the
#    engine's refusal in its outcome (it does not raise), and nothing
#    changes. Any other error of that plan is raised before any change: with
#    the reader's live read refused (`FakeStore.fail_reads_of`), apply
#    raises the read error and the cloud served no call.
# 7. ONLY THE PRIMARY NODE IS MARKED: a service `api` that adopts lowers
#    its identity, its run, its public ingress and its grant, and only the
#    run (its primary node) is marked `adopted`; nothing of `reader`.
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
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    LoweredNode,
    Setting,
    apply_resources,
    describe,
    lower_data,
    plan_report,
    render_plan,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, ProviderShape


def _shapes() -> List[ProviderShape]:
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    l.append(ProviderShape.onprem())
    return l^


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _reg(cloud: FakeCloud) raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    return reg^


def _list(versioning: Bool = False, deletable: Bool = False, adopt: Bool = True) raises -> List[Resource]:
    var b = String('{"id":"logs","physicalName":"acme-logs","labels":{"team":"data"},')
    if deletable:
        b += String('"adopt":"ADOPT_DELETABLE",')
    elif adopt:
        b += String('"adopt":"ADOPT",')
    b += String('"bucket":{"versioning":') + (String("true") if versioning else String("false")) + String("}}")
    return decode_json[ResourceList](
        String('{"resource":[') + b + String(',{"id":"reader","serviceAccount":{}}]}')
    ).resource.copy()


def _primary(cloud: FakeCloud, resources: List[Resource]) raises -> LoweredNode:
    var nodes = lower_data(cloud, resources)
    for i in range(len(nodes)):
        if nodes[i].id == "logs/bucket":
            return nodes[i].copy()
    raise Error("no logs/bucket node")


def _with(node: LoweredNode, key: String, value: String) -> LoweredNode:
    var out = node.copy()
    for i in range(len(out.desired)):
        if out.desired[i].key == key:
            out.desired[i].value = value
    return out^


def _refusal(mut cloud: FakeCloud, reg: Clouds, resources: List[Resource]) raises -> String:
    """The plan's refusal; the apply must refuse the same way, and neither
    may change anything."""
    var before = cloud.mutations()
    var st = InMemoryStateStore()
    var plan_says = String("")
    try:
        _ = plan_report(reg, cloud, _ctx(), resources, Creds.none(), st)
    except e:
        plan_says = String(e)
    assert_true(plan_says.byte_length() > 0, "the plan is refused")
    var apply_says = String("")
    try:
        _ = apply_resources(reg, cloud, _ctx(), resources, Creds.none(), st)
    except e:
        apply_says = String(e)
    assert_equal(apply_says, plan_says, "the apply is refused the same way")
    assert_equal(cloud.mutations(), before, "nothing changed")
    return plan_says^


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _verb(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def _label(cloud: FakeCloud, id: String, key: String) -> String:
    var labels = cloud.live_labels(id)
    for i in range(len(labels)):
        if labels[i].key == key:
            return labels[i].value.copy()
    return String("")


# ---- 1. nothing stands there ------------------------------------------------------------


def test_a_missing_object_refuses_the_plan() raises:
    """Catches: a missing object not refused (mutant: the absent branch
    skipped; the engine would then CREATE the bucket the file said exists),
    a refusal that does not name the node, the kind, the name or the cloud,
    and an apply that is not refused the same way before any change."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        var id = String("ad1-") + shapes[s].name
        var cloud = FakeCloud(id, shape=shapes[s].copy())
        var reg = _reg(FakeCloud(id, shape=shapes[s].copy()))
        var kind = _primary(cloud, _list()).kind
        var says = _refusal(cloud, reg, _list())
        assert_true(
            says.find(
                String('logs/bucket: the resource adopts ') + kind + String(' "acme-logs", and cloud "') + id
                + String('" holds no such object')
            ) >= 0,
            shapes[s].name + ": " + says,
        )
        assert_equal(cloud.live_count(), 0, shapes[s].name + ": nothing was created")
    print("  test_a_missing_object_refuses_the_plan: PASS")


# ---- 2. something else stands there ------------------------------------------------------


def test_a_different_object_refuses_the_plan() raises:
    """Catches: the kind, the cloud name or a field of the shape not compared
    (each mutant lets that one through, and the engine would stamp a
    different object as the resource's), a side not named, and the author's
    label compared (an object that differs only there must be taken)."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var node = _primary(FakeCloud(String("ad2"), shape=sh.copy()), _list())
        var kinds = List[LoweredNode]()
        var needles = List[String]()
        var other_kind = node.copy()
        other_kind.kind = String("some-other-kind")
        kinds.append(other_kind^)
        needles.append(String('kind: the resource declares "') + node.kind + String('", the cloud holds "some-other-kind"'))
        kinds.append(_with(node, String("physical_name"), String("old-logs")))
        needles.append(String('cloud name: the resource declares "acme-logs", the cloud holds "old-logs"'))
        kinds.append(_with(node, String("versioning"), String("true")))
        needles.append(String('versioning: the resource declares "false", the cloud holds "true"'))
        for k in range(len(kinds)):
            var id = String("ad2-") + sh.name
            var cloud = FakeCloud(id, shape=sh.copy())
            var reg = _reg(FakeCloud(id, shape=sh.copy()))
            cloud.plant_like(kinds[k])
            var says = _refusal(cloud, reg, _list())
            assert_true(says.find("logs/bucket: the object cloud") >= 0, sh.name + ": " + says)
            assert_true(says.find(needles[k]) >= 0, sh.name + ": " + needles[k] + " in " + says)
            assert_equal(_label(cloud, String("logs/bucket"), String("kci_adopted")), "", "not stamped")
        var id = String("ad2l-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        cloud.plant_like(_with(node, String("label.team"), String("other")))
        var st = InMemoryStateStore()
        var applied = _done(apply_resources(reg, cloud, _ctx(), _list(), Creds.none(), st))
        assert_equal(_verb(applied, String("logs/bucket")), VERB_UPDATE, sh.name + ": a label is no reason to refuse")
    print("  test_a_different_object_refuses_the_plan: PASS")


# ---- 3. the adoption ---------------------------------------------------------------------


def test_the_adoption_is_marked_and_said() raises:
    """Catches: the plan not marking the adopted node (or marking another),
    the object created instead of stamped, the adoption mark not written
    (mutant: `adopt_owned` without `adoption_labels`; the closed world would
    then treat it as kci's own), a run-id written by an adoption, the mark
    not read back by `list_owned`, and a re-apply that is not a no-op."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("ad3-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        cloud.plant_like(_primary(cloud, _list()))
        var st = InMemoryStateStore()
        var plan = plan_report(reg, cloud, _ctx(), _list(), Creds.none(), st)
        var text = render_plan(plan)
        assert_true(text.find("logs: noop logs/bucket (adopted)") >= 0, sh.name + ": matched, so noop: " + text)
        assert_equal(len(plan.adopted), 1, sh.name + ": only the bucket's primary node is adopted")
        assert_equal(len(plan.released), 0)
        var applied = _done(apply_resources(reg, cloud, _ctx(), _list(), Creds.none(), st))
        assert_equal(_verb(applied, String("logs/bucket")), VERB_UPDATE, sh.name + ": stamped, never created")
        assert_equal(cloud.creates_of(String("logs/bucket")), 0)
        assert_equal(_label(cloud, String("logs/bucket"), String("kci_adopted")), "true", sh.name + ": the mark")
        assert_equal(_label(cloud, String("logs/bucket"), String("kci-run-id")), "", "an adoption writes no run-id")
        assert_equal(_label(cloud, String("reader/identity"), String("kci_adopted")), "", "a created object: no mark")
        var owned = cloud.list_owned(Creds.none(), _ctx().scope)
        var marked = 0
        for i in range(len(owned)):
            if owned[i].adopted:
                marked += 1
                assert_equal(owned[i].owner_node, "logs/bucket")
        assert_equal(marked, 1, sh.name + ": list_owned reports the adoption")
        var again = render_plan(plan_report(reg, cloud, _ctx(), _list(), Creds.none(), st))
        assert_true(again.find("noop logs/bucket (adopted)") >= 0, sh.name + ": still marked: " + again)
        var re = _done(apply_resources(reg, cloud, _ctx(), _list(), Creds.none(), st))
        for i in range(len(re)):
            assert_equal(re[i].verb, VERB_NOOP, re[i].logical_id + ": a re-apply is a no-op")
    print("  test_the_adoption_is_marked_and_said: PASS")


# ---- 4. once kci's, the file may change it ------------------------------------------------


def test_an_adopted_object_takes_the_files_changes() raises:
    """Catches: the read judging an object kci already stamped (mutant: the
    stamped skip removed; every change after the adoption would be refused
    as a different object)."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("ad4-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        cloud.plant_like(_primary(cloud, _list()))
        var st = InMemoryStateStore()
        _ = _done(apply_resources(reg, cloud, _ctx(), _list(), Creds.none(), st))
        var changed = _done(apply_resources(reg, cloud, _ctx(), _list(versioning=True), Creds.none(), st))
        assert_equal(_verb(changed, String("logs/bucket")), VERB_UPDATE, sh.name + ": an update of an adopted object")
        assert_equal(_label(cloud, String("logs/bucket"), String("kci_adopted")), "true", "an update keeps the mark")
    print("  test_an_adopted_object_takes_the_files_changes: PASS")


# ---- 5. a replace is refused ------------------------------------------------------------------


def test_a_replace_of_an_adopted_object_is_refused() raises:
    """Catches: the replace check dropped from the plan (mutant: no
    `replace_findings`), apply not planning first (the engine would raise
    only when it reached the node, after others landed), and
    ADOPT_DELETABLE let through (mutant: the `deletable` skip kept in
    `replace_findings`; the plan would show a replace the engine's apply
    cannot make)."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("ad5-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        cloud.plant_like(_primary(cloud, _list()))
        var st = InMemoryStateStore()
        _ = _done(apply_resources(reg, cloud, _ctx(), _list(), Creds.none(), st))
        cloud.store[].replace_only(String("logs/bucket"))
        var before = cloud.mutations()
        var says = String("")
        try:
            _ = plan_report(reg, cloud, _ctx(), _list(versioning=True), Creds.none(), st)
        except e:
            says = String(e)
        assert_true(says.find("logs/bucket: kci adopted this object") >= 0, sh.name + ": " + says)
        assert_true(says.find("this change would replace it") >= 0, says)
        var apply_says = String("")
        try:
            _ = apply_resources(reg, cloud, _ctx(), _list(versioning=True), Creds.none(), st)
        except e:
            apply_says = String(e)
        assert_equal(apply_says, says, sh.name + ": apply refuses the same way")
        assert_equal(cloud.mutations(), before, sh.name + ": nothing changed")
        for p in range(2):
            var del_says = String("")
            try:
                if p == 0:
                    _ = plan_report(reg, cloud, _ctx(), _list(versioning=True, deletable=True), Creds.none(), st)
                else:
                    _ = apply_resources(reg, cloud, _ctx(), _list(versioning=True, deletable=True), Creds.none(), st)
            except e:
                del_says = String(e)
            assert_true(
                del_says.find("kci never replaces an adopted object, whatever adopt says") >= 0,
                sh.name + ": ADOPT_DELETABLE is refused too: " + del_says,
            )
        assert_equal(cloud.mutations(), before, sh.name + ": still nothing changed")
    print("  test_a_replace_of_an_adopted_object_is_refused: PASS")


# ---- 6. apply's own plan steps aside for an ownership refusal ------------------------------------


def test_an_ownership_refusal_is_still_an_outcome() raises:
    """Catches: apply's plan-first step raising the engine's ownership
    refusal (mutant: re-raise in its except arm), where apply returns every
    refusal in its outcome."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("ad6-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        cloud.plant_like(_primary(cloud, _list()))
        cloud.plant_foreign(String("reader/identity"))
        var st = InMemoryStateStore()
        var out = apply_resources(reg, cloud, _ctx(), _list(), Creds.none(), st)
        assert_true(out.refused(), sh.name + ": the foreign object refuses the apply")
        assert_true(out.error.value().find("reader/identity: foreign") >= 0, out.error.value())
        assert_equal(cloud.mutations(), 0, sh.name + ": nothing changed")
    print("  test_an_ownership_refusal_is_still_an_outcome: PASS")


def test_another_plan_error_is_raised_before_any_change() raises:
    """Catches: apply's plan-first step swallowing every error (mutant: a
    bare `except: pass`), where only the ownership refusal steps aside: the
    apply would then go on and return the read error as an outcome instead
    of raising it before any change."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("ad6r-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        cloud.plant_like(_primary(cloud, _list()))
        cloud.store[].fail_reads_of(String("reader/identity"))
        var st = InMemoryStateStore()
        var says = String("")
        try:
            _ = apply_resources(reg, cloud, _ctx(), _list(), Creds.none(), st)
        except e:
            says = String(e)
        assert_true(says.find("fake: injected read fault (reader/identity)") >= 0, sh.name + ": raised: " + says)
        assert_equal(cloud.mutations(), 0, sh.name + ": nothing changed")
    print("  test_another_plan_error_is_raised_before_any_change: PASS")


# ---- 7. only the primary node is marked -----------------------------------------------------------


def test_only_the_primary_node_is_marked() raises:
    """Catches: every node of an adopting resource marked (mutant: `adopted`
    set from `adopt` alone; kci would then demand that its helpers already
    exist, and mark objects it creates), or none."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var l = decode_json[ResourceList](
            String('{"resource":[{"id":"api","physicalName":"api-1","adopt":"ADOPT",')
            + String('"service":{"image":{"digest":"sha256:0011"},"internal":{}}},')
            + String('{"id":"reader","serviceAccount":{}}]}')
        ).resource.copy()
        var nodes = lower_data(FakeCloud(String("ad7"), shape=sh.copy()), l)
        var marked = List[String]()
        for i in range(len(nodes)):
            if nodes[i].adopted:
                marked.append(nodes[i].id.copy())
        assert_true(len(nodes) > 3, sh.name + ": the service lowers several nodes")
        assert_equal(len(marked), 1, sh.name + ": one node marked")
        assert_equal(marked[0], "api/run", sh.name + ": the primary node")
    print("  test_only_the_primary_node_is_marked: PASS")


def main() raises:
    print("test_fake_adoption")
    test_a_missing_object_refuses_the_plan()
    test_a_different_object_refuses_the_plan()
    test_the_adoption_is_marked_and_said()
    test_an_adopted_object_takes_the_files_changes()
    test_a_replace_of_an_adopted_object_is_refused()
    test_an_ownership_refusal_is_still_an_outcome()
    test_another_plan_error_is_raised_before_any_change()
    test_only_the_primary_node_is_marked()
    print("ALL FAKE ADOPTION TESTS PASSED")
