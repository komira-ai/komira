# `komira_kg_enrich`

## Responsibility

A durable enrichment queue and the worker that drains it, from
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md).
A producer enqueues an item and returns at once. A drain worker delivers the
item later, off the producer's path, through an `EnrichmentSender` that the host
supplies, acks what was delivered and arms a retry for what was refused.

- `EnrichmentItem`: an item id, a partition id, an opaque source key, an opaque
  body and an enqueue time. The queue and the worker never read the body; the
  host decides what a source key and a body mean.
- `EnrichmentQueue` (trait): partition-scoped, at-least-once, oldest first.
  `CasEnrichmentQueue` keeps one object per pending item on any
  `komira_objectstore` conditional-write store; `FakeEnrichmentQueue` is the
  in-memory conformer.
- `DrainLease`: one lease per partition on an object store, so two workers do not
  drain one partition at once. It carries a fencing epoch that only rises, and a
  holder can `renew` its grant.
- `LeaseClock` (trait): the time source of a fenced pass; `FixedLeaseClock` and
  `FakeLeaseClock` (a counter a test advances).
- `RetryScheduler` (trait): a delayed, one-shot, idempotent call back to the
  worker. The host plugs in its task queue or timer; `FakeRetryScheduler` runs on
  a clock a test advances.
- `EnrichmentSender` (trait): deliver one item, True to ack it, False to retry
  it. A sender that talks to a particular network or identity service is the
  host's; `FakeEnrichmentSender` records and fails on request.
- `EnrichmentDrainWorker`: one pass over a partition, deliver then ack or arm a
  retry, items of one source key in order.

The package reads no clock and no environment. Time is an argument (the lease)
or a delay (the retry); nothing in it names a vendor, a network or a vocabulary.
No pointer crosses its API.

## API

Everything is exported from `komira_kg_enrich`:

- `EnrichmentItem` (`new`, `with_queue_key`, `validate`, `order_key`).
- `EnrichmentQueue`, `CasEnrichmentQueue[Store]`, `FakeEnrichmentQueue`.
- `EnrichmentSender`, `FakeEnrichmentSender`.
- `RetryScheduler`, `FakeRetryScheduler`, `DueRetry`.
- `DrainLease[Store]` (`try_acquire`, `renew`, `release`, `take_over_malformed`),
  `LeaseGrant`.
- `LeaseClock`, `FixedLeaseClock`, `FakeLeaseClock`.
- `EnrichmentDrainWorker` (`drain_partition`, `drain_partition_with_lease`,
  `drain_partition_fenced`), `DrainOutcome`, `drain_dedup_key`, `drain_payload`.
- `check_identifier`, the rule an id must meet: non-empty, no control byte, no
  `/`, no `"` and no `\`.

## Behaviour worth knowing

- **At-least-once.** A delivery followed by a crash before the ack, or by an
  ack that fails, is delivered again, so a sender treats a repeated item id as a
  repeat. One worker at a time delivers a partition's items only while its lease
  holds: see Lease.
- **Which failures are retried.** A sender that returns False arms a retry, and
  so does an item held back behind it, and a pass that lost its lease. A sender
  that raises, and a queue whose `list_pending` or `ack` raises, end the pass with
  the error and arm no retry: the caller sees the error and calls the pass again.
  The lease is released on those exits.
- **Order.** A partition's items drain oldest first, ties by item id. After a
  refusal, later items of the same source key in that pass are not attempted;
  items of other source keys carry on.
- **Retry schedule.** One fixed delay, `retry_backoff_seconds`, given to the
  worker. A pass that leaves anything pending arms one retry at now plus the
  delay, with a per-partition dedup key, so a burst of refusals arms one. When the
  retry fires and is refused again, the next is armed a delay after that pass.
- **Lease.** `try_acquire` creates the lease, takes it over once it has expired
  (`now >= expiry`) or renews it for the same holder token, adding one to the
  epoch each time. `release` leaves an expired record with the same epoch, and
  only if the lease is still the grant's version. A worker that lost its lease
  releases nothing. The expiry is `now + ttl`; a sum that does not fit in an
  Int64 is refused with an error (not saturated), as is a non-positive ttl.
- **Fencing.** `drain_partition_fenced` renews the lease (`renew`: same epoch,
  later expiry; refused once the grant has expired or is no longer the stored
  version) at the `LeaseClock` time before each delivery. When the renewal is
  refused the pass stops before that delivery, acks nothing more, arms the retry
  and reports `lease_lost`; the next holder delivers the rest. The guarantee is
  therefore: an item is delivered at least once, and by one worker at a time only
  while that worker's lease holds. A single delivery that itself outlasts the
  lease can still overlap the next holder's first delivery, and the sender is not
  given the epoch. `drain_partition_with_lease` is the same pass on a clock fixed
  at the `now_micros` it is given.
- **A damaged lease record.** A stored record that does not decode is reported
  by `try_acquire` ("malformed lease object") and never taken over silently.
  `take_over_malformed` replaces such a record, and only such a record (epoch
  one more than a numeric epoch line, else 1, so fencing order across a damaged
  record is not guaranteed).
- **Listing under concurrency.** `CasEnrichmentQueue.list_pending` skips an
  object that another worker acked between the listing and the read.
- **Object keys.** The queue key of an item is
  `<prefix>/<partition>/<enqueue time>-<item id>` (no file suffix) and the prefix
  is required.
- **Prefixes.** Give the queue and the lease prefixes of their own, and do not
  nest one inside another.

## Examples

A delivered item is acked. A second pass finds nothing pending and attempts
nothing:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg_enrich import (
    EnrichmentDrainWorker,
    EnrichmentItem,
    FakeEnrichmentQueue,
    FakeEnrichmentSender,
    FakeRetryScheduler,
)

var queue = FakeEnrichmentQueue()
var sender = FakeEnrichmentSender()
var scheduler = FakeRetryScheduler()
var worker = EnrichmentDrainWorker(30, "/drain")

queue.enqueue(EnrichmentItem.new("item-1", "part-a", "source-1", "payload", 10))
var first = worker.drain_partition(queue, sender, scheduler, "part-a")
assert_equal(first.acked, 1)
assert_equal(sender.delivered_count(), 1)
assert_equal(len(queue.list_pending("part-a")), 0)

var second = worker.drain_partition(queue, sender, scheduler, "part-a")
assert_equal(second.acked, 0)
assert_equal(sender.attempt_count(), 1)
```

