# =============================================================================
# test_fake_adoption_release.mojo
# =============================================================================
#
# SAFE ADOPTION ON EVERY SHAPE (generic, aws, gcp, azure, onprem), part 2:
# the delete side. An object kci adopted is never deleted unless its
# resource writes `adopt` ADOPT_DELETABLE, and is RELEASED when its resource
# leaves the list. Part 1 (test_fake_adoption.mojo) is the read, the
# adoption and the replace.
#
# The list: the bucket `logs` under the cloud name `acme-logs`, which
# `adopt`s the object planted for it, and the service account `reader`.
#
# 1. THE RESOURCE LEAVES THE LIST: the plan reports `release logs/bucket`
#    under `logs`; the apply releases it (`ApplyOutcome.released`), it is not
#    leftover, the cloud served a `release` and NO delete call, the object
#    still stands with no kci label left, `list_owned` no longer reports it,
#    and its state record is retired. A file that names it again without
#    `adopt` meets an unstamped object: refused as foreign. A bucket kci
#    created that leaves the same list stays leftover, as before.
# 2. A RELEASE THAT FAILS, at either of its two steps (the record is
#    retired first, then the cloud drops the labels). The cloud refuses the
#    release call: the outcome carries the error and no release, the record
#    is retired, the object keeps its stamp and the adoption mark, and the
#    next apply releases it. The store refuses to retire the record
#    (`_ReapFails`): the same outcome, the record kept, the object still
#    stamped and marked, the next apply releases it, and a file that then
#    adopts it again takes it over. AFTER THE FAILED CLOUD CALL (the record
#    retired, the object stamped and marked) the file names the bucket
#    again: without `adopt` the plan and the apply are refused before any
#    change, naming the mark (a clean release would have left it foreign);
#    with `adopt` the apply keeps it adopted, still marked.
# 3. DESTROY (the bucket written DELETE; a bucket is KEEP by default, and a
#    kept object is never deleted, so never refused): refused before any
#    change while the bucket does not write ADOPT_DELETABLE (the refusal
#    names the node and both ways out); with it, the destroy deletes the
#    adopted bucket. The retention that counts is the file's, never the
#    object's label: a bucket adopted under KEEP and destroyed by a file
#    that now writes DELETE is refused, and the KEEP destroy deletes nothing.
# 4. THE RESOURCE STAYS BUT NO LONGER LOWERS IT (`logs` becomes a secret):
#    the delete of the adopted bucket (written DELETE) is refused at plan
#    and apply before any change. An adopted bucket kept by retention (KEEP)
#    is left behind instead, never refused and never deleted.
# 5. A COMPONENT A DEFINITION DROPS (generic shape; expansion is the same
#    on every shape; both buckets written DELETE): the adopted bucket of
#    `site/files` is released when
#    version 2 of the definition no longer has `files`, though its owner
#    `site` is still in the list, where a bucket kci created would be
#    deleted.
# 6. A COMPONENT'S ADOPT IS HONOURED ON DESTROY (generic shape; both
#    buckets written DELETE): a destroy of `site` is refused before any
#    change while the adopted component writes ADOPT, naming
#    `site/files/bucket`; with ADOPT_DELETABLE it deletes the adopted
#    bucket with the rest of the instance.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    IntentTicket,
    Outputs,
    Provenance,
    ResourceKey,
    StateStore,
    VERB_DELETE,
)
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    LoweredNode,
    apply_resources,
    describe,
    destroy_resources,
    expand,
    is_kci_label_key,
    lower_data,
    plan_report,
    render_plan,
)

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


def _logs(adopt: Bool = True, deletable: Bool = False, retention: String = String("")) -> String:
    var b = String('{"id":"logs","physicalName":"acme-logs",')
    if retention.byte_length() > 0:
        b += String('"retention":"') + retention + String('",')
    if deletable:
        b += String('"adopt":"ADOPT_DELETABLE",')
    elif adopt:
        b += String('"adopt":"ADOPT",')
    return b + String('"bucket":{}}')


