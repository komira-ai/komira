# =============================================================================
# test_fake_derived_grants.mojo
# =============================================================================
#
# The gcp fake's grants are member bindings whose stamp is DERIVED
# (kci_cloud/derived.mojo), the two kit steps that came with it, and the
# cell's image registry:
#
# 1. THE KIT, ALL FIFTEEN STEPS, on the gcp fake over a graph with a public
#    service, a CALL edge, an account's READ on a bucket and each identity's
#    cell LOGS edge. Steps 14 and 15 are shown to have run: the members the
#    kit planted on the cell scope are still there (never removed), one a
#    foreign identity, one an unmapped role, and step 15 failed the create
#    of every wanted node of `base`'s lowering, each once.
# 2. BORN WITH NO LABELS: every binding object of an apply carries no label
#    as stored, yet reads as its own node's stamp (identity, retention, run
#    id), and `list_owned` names it; on aws the same grants carry labels.
# 3. A FOREIGN MEMBER IS REPORTED AND KEPT, on an owned target's policy and
#    on the cell scope's: the plan keeps the node a NOOP and reports it, an
#    apply makes no call, the member stays. A member of ANOTHER MACHINE
#    whose cell has this cell's name is foreign too.
# 4. `check` REFUSES, ON THE GCP FAKE, a grant resource and a `uses` line on
#    a workload with `run_as`, before any call; aws plans both.
# 5. THE IMAGE REGISTRY is the bootstrap registry's name, and two cells
#    differ; `registry_login` presents the token.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    CellScope,
    Creds,
    InMemoryStateStore,
    LABEL_MACHINE,
    Provenance,
    VERB_NOOP,
)
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    MEMBER_CELL,
    MEMBER_FOREIGN,
    ROLE_MAPPED,
    ROLE_UNMAPPED,
    apply_resources,
    decode_label_value,
    describe,
    encode_label_value,
    label_problems,
    lower_data,
    plan_resources,
    retained_by,
    run_conformance,
    validation_run_of,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import (
    CELL_SCOPE,
    FakeCloud,
    FakeLimitedCloud,
    OUTSIDE_PREFIX,
    ProviderShape,
    UNMAPPED_ROLE,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx(cell: String = String("blue")) -> CellContext:
    return CellContext(CellScope(String("shop"), cell, Provenance(String("run-1"), String("rev-1"))))


def _reg(cloud: FakeCloud) raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    return reg^


def _graph(port: String = String("8080"), roles_on: Bool = True) -> String:
    """runner READ media (a binding on an owned target), a public api (its
    public binding), web CALL api, and each own identity's cell LOGS edge.
    `roles_on` False makes api internal and drops web's CALL line."""
    var exposure = String('"public":{}') if roles_on else String('"internal":{}')
    var web_uses = String('{"target":{"resource":"api"},"access":"CALL"}') if roles_on else String("")
    return (
        String('{"resource":[')
        + String('{"id":"runner","serviceAccount":{},"uses":[{"target":{"resource":"media"},"access":"READ"}]},')
        + String('{"id":"media","retention":"DELETE","bucket":{}},')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":') + port + String(",")
        + exposure + String("}},")
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"internal":{},')
        + String('"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}}}},')
        + String('"uses":[') + web_uses + String("]}")
        + String("]}")
    )


def _done(outcome: ApplyOutcome) raises:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())


def _bindings(cloud: FakeCloud, json: String) raises -> List[String]:
    """The wanted nodes of `json` the gcp fake stores as member bindings."""
    var out = List[String]()
    var nodes = lower_data(cloud, _list(json))
    var shape = ProviderShape.gcp()
    for i in range(len(nodes)):
        if nodes[i].wanted and shape.is_binding(nodes[i].kind):
            out.append(nodes[i].id.copy())
    return out^


def _first_with(cloud: FakeCloud, json: String, field: String) raises -> String:
    var nodes = lower_data(cloud, _list(json))
    for i in range(len(nodes)):
        if nodes[i].wanted and nodes[i].field(String("access")).byte_length() > 0:
            if nodes[i].field(field).byte_length() > 0:
                return nodes[i].id.copy()
    raise Error(String("no grant node with ") + field)


# ---- 1. the kit ----------------------------------------------------------------------


