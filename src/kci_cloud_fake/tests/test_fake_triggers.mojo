# =============================================================================
# test_fake_triggers.mojo
# =============================================================================
#
# The triggers (schedule, event trigger) on the fake clouds. One graph
# throughout: a DELETE bucket `media`; a container job `nightly` that reads
# the bucket's NAME; an internal service `api` (one to three instances) that
# may READ `media` (a `uses` line the kit turns off); the schedule
# `nightly-at-2` that starts `nightly` at 02:30 on weekdays (UTC); the
# schedule `warm` that calls `api` every quarter hour (Europe/Paris); and the
# event trigger `on-upload` that delivers `media`'s new objects to `api`.
#
# 1. A GOLDEN LOWERING PER SHAPE (generic, aws, gcp, azure, onprem): per
#    node of `nightly` and the three triggers its kind, wanted, retention,
#    dependencies, inputs and desired fields: each trigger's identity, its
#    object (`schedule` or `trigger`, the time zone written out, after its
#    target and its CALL edge) and its CALL edge by the shape's grant row
#    for the target's type (aws: a Lambda permission on a service, a role
#    policy on a job); on azure and onprem the job's schedule FOLDED into the
#    job's run (`schedule`, `cron`, `timezone`) and its identity, object and
#    edge (onprem: with the edge's Role) turned off. onprem lowers neither
#    `warm` (a limit, test 4) nor `on-upload` (NOT_YET, test 5).
# 2. THE KIT ON EVERY SHAPE: the kci_cloud conformance kit (twelve steps) on
#    generic, aws, gcp, azure and onprem, each under a random id, tampering
#    with `nightly/run`; the changed graph moves `nightly-at-2` to 04:00 (an
#    update of the schedule, or of the job's run where it folds); the role
#    turned off is `api`'s READ on `media` (a trigger's own roles turning off
#    is test 3: a resource that leaves the file is reported left over, not
#    deleted, so the kit turns roles off inside the file).
# 3. AFTER AN APPLY: on the generic shape a schedule is created after the
#    job it starts and after its CALL edge, and a cron change updates the
#    schedule alone; on azure and onprem nothing of `nightly-at-2` exists,
#    the job's run carries its cron and time zone, a cron change updates the
#    job's run alone; on azure, retargeting the schedule to `api` creates its
#    identity, its object and its edge and updates the job's run (the
#    schedule leaves it), and retargeting it back to the job deletes those
#    three (turned off: the closed world) and updates the job's run (it
#    holds the schedule again); on onprem, removing the schedule updates the
#    job's run alone.
# 4. LIMITS, PER SHAPE: aws refuses a cron naming both a day of the month
#    and a day of the week; azure refuses a time zone on a schedule its job
#    holds (and takes one on a schedule that calls a service); azure and
#    onprem refuse a second schedule of one job; onprem refuses a schedule
#    that calls a service, naming Q28, through plan with the exact text and
#    nothing created. Every other shape takes each of these.
# 5. NOT_YET: onprem declares the event trigger NOT_YET naming Q22 and
#    refuses one through plan (a coverage finding naming the built-in clouds
#    that host it); fake-limited declares both triggers NOT_YET.
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
    FIELD_EVENT_TRIGGER,
    FIELD_SCHEDULE,
    NOT_YET,
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    Feed,
    LoweredNode,
    apply_resources,
    describe,
    firings_of,
    lower_data,
    plan_resources,
    retention_name,
    run_conformance,
    uses_role,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import (
    ONPREM_EVENT_TRIGGER_REASON,
    ONPREM_SCHEDULE_CALL_REASON,
    SCHEDULE_DAY_REASON_AWS,
    SCHEDULE_UTC_REASON_AZURE,
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
    cron: String = String("30 2 * * 1-5"),
    warm: Bool = True,
    events: Bool = True,
    api_uses: Bool = True,
    target: String = String("nightly"),
    schedule: Bool = True,
) -> String:
    """The graph of the file header. `warm` and `events` keep `warm` and
    `on-upload`; `api_uses` keeps `api`'s READ on `media`; `target` is what
    `nightly-at-2` starts or calls; `schedule` keeps `nightly-at-2`."""
    var uses = String(',"uses":[{"target":{"resource":"media"},"access":"READ"}]') if api_uses else String("")
    var s = (
        String('{"resource":[')
        + String('{"id":"media","retention":"DELETE","bucket":{}},')
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"},')
        + String('"env":{"MEDIA":{"ref":{"resource":"media","standard":"NAME"}}}}},')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},')
        + String('"scale":{"min":1,"max":3}}') + uses + String("}")
    )
    if schedule:
        s += String(',{"id":"nightly-at-2","schedule":{"cron":"') + cron + String('","target":{"resource":"')
        s += target + String('"}}}')
    if warm:
        s += String(',{"id":"warm","schedule":{"cron":"*/15 * * * *","timezone":"Europe/Paris",')
        s += String('"target":{"resource":"api"}}}')
    if events:
        s += String(',{"id":"on-upload","eventTrigger":{"source":{"resource":"media"},"event":"OBJECT_CREATED",')
        s += String('"target":{"resource":"api"}}}')
    return s + String("]}")