def _list(*items: String) raises -> List[Resource]:
    var s = String('{"resource":[')
    for i in range(len(items)):
        if i > 0:
            s += String(",")
        s += items[i]
    return decode_json[ResourceList](s + String("]}")).resource.copy()


comptime _READER = '{"id":"reader","serviceAccount":{}}'
comptime _MADE = '{"id":"made","bucket":{}}'


def _adopted(mut cloud: FakeCloud, reg: Clouds, resources: List[Resource], mut st: InMemoryStateStore) raises:
    """Plant what `logs/bucket` declares, then apply `resources` (which adopt
    it)."""
    var nodes = lower_data(cloud, resources)
    for i in range(len(nodes)):
        if nodes[i].adopted:
            cloud.plant_like(nodes[i])
    var out = apply_resources(reg, cloud, _ctx(), resources, Creds.none(), st)
    if out.error:
        raise Error(String("the adopting apply stopped: ") + out.error.value())


def _served(cloud: FakeCloud, call: String) -> Bool:
    for i in range(len(cloud.store[].calls)):
        if cloud.store[].calls[i] == call:
            return True
    return False


def _kci_labels(cloud: FakeCloud, id: String) -> Int:
    var n = 0
    var labels = cloud.live_labels(id)
    for i in range(len(labels)):
        if is_kci_label_key(labels[i].key):
            n += 1
    return n


def _label_of(cloud: FakeCloud, id: String, key: String) -> String:
    var labels = cloud.live_labels(id)
    for i in range(len(labels)):
        if labels[i].key == key:
            return labels[i].value.copy()
    return String("")


def _listed(mut cloud: FakeCloud, id: String) raises -> Bool:
    var owned = cloud.list_owned(Creds.none(), _ctx().scope)
    for i in range(len(owned)):
        if owned[i].owner_node == id:
            return True
    return False


def _refused(mut cloud: FakeCloud, reg: Clouds, resources: List[Resource], mut st: InMemoryStateStore, destroy: Bool) raises -> String:
    var before = cloud.mutations()
    var says = String("")
    try:
        if destroy:
            _ = destroy_resources(reg, cloud, _ctx(), resources, Creds.none(), st)
        else:
            _ = apply_resources(reg, cloud, _ctx(), resources, Creds.none(), st)
    except e:
        says = String(e)
    assert_equal(cloud.mutations(), before, "a refusal changes nothing")
    return says^


# ---- 1. the resource leaves the list ---------------------------------------------------------


