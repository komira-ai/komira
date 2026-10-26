# =============================================================================
# komira_kg_enrich/enrichment_queue.mojo -- the EnrichmentQueue trait and an
#   in-memory conformer.
# =============================================================================
#
# A durable, partition-scoped, at-least-once queue that takes enrichment off the
# producer's path. A producer enqueues and returns; a drain worker lists a
# partition's pending items, hands each to an `EnrichmentSender` and acks the
# ones that were delivered.
#
#   enqueue(item)       record a pending item. At-least-once: the item survives
#                       the producer's crash after this returns. Enqueueing the
#                       same item (same id and enqueue time) again stores it once.
#   list_pending(p)     the pending items of one partition, oldest first (ties by
#                       item id), each with the `queue_key` that `ack` takes.
#                       Another partition's items are never returned.
#   ack(queue_key)      remove a delivered item. Idempotent: an unknown key is
#                       swallowed, so a double ack is safe.
#   clone()             a handle on the same queue, so a producer and a worker
#                       each hold one.
#
# A delivery that is followed by a crash before `ack` is delivered again on the
# next pass, so a sender must tolerate a repeat of an item id.
# =============================================================================

from std.memory import ArcPointer

from .enrichment_item import EnrichmentItem


trait EnrichmentQueue(Movable, Deinitable):
    """A durable, partition-scoped, at-least-once queue of enrichment items."""

    def enqueue(mut self, item: EnrichmentItem) raises:
        """Record `item` as pending for its partition. Refuses an item that
        `EnrichmentItem.validate` refuses."""
        ...

    def list_pending(self, partition_id: String) raises -> List[EnrichmentItem]:
        """The pending items of `partition_id`, oldest first, each carrying its
        `queue_key`. Empty when none are pending."""
        ...

    def ack(mut self, queue_key: String) raises:
        """Remove the item addressed by `queue_key`. An unknown key is not an
        error."""
        ...

    def clone(self) -> Self:
        """A handle on the same queue."""
        ...


struct _QueueState(Movable):
    """What the handles of one `FakeEnrichmentQueue` share: the stored items."""

    var items: List[EnrichmentItem]

    def __init__(out self):
        self.items = List[EnrichmentItem]()


struct FakeEnrichmentQueue(EnrichmentQueue, Movable):
    """An in-memory `EnrichmentQueue` with the contract of `CasEnrichmentQueue`:
    scoped by partition, ordered by enqueue time then item id, one stored item
    per (enqueue time, item id), ack idempotent. The `queue_key` is
    `<partition id>/<order key>`. `clone()` shares the items."""

    var _state: ArcPointer[_QueueState]

    def __init__(out self):
        self._state = ArcPointer[_QueueState](_QueueState())

    def __init__(out self, var state: ArcPointer[_QueueState]):
        self._state = state^

    def clone(self) -> Self:
        return Self(self._state.copy())

    def enqueue(mut self, item: EnrichmentItem) raises:
        item.validate()
        var key = item.partition_id + String("/") + item.order_key()
        var stored = item.with_queue_key(key.copy())
        ref items = self._state[].items
        for i in range(len(items)):
            if items[i].queue_key == key:
                items[i] = stored^
                return
        items.append(stored^)

    def list_pending(self, partition_id: String) raises -> List[EnrichmentItem]:
        var out = List[EnrichmentItem]()
        ref items = self._state[].items
        for i in range(len(items)):
            if items[i].partition_id != partition_id:
                continue
            var item = items[i].copy()
            out.append(item^)
            # Keep `out` in queue_key order by sinking the new last element.
            var j = len(out) - 1
            while j > 0 and out[j - 1].queue_key > out[j].queue_key:
                var tmp = out[j - 1].copy()
                out[j - 1] = out[j].copy()
                out[j] = tmp^
                j -= 1
        return out^

    def ack(mut self, queue_key: String) raises:
        var keep = List[EnrichmentItem]()
        ref items = self._state[].items
        for i in range(len(items)):
            if items[i].queue_key != queue_key:
                keep.append(items[i].copy())
        self._state[].items = keep^

    def total_pending(self) -> Int:
        """The pending items across every partition."""
        return len(self._state[].items)
