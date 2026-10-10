# =============================================================================
# test_fake_kci_job.mojo
# =============================================================================
#
# `kci.job@1`, THE DEFINITION KCI SHIPS (kci_composites), EXPANDED AND
# DEPLOYED on the fake clouds. The list: a bucket `media`; `nightly`, an
# instance of kci.job@1 (image, cron `30 2 * * 1-5`, two retries, an env
# reading `media`'s NAME); and a grant `reads` whose principal is the job's
# exported `account` (`{resource: nightly, path: account}`), READ on `media`.
#
# 1. THE TREE AND THE EXPANSION: `nightly/account` (a service account),
#    `nightly/job` (a container job running as it, with the image, the
#    retries and the env written by bindings) and `nightly/timer` (a
#    schedule starting the job, its cron written by a binding).
# 2. A GOLDEN LOWERING PER SHAPE (generic, aws, gcp, azure, onprem): every
#    node of the list, with its kind, wanted, retention, dependencies,
#    inputs and desired fields. The job runs as `nightly/account` (its own
#    identity turned off); the grant's principal is `nightly/account`; on
#    azure and onprem the schedule FOLDS into the job's run (its own nodes
#    turned off), as for a schedule written by hand.
# 3. PRESENCE IS THE CLOSED WORLD (generic): applied with a cron, then
#    without, the timer's nodes (and only they) are deleted; destroy then
#    removes everything but the KEEP-by-default nothing (media is DELETE).
# 4. REFUSALS, through validate on the generic fake, for every input:
#    `image` unbound (required), bound in `input` instead of `image_input`;
#    `cron` that the schedule's rule refuses (the expanded schedule is
#    judged like any schedule, at `nightly/timer`); `max_retries` that is
#    not an integer; an `env` value with nothing in it; an input kci.job
#    does not declare.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    Provenance,
    VERB_CREATE,
    VERB_DELETE,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    Finding,
    LoweredNode,
    apply_resources,
    describe,
    destroy_resources,
    expand,
    lower_data,
    retention_name,
    validate_for,
)
from kci_composites import read_kci_definitions
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, ProviderShape, builtin_shapes


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _findings(fs: List[Finding]) -> String:
    var s = String("")
    for i in range(len(fs)):
        s += fs[i].resource_id + String(" | ") + fs[i].field_path + String(" | ") + fs[i].reason + String("\n")
    return s^


comptime _MEDIA_ENV = '"MEDIA":{"ref":{"resource":"media","standard":"NAME"}}'


def _job(
    inputs: String = String('"cron":{"literal":"30 2 * * 1-5"},"max_retries":{"literal":"2"}'),
    image: Bool = True,
    env: String = String(_MEDIA_ENV),
) -> String:
    """`nightly`: `inputs` in `input`, the image unless `image` is False, and
    `env` (entries) as the env unless it is empty."""
    var s = String('{"id":"nightly","composite":{"definition":"kci.job","version":"1","input":{') + inputs + String("}")
    if image:
        s += String(',"imageInput":{"image":{"digest":"sha256:99"}}')
    if env.byte_length() > 0:
        s += String(',"mapInput":{"env":{"value":{') + env + String("}}}")
    return s + String("}}")


def _graph(job: String) -> String:
    return (
        String('{"resource":[{"id":"media","retention":"DELETE","bucket":{}},')
        + job
        + String(',{"id":"reads","grant":{"principal":{"resource":"nightly","path":"account"},"target":{"resource":"media"},"access":"READ"}}]}')
    )


# ---- 1. the tree and the expansion -----------------------------------------------------------


def test_the_expansion() raises:
    """Catches: kci.job's components or bindings changed (a run_as lost, a
    binding not written, the timer present without a cron), and a tree
    that does not name kci.job@1."""
    var x = expand(Catalog.v1(), read_kci_definitions(), _list(_graph(_job())))
    assert_equal(len(x.findings), 0, _findings(x.findings))
    var tree = x.tree.copy()
    assert_true(tree.startswith("media: bucket\nnightly: kci.job@1 sha256:"), tree)
    assert_true(
        tree.find("\n  nightly/account: service_account\n  nightly/job: container_job\n  nightly/timer: schedule\nreads: grant\n") >= 0,
        tree,
    )
    var ids = String("")
    for i in range(len(x.resources)):
        ids += x.resources[i].id + String(";")
    assert_equal(ids, "media;nightly/account;nightly/job;nightly/timer;reads;", "the expanded list")
    ref job = x.resources[2].container_job.value()
    assert_equal(job.image.value().digest.value(), "sha256:99", "the image")
    assert_equal(Int(job.max_retries.value()), 2, "the retries")
    assert_equal(job.run_as.value().resource, "nightly/account", "runs as the account")
    assert_equal(job.env["MEDIA"].ref_.value().resource, "media", "the env, resolved at the top")
    ref timer = x.resources[3].schedule.value()
    assert_equal(timer.cron, "30 2 * * 1-5", "the cron")
    assert_equal(timer.target.value().resource, "nightly/job", "the timer starts the job")
    assert_equal(x.resources[4].grant.value().principal.value().resource, "nightly/account", "the exported account")
    print("  test_the_expansion: PASS")


