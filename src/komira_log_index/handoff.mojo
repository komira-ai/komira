# =============================================================================
# komira_log_index.handoff: the bounded on-core to off-core handoff.
# =============================================================================
#
# The queue carries owned, transposed work from the on-core transpose (the
# producer, the drain core) to the off-core index consumer (the flush thread).
#
# WHY A SPINLOCK-GUARDED SLAB, NOT A LOCK-FREE BYTE RING. A handoff unit owns a
# `RecordBatch`, a move-only value with heap-owning columns. Storing such a value
# in a byte-backed lock-free ring would defeat destruction of the inner heap
# buffers, and `LogRecordView` is likewise never stored in a byte ring. So the
# queue is a `Slab[HandoffUnit]` guarded by an `Atomic[uint8]` test-and-set
# spinlock. This composes existing primitives (the spinlock and the byte gate)
# rather than adding a new lock-free queue. The bound is enforced by COUNT (the
# queue depth) and by BYTES (the shared `InFlightBytesGate`); the producer is
# pushed back on either.
#
# BOUND BEHAVIOR WHEN FULL. `offer(batch, gate, est)` never blocks and never
# drops silently:
#   * it reserves `est` bytes on the gate; if the gate rejects (memory cap) it
#     returns False and the gate counts a rejection;
#   * else, if the queue is at its depth cap, it releases the reservation it
#     just took, counts a depth rejection and returns False;
#   * else it enqueues under the spinlock and returns True.
# The caller owns the decision on False: the batch handed to `offer` is consumed
# (dropped) on a rejection, so a False return is the loud signal that the
# off-core stage is saturated. `poll`-side, `drain_all` moves the whole queue out
# under the spinlock in FIFO order.
#
# The gate reservation travels with the unit and is released by the CONSUMER
# after the batch is published; the handoff only reserves on offer.
#
# THE LOCK. `_acquire` is a compare-and-swap spin (default, sequentially
# consistent ordering) that yields the CPU every `_SPINS_BEFORE_YIELD` failed
# attempts, so a holder preempted on a shared core does not leave the other side
# spinning at full speed. The queue is allocated at its depth cap up front and
# `drain_all` swaps in a fresh full-capacity queue allocated BEFORE the lock is
# taken, so no allocation happens while the lock is held.
#
# Encapsulation: no UnsafePointer in any signature. NON-MOVABLE (it owns an
# `Atomic`). Its methods take `mut self`; sharing one handoff between a producer
# thread and a consumer thread is the owner's thread-launch design (see
# flush_thread). Wrap it in an `OwnedPointer` to move it.
# =============================================================================

from std.atomic import Atomic

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab

from komira_async.runtime.wake_primitives import cpu_pause
from komira_log import LogRecordView

from komira_log_index.flush_stage import (
    InFlightBytesGate,
    _estimate_batch_bytes,
)
from komira_log_index.transpose import log_views_to_record_batch


comptime _SPINS_BEFORE_YIELD: Int = 64


# -----------------------------------------------------------------------------
# A single handoff unit: the on-core-transposed RecordBatch, the bytes reserved
# for it on the gate (so the consumer knows exactly how much to release after the
# publish lands) and the row count (for the publish summary's doc count).
#
# THE TRANSPOSE IS ON-CORE: the producer does the cheap `log_views_to_record_batch`
# transpose BEFORE the handoff. Only the heavy index build (tokenize, invert,
# serialize) and the publish run off-core in the consumer. So the unit carries a
# typed batch, not raw views.
# -----------------------------------------------------------------------------


struct HandoffUnit(Movable, Deinitable):
    """One on-core to off-core handoff: the on-core-transposed RecordBatch, the
    gate bytes reserved for it and the row count. The consumer index-builds and
    publishes the batch, then releases `reserved_bytes` on the gate.

    The batch is held in an `Optional[RecordBatch]` so `take_batch()` can extract
    it with `Optional.take()` instead of partially moving a field out of the
    struct. After `take()` the Optional is None and the unit drops cleanly (the
    scalar receipts are trivially destructible)."""

    var batch: Optional[RecordBatch]
    var reserved_bytes: Int64
    var row_count: Int64

    def __init__(
        out self, var batch: RecordBatch, reserved_bytes: Int64, row_count: Int64
    ):
        self.batch = Optional[RecordBatch](batch^)
        self.reserved_bytes = reserved_bytes
        self.row_count = row_count

    def take_batch(mut self) -> RecordBatch:
        """Extract the owned RecordBatch via `Optional.take()`, leaving the
        Optional None. The caller reads `reserved_bytes` and `row_count`
        separately (Int64 copies)."""
        return self.batch.take()


# -----------------------------------------------------------------------------
# LogIndexHandoff: the bounded SPSC handoff (spinlock-guarded). One handoff per
# drain-worker sub-lineage: the drain core is the sole producer, the off-core
# flush thread is the sole consumer.
# -----------------------------------------------------------------------------


