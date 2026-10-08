# =============================================================================
# test_fake_provider_shapes.mojo
# =============================================================================
#
# The shaped fakes: `FakeCloud` built with a `ProviderShape` lowers each
# catalog type to that shape's own fixed roles and provider kinds.
#
# 1. THE TABLE: every row names a catalog field the fake implements; every
#    workload field (service, container job, worker) has an `identity` and a
#    `run` row on every shape, a service account an `identity` row, the bucket exactly one row,
#    `bucket`, and no identity; every role name is at most 8 bytes (the role
#    vocabulary's bound, which the label budget counts on); every shape has
#    a grant row for every type a grant may target (onprem folds a cell
#    grant: no row); every shape that hosts a table has a `table` row (gcp
#    also `ix` and `ttl`), and onprem hosts none and declares it NOT_YET
#    (Q17); the generic shape is the fake's own roles.
# 2. THE KIT ON EVERY SHAPE: the kci_cloud conformance kit (all twelve steps)
#    passes on the aws, gcp, azure and onprem shapes, each registered under a random
#    id, on the graph of test_fake_conformance (a public service, an internal
#    service reading its URL and HOST, a container job, two grants; every
#    service keeps one instance, which onprem requires until Q21).
# 3. A GOLDEN LOWERING PER SHAPE of one public service and one container job
#    with one `uses` line: per node, its role and provider kind, in order;
#    the private identity the run depends on and the grants hang off (the
#    `uses` line, and each identity's implicit cell LOGS WRITE); on azure,
#    the public ingress folded into the run node; on onprem, the service's
#    in-cluster endpoint the public ingress fronts. No shape lowers a
#    trigger for the job (the worker's goldens are in test_fake_compute).
# 4. A FOLDED ROLE IS AN UPDATE: on azure, making a public service internal
#    updates its run node and deletes nothing; on aws and onprem it deletes
#    the public role's object, and onprem keeps the endpoint.
# 5. THE BUILT-IN CLOUDS ARE DATA: the shapes are a list of values (aws,
#    gcp, azure, onprem, in that order); a cloud name is looked up in it, and
#    a name that is not a built-in cloud (a near-miss spelling, the generic
#    fake's own shape) is refused naming the built-in list.
# 6. IDENTITY PER SHAPE: a golden of a service account, a service that runs
#    as it and reads a bucket, a container job with its own identity, and a
#    grant
#    resource: per node its kind, wanted and dependencies. The grant kind
#    follows the TARGET'S TYPE (on aws a CALL on a service is the function's
#    resource policy; on onprem a Kubernetes target is a RoleBinding with
#    its Role helper and a bucket is a MinIO policy); onprem adds the `vault`
#    auth role beside each identity and folds a cell grant into it.
# 7. RUN_AS TURNS THE PRIVATE IDENTITY OFF: moving a service onto an account
#    deletes its private identity and its implicit LOGS grant and updates
#    its run; nothing else changes.
# 8. ONPREM REFUSES A CELL GRANT IT CANNOT FOLD (one written for another
#    resource's identity) as a limit, before anything is created; aws lowers
#    the same file.
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
    EDGE_TARGET_CELL,
    FIELD_BUCKET,
    FIELD_GRANT,
    FIELD_CONTAINER_JOB,
    FIELD_SERVICE,
    FIELD_SERVICE_ACCOUNT,
    FIELD_TABLE,
    FIELD_WORKER,
    LoweredNode,
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

