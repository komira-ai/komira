# =============================================================================
# test_fake_metadata.mojo
# =============================================================================
#
# Every resource's metadata (`labels`, `physical_name`, `adopt`) on the fake
# clouds. One graph throughout: the bucket `logs` under the author's cloud
# name `acme-logs` with two labels; the container job `job` under the name
# `nightly-export` with one label, which READs the bucket (a `uses` line the
# kit turns off) and reads its NAME; and the service account `reader` with
# one label.
#
# 1. A GOLDEN LOWERING PER SHAPE (generic, aws, gcp, azure, onprem): each
#    fixed role's kind and wanted, and the metadata kci wrote on it (the
#    label fields, sorted, on every role; the name on the primary role
#    only); the job's run reading the bucket's NAME. The JSON of the generic
#    lowering of a named, labelled bucket alone is pinned (kci's fields
#    after the adapter's, the labels sorted though written unsorted).
# 2. LABELS ON EVERY NODE, THE NAME ON THE PRIMARY ONE: on every shape,
#    every node of a labelled resource (its edges `u-<h>` included) holds
#    each label field once, a node of an unlabelled resource none, and only
#    the two primary nodes hold a name.
# 3. THE KIT ON EVERY SHAPE: the kci_cloud conformance kit (twelve steps) on
#    generic, aws, gcp, azure and onprem, each under an id of its own,
#    tampering with `logs/bucket` (written DELETE: the kit destroys what it
#    applied and expects nothing left).
# 4. AFTER AN APPLY: the job's run holds the bucket's NAME as the author
#    wrote it (`acme-logs`); `list_owned` reports the name each object was
#    created under (empty for one the cloud named); a changed label is an
#    update of every node of that resource and of nothing else; a changed
#    cloud name, and a name written on an object created without one, are
#    refused by plan, apply and destroy before any change, and the original
#    name still destroys.
# 5. ADOPT: an unstamped object at the bucket's node (the bucket the file
#    declares, test_fake_adoption.mojo says why it must be) refuses the
#    apply without `adopt` (nothing changes); with `adopt` the apply stamps
#    it (an update, never a create), `list_owned` then reports it as kci's,
#    and a re-apply is a no-op; a destroy of the adopted bucket (written
#    DELETE) is refused unless the bucket writes `adopt` ADOPT_DELETABLE, and then
#    deletes it like any object of the resource. A destroy never adopts: an
#    unstamped object refuses it, `adopt` or not.
# 6. EACH SHAPE'S METADATA LIMITS, as data: the label cap (aws 50 tags, kci
#    writes up to 8: 42 pass, 43 refused; generic has no cap), kinds with no
#    name of their own (an aws network, a gcp subscription, an azure DNS
#    zone), name lengths (gcp service account 6 to 30, gcp service at most
#    49, azure container job at most 32, onprem container job at most 52),
#    letters and digits only (an azure registry), and a schedule folded into
#    its container job (azure, onprem) refusing a name, never one that calls
#    a service on azure. Every finding is a limit cited as the fake's.
# 7. THE LOWERING CONTRACT HOLDS THE METADATA: an adapter that writes a
#    `label.<key>` or `physical_name` field itself, or lowers no primary
#    node for a named resource, is refused by `lower_data`.
# 8. ONE NAME PER KIND ON A CLOUD: a service and a worker under one name
#    are refused where their primary objects are one kind (generic, azure,
#    onprem) and taken where they are two (aws, gcp), a bucket under the
#    same name taken everywhere; plan and apply refuse it before any
#    change; the check runs only on a graph with no other finding; and the
#    kind is the lowered primary node's (a cheat adapter: one kind for all
#    collides, no primary node or a lowering that raises is skipped).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    ErasedResource,
    InMemoryStateStore,
    Label,
    OwnerStamp,
    Provenance,
    VERB_CREATE,
    VERB_DELETE,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_cloud import (
    RegistryLogin,
    Absence,
    ApplyOutcome,
    ArtifactNeed,
    BootstrapItem,
    Catalog,
    CellContext,
    CloudAdapter,
    CloudId,
    Clouds,
    FINDING_LIMIT,
    Feed,
    Finding,
    Firing,
    GrantEdge,
    LoweredNode,
    OwnedRecord,
    ExistingObject,
    Principal,
    Setting,
    apply_resources,
    describe,
    destroy_resources,
    feeds_of,
    firings_of,
    lower_data,
    lowering_json,
    plan_resources,
    run_conformance,
    validate_for,
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


def _graph(
    retention: String = String(""),
    name: String = String("acme-logs"),
    tier: String = String("gold"),
    team: String = String("data"),
    reads: Bool = True,
    arg: String = String("--all"),
    adopt: Bool = False,
    deletable: Bool = False,
) -> String:
    """The graph of the file header. `retention` is the bucket's written
    retention (empty: unset); `name` its cloud name (empty: unset); `tier`
    its second label; `team` the job's label; `reads` keeps the job's READ
    line; `arg` is its one arg; `adopt` takes the bucket over (ADOPT), and
    `deletable` lets kci delete it too (ADOPT_DELETABLE)."""
    var head = String('{"id":"logs",')
    if retention.byte_length() > 0:
        head += String('"retention":"') + retention + String('",')
    if name.byte_length() > 0:
        head += String('"physicalName":"') + name + String('",')
    if deletable:
        head += String('"adopt":"ADOPT_DELETABLE",')
    elif adopt:
        head += String('"adopt":"ADOPT",')
    var uses = String('"uses":[{"target":{"resource":"logs"},"access":"READ"}],') if reads else String("")
    return (
        String('{"resource":[')
        + head + String('"labels":{"tier":"') + tier + String('","team":"data"},"bucket":{}},')
        + String('{"id":"job",') + uses + String('"labels":{"team":"') + team + String('"},')
        + String('"physicalName":"nightly-export",')
        + String('"containerJob":{"image":{"digest":"sha256:b1"},"args":["') + arg + String('"],')
        + String('"env":{"LOGS":{"ref":{"resource":"logs","standard":"NAME"}}}}},')
        + String('{"id":"reader","labels":{"team":"data"},"serviceAccount":{}}')
        + String("]}")
    )


def _shapes() -> List[ProviderShape]:
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    l.append(ProviderShape.onprem())
    return l^


def _is_edge(id: String) -> Bool:
    return id.find("/u-") >= 0 or id.find("/r-") >= 0


def _meta(n: LoweredNode) -> String:
    """The metadata fields of `n`, in order: `{k=v;...}`."""
    var s = String("{")
    var first = True
    for k in range(len(n.desired)):
        ref key = n.desired[k].key
        if key.startswith("label.") or key == "physical_name":
            if not first:
                s += String(";")
            first = False
            s += key + String("=") + n.desired[k].value
    return s + String("}")


# ---- 1. a golden lowering per shape ------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per fixed role (no edges): id, kind, wanted (+ or -),
    `job/run`'s inputs (`[producer.OUTPUT>field]`), and the metadata."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        if _is_edge(n.id):
            continue
        s += n.id + String(" ") + n.kind + String(" ") + (String("+") if n.wanted else String("-"))
        if n.id == "job/run":
            for k in range(len(n.inputs)):
                ref inp = n.inputs[k]
                s += (String(" [") if k == 0 else String(",")) + inp.producer + String(".") + inp.output
                s += String(">") + inp.field
                if k == len(n.inputs) - 1:
                    s += String("]")
        s += String(" ") + _meta(n) + String("\n")
    return s^


def _golden(bucket: String, ident: String, run: String, vault: String = String("")) -> String:
    var s = String("logs/bucket ") + bucket + String(" + {label.team=data;label.tier=gold;physical_name=acme-logs}\n")
    s += String("job/identity ") + ident + String(" + {label.team=data}\n")
    if vault.byte_length() > 0:
        s += String("job/vault ") + vault + String(" + {label.team=data}\n")
    s += String("job/run ") + run + String(" + [logs/bucket.NAME>container_job.env.LOGS]")
    s += String(" {label.team=data;physical_name=nightly-export}\n")
    s += String("reader/identity ") + ident + String(" + {label.team=data}\n")
    if vault.byte_length() > 0:
        s += String("reader/vault ") + vault + String(" + {label.team=data}\n")
    return s^


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-m1"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_graph())))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


def test_golden_lowering_per_shape() raises:
    """Catches: a label not lowered (or lowered unsorted, or under another
    field name) on any role, the name lowered on a role other than the
    primary one (or not at all), metadata lowered as something other than
    desired state, and a reference to the named bucket that no longer lands
    on its primary node."""
    assert_equal(_lowered(ProviderShape.generic()), _golden(String("bucket"), String("identity"), String("run")), "generic")
    assert_equal(
        _lowered(ProviderShape.aws()),
        _golden(String("AWS::S3::Bucket"), String("AWS::IAM::Role"), String("AWS::ECS::TaskDefinition")),
        "aws",
    )
    assert_equal(
        _lowered(ProviderShape.gcp()),
        _golden(String("storage.googleapis.com/Bucket"), String("iam.googleapis.com/ServiceAccount"), String("run.googleapis.com/Job")),
        "gcp",
    )
    assert_equal(
        _lowered(ProviderShape.azure()),
        _golden(
            String("Microsoft.Storage/storageAccounts/blobServices/containers"),
            String("Microsoft.ManagedIdentity/userAssignedIdentities"),
            String("Microsoft.App/jobs"),
        ),
        "azure",
    )
    assert_equal(
        _lowered(ProviderShape.onprem()),
        _golden(String("minio/Bucket"), String("v1/ServiceAccount"), String("batch/v1/CronJob"), String("vault:auth/kubernetes/role")),
        "onprem",
    )
    var cloud = FakeCloud()
    assert_equal(
        lowering_json(
            lower_data(
                cloud,
                _list(String('{"resource":[{"id":"logs","physicalName":"acme-logs",')
                + String('"labels":{"tier":"gold","team":"data"},"bucket":{}}]}')),
            )
        ),
        String('[\n  {"id":"logs/bucket","owner":"logs","kind":"bucket","wanted":true,')
        + String('"retention":"keep","depends_on":[],"inputs":[],')
        + String('"desired":{"expiry_days":"never","versioning":"false","tier":"STANDARD","stores":"true",')
        + String('"label.team":"data","label.tier":"gold","physical_name":"acme-logs"}}\n]'),
    )
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. labels on every node, the name on the primary one ------------------------------


def test_labels_ride_on_every_node_and_the_name_on_the_primary() raises:
    """Catches: a node of a labelled resource lowered without its labels (an
    edge's included: it is the resource's object too), a label written twice
    on one node, labels leaking onto another resource's nodes, and a name on
    any node but the two primary ones."""
    var shapes = _shapes()
    for s in range(len(shapes)):
        var cloud = FakeCloud(String("p-m2"), shape=shapes[s].copy())
        var nodes = lower_data(cloud, _list(_graph()))
        var named = 0
        var edges = 0
        for i in range(len(nodes)):
            ref n = nodes[i]
            var team = 0
            var tier = 0
            for k in range(len(n.desired)):
                if n.desired[k].key == "label.team":
                    team += 1
                if n.desired[k].key == "label.tier":
                    tier += 1
                if n.desired[k].key == "physical_name":
                    named += 1
                    assert_true(n.id == "logs/bucket" or n.id == "job/run", n.id + String(" holds a name"))
            var where = shapes[s].name + String(" ") + n.id
            assert_equal(team, 1, where + String(": label.team once"))
            assert_equal(tier, 1 if n.owner == "logs" else 0, where + String(": label.tier only on logs"))
            if _is_edge(n.id):
                edges += 1
        assert_equal(named, 2, shapes[s].name + String(": two named primary nodes"))
        assert_true(edges >= 1, shapes[s].name + String(": the edges were checked too"))
    print("  test_labels_ride_on_every_node_and_the_name_on_the_primary: PASS")


# ---- 3. the kit on every shape -----------------------------------------------------------


def test_the_kit_on_every_shape() raises:
    """Catches: a node whose metadata makes its digest move on a re-apply
    (an unsorted label order would), a create that skips the stamp, the
    retention mark or the run-id label of a named or labelled object, a
    tampered named bucket not planned as an update, a turned-off edge of a
    labelled resource not deleted, and a lowering that keys on the cloud's
    id."""
    var shapes = _shapes()
    var ids = [String("p-q7"), String("p-a3x"), String("p-g9"), String("p-z2"), String("p-o5")]
    for s in range(len(shapes)):
        ref shape = shapes[s]
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shape.copy())))
        var cloud = FakeCloud(ids[s], shape=shape.copy())
        try:
            var d = String("DELETE")
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_graph(retention=d)),
                _list(_graph(retention=d, arg=String("--since=1d"))),
                _list(_graph(retention=d, reads=False, arg=String("--since=1d"))),
                String("logs/bucket"),
            )
        except e:
            raise Error(shape.name + String(" shape: ") + String(e))
    print("  test_the_kit_on_every_shape: PASS")


