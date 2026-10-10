# =============================================================================
# test_fake_secret.mojo
# =============================================================================
#
# The `secret` primitive on the fake clouds. One graph throughout: a service
# `api` that receives the secret `db` by `SecretRef.secret` (pinned to
# version 2) and a secret `legacy` by name, and may READ `db` and `seed`; the
# secret `db` (retention unset: KEEP); the secret `seed` (DELETE); the
# account `rot`; and the grant `rot-db` that lets `rot` WRITE `db`.
#
# 1. A GOLDEN LOWERING PER SHAPE (generic, aws, gcp, azure and onprem): per
#    node its kind, wanted, retention, dependencies, inputs and desired
#    fields (of `api/run`, only its `secret_env` fields). Each secret is ONE
#    node of its shape's provider kind (onprem: a Vault KV v2 metadata
#    entry), with no modelled field; `api/run` reads `db`'s NAME as an input
#    (so it waits for `db/secret`) and carries the version pin and the
#    by-name reference as fields; a grant to a secret is the shape's grant
#    kind (onprem: a Vault ACL policy, `vault:sys/policies/acl`). The full
#    JSON of the generic lowering of a secret alone is pinned.
# 2. THE KIT ON EVERY SHAPE: the kci_cloud conformance kit (all twelve
#    steps) passes on generic, aws, gcp, azure and onprem, each under a
#    random id, tampering with `db/secret` (written DELETE there: the kit
#    destroys what it applied and expects nothing left). Onprem HOSTS a secret (its
#    backing, Vault, is fixed), so it runs the kit too.
# 3. NAME, VERSION AND RETENTION AFTER AN APPLY: `api/run` holds `db`'s NAME
#    as the fake writes it (`db-secret`), the pinned version and the
#    by-name reference; `db/secret` is created before `api/run`; a changed
#    version pin is an update of `api/run` alone; a destroy keeps `db`
#    (KEEP by default, marked `retain`) and deletes `seed`.
# 4. A REFERENCE WITHOUT READ IS REFUSED BEFORE ANYTHING IS CREATED, on
#    every shape: dropping `api`'s READ line on `db` refuses the graph with
#    the one refusal text, naming the identity, the secret and the field.
# 5. FAKE-LIMITED DECLARES THE SECRET NOT_YET, and refuses one (coverage).
# 6. `uses` ON A SECRET never reaches a lowering: validate refuses it, and
#    the fake's own lowering, asked directly, refuses it too.
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
    FIELD_SECRET,
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

from kci_cloud_fake import FakeCloud, FakeLimitedCloud, ProviderShape, builtin_shapes


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _graph(
    port: String = String("8080"),
    version: String = String("2"),
    read_db: Bool = True,
    read_seed: Bool = True,
    db: String = String('{"id":"db","secret":{}},'),
) -> String:
    var uses = String("")
    if read_db:
        uses += String('{"target":{"resource":"db"},"access":"READ"}')
    if read_seed:
        if uses.byte_length() > 0:
            uses += String(",")
        uses += String('{"target":{"resource":"seed"},"access":"READ"}')
    return (
        String('{"resource":[')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":') + port
        + String(',"internal":{},"scale":{"min":1,"max":2},"secretEnv":{')
        + String('"DB":{"secret":{"resource":"db"},"version":"') + version + String('"},')
        + String('"LEGACY":{"name":"legacy"}}},')
        + String('"uses":[') + uses + String("]},")
        + db
        + String('{"id":"seed","retention":"DELETE","secret":{}},')
        + String('{"id":"rot","serviceAccount":{}},')
        + String('{"id":"rot-db","grant":{"principal":{"resource":"rot"},"target":{"resource":"db"},')
        + String('"access":"WRITE"}}')
        + String("]}")
    )


def _all_shapes() -> List[ProviderShape]:
    """The fake's own shape, then the built-in clouds."""
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.extend(builtin_shapes())
    return l^