from kci_cloud_fake import FakeCloud, ProviderShape, builtin_shapes, helper_role, shape_named


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _shapes() -> List[ProviderShape]:
    return builtin_shapes()


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
        for f in [FIELD_SERVICE, FIELD_CONTAINER_JOB, FIELD_WORKER]:
            assert_true(shape.has(f, String("identity")), shape.name + ": compute has an identity row")
            assert_true(shape.has(f, String("run")), shape.name + ": compute has a run row")
        assert_equal(len(shape.roles_of(FIELD_BUCKET)), 1, shape.name + ": one bucket row")
        assert_true(shape.has(FIELD_BUCKET, String("bucket")), shape.name + ": the bucket row")
        assert_true(shape.has(FIELD_SERVICE_ACCOUNT, String("identity")), shape.name + ": an account row")
        assert_equal(len(shape.roles_of(FIELD_GRANT)), 0, shape.name + ": a grant's roles are its edge's")
        # Every type a grant may target has a row (a service, a container
        # job, a bucket, a service account; a worker accepts no verb); a cell resource too, except where it
        # folds (onprem).
        for f in [FIELD_SERVICE, FIELD_CONTAINER_JOB, FIELD_BUCKET, FIELD_SERVICE_ACCOUNT]:
            assert_true(Bool(shape.grant_row(f)), shape.name + ": a grant row for field " + String(f))
        assert_equal(
            Bool(shape.grant_row(EDGE_TARGET_CELL)),
            shape.name != "onprem",
            shape.name + ": a cell grant has a row, or folds on onprem",
        )
    var g = ProviderShape.generic()
    assert_equal(
        len(g.rows),
        25,
        "generic: identity, run, public; identity, run; identity, run; table; bucket; identity; queue; topic; sub;"
        + " secret; zone; record; cert; identity, schedule; identity, trigger; network; subnet; address; registry",
    )
    # The table: one `table` row where it is hosted (gcp adds its index and
    # TTL objects), a grant row to it, and NOT_YET on onprem.
    for s in range(len(all)):
        ref shape = all[s]
        if shape.name == "onprem":
            assert_equal(len(shape.roles_of(FIELD_TABLE)), 0, "onprem: no table row")
            assert_true(not shape.hosts(FIELD_TABLE), "onprem: a table is NOT_YET")
            assert_equal(
                len(shape.not_yet),
                12,
                "onprem: table, queue, topic, subscription, dns_zone, dns_record, certificate, event_trigger,"
                + " network, subnet, ip_address, registry",
            )
            assert_true(shape.not_yet[0].reason.find("Q17") >= 0, shape.not_yet[0].reason)
            continue
        assert_true(shape.hosts(FIELD_TABLE), shape.name + ": hosts a table")
        assert_true(shape.has(FIELD_TABLE, String("table")), shape.name + ": the table row")
        assert_true(Bool(shape.grant_row(FIELD_TABLE)), shape.name + ": a grant row to a table")
        var n = 3 if shape.name == "gcp" else 1
        assert_equal(len(shape.roles_of(FIELD_TABLE)), n, shape.name + ": table rows")
    assert_equal(
        ProviderShape.azure().grant_row(FIELD_TABLE).value().kind,
        "Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments",
        "azure: Cosmos data access is its own role assignment",
    )
    assert_equal(g.grant_row(FIELD_BUCKET).value().kind, "grant")
    # One grant row per target type on onprem, by the target's backing.
    var o = ProviderShape.onprem()
    for f in [FIELD_SERVICE, FIELD_CONTAINER_JOB, FIELD_SERVICE_ACCOUNT]:
        assert_equal(o.grant_row(f).value().kind, "rbac.authorization.k8s.io/v1/RoleBinding")
        assert_equal(o.grant_row(f).value().helper, "rbac.authorization.k8s.io/v1/Role")
    assert_equal(o.grant_row(FIELD_BUCKET).value().kind, "minio:policy")
    assert_equal(o.grant_row(FIELD_BUCKET).value().helper, "", "a MinIO policy has no helper")
    for f in [FIELD_SERVICE, FIELD_CONTAINER_JOB, FIELD_WORKER, FIELD_SERVICE_ACCOUNT]:
        assert_equal(o.kind_of(f, String("vault")), "vault:auth/kubernetes/role", "the vault helper")
    var a = ProviderShape.aws()
    assert_equal(a.grant_row(FIELD_SERVICE).value().kind, "AWS::Lambda::Permission")
    assert_equal(a.grant_row(FIELD_BUCKET).value().kind, "AWS::IAM::RolePolicy")
    assert_equal(helper_role(String("u-e4f3tk")), "r-e4f3tk")
    assert_equal(helper_role(String("grant")), "rules")
    print("  test_the_shape_table: PASS")


