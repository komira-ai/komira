# =============================================================================
# test_cloud_messaging_rules.mojo
# =============================================================================
#
# The messaging rules (messaging.mojo) and the feeds (feed.mojo), through
# `graph_findings`, the cloud-independent half of validate. No cloud is
# needed: the fakes in kci_cloud_fake run these graphs on every shape.
#
# 1. EVERY MESSAGING REFUSAL, IN ONE PASS, each pinned by resource, field
#    path and reason: an ack deadline below 10 s, above 300 s, and with a
#    fraction of a second; max deliveries below 5, above 100, and an
#    explicit 0; a dead-letter queue with no max deliveries and max
#    deliveries with no dead-letter queue; a dead-letter queue that is the
#    queue itself, a missing resource, a topic, or an output of a queue; a
#    dead-letter cycle of two queues (reported on both); `uses` on a queue,
#    a topic and a subscription; a subscription with no topic, with no queue,
#    whose topic is a queue, whose queue is a topic, whose topic is an output,
#    whose queue is missing, and a second subscription of one (topic, queue)
#    pair; retention on a subscription; RECEIVE asked of a topic and READ of
#    a queue; a NAME read from a subscription. Nothing else is reported.
# 2. A GOOD MESSAGING GRAPH IS CLEAN: the bounds themselves (10 s, 300 s, 5,
#    100), a dead-letter chain of three queues, a topic fanned out to two
#    queues, KEEP on a queue, and a service that SENDs to the topic and to a
#    queue, RECEIVEs from both fed queues, and reads a queue's ADDRESS and a
#    topic's NAME.
# 3. A CYCLE OF THREE is reported on each of its queues, naming the path,
#    and a queue that only LEADS into a cycle is not reported.
# 4. FEEDS: `feeds_of` lists every subscription whose topic and queue are a
#    topic and a queue of the list, in order, and skips the ones validate
#    refuses (no topic, a topic that is a queue, a topic with no type, a
#    missing queue); `messaging_findings` asked of a service finds nothing;
#    `feeds_into` selects one queue's. `ack_deadline_seconds` is the written
#    deadline or the versioned default 30; `dead_letter_of` is the named
#    queue or empty.
# Each test names the defect it catches in its docstring.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    ACK_DEADLINE_DEFAULT_SECONDS,
    FIELD_SERVICE,
    Catalog,
    Feed,
    Finding,
    ack_deadline_seconds,
    dead_letter_of,
    feeds_into,
    feeds_of,
    graph_findings,
    messaging_findings,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _lines(findings: List[Finding]) -> List[String]:
    var out = List[String]()
    for i in range(len(findings)):
        out.append(findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason)
    return out^


def _expect(lines: List[String], prefix: String, reason: String) raises:
    """Exactly one finding starts with `prefix` (`id|path|`) and holds
    `reason`."""
    var n = 0
    var all = String("")
    for i in range(len(lines)):
        all += lines[i] + String("\n")
        if lines[i].startswith(prefix) and lines[i].find(reason) >= 0:
            n += 1
    assert_equal(n, 1, String("one finding ") + prefix + String(" ... ") + reason + String(" in:\n") + all)


comptime IMG = '"image":{"digest":"sha256:0011"}'


# ---- 1. every refusal, in one pass ------------------------------------------------


