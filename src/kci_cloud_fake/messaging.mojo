# =============================================================================
# kci_cloud_fake/messaging.mojo: how the fake clouds lower the MESSAGING
# types (queue, topic, subscription), and the limits a shape whose queue is
# a pull subscription refuses.
# =============================================================================
#
# A messaging resource runs as no identity: it holds no `identity` role and
# no grant (validate refuses `uses` on it), and it is only granted to (a
# queue SEND and RECEIVE, a topic SEND). The roles per shape are in
# shapes.mojo; kci hands every lowering the list's FEEDS (kci_cloud.feed),
# so a queue knows the topics that deliver to it without reading another
# resource.
#
#   * queue -> `<id>/queue` with every modelled field, the default filled in:
#     `ack_deadline` (`30s` when unset, kci_cloud's versioned default),
#     `dead_letter` (the queue's id, `none` when unset), `max_deliveries`
#     (`none` when unset), and `addressed=queue` (it exposes NAME and
#     ADDRESS; how the node behaves, not state). It depends on its
#     dead-letter queue. Then, by shape:
#       - a `policy` row (aws): `<id>/policy`, wanted iff a feed delivers to
#         the queue, with `topics` (every feeding topic, in feed order),
#         depending on the queue and on each of those topics;
#       - a `topic` row (gcp, where the queue is a pull subscription): FIRST
#         `<id>/topic`, the private topic, wanted iff no feed delivers to
#         the queue; the `queue` node then has the field `topic` (`private`,
#         or the feeding topic's id) and depends on that topic. Its
#         dead-letter dependency is the dead-letter queue's private topic
#         (`<dead letter>/topic`), the topic Pub/Sub dead-letters to.
#   * topic -> `<id>/topic`, `addressed=topic`.
#   * subscription -> `<id>/sub` with `topic` and `queue`, depending on both
#     (and, on aws, on the queue's `policy`, so the queue accepts the topic's
#     deliveries before the subscription exists). On a shape whose queue is a
#     pull subscription (gcp) the subscription has NO OBJECT: it is the topic
#     the queue's subscription is on, so its one role is lowered TURNED OFF.
#
# THE LIMITS of a shape whose queue is a pull subscription on ONE topic
# (`messaging_limits`, asked by `check`; each cites FAKE_CITATION):
#   * a second subscription delivering to one queue (the queue is already a
#     subscription on the first one's topic);
#   * a SEND edge (a `uses` line or a grant) to a fed queue (its
#     subscription is on the feeding topic, so a direct send has no topic
#     to go to: send to the topic);
#   * a dead-letter queue that is fed (a queue dead-letters to the private
#     topic of its dead-letter queue, which a fed queue does not have).
# =============================================================================

from kci_reconciler import InputRef
from kci_cloud import (
    ACCESS_SEND,
    FIELD_QUEUE,
    FIELD_SUBSCRIPTION,
    FIELD_TOPIC,
    FINDING_LIMIT,
    Feed,
    Finding,
    GrantEdge,
    LoweredNode,
    Setting,
    ack_deadline_seconds,
    body_is,
    dead_letter_of,
    edges_of,
    feeds_into,
)
from kci_resource_proto.resource import Resource

from kci_cloud_fake.shapes import ProviderShape, ROLE_POLICY, ROLE_QUEUE, ROLE_SUB, ROLE_TOPIC


comptime FAKE_MESSAGING_CITATION = "kci_cloud_fake: reference limits"
comptime NONE = "none"
comptime PRIVATE_TOPIC = "private"


def _no_uses(r: Resource, what: String) raises:
    if len(r.uses) > 0:
        raise Error(
            String("fake: ") + what + String(" \"") + r.id + String("\" has uses lines; validate refuses them")
        )


def pull_shape(shape: ProviderShape) -> Bool:
    """True iff a queue on `shape` is a pull subscription with a private
    topic (gcp): a subscription then folds into the queue it feeds."""
    return shape.has(FIELD_QUEUE, String(ROLE_TOPIC))


