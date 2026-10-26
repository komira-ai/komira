# =============================================================================
# test_drain_worker.mojo -- the drain pass and its retry schedule.
# =============================================================================
#
# The queue is a Fake or a CasEnrichmentQueue, the sender a FakeEnrichmentSender
# or a sender that raises, the scheduler a FakeRetryScheduler whose clock the
# test advances, the lease time an argument. Nothing waits.
#
#   delivery     an item is delivered once and acked: a second pass delivers
#                nothing and attempts nothing (on the Fake queue and on the
#                object-store queue); items are delivered oldest first whatever
#                order they were enqueued in; a pass over one partition leaves
#                another's items; an empty partition arms no retry.
#   retry        a refused item stays pending and arms one retry at the stated
#                backoff, aimed at the configured path with the partition in its
#                payload; the retry is not due one second before the backoff and
#                is due at it; the pass the retry triggers delivers the item; a
#                pass that is refused again arms the next retry a backoff after
#                that pass; a burst of refusals arms one retry; the backoff is
#                what the constructor was given.
#   ordering     after a refusal, later items of the same source key in the pass
#                are not attempted and stay pending, items of other source keys
#                are delivered, and the next pass delivers the held items in
#                order.
#   sender fault a sender that raises ends the pass: earlier acks stand, the
#                item stays pending, no retry is armed and the error reaches the
#                caller.
#   lease        a worker that cannot take the lease delivers nothing, arms the
#                retry and reports lease_held_elsewhere; it drains once the
#                holder's lease has expired (time moved by argument); a pass
#                releases the lease when it ends, also when the sender raises;
#                two workers sharing one queue and one lease deliver an item
#                once.
#   arguments    a zero or negative backoff, an empty callback path and an unsafe
#                partition id are errors; the dedup key and the payload have the
#                stated shape.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_objectstore import DelimiterFaithfulConditionalStore

from komira_kg_enrich import (
    CasEnrichmentQueue,
    DrainLease,
    EnrichmentDrainWorker,
    EnrichmentItem,
    EnrichmentQueue,
    EnrichmentSender,
    FakeEnrichmentQueue,
    FakeEnrichmentSender,
    FakeRetryScheduler,
    drain_dedup_key,
    drain_payload,
)


comptime Store = DelimiterFaithfulConditionalStore
comptime BACKOFF = Int64(30)
comptime TTL = Int64(1000)


def _item(id: String, source: String, at: Int64) -> EnrichmentItem:
    return EnrichmentItem.new(id.copy(), "p", source.copy(), "body of " + id, at)


def _worker() raises -> EnrichmentDrainWorker:
    return EnrichmentDrainWorker(BACKOFF, "/internal/drain")


struct _RaisingSender(EnrichmentSender):
    """Delivers every item except the one named, for which it raises."""

    var bad_item_id: String
    var delivered: List[String]

    def __init__(out self, bad_item_id: String):
        self.bad_item_id = bad_item_id.copy()
        self.delivered = List[String]()

    def deliver(mut self, item: EnrichmentItem) raises -> Bool:
        if item.item_id == self.bad_item_id:
            raise Error("sender fault on " + item.item_id)
        self.delivered.append(item.item_id.copy())
        return True


# ---- delivery ----


def _delivered_once[Q: EnrichmentQueue](mut q: Q) raises:
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var w = _worker()
    q.enqueue(_item("a", "s", Int64(1)))

    var first = w.drain_partition(q, sender, sched, "p")
    assert_equal(first.acked, 1)
    assert_equal(first.failed, 0)
    assert_equal(first.skipped, 0)
    assert_false(first.retry_armed)
    assert_false(first.lease_held_elsewhere)
    assert_equal(sender.delivered_count(), 1)
    assert_equal(sender.delivered_bodies[0], "body of a")
    assert_equal(len(q.list_pending("p")), 0)

    var second = w.drain_partition(q, sender, sched, "p")
    assert_equal(second.acked, 0)
    assert_equal(sender.attempt_count(), 1)
    assert_equal(sender.delivered_count(), 1)
    assert_equal(sched.schedule_count(), 0)


def test_item_is_delivered_once_fake_queue() raises:
    var q = FakeEnrichmentQueue()
    _delivered_once(q)