# ---- 2. the kit on every shape ---------------------------------------------------------


def _full(api_port: String, roles_on: Bool = True, derived: Bool = False) -> String:
    """The graph of test_fake_conformance, plus identity: the job runs as a
    service account, and a grant lets web DESCRIBE that account. `roles_on`
    False makes api internal and removes web's grant on api. Each service
    keeps one instance (a scale from 1), so the graph is legal on onprem.
    `derived`: the graph a shape whose grants are DERIVED reads: the grant
    `see` written as the `uses` line it is equivalent to, `uses runner
    DESCRIBE` on web, kept when the roles are off."""
    var see = String('{"target":{"resource":"runner"},"access":"DESCRIBE"}')
    var call = String('{"target":{"resource":"api"},"access":"CALL"}')
    var web_uses = String('"uses":[') + call + String("]},")
    if derived:
        web_uses = String('"uses":[') + call + String(",") + see + String("]},")
    var exposure = String('"public":{}')
    if not roles_on:
        web_uses = String('"uses":[') + (see if derived else String("")) + String("]},")
        exposure = String('"internal":{}')
    var grant = String(',{"id":"see","grant":{"principal":{"resource":"web"},')
    grant += String('"target":{"resource":"runner"},"access":"DESCRIBE"}}')
    if derived:
        grant = String("")
    return (
        String('{"resource":[')
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"port":8080,"internal":{},')
        + String('"scale":{"min":1,"max":2},')
        + String('"env":{"API_URL":{"ref":{"resource":"api","standard":"URL"}},')
        + String('"API_HOST":{"ref":{"resource":"api","standard":"HOST"}},')
        + String('"MODE":{"literal":"fast"}}},')
        + web_uses
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(",")
        + exposure
        + String(',"requestTimeout":"30s","scale":{"min":1,"max":3}},')
        + String('"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]},')
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"},"maxRetries":1,')
        + String('"runAs":{"resource":"runner"}}},')
        + String('{"id":"runner","serviceAccount":{}}')
        + grant
        + String("]}")
    )


def test_every_shape_passes_the_kit_under_a_random_id() raises:
    var ids = List[String]()
    ids.append(String("p-7c21aa"))
    ids.append(String("p-0e93f4"))
    ids.append(String("p-b5d018"))
    ids.append(String("p-4e8a61"))
    var shapes = _shapes()
    assert_equal(len(shapes), len(ids), "one random id per built-in shape")
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shapes[s].copy())))
        var cloud = FakeCloud(ids[s], shape=shapes[s].copy())
        var d = shapes[s].grants_derived()
        try:
            run_conformance(
                reg, cloud, _ctx(), _list(_full("8080", derived=d)), _list(_full("9090", derived=d)),
                _list(_full("9090", False, derived=d)), String("api/run"),
            )
        except e:
            raise Error(shapes[s].name + String(" shape: ") + String(e))
    print("  test_every_shape_passes_the_kit_under_a_random_id: PASS")


# ---- 3. a golden lowering per shape -------------------------------------------------------


def _golden_graph() -> String:
    return String(
        '{"resource":['
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"public":{}}},'
        '{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"}},'
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


def _node(
    id: String, kind: String, deps: String, desired: String, wanted: Bool = True
) -> String:
    """One golden node: `deps` is the JSON array body, `desired` the JSON
    object body."""
    var owner = String(id[byte = 0 : id.find("/")])
    return (
        String('  {"id":"') + id + String('","owner":"') + owner + String('","kind":"') + kind
        + String('","wanted":') + (String("true") if wanted else String("false"))
        + String(',"retention":"delete","depends_on":[') + deps
        + String('],"inputs":[],"desired":{') + desired + String("}}")
    )


def _nodes(lines: List[String]) -> String:
    var s = String("[\n")
    for i in range(len(lines)):
        if i > 0:
            s += String(",\n")
        s += lines[i]
    return s + String("\n]")


