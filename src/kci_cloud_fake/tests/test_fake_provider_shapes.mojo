# =============================================================================
# test_fake_provider_shapes.mojo
# =============================================================================
#
# The shaped fakes: `FakeCloud` built with a `ProviderShape` lowers each
# catalog type to that shape's own fixed roles and provider kinds.
#
# 1. THE TABLE: every row names a catalog field the fake implements; every
#    compute field (service, job) has a `run` row on every shape, and the
#    bucket exactly one row, `bucket`, and no identity; every role name is
#    at most 8 bytes (the role vocabulary's bound, which the label budget
#    counts on); the generic shape is the fake's own roles.
# 2. THE KIT ON EVERY SHAPE: the kci_cloud conformance kit (all eleven steps)
#    passes on the aws, gcp and azure shapes, each registered under a random
#    id, on the graph of test_fake_conformance (a public service, an internal
#    service reading its URL and HOST, a scheduled job, two grants).
# 3. A GOLDEN LOWERING PER SHAPE of one public service and one scheduled job
#    with one `uses` line: per node, its role and provider kind, in order;
#    the private identity the run depends on and the grant hangs off; on
#    azure, the public ingress and the schedule folded into the run node.
# 4. A FOLDED ROLE IS AN UPDATE: on azure, making a public service internal
#    updates its run node and deletes nothing; on aws it deletes the public
#    role's object.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    Provenance,
    VERB_DELETE,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_cloud import (
    FIELD_BUCKET,
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    apply_resources,
    describe,
    lower_data,
    lowering_json,
    run_conformance,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, ProviderShape


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _shapes() -> List[ProviderShape]:
    var l = List[ProviderShape]()
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    return l^


# ---- 1. the table ------------------------------------------------------------------


def test_the_shape_table() raises:
    var fake = FakeCloud()
    var implemented = fake.implemented()
    var all = _shapes()
    all.append(ProviderShape.generic())
    for s in range(len(all)):
        ref shape = all[s]
        for i in range(len(shape.rows)):
            ref row = shape.rows[i]
            var known = False
            for k in range(len(implemented)):
                if implemented[k] == row.field:
                    known = True
            assert_true(known, shape.name + ": row field " + String(row.field) + " is implemented")
            assert_true(row.role.byte_length() <= 8, shape.name + ": role " + row.role + " is over 8 bytes")
            assert_true(row.kind.byte_length() > 0, shape.name + ": role " + row.role + " has a kind")
        for k in range(len(implemented)):
            if implemented[k] == FIELD_BUCKET:
                assert_equal(len(shape.roles_of(FIELD_BUCKET)), 1, shape.name + ": one bucket row")
                assert_true(shape.has(FIELD_BUCKET, String("bucket")), shape.name + ": the bucket row")
                continue
            assert_true(
                shape.has(implemented[k], String("run")),
                shape.name + ": field " + String(implemented[k]) + " has a run row",
            )
        assert_true(shape.grant_kind.byte_length() > 0, shape.name + " has a grant kind")
    var g = ProviderShape.generic()
    assert_equal(len(g.rows), 5, "generic: service run, public; job run, schedule; bucket")
    assert_true(not g.has(10, String("identity")), "generic has no identity role")
    assert_equal(g.grant_kind, "grant")
    print("  test_the_shape_table: PASS")


# ---- 2. the kit on every shape ---------------------------------------------------------


def _full(api_port: String, roles_on: Bool = True) -> String:
    """The graph of test_fake_conformance. `roles_on` False makes api
    internal and removes web's grant on api."""
    var web_uses = String('"uses":[{"target":{"resource":"api"},"access":"CALL"}]},')
    var exposure = String('"public":{}')
    if not roles_on:
        web_uses = String('"uses":[]},')
        exposure = String('"internal":{}')
    return (
        String('{"resource":[')
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"port":8080,"internal":{},')
        + String('"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}},')
        + String('"API_HOST":{"ref":{"resource":"api","standard":"HOST"}},')
        + String('"MODE":{"literal":"fast"}}},')
        + web_uses
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(",")
        + exposure
        + String(',"requestTimeout":"30s","scale":{"min":0,"max":3}},')
        + String('"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]},')
        + String('{"id":"nightly","job":{"image":{"digest":"sha256:b2"},"maxRetries":1,')
        + String('"schedule":{"cron":"0 3 * * *","timezone":"UTC"}}}')
        + String("]}")
    )


def test_every_shape_passes_the_kit_under_a_random_id() raises:
    var ids = List[String]()
    ids.append(String("p-7c21aa"))
    ids.append(String("p-0e93f4"))
    ids.append(String("p-b5d018"))
    var shapes = _shapes()
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shapes[s].copy())))
        var cloud = FakeCloud(ids[s], shape=shapes[s].copy())
        try:
            run_conformance(
                reg, cloud, _ctx(), _list(_full("8080")), _list(_full("9090")),
                _list(_full("9090", False)), String("api/run"),
            )
        except e:
            raise Error(shapes[s].name + String(" shape: ") + String(e))
    print("  test_every_shape_passes_the_kit_under_a_random_id: PASS")


