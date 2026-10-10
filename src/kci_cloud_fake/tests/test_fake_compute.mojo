# =============================================================================
# test_fake_compute.mojo
# =============================================================================
#
# The workloads (service, container job, worker) on the fake clouds. One
# graph throughout: a service account `runner` that may READ the bucket
# `media` (a grant resource); the worker `relay` running as `runner` (a
# command, an argument, an env literal and the bucket's NAME, a secret by
# name, a size, three replicas); the worker `sweeper` with its own identity,
# which may READ_WRITE `media` (a `uses` line the kit turns off); the
# container job `nightly` with a command; and the internal service `api`
# (one to three instances, a command) that may CALL `nightly`.
#
# 1. A GOLDEN LOWERING PER SHAPE (generic, aws, gcp, azure, onprem): per
#    node of the four workloads its kind, wanted, retention, dependencies,
#    inputs and desired fields: a worker is one run node (aws: a task
#    definition holding the container and a service holding the replicas,
#    created after it) with its command, args, env, secret_env, size and
#    replicas (the default 1 written out); a container job lowers no
#    trigger on any shape; the onprem `vault` role beside each identity, the
#    service's endpoint, the cell LOGS edge folded into the identity, and a
#    CALL on the job as a RoleBinding with its Role.
# 2. THE KIT ON EVERY SHAPE: the kci_cloud conformance kit (twelve steps) on
#    generic, aws, gcp, azure and onprem, each under a random id, tampering
#    with `relay/run`; the changed graph moves `relay` to four replicas, and
#    the role turned off is `sweeper`'s READ_WRITE grant.
# 3. AFTER AN APPLY: `relay`'s run is bound to the bucket's NAME and created
#    after the bucket and after `runner`'s identity; a replicas change
#    updates `relay`'s run alone; on aws a command change updates the task
#    alone (the service that keeps the replicas is untouched), and the task
#    is created before the service.
# 4. GPUS, PER SHAPE: the generic fake attaches GPUs (`/1gpu` in the size);
#    aws refuses a GPU on each of the three workloads (a Lambda function has
#    none; an ECS task's launch type with GPUs is not decided); gcp, azure
#    and onprem refuse it as undecided; through
#    plan the refusal text is exact and nothing is created.
# 5. ONPREM AND SCALING TO ZERO: onprem refuses a service whose scale may
#    reach zero (the default scale, an explicit `min: 0`), naming Q21, and
#    accepts one that keeps an instance; the other shapes accept scaling to
#    zero; a worker or a job is never refused for it.
# 6. FAKE-LIMITED DECLARES THE WORKER NOT_YET, and refuses one (coverage).
# 7. THE TRIGGER MOVED OUT: no shape has a row for a container job beyond
#    its identity (onprem: and vault) and run, and no shape's lowering of a
#    job writes a trigger field.
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
    FIELD_CONTAINER_JOB,
    FIELD_WORKER,
    NOT_YET,
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    LoweredNode,
    apply_resources,
    describe,
    lower_data,
    plan_resources,
    retention_name,
    run_conformance,
    uses_role,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import (
    GPU_REASON_AWS,
    GPU_REASON_UNDECIDED,
    ONPREM_SCALE_TO_ZERO_REASON,
    FakeCloud,
    FakeLimitedCloud,
    ProviderShape,
    builtin_shapes,
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
    replicas: String = String("3"),
    sweeper_uses: Bool = True,
    relay_cmd: String = String('"/bin/relay","--drain"'),
    derived: Bool = False,
) -> String:
    """`derived`: the graph a shape whose grants are DERIVED reads: the
    grant `reads` (runner READ on media) written as the `uses` line it is
    equivalent to, on its principal `runner` (such a shape refuses a grant
    resource)."""
    var runner = String('{"id":"runner","serviceAccount":{}},')
    var reads = String('{"id":"reads","grant":{"principal":{"resource":"runner"},"target":{"resource":"media"},')
    reads += String('"access":"READ"}}')
    if derived:
        runner = String('{"id":"runner","serviceAccount":{},"uses":[{"target":{"resource":"media"},"access":"READ"}]},')
        reads = String("")
    var uses = String(',"uses":[{"target":{"resource":"media"},"access":"READ_WRITE"}]') if sweeper_uses else String(
        ""
    )
    return (
        String('{"resource":[')
        + runner
        + String('{"id":"media","retention":"DELETE","bucket":{}},')
        + String('{"id":"relay","worker":{"image":{"digest":"sha256:77"},"command":[') + relay_cmd + String("],")
        + String('"args":["--batch=10"],')
        + String('"env":{"MODE":{"literal":"drain"},"MEDIA":{"ref":{"resource":"media","standard":"NAME"}}},')
        + String('"secretEnv":{"TOKEN":{"name":"relay-token"}},"size":{"cpuMillis":500,"memoryMb":1024},')
        + String('"replicas":') + replicas + String(',"runAs":{"resource":"runner"}}},')
        + String('{"id":"sweeper","worker":{"image":{"digest":"sha256:88"}}') + uses + String("},")
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"},"command":["/bin/report"],')
        + String('"maxRetries":2}},')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},')
        + String('"scale":{"min":1,"max":3},"command":["/opt/serve"]},')
        + String('"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]}')
        + (String(",") + reads if reads.byte_length() > 0 else String(""))
        + String("]}")
    )