def test_a_resource_leaving_the_list_releases_its_adopted_object() raises:
    """Catches: the adopted object left as leftover (mutant: no release
    branch in `removals`), deleted (mutant: released objects made roles to
    remove), released without the cloud call or with a delete, its record
    kept (mutant: no `mark_reaped`; a later adoption would meet a conflict),
    the release missing from the plan or the outcome, and a bucket kci
    created released instead of left over."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("re1-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        var st = InMemoryStateStore()
        _adopted(cloud, reg, _list(_logs(), String(_READER), String(_MADE)), st)
        var plan = plan_report(reg, cloud, _ctx(), _list(String(_READER)), Creds.none(), st)
        assert_equal(len(plan.released), 1, sh.name)
        assert_equal(plan.released[0], "logs/bucket")
        var text = render_plan(plan)
        assert_true(
            text.find("logs: release logs/bucket (adopted; kci drops its stamp and record and leaves it standing)") >= 0,
            sh.name + ": " + text,
        )
        var out = apply_resources(reg, cloud, _ctx(), _list(String(_READER)), Creds.none(), st)
        assert_true(not out.error, sh.name + ": " + (out.error.value() if out.error else String("")))
        assert_equal(len(out.released), 1, sh.name + ": the outcome names the release")
        assert_equal(out.released[0], "logs/bucket")
        for i in range(len(out.leftover)):
            assert_true(out.leftover[i] != "logs/bucket", "a released object is not leftover")
        var made_left = False
        for i in range(len(out.leftover)):
            if out.leftover[i] == "made/bucket":
                made_left = True
        assert_true(made_left, sh.name + ": a bucket kci created stays leftover")
        assert_true(_served(cloud, String("release logs/bucket")), sh.name + ": the cloud served the release")
        assert_true(not _served(cloud, String("delete logs/bucket")), sh.name + ": no delete call reached the cloud")
        assert_true(cloud.store[].find(String("logs/bucket")) >= 0, sh.name + ": the object still stands")
        assert_equal(_kci_labels(cloud, String("logs/bucket")), 0, sh.name + ": no kci label is left on it")
        assert_true(not _listed(cloud, String("logs/bucket")), sh.name + ": no longer kci's")
        assert_equal(st.physical_id_for(_ctx().scope.key(String("logs/bucket"))), "", sh.name + ": record retired")
        var again = apply_resources(reg, cloud, _ctx(), _list(_logs(adopt=False), String(_READER)), Creds.none(), st)
        assert_true(again.refused(), sh.name + ": named again without adopt, it is foreign")
        assert_true(again.error.value().find("logs/bucket: foreign") >= 0, again.error.value())
    print("  test_a_resource_leaving_the_list_releases_its_adopted_object: PASS")


# ---- 2. a release that fails -------------------------------------------------------------------


struct _ReapFails(StateStore, Movable, Deinitable):
    """An `InMemoryStateStore` whose `mark_reaped` raises while `fail` is
    set; every other call is the inner store's."""

    var inner: InMemoryStateStore
    var fail: Bool

    def __init__(out self):
        self.inner = InMemoryStateStore()
        self.fail = False

    def record_or_adopt_intent(mut self, key: ResourceKey, stamp: String) raises -> IntentTicket:
        return self.inner.record_or_adopt_intent(key, stamp)

    def confirm(mut self, ticket: IntentTicket, physical_id: String) raises:
        self.inner.confirm(ticket, physical_id)

    def mark_reaped(mut self, key: ResourceKey) raises:
        if self.fail:
            raise Error(String("store: injected fault on mark_reaped ") + key.text())
        self.inner.mark_reaped(key)

    def physical_id_for(mut self, key: ResourceKey) raises -> String:
        return self.inner.physical_id_for(key)

    def record_outputs(mut self, key: ResourceKey, outputs: Outputs) raises:
        self.inner.record_outputs(key, outputs)

    def outputs_for(mut self, key: ResourceKey) raises -> Outputs:
        return self.inner.outputs_for(key)