def _shape_graph(shape: ProviderShape, cron: String = String("30 2 * * 1-5"), api_uses: Bool = True) -> String:
    """`_graph` with what `shape` lowers: onprem takes neither `warm` nor
    `on-upload` (tests 4 and 5)."""
    var full = shape.name != "onprem"
    return _graph(cron, warm=full, events=full, api_uses=api_uses)


def _shapes() -> List[ProviderShape]:
    """The fake's own shape, then the built-in clouds."""
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.extend(builtin_shapes())
    return l^


# ---- 1. a golden lowering per shape ------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per node of `nightly` and the triggers: id, kind, wanted (+
    or -), retention, dependencies (`<`), inputs (`[producer.OUTPUT>field]`)
    and desired fields (`{}`)."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        if n.owner != "nightly" and n.owner != "nightly-at-2" and n.owner != "warm" and n.owner != "on-upload":
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
    var cloud = FakeCloud(String("p-c9"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_shape_graph(shape))))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


comptime _JOB = "img=sha256:99@linux/amd64;size=1000m/512MB;retries=0;timeout=600s0n"
comptime _MEDIA_IN = " [media/bucket.NAME>container_job.env.MEDIA]"
comptime _FOLDED = ";schedule=nightly-at-2;cron=30 2 * * 1-5;timezone=UTC"
comptime _AT2 = "{cron=30 2 * * 1-5;timezone=UTC;target=nightly}"
comptime _WARM = "{cron=*/15 * * * *;timezone=Europe/Paris;target=api}"
comptime _UPLOAD = "{source=media;event=OBJECT_CREATED;target=api}"


def _hash_of(role: String) -> String:
    """The hash of a `u-<h>` role (what its helper `r-<h>` shares)."""
    return String(role[byte = 2 : role.byte_length()])


def _roles(s: String) -> String:
    """The golden with each edge's hashed role filled in (kci derives it)."""
    return (
        s.replace("NI_LOGS", uses_role(String("nightly"), String("cell/LOGS")))
        .replace("SC_CALL", uses_role(String("nightly-at-2"), String("nightly")))
        .replace("SC_HELP", String("r-") + _hash_of(uses_role(String("nightly-at-2"), String("nightly"))))
        .replace("WA_CALL", uses_role(String("warm"), String("api")))
        .replace("OU_CALL", uses_role(String("on-upload"), String("api")))
    )


def _golden(
    ident: String,
    job: String,
    logs: String,
    sched: String,
    on_job: String,
    on_api: String,
    trigger: String,
    folds: Bool,
) -> String:
    """generic, aws, gcp and azure: `nightly`, then the three triggers. On a
    folding shape `nightly-at-2` is turned off and the job carries it."""
    var at2 = String("-") if folds else String("+")
    return _roles(
        String("nightly/identity ") + ident + String(" + delete {}\n")
        + String("nightly/run ") + job + String(" + delete <nightly/identity") + String(_MEDIA_IN) + String(" {")
        + String(_JOB) + (String(_FOLDED) if folds else String("")) + String(";serves=false}\n")
        + String("nightly/NI_LOGS ") + logs + String(" + delete <nightly/identity {principal=nightly;cell=LOGS;access=WRITE}\n")
        + String("nightly-at-2/identity ") + ident + String(" ") + at2 + String(" delete {}\n")
        + String("nightly-at-2/schedule ") + sched + String(" ") + at2
        + String(" delete <nightly-at-2/identity,nightly/run,nightly-at-2/SC_CALL ") + String(_AT2) + String("\n")
        + String("nightly-at-2/SC_CALL ") + on_job + String(" ") + at2
        + String(" delete <nightly-at-2/identity,nightly/run {principal=nightly-at-2;target=nightly;access=CALL}\n")
        + String("warm/identity ") + ident + String(" + delete {}\n")
        + String("warm/schedule ") + sched + String(" + delete <warm/identity,api/run,warm/WA_CALL ") + String(_WARM)
        + String("\n")
        + String("warm/WA_CALL ") + on_api + String(" + delete <warm/identity,api/run {principal=warm;target=api;access=CALL}\n")
        + String("on-upload/identity ") + ident + String(" + delete {}\n")
        + String("on-upload/trigger ") + trigger
        + String(" + delete <on-upload/identity,media/bucket,api/run,on-upload/OU_CALL ") + String(_UPLOAD) + String("\n")
        + String("on-upload/OU_CALL ") + on_api
        + String(" + delete <on-upload/identity,api/run {principal=on-upload;target=api;access=CALL}\n")
    )