# ---- 4. after an apply ------------------------------------------------------------------


def _digest(cloud: FakeCloud, id: String) raises -> String:
    var at = cloud.store[].find(id)
    assert_true(at >= 0, id + String(" is live"))
    return cloud.store[].digests[at].copy()


def _reg() raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    return reg^


def _refused(
    reg: Clouds, mut cloud: FakeCloud, json: String, verb: String, mut st: InMemoryStateStore, want: String
) raises:
    """`verb` (plan, apply or destroy) of `json` raises a refusal holding
    `want`, and nothing is mutated."""
    var before = cloud.mutations()
    var raised = False
    try:
        if verb == "plan":
            _ = plan_resources(reg, cloud, _ctx(), _list(json), Creds.none(), st)
        elif verb == "apply":
            _ = apply_resources(reg, cloud, _ctx(), _list(json), Creds.none(), st)
        else:
            _ = destroy_resources(reg, cloud, _ctx(), _list(json), Creds.none(), st)
    except e:
        raised = True
        assert_true(String(e).find("Nothing was created.") >= 0, verb + String(": ") + String(e))
        assert_true(String(e).find(want) >= 0, verb + String(": ") + String(e))
    assert_true(raised, verb + String(" is refused"))
    assert_equal(cloud.mutations(), before, verb + String(": nothing changed"))