def test_a_failed_release_is_reported_and_retried() raises:
    """Catches: a failed release reported as done, the cloud call made before
    the record is retired (mutant: the two steps swapped; the record would
    be kept here), and a next apply that does not release it."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("re2-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        var st = InMemoryStateStore()
        _adopted(cloud, reg, _list(_logs(), String(_READER)), st)
        # The reader is converged, so the release is the next served call.
        cloud.store[].fail_at_call = cloud.store[]._attempts + 1
        var out = apply_resources(reg, cloud, _ctx(), _list(String(_READER)), Creds.none(), st)
        assert_true(Bool(out.error), sh.name + ": the failure is reported")
        assert_true(out.error.value().startswith("release of logs/bucket failed: "), out.error.value())
        assert_equal(len(out.released), 0)
        assert_equal(len(out.applied), 0, sh.name + ": a failed release reports no applied list")
        assert_equal(len(out.pending), 0, sh.name + ": the engine finished, so nothing is pending")
        assert_true(len(out.landed) > 0, sh.name + ": every node the engine applied is landed")
        assert_true(_listed(cloud, String("logs/bucket")), sh.name + ": still kci's")
        assert_equal(_label_of(cloud, String("logs/bucket"), String("kci_adopted")), "true", "still marked")
        assert_equal(st.physical_id_for(_ctx().scope.key(String("logs/bucket"))), "", "the record is retired")
        var retry = apply_resources(reg, cloud, _ctx(), _list(String(_READER)), Creds.none(), st)
        assert_true(not retry.error)
        assert_equal(len(retry.released), 1, sh.name + ": released on the next apply")
    print("  test_a_failed_release_is_reported_and_retried: PASS")


def test_a_failed_retire_is_reported_and_retried() raises:
    """Catches: the cloud call made before the record is retired (mutant:
    the two steps swapped): a failed retire would then leave an unstamped
    object with a live record, which no later apply releases and which the
    engine refuses as a conflict when a file adopts it again."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("re2r-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        var st = _ReapFails()
        _adopted(cloud, reg, _list(_logs(), String(_READER)), st.inner)
        st.fail = True
        var out = apply_resources(reg, cloud, _ctx(), _list(String(_READER)), Creds.none(), st)
        assert_true(Bool(out.error), sh.name + ": the failure is reported")
        assert_true(out.error.value().startswith("release of logs/bucket failed: "), out.error.value())
        assert_equal(len(out.released), 0)
        assert_true(not _served(cloud, String("release logs/bucket")), sh.name + ": no release call yet")
        assert_true(_listed(cloud, String("logs/bucket")), sh.name + ": still kci's")
        assert_equal(_label_of(cloud, String("logs/bucket"), String("kci_adopted")), "true", "still marked")
        assert_true(
            st.physical_id_for(_ctx().scope.key(String("logs/bucket"))).byte_length() > 0, "the record is kept"
        )
        st.fail = False
        var retry = apply_resources(reg, cloud, _ctx(), _list(String(_READER)), Creds.none(), st)
        assert_true(not retry.error, sh.name + ": " + (retry.error.value() if retry.error else String("")))
        assert_equal(len(retry.released), 1, sh.name + ": released on the next apply")
        assert_equal(_kci_labels(cloud, String("logs/bucket")), 0, sh.name + ": no kci label is left on it")
        assert_equal(st.physical_id_for(_ctx().scope.key(String("logs/bucket"))), "", sh.name + ": record retired")
        var back = apply_resources(reg, cloud, _ctx(), _list(_logs(), String(_READER)), Creds.none(), st)
        assert_true(not back.error, sh.name + ": adopted again: " + (back.error.value() if back.error else String("")))
        assert_equal(_label_of(cloud, String("logs/bucket"), String("kci_adopted")), "true", "marked again")
    print("  test_a_failed_retire_is_reported_and_retried: PASS")


