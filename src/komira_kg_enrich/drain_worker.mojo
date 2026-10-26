# =============================================================================
# komira_kg_enrich/drain_worker.mojo -- the drain pass over one partition.
# =============================================================================
#
# One pass over a partition's pending items, oldest first:
#
#   deliver the item to the `EnrichmentSender`;
#   accepted -> ack it (it leaves the queue);
#   refused  -> leave it pending, and remember its source key, so a later item
#               of the same source key is held back in this pass (an earlier item
#               must land before a later one that may supersede it). Items of
#               other source keys carry on.
#
# If any item was refused or held back, the pass arms one retry through the
# `RetryScheduler`, at `retry_backoff_seconds` from now, aimed at
# `callback_path` with the partition id as its payload. The dedup key is
# per-partition, so a burst of refusals arms one retry, and an armed retry that
# has not fired is not armed twice. There is no loop and no timer: a pass runs
# when something calls it (a producer, a fired retry) and ends when the queue is
# walked.
#
# `drain_partition_with_lease` is the same pass behind a `DrainLease`: a worker
# that cannot take the lease delivers nothing, arms the retry (so the partition is
# looked at again if the holder dies) and reports `lease_held_elsewhere`. The
# lease is released when the pass ends, also when it raises.
#
# The retry schedule is one fixed delay, given to the constructor; the time of
# the lease is an argument. Neither reads a clock.
# =============================================================================

from komira_objectstore.store import CloneableConditionalWriteStore

from .drain_lease import DrainLease
from .enrichment_item import EnrichmentItem
from .enrichment_queue import EnrichmentQueue
from .enrichment_sender import EnrichmentSender
from .framing import check_identifier
from .retry_scheduler import RetryScheduler


@fieldwise_init
struct DrainOutcome(Copyable, Movable):
    """How one pass went. `acked`: delivered and removed. `failed`: refused by
    the sender and left pending. `skipped`: left pending, not tried, because an
    earlier item of the same source key was refused in this pass.
    `retry_armed`: a retry was armed. `lease_held_elsewhere`: the lease was
    another worker's and nothing was delivered."""

    var acked: Int
    var failed: Int
    var skipped: Int
    var retry_armed: Bool
    var lease_held_elsewhere: Bool


def drain_dedup_key(partition_id: String) -> String:
    """The dedup key of a partition's armed retry: `enrich-drain-<partition>`."""
    return String("enrich-drain-") + partition_id


def drain_payload(partition_id: String) raises -> String:
    """The payload of an armed retry, `{"partition_id":"<partition>"}`. It only
    names the partition; the fired handler reads the pending set from the queue.
    The id must pass `check_identifier`, so it needs no JSON escaping."""
    check_identifier("partition_id", partition_id)
    return String('{"partition_id":"') + partition_id + String('"}')


struct EnrichmentDrainWorker(Copyable, Movable):
    """The drain pass. Holds the retry delay and the path the retry calls; the
    queue, the sender and the scheduler are passed to each call, so the caller
    owns them."""

    var retry_backoff_seconds: Int64
    var callback_path: String

    def __init__(
        out self, retry_backoff_seconds: Int64, var callback_path: String
    ) raises:
        """`retry_backoff_seconds` (positive) is the delay of an armed retry;
        `callback_path` (non-empty) is the path on this worker the retry calls."""
        if retry_backoff_seconds <= Int64(0):
            raise Error("retry_backoff_seconds must be positive")
        if len(callback_path.as_bytes()) == 0:
            raise Error("callback_path must not be empty")
        self.retry_backoff_seconds = retry_backoff_seconds
        self.callback_path = callback_path^

    def _arm_retry[
        S: RetryScheduler
    ](self, mut sched: S, partition_id: String) raises:
        _ = sched.schedule(
            self.retry_backoff_seconds,
            self.callback_path.copy(),
            drain_payload(partition_id),
            drain_dedup_key(partition_id),
        )

    def drain_partition[
        Q: EnrichmentQueue, Sender: EnrichmentSender, S: RetryScheduler
    ](
        self,
        mut queue: Q,
        mut sender: Sender,
        mut sched: S,
        partition_id: String,
    ) raises -> DrainOutcome:
        """One pass over `partition_id`, as the header describes. A sender that
        raises ends the pass at that item: earlier acks stand, no retry is armed
        and the error propagates."""
        var pending = queue.list_pending(partition_id)
        var acked = 0
        var failed = 0
        var skipped = 0
        var failed_sources = List[String]()

        for i in range(len(pending)):
            ref item = pending[i]
            if _source_in(failed_sources, item.source_key):
                skipped += 1
                continue
            if sender.deliver(item):
                queue.ack(item.queue_key)
                acked += 1
            else:
                failed += 1
                failed_sources.append(item.source_key.copy())

        var retry_armed = False
        if failed > 0 or skipped > 0:
            self._arm_retry(sched, partition_id)
            retry_armed = True
        return DrainOutcome(acked, failed, skipped, retry_armed, False)

    def drain_partition_with_lease[
        Q: EnrichmentQueue,
        Sender: EnrichmentSender,
        S: RetryScheduler,
        L: CloneableConditionalWriteStore,
    ](
        self,
        mut queue: Q,
        mut sender: Sender,
        mut sched: S,
        mut lease: DrainLease[L],
        partition_id: String,
        holder_token: String,
        now_micros: Int64,
        lease_ttl_micros: Int64,
    ) raises -> DrainOutcome:
        """`drain_partition` behind the partition's lease. When another worker
        holds it, nothing is delivered and a retry is armed."""
        var grant = lease.try_acquire(
            partition_id, holder_token, now_micros, lease_ttl_micros
        )
        if not grant:
            self._arm_retry(sched, partition_id)
            return DrainOutcome(0, 0, 0, True, True)
        var held = grant.take()
        var outcome: DrainOutcome
        try:
            outcome = self.drain_partition(queue, sender, sched, partition_id)
        except e:
            try:
                lease.release(held)
            except:
                pass
            raise e^
        lease.release(held)
        return outcome^


def _source_in(sources: List[String], source: String) -> Bool:
    for i in range(len(sources)):
        if sources[i] == source:
            return True
    return False
