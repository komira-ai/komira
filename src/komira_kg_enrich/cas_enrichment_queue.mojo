# =============================================================================
# komira_kg_enrich/cas_enrichment_queue.mojo -- the object-store EnrichmentQueue.
# =============================================================================
#
# One object per pending item; ack deletes it. The queue lives on any
# `CloneableConditionalWriteStore` (an in-memory store in tests, a bucket
# behind the same trait in production), under a prefix the host chooses.
#
# Key layout:
#   <prefix>/<partition id>/<enqueue time, 20 digits>-<item id>
#   * the partition id is a path segment, so `list_pending(p)` lists under
#     `<prefix>/<p>/` and a partition never sees another's items; ids may not hold
#     '/', which is what keeps one partition's prefix out of another's;
#   * the zero-padded enqueue time makes key order the enqueue order.
#
# Object layout: four header lines (item id, partition id, source key, enqueue
# time) then the body, verbatim, as the rest of the object. The body is the
# remainder, so it may hold newlines and is never re-encoded.
#
# `enqueue` is one unconditional put; the key is a function of the item, so
# enqueueing an item again rewrites the same object. `ack` is a delete, which is
# idempotent. A queue key that is not under this queue's prefix is refused, so an
# ack can never delete some other object of the bucket (the lease, for one:
# give the queue and the lease different prefixes).
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from .enrichment_item import EnrichmentItem
from .enrichment_queue import EnrichmentQueue
from .framing import (
    check_identifier,
    check_prefix,
    parse_nonneg_i64,
    sort_strings,
    to_bytes,
)


struct CasEnrichmentQueue[S: CloneableConditionalWriteStore](
    EnrichmentQueue, Movable
):
    """An `EnrichmentQueue` over a `CloneableConditionalWriteStore`, one object
    per pending item under `prefix`. `clone()` clones the store handle, so a
    producer and a worker on the same bucket see one queue."""

    var _store: Self.S
    var _prefix: String

    def __init__(out self, var store: Self.S, var prefix: String) raises:
        """`prefix` is the key prefix of the queue's objects; see `check_prefix` for what it may hold."""
        check_prefix("queue prefix", prefix)
        self._store = store^
        self._prefix = prefix^

    def __init__(out self, *, var cloned_store: Self.S, var cloned_prefix: String):
        # The prefix was checked when the queue it is cloned from was built.
        self._store = cloned_store^
        self._prefix = cloned_prefix^

    def clone(self) -> Self:
        return Self(
            cloned_store=self._store.clone(),
            cloned_prefix=self._prefix.copy(),
        )

    def _partition_prefix(self, partition_id: String) -> String:
        return self._prefix + String("/") + partition_id + String("/")

    def enqueue(mut self, item: EnrichmentItem) raises:
        item.validate()
        var key = self._partition_prefix(item.partition_id) + item.order_key()
        _ = self._store.put(Path.parse(key^), to_bytes(_frame(item)))

    def list_pending(self, partition_id: String) raises -> List[EnrichmentItem]:
        check_identifier("partition_id", partition_id)
        var prefix = self._partition_prefix(partition_id)
        var listing = self._store.list_with_delimiter(Path.parse(prefix.copy()))
        var keys = List[String]()
        for i in range(len(listing.objects)):
            keys.append(listing.objects[i].location.copy())
        sort_strings(keys)
        var out = List[EnrichmentItem]()
        for i in range(len(keys)):
            var bytes = self._store.get(Path.parse(keys[i].copy()))
            var raw = String(StringSlice(from_utf8=Span(bytes)))
            out.append(_unframe(raw, keys[i].copy()))
        return out^

    def ack(mut self, queue_key: String) raises:
        var under = self._prefix + String("/")
        var kb = queue_key.as_bytes()
        var ub = under.as_bytes()
        var ok = len(kb) > len(ub)
        if ok:
            for i in range(len(ub)):
                if kb[i] != ub[i]:
                    ok = False
                    break
        if not ok:
            raise Error("queue key is not under this queue's prefix: " + queue_key)
        self._store.delete(Path.parse(queue_key.copy()))


def _frame(item: EnrichmentItem) -> String:
    """`<item id>\\n<partition id>\\n<source key>\\n<enqueue time>\\n<body>`."""
    var out = item.item_id.copy()
    out += String("\n")
    out += item.partition_id
    out += String("\n")
    out += item.source_key
    out += String("\n")
    out += String(item.enqueued_at_micros)
    out += String("\n")
    out += item.body
    return out^


def _unframe(raw: String, var queue_key: String) raises -> EnrichmentItem:
    """The four header lines and the body (everything after the fourth
    newline). An object with fewer than four newlines is an error naming its
    key, never an item with empty fields."""
    var bs = raw.as_bytes()
    var n = len(bs)
    var fields = List[String]()
    var start = 0
    var i = 0
    while i < n and len(fields) < 4:
        if bs[i] == UInt8(0x0A):
            fields.append(String(raw[byte=start:i]))
            start = i + 1
        i += 1
    if len(fields) < 4:
        raise Error("malformed queue object (fewer than four header lines): " + queue_key)
    var body = String("")
    if start < n:
        body = String(raw[byte=start:n])
    var enq = parse_nonneg_i64("enqueue time of " + queue_key, fields[3])
    return EnrichmentItem(
        fields[0].copy(),
        fields[1].copy(),
        fields[2].copy(),
        body^,
        enq,
        queue_key^,
    )