def test_a_marked_object_relisted_needs_adopt() raises:
    """Catches: an object left stamped and marked by a failed release taken
    for kci's own when the file names it again without `adopt` (mutant: no
    `unadopted_findings` in `_prepare`; the apply would succeed and the
    bucket would be kci's to delete), a refusal that changes something
    first, and the same file with `adopt` refused."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("re2m-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        var st = InMemoryStateStore()
        _adopted(cloud, reg, _list(_logs(), String(_READER)), st)
        cloud.store[].fail_at_call = cloud.store[]._attempts + 1
        var out = apply_resources(reg, cloud, _ctx(), _list(String(_READER)), Creds.none(), st)
        assert_true(Bool(out.error), sh.name + ": the release failed")
        assert_equal(_label_of(cloud, String("logs/bucket"), String("kci_adopted")), "true", "still marked")
        var plain = _list(_logs(adopt=False), String(_READER))
        var says = _refused(cloud, reg, plain, st, False)
        assert_true(says.find("logs/bucket: the object carries kci's adoption mark") >= 0, sh.name + ": " + says)
        var plan_says = String("")
        try:
            _ = plan_report(reg, cloud, _ctx(), plain, Creds.none(), st)
        except e:
            plan_says = String(e)
        assert_equal(plan_says, says, sh.name + ": the plan refuses the same way")
        var back = apply_resources(reg, cloud, _ctx(), _list(_logs(), String(_READER)), Creds.none(), st)
        assert_true(not back.error, sh.name + ": with adopt: " + (back.error.value() if back.error else String("")))
        assert_true(_listed(cloud, String("logs/bucket")), sh.name + ": still kci's")
        assert_equal(_label_of(cloud, String("logs/bucket"), String("kci_adopted")), "true", "still marked")
    print("  test_a_marked_object_relisted_needs_adopt: PASS")


# ---- 3. destroy ----------------------------------------------------------------------------------


def test_destroy_needs_adopt_deletable_value() raises:
    """Catches: a destroy that deletes an adopted object without the opt-in
    (mutant: `delete_findings` dropped, or not run on destroy), a refusal
    that changes something first, and the opt-in ignored (mutant:
    `deletable` always False)."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("re3-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        var st = InMemoryStateStore()
        _adopted(cloud, reg, _list(_logs(retention=String("DELETE")), String(_READER)), st)
        var says = _refused(cloud, reg, _list(_logs(retention=String("DELETE")), String(_READER)), st, True)
        assert_true(says.find("logs/bucket: kci adopted this object") >= 0, sh.name + ": " + says)
        assert_true(says.find("this destroy would delete it") >= 0, says)
        assert_true(says.find("Write adopt ADOPT_DELETABLE on the resource") >= 0, says)
        assert_true(says.find("remove the resource from the list to release the object") >= 0, says)
        assert_true(cloud.store[].find(String("logs/bucket")) >= 0)
        var opted = _list(_logs(retention=String("DELETE"), deletable=True), String(_READER))
        _ = destroy_resources(reg, cloud, _ctx(), opted, Creds.none(), st)
        assert_equal(cloud.live_count(), 0, sh.name + ": with ADOPT_DELETABLE the destroy deletes it")
        assert_true(_served(cloud, String("delete logs/bucket")))
    print("  test_destroy_needs_adopt_deletable_value: PASS")