def _shapes() -> List[ProviderShape]:
    """The fake's own shape, then the built-in clouds: every one hosts the
    three workloads."""
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.extend(builtin_shapes())
    return l^


# ---- 1. a golden lowering per shape ------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per node of the four workloads: id, kind, wanted (+ or -),
    retention, dependencies (`<`), inputs (`[producer.OUTPUT>field]`) and
    desired fields (`{}`)."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        if n.owner != "relay" and n.owner != "sweeper" and n.owner != "nightly" and n.owner != "api":
            continue
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


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-c8"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_graph())))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


comptime _RELAY_CONTAINER = (
    "img=sha256:77@linux/amd64;cmd=/bin/relay;cmd=--drain;arg=--batch=10;worker.env.MODE=drain;"
    "worker.secret_env.TOKEN=relay-token;size=500m/1024MB"
)
comptime _MEDIA_IN = " [media/bucket.NAME>worker.env.MEDIA]"
comptime _SWEEPER_CONTAINER = "img=sha256:88@linux/amd64;size=1000m/512MB"
comptime _NIGHTLY = "img=sha256:99@linux/amd64;cmd=/bin/report;size=1000m/512MB;retries=2;timeout=600s0n;serves=false"
comptime _API = (
    "img=sha256:a1@linux/amd64;port=8080;cmd=/opt/serve;size=1000m/512MB;scale=1..3;health=;timeout=60s0n;"
    "concurrency=0"
)


def _hash_of(role: String) -> String:
    """The hash of a `u-<h>` role (what its helper `r-<h>` shares)."""
    return String(role[byte = 2 : role.byte_length()])


def _roles(s: String) -> String:
    """The golden with each edge's hashed role filled in (kci derives it)."""
    return (
        s.replace("SW_MEDIA", uses_role(String("sweeper"), String("media")))
        .replace("SW_LOGS", uses_role(String("sweeper"), String("cell/LOGS")))
        .replace("NI_LOGS", uses_role(String("nightly"), String("cell/LOGS")))
        .replace("API_CALL", uses_role(String("api"), String("nightly")))
        .replace("API_LOGS", uses_role(String("api"), String("cell/LOGS")))
        .replace("API_HELP", String("r-") + _hash_of(uses_role(String("api"), String("nightly"))))
    )