comptime _API_LOGS = '"principal":"api","cell":"LOGS","access":"WRITE"'
comptime _NIGHTLY_LOGS = '"principal":"nightly","cell":"LOGS","access":"WRITE"'
comptime _CALL_API = '"principal":"nightly","target":"api","access":"CALL"'


def _golden_with_roles(
    identity: String, service: String, public: String, job: String,
    call_grant: String, grant: String,
) -> String:
    """The lowering of `_golden_graph` on a shape with an identity and a
    public role (aws, gcp), given each role's provider kind:
    `call_grant` for nightly's CALL on the api service, `grant` for the
    implicit cell LOGS grants."""
    var l = List[String]()
    l.append(_node(String("api/identity"), identity, String(""), String("")))
    l.append(
        _node(String("api/run"), service, String('"api/identity"'), String(_SVC_FIELDS) + String(',"serves":"true"'))
    )
    l.append(_node(String("api/public"), public, String('"api/run"'), String('"mechanism":"invoker"')))
    l.append(_node(String("api/u-gktqg5"), grant, String('"api/identity"'), String(_API_LOGS)))
    l.append(_node(String("nightly/identity"), identity, String(""), String("")))
    l.append(
        _node(
            String("nightly/run"), job, String('"nightly/identity"'), String(_JOB_FIELDS) + String(',"serves":"false"')
        )
    )
    l.append(
        _node(String("nightly/u-e4f3tk"), call_grant, String('"nightly/identity","api/run"'), String(_CALL_API))
    )
    l.append(_node(String("nightly/u-g2ewtg"), grant, String('"nightly/identity"'), String(_NIGHTLY_LOGS)))
    return _nodes(l)


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
        String("AWS::Lambda::Permission"),
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
        String("setIamPolicy"),
        String("setIamPolicy"),
    )
    assert_equal(_lowered(ProviderShape.gcp()), want)
    print("  test_golden_lowering_gcp: PASS")


def test_golden_lowering_azure() raises:
    var ident = String("Microsoft.ManagedIdentity/userAssignedIdentities")
    var ra = String("Microsoft.Authorization/roleAssignments")
    var l = List[String]()
    l.append(_node(String("api/identity"), ident, String(""), String("")))
    l.append(
        _node(
            String("api/run"), String("Microsoft.App/containerApps"), String('"api/identity"'),
            String(_SVC_FIELDS) + String(',"ingress":"invoker","serves":"true"'),
        )
    )
    l.append(_node(String("api/u-gktqg5"), ra, String('"api/identity"'), String(_API_LOGS)))
    l.append(_node(String("nightly/identity"), ident, String(""), String("")))
    l.append(
        _node(
            String("nightly/run"), String("Microsoft.App/jobs"), String('"nightly/identity"'),
            String(_JOB_FIELDS) + String(',"serves":"false"'),
        )
    )
    l.append(_node(String("nightly/u-e4f3tk"), ra, String('"nightly/identity","api/run"'), String(_CALL_API)))
    l.append(_node(String("nightly/u-g2ewtg"), ra, String('"nightly/identity"'), String(_NIGHTLY_LOGS)))
    assert_equal(_lowered(ProviderShape.azure()), _nodes(l))
    print("  test_golden_lowering_azure: PASS")