def test_the_gcp_fake_passes_all_fifteen_steps() raises:
    """Catches: a binding whose derived stamp is not its node's (steps 3, 12,
    15), a foreign member taken as the cell's or removed (step 14), an object
    created before it is stamped (step 15); and a kit whose steps 14 and 15
    silently do nothing, or whose step 15 arms only some nodes (the members
    it planted and every create it failed are asserted below)."""
    var cloud = FakeCloud(String("p-d3r"), shape=ProviderShape.gcp())
    var reg = _reg(FakeCloud(String("p-d3r"), shape=ProviderShape.gcp()))
    run_conformance(
        reg, cloud, _ctx(), _list(_graph()), _list(_graph(String("9090"))),
        _list(_graph(String("9090"), False)), String("api/run"),
    )
    ref s = cloud.store[]
    var on_cell = 0
    var foreign = 0
    var unmapped = 0
    for k in range(len(s.planted_key)):
        if s.planted_key[k] == CELL_SCOPE:
            on_cell += 1
            if s.planted_member[k].startswith(OUTSIDE_PREFIX):
                foreign += 1
            if s.planted_role[k] == UNMAPPED_ROLE:
                unmapped += 1
    assert_equal(on_cell, 2, "step 14 planted two members on the cell scope, and they stayed")
    assert_equal(foreign, 1, "one is an identity of another cell")
    assert_equal(unmapped, 1, "one holds a role the table does not map")
    var wanted = List[String]()
    var lowered = lower_data(cloud, _list(_graph()))
    for i in range(len(lowered)):
        if lowered[i].wanted:
            wanted.append(lowered[i].id.copy())
    assert_true(len(wanted) > 1, "base lowers several nodes, so a kit that arms only one is visible")
    assert_equal(len(s.failed_log), len(wanted), "step 15 failed one create per wanted node")
    for w in range(len(wanted)):
        var hits = 0
        for k in range(len(s.failed_log)):
            if s.failed_log[k] == wanted[w]:
                hits += 1
        assert_equal(hits, 1, "step 15 failed the create of " + wanted[w] + " once")
    print("  test_the_gcp_fake_passes_all_fifteen_steps: PASS")


# ---- 2. born with no labels ------------------------------------------------------------


def test_a_binding_carries_no_label_and_reads_as_its_node() raises:
    var cloud = FakeCloud(String("p-g"), shape=ProviderShape.gcp())
    var reg = _reg(FakeCloud(String("p-g"), shape=ProviderShape.gcp()))
    var ctx = _ctx()
    ctx.scope.validation_run_id = String("vr-9")
    var store = InMemoryStateStore()
    _done(apply_resources(reg, cloud, ctx, _list(_graph()), Creds.none(), store))
    var bindings = _bindings(cloud, _graph())
    assert_true(len(bindings) >= 5, "public, CALL, READ and the LOGS edges are bindings")
    var owned = cloud.list_owned(Creds.none(), ctx.scope)
    var nodes = lower_data(cloud, _list(_graph()))
    for b in range(len(bindings)):
        ref id = bindings[b]
        var i = cloud.store[].find(id)
        assert_true(i >= 0, id + " is live")
        assert_equal(len(cloud.store[].labels[i]), 0, id + ": a binding is stored with no label")
        var labels = cloud.live_labels(id)
        assert_equal(len(label_problems(labels)), 0, id)
        var owner = String("")
        for k in range(len(nodes)):
            if nodes[k].id == id:
                owner = nodes[k].owner.copy()
        assert_equal(cloud.identity_of(labels), ctx.scope.stamp(owner, id).identity(), id + ": derived stamp")
        assert_false(retained_by(labels), id + ": its resource's retention, DELETE")
        assert_equal(validation_run_of(labels).value(), "vr-9", id + ": the run of the identity it binds")
        var listed = False
        for k in range(len(owned)):
            if owned[k].owner_node == id:
                listed = True
        assert_true(listed, id + ": list_owned names it")

    var aws = FakeCloud(String("p-a"), shape=ProviderShape.aws())
    var areg = _reg(FakeCloud(String("p-a"), shape=ProviderShape.aws()))
    var astore = InMemoryStateStore()
    _done(apply_resources(areg, aws, _ctx(), _list(_graph()), Creds.none(), astore))
    var grant = _first_with(aws, _graph(), String("target"))
    assert_true(len(aws.store[].labels[aws.store[].find(grant)]) > 0, "aws: a grant object carries its labels")
    print("  test_a_binding_carries_no_label_and_reads_as_its_node: PASS")