struct LogIndexHandoff(Deinitable):
    """Bounded, spinlock-guarded SPSC handoff of transposed log batches from the
    on-core transpose to the off-core index consumer.

    Bounded by COUNT (`_depth_cap` queued batches) and by BYTES (the shared
    `InFlightBytesGate`). The producer is pushed back on either. NON-MOVABLE
    (owns the Atomic spinlock)."""

    # HandoffUnit is move-only (it owns a RecordBatch), so the queue is a
    # `Slab[HandoffUnit]`, not a `List` (`List[T]` requires `T: Copyable`).
    var _queue: Slab[HandoffUnit]
    var _depth_cap: Int
    var _lock: Atomic[DType.uint8]
    # Count-backpressure counter (distinct from the gate's byte rejection and
    # from the ring's overflow drop: three distinct pressure signals).
    var _depth_rejections: Atomic[DType.int64]
    # Total offered and polled units.
    var _offered: Atomic[DType.int64]
    var _polled: Atomic[DType.int64]

    def __init__(out self, depth_cap: Int = 256):
        self._queue = Self._fresh_queue(depth_cap)
        self._depth_cap = depth_cap
        self._lock = Atomic[DType.uint8](UInt8(0))
        self._depth_rejections = Atomic[DType.int64](Int64(0))
        self._offered = Atomic[DType.int64](Int64(0))
        self._polled = Atomic[DType.int64](Int64(0))

    @staticmethod
    def _fresh_queue(depth_cap: Int) -> Slab[HandoffUnit]:
        # Capacity for a full queue, so an `append` below the cap never grows.
        if depth_cap > 0:
            return Slab[HandoffUnit](depth_cap)
        return Slab[HandoffUnit]()

    @always_inline
    def _acquire(mut self):
        var spins = 0
        while True:
            var expected = UInt8(0)
            if self._lock.compare_exchange(expected, UInt8(1)):
                return
            spins += 1
            if spins >= _SPINS_BEFORE_YIELD:
                spins = 0
                cpu_pause()

    @always_inline
    def _release(mut self):
        # Only the lock holder calls this, so the lock reads 1; the CAS to 0 is
        # the release.
        var expected = UInt8(1)
        _ = self._lock.compare_exchange(expected, UInt8(0))

    @always_inline
    def depth_rejection_count(self) -> Int64:
        return self._depth_rejections.load()

    @always_inline
    def offered_count(self) -> Int64:
        return self._offered.load()

    @always_inline
    def polled_count(self) -> Int64:
        return self._polled.load()

    def depth(mut self) -> Int:
        """Current queued-batch count, read under the lock."""
        self._acquire()
        var d = len(self._queue)
        self._release()
        return d

    def offer(
        mut self,
        var batch: RecordBatch,
        mut gate: InFlightBytesGate,
        est: Int64,
    ) -> Bool:
        """Producer-side enqueue. Reserves `est` bytes on the gate; on a reject
        (memory cap) returns False. Else, if the queue is at its COUNT cap,
        returns False. Else enqueues the on-core-transposed batch under the
        spinlock and returns True. An empty (0-row) batch is a no-op success
        (nothing to hand off).

        On a successful offer the reservation travels with the unit (the
        consumer releases it after publish). On a count reject AFTER a
        successful reserve, the reservation is released here (the unit was not
        enqueued). On any False the batch is dropped."""
        var rows = Int64(batch.num_rows())
        if rows == 0:
            return True
        # Reserve first (the byte cap). On reject, push back.
        if not gate.try_reserve(est):
            return False
        # Count cap. If full, release the reservation just taken and reject.
        self._acquire()
        if len(self._queue) >= self._depth_cap:
            self._release()
            gate.release(est)
            _ = self._depth_rejections.fetch_add(Int64(1))
            return False
        self._queue.append(HandoffUnit(batch^, est, rows))
        self._release()
        _ = self._offered.fetch_add(Int64(1))
        return True

    def drain_all(mut self) -> Slab[HandoffUnit]:
        """Consumer-side bulk dequeue (FIFO). Moves the ENTIRE queued Slab out
        under the spinlock and returns it (append order is the producer's FIFO
        drain order), leaving the handoff empty. The consumer iterates the
        returned Slab in order, preserving the time-sorted-split invariant (a
        split's [min_ts, max_ts] is [first, last]). A bulk drain (instead of one
        pop at a time) also avoids a Slab LIFO `pop` reversing the order and
        keeps the lock hold short (one move, not N)."""
        # Nothing offered since the last drain: skip the lock and the
        # allocation (an idle flush thread polls here every few milliseconds).
        # A unit enqueued just after this check is taken by the next drain.
        if self._offered.load() == self._polled.load():
            return Slab[HandoffUnit]()
        # Allocate the replacement queue BEFORE taking the lock.
        var fresh = Self._fresh_queue(self._depth_cap)
        self._acquire()
        var out = self._queue^
        self._queue = fresh^
        var n = Int64(len(out))
        self._release()
        if n > Int64(0):
            _ = self._polled.fetch_add(n)
        return out^


# -----------------------------------------------------------------------------
# offer_log_views: the producer-side on-core helper. The drain core calls this
# with the OWNED `List[LogRecordView]` it drained: it does the cheap on-core
# transpose (`log_views_to_record_batch`, the cost class of a text render),
# estimates the bytes and offers the typed batch to the handoff.
#
# Returns True if the batch was accepted into the handoff, False if it was pushed
# back (byte cap OR count cap). On False the views are DROPPED here (the
# destructive ring already popped them), so a False return is the loud signal
# that the off-core stage is saturated: the caller counts it against a distinct
# drop counter, or stops draining so the ring's overflow policy throttles the
# application. A 0-row drain is a no-op success.
# -----------------------------------------------------------------------------


def offer_log_views(
    mut handoff: LogIndexHandoff,
    mut gate: InFlightBytesGate,
    var views: List[LogRecordView],
) raises -> Bool:
    """On-core transpose and offer. Returns True on accept, False on
    backpressure (the caller drops and counts, or stops draining to let the ring
    throttle)."""
    if len(views) == 0:
        return True
    var batch = log_views_to_record_batch(views)
    var est = _estimate_batch_bytes(batch)
    return handoff.offer(batch^, gate, est)
