# =============================================================================
# test_enrichment_queue.mojo -- the EnrichmentQueue contract, on both conformers.
# =============================================================================
#
#   contract     the same checks run on FakeEnrichmentQueue and on
#                CasEnrichmentQueue over an object store: items drain oldest
#                first whatever order they were enqueued in, ties by item id; a
#                partition never sees another's items; enqueueing an item twice
#                stores it once; ack removes the item, and a second ack or an
#                unknown key is not an error; a clone is a handle on the same
#                queue; the body, the source key and the enqueue time come back
#                exactly (a body with newlines, non-ASCII text and nothing at
#                all).
#   refusal      an item with an empty or unsafe id, a source key with a newline
#                or a negative time is refused by both conformers, and nothing is
#                stored.
#   cas layout   the queue key is <prefix>/<partition>/<20-digit time>-<item id>;
#                an ack of a key outside the queue's prefix is refused and the
#                object it names is kept; an object that is not a queue item,
#                or is not UTF-8, makes the listing an error naming it; an empty
#                prefix is refused; two prefixes on one store are two queues.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_objectstore import (
    DelimiterFaithfulConditionalStore,
    Path,
)

from komira_kg_enrich import (
    CasEnrichmentQueue,
    EnrichmentItem,
    EnrichmentQueue,
    FakeEnrichmentQueue,
)


def _item(
    id: String, partition: String, source: String, body: String, at: Int64
) -> EnrichmentItem:
    return EnrichmentItem.new(id.copy(), partition.copy(), source.copy(), body.copy(), at)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _contract[Q: EnrichmentQueue](mut q: Q) raises:
    # Enqueue out of order across two partitions.
    q.enqueue(_item("c", "p1", "s", "third", Int64(30)))
    q.enqueue(_item("a", "p1", "s", "first", Int64(10)))
    q.enqueue(_item("b", "p1", "t", "second", Int64(20)))
    q.enqueue(_item("z", "p2", "s", "other partition", Int64(5)))

    var p1 = q.list_pending("p1")
    assert_equal(len(p1), 3)
    assert_equal(p1[0].item_id, "a")
    assert_equal(p1[1].item_id, "b")
    assert_equal(p1[2].item_id, "c")
    assert_equal(p1[1].source_key, "t")
    assert_equal(p1[1].body, "second")
    assert_equal(p1[1].enqueued_at_micros, Int64(20))
    assert_equal(p1[1].partition_id, "p1")
    assert_true(len(p1[1].queue_key.as_bytes()) > 0)
    var p2 = q.list_pending("p2")
    assert_equal(len(p2), 1)
    assert_equal(p2[0].item_id, "z")
    assert_equal(len(q.list_pending("p3")), 0)

    # The same item again is stored once.
    q.enqueue(_item("a", "p1", "s", "first", Int64(10)))
    assert_equal(len(q.list_pending("p1")), 3)

    # Ties on the enqueue time are ordered by item id.
    q.enqueue(_item("m2", "tie", "s", "", Int64(7)))
    q.enqueue(_item("m1", "tie", "s", "", Int64(7)))
    var tie = q.list_pending("tie")
    assert_equal(tie[0].item_id, "m1")
    assert_equal(tie[1].item_id, "m2")

    # Ack removes exactly that item; a second ack and an unknown key are fine.
    q.ack(p1[0].queue_key)
    var after = q.list_pending("p1")
    assert_equal(len(after), 2)
    assert_equal(after[0].item_id, "b")
    q.ack(p1[0].queue_key)
    assert_equal(len(q.list_pending("p1")), 2)
    assert_equal(len(q.list_pending("p2")), 1)

    # A clone is a handle on the same queue, in both directions.
    var other = q.clone()
    other.enqueue(_item("d", "p1", "s", "via clone", Int64(40)))
    assert_equal(len(q.list_pending("p1")), 3)
    q.ack(after[0].queue_key)
    assert_equal(len(other.list_pending("p1")), 2)


def _fidelity[Q: EnrichmentQueue](mut q: Q) raises:
    var body = String("line one\nline two\n\n{\"k\": \"café 世界\"}\n")
    q.enqueue(_item("i1", "f", "src key with spaces:/and slashes", body, Int64(1)))
    q.enqueue(_item("i2", "f", "", "", Int64(2)))
    var got = q.list_pending("f")
    assert_equal(len(got), 2)
    assert_equal(got[0].body, body)
    assert_equal(got[0].source_key, "src key with spaces:/and slashes")
    assert_equal(got[1].body, "")
    assert_equal(got[1].source_key, "")


