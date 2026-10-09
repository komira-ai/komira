# =============================================================================
# test_fake_messaging.mojo
# =============================================================================
#
# The messaging primitives (`queue`, `topic`, `subscription`) on the fake
# clouds. One graph throughout: a service `api` that SENDs to the topic `ev`,
# RECEIVEs from the queue `work` and reads its ADDRESS; `work` (ack deadline
# 45 s, 5 deliveries, then the dead-letter queue `dl`); and the subscription
# `ev-work` that feeds `work` from `ev`.
#
# 1. A GOLDEN LOWERING PER SHAPE: per node its kind, wanted, retention,
#    dependencies and, for the messaging nodes, every desired field. generic
#    and azure lower one node per resource; aws adds each queue's `policy`
#    (wanted only for the fed `work`, listing `ev`), and its subscription
#    waits for that policy; gcp lowers each queue as a private topic (wanted
#    only for the unfed `dl`) and a pull subscription on it or on `ev`,
#    dead-letters `work` to `dl`'s private topic, and lowers the subscription
#    TURNED OFF (it has no object). The full JSON of the generic lowering of
#    a queue alone (the versioned 30 s ack deadline written out) is pinned.
# 2. THE KIT ON EVERY SHAPE THAT HOSTS MESSAGING: the kci_cloud conformance
#    kit (all twelve steps) passes on generic, aws, gcp and azure, each under
#    a random id.
# 3. ONPREM DECLARES ALL THREE NOT_YET: the graph is refused on onprem
#    before anything is created, one coverage finding per messaging resource
#    naming its type and the open question (Q16), and the clouds that host
#    it (pinned refusal text).
# 4. FAKE-LIMITED DECLARES ALL THREE NOT_YET, and refuses a queue.
# 5. THE PULL-SHAPE LIMITS, on gcp, before anything is created: a second
#    topic feeding `work`; a direct SEND to the fed `work` (a `uses` line and
#    a grant resource); a queue dead-lettering to a fed queue. aws applies
#    the same two-topic file, its one queue policy listing both topics.
# 6. ADDRESSES AND RETENTION: after an apply, `api`'s run holds `work`'s
#    ADDRESS as the fake writes it (`fake-queue://work-queue`); a queue and a
#    topic written KEEP outlive a destroy with the `retain` mark, while the
#    default (DELETE) ones are destroyed.
# 7. A FEED THAT LEAVES CHANGES THE QUEUE: on gcp, dropping the subscription
#    from the file turns `work`'s private topic on (create) and moves its
#    subscription to it (update); on aws, it turns `work/policy` off
#    (delete). The subscription object itself is LEFTOVER (its resource left
#    the file), reported and not deleted, as for every resource.
# 8. `uses` ON A MESSAGING RESOURCE never reaches a lowering: validate
#    refuses it (one graph finding each on gcp, whose limits skip a resource
#    whose edges are malformed), and the fake's own lowering, asked
#    directly, refuses it too.
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
    Feed,
    Firing,
    GrantEdge,
    FIELD_QUEUE,
    FIELD_SUBSCRIPTION,
    FIELD_TOPIC,
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

from kci_cloud_fake import FakeCloud, FakeLimitedCloud, ProviderShape


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
    uses: Bool = True,
    extra: String = String(""),
    work_retention: String = String(""),
    feed: Bool = True,
) -> String:
    var u = String('"uses":[{"target":{"resource":"ev"},"access":"SEND"},')
    u += String('{"target":{"resource":"work"},"access":"RECEIVE"}]')
    if not uses:
        u = String('"uses":[]')
    var ret = String("")
    if work_retention.byte_length() > 0:
        ret = String('"retention":"') + work_retention + String('",')
    var s = (
        String('{"resource":[')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":') + port
        + String(',"internal":{},"scale":{"min":1,"max":2},"env":{"Q":{"ref":{"resource":"work","standard":"ADDRESS"}}}},')
        + u + String("},")
        + String('{"id":"dl","queue":{}},')
        + String('{"id":"work",') + ret
        + String('"queue":{"ackDeadline":"45s","deadLetter":{"resource":"dl"},"maxDeliveries":5}},')
        + String('{"id":"ev","topic":{}}')
    )
    if feed:
        s += String(',{"id":"ev-work","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"work"}}}')
    return s + extra + String("]}")