def test_after_an_apply() raises:
    """Catches: an output of the named bucket built on its id instead of its
    name, `list_owned` not reporting the name an object was created under
    (or reporting one for an object the cloud named), a label change
    planned as a no-op or spilling onto another resource's nodes, and a
    rename (either way, or from the cloud's own name) taken as an update
    on plan, apply or destroy (it would orphan the first object)."""
    var reg = _reg()
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"))), Creds.none(), st))
    var run = _digest(cloud, String("job/run"))
    assert_true(run.find("|container_job.env.LOGS=acme-logs") >= 0, "the run holds the bucket's name: " + run)
    var owned = cloud.list_owned(Creds.none(), _ctx().scope)
    var seen = 0
    for i in range(len(owned)):
        if owned[i].owner_node == "logs/bucket":
            assert_equal(owned[i].name, "acme-logs", "logs/bucket was created under acme-logs")
            seen += 1
        elif owned[i].owner_node == "job/run":
            assert_equal(owned[i].name, "nightly-export")
            seen += 1
        else:
            assert_equal(owned[i].name, "", owned[i].owner_node + String(" was named by the cloud"))
    assert_equal(seen, 2)

    var b = _done(
        apply_resources(reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"), team=String("ops"))), Creds.none(), st)
    )
    var updated = 0
    for i in range(len(b)):
        var want = VERB_UPDATE if b[i].logical_id.startswith("job/") else VERB_NOOP
        assert_equal(b[i].verb, want, b[i].logical_id + String(": a label of job changed"))
        if want == VERB_UPDATE:
            updated += 1
    assert_true(updated >= 3, "every node of job: identity, run and its edges")
    assert_true(_digest(cloud, String("job/run")).find("|label.team=ops") >= 0, "the run holds the new label")

    var renamed = _graph(retention=String("DELETE"), team=String("ops"), name=String("acme-archive"))
    for verb in [String("plan"), String("apply"), String("destroy")]:
        _refused(reg, cloud, renamed, verb, st, String('the cloud name of logs/bucket changed from "acme-logs" to "acme-archive"'))
    var unnamed = _graph(retention=String("DELETE"), team=String("ops"), name=String(""))
    _refused(reg, cloud, unnamed, String("apply"), st, String("changed from \"acme-logs\" to the cloud's own"))
    _ = destroy_resources(reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"), team=String("ops"))), Creds.none(), st)
    assert_equal(cloud.live_count(), 0, "the original name destroys everything")

    # A name written on an object created without one is a rename too.
    var cloud2 = FakeCloud()
    var st2 = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud2, _ctx(), _list(_graph(name=String(""))), Creds.none(), st2))
    _refused(reg, cloud2, _graph(), String("apply"), st2, String("changed from the cloud's own to \"acme-logs\""))
    print("  test_after_an_apply: PASS")