def _refusals[Q: EnrichmentQueue](mut q: Q) raises:
    with assert_raises(contains="item_id must not be empty"):
        q.enqueue(_item("", "p", "s", "b", Int64(1)))
    with assert_raises(contains="partition_id must not be empty"):
        q.enqueue(_item("i", "", "s", "b", Int64(1)))
    with assert_raises(contains="partition_id must not hold"):
        q.enqueue(_item("i", "a/b", "s", "b", Int64(1)))
    with assert_raises(contains="item_id must not hold"):
        q.enqueue(_item("i\nj", "p", "s", "b", Int64(1)))
    with assert_raises(contains="item_id must not hold"):
        q.enqueue(_item("i\"j", "p", "s", "b", Int64(1)))
    with assert_raises(contains="source_key must not hold a newline"):
        q.enqueue(_item("i", "p", "s\nt", "b", Int64(1)))
    with assert_raises(contains="must not be negative"):
        q.enqueue(_item("i", "p", "s", "b", Int64(-1)))
    assert_equal(len(q.list_pending("p")), 0)


def test_fake_queue_contract() raises:
    var q = FakeEnrichmentQueue()
    _contract(q)


def test_fake_queue_fidelity() raises:
    var q = FakeEnrichmentQueue()
    _fidelity(q)


def test_fake_queue_refusals() raises:
    var q = FakeEnrichmentQueue()
    _refusals(q)
    assert_equal(q.total_pending(), 0)


def test_cas_queue_contract() raises:
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        DelimiterFaithfulConditionalStore(), "queue"
    )
    _contract(q)


def test_cas_queue_fidelity() raises:
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        DelimiterFaithfulConditionalStore(), "queue"
    )
    _fidelity(q)


def test_cas_queue_refusals_store_nothing() raises:
    var store = DelimiterFaithfulConditionalStore()
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        store.clone(), "queue"
    )
    _refusals(q)
    assert_equal(len(store.list_with_delimiter(Path.parse("queue/")).objects), 0)


def test_cas_queue_key_layout() raises:
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        DelimiterFaithfulConditionalStore(), "queue"
    )
    q.enqueue(_item("abc", "part", "s", "b", Int64(42)))
    var got = q.list_pending("part")
    assert_equal(got[0].queue_key, "queue/part/00000000000000000042-abc")


def test_cas_queue_orders_numerically_not_by_digit_count() raises:
    # 9 sorts after 10 as text; the padded key keeps the numeric order.
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        DelimiterFaithfulConditionalStore(), "queue"
    )
    q.enqueue(_item("ten", "p", "s", "", Int64(10)))
    q.enqueue(_item("nine", "p", "s", "", Int64(9)))
    q.enqueue(_item("big", "p", "s", "", Int64(9223372036854775807)))
    var got = q.list_pending("p")
    assert_equal(got[0].item_id, "nine")
    assert_equal(got[1].item_id, "ten")
    assert_equal(got[2].item_id, "big")
    assert_equal(got[2].enqueued_at_micros, Int64(9223372036854775807))


def test_cas_queue_ack_outside_prefix_is_refused() raises:
    var store = DelimiterFaithfulConditionalStore()
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        store.clone(), "queue"
    )
    _ = store.put(Path.parse("locks/p.lease"), _bytes("held"))
    with assert_raises(contains="not under this queue's prefix"):
        q.ack("locks/p.lease")
    with assert_raises(contains="not under this queue's prefix"):
        q.ack("queuefoo/p/1")
    with assert_raises(contains="not under this queue's prefix"):
        q.ack("queue/")
    assert_equal(len(store.get(Path.parse("locks/p.lease"))), 4)


def test_cas_queue_malformed_object_is_an_error_naming_it() raises:
    var store = DelimiterFaithfulConditionalStore()
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        store.clone(), "queue"
    )
    _ = store.put(Path.parse("queue/p/00000000000000000001-x"), _bytes("only\ntwo lines"))
    with assert_raises(contains="queue/p/00000000000000000001-x"):
        _ = q.list_pending("p")


def test_cas_queue_non_utf8_object_is_an_error() raises:
    var store = DelimiterFaithfulConditionalStore()
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        store.clone(), "queue"
    )
    var raw = _bytes("x\np\ns\n1\n")
    raw.append(UInt8(0xFF))
    _ = store.put(Path.parse("queue/p/00000000000000000001-x"), raw)
    with assert_raises():
        _ = q.list_pending("p")


def test_cas_queue_bad_time_header_is_an_error() raises:
    var store = DelimiterFaithfulConditionalStore()
    var q = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
        store.clone(), "queue"
    )
    _ = store.put(Path.parse("queue/p/00000000000000000001-x"), _bytes("x\np\ns\nsoon\nbody"))
    with assert_raises(contains="not a decimal number"):
        _ = q.list_pending("p")


def test_cas_queue_empty_prefix_is_refused() raises:
    with assert_raises(contains="queue prefix must not be empty"):
        _ = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](
            DelimiterFaithfulConditionalStore(), ""
        )


def test_cas_queue_two_prefixes_are_two_queues() raises:
    var store = DelimiterFaithfulConditionalStore()
    var a = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](store.clone(), "qa")
    var b = CasEnrichmentQueue[DelimiterFaithfulConditionalStore](store.clone(), "qb")
    a.enqueue(_item("i", "p", "s", "in a", Int64(1)))
    assert_equal(len(a.list_pending("p")), 1)
    assert_equal(len(b.list_pending("p")), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