def test_golden_lowering_onprem() raises:
    var sa = String("v1/ServiceAccount")
    var vault = String("vault:auth/kubernetes/role")
    var l = List[String]()
    # The implicit cell LOGS grant folds into the identity it is for.
    l.append(_node(String("api/identity"), sa, String(""), String('"cell.LOGS":"WRITE"')))
    l.append(_node(String("api/vault"), vault, String('"api/identity"'), String("")))
    l.append(
        _node(
            String("api/run"), String("apps/v1/Deployment"), String('"api/identity"'),
            String(_SVC_FIELDS) + String(',"serves":"true"'),
        )
    )
    l.append(_node(String("api/endpoint"), String("v1/Service"), String('"api/run"'), String('"port":"8080"')))
    l.append(
        _node(
            String("api/public"), String("networking.k8s.io/v1/Ingress"), String('"api/endpoint"'),
            String('"mechanism":"invoker"'),
        )
    )
    l.append(_node(String("nightly/identity"), sa, String(""), String('"cell.LOGS":"WRITE"')))
    l.append(_node(String("nightly/vault"), vault, String('"nightly/identity"'), String("")))
    l.append(
        _node(
            String("nightly/run"), String("batch/v1/CronJob"), String('"nightly/identity"'),
            String(_JOB_FIELDS) + String(',"serves":"false"'),
        )
    )
    # A Kubernetes target: the Role helper, then the RoleBinding that binds it.
    l.append(
        _node(
            String("nightly/r-e4f3tk"), String("rbac.authorization.k8s.io/v1/Role"), String('"api/run"'),
            String('"target":"api","access":"CALL"'),
        )
    )
    l.append(
        _node(
            String("nightly/u-e4f3tk"), String("rbac.authorization.k8s.io/v1/RoleBinding"),
            String('"nightly/identity","api/run","nightly/r-e4f3tk"'), String(_CALL_API),
        )
    )
    assert_equal(_lowered(ProviderShape.onprem()), _nodes(l))
    print("  test_golden_lowering_onprem: PASS")


# ---- 4. a folded role is an update ---------------------------------------------------------