# ---- 1. a golden lowering per shape ------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per node: id, kind, wanted (+ or -), retention, dependencies
    (`<`), inputs (`[producer.OUTPUT>field]`) and desired fields (`{}`; of
    `api/run` only its `secret_env` fields)."""
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
        var first = True
        for k in range(len(n.desired)):
            ref key = n.desired[k].key
            if n.id == "api/run" and key.find("secret_env") < 0:
                continue
            if not first:
                s += String(";")
            first = False
            s += key + String("=") + n.desired[k].value
        s += String("}\n")
    return s^


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-s6"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_graph())))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


comptime _RUN_TAIL = (
    " [db/secret.NAME>service.secret_env.DB] {service.secret_env.DB.version=2;service.secret_env.LEGACY=legacy}\n"
)


def _golden(
    identity: String,
    run: String,
    public: String,
    grant: String,
    secret: String,
    vault: String = String(""),
    endpoint: String = String(""),
) -> String:
    """The lowering of `_graph()` on a shape with these kinds. Roles computed
    with Python hashlib: `api` READ `db` `u-zzkf7b`, READ `seed` `u-m7esj7`,
    its implicit cell LOGS WRITE `u-gktqg5`; `rot`'s `u-az622e`. Where
    `vault` is given (onprem) each identity has its Vault auth role and a
    cell LOGS edge folds into the identity (`cell.LOGS=WRITE`) instead of a
    node of its own."""
    var folds = vault.byte_length() > 0
    var logs = String(";cell.LOGS=WRITE") if folds else String("")
    var api_logs = String("cell.LOGS=WRITE") if folds else String("")
    var s = String("api/identity ") + identity + String(" + delete {") + api_logs + String("}\n")
    if folds:
        s += String("api/vault ") + vault + String(" + delete <api/identity {}\n")
    s += String("api/run ") + run + String(" + delete <api/identity") + String(_RUN_TAIL)
    var front = String("api/run")
    if endpoint.byte_length() > 0:
        s += String("api/endpoint ") + endpoint + String(" + delete <api/run {port=8080}\n")
        front = String("api/endpoint")
    if public.byte_length() > 0:
        s += String("api/public ") + public + String(" - delete <") + front + String(" {mechanism=invoker}\n")
    s += String("api/u-zzkf7b ") + grant + String(" + delete <api/identity,db/secret {principal=api;target=db;access=READ}\n")
    s += String("api/u-m7esj7 ") + grant + String(" + delete <api/identity,seed/secret {principal=api;target=seed;access=READ}\n")
    if not folds:
        s += String("api/u-gktqg5 ") + grant + String(" + delete <api/identity {principal=api;cell=LOGS;access=WRITE}\n")
    s += String("db/secret ") + secret + String(" + keep {secret_named=true}\n")
    s += String("seed/secret ") + secret + String(" + delete {secret_named=true}\n")
    s += String("rot/identity ") + identity + String(" + delete {account=true") + logs + String("}\n")
    if folds:
        s += String("rot/vault ") + vault + String(" + delete <rot/identity {}\n")
    else:
        s += String("rot/u-az622e ") + grant + String(" + delete <rot/identity {principal=rot;cell=LOGS;access=WRITE}\n")
    s += String("rot-db/grant ") + grant + String(" + delete <rot/identity,db/secret {principal=rot;target=db;access=WRITE}\n")
    return s^


def test_golden_lowering_per_shape() raises:
    """Catches: a secret role missing, extra or of the wrong provider kind on
    any shape; a secret lowered with a value or any modelled field; a run
    that does not read the secret's NAME (it could start before the secret
    exists, and would hold no reference to it); the version pin or the
    by-name reference dropped; a grant to a secret lowered to another kind
    (on onprem, folded or refused instead of a Vault policy); a default
    retention other than KEEP."""
    assert_equal(
        _lowered(ProviderShape.generic()),
        _golden(String("identity"), String("run"), String("public"), String("grant"), String("secret")),
        "generic",
    )
    assert_equal(
        _lowered(ProviderShape.aws()),
        _golden(
            String("AWS::IAM::Role"),
            String("AWS::Lambda::Function"),
            String("AWS::Lambda::Url"),
            String("AWS::IAM::RolePolicy"),
            String("AWS::SecretsManager::Secret"),
        ),
        "aws",
    )
    assert_equal(
        _lowered(ProviderShape.gcp()),
        _golden(
            String("iam.googleapis.com/ServiceAccount"),
            String("run.googleapis.com/Service"),
            String("setIamPolicy"),
            String("setIamPolicy"),
            String("secretmanager.googleapis.com/Secret"),
        ),
        "gcp",
    )
    assert_equal(
        _lowered(ProviderShape.azure()),
        _golden(
            String("Microsoft.ManagedIdentity/userAssignedIdentities"),
            String("Microsoft.App/containerApps"),
            String(""),
            String("Microsoft.Authorization/roleAssignments"),
            String("Microsoft.KeyVault/vaults/secrets"),
        ),
        "azure",
    )
    assert_equal(
        _lowered(ProviderShape.onprem()),
        _golden(
            String("v1/ServiceAccount"),
            String("apps/v1/Deployment"),
            String("networking.k8s.io/v1/Ingress"),
            String("vault:sys/policies/acl"),
            String("vault:kv-v2/metadata"),
            vault=String("vault:auth/kubernetes/role"),
            endpoint=String("v1/Service"),
        ),
        "onprem",
    )
    # The generic lowering of a secret alone, as JSON.
    var cloud = FakeCloud()
    assert_equal(
        lowering_json(lower_data(cloud, _list(String('{"resource":[{"id":"db","secret":{}}]}')))),
        String('[\n  {"id":"db/secret","owner":"db","kind":"secret","wanted":true,')
        + String('"retention":"keep","depends_on":[],"inputs":[],')
        + String('"desired":{"secret_named":"true"}}\n]'),
    )
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. the kit on every shape ----------------------------------------------------------------


def test_the_kit_on_every_shape() raises:
    """Catches: a secret node whose create skips the stamp, the retention
    mark or the run-id label; a digest that moves on a re-apply; a tampered
    secret object not planned as an update; a turned-off role (a removed
    READ edge) not deleted; a lowering that keys on the cloud's id."""
    var shapes = _all_shapes()
    var ids = [String("p-7k"), String("p-d02a"), String("p-1x9"), String("p-a4c3e"), String("p-6b")]
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shapes[s].copy())))
        var cloud = FakeCloud(ids[s], shape=shapes[s].copy())
        try:
            # The kit destroys what it applied and expects nothing left, so
            # `db` is written DELETE here (its KEEP default is test 3's).
            var d = String('{"id":"db","retention":"DELETE","secret":{}},')
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_graph(db=d)),
                _list(_graph(String("9090"), db=d)),
                _list(_graph(String("9090"), read_seed=False, db=d)),
                String("db/secret"),
            )
        except e:
            raise Error(shapes[s].name + String(" shape: ") + String(e))
    print("  test_the_kit_on_every_shape: PASS")


