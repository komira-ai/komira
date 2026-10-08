# =============================================================================
# kci_cloud/feed.mojo: the FEEDS kci hands every cloud adapter.
# =============================================================================
#
# A FEED is one subscription as kci reads it: (subscription, topic, queue),
# each a resource id. `feeds_of` lists every subscription of a list whose
# topic and queue name a topic and a queue of it, in list order (any other
# subscription is a graph finding, messaging.mojo). kci hands the feeds to
# `CloudAdapter.check` and `CloudAdapter.lower` with every resource, as it
# hands a resource its grant edges, because what a queue lowers to can depend
# on the subscriptions that deliver to it: on a cloud where a subscription is
# not an object of its own but the queue's own subscription to the topic,
# the queue is lowered from its feed, and a shape that cloud cannot host (a
# queue fed by two topics, a direct send to a fed queue) is refused as a
# limit before anything is created. An adapter still lowers one resource
# without reading the others.
# =============================================================================

from kci_resource_proto.resource import Resource

from kci_cloud.catalog import FIELD_QUEUE, FIELD_TOPIC, body_field


@fieldwise_init
struct Feed(Copyable, Movable, Deinitable):
    """One subscription, as kci reads it: every message sent to the topic
    `topic` is delivered to the queue `queue` (each a resource id)."""

    var subscription: String
    var topic: String
    var queue: String


def _field(r: Resource) -> Int:
    try:
        return body_field(r)
    except:
        return -1


def field_of_id(resources: List[Resource], id: String) -> Int:
    """The body field of resource `id` of `resources`; -1 when there is
    none."""
    for i in range(len(resources)):
        if resources[i].id == id:
            return _field(resources[i])
    return -1


def feeds_of(resources: List[Resource]) -> List[Feed]:
    """Every subscription of `resources` whose topic and queue name a topic
    and a queue of it, in list order (the others are graph findings)."""
    var out = List[Feed]()
    for i in range(len(resources)):
        ref r = resources[i]
        if not r.subscription:
            continue
        ref s = r.subscription.value()
        if not s.topic or not s.queue:
            continue
        var topic = s.topic.value().resource.copy()
        var queue = s.queue.value().resource.copy()
        if field_of_id(resources, topic) != FIELD_TOPIC or field_of_id(resources, queue) != FIELD_QUEUE:
            continue
        out.append(Feed(r.id.copy(), topic^, queue^))
    return out^


def feeds_into(feeds: List[Feed], queue: String) -> List[Feed]:
    """The feeds whose queue is `queue`, in order."""
    var out = List[Feed]()
    for i in range(len(feeds)):
        if feeds[i].queue == queue:
            out.append(feeds[i].copy())
    return out^