def test_item_is_delivered_once_object_store_queue() raises:
    var q = CasEnrichmentQueue[Store](Store(), "queue")
    _delivered_once(q)


def test_items_are_delivered_oldest_first() raises:
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    q.enqueue(_item("c", "s3", Int64(30)))
    q.enqueue(_item("a", "s1", Int64(10)))
    q.enqueue(_item("b", "s2", Int64(20)))
    var out = _worker().drain_partition(q, sender, sched, "p")
    assert_equal(out.acked, 3)
    assert_equal(sender.delivered_item_ids[0], "a")
    assert_equal(sender.delivered_item_ids[1], "b")
    assert_equal(sender.delivered_item_ids[2], "c")


def test_a_pass_leaves_other_partitions_alone() raises:
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    q.enqueue(_item("a", "s", Int64(1)))
    q.enqueue(EnrichmentItem.new("z", "other", "s", "b", Int64(1)))
    _ = _worker().drain_partition(q, sender, sched, "p")
    assert_equal(sender.delivered_count(), 1)
    assert_equal(len(q.list_pending("other")), 1)


def test_an_empty_partition_arms_no_retry() raises:
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var out = _worker().drain_partition(q, sender, sched, "p")
    assert_equal(out.acked + out.failed + out.skipped, 0)
    assert_false(out.retry_armed)
    assert_equal(sched.schedule_count(), 0)
    assert_equal(sender.attempt_count(), 0)


# ---- retry ----


def test_a_refused_item_is_retried_on_the_stated_schedule() raises:
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler(Int64(1000))
    var w = _worker()
    q.enqueue(_item("a", "s", Int64(1)))
    sender.fail_all = True

    var first = w.drain_partition(q, sender, sched, "p")
    assert_equal(first.failed, 1)
    assert_equal(first.acked, 0)
    assert_true(first.retry_armed)
    assert_equal(len(q.list_pending("p")), 1)
    assert_equal(sched.schedule_count(), 1)
    assert_equal(sched.last_delay(), BACKOFF)
    assert_equal(sched.last_due_at(), Int64(1030))
    assert_equal(sched.last_callback_path(), "/internal/drain")
    assert_equal(sched.last_payload(), "{\"partition_id\":\"p\"}")

    # One second early nothing is due; at the backoff the retry is due.
    sched.advance(BACKOFF - Int64(1))
    assert_equal(len(sched.take_due()), 0)
    sched.advance(Int64(1))
    var due = sched.take_due()
    assert_equal(len(due), 1)
    assert_equal(due[0].dedup_key, "enrich-drain-p")

    # The sender recovers; the pass the retry triggers delivers the item.
    sender.clear_failures()
    var second = w.drain_partition(q, sender, sched, "p")
    assert_equal(second.acked, 1)
    assert_false(second.retry_armed)
    assert_equal(len(q.list_pending("p")), 0)
    assert_equal(sender.delivered_count(), 1)
    assert_equal(sender.attempt_count(), 2)
    assert_equal(sched.pending_count(), 0)


def test_a_retry_that_is_refused_again_arms_the_next_one_a_backoff_later() raises:
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var w = _worker()
    q.enqueue(_item("a", "s", Int64(1)))
    sender.fail_next(2)

    _ = w.drain_partition(q, sender, sched, "p")
    assert_equal(sched.last_due_at(), Int64(30))
    sched.advance(Int64(30))
    assert_equal(len(sched.take_due()), 1)

    var second = w.drain_partition(q, sender, sched, "p")
    assert_equal(second.failed, 1)
    assert_equal(sched.schedule_count(), 2)
    assert_equal(sched.last_due_at(), Int64(60))
    sched.advance(Int64(29))
    assert_equal(len(sched.take_due()), 0)
    sched.advance(Int64(1))
    assert_equal(len(sched.take_due()), 1)

    var third = w.drain_partition(q, sender, sched, "p")
    assert_equal(third.acked, 1)
    assert_equal(sender.attempt_count(), 3)
    assert_equal(sender.delivered_count(), 1)