# ---- 5. adopt -----------------------------------------------------------------------------


def _verb(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def test_adopt_takes_over_the_named_object() raises:
    """Catches: an unstamped object taken over without `adopt` (it must be
    refused as foreign), `adopt` not reaching the engine (the apply is
    refused anyway), an adopted object re-created instead of stamped, an
    adopted object not listed as kci's afterwards, a re-apply that is not a
    no-op, an adopted object a destroy deletes without ADOPT_DELETABLE or
    does not delete at its written retention with it, and a destroy that
    adopts (it would delete an object kci
    never took over)."""
    var reg = _reg()
    var cloud = FakeCloud()
    var declared = lower_data(cloud, _list(_graph(retention=String("DELETE"), adopt=True)))
    for i in range(len(declared)):
        if declared[i].id == "logs/bucket":
            cloud.plant_like(declared[i])
    var st = InMemoryStateStore()
    var before = cloud.mutations()
    var refused = apply_resources(reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"))), Creds.none(), st)
    assert_true(refused.refused(), "an unstamped object refuses the apply without adopt")
    assert_equal(cloud.mutations(), before, "nothing changed")

    var raised = False
    try:
        _ = destroy_resources(reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"), adopt=True)), Creds.none(), st)
    except e:
        raised = True
        assert_true(String(e).find("kci: REFUSED") >= 0, String(e))
    assert_true(raised, "a destroy never adopts: the unstamped object refuses it")
    assert_equal(cloud.store[].find(String("logs/bucket")) >= 0, True, "the foreign object is still there")

    var adopted = _done(
        apply_resources(reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"), adopt=True)), Creds.none(), st)
    )
    assert_equal(_verb(adopted, String("logs/bucket")), VERB_UPDATE, "stamped and converged, never created")
    assert_equal(cloud.store[].creates_of(String("logs/bucket")), 0, "the bucket was never created by kci")
    var mine = False
    var owned = cloud.list_owned(Creds.none(), _ctx().scope)
    for i in range(len(owned)):
        if owned[i].owner_node == "logs/bucket":
            mine = True
            assert_equal(owned[i].name, "acme-logs")
    assert_true(mine, "the adopted bucket is listed as kci's")
    var again = _done(
        apply_resources(reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"), adopt=True)), Creds.none(), st)
    )
    for i in range(len(again)):
        assert_equal(again[i].verb, VERB_NOOP, again[i].logical_id + String(": a re-apply is a no-op"))
    var kept = False
    try:
        _ = destroy_resources(reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"), adopt=True)), Creds.none(), st)
    except e:
        kept = String(e).find("ADOPT_DELETABLE") >= 0
    assert_true(kept, "kci did not create the bucket: a destroy without ADOPT_DELETABLE is refused")
    assert_true(cloud.store[].find(String("logs/bucket")) >= 0, "the adopted bucket is still there")
    _ = destroy_resources(
        reg, cloud, _ctx(), _list(_graph(retention=String("DELETE"), adopt=True, deletable=True)), Creds.none(), st
    )
    assert_equal(cloud.live_count(), 0, "with ADOPT_DELETABLE, destroy deletes the adopted bucket at DELETE")
    print("  test_adopt_takes_over_the_named_object: PASS")


# ---- 6. each shape's metadata limits ------------------------------------------------------


def _rep(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def _labels(n: Int) -> String:
    var s = String('"labels":{')
    for i in range(n):
        if i > 0:
            s += String(",")
        s += String('"k') + String(i) + String('":"v"')
    return s + String("},")


def _check(shape: ProviderShape, json: String) raises -> List[String]:
    """`check` of every resource of `json` on a fake of `shape`, as
    `id|path|reason` lines; each must be a limit cited as the fake's."""
    var cloud = FakeCloud(String("p-lim"), shape=shape.copy())
    var l = _list(json)
    var feeds = feeds_of(l)
    var firings = firings_of(l)
    var out = List[String]()
    for i in range(len(l)):
        var f = cloud.check(l[i], feeds, firings)
        for k in range(len(f)):
            assert_equal(f[k].kind, FINDING_LIMIT, f[k].reason)
            assert_equal(f[k].citation, "kci_cloud_fake: reference limits", "cited as the fake's")
            out.append(f[k].resource_id + String("|") + f[k].field_path + String("|") + f[k].reason)
    return out^


def _one(lines: List[String], prefix: String, reason: String) raises:
    var n = 0
    var all = String("")
    for i in range(len(lines)):
        all += lines[i] + String("\n")
        if lines[i].startswith(prefix) and lines[i].find(reason) >= 0:
            n += 1
    assert_equal(n, 1, String("one finding ") + prefix + String(" ... ") + reason + String(" in:\n") + all)


comptime IMG = '"image":{"digest":"sha256:0011"}'


def test_each_shape_refuses_its_metadata_limits() raises:
    """Catches: a cloud's label cap not checked (or not leaving room for
    kci's own eight), a kind with no name of its own on a cloud taking one,
    a name length or character rule of a cloud not checked (each would fail
    at create, part-way through an apply), a folded schedule taking a name
    it has no object for, a rule leaking onto a shape that does not have it
    (the generic shape, a schedule that calls a service), and a shape's
    limit cited as anything but the fake's."""
    var aws = _check(
        ProviderShape.aws(),
        String('{"resource":[')
        + String('{"id":"ok42",') + _labels(42) + String('"bucket":{}},')
        + String('{"id":"over43",') + _labels(43) + String('"bucket":{}},')
        + String('{"id":"core","physicalName":"core-net","network":{"ipv4Cidr":"198.51.100.0/24"}},')
        + String('{"id":"b2","physicalName":"ab","bucket":{}}')
        + String("]}"),
    )
    _one(aws, "over43|labels|", "an object carries 50 labels, 8 of them kci's: at most 42 of the author's; this resource writes 43")
    _one(aws, "core|physical_name|", "this kind has no name an author chooses: a VPC is an id the cloud assigns")
    _one(aws, "b2|physical_name|", "this kind's name is 3 to 63 bytes; \"ab\" is 2")
    assert_equal(len(aws), 3, "aws: nothing else")
    assert_equal(len(_check(ProviderShape.generic(), String('{"resource":[{"id":"many",') + _labels(80) + String('"bucket":{}}]}'))), 0, "generic has no cap")

    var gcp = _check(
        ProviderShape.gcp(),
        String('{"resource":[')
        + String('{"id":"q","queue":{}},{"id":"t","topic":{}},')
        + String('{"id":"s","physicalName":"feed-sub","subscription":{"topic":{"resource":"t"},"queue":{"resource":"q"}}},')
        + String('{"id":"short","physicalName":"abcde","serviceAccount":{}},')
        + String('{"id":"long","physicalName":"abcdefghijklmnopqrstuvwxyz01234","serviceAccount":{}},')
        + String('{"id":"fits","physicalName":"abcdef","serviceAccount":{}},')
        + String('{"id":"api","physicalName":"') + _rep(String("a"), 50) + String('","service":{') + String(IMG) + String(',"internal":{}}}')
        + String("]}"),
    )
    _one(gcp, "s|physical_name|", "a subscription has no object of its own")
    _one(gcp, "short|physical_name|", "this kind's name is 6 to 30 bytes; \"abcde\" is 5")
    _one(gcp, "long|physical_name|", "is 31")
    _one(gcp, "api|physical_name|", "this kind's name is 1 to 49 bytes")
    assert_equal(len(gcp), 4, "gcp: nothing else")

    var azure = _check(
        ProviderShape.azure(),
        String('{"resource":[')
        + String('{"id":"zone","physicalName":"my-zone","dnsZone":{"name":"example.com"}},')
        + String('{"id":"reg","physicalName":"my-reg","registry":{"format":"OCI"}},')
        + String('{"id":"job","physicalName":"') + _rep(String("j"), 33) + String('","containerJob":{') + String(IMG) + String("}},")
        + String('{"id":"api","service":{') + String(IMG) + String(',"internal":{}}},')
        + String('{"id":"nightly","physicalName":"nightly-run","schedule":{"cron":"0 2 * * *","target":{"resource":"job"}}},')
        + String('{"id":"ping","physicalName":"ping-api","schedule":{"cron":"0 2 * * *","target":{"resource":"api"}}}')
        + String("]}"),
    )
    _one(azure, "zone|physical_name|", "a DNS zone is named by its domain")
    _one(azure, "reg|physical_name|", "this kind's name is letters and digits only: \"my-reg\" holds '-'")
    _one(azure, "job|physical_name|", "this kind's name is 2 to 32 bytes")
    _one(azure, "nightly|physical_name|", "a schedule of a container job is the job's own schedule: it has no object to name")
    assert_equal(len(azure), 4, "azure: nothing else (the schedule that calls a service keeps its name)")

    var onprem = _check(
        ProviderShape.onprem(),
        String('{"resource":[')
        + String('{"id":"job","physicalName":"') + _rep(String("j"), 53) + String('","containerJob":{') + String(IMG) + String("}},")
        + String('{"id":"nightly","physicalName":"nightly-run","schedule":{"cron":"0 2 * * *","target":{"resource":"job"}}}')
        + String("]}"),
    )
    _one(onprem, "job|physical_name|", "this kind's name is 1 to 52 bytes")
    _one(onprem, "nightly|physical_name|", "a schedule of a container job is the job's own schedule")
    assert_equal(len(onprem), 2, "onprem: nothing else")
    print("  test_each_shape_refuses_its_metadata_limits: PASS")


# ---- 7. the lowering contract holds the metadata -----------------------------------------


struct _Cheat(CloudAdapter, Movable):
    """The generic fake, except that it writes `label.x` (`mode` "label")
    or `physical_name` (`mode` "name") on every node itself, or lowers no
    `bucket` node (`mode` holds "drop"). For section 8: `mode` holding
    "same" lowers every node to the one kind `k`, "hide" lowers no bucket
    or table node, and "raise" raises on the resource `b`."""

    var inner: FakeCloud
    var mode: String

    def __init__(out self, mode: String):
        self.inner = FakeCloud(String("cheat"))
        self.mode = mode

    def cloud_id(self) -> CloudId:
        return self.inner.cloud_id()

    def complete(self) -> Bool:
        return self.inner.complete()

    def implemented(self) -> List[Int]:
        return self.inner.implemented()

    def absences(self) -> List[Absence]:
        return self.inner.absences()

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        return self.inner.configure(ctx)

    def public_mechanism(self) -> String:
        return self.inner.public_mechanism()

    def check(self, r: Resource, feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
        return self.inner.check(r, feeds, firings)

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return self.inner.required_artifact(r)

    def lower(
        self, r: Resource, edges: List[GrantEdge], feeds: List[Feed], firings: List[Firing]
    ) raises -> List[LoweredNode]:
        if self.mode.find("raise") >= 0 and r.id == "b":
            raise Error("this cheat cannot lower b")
        var nodes = self.inner.lower(r, edges, feeds, firings)
        var out = List[LoweredNode]()
        for i in range(len(nodes)):
            var n = nodes[i].copy()
            if self.mode.find("drop") >= 0 and n.id.endswith("/bucket"):
                continue
            if self.mode.find("hide") >= 0 and (n.id.endswith("/bucket") or n.id.endswith("/table")):
                continue
            if self.mode.find("same") >= 0:
                n.kind = String("k")
            if self.mode == "label":
                n.desired.append(Setting(String("label.x"), String("y")))
            if self.mode == "name":
                n.desired.append(Setting(String("physical_name"), String("mine")))
            out.append(n^)
        if len(out) == 0:
            out.append(LoweredNode(r.id + String("/other"), r.id, String("other")))
        return out^

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        return self.inner.realize(node)

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        return self.inner.bootstrap_resources(machine, cell)

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return self.inner.label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        return self.inner.identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        return self.inner.list_owned(creds, scope)

    def read_existing(mut self, creds: Creds, node: LoweredNode) raises -> ExistingObject:
        return self.inner.read_existing(creds, node)

    def release(mut self, creds: Creds, record: OwnedRecord) raises:
        self.inner.release(creds, record)

    def whoami(mut self, creds: Creds) raises -> Principal:
        return self.inner.whoami(creds)

    def trust_render(self, scope: CellScope) -> String:
        return self.inner.trust_render(scope)

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        return self.inner.trust_check(creds, scope)

    def image_registry(self, ctx: CellContext) -> String:
        return self.inner.image_registry(ctx)

    def registry_login(mut self, creds: Creds) raises -> RegistryLogin:
        return self.inner.registry_login(creds)


def _contract(mode: String, json: String, want: String) raises:
    var raised = False
    try:
        _ = lower_data(_Cheat(mode), _list(json))
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, mode + String(": ") + String(e))
    assert_true(raised, mode + String(": the lowering contract refuses it"))


def test_the_lowering_contract_holds_the_metadata() raises:
    """Catches: an adapter allowed to write kci's metadata fields itself (a
    label an author never wrote, or a name kci did not validate, would be
    created), and a named resource lowered with no primary node to carry
    the name (the name would silently not apply). The honest lowering of
    the same graphs passes (the control)."""
    var plain = String('{"resource":[{"id":"logs","bucket":{}}]}')
    var named = String('{"resource":[{"id":"logs","physicalName":"acme-logs","bucket":{}}]}')
    _contract(String("label"), plain, String('it wrote the desired field "label.x", which is kci\'s (the metadata)'))
    _contract(String("name"), plain, String('it wrote the desired field "physical_name", which is kci\'s'))
    _contract(String("drop"), named, String('lowered no primary node "logs/bucket" to hold the cloud name of "logs"'))
    assert_equal(len(lower_data(_Cheat(String("drop")), _list(plain))), 1, "an unnamed resource needs no primary node here")
    assert_equal(len(lower_data(_Cheat(String("honest")), _list(named))), 1, "the honest lowering passes")
    print("  test_the_lowering_contract_holds_the_metadata: PASS")


# ---- 8. one name per kind on a cloud -------------------------------------------------------


def _validated[S: CloudAdapter](cloud: S, json: String) raises -> List[String]:
    """`validate_for` of `json` on `cloud`, as `id|path|reason` lines."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    var f = validate_for(reg, cloud, _list(json))
    var out = List[String]()
    for k in range(len(f)):
        out.append(f[k].resource_id + String("|") + f[k].field_path + String("|") + f[k].reason)
    return out^


def _all_of(lines: List[String]) -> String:
    var s = String("")
    for i in range(len(lines)):
        s += lines[i] + String("\n")
    return s^


comptime SHARED = (
    '{"resource":[{"id":"api","physicalName":"web","service":{"image":{"digest":"sha256:0011"},"internal":{},"scale":{"min":1,"max":2}}},'
    + '{"id":"w","physicalName":"web","worker":{"image":{"digest":"sha256:0011"}}},'
    + '{"id":"b","physicalName":"web","bucket":{}}]}'
)
"""A service, a worker and a bucket under one cloud name `web`: three
types, so the graph rule (one name per type) passes."""


def test_one_name_per_kind_on_each_shape() raises:
    """Catches: one name taken by two types whose primary objects are one
    kind on a cloud (a service and a worker that are both a container app on
    azure, both a Deployment on onprem, both `run` on generic): it would pass
    validate and collide at create, part-way through an apply. And the
    other way: a name refused for two kinds that are distinct (the bucket
    beside them everywhere; the service and the worker on aws and gcp,
    where they are two kinds), which would refuse a file the cloud takes.
    MUTANTS: the kind left out of the comparison (aws, gcp and the bucket
    go red); the check not called by validate (generic, azure, onprem go
    red)."""
    var shapes = _shapes()
    var kinds = List[String]()
    kinds.append(String("run"))
    kinds.append(String(""))
    kinds.append(String(""))
    kinds.append(String("Microsoft.App/containerApps"))
    kinds.append(String("apps/v1/Deployment"))
    for i in range(len(shapes)):
        var id = String("p-") + shapes[i].name
        var l = _validated(FakeCloud(id, shape=shapes[i].copy()), String(SHARED))
        if kinds[i].byte_length() == 0:
            assert_equal(len(l), 0, shapes[i].name + String(": two kinds, no finding:\n") + _all_of(l))
            continue
        assert_equal(len(l), 1, shapes[i].name + String(": one finding:\n") + _all_of(l))
        assert_equal(
            l[0],
            String('w|physical_name|"web" is also the cloud name of "api": on cloud "') + id + String('" both are ')
            + kinds[i] + String(", and one name names one object of a kind"),
        )
    print("  test_one_name_per_kind_on_each_shape: PASS")


def test_one_name_per_kind_refuses_before_any_change() raises:
    """Catches: the per-kind refusal reported by validate but not stopping
    plan or apply (the apply would create the service, then fail on the
    worker). And the gate: the check runs only on a graph with no other
    finding (it lowers, and an adapter is never asked to lower a graph it
    refused), so a collision beside a bad label reports the label alone.
    MUTANT: the gate dropped (the second graph reports two findings)."""
    var reg = _reg()
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    for verb in [String("plan"), String("apply")]:
        _refused(reg, cloud, String(SHARED), verb, st, String('"web" is also the cloud name of "api"'))
    assert_equal(cloud.live_count(), 0, "nothing was created")
    var bad = String(SHARED).replace('{"id":"b",', '{"id":"b","labels":{"Bad":"x"},')
    var l = _validated(FakeCloud(), bad)
    assert_equal(len(l), 1, String("the label alone:\n") + _all_of(l))
    assert_true(l[0].startswith("b|labels.Bad|"), l[0])
    print("  test_one_name_per_kind_refuses_before_any_change: PASS")


def test_one_name_per_kind_reads_the_lowering() raises:
    """Catches: the kind taken from anything but the cloud's lowered
    primary node. A cheat that lowers every node to one kind makes a
    bucket and a table under one name collide (the positive control); one
    that lowers neither a bucket nor a table node, or that cannot lower the
    bucket, makes no finding and does not raise (the lowering contract
    refuses those at plan). MUTANT: an empty kind (no primary node) not
    skipped ("hide" goes red: two empty kinds compare equal)."""
    var g = String(
        '{"resource":[{"id":"b","physicalName":"web","bucket":{}},'
        + '{"id":"t","physicalName":"web","table":{"key":{"partition":{"name":"id","type":"STRING"}}}}]}'
    )
    var same = _validated(_Cheat(String("same")), g)
    assert_equal(len(same), 1, String("same:\n") + _all_of(same))
    assert_equal(same[0], 't|physical_name|"web" is also the cloud name of "b": on cloud "cheat" both are k, and one name names one object of a kind')
    var hide = _validated(_Cheat(String("same,hide")), g)
    assert_equal(len(hide), 0, String("hide:\n") + _all_of(hide))
    var boom = _validated(_Cheat(String("same,raise")), g)
    assert_equal(len(boom), 0, String("raise:\n") + _all_of(boom))
    assert_equal(len(_validated(_Cheat(String("honest")), g)), 0, "two kinds on the honest generic lowering")
    print("  test_one_name_per_kind_reads_the_lowering: PASS")


def main() raises:
    print("test_fake_metadata")
    test_golden_lowering_per_shape()
    test_labels_ride_on_every_node_and_the_name_on_the_primary()
    test_the_kit_on_every_shape()
    test_after_an_apply()
    test_adopt_takes_over_the_named_object()
    test_each_shape_refuses_its_metadata_limits()
    test_the_lowering_contract_holds_the_metadata()
    test_one_name_per_kind_on_each_shape()
    test_one_name_per_kind_refuses_before_any_change()
    test_one_name_per_kind_reads_the_lowering()
    print("ALL kci_cloud_fake METADATA TESTS PASSED")