# ---- 3. a golden lowering per shape -------------------------------------------------------


def _golden_graph() -> String:
    return String(
        '{"resource":['
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"public":{}}},'
        '{"id":"nightly","job":{"image":{"digest":"sha256:b2"},"schedule":{"cron":"0 3 * * *"}},'
        '"uses":[{"target":{"resource":"api"},"access":"CALL"}]}'
        "]}"
    )


comptime _SVC_FIELDS = (
    '"img":"sha256:a1@linux/amd64","port":"8080","size":"1000m/512MB","scale":"0..10",'
    '"health":"","timeout":"60s0n","concurrency":"0"'
)
comptime _JOB_FIELDS = (
    '"img":"sha256:b2@linux/amd64","size":"1000m/512MB","retries":"0","timeout":"600s0n"'
)


def _golden_with_roles(
    identity: String, service: String, public: String, job: String, schedule: String, grant: String
) -> String:
    """The lowering of `_golden_graph` on a shape with an identity, a public
    role and a schedule role (aws, gcp), given each role's provider kind."""
    return (
        String("[\n")
        + String('  {"id":"api/identity","owner":"api","kind":"') + identity
        + String('","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{}},\n')
        + String('  {"id":"api/run","owner":"api","kind":"') + service
        + String('","wanted":true,"retention":"delete","depends_on":["api/identity"],"inputs":[],"desired":{')
        + String(_SVC_FIELDS) + String(',"serves":"true"}},\n')
        + String('  {"id":"api/public","owner":"api","kind":"') + public
        + String('","wanted":true,"retention":"delete","depends_on":["api/run"],"inputs":[],"desired":{"mechanism":"invoker"}},\n')
        + String('  {"id":"nightly/identity","owner":"nightly","kind":"') + identity
        + String('","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{}},\n')
        + String('  {"id":"nightly/run","owner":"nightly","kind":"') + job
        + String('","wanted":true,"retention":"delete","depends_on":["nightly/identity"],"inputs":[],"desired":{')
        + String(_JOB_FIELDS) + String(',"serves":"false"}},\n')
        + String('  {"id":"nightly/schedule","owner":"nightly","kind":"') + schedule
        + String('","wanted":true,"retention":"delete","depends_on":["nightly/run"],"inputs":[],')
        + String('"desired":{"cron":"0 3 * * *","tz":"UTC"}},\n')
        + String('  {"id":"nightly/uses/api","owner":"nightly","kind":"') + grant
        + String('","wanted":true,"retention":"delete","depends_on":["nightly/identity","api/run"],"inputs":[],')
        + String('"desired":{"access":"CALL"}}\n')
        + String("]")
    )


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-91e3"), shape=shape.copy())
    var got = lowering_json(lower_data(cloud, _list(_golden_graph())))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


def test_golden_lowering_aws() raises:
    var want = _golden_with_roles(
        String("AWS::IAM::Role"),
        String("AWS::Lambda::Function"),
        String("AWS::Lambda::Url"),
        String("AWS::ECS::TaskDefinition"),
        String("AWS::Scheduler::Schedule"),
        String("AWS::IAM::RolePolicy"),
    )
    assert_equal(_lowered(ProviderShape.aws()), want)
    print("  test_golden_lowering_aws: PASS")


