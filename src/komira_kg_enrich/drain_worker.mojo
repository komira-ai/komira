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
# lease is released when the pass ends, also when it raises (not when it was lost).
#
# Fencing. Before each delivery the pass renews its lease through
# `DrainLease.renew` at the time the `LeaseClock` gives. When the renewal says the
# lease is lost (expired, or taken over) the pass stops before that delivery,
# acks nothing more, arms the retry and reports `lease_lost`; it does not release
# a lease it no longer holds. `drain_partition_with_lease` takes a fixed `now`
# (the lease never expires inside the pass, a takeover is still noticed);
# `drain_partition_fenced` takes a `LeaseClock`.
#
# What is guaranteed. Delivery is at-least-once: a delivery whose ack is lost, or
# a pass that stops in the middle, is delivered again by a later pass. An item is
# delivered by one worker at a time only while that worker's lease holds: the
# check is before each delivery, so a delivery that itself outlasts the lease can
# still overlap the next holder's first delivery. The sender is never given the
# epoch, so the receiver cannot fence it either; a sender treats a repeated item
# id as a repeat.
#
# Which failures are retried. A sender that returns False (a refusal), and an
# item held back behind it, arm the retry. Nothing else does: a sender that
# raises, and a queue fault (`list_pending` or `ack` raising) end the pass with
# the error and arm no retry; the caller sees the error and calls the pass again.
# An item delivered whose ack then fails stays pending and is delivered again by
# that next pass. The lease is released on every one of these exits.
#
# The retry schedule is one fixed delay, given to the constructor; the time of
# the lease comes from the caller. Neither reads a clock.
# =============================================================================

from komira_objectstore.store import CloneableConditionalWriteStore

from .drain_lease import DrainLease, LeaseGrant
from .enrichment_item import EnrichmentItem
from .enrichment_queue import EnrichmentQueue
from .enrichment_sender import EnrichmentSender
from .framing import check_identifier
from .lease_clock import FixedLeaseClock, LeaseClock
from .retry_scheduler import RetryScheduler


@fieldwise_init
struct DrainOutcome(Copyable, Movable):
    """How one pass went. `acked`: delivered and removed. `failed`: refused by
    the sender and left pending. `skipped`: left pending, not tried, because an
    earlier item of the same source key was refused in this pass.
    `retry_armed`: a retry was armed. `lease_held_elsewhere`: the lease was
    another worker's and nothing was delivered. `lease_lost`: the pass held the
    lease but lost it part-way and stopped before the next delivery; what it
    had not reached is counted in none of the other fields."""

    var acked: Int
    var failed: Int
    var skipped: Int
    var retry_armed: Bool
    var lease_held_elsewhere: Bool
    var lease_lost: Bool


def drain_dedup_key(partition_id: String) -> String:
    """The dedup key of a partition's armed retry: `enrich-drain-<partition>`."""
    return String("enrich-drain-") + partition_id


def drain_payload(partition_id: String) raises -> String:
    """The payload of an armed retry, `{"partition_id":"<partition>"}`. It only
    names the partition; the fired handler reads the pending set from the queue.
    The id must pass `check_identifier`, so it needs no JSON escaping."""
    check_identifier("partition_id", partition_id)
    return String('{"partition_id":"') + partition_id + String('"}')