A refused item stays pending and arms one retry, `retry_backoff_seconds` from
now. The test moves the clock instead of waiting:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo
from komira_kg_enrich import (
    EnrichmentDrainWorker,
    EnrichmentItem,
    FakeEnrichmentQueue,
    FakeEnrichmentSender,
    FakeRetryScheduler,
)

var queue = FakeEnrichmentQueue()
var sender = FakeEnrichmentSender()
var scheduler = FakeRetryScheduler()
var worker = EnrichmentDrainWorker(30, "/drain")

queue.enqueue(EnrichmentItem.new("item-1", "part-a", "source-1", "payload", 10))
sender.fail_all = True
var out = worker.drain_partition(queue, sender, scheduler, "part-a")
assert_equal(out.failed, 1)
assert_true(out.retry_armed)
assert_equal(scheduler.last_due_at(), 30)
assert_equal(scheduler.last_payload(), '{"partition_id":"part-a"}')

scheduler.advance(29)
assert_equal(len(scheduler.take_due()), 0)
scheduler.advance(1)
assert_equal(len(scheduler.take_due()), 1)

sender.clear_failures()
var retried = worker.drain_partition(queue, sender, scheduler, "part-a")
assert_equal(retried.acked, 1)
```

A second worker cannot drain a partition while the lease is held. Its pass
delivers nothing and arms the retry; once the holder's lease has expired the
pass drains. The lease lives on an object store, here an in-memory one:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_objectstore import DelimiterFaithfulConditionalStore
from komira_kg_enrich import (
    DrainLease,
    EnrichmentDrainWorker,
    EnrichmentItem,
    FakeEnrichmentQueue,
    FakeEnrichmentSender,
    FakeRetryScheduler,
)

comptime Store = DelimiterFaithfulConditionalStore
var store = Store()
var holder = DrainLease[Store](store.clone(), "locks")
var mine = DrainLease[Store](store.clone(), "locks")

var queue = FakeEnrichmentQueue()
var sender = FakeEnrichmentSender()
var scheduler = FakeRetryScheduler()
var worker = EnrichmentDrainWorker(30, "/drain")
queue.enqueue(EnrichmentItem.new("item-1", "part-a", "source-1", "payload", 10))

# Another worker holds the lease for 1000 microseconds from time 0.
var held = holder.try_acquire("part-a", "worker-1", 0, 1000)
assert_true(Bool(held))
assert_equal(held.value().epoch, 1)

var blocked = worker.drain_partition_with_lease(
    queue, sender, scheduler, mine, "part-a", "worker-2", 999, 1000
)
assert_true(blocked.lease_held_elsewhere)
assert_equal(sender.attempt_count(), 0)

var later = worker.drain_partition_with_lease(
    queue, sender, scheduler, mine, "part-a", "worker-2", 1000, 1000
)
assert_equal(later.acked, 1)
```

The queue can live on an object store instead of in memory. One object holds one
item, under `<prefix>/<partition>/<enqueue time>-<item id>`, and the body comes
back byte for byte:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_objectstore import DelimiterFaithfulConditionalStore
from komira_kg_enrich import CasEnrichmentQueue, EnrichmentItem

comptime Store = DelimiterFaithfulConditionalStore
var queue = CasEnrichmentQueue[Store](Store(), "enrich/queue")
queue.enqueue(EnrichmentItem.new("b", "part-a", "src", "two\nlines", 20))
queue.enqueue(EnrichmentItem.new("a", "part-a", "src", "first", 10))

var pending = queue.list_pending("part-a")
assert_equal(pending[0].item_id, "a")
assert_equal(pending[1].body, "two\nlines")
assert_equal(pending[0].queue_key, "enrich/queue/part-a/00000000000000000010-a")
```