# ---- 2. a golden lowering per shape ---------------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per node: id, kind, wanted (+ or -), retention, dependencies
    (`<`), inputs (`[producer.OUTPUT>field]`) and desired fields (`{}`)."""
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
        for k in range(len(n.desired)):
            if k > 0:
                s += String(";")
            s += n.desired[k].key + String("=") + n.desired[k].value
        s += String("}\n")
    return s^


def _lowered(shape: ProviderShape) raises -> String:
    var x = expand(Catalog.v1(), read_kci_definitions(), _list(_graph(_job())))
    assert_equal(len(x.findings), 0, _findings(x.findings))
    var cloud = FakeCloud(String("p-j1"), shape=shape.copy())
    return _summary(lower_data(cloud, x.resources))


comptime _GOLDEN_GENERIC = (
    'media/bucket bucket + delete {expiry_days=never;versioning=false;tier=STANDARD;stores=true}\n'
    + 'nightly/account/identity identity + delete {account=true}\n'
    + 'nightly/account/u-6xdemu grant + delete <nightly/account/identity {principal=nightly/account;cell=LOGS;access=WRITE}\n'
    + 'nightly/job/identity identity - delete {}\n'
    + 'nightly/job/run run + delete <nightly/account/identity [media/bucket.NAME>container_job.env.MEDIA] {img=sha256:99@linux/amd64;size=1000m/512MB;retries=2;timeout=600s0n;run_as=nightly/account;serves=false}\n'
    + 'nightly/timer/identity identity + delete {}\n'
    + 'nightly/timer/schedule schedule + delete <nightly/timer/identity,nightly/job/run,nightly/timer/u-trg2dh {cron=30 2 * * 1-5;timezone=UTC;target=nightly/job}\n'
    + 'nightly/timer/u-trg2dh grant + delete <nightly/timer/identity,nightly/job/run {principal=nightly/timer;target=nightly/job;access=CALL}\n'
    + 'reads/grant grant + delete <nightly/account/identity,media/bucket {principal=nightly/account;target=media;access=READ}\n'
)
comptime _GOLDEN_AWS = (
    'media/bucket AWS::S3::Bucket + delete {expiry_days=never;versioning=false;tier=STANDARD;stores=true}\n'
    + 'nightly/account/identity AWS::IAM::Role + delete {account=true}\n'
    + 'nightly/account/u-6xdemu AWS::IAM::RolePolicy + delete <nightly/account/identity {principal=nightly/account;cell=LOGS;access=WRITE}\n'
    + 'nightly/job/identity AWS::IAM::Role - delete {}\n'
    + 'nightly/job/run AWS::ECS::TaskDefinition + delete <nightly/account/identity [media/bucket.NAME>container_job.env.MEDIA] {img=sha256:99@linux/amd64;size=1000m/512MB;retries=2;timeout=600s0n;run_as=nightly/account;serves=false}\n'
    + 'nightly/timer/identity AWS::IAM::Role + delete {}\n'
    + 'nightly/timer/schedule AWS::Scheduler::Schedule + delete <nightly/timer/identity,nightly/job/run,nightly/timer/u-trg2dh {cron=30 2 * * 1-5;timezone=UTC;target=nightly/job}\n'
    + 'nightly/timer/u-trg2dh AWS::IAM::RolePolicy + delete <nightly/timer/identity,nightly/job/run {principal=nightly/timer;target=nightly/job;access=CALL}\n'
    + 'reads/grant AWS::IAM::RolePolicy + delete <nightly/account/identity,media/bucket {principal=nightly/account;target=media;access=READ}\n'
)
comptime _GOLDEN_GCP = (
    'media/bucket storage.googleapis.com/Bucket + delete {expiry_days=never;versioning=false;tier=STANDARD;stores=true}\n'
    + 'nightly/account/identity iam.googleapis.com/ServiceAccount + delete {account=true}\n'
    + 'nightly/account/u-6xdemu setIamPolicy + delete <nightly/account/identity {principal=nightly/account;cell=LOGS;access=WRITE}\n'
    + 'nightly/job/identity iam.googleapis.com/ServiceAccount - delete {}\n'
    + 'nightly/job/run run.googleapis.com/Job + delete <nightly/account/identity [media/bucket.NAME>container_job.env.MEDIA] {img=sha256:99@linux/amd64;size=1000m/512MB;retries=2;timeout=600s0n;run_as=nightly/account;serves=false}\n'
    + 'nightly/timer/identity iam.googleapis.com/ServiceAccount + delete {}\n'
    + 'nightly/timer/schedule cloudscheduler.googleapis.com/Job + delete <nightly/timer/identity,nightly/job/run,nightly/timer/u-trg2dh {cron=30 2 * * 1-5;timezone=UTC;target=nightly/job}\n'
    + 'nightly/timer/u-trg2dh setIamPolicy + delete <nightly/timer/identity,nightly/job/run {principal=nightly/timer;target=nightly/job;access=CALL}\n'
    + 'reads/grant setIamPolicy + delete <nightly/account/identity,media/bucket {principal=nightly/account;target=media;access=READ}\n'
)
comptime _GOLDEN_AZURE = (
    'media/bucket Microsoft.Storage/storageAccounts/blobServices/containers + delete {expiry_days=never;versioning=false;tier=STANDARD;stores=true}\n'
    + 'nightly/account/identity Microsoft.ManagedIdentity/userAssignedIdentities + delete {account=true}\n'
    + 'nightly/account/u-6xdemu Microsoft.Authorization/roleAssignments + delete <nightly/account/identity {principal=nightly/account;cell=LOGS;access=WRITE}\n'
    + 'nightly/job/identity Microsoft.ManagedIdentity/userAssignedIdentities - delete {}\n'
    + 'nightly/job/run Microsoft.App/jobs + delete <nightly/account/identity [media/bucket.NAME>container_job.env.MEDIA] {img=sha256:99@linux/amd64;size=1000m/512MB;retries=2;timeout=600s0n;schedule=nightly/timer;cron=30 2 * * 1-5;timezone=UTC;run_as=nightly/account;serves=false}\n'
    + 'nightly/timer/identity Microsoft.ManagedIdentity/userAssignedIdentities - delete {}\n'
    + 'nightly/timer/schedule Microsoft.Logic/workflows - delete <nightly/timer/identity,nightly/job/run,nightly/timer/u-trg2dh {cron=30 2 * * 1-5;timezone=UTC;target=nightly/job}\n'
    + 'nightly/timer/u-trg2dh Microsoft.Authorization/roleAssignments - delete <nightly/timer/identity,nightly/job/run {principal=nightly/timer;target=nightly/job;access=CALL}\n'
    + 'reads/grant Microsoft.Authorization/roleAssignments + delete <nightly/account/identity,media/bucket {principal=nightly/account;target=media;access=READ}\n'
)
comptime _GOLDEN_ONPREM = (
    'media/bucket minio/Bucket + delete {expiry_days=never;versioning=false;tier=STANDARD;stores=true}\n'
    + 'nightly/account/identity v1/ServiceAccount + delete {account=true;cell.LOGS=WRITE}\n'
    + 'nightly/account/vault vault:auth/kubernetes/role + delete <nightly/account/identity {}\n'
    + 'nightly/job/identity v1/ServiceAccount - delete {}\n'
    + 'nightly/job/vault vault:auth/kubernetes/role - delete <nightly/job/identity {}\n'
    + 'nightly/job/run batch/v1/CronJob + delete <nightly/account/identity [media/bucket.NAME>container_job.env.MEDIA] {img=sha256:99@linux/amd64;size=1000m/512MB;retries=2;timeout=600s0n;schedule=nightly/timer;cron=30 2 * * 1-5;timezone=UTC;run_as=nightly/account;serves=false}\n'
    + 'nightly/timer/identity v1/ServiceAccount - delete {}\n'
    + 'nightly/timer/schedule batch/v1/CronJob - delete <nightly/timer/identity,nightly/job/run,nightly/timer/u-trg2dh {cron=30 2 * * 1-5;timezone=UTC;target=nightly/job}\n'
    + 'nightly/timer/r-trg2dh rbac.authorization.k8s.io/v1/Role - delete <nightly/job/run {target=nightly/job;access=CALL}\n'
    + 'nightly/timer/u-trg2dh rbac.authorization.k8s.io/v1/RoleBinding - delete <nightly/timer/identity,nightly/job/run,nightly/timer/r-trg2dh {principal=nightly/timer;target=nightly/job;access=CALL}\n'
    + 'reads/grant minio:policy + delete <nightly/account/identity,media/bucket {principal=nightly/account;target=media;access=READ}\n'
)


def test_golden_lowering_per_shape() raises:
    """Catches: a node of kci.job missing, extra, of the wrong provider kind
    or out of order on any shape; the job's own identity left on beside
    the account (two identities for one job); the grant's principal not the
    exported account; the schedule not folded into the job on azure and
    onprem, or folded where the shape has its own scheduler object."""
    var shapes = List[ProviderShape]()
    shapes.append(ProviderShape.generic())
    shapes.extend(builtin_shapes())
    var want: List[String] = [
        String(_GOLDEN_GENERIC), String(_GOLDEN_AWS), String(_GOLDEN_GCP), String(_GOLDEN_AZURE), String(_GOLDEN_ONPREM)
    ]
    var bad = String("")
    for s in range(len(shapes)):
        var got = _lowered(shapes[s])
        if got != want[s]:
            bad += String("\n==== ") + shapes[s].name + String("\n") + got
    assert_equal(bad, String(""), "the lowering per shape")
    print("  test_golden_lowering_per_shape: PASS")


# ---- 3. presence is the closed world ----------------------------------------------------------------


def _verbs(applied: List[AppliedNode]) -> String:
    """Every node that is not a NOOP, as `id:verb;`, in order."""
    var s = String("")
    for i in range(len(applied)):
        if applied[i].verb == VERB_NOOP:
            continue
        var v = String("create") if applied[i].verb == VERB_CREATE else (
            String("update") if applied[i].verb == VERB_UPDATE else (
                String("delete") if applied[i].verb == VERB_DELETE else String(applied[i].verb)
            )
        )
        s += applied[i].logical_id + String(":") + v + String(";")
    return s^


def test_presence_is_the_closed_world() raises:
    """Catches: a component that becomes absent left live (N22: its nodes
    are roles of `nightly` the file no longer lowers, so they must be
    deleted), anything else touched, and a destroy that keeps a node."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var defs = read_kci_definitions()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(_job())), Creds.none(), st, defs))
    assert_true(cloud.store[].find(String("nightly/timer/schedule")) >= 0, "the timer is live")
    var out = apply_resources(reg, cloud, _ctx(), _list(_graph(_job(String('"max_retries":{"literal":"2"}')))), Creds.none(), st, defs)
    var gone = _verbs(_done(out))
    assert_equal(gone.find("nightly/job/"), -1, String("the job is untouched: ") + gone)
    assert_true(gone.find("nightly/timer/schedule:delete;") >= 0, gone)
    assert_true(gone.find(":create;") < 0 and gone.find(":update;") < 0, gone)
    assert_true(cloud.store[].find(String("nightly/timer/schedule")) < 0, "the timer is gone")
    assert_equal(len(out.leftover), 0, "nothing leftover")
    _ = destroy_resources(reg, cloud, _ctx(), _list(_graph(_job(String('"max_retries":{"literal":"2"}')))), Creds.none(), st, defs)
    assert_equal(cloud.live_count(), 0, "destroy removes every node")
    print("  test_presence_is_the_closed_world: PASS")