def lower_queue(r: Resource, feeds: List[Feed], shape: ProviderShape) raises -> List[LoweredNode]:
    """A queue's roles on `shape` (see the file header)."""
    _no_uses(r, String("queue"))
    ref q = r.queue.value()
    var fed = feeds_into(feeds, r.id)
    var dl = dead_letter_of(r)
    var pull = pull_shape(shape)
    var fields = List[Setting]()
    fields.append(Setting(String("ack_deadline"), String(ack_deadline_seconds(r)) + String("s")))
    fields.append(Setting(String("dead_letter"), dl.copy() if dl.byte_length() > 0 else String(NONE)))
    var most = String(NONE)
    if q.max_deliveries:
        most = String(Int(q.max_deliveries.value()))
    fields.append(Setting(String("max_deliveries"), most^))
    var deps = List[String]()
    if dl.byte_length() > 0:
        # The dead-letter queue by its resource id (kci resolves its primary
        # node), or, on a pull shape, its private topic.
        deps.append(dl + String("/") + String(ROLE_TOPIC) if pull else dl.copy())
    var out = List[LoweredNode]()
    var queue_id = r.id + String("/") + String(ROLE_QUEUE)
    if pull:
        var private = r.id + String("/") + String(ROLE_TOPIC)
        out.append(
            LoweredNode(
                private.copy(),
                r.id,
                shape.kind_of(FIELD_QUEUE, String(ROLE_TOPIC)),
                List[String](),
                List[InputRef](),
                List[Setting](),
                len(fed) == 0,
            )
        )
        if len(fed) > 0:
            fields.append(Setting(String("topic"), fed[0].topic.copy()))
            deps.append(fed[0].topic.copy())
        else:
            fields.append(Setting(String("topic"), String(PRIVATE_TOPIC)))
            deps.append(private^)
    fields.append(Setting(String("addressed"), String("queue")))
    out.append(
        LoweredNode(
            queue_id.copy(),
            r.id,
            shape.kind_of(FIELD_QUEUE, String(ROLE_QUEUE)),
            deps^,
            List[InputRef](),
            fields^,
        )
    )
    if shape.has(FIELD_QUEUE, String(ROLE_POLICY)):
        var topics = String("")
        var pdeps = List[String]()
        pdeps.append(queue_id^)
        for i in range(len(fed)):
            if i > 0:
                topics += String(",")
            topics += fed[i].topic
            pdeps.append(fed[i].topic.copy())
        var pf = List[Setting]()
        pf.append(Setting(String("topics"), topics if len(fed) > 0 else String(NONE)))
        out.append(
            LoweredNode(
                r.id + String("/") + String(ROLE_POLICY),
                r.id,
                shape.kind_of(FIELD_QUEUE, String(ROLE_POLICY)),
                pdeps^,
                List[InputRef](),
                pf^,
                len(fed) > 0,
            )
        )
    return out^


def lower_topic(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A topic's one role."""
    _no_uses(r, String("topic"))
    var fields = List[Setting]()
    fields.append(Setting(String("addressed"), String("topic")))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_TOPIC),
            r.id,
            shape.kind_of(FIELD_TOPIC, String(ROLE_TOPIC)),
            List[String](),
            List[InputRef](),
            fields^,
        )
    )
    return out^


def lower_subscription(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A subscription's one role: an object of its own, or turned off on a
    pull shape (it is the topic its queue's subscription is on)."""
    _no_uses(r, String("subscription"))
    ref s = r.subscription.value()
    var topic = s.topic.value().resource.copy()
    var queue = s.queue.value().resource.copy()
    var fields = List[Setting]()
    fields.append(Setting(String("topic"), topic.copy()))
    fields.append(Setting(String("queue"), queue.copy()))
    var deps = List[String]()
    deps.append(topic^)
    deps.append(queue.copy())
    if shape.has(FIELD_QUEUE, String(ROLE_POLICY)):
        deps.append(queue + String("/") + String(ROLE_POLICY))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_SUB),
            r.id,
            shape.kind_of(FIELD_SUBSCRIPTION, String(ROLE_SUB)),
            deps^,
            List[InputRef](),
            fields^,
            not pull_shape(shape),
        )
    )
    return out^


def _limit(r: Resource, path: String, cloud: String, why: String) -> Finding:
    return Finding(
        FINDING_LIMIT,
        r.id,
        path,
        String("on cloud \"") + cloud + String("\" ") + why,
        String(FAKE_MESSAGING_CITATION),
    )


def messaging_limits(
    r: Resource, feeds: List[Feed], shape: ProviderShape, cloud: String, mut out: List[Finding]
):
    """The limits of a pull shape (see the file header); none elsewhere."""
    if not pull_shape(shape):
        return
    if body_is(r, FIELD_SUBSCRIPTION):
        for i in range(len(feeds)):
            if feeds[i].subscription != r.id:
                continue
            var into = feeds_into(feeds, feeds[i].queue)
            if into[0].subscription != r.id:
                out.append(
                    _limit(
                        r,
                        String("subscription.queue"),
                        cloud,
                        String("a queue is one pull subscription on one topic, and queue \"")
                        + into[0].queue
                        + String("\" is already fed from topic \"")
                        + into[0].topic
                        + String("\" by \"")
                        + into[0].subscription
                        + String("\""),
                    )
                )
    var dl = dead_letter_of(r)
    if dl.byte_length() > 0 and len(feeds_into(feeds, dl)) > 0:
        out.append(
            _limit(
                r,
                String("queue.dead_letter"),
                cloud,
                String("a queue dead-letters to the private topic of its dead-letter queue, and \"")
                + dl
                + String("\" has none: it is fed from topic \"")
                + feeds_into(feeds, dl)[0].topic
                + String("\""),
            )
        )
    var edges: List[GrantEdge]
    try:
        edges = edges_of(r)
    except:
        return  # a graph finding
    for i in range(len(edges)):
        ref e = edges[i]
        if e.on_cell() or e.access != ACCESS_SEND:
            continue
        var into = feeds_into(feeds, e.target)
        if len(into) == 0:
            continue
        var path = String("grant") if e.role == "grant" else String("uses[") + String(i) + String("]")
        out.append(
            _limit(
                r,
                path,
                cloud,
                String("queue \"")
                + e.target
                + String("\" is a pull subscription on topic \"")
                + into[0].topic
                + String("\" (subscription \"")
                + into[0].subscription
                + String("\"), so nothing sends to it directly; send to \"")
                + into[0].topic
                + String("\""),
            )
        )