def test_destroy_judges_by_the_file_retention_not_the_label() raises:
    """Proves a destroy is judged by the retention the engine deletes by (the
    file's), not the label the object was stamped with. `logs` is adopted
    under KEEP (the bucket default, so its label says retain); a destroy of a
    file that now writes it DELETE would delete it, so it is refused before
    any change, no delete call reaches the adapter, and the object stands.
    The same destroy with the file still KEEP deletes nothing and is not
    refused. Catches: the skip read from the object's label (mutant:
    `rec.retained` in `delete_findings`; the DELETE destroy deletes the
    adopted bucket with no opt-in)."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("re3k-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        var st = InMemoryStateStore()
        _adopted(cloud, reg, _list(_logs(), String(_READER)), st)
        var says = _refused(cloud, reg, _list(_logs(retention=String("DELETE")), String(_READER)), st, True)
        assert_true(says.find("logs/bucket: kci adopted this object") >= 0, sh.name + ": " + says)
        assert_true(says.find("this destroy would delete it") >= 0, says)
        assert_true(not _served(cloud, String("delete logs/bucket")), sh.name + ": no delete reaches the adapter")
        assert_true(cloud.store[].find(String("logs/bucket")) >= 0, sh.name + ": the adopted bucket stands")
        _ = destroy_resources(reg, cloud, _ctx(), _list(_logs(), String(_READER)), Creds.none(), st)
        assert_true(not _served(cloud, String("delete logs/bucket")), sh.name + ": a KEEP destroy deletes nothing")
        assert_true(cloud.store[].find(String("logs/bucket")) >= 0, sh.name + ": still standing")
    print("  test_destroy_judges_by_the_file_retention_not_the_label: PASS")


# ---- 4. the resource stays but no longer lowers it ---------------------------------------------------


def test_a_type_change_does_not_delete_an_adopted_object() raises:
    """Catches: the delete of an adopted object whose resource now lowers
    other roles let through (it would be a role to remove), a plan that is
    not refused the same way, and an adopted object kept by retention
    refused (mutant: the retained skip dropped) or deleted."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        ref sh = shapes[s]
        var id = String("re4-") + sh.name
        var cloud = FakeCloud(id, shape=sh.copy())
        var reg = _reg(FakeCloud(id, shape=sh.copy()))
        var st = InMemoryStateStore()
        _adopted(cloud, reg, _list(_logs(retention=String("DELETE")), String(_READER)), st)
        var secret = _list(String('{"id":"logs","secret":{}}'), String(_READER))
        var says = _refused(cloud, reg, secret, st, False)
        assert_true(says.find("logs/bucket: kci adopted this object") >= 0, sh.name + ": " + says)
        assert_true(says.find("the resource no longer lowers it") >= 0, says)
        var plan_says = String("")
        try:
            _ = plan_report(reg, cloud, _ctx(), secret, Creds.none(), st)
        except e:
            plan_says = String(e)
        assert_equal(plan_says, says, sh.name + ": the plan refuses the same way")

        var kid = String("re4k-") + sh.name
        var kept = FakeCloud(kid, shape=sh.copy())
        var kreg = _reg(FakeCloud(kid, shape=sh.copy()))
        var kst = InMemoryStateStore()
        _adopted(kept, kreg, _list(_logs(retention=String("KEEP")), String(_READER)), kst)
        var out = apply_resources(kreg, kept, _ctx(), secret, Creds.none(), kst)
        assert_true(not out.error, sh.name + ": " + (out.error.value() if out.error else String("")))
        var behind = False
        for i in range(len(out.left_behind)):
            if out.left_behind[i] == "logs/bucket":
                behind = True
        assert_true(behind, sh.name + ": a kept adopted bucket is left behind")
        assert_true(not _served(kept, String("delete logs/bucket")), "and never deleted")
    print("  test_a_type_change_does_not_delete_an_adopted_object: PASS")


# ---- 5. a component a definition drops ---------------------------------------------------------------


def _keep(version: Int) raises -> List[CompositeDefinition]:
    var files = String('{"id":"files","physicalName":"acme-files","retention":"DELETE","adopt":"ADOPT","bucket":{}},')
    var made = String('{"id":"made","retention":"DELETE","bucket":{}},')
    var comps = (files if version == 1 else String("")) + made + String('{"id":"scratch","bucket":{}}')
    if version == 3:
        comps = String('{"id":"scratch","bucket":{}}')
    var out = List[CompositeDefinition]()
    out.append(
        decode_json[CompositeDefinition](
            String('{"name":"acme.keep","version":"') + String(version) + String('","component":[') + comps
            + String("]}")
        )
    )
    return out^


def _site(version: Int) raises -> List[Resource]:
    return _list(String('{"id":"site","composite":{"definition":"acme.keep","version":"') + String(version) + String('"}}'))


def test_a_dropped_component_releases_its_adopted_object() raises:
    """Catches: an adopted component's object deleted as a role of its
    owner (mutant: the release keyed on the owner `site`, which is still in
    the list, instead of the resource `site/files`), and a component kci
    created no longer deleted when its definition drops it."""
    var cloud = FakeCloud(String("re5"))
    var reg = _reg(FakeCloud(String("re5")))
    var st = InMemoryStateStore()
    var x = expand(Catalog.v1(), _keep(1), _site(1))
    var nodes = lower_data(cloud, x.resources)
    for i in range(len(nodes)):
        if nodes[i].adopted:
            assert_equal(nodes[i].id, "site/files/bucket")
            cloud.plant_like(nodes[i])
    var first = apply_resources(reg, cloud, _ctx(), _site(1), Creds.none(), st, _keep(1))
    assert_true(not first.error, first.error.value() if first.error else String(""))
    var out = apply_resources(reg, cloud, _ctx(), _site(2), Creds.none(), st, _keep(2))
    assert_true(not out.error, out.error.value() if out.error else String(""))
    assert_equal(len(out.released), 1)
    assert_equal(out.released[0], "site/files/bucket")
    assert_true(not _served(cloud, String("delete site/files/bucket")), "no delete call")
    assert_true(cloud.store[].find(String("site/files/bucket")) >= 0, "the object still stands")
    var gone = apply_resources(reg, cloud, _ctx(), _site(3), Creds.none(), st, _keep(3))
    assert_true(not gone.error, gone.error.value() if gone.error else String(""))
    assert_true(_served(cloud, String("delete site/made/bucket")), "a component kci created is deleted")
    print("  test_a_dropped_component_releases_its_adopted_object: PASS")