# ---- 4. refusals --------------------------------------------------------------------------------------


def _refused(job: String, rid: String, field: String, needle: String) raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var fs = validate_for(reg, FakeCloud(), _list(_graph(job)), read_kci_definitions())
    var got = _findings(fs)
    assert_equal(len(fs), 1, String("one finding (") + needle + String("), got:\n") + got)
    assert_equal(fs[0].resource_id, rid, got)
    assert_equal(fs[0].field_path, field, got)
    assert_true(fs[0].reason.find(needle) >= 0, String("reason holds ") + needle + String(":\n") + got)


def test_refusals() raises:
    """Catches: kci.job's required input not required (N23), and each input
    accepted where its type or the expanded primitive's rule refuses it
    (timezone: a binding that dropped it, or wrote it anywhere but the
    schedule, would leave this graph accepted)."""
    _refused(_job(image=False), "nightly", "composite.input", "required input \"image\" of kci.job@1 is not bound")
    _refused(
        _job(String('"image":{"literal":"sha256:99"}'), image=False),
        "nightly",
        "composite.input.image",
        "an IMAGE input is bound in image_input",
    )
    _refused(_job(String('"cron":{"literal":"every night"}')), "nightly/timer", "schedule.cron", "a cron is five fields")
    _refused(
        _job(String('"cron":{"literal":"30 2 * * 1-5"},"timezone":{"literal":"9am"}')),
        "nightly/timer",
        "schedule.timezone",
        "starts with a letter",
    )
    _refused(_job(String('"max_retries":{"literal":"two"}')), "nightly", "composite.input.max_retries", "an INT input is a decimal integer")
    _refused(_job(env=String('"E":{}')), "nightly", "composite.map_input.env.E", "has no value")
    _refused(_job(String('"schedule":{"literal":"daily"}')), "nightly", "composite.input.schedule", "kci.job@1 declares no input \"schedule\"")
    print("  test_refusals: PASS")


def main() raises:
    print("test_fake_kci_job: kci.job@1 expanded and deployed on the fakes")
    test_the_expansion()
    test_golden_lowering_per_shape()
    test_presence_is_the_closed_world()
    test_refusals()
    print("ALL kci_cloud_fake kci.job TESTS PASSED")