# ---- 3. name, version and retention after an apply ---------------------------------------------


def _at(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return i
    return -1


def test_name_version_and_retention() raises:
    """Catches: a run bound to nothing (or to another type's name) for its
    secret, the pinned version or the by-name reference missing from the
    run's digest, a run created before its secret, a version change planned
    as anything but an update of the run (or touching the secret), and a
    KEEP secret deleted by destroy (or a DELETE one kept)."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var a = _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st))
    assert_true(_at(a, String("db/secret")) >= 0 and _at(a, String("api/run")) >= 0, "both applied")
    assert_true(_at(a, String("db/secret")) < _at(a, String("api/run")), "the secret is created before the run")
    var at = cloud.store[].find(String("api/run"))
    var digest = cloud.store[].digests[at].copy()
    for want in ["|service.secret_env.DB=db-secret", "|service.secret_env.DB.version=2", "|service.secret_env.LEGACY=legacy"]:
        assert_true(digest.find(String(want)) >= 0, String(want) + " in " + digest)

    var b = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(version=String("3"))), Creds.none(), st))
    for i in range(len(b)):
        var want = VERB_UPDATE if b[i].logical_id == "api/run" else VERB_NOOP
        assert_equal(b[i].verb, want, b[i].logical_id + String(": a version pin changes the run alone"))

    _ = destroy_resources(reg, cloud, _ctx(), _list(_graph(version=String("3"))), Creds.none(), st)
    var labels = cloud.live_labels(String("db/secret"))
    var kept = False
    for i in range(len(labels)):
        if labels[i].key == "kci-retention" and labels[i].value == "retain":
            kept = True
    assert_true(kept, "db/secret is still there, marked kci-retention=retain")
    assert_equal(cloud.store[].find(String("seed/secret")), -1, "the DELETE secret was destroyed")
    assert_equal(cloud.live_count(), 1, "only the KEEP secret is left")
    print("  test_name_version_and_retention: PASS")


# ---- 4. a reference without READ is refused ----------------------------------------------------


def test_a_reference_without_read_is_refused_on_every_shape() raises:
    """Catches: a reference to a secret accepted with no READ edge (the run
    would come up and be refused reading its secret), on any shape, and a
    refusal after a create."""
    var shapes = _all_shapes()
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(String("p-r"), shape=shapes[s].copy())))
        var cloud = FakeCloud(String("p-r"), shape=shapes[s].copy())
        var raised = False
        try:
            var st = InMemoryStateStore()
            _ = plan_resources(reg, cloud, _ctx(), _list(_graph(read_db=False)), Creds.none(), st)
        except e:
            raised = True
            assert_equal(
                String(e),
                String('kci: cannot apply this graph to cloud "p-r". Nothing was created.')
                + String('\n  resource "api" field service.secret_env.DB.secret: identity "api" may not')
                + String(' READ secret "db": the reference is not a grant; write a uses line (or a grant)')
                + String(' giving it READ on "db"'),
                shapes[s].name,
            )
        assert_true(raised, shapes[s].name + ": refused")
        assert_equal(cloud.mutations(), 0, shapes[s].name + ": nothing was created")
    print("  test_a_reference_without_read_is_refused_on_every_shape: PASS")


# ---- 5. fake-limited declares the secret NOT_YET -------------------------------------------------


def test_fake_limited_declares_the_secret_not_yet() raises:
    """Catches: fake-limited claiming a secret it cannot lower, or declaring
    it absent of the wrong kind."""
    var limited = FakeLimitedCloud()
    var absent = limited.absences()
    var n = 0
    for i in range(len(absent)):
        if absent[i].field == FIELD_SECRET:
            n += 1
            assert_equal(absent[i].kind, NOT_YET)
            assert_equal(absent[i].reason, "fake-limited has no secret store")
    assert_equal(n, 1, "fake-limited declares the secret NOT_YET once")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeLimitedCloud()))
    reg.add(describe(FakeCloud(String("p-z"), shape=ProviderShape.onprem())))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, limited, _ctx(), _list(String('{"resource":[{"id":"s","secret":{}}]}')), Creds.none(), st)
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "fake-limited". Nothing was created.')
            + String('\n  resource "s": secret (PORTABLE): no adapter in cloud "fake-limited"')
            + String(" (NOT_YET: fake-limited has no secret store)")
            + String("\n      clouds built into this kci that implement it: p-z"),
        )
    assert_true(raised, "a secret is refused on fake-limited")
    assert_equal(limited.mutations(), 0)
    print("  test_fake_limited_declares_the_secret_not_yet: PASS")


# ---- 6. uses on a secret ---------------------------------------------------------------------------


def test_uses_on_a_secret_never_reaches_a_lowering() raises:
    """Catches: a secret lowered with `uses` lines (as if it held an
    identity), by validate or by the fake's lowering asked directly."""
    var bad = String('{"resource":[{"id":"db","secret":{}},')
    bad += String('{"id":"s","secret":{},"uses":[{"target":{"resource":"db"},"access":"READ"}]}]}')
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-u"), shape=ProviderShape.onprem())))
    var cloud = FakeCloud(String("p-u"), shape=ProviderShape.onprem())
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(bad), Creds.none(), st)
    except e:
        raised = True
        assert_true(String(e).find('resource "s" field uses: a secret runs as no identity') >= 0, String(e))
    assert_true(raised, "validate refuses uses on a secret")
    assert_equal(cloud.mutations(), 0)
    var l = _list(bad)
    var direct = False
    try:
        _ = FakeCloud().lower(l[1], List[GrantEdge](), List[Feed](), List[Firing]())
    except e:
        direct = True
        assert_true(String(e).find("has uses lines; validate refuses them") >= 0, String(e))
    assert_true(direct, "the lowering refuses uses")
    print("  test_uses_on_a_secret_never_reaches_a_lowering: PASS")


def main() raises:
    print("test_fake_secret")
    test_golden_lowering_per_shape()
    test_the_kit_on_every_shape()
    test_name_version_and_retention()
    test_a_reference_without_read_is_refused_on_every_shape()
    test_fake_limited_declares_the_secret_not_yet()
    test_uses_on_a_secret_never_reaches_a_lowering()
    print("ALL kci_cloud_fake SECRET TESTS PASSED")