def test_golden_lowering_gcp() raises:
    var want = _golden_with_roles(
        String("iam.googleapis.com/ServiceAccount"),
        String("run.googleapis.com/Service"),
        String("setIamPolicy"),
        String("run.googleapis.com/Job"),
        String("cloudscheduler.googleapis.com/Job"),
        String("setIamPolicy"),
    )
    assert_equal(_lowered(ProviderShape.gcp()), want)
    print("  test_golden_lowering_gcp: PASS")


def test_golden_lowering_azure() raises:
    var ident = String("Microsoft.ManagedIdentity/userAssignedIdentities")
    var want = (
        String("[\n")
        + String('  {"id":"api/identity","owner":"api","kind":"') + ident
        + String('","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{}},\n')
        + String('  {"id":"api/run","owner":"api","kind":"Microsoft.App/containerApps",')
        + String('"wanted":true,"retention":"delete","depends_on":["api/identity"],"inputs":[],"desired":{')
        + String(_SVC_FIELDS) + String(',"ingress":"invoker","serves":"true"}},\n')
        + String('  {"id":"nightly/identity","owner":"nightly","kind":"') + ident
        + String('","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{}},\n')
        + String('  {"id":"nightly/run","owner":"nightly","kind":"Microsoft.App/jobs",')
        + String('"wanted":true,"retention":"delete","depends_on":["nightly/identity"],"inputs":[],"desired":{')
        + String(_JOB_FIELDS)
        + String(',"trigger":"schedule","trigger.cron":"0 3 * * *","trigger.tz":"UTC","serves":"false"}},\n')
        + String('  {"id":"nightly/uses/api","owner":"nightly","kind":"Microsoft.Authorization/roleAssignments",')
        + String('"wanted":true,"retention":"delete","depends_on":["nightly/identity","api/run"],"inputs":[],')
        + String('"desired":{"access":"CALL"}}\n')
        + String("]")
    )
    assert_equal(_lowered(ProviderShape.azure()), want)
    print("  test_golden_lowering_azure: PASS")


# ---- 4. a folded role is an update ---------------------------------------------------------


def _one(exposure: String) -> String:
    return (
        String('{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},')
        + exposure
        + String("}}]}")
    )


def _verbs(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def test_a_folded_role_turned_off_is_an_update() raises:
    var shapes = List[ProviderShape]()
    shapes.append(ProviderShape.azure())
    shapes.append(ProviderShape.aws())
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(String("p-3f"), shape=shapes[s].copy())))
        var cloud = FakeCloud(String("p-3f"), shape=shapes[s].copy())
        var store = InMemoryStateStore()
        _ = _done(apply_resources(reg, cloud, _ctx(), _list(_one(String('"public":{}'))), Creds.none(), store))
        var live = cloud.live_count()
        var off = _done(
            apply_resources(reg, cloud, _ctx(), _list(_one(String('"internal":{}'))), Creds.none(), store)
        )
        if shapes[s].name == "azure":
            assert_equal(_verbs(off, String("api/run")), VERB_UPDATE, "azure: the ingress is a run setting")
            assert_equal(cloud.live_count(), live, "azure: nothing deleted")
        else:
            assert_equal(_verbs(off, String("api/run")), VERB_NOOP, "aws: the run is unchanged")
            assert_equal(_verbs(off, String("api/public")), VERB_DELETE, "aws: the public role is deleted")
            assert_equal(cloud.live_count(), live - 1)
    print("  test_a_folded_role_turned_off_is_an_update: PASS")


def main() raises:
    print("test_fake_provider_shapes")
    test_the_shape_table()
    test_every_shape_passes_the_kit_under_a_random_id()
    test_golden_lowering_aws()
    test_golden_lowering_gcp()
    test_golden_lowering_azure()
    test_a_folded_role_turned_off_is_an_update()
    print("ALL kci_cloud_fake PROVIDER SHAPE TESTS PASSED")
