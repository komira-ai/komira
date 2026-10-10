# =============================================================================
# kci_cloud/messaging.mojo: the rules of the MESSAGING primitives (queue,
# topic, subscription), and the queue's versioned default.
# =============================================================================
#
# GRAPH findings, true on every cloud, that validate collects for a
# messaging resource (`messaging_findings`):
#   * a queue, a topic and a subscription run as no identity, so none has
#     `uses` lines (write the line on the workload that sends or receives);
#   * a queue's `ack_deadline`, when written, is whole seconds from 10 to
#     300; its `max_deliveries`, when written, is from 5 to 100. Both ranges
#     are the ones every built-in cloud honours, so a value means the same on
#     every cloud and a file deploys on any of them;
#   * `dead_letter` and `max_deliveries` are written together or not at
#     all: a message moves to the dead-letter queue after `max_deliveries`,
#     and with neither it is delivered until it is acknowledged;
#   * `dead_letter` names another queue of the list, not one of its outputs,
#     and following dead-letter queues from a queue never comes back to it
#     (a cycle of queues that wait on each other can be created in no order);
#   * a subscription names a `topic` and a `queue` of the list (each by the
#     resource, not an output), and a (topic, queue) pair is connected by one
#     subscription only (a second would deliver every message twice).
#
# FEEDS (feed.mojo) are the subscriptions as kci reads them, handed to every
# cloud adapter's `check` and `lower`.
#
# THE VERSIONED DEFAULT. An unwritten `ack_deadline` is 30 seconds
# (`ACK_DEADLINE_DEFAULT_SECONDS`) on every cloud. kci writes it out, so an
# author's file means the same thing whichever cloud's own default differs.
# =============================================================================

from kci_resource_proto.refs import Ref
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import FIELD_QUEUE, FIELD_SUBSCRIPTION, FIELD_TOPIC
from kci_cloud.feed import field_of_id


comptime ACK_DEADLINE_DEFAULT_SECONDS: Int = 30
"""What an unwritten `Queue.ack_deadline` means."""
comptime ACK_DEADLINE_MIN_SECONDS: Int = 10
comptime ACK_DEADLINE_MAX_SECONDS: Int = 300
comptime MAX_DELIVERIES_MIN: Int = 5
comptime MAX_DELIVERIES_MAX: Int = 100


def ack_deadline_seconds(r: Resource) -> Int:
    """Queue `r`'s ack deadline in seconds: the written one, else the
    versioned default."""
    ref q = r.queue.value()
    if q.ack_deadline:
        return Int(q.ack_deadline.value().seconds)
    return ACK_DEADLINE_DEFAULT_SECONDS


def dead_letter_of(r: Resource) -> String:
    """The queue `r`'s `dead_letter` names, or empty."""
    if r.queue and r.queue.value().dead_letter:
        return r.queue.value().dead_letter.value().resource.copy()
    return String("")


def check_typed_ref(
    resources: List[Resource],
    id: String,
    path: String,
    r: Ref,
    want: Int,
    want_name: String,
    mut out: List[Finding],
):
    """`r` names another resource of the list, of type `want`, and no
    output."""
    if r._oneof0_case != 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                path,
                String("names a ") + want_name + String(", not one of its outputs"),
            )
        )
        return
    if r.resource == id:
        out.append(Finding(FINDING_GRAPH, id, path, String("refers to its own resource")))
        return
    var f = field_of_id(resources, r.resource)
    var found = False
    for i in range(len(resources)):
        if resources[i].id == r.resource:
            found = True
            break
    if not found:
        out.append(
            Finding(FINDING_GRAPH, id, path, String("ref to missing resource \"") + r.resource + String("\""))
        )
    elif f != want:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                path,
                String("must name a ") + want_name + String("; \"") + r.resource + String("\" is not one"),
            )
        )