def test_golden_lowering_per_shape() raises:
    """Catches: a trigger role missing, extra or of the wrong provider kind
    on any shape; a trigger object created before its target or its CALL
    edge; the time zone not written out; the CALL edge lowered by the wrong
    grant row (aws: a role policy on a service, a Lambda permission on a
    job); a schedule that folds on a shape that has its own scheduler
    object, or does not fold on azure and onprem (its identity, object or
    edge left on, the job's run without its cron); and the onprem Role
    helper of the folded edge left on."""
    assert_equal(
        _lowered(ProviderShape.generic()),
        _golden(
            String("identity"), String("run"), String("grant"), String("schedule"), String("grant"),
            String("grant"), String("trigger"), False,
        ),
        "generic",
    )
    assert_equal(
        _lowered(ProviderShape.aws()),
        _golden(
            String("AWS::IAM::Role"), String("AWS::ECS::TaskDefinition"), String("AWS::IAM::RolePolicy"),
            String("AWS::Scheduler::Schedule"), String("AWS::IAM::RolePolicy"), String("AWS::Lambda::Permission"),
            String("AWS::Events::Rule"), False,
        ),
        "aws",
    )
    assert_equal(
        _lowered(ProviderShape.gcp()),
        _golden(
            String("iam.googleapis.com/ServiceAccount"), String("run.googleapis.com/Job"), String("setIamPolicy"),
            String("cloudscheduler.googleapis.com/Job"), String("setIamPolicy"), String("setIamPolicy"),
            String("eventarc.googleapis.com/Trigger"), False,
        ),
        "gcp",
    )
    var ra = String("Microsoft.Authorization/roleAssignments")
    assert_equal(
        _lowered(ProviderShape.azure()),
        _golden(
            String("Microsoft.ManagedIdentity/userAssignedIdentities"), String("Microsoft.App/jobs"), ra,
            String("Microsoft.Logic/workflows"), ra, ra,
            String("Microsoft.EventGrid/systemTopics/eventSubscriptions"), True,
        ),
        "azure",
    )
    var sa = String("v1/ServiceAccount")
    var onprem = _roles(
        String("nightly/identity ") + sa + String(" + delete {cell.LOGS=WRITE}\n")
        + String("nightly/vault vault:auth/kubernetes/role + delete <nightly/identity {}\n")
        + String("nightly/run batch/v1/CronJob + delete <nightly/identity") + String(_MEDIA_IN) + String(" {")
        + String(_JOB) + String(_FOLDED) + String(";serves=false}\n")
        + String("nightly-at-2/identity ") + sa + String(" - delete {}\n")
        + String("nightly-at-2/schedule batch/v1/CronJob - delete <nightly-at-2/identity,nightly/run,nightly-at-2/SC_CALL ")
        + String(_AT2) + String("\n")
        + String("nightly-at-2/SC_HELP rbac.authorization.k8s.io/v1/Role - delete <nightly/run {target=nightly;access=CALL}\n")
        + String("nightly-at-2/SC_CALL rbac.authorization.k8s.io/v1/RoleBinding - delete")
        + String(" <nightly-at-2/identity,nightly/run,nightly-at-2/SC_HELP {principal=nightly-at-2;target=nightly;access=CALL}\n")
    )
    assert_equal(_lowered(ProviderShape.onprem()), onprem, "onprem")
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. the kit on every shape --------------------------------------------------------------