def _one(exposure: String) -> String:
    return (
        String('{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},"scale":{"min":1,"max":2},')
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
    shapes.append(ProviderShape.onprem())
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
            var n = shapes[s].name
            assert_equal(_verbs(off, String("api/run")), VERB_NOOP, n + ": the run is unchanged")
            assert_equal(_verbs(off, String("api/public")), VERB_DELETE, n + ": the public role is deleted")
            assert_equal(cloud.live_count(), live - 1, n + ": only the public role is deleted")
            if n == "onprem":
                assert_equal(
                    _verbs(off, String("api/endpoint")), VERB_NOOP, "onprem: the in-cluster endpoint stays"
                )
    print("  test_a_folded_role_turned_off_is_an_update: PASS")


# ---- 5. the built-in clouds are data ---------------------------------------------------------


def _refused(name: String) -> String:
    """The refusal `shape_named(name)` raises, or "" when it returns."""
    try:
        _ = shape_named(name)
    except e:
        return String(e)
    return String("")


def test_the_built_in_clouds_are_data() raises:
    var shapes = builtin_shapes()
    var names = String("")
    for s in range(len(shapes)):
        if s > 0:
            names += String(",")
        names += shapes[s].name
        assert_equal(shape_named(shapes[s].name).name, shapes[s].name, "looked up by its own name")
    assert_equal(names, "aws,gcp,azure,onprem", "the built-in clouds, in order")
    var bad = List[String]()
    bad.append(String("on-prem"))
    bad.append(String("ONPREM"))
    bad.append(String("k8s"))
    bad.append(String("generic"))
    bad.append(String(""))
    for i in range(len(bad)):
        var why = _refused(bad[i])
        assert_true(why.byte_length() > 0, "\"" + bad[i] + "\" is not a built-in cloud")
        assert_true(why.find("aws, gcp, azure, onprem") >= 0, "the refusal names the built-in list: " + why)
    print("  test_the_built_in_clouds_are_data: PASS")


def test_onprem_endpoint_is_always_wanted() raises:
    var cloud = FakeCloud(String("p-5a"), shape=ProviderShape.onprem())
    var nodes = lower_data(cloud, _list(_one(String('"internal":{}'))))
    var ep = False
    for i in range(len(nodes)):
        if nodes[i].id == "api/endpoint":
            ep = True
            assert_true(nodes[i].wanted, "an internal service is still reachable in the cluster")
            assert_equal(nodes[i].kind, "v1/Service")
        if nodes[i].id == "api/public":
            assert_true(not nodes[i].wanted, "an internal service has no ingress")
            assert_equal(nodes[i].depends_on[0], "api/endpoint", "the ingress fronts the endpoint")
    assert_true(ep, "the endpoint is lowered")
    print("  test_onprem_endpoint_is_always_wanted: PASS")


# ---- 6. identity per shape -------------------------------------------------------------


def _identity_graph(derived: Bool = False) -> String:
    """`derived`: the graph a shape whose grants are DERIVED reads: api's
    `uses store READ` moved onto runner, the account it runs as, and the
    grant `see` written as `uses runner DESCRIBE` on nightly."""
    if derived:
        return String(
            '{"resource":['
            '{"id":"runner","serviceAccount":{},"uses":[{"target":{"resource":"store"},"access":"READ"}]},'
            '{"id":"store","bucket":{}},'
            '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"scale":{"min":1,"max":2},'
            '"runAs":{"resource":"runner"}}},'
            '{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"}},'
            '"uses":[{"target":{"resource":"runner"},"access":"DESCRIBE"}]}'
            "]}"
        )
    return String(
        '{"resource":['
        '{"id":"runner","serviceAccount":{}},'
        '{"id":"store","bucket":{}},'
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"scale":{"min":1,"max":2},'
        '"runAs":{"resource":"runner"}},'
        '"uses":[{"target":{"resource":"store"},"access":"READ"}]},'
        '{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"}}},'
        '{"id":"see","grant":{"principal":{"resource":"nightly"},'
        '"target":{"resource":"runner"},"access":"DESCRIBE"}}'
        "]}"
    )


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per node: id, kind, wanted (+ or -), dependencies, and the
    folded cell fields of an identity."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        s += n.id + String(" ") + n.kind + String(" ") + (String("+") if n.wanted else String("-"))
        for k in range(len(n.depends_on)):
            s += (String(" <") if k == 0 else String(",")) + n.depends_on[k]
        var cell = n.field(String("cell.LOGS"))
        if cell.byte_length() > 0:
            s += String(" cell.LOGS=") + cell
        s += String("\n")
    return s^


def _want_identity(
    sa: String, run: String, public: String, job: String, grant: String,
) -> String:
    """The identity golden on aws, gcp (and generic): every node, `grant` the
    kind of every grant here (none targets a service)."""
    return (
        String("runner/identity ") + sa + String(" +\n")
        + String("runner/u-atqd3s ") + grant + String(" + <runner/identity\n")
        + String("store/bucket BUCKET +\n")
        + String("api/identity ") + sa + String(" -\n")
        + String("api/run ") + run + String(" + <runner/identity\n")
        + String("api/public ") + public + String(" - <api/run\n")
        + String("api/u-2wfpfg ") + grant + String(" + <runner/identity,store/bucket\n")
        + String("nightly/identity ") + sa + String(" +\n")
        + String("nightly/run ") + job + String(" + <nightly/identity\n")
        + String("nightly/u-g2ewtg ") + grant + String(" + <nightly/identity\n")
        + String("see/grant ") + grant + String(" + <nightly/identity,runner/identity\n")
    )


def _identity_lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-6d"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_identity_graph())))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


def test_identity_lowering_per_shape() raises:
    var aws = _want_identity(
        String("AWS::IAM::Role"), String("AWS::Lambda::Function"), String("AWS::Lambda::Url"),
        String("AWS::ECS::TaskDefinition"), String("AWS::IAM::RolePolicy"),
    ).replace("BUCKET", "AWS::S3::Bucket")
    assert_equal(_identity_lowered(ProviderShape.aws()), aws, "aws")
    var gcp = _want_identity(
        String("iam.googleapis.com/ServiceAccount"), String("run.googleapis.com/Service"), String("setIamPolicy"),
        String("run.googleapis.com/Job"), String("setIamPolicy"),
    ).replace("BUCKET", "storage.googleapis.com/Bucket")
    assert_equal(_identity_lowered(ProviderShape.gcp()), gcp, "gcp")
    var generic = _want_identity(
        String("identity"), String("run"), String("public"), String("run"), String("grant")
    ).replace("BUCKET", "bucket")
    assert_equal(_identity_lowered(ProviderShape.generic()), generic, "generic")

    var mi = String("Microsoft.ManagedIdentity/userAssignedIdentities")
    var ra = String("Microsoft.Authorization/roleAssignments")
    var azure = (
        String("runner/identity ") + mi + String(" +\n")
        + String("runner/u-atqd3s ") + ra + String(" + <runner/identity\n")
        + String("store/bucket Microsoft.Storage/storageAccounts/blobServices/containers +\n")
        + String("api/identity ") + mi + String(" -\n")
        + String("api/run Microsoft.App/containerApps + <runner/identity\n")
        + String("api/u-2wfpfg ") + ra + String(" + <runner/identity,store/bucket\n")
        + String("nightly/identity ") + mi + String(" +\n")
        + String("nightly/run Microsoft.App/jobs + <nightly/identity\n")
        + String("nightly/u-g2ewtg ") + ra + String(" + <nightly/identity\n")
        + String("see/grant ") + ra + String(" + <nightly/identity,runner/identity\n")
    )
    assert_equal(_identity_lowered(ProviderShape.azure()), azure, "azure")

    var sa = String("v1/ServiceAccount")
    var vr = String("vault:auth/kubernetes/role")
    var onprem = (
        String("runner/identity ") + sa + String(" + cell.LOGS=WRITE\n")
        + String("runner/vault ") + vr + String(" + <runner/identity\n")
        + String("store/bucket minio/Bucket +\n")
        + String("api/identity ") + sa + String(" -\n")
        + String("api/vault ") + vr + String(" - <api/identity\n")
        + String("api/run apps/v1/Deployment + <runner/identity\n")
        + String("api/endpoint v1/Service + <api/run\n")
        + String("api/public networking.k8s.io/v1/Ingress - <api/endpoint\n")
        + String("api/u-2wfpfg minio:policy + <runner/identity,store/bucket\n")
        + String("nightly/identity ") + sa + String(" + cell.LOGS=WRITE\n")
        + String("nightly/vault ") + vr + String(" + <nightly/identity\n")
        + String("nightly/run batch/v1/CronJob + <nightly/identity\n")
        + String("see/rules rbac.authorization.k8s.io/v1/Role + <runner/identity\n")
        + String("see/grant rbac.authorization.k8s.io/v1/RoleBinding +")
        + String(" <nightly/identity,runner/identity,see/rules\n")
    )
    assert_equal(_identity_lowered(ProviderShape.onprem()), onprem, "onprem")
    print("  test_identity_lowering_per_shape: PASS")


def test_the_identity_graph_applies_and_settles_on_every_shape() raises:
    var shapes = _shapes()
    shapes.append(ProviderShape.generic())
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(String("p-6k"), shape=shapes[s].copy())))
        var cloud = FakeCloud(String("p-6k"), shape=shapes[s].copy())
        var store = InMemoryStateStore()
        var d = shapes[s].grants_derived()
        var applied = _done(
            apply_resources(reg, cloud, _ctx(), _list(_identity_graph(d)), Creds.none(), store)
        )
        var again = _done(
            apply_resources(reg, cloud, _ctx(), _list(_identity_graph(d)), Creds.none(), store)
        )
        for k in range(len(again)):
            assert_equal(again[k].verb, VERB_NOOP, shapes[s].name + ": " + again[k].logical_id + " settled")
        assert_true(len(applied) > 0)
    print("  test_the_identity_graph_applies_and_settles_on_every_shape: PASS")


