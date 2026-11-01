# =============================================================================
# komira_kg_enrich -- a durable enrichment queue and the worker that drains it.
# =============================================================================
#
# Producers enqueue items and return; a drain worker delivers them off the
# producers' path through an `EnrichmentSender` the host supplies, and retries
# what was refused on a fixed delay.
#
#   * EnrichmentItem        -- one queued unit: partition id, opaque source key,
#                              opaque body, enqueue time.
#   * EnrichmentQueue       -- the partition-scoped, at-least-once queue trait;
#                              CasEnrichmentQueue over an object store,
#                              FakeEnrichmentQueue in memory.
#   * DrainLease            -- the per-partition lease on an object store, with a
#                              fencing epoch and an injected time.
#   * RetryScheduler        -- the delayed self-call trait; FakeRetryScheduler
#                              runs on a clock a test advances.
#   * EnrichmentSender      -- the delivery trait; FakeEnrichmentSender in tests.
#   * EnrichmentDrainWorker -- deliver, ack or arm a retry; per-source in order.
#
# Depends on komira_objectstore. No clock and no environment is read.
# =============================================================================

from .enrichment_item import EnrichmentItem
from .enrichment_queue import EnrichmentQueue, FakeEnrichmentQueue
from .cas_enrichment_queue import CasEnrichmentQueue
from .enrichment_sender import EnrichmentSender, FakeEnrichmentSender
from .retry_scheduler import DueRetry, FakeRetryScheduler, RetryScheduler
from .drain_lease import DrainLease, LeaseGrant
from .lease_clock import FakeLeaseClock, FixedLeaseClock, LeaseClock
from .drain_worker import (
    DrainOutcome,
    EnrichmentDrainWorker,
    drain_dedup_key,
    drain_payload,
)
from .framing import check_identifier