def test_the_kit_on_every_shape() raises:
    """Catches: a trigger node whose create skips the stamp, the retention
    mark or the run-id label; a digest that moves on a re-apply; a cron
    change that is not an update (of the schedule, or of the job's run
    where it folds); a lowering that keys on the cloud's id."""
    var shapes = _shapes()
    var ids = [String("p-t1"), String("p-a9c"), String("p-g7"), String("p-z3"), String("p-o5e")]
    assert_equal(len(shapes), len(ids), "one random id per shape")
    for s in range(len(shapes)):
        ref shape = shapes[s]
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shape.copy())))
        var cloud = FakeCloud(ids[s], shape=shape.copy())
        var later = String("0 4 * * 1-5")
        try:
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_shape_graph(shape)),
                _list(_shape_graph(shape, later)),
                _list(_shape_graph(shape, later, api_uses=False)),
                String("nightly/run"),
            )
        except e:
            raise Error(shape.name + String(" shape: ") + String(e))
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


def _verbs(applied: List[AppliedNode], where: String) -> String:
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


def test_after_an_apply() raises:
    """Catches: a schedule created before the job it starts or before the
    permission it needs; a cron change that touches anything but the
    schedule (or, where it folds, the job's run); a folded schedule that
    still creates an object; the job's run without the folded cron; a
    retarget that leaves the job holding the schedule, or creates nothing
    of the schedule's own; a schedule folded back into its job whose
    identity, object or edge is left live (or more than those deleted)."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var a = _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st))
    var sched = _at(a, String("nightly-at-2/schedule"))
    assert_true(_at(a, String("nightly/run")) < sched, "the schedule after the job it starts")
    assert_true(_at(a, String("nightly-at-2/") + uses_role(String("nightly-at-2"), String("nightly"))) < sched)
    assert_true(_at(a, String("on-upload/trigger")) > _at(a, String("media/bucket")), "a trigger after its source")
    var b = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(String("0 4 * * 1-5"))), Creds.none(), st))
    assert_equal(_verbs(b, String("generic")), "nightly-at-2/schedule:update;", "generic: a cron change")
    assert_true(_digest(cloud, String("nightly-at-2/schedule")).find("|cron=0 4 * * 1-5") >= 0)

    for which in [String("azure"), String("onprem")]:
        var shape = ProviderShape.azure() if which == "azure" else ProviderShape.onprem()
        var full = which == "azure"
        var sreg = Clouds(Catalog.v1())
        sreg.add(describe(FakeCloud(String("p-f"), shape=shape.copy())))
        var c = FakeCloud(String("p-f"), shape=shape.copy())
        var s2 = InMemoryStateStore()
        _ = _done(apply_resources(sreg, c, _ctx(), _list(_graph(warm=full, events=full)), Creds.none(), s2))
        assert_true(c.store[].find(String("nightly-at-2/schedule")) < 0, which + ": the folded schedule has no object")
        assert_true(c.store[].find(String("nightly-at-2/identity")) < 0, which + ": nor an identity")
        var job = _digest(c, String("nightly/run"))
        assert_true(job.find("|schedule=nightly-at-2|cron=30 2 * * 1-5|timezone=UTC") >= 0, which + ": " + job)
        var d = _done(
            apply_resources(sreg, c, _ctx(), _list(_graph(String("0 4 * * 1-5"), warm=full, events=full)), Creds.none(), s2)
        )
        assert_equal(_verbs(d, which), "nightly/run:update;", which + ": a cron change updates the job's run alone")
        # Retarget the schedule to the service: it is no longer the job's.
        if full:
            var e = _done(
                apply_resources(sreg, c, _ctx(), _list(_graph(String("0 4 * * 1-5"), target=String("api"))), Creds.none(), s2)
            )
            var call = String("nightly-at-2/") + uses_role(String("nightly-at-2"), String("api"))
            var got = _verbs(e, which)
            assert_equal(len(got.split(";")), 5, which + ": the retarget changes four nodes: " + got)
            for want in [
                String("nightly/run:update;"),
                String("nightly-at-2/identity:create;"),
                String("nightly-at-2/schedule:create;"),
                call + String(":create;"),
            ]:
                assert_true(got.find(want) >= 0, which + String(": ") + want + String(" in ") + got)
            assert_true(_digest(c, String("nightly/run")).find("|schedule=") < 0, which + ": the job holds no schedule")
            # And back to the job: the schedule's own roles are turned off
            # (deleted: the closed world), and the job holds it again.
            var f = _done(apply_resources(sreg, c, _ctx(), _list(_graph(String("0 4 * * 1-5"))), Creds.none(), s2))
            var back = _verbs(f, which)
            assert_equal(len(back.split(";")), 5, which + ": back to the job changes four nodes: " + back)
            for want in [
                String("nightly/run:update;"),
                String("nightly-at-2/identity:delete;"),
                String("nightly-at-2/schedule:delete;"),
                call + String(":delete;"),
            ]:
                assert_true(back.find(want) >= 0, which + String(": ") + want + String(" in ") + back)
            var held = _digest(c, String("nightly/run"))
            assert_true(held.find("|schedule=nightly-at-2|cron=0 4 * * 1-5|timezone=UTC") >= 0, which + ": " + held)
        else:
            # onprem: a schedule that calls a service is a limit (test 4);
            # removing the job's schedule updates the job's run alone.
            var f = _done(
                apply_resources(
                    sreg, c, _ctx(), _list(_graph(warm=False, events=False, schedule=False)), Creds.none(), s2
                )
            )
            assert_equal(_verbs(f, which), "nightly/run:update;", which + ": the job's run drops the schedule")
            assert_true(_digest(c, String("nightly/run")).find("|schedule=") < 0, which + ": the job holds no schedule")
    print("  test_after_an_apply: PASS")


# ---- 4. limits per shape ----------------------------------------------------------------------


def _limit_lines(shape: ProviderShape, json: String) raises -> List[String]:
    """Every limit finding of `json` on `shape`, as `id|path|reason`."""
    var cloud = FakeCloud(String("p-l"), shape=shape.copy())
    var l = _list(json)
    var firings = firings_of(l)
    var out = List[String]()
    for i in range(len(l)):
        var got = cloud.check(l[i], List[Feed](), firings)
        for k in range(len(got)):
            out.append(l[i].id + String("|") + got[k].field_path + String("|") + got[k].reason)
    return out^


def _one(id: String, body: String) -> String:
    """A job, a service and one or two more resources."""
    return (
        String('{"resource":[{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"}}},')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"scale":{"min":1,"max":3}}},')
        + String('{"id":"') + id + String('","schedule":') + body + String("}]}")
    )


def test_limits_per_shape() raises:
    """Catches: aws taking a cron its scheduler cannot read (both day
    fields), azure taking a time zone on a job's own schedule (read in UTC)
    or refusing one on a schedule that calls a service, a folding shape
    taking a second schedule of one job (the second would overwrite the
    first), onprem calling a service with a caller image nobody chose
    (Q28), a limit at the wrong path or keyed on the cloud's id, and another
    shape refusing what it hosts."""
    var shapes = _shapes()
    var days = _one(String("monthly"), String('{"cron":"0 3 1 * 1","target":{"resource":"nightly"}}'))
    var job_tz = _one(
        String("paris"), String('{"cron":"0 3 * * *","timezone":"Europe/Paris","target":{"resource":"nightly"}}')
    )
    var svc_tz = _one(
        String("paris"), String('{"cron":"0 3 * * *","timezone":"Europe/Paris","target":{"resource":"api"}}')
    )
    var two = (
        String('{"resource":[{"id":"nightly","containerJob":{"image":{"digest":"sha256:99"}}},')
        + String('{"id":"first","schedule":{"cron":"0 3 * * *","target":{"resource":"nightly"}}},')
        + String('{"id":"second","schedule":{"cron":"0 4 * * *","target":{"resource":"nightly"}}}]}')
    )
    for s in range(len(shapes)):
        ref shape = shapes[s]
        var n = shape.name
        var d = _limit_lines(shape, days)
        if n == "aws":
            assert_equal(len(d), 1, n)
            assert_equal(
                d[0],
                String('monthly|schedule.cron|on cloud "p-l" a cron cannot name both a day of the month and a day')
                + String(" of the week: ") + String(SCHEDULE_DAY_REASON_AWS),
            )
        else:
            assert_equal(len(d), 0, n + String(": both day fields"))
        var z = _limit_lines(shape, job_tz)
        if n == "azure":
            assert_equal(len(z), 1, n)
            assert_equal(
                z[0],
                String('paris|schedule.timezone|on cloud "p-l" a container job\'s schedule is read in UTC: ')
                + String(SCHEDULE_UTC_REASON_AZURE) + String("; write the cron in UTC"),
            )
        else:
            assert_equal(len(z), 0, n + String(": a time zone on a job's schedule"))
        var c = _limit_lines(shape, svc_tz)
        if n == "onprem":
            assert_equal(len(c), 1, n)
            assert_equal(
                c[0],
                String('paris|schedule.target|on cloud "p-l" a schedule cannot call a service: ')
                + String(ONPREM_SCHEDULE_CALL_REASON),
            )
        else:
            assert_equal(len(c), 0, n + String(": a schedule that calls a service, with a time zone"))
        var t = _limit_lines(shape, two)
        if n == "azure" or n == "onprem":
            assert_equal(len(t), 1, n)
            assert_equal(
                t[0],
                String('second|schedule.target|on cloud "p-l" a container job\'s schedule is a setting of the job,')
                + String(' and "nightly" already has one: "first"'),
            )
        else:
            assert_equal(len(t), 0, n + String(": two schedules of one job"))
    assert_true(String(ONPREM_SCHEDULE_CALL_REASON).find("Q28") >= 0, "the reason names Q28")
    # Through plan on onprem: the exact refusal, nothing created.
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-l"), shape=ProviderShape.onprem())))
    var cloud = FakeCloud(String("p-l"), shape=ProviderShape.onprem())
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(svc_tz), Creds.none(), st)
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "p-l". Nothing was created.')
            + String('\n  resource "paris" field schedule.target: on cloud "p-l" a schedule cannot call a service: ')
            + String(ONPREM_SCHEDULE_CALL_REASON)
            + String(" (citation: kci_cloud_fake: reference limits)"),
        )
    assert_true(raised, "onprem refuses a schedule that calls a service")
    assert_equal(cloud.mutations(), 0)
    print("  test_limits_per_shape: PASS")


# ---- 5. NOT_YET --------------------------------------------------------------------------------


def test_not_yet() raises:
    """Catches: onprem claiming an event trigger it has no plumbing for (or
    declaring it with a reason that does not name Q22), the refusal not
    naming the clouds that host it, and fake-limited claiming either
    trigger."""
    var onprem = FakeCloud(String("p-o"), shape=ProviderShape.onprem())
    var n = 0
    for i in range(len(onprem.absences())):
        if onprem.absences()[i].field == FIELD_EVENT_TRIGGER:
            n += 1
            assert_equal(onprem.absences()[i].kind, NOT_YET)
            assert_equal(onprem.absences()[i].reason, String(ONPREM_EVENT_TRIGGER_REASON))
    assert_equal(n, 1, "onprem declares the event trigger NOT_YET once")
    assert_true(String(ONPREM_EVENT_TRIGGER_REASON).find("Q22") >= 0, "the reason names Q22")
    var hosted = onprem.implemented()
    var sched = False
    for i in range(len(hosted)):
        if hosted[i] == FIELD_SCHEDULE:
            sched = True
    assert_true(sched, "onprem hosts the schedule")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-o"), shape=ProviderShape.onprem())))
    reg.add(describe(FakeCloud(String("p-a"), shape=ProviderShape.aws())))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(
            reg, onprem, _ctx(), _list(_graph(warm=False, schedule=False, api_uses=False)), Creds.none(), st
        )
    except e:
        raised = True
        assert_equal(
            String(e),
            String('kci: cannot apply this graph to cloud "p-o". Nothing was created.')
            + String('\n  resource "on-upload": event_trigger (PORTABLE): no adapter in cloud "p-o" (NOT_YET: ')
            + String(ONPREM_EVENT_TRIGGER_REASON)
            + String(")\n      clouds built into this kci that implement it: p-a"),
        )
    assert_true(raised, "onprem refuses an event trigger")
    assert_equal(onprem.mutations(), 0)
    var limited = FakeLimitedCloud()
    var absent = limited.absences()
    for f in [FIELD_SCHEDULE, FIELD_EVENT_TRIGGER]:
        var k = 0
        for i in range(len(absent)):
            if absent[i].field == f:
                k += 1
                assert_equal(absent[i].kind, NOT_YET)
        assert_equal(k, 1, String("fake-limited declares ") + String(f) + " NOT_YET once")
    print("  test_not_yet: PASS")


def main() raises:
    print("test_fake_triggers")
    test_golden_lowering_per_shape()
    test_the_kit_on_every_shape()
    test_after_an_apply()
    test_limits_per_shape()
    test_not_yet()
    print("ALL kci_cloud_fake TRIGGER TESTS PASSED")