# ---- 3. a foreign member is reported and kept --------------------------------------------


def _unmanaged(mut cloud: FakeCloud, reg: Clouds, node: String, mut store: InMemoryStateStore) raises -> String:
    var plan = plan_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), store)
    for i in range(len(plan)):
        if plan[i].logical_id == node:
            assert_equal(plan[i].verb, VERB_NOOP, node + ": a planted member is no change of the node")
            return plan[i].unmanaged.copy()
    raise Error(node + String(" was not planned"))


def test_a_foreign_member_is_reported_and_kept() raises:
    """Catches: a planted member not reported (an apply would then be blind
    to it), or removed by an apply (a binding kci did not write)."""
    var cloud = FakeCloud(String("p-f"), shape=ProviderShape.gcp())
    var reg = _reg(FakeCloud(String("p-f"), shape=ProviderShape.gcp()))
    var store = InMemoryStateStore()
    _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), store))
    for field in [String("target"), String("cell")]:
        var node = _first_with(cloud, _graph(), field)
        assert_equal(_unmanaged(cloud, reg, node, store), "", node + ": nothing planted yet")
        cloud.plant_foreign_member(node, String(MEMBER_FOREIGN), String(ROLE_MAPPED))
        var one = _unmanaged(cloud, reg, node, store)
        assert_true(one.find(String(OUTSIDE_PREFIX)) >= 0, node + ": the foreign member is reported: " + one)
        cloud.plant_foreign_member(node, String(MEMBER_CELL), String(ROLE_UNMAPPED))
        var two = _unmanaged(cloud, reg, node, store)
        assert_true(two.find(String(UNMAPPED_ROLE)) >= 0, node + ": the unmapped role is reported: " + two)
        var m = cloud.mutations()
        _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), store))
        assert_equal(cloud.mutations(), m, node + ": the apply made no call")
        assert_true(cloud.member_present(node, String(MEMBER_FOREIGN), String(ROLE_MAPPED)), node + ": kept")
        assert_true(cloud.member_present(node, String(MEMBER_CELL), String(ROLE_UNMAPPED)), node + ": kept")
        assert_true(cloud.member_present(node, String(MEMBER_CELL), String(ROLE_MAPPED)), node + ": its own")
    print("  test_a_foreign_member_is_reported_and_kept: PASS")


def test_a_member_of_another_machine_is_foreign() raises:
    """THE MEMBER CHECK on the fake, its machine half: an identity of another
    machine whose cell has this cell's name (two machines in one project),
    holding the node's own mapped role, on an owned target's policy and on
    the cell scope's. Catches: a check that compares only the cells (the
    member then reads as this cell's own binding and is not reported)."""
    var cloud = FakeCloud(String("p-m"), shape=ProviderShape.gcp())
    var reg = _reg(FakeCloud(String("p-m"), shape=ProviderShape.gcp()))
    var store = InMemoryStateStore()
    _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), store))
    for field in [String("target"), String("cell")]:
        var node = _first_with(cloud, _graph(), field)
        var i = cloud.store[].find(node)
        var principal = cloud.store[].b_member[i].copy()
        var src = cloud.store[].find(principal)
        assert_true(src >= 0, principal + " is live")
        var labels = cloud.store[].labels[src].copy()
        var changed = 0
        for k in range(len(labels)):
            if labels[k].key == LABEL_MACHINE:
                labels[k].value = encode_label_value(decode_label_value(labels[k].value) + String("-depot"))
                changed += 1
        assert_equal(changed, 1, "the principal carries one machine label")
        var id = String(OUTSIDE_PREFIX) + String("machine/") + principal
        cloud.store[].outside_ids.append(id)
        cloud.store[].outside_labels.append(labels^)
        cloud.store[].planted_key.append(cloud.store[].b_target[i].copy())
        cloud.store[].planted_member.append(id)
        cloud.store[].planted_role.append(cloud.store[].b_role[i].copy())
        var report = _unmanaged(cloud, reg, node, store)
        assert_true(report.find(id) >= 0, node + ": the other machine's member is reported: " + report)
        var m = cloud.mutations()
        _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), store))
        assert_equal(cloud.mutations(), m, node + ": the apply made no call")
    print("  test_a_member_of_another_machine_is_foreign: PASS")