def test_a_burst_of_refusals_arms_one_retry() raises:
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var w = _worker()
    q.enqueue(_item("a", "s1", Int64(1)))
    q.enqueue(_item("b", "s2", Int64(2)))
    q.enqueue(_item("c", "s3", Int64(3)))
    sender.fail_all = True
    var out = w.drain_partition(q, sender, sched, "p")
    assert_equal(out.failed, 3)
    assert_equal(sched.schedule_count(), 1)
    # A second pass before the retry fires does not arm another.
    sched.advance(Int64(5))
    _ = w.drain_partition(q, sender, sched, "p")
    assert_equal(sched.schedule_count(), 1)
    assert_equal(sched.pending_count(), 1)


def test_the_backoff_is_the_constructors() raises:
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var w = EnrichmentDrainWorker(Int64(7), "/other")
    q.enqueue(_item("a", "s", Int64(1)))
    sender.fail_all = True
    _ = w.drain_partition(q, sender, sched, "p")
    assert_equal(sched.last_delay(), Int64(7))
    assert_equal(sched.last_callback_path(), "/other")


# ---- ordering ----


def test_a_refusal_holds_back_later_items_of_the_same_source() raises:
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var w = _worker()
    q.enqueue(_item("A", "s1", Int64(1)))
    q.enqueue(_item("B", "s2", Int64(2)))
    q.enqueue(_item("C", "s1", Int64(3)))
    sender.fail_source("s1")

    var out = w.drain_partition(q, sender, sched, "p")
    assert_equal(out.acked, 1)
    assert_equal(out.failed, 1)
    assert_equal(out.skipped, 1)
    assert_true(out.retry_armed)
    # C was never attempted; B (another source) was delivered.
    assert_equal(len(sender.attempted_item_ids), 2)
    assert_equal(sender.attempted_item_ids[0], "A")
    assert_equal(sender.attempted_item_ids[1], "B")
    assert_equal(sender.delivered_item_ids[0], "B")
    var pending = q.list_pending("p")
    assert_equal(len(pending), 2)
    assert_equal(pending[0].item_id, "A")
    assert_equal(pending[1].item_id, "C")

    sender.clear_failures()
    var next = w.drain_partition(q, sender, sched, "p")
    assert_equal(next.acked, 2)
    assert_equal(sender.delivered_item_ids[1], "A")
    assert_equal(sender.delivered_item_ids[2], "C")


# ---- sender fault ----


def test_a_raising_sender_ends_the_pass_without_a_retry() raises:
    var q = FakeEnrichmentQueue()
    var sender = _RaisingSender("b")
    var sched = FakeRetryScheduler()
    q.enqueue(_item("a", "s1", Int64(1)))
    q.enqueue(_item("b", "s2", Int64(2)))
    q.enqueue(_item("c", "s3", Int64(3)))
    with assert_raises(contains="sender fault on b"):
        _ = _worker().drain_partition(q, sender, sched, "p")
    assert_equal(len(sender.delivered), 1)
    var pending = q.list_pending("p")
    assert_equal(len(pending), 2)
    assert_equal(pending[0].item_id, "b")
    assert_equal(sched.schedule_count(), 0)


# ---- lease ----


def test_a_worker_without_the_lease_delivers_nothing_and_arms_a_retry() raises:
    var store = Store()
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var w = _worker()
    var held = DrainLease[Store](store.clone(), "locks")
    var mine = DrainLease[Store](store.clone(), "locks")
    q.enqueue(_item("a", "s", Int64(1)))

    # Another worker holds the lease until 1000 (micros).
    assert_true(Bool(held.try_acquire("p", "other-worker", Int64(0), TTL)))
    var out = w.drain_partition_with_lease(
        q, sender, sched, mine, "p", "this-worker", Int64(999), TTL
    )
    assert_true(out.lease_held_elsewhere)
    assert_true(out.retry_armed)
    assert_equal(out.acked, 0)
    assert_equal(sender.attempt_count(), 0)
    assert_equal(len(q.list_pending("p")), 1)
    assert_equal(sched.last_due_at(), BACKOFF)
    assert_equal(sched.last_payload(), "{\"partition_id\":\"p\"}")

    # The retry fires after the holder's lease has expired: the pass drains.
    sched.advance(BACKOFF)
    assert_equal(len(sched.take_due()), 1)
    var later = w.drain_partition_with_lease(
        q, sender, sched, mine, "p", "this-worker", Int64(1000), TTL
    )
    assert_false(later.lease_held_elsewhere)
    assert_equal(later.acked, 1)
    assert_equal(sender.delivered_count(), 1)


