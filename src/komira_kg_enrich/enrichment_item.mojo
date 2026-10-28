# =============================================================================
# komira_kg_enrich/enrichment_item.mojo -- one queued enrichment unit.
# =============================================================================
#
# An item is what a producer hands the queue: a partition id (the key the queue
# is scoped by), an opaque source key (items of one source drain in the order
# they were enqueued), an opaque body that the sender delivers byte for byte, and
# the enqueue time that fixes the item's place in its partition's order. The
# queue and the worker never read the body, and neither the source key nor the
# body has a vocabulary: the host decides what they mean.
#
# A flat value type: strings and Int64 only.
# =============================================================================

from .framing import check_identifier, check_one_line, zeropad


# The zero-pad width of the enqueue time in a queue key: 20 digits hold every
# non-negative Int64, so the byte order of keys is the numeric order of times.
comptime QUEUE_TIME_WIDTH: Int = 20


@fieldwise_init
struct EnrichmentItem(Copyable, Movable):
    """One durable queue item.

    Fields:
        item_id:            the item's stable identity; with the enqueue time it
                            names the stored object, so enqueueing the same item
                            twice stores it once.
        partition_id:       the partition the queue is scoped by; a partition
                            never sees another's items.
        source_key:         an opaque key. Within a partition, a later item of
                            one source key is not delivered before an earlier
                            one of the same source key has been.
        body:               the payload, delivered verbatim.
        enqueued_at_micros: when the item was enqueued, in microseconds on the
                            producer's clock; items of a partition drain oldest
                            first, ties broken by item id.
        queue_key:          the handle the store assigned (set by
                            `list_pending`; `ack` addresses the item by it).
                            Empty on an item that has not been stored.
    """

    var item_id: String
    var partition_id: String
    var source_key: String
    var body: String
    var enqueued_at_micros: Int64
    var queue_key: String

    @staticmethod
    def new(
        var item_id: String,
        var partition_id: String,
        var source_key: String,
        var body: String,
        enqueued_at_micros: Int64,
    ) -> EnrichmentItem:
        """A fresh item that has not been stored: `queue_key` is empty."""
        return EnrichmentItem(
            item_id^,
            partition_id^,
            source_key^,
            body^,
            enqueued_at_micros,
            String(""),
        )

    def with_queue_key(self, var key: String) -> EnrichmentItem:
        """A copy of this item stamped with the key the store assigned."""
        return EnrichmentItem(
            self.item_id.copy(),
            self.partition_id.copy(),
            self.source_key.copy(),
            self.body.copy(),
            self.enqueued_at_micros,
            key^,
        )

    def validate(self) raises:
        """Refuse an item a queue cannot store faithfully: an item id or
        partition id that is empty or holds a control byte, '/', a quote or a
        backslash; a source key with a newline; a negative enqueue time."""
        check_identifier("item_id", self.item_id)
        check_identifier("partition_id", self.partition_id)
        check_one_line("source_key", self.source_key)
        if self.enqueued_at_micros < Int64(0):
            raise Error("enqueued_at_micros must not be negative")

    def order_key(self) -> String:
        """The name that orders items within a partition:
        `<enqueue time, 20 digits>-<item id>`."""
        return (
            zeropad(self.enqueued_at_micros, QUEUE_TIME_WIDTH)
            + String("-")
            + self.item_id
        )