def _plain_golden(ident: String, worker: String, job: String, svc: String, public: String, grant: String) -> String:
    """generic and gcp: one run node per workload, a public role, and every
    edge a node of kind `grant`."""
    return _roles(
        String("relay/identity ") + ident + String(" - delete {}\n")
        + String("relay/run ") + worker + String(" + delete <runner/identity") + String(_MEDIA_IN)
        + String(" {") + String(_RELAY_CONTAINER) + String(";replicas=3;run_as=runner;serves=false}\n")
        + String("sweeper/identity ") + ident + String(" + delete {}\n")
        + String("sweeper/run ") + worker + String(" + delete <sweeper/identity {")
        + String(_SWEEPER_CONTAINER) + String(";replicas=1;serves=false}\n")
        + String("sweeper/SW_MEDIA ") + grant + String(" + delete <sweeper/identity,media/bucket")
        + String(" {principal=sweeper;target=media;access=READ_WRITE}\n")
        + String("sweeper/SW_LOGS ") + grant + String(" + delete <sweeper/identity {principal=sweeper;cell=LOGS;access=WRITE}\n")
        + String("nightly/identity ") + ident + String(" + delete {}\n")
        + String("nightly/run ") + job + String(" + delete <nightly/identity {") + String(_NIGHTLY) + String("}\n")
        + String("nightly/NI_LOGS ") + grant + String(" + delete <nightly/identity {principal=nightly;cell=LOGS;access=WRITE}\n")
        + String("api/identity ") + ident + String(" + delete {}\n")
        + String("api/run ") + svc + String(" + delete <api/identity {") + String(_API) + String(";serves=true}\n")
        + String("api/public ") + public + String(" - delete <api/run {mechanism=invoker}\n")
        + String("api/API_CALL ") + grant + String(" + delete <api/identity,nightly/run {principal=api;target=nightly;access=CALL}\n")
        + String("api/API_LOGS ") + grant + String(" + delete <api/identity {principal=api;cell=LOGS;access=WRITE}\n")
    )