struct _PassState(Movable):
    """The counts of one pass and the source keys that were refused in it."""

    var acked: Int
    var failed: Int
    var skipped: Int
    var failed_sources: List[String]

    def __init__(out self):
        self.acked = 0
        self.failed = 0
        self.skipped = 0
        self.failed_sources = List[String]()

    def would_skip(self, item: EnrichmentItem) -> Bool:
        return _source_in(self.failed_sources, item.source_key)

    def step[
        Q: EnrichmentQueue, Sender: EnrichmentSender
    ](mut self, item: EnrichmentItem, mut queue: Q, mut sender: Sender) raises:
        """Hold the item back, or deliver it and ack or record the refusal."""
        if self.would_skip(item):
            self.skipped += 1
            return
        if sender.deliver(item):
            queue.ack(item.queue_key)
            self.acked += 1
        else:
            self.failed += 1
            self.failed_sources.append(item.source_key.copy())


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
        """One pass over `partition_id`, as the header describes, with no lease.
        A sender that raises ends the pass at that item: earlier acks stand, no
        retry is armed and the error propagates."""
        var pending = queue.list_pending(partition_id)
        var state = _PassState()
        for i in range(len(pending)):
            state.step(pending[i], queue, sender)
        return self._finish(sched, partition_id, state, False)

    def _finish[
        S: RetryScheduler
    ](
        self,
        mut sched: S,
        partition_id: String,
        state: _PassState,
        lease_lost: Bool,
    ) raises -> DrainOutcome:
        var retry_armed = False
        if state.failed > 0 or state.skipped > 0 or lease_lost:
            self._arm_retry(sched, partition_id)
            retry_armed = True
        return DrainOutcome(
            state.acked,
            state.failed,
            state.skipped,
            retry_armed,
            False,
            lease_lost,
        )

    def _drain_fenced[
        Q: EnrichmentQueue,
        Sender: EnrichmentSender,
        S: RetryScheduler,
        L: CloneableConditionalWriteStore,
        C: LeaseClock,
    ](
        self,
        mut queue: Q,
        mut sender: Sender,
        mut sched: S,
        mut lease: DrainLease[L],
        mut clock: C,
        mut held: LeaseGrant,
        lease_ttl_micros: Int64,
    ) raises -> DrainOutcome:
        """The pass with a renewal before each delivery. `held` is replaced by
        each renewed grant, so the caller releases the latest version."""
        var pending = queue.list_pending(held.partition_id)
        var state = _PassState()
        var lost = False
        for i in range(len(pending)):
            if state.would_skip(pending[i]):
                state.step(pending[i], queue, sender)
                continue
            var renewed = lease.renew(held, clock.now_micros(), lease_ttl_micros)
            if not renewed:
                lost = True
                break
            held = renewed.take()
            state.step(pending[i], queue, sender)
        return self._finish(sched, held.partition_id, state, lost)

    def drain_partition_fenced[
        Q: EnrichmentQueue,
        Sender: EnrichmentSender,
        S: RetryScheduler,
        L: CloneableConditionalWriteStore,
        C: LeaseClock,
    ](
        self,
        mut queue: Q,
        mut sender: Sender,
        mut sched: S,
        mut lease: DrainLease[L],
        mut clock: C,
        partition_id: String,
        holder_token: String,
        lease_ttl_micros: Int64,
    ) raises -> DrainOutcome:
        """`drain_partition` behind the partition's lease, which the pass renews
        before each delivery at the time `clock` gives. When another worker holds
        the lease, nothing is delivered and a retry is armed; when the lease is
        lost part-way the pass stops (see the header)."""
        var grant = lease.try_acquire(
            partition_id, holder_token, clock.now_micros(), lease_ttl_micros
        )
        if not grant:
            self._arm_retry(sched, partition_id)
            return DrainOutcome(0, 0, 0, True, True, False)
        var held = grant.take()
        var outcome: DrainOutcome
        try:
            outcome = self._drain_fenced(
                queue, sender, sched, lease, clock, held, lease_ttl_micros
            )
        except e:
            try:
                lease.release(held)
            except:
                pass
            raise e^
        if not outcome.lease_lost:
            lease.release(held)
        return outcome^

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
        """`drain_partition_fenced` on a clock fixed at `now_micros`: the lease
        never expires inside the pass, a takeover by another holder is still
        noticed."""
        var clock = FixedLeaseClock(now_micros)
        return self.drain_partition_fenced(
            queue,
            sender,
            sched,
            lease,
            clock,
            partition_id,
            holder_token,
            lease_ttl_micros,
        )


def _source_in(sources: List[String], source: String) -> Bool:
    for i in range(len(sources)):
        if sources[i] == source:
            return True
    return False