# ---- 1. a golden lowering per shape ------------------------------------------------------


def _summary(nodes: List[LoweredNode]) -> String:
    """One line per node: id, kind, wanted (+ or -), retention, dependencies,
    and every desired field of the messaging nodes."""
    var s = String("")
    for i in range(len(nodes)):
        ref n = nodes[i]
        s += n.id + String(" ") + n.kind + String(" ") + (String("+") if n.wanted else String("-"))
        s += String(" ") + retention_name(n.retention)
        for k in range(len(n.depends_on)):
            s += (String(" <") if k == 0 else String(",")) + n.depends_on[k]
        if n.owner != "api":
            s += String(" {")
            for k in range(len(n.desired)):
                if k > 0:
                    s += String(";")
                s += n.desired[k].key + String("=") + n.desired[k].value
            s += String("}")
        s += String("\n")
    return s^


def _lowered(shape: ProviderShape) raises -> String:
    var cloud = FakeCloud(String("p-m4"), shape=shape.copy())
    var got = _summary(lower_data(cloud, _list(_graph())))
    assert_equal(cloud.live_count(), 0, "lowering touched nothing")
    return got^


def _api(identity: String, run: String, public: String, grant: String) -> String:
    """`api`'s nodes: its identity, run, public (absent where it folds), and
    its three edges: SEND ev (`u-arctfl`), RECEIVE work (`u-vfws2s`) and the
    implicit cell LOGS WRITE (`u-gktqg5`), roles computed with Python
    hashlib."""
    var s = String("api/identity ") + identity + String(" + delete\n")
    s += String("api/run ") + run + String(" + delete <api/identity\n")
    if public.byte_length() > 0:
        s += String("api/public ") + public + String(" - delete <api/run\n")
    s += String("api/u-arctfl ") + grant + String(" + delete <api/identity,ev/topic\n")
    s += String("api/u-vfws2s ") + grant + String(" + delete <api/identity,work/queue\n")
    s += String("api/u-gktqg5 ") + grant + String(" + delete <api/identity\n")
    return s^


comptime _DL_FIELDS = "ack_deadline=30s;dead_letter=none;max_deliveries=none"
comptime _WORK_FIELDS = "ack_deadline=45s;dead_letter=dl;max_deliveries=5"