def test_every_messaging_refusal_in_one_pass() raises:
    """Catches: any one rule dropped (its line is missing), a rule that fires
    on the wrong resource or path, and a rule that fires on a good resource
    (the total)."""
    var g = _list(
        String('{"resource":[')
        + String('{"id":"dlq","queue":{}},')
        + String('{"id":"ev","topic":{}},')
        + String('{"id":"q-low","queue":{"ackDeadline":"9s"}},')
        + String('{"id":"q-high","queue":{"ackDeadline":"301s"}},')
        + String('{"id":"q-frac","queue":{"ackDeadline":"30.500s"}},')
        + String('{"id":"q-four","queue":{"maxDeliveries":4,"deadLetter":{"resource":"dlq"}}},')
        + String('{"id":"q-many","queue":{"maxDeliveries":101,"deadLetter":{"resource":"dlq"}}},')
        + String('{"id":"q-zero","queue":{"maxDeliveries":0,"deadLetter":{"resource":"dlq"}}},')
        + String('{"id":"q-dl-only","queue":{"deadLetter":{"resource":"dlq"}}},')
        + String('{"id":"q-max-only","queue":{"maxDeliveries":5}},')
        + String('{"id":"q-self","queue":{"maxDeliveries":5,"deadLetter":{"resource":"q-self"}}},')
        + String('{"id":"q-gone","queue":{"maxDeliveries":5,"deadLetter":{"resource":"nope"}}},')
        + String('{"id":"q-to-topic","queue":{"maxDeliveries":5,"deadLetter":{"resource":"ev"}}},')
        + String('{"id":"q-to-out","queue":{"maxDeliveries":5,"deadLetter":{"resource":"dlq","standard":"NAME"}}},')
        + String('{"id":"q-a","queue":{"maxDeliveries":5,"deadLetter":{"resource":"q-b"}}},')
        + String('{"id":"q-b","queue":{"maxDeliveries":5,"deadLetter":{"resource":"q-a"}}},')
        + String('{"id":"q-uses","queue":{},"uses":[{"target":{"resource":"ev"},"access":"SEND"}]},')
        + String('{"id":"t-uses","topic":{},"uses":[{"target":{"resource":"dlq"},"access":"SEND"}]},')
        + String('{"id":"s-uses","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"q-low"}},')
        + String('"uses":[{"target":{"resource":"dlq"},"access":"SEND"}]},')
        + String('{"id":"s-no-topic","subscription":{"queue":{"resource":"dlq"}}},')
        + String('{"id":"s-no-queue","subscription":{"topic":{"resource":"ev"}}},')
        + String('{"id":"s-swapped","subscription":{"topic":{"resource":"dlq"},"queue":{"resource":"ev"}}},')
        + String('{"id":"s-out","subscription":{"topic":{"resource":"ev","standard":"ADDRESS"},')
        + String('"queue":{"resource":"q-high"}}},')
        + String('{"id":"s-gone","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"nope"}}},')
        + String('{"id":"s-first","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"dlq"}}},')
        + String('{"id":"s-again","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"dlq"}}},')
        + String('{"id":"s-kept","retention":"KEEP","subscription":{"topic":{"resource":"ev"},')
        + String('"queue":{"resource":"q-frac"}}},')
        + String('{"id":"api","service":{') + String(IMG) + String(',"internal":{},')
        + String('"env":{"FAN":{"ref":{"resource":"s-first","standard":"NAME"}}}},')
        + String('"uses":[{"target":{"resource":"ev"},"access":"RECEIVE"},')
        + String('{"target":{"resource":"dlq"},"access":"READ"}]}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    var deadline = String("whole seconds from 10 to 300")
    _expect(l, "q-low|queue.ack_deadline|", deadline)
    _expect(l, "q-high|queue.ack_deadline|", deadline)
    _expect(l, "q-frac|queue.ack_deadline|", deadline)
    var deliveries = String("from 5 to 100 (the range every built-in cloud honours), not ")
    _expect(l, "q-four|queue.max_deliveries|", deliveries + String("4"))
    _expect(l, "q-many|queue.max_deliveries|", deliveries + String("101"))
    _expect(l, "q-zero|queue.max_deliveries|", deliveries + String("0"))
    var together = String("dead_letter and max_deliveries go together")
    _expect(l, "q-dl-only|queue.max_deliveries|", together)
    _expect(l, "q-max-only|queue.dead_letter|", together)
    _expect(l, "q-self|queue.dead_letter|", "refers to its own resource")
    _expect(l, "q-gone|queue.dead_letter|", 'ref to missing resource "nope"')
    _expect(l, "q-to-topic|queue.dead_letter|", 'must name a queue; "ev" is not one')
    _expect(l, "q-to-out|queue.dead_letter|", "names a queue, not one of its outputs")
    _expect(l, "q-a|queue.dead_letter|", "a dead-letter cycle (q-a -> q-b -> q-a)")
    _expect(l, "q-b|queue.dead_letter|", "a dead-letter cycle (q-b -> q-a -> q-b)")
    _expect(l, "q-uses|uses|", "a queue runs as no identity")
    _expect(l, "t-uses|uses|", "a topic runs as no identity")
    _expect(l, "s-uses|uses|", "a subscription runs as no identity")
    _expect(l, "s-no-topic|subscription.topic|", "no topic")
    _expect(l, "s-no-queue|subscription.queue|", "no queue")
    _expect(l, "s-swapped|subscription.topic|", 'must name a topic; "dlq" is not one')
    _expect(l, "s-swapped|subscription.queue|", 'must name a queue; "ev" is not one')
    _expect(l, "s-out|subscription.topic|", "names a topic, not one of its outputs")
    _expect(l, "s-gone|subscription.queue|", 'ref to missing resource "nope"')
    _expect(l, "s-again|subscription|", '"s-first" already delivers topic "ev" to queue "dlq"')
    _expect(l, "s-kept|retention|", "a subscription takes no retention")
    _expect(l, "api|uses[0]|", 'topic "ev" does not accept access RECEIVE')
    _expect(l, "api|uses[1]|", 'queue "dlq" does not accept access READ')
    _expect(l, "api|service.env.FAN|", '"s-first" (subscription) does not expose NAME')
    assert_equal(len(l), 28, "no other finding")
    print("  test_every_messaging_refusal_in_one_pass: PASS")


# ---- 2. a good graph is clean -----------------------------------------------------


comptime _GOOD = (
    '{"resource":['
    '{"id":"ev","retention":"KEEP","topic":{}},'
    '{"id":"last","queue":{"ackDeadline":"300s"}},'
    '{"id":"mid","queue":{"ackDeadline":"10s","maxDeliveries":100,"deadLetter":{"resource":"last"}}},'
    '{"id":"work","retention":"KEEP","queue":{"maxDeliveries":5,"deadLetter":{"resource":"mid"}}},'
    '{"id":"audit","queue":{}},'
    '{"id":"ev-work","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"work"}}},'
    '{"id":"ev-audit","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"audit"}}},'
    '{"id":"api","service":{"image":{"digest":"sha256:0011"},"internal":{},'
    '"env":{"Q":{"ref":{"resource":"work","standard":"ADDRESS"}},'
    '"T":{"ref":{"resource":"ev","standard":"NAME"}}}},'
    '"uses":[{"target":{"resource":"ev"},"access":"SEND"},'
    '{"target":{"resource":"last"},"access":"SEND"},'
    '{"target":{"resource":"work"},"access":"RECEIVE"},'
    '{"target":{"resource":"audit"},"access":"RECEIVE"}]}'
    "]}"
)


def test_a_good_messaging_graph_is_clean() raises:
    """Catches: a bound off by one (10 s, 300 s, 5 and 100 are legal), a
    dead-letter CHAIN taken for a cycle, a topic fanned out to two queues
    taken for a duplicate, KEEP refused on a queue, SEND or RECEIVE refused
    where the catalog accepts them, and NAME / ADDRESS refused on a queue or
    a topic."""
    var l = _lines(graph_findings(Catalog.v1(), _list(String(_GOOD))))
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 0, String("a good messaging graph is clean:\n") + all)
    print("  test_a_good_messaging_graph_is_clean: PASS")


# ---- 3. a cycle of three ----------------------------------------------------------


def test_a_cycle_of_three_is_reported_on_each_queue() raises:
    """Catches: a walk that only looks one step ahead (it would miss a cycle
    of three), and one that reports a queue leading INTO a cycle it is not
    part of (`lead` here)."""
    var g = _list(
        String('{"resource":[')
        + String('{"id":"a","queue":{"maxDeliveries":5,"deadLetter":{"resource":"b"}}},')
        + String('{"id":"b","queue":{"maxDeliveries":5,"deadLetter":{"resource":"c"}}},')
        + String('{"id":"c","queue":{"maxDeliveries":5,"deadLetter":{"resource":"a"}}},')
        + String('{"id":"lead","queue":{"maxDeliveries":5,"deadLetter":{"resource":"a"}}}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    _expect(l, "a|queue.dead_letter|", "a dead-letter cycle (a -> b -> c -> a)")
    _expect(l, "b|queue.dead_letter|", "a dead-letter cycle (b -> c -> a -> b)")
    _expect(l, "c|queue.dead_letter|", "a dead-letter cycle (c -> a -> b -> c)")
    assert_equal(len(l), 3, "lead is not in the cycle")
    print("  test_a_cycle_of_three_is_reported_on_each_queue: PASS")


# ---- 4. feeds and the queue helpers ------------------------------------------------


def _feed_text(feeds: List[Feed]) -> String:
    var s = String("")
    for i in range(len(feeds)):
        s += feeds[i].subscription + String(":") + feeds[i].topic + String(">") + feeds[i].queue + String(";")
    return s^


def test_feeds_and_the_queue_helpers() raises:
    """Catches: a feed listed for a subscription validate refuses (the
    adapter would lower an edge to nothing), feeds out of list order, a
    `feeds_into` that ignores the queue, the default deadline changed, and a
    `dead_letter_of` that reads the wrong field."""
    var good = _list(String(_GOOD))
    var feeds = feeds_of(good)
    assert_equal(_feed_text(feeds), "ev-work:ev>work;ev-audit:ev>audit;")
    assert_equal(_feed_text(feeds_into(feeds, String("audit"))), "ev-audit:ev>audit;")
    assert_equal(len(feeds_into(feeds, String("mid"))), 0, "an unfed queue has no feed")
    var bad = _list(
        String('{"resource":[{"id":"ev","topic":{}},{"id":"q","queue":{}},')
        + String('{"id":"no-topic","subscription":{"queue":{"resource":"q"}}},')
        + String('{"id":"no-queue","subscription":{"topic":{"resource":"ev"}}},')
        + String('{"id":"topic-is-queue","subscription":{"topic":{"resource":"q"},"queue":{"resource":"q"}}},')
        + String('{"id":"queue-is-topic","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"ev"}}},')
        + String('{"id":"gone","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"nope"}}},')
        + String('{"id":"blank"},')
        + String('{"id":"untyped","subscription":{"topic":{"resource":"blank"},"queue":{"resource":"q"}}},')
        + String('{"id":"ok","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"q"}}}]}')
    )
    assert_equal(_feed_text(feeds_of(bad)), "ok:ev>q;", "only the well-formed subscription is a feed")
    assert_equal(ACK_DEADLINE_DEFAULT_SECONDS, 30)
    assert_equal(ack_deadline_seconds(good[1]), 300, "written")
    assert_equal(ack_deadline_seconds(good[4]), 30, "unset: the versioned default")
    assert_equal(dead_letter_of(good[3]), "mid")
    assert_equal(dead_letter_of(good[1]), "", "no dead-letter queue")
    assert_equal(dead_letter_of(good[0]), "", "a topic has none")
    # Asked of another type, the messaging rules find nothing.
    assert_equal(len(messaging_findings(good, FIELD_SERVICE, good[7])), 0, "a service is not messaging")
    print("  test_feeds_and_the_queue_helpers: PASS")


def main() raises:
    print("test_cloud_messaging_rules")
    test_every_messaging_refusal_in_one_pass()
    test_a_good_messaging_graph_is_clean()
    test_a_cycle_of_three_is_reported_on_each_queue()
    test_feeds_and_the_queue_helpers()
    print("ALL kci_cloud MESSAGING RULES TESTS PASSED")