# ---- 7. run_as turns the private identity off --------------------------------------------


def test_run_as_turns_the_private_identity_off() raises:
    var own = String(
        '{"resource":[{"id":"runner","serviceAccount":{}},'
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"scale":{"min":1,"max":2}}}]}'
    )
    var moved = String(
        '{"resource":[{"id":"runner","serviceAccount":{}},'
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"scale":{"min":1,"max":2},'
        '"runAs":{"resource":"runner"}}}]}'
    )
    var shapes = _shapes()
    for s in range(len(shapes)):
        var n = shapes[s].name
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(String("p-7r"), shape=shapes[s].copy())))
        var cloud = FakeCloud(String("p-7r"), shape=shapes[s].copy())
        var store = InMemoryStateStore()
        _ = _done(apply_resources(reg, cloud, _ctx(), _list(own), Creds.none(), store))
        var live = cloud.live_count()
        var off = _done(apply_resources(reg, cloud, _ctx(), _list(moved), Creds.none(), store))
        assert_equal(_verbs(off, String("api/identity")), VERB_DELETE, n + ": the private identity is deleted")
        assert_equal(_verbs(off, String("api/run")), VERB_UPDATE, n + ": the run now runs as the account")
        assert_equal(_verbs(off, String("runner/identity")), VERB_NOOP, n + ": the account is unchanged")
        var gone = 1  # the identity
        if n == "onprem":
            assert_equal(_verbs(off, String("api/vault")), VERB_DELETE, "onprem: its vault role goes with it")
            gone += 1
        else:
            assert_equal(_verbs(off, String("api/u-gktqg5")), VERB_DELETE, n + ": its implicit LOGS grant goes")
            gone += 1
        assert_equal(cloud.live_count(), live - gone, n + ": nothing else is deleted")
    print("  test_run_as_turns_the_private_identity_off: PASS")