def _del(adopt: String) raises -> List[CompositeDefinition]:
    var out = List[CompositeDefinition]()
    out.append(
        decode_json[CompositeDefinition](
            String('{"name":"acme.del","version":"1","component":[')
            + String('{"id":"files","physicalName":"acme-files","retention":"DELETE","adopt":"') + adopt
            + String('","bucket":{}},{"id":"made","retention":"DELETE","bucket":{}}]}')
        )
    )
    return out^


def test_a_component_adopt_deletable_is_honoured_on_destroy() raises:
    """Catches: the opt-in read from the instance's owner `site` instead of
    the component resource `site/files` (mutant: `delete_findings` asks
    `deletable` about `site`, which is no resource of the expanded list, so
    the ADOPT_DELETABLE destroy is refused), and a component that writes
    ADOPT deleted by a destroy."""
    var site = _list(String('{"id":"site","composite":{"definition":"acme.del","version":"1"}}'))
    var cloud = FakeCloud(String("re6"))
    var reg = _reg(FakeCloud(String("re6")))
    var st = InMemoryStateStore()
    var x = expand(Catalog.v1(), _del(String("ADOPT")), site)
    var nodes = lower_data(cloud, x.resources)
    for i in range(len(nodes)):
        if nodes[i].adopted:
            cloud.plant_like(nodes[i])
    var first = apply_resources(reg, cloud, _ctx(), site, Creds.none(), st, _del(String("ADOPT")))
    assert_true(not first.error, first.error.value() if first.error else String(""))
    var before = cloud.mutations()
    var says = String("")
    try:
        _ = destroy_resources(reg, cloud, _ctx(), site, Creds.none(), st, _del(String("ADOPT")))
    except e:
        says = String(e)
    assert_true(says.find("site/files/bucket: kci adopted this object") >= 0, "ADOPT refuses the destroy: " + says)
    assert_equal(cloud.mutations(), before, "the refusal changed nothing")
    _ = destroy_resources(reg, cloud, _ctx(), site, Creds.none(), st, _del(String("ADOPT_DELETABLE")))
    assert_true(_served(cloud, String("delete site/files/bucket")), "ADOPT_DELETABLE: the adopted bucket is deleted")
    assert_equal(cloud.live_count(), 0, "the whole instance is destroyed")
    print("  test_a_component_adopt_deletable_is_honoured_on_destroy: PASS")


def main() raises:
    print("test_fake_adoption_release")
    test_a_resource_leaving_the_list_releases_its_adopted_object()
    test_a_failed_release_is_reported_and_retried()
    test_a_failed_retire_is_reported_and_retried()
    test_a_marked_object_relisted_needs_adopt()
    test_destroy_needs_adopt_deletable_value()
    test_destroy_judges_by_the_file_retention_not_the_label()
    test_a_type_change_does_not_delete_an_adopted_object()
    test_a_dropped_component_releases_its_adopted_object()
    test_a_component_adopt_deletable_is_honoured_on_destroy()
    print("ALL FAKE ADOPTION RELEASE TESTS PASSED")