def test_golden_lowering_per_shape() raises:
    """Catches: a workload role missing, extra or of the wrong provider kind
    on any shape; a worker's container fields or replicas (the default 1
    included) not written out, or on the wrong node on aws; the aws service
    not created after its task definition; a job lowering a trigger; a
    worker's private identity on while it runs as an account; an env
    reference rendered as a value instead of an input; a command merged with
    the args; and the onprem vault role, endpoint, folded LOGS edge or the
    Role helper of a CALL missing."""
    assert_equal(
        _lowered(ProviderShape.generic()),
        _plain_golden(
            String("identity"), String("run"), String("run"), String("run"), String("public"), String("grant")
        ),
        "generic",
    )
    assert_equal(
        _lowered(ProviderShape.gcp()),
        _plain_golden(
            String("iam.googleapis.com/ServiceAccount"),
            String("run.googleapis.com/WorkerPool"),
            String("run.googleapis.com/Job"),
            String("run.googleapis.com/Service"),
            String("setIamPolicy"),
            String("setIamPolicy"),
        ),
        "gcp",
    )
    var role = String("AWS::IAM::Role")
    var pol = String("AWS::IAM::RolePolicy")
    var task = String("AWS::ECS::TaskDefinition")
    var aws = _roles(
        String("relay/identity ") + role + String(" - delete {}\n")
        + String("relay/task ") + task + String(" + delete <runner/identity") + String(_MEDIA_IN)
        + String(" {") + String(_RELAY_CONTAINER) + String(";run_as=runner}\n")
        + String("relay/run AWS::ECS::Service + delete <relay/task {replicas=3;serves=false}\n")
        + String("sweeper/identity ") + role + String(" + delete {}\n")
        + String("sweeper/task ") + task + String(" + delete <sweeper/identity {") + String(_SWEEPER_CONTAINER) + String("}\n")
        + String("sweeper/run AWS::ECS::Service + delete <sweeper/task {replicas=1;serves=false}\n")
        + String("sweeper/SW_MEDIA ") + pol + String(" + delete <sweeper/identity,media/bucket")
        + String(" {principal=sweeper;target=media;access=READ_WRITE}\n")
        + String("sweeper/SW_LOGS ") + pol + String(" + delete <sweeper/identity {principal=sweeper;cell=LOGS;access=WRITE}\n")
        + String("nightly/identity ") + role + String(" + delete {}\n")
        + String("nightly/run ") + task + String(" + delete <nightly/identity {") + String(_NIGHTLY) + String("}\n")
        + String("nightly/NI_LOGS ") + pol + String(" + delete <nightly/identity {principal=nightly;cell=LOGS;access=WRITE}\n")
        + String("api/identity ") + role + String(" + delete {}\n")
        + String("api/run AWS::Lambda::Function + delete <api/identity {") + String(_API) + String(";serves=true}\n")
        + String("api/public AWS::Lambda::Url - delete <api/run {mechanism=invoker}\n")
        + String("api/API_CALL ") + pol + String(" + delete <api/identity,nightly/run {principal=api;target=nightly;access=CALL}\n")
        + String("api/API_LOGS ") + pol + String(" + delete <api/identity {principal=api;cell=LOGS;access=WRITE}\n")
    )
    assert_equal(_lowered(ProviderShape.aws()), aws, "aws")
    var mi = String("Microsoft.ManagedIdentity/userAssignedIdentities")
    var ra = String("Microsoft.Authorization/roleAssignments")
    var app = String("Microsoft.App/containerApps")
    var azure = _roles(
        String("relay/identity ") + mi + String(" - delete {}\n")
        + String("relay/run ") + app + String(" + delete <runner/identity") + String(_MEDIA_IN)
        + String(" {") + String(_RELAY_CONTAINER) + String(";replicas=3;run_as=runner;serves=false}\n")
        + String("sweeper/identity ") + mi + String(" + delete {}\n")
        + String("sweeper/run ") + app + String(" + delete <sweeper/identity {")
        + String(_SWEEPER_CONTAINER) + String(";replicas=1;serves=false}\n")
        + String("sweeper/SW_MEDIA ") + ra + String(" + delete <sweeper/identity,media/bucket")
        + String(" {principal=sweeper;target=media;access=READ_WRITE}\n")
        + String("sweeper/SW_LOGS ") + ra + String(" + delete <sweeper/identity {principal=sweeper;cell=LOGS;access=WRITE}\n")
        + String("nightly/identity ") + mi + String(" + delete {}\n")
        + String("nightly/run Microsoft.App/jobs + delete <nightly/identity {") + String(_NIGHTLY) + String("}\n")
        + String("nightly/NI_LOGS ") + ra + String(" + delete <nightly/identity {principal=nightly;cell=LOGS;access=WRITE}\n")
        + String("api/identity ") + mi + String(" + delete {}\n")
        + String("api/run ") + app + String(" + delete <api/identity {") + String(_API)
        + String(";ingress=none;serves=true}\n")
        + String("api/API_CALL ") + ra + String(" + delete <api/identity,nightly/run {principal=api;target=nightly;access=CALL}\n")
        + String("api/API_LOGS ") + ra + String(" + delete <api/identity {principal=api;cell=LOGS;access=WRITE}\n")
    )
    assert_equal(_lowered(ProviderShape.azure()), azure, "azure")
    var sa = String("v1/ServiceAccount")
    var vr = String("vault:auth/kubernetes/role")
    var dep = String("apps/v1/Deployment")
    var onprem = _roles(
        String("relay/identity ") + sa + String(" - delete {}\n")
        + String("relay/vault ") + vr + String(" - delete <relay/identity {}\n")
        + String("relay/run ") + dep + String(" + delete <runner/identity") + String(_MEDIA_IN)
        + String(" {") + String(_RELAY_CONTAINER) + String(";replicas=3;run_as=runner;serves=false}\n")
        + String("sweeper/identity ") + sa + String(" + delete {cell.LOGS=WRITE}\n")
        + String("sweeper/vault ") + vr + String(" + delete <sweeper/identity {}\n")
        + String("sweeper/run ") + dep + String(" + delete <sweeper/identity {")
        + String(_SWEEPER_CONTAINER) + String(";replicas=1;serves=false}\n")
        + String("sweeper/SW_MEDIA minio:policy + delete <sweeper/identity,media/bucket")
        + String(" {principal=sweeper;target=media;access=READ_WRITE}\n")
        + String("nightly/identity ") + sa + String(" + delete {cell.LOGS=WRITE}\n")
        + String("nightly/vault ") + vr + String(" + delete <nightly/identity {}\n")
        + String("nightly/run batch/v1/CronJob + delete <nightly/identity {") + String(_NIGHTLY) + String("}\n")
        + String("api/identity ") + sa + String(" + delete {cell.LOGS=WRITE}\n")
        + String("api/vault ") + vr + String(" + delete <api/identity {}\n")
        + String("api/run ") + dep + String(" + delete <api/identity {") + String(_API) + String(";serves=true}\n")
        + String("api/endpoint v1/Service + delete <api/run {port=8080}\n")
        + String("api/public networking.k8s.io/v1/Ingress - delete <api/endpoint {mechanism=invoker}\n")
        + String("api/API_HELP rbac.authorization.k8s.io/v1/Role + delete <nightly/run {target=nightly;access=CALL}\n")
        + String("api/API_CALL rbac.authorization.k8s.io/v1/RoleBinding + delete <api/identity,nightly/run,api/API_HELP")
        + String(" {principal=api;target=nightly;access=CALL}\n")
    )
    assert_equal(_lowered(ProviderShape.onprem()), onprem, "onprem")
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. the kit on every shape --------------------------------------------------------------