def test_golden_lowering_per_shape() raises:
    """Catches: a role missing or extra on any shape, a wrong provider kind,
    a dependency that lets a queue exist before its dead-letter queue or a
    subscription before its queue (or, on aws, before its policy), a gcp
    queue subscribed to the wrong topic, a gcp subscription that creates an
    object, a modelled default left out (30 s), and a retention not DELETE
    by default."""
    var generic = _api(String("identity"), String("run"), String("public"), String("grant"))
    generic += String("dl/queue queue + delete {") + String(_DL_FIELDS) + String(";addressed=queue}\n")
    generic += String("work/queue queue + delete <dl/queue {") + String(_WORK_FIELDS) + String(";addressed=queue}\n")
    generic += String("ev/topic topic + delete {addressed=topic}\n")
    generic += String("ev-work/sub subscription + delete <ev/topic,work/queue {topic=ev;queue=work}\n")
    assert_equal(_lowered(ProviderShape.generic()), generic, "generic")

    var aws = _api(
        String("AWS::IAM::Role"), String("AWS::Lambda::Function"), String("AWS::Lambda::Url"), String("AWS::IAM::RolePolicy")
    )
    aws += String("dl/queue AWS::SQS::Queue + delete {") + String(_DL_FIELDS) + String(";addressed=queue}\n")
    aws += String("dl/policy AWS::SQS::QueuePolicy - delete <dl/queue {topics=none}\n")
    aws += String("work/queue AWS::SQS::Queue + delete <dl/queue {") + String(_WORK_FIELDS) + String(";addressed=queue}\n")
    aws += String("work/policy AWS::SQS::QueuePolicy + delete <work/queue,ev/topic {topics=ev}\n")
    aws += String("ev/topic AWS::SNS::Topic + delete {addressed=topic}\n")
    aws += String("ev-work/sub AWS::SNS::Subscription + delete <ev/topic,work/queue,work/policy {topic=ev;queue=work}\n")
    assert_equal(_lowered(ProviderShape.aws()), aws, "aws")

    var t = String("pubsub.googleapis.com/Topic")
    var sub = String("pubsub.googleapis.com/Subscription")
    var gcp = _api(
        String("iam.googleapis.com/ServiceAccount"),
        String("run.googleapis.com/Service"),
        String("setIamPolicy"),
        String("setIamPolicy"),
    )
    gcp += String("dl/topic ") + t + String(" + delete {}\n")
    gcp += String("dl/queue ") + sub + String(" + delete <dl/topic {") + String(_DL_FIELDS)
    gcp += String(";topic=private;addressed=queue}\n")
    gcp += String("work/topic ") + t + String(" - delete {}\n")
    gcp += String("work/queue ") + sub + String(" + delete <dl/topic,ev/topic {") + String(_WORK_FIELDS)
    gcp += String(";topic=ev;addressed=queue}\n")
    gcp += String("ev/topic ") + t + String(" + delete {addressed=topic}\n")
    gcp += String("ev-work/sub ") + sub + String(" - delete <ev/topic,work/queue {topic=ev;queue=work}\n")
    assert_equal(_lowered(ProviderShape.gcp()), gcp, "gcp")

    var sb = String("Microsoft.ServiceBus/namespaces/")
    var azure = _api(
        String("Microsoft.ManagedIdentity/userAssignedIdentities"),
        String("Microsoft.App/containerApps"),
        String(""),
        String("Microsoft.Authorization/roleAssignments"),
    )
    azure += String("dl/queue ") + sb + String("queues + delete {") + String(_DL_FIELDS) + String(";addressed=queue}\n")
    azure += String("work/queue ") + sb + String("queues + delete <dl/queue {") + String(_WORK_FIELDS)
    azure += String(";addressed=queue}\n")
    azure += String("ev/topic ") + sb + String("topics + delete {addressed=topic}\n")
    azure += String("ev-work/sub ") + sb + String("topics/subscriptions + delete <ev/topic,work/queue {topic=ev;queue=work}\n")
    assert_equal(_lowered(ProviderShape.azure()), azure, "azure")

    # The generic lowering of a queue alone, as JSON.
    var cloud = FakeCloud()
    assert_equal(
        lowering_json(lower_data(cloud, _list(String('{"resource":[{"id":"jobs","queue":{}}]}')))),
        String('[\n  {"id":"jobs/queue","owner":"jobs","kind":"queue","wanted":true,')
        + String('"retention":"delete","depends_on":[],"inputs":[],')
        + String('"desired":{"ack_deadline":"30s","dead_letter":"none","max_deliveries":"none",')
        + String('"addressed":"queue"}}\n]'),
    )
    print("  test_golden_lowering_per_shape: PASS")


# ---- 2. the kit on every shape that hosts messaging -------------------------------------------


def test_the_kit_on_every_shape_that_hosts_messaging() raises:
    """Catches: a messaging node whose create skips the stamp, the retention
    mark or the run-id label; a digest that moves on a re-apply; a modelled
    field (the ack deadline) not compared; a turned-off role (a removed
    edge) not deleted; a lowering that keys on the cloud's id."""
    var shapes = List[ProviderShape]()
    shapes.append(ProviderShape.generic())
    shapes.append(ProviderShape.aws())
    shapes.append(ProviderShape.gcp())
    shapes.append(ProviderShape.azure())
    var ids = List[String]()
    ids.append(String("p-9q"))
    ids.append(String("p-c41e7"))
    ids.append(String("p-0f3a"))
    ids.append(String("p-ee5d1b"))
    for s in range(len(shapes)):
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(ids[s], shape=shapes[s].copy())))
        var cloud = FakeCloud(ids[s], shape=shapes[s].copy())
        try:
            run_conformance(
                reg,
                cloud,
                _ctx(),
                _list(_graph()),
                _list(_graph(String("9090"))),
                _list(_graph(String("9090"), uses=False)),
                String("work/queue"),
            )
        except e:
            raise Error(shapes[s].name + String(" shape: ") + String(e))
    print("  test_the_kit_on_every_shape_that_hosts_messaging: PASS")


