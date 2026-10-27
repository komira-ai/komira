# =============================================================================
# komira_kg_enrich/enrichment_sender.mojo -- the EnrichmentSender trait and an
#   in-memory conformer.
# =============================================================================
#
# The seam through which the drain worker hands one item to wherever enrichment
# goes. A sender that speaks to a particular network, endpoint or identity
# service belongs to the host; the worker codes only against this trait.
#
# `deliver` returns True when the item was accepted (the worker then acks it) and
# False when it was not (the item stays pending and the worker arms a retry).
# It raises only for an error the host cannot recover from by retrying: a raise
# ends the drain pass, acks nothing further and arms no retry.
#
# A delivery whose ack is lost is delivered again, so a sender must treat a
# repeated `item_id` as a repeat.
# =============================================================================

from .enrichment_item import EnrichmentItem


trait EnrichmentSender(Movable, Deinitable):
    """Deliver one enrichment item."""

    def deliver(mut self, item: EnrichmentItem) raises -> Bool:
        """True when the item was accepted; False to have it retried."""
        ...


struct FakeEnrichmentSender(EnrichmentSender):
    """Records what it is given and fails on request.

    Every call counts in `attempts`. A call fails (returns False and records no
    delivery) while `fail_all` is set, while `fail_next_count` is positive (each
    failure uses one), or when the item's source key is in `failing_sources`.
    Otherwise the item is recorded in `delivered_item_ids`, `delivered_sources`
    and `delivered_bodies`, in order."""

    var delivered_item_ids: List[String]
    var delivered_sources: List[String]
    var delivered_bodies: List[String]
    var attempted_item_ids: List[String]
    var failing_sources: List[String]
    var fail_all: Bool
    var fail_next_count: Int

    def __init__(out self):
        self.delivered_item_ids = List[String]()
        self.delivered_sources = List[String]()
        self.delivered_bodies = List[String]()
        self.attempted_item_ids = List[String]()
        self.failing_sources = List[String]()
        self.fail_all = False
        self.fail_next_count = 0

    def deliver(mut self, item: EnrichmentItem) raises -> Bool:
        self.attempted_item_ids.append(item.item_id.copy())
        if self.fail_all:
            return False
        if self.fail_next_count > 0:
            self.fail_next_count -= 1
            return False
        for i in range(len(self.failing_sources)):
            if self.failing_sources[i] == item.source_key:
                return False
        self.delivered_item_ids.append(item.item_id.copy())
        self.delivered_sources.append(item.source_key.copy())
        self.delivered_bodies.append(item.body.copy())
        return True

    def fail_next(mut self, count: Int):
        """Fail the next `count` calls."""
        self.fail_next_count = count

    def fail_source(mut self, source_key: String):
        """Fail every call for items of `source_key` until `clear_failures`."""
        self.failing_sources.append(source_key.copy())

    def clear_failures(mut self):
        self.fail_all = False
        self.fail_next_count = 0
        self.failing_sources = List[String]()

    def delivered_count(self) -> Int:
        return len(self.delivered_item_ids)

    def attempt_count(self) -> Int:
        return len(self.attempted_item_ids)
