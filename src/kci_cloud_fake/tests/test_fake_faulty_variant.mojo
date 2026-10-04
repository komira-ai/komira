# =============================================================================
# test_fake_faulty_variant.mojo: the faulty fake cloud, and the cell's side.
# =============================================================================
#
# 1. READ LAG: with reads one step behind every create and delete, applies
#    may fail loud part-way (a value not yet readable, a create that meets
#    its own object), but nothing is ever created twice, the cell converges
#    within a few runs, and a destroy retires a record only when the object
#    is gone (it fails loud while the read still shows it).
# 2. A PRE-EXISTING FOREIGN OBJECT: an object of a wanted name made outside
#    kci refuses the apply before any change; adopting it by name stamps it,
#    and the run after is a no-op.
# 3. THE CELL'S SETTINGS AND TRUST on fake: an unknown setting and a bad
#    public mechanism refuse the graph; `none` chooses no mechanism, and a
#    public service is then refused at validate time; the cell's principal
#    is what `trust_check` accepts; fake-limited takes no public mechanism.
# 4. THE REST OF THE INTERFACE: bootstrap resources (the state store
#    first), whoami, trust_render, and list_owned (filtered to the cell,
#    with the run that made each object).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

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
    Setting,
    apply_resources,
    describe,
    destroy_resources,
    plan_resources,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, FakeLimitedCloud


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _graph() -> String:
    return String(
        '{"resource":['
        '{"id":"web","service":{"image":{"digest":"sha256:c3"},"internal":{},'
        '"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}}}},'
        '"uses":[{"target":{"resource":"api"},"access":"CALL"}]},'
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"public":{}}}'
        "]}"
    )


def _reg() raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    reg.add(describe(FakeLimitedCloud()))
    return reg^


def test_read_lag_never_creates_twice_and_converges() raises:
    var reg = _reg()
    var fake = FakeCloud(read_lag=1)
    var store = InMemoryStateStore()
    var creds = Creds.none()
    var graph = _list(_graph())
    var runs = 0
    var failures = 0
    while True:
        runs += 1
        assert_true(runs <= 6, "the cell converges within a few runs")
        var o = apply_resources(reg, fake, _ctx(), graph, creds, store)
        if o.ok():
            break
        failures += 1
    assert_true(failures >= 1, "a read one step behind does fail a run part-way")
    for id in ["web/run", "api/run", "api/public", "web/uses/api"]:
        assert_equal(fake.store[].creates_of(String(id)), 1, String(id) + " was created once")
    var o2 = apply_resources(reg, fake, _ctx(), graph, creds, store)
    assert_true(o2.ok())
    for k in range(len(o2.applied)):
        assert_equal(o2.applied[k].verb, VERB_NOOP, o2.applied[k].logical_id + " settled")

    # destroy: the read still shows a deleted object for one more read, so the
    # first teardown fails loud on it; a re-run finishes. Nothing is left.
    var tries = 0
    var loud = False
    while fake.live_count() > 0 or tries == 0:
        tries += 1
        assert_true(tries <= 6, "the teardown converges")
        try:
            _ = destroy_resources(reg, fake, _ctx(), graph, creds, store)
        except e:
            loud = _has(String(e), "STILL PRESENT") or loud
    assert_true(loud, "a delete the read cannot confirm yet fails loud")
    assert_equal(fake.live_count(), 0)
    print("  test_read_lag_never_creates_twice_and_converges: PASS")


def test_a_pre_existing_foreign_object_is_refused_then_adopted() raises:
    var reg = _reg()
    var foreign = List[String]()
    foreign.append(String("api/run"))
    var fake = FakeCloud(foreign=foreign)
    var store = InMemoryStateStore()
    var creds = Creds.none()
    var o = apply_resources(reg, fake, _ctx(), _list(_graph()), creds, store)
    assert_true(o.refused(), "refused before any change")
    assert_true(_has(o.error.value(), "api/run: foreign"), o.error.value())
    assert_equal(len(fake.store[].calls), 0, "not one call")
    assert_equal(fake.live_count(), 1, "only the foreign object exists")

    var adopt = _ctx()
    adopt.scope.adopt.append(String("api/run"))
    var a = apply_resources(reg, fake, adopt, _list(_graph()), creds, store)
    assert_true(a.ok(), a.error.value() if a.error else String(""))
    for k in range(len(a.applied)):
        if a.applied[k].logical_id == "api/run":
            assert_equal(a.applied[k].verb, VERB_UPDATE, "stamped, then converged")
    assert_equal(fake.store[].creates_of(String("api/run")), 0, "never re-created")
    var again = apply_resources(reg, fake, _ctx(), _list(_graph()), creds, store)
    assert_true(again.ok())
    for k in range(len(again.applied)):
        assert_equal(again.applied[k].verb, VERB_NOOP, again.applied[k].logical_id)
    print("  test_a_pre_existing_foreign_object_is_refused_then_adopted: PASS")