def test_the_kit_on_every_shape() raises:
    """Catches: a workload node whose create skips the stamp, the retention
    mark or the run-id label; a digest that moves on a re-apply; a tampered
    run not planned as an update; a replicas change that is not an update;
    a `uses` line removed from a worker that does not delete its grant; a
    lowering that keys on the cloud's id."""
    var shapes = _shapes()
    var ids = [String("p-w1"), String("p-a7c"), String("p-g40"), String("p-z9"), String("p-o2e")]
    assert_equal(len(shapes), len(ids), "one random id per shape")
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shapes[s].copy())))
        var cloud = FakeCloud(ids[s], shape=shapes[s].copy())
        var derived = shapes[s].grants_derived()
        try:
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_graph(derived=derived)),
                _list(_graph(String("4"), derived=derived)),
                _list(_graph(String("4"), sweeper_uses=False, derived=derived)),
                String("relay/run"),
            )
        except e:
            raise Error(shapes[s].name + String(" shape: ") + String(e))
    print("  test_the_kit_on_every_shape: PASS")


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
    """Catches: a worker created before the bucket it reads or the account
    it runs as, its env reference bound to nothing, its command or replicas
    missing from the digest, a replicas change that touches anything but the
    run, and on aws a command change that recreates or touches the service
    (or a task created after the service that runs it)."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var a = _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st))
    assert_true(_at(a, String("media/bucket")) < _at(a, String("relay/run")), "the worker after the bucket it reads")
    assert_true(_at(a, String("runner/identity")) < _at(a, String("relay/run")), "and after its account")
    var relay = _digest(cloud, String("relay/run"))
    for want in ["|cmd=/bin/relay|cmd=--drain|arg=--batch=10", "|replicas=3", "|run_as=runner"]:
        assert_true(relay.find(String(want)) >= 0, String(want) + " in " + relay)
    assert_true(relay.find("|worker.env.MEDIA=") >= 0, "the bucket's NAME is bound: " + relay)
    var b = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(String("5"))), Creds.none(), st))
    for i in range(len(b)):
        var want = VERB_UPDATE if b[i].logical_id == "relay/run" else VERB_NOOP
        assert_equal(b[i].verb, want, b[i].logical_id + String(": a replicas change updates the run alone"))

    var areg = Clouds(Catalog.v1())
    areg.add(describe(FakeCloud(String("p-aw"), shape=ProviderShape.aws())))
    var aws = FakeCloud(String("p-aw"), shape=ProviderShape.aws())
    var ast = InMemoryStateStore()
    var c = _done(apply_resources(areg, aws, _ctx(), _list(_graph()), Creds.none(), ast))
    assert_true(_at(c, String("relay/task")) < _at(c, String("relay/run")), "aws: the task before its service")
    var d = _done(
        apply_resources(areg, aws, _ctx(), _list(_graph(relay_cmd=String('"/bin/relay2"'))), Creds.none(), ast)
    )
    for i in range(len(d)):
        var want = VERB_UPDATE if d[i].logical_id == "relay/task" else VERB_NOOP
        assert_equal(d[i].verb, want, d[i].logical_id + String(": aws, a command change updates the task alone"))
    var e = _done(
        apply_resources(
            areg, aws, _ctx(), _list(_graph(String("2"), relay_cmd=String('"/bin/relay2"'))), Creds.none(), ast
        )
    )
    for i in range(len(e)):
        var want = VERB_UPDATE if e[i].logical_id == "relay/run" else VERB_NOOP
        assert_equal(e[i].verb, want, e[i].logical_id + String(": aws, the service keeps the replicas"))
    print("  test_after_an_apply: PASS")


# ---- 4. GPUs per shape --------------------------------------------------------------------------


comptime _GPUS = (
    '{"resource":['
    '{"id":"relay","worker":{"image":{"digest":"sha256:77"},"size":{"cpuMillis":500,"memoryMb":1024,"gpus":1}}},'
    '{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"},"size":{"cpuMillis":500,"memoryMb":1024,"gpus":2}}},'
    '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"scale":{"min":1,"max":2},'
    '"size":{"cpuMillis":500,"memoryMb":1024,"gpus":1}}}'
    "]}"
)


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


def test_gpus_per_shape() raises:
    """Catches: a shape attaching a GPU it has none of (aws), a shape picking
    a GPU type nobody decided (gcp, azure, onprem), a GPU refusal missing on
    one of the three workloads or at the wrong path, the generic fake
    refusing what it hosts, the GPU count missing from the digest, and a
    limit keyed on the cloud's id rather than the shape's data."""
    var g = _limit_lines(ProviderShape.generic(), String(_GPUS))
    assert_equal(len(g), 0, "generic attaches GPUs")
    var paths = ["relay|worker.size.gpus|", "nightly|container_job.size.gpus|", "api|service.size.gpus|"]
    var shapes = builtin_shapes()
    for s in range(len(shapes)):
        var lines = _limit_lines(shapes[s], String(_GPUS))
        assert_equal(len(lines), 3, shapes[s].name + String(": one refusal per workload"))
        var why = String(GPU_REASON_AWS) if shapes[s].name == "aws" else String(GPU_REASON_UNDECIDED)
        for k in range(3):
            assert_equal(
                lines[k],
                String(paths[k]) + String('on cloud "p-l" a workload cannot ask for a GPU: ') + why,
                shapes[s].name,
            )
    # Through plan: the exact refusal, nothing created.
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-l"), shape=ProviderShape.gcp())))
    var cloud = FakeCloud(String("p-l"), shape=ProviderShape.gcp())
    var one = String(
        '{"resource":[{"id":"relay","worker":{"image":{"digest":"sha256:77"},'
        '"size":{"cpuMillis":500,"memoryMb":1024,"gpus":1}}}]}'
    )
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(one), Creds.none(), st)
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "p-l". Nothing was created.')
            + String('\n  resource "relay" field worker.size.gpus: on cloud "p-l" a workload cannot ask for a GPU: ')
            + String(GPU_REASON_UNDECIDED)
            + String(" (citation: kci_cloud_fake: reference limits)"),
        )
    assert_true(raised, "gcp refuses a GPU at validate")
    assert_equal(cloud.mutations(), 0)
    # The generic fake writes the count into the size, so a change is seen.
    var greg = Clouds(Catalog.v1())
    greg.add(describe(FakeCloud()))
    var fake = FakeCloud()
    var st = InMemoryStateStore()
    _ = _done(apply_resources(greg, fake, _ctx(), _list(one), Creds.none(), st))
    var dg = _digest(fake, String("relay/run"))
    assert_true(dg.find("|size=500m/1024MB/1gpu") >= 0, dg)
    print("  test_gpus_per_shape: PASS")


# ---- 5. onprem and scaling to zero ------------------------------------------------------------


def _svc(scale: String) -> String:
    return (
        String('{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}')
        + scale
        + String("}},")
        + String('{"id":"relay","worker":{"image":{"digest":"sha256:77"}}},')
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"}}}]}')
    )


def test_onprem_and_scaling_to_zero() raises:
    """Catches: onprem lowering a scale-to-zero service onto a plain
    Deployment (which cannot), a refusal that misses the default scale or
    an explicit `min: 0`, a reason that does not name Q21, onprem refusing
    a service that keeps an instance, another shape refusing scale to zero,
    and a worker or a job refused for it."""
    var why = String('service.scale.min|on cloud "p-l" a service cannot scale to zero: ') + String(
        ONPREM_SCALE_TO_ZERO_REASON
    ) + String("; write scale.min 1 or more")
    assert_true(String(ONPREM_SCALE_TO_ZERO_REASON).find("Q21") >= 0, "the reason names Q21")
    var onprem = ProviderShape.onprem()
    for scale in [String(""), String(',"scale":{"max":5}'), String(',"scale":{"min":0,"max":5}')]:
        var lines = _limit_lines(onprem, _svc(scale))
        assert_equal(len(lines), 1, String("onprem refuses scale") + scale)
        assert_equal(lines[0], String("api|") + why)
    assert_equal(len(_limit_lines(onprem, _svc(String(',"scale":{"min":1,"max":5}')))), 0, "onprem: min 1 is fine")
    var others = List[ProviderShape]()
    others.append(ProviderShape.generic())
    others.append(ProviderShape.aws())
    others.append(ProviderShape.gcp())
    others.append(ProviderShape.azure())
    for s in range(len(others)):
        assert_equal(len(_limit_lines(others[s], _svc(String("")))), 0, others[s].name + ": scales to zero")
    # Through plan on onprem: refused before anything is created.
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-l"), shape=ProviderShape.onprem())))
    var cloud = FakeCloud(String("p-l"), shape=ProviderShape.onprem())
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(_svc(String(""))), Creds.none(), st)
    except e:
        raised = True
        assert_true(String(e).find('resource "api" field service.scale.min: on cloud "p-l"') >= 0, String(e))
        assert_true(String(e).find("(Q21: a plain Deployment, Knative Serving or the KEDA HTTP add-on)") >= 0)
    assert_true(raised, "onprem refuses a service that scales to zero")
    assert_equal(cloud.mutations(), 0)
    print("  test_onprem_and_scaling_to_zero: PASS")


# ---- 6. fake-limited declares the worker NOT_YET ---------------------------------------------------


def test_fake_limited_declares_the_worker_not_yet() raises:
    """Catches: fake-limited claiming a worker it cannot lower, or declaring
    the worker or the container job absent of the wrong kind."""
    var limited = FakeLimitedCloud()
    var absent = limited.absences()
    for f in [FIELD_WORKER, FIELD_CONTAINER_JOB]:
        var n = 0
        for i in range(len(absent)):
            if absent[i].field == f:
                n += 1
                assert_equal(absent[i].kind, NOT_YET)
        assert_equal(n, 1, String("fake-limited declares ") + String(f) + " NOT_YET once")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeLimitedCloud()))
    reg.add(describe(FakeCloud(String("p-z"))))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(
            reg, limited, _ctx(), _list(String('{"resource":[{"id":"relay","worker":{"image":{"digest":"sha256:77"}}}]}')),
            Creds.none(), st,
        )
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "fake-limited". Nothing was created.')
            + String('\n  resource "relay": worker (PORTABLE): no adapter in cloud "fake-limited"')
            + String(" (NOT_YET: fake-limited has no always-on runner)")
            + String("\n      clouds built into this kci that implement it: p-z"),
        )
    assert_true(raised, "a worker is refused on fake-limited")
    assert_equal(limited.mutations(), 0)
    print("  test_fake_limited_declares_the_worker_not_yet: PASS")


# ---- 7. the trigger moved out -------------------------------------------------------------------


def test_no_shape_lowers_a_trigger() raises:
    """Catches: a schedule or trigger role left on a container job (on any
    shape), and a trigger folded into a job's run node as a field."""
    var shapes = _shapes()
    var job = _list(String('{"resource":[{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"}}}]}'))
    for s in range(len(shapes)):
        ref shape = shapes[s]
        var rows = shape.roles_of(FIELD_CONTAINER_JOB)
        var roles = String("")
        for i in range(len(rows)):
            roles += rows[i].role + String(",")
        var want = String("identity,vault,run,") if shape.name == "onprem" else String("identity,run,")
        assert_equal(roles, want, shape.name + String(": a job's roles"))
        var nodes = lower_data(FakeCloud(String("p-t"), shape=shape.copy()), job)
        for i in range(len(nodes)):
            for k in range(len(nodes[i].desired)):
                assert_true(
                    not nodes[i].desired[k].key.startswith("trigger"),
                    shape.name + String(": ") + nodes[i].id + String(" has no trigger field"),
                )
    print("  test_no_shape_lowers_a_trigger: PASS")


def main() raises:
    print("test_fake_compute")
    test_golden_lowering_per_shape()
    test_the_kit_on_every_shape()
    test_after_an_apply()
    test_gpus_per_shape()
    test_onprem_and_scaling_to_zero()
    test_fake_limited_declares_the_worker_not_yet()
    test_no_shape_lowers_a_trigger()
    print("ALL kci_cloud_fake COMPUTE TESTS PASSED")