def _queue_findings(resources: List[Resource], r: Resource, mut out: List[Finding]):
    ref q = r.queue.value()
    var id = r.id.copy()
    if q.ack_deadline:
        ref d = q.ack_deadline.value()
        var secs = Int(d.seconds)
        if Int(d.nanos) != 0 or secs < ACK_DEADLINE_MIN_SECONDS or secs > ACK_DEADLINE_MAX_SECONDS:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    String("queue.ack_deadline"),
                    String("whole seconds from ")
                    + String(ACK_DEADLINE_MIN_SECONDS)
                    + String(" to ")
                    + String(ACK_DEADLINE_MAX_SECONDS)
                    + String(" (the range every built-in cloud honours); unset means ")
                    + String(ACK_DEADLINE_DEFAULT_SECONDS),
                )
            )
    if q.max_deliveries:
        var n = Int(q.max_deliveries.value())
        if n < MAX_DELIVERIES_MIN or n > MAX_DELIVERIES_MAX:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    String("queue.max_deliveries"),
                    String("from ")
                    + String(MAX_DELIVERIES_MIN)
                    + String(" to ")
                    + String(MAX_DELIVERIES_MAX)
                    + String(" (the range every built-in cloud honours), not ")
                    + String(n),
                )
            )
    if Bool(q.dead_letter) != Bool(q.max_deliveries):
        var missing = String("max_deliveries") if q.dead_letter else String("dead_letter")
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                String("queue.") + missing,
                String("dead_letter and max_deliveries go together: a message moves to the")
                + String(" dead-letter queue after max_deliveries; with neither it is")
                + String(" delivered until it is acknowledged"),
            )
        )
    if not q.dead_letter:
        return
    check_typed_ref(resources, id, String("queue.dead_letter"), q.dead_letter.value(), FIELD_QUEUE, String("queue"), out)
    # A cycle: follow the dead-letter queues from this one (at most one step
    # per resource), and refuse when the walk comes back to it.
    var path = id.copy()
    var at = dead_letter_of(r)
    for _ in range(len(resources)):
        if at.byte_length() == 0 or at == id:
            break
        path += String(" -> ") + at
        var next = String("")
        for i in range(len(resources)):
            if resources[i].id == at:
                next = dead_letter_of(resources[i])
                break
        if next == id:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    String("queue.dead_letter"),
                    String("a dead-letter cycle (") + path + String(" -> ") + id
                    + String("): each queue would need the other to exist first"),
                )
            )
            break
        at = next^


def _subscription_findings(resources: List[Resource], r: Resource, mut out: List[Finding]):
    ref s = r.subscription.value()
    var id = r.id.copy()
    if not s.topic:
        out.append(Finding(FINDING_GRAPH, id, String("subscription.topic"), String("no topic")))
    else:
        check_typed_ref(resources, id, String("subscription.topic"), s.topic.value(), FIELD_TOPIC, String("topic"), out)
    if not s.queue:
        out.append(Finding(FINDING_GRAPH, id, String("subscription.queue"), String("no queue")))
    else:
        check_typed_ref(resources, id, String("subscription.queue"), s.queue.value(), FIELD_QUEUE, String("queue"), out)
    if not s.topic or not s.queue:
        return
    var topic = s.topic.value().resource.copy()
    var queue = s.queue.value().resource.copy()
    for i in range(len(resources)):
        ref o = resources[i]
        if o.id == id:
            break
        if not o.subscription or not o.subscription.value().topic or not o.subscription.value().queue:
            continue
        ref os = o.subscription.value()
        if os.topic.value().resource == topic and os.queue.value().resource == queue:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    String("subscription"),
                    String("\"")
                    + o.id
                    + String("\" already delivers topic \"")
                    + topic
                    + String("\" to queue \"")
                    + queue
                    + String("\"; a second subscription would deliver every message twice"),
                )
            )
            break


def messaging_findings(resources: List[Resource], field: Int, r: Resource) -> List[Finding]:
    """Every graph finding of the messaging resource `r` (a `queue`, a
    `topic` or a `subscription`, by its body `field`) in `resources`; empty
    for any other type."""
    var out = List[Finding]()
    var name: String
    if field == FIELD_QUEUE:
        name = String("queue")
        _queue_findings(resources, r, out)
    elif field == FIELD_TOPIC:
        name = String("topic")
    elif field == FIELD_SUBSCRIPTION:
        name = String("subscription")
        _subscription_findings(resources, r, out)
    else:
        return out^
    if len(r.uses) > 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("uses"),
                String("a ")
                + name
                + String(
                    " runs as no identity, so it cannot use another resource; write"
                    " the uses line on the workload that sends or receives"
                ),
            )
        )
    return out^