def test_the_cells_settings_and_trust() raises:
    var reg = _reg()
    var fake = FakeCloud()
    var store = InMemoryStateStore()
    var creds = Creds.none()

    var bad = _ctx()
    bad.settings.append(Setting(String("public_mechanism"), String("teleport")))
    bad.settings.append(Setting(String("zone"), String("x")))
    var msg = String("")
    try:
        _ = plan_resources(reg, fake, bad, _list(_graph()), creds, store)
    except e:
        msg = String(e)
    assert_true(_has(msg, '"teleport" is not invoker, gateway or none'), msg)
    assert_true(_has(msg, "settings.zone: not a setting of this cloud"), msg)

    var none = _ctx()
    none.settings.append(Setting(String("public_mechanism"), String("none")))
    var msg2 = String("")
    try:
        _ = apply_resources(reg, fake, none, _list(_graph()), creds, store)
    except e:
        msg2 = String(e)
    assert_true(_has(msg2, 'resource "api" field service.public: this cell\'s settings choose no public mechanism'), msg2)
    assert_equal(fake.live_count(), 0)

    var gw = _ctx()
    gw.settings.append(Setting(String("public_mechanism"), String("gateway")))
    gw.settings.append(Setting(String("principal"), String("deployer")))
    var o = apply_resources(reg, fake, gw, _list(_graph()), creds, store)
    assert_true(o.ok())
    var i = fake.store[].find(String("api/public"))
    assert_true(_has(fake.store[].digests[i], "mechanism=gateway"), fake.store[].digests[i])
    assert_equal(len(fake.trust_check(Creds(String("deployer")), gw.scope)), 0)
    var tf = fake.trust_check(Creds(String("someone")), gw.scope)
    assert_equal(len(tf), 1)
    assert_true(_has(tf[0].reason, "not the cell's principal \"deployer\""), tf[0].reason)
    assert_true(_has(fake.trust_render(gw.scope), "cell blue of shop is deployed by deployer"))

    var limited = FakeLimitedCloud()
    var limited_ctx = _ctx()
    limited_ctx.settings.append(Setting(String("public_mechanism"), String("invoker")))
    var f = limited.configure(limited_ctx)
    assert_equal(len(f), 1)
    assert_true(_has(f[0].reason, "no public ingress"), f[0].reason)
    print("  test_the_cells_settings_and_trust: PASS")


def test_bootstrap_whoami_and_list_owned() raises:
    var reg = _reg()
    var fake = FakeCloud()
    var store = InMemoryStateStore()
    var boot = fake.bootstrap_resources(String("shop"), String("blue"))
    assert_equal(len(boot), 2)
    assert_equal(boot[0].kind, "state-store", "the state store is created first")
    assert_equal(boot[0].name, "shop-blue-ledger")
    var me = fake.whoami(Creds(String("deployer")))
    assert_equal(me.principal, "deployer")
    assert_equal(me.account, "fake:fake")
    assert_equal(fake.whoami(Creds.none()).principal, "fake-anonymous")

    var o = apply_resources(reg, fake, _ctx(), _list(_graph()), Creds.none(), store)
    assert_true(o.ok())
    var owned = fake.list_owned(Creds.none(), _ctx().scope)
    assert_equal(len(owned), 4, "web/run, web/uses/api, api/run, api/public")
    var saw_grant = False
    for k in range(len(owned)):
        assert_equal(owned[k].run_id, "run-1", "the run that made it")
        assert_true(owned[k].deletable_by_kci)
        if owned[k].owner_node == "web/uses/api":
            saw_grant = True
    assert_true(saw_grant, "a role with a slash is decoded exactly")
    var green = CellScope(String("shop"), String("green"))
    assert_equal(len(fake.list_owned(Creds.none(), green)), 0, "another cell owns nothing here")
    print("  test_bootstrap_whoami_and_list_owned: PASS")


def main() raises:
    print("test_fake_faulty_variant")
    test_read_lag_never_creates_twice_and_converges()
    test_a_pre_existing_foreign_object_is_refused_then_adopted()
    test_the_cells_settings_and_trust()
    test_bootstrap_whoami_and_list_owned()
    print("ALL kci_cloud_fake FAULTY VARIANT TESTS PASSED")