# ---- 8. onprem refuses a cell grant it cannot fold -------------------------------------


def test_onprem_refuses_a_cell_grant_it_cannot_fold() raises:
    var json = String(
        '{"resource":[{"id":"runner","serviceAccount":{}},'
        '{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"},"runAs":{"resource":"runner"}},'
        '"uses":[{"cell":"METRICS","access":"WRITE"}]}]}'
    )
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-8o"), shape=ProviderShape.onprem())))
    var cloud = FakeCloud(String("p-8o"), shape=ProviderShape.onprem())
    var store = InMemoryStateStore()
    var why = String("")
    try:
        _ = apply_resources(reg, cloud, _ctx(), _list(json), Creds.none(), store)
    except e:
        why = String(e)
    assert_true(
        why.find(
            'resource "nightly" field uses[0]: on cloud "p-8o" a grant to the cell\'s METRICS is a'
            + ' setting of the identity it is for; write it on "runner" itself'
        )
        >= 0,
        why,
    )
    assert_equal(cloud.live_count(), 0, "nothing was created")
    assert_equal(cloud.mutations(), 0, "no call was made")

    # aws has a row for a cell grant: the same file lowers there.
    var aws = FakeCloud(String("p-8a"), shape=ProviderShape.aws())
    var nodes = lower_data(aws, _list(json))
    var found = False
    for i in range(len(nodes)):
        if nodes[i].field(String("cell")) == "METRICS":
            found = True
            assert_equal(nodes[i].owner, "nightly", "the line's node is nightly's")
            assert_equal(nodes[i].depends_on[0], "runner/identity", "it hangs off the account")
            assert_equal(nodes[i].kind, "AWS::IAM::RolePolicy")
    assert_true(found, "aws lowers the METRICS grant")
    print("  test_onprem_refuses_a_cell_grant_it_cannot_fold: PASS")


def main() raises:
    print("test_fake_provider_shapes")
    test_the_shape_table()
    test_every_shape_passes_the_kit_under_a_random_id()
    test_golden_lowering_aws()
    test_golden_lowering_gcp()
    test_golden_lowering_azure()
    test_golden_lowering_onprem()
    test_a_folded_role_turned_off_is_an_update()
    test_the_built_in_clouds_are_data()
    test_onprem_endpoint_is_always_wanted()
    test_identity_lowering_per_shape()
    test_the_identity_graph_applies_and_settles_on_every_shape()
    test_run_as_turns_the_private_identity_off()
    test_onprem_refuses_a_cell_grant_it_cannot_fold()
    print("ALL kci_cloud_fake PROVIDER SHAPE TESTS PASSED")