# ---- 4. check refuses what cannot be derived ---------------------------------------------


comptime _WITH_GRANT = (
    '{"resource":[{"id":"runner","serviceAccount":{}},{"id":"media","bucket":{}},'
    + '{"id":"reads","grant":{"principal":{"resource":"runner"},"target":{"resource":"media"},"access":"READ"}}]}'
)
comptime _RUN_AS_USES = (
    '{"resource":[{"id":"runner","serviceAccount":{}},{"id":"media","bucket":{}},'
    + '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"runAs":{"resource":"runner"}},'
    + '"uses":[{"target":{"resource":"media"},"access":"READ"}]}]}'
)


def _refused(shape: ProviderShape, json: String) raises -> String:
    var cloud = FakeCloud(String("p-c"), shape=shape.copy())
    var reg = _reg(FakeCloud(String("p-c"), shape=shape.copy()))
    var store = InMemoryStateStore()
    try:
        _ = plan_resources(reg, cloud, _ctx(), _list(json), Creds.none(), store)
    except e:
        assert_equal(cloud.mutations(), 0, "nothing was created")
        return String(e)
    return String("")


def test_check_refuses_a_grant_and_uses_on_run_as_on_gcp() raises:
    """Catches: either refusal removed from `check` on a DERIVED shape (the
    case would plan), or leaked to a labelled shape (aws would refuse)."""
    var g = _refused(ProviderShape.gcp(), String(_WITH_GRANT))
    assert_true(g.find('resource "reads" field grant: cloud "p-c" derives a binding') >= 0, g)
    var u = _refused(ProviderShape.gcp(), String(_RUN_AS_USES))
    assert_true(u.find('resource "api" field uses: cloud "p-c" derives a binding') >= 0, u)
    assert_true(u.find('write the uses line on "runner" itself') >= 0, u)
    assert_equal(_refused(ProviderShape.aws(), String(_WITH_GRANT)), "", "aws plans a grant resource")
    assert_equal(_refused(ProviderShape.aws(), String(_RUN_AS_USES)), "", "aws plans uses on run_as")
    print("  test_check_refuses_a_grant_and_uses_on_run_as_on_gcp: PASS")


# ---- 5. the image registry -------------------------------------------------------------


def test_the_image_registry_is_the_cells_bootstrap_registry() raises:
    """Catches: an image registry that is not the one bootstrap creates, or
    one shared by two cells (a constant)."""
    for s in range(2):
        var shape = ProviderShape.gcp() if s == 0 else ProviderShape.generic()
        var cloud = FakeCloud(String("p-r"), shape=shape.copy())
        var blue = cloud.image_registry(_ctx(String("blue")))
        var green = cloud.image_registry(_ctx(String("green")))
        assert_true(blue != green, "two cells, two registries")
        var boot = cloud.bootstrap_resources(String("shop"), String("blue"))
        var named = String("")
        for i in range(len(boot)):
            if boot[i].kind == "registry":
                named = boot[i].name.copy()
        assert_equal(blue, named, "the bootstrap registry")
        var login = cloud.registry_login(Creds(String("tok-1")))
        assert_true(login.user.byte_length() > 0, "a user")
        assert_equal(login.secret, "tok-1", "the token is the secret")
    var limited = FakeLimitedCloud()
    assert_true(limited.image_registry(_ctx(String("blue"))) != limited.image_registry(_ctx(String("green"))))
    print("  test_the_image_registry_is_the_cells_bootstrap_registry: PASS")


def main() raises:
    print("test_fake_derived_grants")
    test_the_gcp_fake_passes_all_fifteen_steps()
    test_a_binding_carries_no_label_and_reads_as_its_node()
    test_a_foreign_member_is_reported_and_kept()
    test_a_member_of_another_machine_is_foreign()
    test_check_refuses_a_grant_and_uses_on_run_as_on_gcp()
    test_the_image_registry_is_the_cells_bootstrap_registry()
    print("ALL kci_cloud_fake DERIVED GRANT TESTS PASSED")