def test_a_pass_releases_the_lease_when_it_ends() raises:
    var store = Store()
    var q = FakeEnrichmentQueue()
    var sender = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var mine = DrainLease[Store](store.clone(), "locks")
    var theirs = DrainLease[Store](store.clone(), "locks")
    q.enqueue(_item("a", "s", Int64(1)))
    _ = _worker().drain_partition_with_lease(
        q, sender, sched, mine, "p", "this-worker", Int64(10), TTL
    )
    # Long before the ttl, another worker takes it at once, with a higher epoch.
    var grant = theirs.try_acquire("p", "other-worker", Int64(11), TTL)
    assert_true(Bool(grant))
    assert_equal(grant.value().epoch, Int64(2))


def test_a_raising_sender_still_releases_the_lease() raises:
    var store = Store()
    var q = FakeEnrichmentQueue()
    var sender = _RaisingSender("a")
    var sched = FakeRetryScheduler()
    var mine = DrainLease[Store](store.clone(), "locks")
    var theirs = DrainLease[Store](store.clone(), "locks")
    q.enqueue(_item("a", "s", Int64(1)))
    with assert_raises(contains="sender fault on a"):
        _ = _worker().drain_partition_with_lease(
            q, sender, sched, mine, "p", "this-worker", Int64(10), TTL
        )
    assert_true(Bool(theirs.try_acquire("p", "other-worker", Int64(11), TTL)))


def test_two_workers_on_one_queue_and_lease_deliver_an_item_once() raises:
    var store = Store()
    var q_store = Store()
    var q1 = CasEnrichmentQueue[Store](q_store.clone(), "queue")
    var q2 = q1.clone()
    var l1 = DrainLease[Store](store.clone(), "locks")
    var l2 = DrainLease[Store](store.clone(), "locks")
    var s1 = FakeEnrichmentSender()
    var s2 = FakeEnrichmentSender()
    var sched = FakeRetryScheduler()
    var w = _worker()
    q1.enqueue(_item("a", "s", Int64(1)))

    # Worker one is mid-pass (holds the lease): worker two cannot drain.
    var held = l1.try_acquire("p", "worker-1", Int64(0), TTL)
    assert_true(Bool(held))
    var blocked = w.drain_partition_with_lease(
        q2, s2, sched, l2, "p", "worker-2", Int64(1), TTL
    )
    assert_true(blocked.lease_held_elsewhere)
    assert_equal(s2.attempt_count(), 0)
    l1.release(held.value())

    # Worker one finishes and releases; worker two then drains, and a further
    # pass by worker one finds nothing left to deliver.
    var out2 = w.drain_partition_with_lease(
        q2, s2, sched, l2, "p", "worker-2", Int64(2), TTL
    )
    assert_equal(out2.acked, 1)
    var out1 = w.drain_partition_with_lease(
        q1, s1, sched, l1, "p", "worker-1", Int64(3), TTL
    )
    assert_equal(out1.acked, 0)
    assert_equal(s1.attempt_count(), 0)
    assert_equal(s2.delivered_count(), 1)


# ---- arguments ----


def test_constructor_refuses_a_bad_backoff_or_path() raises:
    with assert_raises(contains="retry_backoff_seconds must be positive"):
        _ = EnrichmentDrainWorker(Int64(0), "/d")
    with assert_raises(contains="retry_backoff_seconds must be positive"):
        _ = EnrichmentDrainWorker(Int64(-3), "/d")
    with assert_raises(contains="callback_path must not be empty"):
        _ = EnrichmentDrainWorker(Int64(5), "")


def test_dedup_key_and_payload_shape() raises:
    assert_equal(drain_dedup_key("part-1"), "enrich-drain-part-1")
    assert_equal(drain_payload("part-1"), "{\"partition_id\":\"part-1\"}")
    with assert_raises(contains="partition_id must not hold"):
        _ = drain_payload("a\"b")
    with assert_raises(contains="partition_id must not be empty"):
        _ = drain_payload("")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