# ---- 3. onprem declares all three NOT_YET ---------------------------------------------------


def test_onprem_refuses_messaging_naming_q16() raises:
    """Catches: onprem picking a message backing (it must not, until Q16 is
    answered), an absence of the wrong kind, a coverage finding missing for
    one of the three types, and a refusal after a create."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-onp"), shape=ProviderShape.onprem())))
    reg.add(describe(FakeCloud(String("p-az"), shape=ProviderShape.azure())))
    var cloud = FakeCloud(String("p-onp"), shape=ProviderShape.onprem())
    assert_true(not cloud.complete(), "a cloud with a NOT_YET type is not complete")
    var absent = cloud.absences()
    var want = [FIELD_QUEUE, FIELD_TOPIC, FIELD_SUBSCRIPTION]
    for k in range(3):
        var found = 0
        for i in range(len(absent)):
            if absent[i].field == want[k]:
                found += 1
                assert_equal(absent[i].kind, NOT_YET)
        assert_equal(found, 1, String("onprem declares field ") + String(want[k]) + " NOT_YET once")
    var why = String(
        "the onprem message backing of a queue, a topic and a subscription is an open question"
        " (Q16: RabbitMQ, NATS JetStream, Apache Kafka or Redis Streams)"
    )
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st)
    except e:
        raised = True
        var text = String('kci: cannot apply this graph to cloud "p-onp". Nothing was created.')
        var ids = ["dl", "work", "ev", "ev-work"]
        var types = ["queue", "queue", "topic", "subscription"]
        for i in range(4):
            text += String('\n  resource "') + String(ids[i]) + String('": ') + String(types[i])
            text += String(' (PORTABLE): no adapter in cloud "p-onp" (NOT_YET: ') + why + String(")")
            text += String("\n      clouds built into this kci that implement it: p-az")
        assert_equal(String(e), text)
    assert_true(raised, "messaging is refused on onprem")
    assert_equal(cloud.mutations(), 0, "nothing was created")
    print("  test_onprem_refuses_messaging_naming_q16: PASS")


# ---- 4. fake-limited declares all three NOT_YET ---------------------------------------------


def test_fake_limited_declares_messaging_not_yet() raises:
    """Catches: fake-limited claiming a messaging type it cannot lower."""
    var limited = FakeLimitedCloud()
    var absent = limited.absences()
    var n = 0
    for i in range(len(absent)):
        var f = absent[i].field
        if f == FIELD_QUEUE or f == FIELD_TOPIC or f == FIELD_SUBSCRIPTION:
            n += 1
            assert_equal(absent[i].kind, NOT_YET)
            assert_equal(absent[i].reason, "fake-limited has no messaging")
    assert_equal(n, 3, "fake-limited declares queue, topic and subscription NOT_YET")
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeLimitedCloud()))
    var raised = False
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, limited, _ctx(), _list(String('{"resource":[{"id":"q","queue":{}}]}')), Creds.none(), st)
    except e:
        raised = True
        assert_true(String(e).find("queue (PORTABLE): no adapter") >= 0, String(e))
    assert_true(raised, "a queue is refused on fake-limited")
    assert_equal(limited.mutations(), 0)
    print("  test_fake_limited_declares_messaging_not_yet: PASS")


# ---- 5. the pull-shape limits ---------------------------------------------------------------


def _refusal(shape: ProviderShape, json: String) raises -> String:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud(String("p-g"), shape=shape.copy())))
    var cloud = FakeCloud(String("p-g"), shape=shape.copy())
    try:
        var st = InMemoryStateStore()
        _ = plan_resources(reg, cloud, _ctx(), _list(json), Creds.none(), st)
    except e:
        assert_equal(cloud.mutations(), 0, "nothing was created")
        return String(e)
    return String("")


comptime _CITE = " (citation: kci_cloud_fake: reference limits)"


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + 1)
    return n


def test_gcp_refuses_what_a_pull_subscription_cannot_be() raises:
    """Catches: a gcp queue silently subscribed to only one of two topics, a
    direct send to a fed queue accepted (its messages would go nowhere), and
    a dead-letter queue with no topic to dead-letter to; and the same limits
    leaking to a shape that hosts all three (aws applies the two-topic file,
    one queue policy naming both topics)."""
    var two = String(
        ',{"id":"ev2","topic":{}},'
        '{"id":"ev2-work","subscription":{"topic":{"resource":"ev2"},"queue":{"resource":"work"}}}'
    )
    var t = _refusal(ProviderShape.gcp(), _graph(extra=two))
    assert_true(
        t.find(
            String('resource "ev2-work" field subscription.queue: on cloud "p-g" a queue is one pull')
            + String(' subscription on one topic, and queue "work" is already fed from topic "ev" by "ev-work"')
            + String(_CITE)
        )
        >= 0,
        t,
    )
    assert_equal(_count(t, String('\n  resource "')), 1, "one finding: " + t)

    var send = String(
        ',{"id":"pusher","grant":{"principal":{"resource":"api"},"target":{"resource":"work"},"access":"SEND"}}'
    )
    t = _refusal(ProviderShape.gcp(), _graph(uses=False, extra=send))
    var why = String(
        'queue "work" is a pull subscription on topic "ev" (subscription "ev-work"), so nothing sends to it'
        ' directly; send to "ev"'
    )
    assert_true(t.find(String('resource "pusher" field grant: on cloud "p-g" ') + why + String(_CITE)) >= 0, t)
    assert_equal(_count(t, String('\n  resource "')), 1, "one finding: " + t)
    var direct = _graph().replace(String('"access":"RECEIVE"'), String('"access":"SEND"'))
    t = _refusal(ProviderShape.gcp(), direct)
    assert_true(t.find(String('resource "api" field uses[1]: on cloud "p-g" ') + why + String(_CITE)) >= 0, t)
    assert_equal(_count(t, String('\n  resource "')), 1, "one finding: " + t)

    var fed_dl = String(',{"id":"late","queue":{"maxDeliveries":5,"deadLetter":{"resource":"work"}}}')
    t = _refusal(ProviderShape.gcp(), _graph(extra=fed_dl))
    assert_true(
        t.find(
            String('resource "late" field queue.dead_letter: on cloud "p-g" a queue dead-letters to the private')
            + String(' topic of its dead-letter queue, and "work" has none: it is fed from topic "ev"')
            + String(_CITE)
        )
        >= 0,
        t,
    )
    assert_equal(_count(t, String('\n  resource "')), 1, "one finding: " + t)

    # aws hosts every one of them.
    for g in [_graph(extra=two), _graph(uses=False, extra=send), direct, _graph(extra=fed_dl)]:
        assert_equal(_refusal(ProviderShape.aws(), String(g)), "", "aws hosts it")
    var cloud = FakeCloud(String("p-a"), shape=ProviderShape.aws())
    var nodes = lower_data(cloud, _list(_graph(extra=two)))
    for i in range(len(nodes)):
        if nodes[i].id == "work/policy":
            assert_equal(nodes[i].field(String("topics")), "ev,ev2", "one policy for both topics")
            assert_equal(len(nodes[i].depends_on), 3, "the queue and both topics")
    print("  test_gcp_refuses_what_a_pull_subscription_cannot_be: PASS")


# ---- 6. addresses and retention ---------------------------------------------------------------


def test_addresses_and_retention() raises:
    """Catches: a queue that exposes no ADDRESS (the reader's env would bind
    nothing), the address of another type, and a KEEP queue or topic deleted
    by destroy (or a DELETE one kept)."""
    var reg = Clouds(Catalog.v1())
    reg.add(describe(FakeCloud()))
    var cloud = FakeCloud()
    var st = InMemoryStateStore()
    var kept_topic = String(',{"id":"archive","retention":"KEEP","topic":{}}')
    var graph = _list(_graph(work_retention=String("KEEP"), extra=kept_topic))
    _ = _done(apply_resources(reg, cloud, _ctx(), graph, Creds.none(), st))
    var at = cloud.store[].find(String("api/run"))
    assert_true(at >= 0, "api/run exists")
    var digest = cloud.store[].digests[at].copy()
    assert_true(digest.find("Q=fake-queue://work-queue") >= 0, digest)
    _ = destroy_resources(reg, cloud, _ctx(), graph, Creds.none(), st)
    for id in ["work/queue", "archive/topic"]:
        var labels = cloud.live_labels(String(id))
        var kept = False
        for i in range(len(labels)):
            if labels[i].key == "kci-retention" and labels[i].value == "retain":
                kept = True
        assert_true(kept, String(id) + " is still there, marked kci-retention=retain")
    assert_equal(cloud.live_count(), 2, "the DELETE queue, topic and subscription were destroyed")
    print("  test_addresses_and_retention: PASS")


# ---- 7. a feed that leaves changes the queue -----------------------------------------------------


def _verb(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def test_a_feed_that_leaves_changes_the_queue() raises:
    """Catches: a queue lowered without its feeds (gcp would keep `work` on
    `ev` after the subscription left; aws would keep a policy for a topic
    that no longer feeds it)."""
    for shape in [ProviderShape.gcp(), ProviderShape.aws()]:
        var reg = Clouds(Catalog.v1())
        reg.add(describe(FakeCloud(String("p-f"), shape=shape.copy())))
        var cloud = FakeCloud(String("p-f"), shape=shape.copy())
        var st = InMemoryStateStore()
        _ = _done(apply_resources(reg, cloud, _ctx(), _list(_graph()), Creds.none(), st))
        var out = apply_resources(reg, cloud, _ctx(), _list(_graph(feed=False)), Creds.none(), st)
        var a = _done(out)
        if shape.name == "gcp":
            assert_equal(_verb(a, String("work/topic")), VERB_CREATE, "gcp: work's private topic is created")
            assert_equal(_verb(a, String("work/queue")), VERB_UPDATE, "gcp: work's subscription moves to it")
            assert_equal(len(out.leftover), 0, "gcp: the subscription had no object")
        else:
            assert_equal(_verb(a, String("work/policy")), VERB_DELETE, "aws: work's policy is turned off")
            assert_equal(_verb(a, String("work/queue")), VERB_NOOP, "aws: the queue itself is unchanged")
            assert_equal(len(out.leftover), 1, "aws: the subscription is leftover")
            assert_equal(out.leftover[0], "ev-work/sub")
    print("  test_a_feed_that_leaves_changes_the_queue: PASS")


# ---- 8. uses on a messaging resource --------------------------------------------------------


def test_uses_on_messaging_never_reaches_a_lowering() raises:
    """Catches: a gcp limit that raises on a resource whose edges validate
    refuses (instead of leaving it to the graph finding), and a fake lowering
    that would silently drop `uses` lines handed to it directly."""
    var bad = String(
        '{"resource":[{"id":"ev","topic":{},"uses":[{"target":{"resource":"q"},"access":"SEND"}]},'
        '{"id":"q","queue":{},"uses":[{"target":{"resource":"ev"},"access":"SEND"}]},'
        '{"id":"s","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"q"}},'
        '"uses":[{"target":{"resource":"ev"},"access":"SEND"}]}]}'
    )
    var t = _refusal(ProviderShape.gcp(), bad)
    assert_equal(_count(t, String('\n  resource "')), 3, t)
    for id in ["ev", "q", "s"]:
        assert_true(t.find(String('resource "') + String(id) + String('" field uses: a ')) >= 0, t)
    var cloud = FakeCloud()
    var l = _list(bad)
    for i in range(3):
        var raised = False
        try:
            _ = cloud.lower(l[i], List[GrantEdge](), List[Feed](), List[Firing]())
        except e:
            raised = True
            assert_true(String(e).find("has uses lines; validate refuses them") >= 0, String(e))
        assert_true(raised, l[i].id + String(": the lowering refuses uses"))
    print("  test_uses_on_messaging_never_reaches_a_lowering: PASS")


def main() raises:
    print("test_fake_messaging")
    test_golden_lowering_per_shape()
    test_the_kit_on_every_shape_that_hosts_messaging()
    test_onprem_refuses_messaging_naming_q16()
    test_fake_limited_declares_messaging_not_yet()
    test_gcp_refuses_what_a_pull_subscription_cannot_be()
    test_addresses_and_retention()
    test_a_feed_that_leaves_changes_the_queue()
    test_uses_on_messaging_never_reaches_a_lowering()
    print("ALL kci_cloud_fake MESSAGING TESTS PASSED")
