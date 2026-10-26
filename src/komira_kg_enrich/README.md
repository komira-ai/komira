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
  drain one partition at once. It carries a fencing epoch that only rises.
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
- `DrainLease[Store]`, `LeaseGrant`.
- `EnrichmentDrainWorker`, `DrainOutcome`, `drain_dedup_key`, `drain_payload`.
- `check_identifier`, the rule an id must meet: non-empty, no control byte, no
  `/`, no `"` and no `\`.

## Behaviour worth knowing

- **At-least-once.** A delivery followed by a crash before the ack is delivered
  again, so a sender treats a repeated item id as a repeat.
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
  releases nothing.
- **Prefixes.** Give the queue and the lease prefixes of their own, and do not
  nest one inside another.

## Examples

An item is delivered once. A second pass finds nothing pending and attempts
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
